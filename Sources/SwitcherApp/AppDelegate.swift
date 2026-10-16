import AppKit
import ApplicationServices
import Carbon
import SwitcherCore

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

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
    private let updates = UpdateController()
    private let preferences = AppPreferences()
    private var hiddenAppsController: HiddenAppsController?
    private let hiddenAppsSummary = NSTextField(labelWithString: "")
    private var versionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "CmdTabo \(info["CFBundleShortVersionString"] as? String ?? "development") · build \(info["CFBundleVersion"] as? String ?? "unknown")"
    }
    private(set) var settings: NSWindow!
    private let status = NSTextField(wrappingLabelWithString: "Preparing…")
    private let displaysLabel = NSTextField(wrappingLabelWithString: "")
    private let permissionLabel = NSTextField(labelWithString: "Checking Accessibility…")
    private let permissionIcon = NSImageView()
    private var enabledButton: NSButton!
    private var scopeButton: NSButton!
    private var minimizedMenu: NSPopUpButton!
    private var hiddenButton: NSButton!
    private var windowlessButton: NSButton!
    private var accessibilityButton: NSButton!
    private var heartbeat: Timer?
    private var lifecycle = CaptureLifecycle()
    private var deliveryMonitor = KeyboardDeliveryMonitor()
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
    private var filterOptions: FilterOptions { preferences.filterOptions }
    private func filteredEntries() -> [AppEntry] {
        catalog.filtered(target: target, options: filterOptions,
                         excludedApplications: preferences.excludedApplications,
                         minimizedLast: preferences.minimizedAppsMode == .atEnd)
    }

    func applicationWillFinishLaunching(_ notification: Notification) { configureLifecycle() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["switcherEnabled": true, "onlyThisDisplay": true,
                                                "excludeMinimized": true, "excludeHidden": true, "excludeWindowless": true])
        NSApp.setActivationPolicy(.accessory)
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        let root = NSMenuItem()
        root.submenu = appMenu
        mainMenu.addItem(root)
        appMenu.addItem(NSMenuItem(title: versionLabel, action: nil, keyEquivalent: ""))
        appMenu.addItem(.separator())
        let preferences = NSMenuItem(title: "CmdTabo Settings…", action: #selector(showSettings), keyEquivalent: ",")
        preferences.target = self
        appMenu.addItem(preferences)
        updates.addMenuItems(to: appMenu)
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
        updates.onWillRelaunch = { [weak self] in self?.prepareForUpdate() }
        updates.onUpdateReady = { [weak self] available in
            self?.statusItem.button?.image = MenuBarIcon.image(updateAvailable: available)
        }
        updates.start()
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
                self.sessionEntries = self.filteredEntries()
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
                let eventAge = self.keyboard.lastEventTime.map { String(Int(max(0, now - $0))) } ?? "none"
                DiagnosticLog.shared.record("health capture=\(self.keyboard.running) owned=\(self.nativeCommandTab.isOverridden) catalogReady=\(self.catalog.ready) querying=\(self.catalog.queryInProgress) failed=\(self.lifecycle.failed) secureInput=\(self.lifecycle.secureInputEnabled) events=\(self.keyboard.eventCount) shortcuts=\(self.keyboard.shortcutCount) lastEventAge=\(eventAge)")
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
            self.deliveryMonitor.reset()
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
        sessionEntries = filteredEntries()
        var current = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // If the front app was just minimized, forward switching should start
        // with a regular app rather than another member of the deferred group.
        if !backwards, preferences.minimizedAppsMode == .atEnd,
           sessionEntries.first(where: { $0.pid == current })?.isMinimized == true,
           sessionEntries.contains(where: { !$0.isMinimized }) { current = nil }
        selection.begin(ids: sessionEntries.map(\.pid), current: current, backwards: backwards)
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
        keyboard.endSession()
        showing = false; preview = false; selection.clear(); sessionEntries = []
        overlay.hide()
    }
    private func reconcilePermissions() {
        let now = ProcessInfo.processInfo.systemUptime
        if lifecycle.updateSecureInput(IsSecureEventInputEnabled(), now: now) {
            DiagnosticLog.shared.record("secure input \(lifecycle.secureInputEnabled ? "enabled; native shortcuts restored" : "disabled; capture settling")")
        }
        let eligible = !relaunching && enabled && accessibility.trusted && catalog.ready && lifecycle.permitsCapture(now: now)
        let wasCapturing = eligible && keyboard.running && nativeCommandTab.isOverridden
        let stalled = deliveryMonitor.observe(active: wasCapturing,
                                              systemKeyDowns: CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown),
                                              deliveredKeyDowns: keyboard.keyDownCount, now: now)
        if stalled { DiagnosticLog.shared.record("capture delivery stalled; hardware key-down activity without tap delivery") }
        if !KeyboardOwnership.reconcile(eligible: eligible, keyboard: keyboard, native: nativeCommandTab,
                                        deliveryStalled: stalled) {
            captureFailed()
        } else if !wasCapturing && eligible && keyboard.running && nativeCommandTab.isOverridden {
            // Arm a new acquisition without carrying input from sleep or pause.
            _ = deliveryMonitor.observe(active: true,
                                        systemKeyDowns: CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown),
                                        deliveredKeyDowns: keyboard.keyDownCount,
                                        now: ProcessInfo.processInfo.systemUptime)
        }
        updateStatus()
    }
    private func updateStatus() {
        let text: String
        if lifecycle.failed { text = "Capture stopped after a failure. ⌘Tab uses macOS. Choose Pause / resume to retry. Logs are available from the menu." }
        else if !enabled { text = "Paused. ⌘Tab uses the macOS switcher." }
        else if lifecycle.secureInputEnabled { text = "Secure keyboard input is active. ⌘Tab uses macOS until it ends." }
        else if !lifecycle.permitsCapture(now: ProcessInfo.processInfo.systemUptime) { text = "Waiting for the session to resume. ⌘Tab uses macOS." }
        else if relaunching { text = "Access granted. Reopening CmdTabo to refresh the permission…" }
        else if !accessibility.trusted { text = "Enable CmdTabo in System Settings to use ⌘Tab. After an update, you may need to remove and add its permission again." }
        else if !catalog.ready { text = "Loading windows…" }
        else if !keyboard.running { text = "Accessibility granted, but ⌘Tab could not be captured. Try quitting and reopening CmdTabo." }
        else { text = "Active. Release ⌘ to switch to the selected app." }
        status.stringValue = text
        let accessGranted = accessibility.trusted || relaunching
        permissionLabel.stringValue = accessGranted ? "Accessibility granted" : "Accessibility required"
        permissionIcon.image = NSImage(systemSymbolName: accessGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                                       accessibilityDescription: permissionLabel.stringValue)
        permissionIcon.contentTintColor = accessGranted ? .systemGreen : .systemOrange
        accessibilityButton.isHidden = accessGranted
        accessibilityButton.isEnabled = !accessGranted
        let screens = NSScreen.screens
        displaysLabel.stringValue = "\(screens.count) display\(screens.count == 1 ? "" : "s") · " + screens.map(\.localizedName).joined(separator: ", ")
        enabledButton.state = enabled ? .on : .off
        scopeButton.state = onlyThisDisplay ? .on : .off
        minimizedMenu.selectItem(at: MinimizedAppsMode.allCases.firstIndex(of: preferences.minimizedAppsMode)!)
        hiddenButton.state = filterOptions.excludeHidden ? .on : .off
        windowlessButton.state = filterOptions.excludeWindowless ? .on : .off
        statusItem.button?.toolTip = versionLabel + " · " + (keyboard.running ? "Active" : "Pending / paused")
    }
    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.image()
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: versionLabel, action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        for (title, action) in [("CmdTabo Settings…", #selector(showSettings)),
                                ("Preview switcher", #selector(showPreview)),
                                ("Pause / resume", #selector(toggleEnabled)),
                                ("Open diagnostic logs", #selector(openLogs))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        updates.addMenuItems(to: menu)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit CmdTabo", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }
    func createSettings() {
        let height = min(690, (NSScreen.main?.visibleFrame.height ?? 770) - 80)
        settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: height),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        settings.title = "CmdTabo"
        settings.minSize = NSSize(width: 520, height: 420)
        settings.isReleasedWhenClosed = false
        func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular,
                   color: NSColor = .secondaryLabelColor) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = .systemFont(ofSize: size, weight: weight)
            field.textColor = color
            return field
        }
        func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = spacing
            for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
            return stack
        }
        func divider() -> NSBox {
            let line = NSBox()
            line.boxType = .separator
            return line
        }
        func card(_ body: NSView) -> NSBox {
            let box = NSBox()
            box.boxType = .custom
            box.titlePosition = .noTitle
            box.cornerRadius = 12
            box.fillColor = .controlBackgroundColor
            box.borderColor = .separatorColor
            box.borderWidth = 0.5
            body.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(body)
            NSLayoutConstraint.activate([
                body.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
                body.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
                body.topAnchor.constraint(equalTo: box.topAnchor, constant: 16),
                body.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -16)
            ])
            return box
        }
        func filterRow(_ button: NSButton, hint: String) -> NSView {
            let detail = label(hint, size: 11)
            let row = NSView()
            button.translatesAutoresizingMaskIntoConstraints = false
            detail.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(button)
            row.addSubview(detail)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                button.topAnchor.constraint(equalTo: row.topAnchor),
                button.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
                detail.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 22),
                detail.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                detail.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 3),
                detail.bottomAnchor.constraint(equalTo: row.bottomAnchor)
            ])
            return row
        }

        let mark = NSImageView()
        mark.image = NSImage(named: "Icon") ?? NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
        mark.setAccessibilityElement(false)
        mark.widthAnchor.constraint(equalToConstant: 42).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 42).isActive = true
        let heading = column([label("CmdTabo", size: 25, weight: .semibold, color: .labelColor),
                              label("Your apps, without the clutter.", size: 13)], spacing: 3)
        let header = NSStackView(views: [mark, heading])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14

        let shortcuts = NSStackView()
        shortcuts.orientation = .horizontal
        shortcuts.spacing = 18
        for (key, action) in [("⌘Tab", "Next"), ("⌘⇧Tab", "Previous"), ("Esc", "Cancel")] {
            let keyLabel = label(key, size: 12, weight: .medium, color: .labelColor)
            let item = NSStackView(views: [keyLabel, label(action, size: 11)])
            item.spacing = 5
            shortcuts.addArrangedSubview(item)
        }
        let shortcutLine = NSView()
        shortcuts.translatesAutoresizingMaskIntoConstraints = false
        shortcutLine.addSubview(shortcuts)
        NSLayoutConstraint.activate([
            shortcuts.leadingAnchor.constraint(equalTo: shortcutLine.leadingAnchor),
            shortcuts.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLine.trailingAnchor),
            shortcuts.topAnchor.constraint(equalTo: shortcutLine.topAnchor),
            shortcuts.bottomAnchor.constraint(equalTo: shortcutLine.bottomAnchor)
        ])

        enabledButton = NSButton(checkboxWithTitle: "Use CmdTabo for ⌘Tab", target: self, action: #selector(toggleEnabled))
        enabledButton.font = .systemFont(ofSize: 13, weight: .medium)
        minimizedMenu = NSPopUpButton(frame: .zero, pullsDown: false)
        minimizedMenu.addItems(withTitles: MinimizedAppsMode.allCases.map(\.title))
        minimizedMenu.target = self
        minimizedMenu.action = #selector(changeMinimizedMode)
        minimizedMenu.setAccessibilityLabel("Minimized apps")
        let minimizedTitle = label("Minimized apps", size: 12, weight: .medium, color: .labelColor)
        minimizedTitle.setContentHuggingPriority(.required, for: .horizontal)
        let minimizedRow = NSStackView(views: [minimizedTitle, NSView(), minimizedMenu])
        minimizedRow.orientation = .horizontal
        let minimized = column([minimizedRow,
                                label("Applies when all windows are minimized. Shown apps get a small window badge.", size: 11)], spacing: 4)
        hiddenButton = NSButton(checkboxWithTitle: "Hidden apps", target: self, action: #selector(toggleHidden))
        windowlessButton = NSButton(checkboxWithTitle: "Apps without windows", target: self, action: #selector(toggleWindowless))
        scopeButton = NSButton(checkboxWithTitle: "Apps only on other displays", target: self, action: #selector(toggleScope))
        let filters = column([
            filterRow(hiddenButton, hint: "Exclude apps hidden with ⌘H."),
            filterRow(windowlessButton, hint: "Exclude background apps until a window opens."),
            filterRow(scopeButton, hint: "Use the display under your pointer when switching.")
        ], spacing: 14)
        let hiddenApps = NSButton(title: "Always hidden apps…", target: self, action: #selector(showHiddenApps))
        hiddenApps.bezelStyle = .rounded
        hiddenAppsSummary.font = .systemFont(ofSize: 11)
        hiddenAppsSummary.textColor = .secondaryLabelColor
        let exclusions = NSStackView(views: [hiddenApps, hiddenAppsSummary, NSView()])
        exclusions.orientation = .horizontal
        exclusions.spacing = 10
        updateHiddenAppsSummary()
        let switcher = card(column([
            enabledButton, divider(),
            label("APP VISIBILITY", size: 10, weight: .semibold), minimized, filters,
            divider(), exclusions
        ], spacing: 14))

        displaysLabel.font = .systemFont(ofSize: 11)
        displaysLabel.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        permissionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        permissionIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        permissionIcon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        permissionIcon.setAccessibilityElement(false)
        let permission = NSStackView(views: [permissionIcon, permissionLabel])
        permission.spacing = 7
        let connection = card(column([permission, status, displaysLabel], spacing: 8))

        accessibilityButton = NSButton(title: "Grant Accessibility", target: self, action: #selector(requestAccessibility))
        accessibilityButton.bezelStyle = .rounded
        let previewButton = NSButton(title: "Preview switcher", target: self, action: #selector(showPreview))
        previewButton.bezelStyle = .rounded
        previewButton.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)
        previewButton.imagePosition = .imageLeading
        previewButton.setAccessibilityLabel("Preview switcher")
        let buttons = NSStackView(views: [accessibilityButton, previewButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "development"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        let privacy = column([label("Version \(version) · build \(build)", size: 10),
                              label("No telemetry · No screen capture", size: 10)], spacing: 3)
        let footer = NSStackView(views: [privacy, NSView(), buttons])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        privacy.setContentHuggingPriority(.required, for: .horizontal)
        buttons.setContentHuggingPriority(.required, for: .horizontal)

        let stack = column([header, shortcutLine, switcher, connection, footer], spacing: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let document = SettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        let content = settings.contentView!
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])
        settings.center()
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
    @objc private func showSettings() {
        cancel(); NSApp.activate(ignoringOtherApps: true); settings.makeKeyAndOrderFront(nil)
        updateHiddenAppsSummary(); updateStatus()
    }
    private func updateHiddenAppsSummary() {
        let count = preferences.excludedApplications.count
        hiddenAppsSummary.stringValue = count == 0 ? "No apps always hidden" : "\(count) app\(count == 1 ? "" : "s") always hidden"
    }
    @objc private func showHiddenApps() {
        cancel()
        if hiddenAppsController == nil {
            let controller = HiddenAppsController(preferences: preferences)
            controller.onChange = { [weak self] in
                self?.cancel()
                self?.updateHiddenAppsSummary()
            }
            hiddenAppsController = controller
        }
        hiddenAppsController?.showWindow(nil)
    }
    @objc private func showPreview() { cancel(); settings.orderOut(nil); catalog.refresh(); begin(backwards: false, preview: true) }
    @objc private func toggleEnabled() {
        if lifecycle.failed { lifecycle.retry(); enabled = true }
        else { enabled.toggle() }
        DiagnosticLog.shared.record("user capture enabled=\(enabled)")
        reconcilePermissions()
    }
    @objc private func openLogs() { NSWorkspace.shared.open(DiagnosticLog.directory) }
    @objc private func toggleScope() { onlyThisDisplay.toggle(); cancel(); updateStatus() }
    @objc private func changeMinimizedMode() {
        guard MinimizedAppsMode.allCases.indices.contains(minimizedMenu.indexOfSelectedItem) else { return }
        preferences.minimizedAppsMode = MinimizedAppsMode.allCases[minimizedMenu.indexOfSelectedItem]
        cancel(); updateStatus()
    }
    @objc private func toggleHidden() {
        UserDefaults.standard.set(!filterOptions.excludeHidden, forKey: "excludeHidden")
        cancel(); updateStatus()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func toggleWindowless() {
        UserDefaults.standard.set(!filterOptions.excludeWindowless, forKey: "excludeWindowless")
        cancel(); updateStatus()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func prepareForUpdate() {
        // Sparkle can ask to relaunch before AppKit starts normal termination.
        // Block queued permission callbacks from acquiring shortcuts again.
        relaunching = true
        nativeCommandTab.restore()
        deliveryMonitor.reset()
        keyboard.stop()
        heartbeat?.invalidate()
        heartbeat = nil
        catalog.suspend()
        for observer in lifecycleObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        lifecycleObservers.removeAll()
    }
    func applicationWillTerminate(_ notification: Notification) {
        prepareForUpdate()
        DiagnosticLog.shared.record("terminated normally")
        DiagnosticLog.shared.flush()
    }
}
