import Foundation
import Testing
@testable import FilsynkCore

@Suite struct DestinationRowsTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let home = "/Users/anna"
    private let disk = DiskLocation(volumeUUID: "AAAA-1111", volumeName: "Backupdisk", path: "Filsynk/Sync")

    private func config() -> Config {
        var config = Config.initial(home: home)
        config.verifiedHome = "/home/anna"
        config.folders = [
            FolderConfig(path: "/Users/anna/Sync", destinations: [.server(path: "/home/anna/Sync"), .disk(disk)]),
            FolderConfig(path: "/Users/anna/Foto", destinations: [.server(path: "~/Foto")]),
        ]
        return config
    }

    private func row(_ path: String, _ destination: Destination, _ state: FolderState, _ last: Date? = nil) -> FolderStatus {
        FolderStatus(path: path, destination: destination, state: state, lastSuccess: last)
    }

    @Test func oneRowPerDestinationInConfigOrder() {
        let status = EngineStatus(folders: [
            row("/Users/anna/Sync", .server(path: "/home/anna/Sync"), .synced, Date(timeIntervalSince1970: 0)),
            row("/Users/anna/Sync", .disk(disk), .notConnected, Date(timeIntervalSince1970: 86_400 * 20_000)),
            row("/Users/anna/Foto", .server(path: "~/Foto"), .notConfigured),
        ], isPaused: false, configError: nil)

        let rows = DestinationRows.rows(config: config(), status: status, home: home, timeZone: utc)

        #expect(rows.map(\.local) == ["~/Sync", "~/Sync", "~/Foto"])
        #expect(rows.map(\.destination) == ["Server: ~/Sync", "Backupdisk: Filsynk/Sync", "Server: ~/Foto"])
        #expect(rows.map(\.state) == ["✓ 00:00", "Inte inkopplad · senast 2024-10-04", "Inte inställd"])
        #expect(rows.map(\.id) == [
            "/Users/anna/Sync|server", "/Users/anna/Sync|disk:AAAA-1111:Filsynk/Sync", "/Users/anna/Foto|server",
        ])
    }

    @Test func destinationWithoutStatusWaits() {
        let rows = DestinationRows.rows(config: config(), status: .empty, home: home, timeZone: utc)
        #expect(rows.map(\.state) == ["Väntar", "Väntar", "Inte inställd"])
    }

    @Test func rowIdsMatchStatusRowIds() {
        let status = EngineStatus(folders: [row("/Users/anna/Sync", .disk(disk), .pending)], isPaused: false, configError: nil)
        let rows = DestinationRows.rows(config: config(), status: status, home: home, timeZone: utc)
        #expect(rows[1].id == status.folders[0].id)
        #expect(rows[1].folderPath == "/Users/anna/Sync")
        #expect(rows[1].destinationID == status.folders[0].destinationID)
    }

    @Test func menuLineJoinsFolderDestinationAndState() {
        let line = DestinationRows.menuLine(row("/Users/anna/Sync", .disk(disk), .syncing), home: home, serverHome: "/home/anna", timeZone: utc)
        #expect(line == "~/Sync → Backupdisk: Filsynk/Sync   Synkar…")
        let server = DestinationRows.menuLine(row("/Users/anna/Sync", .server(path: "/home/anna/Sync"), .pending), home: home, serverHome: "/home/anna", timeZone: utc)
        #expect(server == "~/Sync → Server: ~/Sync   Väntar")
    }

    @Test func menuLineWithoutDestinationIsAsBefore() {
        let status = FolderStatus(path: "/Users/anna/Sync", destination: nil, state: .notConfigured, lastSuccess: nil)
        #expect(DestinationRows.menuLine(status, home: home, serverHome: "", timeZone: utc) == "~/Sync   Inte inställd")
    }

    @Test func pickedDiskFolderShowsDiskNameAndPath() {
        let volumes = [
            VolumeInfo(uuid: "SYS", name: "Macintosh HD", mountPath: "/", format: .apfs, isSystem: true),
            VolumeInfo(uuid: "AAAA-1111", name: "Backupdisk", mountPath: "/Volumes/Backupdisk", format: .exfat, isSystem: false),
        ]
        #expect(DestinationRows.pickedDiskText(pickedPath: "/Volumes/Backupdisk/Filsynk/Sync", volumes: volumes) == "Backupdisk: Filsynk/Sync")
        #expect(DestinationRows.pickedDiskText(pickedPath: "/Volumes/Backupdisk", volumes: volumes) == "Backupdisk: /")
        #expect(DestinationRows.pickedDiskText(pickedPath: "/Volumes/Okänd/Mapp", volumes: volumes) == "/Volumes/Okänd/Mapp")
    }
}
