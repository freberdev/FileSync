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

    /// What can be judged about adding the server destination without the server and without looking
    /// at the folder itself: the message to show, or nil when nothing speaks against it. Starts no process.
    public func addRejection(to config: Config, localPath: String, remoteEntered: String) -> String? {
        let entered = remoteEntered.trimmingCharacters(in: .whitespacesAndNewlines)
        if !config.isVerified { return "Testa anslutningen först." }

        var candidate = config
        if let index = Self.folderIndex(of: localPath, in: config) {
            if config.folders[index].destinations.contains(where: \.isServer) {
                return "Mappen har redan ett mål på servern."
            }
            candidate.folders[index].remotePath = entered
        } else {
            // Nested or unsafe paths.
            candidate.folders.append(FolderConfig(path: Self.resolved(localPath), remotePath: entered))
        }
        return candidate.validate().first?.message
    }

    /// Resolves the remote path and adds it to the folder, or appends the folder when it is new.
    /// Never returns an invalid config.
    public func addServerDestination(to config: Config, localPath: String, remoteEntered: String) async -> AddFolderResult {
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
        if let index = Self.folderIndex(of: localPath, in: config) {
            result.folders[index].remotePath = resolved
        } else {
            result.folders.append(FolderConfig(path: Self.resolved(localPath), remotePath: resolved))
        }
        if let issue = result.validate().first { return .rejected(issue.message) }
        return .added(result)
    }

    /// Resolves the remote path and appends the folder. Never returns an invalid config.
    public func addFolder(to config: Config, localPath: String, remoteEntered: String) async -> AddFolderResult {
        await addServerDestination(to: config, localPath: localPath, remoteEntered: remoteEntered)
    }

    /// Removes the folder from the configuration only; nothing is deleted on the server.
    public static func removeFolder(_ folder: FolderConfig, from config: Config) -> Config {
        var updated = config
        updated.folders.removeAll { $0 == folder }
        return updated
    }

    /// Removes one destination from the configuration only; nothing is touched on the server or the
    /// disk. The folder goes when its last destination does.
    public static func removeDestination(_ destinationID: String, fromFolder path: String, in config: Config) -> Config {
        var updated = config
        guard let index = folderIndex(of: path, in: updated) else { return config }
        let before = updated.folders[index].destinations.count
        updated.folders[index].destinations.removeAll { $0.id == destinationID }
        guard updated.folders[index].destinations.count < before else { return config }
        if updated.folders[index].destinations.isEmpty { updated.folders.remove(at: index) }
        return updated
    }

    /// True when the folder, or the folder a link points to, is already in the configuration.
    public static func isWatched(_ localPath: String, in config: Config) -> Bool {
        folderIndex(of: localPath, in: config) != nil
    }

    // MARK: Disk destinations

    private struct DiskPlan {
        var config: Config
        var destination: String
        var hasMarker: Bool
        var folder: String
    }

    /// What can be judged about adding the disk destination without writing anything: the message to
    /// show, or nil when nothing speaks against it. Only reads (stat and a listing of the picked folder).
    public func diskRejection(to config: Config, localPath: String, pickedPath: String,
                              volumes: [VolumeInfo]) -> String? {
        if case .failure(let rejection) = diskPlan(config, localPath: localPath, pickedPath: pickedPath, volumes: volumes) {
            return rejection.text
        }
        return nil
    }

    /// Adds the disk destination and writes the marker in the picked folder when it has none. The folder
    /// must be empty (or already carry the marker); nothing on the disk is moved, changed or removed.
    /// Never returns an invalid config.
    public func addDiskDestination(to config: Config, localPath: String, pickedPath: String,
                                   volumes: [VolumeInfo]) -> AddFolderResult {
        switch diskPlan(config, localPath: localPath, pickedPath: pickedPath, volumes: volumes) {
        case .failure(let rejection):
            return .rejected(rejection.text)
        case .success(let plan):
            if !plan.hasMarker {
                do {
                    try DiskMarker.write(in: plan.destination, folder: plan.folder)
                } catch {
                    log?("Kunde inte skriva markören i \(plan.destination): \(error)")
                    return .rejected("Kunde inte skriva till mappen på disken.")
                }
            }
            return .added(plan.config)
        }
    }

    private static let notEmptyText = "Mappen på disken måste vara tom. Skapa en ny mapp för säkerhetskopian."

    private struct Rejection: Error { var text: String }

    private func diskPlan(_ config: Config, localPath: String, pickedPath: String,
                          volumes: [VolumeInfo]) -> Result<DiskPlan, Rejection> {
        func reject(_ text: String) -> Result<DiskPlan, Rejection> { .failure(Rejection(text: text)) }

        let picked = Self.resolvingExistingPart(of: pickedPath)
        guard let volume = VolumeLookup.volume(containing: picked, in: volumes),
              let uuid = volume.uuid, !uuid.isEmpty else {
            return reject("Disken saknar id och kan inte användas.")
        }
        if volume.isSystem { return reject("Välj en mapp på en extern disk.") }
        if !volume.format.isSupported {
            return reject("Disken måste vara formaterad som APFS, Mac OS Extended eller exFAT.")
        }
        guard let relative = VolumeLookup.relativePath(of: picked, on: volume) else {
            return reject("Disken saknar id och kan inte användas.")
        }
        if relative.isEmpty { return reject("Välj en mapp på disken, inte diskens rot.") }

        guard let destination = Self.realPath(pickedPath), Self.isDirectory(destination) else {
            return reject("Mappen finns inte.")
        }
        guard localPath.hasPrefix("/") else { return reject(ConfigIssue.localPathNotAbsolute(localPath).message) }
        guard let local = Self.realPath(localPath), Self.isDirectory(local) else {
            return reject("Mappen på Macen finns inte.")
        }

        // A folder with content is only taken over when its marker names this very folder; a marker
        // naming another folder never is, since the first mirror would move that backup away.
        let recorded = DiskMarker.folder(in: destination)
        let hasMarker = recorded != nil
        if let recorded {
            if recorded != local { return reject(Self.notEmptyText) }
        } else if !Self.holdsOnlyFinderFiles(destination) {
            return reject(Self.notEmptyText)
        }

        let destinationParts = Self.components(destination)
        var watched = config.folders.map { Self.resolved($0.path) }
        watched.append(local)
        for path in watched {
            let parts = Self.components(path)
            if Self.isPrefix(parts, of: destinationParts) || Self.isPrefix(destinationParts, of: parts) {
                return reject("Mappen på disken och en bevakad mapp ligger inuti varandra.")
            }
        }

        let location = DiskLocation(volumeUUID: uuid, volumeName: volume.name, path: relative)
        var candidate = config
        if let index = Self.folderIndex(of: local, in: candidate) {
            let same = candidate.folders[index].diskDestinations.contains {
                $0.volumeUUID.caseInsensitiveCompare(uuid) == .orderedSame && $0.path == relative
            }
            if same {
                return reject("Mappen har redan det här målet.")
            }
            candidate.folders[index].destinations.append(.disk(location))
        } else {
            var folder = FolderConfig(path: local, destinations: [.disk(location)])
            if let source = VolumeLookup.volume(containing: local, in: volumes),
               !source.isSystem, let id = source.uuid, !id.isEmpty {
                folder.sourceVolumeUUID = id
            }
            candidate.folders.append(folder)
        }
        if let issue = candidate.validate().first { return reject(issue.message) }
        return .success(DiskPlan(config: candidate, destination: destination, hasMarker: hasMarker, folder: local))
    }

    /// The folder in the config that is the same folder as `localPath`: an exact match, or the same
    /// path once links are resolved (the standardised path where resolving fails).
    private static func folderIndex(of localPath: String, in config: Config) -> Int? {
        if let exact = config.folders.firstIndex(where: { $0.path == localPath }) { return exact }
        let wanted = resolved(localPath)
        return config.folders.firstIndex { resolved($0.path) == wanted }
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func isPrefix(_ prefix: [String], of path: [String]) -> Bool {
        prefix.count <= path.count && Array(path.prefix(prefix.count)) == prefix
    }

    private static func realPath(_ path: String) -> String? {
        guard let result = realpath(path, nil) else { return nil }
        defer { free(result) }
        return String(cString: result)
    }

    private static func resolved(_ path: String) -> String {
        realPath(path) ?? (path as NSString).standardizingPath
    }

    /// The path with its longest existing part resolved, so a folder that is missing can still be
    /// placed on a volume.
    private static func resolvingExistingPart(of path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var rest: [String] = []
        var base = path
        while base.count > 1 {
            if let real = realPath(base) {
                return rest.isEmpty ? real : ((real == "/" ? "" : real) + "/" + rest.reversed().joined(separator: "/"))
            }
            let name = (base as NSString).lastPathComponent
            guard !name.isEmpty else { break }
            rest.append(name)
            base = (base as NSString).deletingLastPathComponent
        }
        return path
    }

    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// Only `.DS_Store`, `._*` files and a marker; false when the listing fails.
    private static func holdsOnlyFinderFiles(_ directory: String) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return false }
        return names.allSatisfy { $0 == ".DS_Store" || $0.hasPrefix("._") }
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
