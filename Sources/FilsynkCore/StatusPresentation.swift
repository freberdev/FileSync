import Foundation

public enum FolderState: Equatable, Sendable {
    case notConfigured, synced, pending, syncing, waitingForServer, notConnected, error(String)
}

/// The state of one destination of a folder.
public struct FolderStatus: Equatable, Sendable, Identifiable {
    public var id: String { path + "|" + destinationID }
    public var path: String
    public var destinationID: String
    /// Nil for a folder without destinations.
    public var destination: Destination?
    public var state: FolderState
    public var lastSuccess: Date?

    public init(path: String, destination: Destination?, state: FolderState, lastSuccess: Date?) {
        self.path = path
        self.destinationID = destination?.id ?? ""
        self.destination = destination
        self.state = state
        self.lastSuccess = lastSuccess
    }
}

public enum OverallState: Equatable, Sendable {
    case notConfigured, paused, notConnected, error(String), syncing, waitingForServer, pending, synced
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
        // A folder that is not set up is not backed up, whatever the others do.
        if folders.isEmpty || folders.contains(where: { $0.state == .notConfigured }) { return .notConfigured }
        if isPaused { return .paused }
        // A disk that is not connected counts only when nothing else takes part.
        let connected = connectedFolders
        if connected.isEmpty { return .notConnected }
        for folder in connected {
            if case .error(let message) = folder.state { return .error(message) }
        }
        if connected.contains(where: { $0.state == .syncing }) { return .syncing }
        if connected.contains(where: { $0.state == .waitingForServer }) { return .waitingForServer }
        if connected.contains(where: { $0.state == .pending }) { return .pending }
        return .synced
    }

    /// The rows whose destination can be reached now.
    var connectedFolders: [FolderStatus] { folders.filter { $0.state != .notConnected } }
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
            guard let latest = status.connectedFolders.compactMap(\.lastSuccess).max() else { return L("Allt synkat") }
            return L("Allt synkat · %@", clockTime(latest, timeZone: timeZone))
        case .syncing: return L("Synkar…")
        case .pending: return L("Ändringar väntar")
        case .waitingForServer: return L("Väntar på servern")
        case .error(let message): return L("Fel: %@", message)
        case .paused: return L("Pausad")
        case .notConfigured: return L("Inte inställd")
        case .notConnected: return L("Disken är inte inkopplad")
        }
    }

    public static func symbolName(_ overall: OverallState) -> String {
        switch overall {
        case .synced: return "checkmark.circle"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .pending: return "hourglass"
        case .waitingForServer: return "clock.arrow.circlepath"
        case .error: return "exclamationmark.triangle"
        case .paused: return "pause.circle"
        case .notConfigured: return "gearshape"
        case .notConnected: return "externaldrive.badge.xmark"
        }
    }

    /// "/Users/x/Sync" becomes "~/Sync" when `home` is "/Users/x".
    public static func displayPath(_ path: String, home: String) -> String {
        if path == home { return "~" }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        if path.hasPrefix(prefix) { return "~/" + path.dropFirst(prefix.count) }
        return path
    }

    /// "Server: ~/Filsynk/A" with the server's home shown as "~", or "HDD: Filsynk/A".
    public static func destinationLabel(_ destination: Destination, serverHome: String) -> String {
        switch destination {
        case .server(let path):
            return L("Server: %@", serverHome.isEmpty ? path : displayPath(path, home: serverHome))
        case .disk(let location):
            return "\(location.volumeName): \(location.path)"
        }
    }

    /// The state column of a folder's menu row.
    public static func folderLabel(_ folder: FolderStatus, timeZone: TimeZone) -> String {
        switch folder.state {
        case .synced:
            guard let last = folder.lastSuccess else { return "✓" }
            return "✓ \(clockTime(last, timeZone: timeZone))"
        case .syncing: return L("Synkar…")
        case .pending: return L("Väntar")
        case .waitingForServer: return L("Väntar på servern")
        case .error: return L("Fel")
        case .notConfigured: return L("Inte inställd")
        case .notConnected:
            guard let last = folder.lastSuccess else { return L("Inte inkopplad · aldrig synkad") }
            return L("Inte inkopplad · senast %@", day(last, timeZone: timeZone))
        }
    }

    private static func day(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func clockTime(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
