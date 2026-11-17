import Foundation

public enum Notice: Equatable, Sendable {
    case authDenied(folder: String)
    case repeatedFailure(folder: String, message: String)
    case stale(folder: String)

    public var title: String {
        switch self {
        case .authDenied: return L("FileSync: inloggningen nekades")
        case .repeatedFailure: return L("FileSync: synken misslyckas")
        case .stale: return L("FileSync: osynkade ändringar")
        }
    }

    public var body: String {
        switch self {
        case .authDenied:
            return L("Servern accepterar inte nyckeln. Öppna Inställningar och testa anslutningen.")
        case .repeatedFailure(let folder, let message):
            return "\(folder): \(message)"
        case .stale(let folder):
            return L("%@ har inte kunnat säkerhetskopieras på över ett dygn.", folder)
        }
    }
}

/// Decides when a notification is sent. Keeps per-folder memory so that calling
/// `evaluate` repeatedly with an unchanged schedule never repeats a notice.
public struct NoticePolicy: Sendable {
    private struct FolderMemory: Sendable {
        var authNotified = false
        /// `lastSuccess` at the time the auth notice was sent; the notice is rearmed when it changes.
        var successAtAuthNotice: Date?
        /// Set at the first `.failed` outcome of a series of at least three failures; cleared when the series ends.
        var failureSeriesNotified = false
        var lastStaleNotice: Date?
    }

    private static let failureThreshold = 3
    private static let staleAge: TimeInterval = 24 * 3600

    private var memory: [String: FolderMemory] = [:]

    public init() {}

    /// Called after every finished sync and at every periodic check. Without `allowStale` the
    /// notice about changes waiting for more than a day is not given (a disk may be away for long).
    public mutating func evaluate(folder: String, schedule: FolderSchedule, now: Date, allowStale: Bool = true) -> [Notice] {
        var mem = memory[folder] ?? FolderMemory()
        var notices: [Notice] = []

        // A successful sync since the last auth notice rearms it.
        if mem.authNotified, schedule.lastSuccess != mem.successAtAuthNotice {
            mem.authNotified = false
        }
        if schedule.lastOutcome == .authDenied, !mem.authNotified {
            mem.authNotified = true
            mem.successAtAuthNotice = schedule.lastSuccess
            notices.append(.authDenied(folder: folder))
        }

        if schedule.failureCount < Self.failureThreshold {
            mem.failureSeriesNotified = false
        } else if case .failed(let message)? = schedule.lastOutcome,
                  !mem.failureSeriesNotified {
            mem.failureSeriesNotified = true
            notices.append(.repeatedFailure(folder: folder, message: message))
        }

        if allowStale, let since = schedule.dirtySince, now.timeIntervalSince(since) > Self.staleAge,
           mem.lastStaleNotice.map({ now.timeIntervalSince($0) >= Self.staleAge }) ?? true {
            mem.lastStaleNotice = now
            notices.append(.stale(folder: folder))
        }

        memory[folder] = mem
        return notices
    }
}
