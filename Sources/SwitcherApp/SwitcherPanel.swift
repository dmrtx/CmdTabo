import AppKit

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class AppTile: NSButton {
    let pid: Int32
    var onClick: ((Int32) -> Void)?
    var selected = false {
        didSet {
            guard selected != oldValue else { return }
            updateHighlight()
        }
    }
    init(entry: AppEntry, frame: NSRect) {
        pid = entry.pid
        super.init(frame: frame)
        title = ""
        isBordered = false
        focusRingType = .none
        target = self
        action = #selector(activateTile)
        wantsLayer = true
        layer?.cornerRadius = 14
        let side = frame.width - 12
        let icon = NSImageView(frame: NSRect(x: 6, y: 6, width: side, height: side))
        icon.image = entry.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        addSubview(icon)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(entry.name)
        updateHighlight()
    }
    private func updateHighlight() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = selected ? NSColor.labelColor.withAlphaComponent(0.14).cgColor : NSColor.clear.cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
            layer?.borderWidth = selected ? 1 : 0
        }
        setAccessibilityValue(selected ? "Selected" : "")
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHighlight()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func activateTile() { onClick?(pid) }
    override func accessibilityPerformPress() -> Bool { onClick?(pid); return true }
}

final class SwitcherPanel {
    private let panel: OverlayPanel
    private var displayedIDs: [Int32] = []
    private var displayedNames: [String] = []
    private var displayedFrame = NSRect.zero
    private var tiles: [AppTile] = []
    private var scroll: NSScrollView?
    private var nameLabel: NSTextField?
    var onClick: ((Int32) -> Void)?

    init() {
        panel = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.title = "CmdTabo Switcher"
        panel.setAccessibilityLabel("Application switcher")
    }

    func show(entries: [AppEntry], selected: Int32?, screen: NSScreen?) {
        let available = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let count = max(1, entries.count)
        let maximumWidth = max(140, available.width - 80)
        // One row, like macOS. Keep icons usable even with unusually many apps;
        // the selected icon scrolls into view once the minimum size is reached.
        let cell = min(112, max(52, floor((maximumWidth - 40) / CGFloat(count))))
        let width = entries.isEmpty ? min(280, maximumWidth) : min(maximumWidth, CGFloat(count) * cell + 40)
        let height = cell + 58
        let frame = NSRect(x: available.midX - width / 2, y: available.midY - height / 2, width: width, height: height)
        let ids = entries.map(\.pid)
        let names = entries.map(\.name)
        if ids != displayedIDs || names != displayedNames || frame != displayedFrame || scroll == nil {
            rebuild(entries: entries, cell: cell, frame: frame)
            displayedIDs = ids
            displayedNames = names
            displayedFrame = frame
        }
        // Window polling does not rebuild the panel. A Tab press changes only
        // the two affected highlights, the name, and the scroll position.
        for tile in tiles { tile.selected = tile.pid == selected }
        if let index = entries.firstIndex(where: { $0.pid == selected }), let scroll, let nameLabel {
            let tile = tiles[index]
            tile.scrollToVisible(tile.bounds)
            nameLabel.stringValue = entries[index].name
            let labelWidth = min(230, width - 24)
            let center = scroll.frame.minX + tile.frame.midX - scroll.contentView.bounds.minX
            nameLabel.frame = NSRect(x: min(max(12, center - labelWidth / 2), width - labelWidth - 12),
                                     y: 14, width: labelWidth, height: 20)
        } else {
            nameLabel?.stringValue = entries.isEmpty ? "No available apps" : ""
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func rebuild(entries: [AppEntry], cell: CGFloat, frame: NSRect) {
        panel.setFrame(frame, display: false)
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 22
        background.layer?.masksToBounds = true
        panel.contentView = background
        let row = NSScrollView(frame: NSRect(x: 20, y: 38, width: frame.width - 40, height: cell))
        row.drawsBackground = false
        row.hasHorizontalScroller = false
        row.hasVerticalScroller = false
        row.horizontalScrollElasticity = .none
        row.verticalScrollElasticity = .none
        let document = NSView(frame: NSRect(x: 0, y: 0, width: CGFloat(max(1, entries.count)) * cell, height: cell))
        tiles = entries.enumerated().map { index, entry in
            let tile = AppTile(entry: entry, frame: NSRect(x: CGFloat(index) * cell + 2, y: 2, width: cell - 4, height: cell - 4))
            tile.onClick = { [weak self] in self?.onClick?($0) }
            document.addSubview(tile)
            return tile
        }
        row.documentView = document
        background.addSubview(row)
        scroll = row
        let label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 12, y: 14, width: frame.width - 24, height: 20)
        background.addSubview(label)
        nameLabel = label
    }
    func hide() { panel.orderOut(nil) }
}
