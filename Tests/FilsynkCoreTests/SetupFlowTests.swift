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
        if command.contains("$HOME/") {
            let name = command.components(separatedBy: "$HOME/")[1].components(separatedBy: "\"")[0]
            return ProcessResult(exitCode: 0, stdout: "/home/u/\(name)\n", stderr: "")
        }
        return ProcessResult(exitCode: 0, stdout: "/srv/data\n", stderr: "")
    }

    var calls: [(executable: String, arguments: [String])] { lock.withLock { _calls } }
    var remoteCommands: [String] { calls.filter { $0.executable == "/usr/bin/ssh" }.compactMap(\.arguments.last) }
    var contactedServer: Bool { !calls.filter { $0.executable == "/usr/bin/ssh" }.isEmpty }

    func run(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
        lock.withLock { _calls.append((executable, arguments)) }
        if executable == "/usr/bin/ssh-keygen" { return keygen }
        let command = arguments.last ?? ""
        return command == "rsync --version" ? version : resolve(command)
    }
}

struct SetupFlowTests {
    private func tempKey() -> String {
        // Existing file so ensureKey does nothing unless a test removes it.
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("filsynk-flow-\(UUID().uuidString)").path
        FileManager.default.createFile(atPath: path, contents: Data())
        return path
    }

    private func config(server: String = "u@h", key: String? = nil, folders: [FolderConfig]) -> Config {
        var c = Config(server: server, folders: folders)
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
        #expect(p.remoteCommands.count == 2) // version check + one resolve
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
                : ProcessResult(exitCode: 0, stdout: "/home/u/Good\n", stderr: "")
        }
        let c = config(folders: [
            .init(path: "/Users/x/Good", remotePath: "~/Good"),
            .init(path: "/Users/x/Bad", remotePath: "~/Bad"),
        ])
        let out = await SetupFlow(process: p).connect(c)
        guard case .failed(let message) = out.result else { Issue.record("expected failure"); return }
        #expect(message.hasPrefix("Kunde inte skapa mappen på servern"))
        #expect(out.config.folders.map(\.remotePath) == ["/home/u/Good", "~/Bad"])
    }

    // MARK: addFolder

    @Test func addFolderResolvesAndAppends() async {
        let p = ScriptedProcess()
        let c = config(folders: [.init(path: "/Users/x/Sync", remotePath: "/home/u/Sync")])
        let out = await SetupFlow(process: p).addFolder(to: c, localPath: "/Users/x/Pictures", remoteEntered: " ~/Pictures ")
        #expect(out == .added(Config(server: c.server, identityFile: c.identityFile, folders: [
            c.folders[0], .init(path: "/Users/x/Pictures", remotePath: "/home/u/Pictures"),
        ])))
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

    @Test func addFolderNeedsServer() async {
        let p = ScriptedProcess()
        let out = await SetupFlow(process: p).addFolder(to: config(server: "", folders: []), localPath: "/Users/x/A", remoteEntered: "~/A")
        #expect(out == .rejected("Ange serveradressen först."))
        #expect(!p.contactedServer)
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
