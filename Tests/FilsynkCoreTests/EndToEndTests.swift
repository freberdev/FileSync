import Testing
import Foundation
@testable import FilsynkCore

/// End-to-end test against the real server. Opt-in: set both
///   FILSYNK_E2E_SERVER=user@host  FILSYNK_E2E_IDENTITY=~/.ssh/filsynk_ed25519
/// Writes only in a fresh temporary local directory and in `~/filsynk-interop-e2e-<hex>` on the
/// server, which the test removes at the end (test tooling only; the app never deletes remotely).
private enum E2EEnvironment {
    static let server = ProcessInfo.processInfo.environment["FILSYNK_E2E_SERVER"]
    static let identity = ProcessInfo.processInfo.environment["FILSYNK_E2E_IDENTITY"]
    static var isConfigured: Bool { !(server ?? "").isEmpty && !(identity ?? "").isEmpty }
}

/// Collects everything the engine reports.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _statuses: [EngineStatus] = []
    private var _notices: [Notice] = []

    func status(_ s: EngineStatus) { lock.lock(); _statuses.append(s); lock.unlock() }
    func notice(_ n: Notice) { lock.lock(); _notices.append(n); lock.unlock() }
    var statuses: [EngineStatus] { lock.lock(); defer { lock.unlock() }; return _statuses }
    var notices: [Notice] { lock.lock(); defer { lock.unlock() }; return _notices }
    var lastFolderState: FolderState? { statuses.last?.folders.first?.state }
}

/// Runs commands on the server through /usr/bin/ssh with the app's ssh options.
private struct Remote {
    let server: String
    let identity: String
    let process = SystemProcessRunner()

    func run(_ command: String) async throws -> ProcessResult {
        try await process.run(
            "/usr/bin/ssh", RsyncCommand.sshArguments(identityFile: identity) + ["--", server, command])
    }

    /// stdout of a successful command, or nil.
    func output(_ command: String) async -> String? {
        guard let r = try? await run(command), r.exitCode == 0 else { return nil }
        return r.stdout
    }

    func lines(_ command: String) async -> [String] {
        (await output(command) ?? "").split(whereSeparator: \.isNewline).map(String.init)
    }

    func read(_ path: String) async -> String? { await output("cat '\(path)'") }

    func exists(_ path: String) async -> Bool { (try? await run("test -e '\(path)'"))?.exitCode == 0 }

    /// Deletes the test directory, and only that: last component starts with filsynk-interop-e2e-
    /// and the parent is the remote home.
    func cleanUp(_ path: String) async -> String? {
        guard let home = (await output("cd && pwd -P"))?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return "cleanup refused: cannot determine remote home"
        }
        let url = URL(fileURLWithPath: path)
        guard path.hasPrefix("/"), url.lastPathComponent.hasPrefix("filsynk-interop-e2e-"),
              url.deletingLastPathComponent().path == home, path != home else {
            return "cleanup refused for \(path) (home \(home))"
        }
        guard let r = try? await run("rm -rf -- '\(path)'"), r.exitCode == 0 else {
            return "cleanup failed for \(path)"
        }
        return nil
    }
}

private func eventually(timeout: TimeInterval = 30, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(500))
    }
    return await condition()
}

@Suite(.enabled(if: E2EEnvironment.isConfigured, "Kräver FILSYNK_E2E_SERVER och FILSYNK_E2E_IDENTITY"))
struct EndToEndTests {
    @Test(.timeLimit(.minutes(5))) func wholeStackAgainstRealServer() async throws {
        let server = try #require(E2EEnvironment.server)
        let identity = try #require(E2EEnvironment.identity)
        let remote = Remote(server: server, identity: identity)

        let hex = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        let remoteName = "filsynk-interop-e2e-\(hex)"
        let local = URL(fileURLWithPath: NSTemporaryDirectory())
            .resolvingSymlinksInPath()
            .appendingPathComponent("filsynk-interop-e2e-local-\(hex)")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)

        var config = Config(
            server: server, identityFile: identity, quietSeconds: 1, maxWaitSeconds: 5,
            folders: [FolderConfig(path: local.path, remotePath: "~/\(remoteName)")])
        let flow = SetupFlow(process: SystemProcessRunner())

