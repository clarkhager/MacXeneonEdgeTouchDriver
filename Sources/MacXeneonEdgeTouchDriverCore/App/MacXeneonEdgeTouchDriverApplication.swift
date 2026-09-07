import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation

/// Production application wiring for the Xeneon Edge single-touch driver.
public final class MacXeneonEdgeTouchDriverApplication {
    private let configuration: DriverConfiguration
    private let displayResolver: DisplayResolver
    private let mapperStore = CoordinateMapperStore()
    private let gestureQueue = DispatchQueue(label: "\(DriverLoggers.subsystem).gesture-queue")
    private let inputSink: SyntheticInputSink
    private let cursorController: CursorController
    private let focusRestorer: FocusRestorer

    private lazy var gestureController = GestureController(
        mapperProvider: { [mapperStore] in
            mapperStore.currentMapper
        },
        inputSink: inputSink,
        cursorController: cursorController,
        focusRestorer: focusRestorer,
        timing: GestureTiming(configuration: configuration.timing),
        schedulingQueue: gestureQueue
    )

    /// Owns the Edge coordinate mapping and keeps it re-resolved across display
    /// arrangement changes. Every call runs on `gestureQueue` (the one serial
    /// domain shared with HID touch handling and gesture-state transitions).
    private lazy var displayCoordinator = DisplayMappingCoordinator(
        resolver: displayResolver,
        queue: gestureQueue,
        setMapper: { [weak self] mapper in
            self?.mapperStore.currentMapper = mapper
        },
        isControllerIdle: { [weak self] in
            self?.gestureController.state == .idle
        },
        cancelActiveInput: { [weak self] in
            self?.cancelStuckGestureTimer()
            self?.gestureController.forceCancel()
        }
    )

    private lazy var hidMonitor = HIDDeviceMonitor(
        eventQueue: gestureQueue,
        seizeDevice: true,
        touchEventHandler: { [weak self] event in
            self?.handleTouchEvent(event)
        },
        deviceRemovalHandler: { [weak self] in
            self?.handleDeviceRemoval()
        },
        deviceMatchedHandler: { [weak self] in
            self?.handleDeviceMatched()
        }
    )

    private var stuckGestureTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var manualRefreshSource: DispatchSourceSignal?
    private var didRegisterDisplayCallback = false
    private var isRunning = false

    /// Creates a production application with CoreGraphics side effects.
    public convenience init(configuration: DriverConfiguration = .defaults) {
        self.init(
            configuration: configuration,
            displayResolver: DisplayResolver(configuration: configuration.display),
            inputSink: CGEventInputSink(),
            cursorController: CGCursorController(),
            focusRestorer: AXFocusRestorer()
        )
    }

    /// Creates an application with injectable side-effect dependencies.
    public init(
        configuration: DriverConfiguration,
        displayResolver: DisplayResolver,
        inputSink: SyntheticInputSink,
        cursorController: CursorController,
        focusRestorer: FocusRestorer = NoOpFocusRestorer()
    ) {
        self.configuration = configuration
        self.displayResolver = displayResolver
        self.inputSink = inputSink
        self.cursorController = cursorController
        self.focusRestorer = focusRestorer
    }

    deinit {
        stop()
    }

    /// Starts the driver and runs the main CFRunLoop until stopped.
    public func run() -> Int32 {
        guard !isRunning else {
            return EXIT_SUCCESS
        }

        isRunning = true
        DriverLoggers.log(.notice, category: .lifecycle, "Starting Mac Xeneon Edge Touch Driver in single-touch mode.")
        gestureController.onBecameIdle = { [weak self] in
            self?.cancelStuckGestureTimer()
            self?.displayCoordinator.commitOnIdle()
        }

        guard verifySyntheticEventPermission() else {
            stop()
            return EXIT_FAILURE
        }

        // Startup resolve + start the periodic re-resolve safety net, on the queue.
        gestureQueue.sync {
            displayCoordinator.start()
        }
        registerDisplayReconfigurationCallback()
        installSignalHandlers()
        installManualRefreshHandler()

        do {
            try hidMonitor.start()
        } catch {
            DriverLoggers.log(.fault, category: .lifecycle, "Could not start HID monitor: \(error.localizedDescription)")
            stop()
            return EXIT_FAILURE
        }

        CFRunLoopRun()
        return EXIT_SUCCESS
    }

    /// Stops monitoring and restores cursor/input state.
    public func stop() {
        guard isRunning else {
            return
        }

        hidMonitor.stop()
        gestureQueue.sync {
            // Shut the coordinator down FIRST: sets isStopping, cancels the poll
            // timer, and clears any pending mapping BEFORE forceCancel() (which
            // synchronously fires onBecameIdle) so no mapping commits during teardown.
            displayCoordinator.shutdown()
            cancelStuckGestureTimer()
            gestureController.forceCancel()
        }
        unregisterDisplayReconfigurationCallback()
        manualRefreshSource?.cancel()
        manualRefreshSource = nil
        signalSources.removeAll()
        isRunning = false

        DriverLoggers.log(.notice, category: .lifecycle, "Stopped Mac Xeneon Edge Touch Driver.")
        CFRunLoopStop(CFRunLoopGetMain())
    }

    fileprivate func handleDisplayReconfiguration() {
        gestureQueue.async { [weak self] in
            self?.displayCoordinator.reconcile(reason: "display reconfiguration")
        }
    }

