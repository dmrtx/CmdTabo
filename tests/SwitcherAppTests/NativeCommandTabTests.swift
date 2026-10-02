import Darwin
import Foundation
import XCTest
@testable import CmdTabo

final class NativeCommandTabTests: XCTestCase {
    private var directory: URL!
    private var children: [Process] = []
    private var stateURL: URL { directory.appendingPathComponent("states") }
    private var lockURL: URL { directory.appendingPathComponent("ownership.lock") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("1 0".utf8).write(to: stateURL)
    }

    override func tearDownWithError() throws {
        for child in children where child.isRunning { child.terminate(); child.waitUntilExit() }
        try FileManager.default.removeItem(at: directory)
    }

    private func states() -> [Bool]? {
        guard let data = try? String(contentsOf: stateURL, encoding: .utf8) else { return nil }
        return data.split(separator: " ").map { $0 == "1" }
    }

    private func owner(failRestoration: Bool = false, delayedGuardian: Bool = false) -> NativeCommandTab {
        let stateURL = self.stateURL, directory = self.directory!
        return NativeCommandTab(lockURL: lockURL, readStates: { self.states() }, writeStates: { states in
            if failRestoration && states != [false, false] { return false }
            do {
                try Data(states.map { $0 ? "1" : "0" }.joined(separator: " ").utf8).write(to: stateURL, options: .atomic)
                return true
            } catch { return false }
        }, makeGuardian: { previous in
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sh")
            child.arguments = ["-c", """
                input=$(cat)
                if [ "$input" != cancel ]; then
                    if [ "$3" = delayed ]; then
                        touch "$4/waiting"
                        while [ ! -f "$4/release" ]; do sleep 0.01; done
                    fi
                    printf '%s' "$2" > "$1"
                fi
                """, "guardian", stateURL.path, previous.map { $0 ? "1" : "0" }.joined(separator: " "),
                delayedGuardian ? "delayed" : "immediate", directory.path]
            self.children.append(child)
            return child
        })
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testExclusiveOwnershipAndBothExitOrders() throws {
        for ownerExitsFirst in [false, true] {
            try Data("1 1".utf8).write(to: stateURL)
            let first = owner(), second = owner()
            XCTAssertTrue(first.takeOver())
            XCTAssertFalse(second.takeOver())
            XCTAssertFalse(second.isOverridden)
            XCTAssertEqual(states(), [false, false])
            if ownerExitsFirst { first.restore(); second.restore() }
            else { second.restore(); XCTAssertEqual(states(), [false, false]); first.restore() }
            waitUntil { self.children.allSatisfy { !$0.isRunning } }
            XCTAssertEqual(states(), [true, true])
            XCTAssertTrue(second.takeOver())
            second.restore()
            waitUntil { self.children.allSatisfy { !$0.isRunning } }
            XCTAssertEqual(states(), [true, true])
        }
    }

    func testGuardianKeepsLockUntilEOFFallbackRestores() throws {
        let first = owner(failRestoration: true, delayedGuardian: true), second = owner()
        XCTAssertTrue(first.takeOver())
        first.restore() // Failed parent restoration sends EOF, as a crash does.
        waitUntil { FileManager.default.fileExists(atPath: self.directory.appendingPathComponent("waiting").path) }
        XCTAssertFalse(second.takeOver())
        XCTAssertEqual(states(), [false, false])
        try Data().write(to: directory.appendingPathComponent("release"))
        waitUntil { self.children.allSatisfy { !$0.isRunning } }
        XCTAssertEqual(states(), [true, false])
        XCTAssertTrue(second.takeOver())
        second.restore()
    }

    func testGuardianUnexpectedExitRestoresAndReportsFailure() {
        let first = owner(), second = owner()
        var failed = false
        first.onGuardianFailure = { failed = true }
        XCTAssertTrue(first.takeOver())
        children[0].terminate()
        waitUntil { failed }
        XCTAssertFalse(first.isOverridden)
        XCTAssertEqual(states(), [true, false])
        XCTAssertTrue(second.takeOver())
        second.restore()
    }

    func testGuardianLaunchFailureReleasesLockWithoutChangingShortcuts() {
        let first = NativeCommandTab(lockURL: lockURL, readStates: { self.states() }, makeGuardian: { _ in
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/nonexistent-cmdtabo-test-guardian")
            return child
        })
        XCTAssertFalse(first.takeOver())
        XCTAssertEqual(states(), [true, false])
        let second = owner()
        XCTAssertTrue(second.takeOver())
        second.restore()
    }

    func testMissingStateReleasesLockWithoutLaunchingGuardian() {
        let first = NativeCommandTab(lockURL: lockURL, readStates: { nil }, makeGuardian: { _ in
            XCTFail("Must not launch without original states")
            return nil
        })
        XCTAssertFalse(first.takeOver())
        let second = owner()
        XCTAssertTrue(second.takeOver())
        second.restore()
    }

    func testLockSymlinkIsRejected() throws {
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: stateURL)
        XCTAssertFalse(owner().takeOver())
        XCTAssertEqual(states(), [true, false])
    }

    private func runCrashOwnerFixture(at fixture: String) throws {
        // Run only in a disposable subprocess with file-backed fake shortcuts.
        try FileManager.default.removeItem(at: directory)
        directory = URL(fileURLWithPath: fixture)
        let first = owner(delayedGuardian: true)
        guard first.takeOver() else { exit(1) }
        try Data().write(to: directory.appendingPathComponent("ready"))
        while true { Thread.sleep(forTimeInterval: 0.01) }
    }

    func testKilledOwnerLeavesGuardianExclusiveUntilRestoration() throws {
        if let fixture = ProcessInfo.processInfo.environment["CMDTABO_CRASH_FIXTURE"] {
            try runCrashOwnerFixture(at: fixture)
            return
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "SwitcherAppTests.NativeCommandTabTests/testKilledOwnerLeavesGuardianExclusiveUntilRestoration",
                           Bundle(for: NativeCommandTabTests.self).bundleURL.path]
        child.environment = ProcessInfo.processInfo.environment.merging(["CMDTABO_CRASH_FIXTURE": directory.path]) { _, new in new }
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        children.append(child)
        waitUntil { FileManager.default.fileExists(atPath: self.directory.appendingPathComponent("ready").path) }
        let second = owner()
        XCTAssertFalse(second.takeOver())
        XCTAssertEqual(states(), [false, false])
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
        waitUntil { FileManager.default.fileExists(atPath: self.directory.appendingPathComponent("waiting").path) }
        XCTAssertFalse(second.takeOver())
        try Data().write(to: directory.appendingPathComponent("release"))
        waitUntil { self.states() == [true, false] }
        waitUntil { second.takeOver() }
        second.restore()
    }
}
