import AppKit
import XCTest
@testable import CmdTabo

final class KeyboardTests: XCTestCase {
    func testPreviewCommandTabAndShiftTabConfirmOnRelease() throws {
        for backwards in [false, true] {
            let delegate = AppDelegate()
            delegate.configureKeyboard()
            delegate.selection.begin(ids: [1, 2, 3], current: 1, backwards: false)
            delegate.showing = true
            delegate.preview = true
            let tab = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true))
            tab.flags = backwards ? [.maskCommand, .maskShift] : .maskCommand
            XCTAssertTrue(delegate.keyboard.handle(type: .keyDown, event: tab))
            XCTAssertFalse(delegate.preview)
            XCTAssertEqual(delegate.selection.selected, backwards ? 1 : 3)
            let release = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: false))
            release.flags = []
            XCTAssertFalse(delegate.keyboard.handle(type: .flagsChanged, event: release))
            XCTAssertFalse(delegate.showing)
            XCTAssertNil(delegate.selection.selected)
            let up = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: false))
            XCTAssertTrue(delegate.keyboard.handle(type: .keyUp, event: up))
        }
    }

    func testMousePreviewStaysOpenWithoutCommand() throws {
        let delegate = AppDelegate()
        delegate.configureKeyboard()
        delegate.showing = true
        delegate.preview = true
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: false))
        event.flags = []
        XCTAssertFalse(delegate.keyboard.handle(type: .flagsChanged, event: event))
        XCTAssertTrue(delegate.showing)
        XCTAssertTrue(delegate.preview)
        delegate.keyboard.onCancel()
    }
}

final class KeyboardOwnershipTests: XCTestCase {
    func testSecureInputRestoresNativeShortcutsEvenWhenTapReportsRunning() {
        let keyboard = Capture(), native = Native()
        var lifecycle = CaptureLifecycle()
        lifecycle.onRelease = { native.restore(); keyboard.stop() }
        KeyboardOwnership.reconcile(eligible: lifecycle.permitsCapture(now: 100), keyboard: keyboard, native: native)
        XCTAssertTrue(keyboard.running)
        XCTAssertTrue(native.overridden)
        lifecycle.updateSecureInput(true, now: 101)
        KeyboardOwnership.reconcile(eligible: lifecycle.permitsCapture(now: 101), keyboard: keyboard, native: native)
        XCTAssertFalse(keyboard.running)
        XCTAssertFalse(native.overridden)
        XCTAssertEqual(keyboard.starts, 1)
        lifecycle.updateSecureInput(false, now: 102)
        KeyboardOwnership.reconcile(eligible: lifecycle.permitsCapture(now: 103), keyboard: keyboard, native: native)
        XCTAssertFalse(native.overridden)
        KeyboardOwnership.reconcile(eligible: lifecycle.permitsCapture(now: 104), keyboard: keyboard, native: native)
        XCTAssertTrue(keyboard.running)
        XCTAssertTrue(native.overridden)
        XCTAssertEqual(keyboard.starts, 2)
    }
    final class Capture: KeyboardCapture {
        var running = false
        var canStart = true
        var starts = 0
        var stops = 0
        func start() -> Bool { starts += 1; running = canStart; return running }
        func stop() { stops += 1; running = false }
    }
    final class Native: NativeShortcutOwnership {
        var overridden = false
        var canAcquire = true
        var acquisitions = 0
        var restorations = 0
        func takeOver() -> Bool { acquisitions += 1; overridden = canAcquire; return overridden }
        func restore() { restorations += 1; overridden = false }
    }

