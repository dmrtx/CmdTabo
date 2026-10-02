import AppKit
import SwitcherCore

/// A disposable own-process check of undocumented bits on this macOS build.
final class WindowProbe: NSObject, NSApplicationDelegate {
    private let server = WindowServer()
    private var windows: [NSWindow] = []
    private var stage = 0
    private var attempts = 0
    private var timer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        for i in 0..<2 {
            let window = NSWindow(contentRect: NSRect(x: 220 + i * 40, y: 200 + i * 40, width: 480, height: 260),
                                  styleMask: [.titled, .miniaturizable, .closable], backing: .buffered, defer: false)
            window.title = "CmdTabo · disposable test \(i + 1)"
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.tick() }
    }
    private func tick() {
        attempts += 1
        let own = (server.snapshot() ?? []).filter { $0.pid == ProcessInfo.processInfo.processIdentifier }
        let ids = windows.map { UInt32($0.windowNumber) }
        let first = own.first { $0.id == ids[0] }
        let second = own.first { $0.id == ids[1] }
        let reason = WindowFilter.exclusion(windows: own, displays: connectedDisplays(), target: nil)
        let valid: Bool
        let name: String
        switch stage {
        case 0: name = "two visible"; valid = first?.onScreen == true && second?.onScreen == true && reason == nil
        case 1: name = "one minimized"; valid = first?.minimized == true && second?.onScreen == true && reason == nil
        case 2: name = "all minimized"; valid = first?.minimized == true && second?.minimized == true && reason == .minimized
        case 3:
            name = "minimized filter off"
            valid = reason == .minimized && WindowFilter.exclusion(windows: own, displays: connectedDisplays(), target: nil,
                                                                  options: FilterOptions(excludeMinimized: false)) == nil
        case 4: name = "restored"; valid = first?.onScreen == true && reason == nil
        case 5:
            name = "hidden filter on"
            valid = NSRunningApplication.current.isHidden && first?.minimized == false &&
                WindowFilter.exclusion(windows: own, displays: connectedDisplays(), target: nil, isHidden: NSRunningApplication.current.isHidden) == .hidden
        case 6:
            name = "hidden filter off"
            valid = NSRunningApplication.current.isHidden &&
                WindowFilter.exclusion(windows: own, displays: connectedDisplays(), target: nil, isHidden: NSRunningApplication.current.isHidden,
                                       options: FilterOptions(excludeHidden: false)) == nil
        case 7: name = "unhidden"; valid = !NSRunningApplication.current.isHidden && first?.onScreen == true && reason == nil
        case 8: name = "no windows"; valid = own.filter(\.isUserWindow).isEmpty && reason == nil
        case 9:
            name = "cold-start hidden with one minimized"
            let fresh = (WindowServer().snapshot() ?? []).filter { $0.pid == ProcessInfo.processInfo.processIdentifier }
            valid = NSRunningApplication.current.isHidden && second?.minimized == true &&
                WindowFilter.exclusion(windows: fresh, displays: connectedDisplays(), target: nil, isHidden: true,
                                       options: FilterOptions(excludeHidden: false)) == nil
        default:
            name = "cold-start hidden with all minimized"
            let fresh = (WindowServer().snapshot() ?? []).filter { $0.pid == ProcessInfo.processInfo.processIdentifier }
            valid = NSRunningApplication.current.isHidden && first?.minimized == true && second?.minimized == true &&
                WindowFilter.exclusion(windows: fresh, displays: connectedDisplays(), target: nil, isHidden: true,
                                       options: FilterOptions(excludeHidden: false)) == .minimized
        }
        guard valid else {
            if attempts >= 40 {
                print("FAIL \(name): \(own.map { String(format: "%u:%016llx:%d", $0.id, $0.tags ?? 0, $0.onScreen ? 1 : 0) })")
                exit(1)
            }
            return
        }
        print("PASS \(name): \(own.map { String(format: "%u:%016llx:%d", $0.id, $0.tags ?? 0, $0.onScreen ? 1 : 0) })")
        attempts = 0
        switch stage {
        case 0: windows[0].miniaturize(nil)
        case 1: windows[1].miniaturize(nil)
        case 2: break
        case 3: windows[0].deminiaturize(nil)
        case 4: NSApp.hide(nil)
        case 5: break
        case 6: NSApp.unhide(nil); windows[0].makeKeyAndOrderFront(nil)
        case 7: windows.forEach { $0.close() }
        case 8:
            windows.forEach { $0.makeKeyAndOrderFront(nil) }
            windows[1].miniaturize(nil)
            NSApp.hide(nil)
        case 9: windows[0].miniaturize(nil)
        default:
            NSApp.unhide(nil)
            windows.forEach { $0.close() }
            print("RESULT 11 checks passed"); timer?.invalidate(); exit(0)
        }
        stage += 1
    }
}
