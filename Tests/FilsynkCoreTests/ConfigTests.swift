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
