import Testing
import Foundation
@testable import FilsynkCore

struct ConnectionSetupTests {
    let server = "user@host"
    let key = "~/.ssh/filsynk_ed25519"

    private func fake(exit: Int32 = 0, out: String = "", err: String = "") -> FakeProcess {
        let f = FakeProcess()
        f.result = ProcessResult(exitCode: exit, stdout: out, stderr: err)
        return f
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("filsynk-conn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func parsesGnuRsync() {
        let v = ConnectionSetup.parseRsyncVersion("rsync  version 3.2.7  protocol version 31")
        #expect(v?.major == 3 && v?.minor == 2 && v?.patch == 7)
    }

    @Test func parsesTwoPartVersion() {
        let v = ConnectionSetup.parseRsyncVersion("rsync  version 3.4  protocol version 32")
        #expect(v?.major == 3 && v?.minor == 4 && v?.patch == 0)
    }

    @Test func openrsyncIsNotAVersion() {
        #expect(ConnectionSetup.parseRsyncVersion("openrsync: protocol version 29") == nil)
    }

    @Test func garbageIsNotAVersion() {
        #expect(ConnectionSetup.parseRsyncVersion("hello") == nil)
    }

    @Test func copyIdCommandText() {
        #expect(ConnectionSetup.copyIdCommand(identityFile: "~/.ssh/filsynk_ed25519", server: "user@192.168.1.10")
            == "ssh-copy-id -i ~/.ssh/filsynk_ed25519.pub user@192.168.1.10")
    }

    @Test func checkOk() async {
        let f = fake(out: "rsync  version 3.2.7  protocol version 31\nCopyright...\n")
        let r = await ConnectionSetup(process: f).check(server: server, identityFile: key)
        #expect(r == .ok(rsyncVersion: "3.2.7"))
        #expect(f.calls.first?.executable == "/usr/bin/ssh")
        #expect(f.calls.first?.arguments.suffix(3) == ["--", server, "rsync --version"])
    }

    @Test func checkRejectsOld() async {
        let f = fake(out: "rsync  version 2.6.9  protocol version 29\n")
        let r = await ConnectionSetup(process: f).check(server: server, identityFile: key)
        #expect(r == .unsupportedRsync("rsync  version 2.6.9  protocol version 29"))
    }

    @Test func checkRejectsOpenrsync() async {
        let f = fake(out: "openrsync: protocol version 29\n")
        let r = await ConnectionSetup(process: f).check(server: server, identityFile: key)
        #expect(r == .unsupportedRsync("openrsync: protocol version 29"))
    }

    @Test func checkMapsAuthAndUnreachable() async {
        let a = await ConnectionSetup(process: fake(exit: 255, err: "Permission denied (publickey).\n"))
            .check(server: server, identityFile: key)
        #expect(a == .authDenied)
        let u = await ConnectionSetup(process: fake(exit: 255, err: "ssh: connect to host x port 22: Connection refused\n"))
            .check(server: server, identityFile: key)
        #expect(u == .unreachable)
    }

    @Test func checkMapsMissingRsync() async {
        let r = await ConnectionSetup(process: fake(exit: 127, err: "bash: rsync: command not found\n"))
            .check(server: server, identityFile: key)
        #expect(r == .unsupportedRsync("rsync finns inte på servern"))
    }

    @Test func checkMapsOtherFailure() async {
        let r = await ConnectionSetup(process: fake(exit: 1, err: "something odd\n"))
            .check(server: server, identityFile: key)
        #expect(r == .failed("something odd"))
    }

    @Test func checkMapsLaunchError() async {
        let f = FakeProcess()
        f.error = LaunchError()
        let r = await ConnectionSetup(process: f).check(server: server, identityFile: key)
        guard case .failed = r else { Issue.record("expected .failed, got \(r)"); return }
    }

    @Test func checkUsesBatchModeAndIdentityOnly() async {
        let f = fake(out: "rsync  version 3.2.7  protocol version 31\n")
        _ = await ConnectionSetup(process: f).check(server: server, identityFile: key)
        let args = f.calls.first?.arguments ?? []
        #expect(args.contains("BatchMode=yes"))
        #expect(args.contains("IdentitiesOnly=yes"))
    }

