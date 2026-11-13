import AppKit
import Observation
import FilsynkCore

enum ConnectionState: Equatable {
    case unknown, testing, ok(String), problem(String)
}

/// A folder whose inspection found warnings; it is added only if the user confirms.
struct PendingFolder: Equatable {
    let localPath: String
    let remoteEntered: String
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
    private(set) var pendingFolder: PendingFolder?
    /// True while a connection test or folder addition is under way; settings edits are refused meanwhile.
    private(set) var isBusy = false
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
    @ObservationIgnored private let volumes = SystemVolumeMonitor()

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
        log.write("Filsynk startar")
        let firstStart = !FileManager.default.fileExists(atPath: store.url.path)
        do {
            config = try store.load()
        } catch {
            log.write("Konfigurationsfilen kan inte läsas: \(error)")
            configError = "Konfigurationsfilen kan inte läsas"
            publish()
            return
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

    /// Inspects the folder before anything is saved, so that no sync starts before its warnings
    /// have been seen. With warnings the folder waits in `pendingFolder` for `confirmPendingFolder()`.
    /// Returns true when the folder was added.
    func addFolder(localPath: String, remoteEntered: String) async -> Bool {
        guard canEdit else { return false }
        isBusy = true
        defer { isBusy = false }
        issue = nil
        if let message = flow.addRejection(to: config, localPath: localPath, remoteEntered: remoteEntered) {
            issue = message
            return false
        }
        let report = await Task.detached { FolderInspector.inspect(path: localPath) }.value
        switch FolderAddStep.after(report, confirmed: false) {
        case .confirm:
            pendingFolder = PendingFolder(localPath: localPath, remoteEntered: remoteEntered, report: report)
            return false
        case .add:
            return await performAdd(localPath: localPath, remoteEntered: remoteEntered)
        }
    }

    /// Adds the pending folder despite its warnings. Returns true when the folder was added.
    func confirmPendingFolder() async -> Bool {
        guard canSave, !isBusy, let pending = pendingFolder else { return false }
        isBusy = true
        defer { isBusy = false }
        pendingFolder = nil
        guard FolderAddStep.after(pending.report, confirmed: true) == .add else { return false }
        return await performAdd(localPath: pending.localPath, remoteEntered: pending.remoteEntered)
    }

    /// Discards the pending folder; nothing was saved.
    func cancelPendingFolder() {
        guard !isBusy else { return }
        pendingFolder = nil
    }

    private func performAdd(localPath: String, remoteEntered: String) async -> Bool {
        switch await flow.addFolder(to: config, localPath: localPath, remoteEntered: remoteEntered) {
        case .rejected(let message):
            issue = message
            return false
        case .added(let updated):
            issue = apply(updated)
            return issue == nil
        }
    }

    func removeFolder(_ folder: FolderConfig) {
        guard canEdit else { return }
        issue = apply(SetupFlow.removeFolder(folder, from: config))
    }

    /// The status of the folder's server destination.
    func state(of folder: FolderConfig) -> FolderStatus? {
        status.folders.first { $0.path == folder.path && $0.destination?.isServer == true }
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
