import Foundation

/// Disable only the native app switcher while our event tap is alive.
/// A separate process restores it if this app crashes or is force-quit.
final class NativeCommandTab {
    private typealias Get = @convention(c) (Int32) -> Bool
    private typealias Set = @convention(c) (Int32, Bool) -> Int32
    private let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private var saved: [Bool]?
    private var guardian: Process?
    private var guardianInput: FileHandle?
    var onGuardianFailure: (() -> Void)?
    var isOverridden: Bool { saved != nil }

    private func symbol<T>(_ name: String, as: T.Type) -> T? {
        guard let handle, let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }
    func states() -> [Bool]? {
        guard let get = symbol("CGSIsSymbolicHotKeyEnabled", as: Get.self) else { return nil }
        return [get(1), get(2)]
    }
    @discardableResult private func apply(_ states: [Bool]) -> Bool {
        guard states.count == 2, let set = symbol("CGSSetSymbolicHotKeyEnabled", as: Set.self) else { return false }
        // Apply both even if the first call fails, so restoration is complete.
        let first = set(1, states[0])
        let second = set(2, states[1])
        return first == 0 && second == 0 && self.states() == states
    }
    func takeOver() -> Bool {
        if isOverridden { return true }
        guard let previous = states(), let executable = Bundle.main.executableURL else { return false }
        let pipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--guard-native-command-tab", previous[0] ? "1" : "0", previous[1] ? "1" : "0"]
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                guard let self, self.guardian?.processIdentifier == ended.processIdentifier, self.isOverridden else { return }
                self.restore()
                self.onGuardianFailure?()
            }
        }
        do { try process.run() } catch { return false }
        pipe.fileHandleForReading.closeFile()
        guardian = process
        guardianInput = pipe.fileHandleForWriting
        saved = previous
        guard apply([false, false]) else { restore(); return false }
        NSLog("CmdTabo native switcher disabled; restore guard pid=%d", process.processIdentifier)
        return true
    }
    func restore() {
        guard let saved else { return }
        let restored = apply(saved)
        self.saved = nil
        // On normal restoration the child must not race a new takeover.
        // With no cancellation message, EOF means the parent crashed.
        if restored { try? guardianInput?.write(contentsOf: Data("cancel".utf8)) }
        try? guardianInput?.close()
        guardianInput = nil
        guardian = nil
        NSLog("CmdTabo native switcher restored=%@", restored.description)
    }
    static func runGuardian(previous: [Bool]) {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        if input != Data("cancel".utf8) { _ = NativeCommandTab().apply(previous) }
    }
    deinit { restore() }
}
