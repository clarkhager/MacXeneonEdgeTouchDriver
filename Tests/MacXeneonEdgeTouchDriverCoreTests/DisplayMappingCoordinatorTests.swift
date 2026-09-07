import CoreGraphics
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

/// State-machine tests for `DisplayMappingCoordinator`. These call the
/// coordinator's methods directly on the test thread (it never dispatches
/// internally and the poll timer is only started by `start()`, which these tests
/// do not call), so they are fully deterministic and hardware-free.
final class DisplayMappingCoordinatorTests: XCTestCase {
    // Test-controlled collaborators.
    private var enumeration: DisplayEnumeration = .ok([])
    private var appliedOrigins: [CGRect?] = []
    private var idle = true
    private var cancelCount = 0

    private func makeCoordinator() -> DisplayMappingCoordinator {
        let resolver = DisplayResolver(activeDisplayProvider: { [unowned self] in self.enumeration })
        return DisplayMappingCoordinator(
            resolver: resolver,
            queue: DispatchQueue(label: "test.coordinator"),
            setMapper: { [unowned self] mapper in self.appliedOrigins.append(mapper?.displayBounds) },
            isControllerIdle: { [unowned self] in self.idle },
            cancelActiveInput: { [unowned self] in self.cancelCount += 1 }
        )
    }

    private func edge(y: CGFloat, id: CGDirectDisplayID = 3) -> DisplaySnapshot {
        DisplaySnapshot(
            displayID: id,
            vendorNumber: CapturedXeneonDisplay.vendorNumber,
            modelNumber: CapturedXeneonDisplay.modelNumber,
            serialNumber: CapturedXeneonDisplay.observedSerialNumber,
            bounds: CGRect(x: 248, y: y, width: 2_560, height: 720),
            pixelsWide: CapturedXeneonDisplay.expectedWidth,
            pixelsHigh: CapturedXeneonDisplay.expectedHeight
        )
    }

    private var appliedYs: [CGFloat?] { appliedOrigins.map { $0?.origin.y } }

    func testReconcileWhileIdleAppliesImmediately() {
        enumeration = .ok([edge(y: 1_080)])
        let c = makeCoordinator()
        c.reconcile(reason: "startup")
        XCTAssertEqual(appliedYs, [1_080])
    }

    func testChangeWhileIdleReappliesImmediately() {
        let c = makeCoordinator()
        enumeration = .ok([edge(y: 1_080)]); c.reconcile(reason: "poll")
        enumeration = .ok([edge(y: 1_692)]); c.reconcile(reason: "poll")
        XCTAssertEqual(appliedYs, [1_080, 1_692])
    }

    func testUnchangedReconcileIsSilentNoOp() {
        let c = makeCoordinator()
        enumeration = .ok([edge(y: 1_080)]); c.reconcile(reason: "poll")
        c.reconcile(reason: "poll")
        c.reconcile(reason: "poll")
        XCTAssertEqual(appliedYs, [1_080]) // only the first applied
    }

    func testChangeMidGestureDefersUntilIdle() {
        let c = makeCoordinator()
        enumeration = .ok([edge(y: 1_080)]); idle = true; c.reconcile(reason: "startup")
        idle = false
        enumeration = .ok([edge(y: 1_692)]); c.reconcile(reason: "poll")
        XCTAssertEqual(appliedYs, [1_080]) // deferred, not yet applied
        c.commitOnIdle()
        XCTAssertEqual(appliedYs, [1_080, 1_692]) // applied on idle
    }

    /// The R2#1 regression: B -> B -> A during a drag must end at A with no
    /// obsolete B swap.
    func testReversionDuringGestureClearsPending() {
        let c = makeCoordinator()
        enumeration = .ok([edge(y: 1_080)]); idle = true; c.reconcile(reason: "startup") // apply A
        idle = false
        enumeration = .ok([edge(y: 1_692)]); c.reconcile(reason: "poll")  // B -> pending
        enumeration = .ok([edge(y: 1_692)]); c.reconcile(reason: "poll")  // B -> unchanged
        enumeration = .ok([edge(y: 1_080)]); c.reconcile(reason: "poll")  // back to A == applied
        c.commitOnIdle()
        XCTAssertEqual(appliedYs, [1_080]) // never applied the obsolete B
    }

