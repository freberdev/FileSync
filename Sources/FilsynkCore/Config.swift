import Foundation

public struct FolderConfig: Codable, Equatable, Sendable {
    /// Absolute local path.
    public var path: String
    /// Absolute once ready; "~/…" until the connection has been tested.
    public var remotePath: String

    public init(path: String, remotePath: String) {
        self.path = path
        self.remotePath = remotePath
    }

    public var isReady: Bool { remotePath.hasPrefix("/") }
}

public struct Config: Codable, Equatable, Sendable {
    public var server: String
    public var identityFile: String
    public var quietSeconds: Int
    public var maxWaitSeconds: Int
    public var exclude: [String]
    public var folders: [FolderConfig]
    public var rsyncPath: String

    public static let builtInExcludes: [String] = [
        ".DS_Store", "._*", ".localized", ".Trash*", ".Spotlight-V100", ".fseventsd",
    ]

    public init(
        server: String = "",
        identityFile: String = "~/.ssh/filsynk_ed25519",
        quietSeconds: Int = 60,
        maxWaitSeconds: Int = 600,
        exclude: [String] = [],
        folders: [FolderConfig] = [],
        rsyncPath: String = "/usr/bin/rsync"
    ) {
        self.server = server
        self.identityFile = identityFile
        self.quietSeconds = quietSeconds
        self.maxWaitSeconds = maxWaitSeconds
        self.exclude = exclude
        self.folders = folders
        self.rsyncPath = rsyncPath
    }

    private enum CodingKeys: String, CodingKey {
        case server, identityFile, quietSeconds, maxWaitSeconds, exclude, folders, rsyncPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.server = try c.decode(String.self, forKey: .server)
        self.folders = try c.decode([FolderConfig].self, forKey: .folders)
        self.identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile) ?? "~/.ssh/filsynk_ed25519"
        self.quietSeconds = try c.decodeIfPresent(Int.self, forKey: .quietSeconds) ?? 60
        self.maxWaitSeconds = try c.decodeIfPresent(Int.self, forKey: .maxWaitSeconds) ?? 600
        self.exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
        self.rsyncPath = try c.decodeIfPresent(String.self, forKey: .rsyncPath) ?? "/usr/bin/rsync"
    }

    public static func initial(home: String) -> Config {
        Config(folders: [FolderConfig(path: home + "/Sync", remotePath: "~/Sync")])
    }

    public var expandedIdentityFile: String { Config.expandTilde(identityFile) }

    public static func expandTilde(_ path: String) -> String {
        if path == "~" { return NSHomeDirectory() }
        if path.hasPrefix("~/") { return NSHomeDirectory() + String(path.dropFirst(1)) }
        return path
    }

    public func validate() -> [ConfigIssue] {
        var issues: [ConfigIssue] = []

        for folder in folders where !folder.path.hasPrefix("/") {
            issues.append(.localPathNotAbsolute(folder.path))
        }
        for folder in folders where Config.isUnsafe(folder.remotePath) {
            issues.append(.unsafeRemotePath(folder.remotePath))
        }
        if Config.isUnsafe(identityFile) {
            issues.append(.unsafeIdentityFile(identityFile))
        }

        let local = folders.map(\.path).filter { $0.hasPrefix("/") }
        for (outer, inner) in Config.nestedPairs(local, components: Config.localComponents) {
            issues.append(.nestedLocalPaths(outer, inner))
        }
        let remote = folders.map(\.remotePath)
        for (outer, inner) in Config.nestedPairs(remote, components: Config.remoteComponents) {
            issues.append(.nestedRemotePaths(outer, inner))
        }
        return issues
    }

    private static let unsafeCharacters: Set<Character> = [" ", "\"", "'", "$", "`", "\\", "\n", "\r", "\r\n"]

    static func isUnsafe(_ s: String) -> Bool {
        s.contains { unsafeCharacters.contains($0) }
    }

    private static func localComponents(_ path: String) -> [String] {
        let standardized = (path as NSString).standardizingPath
        return standardized.split(separator: "/").map(String.init)
    }

    private static func remoteComponents(_ path: String) -> [String] {
        var result: [String] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !result.isEmpty, result.last != ".." { result.removeLast() } else { result.append("..") }
            default: result.append(String(part))
            }
        }
        return result
    }

    /// Returns (ancestor, descendant) for every pair where one path lies inside the other
    /// (compared on path components, so "/a/Sync" and "/a/Sync2" are not nested).
    private static func nestedPairs(
        _ paths: [String], components: (String) -> [String]
    ) -> [(String, String)] {
        var pairs: [(String, String)] = []
        let comps = paths.map(components)
        for i in paths.indices {
            for j in paths.indices where j > i {
                let a = comps[i], b = comps[j]
                if b.count >= a.count, Array(b.prefix(a.count)) == a {
                    pairs.append((paths[i], paths[j]))
                } else if a.count > b.count, Array(a.prefix(b.count)) == b {
                    pairs.append((paths[j], paths[i]))
                }
            }
        }
        return pairs
    }
}

public enum ConfigIssue: Equatable, Sendable {
    case localPathNotAbsolute(String)
    case nestedLocalPaths(String, String)
    case nestedRemotePaths(String, String)
    case unsafeRemotePath(String)
    case unsafeIdentityFile(String)

    public var message: String {
        switch self {
        case .localPathNotAbsolute(let p):
            return "Den lokala sökvägen \"\(p)\" måste vara absolut (börja med /)."
        case .nestedLocalPaths(let a, let b):
            return "De lokala mapparna \"\(a)\" och \"\(b)\" ligger inuti varandra."
        case .nestedRemotePaths(let a, let b):
            return "Mapparna på servern \"\(a)\" och \"\(b)\" ligger inuti varandra."
        case .unsafeRemotePath(let p):
            return "Sökvägen på servern \"\(p)\" innehåller otillåtna tecken (mellanslag, citattecken, $, ` eller \\)."
        case .unsafeIdentityFile(let p):
            return "Nyckelfilen \"\(p)\" innehåller otillåtna tecken (mellanslag, citattecken, $, ` eller \\)."
        }
    }
}
