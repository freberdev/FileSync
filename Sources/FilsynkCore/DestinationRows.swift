import Foundation

/// One line of the folder table in the settings window: a folder and one of its destinations.
public struct DestinationRow: Equatable, Identifiable, Sendable {
    /// The same id as the status row of the destination, so a selection survives status updates.
    public var id: String { folderPath + "|" + destinationID }
    public var folderPath: String
    public var destinationID: String
    public var local: String
    public var destination: String
    public var state: String
}

public enum DestinationRows {
    /// One row per destination, in the order of the folders and their destinations.
    public static func rows(config: Config, status: EngineStatus, home: String, timeZone: TimeZone) -> [DestinationRow] {
        var byID: [String: FolderStatus] = [:]
        for row in status.folders { byID[row.id] = row }
        var rows: [DestinationRow] = []
        for folder in config.folders {
            for destination in folder.destinations {
                let state: String
                if let current = byID[folder.path + "|" + destination.id] {
                    state = StatusPresentation.folderLabel(current, timeZone: timeZone)
                } else {
                    state = destination.isReady ? L("Väntar") : L("Inte inställd")
                }
                rows.append(DestinationRow(
                    folderPath: folder.path,
                    destinationID: destination.id,
                    local: StatusPresentation.displayPath(folder.path, home: home),
                    destination: StatusPresentation.destinationLabel(destination, serverHome: config.verifiedHome),
                    state: state))
            }
        }
        return rows
    }

    /// "~/Sync → Server: ~/Sync   ✓ 14:32"; a folder without a destination shows only its path.
    public static func menuLine(_ row: FolderStatus, home: String, serverHome: String, timeZone: TimeZone) -> String {
        var name = StatusPresentation.displayPath(row.path, home: home)
        if let destination = row.destination {
            name += " → " + StatusPresentation.destinationLabel(destination, serverHome: serverHome)
        }
        return "\(name)   \(StatusPresentation.folderLabel(row, timeZone: timeZone))"
    }

    /// "<diskens namn>: <sökväg på disken>" for a folder picked on a disk, "/" for the disk's root.
    /// A path outside every external volume is shown as it is.
    public static func pickedDiskText(pickedPath: String, volumes: [VolumeInfo]) -> String {
        let resolved = (pickedPath as NSString).resolvingSymlinksInPath
        guard let volume = VolumeLookup.volume(containing: resolved, in: volumes), !volume.isSystem,
              let relative = VolumeLookup.relativePath(of: resolved, on: volume) else { return pickedPath }
        return "\(volume.name): \(relative.isEmpty ? "/" : relative)"
    }
}
