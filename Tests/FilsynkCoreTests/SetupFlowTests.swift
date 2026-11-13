import Testing
import Foundation
@testable import FilsynkCore

/// Answers by looking at the remote command: "rsync --version", "mkdir -p …", or ssh-keygen.
final class ScriptedProcess: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(executable: String, arguments: [String])] = []
    var version = ProcessResult(exitCode: 0, stdout: "rsync  version 3.2.7  protocol version 31\n", stderr: "")
    var keygen = ProcessResult(exitCode: 0, stdout: "", stderr: "")
    /// Maps the quoted path in the mkdir command to a result; default resolves "$HOME/x" to "/home/u/x".
    var resolve: @Sendable (String) -> ProcessResult = { command in
        // command: cd && pwd -P && pwd && mkdir -p "X" && cd "X" && pwd -P
        let quoted = command.components(separatedBy: "mkdir -p \"")[1].components(separatedBy: "\"")[0]
        let path = quoted.replacingOccurrences(of: "$HOME", with: "/home/u")
        return ProcessResult(exitCode: 0, stdout: "/home/u\n/home/u\n\(path)\n", stderr: "")
    }

    /// Answer to "cd && pwd -P && pwd" on its own.
    var home = ProcessResult(exitCode: 0, stdout: "/home/u\n/home/u\n", stderr: "")

    var calls: [(executable: String, arguments: [String])] { lock.withLock { _calls } }
    var remoteCommands: [String] { calls.filter { $0.executable == "/usr/bin/ssh" }.compactMap(\.arguments.last) }
    var contactedServer: Bool { !calls.filter { $0.executable == "/usr/bin/ssh" }.isEmpty }

    func run(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
        lock.withLock { _calls.append((executable, arguments)) }
        if executable == "/usr/bin/ssh-keygen" { return keygen }
        let command = arguments.last ?? ""
        if command == "rsync --version" { return version }
        if command == "cd && pwd -P && pwd" { return home }
        return resolve(command)
    }
}

struct SetupFlowTests {
    private func tempKey() -> String {
        // Existing file so ensureKey does nothing unless a test removes it.
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("filsynk-flow-\(UUID().uuidString)").path
        FileManager.default.createFile(atPath: path, contents: Data())
        return path
    }

    private func config(server: String = "u@h", verified: String? = "u@h", key: String? = nil, folders: [FolderConfig]) -> Config {
        let verifiedServer = verified ?? ""
        var c = Config(server: server, folders: folders, verifiedServer: verifiedServer,
                       verifiedHome: verifiedServer.isEmpty ? "" : "/home/u",
                       verifiedLogicalHome: verifiedServer.isEmpty ? "" : "/home/u")
        c.identityFile = key ?? tempKey()
        return c
    }

    // MARK: connect

    @Test func connectResolvesUnreadyFoldersOnly() async {
        let p = ScriptedProcess()
        let c = config(folders: [
            .init(path: "/Users/x/Sync", remotePath: "~/Sync"),
            .init(path: "/Users/x/Done", remotePath: "/srv/Done"),
        ])
        let out = await SetupFlow(process: p).connect(c)
        #expect(out.result == .ok(rsyncVersion: "3.2.7"))
        #expect(out.config.folders.map(\.remotePath) == ["/home/u/Sync", "/srv/Done"])
        #expect(out.config.verifiedServer == "u@h")
        #expect(p.remoteCommands.count == 2) // already verified: version check + one resolve
        #expect(out.config.validate().isEmpty)
    }

    @Test func connectCreatesMissingKeyBeforeChecking() async {
        let p = ScriptedProcess()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("filsynk-nokey-\(UUID().uuidString)").path
        let out = await SetupFlow(process: p).connect(config(key: missing, folders: []))
        #expect(p.calls.first?.executable == "/usr/bin/ssh-keygen")
        #expect(p.calls.dropFirst().first?.executable == "/usr/bin/ssh")
        #expect(out.result == .ok(rsyncVersion: "3.2.7"))
    }

    @Test func connectKeyCreationFailureNeverContactsServer() async {
        let p = ScriptedProcess()
        p.keygen = ProcessResult(exitCode: 1, stdout: "", stderr: "Permission denied")
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("filsynk-nokey-\(UUID().uuidString)").path
        let c = config(key: missing, folders: [.init(path: "/Users/x/Sync", remotePath: "~/Sync")])
        let out = await SetupFlow(process: p).connect(c)
        #expect(out.result == .failed("Kunde inte skapa nyckeln: Permission denied"))
        #expect(out.config == c)
        #expect(!p.contactedServer)
    }

    @Test func connectLeavesConfigUnchangedUnlessOk() async {
        let c = config(folders: [.init(path: "/Users/x/Sync", remotePath: "~/Sync")])
        let cases: [(ProcessResult, ConnectionResult)] = [
            (ProcessResult(exitCode: 255, stdout: "", stderr: "Permission denied (publickey)."), .authDenied),
            (ProcessResult(exitCode: 255, stdout: "", stderr: "ssh: connect to host h port 22: Operation timed out"), .unreachable),
            (ProcessResult(exitCode: 0, stdout: "rsync  version 2.6.9  protocol version 29\n", stderr: ""),
             .unsupportedRsync("rsync  version 2.6.9  protocol version 29")),
        ]
        for (answer, expected) in cases {
            let p = ScriptedProcess()
            p.version = answer
            let out = await SetupFlow(process: p).connect(c)
            #expect(out.result == expected)
            #expect(out.config == c)
            #expect(p.remoteCommands == ["rsync --version"]) // nothing resolved
        }
    }

