import CoreGraphics
import Foundation

/// Owns the Edge display coordinate mapping and keeps it correct across display
/// arrangement changes (Dell resolution/scaling changes, reboots that settle the
/// scaled mode after startup, hotplug).
///
/// ## Serialization
/// Every method here is expected to run on ONE serial queue (the driver's
/// `gestureQueue`), the same queue that drives HID touch handling and gesture
/// state transitions. The coordinator itself never dispatches; the owner is
/// responsible for calling it on that queue. This removes every race between the
/// poll timer, the display-reconfiguration callback, HID rematch, the manual
/// trigger, and in-flight touch handling. It also makes the whole state machine
/// trivially unit-testable by calling the methods directly (no permissions, no
/// HID, no run loop, no signals).
///
/// ## State model (see PLAN-DRIVER-RERESOLVE.md)
/// - `lastObserved` — the most recent successful observation; drives churn
///   suppression (a resolve equal to it is a true no-op).
/// - `applied` — what the live coordinate frame currently is.
/// - `pending` — a resolved mapping not yet committed because a gesture is active.
///
/// Reconcile (after a successful resolve) sets/clears `pending` by comparing the
/// desired observation against `applied`. Commit-on-idle is a PURE CONSUMER: it
/// only applies an existing `pending`, never recomputes it — so clearing
/// `pending` before a `forceCancel()` (which synchronously fires the idle hook)
/// genuinely makes that callback a no-op.
public final class DisplayMappingCoordinator {
    /// The resolved state of the Edge display.
    public enum EdgeState: Equatable {
        case present(bounds: CGRect, id: CGDirectDisplayID)
        case absent
    }

    /// Default poll interval. A compile-time constant, not a config field: no
    /// consumer needs runtime tuning, and the whole tick is a cheap bounds read
    /// that no-ops unless the Edge moved.
    public static let defaultInterval: DispatchTimeInterval = .seconds(2)
    /// Timer leeway so periodic firings coalesce (power).
    public static let defaultLeeway: DispatchTimeInterval = .milliseconds(200)

    private let resolver: DisplayResolver
    private let queue: DispatchQueue
    private let setMapper: (CoordinateMapper?) -> Void
    private let isControllerIdle: () -> Bool
    private let cancelActiveInput: () -> Void
    private let interval: DispatchTimeInterval
    private let leeway: DispatchTimeInterval

    // Queue-confined state.
    private var lastObserved: EdgeState?
    private var applied: EdgeState?
    private var pending: (mapper: CoordinateMapper, state: EdgeState)?
    private var isStopping = false
    private var pollTimer: DispatchSourceTimer?

    /// - Parameters:
    ///   - resolver: enumerates + matches the Edge (stateless).
    ///   - queue: the single serial queue all calls run on (the gesture queue).
    ///   - setMapper: installs the live mapper (or `nil` on loss) where the
    ///     gesture controller reads it.
    ///   - isControllerIdle: true when no gesture is in flight (read on `queue`).
    ///   - cancelActiveInput: cancels any in-flight gesture + its stuck timer
    ///     (used on manual refresh and on display loss).
    public init(
        resolver: DisplayResolver,
        queue: DispatchQueue,
        setMapper: @escaping (CoordinateMapper?) -> Void,
        isControllerIdle: @escaping () -> Bool,
        cancelActiveInput: @escaping () -> Void,
        interval: DispatchTimeInterval = DisplayMappingCoordinator.defaultInterval,
        leeway: DispatchTimeInterval = DisplayMappingCoordinator.defaultLeeway
    ) {
        self.resolver = resolver
        self.queue = queue
        self.setMapper = setMapper
        self.isControllerIdle = isControllerIdle
        self.cancelActiveInput = cancelActiveInput
        self.interval = interval
        self.leeway = leeway
    }

    /// Startup: resolve once, then begin the periodic safety-net poll. Call on `queue`.
    public func start() {
        reconcile(reason: "startup")
        startPollTimer()
    }

