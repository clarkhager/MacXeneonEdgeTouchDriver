import CoreGraphics
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class MacXeneonEdgeTouchDriverApplicationTests: XCTestCase {
    func testDeviceMatchRefreshesDisplayMapper() {
        var displays = [xeneonDisplay()]
        let resolver = DisplayResolver(activeDisplayProvider: { .ok(displays) })
        let input = ApplicationRecordingInputSink()
        let cursor = ApplicationRecordingCursorController()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: input,
            cursorController: cursor
        )

        application.handleDeviceMatched()
        displays = []

        application.handleTouchEvent(touchEvent(.down, rawX: 0, rawY: 0))
        application.handleTouchEvent(touchEvent(.up, rawX: 0, rawY: 0))

        XCTAssertEqual(cursor.calls, [.borrow(CGPoint(x: 100, y: 200)), .returnToOrigin])
        XCTAssertEqual(input.calls, [.mouseDown(CGPoint(x: 100, y: 200)), .mouseUp(CGPoint(x: 100, y: 200))])
    }

    func testTouchEventRefreshesMissingDisplayMapperBeforeDropping() {
        let displays = [xeneonDisplay()]
        let resolver = DisplayResolver(activeDisplayProvider: { .ok(displays) })
        let input = ApplicationRecordingInputSink()
        let cursor = ApplicationRecordingCursorController()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: input,
            cursorController: cursor
        )

        application.handleTouchEvent(touchEvent(.down, rawX: 0, rawY: 0))
        application.handleTouchEvent(touchEvent(.up, rawX: 0, rawY: 0))

        XCTAssertEqual(cursor.calls, [.borrow(CGPoint(x: 100, y: 200)), .returnToOrigin])
        XCTAssertEqual(input.calls, [.mouseDown(CGPoint(x: 100, y: 200)), .mouseUp(CGPoint(x: 100, y: 200))])
    }

    /// Exercises the REAL production idle wiring (`installDisplayIdleHook`, the
    /// exact hook `run()` installs) without `run()`'s permission/HID/run-loop side
    /// effects: a display change mid-gesture is deferred and only swaps the mapper
    /// after the gesture ends. If the hook regresses (e.g. loses its
    /// `commitOnIdle`), the second gesture would emit at the stale origin and this
    /// fails.
    func testIdleHookDefersMapperSwapUntilGestureEnds() {
        var displays = [xeneonDisplay(y: 200)]
        let resolver = DisplayResolver(activeDisplayProvider: { .ok(displays) })
        let input = ApplicationRecordingInputSink()
        let cursor = ApplicationRecordingCursorController()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: input,
            cursorController: cursor
        )
        application.installDisplayIdleHook()

        application.handleDeviceMatched() // apply A @ y=200

        // Gesture 1 on A; display moves mid-gesture -> must defer.
        application.handleTouchEvent(touchEvent(.down, rawX: 0, rawY: 0))
        displays = [xeneonDisplay(y: 800)]
        application.handleDeviceMatched()  // reconcile mid-gesture -> deferred
        application.handleTouchEvent(touchEvent(.up, rawX: 0, rawY: 0)) // ends -> real idle hook commits B

        // Gesture 2 on B.
        application.handleTouchEvent(touchEvent(.down, rawX: 0, rawY: 0))
        application.handleTouchEvent(touchEvent(.up, rawX: 0, rawY: 0))

        XCTAssertEqual(input.calls, [
            .mouseDown(CGPoint(x: 100, y: 200)),
            .mouseUp(CGPoint(x: 100, y: 200)),
            .mouseDown(CGPoint(x: 100, y: 800)),
            .mouseUp(CGPoint(x: 100, y: 800))
        ])
    }

    /// Exercises the REAL production teardown ordering (`teardownDisplayHandling`,
    /// the exact block `stop()` runs): the coordinator must be shut down (pending
    /// cleared) BEFORE `forceCancel()` fires `onBecameIdle`. With a display change
    /// pending mid-gesture at teardown, a stale B must never be committed — a probe
    /// tap right after teardown must still land on A. If the two calls were
    /// reordered, the probe would land on B and this fails.
    func testTeardownShutsCoordinatorBeforeForceCancelSoNoStaleCommit() {
        var displays = [xeneonDisplay(y: 200)]
        let resolver = DisplayResolver(activeDisplayProvider: { .ok(displays) })
        let input = ApplicationRecordingInputSink()
        let cursor = ApplicationRecordingCursorController()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: input,
            cursorController: cursor
        )
        application.installDisplayIdleHook()
        application.handleDeviceMatched() // apply A @ y=200

        application.handleTouchEvent(touchEvent(.down, rawX: 0, rawY: 0)) // gesture active on A
        displays = [xeneonDisplay(y: 800)]
        application.handleDeviceMatched() // reconcile B mid-gesture -> pending B

        application.teardownDisplayHandling() // shutdown() THEN forceCancel(): must not commit B

        // Probe tap reveals the surviving mapper: still A.
        application.handleTouchEvent(touchEvent(.down, rawX: 0, rawY: 0))
        application.handleTouchEvent(touchEvent(.up, rawX: 0, rawY: 0))

        XCTAssertEqual(input.calls, [
            .mouseDown(CGPoint(x: 100, y: 200)), // gesture 1 down on A
            .mouseUp(CGPoint(x: 100, y: 200)),   // teardown forceCancel cleanup up on A
            .mouseDown(CGPoint(x: 100, y: 200)), // probe still on A (B never committed)
            .mouseUp(CGPoint(x: 100, y: 200))
        ])
    }

    private func immediateConfiguration() -> DriverConfiguration {
        var configuration = DriverConfiguration.defaults
        configuration.timing.warpToClickDelayMs = 0
        configuration.timing.downToUpDelayMs = 0
        configuration.timing.clickToWarpBackDelayMs = 0
        configuration.timing.tapDebounceMs = 0
        configuration.timing.stuckGestureTimeoutMs = 1_000
        return configuration
    }

    private func xeneonDisplay(y: CGFloat = 200) -> DisplaySnapshot {
        DisplaySnapshot(
            displayID: 42,
            vendorNumber: CapturedXeneonDisplay.vendorNumber,
            modelNumber: CapturedXeneonDisplay.modelNumber,
            serialNumber: CapturedXeneonDisplay.observedSerialNumber,
            bounds: CGRect(x: 100, y: y, width: 2_560, height: 720),
            pixelsWide: CapturedXeneonDisplay.expectedWidth,
            pixelsHigh: CapturedXeneonDisplay.expectedHeight
        )
    }

    private func touchEvent(_ kind: TouchEvent.Kind, rawX: Int, rawY: Int) -> TouchEvent {
        TouchEvent(kind: kind, contactID: 0, rawX: rawX, rawY: rawY, timestamp: .now())
    }
}

private final class ApplicationRecordingInputSink: SyntheticInputSink {
    enum Call: Equatable {
        case mouseDown(CGPoint)
        case mouseUp(CGPoint)
        case mouseDragged(CGPoint)
    }

    private(set) var calls: [Call] = []

    func postMouseDown(at point: CGPoint) {
        calls.append(.mouseDown(point))
    }

    func postMouseUp(at point: CGPoint) {
        calls.append(.mouseUp(point))
    }

    func postMouseDragged(to point: CGPoint) {
        calls.append(.mouseDragged(point))
    }
}

private final class ApplicationRecordingCursorController: CursorController {
    enum Call: Equatable {
        case borrow(CGPoint)
        case update(CGPoint)
        case returnToOrigin
        case forceShow
    }

    private(set) var calls: [Call] = []

    func borrow(warpingTo point: CGPoint) -> Bool {
        calls.append(.borrow(point))
        return true
    }

    func updatePosition(_ point: CGPoint) {
        calls.append(.update(point))
    }

    func returnToOrigin() {
        calls.append(.returnToOrigin)
    }

    func forceShow() {
        calls.append(.forceShow)
    }
}