    func testFailedRecoveryRestoresPreviousAcquisitionAndCanRetry() {
        let keyboard = Capture(), native = Native()
        KeyboardOwnership.reconcile(eligible: true, keyboard: keyboard, native: native)
        XCTAssertTrue(native.overridden)
        keyboard.running = false
        keyboard.canStart = false
        KeyboardOwnership.reconcile(eligible: true, keyboard: keyboard, native: native)
        XCTAssertFalse(native.overridden)
        XCTAssertFalse(keyboard.running)
        XCTAssertEqual(native.acquisitions, 1)
        XCTAssertEqual(native.restorations, 1)
        keyboard.canStart = true
        KeyboardOwnership.reconcile(eligible: true, keyboard: keyboard, native: native)
        XCTAssertTrue(native.overridden)
        XCTAssertTrue(keyboard.running)
        KeyboardOwnership.reconcile(eligible: false, keyboard: keyboard, native: native)
        XCTAssertFalse(native.overridden)
        XCTAssertFalse(keyboard.running)
    }

    func testUnavailableOwnershipStopsCapture() {
        let keyboard = Capture(), native = Native()
        native.canAcquire = false
        KeyboardOwnership.reconcile(eligible: true, keyboard: keyboard, native: native)
        XCTAssertFalse(keyboard.running)
        XCTAssertEqual(keyboard.stops, 1)
        XCTAssertEqual(native.restorations, 1)
    }

    func testRunningCaptureDoesNotRestartAndStillAcquiresNativeOwnership() {
        let keyboard = Capture(), native = Native()
        keyboard.running = true
        KeyboardOwnership.reconcile(eligible: true, keyboard: keyboard, native: native)
        XCTAssertEqual(keyboard.starts, 0)
        XCTAssertTrue(native.overridden)
    }
}

final class KeyboardRecoveryTests: XCTestCase {
    private func event(_ key: CGKeyCode = 48, flags: CGEventFlags = .maskCommand) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true))
        event.flags = flags
        return event
    }
    private func drain() {
        let done = expectation(description: "main queue drained")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }
    func testDiagnosticsDistinguishReceivedEventsFromHandledShortcuts() throws {
        let keyboard = Keyboard()
        keyboard.canBegin = { false }
        XCTAssertFalse(keyboard.handle(type: .keyDown, event: try event()))
        XCTAssertEqual(keyboard.eventCount, 1)
        XCTAssertEqual(keyboard.shortcutCount, 0)
        XCTAssertNotNil(keyboard.lastEventTime)
        keyboard.canBegin = { true }
        XCTAssertTrue(keyboard.handle(type: .keyDown, event: try event()))
        XCTAssertEqual(keyboard.eventCount, 2)
        XCTAssertEqual(keyboard.shortcutCount, 1)
        keyboard.stop()
        XCTAssertEqual(keyboard.eventCount, 2)
        XCTAssertEqual(keyboard.shortcutCount, 1)
    }
    func testSecureInputDiscardsQueuedSelectionAndConfirmation() throws {
        let keyboard = Keyboard()
        var lifecycle = CaptureLifecycle()
        var actions: [String] = []
        keyboard.canBegin = { true }
        keyboard.onTab = { _ in actions.append("tab") }
        keyboard.onConfirm = { actions.append("confirm") }
        lifecycle.onRelease = { keyboard.stop() }
        XCTAssertTrue(keyboard.handle(type: .keyDown, event: try event(), deferred: true))
        XCTAssertFalse(keyboard.handle(type: .flagsChanged, event: try event(55, flags: []), deferred: true))
        lifecycle.updateSecureInput(true, now: 100)
        drain()
        XCTAssertEqual(actions, [])
        XCTAssertFalse(lifecycle.permitsCapture(now: 101))
    }
    func testCallbackDefersWindowActionsAndKeepsRapidPressReleaseOrder() throws {
        let keyboard = Keyboard()
        var actions: [String] = []
        keyboard.canBegin = { true }
        keyboard.onTab = { _ in actions.append("tab") }
        keyboard.onStep = { _ in actions.append("step") }
        keyboard.onConfirm = { actions.append("confirm") }
        XCTAssertTrue(keyboard.handle(type: .keyDown, event: try event(), deferred: true))
        XCTAssertTrue(keyboard.handle(type: .keyDown, event: try event(124), deferred: true))
        XCTAssertFalse(keyboard.handle(type: .flagsChanged, event: try event(55, flags: []), deferred: true))
        XCTAssertEqual(actions, [])
        drain()
        XCTAssertEqual(actions, ["tab", "step", "confirm"])
    }
    func testStopInvalidatesQueuedActivationBeforeSleep() throws {
        let keyboard = Keyboard()
        var tabs = 0
        keyboard.canBegin = { true }
        keyboard.onTab = { _ in tabs += 1 }
        XCTAssertTrue(keyboard.handle(type: .keyDown, event: try event(), deferred: true))
        keyboard.stop()
        drain()
        XCTAssertEqual(tabs, 0)
        XCTAssertFalse(keyboard.handle(type: .keyUp, event: try event()))
    }
    func testDisabledTapFailsOpenAndDoesNotRunRecoveryInsideCallback() throws {
        for type in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
            let keyboard = Keyboard()
            var failed = false, opened = false
            keyboard.canBegin = { true }
            keyboard.onTab = { _ in opened = true }
            keyboard.onFailure = { failed = true }
            XCTAssertTrue(keyboard.handle(type: .keyDown, event: try event(), deferred: true))
            XCTAssertFalse(keyboard.handle(type: type, event: try event(), deferred: true))
            XCTAssertFalse(failed)
            XCTAssertFalse(keyboard.handle(type: .keyDown, event: try event()))
            XCTAssertFalse(keyboard.handle(type: .keyUp, event: try event()))
            drain()
            XCTAssertTrue(failed)
            XCTAssertFalse(opened)
        }
    }
    func testMousePreviewStillRequiresCommandTabBeforeConfirming() throws {
        let keyboard = Keyboard()
        var confirmed = false
        keyboard.isShowing = { true }
        keyboard.shouldConfirmOnCommandRelease = { false }
        keyboard.onConfirm = { confirmed = true }
        XCTAssertFalse(keyboard.handle(type: .flagsChanged, event: try event(55, flags: []), deferred: true))
        drain()
        XCTAssertFalse(confirmed)
        XCTAssertTrue(keyboard.handle(type: .keyDown, event: try event(), deferred: true))
        XCTAssertFalse(keyboard.handle(type: .flagsChanged, event: try event(55, flags: []), deferred: true))
        drain()
        XCTAssertTrue(confirmed)
    }
}

