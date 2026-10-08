import AppKit
import SwitcherCore

struct WindowMetadataExtractor {
    private struct Candidate {
        let id: UInt32
        let pid: Int32
        let bounds: CGRect
        let onScreen: Bool
        let layer: Int
    }
    // Content windows can float or be modal. Main-menu, popup-menu, tooltip,
    // status and overlay levels are absent even when those windows are on screen.
    private static let contentLevels = Set([NSWindow.Level.normal.rawValue, NSWindow.Level.floating.rawValue,
                                           NSWindow.Level.modalPanel.rawValue])
    private var knownWindows: Set<UInt32> = []

    mutating func snapshot(from dictionaries: [[String: Any]],
                           tagsProvider: ([UInt32]) -> [UInt32: UInt64]) -> [WindowState] {
        var candidates: [Candidate] = []
        for item in dictionaries {
            guard let id = item[kCGWindowNumber as String] as? UInt32,
                  let pid = item[kCGWindowOwnerPID as String] as? Int32,
                  let layer = item[kCGWindowLayer as String] as? Int, Self.contentLevels.contains(layer),
                  let dictionary = item[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary), rect.width >= 40, rect.height >= 40 else { continue }
            let onScreen = item[kCGWindowIsOnscreen as String] as? Bool ?? false
            // Off-screen hidden/minimized windows may have alpha zero and still
            // need their tags. Missing alpha remains unknown rather than hidden.
            if onScreen, let alpha = item[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue <= 0 { continue }
            candidates.append(Candidate(id: id, pid: pid, bounds: rect, onScreen: onScreen, layer: layer))
        }
        let tags = tagsProvider(candidates.map(\.id))
        candidates.removeAll { window in
            guard window.layer != NSWindow.Level.normal.rawValue, let value = tags[window.id] else { return false }
            // Do not let a floating helper become the app's only content window.
            // Only the measured helper marker is rejected. Zero or unfamiliar
            // tags remain candidates rather than being assumed to be helpers.
            return value & (1 << 19) != 0 && value & (1 << 22) == 0 && value & 0x1300000000000000 == 0
        }
        knownWindows.formIntersection(candidates.map(\.id))
        for window in candidates where window.onScreen { knownWindows.insert(window.id) }
        return candidates.map { WindowState(id: $0.id, pid: $0.pid, bounds: $0.bounds, onScreen: $0.onScreen,
                                            tags: tags[$0.id], knownUserWindow: knownWindows.contains($0.id)) }
    }
}

/// All private symbols are optional: missing symbols leave apps listed.
final class WindowServer {
    private typealias Connection = @convention(c) () -> UInt32
    private typealias Query = @convention(c) (UInt32, CFArray, Int32) -> Unmanaged<CFTypeRef>?
    private typealias CopyIterator = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    private typealias Advance = @convention(c) (CFTypeRef) -> Bool
    private typealias WindowID = @convention(c) (CFTypeRef) -> UInt32
    private typealias Tags = @convention(c) (CFTypeRef) -> UInt64
    private let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private var metadata = WindowMetadataExtractor()
    private func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
    var available: Bool {
        guard let handle else { return false }
        let names: [String] = ["SLSMainConnectionID", "SLSWindowQueryWindows", "SLSWindowQueryResultCopyWindows",
                               "SLSWindowIteratorAdvance", "SLSWindowIteratorGetWindowID", "SLSWindowIteratorGetTags"]
        return names.allSatisfy { dlsym(handle, $0) != nil }
    }
    private func windowTags(_ ids: [UInt32]) -> [UInt32: UInt64] {
        guard !ids.isEmpty,
              let connection = symbol("SLSMainConnectionID", Connection.self),
              let query = symbol("SLSWindowQueryWindows", Query.self),
              let iterator = symbol("SLSWindowQueryResultCopyWindows", CopyIterator.self),
              let advance = symbol("SLSWindowIteratorAdvance", Advance.self),
              let getID = symbol("SLSWindowIteratorGetWindowID", WindowID.self),
              let tags = symbol("SLSWindowIteratorGetTags", Tags.self),
              let result = query(connection(), ids.map(NSNumber.init(value:)) as CFArray, Int32(ids.count))?.takeRetainedValue(),
              let windows = iterator(result)?.takeRetainedValue() else { return [:] }
        var values: [UInt32: UInt64] = [:]
        while advance(windows) { values[getID(windows)] = tags(windows) }
        return values
    }
    func snapshot() -> [WindowState]? {
        guard let dictionaries = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return metadata.snapshot(from: dictionaries, tagsProvider: windowTags)
    }
}

func connectedDisplays() -> [Display] {
    NSScreen.screens.compactMap { screen in
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let id = number.uint32Value
        return Display(id: id, bounds: CGDisplayBounds(id))
    }
}

func pointerScreen() -> NSScreen? {
    let location = NSEvent.mouseLocation
    return NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main ?? NSScreen.screens.first
}

func displayID(_ screen: NSScreen?) -> UInt32? {
    (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
}
