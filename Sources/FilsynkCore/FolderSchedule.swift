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
        precondition(!backoff.isEmpty, "backoff needs at least one step")
        self.quiet = quiet
        self.maxWait = maxWait
        self.backoff = backoff
    }

    /// The same state with new timing; used when the settings change but the folder does not.
    public func retimed(quiet: TimeInterval, maxWait: TimeInterval, backoff: [TimeInterval]) -> FolderSchedule {
        var copy = FolderSchedule(quiet: quiet, maxWait: maxWait, backoff: backoff)
        copy.isDirty = isDirty
        copy.isSyncing = isSyncing
        copy.failureCount = failureCount
        copy.dirtySince = dirtySince
        copy.lastOutcome = lastOutcome
        copy.lastSuccess = lastSuccess
        copy.firstChange = firstChange
        copy.lastChange = lastChange
        copy.retryAt = retryAt
        copy.immediateAt = immediateAt
        copy.dirtySinceAtStart = dirtySinceAtStart
        return copy
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
            // A denied login waits the longest step: repeated refused logins can get the Mac banned.
            let step = outcome == .authDenied ? backoff.count : min(failureCount, backoff.count)
            retryAt = date.addingTimeInterval(backoff[step - 1])
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
