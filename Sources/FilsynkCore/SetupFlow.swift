import Foundation

public enum AddFolderResult: Equatable, Sendable {
    case added(Config)
    /// The message to show the user; nothing was changed.
    case rejected(String)
}

/// The logic behind the settings window's buttons, on top of `ConnectionSetup`.
public struct SetupFlow: Sendable {
    private let setup: ConnectionSetup

    public init(process: any ProcessRunning) {
        self.setup = ConnectionSetup(process: process)
    }

    /// ensureKey, check, and (only when the check is `.ok`) resolve every folder that is not ready.
    /// Any other result returns `config` unchanged. If a resolve fails, the result is `.failed`
    /// and that folder stays unresolved; folders resolved before it stay resolved.
    public func connect(_ config: Config) async -> (result: ConnectionResult, config: Config) {
        do {
            _ = try await setup.ensureKey(identityFile: config.identityFile)
        } catch {
            return (.failed(Self.message(for: error)), config)
        }
        let result = await setup.check(server: config.server, identityFile: config.identityFile)
        guard case .ok = result else { return (result, config) }

        // Paths resolved on another server mean nothing here: resolve them all again.
        let resolveAll = config.verifiedServer != config.server
        var updated = config
        for index in updated.folders.indices where resolveAll || !updated.folders[index].isReady {
            do {
                updated.folders[index].remotePath = try await setup.resolveRemotePath(
                    updated.folders[index].remotePath, server: updated.server, identityFile: updated.identityFile)
            } catch {
                return (.failed(Self.message(for: error)), updated)
            }
        }
        updated.verifiedServer = updated.server
        return (result, updated)
    }

    /// Resolves the remote path and appends the folder. Never returns an invalid config.
    public func addFolder(to config: Config, localPath: String, remoteEntered: String) async -> AddFolderResult {
        let entered = remoteEntered.trimmingCharacters(in: .whitespacesAndNewlines)
        if !config.isVerified { return .rejected("Testa anslutningen först.") }

        // Everything knowable without the server: nested or unsafe paths.
        var candidate = config
        candidate.folders.append(FolderConfig(path: localPath, remotePath: entered))
        if let issue = candidate.validate().first { return .rejected(issue.message) }

        let resolved: String
        do {
            resolved = try await setup.resolveRemotePath(entered, server: config.server, identityFile: config.identityFile)
        } catch {
            return .rejected(Self.message(for: error))
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

    static func message(for error: any Error) -> String {
        guard let error = error as? ConnectionError else { return "\(error)" }
        switch error {
        case .unsafePath(let path):
            return "Sökvägen på servern \"\(path)\" innehåller otillåtna tecken."
        case .unsafeServer:
            return "Serveradressen är ogiltig"
        case .remoteCommandFailed(let outcome):
            return "Kunde inte skapa mappen på servern: \(outcome.message ?? "okänt fel")"
        case .unexpectedOutput:
            return "Oväntat svar från servern"
        case .pathTooBroad:
            return "Välj en egen mapp på servern, inte hemkatalogen eller en mapp ovanför den."
        case .keyCreationFailed(let detail):
            return "Kunde inte skapa nyckeln: \(detail)"
        }
    }
}
