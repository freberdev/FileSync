import Testing
import Foundation
@testable import FilsynkCore

@Suite struct ConfigTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("filsynk-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func decodesMinimalFileWithDefaults() throws {
        let json = #"{"server":"u@h","folders":[{"path":"/a","remotePath":"/b"}]}"#
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(c.quietSeconds == 60); #expect(c.maxWaitSeconds == 600)
        #expect(c.identityFile == "~/.ssh/filsynk_ed25519"); #expect(c.rsyncPath == "/usr/bin/rsync")
        #expect(c.exclude == [])
    }

    @Test func initialConfigIsSyncToSyncAndNotReady() {
        let c = Config.initial(home: "/Users/x")
        #expect(c.server == ""); #expect(c.folders == [FolderConfig(path: "/Users/x/Sync", remotePath: "~/Sync")])
        #expect(c.folders[0].isReady == false)
    }

    @Test func detectsNestedPaths() {
        var c = Config.initial(home: "/Users/x"); c.folders = [
            .init(path: "/Users/x/Sync", remotePath: "/srv/a"), .init(path: "/Users/x/Sync/sub", remotePath: "/srv/a/b")]
        #expect(c.validate().contains(.nestedLocalPaths("/Users/x/Sync", "/Users/x/Sync/sub")))
        #expect(c.validate().contains(.nestedRemotePaths("/srv/a", "/srv/a/b")))
    }

    @Test func siblingWithCommonPrefixIsNotNested() {
        var c = Config.initial(home: "/a"); c.folders = [
            .init(path: "/a/Sync", remotePath: "/r/Sync"), .init(path: "/a/Sync2", remotePath: "/r/Sync2")]
        #expect(c.validate() == [])
    }

    @Test func rejectsUnsafeRemotePathAndIdentity() {
        var c = Config.initial(home: "/a"); c.folders[0].remotePath = "/home/u/My Sync"; c.identityFile = "~/.ssh/my key"
        #expect(c.validate().contains(.unsafeRemotePath("/home/u/My Sync")))
        #expect(c.validate().contains(.unsafeIdentityFile("~/.ssh/my key")))
    }

    @Test func localPathWithSpaceIsAllowed() {
        var c = Config.initial(home: "/a"); c.folders[0] = .init(path: "/a/Mina filer", remotePath: "/r/x")
        #expect(c.validate() == [])
    }

    @Test func missingFileLoadsInitial() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(url: dir.appendingPathComponent("nonexistent/config.json"))
        #expect(try store.load() == Config.initial(home: NSHomeDirectory()))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("nonexistent").path))
    }

    @Test func saveThenLoadRoundTrips() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(url: dir.appendingPathComponent("sub/dir/config.json"))
        var c = Config.initial(home: "/Users/x")
        c.server = "u@h"; c.quietSeconds = 5; c.exclude = ["*.tmp"]
        c.folders = [.init(path: "/Users/x/Sync", remotePath: "/srv/Sync")]
        try store.save(c)
        #expect(try store.load() == c)
    }

    @Test func malformedFileThrowsAndIsLeftUntouched() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try "{ not json".write(to: url, atomically: true, encoding: .utf8)
        let store = ConfigStore(url: url)
        #expect(throws: ConfigError.self) { try store.load() }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
    }
}

