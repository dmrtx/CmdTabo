import Foundation
import XCTest
@testable import CmdTabo

final class CaptureLifecycleTests: XCTestCase {
    func testSecureInputReleasesOnceAndWaitsBeforeCapturingAgain() {
        var lifecycle = CaptureLifecycle()
        var releases = 0
        lifecycle.onRelease = { releases += 1 }
        XCTAssertTrue(lifecycle.permitsCapture(now: 100))
        XCTAssertTrue(lifecycle.updateSecureInput(true, now: 100))
        XCTAssertFalse(lifecycle.permitsCapture(now: 101))
        XCTAssertFalse(lifecycle.updateSecureInput(true, now: 101))
        XCTAssertEqual(releases, 1)
        XCTAssertTrue(lifecycle.updateSecureInput(false, now: 102))
        XCTAssertFalse(lifecycle.permitsCapture(now: 103.9))
        XCTAssertFalse(lifecycle.updateSecureInput(false, now: 104))
        XCTAssertTrue(lifecycle.permitsCapture(now: 104))
    }
    func testSecureInputEndingCannotBypassSleepSessionOrFailure() {
        var lifecycle = CaptureLifecycle()
        lifecycle.suspend(.systemSleep)
        lifecycle.suspend(.inactiveSession)
        lifecycle.updateSecureInput(true, now: 100)
        lifecycle.fail()
        lifecycle.updateSecureInput(false, now: 101)
        XCTAssertFalse(lifecycle.permitsCapture(now: 200))
        lifecycle.retry()
        XCTAssertFalse(lifecycle.permitsCapture(now: 200))
        lifecycle.resume(.systemSleep, now: 200)
        XCTAssertFalse(lifecycle.permitsCapture(now: 210))
        lifecycle.resume(.inactiveSession, now: 211)
        XCTAssertTrue(lifecycle.permitsCapture(now: 213))
    }
    func testWakeAndRetryCannotBypassSecureInput() {
        var lifecycle = CaptureLifecycle()
        lifecycle.updateSecureInput(true, now: 100)
        lifecycle.suspend(.displaySleep)
        lifecycle.fail()
        lifecycle.resume(.displaySleep, now: 101)
        lifecycle.retry()
        XCTAssertFalse(lifecycle.permitsCapture(now: 200))
        lifecycle.updateSecureInput(false, now: 201)
        XCTAssertTrue(lifecycle.permitsCapture(now: 203))
    }
    func testWakeCannotCaptureWhileDisplayOrSessionIsStillAsleep() {
        var lifecycle = CaptureLifecycle()
        var releases = 0
        lifecycle.onRelease = { releases += 1 }
        lifecycle.suspend(.systemSleep)
        lifecycle.suspend(.displaySleep)
        lifecycle.suspend(.inactiveSession)
        XCTAssertEqual(releases, 3)
        lifecycle.resume(.systemSleep, now: 100)
        XCTAssertFalse(lifecycle.permitsCapture(now: 110))
        lifecycle.resume(.displaySleep, now: 111)
        XCTAssertFalse(lifecycle.permitsCapture(now: 120))
        lifecycle.resume(.inactiveSession, now: 121)
        XCTAssertFalse(lifecycle.permitsCapture(now: 122.9))
        XCTAssertTrue(lifecycle.permitsCapture(now: 123))
    }
    func testFailureStaysPausedAcrossWakeAndOnlyExplicitRetryClearsIt() {
        var lifecycle = CaptureLifecycle()
        lifecycle.fail()
        lifecycle.suspend(.systemSleep)
        lifecycle.resume(.systemSleep, now: 100)
        XCTAssertFalse(lifecycle.permitsCapture(now: 200))
        lifecycle.retry()
        XCTAssertTrue(lifecycle.permitsCapture(now: 200))
        lifecycle.suspend(.inactiveSession)
        lifecycle.retry()
        XCTAssertFalse(lifecycle.permitsCapture(now: 300))
    }
}

