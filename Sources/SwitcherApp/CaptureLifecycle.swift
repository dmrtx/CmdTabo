import Foundation

/// Independent suspension reasons prevent a screen wake from bypassing a locked session.
struct CaptureLifecycle {
    enum Suspension: String, Hashable { case systemSleep, displaySleep, inactiveSession }
    private(set) var suspensions: Set<Suspension> = []
    private(set) var failed = false
    private(set) var secureInputEnabled = false
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
    /// An enabled event tap may receive no keyboard events during Secure Input.
    /// Release native shortcuts until the system allows capture again.
    @discardableResult mutating func updateSecureInput(_ enabled: Bool, now: TimeInterval) -> Bool {
        guard enabled != secureInputEnabled else { return false }
        secureInputEnabled = enabled
        if enabled { onRelease?() }
        else { resumeAfter = max(resumeAfter, now + 2) }
        return true
    }
    func permitsCapture(now: TimeInterval) -> Bool {
        suspensions.isEmpty && !failed && !secureInputEnabled && now >= resumeAfter
    }
}
