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
        // command: cd && pwd -P && mkdir -p "X" && cd "X" && pwd -P
        let quoted = command.components(separatedBy: "mkdir -p \"")[1].components(separatedBy: "\"")[0]
        let path = quoted.replacingOccurrences(of: "$HOME", with: "/home/u")
        return ProcessResult(exitCode: 0, stdout: "/home/u\n\(path)\n", stderr: "")
    }

    /// Answer to "cd && pwd -P" on its own.
    var home = ProcessResult(exitCode: 0, stdout: "/home/u\n", stderr: "")

    var calls: [(executable: String, arguments: [String])] { lock.withLock { _calls } }
    var remoteCommands: [String] { calls.filter { $0.executable == "/usr/bin/ssh" }.compactMap(\.arguments.last) }
    var contactedServer: Bool { !calls.filter { $0.executable == "/usr/bin/ssh" }.isEmpty }

    func run(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
        lock.withLock { _calls.append((executable, arguments)) }
        if executable == "/usr/bin/ssh-keygen" { return keygen }
        let command = arguments.last ?? ""
        if command == "rsync --version" { return version }
        if command == "cd && pwd -P" { return home }
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
                       verifiedHome: verifiedServer.isEmpty ? "" : "/home/u")
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
                : ProcessResult(exitCode: 0, stdout: "/home/u\n/home/u/Good\n", stderr: "")
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
        #expect(out.config.verifiedHome == "/home/u")
        #expect(out.config.isVerified)
        #expect(!p.remoteCommands.contains("cd && pwd -P")) // learnt while resolving
    }

    @Test func connectAsksForHomeWhenNothingIsResolved() async {
        let p = ScriptedProcess()
        p.home = ProcessResult(exitCode: 0, stdout: "banner\n/home/annan\n", stderr: "")
        var c = config(folders: [.init(path: "/Users/x/Done", remotePath: "/srv/Done")])
        c.verifiedHome = ""
        let out = await SetupFlow(process: p).connect(c)
        #expect(out.result == .ok(rsyncVersion: "3.2.7"))
        #expect(p.remoteCommands == ["rsync --version", "cd && pwd -P"])
        #expect(out.config.verifiedHome == "/home/annan" && out.config.isVerified)
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
        #expect(out.config.verifiedHome == "")
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
        p.resolve = { _ in ProcessResult(exitCode: 0, stdout: "/home/u\n/home/u/.ssh\n", stderr: "") }
        let out = await SetupFlow(process: p).addFolder(to: config(folders: []), localPath: "/Users/x/A", remoteEntered: "~/nycklar")
        #expect(out == .rejected(ConfigIssue.remotePathNotAllowed("/home/u/.ssh").message))
    }

    @Test func addFolderResolvesAndAppends() async {
        let p = ScriptedProcess()
        let c = config(folders: [.init(path: "/Users/x/Sync", remotePath: "/home/u/Sync")])
        let out = await SetupFlow(process: p).addFolder(to: c, localPath: "/Users/x/Pictures", remoteEntered: " ~/Pictures ")
        #expect(out == .added(Config(server: c.server, identityFile: c.identityFile, folders: [
            c.folders[0], .init(path: "/Users/x/Pictures", remotePath: "/home/u/Pictures"),
        ], verifiedServer: "u@h", verifiedHome: "/home/u")))
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
        q.resolve = { _ in ProcessResult(exitCode: 0, stdout: "/home/u\n/home/u\n", stderr: "") }
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
