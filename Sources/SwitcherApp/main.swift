import AppKit
import ApplicationServices
import SwitcherCore

if CommandLine.arguments.contains("--accessibility-status") {
    // Bound the helper even if the system trust query itself stops responding.
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) { exit(2) }
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
    print(AXIsProcessTrustedWithOptions(options) ? "trusted" : "untrusted")
} else if CommandLine.arguments.contains("--guard-native-command-tab") {
    let arguments = CommandLine.arguments
    guard arguments.count == 4, ["0", "1"].contains(arguments[2]), ["0", "1"].contains(arguments[3]) else { exit(2) }
    NativeCommandTab.runGuardian(previous: [arguments[2] == "1", arguments[3] == "1"])
} else if CommandLine.arguments.contains("--native-status") {
    if let states = NativeCommandTab().states() {
        print("commandTab=\(states[0]) commandShiftTab=\(states[1])")
    } else { print("native switcher API unavailable"); exit(1) }
} else if CommandLine.arguments.contains("--self-test-windows") {
    let app = NSApplication.shared
    let probe = WindowProbe()
    app.delegate = probe
    app.run()
} else if CommandLine.arguments.contains("--diagnose") {
    let server = WindowServer()
    let windows = server.snapshot() ?? []
    let displays = connectedDisplays()
    let current = displayID(pointerScreen())
    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map { app -> [String: Any] in
        let owned = windows.filter { $0.pid == app.processIdentifier }
        return ["name": app.localizedName ?? "", "pid": app.processIdentifier, "hidden": app.isHidden,
                "allDisplaysExclusion": WindowFilter.exclusion(windows: owned, displays: displays, target: nil, isHidden: app.isHidden)?.rawValue ?? "included",
                "currentDisplayExclusion": WindowFilter.exclusion(windows: owned, displays: displays, target: current, isHidden: app.isHidden)?.rawValue ?? "included",
                "windows": owned.map { window -> [String: Any] in
                    ["id": window.id, "onScreen": window.onScreen, "minimized": window.minimized,
                     "userWindow": window.isUserWindow, "tags": window.tags.map { String(format: "%016llx", $0) } ?? "unknown",
                     "display": WindowFilter.displayID(for: window.bounds, displays: displays).map { Int64($0) } ?? -1,
                     "bounds": [window.bounds.minX, window.bounds.minY, window.bounds.width, window.bounds.height]]
                }]
    }
    let report: [String: Any] = ["skyLightAvailable": server.available, "accessibility": AXIsProcessTrusted(),
                                "currentDisplay": current.map { Int64($0) } ?? -1,
                                "displays": displays.map { ["id": $0.id, "bounds": [$0.bounds.minX, $0.bounds.minY, $0.bounds.width, $0.bounds.height]] as [String: Any] },
                                "apps": apps]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
