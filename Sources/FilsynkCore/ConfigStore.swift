import Foundation

public enum ConfigError: Error, Equatable {
    case malformed(String)
}

public struct ConfigStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Filsynk/config.json")
    }

    /// Never writes. A missing file yields the initial config; a broken file throws.
    public func load() throws -> Config {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return Config.initial(home: NSHomeDirectory())
        }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw ConfigError.malformed(String(describing: error))
        }
    }

    public func save(_ config: Config) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(config)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
