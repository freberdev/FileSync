import Foundation

public struct EngineTiming: Equatable, Sendable {
    public var quiet: TimeInterval
    public var maxWait: TimeInterval
    public var backoff: [TimeInterval]
    public var noticeCheckInterval: TimeInterval
    /// How long a volume that is about to be unmounted counts as gone if it never is (a refused eject).
    public var unmountGrace: TimeInterval

    /// quiet/maxWait from the config, backoff 60/120/300/900 s, notice check every 600 s, unmount grace 20 s.
    public init(config: Config) {
        self.init(
            quiet: TimeInterval(config.quietSeconds),
            maxWait: TimeInterval(config.maxWaitSeconds),
            backoff: [60, 120, 300, 900],
            noticeCheckInterval: 600)
    }

    public init(quiet: TimeInterval, maxWait: TimeInterval, backoff: [TimeInterval], noticeCheckInterval: TimeInterval,
                unmountGrace: TimeInterval = 20) {
        self.quiet = quiet
        self.maxWait = maxWait
        self.backoff = backoff
        self.noticeCheckInterval = noticeCheckInterval
        self.unmountGrace = unmountGrace
    }
}

/// Watches the configured folders and syncs each of their destinations when its `FolderSchedule`
/// says so. All scheduling decisions are the schedules'; the engine only feeds them events and runs
/// syncs when `nextFireDate` has passed. One sleeping task wakes at the earliest fire date.
///
/// A destination on a disk, and every destination of a folder on a disk, waits while that disk is
/// not connected and is synced as soon as it is mounted.
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
        /// The last success from an earlier launch, shown until this one has its own.
        var savedSuccess: Date?

        var key: SlotKey { SlotKey(path: folder.path, destinationID: destination.id) }
        var lastSuccess: Date? { schedule.lastSuccess ?? savedSuccess }

        /// The ids of the volumes the destination needs: its disk and the volume of its folder.
        var volumeIDs: [String] {
            var ids: [String] = []
            if let source = folder.sourceVolumeUUID, !source.isEmpty { ids.append(source) }
            if case .disk(let location) = destination { ids.append(location.volumeUUID) }
            return ids
        }

        func needs(volumeID id: String) -> Bool {
            volumeIDs.contains { $0.caseInsensitiveCompare(id) == .orderedSame }
        }
    }

    /// Why a destination cannot run because of its volumes.
    private enum VolumeHold {
        /// A volume it needs is not mounted.
        case absent
        /// Two mounted volumes have the id of one it needs.
        case duplicate
    }

    private static let duplicateMessage = "Två inkopplade diskar har samma id."

    private struct Leaving {
        let mountPath: String
        /// Tells the grace timer of this will-unmount from that of an earlier one.
        let token: Int
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
    private let volumes: any VolumeMonitoring
    private let state: StateStore?
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
    /// The mounted volumes as last read; refreshed on start, reload and every mount event.
    /// Volumes in `leaving` are left out.
    private var mounted: [VolumeInfo]
    /// Volumes that are about to be unmounted, by lowercased id. They count as gone until they are
    /// unmounted, mounted again, or the grace has passed (the eject was refused).
    private var leaving: [String: Leaving] = [:]
    private var leaveTasks: [String: Task<Void, Never>] = [:]
    private var nextLeaveToken = 0
    /// Changes on every start/stop; callbacks carrying an older value are ignored.
    private var generation = 0
    private var nextSyncID = 0
    private var wakeTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var published: EngineStatus

    /// `state` keeps the last success of every destination between launches; nil keeps nothing.
    public init(
        config: Config, timing: EngineTiming? = nil, runner: any SyncRunning,
        makeWatcher: @escaping WatcherFactory, network: any NetworkMonitoring,
        volumes: any VolumeMonitoring, state: StateStore? = nil,
        onStatus: @escaping @Sendable (EngineStatus) -> Void,
        onNotice: @escaping @Sendable (Notice) -> Void
    ) {
        let effectiveTiming = timing ?? EngineTiming(config: config)
        var slots = Self.makeSlots(config: config, timing: effectiveTiming)
        let saved = state?.load() ?? [:]
        for index in slots.indices {
            let key = slots[index].key
            slots[index].savedSuccess = saved[StateStore.key(path: key.path, destinationID: key.destinationID)]
        }
        let mounted = volumes.mountedVolumes()
        self.config = config
        self.fixedTiming = timing
        self.timing = effectiveTiming
        self.runner = runner
        self.makeWatcher = makeWatcher
        self.network = network
        self.volumes = volumes
        self.state = state
        self.onStatus = onStatus
        self.onNotice = onNotice
        self.slots = slots
        self.mounted = mounted
        self.published = Self.status(config: config, slots: slots, isPaused: false, mounted: mounted)
        onStatus(published)
    }

    // MARK: Public API

    /// Starts watching and requests an immediate sync of every participating destination whose
    /// volumes are connected.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        isNetworkKnown = false
        generation += 1
        let generation = self.generation
        // Events first, then the list: a volume mounted in between is in one of them.
        volumes.start(
            onMount: { [weak self] volume in
                Task { await self?.volumeMounted(volume, generation: generation) }
            },
            onWillUnmount: { [weak self] volume in
                Task { await self?.volumeWillUnmount(volume, generation: generation) }
            },
            onUnmount: { [weak self] path in
                Task { await self?.volumeUnmounted(path, generation: generation) }
            })
        for (id, entry) in leaving { armLeaveTimer(id: id, token: entry.token, generation: generation) }
        refreshVolumes()
        let now = Date()
        for index in slots.indices where slots[index].participates {
            let path = slots[index].folder.path
            if watchers[path] == nil { startWatcher(path, generation: generation) }
            if volumeHold(index) == nil {
                slots[index].schedule.requestImmediate(at: now)
            }
        }
        network.start { [weak self] in
            Task { await self?.networkChanged(generation: generation) }
        }
        startNoticeChecks(generation: generation)
        runDue()
    }

    private func startWatcher(_ path: String, generation: Int) {
        let watcher = makeWatcher(path) { [weak self] in
            Task { await self?.folderChanged(path, generation: generation) }
        }
        watchers[path] = watcher
        watcher.start()
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
        volumes.stop()
        wakeTask?.cancel()
        wakeTask = nil
        noticeTask?.cancel()
        noticeTask = nil
        // `leaving` is kept; `start()` arms the timers again.
        for task in leaveTasks.values { task.cancel() }
        leaveTasks.removeAll()
        forced.removeAll()
        for key in Array(inFlight.keys) where inFlight[key]?.discarded == false && !kept.contains(key) {
            discardSync(of: key)
        }
        publishIfChanged()
    }

    /// Cancels the running sync of a destination. Its outcome will be ignored, and the schedule is
    /// put back as it was before the sync started, so the work it was doing is still owed.
    private func discardSync(of key: SlotKey) {
        inFlight[key]?.task.cancel()
        inFlight[key]?.discarded = true
        if let index = slots.firstIndex(where: { $0.key == key }),
           let before = slots[index].scheduleBeforeSync {
            slots[index].schedule = before
            slots[index].scheduleBeforeSync = nil
        }
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
            let slot = newSlots[index]
            let same = slots.first { $0.key == slot.key && $0.destination == slot.destination }
            newSlots[index].savedSuccess = same?.lastSuccess
            guard let old = previous(newSlots[index]) else { continue }
            newSlots[index].schedule = old.schedule.retimed(
                quiet: newTiming.quiet, maxWait: newTiming.maxWait, backoff: newTiming.backoff)
            newSlots[index].scheduleBeforeSync = old.scheduleBeforeSync?.retimed(
                quiet: newTiming.quiet, maxWait: newTiming.maxWait, backoff: newTiming.backoff)
        }
        self.config = config
        timing = newTiming
        slots = newSlots
        if wasRunning {
            start()
        } else {
            refreshVolumes()
            publishIfChanged()
        }
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

    /// Pausing holds automatic syncs; resuming requests an immediate sync of every participating
    /// destination whose volumes are connected.
    public func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if !paused, isRunning {
            let now = Date()
            for index in slots.indices where slots[index].participates && volumeHold(index) == nil {
                slots[index].schedule.requestImmediate(at: now)
            }
        }
        runDue()
    }

    /// Immediate sync of every participating destination, also when paused or on a metered network.
    /// A destination whose volumes are not connected is left alone.
    public func syncNow() {
        guard isRunning else { return }
        let now = Date()
        for index in slots.indices where slots[index].participates && volumeHold(index) == nil {
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

    /// A volume was mounted: every destination that needs it is synced now, changed or not.
    /// A folder on it gets a new watcher, since the old one may not report anything after a remount.
    private func volumeMounted(_ volume: VolumeInfo, generation: Int) {
        guard isRunning, generation == self.generation else { return }
        if let id = volume.uuid, !id.isEmpty { stopLeaving(id.lowercased()) }
        refreshVolumes()
        if let id = volume.uuid, !id.isEmpty {
            let onVolume = Set(slots.filter {
                $0.participates && $0.folder.sourceVolumeUUID?.caseInsensitiveCompare(id) == .orderedSame
            }.map(\.folder.path))
            for path in onVolume.sorted() where watchers[path] != nil {
                watchers[path]?.stop()
                startWatcher(path, generation: generation)
            }
            let now = Date()
            for index in slots.indices where slots[index].participates && slots[index].needs(volumeID: id) {
                slots[index].schedule.requestImmediate(at: now)
            }
        }
        runDue()
    }

    /// A volume is about to go: the syncs that need it are cancelled and discarded, and the volume
    /// counts as gone from now on, so that nothing starts on it before it has been unmounted.
    private func volumeWillUnmount(_ volume: VolumeInfo, generation: Int) {
        guard isRunning, generation == self.generation else { return }
        let going = mounted.filter { $0.mountPath == volume.mountPath } + [volume]
        let ids = Set(going.compactMap { $0.uuid?.lowercased() }.filter { !$0.isEmpty })
        for key in Array(inFlight.keys) where inFlight[key]?.discarded == false {
            guard let slot = slots.first(where: { $0.key == key }),
                  ids.contains(where: { slot.needs(volumeID: $0) }) else { continue }
            discardSync(of: key)
        }
        for id in ids {
            nextLeaveToken += 1
            leaving[id] = Leaving(mountPath: volume.mountPath, token: nextLeaveToken)
            armLeaveTimer(id: id, token: nextLeaveToken, generation: generation)
        }
        mounted.removeAll { $0.mountPath == volume.mountPath || isLeaving($0) }
        runDue()
    }

    private func volumeUnmounted(_ path: String, generation: Int) {
        guard isRunning, generation == self.generation else { return }
        for (id, entry) in leaving where entry.mountPath == path { stopLeaving(id) }
        refreshVolumes()
        runDue()
    }

    /// A volume that was about to go is still there after the grace: the eject was refused.
    private func leaveExpired(id: String, token: Int, generation: Int) {
        guard isRunning, generation == self.generation, leaving[id]?.token == token else { return }
        stopLeaving(id)
        refreshVolumes()
        runDue()
    }

    private func armLeaveTimer(id: String, token: Int, generation: Int) {
        leaveTasks[id]?.cancel()
        let delay = timing.unmountGrace
        leaveTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.leaveExpired(id: id, token: token, generation: generation)
        }
    }

    private func stopLeaving(_ id: String) {
        leaving[id] = nil
        leaveTasks[id]?.cancel()
        leaveTasks[id] = nil
    }

    private func isLeaving(_ volume: VolumeInfo) -> Bool {
        guard let id = volume.uuid?.lowercased() else { return false }
        return leaving[id] != nil
    }

    private func refreshVolumes() {
        mounted = volumes.mountedVolumes().filter { !isLeaving($0) }
    }

    private func syncEnded(key: SlotKey, id: Int, outcome: SyncOutcome) {
        guard let running = inFlight[key], running.id == id else { return }
        inFlight[key] = nil
        if !running.discarded,
           let index = slots.firstIndex(where: { $0.key == key && $0.participates }) {
            let now = Date()
            slots[index].schedule.syncFinished(outcome, at: now)
            slots[index].scheduleBeforeSync = nil
            // A volume that vanished without notice: once it is known to be gone, the destination
            // waits for it instead of retrying.
            if outcome == .unreachable, !slots[index].volumeIDs.isEmpty {
                refreshVolumes()
            }
            if outcome == .success { saveState() }
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
    /// `syncNow` overrides these holds; it does not override `volumeHold`.
    private func isHeld(_ index: Int) -> Bool {
        isPaused || (slots[index].destination.isServer && (!isNetworkKnown || network.isMetered))
    }

    /// A destination is never started while a volume it needs is missing or ambiguous.
    private func volumeHold(_ index: Int) -> VolumeHold? {
        Self.volumeHold(slots[index], mounted: mounted)
    }

    /// The folder must also lie on its recorded volume: with two disks of the same name, its path
    /// may lead into the other one.
    private static func volumeHold(_ slot: Slot, mounted: [VolumeInfo]) -> VolumeHold? {
        var hold: VolumeHold?
        if let source = slot.folder.sourceVolumeUUID, !source.isEmpty {
            switch VolumeLookup.find(uuid: source, in: mounted) {
            case .failure(.notMounted): return .absent
            case .failure(.duplicate): hold = .duplicate
            case .success:
                guard let holder = VolumeLookup.volume(containing: slot.folder.path, in: mounted)?.uuid,
                      holder.caseInsensitiveCompare(source) == .orderedSame else { return .absent }
            }
        }
        if case .disk(let location) = slot.destination {
            switch VolumeLookup.find(uuid: location.volumeUUID, in: mounted) {
            case .failure(.notMounted): return .absent
            case .failure(.duplicate): hold = .duplicate
            case .success: break
            }
        }
        return hold
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
        return slots[index].participates && inFlight[key] == nil && volumeHold(index) == nil
            && (forced.contains(key) || !isHeld(index))
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

    /// Nothing is said about a destination that waits for its volume. The notice about changes
    /// waiting for a day is only given for the server: a disk may well be away for longer.
    private func emitNotices(for index: Int, now: Date) {
        guard volumeHold(index) == nil else { return }
        let slot = slots[index]
        let name = StatusPresentation.displayPath(slot.folder.path, home: NSHomeDirectory()) + " → "
            + StatusPresentation.destinationLabel(slot.destination, serverHome: config.verifiedHome)
        var policy = noticePolicies[slot.key] ?? NoticePolicy()
        let notices = policy.evaluate(folder: name, schedule: slot.schedule, now: now, allowStale: slot.destination.isServer)
        noticePolicies[slot.key] = policy
        for notice in notices { onNotice(notice) }
    }

    /// The last success of every destination there is now; destinations that are gone are dropped.
    private func saveState() {
        guard let state else { return }
        var saved: [String: Date] = [:]
        for slot in slots {
            if let date = slot.lastSuccess {
                saved[StateStore.key(path: slot.key.path, destinationID: slot.key.destinationID)] = date
            }
        }
        state.save(saved)
    }

    private func publishIfChanged() {
        let status = Self.status(config: config, slots: slots, isPaused: isPaused, mounted: mounted)
        guard status != published else { return }
        published = status
        onStatus(status)
    }

    /// One row per destination, in the order of the folders and their destinations. A folder
    /// without destinations gets one row that is not configured.
    private static func status(config: Config, slots: [Slot], isPaused: Bool, mounted: [VolumeInfo]) -> EngineStatus {
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
                    state: state(of: slot, mounted: mounted),
                    lastSuccess: slot.lastSuccess))
            }
            rest = rest.dropFirst(folder.destinations.count)
        }
        return EngineStatus(folders: rows, isPaused: isPaused, configError: nil)
    }

    private static func state(of slot: Slot, mounted: [VolumeInfo]) -> FolderState {
        guard slot.participates else { return .notConfigured }
        switch volumeHold(slot, mounted: mounted) {
        case .absent?: return .notConnected
        case .duplicate?: return .error(duplicateMessage)
        case nil: break
        }
        let state = StatusPresentation.folderState(ready: true, schedule: slot.schedule)
        // A disk that could not be reached is not connected, whatever the volume list said.
        if state == .waitingForServer, !slot.destination.isServer { return .notConnected }
        return state
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
