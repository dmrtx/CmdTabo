import Foundation
import OSLog

/// Small, local, rotating logs. Never record key values, app names or window titles.
final class DiagnosticLog {
    static let shared = DiagnosticLog()
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/CmdTabo", isDirectory: true)
    }
    private let queue = DispatchQueue(label: "local.cmdtabo.diagnostics", qos: .utility)
    private let logger = Logger(subsystem: "local.cmdtabo.switcher", category: "health")
    private let directory: URL
    private let limit: Int
    private let name: String

    init(directory: URL = DiagnosticLog.directory, limit: Int = 1_048_576,
         name: String = CommandLine.arguments.contains("--guard-native-command-tab") ? "guardian" : "health") {
        self.directory = directory
        self.limit = limit
        self.name = name
    }

    func record(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        let date = Date()
        queue.async { [self] in
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                let url = directory.appendingPathComponent("\(name).log")
                let backup = directory.appendingPathComponent("\(name).previous.log")
                let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                if size >= limit {
                    if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
                    try fm.moveItem(at: url, to: backup)
                }
                if !fm.fileExists(atPath: url.path) {
                    guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
                }
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                try file.seekToEnd()
                let stamp = ISO8601DateFormatter().string(from: date)
                try file.write(contentsOf: Data("\(stamp) pid=\(getpid()) \(message)\n".utf8))
            } catch {
                logger.error("Local health log write failed")
            }
        }
    }
    func flush() { queue.sync {} }
}
