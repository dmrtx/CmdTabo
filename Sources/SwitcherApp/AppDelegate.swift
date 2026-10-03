import AppKit
import ApplicationServices
import SwitcherCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let catalog = AppCatalog()
    let keyboard = Keyboard()
    private let nativeCommandTab = NativeCommandTab()
    private let overlay = SwitcherPanel()
    var selection = Selection()
    private var sessionEntries: [AppEntry] = []
    private var sessionScreen: NSScreen?
    private var target: UInt32?
    var showing = false
    var preview = false
    private var renderQueued = false
    private var statusItem: NSStatusItem!
    private var settings: NSWindow!
    private let status = NSTextField(wrappingLabelWithString: "Preparing…")
    private let displaysLabel = NSTextField(wrappingLabelWithString: "")
    private var enabledButton: NSButton!
    private var scopeButton: NSButton!
    private var minimizedButton: NSButton!
    private var hiddenButton: NSButton!
    private var heartbeat: Timer?
    private var lifecycle = CaptureLifecycle()
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var lastHealth: TimeInterval = 0
    private let accessibility = AccessibilityMonitor()
    private var relaunching = false
    private var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "switcherEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "switcherEnabled") }
    }
    private var onlyThisDisplay: Bool {
        get { UserDefaults.standard.bool(forKey: "onlyThisDisplay") }
        set { UserDefaults.standard.set(newValue, forKey: "onlyThisDisplay") }
    }
    private var filterOptions: FilterOptions {
        FilterOptions(excludeMinimized: UserDefaults.standard.bool(forKey: "excludeMinimized"),
                      excludeHidden: UserDefaults.standard.bool(forKey: "excludeHidden"))
    }

    func applicationWillFinishLaunching(_ notification: Notification) { configureLifecycle() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["switcherEnabled": true, "onlyThisDisplay": true,
                                                "excludeMinimized": true, "excludeHidden": true])
        NSApp.setActivationPolicy(.accessory)
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        let root = NSMenuItem()
        root.submenu = appMenu
        mainMenu.addItem(root)
        let preferences = NSMenuItem(title: "CmdTabo Settings…", action: #selector(showSettings), keyEquivalent: ",")
        preferences.target = self
        appMenu.addItem(preferences)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit CmdTabo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        NSApp.mainMenu = mainMenu
        configureKeyboard()
        configureLifecycle()
        if CommandLine.arguments.contains("--accessibility-relaunched") {
            lifecycle.resume(.systemSleep, now: ProcessInfo.processInfo.systemUptime)
        }
        createStatusItem()
        createSettings()
        accessibility.onChange = { [weak self] trusted in
            guard let self else { return }
            if trusted { self.lifecycle.retry() }
            self.reconcilePermissions()
        }
        accessibility.onStaleGrant = { [weak self] in self?.relaunchAfterGrant() }
        catalog.onStall = { [weak self] in self?.captureFailed() }
        catalog.onChange = { [weak self] in
            guard let self else { return }
            if self.showing {
                self.sessionEntries = self.catalog.filtered(target: self.target, options: self.filterOptions)
                self.selection.update(ids: self.sessionEntries.map(\.pid))
                self.scheduleRender()
            }
            self.updateStatus()
        }
        catalog.start()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.nativeCommandTab.heartbeat() { self.captureFailed() }
            self.accessibility.refresh()
            self.reconcilePermissions()
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastHealth >= 30 {
                self.lastHealth = now
                DiagnosticLog.shared.record("health capture=\(self.keyboard.running) owned=\(self.nativeCommandTab.isOverridden) catalogReady=\(self.catalog.ready) querying=\(self.catalog.queryInProgress) failed=\(self.lifecycle.failed)")
            }
            if self.showing && !self.preview && !CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand) { self.confirm() }
        }
        RunLoop.main.add(heartbeat!, forMode: .common)
        if !accessibility.trusted { showSettings() }
        else { reconcilePermissions() }
        let info = Bundle.main.infoDictionary ?? [:]
        DiagnosticLog.shared.record("started version=\(info["CFBundleShortVersionString"] ?? "development") build=\(info["CFBundleVersion"] ?? "unknown") commit=\(info["GitCommit"] ?? "unknown") source=\(info["SourceState"] ?? "unknown") os=\(ProcessInfo.processInfo.operatingSystemVersionString) accessibility=\(AXIsProcessTrusted()) SkyLight=\(catalog.server.available)")
    }
    func configureKeyboard() {
        keyboard.isShowing = { [weak self] in self?.showing == true }
        keyboard.canBegin = { [weak self] in self?.catalog.ready == true }
        keyboard.onTab = { [weak self] backwards in
            guard let self else { return }
            if self.showing {
                self.preview = false
                self.selection.step(backwards ? -1 : 1)
                self.scheduleRender()
            }
            else { self.begin(backwards: backwards, preview: false) }
        }
        keyboard.onStep = { [weak self] delta in self?.selection.step(delta); self?.scheduleRender() }
        keyboard.onConfirm = { [weak self] in self?.confirm() }
        keyboard.shouldConfirmOnCommandRelease = { [weak self] in self?.preview == false }
        keyboard.onCancel = { [weak self] in self?.cancel() }
        keyboard.onFailure = { [weak self] in self?.captureFailed() }
        nativeCommandTab.onGuardianFailure = { [weak self] in self?.captureFailed() }
        overlay.onClick = { [weak self] pid in self?.selection.choose(pid); self?.confirm() }
    }
    private func configureLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        lifecycle.onRelease = { [weak self] in
            guard let self else { return }
            // No AppKit window calls until the tap and native override are gone.
            self.nativeCommandTab.restore()
            self.keyboard.stop()
        }
        let center = NSWorkspace.shared.notificationCenter
        let notices: [(Notification.Name, CaptureLifecycle.Suspension, Bool)] = [
            (NSWorkspace.willSleepNotification, .systemSleep, true),
            (NSWorkspace.didWakeNotification, .systemSleep, false),
            (NSWorkspace.screensDidSleepNotification, .displaySleep, true),
            (NSWorkspace.screensDidWakeNotification, .displaySleep, false),
            (NSWorkspace.sessionDidResignActiveNotification, .inactiveSession, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .inactiveSession, false)
        ]
        for (name, reason, suspending) in notices {
            lifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                DiagnosticLog.shared.record("lifecycle \(reason.rawValue) \(suspending ? "suspend" : "resume")")
                if suspending { self.lifecycle.suspend(reason); self.catalog.suspend() }
                else {
                    self.lifecycle.resume(reason, now: ProcessInfo.processInfo.systemUptime)
                    if self.lifecycle.suspensions.isEmpty { self.catalog.resume() }
                }
                if self.statusItem != nil { self.updateStatus() }
            })
        }
    }
    private func captureFailed() {
        DiagnosticLog.shared.record("capture failed; native shortcuts restored; manual resume required")
        lifecycle.fail()
        updateStatus()
    }
    private func begin(backwards: Bool, preview: Bool) {
        guard catalog.ready else { return }
        sessionScreen = pointerScreen()
        target = onlyThisDisplay ? displayID(sessionScreen) : nil
        sessionEntries = catalog.filtered(target: target, options: filterOptions)
        selection.begin(ids: sessionEntries.map(\.pid), current: NSWorkspace.shared.frontmostApplication?.processIdentifier, backwards: backwards)
        self.preview = preview
        showing = true
        DiagnosticLog.shared.record("selector opened count=\(sessionEntries.count) preview=\(preview)")
        scheduleRender()
    }
    private func scheduleRender() {
        guard !renderQueued else { return }
        renderQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderQueued = false
            guard self.showing else { return }
            self.overlay.show(entries: self.sessionEntries, selected: self.selection.selected, screen: self.sessionScreen)
        }
    }
    private func confirm() {
        guard showing else { return }
        let app = sessionEntries.first { $0.pid == selection.selected }?.app
        DiagnosticLog.shared.record("selector confirmed")
        cancel()
        // Activation runs after the event callback returns to WindowServer.
        DispatchQueue.main.async { app?.activate(options: [.activateIgnoringOtherApps]) }
    }
    private func cancel() {
        showing = false; preview = false; selection.clear(); sessionEntries = []
        overlay.hide()
    }
    private func reconcilePermissions() {
        if !KeyboardOwnership.reconcile(eligible: !relaunching && enabled && accessibility.trusted && catalog.ready && lifecycle.permitsCapture(now: ProcessInfo.processInfo.systemUptime),
                                        keyboard: keyboard, native: nativeCommandTab) {
            captureFailed()
        }
        updateStatus()
    }
    private func updateStatus() {
        let text: String
        if lifecycle.failed { text = "Capture stopped after a failure. ⌘Tab uses macOS. Choose Pause / resume to retry. Logs are available from the menu." }
        else if !enabled { text = "Paused. ⌘Tab uses the macOS switcher." }
        else if !lifecycle.permitsCapture(now: ProcessInfo.processInfo.systemUptime) { text = "Waiting for the session to resume. ⌘Tab uses macOS." }
        else if relaunching { text = "Access granted. Reopening CmdTabo to refresh the permission…" }
        else if !accessibility.trusted { text = "Accessibility is required. Click “Grant Accessibility” and enable CmdTabo in System Settings. Access is checked automatically; an existing grant may need removing and re-adding after an update." }
        else if !catalog.ready { text = "Loading windows…" }
        else if !keyboard.running { text = "Accessibility granted, but ⌘Tab could not be captured. Try quitting and reopening CmdTabo." }
        else { text = "Active. Hold ⌘ and press Tab; release ⌘ to switch apps." }
        status.stringValue = text
        let screens = NSScreen.screens
        displaysLabel.stringValue = "\(screens.count) display\(screens.count == 1 ? "" : "s") detected: " + screens.map(\.localizedName).joined(separator: ", ")
        enabledButton.state = enabled ? .on : .off
        scopeButton.state = onlyThisDisplay ? .on : .off
        minimizedButton.state = filterOptions.excludeMinimized ? .on : .off
        hiddenButton.state = filterOptions.excludeHidden ? .on : .off
        statusItem.button?.toolTip = "CmdTabo · " + (keyboard.running ? "Active" : "Pending / paused")
    }
    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "CmdTabo")
        let menu = NSMenu()
        for (title, action) in [("CmdTabo Settings…", #selector(showSettings)),
                                ("Preview switcher", #selector(showPreview)),
                                ("Pause / resume", #selector(toggleEnabled)),
                                ("Open diagnostic logs", #selector(openLogs)),
                                ("Quit CmdTabo", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        statusItem.menu = menu
    }
    private func createSettings() {
        settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 485),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        settings.title = "CmdTabo"
        settings.isReleasedWhenClosed = false
        settings.center()
        let title = NSTextField(labelWithString: "CmdTabo")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString: "One entry per app, just like ⌘Tab. Hold ⌘, press Tab, then release ⌘ to switch. ⌘⇧Tab goes back; Esc cancels.")
        description.textColor = .secondaryLabelColor
        enabledButton = NSButton(checkboxWithTitle: "Use CmdTabo for ⌘Tab", target: self, action: #selector(toggleEnabled))
        let filtersTitle = NSTextField(labelWithString: "Exclude from the switcher")
        filtersTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        minimizedButton = NSButton(checkboxWithTitle: "Apps with all windows minimized", target: self, action: #selector(toggleMinimized))
        hiddenButton = NSButton(checkboxWithTitle: "Hidden apps (⌘H)", target: self, action: #selector(toggleHidden))
        scopeButton = NSButton(checkboxWithTitle: "Apps with windows only on other displays", target: self, action: #selector(toggleScope))
        let scopeHint = NSTextField(wrappingLabelWithString: "Each filter can be disabled independently. Apps return when restored or unhidden. The display filter uses the screen under the pointer when you press ⌘Tab.")
        scopeHint.font = .systemFont(ofSize: 11)
        scopeHint.textColor = .secondaryLabelColor
        displaysLabel.font = .systemFont(ofSize: 11)
        displaysLabel.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        let access = NSButton(title: "Grant Accessibility", target: self, action: #selector(requestAccessibility))
        access.bezelStyle = .rounded
        let previewButton = NSButton(title: "Preview", target: self, action: #selector(showPreview))
        previewButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [access, previewButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let footnote = NSTextField(labelWithString: "Accessibility only · No screen capture · Keeps the Dock")
        footnote.font = .systemFont(ofSize: 10)
        footnote.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [title, description, enabledButton, filtersTitle, minimizedButton, hiddenButton,
                                      scopeButton, scopeHint, displaysLabel, status, buttons, footnote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        settings.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: settings.contentView!.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: settings.contentView!.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: settings.contentView!.topAnchor, constant: 24)
        ])
        for label in [description, scopeHint, displaysLabel, status] { label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        accessibility.refresh()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    private func relaunchAfterGrant() {
        guard !relaunching else { return }
        relaunching = true
        nativeCommandTab.restore()
        keyboard.stop()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.arguments = ["--accessibility-relaunched"]
        updateStatus()
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] application, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard error == nil, application != nil else {
                    self.relaunching = false
                    DiagnosticLog.shared.record("accessibility relaunch failed")
                    self.captureFailed()
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }
    @objc private func showSettings() { cancel(); NSApp.activate(ignoringOtherApps: true); settings.makeKeyAndOrderFront(nil); updateStatus() }
    @objc private func showPreview() { cancel(); settings.orderOut(nil); catalog.refresh(); begin(backwards: false, preview: true) }
    @objc private func toggleEnabled() {
        if lifecycle.failed { lifecycle.retry(); enabled = true }
        else { enabled.toggle() }
        DiagnosticLog.shared.record("user capture enabled=\(enabled)")
        reconcilePermissions()
    }
    @objc private func openLogs() { NSWorkspace.shared.open(DiagnosticLog.directory) }
    @objc private func toggleScope() { onlyThisDisplay.toggle(); cancel(); updateStatus() }
    @objc private func toggleMinimized() {
        UserDefaults.standard.set(!filterOptions.excludeMinimized, forKey: "excludeMinimized")
        cancel(); updateStatus()
    }
    @objc private func toggleHidden() {
        UserDefaults.standard.set(!filterOptions.excludeHidden, forKey: "excludeHidden")
        cancel(); updateStatus()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        nativeCommandTab.restore(); keyboard.stop(); heartbeat?.invalidate(); catalog.suspend()
        for observer in lifecycleObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        DiagnosticLog.shared.record("terminated normally")
        DiagnosticLog.shared.flush()
    }
}