    func testUnchangedPollLeavesPendingIntact() {
        let c = makeCoordinator()
        enumeration = .ok([edge(y: 1_080)]); idle = true; c.reconcile(reason: "startup")
        idle = false
        enumeration = .ok([edge(y: 1_692)]); c.reconcile(reason: "poll")  // pending B
        enumeration = .ok([edge(y: 1_692)]); c.reconcile(reason: "poll")  // unchanged, pending stays
        c.commitOnIdle()
        XCTAssertEqual(appliedYs, [1_080, 1_692])
    }

    func testManualRefreshCommitsAlreadyPendingChange() {
        let c = makeCoordinator()
        enumeration = .ok([edge(y: 1_080)]); idle = true; c.reconcile(reason: "startup") // apply A
        idle = false
        enumeration = .ok([edge(y: 1_692)]); c.reconcile(reason: "poll")  // pending B, resolver now returns B
        c.manualRefresh() // B still current => resolver says .unchanged, but manual compares vs applied
        XCTAssertEqual(appliedYs, [1_080, 1_692]) // committed once
        XCTAssertEqual(cancelCount, 1)            // active gesture cancelled
        c.commitOnIdle()                          // idle hook must not double-commit
        XCTAssertEqual(appliedYs, [1_080, 1_692])
    }

    func testManualRefreshAlreadyCurrentIsNoOp() {
        let c = makeCoordinator()
        enumeration = .ok([edge(y: 1_080)]); idle = true; c.reconcile(reason: "startup")
        c.manualRefresh()
        XCTAssertEqual(appliedYs, [1_080])
        XCTAssertEqual(cancelCount, 0) // already current: no cancel, no swap
    }

    func testDisplayLossCancelsSynchronouslyAndClearsMapper() {
        let c = makeCoordinator()
        enumeration = .ok([edge(y: 1_080)]); idle = true; c.reconcile(reason: "startup")
        enumeration = .ok([]); c.reconcile(reason: "poll") // Edge absent (empty list) => loss
        XCTAssertEqual(appliedYs, [1_080, nil]) // mapper cleared
        XCTAssertEqual(cancelCount, 1)          // input cancelled synchronously
        enumeration = .ok([]); c.reconcile(reason: "poll") // still absent => unchanged
        XCTAssertEqual(cancelCount, 1)          // not repeated
        XCTAssertEqual(appliedYs, [1_080, nil])
        enumeration = .ok([edge(y: 1_692)]); c.reconcile(reason: "poll") // replug
        XCTAssertEqual(appliedYs, [1_080, nil, 1_692])
    }

    func testEnumerationFailureLeavesMappingUntouched() {
        let c = makeCoordinator()
        enumeration = .ok([edge(y: 1_080)]); idle = true; c.reconcile(reason: "startup")
        enumeration = .failed; c.reconcile(reason: "poll")
        XCTAssertEqual(appliedYs, [1_080]) // untouched
        XCTAssertEqual(cancelCount, 0)
    }

    func testShutdownStopsAllCommits() {
        let c = makeCoordinator()
        enumeration = .ok([edge(y: 1_080)]); idle = true; c.reconcile(reason: "startup")
        idle = false
        enumeration = .ok([edge(y: 1_692)]); c.reconcile(reason: "poll") // pending B
        c.shutdown()
        c.commitOnIdle()
        enumeration = .ok([edge(y: 1_692)]); c.reconcile(reason: "poll")
        c.manualRefresh()
        XCTAssertEqual(appliedYs, [1_080]) // nothing after shutdown
    }

    /// Proves the ordering that prevents a double commit: on manual refresh, a
    /// `cancelActiveInput()` that synchronously fires `commitOnIdle` (exactly what
    /// production's `forceCancel()` -> `onBecameIdle` does) must NOT commit the
    /// old pending, because manual clears `pending` BEFORE cancelling. If the
    /// clear moved below the cancel, this test would see a duplicate.
    func testManualRefreshDoesNotDoubleCommitWhenCancelFiresIdleHook() {
        var applied: [CGFloat?] = []
        var currentEnum: DisplayEnumeration = .ok([edge(y: 1_080)])
        var gestureIdle = true
        var coordinatorRef: DisplayMappingCoordinator!
        let resolver = DisplayResolver(activeDisplayProvider: { currentEnum })
        let coordinator = DisplayMappingCoordinator(
            resolver: resolver,
            queue: DispatchQueue(label: "test.synccancel"),
            setMapper: { applied.append($0?.displayBounds.origin.y) },
            isControllerIdle: { gestureIdle },
            cancelActiveInput: { coordinatorRef.commitOnIdle() } // forceCancel -> onBecameIdle
        )
        coordinatorRef = coordinator

        coordinator.reconcile(reason: "startup") // idle: apply A
        gestureIdle = false
        currentEnum = .ok([edge(y: 1_692)])
        coordinator.reconcile(reason: "poll")    // pending B (deferred)
        coordinator.manualRefresh()              // clears pending, cancels (idle hook no-ops), commits once
        XCTAssertEqual(applied, [1_080, 1_692])  // exactly one B, not two
    }

