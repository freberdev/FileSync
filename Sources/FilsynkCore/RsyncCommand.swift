import Foundation

public struct Invocation: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public enum SyncTarget: Equatable, Sendable {
    case ssh
    case localForTesting
}

public enum RsyncCommand {
    /// `yyyy-MM-dd_HHmmss` in the given time zone.
    public static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: date)
    }

    public static func sshArguments(identityFile: String) -> [String] {
        ["-i", Config.expandTilde(identityFile),
         "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
         "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4"]
    }

    public static func excludeFileContents(_ config: Config) -> String {
        (Config.builtInExcludes + config.exclude).map { $0 + "\n" }.joined()
    }

    public static func sync(
        config: Config, folder: FolderConfig, timestamp: String,
        excludeFile: String, target: SyncTarget = .ssh
    ) -> Invocation {
        let local = withoutTrailingSlashes(folder.path) + "/"
        let remote = withoutTrailingSlashes(folder.remotePath)

        var arguments = [
            "-a", "--delete", "--backup",
            "--backup-dir=\(remote)/Raderat/\(timestamp)",
            "--exclude=/Raderat/",
            "--exclude-from=\(excludeFile)",
            "--partial-dir=.filsynk-partial",
            "--timeout=60",
            "--stats",
        ]
        switch target {
        case .ssh:
            arguments += ["-e", "ssh " + sshArguments(identityFile: config.identityFile).joined(separator: " ")]
            arguments += [local, "\(config.server):\(remote)/"]
        case .localForTesting:
            arguments += [local, remote + "/"]
        }
        return Invocation(executable: config.rsyncPath, arguments: arguments)
    }

    private static func withoutTrailingSlashes(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
