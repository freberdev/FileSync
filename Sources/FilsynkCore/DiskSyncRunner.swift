import Foundation

/// En synk av en mapp till en mapp på en extern disk. Disken slås upp på volym-id; det som rsync
/// skulle ha tagit bort flyttas först till `Raderat/<tidsstämpel>/`, sedan körs rsync utan radering.
public final class DiskSyncRunner: @unchecked Sendable {
    private let process: any ProcessRunning
    private let volumes: any VolumeMonitoring
    private let timeZone: TimeZone
    private let log: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private var lastTimestamp: Date?

    public init(process: any ProcessRunning, volumes: any VolumeMonitoring,
                timeZone: TimeZone = .current, log: (@Sendable (String) -> Void)? = nil) {
        self.process = process
        self.volumes = volumes
        self.timeZone = timeZone
        self.log = log
    }

    public func sync(folder: FolderConfig, disk: DiskLocation, config: Config, now: Date) async -> SyncOutcome {
        let started = Date()
        let outcome = await perform(folder: folder, disk: disk, config: config, now: now)
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        log?("\(folder.path) → \(disk.volumeName)/\(disk.path): \(describe(outcome)) (\(seconds) s)")
        return outcome
    }

    private func perform(folder: FolderConfig, disk: DiskLocation, config: Config, now: Date) async -> SyncOutcome {
        // 1. Volymen.
        let volume: VolumeInfo
        switch VolumeLookup.find(uuid: disk.volumeUUID, in: volumes.mountedVolumes()) {
        case .failure(.notMounted): return .unreachable
        case .failure(.duplicate): return .failed("Två inkopplade diskar har samma id.")
        case .success(let found): volume = found
        }
        guard volume.format.isSupported else { return .failed("Diskens format stöds inte.") }
        guard !volume.isSystem else { return .failed("Systemdisken kan inte vara mål.") }

        // 2. Källan.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: folder.path) else {
            return .failed("Mappen \(folder.path) saknas eller går inte att läsa")
        }
        if let sourceID = folder.sourceVolumeUUID, !sourceID.isEmpty, !sourceIsOnVolume(folder.path, id: sourceID) {
            return .unreachable
        }

        // 3. Målmappen ska finnas och vara en som appen tagit i bruk. Den skapas aldrig här.
        let unknown = SyncOutcome.failed("Mappen på disken känns inte igen. Lägg till målet igen.")
        guard Config.isValidDiskPath(disk.path),
              let destination = Self.destinationPath(mount: volume.mountPath, relative: disk.path),
              let recorded = DiskMarker.folder(in: destination),
              let resolvedSource = Self.realPath(folder.path),
              recorded == resolvedSource else {
            return unknown
        }

        let timestamp = RsyncCommand.timestamp(nextTimestamp(for: now, destination: destination), timeZone: timeZone)

        // 4. Torrkörningen.
        let excludeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("filsynk-exclude-\(UUID().uuidString)")
        do {
            try RsyncCommand.diskExcludeFileContents(config).write(to: excludeURL, atomically: true, encoding: .utf8)
        } catch {
            log?("\(folder.path): kunde inte skriva undantagsfilen: \(error)")
            return .failed("Kunde inte förbereda synken")
        }
        defer { try? FileManager.default.removeItem(at: excludeURL) }

        let dryRun = RsyncCommand.diskDryRun(
            config: config, source: folder.path, destination: destination,
            format: volume.format, excludeFile: excludeURL.path)
        let listing: ProcessResult
        do {
            listing = try await process.run(dryRun.executable, dryRun.arguments)
        } catch {
            log?("\(folder.path): kunde inte starta rsync: \(error)")
            return .failed("Kunde inte starta rsync: \(error.localizedDescription)")
        }
        // 24: filer försvann medan rsync listade. Varje listad sökväg kontrolleras ändå mot källan.
        guard listing.exitCode == 0 || listing.exitCode == 24 else {
            return localOutcome(exitCode: listing.exitCode, stderr: listing.stderr, volume: volume, disk: disk)
        }

        // 5. Samma disk på samma plats?
        guard isSameVolume(volume, disk: disk) else { return .unreachable }

        // Ett avbrott sätter inte igång något mer.
        guard !Task.isCancelled else { return .failed("Synken avbröts") }

        // 6. Flytta undan det som försvunnit.
        do {
            var listed = DeletionList.parse(listing.stdout)
            for entry in Self.replacedEntries(in: listing.stdout, destination: destination)
            where !listed.contains(entry) {
                listed.append(entry)
            }
            _ = try RaderatMover.move(
                listed, source: folder.path, destination: destination, timestamp: timestamp)
        } catch {
            return .failed("Kunde inte flytta undan raderade filer: \(error.localizedDescription)")
        }