extension ConfigTests {
    @Test func parsesCommaSeparatedExcludes() { #expect(Config.parseExcludes(" node_modules, *.tmp ,, ") == ["node_modules", "*.tmp"]) }
    @Test func excludesTextRoundTrips() { var c = Config.initial(home: "/a"); c.exclude = ["a", "b"]; #expect(Config.parseExcludes(c.excludesText()) == ["a", "b"]) }
    @Test func emptyExcludesText() { #expect(Config.parseExcludes("").isEmpty); #expect(Config.initial(home: "/a").excludesText() == "") }
}

extension ConfigTests {
    @Test func verifiedServerDefaultsToEmptyWhenAbsent() throws {
        let json = #"{"server":"u@h","folders":[]}"#
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(c.verifiedServer == "")
        #expect(!c.isVerified)
    }

    @Test func verifiedServerRoundTrips() throws {
        let c = Config(server: "u@h", verifiedServer: "u@h", verifiedHome: "/home/u")
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        #expect(back == c && back.verifiedServer == "u@h" && back.isVerified)
    }

    @Test func isVerifiedNeedsMatchingNonEmptyServer() {
        #expect(!Config(server: "", verifiedServer: "").isVerified)
        #expect(!Config(server: "a@h", verifiedServer: "b@h").isVerified)
        #expect(Config(server: "a@h", verifiedServer: "a@h", verifiedHome: "/home/a").isVerified)
    }

    @Test func validateRejectsRootAsRemotePath() {
        let c = Config(server: "u@h", folders: [.init(path: "/Users/x/A", remotePath: "/")])
        #expect(c.validate().contains(.remotePathTooBroad("/")))
        #expect(ConfigIssue.remotePathTooBroad("/").message == "Sökvägen på servern \"/\" är för bred. Välj en egen mapp.")
    }
}

extension ConfigTests {
    @Test func remotePathAllowsOnlyLettersDigitsAndPlainPunctuation() {
        for bad in ["~/R&D", "~/a;b", "~/Foto*", "~/a|b", "~/a(b)", "~/a<b", "~/a#b", "~x/y", "~/a?b", "/srv/a~b", "~~/a"] {
            #expect(!Config.isSafeRemotePath(bad), "\(bad)")
            let c = Config(server: "u@h", folders: [.init(path: "/Users/x/A", remotePath: bad)])
            #expect(c.validate(home: "/Users/x").contains(.unsafeRemotePath(bad)), "\(bad)")
        }
        for good in ["~/Säkerhetskopia-2026/Mac_1", "/srv/backup/mac+1", "~", "~/Sync", "/srv/a.b/c@d,e=f%g",
                     "~/Sa\u{0308}kerhet"] {
            #expect(Config.isSafeRemotePath(good), "\(good)")
            let c = Config(server: "u@h", folders: [.init(path: "/Users/x/A", remotePath: good)])
            #expect(!c.validate(home: "/Users/x").contains(.unsafeRemotePath(good)), "\(good)")
        }
    }

    @Test func serverAllowsOnlyPlainAddressCharacters() {
        for good in ["user@192.168.1.10", "host.example.com", "my-server", "user@[fe80::1%en0]", "u_1@h"] {
            #expect(Config.isSafeServer(good), "\(good)")
            #expect(!Config(server: good).validate(home: "/Users/x").contains(.unsafeServer(good)), "\(good)")
        }
        for bad in ["h;sh<x", "a b", "-oProxyCommand=x", "user@host/x", "u@h$x", "u@h\tx", "användare@h", "u@h&"] {
            #expect(!Config.isSafeServer(bad), "\(bad)")
            #expect(Config(server: bad).validate(home: "/Users/x").contains(.unsafeServer(bad)), "\(bad)")
        }
        #expect(Config(server: "").validate(home: "/Users/x").isEmpty)
    }

    @Test func identityFileMustNotExpandToPathWithWhitespace() {
        let c = Config(identityFile: "~/.ssh/filsynk_ed25519")
        #expect(c.validate(home: "/Users/Mitt Namn").contains(.unsafeIdentityFile("~/.ssh/filsynk_ed25519")))
        #expect(c.validate(home: "/Users/x").isEmpty)
        #expect(Config(identityFile: "/k/a\tb").validate(home: "/Users/x").contains(.unsafeIdentityFile("/k/a\tb")))
    }
}

extension ConfigTests {
    private func verified(_ remotePaths: [String], home: String = "/home/u") -> Config {
        Config(server: "u@h", folders: remotePaths.enumerated().map { .init(path: "/Users/x/F\($0.offset)", remotePath: $0.element) },
               verifiedServer: "u@h", verifiedHome: home)
    }

    @Test func verifiedHomeDefaultsToEmptyAndRoundTrips() throws {
        let old = try JSONDecoder().decode(Config.self, from: Data(#"{"server":"u@h","folders":[],"verifiedServer":"u@h"}"#.utf8))
        #expect(old.verifiedHome == "")
        #expect(!old.isVerified)
        let c = Config(server: "u@h", verifiedServer: "u@h", verifiedHome: "/home/u")
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        #expect(back == c && back.isVerified)
    }

    @Test func isVerifiedNeedsKnownHome() {
        #expect(!Config(server: "a@h", verifiedServer: "a@h").isVerified)
        #expect(Config(server: "a@h", verifiedServer: "a@h", verifiedHome: "/home/a").isVerified)
        #expect(!Config(server: "b@h", verifiedServer: "a@h", verifiedHome: "/home/a").isVerified)
    }

    @Test func remotePathWithDotComponentIsRejected() {
        for bad in ["/home/u/Sync/..", "/home/u/./Sync", "~/..", "/srv/x/../y", "~/."] {
            #expect(verified([bad]).validate(home: "/Users/x").contains(.remotePathNotAllowed(bad)), "\(bad)")
            #expect(verified([bad], home: "").validate(home: "/Users/x").contains(.remotePathNotAllowed(bad)), "\(bad)")
        }
    }

    @Test func remotePathAtOrAboveVerifiedHomeIsTooBroad() {
        for bad in ["/home/u", "/home/u/", "/home"] {
            #expect(verified([bad]).validate(home: "/Users/x").contains(.remotePathTooBroad(bad)), "\(bad)")
        }
        // Without a known home only the root can be judged.
        #expect(!verified(["/home/u"], home: "").validate(home: "/Users/x").contains(.remotePathTooBroad("/home/u")))
    }

    @Test func remotePathInSshDirectoryIsRejected() {
        for bad in ["/home/u/.ssh", "/home/u/.ssh/keys", "~/.ssh"] {
            #expect(verified([bad]).validate(home: "/Users/x").contains(.remotePathNotAllowed(bad)), "\(bad)")
        }
        #expect(ConfigIssue.remotePathNotAllowed("/home/u/.ssh").message.contains(".ssh"))
    }

    private func twoHomes(_ remotePaths: [String], logical: String = "/home/u") -> Config {
        var c = verified(remotePaths, home: "/var/home/u")
        c.verifiedLogicalHome = logical
        return c
    }

    @Test func homeRulesApplyToTheUnresolvedHomeToo() {
        for bad in ["/home/u", "/home", "/var/home/u", "/var/home", "/"] {
            #expect(twoHomes([bad]).validate(home: "/Users/x").contains(.remotePathTooBroad(bad)), "\(bad)")
        }
        for bad in ["/home/u/.ssh", "/home/u/.ssh/x", "/var/home/u/.ssh", "/var/home/u/.ssh/x"] {
            #expect(twoHomes([bad]).validate(home: "/Users/x").contains(.remotePathNotAllowed(bad)), "\(bad)")
        }
        for good in ["/home/u/Sync", "/var/home/u/Sync"] {
            #expect(twoHomes([good]).validate(home: "/Users/x") == [], "\(good)")
        }
    }

    @Test func emptyLogicalHomeBehavesAsBefore() {
        #expect(twoHomes(["/home/u"], logical: "").validate(home: "/Users/x") == [])
        #expect(twoHomes(["/home/u/.ssh"], logical: "").validate(home: "/Users/x") == [])
        #expect(twoHomes(["/var/home/u"], logical: "").validate(home: "/Users/x").contains(.remotePathTooBroad("/var/home/u")))
    }

    @Test func logicalHomeDefaultsToEmptyAndDoesNotAffectVerification() throws {
        let old = try JSONDecoder().decode(
            Config.self, from: Data(#"{"server":"u@h","folders":[],"verifiedServer":"u@h","verifiedHome":"/home/u"}"#.utf8))
        #expect(old.verifiedLogicalHome == "" && old.isVerified)
        var c = Config(server: "u@h", verifiedServer: "u@h", verifiedHome: "/var/home/u")
        c.verifiedLogicalHome = "/home/u"
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        #expect(back == c && back.verifiedLogicalHome == "/home/u")
    }

    @Test func remotePathBelowOrOutsideHomeIsAccepted() {
        #expect(verified(["/home/u/Sync"]).validate(home: "/Users/x") == [])
        #expect(verified(["/srv/backup/x"]).validate(home: "/Users/x") == [])
        #expect(verified(["/home/u/.sshfiler"]).validate(home: "/Users/x") == [])
        #expect(verified(["/home/u2/Sync"]).validate(home: "/Users/x") == [])
    }
}

extension ConfigTests {
    @Test func excludeEntriesThatAreRsyncRulesAreRejected() {
        for bad in ["", "  ", "!", "!foo", "+ foo", "- foo", ": .gitignore", ". regler", "a\nb", "a\rb"] {
            let c = Config(exclude: [bad])
            #expect(c.validate(home: "/Users/x").contains(.unsafeExclude(bad)), "\(bad.debugDescription)")
        }
        for good in ["node_modules", "*.tmp", ".git", "-foo", "+foo", ".hidden", "a!b", ":x"] {
            #expect(Config(exclude: [good]).validate(home: "/Users/x") == [], "\(good)")
        }
        #expect(ConfigIssue.unsafeExclude("!").message.hasPrefix("Undantaget"))
    }

    @Test func localFolderHoldingTheAppsOwnFilesIsRejected() {
        for bad in ["/Users/x", "/Users/x/Library", "/Users/x/Library/Logs", "/Users/x/Library/Logs/Filsynk",
                    "/Users/x/Library/Application Support", "/Users/x/Library/Application Support/Filsynk", "/Users", "/"] {
            let c = Config(folders: [.init(path: bad, remotePath: "/srv/x")])
            #expect(c.validate(home: "/Users/x").contains(.localPathHoldsAppFiles(bad)), "\(bad)")
        }
        for good in ["/Users/x/Sync", "/Users/x/Library/Mail", "/Users/y", "/Users/x/Library/Logs/Annat"] {
            let c = Config(folders: [.init(path: good, remotePath: "/srv/x")])
            #expect(c.validate(home: "/Users/x") == [], "\(good)")
        }
    }

    @Test func recordsSourceVolumeOnlyForFoldersOnOtherVolumes() {
        let volumes = [
            VolumeInfo(uuid: "SYS", name: "Macintosh HD", mountPath: "/", format: .apfs, isSystem: true),
            VolumeInfo(uuid: "D1", name: "Data", mountPath: "/Volumes/Data", format: .apfs, isSystem: false),
            VolumeInfo(uuid: "D2", name: "Other", mountPath: "/Volumes/Other", format: .apfs, isSystem: false),
        ]
        let home = FolderConfig(path: "/Users/x/Sync", remotePath: "/srv/a")
        let onData = FolderConfig(path: "/Volumes/Data/Photos", remotePath: "/srv/b")
        let alreadySet = FolderConfig(path: "/Volumes/Other/Docs", destinations: [.server(path: "/srv/c")], sourceVolumeUUID: "OLD")
        let absent = FolderConfig(path: "/Volumes/Gone/Docs", remotePath: "/srv/d")
        let config = Config(folders: [home, onData, alreadySet, absent])

        let recorded = config.recordingSourceVolumes(volumes)
        #expect(recorded.folders.map(\.sourceVolumeUUID) == [nil, "D1", "OLD", nil])
        #expect(recorded.folders.map(\.path) == config.folders.map(\.path))
        #expect(recorded.folders.map(\.destinations) == config.folders.map(\.destinations))
        // Nothing to record: unchanged.
        #expect(recorded.recordingSourceVolumes(volumes) == recorded)
        #expect(Config(folders: [home]).recordingSourceVolumes(volumes) == Config(folders: [home]))
    }

    @Test func nestedDiskPathsAreFoundWhateverTheCaseOfTheVolumeID() {
        let a = DiskLocation(volumeUUID: "abcd-1", volumeName: "D", path: "Outer")
        let b = DiskLocation(volumeUUID: "ABCD-1", volumeName: "D", path: "Outer/Inner")
        let c = Config(folders: [
            FolderConfig(path: "/Users/x/A", destinations: [.disk(a)]),
            FolderConfig(path: "/Users/x/B", destinations: [.disk(b)]),
        ])
        #expect(c.validate().contains(.nestedDiskPaths("Outer", "Outer/Inner")))
    }
}
