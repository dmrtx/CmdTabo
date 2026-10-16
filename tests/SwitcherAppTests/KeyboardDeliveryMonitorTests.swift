import AppKit
import XCTest
@testable import CmdTabo

final class KeyboardDeliveryMonitorTests: XCTestCase {
    func testEnabledButSilentTapRestoresNativeShortcutsAndLatchesFailureAcrossWake() {
        let keyboard = KeyboardOwnershipTests.Capture(), native = KeyboardOwnershipTests.Native()
        var lifecycle = CaptureLifecycle()
        var monitor = KeyboardDeliveryMonitor()
        lifecycle.onRelease = { native.restore(); keyboard.stop() }
        XCTAssertTrue(KeyboardOwnership.reconcile(eligible: true, keyboard: keyboard, native: native))
        XCTAssertTrue(keyboard.running)
        XCTAssertTrue(native.overridden)
        XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 100, deliveredKeyDowns: 10, now: 0))
        for now in [0.5, 1, 1.5, 2] {
            XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 101, deliveredKeyDowns: 10, now: now))
        }
        let stalled = monitor.observe(active: true, systemKeyDowns: 101, deliveredKeyDowns: 10, now: 2.5)
        XCTAssertTrue(stalled)
        if !KeyboardOwnership.reconcile(eligible: true, keyboard: keyboard, native: native, deliveryStalled: stalled) {
            lifecycle.fail()
        }
        XCTAssertFalse(keyboard.running)
        XCTAssertFalse(native.overridden)
        XCTAssertEqual(native.acquisitions, 1)
        lifecycle.suspend(.systemSleep)
        lifecycle.resume(.systemSleep, now: 100)
        KeyboardOwnership.reconcile(eligible: lifecycle.permitsCapture(now: 110), keyboard: keyboard, native: native)
        XCTAssertFalse(native.overridden)
        lifecycle.retry()
        monitor.reset()
        XCTAssertTrue(KeyboardOwnership.reconcile(eligible: lifecycle.permitsCapture(now: 111), keyboard: keyboard, native: native))
        XCTAssertTrue(native.overridden)
    }

    func testIdleAndUnavailableSystemCounterNeverTriggerFailure() {
        for count: UInt32 in [0, 100] {
            var monitor = KeyboardDeliveryMonitor()
            for tick in 0...100 {
                XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: count, deliveredKeyDowns: 0, now: Double(tick) / 2))
            }
        }
    }

    func testDeliveryProgressNeedNotMatchHardwareDeltaOrAutorepeat() {
        var monitor = KeyboardDeliveryMonitor()
        XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 100, deliveredKeyDowns: 10, now: 0))
        for tick in 1...10 {
            XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 100 + UInt32(tick * 3),
                                          deliveredKeyDowns: 10 + UInt64(tick), now: Double(tick) / 2))
        }
        // Received repeats prove delivery even though the hardware counter is unchanged.
        XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 131, deliveredKeyDowns: 20, now: 5.5))
        XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 131, deliveredKeyDowns: 21, now: 6))
        for tick in 13...20 {
            XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 131, deliveredKeyDowns: 21, now: Double(tick) / 2))
        }
    }

    func testCallbackLagGetsGraceAndClearsSuspicion() {
        var monitor = KeyboardDeliveryMonitor()
        XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 100, deliveredKeyDowns: 10, now: 0))
        XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 101, deliveredKeyDowns: 10, now: 0.5))
        XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 101, deliveredKeyDowns: 11, now: 1))
        for tick in 3...10 {
            XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 101, deliveredKeyDowns: 11, now: Double(tick) / 2))
        }
    }

    func testMoreUndeliveredKeysDoNotPostponeFailure() {
        var monitor = KeyboardDeliveryMonitor()
        for tick in 0...4 {
            XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: UInt32(tick), deliveredKeyDowns: 0, now: Double(tick) / 2))
        }
        XCTAssertTrue(monitor.observe(active: true, systemKeyDowns: 5, deliveredKeyDowns: 0, now: 2.5))
    }

    func testSleepPauseAndNewAcquisitionForgetOldEvidence() {
        var monitor = KeyboardDeliveryMonitor()
        XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 100, deliveredKeyDowns: 10, now: 0))
        XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 101, deliveredKeyDowns: 10, now: 0.5))
        XCTAssertFalse(monitor.observe(active: false, systemKeyDowns: 102, deliveredKeyDowns: 10, now: 1))
        XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 1000, deliveredKeyDowns: 10, now: 100))
        for tick in 1...8 {
            XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 1000, deliveredKeyDowns: 10, now: 100 + Double(tick) / 2))
        }
        monitor.reset()
        XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 2000, deliveredKeyDowns: 10, now: 105))
    }

    func testCounterWrapAndClockResetInvalidateSuspicion() {
        var monitor = KeyboardDeliveryMonitor()
        XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: .max - 1, deliveredKeyDowns: 10, now: 0))
        XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: .max, deliveredKeyDowns: 10, now: 0.5))
        XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 1, deliveredKeyDowns: 10, now: 1))
        for tick in 3...8 {
            XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 1, deliveredKeyDowns: 10, now: Double(tick) / 2))
        }
        XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 2, deliveredKeyDowns: 10, now: 4.5))
        XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 2, deliveredKeyDowns: 10, now: 0))
        for tick in 1...8 {
            XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 2, deliveredKeyDowns: 10, now: Double(tick) / 2))
        }
    }

    func testDelayedMainLoopSampleRearmsBeforeQueuedCallbacksAreDelivered() {
        var monitor = KeyboardDeliveryMonitor()
        XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 100, deliveredKeyDowns: 10, now: 0))
        XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 101, deliveredKeyDowns: 10, now: 0.5))
        XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 102, deliveredKeyDowns: 10, now: 3))
        XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 102, deliveredKeyDowns: 12, now: 3.5))
        for tick in 8...14 {
            XCTAssertFalse(monitor.observe(active: true, systemKeyDowns: 102, deliveredKeyDowns: 12, now: Double(tick) / 2))
        }
    }

    func testOnlyKeyDownDeliveryCountsAndIncludesAutorepeat() throws {
        let keyboard = Keyboard()
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        _ = keyboard.handle(type: .flagsChanged, event: event)
        _ = keyboard.handle(type: .keyUp, event: event)
        XCTAssertEqual(keyboard.keyDownCount, 0)
        _ = keyboard.handle(type: .keyDown, event: event)
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        _ = keyboard.handle(type: .keyDown, event: event)
        XCTAssertEqual(keyboard.keyDownCount, 2)
    }
}