        // 7. Den riktiga körningen.
        guard !Task.isCancelled else { return .failed("Synken avbröts") }
        guard isSameVolume(volume, disk: disk) else { return .unreachable }
        var raderat = stat()
        if lstat(destination + "/Raderat", &raderat) == 0, raderat.st_mode & S_IFMT != S_IFDIR {
            return .failed("Mappen Raderat på disken är inte en vanlig mapp.")
        }
        let real = RsyncCommand.diskSync(
            config: config, source: folder.path, destination: destination,
            format: volume.format, timestamp: timestamp, excludeFile: excludeURL.path)
        let outcome: SyncOutcome
        do {
            let result = try await process.run(real.executable, real.arguments)
            let classified = localOutcome(exitCode: result.exitCode, stderr: result.stderr, volume: volume, disk: disk)
            outcome = classified == .failed("Disken på servern är full") ? .failed("Disken är full") : classified
        } catch {
            log?("\(folder.path): kunde inte starta rsync: \(error)")
            outcome = .failed("Kunde inte starta rsync: \(error.localizedDescription)")
        }
        if outcome != .success, !isSameVolume(volume, disk: disk) { return .unreachable }
        return outcome
    }

    /// Som `OutcomeClassifier`, men "Broken pipe" och liknande betyder inte att disken är borta när
    /// den sitter kvar på samma plats: då är det ett vanligt fel med rsyncs sista rad som text.
    private func localOutcome(exitCode: Int32, stderr: String, volume: VolumeInfo, disk: DiskLocation) -> SyncOutcome {
        let classified = OutcomeClassifier.classify(exitCode: exitCode, stderr: stderr)
        guard classified == .unreachable, isSameVolume(volume, disk: disk) else { return classified }
        let last = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        guard let last else { return .failed("rsync avslutades med kod \(exitCode)") }
        return .failed(String(last.prefix(200)))
    }

    /// rsync tar bort en post som byter typ (fil som blir mapp, mapp som blir fil, fil som blir länk)
    /// utan att ta den med i `--backup` och utan att nämna den som borttagen. Torrkörningen visar den
    /// däremot som nyskapad på en plats där något redan finns. Sådana poster flyttas undan också.
    /// En mapp får avslutande snedstreck, som i `DeletionList`.
    private static func replacedEntries(in dryRunOutput: String, destination: String) -> [String] {
        var result: [String] = []
        for line in dryRunOutput.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            // Nio tecken flaggor, ett blanksteg, sedan namnet. Nyskapat är alla flaggor efter de två första "+".
            let bytes = Array(line)
            guard bytes.count > 10, bytes[9] == UInt8(ascii: " ") else { continue }
            let flags = Array(bytes.prefix(9))
            guard flags[0] != UInt8(ascii: "*"), flags.dropFirst(2).allSatisfy({ $0 == UInt8(ascii: "+") }) else { continue }
            var raw = Array(bytes.dropFirst(10))
            if raw.last == UInt8(ascii: "\r") { raw.removeLast() }
            let name = String(decoding: DeletionList.unescaped(raw), as: UTF8.self)
            var candidates = [name]
            if flags[1] == UInt8(ascii: "L") {
                // "namn -> mål": prova varje möjlig delning.
                var rest = name[...]
                while let r = rest.range(of: " -> ", options: .backwards) {
                    rest = rest[..<r.lowerBound]
                    candidates.append(String(rest))
                }
            }
            // Alla kandidater som finns lämnas över; mover avgör vilka som får flyttas.
            for candidate in candidates {
                let path = candidate.hasSuffix("/") ? String(candidate.dropLast()) : candidate
                guard !path.isEmpty else { continue }
                var info = stat()
                guard lstat(destination + "/" + path, &info) == 0 else { continue }
                let entry = info.st_mode & S_IFMT == S_IFDIR ? path + "/" : path
                if !result.contains(entry) { result.append(entry) }
            }
        }
        return result
    }

    private static func realPath(_ path: String) -> String? {
        guard let result = realpath(path, nil) else { return nil }
        defer { free(result) }
        return String(cString: result)
    }

    /// `<monteringspunkt>/<relativ sökväg>`, men bara om varje del är en riktig mapp (ingen länk, ingen fil).
    /// Delarna kontrolleras en i taget från monteringspunkten så att ingen länk leder ut från disken.
    private static func destinationPath(mount: String, relative: String) -> String? {
        var path = mount == "/" ? "" : mount
        for component in relative.split(separator: "/", omittingEmptySubsequences: false) {
            path += "/" + component
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        }
        return path
    }

    /// Disken ska fortfarande ha samma id och sitta på samma monteringspunkt som i början.
    private func isSameVolume(_ original: VolumeInfo, disk: DiskLocation) -> Bool {
        guard case .success(let current) = VolumeLookup.find(uuid: disk.volumeUUID, in: volumes.mountedVolumes()) else {
            return false
        }
        return current.mountPath == original.mountPath
    }

    private func sourceIsOnVolume(_ path: String, id: String) -> Bool {
        let mounted = volumes.mountedVolumes()
        let real = Self.realPath(path) ?? URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let holder = VolumeLookup.volume(containing: real, in: mounted),
              let holderID = holder.uuid, !holderID.isEmpty else { return false }
        return holderID.caseInsensitiveCompare(id) == .orderedSame
    }

    /// Tidsstämpeln är strikt senare än den förra som den här instansen använt, och namnger ingen
    /// post som redan finns under Raderat: rsync skriver över en sådan utan att fråga.
    private func nextTimestamp(for now: Date, destination: String) -> Date {
        lock.lock(); defer { lock.unlock() }
        var candidate = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        if let last = lastTimestamp, candidate <= last {
            candidate = last.addingTimeInterval(1)
        }
        while true {
            var info = stat()
            let name = RsyncCommand.timestamp(candidate, timeZone: timeZone)
            if lstat(destination + "/Raderat/" + name, &info) != 0 { break }
            candidate = candidate.addingTimeInterval(1)
        }
        lastTimestamp = candidate
        return candidate
    }

    private func describe(_ outcome: SyncOutcome) -> String {
        switch outcome {
        case .success: return "klar"
        case .unreachable: return "disken nås inte"
        case .authDenied: return "inloggningen nekades"
        case .failed(let m): return "misslyckades: \(m)"
        }
    }
}
