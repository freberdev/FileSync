import Foundation

public struct DiskLocation: Codable, Equatable, Sendable {
    public var volumeUUID: String
    /// Only for display.
    public var volumeName: String
    /// Relative to the root of the disk, without a leading or trailing slash.
    public var path: String

    public init(volumeUUID: String, volumeName: String, path: String) {
        self.volumeUUID = volumeUUID
        self.volumeName = volumeName
        self.path = path
    }
}

public enum Destination: Codable, Equatable, Sendable, Identifiable {
    /// Absolute once ready; "~/…" until the connection has been tested.
    case server(path: String)
    case disk(DiskLocation)

    public var id: String {
        switch self {
        case .server: return "server"
        case .disk(let location): return "disk:\(location.volumeUUID):\(location.path)"
        }
    }

    public var isServer: Bool {
        if case .server = self { return true }
        return false
    }

    public var isReady: Bool {
        switch self {
        case .server(let path): return path.hasPrefix("/")
        case .disk: return true
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, path, volumeUUID, volumeName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "server":
            self = .server(path: try c.decode(String.self, forKey: .path))
        case "disk":
            self = .disk(DiskLocation(
                volumeUUID: try c.decode(String.self, forKey: .volumeUUID),
                volumeName: try c.decode(String.self, forKey: .volumeName),
                path: try c.decode(String.self, forKey: .path)))
        case let kind:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "Okänt slags mål: \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .server(let path):
            try c.encode("server", forKey: .kind)
            try c.encode(path, forKey: .path)
        case .disk(let location):
            try c.encode("disk", forKey: .kind)
            try c.encode(location.volumeUUID, forKey: .volumeUUID)
            try c.encode(location.volumeName, forKey: .volumeName)
            try c.encode(location.path, forKey: .path)
        }
    }
}

public struct FolderConfig: Codable, Equatable, Sendable, Identifiable {
    public var id: String { path }
    /// Absolute local path.
    public var path: String
    public var destinations: [Destination]
    /// Set when the folder lies on a volume other than the system disk.
    public var sourceVolumeUUID: String?

    public init(path: String, destinations: [Destination], sourceVolumeUUID: String? = nil) {
        self.path = path
        self.destinations = destinations
        self.sourceVolumeUUID = sourceVolumeUUID
    }

    public init(path: String, remotePath: String) {
        self.init(path: path, destinations: [.server(path: remotePath)])
    }

    /// The path of the server destination, "" when the folder has none. Assigning a path sets it
    /// (adding a server destination if needed); assigning "" removes the server destination.
    public var remotePath: String {
        get {
            for case .server(let path) in destinations { return path }
            return ""
        }
        set {
            let index = destinations.firstIndex(where: \.isServer)
            if newValue.isEmpty {
                if let index { destinations.remove(at: index) }
            } else if let index {
                destinations[index] = .server(path: newValue)
            } else {
                destinations.append(.server(path: newValue))
            }
        }
    }

    /// Has a server destination that is ready.
    public var isReady: Bool { destinations.contains { $0.isServer && $0.isReady } }

    public var diskDestinations: [DiskLocation] {
        destinations.compactMap { if case .disk(let location) = $0 { return location } else { return nil } }
    }

