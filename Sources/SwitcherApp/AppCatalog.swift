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
    private var suspended = false
    private var generation = 0
    private var queryID = 0
    private let snapshotProvider: (() -> [WindowState]?)?
    private let stallTimeout: TimeInterval
    var queryInProgress: Bool { querying }
    private var recent: [Int32] = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private(set) var entries: [AppEntry] = []
    private(set) var ready = false
    var onChange: (() -> Void)?
    var onStall: (() -> Void)?

    init(snapshotProvider: (() -> [WindowState]?)? = nil, stallTimeout: TimeInterval = 3) {
        self.snapshotProvider = snapshotProvider
        self.stallTimeout = stallTimeout
    }

    func start() {
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
    func suspend() {
        suspended = true
        generation += 1
        ready = false
    }
    func resume() {
        suspended = false
        if querying { watchQuery(queryID, generation: generation) }
        else { refresh() }
    }
    private func remember(_ pid: Int32?) {
        guard let pid, pid != ProcessInfo.processInfo.processIdentifier else { return }
        recent.removeAll { $0 == pid }; recent.insert(pid, at: 0)
    }
    func refresh() {
        guard !suspended, !querying else { return }
        querying = true
        queryID += 1
        let query = queryID, current = generation
        let started = ProcessInfo.processInfo.systemUptime
        watchQuery(query, generation: current)
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        queue.async { [weak self] in
            guard let self else { return }
            let windows = self.snapshotProvider.map { $0() } ?? self.server.snapshot()
            DispatchQueue.main.async {
                self.querying = false
                guard self.generation == current, !self.suspended else {
                    if !self.suspended { self.refresh() }
                    return
                }
                let duration = ProcessInfo.processInfo.systemUptime - started
                if duration > 1 { DiagnosticLog.shared.record("slow window query duration=\(duration)") }
                guard let windows else { DiagnosticLog.shared.record("window query failed"); return }
                if !self.ready {
                    for window in windows where window.onScreen && !self.recent.contains(window.pid) { self.recent.append(window.pid) }
                }
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
    private func watchQuery(_ query: Int, generation current: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + stallTimeout) { [weak self] in
            guard let self, self.querying, self.queryID == query, self.generation == current, !self.suspended else { return }
            self.ready = false
            DiagnosticLog.shared.record("window query stalled for \(self.stallTimeout) seconds")
            self.onStall?()
        }
    }
    func filtered(target: UInt32?, options: FilterOptions) -> [AppEntry] {
        let displays = connectedDisplays()
        return entries.filter {
            WindowFilter.exclusion(windows: $0.windows, displays: displays, target: target,
                                   isHidden: $0.isHidden, options: options) == nil
        }
    }
    deinit {
        timer?.invalidate()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
