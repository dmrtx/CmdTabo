import XCTest
@testable import SwitcherCore

final class FilteringTests: XCTestCase {
    let screens = [Display(id: 1, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                   Display(id: 2, bounds: CGRect(x: -1440, y: -200, width: 1440, height: 900))]
    func window(_ id: UInt32 = 1, x: CGFloat = 100, onScreen: Bool = false, tags: UInt64? = 0x0300000100480001) -> WindowState {
        WindowState(id: id, pid: 123, bounds: CGRect(x: x, y: 0, width: 500, height: 500), onScreen: onScreen, tags: tags)
    }
    func testAllMinimizedExcludesApp() {
        let windows = [window(tags: 0x1300000100480001), window(2, tags: 0x1300000100480001)]
        XCTAssertEqual(WindowFilter.exclusion(windows: windows, displays: screens, target: nil), .minimized)
    }
    func testMinimizedFilterCanBeDisabled() {
        XCTAssertNil(WindowFilter.exclusion(windows: [window(tags: 0x1300000100480001)], displays: screens,
                                            target: nil, options: FilterOptions(excludeMinimized: false)))
    }
    func testHiddenFilterIncludesWindowlessApps() {
        XCTAssertEqual(WindowFilter.exclusion(windows: [], displays: screens, target: nil, isHidden: true), .hidden)
    }
    func testHiddenFilterCanBeDisabledWithoutDisablingMinimizedFilter() {
        let options = FilterOptions(excludeHidden: false)
        XCTAssertNil(WindowFilter.exclusion(windows: [window()], displays: screens, target: nil, isHidden: true, options: options))
        XCTAssertEqual(WindowFilter.exclusion(windows: [window(tags: 0x1300000100480001)], displays: screens,
                                              target: nil, isHidden: true, options: options), .minimized)
    }
    func testMinimizedFilterCanBeDisabledWithoutDisablingHiddenFilter() {
        XCTAssertEqual(WindowFilter.exclusion(windows: [window(tags: 0x1300000100480001)], displays: screens,
                                              target: nil, isHidden: true,
                                              options: FilterOptions(excludeMinimized: false)), .hidden)
    }
    func testAllFilterCombinationsAreIndependent() {
        for excludeMinimized in [false, true] {
            for excludeHidden in [false, true] {
                for excludeWindowless in [false, true] {
                    let options = FilterOptions(excludeMinimized: excludeMinimized, excludeHidden: excludeHidden,
                                                excludeWindowless: excludeWindowless)
                    let minimized = [window(tags: 0x1300000100480001)]
                    XCTAssertEqual(WindowFilter.exclusion(windows: minimized, displays: screens, target: nil, options: options),
                                   excludeMinimized ? .minimized : nil)
                    XCTAssertEqual(WindowFilter.exclusion(windows: [window()], displays: screens, target: nil,
                                                          isHidden: true, options: options), excludeHidden ? .hidden : nil)
                    XCTAssertEqual(WindowFilter.exclusion(windows: [], displays: screens, target: nil, options: options),
                                   excludeWindowless ? .windowless : nil)
                }
            }
        }
    }
    func testDisabledMinimizedFilterUsesMinimizedWindowsMonitor() {
        let options = FilterOptions(excludeMinimized: false)
        XCTAssertNil(WindowFilter.exclusion(windows: [window(tags: 0x1300000100480001), window(2, x: -1000)],
                                            displays: screens, target: 1, options: options))
        XCTAssertEqual(WindowFilter.exclusion(windows: [window(x: -1000, tags: 0x1300000100480001)],
                                              displays: screens, target: 1, options: options), .otherDisplay)
    }
    func testUnhiddenAppReturnsImmediately() {
        XCTAssertEqual(WindowFilter.exclusion(windows: [window()], displays: screens, target: nil, isHidden: true), .hidden)
        XCTAssertNil(WindowFilter.exclusion(windows: [window()], displays: screens, target: nil, isHidden: false))
    }
    func testOneRestoredKeepsAppEvenWithStaleTag() {
        XCTAssertNil(WindowFilter.exclusion(windows: [window(tags: 0x1300000100480001), window(2, onScreen: true, tags: 0x1300000100480001)], displays: screens, target: nil))
    }
    func testOtherSpaceIsNotMinimized() {
        XCTAssertNil(WindowFilter.exclusion(windows: [window()], displays: screens, target: nil))
    }
    func testInvisibleHelperDoesNotKeepMinimizedApp() {
        XCTAssertEqual(WindowFilter.exclusion(windows: [window(tags: 0x1300000100480001), window(2, tags: 0x0000000100080001)], displays: screens, target: nil), .minimized)
    }
    func testWindowlessAppIsExcludedByDefault() {
        XCTAssertEqual(WindowFilter.exclusion(windows: [], displays: screens, target: 1), .windowless)
    }
    func testWindowlessFilterCanBeDisabledIndependently() {
        let options = FilterOptions(excludeWindowless: false)
        XCTAssertNil(WindowFilter.exclusion(windows: [], displays: screens, target: 1, options: options))
        XCTAssertEqual(WindowFilter.exclusion(windows: [window(tags: 0x1300000100480001)], displays: screens,
                                              target: nil, options: options), .minimized)
        XCTAssertEqual(WindowFilter.exclusion(windows: [window()], displays: screens, target: nil,
                                              isHidden: true, options: options), .hidden)
    }
    func testOnlyClosedWindowsOrInvisibleHelpersCountAsWindowless() {
        for tags: UInt64 in [0x0000000100480001, 0x0000000100080001] {
            var closed = window(tags: tags)
            closed.knownUserWindow = true
            XCTAssertEqual(WindowFilter.exclusion(windows: [closed], displays: screens, target: nil), .windowless)
            XCTAssertNil(WindowFilter.exclusion(windows: [closed], displays: screens, target: nil,
                                                options: FilterOptions(excludeWindowless: false)))
        }
    }
    func testOpeningAndClosingWindowUpdatesEligibility() {
        XCTAssertEqual(WindowFilter.exclusion(windows: [], displays: screens, target: nil), .windowless)
        XCTAssertNil(WindowFilter.exclusion(windows: [window(onScreen: true)], displays: screens, target: nil))
        XCTAssertEqual(WindowFilter.exclusion(windows: [window(tags: 0x0000000100480001)],
                                              displays: screens, target: nil), .windowless)
    }
    func testDisablingMinimizedAndHiddenFiltersDoesNotDisableWindowlessFilter() {
        let options = FilterOptions(excludeMinimized: false, excludeHidden: false)
        XCTAssertEqual(WindowFilter.exclusion(windows: [], displays: screens, target: nil,
                                              isHidden: true, options: options), .windowless)
    }
    func testUnknownTagsFailOpen() {
        XCTAssertNil(WindowFilter.exclusion(windows: [window(tags: nil)], displays: screens, target: nil))
        XCTAssertNil(WindowFilter.exclusion(windows: [window(tags: 0x0000000100080001), window(2, tags: nil)],
                                            displays: screens, target: nil))
    }
    func testMinimizedWindowWithDifferentUserMarkerStillCounts() {
        XCTAssertEqual(WindowFilter.exclusion(windows: [window(tags: 0x1000000100480001)], displays: screens, target: nil), .minimized)
    }
    func testPreviouslyVisibleHiddenWindowRemainsAvailable() {
        var known = window(tags: 0x0000008100480001)
        known.knownUserWindow = true
        XCTAssertNil(WindowFilter.exclusion(windows: [known, window(2, tags: 0x1300000100480001)], displays: screens, target: nil))
    }
    func testClosedRetainedWindowDoesNotRescueMinimizedApp() {
        var closed = window(tags: 0x0000000100480001)
        closed.knownUserWindow = true
        XCTAssertEqual(WindowFilter.exclusion(windows: [closed, window(2, tags: 0x1300000100480001)], displays: screens, target: nil), .minimized)
    }
    func testColdStartHiddenWindowKeepsPartiallyMinimizedApp() {
        let windows = [window(tags: 0x0000008100480001), window(2, tags: 0x1300000100480001)]
        XCTAssertNil(WindowFilter.exclusion(windows: windows, displays: screens, target: nil,
                                            isHidden: true, options: FilterOptions(excludeHidden: false)))
        XCTAssertEqual(WindowFilter.exclusion(windows: windows, displays: screens, target: nil,
                                              isHidden: true), .hidden)
    }
    func testColdStartHiddenWindowsKeepDisplayMembership() {
        let windows = [window(x: -1000, tags: 0x0000008100480001), window(2, tags: 0x1300000100480001)]
        XCTAssertEqual(WindowFilter.exclusion(windows: windows, displays: screens, target: 1,
                                              isHidden: true, options: FilterOptions(excludeHidden: false)), .otherDisplay)
        XCTAssertNil(WindowFilter.exclusion(windows: windows, displays: screens, target: 2,
                                            isHidden: true, options: FilterOptions(excludeHidden: false)))
    }
    func testHiddenHelpersAndRetainedClosedWindowsDoNotRescueMinimizedApp() {
        for tags: UInt64 in [0x0000008100080001, 0x0000000100480001] {
            let windows = [window(tags: tags), window(2, tags: 0x1300000100480001)]
            XCTAssertEqual(WindowFilter.exclusion(windows: windows, displays: screens, target: nil,
                                                  isHidden: true, options: FilterOptions(excludeHidden: false)), .minimized)
        }
    }
    func testOtherMonitorExcluded() {
        XCTAssertEqual(WindowFilter.exclusion(windows: [window(x: -1000)], displays: screens, target: 1), .otherDisplay)
    }
    func testWindowsOnBothMonitorsIncluded() {
        XCTAssertNil(WindowFilter.exclusion(windows: [window(x: -1000), window(2)], displays: screens, target: 1))
    }
    func testMinimizedLocalWindowDoesNotRescueOtherMonitorApp() {
        XCTAssertEqual(WindowFilter.exclusion(windows: [window(tags: 0x1300000100480001), window(2, x: -1000)], displays: screens, target: 1), .otherDisplay)
    }
    func testSpanningWindowUsesLargestOverlap() {
        XCTAssertEqual(WindowFilter.displayID(for: CGRect(x: -100, y: 100, width: 700, height: 500), displays: screens), 1)
    }
    func testUnknownLocationFailOpen() {
        XCTAssertNil(WindowFilter.exclusion(windows: [window(x: 8000)], displays: screens, target: 1))
    }
    func testDisconnectedTargetDoesNotMatchKnownOtherDisplay() {
        XCTAssertEqual(WindowFilter.exclusion(windows: [window()], displays: screens, target: 2), .otherDisplay)
    }
    func testSelectionStartsAtNextAndReverses() {
        var state = Selection()
        state.begin(ids: [1, 2, 3], current: 1, backwards: false)
        XCTAssertEqual(state.selected, 2)
        state.begin(ids: [1, 2, 3], current: 1, backwards: true)
        XCTAssertEqual(state.selected, 3)
        state.step(1)
        XCTAssertEqual(state.selected, 1)
    }
    func testSelectionSurvivesLiveFilteringAndEmptyLists() {
        var state = Selection()
        state.begin(ids: [1, 2, 3], current: 1, backwards: false)
        state.update(ids: [2, 3, 4])
        XCTAssertEqual(state.selected, 2)
        state.update(ids: [3])
        XCTAssertEqual(state.selected, 3)
        state.update(ids: [])
        XCTAssertNil(state.selected)
        state.step(-1)
        state.begin(ids: [4, 5], current: 999, backwards: false)
        XCTAssertEqual(state.selected, 4)
    }
}
