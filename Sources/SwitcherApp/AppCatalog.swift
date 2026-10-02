import AppKit
import SwitcherCore

struct AppEntry {
    let app: NSRunningApplication
    var pid: Int32 { app.processIdentifier }
    var name: String { app.localizedName ?? "Application" }
    var icon: NSImage { app.icon ?? NSImage(named: NSImage.applicationIconName)! }
    let windows: [WindowState]
    let isHidden: Bool
}

final class AppCatalog {
    let server = WindowServer()
    private let queue = DispatchQueue(label: "local.cmdtabo.windows", qos: .userInitiated)
    private var querying = false
    private var recent: [Int32] = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private(set) var entries: [AppEntry] = []
    private(set) var ready = false
    var onChange: (() -> Void)?

    func start() {
        let initial = server.snapshot() ?? []
        for window in initial where window.onScreen && !recent.contains(window.pid) { recent.append(window.pid) }
        remember(NSWorkspace.shared.frontmostApplication?.processIdentifier)
        let center = NSWorkspace.shared.notificationCenter
        for notification in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                             NSWorkspace.didTerminateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                             NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observers.append(center.addObserver(forName: notification, object: nil, queue: .main) { [weak self] notice in
                guard let self else { return }
                if notification == NSWorkspace.didActivateApplicationNotification,
                   let app = notice.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self.remember(app.processIdentifier) }
                self.refresh()
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)
        refresh()
    }
    private func remember(_ pid: Int32?) {
        guard let pid, pid != ProcessInfo.processInfo.processIdentifier else { return }
        recent.removeAll { $0 == pid }; recent.insert(pid, at: 0)
    }
    func refresh() {
        guard !querying else { return }
        querying = true
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        queue.async { [weak self] in
            guard let self else { return }
            let windows = self.server.snapshot()
            DispatchQueue.main.async {
                defer { self.querying = false }
                guard let windows else { return }
                self.entries = apps.map { app in
                    AppEntry(app: app, windows: windows.filter { $0.pid == app.processIdentifier }, isHidden: app.isHidden)
                }
                self.entries.sort {
                    let left = self.recent.firstIndex(of: $0.pid) ?? Int.max
                    let right = self.recent.firstIndex(of: $1.pid) ?? Int.max
                    return left == right ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : left < right
                }
                let alive = Set(apps.map(\.processIdentifier))
                self.recent.removeAll { !alive.contains($0) }
                self.ready = true
                self.onChange?()
            }
        }
    }
    func filtered(target: UInt32?, options: FilterOptions) -> [AppEntry] {
        let displays = connectedDisplays()
        return entries.filter {
            WindowFilter.exclusion(windows: $0.windows, displays: displays, target: target,
                                   isHidden: $0.isHidden, options: options) == nil
        }
    }
}
