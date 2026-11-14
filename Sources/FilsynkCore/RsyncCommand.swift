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

    /// Torrkörning mot en disk: listar med `-i` vad `--delete` skulle ta bort. Skriver ingenting.
    /// `-8` gör att tecken utanför ASCII i namnen skrivs som de är; rsync i macOS 15 och 26 kodar
    /// annars en del av dem, bland annat å, ä och ö i den uppdelade form Finder lagrar.
    public static func diskDryRun(
        config: Config, source: String, destination: String,
        format: VolumeFormat, excludeFile: String
    ) -> Invocation {
        let arguments = diskBaseArguments(format: format, excludeFile: excludeFile)
            + ["-n", "-i", "-8", "--delete"]
            + [withoutTrailingSlashes(source) + "/", withoutTrailingSlashes(destination) + "/"]
        return Invocation(executable: config.rsyncPath, arguments: arguments)
    }

    /// Den riktiga körningen mot en disk. Har aldrig `--delete`: det som skrivs över hamnar i
    /// `Raderat/<tidsstämpel>/`, och det som försvunnit har redan flyttats dit.
    public static func diskSync(
        config: Config, source: String, destination: String,
        format: VolumeFormat, timestamp: String, excludeFile: String
    ) -> Invocation {
        let target = withoutTrailingSlashes(destination)
        let arguments = diskBaseArguments(format: format, excludeFile: excludeFile)
            + ["--backup", "--backup-dir=\(target)/Raderat/\(timestamp)", "--timeout=60", "--stats"]
            + [withoutTrailingSlashes(source) + "/", target + "/"]
        return Invocation(executable: config.rsyncPath, arguments: arguments)
    }

    /// Undantagsfilen för en disk: de vanliga mönstren plus de två reserverade namnen i målets rot,
    /// oavsett skiftläge, eftersom APFS och exFAT normalt inte skiljer på versaler och gemener.
    public static func diskExcludeFileContents(_ config: Config) -> String {
        excludeFileContents(config)
            + "/[Rr][Aa][Dd][Ee][Rr][Aa][Tt]\n"
            + "/.[Ff][Ii][Ll][Ss][Yy][Nn][Kk]\n"
    }

    private static func diskBaseArguments(format: VolumeFormat, excludeFile: String) -> [String] {
        let mode = format == .exfat ? ["-rlt", "--modify-window=1"] : ["-a"]
        return mode + ["--exclude=/Raderat/", "--exclude=/\(DiskMarker.name)",
                       "--exclude-from=\(excludeFile)", "--partial-dir=.filsynk-partial"]
    }

    private static func withoutTrailingSlashes(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
