import Testing
import Foundation
@testable import FilsynkCore

/// Locates an rsync 3.x binary for integration tests. Never `/usr/bin/rsync` (openrsync).
enum IntegrationRsync {
    static let path: String? = {
        let candidate = ProcessInfo.processInfo.environment["FILSYNK_TEST_RSYNC"] ?? "/opt/homebrew/bin/rsync"
        guard candidate != "/usr/bin/rsync",
              FileManager.default.isExecutableFile(atPath: candidate) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: candidate)
        p.arguments = ["--version"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let first = String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
        return first.hasPrefix("rsync  version 3.") ? candidate : nil
    }()
}

@Suite(.enabled(if: IntegrationRsync.path != nil, "Kräver rsync 3.x (brew install rsync)"))
struct SyncIntegrationTests {
    let root: URL
    let source: URL
    let dest: URL
    let config: Config
    let runner: SyncRunner

    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("filsynk-interop-\(UUID().uuidString)")
        try Self.makeDirs(root: root, sourceName: "src")
        source = root.appendingPathComponent("src")
        dest = root.appendingPathComponent("dest")
        var c = Config(server: "unused", exclude: ["*.tmp"])
        c.rsyncPath = IntegrationRsync.path ?? "/nonexistent"
        config = c
        runner = SyncRunner(process: SystemProcessRunner(), target: .localForTesting, timeZone: TimeZone(identifier: "UTC")!)
    }

    private static func makeDirs(root: URL, sourceName: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent(sourceName), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("dest"), withIntermediateDirectories: true)
    }

    // Each sync gets a distinct, increasing "now" so Raderat folders never collide.
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)
    private func run(_ n: Int, source src: URL? = nil) async -> SyncOutcome {
        let folder = FolderConfig(path: (src ?? source).path, remotePath: dest.path)
        return await runner.sync(folder: folder, destination: .server(path: dest.path), config: config, now: Self.base.addingTimeInterval(Double(n) * 10))
    }

    private func write(_ name: String, _ text: String, in dir: URL? = nil) throws {
        try text.write(to: (dir ?? source).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private var raderat: URL { dest.appendingPathComponent("Raderat") }
    private func raderatFolders() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: raderat.path)) ?? []).sorted()
    }

    @Test func newFileArrives() async throws {
        try write("a.txt", "hej")
        #expect(await run(0) == .success)
        #expect(read(dest.appendingPathComponent("a.txt")) == "hej")
    }

    @Test func overwrittenFileGoesToRaderat() async throws {
        try write("a.txt", "gammalt")
        #expect(await run(0) == .success)
        try write("a.txt", "nytt")
        #expect(await run(1) == .success)
        #expect(read(dest.appendingPathComponent("a.txt")) == "nytt")
        let folders = raderatFolders()
        #expect(folders.count == 1)
        #expect(read(raderat.appendingPathComponent(folders.first ?? "-").appendingPathComponent("a.txt")) == "gammalt")
    }

    @Test func deletedFileGoesToRaderat() async throws {
        try write("a.txt", "innehåll")
        #expect(await run(0) == .success)
        try FileManager.default.removeItem(at: source.appendingPathComponent("a.txt"))
        #expect(await run(1) == .success)
        #expect(!exists(dest.appendingPathComponent("a.txt")))
        let folders = raderatFolders()
        #expect(folders.count == 1)
        #expect(read(raderat.appendingPathComponent(folders.first ?? "-").appendingPathComponent("a.txt")) == "innehåll")
    }

    @Test func secondSyncGetsItsOwnRaderatFolder() async throws {
        try write("a.txt", "ett")
        #expect(await run(0) == .success)
        try write("a.txt", "två")
        #expect(await run(1) == .success)
        try write("a.txt", "tre")
        #expect(await run(2) == .success)
        let folders = raderatFolders()
        #expect(folders.count == 2)
        #expect(Set(folders).count == 2)
        let contents = folders.compactMap { read(raderat.appendingPathComponent($0).appendingPathComponent("a.txt")) }
        #expect(contents.sorted() == ["ett", "två"])
    }

    @Test func raderatSurvivesAnUnchangedSync() async throws {
        try write("a.txt", "ett")
        #expect(await run(0) == .success)
        try write("a.txt", "två")
        #expect(await run(1) == .success)
        let before = raderatFolders()
        #expect(before.count == 1)
        #expect(await run(2) == .success)
        #expect(raderatFolders() == before)
        #expect(read(raderat.appendingPathComponent(before.first ?? "-").appendingPathComponent("a.txt")) == "ett")
    }

    @Test func localRaderatFolderIsNotBackedUp() async throws {
        try write("a.txt", "hej")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Raderat/old"), withIntermediateDirectories: true)
        try write("Raderat/old/x.txt", "lokalt", in: source)
        #expect(await run(0) == .success)
        #expect(read(dest.appendingPathComponent("a.txt")) == "hej")
        #expect(!exists(dest.appendingPathComponent("Raderat/old/x.txt")))
    }

    @Test func userExcludeIsRespected() async throws {
        try write("keep.txt", "k")
        try write("x.tmp", "t")
        #expect(await run(0) == .success)
        #expect(exists(dest.appendingPathComponent("keep.txt")))
        #expect(!exists(dest.appendingPathComponent("x.tmp")))
    }

    @Test func unicodeNameIsStable() async throws {
        try write("Räksmörgås anteckning.txt", "gott")
        #expect(await run(0) == .success)
        #expect(await run(1) == .success)
        #expect(read(dest.appendingPathComponent("Räksmörgås anteckning.txt")) == "gott")
        #expect(!exists(raderat))
    }

    @Test func localPathWithSpaceWorks() async throws {
        let spaced = root.appendingPathComponent("Mina filer")
        try FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: true)
        try write("a.txt", "hej", in: spaced)
        #expect(await run(0, source: spaced) == .success)
        #expect(read(dest.appendingPathComponent("a.txt")) == "hej")
    }
}
