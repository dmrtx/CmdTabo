import Foundation
import CoreGraphics

public struct Display {
    public var id: UInt32
    public var bounds: CGRect
    public init(id: UInt32, bounds: CGRect) { self.id = id; self.bounds = bounds }
}

public struct WindowState {
    public var id: UInt32
    public var pid: Int32
    public var bounds: CGRect
    public var onScreen: Bool
    public var tags: UInt64?
    public var knownUserWindow: Bool
    public init(id: UInt32, pid: Int32, bounds: CGRect, onScreen: Bool, tags: UInt64?, knownUserWindow: Bool = false) {
        self.id = id; self.pid = pid; self.bounds = bounds; self.onScreen = onScreen; self.tags = tags
        self.knownUserWindow = knownUserWindow
    }
    // WindowServer fields measured by Switcher; verified by our runtime probe.
    public var minimized: Bool { !onScreen && tags.map { $0 & (1 << 60) != 0 } == true }
    public var isUserWindow: Bool {
        isUserWindow(appIsHidden: false)
    }
    public func isUserWindow(appIsHidden: Bool) -> Bool {
        guard !onScreen, let tags else { return true }
        // Closed-but-retained NSWindows also remain in CGWindowList. History
        // or app visibility rescues hidden windows even at cold start. Normal
        // closed-window markers lack bit 39; helpers lack normal-window bit 22.
        // A stale hidden marker is ambiguous and conservatively stays eligible.
        let hiddenWindow = tags & (1 << 39) != 0 && tags & (1 << 22) != 0
        return tags & 0x1300000000000000 != 0 || (hiddenWindow && (knownUserWindow || appIsHidden))
    }
}

public struct FilterOptions: Equatable {
    public var excludeMinimized: Bool
    public var excludeHidden: Bool
    public init(excludeMinimized: Bool = true, excludeHidden: Bool = true) {
        self.excludeMinimized = excludeMinimized
        self.excludeHidden = excludeHidden
    }
}

public enum Exclusion: String { case hidden, minimized, otherDisplay }

public enum WindowFilter {
    public static func displayID(for rect: CGRect, displays: [Display]) -> UInt32? {
        guard !rect.isEmpty, !rect.isNull else { return nil }
        let overlaps = displays.map { display -> (UInt32, CGFloat) in
            let overlap = rect.intersection(display.bounds)
            return (display.id, overlap.isNull ? 0 : overlap.width * overlap.height)
        }
        guard let best = overlaps.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }

    public static func exclusion(windows: [WindowState], displays: [Display], target: UInt32?,
                                 isHidden: Bool = false, options: FilterOptions = FilterOptions()) -> Exclusion? {
        if options.excludeHidden && isHidden { return .hidden }
        let real = windows.filter { $0.isUserWindow(appIsHidden: isHidden) }
        guard !real.isEmpty else { return nil }
        let available = options.excludeMinimized ? real.filter { !$0.minimized } : real
        guard !available.isEmpty else { return .minimized }
        if let target {
            let locations = available.map { displayID(for: $0.bounds, displays: displays) }
            // An unknown position must not make an app unreachable.
            if locations.allSatisfy({ $0 != nil && $0 != target }) { return .otherDisplay }
        }
        return nil
    }
}

public struct Selection {
    public private(set) var ids: [Int32] = []
    public private(set) var index = 0
    public var selected: Int32? { ids.indices.contains(index) ? ids[index] : nil }
    public var active: Bool { !ids.isEmpty }
    public init() {}
    public mutating func begin(ids: [Int32], current: Int32?, backwards: Bool) {
        self.ids = ids
        index = current.flatMap { ids.firstIndex(of: $0) } ?? (backwards ? 0 : ids.count - 1)
        step(backwards ? -1 : 1)
    }
    public mutating func step(_ delta: Int) {
        guard !ids.isEmpty else { index = 0; return }
        index = ((index + delta) % ids.count + ids.count) % ids.count
    }
    public mutating func update(ids newIDs: [Int32]) {
        let previous = selected
        ids = newIDs
        index = previous.flatMap { newIDs.firstIndex(of: $0) } ?? min(index, max(0, newIDs.count - 1))
    }
    public mutating func choose(_ pid: Int32) { if let i = ids.firstIndex(of: pid) { index = i } }
    public mutating func clear() { ids = []; index = 0 }
}
