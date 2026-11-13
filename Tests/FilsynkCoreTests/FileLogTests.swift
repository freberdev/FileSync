import Foundation
import Testing
@testable import FilsynkCore

@Suite struct FileLogTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("filsynk-filelog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func logAppendsTimestampedLines() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Parent directory does not exist yet: FileLog must create it.
        let url = dir.appendingPathComponent("sub/filsynk.log")
        let log = FileLog(url: url)
        log.write("första")
        log.write("andra")

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasSuffix("\n"))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(lines.count == 2)
        for line in lines {
            #expect(line.range(of: #"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d "#, options: .regularExpression) != nil)
        }
        #expect(lines[0].hasSuffix(" första"))
        #expect(lines[1].hasSuffix(" andra"))
    }

    @Test func logRotatesAtLimit() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("filsynk.log")
        let rotated = dir.appendingPathComponent("filsynk.log.1")
        let log = FileLog(url: url, maxBytes: 200)
        // Each line is 20 (timestamp + space) + 34 + 1 = 55 bytes; 6 lines = 330 bytes.
        let message = String(repeating: "x", count: 34)
        for _ in 0..<6 { log.write(message) }

        #expect(FileManager.default.fileExists(atPath: rotated.path))
        let current = try Data(contentsOf: url)
        let old = try Data(contentsOf: rotated)
        #expect(current.count < 200)
        #expect(old.count <= 200)
        let lineCount = [current, old].reduce(0) { sum, data in
            sum + data.filter { $0 == UInt8(ascii: "\n") }.count
        }
        #expect(lineCount == 6)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
                == ["filsynk.log", "filsynk.log.1"])
    }

    @Test func defaultURLIsInUserLibraryLogs() {
        #expect(FileLog.defaultURL.path.hasSuffix("/Library/Logs/Filsynk/filsynk.log"))
    }
}
