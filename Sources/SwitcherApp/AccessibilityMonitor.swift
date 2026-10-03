import AppKit
import ApplicationServices
import Darwin

/// Recheck without prompting. A fresh process distinguishes a stale local TCC
/// answer from permission that is still missing for this signed executable.
final class AccessibilityMonitor {
    private let readTrust: () -> Bool
    private let probe: (@escaping (Bool?) -> Void) -> Void
    private var probing = false
    private var nextProbe: TimeInterval = 0
    private var attemptedRelaunch: Bool
    private(set) var trusted: Bool
    var onChange: ((Bool) -> Void)?
    var onStaleGrant: (() -> Void)?

    init(alreadyRelaunched: Bool = CommandLine.arguments.contains("--accessibility-relaunched"),
         readTrust: @escaping () -> Bool = {
             AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary)
         }, probe: @escaping (@escaping (Bool?) -> Void) -> Void = AccessibilityMonitor.probeTrust) {
        self.readTrust = readTrust
        self.probe = probe
        attemptedRelaunch = alreadyRelaunched
        trusted = readTrust()
    }

    func refresh(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        updateTrust()
        guard !trusted, !probing, !attemptedRelaunch, now >= nextProbe else { return }
        probing = true
        nextProbe = now + 3
        probe { [weak self] freshTrust in
            // All state and delegate callbacks stay on the main run loop.
            DispatchQueue.main.async {
                guard let self else { return }
                self.probing = false
                self.updateTrust()
                guard freshTrust == true, !self.trusted, !self.attemptedRelaunch else { return }
                self.attemptedRelaunch = true
                DiagnosticLog.shared.record("accessibility grant confirmed in fresh process; one relaunch required")
                self.onStaleGrant?()
            }
        }
    }
    private func updateTrust() {
        let value = readTrust()
        guard value != trusted else { return }
        trusted = value
        DiagnosticLog.shared.record("accessibility changed trusted=\(value)")
        onChange?(value)
    }
    static func probeTrust(completion: @escaping (Bool?) -> Void) {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { completion(nil); return }
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let output = directory.appendingPathComponent("permission")
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                guard fm.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    try? fm.removeItem(at: directory)
                    completion(nil); return
                }
            } catch { completion(nil); return }
            defer { try? fm.removeItem(at: directory) }
            let process = Process()
            // LaunchServices gives the helper its own app identity. A directly
            // forked child can inherit its parent's cached TCC attribution.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", "-g", "-j", "-W", "--stdout", output.path,
                                 "--stderr", "/dev/null", bundle.path, "--args", "--accessibility-status"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { completion(nil); return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6) {
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            // A very short-lived helper can finish before open obtains its PID.
            // Accept only the exact helper result, never infer trust from open.
            let data = (try? Data(contentsOf: output)) ?? Data()
            guard data.count <= 32 else { completion(nil); return }
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            completion(text == "trusted" ? true : text == "untrusted" ? false : nil)
        }
    }
}
