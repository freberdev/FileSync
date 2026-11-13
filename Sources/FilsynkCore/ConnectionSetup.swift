import Foundation

public enum ConnectionResult: Equatable, Sendable {
    case ok(rsyncVersion: String)
    case unreachable, authDenied
    case unsupportedRsync(String)
    case failed(String)
}

public enum ConnectionError: Error, Equatable, Sendable {
    case unsafePath(String)
    case unsafeServer
    case remoteCommandFailed(SyncOutcome)
    case unexpectedOutput(String)
    case keyCreationFailed(String)
    case pathTooBroad
}

public struct ConnectionSetup: Sendable {
    private let process: any ProcessRunning
    private let log: (@Sendable (String) -> Void)?

    public init(process: any ProcessRunning, log: (@Sendable (String) -> Void)? = nil) {
        self.process = process
        self.log = log
    }

    /// Creates the key pair when `identityFile` does not exist. Never overwrites. Returns true if created.
    public func ensureKey(identityFile: String) async throws -> Bool {
        let path = Config.expandTilde(identityFile)
        if FileManager.default.fileExists(atPath: path) { return false }
        let result = try await process.run(
            "/usr/bin/ssh-keygen", ["-t", "ed25519", "-N", "", "-C", "filsynk", "-f", path])
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ConnectionError.keyCreationFailed(detail.isEmpty ? "ssh-keygen avslutades med kod \(result.exitCode)" : detail)
        }
        return true
    }

    public static func copyIdCommand(identityFile: String, server: String) -> String {
        "ssh-copy-id -i \(identityFile).pub \(server)"
    }

    public func check(server: String, identityFile: String) async -> ConnectionResult {
        if server.isEmpty || !Config.isSafeServer(server) { return .failed("Serveradressen är ogiltig") }
        let result: ProcessResult
        do {
            result = try await remote(server: server, identityFile: identityFile, command: "rsync --version")
        } catch {
            log?("Kunde inte starta ssh: \(error)")
            return .failed("Kunde inte starta ssh: \(error.localizedDescription)")
        }

        if result.exitCode == 0 {
            let firstLine = (result.stdout.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                .trimmingCharacters(in: .whitespaces)
            if let v = Self.parseRsyncVersion(firstLine), v.major >= 3 {
                return .ok(rsyncVersion: "\(v.major).\(v.minor).\(v.patch)")
            }
            return .unsupportedRsync(firstLine)
        }

        switch OutcomeClassifier.classify(exitCode: result.exitCode, stderr: result.stderr) {
        case .unreachable: return .unreachable
        case .authDenied: return .authDenied
        case .success: return .failed("Oväntat svar från servern")
        case .failed(let message):
            if result.exitCode == 127 || result.stderr.contains("command not found") {
                return .unsupportedRsync("rsync finns inte på servern")
            }
            return .failed(message)
        }
    }

    /// Creates the folder on the server if needed and returns its absolute, symlink-resolved path
    /// together with the remote home directory, both resolved and as the server writes it.
    public func resolveRemotePath(
        _ entered: String, server: String, identityFile: String
    ) async throws -> (path: String, home: String, logicalHome: String) {
        if server.isEmpty || !Config.isSafeServer(server) { throw ConnectionError.unsafeServer }
        if !Config.isSafeRemotePath(entered) { throw ConnectionError.unsafePath(entered) }

        let quoted: String
        if entered == "~" {
            quoted = "$HOME"
        } else if entered.hasPrefix("~/") {
            quoted = "$HOME/" + entered.dropFirst(2)
        } else {
            quoted = entered
        }
        // Prints the home directory (resolved, then as written), then the resolved folder; the folder
        // is refused if it is a home directory or above one (a --delete sync there would move
        // authorized_keys away).
        let command = "cd && pwd -P && pwd && mkdir -p \"\(quoted)\" && cd \"\(quoted)\" && pwd -P"
        let result = try await remote(server: server, identityFile: identityFile, command: command)

        guard result.exitCode == 0 else {
            throw ConnectionError.remoteCommandFailed(
                OutcomeClassifier.classify(exitCode: result.exitCode, stderr: result.stderr))
        }
        let lines = result.stdout.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 3, let line = lines.last else { throw ConnectionError.unexpectedOutput(lines.last ?? "") }
        let home = lines[lines.count - 3], logicalHome = lines[lines.count - 2]
        guard home.hasPrefix("/"), logicalHome.hasPrefix("/"), line.hasPrefix("/")
        else { throw ConnectionError.unexpectedOutput(line) }

        let pathParts = line.split(separator: "/")
        for candidate in [home, logicalHome] {
            let homeParts = candidate.split(separator: "/")
            if pathParts.count <= homeParts.count, Array(homeParts.prefix(pathParts.count)) == pathParts {
                throw ConnectionError.pathTooBroad
            }
        }
        return (line, home, logicalHome)
    }

    /// The remote home directory, with symlinks resolved and as the server writes it.
    public func remoteHome(server: String, identityFile: String) async throws -> (home: String, logicalHome: String) {
        if server.isEmpty || !Config.isSafeServer(server) { throw ConnectionError.unsafeServer }
        let result = try await remote(server: server, identityFile: identityFile, command: "cd && pwd -P && pwd")
        guard result.exitCode == 0 else {
            throw ConnectionError.remoteCommandFailed(
                OutcomeClassifier.classify(exitCode: result.exitCode, stderr: result.stderr))
        }
        let lines = result.stdout.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2, lines[lines.count - 2].hasPrefix("/"), lines[lines.count - 1].hasPrefix("/")
        else { throw ConnectionError.unexpectedOutput(lines.last ?? "") }
        return (lines[lines.count - 2], lines[lines.count - 1])
    }

    /// Parses e.g. "rsync  version 3.2.7  protocol version 31". Returns nil for openrsync and anything else.
    public static func parseRsyncVersion(_ firstLine: String) -> (major: Int, minor: Int, patch: Int)? {
        let tokens = firstLine.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 3, tokens[0] == "rsync", tokens[1] == "version" else { return nil }
        let parts = tokens[2].split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (2...3).contains(parts.count), !parts.contains(nil) else { return nil }
        let n = parts.compactMap { $0 }
        return (n[0], n[1], n.count > 2 ? n[2] : 0)
    }

    private func remote(server: String, identityFile: String, command: String) async throws -> ProcessResult {
        try await process.run(
            "/usr/bin/ssh", RsyncCommand.sshArguments(identityFile: identityFile) + ["--", server, command])
    }
}
