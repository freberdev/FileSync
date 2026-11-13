import Foundation

public enum AddFolderResult: Equatable, Sendable {
    case added(Config)
    /// The message to show the user; nothing was changed.
    case rejected(String)
}

/// The logic behind the settings window's buttons, on top of `ConnectionSetup`.
public struct SetupFlow: Sendable {
    private let setup: ConnectionSetup
    private let log: (@Sendable (String) -> Void)?

    public init(process: any ProcessRunning, log: (@Sendable (String) -> Void)? = nil) {
        self.setup = ConnectionSetup(process: process, log: log)
        self.log = log
    }

    /// ensureKey, check, and (only when the check is `.ok`) resolve every folder that is not ready.
    /// Any other result returns `config` unchanged. If a resolve fails, the result is `.failed`
    /// and that folder stays unresolved; folders resolved before it stay resolved.
    /// `verifiedServer`, `verifiedHome` and `verifiedLogicalHome` are set together, and only when everything succeeded.
    public func connect(_ config: Config) async -> (result: ConnectionResult, config: Config) {
        do {
            _ = try await setup.ensureKey(identityFile: config.identityFile)
        } catch {
            return (.failed(message(for: error)), config)
        }
        let result = await setup.check(server: config.server, identityFile: config.identityFile)
        guard case .ok = result else { return (result, config) }

        // Paths resolved on another server mean nothing here: resolve them all again.
        let resolveAll = config.verifiedServer != config.server
        var updated = config
        var homes: (home: String, logicalHome: String)?
        for index in updated.folders.indices where resolveAll || !updated.folders[index].isReady {
            do {
                let resolved = try await setup.resolveRemotePath(
                    updated.folders[index].remotePath, server: updated.server, identityFile: updated.identityFile)
                updated.folders[index].remotePath = resolved.path
                homes = (resolved.home, resolved.logicalHome)
            } catch {
                return (.failed(message(for: error)), updated)
            }
        }
        if homes == nil {
            do {
                homes = try await setup.remoteHome(server: updated.server, identityFile: updated.identityFile)
            } catch ConnectionError.remoteCommandFailed(let outcome) {
                switch outcome {
                case .unreachable: return (.unreachable, updated)
                case .authDenied: return (.authDenied, updated)
                case .failed(let text): return (.failed(text), updated)
                case .success: return (.failed("Oväntat svar från servern"), updated)
                }
            } catch {
                return (.failed(message(for: error)), updated)
            }
        }
        updated.verifiedServer = updated.server
        updated.verifiedHome = homes?.home ?? ""
        updated.verifiedLogicalHome = homes?.logicalHome ?? ""
        return (result, updated)
    }

    /// What can be judged about adding the folder without the server and without looking at the
    /// folder itself: the message to show, or nil when nothing speaks against it. Starts no process.
    public func addRejection(to config: Config, localPath: String, remoteEntered: String) -> String? {
        let entered = remoteEntered.trimmingCharacters(in: .whitespacesAndNewlines)
        if !config.isVerified { return "Testa anslutningen först." }

        // Nested or unsafe paths.
        var candidate = config
        candidate.folders.append(FolderConfig(path: localPath, remotePath: entered))
        return candidate.validate().first?.message
    }

    /// Resolves the remote path and appends the folder. Never returns an invalid config.
    public func addFolder(to config: Config, localPath: String, remoteEntered: String) async -> AddFolderResult {
        let entered = remoteEntered.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = addRejection(to: config, localPath: localPath, remoteEntered: entered) {
            return .rejected(message)
        }

        let resolved: String
        do {
            resolved = try await setup.resolveRemotePath(entered, server: config.server, identityFile: config.identityFile).path
        } catch {
            return .rejected(message(for: error))
        }

        // Nesting between remote paths can only be judged once the path is absolute.
        var result = config
        result.folders.append(FolderConfig(path: localPath, remotePath: resolved))
        if let issue = result.validate().first { return .rejected(issue.message) }
        return .added(result)
    }

    /// Removes the folder from the configuration only; nothing is deleted on the server.
    public static func removeFolder(_ folder: FolderConfig, from config: Config) -> Config {
        var updated = config
        updated.folders.removeAll { $0 == folder }
        return updated
    }

    /// A short text for the user; anything unexpected is written to the log in full.
    private func message(for error: any Error) -> String {
        guard let error = error as? ConnectionError else {
            log?("Kunde inte köra kommandot: \(error)")
            return "Kunde inte köra kommandot: \(error.localizedDescription)"
        }
        switch error {
        case .unsafePath(let path):
            return "Sökvägen på servern \"\(path)\" innehåller otillåtna tecken."
        case .unsafeServer:
            return "Serveradressen är ogiltig"
        case .remoteCommandFailed(let outcome):
            return "Kunde inte skapa mappen på servern: \(outcome.message ?? "okänt fel")"
        case .unexpectedOutput(let line):
            log?("Oväntat svar från servern: \(line)")
            return "Oväntat svar från servern"
        case .pathTooBroad:
            return "Välj en egen mapp på servern, inte hemkatalogen eller en mapp ovanför den."
        case .keyCreationFailed(let detail):
            return "Kunde inte skapa nyckeln: \(detail)"
        }
    }
}