extension KeyboardRecoveryTests {
    func testMouseConfirmationEndsSessionAndPreservesConsumedKeyUp() throws {
        let keyboard = Keyboard()
        var showing = false
        keyboard.canBegin = { true }
        keyboard.isShowing = { showing }
        keyboard.onTab = { _ in showing = true }
        XCTAssertTrue(keyboard.handle(type: .keyDown, event: try event(), deferred: true))
        drain()
        XCTAssertTrue(showing)
        showing = false // Overlay confirmation closed the panel.
        for key: CGKeyCode in [123, 124, 126, 125, 36, 76, 53] {
            XCTAssertFalse(keyboard.handle(type: .keyDown, event: try event(key), deferred: true))
        }
        XCTAssertTrue(keyboard.handle(type: .keyUp, event: try event()))
        XCTAssertFalse(keyboard.handle(type: .keyUp, event: try event()))
        drain()
    }

    func testRejectedStartDoesNotLeaveAnInvisibleSession() throws {
        let keyboard = Keyboard()
        keyboard.canBegin = { true }
        // The catalog became unavailable before onTab could open the panel.
        XCTAssertTrue(keyboard.handle(type: .keyDown, event: try event(), deferred: true))
        drain()
        XCTAssertFalse(keyboard.handle(type: .keyDown, event: try event(124), deferred: true))
        XCTAssertTrue(keyboard.handle(type: .keyUp, event: try event()))
        drain()
    }