        // 1. Connect (one retry of the very first connection: "No route to host" after idle).
        var (result, connected) = await flow.connect(config)
        if result == .unreachable {
            try await Task.sleep(for: .seconds(2))
            (result, connected) = await flow.connect(config)
        }
        config = connected
        let remotePath = config.folders[0].remotePath

        var failure: (any Error)?
        do {
            try await scenarios(
                remote: remote, config: config, result: result, local: local,
                remotePath: remotePath, remoteName: remoteName)
        } catch {
            failure = error
        }

        // Cleanup: always, and only our own directory.
        let cleanupProblem = remotePath.hasPrefix("/") ? await remote.cleanUp(remotePath) : nil
        try? FileManager.default.removeItem(at: local)
        #expect(cleanupProblem == nil, Comment(rawValue: cleanupProblem ?? ""))
        if remotePath.hasPrefix("/") {
            #expect(await remote.exists(remotePath) == false, "testkatalogen finns kvar på servern")
        }
        if let failure { throw failure }
    }

    private func scenarios(
        remote: Remote, config: Config, result: ConnectionResult, local: URL,
        remotePath: String, remoteName: String
    ) async throws {
        // 1. Connection result, verified config, absolute remote path.
        guard case .ok(let version) = result else {
            Issue.record("connect gav \(result)")
            throw CancellationError()
        }
        #expect(version.hasPrefix("3."), "rsync-version \(version)")
        #expect(config.isVerified)
        #expect(remotePath.hasPrefix("/") && remotePath.hasSuffix("/" + remoteName), "remotePath \(remotePath)")
        try #require(remotePath.hasPrefix("/"))

        let recorder = Recorder()
        let runner = SyncRunner(process: SystemProcessRunner(), target: .ssh)
        let engine = SyncEngine(
            config: config,
            timing: EngineTiming(quiet: 1, maxWait: 5, backoff: [2, 4], noticeCheckInterval: 60),
            runner: runner,
            makeWatcher: { path, onChange in FolderWatcher(path: path, onChange: onChange) },
            network: SystemNetworkMonitor(),
            onStatus: { recorder.status($0) },
            onNotice: { recorder.notice($0) })

        func rm(_ name: String) { try? FileManager.default.removeItem(at: local.appendingPathComponent(name)) }
        func write(_ name: String, _ text: String) throws {
            try text.write(to: local.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        /// Waits for a sync that starts and finishes after this call.
        @Sendable func waitForSyncCycle(after index: Int) async -> Bool {
            await eventually {
                let tail = Array(recorder.statuses.dropFirst(index))
                guard let started = tail.firstIndex(where: { $0.folders.first?.state == .syncing }) else { return false }
                return tail[started...].contains { $0.folders.first?.state == .synced }
            }
        }
        @Sendable func raderatDirs() async -> [String] { await remote.lines("ls -1 '\(remotePath)/Raderat' 2>/dev/null") }
        @Sendable func raderatFiles(named name: String) async -> [String: String] {
            var found: [String: String] = [:]
            for dir in await raderatDirs() {
                if let text = await remote.read("\(remotePath)/Raderat/\(dir)/\(name)") { found[dir] = text }
            }
            return found
        }

        await engine.start()

        // 2. Watcher -> quiet period -> sync, without any explicit sync call.
        try write("prov.txt", "v1")
        let arrived = await eventually { await remote.read("\(remotePath)/prov.txt") == "v1" }
        #expect(arrived, "prov.txt kom inte fram; status \(String(describing: recorder.lastFolderState))")
        try #require(arrived)

        // 3. Overwrite -> new content, old one in exactly one Raderat/<timestamp>/.
        try write("prov.txt", "v2-längre")
        #expect(await eventually { await remote.read("\(remotePath)/prov.txt") == "v2-längre" })
        #expect(await eventually { await raderatFiles(named: "prov.txt").count == 1 })
        let afterOverwrite = await raderatFiles(named: "prov.txt")
        #expect(afterOverwrite.count == 1 && afterOverwrite.values.first == "v1", "Raderat efter överskrivning: \(afterOverwrite)")
        let stamp = try Regex(#"^\d{4}-\d{2}-\d{2}_\d{6}$"#)
        for dir in afterOverwrite.keys { #expect(dir.wholeMatch(of: stamp) != nil, "tidsstämpel \(dir)") }

        // 4. Delete -> gone, a second Raderat/<timestamp>/ holds v2.
        rm("prov.txt")
        #expect(await eventually { await remote.exists("\(remotePath)/prov.txt") == false })
        #expect(await eventually { await raderatFiles(named: "prov.txt").count == 2 })
        let afterDelete = await raderatFiles(named: "prov.txt")
        #expect(Set(afterDelete.values) == ["v1", "v2-längre"], "Raderat efter radering: \(afterDelete)")
        #expect(afterDelete.count == 2 && Set(afterDelete.keys).count == 2)

        // 5. Unicode + spaces: NFC and NFD spelling, then one more sync must not move anything to Raderat/.
        let nfc = "Räksmörgås anteckning.txt".precomposedStringWithCanonicalMapping
        let nfd = "Räksmörgås anteckning.txt".decomposedStringWithCanonicalMapping
        try write(nfc, "nfc")
        var unicodeNames = [nfc]
        if !FileManager.default.fileExists(atPath: local.appendingPathComponent(nfd).path) {
            try write(nfd, "nfd")
            unicodeNames.append(nfd)
        }
        let localListing = (try? FileManager.default.contentsOfDirectory(atPath: local.path)) ?? []
        let remoteHasUnicode = await eventually {
            let names = await remote.lines("ls -1 '\(remotePath)'")
            return names.filter { $0.contains("anteckning") }.count == localListing.filter { $0.contains("anteckning") }.count
        }
        let serverListing = await remote.lines("ls -1 '\(remotePath)'")
        #expect(remoteHasUnicode, "unicode-filer kom inte fram; lokalt \(localListing), server \(serverListing)")
        // Let the engine go quiet, then compare Raderat/ before and after a forced sync.
        #expect(await eventually { recorder.lastFolderState == .synced })
        try await Task.sleep(for: .seconds(3))
        let raderatBefore = await raderatDirs()
        let mark = recorder.statuses.count
        await engine.syncNow()
        #expect(await waitForSyncCycle(after: mark), "syncNow gav ingen synkcykel")
        let raderatAfter = await raderatDirs()
        let unicodeInRaderat = await remote.lines("find '\(remotePath)/Raderat' -name '*anteckning*'")
        #expect(raderatBefore == raderatAfter && unicodeInRaderat.isEmpty,
                "unicode ej stabilt. lokalt \(localListing.map { Array($0.unicodeScalars.prefix(4)).map(\.value) }), server \(serverListing), Raderat före \(raderatBefore) efter \(raderatAfter), träffar \(unicodeInRaderat)")
        _ = unicodeNames

        // 6. Pause: nothing is sent while paused; resuming sends.
        await engine.setPaused(true)
        try write("paus.txt", "p")
        try await Task.sleep(for: .seconds(6))
        #expect(await remote.exists("\(remotePath)/paus.txt") == false, "paus.txt skickades under pausen")
        await engine.setPaused(false)
        #expect(await eventually { await remote.read("\(remotePath)/paus.txt") == "p" })

        // 8. A local top-level folder named Raderat is not uploaded.
        let localRaderat = local.appendingPathComponent("Raderat")
        try FileManager.default.createDirectory(at: localRaderat, withIntermediateDirectories: true)
        try "x".write(to: localRaderat.appendingPathComponent("lokal-raderat.txt"), atomically: true, encoding: .utf8)
        let markRaderat = recorder.statuses.count
        try write("efter-raderat.txt", "e")
        #expect(await eventually { await remote.read("\(remotePath)/efter-raderat.txt") == "e" })
        _ = markRaderat
        #expect(await remote.lines("find '\(remotePath)' -name 'lokal-raderat.txt'").isEmpty,
                "lokal Raderat/ laddades upp")

        // 7. Status ends at .synced and no notice was emitted at any point.
        #expect(await eventually { recorder.lastFolderState == .synced },
                "slutstatus \(String(describing: recorder.lastFolderState))")
        #expect(recorder.notices.isEmpty, "notiser: \(recorder.notices)")

        await engine.stop()
    }
}