    private enum CodingKeys: String, CodingKey {
        case path, destinations, sourceVolumeUUID, remotePath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try c.decode(String.self, forKey: .path)
        self.sourceVolumeUUID = try c.decodeIfPresent(String.self, forKey: .sourceVolumeUUID)
        if let destinations = try c.decodeIfPresent([Destination].self, forKey: .destinations) {
            self.destinations = destinations
        } else {
            self.destinations = [.server(path: try c.decode(String.self, forKey: .remotePath))]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(destinations, forKey: .destinations)
        try c.encodeIfPresent(sourceVolumeUUID, forKey: .sourceVolumeUUID)
    }
}

public struct Config: Codable, Equatable, Sendable {
    public var server: String
    public var identityFile: String
    public var quietSeconds: Int
    public var maxWaitSeconds: Int
    public var exclude: [String]
    public var folders: [FolderConfig]
    public var rsyncPath: String
    /// The server on which the connection test last succeeded and the folders' remote paths were resolved.
    public var verifiedServer: String
    /// The home directory (symlinks resolved) that `verifiedServer` reported in that test.
    public var verifiedHome: String
    /// The same home directory as the server prints it without resolving symlinks (e.g. `/home/u`
    /// where `verifiedHome` is `/var/home/u`). Empty when unknown.
    public var verifiedLogicalHome: String

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
        rsyncPath: String = "/usr/bin/rsync",
        verifiedServer: String = "",
        verifiedHome: String = "",
        verifiedLogicalHome: String = ""
    ) {
        self.server = server
        self.identityFile = identityFile
        self.quietSeconds = quietSeconds
        self.maxWaitSeconds = maxWaitSeconds
        self.exclude = exclude
        self.folders = folders
        self.rsyncPath = rsyncPath
        self.verifiedServer = verifiedServer
        self.verifiedHome = verifiedHome
        self.verifiedLogicalHome = verifiedLogicalHome
    }

    /// True when `server` is the one the remote paths were resolved on and its home directory is known.
    public var isVerified: Bool { !server.isEmpty && server == verifiedServer && !verifiedHome.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case server, identityFile, quietSeconds, maxWaitSeconds, exclude, folders, rsyncPath, verifiedServer, verifiedHome, verifiedLogicalHome
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
        self.verifiedServer = try c.decodeIfPresent(String.self, forKey: .verifiedServer) ?? ""
        self.verifiedHome = try c.decodeIfPresent(String.self, forKey: .verifiedHome) ?? ""
        self.verifiedLogicalHome = try c.decodeIfPresent(String.self, forKey: .verifiedLogicalHome) ?? ""
    }

    public static func initial(home: String) -> Config {
        Config(folders: [FolderConfig(path: home + "/Sync", remotePath: "~/Sync")])
    }

    /// Records the volume of every folder that has none recorded and now lies on a mounted volume
    /// other than the system disk. Folders that already have one are left as they are.
    public func recordingSourceVolumes(_ volumes: [VolumeInfo]) -> Config {
        var result = self
        for index in result.folders.indices where result.folders[index].sourceVolumeUUID == nil {
            guard let volume = VolumeLookup.volume(containing: result.folders[index].path, in: volumes),
                  !volume.isSystem, let id = volume.uuid, !id.isEmpty else { continue }
            result.folders[index].sourceVolumeUUID = id
        }
        return result
    }

