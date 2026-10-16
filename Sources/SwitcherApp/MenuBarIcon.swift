import AppKit

enum MenuBarIcon {
    /// A template image lets macOS choose the right color for the menu bar.
    static func image(updateAvailable: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let rear = NSBezierPath(roundedRect: NSRect(x: 1, y: 6, width: 11, height: 9.5), xRadius: 2, yRadius: 2)
            rear.lineWidth = 1.3
            rear.stroke()

            let front = NSBezierPath(roundedRect: NSRect(x: 5, y: 2, width: 12, height: 10.5), xRadius: 2, yRadius: 2)
            front.fill()

            // Cut the Tab arrow out of the front window, including any rear
            // outline beneath it, so the glyph stays clear on either appearance.
            if let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.setBlendMode(.clear)
                let arrow = NSBezierPath()
                arrow.move(to: NSPoint(x: 7.6, y: 7.2))
                arrow.line(to: NSPoint(x: 11.5, y: 7.2))
                arrow.move(to: NSPoint(x: 9.8, y: 9))
                arrow.line(to: NSPoint(x: 11.6, y: 7.2))
                arrow.line(to: NSPoint(x: 9.8, y: 5.4))
                arrow.move(to: NSPoint(x: 14, y: 5.3))
                arrow.line(to: NSPoint(x: 14, y: 9.1))
                arrow.lineWidth = 1.2
                arrow.lineCapStyle = .round
                arrow.lineJoinStyle = .round
                arrow.stroke()
                context.restoreGState()
            }
            if updateAvailable {
                NSBezierPath(ovalIn: NSRect(x: 13.5, y: 13.5, width: 3.5, height: 3.5)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = updateAvailable ? "CmdTabo update available" : "CmdTabo"
        return image
    }
}
