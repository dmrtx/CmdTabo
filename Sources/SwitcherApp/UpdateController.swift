import AppKit
import Sparkle

/// Sparkle owns scheduling, persistence, signature validation and installation.
/// Scheduled checks only update the menu; update windows require user action.
final class UpdateController: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate, NSMenuItemValidation {
    private struct AvailableUpdate {
        let item: SUAppcastItem
        let downloaded: Bool
    }
    var onWillRelaunch: (() -> Void)?
    var onUpdateReady: ((Bool) -> Void)?
    private var controller: SPUStandardUpdaterController!
    private var checkItems: [NSMenuItem] = []
    private var started = false
    private var availableUpdate: AvailableUpdate?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }

    func start() {
        do {
            try controller.updater.start()
            started = true
        } catch {
            // Command-line/development executables do not contain updater metadata.
            DiagnosticLog.shared.record("updater unavailable code=\((error as NSError).code)")
            for item in checkItems { item.toolTip = "Updates are available in packaged releases." }
        }
    }

    func addMenuItems(to menu: NSMenu) {
        let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        checkItems.append(check)
        menu.addItem(check)
        let automatic = NSMenuItem(title: "Check automatically every 6 hours", action: #selector(toggleAutomaticChecks), keyEquivalent: "")
        automatic.target = self
        menu.addItem(automatic)
        let downloads = NSMenuItem(title: "Download updates · install on quit", action: #selector(toggleAutomaticDownloads), keyEquivalent: "")
        downloads.target = self
        menu.addItem(downloads)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(checkForUpdates): return started && controller.updater.canCheckForUpdates
        case #selector(toggleAutomaticChecks):
            menuItem.state = controller.updater.automaticallyChecksForUpdates ? .on : .off
            return started
        case #selector(toggleAutomaticDownloads):
            menuItem.state = controller.updater.automaticallyDownloadsUpdates ? .on : .off
            return started && controller.updater.allowsAutomaticUpdates
        default: return false
        }
    }

    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
    @objc private func toggleAutomaticChecks() {
        controller.updater.automaticallyChecksForUpdates.toggle()
    }
    @objc private func toggleAutomaticDownloads() {
        controller.updater.automaticallyDownloadsUpdates.toggle()
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                             andInImmediateFocus immediateFocus: Bool) -> Bool { false }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                  state: SPUUserUpdateState) {
        showAvailableUpdate(update, downloaded: state.stage != .notDownloaded)
    }
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        showAvailableUpdate(item, downloaded: true)
        return false
    }
    private func showAvailableUpdate(_ item: SUAppcastItem, downloaded: Bool) {
        var downloaded = downloaded
        if let current = availableUpdate {
            let order = SUStandardVersionComparator().compareVersion(item.versionString, toVersion: current.item.versionString)
            guard order != .orderedAscending else { return }
            if order == .orderedSame { downloaded = downloaded || current.downloaded }
        }
        availableUpdate = AvailableUpdate(item: item, downloaded: downloaded)
        renderAvailableUpdate()
    }
    private func renderAvailableUpdate() {
        let title: String
        if let update = availableUpdate {
            title = update.downloaded ? "Install Update \(update.item.displayVersionString)…" : "Update to \(update.item.displayVersionString)…"
        } else {
            title = "Check for Updates…"
        }
        for menuItem in checkItems { menuItem.title = title }
        onUpdateReady?(availableUpdate != nil)
    }
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem,
                 state: SPUUserUpdateState) {
        guard let current = availableUpdate, current.item.versionString == updateItem.versionString else { return }
        if choice == .skip {
            availableUpdate = nil
            renderAvailableUpdate()
        } else if choice == .dismiss && state.stage != .notDownloaded {
            // Remind Me Later closes the alert, but the download or installer
            // remains resumable. A later session can still install this update.
            showAvailableUpdate(updateItem, downloaded: true)
        }
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Sparkle does not deliver this for a normal staged install-on-quit or
        // deferred authorization. Actual cancellation/errors invalidate our UI.
        availableUpdate = nil
        renderAvailableUpdate()
    }
    func standardUserDriverWillFinishUpdateSession() {
        // Ending the UI session is not proof the staged update was discarded.
        // In particular, dismissing an .installing update keeps install-on-quit.
        if availableUpdate?.downloaded != true { availableUpdate = nil }
        renderAvailableUpdate()
    }
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { onWillRelaunch?() }
}
