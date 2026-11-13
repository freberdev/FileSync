import Foundation

/// The last successful sync per destination, kept between launches. The file is a flat JSON object
/// from "<folder path>|<destination id>" to an ISO 8601 date.
public struct StateStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Filsynk/state.json")
    }

    public static func key(path: String, destinationID: String) -> String {
        path + "|" + destinationID
    }

    /// A missing or damaged file gives an empty result.
    public func load() -> [String: Date] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        let formatter = Self.formatter()
        var result: [String: Date] = [:]
        for (key, text) in object {
            guard let date = formatter.date(from: text) else { return [:] }
            result[key] = date
        }
        return result
    }

    /// Replaces the file atomically. A failure only means the dates are not restored next time.
    public func save(_ lastSuccess: [String: Date]) {
        let formatter = Self.formatter()
        let object = lastSuccess.mapValues { formatter.string(from: $0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(object) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