    @Test func connectResolveFailureKeepsFolderUnresolvedAndSaysWhy() async {
        let p = ScriptedProcess()
        p.resolve = { command in
            command.contains("$HOME/Bad")
                ? ProcessResult(exitCode: 1, stdout: "", stderr: "mkdir: cannot create directory: Permission denied")
                : ProcessResult(exitCode: 0, stdout: "/home/u\n/home/u\n/home/u/Good\n", stderr: "")
        }
        let c = config(folders: [
            .init(path: "/Users/x/Good", remotePath: "~/Good"),
            .init(path: "/Users/x/Bad", remotePath: "~/Bad"),
        ])
        let out = await SetupFlow(process: p).connect(c)
        guard case .failed(let message) = out.result else { Issue.record("expected failure"); return }
        #expect(message.hasPrefix("Kunde inte skapa mappen på servern"))
        #expect(out.config.folders.map(\.remotePath) == ["/home/u/Good", "~/Bad"])
        #expect(out.config.verifiedServer == "u@h") // unchanged on failure
    }

    @Test func connectToNewServerReResolvesEveryFolderAndVerifies() async {
        let p = ScriptedProcess()
        let c = config(server: "new@h", verified: "old@h", folders: [
            .init(path: "/Users/x/Sync", remotePath: "/home/old/Sync"),
            .init(path: "/Users/x/Pics", remotePath: "~/Pics"),
        ])
        let out = await SetupFlow(process: p).connect(c)
        #expect(out.result == .ok(rsyncVersion: "3.2.7"))
        #expect(p.remoteCommands.count == 3) // check + both folders
        #expect(out.config.folders.map(\.remotePath) == ["/home/old/Sync", "/home/u/Pics"])
        #expect(out.config.verifiedServer == "new@h" && out.config.isVerified)
    }

    @Test func connectFirstTimeVerifiesEvenWithNoFolders() async {
        let out = await SetupFlow(process: ScriptedProcess()).connect(config(verified: "", folders: []))
        #expect(out.config.verifiedServer == "u@h")
    }

    @Test func connectResolveFailureLeavesVerifiedServerUnchanged() async {
        let p = ScriptedProcess()
        p.resolve = { _ in ProcessResult(exitCode: 1, stdout: "", stderr: "boom") }
        let c = config(server: "new@h", verified: "old@h", folders: [.init(path: "/Users/x/Sync", remotePath: "/srv/Sync")])
        let out = await SetupFlow(process: p).connect(c)
        guard case .failed = out.result else { Issue.record("expected failure"); return }
        #expect(out.config.verifiedServer == "old@h")
    }

    @Test func connectNotOkNeverVerifies() async {
        let p = ScriptedProcess()
        p.version = ProcessResult(exitCode: 255, stdout: "", stderr: "Permission denied (publickey).")
        let out = await SetupFlow(process: p).connect(config(verified: "", folders: []))
        #expect(out.config.verifiedServer == "")
    }

    @Test func connectRecordsHomeFromResolvedFolders() async {
        let p = ScriptedProcess()
        let c = config(verified: "", folders: [.init(path: "/Users/x/Sync", remotePath: "~/Sync")])
        let out = await SetupFlow(process: p).connect(c)
        #expect(out.config.verifiedHome == "/home/u" && out.config.verifiedLogicalHome == "/home/u")
        #expect(out.config.isVerified)
        #expect(!p.remoteCommands.contains("cd && pwd -P && pwd")) // learnt while resolving
    }

    @Test func connectAsksForHomeWhenNothingIsResolved() async {
        let p = ScriptedProcess()
        p.home = ProcessResult(exitCode: 0, stdout: "banner\n/var/home/annan\n/home/annan\n", stderr: "")
        var c = config(folders: [.init(path: "/Users/x/Done", remotePath: "/srv/Done")])
        c.verifiedHome = ""
        let out = await SetupFlow(process: p).connect(c)
        #expect(out.result == .ok(rsyncVersion: "3.2.7"))
        #expect(p.remoteCommands == ["rsync --version", "cd && pwd -P && pwd"])
        #expect(out.config.verifiedHome == "/var/home/annan" && out.config.verifiedLogicalHome == "/home/annan")
        #expect(out.config.isVerified)
    }

    @Test func connectHomeQueryFailureLeavesConfigUnverified() async {
        let p = ScriptedProcess()
        p.home = ProcessResult(exitCode: 255, stdout: "", stderr: "ssh: connect to host h port 22: Connection refused")
        let c = config(verified: "", folders: [])
        let out = await SetupFlow(process: p).connect(c)
        #expect(out.result == .unreachable)
        #expect(out.config.verifiedServer == "" && out.config.verifiedHome == "")
    }

    @Test func connectResolveFailureLeavesVerifiedHomeUnchanged() async {
        let p = ScriptedProcess()
        p.resolve = { _ in ProcessResult(exitCode: 1, stdout: "", stderr: "boom") }
        let c = config(verified: "", folders: [.init(path: "/Users/x/Sync", remotePath: "~/Sync")])
        let out = await SetupFlow(process: p).connect(c)
        guard case .failed = out.result else { Issue.record("expected failure"); return }
        #expect(out.config.verifiedHome == "" && out.config.verifiedLogicalHome == "")
    }