    /// Splits a comma-separated field into patterns: whitespace trimmed, empty entries dropped.
    public static func parseExcludes(_ text: String) -> [String] {
        text.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The `exclude` list as shown in the settings field.
    public func excludesText() -> String { exclude.joined(separator: ", ") }

    public var expandedIdentityFile: String { Config.expandTilde(identityFile) }

    public static func expandTilde(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    public func validate() -> [ConfigIssue] {
        validate(home: NSHomeDirectory())
    }

    /// `home` is the local home directory; it locates the app's own files and expands the key path.
    public func validate(home: String) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []

        for folder in folders where !folder.path.hasPrefix("/") {
            issues.append(.localPathNotAbsolute(folder.path))
        }
        let appDirectories = [home + "/Library/Logs/Filsynk", home + "/Library/Application Support/Filsynk"]
        for folder in folders where folder.path.hasPrefix("/") {
            let parts = Config.localComponents(folder.path)
            if appDirectories.contains(where: { Config.isPrefix(parts, of: Config.localComponents($0)) }) {
                issues.append(.localPathHoldsAppFiles(folder.path))
            }
        }
        for folder in folders {
            let servers = folder.destinations.filter(\.isServer).count
            if folder.destinations.isEmpty { issues.append(.folderWithoutDestination(folder.path)) }
            if servers > 1 { issues.append(.multipleServerDestinations(folder.path)) }
            if servers > 0, let issue = remotePathIssue(folder.remotePath) { issues.append(issue) }
            for location in folder.diskDestinations {
                if !Config.isValidDiskPath(location.path) { issues.append(.invalidDiskPath(location.path)) }
                if location.volumeUUID.isEmpty { issues.append(.missingVolumeID(folder.path)) }
            }
        }
        if Config.isUnsafe(identityFile)
            || Config.expandTilde(identityFile, home: home).unicodeScalars.contains(where: \.properties.isWhitespace) {
            issues.append(.unsafeIdentityFile(identityFile))
        }
        if !server.isEmpty, !Config.isSafeServer(server) {
            issues.append(.unsafeServer(server))
        }
        for pattern in exclude where !Config.isPlainExclude(pattern) {
            issues.append(.unsafeExclude(pattern))
        }

        let local = folders.map(\.path).filter { $0.hasPrefix("/") }
        for (outer, inner) in Config.nestedPairs(local, components: Config.localComponents) {
            issues.append(.nestedLocalPaths(outer, inner))
        }
        let remote = folders.filter { $0.destinations.contains(where: \.isServer) }.map(\.remotePath)
        for (outer, inner) in Config.nestedPairs(remote, components: Config.remoteComponents) {
            issues.append(.nestedRemotePaths(outer, inner))
        }
        let disks = folders.flatMap(\.diskDestinations)
            .filter { !$0.volumeUUID.isEmpty && Config.isValidDiskPath($0.path) }
        for volume in Set(disks.map { $0.volumeUUID.lowercased() }).sorted() {
            let paths = disks.filter { $0.volumeUUID.lowercased() == volume }.map(\.path)
            for (outer, inner) in Config.nestedPairs(paths, components: Config.diskComponents) {
                issues.append(.nestedDiskPaths(outer, inner))
            }
        }
        return issues
    }

    /// A path on a disk is relative to its root: not empty, no leading or trailing slash and no
    /// empty, `.` or `..` component.
    static func isValidDiskPath(_ path: String) -> Bool {
        if path.isEmpty || path.hasPrefix("/") || path.hasSuffix("/") { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    private static func diskComponents(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    /// The first problem with a remote path, judged without contacting the server.
    private func remotePathIssue(_ path: String) -> ConfigIssue? {
        guard Config.isSafeRemotePath(path) else { return .unsafeRemotePath(path) }
        let raw = path.split(separator: "/").map(String.init)
        if raw.contains(".") || raw.contains("..") { return .remotePathNotAllowed(path) }

        var absolute = path
        if !verifiedHome.isEmpty, path == "~" || path.hasPrefix("~/") {
            absolute = verifiedHome + path.dropFirst()
        }
        guard absolute.hasPrefix("/") else { return nil }
        let parts = Config.remoteComponents(absolute)
        if parts.isEmpty { return .remotePathTooBroad(path) }
        return Config.homeIssue(path, parts: parts, homes: [verifiedHome, verifiedLogicalHome])
    }

    /// The home directory or above it, or `~/.ssh` and below, judged against each known home
    /// (with and without symlinks resolved): a --delete sync there would move authorized_keys away.
    static func homeIssue(_ path: String, parts: [String], homes: [String]) -> ConfigIssue? {
        for home in homes where !home.isEmpty {
            let homeParts = Config.remoteComponents(home)
            if Config.isPrefix(parts, of: homeParts) { return .remotePathTooBroad(path) }
            if Config.isPrefix(homeParts + [".ssh"], of: parts) { return .remotePathNotAllowed(path) }
        }
        return nil
    }

    private static let unsafeCharacters: Set<Character> = [" ", "\"", "'", "$", "`", "\\", "\n", "\r", "\r\n"]
    private static let remotePathPunctuation: Set<Unicode.Scalar> = [".", "_", "-", "/", "+", "@", ",", "=", "%"]
    private static let serverPunctuation: Set<Unicode.Scalar> = [".", "_", "-", "@", ":", "[", "]", "%"]

    /// A remote path is put on the server's command line, so it may hold only letters, digits and
    /// `. _ - / + @ , = %`, plus a leading `~` that is the whole path or followed by `/`.
    public static func isSafeRemotePath(_ path: String) -> Bool {
        var rest = Substring(path)
        if rest == "~" { return true }
        if rest.hasPrefix("~/") { rest = rest.dropFirst() }
        return rest.allSatisfy { character in
            let scalars = character.unicodeScalars
            guard let first = scalars.first else { return false }
            if scalars.count == 1, remotePathPunctuation.contains(first) { return true }
            return isLetterOrDigit(first) && scalars.dropFirst().allSatisfy(isMark)
        }
    }

    /// ASCII letters and digits and `. _ - @ : [ ] %`, not starting with `-`. Empty is not judged here.
    public static func isSafeServer(_ server: String) -> Bool {
        !server.hasPrefix("-") && server.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || serverPunctuation.contains(scalar))
        }
    }

    /// An exclude entry must be a plain pattern: rsync reads `!`, `+ `, `- `, `: ` and `. ` at the
    /// start of a line as rules, and a line break would start a new rule.
    static func isPlainExclude(_ pattern: String) -> Bool {
        if pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if pattern.contains(where: { $0.unicodeScalars.contains { $0 == "\n" || $0 == "\r" } }) { return false }
        if pattern.hasPrefix("!") { return false }
        return !["+ ", "- ", ": ", ". "].contains(where: pattern.hasPrefix)
    }

    static func isUnsafe(_ s: String) -> Bool {
        s.contains { unsafeCharacters.contains($0) }
    }

    private static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: return true
        default: return false
        }
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    private static func isPrefix(_ prefix: [String], of path: [String]) -> Bool {
        prefix.count <= path.count && Array(path.prefix(prefix.count)) == prefix
    }

    private static func localComponents(_ path: String) -> [String] {
        let standardized = (path as NSString).standardizingPath
        return standardized.split(separator: "/").map(String.init)
    }

    static func remoteComponents(_ path: String) -> [String] {
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
    case unsafeServer(String)
    case remotePathTooBroad(String)
    case remotePathNotAllowed(String)
    case unsafeExclude(String)
    case localPathHoldsAppFiles(String)
    case folderWithoutDestination(String)
    case multipleServerDestinations(String)
    case invalidDiskPath(String)
    case missingVolumeID(String)
    case nestedDiskPaths(String, String)

    public var message: String {
        switch self {
        case .localPathNotAbsolute(let p):
            return "Den lokala sökvägen \"\(p)\" måste vara absolut (börja med /)."
        case .nestedLocalPaths(let a, let b):
            return "De lokala mapparna \"\(a)\" och \"\(b)\" ligger inuti varandra."
        case .nestedRemotePaths(let a, let b):
            return "Mapparna på servern \"\(a)\" och \"\(b)\" ligger inuti varandra."
        case .unsafeRemotePath(let p):
            return "Sökvägen på servern \"\(p)\" innehåller otillåtna tecken. Använd bokstäver, siffror och . _ - / + @ , = %."
        case .unsafeServer(let s):
            return "Serveradressen är ogiltig: \(s)"
        case .remotePathTooBroad(let p):
            return "Sökvägen på servern \"\(p)\" är för bred. Välj en egen mapp."
        case .remotePathNotAllowed(let p):
            return "Sökvägen på servern \"\(p)\" går inte att använda. Välj en egen mapp utan . och .. och utanför ~/.ssh."
        case .unsafeExclude(let e):
            return "Undantaget \"\(e)\" går inte att använda. Det får inte vara tomt eller börja med !, + , - , : eller . följt av mellanslag."
        case .localPathHoldsAppFiles(let p):
            return "Mappen \"\(p)\" innehåller FileSyncs egna filer (logg och inställningar) och skulle synkas om och om igen. Välj en undermapp."
        case .folderWithoutDestination(let p):
            return "Mappen \(p) har inget mål."
        case .multipleServerDestinations(let p):
            return "Mappen \(p) har fler än ett mål på servern."
        case .invalidDiskPath(let p):
            return "Sökvägen på disken är ogiltig: \(p)"
        case .missingVolumeID(let p):
            return "Disken för \(p) saknar id."
        case .nestedDiskPaths(let a, let b):
            return "Mapparna på disken \"\(a)\" och \"\(b)\" ligger inuti varandra."
        case .unsafeIdentityFile(let p):
            return "Nyckelfilen \"\(p)\" innehåller otillåtna tecken (mellanslag, citattecken, $, ` eller \\)."
        }
    }
}