    /// An automatic re-resolve (poll tick, display-reconfiguration callback, HID
    /// rematch, or a touch that found no mapper). Call on `queue`.
    public func reconcile(reason: String) {
        guard !isStopping else { return }
        guard let observation = observe() else { return } // .failed: mapping untouched
        applyObservation(observation, reason: reason, manual: false)
    }

    /// Operator-initiated refresh (SIGUSR1). Compares against `applied` (not the
    /// resolver's change result, which may be `.unchanged` when the desired frame
    /// is already sitting in `pending`), clears `pending`, cancels any active
    /// gesture, and commits once. Call on `queue`.
    public func manualRefresh() {
        guard !isStopping else { return }
        guard let observation = observe() else {
            log("manual refresh: enumeration failed, mapping untouched")
            return
        }
        applyObservation(observation, reason: "manual SIGUSR1", manual: true)
    }

    /// PURE CONSUMER — commits an already-computed `pending` when the controller
    /// becomes idle. Never recomputes `pending`. Call from the gesture
    /// controller's `onBecameIdle` (on `queue`).
    public func commitOnIdle() {
        guard !isStopping, let pending else { return }
        applied = pending.state
        setMapper(pending.mapper)
        self.pending = nil
        log("mapping applied (\(originString(pending.state))) [deferred]")
    }

    /// Teardown: stop reconciling, cancel the poll timer, and clear `pending`
    /// BEFORE the owner's `forceCancel()` so the idle hook cannot commit during
    /// shutdown. Call on `queue`.
    public func shutdown() {
        isStopping = true
        pollTimer?.cancel()
        pollTimer = nil
        pending = nil
    }

    // MARK: - Internals (all on `queue`)

    private func observe() -> EdgeState? {
        switch resolver.enumerate() {
        case .failed:
            return nil
        case .ok(let displays):
            if let match = resolver.resolve(from: displays) {
                return .present(bounds: match.bounds, id: match.displayID)
            }
            return .absent
        }
    }

    private func applyObservation(_ observation: EdgeState, reason: String, manual: Bool) {
        // Churn suppression is vs `lastObserved`. The manual path deliberately
        // skips it and reconciles against `applied` regardless, so a SIGUSR1 with
        // the desired frame already pending still commits.
        if !manual, observation == lastObserved {
            return
        }
        lastObserved = observation

        switch observation {
        case .absent:
            handleLoss()

        case .present(let bounds, _):
            if observation == applied {
                // Reverted to the currently-applied frame (e.g. B -> B -> A):
                // drop any obsolete pending, no swap.
                pending = nil
                if manual {
                    log("manual refresh: already current (\(originString(observation)))")
                }
                return
            }

            let mapper = CoordinateMapper(displayBounds: bounds)
            if manual {
                pending = nil
                cancelActiveInput() // clears any in-flight gesture; idle hook no-ops (pending nil)
                applied = observation
                setMapper(mapper)
                log("mapping applied (\(originString(observation))) [manual]")
            } else if isControllerIdle() {
                pending = nil
                applied = observation
                setMapper(mapper)
                log("mapping applied (\(originString(observation))) [\(reason)]")
            } else {
                pending = (mapper, observation)
                log("mapping deferred (\(originString(observation))) [\(reason), gesture active]")
            }
        }
    }

    private func handleLoss() {
        pending = nil
        applied = .absent
        setMapper(nil)
        cancelActiveInput() // synchronous: HID can stay live after the video link drops
        log("mapping lost")
    }

    private func startPollTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
        timer.setEventHandler { [weak self] in
            self?.reconcile(reason: "poll")
        }
        timer.resume()
        pollTimer = timer
    }

    private func originString(_ state: EdgeState) -> String {
        switch state {
        case .present(let bounds, let id):
            return "id=\(id) x=\(Int(bounds.origin.x)) y=\(Int(bounds.origin.y)) \(Int(bounds.width))x\(Int(bounds.height))"
        case .absent:
            return "absent"
        }
    }

    private func log(_ message: String) {
        DriverLoggers.log(.notice, category: .display, message)
    }
}
