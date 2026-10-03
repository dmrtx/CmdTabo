import XCTest
@testable import CmdTabo

final class AccessibilityMonitorTests: XCTestCase {
    private func drain() {
        let done = expectation(description: "permission callback")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }
    func testNewGrantIsDetectedWithoutRestartWhenLocalCheckUpdates() {
        var trust = false
        var changes: [Bool] = []
        let monitor = AccessibilityMonitor(readTrust: { trust }, probe: { $0(false) })
        monitor.onChange = { changes.append($0) }
        monitor.refresh(now: 0)
        drain()
        trust = true
        monitor.refresh(now: 1)
        XCTAssertTrue(monitor.trusted)
        XCTAssertEqual(changes, [true])
        trust = false
        monitor.refresh(now: 2)
        XCTAssertFalse(monitor.trusted)
        XCTAssertEqual(changes, [true, false])
    }
    func testFreshGrantTriggersExactlyOneRelaunchForStaleParent() {
        var relaunches = 0, probes = 0
        let monitor = AccessibilityMonitor(readTrust: { false }, probe: { completion in probes += 1; completion(true) })
        monitor.onStaleGrant = { relaunches += 1 }
        monitor.refresh(now: 0)
        drain()
        monitor.refresh(now: 10)
        drain()
        XCTAssertEqual(relaunches, 1)
        XCTAssertEqual(probes, 1)
    }
    func testUntrustedFreshProcessNeverTriggersRelaunchAndProbesAreThrottled() {
        var probes = 0
        let monitor = AccessibilityMonitor(readTrust: { false }, probe: { completion in probes += 1; completion(false) })
        monitor.onStaleGrant = { XCTFail("Missing permission must not restart") }
        monitor.refresh(now: 0)
        drain()
        monitor.refresh(now: 1)
        XCTAssertEqual(probes, 1)
        monitor.refresh(now: 3)
        drain()
        XCTAssertEqual(probes, 2)
    }
    func testRelaunchedProcessCannotEnterRestartLoop() {
        let monitor = AccessibilityMonitor(alreadyRelaunched: true, readTrust: { false }, probe: { _ in XCTFail("No more probes after relaunch") })
        monitor.onStaleGrant = { XCTFail("No repeated relaunch") }
        monitor.refresh(now: 0)
        XCTAssertFalse(monitor.trusted)
    }
    func testGrantWhileProbeIsInflightDoesNotRelaunch() {
        var trust = false
        var completion: ((Bool?) -> Void)?
        let monitor = AccessibilityMonitor(readTrust: { trust }, probe: { completion = $0 })
        monitor.onStaleGrant = { XCTFail("Parent already sees permission") }
        monitor.refresh(now: 0)
        monitor.refresh(now: 10)
        trust = true
        completion?(true)
        drain()
        XCTAssertTrue(monitor.trusted)
    }
    func testFailedProbeDoesNotInferPermissionOrRestart() {
        let monitor = AccessibilityMonitor(readTrust: { false }, probe: { $0(nil) })
        monitor.onStaleGrant = { XCTFail("Probe error is not an approval") }
        monitor.refresh(now: 0)
        drain()
        XCTAssertFalse(monitor.trusted)
    }
}
