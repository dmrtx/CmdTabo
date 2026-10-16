import AppKit
import UniformTypeIdentifiers

private final class HiddenAppCell: NSTableCellView {
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingMiddle
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        for view in [icon, name, detail] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class HiddenAppsController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let preferences: AppPreferences
    private var apps: [ExcludedApplication] = []
    private let table = NSTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "No apps hidden.\nAdd an app to always leave it out of the switcher.")
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    var onChange: (() -> Void)?

    init(preferences: AppPreferences) {
        self.preferences = preferences
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 370),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Always hidden apps"
        window.minSize = NSSize(width: 420, height: 300)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let content = window.contentView!
        let title = NSTextField(labelWithString: "Always hide these apps")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: "They stay out of ⌘Tab and Preview, even when they have visible windows. Other filters still apply to the remaining apps.")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        table.headerView = nil
        table.rowHeight = 44
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.delegate = self
        table.dataSource = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("application"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Apps hidden from the switcher")
        scroll.documentView = table
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        let list = NSView()
        for view in [scroll, emptyLabel] { view.translatesAutoresizingMaskIntoConstraints = false; list.addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: list.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: list.topAnchor), scroll.bottomAnchor.constraint(equalTo: list.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: list.centerXAnchor), emptyLabel.centerYAnchor.constraint(equalTo: list.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: list.widthAnchor, constant: -32)
        ])
        let add = NSButton(title: "Add app…", target: self, action: #selector(addApp))
        add.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeApps)
        removeButton.bezelStyle = .rounded
        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [add, removeButton, NSView(), done])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        for view in [title, hint, list, buttons] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22), title.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            hint.leadingAnchor.constraint(equalTo: title.leadingAnchor), hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            list.leadingAnchor.constraint(equalTo: title.leadingAnchor), list.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            list.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 16), list.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -14),
            buttons.leadingAnchor.constraint(equalTo: title.leadingAnchor), buttons.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
        window.center()
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        reload()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }
    private func reload() {
        apps = preferences.excludedApplications
        table.reloadData()
        emptyLabel.isHidden = !apps.isEmpty
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }
    func numberOfRows(in tableView: NSTableView) -> Int { apps.count }
    func tableViewSelectionDidChange(_ notification: Notification) { removeButton.isEnabled = !table.selectedRowIndexes.isEmpty }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("hiddenApp")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? HiddenAppCell ?? HiddenAppCell()
        cell.identifier = identifier
        let app = apps[row]
        cell.icon.image = NSWorkspace.shared.icon(forFile: app.path)
        cell.name.stringValue = app.name
        cell.detail.stringValue = app.bundleIdentifier ?? app.path
        cell.toolTip = app.path
        return cell
    }
    @objc private func addApp() {
        guard let window else { return }
        let picker = NSOpenPanel()
        picker.title = "Choose apps to hide"
        picker.prompt = "Hide apps"
        picker.allowedContentTypes = [.applicationBundle]
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        picker.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        picker.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            self.preferences.addExcludedApplications(picker.urls.compactMap { ExcludedApplication(url: $0) })
            self.reload()
            self.onChange?()
        }
    }
    @objc private func removeApps() {
        let keys = Set(table.selectedRowIndexes.compactMap { apps.indices.contains($0) ? apps[$0].key : nil })
        preferences.removeExcludedApplications(keys: keys)
        table.deselectAll(nil)
        reload()
        onChange?()
    }
    @objc private func done() { close() }
}
