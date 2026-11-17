import AppKit
import Observation
import FilsynkCore

enum ConnectionState: Equatable {
    case unknown, testing, ok(String), problem(String)
}

/// Where a folder is to be mirrored to.
enum NewDestination: Equatable {
    /// The path as the user typed it.
    case server(remoteEntered: String)
    /// The folder picked on the disk, as the panel returned it.
    case disk(pickedPath: String)
}

/// A folder whose inspection found warnings; it is added only if the user confirms.
struct PendingFolder: Equatable {
    let localPath: String
    let destination: NewDestination
    let report: FolderReport
    var warnings: [String] { report.warnings }
}

@MainActor @Observable final class AppModel {
    private(set) var status: EngineStatus = .empty
    var config: Config
    /// Set on a fresh start without a config file; `FilsynkApp` then opens the settings window.
    private(set) var isFirstStart = false

    private(set) var hasStarted = false
    var connection: ConnectionState = .unknown
    /// Set when the last test found the server rejecting the key; the settings window shows the command to run.
    private(set) var needsKeyInstall = false
    /// Validation or save error from the latest change; shown in red at the bottom of the settings window.
    private(set) var issue: String?
    /// A folder waiting for the user to confirm its warnings. Settings edits are refused meanwhile.
    private(set) var pendingFolder: PendingFolder? {
        didSet { recordSourceVolumesIfUnlocked() }
    }
    /// True while a connection test or folder addition is under way; settings edits are refused meanwhile.
    private(set) var isBusy = false {
        didSet { recordSourceVolumesIfUnlocked() }
    }
    /// Set when the config file exists but cannot be read. Nothing may be saved then, so the file is never overwritten.
    private(set) var configError: String?

    var isPaused: Bool { status.isPaused }
    /// The settings controls are disabled while this is true.
    var isLocked: Bool { isBusy || pendingFolder != nil }

    @ObservationIgnored private var engineStatus: EngineStatus = .empty
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private let store: ConfigStore
    @ObservationIgnored private let log: FileLog
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private let flow: SetupFlow
    /// The one volume monitor of the app; the disk runner and the engine share it.
    @ObservationIgnored private let volumes = SystemVolumeMonitor()
    @ObservationIgnored private var mountObserver: NSObjectProtocol?
    /// Set when the source volumes could not be recorded because the settings were locked, and after
    /// a folder has been added; they are recorded as soon as the settings are unlocked.
    @ObservationIgnored private var sourceVolumesPending = false

    init(store: ConfigStore = ConfigStore(url: ConfigStore.defaultURL), log: FileLog = FileLog(url: FileLog.defaultURL)) {
        self.store = store
        self.log = log
        self.notifier = Notifier(log: log)
        self.flow = SetupFlow(process: SystemProcessRunner(), log: { log.write($0) })
        self.config = Config.initial(home: NSHomeDirectory())
    }

    var configFilePath: String { store.url.path }

