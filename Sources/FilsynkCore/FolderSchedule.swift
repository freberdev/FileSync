import Foundation

/// Pure state machine deciding when a watched folder should be synced.
/// It has no clock and no timers; all time is passed in.
public struct FolderSchedule: Equatable, Sendable {
    private let quiet: TimeInterval
    private let maxWait: TimeInterval
    private let backoff: [TimeInterval]

    public private(set) var isDirty = false
    public private(set) var isSyncing = false
    public private(set) var failureCount = 0
    public private(set) var dirtySince: Date?
    public private(set) var lastOutcome: SyncOutcome?
    public private(set) var lastSuccess: Date?

    private var firstChange: Date?
    private var lastChange: Date?
    private var retryAt: Date?
    private var immediateAt: Date?
    /// `dirtySince` as it was when the running sync started.
    private var dirtySinceAtStart: Date?

    public init(quiet: TimeInterval, maxWait: TimeInterval, backoff: [TimeInterval] = [60, 120, 300, 900]) {
        self.quiet = quiet
        self.maxWait = maxWait
        self.backoff = backoff
    }

    public mutating func changeDetected(at date: Date) {
        isDirty = true
        if dirtySince == nil { dirtySince = date }
        if firstChange == nil { firstChange = date }
        lastChange = date
    }

    public mutating func requestImmediate(at date: Date) {
        isDirty = true
        if dirtySince == nil { dirtySince = date }
        retryAt = nil
        immediateAt = date
    }

    public mutating func syncStarted(at date: Date) {
        isSyncing = true
        isDirty = false
        dirtySinceAtStart = dirtySince
        dirtySince = nil
        firstChange = nil
        lastChange = nil
        retryAt = nil
        immediateAt = nil
    }

    public mutating func syncFinished(_ outcome: SyncOutcome, at date: Date) {
        isSyncing = false
        lastOutcome = outcome
        if outcome == .success {
            failureCount = 0
            lastSuccess = date
        } else {
            failureCount += 1
            isDirty = true
            dirtySince = dirtySinceAtStart ?? dirtySince
            retryAt = date.addingTimeInterval(backoff[min(failureCount, backoff.count) - 1])
        }
        dirtySinceAtStart = nil
    }

    public func nextFireDate() -> Date? {
        guard isDirty, !isSyncing else { return nil }
        if let immediateAt { return immediateAt }
        if let retryAt { return retryAt }
        guard let firstChange, let lastChange else { return nil }
        return min(lastChange.addingTimeInterval(quiet), firstChange.addingTimeInterval(maxWait))
    }
}
