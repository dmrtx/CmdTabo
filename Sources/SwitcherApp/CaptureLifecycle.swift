import Foundation

/// Independent suspension reasons prevent a screen wake from bypassing a locked session.
struct CaptureLifecycle {
    enum Suspension: String, Hashable { case systemSleep, displaySleep, inactiveSession }
    private(set) var suspensions: Set<Suspension> = []
    private(set) var failed = false
    private(set) var resumeAfter: TimeInterval = 0
    var onRelease: (() -> Void)?

    mutating func suspend(_ reason: Suspension) {
        suspensions.insert(reason)
        onRelease?()
    }
    mutating func resume(_ reason: Suspension, now: TimeInterval) {
        suspensions.remove(reason)
        resumeAfter = now + 2
    }
    mutating func fail() {
        failed = true
        onRelease?()
    }
    mutating func retry() { failed = false }
    func permitsCapture(now: TimeInterval) -> Bool {
        suspensions.isEmpty && !failed && now >= resumeAfter
    }
}
