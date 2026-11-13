import Foundation

public struct EngineTiming: Equatable, Sendable {
    public var quiet: TimeInterval
    public var maxWait: TimeInterval
    public var backoff: [TimeInterval]
    public var noticeCheckInterval: TimeInterval

    /// quiet/maxWait from the config, backoff 60/120/300/900 s, notice check every 600 s.
    public init(config: Config) {
        self.init(
            quiet: TimeInterval(config.quietSeconds),
            maxWait: TimeInterval(config.maxWaitSeconds),
            backoff: [60, 120, 300, 900],
            noticeCheckInterval: 600)
    }

    public init(quiet: TimeInterval, maxWait: TimeInterval, backoff: [TimeInterval], noticeCheckInterval: TimeInterval) {
        self.quiet = quiet
        self.maxWait = maxWait
        self.backoff = backoff
        self.noticeCheckInterval = noticeCheckInterval
    }
}

/// Watches the configured folders and syncs them when their `FolderSchedule` says so.
/// All scheduling decisions are the schedule's; the engine only feeds it events and runs
/// syncs when `nextFireDate` has passed. One sleeping task wakes at the earliest fire date.
public actor SyncEngine {
    private struct Slot {
        let folder: FolderConfig
        let participates: Bool
        var schedule: FolderSchedule
        /// The schedule as it was before the running sync started; restored if that sync is cancelled.
        var scheduleBeforeSync: FolderSchedule?
        var watcher: (any FolderWatching)?
    }

    /// A running sync, keyed by local path. Kept until its task has ended, also after the
    /// engine cancelled it, so that a folder never has two syncs at once.
    private struct InFlight {
        let id: Int
        let task: Task<Void, Never>
        /// Cancelled by the engine (stop/reload): its outcome is discarded.
        var discarded = false
    }

    private var config: Config
    private let fixedTiming: EngineTiming?
    private var timing: EngineTiming
    private let runner: any SyncRunning
    private let makeWatcher: WatcherFactory
    private let network: any NetworkMonitoring
    private let onStatus: @Sendable (EngineStatus) -> Void
    private let onNotice: @Sendable (Notice) -> Void

    private var slots: [Slot]
    private var inFlight: [String: InFlight] = [:]
    /// Folders asked for by `syncNow`; they run even when automatic syncs are held.
    private var forced: Set<String> = []
    private var noticePolicy = NoticePolicy()
    private var isRunning = false
    private var isPaused = false
    /// False from `start()` until the first network update of that start; unknown counts as metered.
    private var isNetworkKnown = false
    /// Changes on every start/stop; callbacks carrying an older value are ignored.
    private var generation = 0
    private var nextSyncID = 0
    private var wakeTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var published: EngineStatus

    public init(
        config: Config, timing: EngineTiming? = nil, runner: any SyncRunning,
        makeWatcher: @escaping WatcherFactory, network: any NetworkMonitoring,
        onStatus: @escaping @Sendable (EngineStatus) -> Void,
        onNotice: @escaping @Sendable (Notice) -> Void
    ) {
        let effectiveTiming = timing ?? EngineTiming(config: config)
        let slots = Self.makeSlots(config: config, timing: effectiveTiming)
        self.config = config
        self.fixedTiming = timing
        self.timing = effectiveTiming
        self.runner = runner
        self.makeWatcher = makeWatcher
        self.network = network
        self.onStatus = onStatus
        self.onNotice = onNotice
        self.slots = slots
        self.published = Self.status(slots: slots, isPaused: false)
        onStatus(published)
    }

    // MARK: Public API

    /// Starts watching and requests an immediate sync of every ready folder.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        isNetworkKnown = false
        generation += 1
        let generation = self.generation
        let now = Date()
        for index in slots.indices where slots[index].participates {
            let path = slots[index].folder.path
            let watcher = makeWatcher(path) { [weak self] in
                Task { await self?.folderChanged(path, generation: generation) }
            }
            slots[index].watcher = watcher
            watcher.start()
            slots[index].schedule.requestImmediate(at: now)
        }
        network.start { [weak self] in
            Task { await self?.networkChanged(generation: generation) }
        }
        startNoticeChecks(generation: generation)
        runDue()
    }

    /// Stops watching and cancels running syncs; their outcomes are discarded.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        for index in slots.indices {
            slots[index].watcher?.stop()
            slots[index].watcher = nil
        }
        network.stop()
        wakeTask?.cancel()
        wakeTask = nil
        noticeTask?.cancel()
        noticeTask = nil
        forced.removeAll()
        for path in Array(inFlight.keys) where inFlight[path]?.discarded == false {
            inFlight[path]?.task.cancel()
            inFlight[path]?.discarded = true
            if let index = slots.firstIndex(where: { $0.folder.path == path }),
               let before = slots[index].scheduleBeforeSync {
                slots[index].schedule = before
                slots[index].scheduleBeforeSync = nil
            }
        }
        publishIfChanged()
    }

    /// Stops, replaces the configuration and starts again if the engine was running.
    public func reload(_ config: Config) {
        let wasRunning = isRunning
        stop()
        self.config = config
        timing = fixedTiming ?? EngineTiming(config: config)
        slots = Self.makeSlots(config: config, timing: timing)
        if wasRunning { start() } else { publishIfChanged() }
    }

    /// Pausing holds automatic syncs; resuming requests an immediate sync of every ready folder.
    public func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if !paused, isRunning {
            let now = Date()
            for index in slots.indices where slots[index].participates {
                slots[index].schedule.requestImmediate(at: now)
            }
        }
        runDue()
    }

    /// Immediate sync of every ready folder, also when paused or on a metered network.
    public func syncNow() {
        guard isRunning else { return }
        let now = Date()
        for index in slots.indices where slots[index].participates {
            slots[index].schedule.requestImmediate(at: now)
            forced.insert(slots[index].folder.path)
        }
        runDue()
    }

    // MARK: Events

    private func folderChanged(_ path: String, generation: Int) {
        guard isRunning, generation == self.generation,
              let index = slots.firstIndex(where: { $0.folder.path == path && $0.participates }) else { return }
        slots[index].schedule.changeDetected(at: Date())
        runDue()
    }

    private func networkChanged(generation: Int) {
        guard isRunning, generation == self.generation else { return }
        isNetworkKnown = true
        let now = Date()
        for index in slots.indices where slots[index].participates && slots[index].schedule.isDirty {
            slots[index].schedule.requestImmediate(at: now)
        }
        runDue()
    }

    private func syncEnded(path: String, id: Int, outcome: SyncOutcome) {
        guard let running = inFlight[path], running.id == id else { return }
        inFlight[path] = nil
        if !running.discarded,
           let index = slots.firstIndex(where: { $0.folder.path == path && $0.participates }) {
            let now = Date()
            slots[index].schedule.syncFinished(outcome, at: now)
            slots[index].scheduleBeforeSync = nil
            emitNotices(for: index, now: now)
        }
        runDue()
    }

    private func checkNotices(generation: Int) {
        guard isRunning, generation == self.generation else { return }
        let now = Date()
        for index in slots.indices where slots[index].participates {
            emitNotices(for: index, now: now)
        }
    }

    // MARK: Scheduling

    /// Automatic syncs are held while paused, on a metered network, or before the first network
    /// update since `start()` (the network state is not known yet).
    private var isHeld: Bool { isPaused || !isNetworkKnown || network.isMetered }

    /// Starts every folder whose fire date has passed, then sleeps until the next one.
    private func runDue() {
        if isRunning {
            let now = Date()
            let held = isHeld
            for index in slots.indices where canFire(index, held: held) {
                if let fire = slots[index].schedule.nextFireDate(), fire <= now {
                    startSync(index, now: now)
                }
            }
        }
        scheduleWake()
        publishIfChanged()
    }

    private func canFire(_ index: Int, held: Bool) -> Bool {
        let path = slots[index].folder.path
        return slots[index].participates && inFlight[path] == nil && (!held || forced.contains(path))
    }

    private func scheduleWake() {
        wakeTask?.cancel()
        wakeTask = nil
        guard isRunning else { return }
        let held = isHeld
        let earliest = slots.indices
            .filter { canFire($0, held: held) }
            .compactMap { slots[$0].schedule.nextFireDate() }
            .min()
        guard let earliest else { return }
        let delay = max(0, earliest.timeIntervalSinceNow)
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.runDue()
        }
    }

    private func startSync(_ index: Int, now: Date) {
        let folder = slots[index].folder
        forced.remove(folder.path)
        slots[index].scheduleBeforeSync = slots[index].schedule
        slots[index].schedule.syncStarted(at: now)
        nextSyncID += 1
        let id = nextSyncID
        let runner = self.runner
        let config = self.config
        let task = Task { [weak self] in
            let outcome = await runner.sync(folder: folder, config: config, now: now)
            await self?.syncEnded(path: folder.path, id: id, outcome: outcome)
        }
        inFlight[folder.path] = InFlight(id: id, task: task)
    }

    private func startNoticeChecks(generation: Int) {
        let interval = timing.noticeCheckInterval
        noticeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.checkNotices(generation: generation)
            }
        }
    }

    // MARK: Output

    private func emitNotices(for index: Int, now: Date) {
        let folder = StatusPresentation.displayPath(slots[index].folder.path, home: NSHomeDirectory())
        for notice in noticePolicy.evaluate(folder: folder, schedule: slots[index].schedule, now: now) {
            onNotice(notice)
        }
    }

    private func publishIfChanged() {
        let status = Self.status(slots: slots, isPaused: isPaused)
        guard status != published else { return }
        published = status
        onStatus(status)
    }

    private static func status(slots: [Slot], isPaused: Bool) -> EngineStatus {
        let folders = slots.map { slot in
            FolderStatus(
                path: slot.folder.path,
                state: StatusPresentation.folderState(ready: slot.participates, schedule: slot.schedule),
                lastSuccess: slot.schedule.lastSuccess)
        }
        return EngineStatus(folders: folders, isPaused: isPaused, configError: nil)
    }

    private static func makeSlots(config: Config, timing: EngineTiming) -> [Slot] {
        let valid = config.validate().isEmpty && config.isVerified
        return config.folders.map { folder in
            Slot(
                folder: folder,
                participates: valid && folder.isReady,
                schedule: FolderSchedule(quiet: timing.quiet, maxWait: timing.maxWait, backoff: timing.backoff))
        }
    }
}
