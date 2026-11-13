import AppKit
import Observation
import FilsynkCore

@MainActor @Observable final class AppModel {
    private(set) var status: EngineStatus = .empty
    var config: Config
    /// Set on a fresh start without a config file; the app delegate side opens the settings window.
    private(set) var isFirstStart = false

    private(set) var hasStarted = false

    var isPaused: Bool { status.isPaused }

    @ObservationIgnored private var engineStatus: EngineStatus = .empty
    @ObservationIgnored private var configError: String?
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private let store: ConfigStore
    @ObservationIgnored private let log: FileLog
    @ObservationIgnored private let notifier: Notifier

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
        let firstStart = !FileManager.default.fileExists(atPath: ConfigStore.defaultURL.path)
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
        } else {
            makeEngine()
        }
        return nil
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
