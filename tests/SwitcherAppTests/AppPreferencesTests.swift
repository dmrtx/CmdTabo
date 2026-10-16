import AppKit
import XCTest
import SwitcherCore
@testable import CmdTabo

final class AppPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() {
        suite = "local.cmdtabo.preferences-test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }
    private func app(_ id: String? = "example.editor", path: String = "/Applications/Example.app", name: String = "Example") -> ExcludedApplication {
        ExcludedApplication(bundleIdentifier: id, url: URL(fileURLWithPath: path), name: name)
    }
    func testMinimizedModeMigratesBothLegacySettingsAndPreservesOtherFilters() {
        let prefs = AppPreferences(defaults: defaults)
        XCTAssertEqual(prefs.minimizedAppsMode, .hide)
        defaults.set(false, forKey: "excludeMinimized")
        XCTAssertEqual(prefs.minimizedAppsMode, .recentOrder)
        defaults.set(false, forKey: "excludeHidden")
        prefs.minimizedAppsMode = .atEnd
        XCTAssertFalse(prefs.filterOptions.excludeMinimized)
        XCTAssertFalse(prefs.filterOptions.excludeHidden)
        XCTAssertTrue(prefs.filterOptions.excludeWindowless)
        XCTAssertEqual(AppPreferences(defaults: defaults).minimizedAppsMode, .atEnd)
        XCTAssertFalse(defaults.bool(forKey: "excludeMinimized"))
        prefs.minimizedAppsMode = .hide
        XCTAssertTrue(prefs.filterOptions.excludeMinimized)
        XCTAssertTrue(defaults.bool(forKey: "excludeMinimized"))
    }
    func testInvalidModeFallsBackToLegacyPreference() {
        defaults.set("future-mode", forKey: "minimizedAppsMode")
        defaults.set(false, forKey: "excludeMinimized")
        XCTAssertEqual(AppPreferences(defaults: defaults).minimizedAppsMode, .recentOrder)
    }
    func testExclusionFollowsBundleIdentityAcrossMovesAndUpdates() {
        let exclusion = app()
        XCTAssertTrue(exclusion.matches(bundleIdentifier: "example.editor", bundleURL: URL(fileURLWithPath: "/Applications/Updated.app")))
        XCTAssertTrue(exclusion.matches(bundleIdentifier: "example.editor", bundleURL: nil))
        XCTAssertFalse(exclusion.matches(bundleIdentifier: "example.other", bundleURL: URL(fileURLWithPath: exclusion.path)))
    }
    func testAppsWithoutIdentifiersUseCanonicalPathWithoutMatchingEverything() {
        let exclusion = app(nil)
        XCTAssertTrue(exclusion.matches(bundleIdentifier: nil, bundleURL: URL(fileURLWithPath: "/Applications/Folder/../Example.app")))
        XCTAssertFalse(exclusion.matches(bundleIdentifier: nil, bundleURL: URL(fileURLWithPath: "/Applications/Other.app")))
        XCTAssertFalse(exclusion.matches(bundleIdentifier: nil, bundleURL: nil))
    }
    func testSavedExclusionsSurviveReloadDeduplicateAndCanBeRemoved() {
        let prefs = AppPreferences(defaults: defaults)
        prefs.addExcludedApplications([app(), app("example.browser", name: "Browser")])
        prefs.addExcludedApplications([app(path: "/Applications/NewExample.app", name: "Updated Example")])
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.excludedApplications.count, 2)
        XCTAssertEqual(reloaded.excludedApplications.first?.name, "Browser")
        XCTAssertEqual(reloaded.excludedApplications.last?.path, "/Applications/NewExample.app")
        reloaded.removeExcludedApplications(keys: [app().key])
        XCTAssertEqual(prefs.excludedApplications.map(\.bundleIdentifier), ["example.browser"])
        reloaded.removeExcludedApplications(keys: [app("example.browser").key])
        XCTAssertTrue(prefs.excludedApplications.isEmpty)
    }
    func testMalformedExclusionsFailOpenWithoutChangingOtherPreferences() {
        defaults.set(Data("invalid".utf8), forKey: "excludedApplications")
        let prefs = AppPreferences(defaults: defaults)
        XCTAssertTrue(prefs.excludedApplications.isEmpty)
        XCTAssertTrue(prefs.filterOptions.excludeMinimized)
    }
    func testAddingAnIdentifierToAPathExclusionDoesNotLeaveADuplicate() {
        let prefs = AppPreferences(defaults: defaults)
        prefs.addExcludedApplications([app(nil)])
        prefs.addExcludedApplications([app()])
        XCTAssertEqual(prefs.excludedApplications.count, 1)
        XCTAssertEqual(prefs.excludedApplications.first?.bundleIdentifier, "example.editor")
        prefs.addExcludedApplications([app(nil, name: "Renamed Example")])
        XCTAssertEqual(prefs.excludedApplications.count, 1)
        XCTAssertEqual(prefs.excludedApplications.first?.bundleIdentifier, "example.editor")
        prefs.removeExcludedApplications(keys: [app().key])
        XCTAssertTrue(prefs.excludedApplications.isEmpty)
    }
    func testPickerMetadataRejectsNonAppBundles() {
        XCTAssertNil(ExcludedApplication(url: URL(fileURLWithPath: "/Applications/Example.txt")))
    }
}

final class MinimizedTileTests: XCTestCase {
    func testReusedTileUpdatesMinimizedIndicatorWhenWindowIsRestored() {
        _ = NSApplication.shared
        let window = SwitcherCore.WindowState(id: 1, pid: NSRunningApplication.current.processIdentifier,
                                              bounds: CGRect(x: 20, y: 20, width: 300, height: 200),
                                              onScreen: false, tags: 0x1300000100480001)
        let minimized = AppEntry(app: .current, windows: [window], isHidden: false)
        let tile = AppTile(entry: minimized, frame: NSRect(x: 0, y: 0, width: 80, height: 80))
        XCTAssertEqual(tile.accessibilityLabel(), minimized.name + ", minimized")
        var restored = window
        restored.onScreen = true
        tile.update(entry: AppEntry(app: .current, windows: [restored], isHidden: false))
        XCTAssertEqual(tile.accessibilityLabel(), minimized.name)
        XCTAssertEqual(tile.toolTip, minimized.name)
    }
}

final class SettingsLayoutTests: XCTestCase {
    func testSettingsFooterCanScrollIntoViewInAShortWindow() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        delegate.createSettings()
        let window = try XCTUnwrap(delegate.settings)
        defer { window.close() }
        window.setContentSize(NSSize(width: 520, height: 420))
        window.contentView?.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(window.contentView?.subviews.first as? NSScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        func findPreview(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == "Preview switcher" { return button }
            return view.subviews.lazy.compactMap { findPreview(in: $0) }.first
        }
        let preview = try XCTUnwrap(findPreview(in: document))
        XCTAssertTrue(document.visibleRect.intersects(preview.convert(preview.bounds, to: document)))
    }
}