    @Test func launchFailureShowsShortTextAndLogsDetail() async {
        let f = FakeProcess()
        f.error = LaunchError()
        let log = LogSink()
        let c = config(folders: [])
        let out = await SetupFlow(process: f, log: { log.add($0) })
            .addFolder(to: c, localPath: "/Users/x/A", remoteEntered: "~/A")
        #expect(out == .rejected("Kunde inte köra kommandot: \(LaunchError().localizedDescription)"))
        #expect(log.lines.contains { $0.contains("boom") })
    }

    // MARK: addFolder

    @Test func addFolderRejectsSshDirectoryWithoutContactingServer() async {
        let p = ScriptedProcess()
        let out = await SetupFlow(process: p).addFolder(to: config(folders: []), localPath: "/Users/x/A", remoteEntered: "~/.ssh")
        #expect(out == .rejected(ConfigIssue.remotePathNotAllowed("~/.ssh").message))
        #expect(!p.contactedServer)
    }

    @Test func addFolderRejectsPathThatResolvesIntoSshDirectory() async {
        let p = ScriptedProcess()
        p.resolve = { _ in ProcessResult(exitCode: 0, stdout: "/home/u\n/home/u\n/home/u/.ssh\n", stderr: "") }
        let out = await SetupFlow(process: p).addFolder(to: config(folders: []), localPath: "/Users/x/A", remoteEntered: "~/nycklar")
        #expect(out == .rejected(ConfigIssue.remotePathNotAllowed("/home/u/.ssh").message))
    }

    @Test func addFolderResolvesAndAppends() async {
        let p = ScriptedProcess()
        let c = config(folders: [.init(path: "/Users/x/Sync", remotePath: "/home/u/Sync")])
        let out = await SetupFlow(process: p).addFolder(to: c, localPath: "/Users/x/Pictures", remoteEntered: " ~/Pictures ")
        #expect(out == .added(Config(server: c.server, identityFile: c.identityFile, folders: [
            c.folders[0], .init(path: "/Users/x/Pictures", remotePath: "/home/u/Pictures"),
        ], verifiedServer: "u@h", verifiedHome: "/home/u", verifiedLogicalHome: "/home/u")))
    }

    @Test func addRejectionNeedsVerifiedConnection() {
        let p = ScriptedProcess()
        let flow = SetupFlow(process: p)
        let c = config(verified: "", folders: [])
        #expect(flow.addRejection(to: c, localPath: "/Users/x/A", remoteEntered: "~/A") == "Testa anslutningen först.")
        #expect(p.calls.isEmpty)
    }

    @Test func addRejectionExplainsNestedAndUnsafePaths() {
        let p = ScriptedProcess()
        let flow = SetupFlow(process: p)
        let c = config(folders: [.init(path: "/Users/x/Sync", remotePath: "/home/u/Sync")])
        #expect(flow.addRejection(to: c, localPath: "/Users/x/Sync/inner", remoteEntered: "~/inner")
                == ConfigIssue.nestedLocalPaths("/Users/x/Sync", "/Users/x/Sync/inner").message)
        #expect(flow.addRejection(to: c, localPath: "/Users/x/A", remoteEntered: "~/a b")
                == ConfigIssue.unsafeRemotePath("~/a b").message)
        #expect(flow.addRejection(to: c, localPath: "/Users/x/A", remoteEntered: "~/.ssh")
                == ConfigIssue.remotePathNotAllowed("~/.ssh").message)
        #expect(p.calls.isEmpty)
    }

    @Test func addRejectionAcceptsGoodFolder() {
        let p = ScriptedProcess()
        let c = config(folders: [.init(path: "/Users/x/Sync", remotePath: "/home/u/Sync")])
        #expect(SetupFlow(process: p).addRejection(to: c, localPath: "/Users/x/Pictures", remoteEntered: " ~/Pictures ") == nil)
        #expect(p.calls.isEmpty)
    }

    @Test func addFolderRejectsNestedLocalWithoutContactingServer() async {
        let p = ScriptedProcess()
        let c = config(folders: [.init(path: "/Users/x/Sync", remotePath: "/home/u/Sync")])
        let out = await SetupFlow(process: p).addFolder(to: c, localPath: "/Users/x/Sync/inner", remoteEntered: "~/inner")
        #expect(out == .rejected(ConfigIssue.nestedLocalPaths("/Users/x/Sync", "/Users/x/Sync/inner").message))
        #expect(!p.contactedServer)
    }

    @Test func addFolderRejectsUnsafeRemoteWithoutContactingServer() async {
        let p = ScriptedProcess()
        let c = config(folders: [])
        let out = await SetupFlow(process: p).addFolder(to: c, localPath: "/Users/x/A", remoteEntered: "~/a b")
        #expect(out == .rejected(ConfigIssue.unsafeRemotePath("~/a b").message))
        #expect(!p.contactedServer)
    }

    @Test func addFolderNeedsVerifiedConnection() async {
        for (server, verified) in [("u@h", ""), ("new@h", "u@h"), ("", "")] {
            let p = ScriptedProcess()
            let out = await SetupFlow(process: p).addFolder(
                to: config(server: server, verified: verified, folders: []), localPath: "/Users/x/A", remoteEntered: "~/A")
            #expect(out == .rejected("Testa anslutningen först."))
            #expect(!p.contactedServer)
        }
    }

    @Test func addFolderRejectsHomeDirectory() async {
        let p = ScriptedProcess()
        // With the server's home known, "~" is refused before the server is contacted.
        let out = await SetupFlow(process: p).addFolder(to: config(folders: []), localPath: "/Users/x/A", remoteEntered: "~")
        #expect(out == .rejected(ConfigIssue.remotePathTooBroad("~").message))
        #expect(!p.contactedServer)
        // A path that only the server can resolve to the home is refused by the server-side check.
        let q = ScriptedProcess()
        q.resolve = { _ in ProcessResult(exitCode: 0, stdout: "/home/u\n/home/u\n/home/u\n", stderr: "") }
        let viaLink = await SetupFlow(process: q).addFolder(to: config(folders: []), localPath: "/Users/x/A", remoteEntered: "~/hem")
        #expect(viaLink == .rejected("Välj en egen mapp på servern, inte hemkatalogen eller en mapp ovanför den."))
    }

    @Test func addFolderRejectsRemoteNestingFoundOnlyAfterResolving() async {
        let p = ScriptedProcess() // "~/Sync/sub" resolves to /home/u/Sync/sub
        let c = config(folders: [.init(path: "/Users/x/Sync", remotePath: "/home/u/Sync")])
        let out = await SetupFlow(process: p).addFolder(to: c, localPath: "/Users/x/Other", remoteEntered: "~/Sync/sub")
        #expect(out == .rejected(ConfigIssue.nestedRemotePaths("/home/u/Sync", "/home/u/Sync/sub").message))
    }

    @Test func addFolderReportsServerFailure() async {
        let p = ScriptedProcess()
        p.resolve = { _ in ProcessResult(exitCode: 255, stdout: "", stderr: "ssh: connect to host h port 22: Operation timed out") }
        let out = await SetupFlow(process: p).addFolder(to: config(folders: []), localPath: "/Users/x/A", remoteEntered: "~/A")
        #expect(out == .rejected("Kunde inte skapa mappen på servern: Servern nås inte"))
    }

    // MARK: removeFolder

    @Test func removeFolderDropsOnlyThatFolderAndNeverTouchesServer() {
        let a = FolderConfig(path: "/Users/x/A", remotePath: "/srv/A")
        let b = FolderConfig(path: "/Users/x/B", remotePath: "/srv/B")
        let c = config(folders: [a, b])
        #expect(SetupFlow.removeFolder(a, from: c).folders == [b])
        #expect(SetupFlow.removeFolder(.init(path: "/nope", remotePath: "/x"), from: c) == c)
    }
}

