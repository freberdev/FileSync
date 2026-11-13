import AppKit
import Observation
import FilsynkCore

enum ConnectionState: Equatable {
    case unknown, testing, ok(String), problem(String)
}

@MainActor @Observable final class AppModel {
    private(set) var status: EngineStatus = .empty
    var config: Config
    /// Set on a fresh start without a config file; the app delegate side opens the settings window.
    private(set) var isFirstStart = false

    private(set) var hasStarted = false
    var connection: ConnectionState = .unknown
    /// Set when the last test found the server rejecting the key; the settings window shows the command to run.
    private(set) var needsKeyInstall = false
    /// Validation or save error from the latest change; shown in red at the bottom of the settings window.
    private(set) var issue: String?
    /// Warnings from the latest added folder.
    private(set) var folderWarnings: [String] = []

    var isPaused: Bool { status.isPaused }

    @ObservationIgnored private var engineStatus: EngineStatus = .empty
    @ObservationIgnored private var configError: String?
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private let store: ConfigStore
    @ObservationIgnored private let log: FileLog
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private let flow = SetupFlow(process: SystemProcessRunner())

    init(store: ConfigStore = ConfigStore(url: ConfigStore.defaultURL), log: FileLog = FileLog(url: FileLog.defaultURL)) {
        self.store = store
        self.log = log
        self.notifier = Notifier(log: log)
        self.config = Config.initial(home: NSHomeDirectory())
    }

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
        if let issue = newConfig.validate().first { return issue.message }
        do {
            try store.save(newConfig)
        } catch {
            log.write("Kunde inte spara konfigurationen: \(error)")
            return "Kunde inte spara konfigurationen"
        }
        config = newConfig
        configError = nil
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
        var updated = config
        edit(&updated)
        guard updated != config else { return }
        issue = apply(updated)
    }

    func setServer(_ server: String) {
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

    /// Returns nil if the folder was rejected (see `issue`), otherwise the inspection report.
    func addFolder(localPath: String, remoteEntered: String) async -> FolderReport? {
        folderWarnings = []
        switch await flow.addFolder(to: config, localPath: localPath, remoteEntered: remoteEntered) {
        case .rejected(let message):
            issue = message
            return nil
        case .added(let updated):
            issue = apply(updated)
            if issue != nil { return nil }
            let report = await Task.detached { FolderInspector.inspect(path: localPath) }.value
            folderWarnings = report.warnings
            return report
        }
    }

    func removeFolder(_ folder: FolderConfig) {
        issue = apply(SetupFlow.removeFolder(folder, from: config))
        folderWarnings = []
    }

    func state(of folder: FolderConfig) -> FolderStatus? {
        status.folders.first { $0.path == folder.path }
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
        let runner = SyncRunner(process: SystemProcessRunner(), log: { log.write($0) })
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
