import Foundation
import Testing
@testable import FilsynkCore

@Suite struct StateStoreTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("filsynk-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func roundTrip() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The directory is created when needed.
        let store = StateStore(url: dir.appendingPathComponent("sub/state.json"))
        let dates: [String: Date] = [
            "/a|server": Date(timeIntervalSince1970: 1_800_000_000.25),
            "/a|disk:U1:Filsynk/A": Date(timeIntervalSince1970: 1_800_000_100),
        ]
        store.save(dates)
        let loaded = store.load()
        #expect(loaded.keys.sorted() == dates.keys.sorted())
        for (key, date) in dates {
            #expect(abs((loaded[key] ?? .distantPast).timeIntervalSince(date)) < 0.001, "\(key)")
        }
        // A flat object of ISO 8601 strings.
        let data = try Data(contentsOf: dir.appendingPathComponent("sub/state.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object["/a|disk:U1:Filsynk/A"]?.hasPrefix("2027-01-15T") == true)

        store.save([:])
        #expect(store.load().isEmpty)
    }

    @Test func missingFileGivesEmpty() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(StateStore(url: dir.appendingPathComponent("state.json")).load().isEmpty)
    }

    @Test func malformedFileGivesEmpty() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        for text in ["not json", "[1, 2]", #"{"/a|server": 5}"#, #"{"/a|server": "igår"}"#] {
            try Data(text.utf8).write(to: url)
            #expect(StateStore(url: url).load().isEmpty, "\(text)")
        }
    }
}
