import Foundation
import Testing
@testable import FilsynkCore

struct DiskMarkerTests {
    private func makeDirectory() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("filsynk-marker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    @Test func writesAndFindsMarker() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(!DiskMarker.exists(in: dir))
        try DiskMarker.write(in: dir, folder: "/Users/x/A")
        #expect(DiskMarker.exists(in: dir))
        #expect(DiskMarker.exists(in: dir + "/"))
        let text = try String(contentsOfFile: dir + "/.filsynk", encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0] == "/Users/x/A")
        #expect(ISO8601DateFormatter().date(from: lines[1]) != nil)
    }

    @Test func neverOverwritesExistingMarker() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "gammalt innehåll\n".write(toFile: dir + "/.filsynk", atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try DiskMarker.write(in: dir, folder: "/Users/x/B") }
        #expect(try String(contentsOfFile: dir + "/.filsynk", encoding: .utf8) == "gammalt innehåll\n")
    }

    @Test func doesNotCreateMissingDirectory() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let missing = dir + "/finns-inte"
        #expect(throws: (any Error).self) { try DiskMarker.write(in: missing, folder: "/Users/x/A") }
        #expect(!FileManager.default.fileExists(atPath: missing))
        #expect(!DiskMarker.exists(in: missing))
    }

    @Test func aFolderNamedLikeTheMarkerIsNotAMarker() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/.filsynk", withIntermediateDirectories: false)
        #expect(!DiskMarker.exists(in: dir))
    }
}
