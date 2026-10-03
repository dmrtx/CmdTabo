protocol KeyboardCapture: AnyObject {
    var running: Bool { get }
    func start() -> Bool
    func stop()
}

protocol NativeShortcutOwnership: AnyObject {
    func takeOver() -> Bool
    func restore()
}

enum KeyboardOwnership {
    @discardableResult static func reconcile(eligible: Bool, keyboard: KeyboardCapture, native: NativeShortcutOwnership) -> Bool {
        guard eligible else {
            native.restore()
            if keyboard.running { keyboard.stop() }
            return true
        }
        guard keyboard.running || keyboard.start() else {
            native.restore()
            keyboard.stop()
            return false
        }
        if !native.takeOver() {
            native.restore()
            keyboard.stop()
            return false
        }
        return true
    }
}
