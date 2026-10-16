import AppKit
import Sparkle
import XCTest
@testable import CmdTabo

final class UpdateControllerTests: XCTestCase {
    // SPUUserUpdateState exposes NSSecureCoding but no public stage initializer.
    // Supply its documented stage/userInitiated values through that interface.
    private final class UpdateStateDecoder: NSCoder {
        let stage: SPUUserUpdateStage
        init(stage: SPUUserUpdateStage) { self.stage = stage; super.init() }
        override var allowsKeyedCoding: Bool { true }
        override func decodeInteger(forKey key: String) -> Int { stage.rawValue }
        override func decodeBool(forKey key: String) -> Bool { true }
    }

    private func state(_ stage: SPUUserUpdateStage) throws -> SPUUserUpdateState {
        try XCTUnwrap(SPUUserUpdateState(coder: UpdateStateDecoder(stage: stage)))
    }

    private func item(_ version: String = "900", display: String = "9.0") throws -> SUAppcastItem {
        // The fixture needs only version metadata, not host/system-dependent
        // eligibility properties excluded by Sparkle's legacy initializer.
        try XCTUnwrap(SUAppcastItem(dictionary: ["enclosure": [
            "url": "https://example.invalid/CmdTabo.zip",
            "sparkle:version": version,
            "sparkle:shortVersionString": display
        ]]))
    }

    private func updater() -> SPUUpdater {
        SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil).updater
    }

    func testPreparedUpdateSurvivesRemindMeLaterAndSessionCompletion() throws {
        let updates = UpdateController(), menu = NSMenu(), updater = updater()
        updates.addMenuItems(to: menu)
        var available = false
        var immediateInstallInvoked = false
        updates.onUpdateReady = { available = $0 }
        let update = try item()
        XCTAssertFalse(updates.updater(updater, willInstallUpdateOnQuit: update,
                                       immediateInstallationBlock: { immediateInstallInvoked = true }))
        updates.updater(updater, userDidMake: .dismiss, forUpdate: update, state: try state(.installing))
        updates.standardUserDriverWillFinishUpdateSession()
        XCTAssertEqual(menu.items.first?.title, "Install Update 9.0…")
        XCTAssertTrue(available)
        XCTAssertFalse(immediateInstallInvoked)
    }

    func testDownloadedUpdateAwaitingAuthorizationSurvivesDismiss() throws {
        let updates = UpdateController(), menu = NSMenu(), updater = updater()
        updates.addMenuItems(to: menu)
        let update = try item()
        let downloaded = try state(.downloaded)
        updates.standardUserDriverWillHandleShowingUpdate(true, forUpdate: update, state: downloaded)
        updates.updater(updater, userDidMake: .dismiss, forUpdate: update, state: downloaded)
        updates.standardUserDriverWillFinishUpdateSession()
        XCTAssertEqual(menu.items.first?.title, "Install Update 9.0…")
    }

    func testSkippingPreparedUpdateRemovesReminder() throws {
        let updates = UpdateController(), menu = NSMenu(), updater = updater()
        updates.addMenuItems(to: menu)
        var available = true
        updates.onUpdateReady = { available = $0 }
        let update = try item()
        _ = updates.updater(updater, willInstallUpdateOnQuit: update, immediateInstallationBlock: {})
        updates.updater(updater, userDidMake: .skip, forUpdate: update, state: try state(.installing))
        updates.standardUserDriverWillFinishUpdateSession()
        XCTAssertEqual(menu.items.first?.title, "Check for Updates…")
        XCTAssertFalse(available)
    }

    func testCanceledInstallationClearsPreparedReminder() throws {
        let updates = UpdateController(), menu = NSMenu(), updater = updater()
        updates.addMenuItems(to: menu)
        var available = true
        updates.onUpdateReady = { available = $0 }
        _ = updates.updater(updater, willInstallUpdateOnQuit: try item(), immediateInstallationBlock: {})
        // SUInstallationCanceledError in Sparkle's public error enumeration.
        updates.updater(updater, didAbortWithError: NSError(domain: SUSparkleErrorDomain, code: 4007))
        updates.standardUserDriverWillFinishUpdateSession()
        XCTAssertEqual(menu.items.first?.title, "Check for Updates…")
        XCTAssertFalse(available)
    }

    func testOlderCallbacksCannotReplaceOrClearNewerPreparedUpdate() throws {
        let updates = UpdateController(), menu = NSMenu(), updater = updater()
        updates.addMenuItems(to: menu)
        let newer = try item("901", display: "9.1"), older = try item()
        _ = updates.updater(updater, willInstallUpdateOnQuit: newer, immediateInstallationBlock: {})
        updates.standardUserDriverWillHandleShowingUpdate(false, forUpdate: older, state: try state(.notDownloaded))
        updates.updater(updater, userDidMake: .skip, forUpdate: older, state: try state(.downloaded))
        updates.standardUserDriverWillHandleShowingUpdate(false, forUpdate: newer, state: try state(.notDownloaded))
        updates.standardUserDriverWillFinishUpdateSession()
        XCTAssertEqual(menu.items.first?.title, "Install Update 9.1…")
    }

    func testDismissingAnUndownloadedUpdateClearsReminderAtSessionEnd() throws {
        let updates = UpdateController(), menu = NSMenu(), updater = updater()
        updates.addMenuItems(to: menu)
        let update = try item(), notDownloaded = try state(.notDownloaded)
        updates.standardUserDriverWillHandleShowingUpdate(false, forUpdate: update, state: notDownloaded)
        updates.updater(updater, userDidMake: .dismiss, forUpdate: update, state: notDownloaded)
        updates.standardUserDriverWillFinishUpdateSession()
        XCTAssertEqual(menu.items.first?.title, "Check for Updates…")
    }
}
