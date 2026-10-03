import Foundation

struct GuardianLease {
    private var lastHeartbeat: TimeInterval
    private var tail = Data()
    let timeout: TimeInterval
    init(now: TimeInterval, timeout: TimeInterval) { lastHeartbeat = now; self.timeout = timeout }
    mutating func receive(_ data: Data, now: TimeInterval) -> Bool {
        lastHeartbeat = now
        tail.append(data)
        // Cancellation can be split across reads or follow several heartbeats.
        if tail.range(of: Data("cancel".utf8)) != nil { return true }
        tail = Data(tail.suffix(5))
        return false
    }
    func expired(now: TimeInterval) -> Bool { now - lastHeartbeat >= timeout }
}
