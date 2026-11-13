import Foundation

public enum ConnectionResult: Equatable, Sendable {
    case ok(rsyncVersion: String)
    case unreachable, authDenied
    case unsupportedRsync(String)
    case failed(String)
}

public enum ConnectionError: Error, Equatable, Sendable {
    case unsafePath(String)
    case remoteCommandFailed(SyncOutcome)
    case unexpectedOutput(String)
    case keyCreationFailed(String)
}

public struct ConnectionSetup: Sendable {
    private let process: any ProcessRunning

    public init(process: any ProcessRunning) {
        self.process = process
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
        let result: ProcessResult
        do {
            result = try await remote(server: server, identityFile: identityFile, command: "rsync --version")
        } catch {
            return .failed("\(error)")
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

    /// Creates the folder on the server if needed and returns its absolute, symlink-resolved path.
    public func resolveRemotePath(_ entered: String, server: String, identityFile: String) async throws -> String {
        if Config.isUnsafe(entered) { throw ConnectionError.unsafePath(entered) }

        let quoted: String
        if entered == "~" {
            quoted = "$HOME"
        } else if entered.hasPrefix("~/") {
            quoted = "$HOME/" + entered.dropFirst(2)
        } else {
            quoted = entered
        }
        let command = "mkdir -p \"\(quoted)\" && cd \"\(quoted)\" && pwd -P"
        let result = try await remote(server: server, identityFile: identityFile, command: command)

        guard result.exitCode == 0 else {
            throw ConnectionError.remoteCommandFailed(
                OutcomeClassifier.classify(exitCode: result.exitCode, stderr: result.stderr))
        }
        let line = result.stdout.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
        guard line.hasPrefix("/") else { throw ConnectionError.unexpectedOutput(line) }
        return line
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
            "/usr/bin/ssh", RsyncCommand.sshArguments(identityFile: identityFile) + [server, command])
    }
}
