import Foundation
import Darwin

/// Disable only the native app switcher while our event tap is alive.
/// A separate process restores it if this app crashes or is force-quit.
final class NativeCommandTab: NativeShortcutOwnership {
    private typealias Get = @convention(c) (Int32) -> Bool
    private typealias Set = @convention(c) (Int32, Bool) -> Int32
    private let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private var saved: [Bool]?
    private var guardian: Process?
    private var guardianInput: FileHandle?
    private var ownership: FileHandle?
    private let lockURL: URL
    private let readStates: (() -> [Bool]?)?
    private let writeStates: (([Bool]) -> Bool)?
    private let makeGuardian: ([Bool]) -> Process?
    var onGuardianFailure: (() -> Void)?
    var isOverridden: Bool { saved != nil }

    private static var defaultLockURL: URL {
        // Use the OS-assigned per-user directory, independent of a launcher's
        // TMPDIR override, so every instance coordinates on the same inode.
        let count = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        if count > 0 {
            var path = [CChar](repeating: 0, count: count)
            if confstr(_CS_DARWIN_USER_TEMP_DIR, &path, count) > 0 {
                return URL(fileURLWithPath: String(cString: path)).appendingPathComponent("CmdTabo-native-command-tab.lock")
            }
        }
        return URL(fileURLWithPath: "/tmp/CmdTabo-native-command-tab-\(getuid()).lock")
    }

    init(lockURL: URL? = nil,
         readStates: (() -> [Bool]?)? = nil, writeStates: (([Bool]) -> Bool)? = nil,
         makeGuardian: @escaping ([Bool]) -> Process? = { previous in
             guard let executable = Bundle.main.executableURL else { return nil }
             let process = Process()
             process.executableURL = executable
             process.arguments = ["--guard-native-command-tab", previous[0] ? "1" : "0", previous[1] ? "1" : "0"]
             return process
         }) {
        self.lockURL = lockURL ?? Self.defaultLockURL
        self.readStates = readStates
        self.writeStates = writeStates
        self.makeGuardian = makeGuardian
    }

    private func acquireOwnership() -> Bool {
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        ownership = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        // Keep the same inode across releases; unlinking a locked file lets a
        // contender create another inode and acquire a second, unrelated lock.
        return true
    }

    private func releaseOwnership() {
        try? ownership?.close()
        ownership = nil
    }

    private func symbol<T>(_ name: String, as: T.Type) -> T? {
        guard let handle, let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }
    func states() -> [Bool]? {
        if let readStates { return readStates() }
        guard let get = symbol("CGSIsSymbolicHotKeyEnabled", as: Get.self) else { return nil }
        return [get(1), get(2)]
    }
    @discardableResult private func apply(_ states: [Bool]) -> Bool {
        if let writeStates { return writeStates(states) }
        guard states.count == 2, let set = symbol("CGSSetSymbolicHotKeyEnabled", as: Set.self) else { return false }
        // Apply both even if the first call fails, so restoration is complete.
        let first = set(1, states[0])
        let second = set(2, states[1])
        return first == 0 && second == 0 && self.states() == states
    }
    func takeOver() -> Bool {
        if isOverridden { return true }
        guard acquireOwnership() else { return false }
        guard let previous = states(), previous.count == 2, let process = makeGuardian(previous) else {
            releaseOwnership()
            return false
        }
        let pipe = Pipe()
        // A guardian that has already exited makes cancellation writes fail
        // with EPIPE. Suppress SIGPIPE on this descriptor so we can restore
        // safely instead of terminating the main app during recovery.
        guard fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            releaseOwnership()
            return false
        }
        // Never let a stuck guardian fill the pipe and block the main thread.
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else {
            releaseOwnership()
            return false
        }
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        // dup2 inherits the same flock through stderr. The guardian keeps it
        // until restoration completes, including after SIGKILL of the parent.
        process.standardError = ownership
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                guard let self, self.guardian?.processIdentifier == ended.processIdentifier, self.isOverridden else { return }
                self.restore()
                self.onGuardianFailure?()
            }
        }
        do { try process.run() } catch {
            releaseOwnership()
            return false
        }
        pipe.fileHandleForReading.closeFile()
        guardian = process
        guardianInput = pipe.fileHandleForWriting
        saved = previous
        guard apply([false, false]) else { restore(); return false }
        DiagnosticLog.shared.record("native switcher disabled guardian=\(process.processIdentifier)")
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
        // Closing our descriptor does not unlock the guardian's inherited one.
        releaseOwnership()
        DiagnosticLog.shared.record("native switcher restored=\(restored)")
    }
    @discardableResult func heartbeat() -> Bool {
        guard isOverridden, let guardianInput else { return true }
        do { try guardianInput.write(contentsOf: Data(".".utf8)); return true }
        catch { DiagnosticLog.shared.record("guardian heartbeat failed"); return false }
    }
    static func runGuardian(previous: [Bool]) {
        monitorGuardian(input: STDIN_FILENO, parent: getppid(), restore: {
            let restored = NativeCommandTab().apply(previous)
            DiagnosticLog.shared.record("guardian restored native shortcuts=\(restored)")
            DiagnosticLog.shared.flush()
        })
    }
    /// Runs in the child, independently of AppKit and the parent's run loop.
    static func monitorGuardian(input: Int32, parent: pid_t, timeout: TimeInterval = 15,
                                restore: () -> Void) {
        // This clock excludes sleep, so closing the laptop cannot exhaust the lease.
        func uptime() -> TimeInterval { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000 }
        var lease = GuardianLease(now: uptime(), timeout: timeout)
        var descriptor = pollfd(fd: input, events: Int16(POLLIN | POLLHUP), revents: 0)
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let result = poll(&descriptor, 1, 250)
            if result < 0 {
                if errno == EINTR { continue }
                restore(); return
            }
            if result > 0 {
                let count = read(input, &buffer, buffer.count)
                if count <= 0 { restore(); return }
                if lease.receive(Data(buffer.prefix(count)), now: uptime()) { return }
            }
            if lease.expired(now: uptime()) {
                DiagnosticLog.shared.record("guardian main-thread heartbeat timeout; stopping capture owner")
                // Only terminate our still-current parent, never an unrelated PID.
                // Its death removes the tap before we restore the native shortcuts.
                if parent > 1 && getppid() == parent { _ = kill(parent, SIGKILL) }
                restore(); return
            }
        }
    }
    deinit { restore() }
}