    func handleTouchEvent(_ event: TouchEvent) {
        if mapperStore.currentMapper == nil {
            displayCoordinator.reconcile(reason: "touch without mapper")
        }

        gestureController.handle(event)

        switch gestureController.state {
        case .idle:
            cancelStuckGestureTimer()

        case .singleTouch:
            scheduleStuckGestureTimer()
        }
    }

    func handleDeviceMatched() {
        displayCoordinator.reconcile(reason: "HID device match")
    }

    private func handleDeviceRemoval() {
        cancelStuckGestureTimer()
        gestureController.forceCancel()
    }

    private func scheduleStuckGestureTimer() {
        cancelStuckGestureTimer()

        let timer = DispatchSource.makeTimerSource(queue: gestureQueue)
        timer.schedule(deadline: .now() + .milliseconds(configuration.timing.stuckGestureTimeoutMs))
        timer.setEventHandler { [weak self] in
            DriverLoggers.log(.warning, category: .gesture, "Touch gesture timed out without an up event; forcing cleanup.")
            self?.gestureController.handleIdleTimeout()
            self?.stuckGestureTimer = nil
        }
        timer.resume()
        stuckGestureTimer = timer
    }

    private func cancelStuckGestureTimer() {
        stuckGestureTimer?.setEventHandler {}
        stuckGestureTimer?.cancel()
        stuckGestureTimer = nil
    }

    private func registerDisplayReconfigurationCallback() {
        guard !didRegisterDisplayCallback else {
            return
        }

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let result = CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, context)

        if result == .success {
            didRegisterDisplayCallback = true
        } else {
            DriverLoggers.log(.error, category: .display, "CGDisplayRegisterReconfigurationCallback failed with \(result.rawValue).")
        }
    }

    private func unregisterDisplayReconfigurationCallback() {
        guard didRegisterDisplayCallback else {
            return
        }

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let result = CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, context)

        if result != .success {
            DriverLoggers.log(.error, category: .display, "CGDisplayRemoveReconfigurationCallback failed with \(result.rawValue).")
        }
        didRegisterDisplayCallback = false
    }

    private func installSignalHandlers() {
        signalSources = [SIGINT, SIGTERM].map { signalNumber in
            ignoreDefaultSignalAction(signalNumber)

            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                DriverLoggers.log(.notice, category: .lifecycle, "Received signal \(signalNumber); stopping driver.")
                self?.stop()
            }
            source.resume()
            return source
        }
    }

    /// SIGUSR1 = manual "refresh touch mapping". A SEPARATE retained source (NOT
    /// in the SIGINT/SIGTERM stop array); SIG_IGN installed before resume so the
    /// default terminate action never fires. The refresh runs on the gesture queue.
    private func installManualRefreshHandler() {
        ignoreDefaultSignalAction(SIGUSR1)

        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            DriverLoggers.log(.notice, category: .display, "Received SIGUSR1; refreshing touch mapping.")
            self.gestureQueue.async {
                self.displayCoordinator.manualRefresh()
            }
        }
        source.resume()
        manualRefreshSource = source
    }

    private func verifySyntheticEventPermission() -> Bool {
        if CGPreflightPostEventAccess() {
            DriverLoggers.log(.notice, category: .lifecycle, "CoreGraphics post-event permission is granted.")
            return true
        }

        logPermissionIdentity()
        DriverLoggers.log(.error, category: .lifecycle, "CoreGraphics post-event permission is not granted; requesting permission if macOS will show a prompt.")

        if CGRequestPostEventAccess() {
            DriverLoggers.log(.notice, category: .lifecycle, "CoreGraphics post-event permission was granted after request.")
            return true
        }

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let isAXTrusted = AXIsProcessTrustedWithOptions(options)
        if isAXTrusted || CGPreflightPostEventAccess() {
            DriverLoggers.log(.notice, category: .lifecycle, "Accessibility trust is granted after prompt.")
            return true
        }

        DriverLoggers.log(
            .fault,
            category: .lifecycle,
            "Synthetic mouse event permission is not granted. Grant Accessibility to the executable or to the launcher app named in the previous log line, then restart the driver."
        )
        return false
    }

    private func logPermissionIdentity() {
        let executablePath = Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? "Unknown executable"
        let launcherPath = NSRunningApplication(processIdentifier: getppid())?.bundleURL?.path ?? "Unknown launcher"

        DriverLoggers.log(.error, category: .lifecycle, "Permission identity: executable=\(executablePath), launcher=\(launcherPath).")
    }

    private func ignoreDefaultSignalAction(_ signalNumber: Int32) {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = SIG_IGN
        action.sa_flags = 0
        sigemptyset(&action.sa_mask)

        if sigaction(signalNumber, &action, nil) != 0 {
            DriverLoggers.log(.error, category: .lifecycle, "sigaction failed for signal \(signalNumber).")
        }
    }
}

private final class CoordinateMapperStore {
    private let lock = NSLock()
    private var storedMapper: CoordinateMapper?

    var currentMapper: CoordinateMapper? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedMapper
        }
        set {
            lock.lock()
            storedMapper = newValue
            lock.unlock()
        }
    }
}

private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, _, context in
    guard let context else {
        return
    }

    let application = Unmanaged<MacXeneonEdgeTouchDriverApplication>.fromOpaque(context).takeUnretainedValue()
    application.handleDisplayReconfiguration()
}
