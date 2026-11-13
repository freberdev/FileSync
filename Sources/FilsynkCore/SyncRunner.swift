import Foundation

public protocol SyncRunning: Sendable {
    func sync(folder: FolderConfig, config: Config, now: Date) async -> SyncOutcome
}

/// Performs one sync of one folder: guard, build command, run rsync, classify.
public final class SyncRunner: SyncRunning, @unchecked Sendable {
    private let process: ProcessRunning
    private let target: SyncTarget
    private let timeZone: TimeZone
    private let temporaryDirectory: URL
    private let log: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private var lastTimestamp: Date?

    public init(
        process: ProcessRunning,
        target: SyncTarget = .ssh,
        timeZone: TimeZone = .current,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.process = process
        self.target = target
        self.timeZone = timeZone
        self.temporaryDirectory = temporaryDirectory
        self.log = log
    }

    public func sync(folder: FolderConfig, config: Config, now: Date) async -> SyncOutcome {
        let started = Date()
        let outcome = await perform(folder: folder, config: config, now: now)
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        log?("\(folder.path): \(describe(outcome)) (\(seconds) s)")
        return outcome
    }

    private func perform(folder: FolderConfig, config: Config, now: Date) async -> SyncOutcome {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: folder.path) else {
            return .failed("Mappen \(folder.path) saknas eller går inte att läsa")
        }

        let timestamp = RsyncCommand.timestamp(nextTimestamp(for: now), timeZone: timeZone)

        let excludeURL = temporaryDirectory.appendingPathComponent("filsynk-exclude-\(UUID().uuidString)")
        do {
            try RsyncCommand.excludeFileContents(config).write(to: excludeURL, atomically: true, encoding: .utf8)
        } catch {
            log?("\(folder.path): kunde inte skriva undantagsfilen: \(error)")
            return .failed("Kunde inte förbereda synken")
        }
        defer { try? FileManager.default.removeItem(at: excludeURL) }

        let invocation = RsyncCommand.sync(
            config: config, folder: folder, timestamp: timestamp,
            excludeFile: excludeURL.path, target: target)
        do {
            let result = try await process.run(invocation.executable, invocation.arguments)
            return OutcomeClassifier.classify(exitCode: result.exitCode, stderr: result.stderr)
        } catch {
            log?("\(folder.path): kunde inte starta rsync: \(error)")
            return .failed("Kunde inte starta rsync: \(error.localizedDescription)")
        }
    }

    /// The timestamp must be strictly later than the previous one used by this instance.
    private func nextTimestamp(for now: Date) -> Date {
        lock.lock(); defer { lock.unlock() }
        var candidate = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        if let last = lastTimestamp, candidate <= last {
            candidate = last.addingTimeInterval(1)
        }
        lastTimestamp = candidate
        return candidate
    }

    private func describe(_ outcome: SyncOutcome) -> String {
        switch outcome {
        case .success: return "klar"
        case .unreachable: return "servern nås inte"
        case .authDenied: return "inloggningen nekades"
        case .failed(let m): return "misslyckades: \(m)"
        }
    }
}
