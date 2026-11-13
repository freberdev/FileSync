import Foundation
import Testing
@testable import FilsynkCore

/// Thread-safe counter for callbacks arriving on the watcher's queue.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()  // guards `value`
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite struct FolderWatcherTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("filsynk-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test(.timeLimit(.minutes(1))) func reportsChangeInSubfolder() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let counter = CallCounter()
        let watcher = FolderWatcher(path: dir.path, latency: 0.2) { counter.increment() }
        watcher.start()
        defer { watcher.stop() }

        try "hej".write(to: sub.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let deadline = Date().addingTimeInterval(10)
        while counter.count == 0 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(counter.count > 0)
    }

    @Test(.timeLimit(.minutes(1))) func stopSilencesFurtherChanges() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let counter = CallCounter()
        let watcher = FolderWatcher(path: dir.path, latency: 0.2) { counter.increment() }
        watcher.start()
        defer { watcher.stop() }

        try "hej".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(10)
        while counter.count == 0 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(counter.count > 0)

        watcher.stop()
        let countAfterStop = counter.count
        try "mer".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(3))
        #expect(counter.count == countAfterStop)
    }

    @Test func startAndStopTwiceAreHarmless() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = FolderWatcher(path: dir.path, latency: 0.2) {}
        watcher.stop()
        watcher.start()
        watcher.start()
        watcher.stop()
        watcher.stop()
    }
}
