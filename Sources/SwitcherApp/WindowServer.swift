import AppKit
import SwitcherCore

/// All private symbols are optional: missing symbols leave apps listed.
final class WindowServer {
    private typealias Connection = @convention(c) () -> UInt32
    private typealias Query = @convention(c) (UInt32, CFArray, Int32) -> Unmanaged<CFTypeRef>?
    private typealias CopyIterator = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    private typealias Advance = @convention(c) (CFTypeRef) -> Bool
    private typealias WindowID = @convention(c) (CFTypeRef) -> UInt32
    private typealias Tags = @convention(c) (CFTypeRef) -> UInt64
    private let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private var knownWindows: Set<UInt32> = []
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
        var candidates: [(UInt32, Int32, CGRect, Bool)] = []
        for item in dictionaries {
            guard let id = item[kCGWindowNumber as String] as? UInt32,
                  let pid = item[kCGWindowOwnerPID as String] as? Int32,
                  let layer = item[kCGWindowLayer as String] as? Int, layer == 0,
                  let dictionary = item[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary), rect.width >= 40, rect.height >= 40 else { continue }
            candidates.append((id, pid, rect, item[kCGWindowIsOnscreen as String] as? Bool ?? false))
        }
        let tags = windowTags(candidates.map { $0.0 })
        knownWindows.formIntersection(candidates.map { $0.0 })
        for window in candidates where window.3 { knownWindows.insert(window.0) }
        return candidates.map { WindowState(id: $0.0, pid: $0.1, bounds: $0.2, onScreen: $0.3, tags: tags[$0.0], knownUserWindow: knownWindows.contains($0.0)) }
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
