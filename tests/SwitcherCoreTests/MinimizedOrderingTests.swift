import XCTest
@testable import SwitcherCore

final class MinimizedOrderingTests: XCTestCase {
    private func window(_ id: UInt32, tags: UInt64?, onScreen: Bool = false) -> WindowState {
        WindowState(id: id, pid: 1, bounds: CGRect(x: 20, y: 20, width: 300, height: 200), onScreen: onScreen, tags: tags)
    }
    func testOnlyRealFullyMinimizedWindowsGetTheBadgeAndGroup() {
        let minimized = window(1, tags: 0x1300000100480001)
        XCTAssertTrue(WindowFilter.allWindowsMinimized([minimized]))
        XCTAssertTrue(WindowFilter.allWindowsMinimized([minimized, window(2, tags: 0x0000000100080001), window(3, tags: 0x0000000100480001)]))
        XCTAssertFalse(WindowFilter.allWindowsMinimized([]))
        XCTAssertFalse(WindowFilter.allWindowsMinimized([window(1, tags: 0x0000000100480001)]))
    }
    func testVisibleRestoredUnknownAndOtherSpaceWindowsPreventMinimizedStatus() {
        for other in [window(2, tags: 0x1300000100480001, onScreen: true), window(2, tags: nil),
                      window(2, tags: 0x0300000100480001)] {
            XCTAssertFalse(WindowFilter.allWindowsMinimized([window(1, tags: 0x1300000100480001), other]))
        }
    }
    func testHiddenUserWindowIsNotMistakenForFullyMinimized() {
        XCTAssertFalse(WindowFilter.allWindowsMinimized([window(1, tags: 0x1300000100480001),
                                                       window(2, tags: 0x0000008100480001)], isHidden: true))
    }
    func testGroupingPreservesRecentOrderInsideBothGroups() {
        XCTAssertEqual(AppOrdering.minimizedLast([1, 2, 3, 4, 5], isMinimized: { [1, 3, 5].contains($0) }), [2, 4, 1, 3, 5])
        XCTAssertEqual(AppOrdering.minimizedLast([1, 2], isMinimized: { _ in true }), [1, 2])
        XCTAssertEqual(AppOrdering.minimizedLast([1, 2], isMinimized: { _ in false }), [1, 2])
        XCTAssertEqual(AppOrdering.minimizedLast([Int](), isMinimized: { _ in true }), [])
    }
    func testRestoringAWindowReordersWithoutLosingTheSelectedApp() {
        let recent: [Int32] = [1, 2, 3, 4]
        var selection = Selection()
        selection.begin(ids: AppOrdering.minimizedLast(recent, isMinimized: { $0 == 1 || $0 == 3 }), current: 2, backwards: false)
        selection.choose(3)
        selection.update(ids: AppOrdering.minimizedLast(recent, isMinimized: { $0 == 1 }))
        XCTAssertEqual(selection.ids, [2, 3, 4, 1])
        XCTAssertEqual(selection.selected, 3)
        selection.step(1)
        XCTAssertEqual(selection.selected, 4)
    }
}