/// Temporary directories stand in for disks; the volume list is built by hand.
final class DiskDestinationTests {
    private let root: String
    private let source: String
    private let disk: String
    private let sourceDisk: String
    private let system = VolumeInfo(uuid: "SYS", name: "Macintosh HD", mountPath: "/", format: .apfs, isSystem: true)

    deinit { try? FileManager.default.removeItem(atPath: root) }

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("filsynk-disk-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = realpath(base, nil).map { String(cString: $0) } ?? base
        source = root + "/src"
        disk = root + "/disk"
        sourceDisk = root + "/disk2"
        for path in [source, disk, sourceDisk] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }

    private var volumes: [VolumeInfo] {
        [system,
         VolumeInfo(uuid: "U1", name: "Testdisk", mountPath: disk, format: .exfat, isSystem: false),
         VolumeInfo(uuid: "U2", name: "Källdisk", mountPath: sourceDisk, format: .apfs, isSystem: false)]
    }

    private func flow() -> SetupFlow { SetupFlow(process: ScriptedProcess()) }

    private func config(_ folders: [FolderConfig] = []) -> Config {
        Config(server: "u@h", folders: folders, verifiedServer: "u@h", verifiedHome: "/home/u", verifiedLogicalHome: "/home/u")
    }

    @discardableResult
    private func makeDirectory(_ path: String) throws -> String {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func write(_ path: String, _ text: String = "x") {
        FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
    }

    /// Writes the marker the app itself would have written for `folder` (the watched source by default).
    private func marked(_ path: String, for folder: String? = nil) throws {
        try DiskMarker.write(in: path, folder: folder ?? source)
    }

    /// Every path below `directory` with its kind, contents and modification time.
    private func snapshot(_ directory: String) -> [String] {
        let fm = FileManager.default
        var lines: [String] = []
        for name in (fm.subpaths(atPath: directory) ?? []).sorted() {
            let path = directory + "/" + name
            let attributes = try? fm.attributesOfItem(atPath: path)
            let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let content = (fm.contents(atPath: path)).map { String(decoding: $0, as: UTF8.self) } ?? "<katalog>"
            lines.append("\(name)|\(content)|\(date)")
        }
        return lines
    }

    private static let notEmpty = "Mappen på disken måste vara tom. Skapa en ny mapp för säkerhetskopian."

    // MARK: adding

    @Test func addsDiskDestinationToNewFolderAndWritesMarker() throws {
        let target = try makeDirectory(disk + "/Backup")
        let out = flow().addDiskDestination(to: config(), localPath: source, pickedPath: target, volumes: volumes)
        guard case .added(let updated) = out else { Issue.record("expected added, got \(out)"); return }
        #expect(updated.folders == [FolderConfig(
            path: source,
            destinations: [.disk(DiskLocation(volumeUUID: "U1", volumeName: "Testdisk", path: "Backup"))])])
        #expect(updated.validate().isEmpty)
        #expect(DiskMarker.exists(in: target))
        #expect(try FileManager.default.contentsOfDirectory(atPath: target) == [DiskMarker.name])
        let text = try String(contentsOfFile: target + "/" + DiskMarker.name, encoding: .utf8)
        #expect(text.hasPrefix(source + "\n"))
    }

    @Test func addsDiskDestinationToFolderThatHasServerDestination() throws {
        let target = try makeDirectory(disk + "/Backup")
        let c = config([FolderConfig(path: source, remotePath: "/srv/A")])
        let out = flow().addDiskDestination(to: c, localPath: source, pickedPath: target, volumes: volumes)
        guard case .added(let updated) = out else { Issue.record("expected added, got \(out)"); return }
        #expect(updated.folders.count == 1)
        #expect(updated.folders[0].destinations == [
            .server(path: "/srv/A"),
            .disk(DiskLocation(volumeUUID: "U1", volumeName: "Testdisk", path: "Backup")),
        ])
        #expect(DiskMarker.exists(in: target))
    }

    @Test func addsServerDestinationToFolderThatHasDiskDestination() async {
        let location = DiskLocation(volumeUUID: "U1", volumeName: "Testdisk", path: "Backup")
        let c = config([FolderConfig(path: "/Users/x/A", destinations: [.disk(location)])])
        let p = ScriptedProcess()
        let out = await SetupFlow(process: p).addServerDestination(to: c, localPath: "/Users/x/A/", remoteEntered: "~/A")
        guard case .added(let updated) = out else { Issue.record("expected added, got \(out)"); return }
        #expect(updated.folders.count == 1)
        #expect(updated.folders[0].destinations == [.disk(location), .server(path: "/home/u/A")])
        #expect(updated.validate().isEmpty)
    }

    @Test func serverDestinationViaLinkedSpellingJoinsTheExistingFolder() async throws {
        let link = root + "/lank-till-src"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: source)
        let location = DiskLocation(volumeUUID: "U1", volumeName: "Testdisk", path: "Backup")
        let c = config([FolderConfig(path: source, destinations: [.disk(location)])])
        let out = await SetupFlow(process: ScriptedProcess()).addServerDestination(to: c, localPath: link, remoteEntered: "~/A")
        guard case .added(let updated) = out else { Issue.record("expected added, got \(out)"); return }
        #expect(updated.folders.count == 1)
        #expect(updated.folders[0].path == source)
        #expect(updated.folders[0].destinations == [.disk(location), .server(path: "/home/u/A")])
        // A new folder is stored with its resolved path.
        let fresh = await SetupFlow(process: ScriptedProcess()).addServerDestination(to: config(), localPath: link, remoteEntered: "~/A")
        #expect(fresh == .added(config([FolderConfig(path: source, remotePath: "/home/u/A")])))
        // Removal finds the folder through the link too.
        let removed = SetupFlow.removeDestination("server", fromFolder: link, in: updated)
        #expect(removed.folders[0].destinations == [.disk(location)])
    }

    @Test func rejectsSecondServerDestination() async {
        let c = config([FolderConfig(path: "/Users/x/A", remotePath: "/srv/A")])
        let p = ScriptedProcess()
        let out = await SetupFlow(process: p).addServerDestination(to: c, localPath: "/Users/x/A", remoteEntered: "~/B")
        #expect(out == .rejected("Mappen har redan ett mål på servern."))
        #expect(!p.contactedServer)
    }

    @Test func addFolderStillAppendsNewFolders() async {
        let out = await SetupFlow(process: ScriptedProcess()).addFolder(to: config(), localPath: "/Users/x/A", remoteEntered: "~/A")
        #expect(out == .added(config([FolderConfig(path: "/Users/x/A", remotePath: "/home/u/A")])))
    }

    @Test func acceptsFolderWithOnlyFinderFiles() throws {
        let target = try makeDirectory(disk + "/Backup")
        write(target + "/.DS_Store")
        write(target + "/._x")
        #expect(flow().diskRejection(to: config(), localPath: source, pickedPath: target, volumes: volumes) == nil)
        let out = flow().addDiskDestination(to: config(), localPath: source, pickedPath: target, volumes: volumes)
        guard case .added = out else { Issue.record("expected added, got \(out)"); return }
        #expect(DiskMarker.exists(in: target))
        #expect(FileManager.default.fileExists(atPath: target + "/.DS_Store"))
    }

    @Test func acceptsNonEmptyFolderThatHasMarker() throws {
        let target = try makeDirectory(disk + "/Backup")
        try marked(target)
        write(target + "/gammal.txt", "kvar")
        try makeDirectory(target + "/Raderat")
        let before = snapshot(target)
        #expect(flow().diskRejection(to: config(), localPath: source, pickedPath: target, volumes: volumes) == nil)
        let out = flow().addDiskDestination(to: config(), localPath: source, pickedPath: target, volumes: volumes)
        guard case .added = out else { Issue.record("expected added, got \(out)"); return }
        #expect(snapshot(target) == before) // the existing marker is not rewritten
    }

    @Test func rejectsNonEmptyFolderWhoseMarkerNamesAnotherFolder() throws {
        let target = try makeDirectory(disk + "/Backup")
        try marked(target, for: root + "/annan")
        write(target + "/gammal.txt", "kvar")
        let before = snapshot(root)
        #expect(flow().diskRejection(to: config(), localPath: source, pickedPath: target, volumes: volumes) == Self.notEmpty)
        let out = flow().addDiskDestination(to: config(), localPath: source, pickedPath: target, volumes: volumes)
        #expect(out == .rejected(Self.notEmpty))
        #expect(snapshot(root) == before)
    }

    @Test func rejectsEmptyFolderWhoseMarkerNamesAnotherFolder() throws {
        let target = try makeDirectory(disk + "/Backup")
        try marked(target, for: root + "/annan")
        let before = snapshot(root)
        let out = flow().addDiskDestination(to: config(), localPath: source, pickedPath: target, volumes: volumes)
        #expect(out == .rejected(Self.notEmpty))
        #expect(snapshot(root) == before)
    }

    @Test func rejectsEmptyMarkerFile() throws {
        let target = try makeDirectory(disk + "/Backup")
        write(target + "/.filsynk", "")
        #expect(flow().diskRejection(to: config(), localPath: source, pickedPath: target, volumes: volumes) == Self.notEmpty)
    }

    @Test func rejectsWhenMarkerCannotBeWritten() throws {
        let target = try makeDirectory(disk + "/Backup")
        chmod(target, 0o555)
        defer { chmod(target, 0o755) }
        let c = config()
        let out = flow().addDiskDestination(to: c, localPath: source, pickedPath: target, volumes: volumes)
        #expect(out == .rejected("Kunde inte skriva till mappen på disken."))
        #expect(try FileManager.default.contentsOfDirectory(atPath: target).isEmpty)
    }

    // MARK: rejections

    @Test func rejectsNonEmptyFolderOnDisk() throws {
        let target = try makeDirectory(disk + "/Backup")
        write(target + "/foto.jpg", "bild")
        let before = snapshot(root)
        let out = flow().addDiskDestination(to: config(), localPath: source, pickedPath: target, volumes: volumes)
        #expect(out == .rejected(Self.notEmpty))
        #expect(snapshot(root) == before)
        #expect(!DiskMarker.exists(in: target))
        #expect(try String(contentsOfFile: target + "/foto.jpg", encoding: .utf8) == "bild")
    }

    @Test func rejectsRaderatFolderWithoutMarkerAndFilsynkThatIsNotAMarker() throws {
        let a = try makeDirectory(disk + "/A")
        try makeDirectory(a + "/Raderat")
        #expect(flow().diskRejection(to: config(), localPath: source, pickedPath: a, volumes: volumes) == Self.notEmpty)
        let b = try makeDirectory(disk + "/B")
        try makeDirectory(b + "/.filsynk") // a directory is not the marker
        #expect(flow().diskRejection(to: config(), localPath: source, pickedPath: b, volumes: volumes) == Self.notEmpty)
    }

    @Test func rejectsVolumeRoot() {
        let out = flow().diskRejection(to: config(), localPath: source, pickedPath: disk, volumes: volumes)
        #expect(out == "Välj en mapp på disken, inte diskens rot.")
    }

    @Test func rejectsSystemVolume() throws {
        let target = try makeDirectory(root + "/vanlig")
        #expect(flow().diskRejection(to: config(), localPath: source, pickedPath: target, volumes: volumes)
                == "Välj en mapp på en extern disk.")
        // Also when the folder does not exist: the volume is judged first.
        #expect(flow().diskRejection(to: config(), localPath: source, pickedPath: root + "/saknas", volumes: volumes)
                == "Välj en mapp på en extern disk.")
    }

    @Test func rejectsUnsupportedFormat() throws {
        let target = try makeDirectory(disk + "/Backup")
        var list = volumes
        list[1].format = .other("ntfs")
        #expect(flow().diskRejection(to: config(), localPath: source, pickedPath: target, volumes: list)
                == "Disken måste vara formaterad som APFS, Mac OS Extended eller exFAT.")
    }

    @Test func rejectsVolumeWithoutID() throws {
        let target = try makeDirectory(disk + "/Backup")
        for id in [nil, ""] as [String?] {
            var list = volumes
            list[1].uuid = id
            #expect(flow().diskRejection(to: config(), localPath: source, pickedPath: target, volumes: list)
                    == "Disken saknar id och kan inte användas.")
        }
        #expect(flow().diskRejection(to: config(), localPath: source, pickedPath: "disk/Backup", volumes: volumes)
                == "Disken saknar id och kan inte användas.")
    }

    @Test func rejectsMissingFolder() {
        for path in [disk + "/Saknas", disk + "/Saknas/Djupare"] {
            let out = flow().addDiskDestination(to: config(), localPath: source, pickedPath: path, volumes: volumes)
            #expect(out == .rejected("Mappen finns inte."))
            #expect(!FileManager.default.fileExists(atPath: path))
        }
    }

    @Test func rejectsPickedFileAndMissingSource() throws {
        write(disk + "/fil")
        #expect(flow().diskRejection(to: config(), localPath: source, pickedPath: disk + "/fil", volumes: volumes)
                == "Mappen finns inte.")
        let target = try makeDirectory(disk + "/Backup")
        #expect(flow().diskRejection(to: config(), localPath: root + "/saknas", pickedPath: target, volumes: volumes)
                == "Mappen på Macen finns inte.")
    }

    @Test func rejectsDestinationInsideWatchedFolder() throws {
        let watched = try makeDirectory(disk + "/Watched")
        let target = try makeDirectory(watched + "/Backup")
        let c = config([FolderConfig(path: watched, remotePath: "/srv/W")])
        #expect(flow().diskRejection(to: c, localPath: source, pickedPath: target, volumes: volumes)
                == "Mappen på disken och en bevakad mapp ligger inuti varandra.")
        // The folder being added counts too.
        #expect(flow().diskRejection(to: config(), localPath: watched, pickedPath: target, volumes: volumes)
                == "Mappen på disken och en bevakad mapp ligger inuti varandra.")
        // Through a symbolic link.
        let link = root + "/lank"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: watched)
        #expect(flow().diskRejection(to: config(), localPath: link, pickedPath: target, volumes: volumes)
                == "Mappen på disken och en bevakad mapp ligger inuti varandra.")
    }

    @Test func rejectsWatchedFolderInsideDestination() throws {
        let target = try makeDirectory(disk + "/Backup")
        try marked(target)
        let inner = try makeDirectory(target + "/Inner")
        let c = config([FolderConfig(path: inner, remotePath: "/srv/I")])
        #expect(flow().diskRejection(to: c, localPath: source, pickedPath: target, volumes: volumes)
                == "Mappen på disken och en bevakad mapp ligger inuti varandra.")
        let second = try makeDirectory(disk + "/Backup2")
        let inside = try makeDirectory(second + "/Inner")
        try marked(second, for: inside)
        #expect(flow().diskRejection(to: config(), localPath: inside, pickedPath: second, volumes: volumes)
                == "Mappen på disken och en bevakad mapp ligger inuti varandra.")
    }

    @Test func siblingWithSamePrefixIsNotNested() throws {
        let sibling = try makeDirectory(disk + "/Backup2")
        let target = try makeDirectory(disk + "/Backup")
        let c = config([FolderConfig(path: sibling, remotePath: "/srv/S")])
        #expect(flow().diskRejection(to: c, localPath: source, pickedPath: target, volumes: volumes) == nil)
    }

    @Test func rejectsSameDestinationTwice() throws {
        let target = try makeDirectory(disk + "/Backup")
        guard case .added(let once) = flow().addDiskDestination(
            to: config(), localPath: source, pickedPath: target, volumes: volumes) else {
            Issue.record("expected added"); return
        }
        let again = flow().addDiskDestination(to: once, localPath: source, pickedPath: target, volumes: volumes)
        #expect(again == .rejected("Mappen har redan det här målet."))
    }

    @Test func sameDestinationIsJudgedOnVolumeIDAndPathNotName() throws {
        let target = try makeDirectory(disk + "/Backup")
        try marked(target)
        let stored = DiskLocation(volumeUUID: "u1", volumeName: "Gammalt namn", path: "Backup")
        let c = config([FolderConfig(path: source, destinations: [.disk(stored)])])
        #expect(flow().diskRejection(to: c, localPath: source, pickedPath: target, volumes: volumes)
                == "Mappen har redan det här målet.")
    }

    @Test func rejectsNestedDestinationsOnTheSameDisk() throws {
        let outer = try makeDirectory(disk + "/Outer")
        try marked(outer)
        let inner = try makeDirectory(outer + "/Inner")
        let other = try makeDirectory(root + "/src2")
        try marked(inner, for: other)
        guard case .added(let once) = flow().addDiskDestination(
            to: config(), localPath: source, pickedPath: outer, volumes: volumes) else {
            Issue.record("expected added"); return
        }
        let out = flow().diskRejection(to: once, localPath: other, pickedPath: inner, volumes: volumes)
        #expect(out == ConfigIssue.nestedDiskPaths("Outer", "Outer/Inner").message)
    }

    @Test func diskRejectionWritesNothing() throws {
        let nonEmpty = try makeDirectory(disk + "/Full")
        write(nonEmpty + "/a.txt", "a")
        let watched = try makeDirectory(disk + "/Watched")
        let insideWatched = try makeDirectory(watched + "/Backup")
        let outer = try makeDirectory(disk + "/Outer")
        try marked(outer)
        let inner = try makeDirectory(outer + "/Inner")
        let plain = try makeDirectory(root + "/vanlig")
        let foreign = try makeDirectory(disk + "/Foreign")
        try marked(foreign, for: root + "/annan")
        write(foreign + "/b.txt", "b")
        let foreignEmpty = try makeDirectory(disk + "/ForeignEmpty")
        try marked(foreignEmpty, for: root + "/annan")
        let twice = try makeDirectory(disk + "/Twice")
        try marked(twice)
        let other = try makeDirectory(root + "/src2")
        let freshInner = try makeDirectory(outer + "/Fresh") // unmarked and empty: only validation stops it
        let ntfsDisk = try makeDirectory(root + "/ntfs")
        let ntfsTarget = try makeDirectory(ntfsDisk + "/Backup")

        var list = volumes
        list.append(VolumeInfo(uuid: "U3", name: "NTFS", mountPath: ntfsDisk, format: .other("ntfs"), isSystem: false))
        list.append(VolumeInfo(uuid: nil, name: "Utan id", mountPath: root + "/utanid", format: .exfat, isSystem: false))
        try makeDirectory(root + "/utanid/Backup")

        let withWatched = config([FolderConfig(path: watched, remotePath: "/srv/W"),
                                  FolderConfig(path: inner, remotePath: "/srv/I")])
        let twiceLocation = DiskLocation(volumeUUID: "U1", volumeName: "Testdisk", path: "Twice")
        let hasTwice = config([FolderConfig(path: source, destinations: [.disk(twiceLocation)])])
        let hasOuter = config([FolderConfig(path: source, destinations: [
            .disk(DiskLocation(volumeUUID: "U1", volumeName: "Testdisk", path: "Outer"))])])
        let scenarios: [(Config, String, String)] = [
            (hasTwice, source, twice),
            (hasOuter, other, freshInner),
            (config(), source, foreign),
            (config(), source, foreignEmpty),
            (config(), source, nonEmpty),
            (config(), source, disk),
            (config(), source, plain),
            (config(), source, ntfsTarget),
            (config(), source, root + "/utanid/Backup"),
            (config(), source, disk + "/Saknas"),
            (withWatched, source, insideWatched),
            (withWatched, source, outer),
            (config(), root + "/saknas", outer),
        ]
        #expect(flow().diskRejection(to: hasOuter, localPath: other, pickedPath: freshInner, volumes: list)
                == ConfigIssue.nestedDiskPaths("Outer", "Outer/Fresh").message)
        let before = snapshot(root)
        for (c, local, picked) in scenarios {
            let text = flow().diskRejection(to: c, localPath: local, pickedPath: picked, volumes: list)
            #expect(text != nil, "ingen avvisning för \(picked)")
            #expect(snapshot(root) == before)
            let out = flow().addDiskDestination(to: c, localPath: local, pickedPath: picked, volumes: list)
            #expect(out == .rejected(text ?? ""))
            #expect(snapshot(root) == before)
        }
    }

    // MARK: source volume

    @Test func recordsSourceVolumeForFolderOnExternalVolume() throws {
        let target = try makeDirectory(disk + "/Backup")
        let external = try makeDirectory(sourceDisk + "/Foton")
        guard case .added(let onExternal) = flow().addDiskDestination(
            to: config(), localPath: external, pickedPath: target, volumes: volumes) else {
            Issue.record("expected added"); return
        }
        #expect(onExternal.folders.first?.sourceVolumeUUID == "U2")

        let other = try makeDirectory(disk + "/Annan")
        guard case .added(let onSystem) = flow().addDiskDestination(
            to: config(), localPath: source, pickedPath: other, volumes: volumes) else {
            Issue.record("expected added"); return
        }
        #expect(onSystem.folders.first?.sourceVolumeUUID == nil)
    }

    @Test func keepsSourceVolumeOfExistingFolder() throws {
        let target = try makeDirectory(disk + "/Backup")
        var folder = FolderConfig(path: source, remotePath: "/srv/A")
        folder.sourceVolumeUUID = "GAMMAL"
        guard case .added(let updated) = flow().addDiskDestination(
            to: config([folder]), localPath: source, pickedPath: target, volumes: volumes) else {
            Issue.record("expected added"); return
        }
        #expect(updated.folders.first?.sourceVolumeUUID == "GAMMAL")
    }

    // MARK: removing

    private func diskLocation(_ path: String) -> DiskLocation {
        DiskLocation(volumeUUID: "U1", volumeName: "Testdisk", path: path)
    }

    @Test func removingOneOfTwoDestinationsKeepsTheFolder() {
        let location = diskLocation("Backup")
        let other = FolderConfig(path: "/Users/x/B", remotePath: "/srv/B")
        let c = config([FolderConfig(path: "/Users/x/A", destinations: [.server(path: "/srv/A"), .disk(location)]), other])
        let afterDisk = SetupFlow.removeDestination(Destination.disk(location).id, fromFolder: "/Users/x/A", in: c)
        #expect(afterDisk.folders[0].destinations == [.server(path: "/srv/A")])
        #expect(afterDisk.folders[1] == other)
        let afterServer = SetupFlow.removeDestination("server", fromFolder: "/Users/x/A", in: c)
        #expect(afterServer.folders[0].destinations == [.disk(location)])
    }

    @Test func removingTheLastDestinationRemovesTheFolder() {
        let location = diskLocation("Backup")
        let other = FolderConfig(path: "/Users/x/B", remotePath: "/srv/B")
        let c = config([FolderConfig(path: "/Users/x/A", destinations: [.disk(location)]), other])
        let out = SetupFlow.removeDestination(Destination.disk(location).id, fromFolder: "/Users/x/A", in: c)
        #expect(out.folders == [other])
    }

    @Test func removingSomethingThatIsNotThereChangesNothing() {
        let c = config([FolderConfig(path: "/Users/x/A", remotePath: "/srv/A")])
        #expect(SetupFlow.removeDestination("disk:U9:x", fromFolder: "/Users/x/A", in: c) == c)
        #expect(SetupFlow.removeDestination("server", fromFolder: "/Users/x/Z", in: c) == c)
    }

    @Test func knowsWhichFoldersAreWatched() throws {
        let real = FileManager.default.temporaryDirectory.appendingPathComponent("filsynk-watched-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: real) }
        let link = real + "-link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        defer { try? FileManager.default.removeItem(atPath: link) }
        let c = config([FolderConfig(path: real, remotePath: "/srv/A")])
        #expect(SetupFlow.isWatched(real, in: c))
        #expect(SetupFlow.isWatched(link, in: c))
        #expect(!SetupFlow.isWatched("/Users/x/Annan", in: c))
    }
}