    func testManualRefreshWhileAbsentDoesNotRepeatLoss() {
        let c = makeCoordinator()
        enumeration = .ok([edge(y: 1_080)]); idle = true; c.reconcile(reason: "startup")
        enumeration = .ok([]); c.reconcile(reason: "poll") // loss
        XCTAssertEqual(appliedYs, [1_080, nil])
        XCTAssertEqual(cancelCount, 1)
        c.manualRefresh()                                  // still absent: already current
        XCTAssertEqual(appliedYs, [1_080, nil])            // no repeat clear
        XCTAssertEqual(cancelCount, 1)                     // no repeat cancel
    }

    /// Integration: a real GestureController proves in-flight touch events use the
    /// PRE-change mapper and the swap takes effect only after the gesture ends,
    /// asserted on the actual emitted mouse coordinates. (raw 0 maps to the
    /// mapper's display origin.)
    func testInFlightGestureUsesPreChangeMapperThenSwapsOnIdle() {
        let box = MapperBox()
        let input = RecordingInputSink()
        let cursor = RecordingCursorController()
        let controller = GestureController(
            mapperProvider: { box.mapper },
            inputSink: input,
            cursorController: cursor,
            timing: .immediate
        )

        var currentEnum: DisplayEnumeration = .ok([edge(y: 200)])
        let resolver = DisplayResolver(activeDisplayProvider: { currentEnum })
        let coordinator = DisplayMappingCoordinator(
            resolver: resolver,
            queue: DispatchQueue(label: "test.integration"),
            setMapper: { box.mapper = $0 },
            isControllerIdle: { controller.state == .idle },
            cancelActiveInput: { controller.forceCancel() }
        )
        controller.onBecameIdle = { [weak coordinator] in coordinator?.commitOnIdle() }

        coordinator.reconcile(reason: "startup") // apply A @ y=200

        // Gesture 1 on A.
        controller.handle(TouchEvent(kind: .down, contactID: 0, rawX: 0, rawY: 0, timestamp: .now()))
        // Display moves mid-gesture; must be deferred.
        currentEnum = .ok([edge(y: 800)])
        coordinator.reconcile(reason: "display reconfiguration")
        controller.handle(TouchEvent(kind: .up, contactID: 0, rawX: 0, rawY: 0, timestamp: .now())) // ends gesture -> idle -> commit B

        // Gesture 2 on B.
        controller.handle(TouchEvent(kind: .down, contactID: 0, rawX: 0, rawY: 0, timestamp: .now()))
        controller.handle(TouchEvent(kind: .up, contactID: 0, rawX: 0, rawY: 0, timestamp: .now()))

        XCTAssertEqual(input.calls, [
            .mouseDown(CGPoint(x: 248, y: 200)), // gesture 1 used pre-change mapper A
            .mouseUp(CGPoint(x: 248, y: 200)),
            .mouseDown(CGPoint(x: 248, y: 800)), // gesture 2 used post-idle mapper B
            .mouseUp(CGPoint(x: 248, y: 800))
        ])
    }
}

private final class MapperBox {
    var mapper: CoordinateMapper?
}

private final class RecordingInputSink: SyntheticInputSink {
    enum Call: Equatable {
        case mouseDown(CGPoint)
        case mouseUp(CGPoint)
        case mouseDragged(CGPoint)
    }

    private(set) var calls: [Call] = []
    func postMouseDown(at point: CGPoint) { calls.append(.mouseDown(point)) }
    func postMouseUp(at point: CGPoint) { calls.append(.mouseUp(point)) }
    func postMouseDragged(to point: CGPoint) { calls.append(.mouseDragged(point)) }
}

private final class RecordingCursorController: CursorController {
    func borrow(warpingTo point: CGPoint) -> Bool { true }
    func updatePosition(_ point: CGPoint) {}
    func returnToOrigin() {}
    func forceShow() {}
}