    @Test func ensureKeySkipsExistingFile() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("key").path
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        let f = FakeProcess()
        let created = try await ConnectionSetup(process: f).ensureKey(identityFile: path)
        #expect(created == false)
        #expect(f.calls.isEmpty)
    }

    @Test func ensureKeyRunsKeygenWhenMissing() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("key").path
        let f = FakeProcess()
        let created = try await ConnectionSetup(process: f).ensureKey(identityFile: path)
        #expect(created == true)
        #expect(f.calls.count == 1)
        #expect(f.calls.first?.executable == "/usr/bin/ssh-keygen")
        #expect(f.calls.first?.arguments == ["-t", "ed25519", "-N", "", "-C", "filsynk", "-f", path])
    }

    @Test func ensureKeyThrowsWhenKeygenFails() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("key").path
        let f = fake(exit: 1, err: "boom")
        await #expect(throws: ConnectionError.self) {
            _ = try await ConnectionSetup(process: f).ensureKey(identityFile: path)
        }
    }

    @Test func resolveExpandsTildeToHome() async throws {
        let f = fake(out: "/home/u/Sync\n")
        let p = try await ConnectionSetup(process: f).resolveRemotePath("~/Sync", server: server, identityFile: key)
        #expect(p == "/home/u/Sync")
        let command = f.calls.first?.arguments.last ?? ""
        #expect(command == "mkdir -p \"$HOME/Sync\" && cd \"$HOME/Sync\" && pwd -P")
        #expect(f.calls.first?.executable == "/usr/bin/ssh")
    }

    @Test func resolveBareTildeAndAbsolute() async throws {
        let f = fake(out: "/home/u\n")
        _ = try await ConnectionSetup(process: f).resolveRemotePath("~", server: server, identityFile: key)
        #expect(f.calls.last?.arguments.last == "mkdir -p \"$HOME\" && cd \"$HOME\" && pwd -P")
        _ = try await ConnectionSetup(process: f).resolveRemotePath("/srv/x", server: server, identityFile: key)
        #expect(f.calls.last?.arguments.last == "mkdir -p \"/srv/x\" && cd \"/srv/x\" && pwd -P")
    }

    @Test func resolveRejectsUnsafePath() async {
        for bad in ["~/a b", "~/a$(x)"] {
            let f = FakeProcess()
            await #expect(throws: ConnectionError.self) {
                _ = try await ConnectionSetup(process: f).resolveRemotePath(bad, server: server, identityFile: key)
            }
            #expect(f.calls.isEmpty)
        }
    }

    @Test func resolveRejectsNonAbsoluteOutput() async {
        let f = fake(out: "oops\n")
        await #expect(throws: ConnectionError.self) {
            _ = try await ConnectionSetup(process: f).resolveRemotePath("~/Sync", server: server, identityFile: key)
        }
    }

    @Test func resolveReportsRemoteFailure() async {
        let f = fake(exit: 255, err: "Permission denied (publickey).\n")
        do {
            _ = try await ConnectionSetup(process: f).resolveRemotePath("~/Sync", server: server, identityFile: key)
            Issue.record("expected throw")
        } catch let e as ConnectionError {
            #expect(e == .remoteCommandFailed(.authDenied))
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test func validateFlagsUnsafeServer() {
        for bad in ["-oProxyCommand=x", "a b@host", "u@h\tx", "u@h$x"] {
            #expect(Config(server: bad).validate().contains(.unsafeServer(bad)))
        }
        for good in ["user@host", "host", ""] {
            #expect(Config(server: good).validate().isEmpty)
        }
    }

    @Test func checkRejectsUnsafeServerWithoutProcess() async {
        for bad in ["-oProxyCommand=x", "a b", ""] {
            let f = FakeProcess()
            let r = await ConnectionSetup(process: f).check(server: bad, identityFile: key)
            #expect(r == .failed("Serveradressen är ogiltig"))
            #expect(f.calls.isEmpty)
        }
    }

    @Test func resolveRejectsUnsafeServerWithoutProcess() async {
        for bad in ["-oProxyCommand=x", "a b", ""] {
            let f = FakeProcess()
            await #expect(throws: ConnectionError.unsafeServer) {
                _ = try await ConnectionSetup(process: f).resolveRemotePath("~/Sync", server: bad, identityFile: key)
            }
            #expect(f.calls.isEmpty)
        }
    }

    @Test func sshArgumentsPutDoubleDashBeforeServer() async throws {
        let f = fake(out: "/home/u/Sync\n")
        _ = try await ConnectionSetup(process: f).resolveRemotePath("~/Sync", server: "user@host", identityFile: key)
        let args = f.calls.first?.arguments ?? []
        #expect(args.count >= 3 && args[args.count - 3] == "--" && args[args.count - 2] == "user@host")
    }
}