final class GuardianLeaseTests: XCTestCase {
    func testHeartbeatExtendsLeaseAndCancellationCanBeSplit() {
        var lease = GuardianLease(now: 0, timeout: 15)
        XCTAssertFalse(lease.expired(now: 14.9))
        XCTAssertFalse(lease.receive(Data("...can".utf8), now: 14))
        XCTAssertFalse(lease.expired(now: 28.9))
        XCTAssertTrue(lease.receive(Data("cel".utf8), now: 29))
    }
    func testLeaseExpiresWithoutHeartbeat() {
        let lease = GuardianLease(now: 100, timeout: 15)
        XCTAssertFalse(lease.expired(now: 114))
        XCTAssertTrue(lease.expired(now: 115))
    }
    func testMonitorRestoresOnTimeoutWhileParentPipeRemainsOpen() {
        let pipe = Pipe()
        let restored = expectation(description: "watchdog restoration")
        DispatchQueue.global().async {
            NativeCommandTab.monitorGuardian(input: pipe.fileHandleForReading.fileDescriptor,
                                             parent: -1, timeout: 0.3) { restored.fulfill() }
        }
        wait(for: [restored], timeout: 3)
        pipe.fileHandleForReading.closeFile()
        pipe.fileHandleForWriting.closeFile()
    }
    func testMonitorCancellationDoesNotRestoreAgain() throws {
        let pipe = Pipe()
        let finished = expectation(description: "watchdog cancellation")
        DispatchQueue.global().async {
            NativeCommandTab.monitorGuardian(input: pipe.fileHandleForReading.fileDescriptor,
                                             parent: -1, timeout: 2) { XCTFail("Must not restore after normal cancellation") }
            finished.fulfill()
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("...cancel".utf8))
        wait(for: [finished], timeout: 3)
        pipe.fileHandleForReading.closeFile()
        pipe.fileHandleForWriting.closeFile()
    }
}

final class DiagnosticLogTests: XCTestCase {
    func testLocalLogRotatesAndRetainsPrivateFilePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory, limit: 1)
        log.record("started version=fixture")
        log.flush()
        log.record("capture disabled: timeout")
        log.flush()
        let current = directory.appendingPathComponent("health.log")
        let previous = directory.appendingPathComponent("health.previous.log")
        XCTAssertTrue(try String(contentsOf: current).contains("capture disabled: timeout"))
        XCTAssertTrue(try String(contentsOf: previous).contains("started version=fixture"))
        let permissions = try FileManager.default.attributesOfItem(atPath: current.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
}

final class CatalogRecoveryTests: XCTestCase {
    func testSleepDiscardsInflightSnapshotAndWakeWaitsForFreshQuery() {
        let started = expectation(description: "old query started")
        let fresh = expectation(description: "fresh query committed")
        let release = DispatchSemaphore(value: 0)
        let freshRelease = DispatchSemaphore(value: 0)
        var calls = 0
        let catalog = AppCatalog(snapshotProvider: {
            calls += 1
            if calls == 1 { started.fulfill(); release.wait() }
            else { freshRelease.wait() }
            return []
        })
        catalog.onChange = { fresh.fulfill() }
        catalog.refresh()
        wait(for: [started], timeout: 2)
        catalog.suspend()
        catalog.resume()
        XCTAssertFalse(catalog.ready)
        XCTAssertTrue(catalog.queryInProgress)
        release.signal()
        let drained = expectation(description: "stale query discarded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertFalse(catalog.ready)
        freshRelease.signal()
        wait(for: [fresh], timeout: 2)
        XCTAssertTrue(catalog.ready)
        XCTAssertEqual(calls, 2)
    }
    func testStalledQueryReportsFailureWithoutStartingParallelQueries() {
        let stalled = expectation(description: "stalled query reported")
        let returned = expectation(description: "query returned")
        let release = DispatchSemaphore(value: 0)
        var calls = 0
        let catalog = AppCatalog(snapshotProvider: { calls += 1; release.wait(); return [] }, stallTimeout: 0.1)
        catalog.onStall = { stalled.fulfill() }
        catalog.onChange = { returned.fulfill() }
        catalog.refresh()
        catalog.refresh()
        wait(for: [stalled], timeout: 2)
        XCTAssertFalse(catalog.ready)
        XCTAssertTrue(catalog.queryInProgress)
        release.signal()
        wait(for: [returned], timeout: 2)
        XCTAssertEqual(calls, 1)
    }
}

extension CatalogRecoveryTests {
    func testWakeStillDetectsQueryThatWasBlockedBeforeSleep() {
        let started = expectation(description: "pre-sleep query")
        let stalled = expectation(description: "wake query timeout")
        let returned = expectation(description: "fresh query after unblock")
        let release = DispatchSemaphore(value: 0)
        var calls = 0
        let catalog = AppCatalog(snapshotProvider: {
            calls += 1
            if calls == 1 { started.fulfill(); release.wait() }
            return []
        }, stallTimeout: 0.1)
        catalog.onStall = { stalled.fulfill() }
        catalog.onChange = { returned.fulfill() }
        catalog.refresh()
        wait(for: [started], timeout: 2)
        catalog.suspend()
        catalog.resume()
        wait(for: [stalled], timeout: 2)
        XCTAssertFalse(catalog.ready)
        release.signal()
        wait(for: [returned], timeout: 2)
        XCTAssertEqual(calls, 2)
    }
}
