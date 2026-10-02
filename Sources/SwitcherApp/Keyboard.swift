import AppKit

final class Keyboard {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowed: Set<Int64> = []
    var isShowing: () -> Bool = { false }
    var canBegin: () -> Bool = { false }
    var onTab: (Bool) -> Void = { _ in }
    var onStep: (Int) -> Void = { _ in }
    var onConfirm: () -> Void = {}
    var shouldConfirmOnCommandRelease: () -> Bool = { true }
    var onCancel: () -> Void = {}
    var running: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() -> Bool {
        if running { return true }
        stop()
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let keyboard = Unmanaged<Keyboard>.fromOpaque(context).takeUnretainedValue()
            return keyboard.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }
    func stop() {
        onCancel()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; swallowed.removeAll()
    }
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            onCancel()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if type == .flagsChanged {
            if isShowing() && shouldConfirmOnCommandRelease() && !event.flags.contains(.maskCommand) { onConfirm() }
            return false
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp { return swallowed.remove(key) != nil }
        guard type == .keyDown else { return false }
        let command = event.flags.contains(.maskCommand)
        if key == 48 && command && !event.flags.contains(.maskControl) && !event.flags.contains(.maskAlternate),
           isShowing() || canBegin() {
            swallowed.insert(key)
            onTab(event.flags.contains(.maskShift))
            return true
        }
        guard isShowing() else { return false }
        if key == 53 { onCancel() }
        else if key == 36 || key == 76 { onConfirm() }
        else if key == 123 { onStep(-1) }
        else if key == 124 { onStep(1) }
        else if key == 125 { onStep(1) }
        else if key == 126 { onStep(-1) }
        else { onCancel(); return false }
        swallowed.insert(key)
        return true
    }
    deinit { stop() }
}
