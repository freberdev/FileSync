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

/// Watches the configured folders and syncs each of their destinations when its `FolderSchedule`
/// says so. All scheduling decisions are the schedules'; the engine only feeds them events and runs
/// syncs when `nextFireDate` has passed. One sleeping task wakes at the earliest fire date.
public actor SyncEngine {
    /// A destination of a folder: its local path and `Destination.id`.
    private struct SlotKey: Hashable {
        let path: String
        let destinationID: String
    }

    private struct Slot {
        let folder: FolderConfig
        let destination: Destination
        let participates: Bool
        var schedule: FolderSchedule
        /// The schedule as it was before the running sync started; restored if that sync is cancelled.
        var scheduleBeforeSync: FolderSchedule?

        var key: SlotKey { SlotKey(path: folder.path, destinationID: destination.id) }
    }

    /// A running sync, keyed by destination. Kept until its task has ended, also after the
    /// engine cancelled it, so that a destination never has two syncs at once.
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
    /// One per folder with at least one participating destination, while running.
    private var watchers: [String: any FolderWatching] = [:]
    private var inFlight: [SlotKey: InFlight] = [:]
    /// Destinations asked for by `syncNow`; they run even when automatic syncs are held.
    private var forced: Set<SlotKey> = []
    private var noticePolicies: [SlotKey: NoticePolicy] = [:]
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
        self.published = Self.status(config: config, slots: slots, isPaused: false)
        onStatus(published)
    }

    // MARK: Public API

    /// Starts watching and requests an immediate sync of every participating destination.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        isNetworkKnown = false
        generation += 1
        let generation = self.generation
        let now = Date()
        for index in slots.indices where slots[index].participates {
            let path = slots[index].folder.path
            if watchers[path] == nil {
                let watcher = makeWatcher(path) { [weak self] in
                    Task { await self?.folderChanged(path, generation: generation) }
                }
                watchers[path] = watcher
                watcher.start()
            }
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
        stop(keepingSyncsOf: [])
    }

    /// Like `stop()`, but the syncs of the destinations in `kept` go on running and report as usual.
    private func stop(keepingSyncsOf kept: Set<SlotKey>) {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
        network.stop()
        wakeTask?.cancel()
        wakeTask = nil
        noticeTask?.cancel()
        noticeTask = nil
        forced.removeAll()
        for key in Array(inFlight.keys) where inFlight[key]?.discarded == false && !kept.contains(key) {
            inFlight[key]?.task.cancel()
            inFlight[key]?.discarded = true
            if let index = slots.firstIndex(where: { $0.key == key }),
               let before = slots[index].scheduleBeforeSync {
                slots[index].schedule = before
                slots[index].scheduleBeforeSync = nil
            }
        }
        publishIfChanged()
    }

    /// Stops, replaces the configuration and starts again if the engine was running.
    ///
    /// A destination whose folder (local path and source volume) and destination are unchanged,
    /// and which takes part before and after, keeps its schedule (last success, pending changes,
    /// failures); a server destination also needs the same server. Its running sync is left to
    /// finish when the sync inputs for its kind are unchanged too; otherwise it is cancelled.
    public func reload(_ config: Config) {
        let wasRunning = isRunning
        let oldConfig = self.config
        let newTiming = fixedTiming ?? EngineTiming(config: config)
        var newSlots = Self.makeSlots(config: config, timing: newTiming)

        let sameServer = oldConfig.server == config.server
        func previous(_ slot: Slot) -> Slot? {
            guard slot.participates, !slot.destination.isServer || sameServer else { return nil }
            return slots.first {
                $0.participates && $0.key == slot.key && $0.destination == slot.destination
                    && $0.folder.sourceVolumeUUID == slot.folder.sourceVolumeUUID
            }
        }
        let kept: Set<SlotKey> = Set(newSlots.filter {
            previous($0) != nil && inFlight[$0.key]?.discarded == false
                && Self.sameSyncInputs(oldConfig, config, for: $0.destination)
        }.map(\.key))

        stop(keepingSyncsOf: kept)
        for index in newSlots.indices {
            guard let old = previous(newSlots[index]) else { continue }
            newSlots[index].schedule = old.schedule.retimed(
                quiet: newTiming.quiet, maxWait: newTiming.maxWait, backoff: newTiming.backoff)
            newSlots[index].scheduleBeforeSync = old.scheduleBeforeSync?.retimed(
                quiet: newTiming.quiet, maxWait: newTiming.maxWait, backoff: newTiming.backoff)
        }
        self.config = config
        timing = newTiming
        slots = newSlots
        if wasRunning { start() } else { publishIfChanged() }
    }

    /// The configuration a running sync was started with is still the one it would be started with now.
    private static func sameSyncInputs(_ a: Config, _ b: Config, for destination: Destination) -> Bool {
        let common = a.rsyncPath == b.rsyncPath && a.exclude == b.exclude
        switch destination {
        case .server: return common && a.server == b.server && a.identityFile == b.identityFile
        case .disk: return common
        }
    }

    /// The schedule of a destination of a folder, for inspection.
    func schedule(of path: String, destinationID: String = "server") -> FolderSchedule? {
        slots.first { $0.key == SlotKey(path: path, destinationID: destinationID) }?.schedule
    }

    /// Pausing holds automatic syncs; resuming requests an immediate sync of every participating destination.
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

    /// Immediate sync of every participating destination, also when paused or on a metered network.
    public func syncNow() {
        guard isRunning else { return }
        let now = Date()
        for index in slots.indices where slots[index].participates {
            slots[index].schedule.requestImmediate(at: now)
            forced.insert(slots[index].key)
        }
        runDue()
    }

    // MARK: Events

    private func folderChanged(_ path: String, generation: Int) {
        guard isRunning, generation == self.generation else { return }
        let now = Date()
        for index in slots.indices where slots[index].folder.path == path && slots[index].participates {
            slots[index].schedule.changeDetected(at: now)
        }
        runDue()
    }

    /// Only server destinations depend on the network.
    private func networkChanged(generation: Int) {
        guard isRunning, generation == self.generation else { return }
        isNetworkKnown = true
        let now = Date()
        // A denied login is not retried early: repeated refused logins can get the Mac banned.
        for index in slots.indices where slots[index].participates && slots[index].destination.isServer
            && slots[index].schedule.isDirty && slots[index].schedule.lastOutcome != .authDenied {
            slots[index].schedule.requestImmediate(at: now)
        }
        runDue()
    }

    private func syncEnded(key: SlotKey, id: Int, outcome: SyncOutcome) {
        guard let running = inFlight[key], running.id == id else { return }
        inFlight[key] = nil
        if !running.discarded,
           let index = slots.firstIndex(where: { $0.key == key && $0.participates }) {
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

    /// Automatic syncs are held while paused. Those to the server are also held on a metered
    /// network, or before the first network update since `start()` (the network state is not known yet).
    private func isHeld(_ index: Int) -> Bool {
        isPaused || (slots[index].destination.isServer && (!isNetworkKnown || network.isMetered))
    }

    /// Starts every destination whose fire date has passed, then sleeps until the next one.
    private func runDue() {
        if isRunning {
            let now = Date()
            for index in slots.indices where canFire(index) {
                if let fire = slots[index].schedule.nextFireDate(), fire <= now {
                    startSync(index, now: now)
                }
            }
        }
        scheduleWake()
        publishIfChanged()
    }

    private func canFire(_ index: Int) -> Bool {
        let key = slots[index].key
        return slots[index].participates && inFlight[key] == nil && (forced.contains(key) || !isHeld(index))
    }

    private func scheduleWake() {
        wakeTask?.cancel()
        wakeTask = nil
        guard isRunning else { return }
        let earliest = slots.indices
            .filter { canFire($0) }
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
        let destination = slots[index].destination
        let key = slots[index].key
        forced.remove(key)
        slots[index].scheduleBeforeSync = slots[index].schedule
        slots[index].schedule.syncStarted(at: now)
        nextSyncID += 1
        let id = nextSyncID
        let runner = self.runner
        let config = self.config
        let task = Task { [weak self] in
            let outcome = await runner.sync(folder: folder, destination: destination, config: config, now: now)
            await self?.syncEnded(key: key, id: id, outcome: outcome)
        }
        inFlight[key] = InFlight(id: id, task: task)
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
        let slot = slots[index]
        let name = StatusPresentation.displayPath(slot.folder.path, home: NSHomeDirectory()) + " → "
            + StatusPresentation.destinationLabel(slot.destination, serverHome: config.verifiedHome)
        var policy = noticePolicies[slot.key] ?? NoticePolicy()
        let notices = policy.evaluate(folder: name, schedule: slot.schedule, now: now)
        noticePolicies[slot.key] = policy
        for notice in notices { onNotice(notice) }
    }

    private func publishIfChanged() {
        let status = Self.status(config: config, slots: slots, isPaused: isPaused)
        guard status != published else { return }
        published = status
        onStatus(status)
    }

    /// One row per destination, in the order of the folders and their destinations. A folder
    /// without destinations gets one row that is not configured.
    private static func status(config: Config, slots: [Slot], isPaused: Bool) -> EngineStatus {
        // `slots` holds the destinations of `config.folders` in order (see `makeSlots`).
        var rows: [FolderStatus] = []
        var rest = slots[...]
        for folder in config.folders {
            if folder.destinations.isEmpty {
                rows.append(FolderStatus(path: folder.path, destination: nil, state: .notConfigured, lastSuccess: nil))
            }
            for slot in rest.prefix(folder.destinations.count) {
                rows.append(FolderStatus(
                    path: slot.folder.path,
                    destination: slot.destination,
                    state: StatusPresentation.folderState(ready: slot.participates, schedule: slot.schedule),
                    lastSuccess: slot.schedule.lastSuccess))
            }
            rest = rest.dropFirst(folder.destinations.count)
        }
        return EngineStatus(folders: rows, isPaused: isPaused, configError: nil)
    }

    /// A server destination takes part when the configuration is valid, the server verified and
    /// the destination ready; a disk destination when the configuration is valid.
    private static func makeSlots(config: Config, timing: EngineTiming) -> [Slot] {
        let valid = config.validate().isEmpty
        return config.folders.flatMap { folder in
            folder.destinations.map { destination in
                let participates = destination.isServer ? valid && config.isVerified && destination.isReady : valid
                return Slot(
                    folder: folder,
                    destination: destination,
                    participates: participates,
                    schedule: FolderSchedule(quiet: timing.quiet, maxWait: timing.maxWait, backoff: timing.backoff))
            }
        }
    }
}