    /// The one place that decides whether anything may be saved: never over an unreadable file.
    private var canSave: Bool { configError == nil }
    /// Settings actions additionally wait for a running server request or a pending confirmation,
    /// so no snapshot can go stale.
    private var canEdit: Bool { canSave && !isLocked }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        log.write("FileSync startar")
        let firstStart = !FileManager.default.fileExists(atPath: store.url.path)
        do {
            config = try store.load()
        } catch {
            log.write("Konfigurationsfilen kan inte läsas: \(error)")
            configError = "Konfigurationsfilen kan inte läsas"
            publish()
            return
        }
        Task { await recordSourceVolumes() }
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.recordSourceVolumes() }
        }
        makeEngine()
        if firstStart {
            isFirstStart = true
            if Bundle.main.bundlePath.hasPrefix("/Applications/") {
                do { try LoginItem.setEnabled(true) } catch { log.write("Kunde inte lägga till som inloggningsobjekt: \(error)") }
            }
        }
    }

    /// Returns nil on success, otherwise the message to show the user.
    @discardableResult
    func apply(_ newConfig: Config) -> String? {
        guard canSave else { return "Konfigurationsfilen kan inte läsas" }
        if let issue = newConfig.validate().first { return issue.message }
        do {
            try store.save(newConfig)
        } catch {
            log.write("Kunde inte spara konfigurationen: \(error)")
            return "Kunde inte spara konfigurationen"
        }
        config = newConfig
        if let engine {
            Task { await engine.reload(newConfig) }
        } else if hasStarted {
            makeEngine()
        }
        // Before start() there is no engine to create; start() loads the saved file and makes it.
        return nil
    }

    // MARK: Settings

    /// Saves a change from the settings window; records the error to show when it is invalid.
    func change(_ edit: (inout Config) -> Void) {
        guard canEdit else { return }
        var updated = config
        edit(&updated)
        guard updated != config else { return }
        issue = apply(updated)
    }

    func setServer(_ server: String) {
        guard canEdit else { return }
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != config.server else { return }
        connection = .unknown
        needsKeyInstall = false
        change { $0.server = trimmed }
    }

    func setExcludes(_ text: String) {
        change { $0.exclude = Config.parseExcludes(text) }
    }

    var copyIdCommand: String {
        ConnectionSetup.copyIdCommand(identityFile: config.identityFile, server: config.server)
    }

    func testConnection() async {
        guard canEdit else { return }
        isBusy = true
        defer { isBusy = false }
        connection = .testing
        needsKeyInstall = false
        let outcome = await flow.connect(config)
        if outcome.config != config { issue = apply(outcome.config) }
        switch outcome.result {
        case .ok(let version): connection = .ok("✓ Ansluten, rsync \(version)")
        case .authDenied:
            needsKeyInstall = true
            connection = .problem("Servern accepterar inte nyckeln ännu. Kör kommandot nedan i Terminal och testa igen.")
        case .unreachable: connection = .problem("Servern nås inte.")
        case .unsupportedRsync(let m): connection = .problem("Servern behöver rsync 3 eller senare. \(m)")
        case .failed(let m): connection = .problem(m)
        }
    }

    /// The rows of the folder table: one per destination.
    var destinationRows: [DestinationRow] {
        DestinationRows.rows(config: config, status: status, home: NSHomeDirectory(), timeZone: .current)
    }

    /// The text shown for a folder picked on a disk: "<diskens namn>: <sökväg>".
    func pickedDiskText(_ pickedPath: String) async -> String {
        let volumes = self.volumes
        return await Task.detached {
            DestinationRows.pickedDiskText(pickedPath: pickedPath, volumes: volumes.mountedVolumes())
        }.value
    }

    /// Adds a destination to a folder. A folder that is not watched yet is inspected first, so that no
    /// sync starts before its warnings have been seen; with warnings it waits in `pendingFolder` for
    /// `confirmPendingFolder()`. A disk is judged before the folder is inspected, so that a folder
    /// that will be refused is not walked. Returns true when the destination was added.
    func addDestination(_ destination: NewDestination, toFolder localPath: String) async -> Bool {
        guard canEdit else { return false }
        isBusy = true
        defer { isBusy = false }
        issue = nil
        let rejection: String?
        switch destination {
        case .server(let remoteEntered):
            rejection = flow.addRejection(to: config, localPath: localPath, remoteEntered: remoteEntered)
        case .disk(let pickedPath):
            let flow = self.flow, volumes = self.volumes, config = self.config
            rejection = await Task.detached {
                flow.diskRejection(
                    to: config, localPath: localPath, pickedPath: pickedPath, volumes: volumes.mountedVolumes())
            }.value
        }
        if let rejection {
            issue = rejection
            return false
        }
        if SetupFlow.isWatched(localPath, in: config) {
            return await performAdd(localPath: localPath, destination: destination)
        }
        let report = await Task.detached { FolderInspector.inspect(path: localPath) }.value
        switch FolderAddStep.after(report, confirmed: false) {
        case .confirm:
            pendingFolder = PendingFolder(localPath: localPath, destination: destination, report: report)
            return false
        case .add:
            return await performAdd(localPath: localPath, destination: destination)
        }
    }

    /// Adds the pending folder despite its warnings. Returns true when the destination was added.
    func confirmPendingFolder() async -> Bool {
        guard canSave, !isBusy, let pending = pendingFolder else { return false }
        isBusy = true
        defer { isBusy = false }
        pendingFolder = nil
        guard FolderAddStep.after(pending.report, confirmed: true) == .add else { return false }
        return await performAdd(localPath: pending.localPath, destination: pending.destination)
    }

    /// Discards the pending folder; nothing was saved.
    func cancelPendingFolder() {
        guard !isBusy else { return }
        pendingFolder = nil
    }

    private func performAdd(localPath: String, destination: NewDestination) async -> Bool {
        let result: AddFolderResult
        switch destination {
        case .server(let remoteEntered):
            result = await flow.addServerDestination(to: config, localPath: localPath, remoteEntered: remoteEntered)
        case .disk(let pickedPath):
            // The volumes are read now, since a disk may have come or gone while the user was deciding.
            let flow = self.flow, volumes = self.volumes, config = self.config
            result = await Task.detached {
                flow.addDiskDestination(
                    to: config, localPath: localPath, pickedPath: pickedPath, volumes: volumes.mountedVolumes())
            }.value
        }
        switch result {
        case .rejected(let message):
            issue = message
            return false
        case .added(let updated):
            issue = apply(updated)
            // A folder added with a server destination has no source volume yet.
            if issue == nil { sourceVolumesPending = true }
            return issue == nil
        }
    }

    /// Removes one destination from the configuration; nothing is touched on the server or the disk.
    func removeDestination(_ row: DestinationRow) {
        guard canEdit else { return }
        issue = apply(SetupFlow.removeDestination(row.destinationID, fromFolder: row.folderPath, in: config))
    }

    func syncNow() {
        guard let engine else { return }
        Task { await engine.syncNow() }
    }

    func togglePause() {
        guard let engine else { return }
        let paused = !isPaused
        Task { await engine.setPaused(paused) }
    }

    func openLog() {
        let url = FileLog.defaultURL
        if !FileManager.default.fileExists(atPath: url.path) { log.write("Logg öppnad") }
        NSWorkspace.shared.open(url)
    }

    func quit() {
        let engine = self.engine
        Task {
            await engine?.stop()
            NSApplication.shared.terminate(nil)
        }
    }

    /// Remembers the volume of every folder that lies on a disk other than the system disk, so
    /// that the folder waits for that disk instead of syncing an empty mount point. The volumes are
    /// listed off the main actor, since a stalled network mount can hang the listing. While the
    /// settings are locked nothing is saved, so that an addition built on an older config cannot
    /// overwrite the result; it is done again once they are unlocked.
    private func recordSourceVolumes() async {
        guard canSave else { return }
        guard !isLocked else { sourceVolumesPending = true; return }
        let volumes = self.volumes
        let mounted = await Task.detached { volumes.mountedVolumes() }.value
        guard canSave else { return }
        guard !isLocked else { sourceVolumesPending = true; return }
        let updated = config.recordingSourceVolumes(mounted)
        guard updated != config else { return }
        if let message = apply(updated) { log.write("Kunde inte spara mappens volym: \(message)") }
    }

    private func recordSourceVolumesIfUnlocked() {
        guard sourceVolumesPending, !isLocked else { return }
        sourceVolumesPending = false
        Task { await recordSourceVolumes() }
    }

    // MARK: Engine

    private func makeEngine() {
        guard engine == nil else { return }
        let log = self.log
        let notifier = self.notifier
        // One runner of each kind for the life of the app: each keeps its own timestamps.
        let runner = DestinationRunner(
            server: SyncRunner(process: SystemProcessRunner(), log: { log.write($0) }),
            disk: DiskSyncRunner(process: SystemProcessRunner(), volumes: volumes, log: { log.write($0) }))
        let engine = SyncEngine(
            config: config, runner: runner,
            makeWatcher: { path, onChange in FolderWatcher(path: path, onChange: onChange) },
            network: SystemNetworkMonitor(),
            volumes: volumes,
            state: StateStore(url: StateStore.defaultURL),
            onStatus: { [weak self] status in
                Task { @MainActor in self?.engineStatus = status; self?.publish() }
            },
            onNotice: { notice in
                log.write("\(notice.title): \(notice.body)")
                notifier.post(notice)
            })
        self.engine = engine
        Task { await engine.start() }
    }

    private func publish() {
        if let configError {
            status = EngineStatus(folders: [], isPaused: false, configError: configError)
        } else {
            status = engineStatus
        }
    }
}