    func testDelegateCancellationDiscardsPendingOpenWithoutStoppingCapture() throws {
        let delegate = AppDelegate()
        delegate.configureKeyboard()
        let keyboard = delegate.keyboard
        var openings = 0
        keyboard.canBegin = { true }
        keyboard.onTab = { _ in openings += 1; delegate.showing = true }
        XCTAssertTrue(keyboard.handle(type: .keyDown, event: try event(), deferred: true))
        // Settings, filters and overlay confirmation share this cancellation route.
        keyboard.onCancel()
        drain()
        XCTAssertFalse(delegate.showing)
        XCTAssertEqual(openings, 0)
        XCTAssertFalse(keyboard.handle(type: .keyDown, event: try event(124), deferred: true))
        XCTAssertTrue(keyboard.handle(type: .keyUp, event: try event()))
        XCTAssertTrue(keyboard.handle(type: .keyDown, event: try event(), deferred: true))
        drain()
        XCTAssertEqual(openings, 1)
        keyboard.onCancel()
    }

    func testRapidConsecutiveSessionsKeepTheSecondOpening() throws {
        let delegate = AppDelegate()
        delegate.configureKeyboard()
        let keyboard = delegate.keyboard
        var openings = 0
        keyboard.canBegin = { true }
        keyboard.onTab = { _ in openings += 1; delegate.showing = true }
        XCTAssertTrue(keyboard.handle(type: .keyDown, event: try event(), deferred: true))
        XCTAssertFalse(keyboard.handle(type: .flagsChanged, event: try event(55, flags: []), deferred: true))
        XCTAssertTrue(keyboard.handle(type: .keyDown, event: try event(), deferred: true))
        drain()
        XCTAssertEqual(openings, 2)
        XCTAssertTrue(delegate.showing)
        keyboard.onCancel()
    }

    func testTapFailureSurvivesSuspensionBeforeDeferredDelivery() throws {
        for type in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
            let keyboard = Keyboard()
            var lifecycle = CaptureLifecycle()
            keyboard.onFailure = { lifecycle.fail() }
            lifecycle.onRelease = { keyboard.stop() }
            XCTAssertFalse(keyboard.handle(type: type, event: try event(), deferred: true))
            lifecycle.suspend(.systemSleep)
            drain()
            lifecycle.resume(.systemSleep, now: 100)
            XCTAssertTrue(lifecycle.failed)
            XCTAssertFalse(lifecycle.permitsCapture(now: 103))
            lifecycle.retry()
            XCTAssertTrue(lifecycle.permitsCapture(now: 103))
        }
    }

    func testReconciliationCannotAcquireWhileFailureDeliveryIsPending() throws {
        let keyboard = Keyboard()
        let native = KeyboardOwnershipTests.Native()
        var lifecycle = CaptureLifecycle()
        var failures = 0
        keyboard.onFailure = { failures += 1; lifecycle.fail() }
        lifecycle.onRelease = { keyboard.stop() }
        XCTAssertFalse(keyboard.handle(type: .tapDisabledByTimeout, event: try event(), deferred: true))
        XCTAssertFalse(KeyboardOwnership.reconcile(eligible: true, keyboard: keyboard, native: native))
        XCTAssertFalse(native.overridden)
        XCTAssertEqual(native.acquisitions, 0)
        drain()
        XCTAssertEqual(failures, 1)
        XCTAssertTrue(lifecycle.failed)
        XCTAssertFalse(lifecycle.permitsCapture(now: 103))
    }

    func testKeysAfterQueuedConfirmationPassThroughBeforePanelHides() throws {
        let keyboard = Keyboard()
        var visible = true
        keyboard.isShowing = { visible }
        keyboard.onConfirm = { visible = false }
        XCTAssertFalse(keyboard.handle(type: .flagsChanged, event: try event(55, flags: []), deferred: true))
        XCTAssertFalse(keyboard.handle(type: .keyDown, event: try event(124, flags: []), deferred: true))
        drain()
        XCTAssertFalse(visible)
        visible = true // A later mouse preview must accept its navigation again.
        XCTAssertTrue(keyboard.handle(type: .keyDown, event: try event(124, flags: []), deferred: true))
        drain()
    }
}
