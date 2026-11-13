import Testing
import Foundation
@testable import FilsynkCore

struct FolderInspectorTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("filsynk-inspect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func countsRegularFilesRecursively() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("1".utf8).write(to: dir.appendingPathComponent("one"))
        try Data("2".utf8).write(to: dir.appendingPathComponent("a/two"))
        try Data("3".utf8).write(to: sub.appendingPathComponent("three"))
        let r = FolderInspector.inspect(path: dir.path)
        #expect(r.fileCount == 3)
        #expect(r.cloudOnlyCount == 0)
        #expect(r.hasReservedRaderat == false)
        #expect(r.warnings == [])
    }

    @Test func doesNotFollowSymlinks() throws {
        let dir = try tempDir()
        let outside = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: outside) }
        try Data("1".utf8).write(to: outside.appendingPathComponent("f"))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: outside)
        #expect(FolderInspector.inspect(path: dir.path).fileCount == 0)
    }

    @Test func detectsReservedRaderat() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Raderat"), withIntermediateDirectories: true)
        let r = FolderInspector.inspect(path: dir.path)
        #expect(r.hasReservedRaderat)
        #expect(r.warnings == ["Mappen \"Raderat\" i toppnivån säkerhetskopieras inte. Namnet är reserverat."])
    }

    @Test func missingFolderGivesEmptyReport() {
        let r = FolderInspector.inspect(path: "/nonexistent-filsynk-\(UUID().uuidString)")
        #expect(r.fileCount == 0)
        #expect(r.warnings == [])
    }

    @Test func warnsAboveThreshold() {
        let r = FolderReport(fileCount: 100_001, cloudOnlyCount: 0, cloudOnlyBytes: 0, hasReservedRaderat: false)
        #expect(r.warnings == ["Mappen innehåller 100001 filer. Över 100 000 kan synken bli märkbar. Lägg till undantag eller välj en undermapp."])
    }

    @Test func noWarningAtThreshold() {
        let r = FolderReport(fileCount: 100_000, cloudOnlyCount: 0, cloudOnlyBytes: 0, hasReservedRaderat: false)
        #expect(r.warnings.isEmpty)
    }

    @Test func warningsOrderAndCloudText() {
        let r = FolderReport(fileCount: 200_000, cloudOnlyCount: 3, cloudOnlyBytes: 5_000_000, hasReservedRaderat: true)
        let size = ByteCountFormatter.string(fromByteCount: 5_000_000, countStyle: .file)
        #expect(r.warnings.count == 3)
        #expect(r.warnings[0].hasPrefix("Mappen innehåller 200000 filer."))
        #expect(r.warnings[1] == "3 filer (\(size)) finns bara i iCloud och laddas ner vid första synken.")
        #expect(r.warnings[2].hasPrefix("Mappen \"Raderat\""))
    }
}
