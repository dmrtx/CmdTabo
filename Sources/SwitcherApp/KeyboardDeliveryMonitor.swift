import Foundation

/// Detect missing delivery from aggregate counters only. Idle is not failure.
struct KeyboardDeliveryMonitor {
    private struct Sample {
        let system: UInt32
        let delivered: UInt64
        let time: TimeInterval
    }
    private var previous: Sample?
    private var missingSince: TimeInterval?
    private let timeout: TimeInterval
    private let maximumSampleGap: TimeInterval

    init(timeout: TimeInterval = 2, maximumSampleGap: TimeInterval = 1) {
        self.timeout = timeout
        self.maximumSampleGap = maximumSampleGap
    }

    mutating func reset() { previous = nil; missingSince = nil }

    mutating func observe(active: Bool, systemKeyDowns readSystemKeyDowns: @autoclosure () -> UInt32, deliveredKeyDowns: UInt64,
                          now: TimeInterval) -> Bool {
        guard active else { reset(); return false }
        let systemKeyDowns = readSystemKeyDowns()
        let current = Sample(system: systemKeyDowns, delivered: deliveredKeyDowns, time: now)
        defer { self.previous = current }
        guard let previous else { return false }
        // Give queued callbacks a fresh chance after a delayed main-loop sample.
        // Counter wrap/reset and a clock reset also invalidate earlier evidence.
        guard now >= previous.time, now - previous.time <= maximumSampleGap,
              systemKeyDowns >= previous.system, deliveredKeyDowns >= previous.delivered else {
            missingSince = nil
            return false
        }
        if deliveredKeyDowns != previous.delivered {
            // Only progress matters: hardware counters omit autorepeat, while
            // a received repeat still proves that key-down delivery is alive.
            missingSince = nil
        } else if systemKeyDowns != previous.system && missingSince == nil {
            missingSince = now
        }
        return missingSince.map { now - $0 >= timeout } ?? false
    }
}
