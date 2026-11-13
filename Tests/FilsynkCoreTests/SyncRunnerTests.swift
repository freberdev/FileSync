import Testing
import Foundation
@testable import FilsynkCore

final class FakeProcess: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(executable: String, arguments: [String])] = []
    var result: ProcessResult = ProcessResult(exitCode: 0, stdout: "", stderr: "")
    var error: (any Error)?
    var onRun: (@Sendable (String, [String]) -> Void)?

    var calls: [(executable: String, arguments: [String])] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func run(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
        lock.withLock { _calls.append((executable, arguments)) }
        onRun?(executable, arguments)
        if let error { throw error }
        return result
    }
}

struct LaunchError: Error, CustomStringConvertible { var description: String { "boom" } }

final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    func add(_ s: String) { lock.lock(); _lines.append(s); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
}

struct SyncRunnerTests {
    let config = Config(server: "user@host", folders: [])

    private func makeSourceDir() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("filsynk-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func backupDir(_ call: (executable: String, arguments: [String])) -> String? {
        call.arguments.first { $0.hasPrefix("--backup-dir=") }
    }

    @Test func missingSourceFailsWithoutRunningAnything() async {
        let fake = FakeProcess()
        let runner = SyncRunner(process: fake)
        let o = await runner.sync(folder: .init(path: "/nonexistent/zzz", remotePath: "/r"), config: config, now: .now)
        #expect(o == .failed("Mappen /nonexistent/zzz saknas eller går inte att läsa"))
        #expect(fake.calls.isEmpty)
    }

    @Test func fileInsteadOfDirectoryFails() async throws {
        let dir = try makeSourceDir()
        let file = dir + "/f.txt"
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        let fake = FakeProcess()
        let o = await SyncRunner(process: fake).sync(folder: .init(path: file, remotePath: "/r"), config: config, now: .now)
        #expect(o == .failed("Mappen \(file) saknas eller går inte att läsa"))
        #expect(fake.calls.isEmpty)
    }

    @Test func timestampsNeverRepeat() async throws {
        let dir = try makeSourceDir()
        let fake = FakeProcess()
        let runner = SyncRunner(process: fake, timeZone: TimeZone(identifier: "UTC")!)
        let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
        let folder = FolderConfig(path: dir, remotePath: "/r")
        _ = await runner.sync(folder: folder, config: config, now: now)
        _ = await runner.sync(folder: folder, config: config, now: now)
        let calls = fake.calls
        #expect(calls.count == 2)
        #expect(backupDir(calls[0]) == "--backup-dir=/r/Raderat/2023-11-14_221320")
        #expect(backupDir(calls[1]) == "--backup-dir=/r/Raderat/2023-11-14_221321")
    }

    @Test func laterNowIsUsedAsIs() async throws {
        let dir = try makeSourceDir()
        let fake = FakeProcess()
        let runner = SyncRunner(process: fake, timeZone: TimeZone(identifier: "UTC")!)
        let folder = FolderConfig(path: dir, remotePath: "/r")
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await runner.sync(folder: folder, config: config, now: t)
        _ = await runner.sync(folder: folder, config: config, now: t.addingTimeInterval(10))
        #expect(backupDir(fake.calls[1]) == "--backup-dir=/r/Raderat/2023-11-14_221330")
    }

    @Test func classifiesProcessResult() async throws {
        let dir = try makeSourceDir()
        let fake = FakeProcess()
        fake.result = ProcessResult(exitCode: 255, stdout: "", stderr: "ssh: connect to host x port 22: Connection refused\n")
        let o = await SyncRunner(process: fake).sync(folder: .init(path: dir, remotePath: "/r"), config: config, now: .now)
        #expect(o == .unreachable)
    }

    @Test func launchFailureBecomesFailed() async throws {
        let dir = try makeSourceDir()
        let fake = FakeProcess()
        fake.error = LaunchError()
        let sink = LogSink()
        let o = await SyncRunner(process: fake, log: { sink.add($0) })
            .sync(folder: .init(path: dir, remotePath: "/r"), config: config, now: .now)
        #expect(o == .failed("Kunde inte starta rsync: \(LaunchError().localizedDescription)"))
        #expect(sink.lines.contains { $0.contains("kunde inte starta rsync: boom") })
    }

    @Test func excludeFileFailureHasItsOwnText() async throws {
        let dir = try makeSourceDir()
        let fake = FakeProcess()
        let sink = LogSink()
        let missing = URL(fileURLWithPath: "/nonexistent-filsynk-\(UUID().uuidString)")
        let o = await SyncRunner(process: fake, temporaryDirectory: missing, log: { sink.add($0) })
            .sync(folder: .init(path: dir, remotePath: "/r"), config: config, now: .now)
        #expect(o == .failed("Kunde inte förbereda synken"))
        #expect(fake.calls.isEmpty)
        #expect(sink.lines.contains { $0.contains("undantagsfilen") })
    }

    @Test func excludeFileExistsDuringRunAndIsRemovedAfter() async throws {
        let dir = try makeSourceDir()
        let fake = FakeProcess()
        let seen = LogSink()
        var cfg = config
        cfg.exclude = ["*.tmp"]
        fake.onRun = { _, args in
            guard let arg = args.first(where: { $0.hasPrefix("--exclude-from=") }) else { return }
            let path = String(arg.dropFirst("--exclude-from=".count))
            seen.add(path)
            seen.add((try? String(contentsOfFile: path, encoding: .utf8)) ?? "<unreadable>")
        }
        _ = await SyncRunner(process: fake).sync(folder: .init(path: dir, remotePath: "/r"), config: cfg, now: .now)
        let lines = seen.lines
        #expect(lines.count == 2)
        #expect(lines[1] == RsyncCommand.excludeFileContents(cfg))
        #expect(!FileManager.default.fileExists(atPath: lines[0]))
    }

    @Test func excludeFileIsRemovedAlsoWhenLaunchFails() async throws {
        let dir = try makeSourceDir()
        let fake = FakeProcess()
        fake.error = LaunchError()
        let seen = LogSink()
        fake.onRun = { _, args in
            if let arg = args.first(where: { $0.hasPrefix("--exclude-from=") }) {
                seen.add(String(arg.dropFirst("--exclude-from=".count)))
            }
        }
        _ = await SyncRunner(process: fake).sync(folder: .init(path: dir, remotePath: "/r"), config: config, now: .now)
        #expect(seen.lines.count == 1)
        #expect(!FileManager.default.fileExists(atPath: seen.lines[0]))
    }

    @Test func logsOneLinePerRun() async throws {
        let dir = try makeSourceDir()
        let fake = FakeProcess()
        let sink = LogSink()
        let runner = SyncRunner(process: fake, log: { sink.add($0) })
        _ = await runner.sync(folder: .init(path: dir, remotePath: "/r"), config: config, now: .now)
        #expect(sink.lines.count == 1)
        #expect(sink.lines[0].contains(dir))
    }
}
