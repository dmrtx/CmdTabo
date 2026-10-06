import AppKit

final class Keyboard: KeyboardCapture {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowed: Set<Int64> = []
    private var pendingSession = false
    private var queuedSession: Bool?
    private var actionID = 0
    private var generation = 0
    private var deliveringAction = false
    private var failed = false
    private var failurePending = false
    private(set) var eventCount = 0
    private(set) var shortcutCount = 0
    private(set) var lastEventTime: TimeInterval?
    var isShowing: () -> Bool = { false }
    var canBegin: () -> Bool = { false }
    var onTab: (Bool) -> Void = { _ in }
    var onStep: (Int) -> Void = { _ in }
    var onConfirm: () -> Void = {}
    var shouldConfirmOnCommandRelease: () -> Bool = { true }
    var onCancel: () -> Void = {}
    var onFailure: () -> Void = {}
    var running: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() -> Bool {
        // A queued failure must reach the coordinator before any new acquisition.
        guard !failurePending else { return false }
        if running { return true }
        stop()
        failed = false
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let keyboard = Unmanaged<Keyboard>.fromOpaque(context).takeUnretainedValue()
            return keyboard.handle(type: type, event: event, deferred: true) ? nil : Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            DiagnosticLog.shared.record("capture creation failed")
            return false
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        DiagnosticLog.shared.record("capture started")
        return running
    }
    func stop() {
        // Release the event stream before ordering out the panel.
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if tap != nil { DiagnosticLog.shared.record("capture stopped") }
        discardSession()
        tap = nil; source = nil; swallowed.removeAll()
        onCancel()
    }
    func endSession() {
        // Keyboard-driven closes already have ordered session transitions.
        // Keep a subsequent Tab queued after that close; external closes must
        // instead discard all pending selector actions.
        if !deliveringAction { discardSession() }
    }
    private func discardSession() {
        generation += 1
        pendingSession = false
        queuedSession = nil
        // Preserve key-up pairing for key-down events already consumed.
    }
    private func deliver(deferred: Bool, session: Bool? = nil, _ action: @escaping () -> Void) {
        if !deferred { perform(action); return }
        if let session { queuedSession = session }
        actionID += 1
        let queuedAction = actionID
        let current = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == current else { return }
            self.perform(action)
            if self.actionID == queuedAction { self.queuedSession = nil }
        }
    }
    private func perform(_ action: () -> Void) {
        let previous = deliveringAction
        deliveringAction = true
        defer { deliveringAction = previous }
        action()
    }
    func handle(type: CGEventType, event: CGEvent, deferred: Bool = false) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Return to WindowServer before touching windows or shortcuts.
            // Never re-enable a tap that macOS disabled for safety.
            guard !failed else { return false }
            failed = true
            failurePending = true
            discardSession()
            swallowed.removeAll()
            DiagnosticLog.shared.record(type == .tapDisabledByTimeout ? "capture disabled: timeout" : "capture disabled: user input")
            // Failure delivery is independent of cancellable selector actions.
            let notify = { [weak self] in
                guard let self else { return }
                self.onCancel()
                self.onFailure()
                self.failurePending = false
            }
            if deferred { DispatchQueue.main.async(execute: notify) }
            else { notify() }
            return false
        }
        guard !failed else { return false }
        if type == .keyDown || type == .keyUp || type == .flagsChanged {
            eventCount += 1
            lastEventTime = ProcessInfo.processInfo.systemUptime
        }
        let sessionShowing = queuedSession ?? (pendingSession || isShowing())
        if type == .flagsChanged {
            if sessionShowing && (pendingSession || shouldConfirmOnCommandRelease()) && !event.flags.contains(.maskCommand) {
                pendingSession = false
                deliver(deferred: deferred, session: false, onConfirm)
            }
            return false
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp { return swallowed.remove(key) != nil }
        guard type == .keyDown else { return false }
        let command = event.flags.contains(.maskCommand)
        if key == 48 && command && !event.flags.contains(.maskControl) && !event.flags.contains(.maskAlternate),
           sessionShowing || canBegin() {
            shortcutCount += 1
            swallowed.insert(key)
            pendingSession = true
            let backwards = event.flags.contains(.maskShift)
            deliver(deferred: deferred, session: true) { [weak self] in
                self?.onTab(backwards)
                // Once delivered, visibility is owned by the delegate, even if
                // opening was rejected or the panel is subsequently closed.
                self?.pendingSession = false
            }
            return true
        }
        guard sessionShowing else { return false }
        if key == 53 { pendingSession = false; deliver(deferred: deferred, session: false, onCancel) }
        else if key == 36 || key == 76 { pendingSession = false; deliver(deferred: deferred, session: false, onConfirm) }
        else if key == 123 || key == 126 { deliver(deferred: deferred) { [weak self] in self?.onStep(-1) } }
        else if key == 124 || key == 125 { deliver(deferred: deferred) { [weak self] in self?.onStep(1) } }
        else { pendingSession = false; deliver(deferred: deferred, session: false, onCancel); return false }
        swallowed.insert(key)
        return true
    }
    deinit { stop() }
}
