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
