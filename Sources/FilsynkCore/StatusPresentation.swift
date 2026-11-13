import Foundation

public enum FolderState: Equatable, Sendable {
    case notConfigured, synced, pending, syncing, waitingForServer, error(String)
}

public struct FolderStatus: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var state: FolderState
    public var lastSuccess: Date?

    public init(path: String, state: FolderState, lastSuccess: Date?) {
        self.path = path
        self.state = state
        self.lastSuccess = lastSuccess
    }
}

public enum OverallState: Equatable, Sendable {
    case notConfigured, paused, error(String), syncing, waitingForServer, pending, synced
}

public struct EngineStatus: Equatable, Sendable {
    public var folders: [FolderStatus]
    public var isPaused: Bool
    public var configError: String?

    public init(folders: [FolderStatus], isPaused: Bool, configError: String?) {
        self.folders = folders
        self.isPaused = isPaused
        self.configError = configError
    }

    public static let empty = EngineStatus(folders: [], isPaused: false, configError: nil)

    public var overall: OverallState {
        if let configError { return .error(configError) }
        if folders.allSatisfy({ $0.state == .notConfigured }) { return .notConfigured }
        if isPaused { return .paused }
        for folder in folders {
            if case .error(let message) = folder.state { return .error(message) }
        }
        if folders.contains(where: { $0.state == .syncing }) { return .syncing }
        if folders.contains(where: { $0.state == .waitingForServer }) { return .waitingForServer }
        if folders.contains(where: { $0.state == .pending }) { return .pending }
        return .synced
    }
}

public enum StatusPresentation {
    public static func folderState(ready: Bool, schedule: FolderSchedule) -> FolderState {
        guard ready else { return .notConfigured }
        if schedule.isSyncing { return .syncing }
        switch schedule.lastOutcome {
        case .unreachable?:
            return .waitingForServer
        case .authDenied?, .failed?:
            return .error(schedule.lastOutcome?.message ?? "")
        case .success?, nil:
            break
        }
        return schedule.isDirty ? .pending : .synced
    }

    public static func headline(_ status: EngineStatus, timeZone: TimeZone) -> String {
        switch status.overall {
        case .synced:
            guard let latest = status.folders.compactMap(\.lastSuccess).max() else { return "Allt synkat" }
            return "Allt synkat · \(clockTime(latest, timeZone: timeZone))"
        case .syncing: return "Synkar…"
        case .pending: return "Ändringar väntar"
        case .waitingForServer: return "Väntar på servern"
        case .error(let message): return "Fel: \(message)"
        case .paused: return "Pausad"
        case .notConfigured: return "Inte inställd"
        }
    }

    public static func symbolName(_ overall: OverallState) -> String {
        switch overall {
        case .synced: return "checkmark.circle"
        case .syncing, .pending: return "arrow.triangle.2.circlepath"
        case .waitingForServer: return "clock.arrow.circlepath"
        case .error: return "exclamationmark.triangle"
        case .paused: return "pause.circle"
        case .notConfigured: return "gearshape"
        }
    }

    /// "/Users/x/Sync" becomes "~/Sync" when `home` is "/Users/x".
    public static func displayPath(_ path: String, home: String) -> String {
        if path == home { return "~" }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        if path.hasPrefix(prefix) { return "~/" + path.dropFirst(prefix.count) }
        return path
    }

    /// The state column of a folder's menu row.
    public static func folderLabel(_ folder: FolderStatus, timeZone: TimeZone) -> String {
        switch folder.state {
        case .synced:
            guard let last = folder.lastSuccess else { return "✓" }
            return "✓ \(clockTime(last, timeZone: timeZone))"
        case .syncing: return "Synkar…"
        case .pending: return "Väntar"
        case .waitingForServer: return "Väntar på servern"
        case .error: return "Fel"
        case .notConfigured: return "Inte inställd"
        }
    }

    private static func clockTime(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
