import Testing
import Foundation
@testable import FilsynkCore

@Suite struct DestinationTests {
    private func disk(_ uuid: String, _ path: String) -> Destination {
        .disk(.init(volumeUUID: uuid, volumeName: "HDD", path: path))
    }

    private func config(_ folders: [FolderConfig]) -> Config {
        Config(server: "u@h", folders: folders)
    }

    @Test func oldFormatBecomesOneServerDestination() throws {
        let json = #"{"server":"u@h","folders":[{"path":"/a","remotePath":"/b"}]}"#
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(c.folders[0].destinations == [.server(path: "/b")])
        #expect(c.folders[0].remotePath == "/b"); #expect(c.folders[0].isReady)
    }

    @Test func newFormatRoundTripsAndNeverWritesRemotePath() throws {
        let folder = FolderConfig(
            path: "/a", destinations: [.server(path: "/srv/a"), disk("U1", "Filsynk/A")], sourceVolumeUUID: "S1")
        let data = try JSONEncoder().encode(folder)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"destinations\"")); #expect(text.contains("\"kind\""))
        #expect(!text.contains("remotePath"))
        #expect(try JSONDecoder().decode(FolderConfig.self, from: data) == folder)
    }

    @Test func sourceVolumeUUIDIsOmittedWhenNil() throws {
        let text = String(decoding: try JSONEncoder().encode(FolderConfig(path: "/a", remotePath: "/b")), as: UTF8.self)
        #expect(!text.contains("sourceVolumeUUID"))
    }

    @Test func destinationJSONShapes() throws {
        let server = try JSONEncoder().encode(Destination.server(path: "/home/u/Sync"))
        let object = try #require(JSONSerialization.jsonObject(with: server) as? [String: String])
        #expect(object == ["kind": "server", "path": "/home/u/Sync"])
        let json = #"{"kind":"disk","volumeUUID":"U1","volumeName":"HDD","path":"Filsynk/Obsidian"}"#
        #expect(try JSONDecoder().decode(Destination.self, from: Data(json.utf8)) == disk("U1", "Filsynk/Obsidian"))
    }

    @Test func unknownKindIsADecodingError() {
        let json = #"{"kind":"cloud","path":"/x"}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Destination.self, from: Data(json.utf8)) }
    }

    @Test func folderWithNeitherDestinationsNorRemotePathIsADecodingError() {
        let json = #"{"path":"/a"}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(FolderConfig.self, from: Data(json.utf8)) }
    }

    @Test func destinationIDs() {
        #expect(Destination.server(path: "/x").id == "server")
        #expect(disk("U1", "Filsynk/A").id == "disk:U1:Filsynk/A")
    }

    @Test func destinationReadiness() {
        #expect(Destination.server(path: "/x").isReady)
        #expect(!Destination.server(path: "~/x").isReady)
        #expect(disk("U1", "A").isReady)
        #expect(Destination.server(path: "/x").isServer)
        #expect(!disk("U1", "A").isServer)
    }

    @Test func folderIDIsItsPath() {
        #expect(FolderConfig(path: "/a", remotePath: "/b").id == "/a")
    }

    @Test func remotePathShimReadsAndWritesTheServerDestination() {
        var f = FolderConfig(path: "/a", destinations: [disk("U1", "A")])
        #expect(f.remotePath == ""); #expect(!f.isReady)
        f.remotePath = "/srv/a"
        #expect(f.destinations.count == 2); #expect(f.remotePath == "/srv/a"); #expect(f.isReady)
        f.remotePath = "/srv/b"
        #expect(f.destinations.count == 2); #expect(f.remotePath == "/srv/b")
        f.remotePath = ""
        #expect(f.destinations == [disk("U1", "A")]); #expect(f.remotePath == "")
    }

    @Test func diskDestinationsListsOnlyDisks() {
        let f = FolderConfig(path: "/a", destinations: [.server(path: "/s"), disk("U1", "A"), disk("U2", "B")])
        #expect(f.diskDestinations.map(\.volumeUUID) == ["U1", "U2"])
    }

    @Test func diskOnlyFolderIsValidWithoutServer() {
        let c = Config(server: "", folders: [FolderConfig(path: "/Users/x/A", destinations: [disk("U1", "A")])])
        #expect(c.validate(home: "/Users/x") == [])
    }

    @Test func diskOnlyFoldersDoNotCountAsNestedOnTheServer() {
        let c = config([
            FolderConfig(path: "/Users/x/A", destinations: [disk("U1", "A")]),
            FolderConfig(path: "/Users/x/B", destinations: [.server(path: "/srv/b")]),
        ])
        #expect(c.validate(home: "/Users/x") == [])
    }

    @Test func rejectsFolderWithoutDestination() {
        let c = config([FolderConfig(path: "/Users/x/A", destinations: [])])
        #expect(c.validate(home: "/Users/x") == [.folderWithoutDestination("/Users/x/A")])
        #expect(ConfigIssue.folderWithoutDestination("/Users/x/A").message == "Mappen /Users/x/A har inget mål.")
    }

    @Test func rejectsTwoServerDestinations() {
        let c = config([FolderConfig(path: "/Users/x/A", destinations: [.server(path: "/srv/a"), .server(path: "/srv/b")])])
        #expect(c.validate(home: "/Users/x") == [.multipleServerDestinations("/Users/x/A")])
        #expect(ConfigIssue.multipleServerDestinations("/Users/x/A").message
            == "Mappen /Users/x/A har fler än ett mål på servern.")
    }

    @Test func serverPathRulesApplyToTheServerDestination() {
        let c = config([FolderConfig(path: "/Users/x/A", destinations: [disk("U1", "A"), .server(path: "/home/u/My Sync")])])
        #expect(c.validate(home: "/Users/x").contains(.unsafeRemotePath("/home/u/My Sync")))
    }

    @Test func rejectsBadDiskPaths() {
        for bad in ["", "/A", "A/", "A/../B", "./A", "A/./B", ".."] {
            let c = config([FolderConfig(path: "/Users/x/A", destinations: [disk("U1", bad)])])
            #expect(c.validate(home: "/Users/x") == [.invalidDiskPath(bad)], "\(bad)")
        }
        #expect(ConfigIssue.invalidDiskPath("/A").message == "Sökvägen på disken är ogiltig: /A")
    }

    @Test func acceptsPlainDiskPaths() {
        for good in ["A", "Filsynk/Obsidian", "A.b/c..d", "Mina filer/x"] {
            let c = config([FolderConfig(path: "/Users/x/A", destinations: [disk("U1", good)])])
            #expect(c.validate(home: "/Users/x") == [], "\(good)")
        }
    }

    @Test func rejectsMissingVolumeID() {
        let c = config([FolderConfig(path: "/Users/x/A", destinations: [disk("", "A")])])
        #expect(c.validate(home: "/Users/x") == [.missingVolumeID("/Users/x/A")])
        #expect(ConfigIssue.missingVolumeID("/Users/x/A").message == "Disken för /Users/x/A saknar id.")
    }

    @Test func rejectsNestedDiskPathsOnSameVolumeOnly() {
        func issues(_ a: Destination, _ b: Destination) -> [ConfigIssue] {
            config([
                FolderConfig(path: "/Users/x/A", destinations: [a]),
                FolderConfig(path: "/Users/x/B", destinations: [b]),
            ]).validate(home: "/Users/x")
        }
        #expect(issues(disk("U1", "Filsynk"), disk("U1", "Filsynk/A")) == [.nestedDiskPaths("Filsynk", "Filsynk/A")])
        #expect(issues(disk("U1", "Filsynk/A"), disk("U1", "Filsynk")) == [.nestedDiskPaths("Filsynk", "Filsynk/A")])
        #expect(issues(disk("U1", "A"), disk("U1", "A")) == [.nestedDiskPaths("A", "A")])
        #expect(issues(disk("U1", "Filsynk"), disk("U2", "Filsynk/A")) == [])
        #expect(issues(disk("U1", "A"), disk("U1", "AB")) == [])
        #expect(ConfigIssue.nestedDiskPaths("A", "A/B").message
            == "Mapparna på disken \"A\" och \"A/B\" ligger inuti varandra.")
    }

    @Test func rejectsNestedDiskPathsWithinOneFolder() {
        let c = config([FolderConfig(path: "/Users/x/A", destinations: [disk("U1", "X"), disk("U1", "X/Y")])])
        #expect(c.validate(home: "/Users/x") == [.nestedDiskPaths("X", "X/Y")])
    }
}
