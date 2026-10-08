import AppKit
import XCTest
import SwitcherCore
@testable import CmdTabo

final class WindowMetadataTests: XCTestCase {
    private let displays = [Display(id: 1, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                            Display(id: 2, bounds: CGRect(x: -1440, y: 0, width: 1440, height: 900))]
    private let userTags: UInt64 = 0x0300000100480001
    private let minimizedTags: UInt64 = 0x1300000100480001
    private let hiddenTags: UInt64 = 0x0000008100480001
    private let closedTags: UInt64 = 0x0000000100480001
    private let helperTags: UInt64 = 0x0000000100080001

    private func record(_ id: UInt32 = 1, layer: NSWindow.Level = .normal, onScreen: Bool = true,
                        alpha: Double? = 1, bounds: CGRect = CGRect(x: 100, y: 100, width: 500, height: 500)) -> [String: Any] {
        var item: [String: Any] = [kCGWindowNumber as String: NSNumber(value: id),
                                  kCGWindowOwnerPID as String: NSNumber(value: Int32(123)),
                                  kCGWindowLayer as String: NSNumber(value: layer.rawValue),
                                  kCGWindowBounds as String: bounds.dictionaryRepresentation,
                                  kCGWindowIsOnscreen as String: NSNumber(value: onScreen)]
        if let alpha { item[kCGWindowAlpha as String] = NSNumber(value: alpha) }
        return item
    }

    private func reason(_ windows: [WindowState], target: UInt32? = nil, hidden: Bool = false,
                        options: FilterOptions = FilterOptions()) -> Exclusion? {
        WindowFilter.exclusion(windows: windows, displays: displays, target: target, isHidden: hidden, options: options)
    }

    func testVisibleFloatingAndModalWindowsKeepAppsAvailable() {
        for layer: NSWindow.Level in [.floating, .modalPanel] {
            var extractor = WindowMetadataExtractor()
            let windows = extractor.snapshot(from: [record(layer: layer)], tagsProvider: { _ in [1: self.userTags] })
            XCTAssertEqual(windows.map(\.id), [1])
            XCTAssertNil(reason(windows))
        }
    }

    func testFloatingUnknownMetadataFailsOpenWithoutWindowTitles() {
        for tags: UInt64? in [nil, 0, 1] {
            var extractor = WindowMetadataExtractor()
            let windows = extractor.snapshot(from: [record(layer: .floating, alpha: nil)],
                                             tagsProvider: { _ in tags.map { [1: $0] } ?? [:] })
            XCTAssertEqual(windows.count, 1)
            XCTAssertEqual(windows.first?.tags, tags)
            XCTAssertNil(reason(windows))
        }
    }

    func testTransientLayersAndInvisibleHelpersDoNotRescueWindowlessApps() {
        for layer: NSWindow.Level in [.mainMenu, .popUpMenu, .statusBar, .screenSaver,
                                     NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow))),
                                     NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.helpWindow)))] {
            var extractor = WindowMetadataExtractor()
            let windows = extractor.snapshot(from: [record(layer: layer)], tagsProvider: { _ in [1: self.userTags] })
            XCTAssertTrue(windows.isEmpty)
            XCTAssertEqual(reason(windows), .windowless)
        }
        var extractor = WindowMetadataExtractor()
        // Torn-off menus share the floating level; known helper tags must
        // distinguish them from content windows instead of excluding the level.
        let helper = extractor.snapshot(from: [record(layer: .tornOffMenu)], tagsProvider: { _ in [1: self.helperTags] })
        XCTAssertEqual(reason(helper), .windowless)
        let tiny = extractor.snapshot(from: [record(layer: .floating, bounds: CGRect(x: 0, y: 0, width: 20, height: 20))],
                                      tagsProvider: { _ in [1: self.userTags] })
        XCTAssertEqual(reason(tiny), .windowless)
    }

    func testTransparentOnscreenWindowsDoNotKeepAppsAvailable() {
        for layer: NSWindow.Level in [.normal, .floating, .modalPanel] {
            var extractor = WindowMetadataExtractor()
            let windows = extractor.snapshot(from: [record(layer: layer, alpha: 0)], tagsProvider: { _ in [1: self.userTags] })
            XCTAssertEqual(reason(windows), .windowless)
        }
    }

    func testFloatingMinimizedAndHiddenWindowsRespectIndependentFilters() {
        var extractor = WindowMetadataExtractor()
        let minimized = extractor.snapshot(from: [record(layer: .floating, onScreen: false, alpha: 0)],
                                           tagsProvider: { _ in [1: self.minimizedTags] })
        XCTAssertEqual(reason(minimized), .minimized)
        XCTAssertNil(reason(minimized, options: FilterOptions(excludeMinimized: false)))
        let hidden = extractor.snapshot(from: [record(layer: .floating, onScreen: false, alpha: 0)],
                                        tagsProvider: { _ in [1: self.hiddenTags] })
        XCTAssertEqual(reason(hidden, hidden: true), .hidden)
        XCTAssertNil(reason(hidden, hidden: true, options: FilterOptions(excludeHidden: false)))
    }

    func testFloatingWindowsOnOtherSpacesAndDisplaysRemainContentWindows() {
        var extractor = WindowMetadataExtractor()
        let bounds = CGRect(x: -1000, y: 100, width: 500, height: 500)
        let windows = extractor.snapshot(from: [record(layer: .floating, onScreen: false, bounds: bounds)],
                                         tagsProvider: { _ in [1: self.userTags] })
        XCTAssertNil(reason(windows))
        XCTAssertEqual(reason(windows, target: 1), .otherDisplay)
        XCTAssertNil(reason(windows, target: 2))
    }

    func testFloatingHistoryKeepsHiddenWindowsButDoesNotRescueClosedWindows() {
        var extractor = WindowMetadataExtractor()
        let visible = extractor.snapshot(from: [record(layer: .floating)], tagsProvider: { _ in [1: self.userTags] })
        XCTAssertNil(reason(visible))
        let hidden = extractor.snapshot(from: [record(layer: .floating, onScreen: false)],
                                        tagsProvider: { _ in [1: self.hiddenTags] })
        XCTAssertNil(reason(hidden, options: FilterOptions(excludeHidden: false)))
        let closed = extractor.snapshot(from: [record(layer: .floating, onScreen: false)],
                                        tagsProvider: { _ in [1: self.closedTags] })
        XCTAssertEqual(reason(closed), .windowless)
        XCTAssertNil(reason(closed, options: FilterOptions(excludeWindowless: false)))
        let gone = extractor.snapshot(from: [], tagsProvider: { _ in [:] })
        XCTAssertEqual(reason(gone), .windowless)
        let reused = extractor.snapshot(from: [record(layer: .floating, onScreen: false)],
                                        tagsProvider: { _ in [1: self.hiddenTags] })
        XCTAssertEqual(reason(reused), .windowless)
    }

    func testFloatingHelperDoesNotRescueMinimizedNormalWindow() {
        var extractor = WindowMetadataExtractor()
        let windows = extractor.snapshot(from: [record(onScreen: false), record(2, layer: .floating)],
                                         tagsProvider: { _ in [1: self.minimizedTags, 2: self.helperTags] })
        XCTAssertEqual(reason(windows), .minimized)
    }
}
