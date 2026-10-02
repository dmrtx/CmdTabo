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
    static func reconcile(eligible: Bool, keyboard: KeyboardCapture, native: NativeShortcutOwnership) {
        guard eligible else {
            native.restore()
            if keyboard.running { keyboard.stop() }
            return
        }
        guard keyboard.running || keyboard.start() else {
            native.restore()
            keyboard.stop()
            return
        }
        if !native.takeOver() {
            native.restore()
            keyboard.stop()
        }
    }
}
