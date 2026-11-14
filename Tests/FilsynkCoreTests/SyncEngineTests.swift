import Foundation
import Testing
@testable import FilsynkCore

// MARK: - Fakes

/// Records every sync, answers with queued outcomes per destination or folder (default `.success`)
/// and can hold each sync for `delay` seconds. Measures concurrency per destination and in total.
/// A destination is named by `key(path, destinationID)`.
private actor FakeRunner: SyncRunning {
    private(set) var calls: [(path: String, destinationID: String, at: Date)] = []
    private(set) var cancelled: [String] = []
    /// Destination keys of the cancelled syncs.
    private(set) var cancelledKeys: [String] = []
    /// Per destination key.
    private(set) var maxConcurrent: [String: Int] = [:]
    private(set) var maxTotalConcurrent = 0
    private var current: [String: Int] = [:]
    private var outcomes: [String: [SyncOutcome]] = [:]
    private var delay: TimeInterval

    init(delay: TimeInterval = 0) { self.delay = delay }

    static func key(_ path: String, _ destinationID: String = "server") -> String { path + "|" + destinationID }

    /// For every destination of `path`, or only the one named by `destinationID`.
    func setOutcomes(_ list: [SyncOutcome], for path: String, destinationID: String? = nil) {
        outcomes[destinationID.map { Self.key(path, $0) } ?? path] = list
    }
    func setDelay(_ value: TimeInterval) { delay = value }

    func callCount(_ path: String) -> Int { calls.filter { $0.path == path }.count }
    func callCount(_ path: String, _ destinationID: String) -> Int {
        calls.filter { $0.path == path && $0.destinationID == destinationID }.count
    }
    var totalCalls: Int { calls.count }
    var currentTotal: Int { current.values.reduce(0, +) }
    func callDates(_ path: String) -> [Date] { calls.filter { $0.path == path }.map(\.at) }

    func sync(folder: FolderConfig, destination: Destination, config: Config, now: Date) async -> SyncOutcome {
        let path = folder.path
        let key = Self.key(path, destination.id)
        calls.append((path, destination.id, Date()))
        current[key, default: 0] += 1
        maxConcurrent[key] = max(maxConcurrent[key] ?? 0, current[key]!)
        maxTotalConcurrent = max(maxTotalConcurrent, currentTotal)
        defer { current[key]! -= 1 }

        if delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled {
                cancelled.append(path)
                cancelledKeys.append(key)
                // Like a terminated rsync, ending takes a moment (not itself cancellable).
                await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
                // Like the real runner: a terminated rsync is an ordinary failure.
                return .failed("rsync avbröts")
            }
        }
        for name in [key, path] {
            if var queue = outcomes[name], !queue.isEmpty {
                let outcome = queue.removeFirst()
                outcomes[name] = queue
                return outcome
            }
        }
        return .success
    }
}

/// Hands out each watcher's `onChange` per path so the test can trigger changes.
/// Keeps the callback after `stop()`, so a test can simulate a late callback.
private final class FakeWatchers: @unchecked Sendable {
    private let lock = NSLock()  // guards all state below
    private var callbacks: [String: @Sendable () -> Void] = [:]
    private var activePaths: Set<String> = []
    private var stoppedPaths: Set<String> = []
    private var creationCounts: [String: Int] = [:]

    private final class Watcher: FolderWatching, @unchecked Sendable {
        let path: String
        weak var owner: FakeWatchers?
        init(path: String, owner: FakeWatchers) { self.path = path; self.owner = owner }
        func start() { owner?.mark(path, active: true) }
        func stop() { owner?.mark(path, active: false) }
    }

    var factory: WatcherFactory {
        { [self] path, onChange in
            lock.lock(); callbacks[path] = onChange; creationCounts[path, default: 0] += 1; lock.unlock()
            return Watcher(path: path, owner: self)
        }
    }

    fileprivate func mark(_ path: String, active: Bool) {
        lock.lock(); defer { lock.unlock() }
        if active { activePaths.insert(path) } else { activePaths.remove(path); stoppedPaths.insert(path) }
    }

    var active: Set<String> { lock.lock(); defer { lock.unlock() }; return activePaths }
    var stopped: Set<String> { lock.lock(); defer { lock.unlock() }; return stoppedPaths }
    var created: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(callbacks.keys) }
    func creations(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return creationCounts[path] ?? 0 }

    /// Calls the latest `onChange` handed out for `path`, from another queue.
    func trigger(_ path: String) {
        lock.lock(); let callback = callbacks[path]; lock.unlock()
        DispatchQueue.global().async { callback?() }
    }
}

/// Honours the `NetworkMonitoring` contract: `onChange` is called for every update, including
/// the first after `start()` (asynchronously). With `withholdsFirstUpdate`, that first delivery
/// waits until the test calls `releaseFirstUpdate()`.
private final class FakeNetwork: NetworkMonitoring, @unchecked Sendable {
    private let lock = NSLock()  // guards all state below
    private var metered: Bool
    private var withholdFirst: Bool
    private var firstUpdatePending = false
    private var callback: (@Sendable () -> Void)?

    init(metered: Bool = false, withholdsFirstUpdate: Bool = false) {
        self.metered = metered
        self.withholdFirst = withholdsFirstUpdate
    }

    var isMetered: Bool {
        get { lock.lock(); defer { lock.unlock() }; return metered }
        set { lock.lock(); metered = newValue; lock.unlock() }
    }

    /// Applies to the next `start()`.
    var withholdsFirstUpdate: Bool {
        get { lock.lock(); defer { lock.unlock() }; return withholdFirst }
        set { lock.lock(); withholdFirst = newValue; lock.unlock() }
    }

    func start(onChange: @escaping @Sendable () -> Void) {
        lock.lock()
        callback = onChange
        firstUpdatePending = withholdFirst
        let deliverNow = !withholdFirst
        lock.unlock()
        if deliverNow { DispatchQueue.global().async { onChange() } }
    }

    func stop() { lock.lock(); callback = nil; firstUpdatePending = false; lock.unlock() }

    /// Delivers the withheld first update after `start()`.
    func releaseFirstUpdate() {
        lock.lock()
        let callback = firstUpdatePending ? callback : nil
        firstUpdatePending = false
        lock.unlock()
        DispatchQueue.global().async { callback?() }
    }

    /// Simulates a network change, delivered from another queue.
    func change() {
        lock.lock(); let callback = callback; lock.unlock()
        DispatchQueue.global().async { callback?() }
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()  // guards both arrays
    private var statusList: [EngineStatus] = []
    private var noticeList: [Notice] = []

    func record(_ status: EngineStatus) { lock.lock(); statusList.append(status); lock.unlock() }
    func record(_ notice: Notice) { lock.lock(); noticeList.append(notice); lock.unlock() }

    var statuses: [EngineStatus] { lock.lock(); defer { lock.unlock() }; return statusList }
    var notices: [Notice] { lock.lock(); defer { lock.unlock() }; return noticeList }
    var latest: EngineStatus? { statuses.last }

    func state(of path: String, _ destinationID: String = "server") -> FolderState? {
        row(of: path, destinationID)?.state
    }

    func row(of path: String, _ destinationID: String = "server") -> FolderStatus? {
        latest?.folders.first { $0.path == path && $0.destinationID == destinationID }
    }
}

/// Polls `condition` until it holds or `timeout` seconds have passed. It returns as soon as the
/// condition holds, so the generous limit only costs time when something is wrong; a short one
/// fails on a slow or busy machine.
private func eventually(
    timeout: TimeInterval = 20, _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Waits long enough for anything that should NOT happen to have had several chances.
private func settle(_ seconds: TimeInterval = 0.4) async {
    try? await Task.sleep(for: .seconds(seconds))
}

// MARK: - Tests

@Suite struct SyncEngineTests {
    static let timing = EngineTiming(quiet: 0.05, maxWait: 0.5, backoff: [0.05, 0.1], noticeCheckInterval: 0.05)
    static let pathA = "/filsynk-test/A"
    static let pathB = "/filsynk-test/B"

    static func config(
        _ folders: [FolderConfig], server: String = "user@server", verifiedServer: String? = nil,
        verifiedHome: String = "/home/user"
    ) -> Config {
        Config(server: server, folders: folders, verifiedServer: verifiedServer ?? server, verifiedHome: verifiedHome)
    }
    static let folderA = FolderConfig(path: pathA, remotePath: "/srv/A")
    static let folderB = FolderConfig(path: pathB, remotePath: "/srv/B")
    static let diskA = Destination.disk(DiskLocation(volumeUUID: "U1", volumeName: "HDD", path: "Filsynk/A"))
    /// Folder A on the server and on a disk.
    static let bothA = FolderConfig(path: pathA, destinations: [.server(path: "/srv/A"), diskA])
    /// The volume of `diskA`.
    static let volumeU1 = VolumeInfo(uuid: "U1", name: "HDD", mountPath: "/filsynk-test/mnt/HDD", format: .exfat, isSystem: false)

    fileprivate struct Harness {
        let engine: SyncEngine
        let runner: FakeRunner
        let watchers: FakeWatchers
        let network: FakeNetwork
        let volumes: FakeVolumes
        let recorder: Recorder
    }

    /// The volume of `diskA` is mounted unless `volumes` says otherwise.
    fileprivate static func make(
        _ config: Config, timing: EngineTiming = timing,
        runner: FakeRunner = FakeRunner(), network: FakeNetwork = FakeNetwork(),
        volumes: FakeVolumes = FakeVolumes([volumeU1]), state: StateStore? = nil
    ) -> Harness {
        let watchers = FakeWatchers()
        let recorder = Recorder()
        let engine = SyncEngine(
            config: config, timing: timing, runner: runner,
            makeWatcher: watchers.factory, network: network,
            volumes: volumes, state: state,
            onStatus: { recorder.record($0) },
            onNotice: { recorder.record($0) })
        return Harness(
            engine: engine, runner: runner, watchers: watchers, network: network, volumes: volumes, recorder: recorder)
    }

    @Test func startSyncsEveryReadyFolderOnce() async {
        let h = Self.make(Self.config([Self.folderA, Self.folderB]))
        await h.engine.start()
        #expect(await eventually {
            let a = await h.runner.callCount(Self.pathA)
            let b = await h.runner.callCount(Self.pathB)
            return a == 1 && b == 1
        })
        await settle()
        #expect(await h.runner.callCount(Self.pathA) == 1)
        #expect(await h.runner.callCount(Self.pathB) == 1)
        #expect(h.recorder.state(of: Self.pathA) == .synced)
        #expect(h.recorder.state(of: Self.pathB) == .synced)
        await h.engine.stop()
    }

    @Test func unreadyFolderIsNeverSyncedAndReportsNotConfigured() async {
        // remotePath "~/Sync": not ready.
        let unready = FolderConfig(path: Self.pathB, remotePath: "~/Sync")
        let h = Self.make(Self.config([Self.folderA, unready]))
        await h.engine.start()
        #expect(await eventually { await h.runner.callCount(Self.pathA) == 1 })
        await settle()
        #expect(await h.runner.callCount(Self.pathB) == 0)
        #expect(h.recorder.state(of: Self.pathB) == .notConfigured)
        #expect(!h.watchers.created.contains(Self.pathB))
        await h.engine.stop()

        // server "": no folder participates.
        let noServer = Self.make(Self.config([Self.folderA], server: ""))
        await noServer.engine.start()
        await settle()
        #expect(await noServer.runner.totalCalls == 0)
        #expect(noServer.recorder.state(of: Self.pathA) == .notConfigured)
        #expect(noServer.watchers.created.isEmpty)
        await noServer.engine.stop()
    }

    @Test func unverifiedServerSyncsNothingAndReportsNotConfigured() async {
        // Folders are absolute ("ready") but were resolved on another server, or never verified.
        for (verified, home) in [("old@server", "/home/user"), ("", "/home/user"), ("user@server", "")] {
            let h = Self.make(Self.config([Self.folderA, Self.folderB], verifiedServer: verified, verifiedHome: home))
            await h.engine.start()
            await settle()
            #expect(await h.runner.totalCalls == 0)
            #expect(h.watchers.created.isEmpty)
            #expect(h.recorder.latest?.folders.map(\.state) == [.notConfigured, .notConfigured])
            await h.engine.stop()
        }
    }

    @Test func invalidConfigSyncsNothing() async {
        let nested = FolderConfig(path: Self.pathA + "/inner", remotePath: "/srv/other")
        let config = Self.config([Self.folderA, nested])
        #expect(!config.validate().isEmpty)
        let h = Self.make(config)
        await h.engine.start()
        await settle()
        #expect(await h.runner.totalCalls == 0)
        #expect(h.watchers.created.isEmpty)
        #expect(h.recorder.latest?.folders.map(\.state) == [.notConfigured, .notConfigured])
        #expect(h.recorder.latest?.configError == nil)
        await h.engine.stop()
    }

    @Test func changeTriggersSyncAfterQuietPeriod() async {
        let h = Self.make(Self.config([Self.folderA]))
        await h.engine.start()
        #expect(await eventually { await h.runner.callCount(Self.pathA) == 1 })
        #expect(await eventually { h.recorder.state(of: Self.pathA) == .synced })

        let triggered = Date()
        h.watchers.trigger(Self.pathA)
        #expect(await eventually { await h.runner.callCount(Self.pathA) == 2 })
        let second = await h.runner.callDates(Self.pathA)[1]
        // Not before the quiet period has passed (small margin for clock rounding).
        #expect(second.timeIntervalSince(triggered) >= Self.timing.quiet - 0.005)
        await h.engine.stop()
    }

    @Test func pausedEngineHoldsChangesAndResumeSyncs() async {
        let h = Self.make(Self.config([Self.folderA]))
        await h.engine.start()
        #expect(await eventually { await h.runner.callCount(Self.pathA) == 1 })

        await h.engine.setPaused(true)
        h.watchers.trigger(Self.pathA)
        #expect(await eventually { h.recorder.state(of: Self.pathA) == .pending })
        await settle()  // far beyond quiet (0.05) and maxWait (0.5 is not reached, but nothing else is due)
        #expect(await h.runner.callCount(Self.pathA) == 1)
        #expect(h.recorder.latest?.isPaused == true)
        #expect(h.recorder.state(of: Self.pathA) == .pending)

        await h.engine.setPaused(false)
        #expect(await eventually { await h.runner.callCount(Self.pathA) == 2 })
        #expect(await eventually { h.recorder.latest?.isPaused == false && h.recorder.state(of: Self.pathA) == .synced })
        await h.engine.stop()
    }

    @Test func meteredNetworkHoldsAutomaticSyncButSyncNowRuns() async {
        let network = FakeNetwork(metered: true)
        let h = Self.make(Self.config([Self.folderA]), network: network)
        await h.engine.start()
        await settle()
        #expect(await h.runner.totalCalls == 0)
        #expect(h.recorder.state(of: Self.pathA) == .pending)

        await h.engine.syncNow()
        #expect(await eventually { await h.runner.callCount(Self.pathA) == 1 })

        h.watchers.trigger(Self.pathA)
        #expect(await eventually { h.recorder.state(of: Self.pathA) == .pending })
        await settle(0.8)  // beyond maxWait (0.5): even the hard deadline is held
        #expect(await h.runner.callCount(Self.pathA) == 1)
        await h.engine.stop()
    }

    @Test func syncNowWhilePausedRunsOnceAndStaysPaused() async {
        let h = Self.make(Self.config([Self.folderA]))
        await h.engine.start()
        #expect(await eventually { await h.runner.callCount(Self.pathA) == 1 })
        await h.engine.setPaused(true)

        await h.engine.syncNow()
        #expect(await eventually { await h.runner.callCount(Self.pathA) == 2 })
        await settle()
        #expect(await h.runner.callCount(Self.pathA) == 2)
        #expect(h.recorder.latest?.isPaused == true)

        // Still paused: a later change is held.
        h.watchers.trigger(Self.pathA)
        #expect(await eventually { h.recorder.state(of: Self.pathA) == .pending })
        await settle()
        #expect(await h.runner.callCount(Self.pathA) == 2)
        await h.engine.stop()
    }

    @Test func neverRunsTwoSyncsOfSameFolderConcurrently() async {
        let runner = FakeRunner(delay: 0.2)
        let h = Self.make(Self.config([Self.folderA, Self.folderB]), runner: runner)
        await h.engine.start()
        #expect(await eventually { await runner.callCount(Self.pathA) == 1 })
        // Pile on requests while the first sync is still running.
        for _ in 0..<5 {
            h.watchers.trigger(Self.pathA)
            await h.engine.syncNow()
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(await eventually { await runner.callCount(Self.pathA) >= 2 })
        // A reload with new sync inputs cancels the running syncs; the restarted ones must wait until they have ended.
        var changed = Self.config([Self.folderA, Self.folderB])
        changed.exclude = ["*.tmp"]
        await h.engine.reload(changed)
        #expect(await eventually { await runner.callCount(Self.pathA) >= 3 })
        await settle()
        #expect(await runner.maxConcurrent[FakeRunner.key(Self.pathA)] == 1)
        #expect(await runner.maxConcurrent[FakeRunner.key(Self.pathB)] == 1)
        // Different folders may run at the same time.
        #expect(await runner.maxTotalConcurrent == 2)
        await h.engine.stop()
    }

    @Test func unreachableRetriesAndNetworkChangeRetriesImmediately() async {
        // Second backoff step is long, so only a network change can explain the third sync.
        let timing = EngineTiming(quiet: 0.05, maxWait: 0.5, backoff: [0.05, 60], noticeCheckInterval: 0.05)
        let runner = FakeRunner()
        await runner.setOutcomes([.unreachable, .unreachable], for: Self.pathA)
        let h = Self.make(Self.config([Self.folderA]), timing: timing, runner: runner)
        await h.engine.start()

        #expect(await eventually { await runner.callCount(Self.pathA) == 2 })  // retried after backoff
        #expect(await eventually { h.recorder.state(of: Self.pathA) == .waitingForServer })
        await settle()
        #expect(await runner.callCount(Self.pathA) == 2)

        h.network.change()
        #expect(await eventually { await runner.callCount(Self.pathA) == 3 })
        #expect(await eventually { h.recorder.state(of: Self.pathA) == .synced })
        await h.engine.stop()
    }

    @Test func statusFollowsSyncingThenSynced() async {
        let runner = FakeRunner(delay: 0.1)
        let h = Self.make(Self.config([Self.folderA]), runner: runner)
        await h.engine.start()
        #expect(await eventually { h.recorder.state(of: Self.pathA) == .synced })

        let states = h.recorder.statuses.compactMap { $0.folders.first { $0.path == Self.pathA } }
        let syncing = states.firstIndex { $0.state == .syncing }
        let synced = states.lastIndex { $0.state == .synced }
        #expect(syncing != nil)
        #expect(synced != nil)
        if let syncing, let synced {
            #expect(syncing < synced)
            #expect(states[syncing].lastSuccess == nil)
            #expect(states[synced].lastSuccess != nil)
        }
        // Published only on change: no two consecutive statuses are equal.
        let all = h.recorder.statuses
        #expect(zip(all, all.dropFirst()).allSatisfy { $0 != $1 })
        await h.engine.stop()
    }

    @Test func thirdFailureEmitsNotice() async {
        let runner = FakeRunner()
        await runner.setOutcomes([.failed("x"), .failed("x"), .failed("x")], for: Self.pathA)
        let h = Self.make(Self.config([Self.folderA]), runner: runner)
        await h.engine.start()

        let expected = Notice.repeatedFailure(
            folder: StatusPresentation.displayPath(Self.pathA, home: NSHomeDirectory()) + " → Server: /srv/A", message: "x")
        #expect(await eventually { h.recorder.notices.contains(expected) })
        #expect(await eventually { await runner.callCount(Self.pathA) == 4 })  // retry after the third failure succeeds
        await settle()  // several periodic notice checks (0.05)
        #expect(h.recorder.notices == [expected])
        await h.engine.stop()
    }

    @Test func reloadReplacesWatchedFolders() async {
        let h = Self.make(Self.config([Self.folderA]))
        await h.engine.start()
        #expect(await eventually { await h.runner.callCount(Self.pathA) == 1 })
        #expect(h.watchers.active == [Self.pathA])

        await h.engine.reload(Self.config([Self.folderB]))
        #expect(h.watchers.stopped.contains(Self.pathA))
        #expect(h.watchers.active == [Self.pathB])
        #expect(await eventually { await h.runner.callCount(Self.pathB) == 1 })  // started again
        #expect(await eventually { h.recorder.latest?.folders.map(\.path) == [Self.pathB] })

        // A late callback from the old watcher is ignored; the new watcher works.
        h.watchers.trigger(Self.pathA)
        h.watchers.trigger(Self.pathB)
        #expect(await eventually { await h.runner.callCount(Self.pathB) == 2 })
        await settle()
        #expect(await h.runner.callCount(Self.pathA) == 1)
        await h.engine.stop()
    }

    @Test func stopCancelsRunningSync() async {
        let runner = FakeRunner(delay: 30)
        let h = Self.make(Self.config([Self.folderA]), runner: runner)
        await h.engine.start()
        #expect(await eventually { await runner.callCount(Self.pathA) == 1 })

        await h.engine.stop()
        #expect(await eventually { await runner.cancelled == [Self.pathA] })
        await settle()
        // The outcome of a cancelled sync is discarded: no error, no notice, no retry.
        #expect(h.recorder.notices.isEmpty)
        #expect(!h.recorder.statuses.contains { $0.folders.contains { if case .error = $0.state { true } else { false } } })
        #expect(h.recorder.state(of: Self.pathA) != .syncing)
        #expect(await runner.callCount(Self.pathA) == 1)
        #expect(h.watchers.active.isEmpty)
    }

    @Test func startupSyncsWaitForFirstNetworkUpdate() async {
        let network = FakeNetwork(withholdsFirstUpdate: true)
        let h = Self.make(Self.config([Self.folderA]), network: network)
        await h.engine.start()
        await settle()
        #expect(await h.runner.totalCalls == 0)  // network state unknown: held as if metered
        #expect(h.recorder.state(of: Self.pathA) == .pending)

        network.releaseFirstUpdate()
        #expect(await eventually { await h.runner.callCount(Self.pathA) == 1 })
        await h.engine.stop()
    }

    @Test func firstNetworkUpdateMeteredKeepsStartupSyncsHeld() async {
        let network = FakeNetwork(metered: true, withholdsFirstUpdate: true)
        let h = Self.make(Self.config([Self.folderA]), network: network)
        await h.engine.start()
        network.releaseFirstUpdate()
        await settle()
        #expect(await h.runner.totalCalls == 0)

        await h.engine.syncNow()
        #expect(await eventually { await h.runner.callCount(Self.pathA) == 1 })
        await h.engine.stop()
    }

    @Test func heldFolderIsReleasedWhenNetworkBecomesUnmetered() async {
        let network = FakeNetwork(metered: true)
        let h = Self.make(Self.config([Self.folderA]), network: network)
        await h.engine.start()
        await settle()
        #expect(await h.runner.totalCalls == 0)

        network.isMetered = false
        network.change()
        #expect(await eventually { await h.runner.callCount(Self.pathA) == 1 })
        await h.engine.stop()
    }

    @Test func restartAfterStopOnMeteredNetworkUsesFreshNetworkState() async {
        let network = FakeNetwork(metered: true)
        let h = Self.make(Self.config([Self.folderA]), network: network)
        await h.engine.start()
        await settle()
        #expect(await h.runner.totalCalls == 0)
        await h.engine.stop()

        // The network became unmetered while stopped; the next start learns it from its first update.
        network.isMetered = false
        network.withholdsFirstUpdate = true
        await h.engine.start()
        await settle()
        #expect(await h.runner.totalCalls == 0)
        network.releaseFirstUpdate()
        #expect(await eventually { await h.runner.callCount(Self.pathA) == 1 })
        await h.engine.stop()
    }

    // MARK: Reload keeps unchanged folders

    @Test func reloadWithNewExcludesKeepsLastSuccessAndDirtySince() async {
        let h = Self.make(Self.config([Self.folderA, Self.folderB]))
        await h.engine.start()
        #expect(await eventually { h.recorder.state(of: Self.pathA) == .synced && h.recorder.state(of: Self.pathB) == .synced })
        let lastSuccess = await h.engine.schedule(of: Self.pathA)?.lastSuccess
        #expect(lastSuccess != nil)

        await h.engine.setPaused(true)
        h.watchers.trigger(Self.pathA)
        #expect(await eventually { h.recorder.state(of: Self.pathA) == .pending })
        let dirtySince = await h.engine.schedule(of: Self.pathA)?.dirtySince
        #expect(dirtySince != nil)

        var changed = Self.config([Self.folderA, Self.folderB])
        changed.exclude = ["node_modules"]
        await h.engine.reload(changed)
        let after = await h.engine.schedule(of: Self.pathA)
        #expect(after?.lastSuccess == lastSuccess)
        #expect(after?.dirtySince == dirtySince)
        #expect(h.recorder.latest?.folders.first { $0.path == Self.pathA }?.lastSuccess == lastSuccess)
        await h.engine.stop()
    }

    @Test func reloadWithChangedRemotePathStartsAFreshSchedule() async {
        let h = Self.make(Self.config([Self.folderA, Self.folderB]))
        await h.engine.start()
        #expect(await eventually { h.recorder.state(of: Self.pathA) == .synced })
        await h.engine.setPaused(true)

        let moved = FolderConfig(path: Self.pathA, remotePath: "/srv/A2")
        await h.engine.reload(Self.config([moved, Self.folderB]))
        #expect(await h.engine.schedule(of: Self.pathA)?.lastSuccess == nil)
        #expect(await h.engine.schedule(of: Self.pathB)?.lastSuccess != nil)

        // A changed server gives every folder a fresh schedule.
        await h.engine.reload(Self.config([moved, Self.folderB], server: "other@server"))
        #expect(await h.engine.schedule(of: Self.pathB)?.lastSuccess == nil)
        await h.engine.stop()
    }

    @Test func reloadWithSameSyncInputsLetsRunningSyncFinish() async {
        let runner = FakeRunner(delay: 0.3)
        let h = Self.make(Self.config([Self.folderA]), runner: runner)
        await h.engine.start()
        #expect(await eventually { await runner.callCount(Self.pathA) == 1 })

        var changed = Self.config([Self.folderA])
        changed.quietSeconds = 30  // not a sync input
        await h.engine.reload(changed)
        // The running sync is not cancelled; the restart's request runs after it, never beside it.
        #expect(await eventually { await runner.callCount(Self.pathA) == 2 })
        #expect(await eventually { h.recorder.state(of: Self.pathA) == .synced })
        await settle()
        #expect(await runner.cancelled.isEmpty)
        #expect(await runner.maxConcurrent[FakeRunner.key(Self.pathA)] == 1)
        #expect(await runner.callCount(Self.pathA) == 2)
        #expect(await h.engine.schedule(of: Self.pathA)?.lastSuccess != nil)
        await h.engine.stop()
    }

    @Test func reloadWithNewSyncInputsCancelsButKeepsSchedule() async {
        let runner = FakeRunner(delay: 0.3)
        let h = Self.make(Self.config([Self.folderA]), runner: runner)
        await h.engine.start()
        #expect(await eventually { await runner.callCount(Self.pathA) == 1 })

        var changed = Self.config([Self.folderA])
        changed.exclude = ["*.tmp"]
        await h.engine.reload(changed)
        #expect(await eventually { await runner.cancelled == [Self.pathA] })
        #expect(await eventually { await runner.callCount(Self.pathA) == 2 })
        #expect(await eventually { h.recorder.state(of: Self.pathA) == .synced })
        await settle()
        #expect(await runner.maxConcurrent[FakeRunner.key(Self.pathA)] == 1)
        #expect(await runner.callCount(Self.pathA) == 2)
        #expect(h.recorder.notices.isEmpty)
        await h.engine.stop()
    }

    // MARK: Denied login

    @Test func deniedLoginIsNotRetriedOnNetworkChangeButSyncNowRuns() async {
        // Last backoff step is long: only an explicit request can explain another sync.
        let timing = EngineTiming(quiet: 0.05, maxWait: 0.5, backoff: [0.05, 60], noticeCheckInterval: 0.05)
        let runner = FakeRunner()
        await runner.setOutcomes([.authDenied], for: Self.pathA)
        let h = Self.make(Self.config([Self.folderA]), timing: timing, runner: runner)
        await h.engine.start()
        #expect(await eventually { await runner.callCount(Self.pathA) == 1 })
        #expect(await eventually { h.recorder.state(of: Self.pathA) == .error("Inloggningen nekades") })

        await settle()  // far beyond the first backoff step (0.05)
        #expect(await runner.callCount(Self.pathA) == 1)
        h.network.change()
        await settle()
        #expect(await runner.callCount(Self.pathA) == 1)

        await h.engine.syncNow()
        #expect(await eventually { await runner.callCount(Self.pathA) == 2 })
        await h.engine.stop()
    }

    @Test func deniedLoginIsRetriedOnResumeAndReload() async {
        let timing = EngineTiming(quiet: 0.05, maxWait: 0.5, backoff: [0.05, 60], noticeCheckInterval: 0.05)
        let runner = FakeRunner()
        await runner.setOutcomes([.authDenied, .authDenied], for: Self.pathA)
        let h = Self.make(Self.config([Self.folderA]), timing: timing, runner: runner)
        await h.engine.start()
        #expect(await eventually { await runner.callCount(Self.pathA) == 1 })
        #expect(await eventually { h.recorder.state(of: Self.pathA) == .error("Inloggningen nekades") })

        await h.engine.setPaused(true)
        await h.engine.setPaused(false)
        #expect(await eventually { await runner.callCount(Self.pathA) == 2 })
        #expect(await eventually { h.recorder.state(of: Self.pathA) == .error("Inloggningen nekades") })

        await h.engine.reload(Self.config([Self.folderA]))
        #expect(await eventually { await runner.callCount(Self.pathA) == 3 })
        await h.engine.stop()
    }
    // MARK: One schedule per destination

    @Test func oneRowPerDestination() async {
        let h = Self.make(Self.config([Self.bothA, Self.folderB]))
        let rows = h.recorder.latest?.folders ?? []
        #expect(rows.map(\.path) == [Self.pathA, Self.pathA, Self.pathB])
        #expect(rows.map(\.destination) == [.server(path: "/srv/A"), Self.diskA, .server(path: "/srv/B")])
        #expect(Set(rows.map(\.id)).count == 3)
    }

    @Test func folderWithoutDestinationHasOneUnconfiguredRow() async {
        let bare = FolderConfig(path: Self.pathB, destinations: [])
        let h = Self.make(Self.config([Self.folderA, bare]))
        let rows = h.recorder.latest?.folders ?? []
        #expect(rows.map(\.path) == [Self.pathA, Self.pathB])
        #expect(rows.last?.destination == nil)
        #expect(rows.map(\.state) == [.notConfigured, .notConfigured])
    }

    @Test func changeMakesAllDestinationsOfTheFolderSync() async {
        let h = Self.make(Self.config([Self.bothA]))
        await h.engine.start()
        #expect(await eventually {
            let server = await h.runner.callCount(Self.pathA, "server")
            let disk = await h.runner.callCount(Self.pathA, Self.diskA.id)
            return server == 1 && disk == 1
        })
        #expect(h.watchers.created == [Self.pathA])

        h.watchers.trigger(Self.pathA)
        #expect(await eventually {
            let server = await h.runner.callCount(Self.pathA, "server")
            let disk = await h.runner.callCount(Self.pathA, Self.diskA.id)
            return server == 2 && disk == 2
        })
        #expect(await eventually {
            h.recorder.state(of: Self.pathA) == .synced && h.recorder.state(of: Self.pathA, Self.diskA.id) == .synced
        })
        await h.engine.stop()
    }

    @Test func destinationsOfOneFolderMayRunConcurrently() async {
        let runner = FakeRunner(delay: 0.3)
        let h = Self.make(Self.config([Self.bothA]), runner: runner)
        await h.engine.start()
        #expect(await eventually { await runner.currentTotal == 2 })
        #expect(await eventually {
            h.recorder.state(of: Self.pathA) == .syncing && h.recorder.state(of: Self.pathA, Self.diskA.id) == .syncing
        })
        await h.engine.stop()
    }

    @Test func neverTwoSyncsOfTheSameDestination() async {
        let runner = FakeRunner(delay: 0.2)
        let h = Self.make(Self.config([Self.bothA]), runner: runner)
        await h.engine.start()
        #expect(await eventually { await runner.totalCalls == 2 })
        for _ in 0..<5 {
            h.watchers.trigger(Self.pathA)
            await h.engine.syncNow()
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(await eventually {
            let server = await runner.callCount(Self.pathA, "server")
            let disk = await runner.callCount(Self.pathA, Self.diskA.id)
            return server >= 2 && disk >= 2
        })
        // Cancelled syncs must have ended before the same destination runs again.
        var changed = Self.config([Self.bothA])
        changed.exclude = ["*.tmp"]
        await h.engine.reload(changed)
        #expect(await eventually {
            let server = await runner.callCount(Self.pathA, "server")
            let disk = await runner.callCount(Self.pathA, Self.diskA.id)
            return server >= 3 && disk >= 3
        })
        await settle()
        #expect(await runner.maxConcurrent[FakeRunner.key(Self.pathA)] == 1)
        #expect(await runner.maxConcurrent[FakeRunner.key(Self.pathA, Self.diskA.id)] == 1)
        #expect(await runner.maxTotalConcurrent == 2)
        await h.engine.stop()
    }

    @Test func diskDestinationSyncsWithoutVerifiedServer() async {
        let diskOnly = FolderConfig(path: Self.pathB, destinations: [
            .disk(DiskLocation(volumeUUID: "U1", volumeName: "HDD", path: "Filsynk/B")),
        ])
        let config = Self.config([Self.bothA, diskOnly], server: "", verifiedServer: "", verifiedHome: "")
        #expect(config.validate().isEmpty)
        let network = FakeNetwork(withholdsFirstUpdate: true)  // network state unknown
        let h = Self.make(config, network: network)
        await h.engine.start()
        #expect(await eventually {
            let a = await h.runner.callCount(Self.pathA, Self.diskA.id)
            let b = await h.runner.callCount(Self.pathB)
            return a == 1 && b == 1
        })
        await settle()
        #expect(await h.runner.callCount(Self.pathA, "server") == 0)
        #expect(h.recorder.state(of: Self.pathA) == .notConfigured)
        #expect(h.recorder.state(of: Self.pathA, Self.diskA.id) == .synced)
        #expect(h.watchers.created == [Self.pathA, Self.pathB])
        await h.engine.stop()
    }

    @Test func meteredNetworkHoldsOnlyServerDestinations() async {
        let network = FakeNetwork(metered: true)
        let h = Self.make(Self.config([Self.bothA]), network: network)
        await h.engine.start()
        #expect(await eventually { await h.runner.callCount(Self.pathA, Self.diskA.id) == 1 })
        h.watchers.trigger(Self.pathA)
        #expect(await eventually { await h.runner.callCount(Self.pathA, Self.diskA.id) == 2 })
        await settle()
        #expect(await h.runner.callCount(Self.pathA, "server") == 0)
        #expect(h.recorder.state(of: Self.pathA) == .pending)
        #expect(h.recorder.state(of: Self.pathA, Self.diskA.id) == .synced)

        await h.engine.syncNow()
        #expect(await eventually { await h.runner.callCount(Self.pathA, "server") == 1 })
        await h.engine.stop()
    }

    @Test func failureOfOneDestinationDoesNotAffectTheOther() async {
        // Second backoff step is long, so the server stays waiting.
        let timing = EngineTiming(quiet: 0.05, maxWait: 0.5, backoff: [0.05, 60], noticeCheckInterval: 0.05)
        let runner = FakeRunner()
        await runner.setOutcomes([.unreachable, .unreachable], for: Self.pathA, destinationID: "server")
        let h = Self.make(Self.config([Self.bothA]), timing: timing, runner: runner)
        await h.engine.start()
        #expect(await eventually { await runner.callCount(Self.pathA, "server") == 2 })
        #expect(await eventually {
            h.recorder.state(of: Self.pathA) == .waitingForServer
                && h.recorder.state(of: Self.pathA, Self.diskA.id) == .synced
        })
        await settle()
        #expect(await runner.callCount(Self.pathA, Self.diskA.id) == 1)
        #expect(await h.engine.schedule(of: Self.pathA, destinationID: Self.diskA.id)?.failureCount == 0)
        #expect(await h.engine.schedule(of: Self.pathA)?.failureCount == 2)
        await h.engine.stop()
    }

    @Test func reloadKeepsScheduleOfUnchangedDestinationOnly() async {
        let h = Self.make(Self.config([Self.bothA]))
        await h.engine.start()
        #expect(await eventually {
            h.recorder.state(of: Self.pathA) == .synced && h.recorder.state(of: Self.pathA, Self.diskA.id) == .synced
        })
        await h.engine.setPaused(true)
        let serverSuccess = await h.engine.schedule(of: Self.pathA)?.lastSuccess
        let diskSuccess = await h.engine.schedule(of: Self.pathA, destinationID: Self.diskA.id)?.lastSuccess
        #expect(serverSuccess != nil)
        #expect(diskSuccess != nil)

        // Another folder on the disk: the server destination keeps its schedule.
        let movedDisk = Destination.disk(DiskLocation(volumeUUID: "U1", volumeName: "HDD", path: "Filsynk/A2"))
        await h.engine.reload(Self.config([FolderConfig(path: Self.pathA, destinations: [.server(path: "/srv/A"), movedDisk])]))
        #expect(await h.engine.schedule(of: Self.pathA)?.lastSuccess == serverSuccess)
        #expect(await h.engine.schedule(of: Self.pathA, destinationID: movedDisk.id)?.lastSuccess == nil)

        // Back to the first disk folder, then another server: only the disk destination keeps its schedule.
        await h.engine.reload(Self.config([Self.bothA]))
        await h.engine.setPaused(false)
        #expect(await eventually {
            h.recorder.state(of: Self.pathA) == .synced && h.recorder.state(of: Self.pathA, Self.diskA.id) == .synced
        })
        await h.engine.setPaused(true)
        let diskAgain = await h.engine.schedule(of: Self.pathA, destinationID: Self.diskA.id)?.lastSuccess
        #expect(diskAgain != nil)
        await h.engine.reload(Self.config([Self.bothA], server: "other@server"))
        #expect(await h.engine.schedule(of: Self.pathA)?.lastSuccess == nil)
        #expect(await h.engine.schedule(of: Self.pathA, destinationID: Self.diskA.id)?.lastSuccess == diskAgain)

        // A new server path for the folder: likewise.
        await h.engine.reload(Self.config([FolderConfig(path: Self.pathA, destinations: [.server(path: "/srv/A3"), Self.diskA])],
                                          server: "other@server"))
        #expect(await h.engine.schedule(of: Self.pathA, destinationID: Self.diskA.id)?.lastSuccess == diskAgain)
        await h.engine.stop()
    }

    @Test func noticeNamesTheDestination() async {
        let runner = FakeRunner()
        await runner.setOutcomes([.failed("x"), .failed("x"), .failed("x")], for: Self.pathA, destinationID: Self.diskA.id)
        let h = Self.make(Self.config([Self.bothA]), runner: runner)
        await h.engine.start()
        let expected = Notice.repeatedFailure(
            folder: StatusPresentation.displayPath(Self.pathA, home: NSHomeDirectory()) + " → HDD: Filsynk/A", message: "x")
        #expect(await eventually { h.recorder.notices.contains(expected) })
        await settle()
        #expect(h.recorder.notices == [expected])
        await h.engine.stop()
    }
    // MARK: Volumes

    /// Long quiet period and backoff: only an explicit request explains a sync.
    static let slow = EngineTiming(quiet: 30, maxWait: 60, backoff: [60], noticeCheckInterval: 0.05)
    static let diskOnlyA = FolderConfig(path: pathA, destinations: [diskA])
    static func diskOnly(_ folders: [FolderConfig]) -> Config {
        Config(server: "", folders: folders)
    }

    @Test func startsWithDiskAbsentAndReportsNotConnected() async {
        let h = Self.make(Self.config([Self.bothA]), volumes: FakeVolumes())
        await h.engine.start()
        #expect(await eventually { await h.runner.callCount(Self.pathA, "server") == 1 })
        #expect(await eventually { h.recorder.state(of: Self.pathA, Self.diskA.id) == .notConnected })
        await settle()
        #expect(await h.runner.callCount(Self.pathA, Self.diskA.id) == 0)
        #expect(h.recorder.state(of: Self.pathA, Self.diskA.id) == .notConnected)
        #expect(h.recorder.notices.isEmpty)
        #expect(h.volumes.isStarted)
        await h.engine.stop()
        #expect(!h.volumes.isStarted)
    }

    @Test func mountingTheChosenVolumeSyncsAtOnce() async {
        let h = Self.make(Self.config([Self.bothA]), timing: Self.slow)
        await h.engine.start()
        #expect(await eventually {
            h.recorder.state(of: Self.pathA) == .synced && h.recorder.state(of: Self.pathA, Self.diskA.id) == .synced
        })
        h.volumes.willUnmount(Self.volumeU1)
        h.volumes.unmount(path: Self.volumeU1.mountPath)
        #expect(await eventually { h.recorder.state(of: Self.pathA, Self.diskA.id) == .notConnected })
        #expect(await h.engine.schedule(of: Self.pathA, destinationID: Self.diskA.id)?.isDirty == false)

        // Nothing has changed, yet the disk is synced as soon as it is back.
        h.volumes.mount(Self.volumeU1)
        #expect(await eventually { await h.runner.callCount(Self.pathA, Self.diskA.id) == 2 })
        #expect(await eventually { h.recorder.state(of: Self.pathA, Self.diskA.id) == .synced })
        await settle()
        #expect(await h.runner.callCount(Self.pathA, "server") == 1)
        #expect(await h.runner.callCount(Self.pathA, Self.diskA.id) == 2)
        await h.engine.stop()
    }

    @Test func mountingAnotherVolumeDoesNothing() async {
        let other = VolumeInfo(uuid: "U2", name: "HDD", mountPath: "/filsynk-test/mnt/HDD 1", format: .exfat, isSystem: false)

        // The disk is absent: a disk with the same name is not it.
        let absent = Self.make(Self.config([Self.bothA]), timing: Self.slow, volumes: FakeVolumes())
        await absent.engine.start()
        #expect(await eventually { absent.recorder.state(of: Self.pathA) == .synced })
        absent.volumes.mount(other)
        await settle()
        #expect(await absent.runner.callCount(Self.pathA, Self.diskA.id) == 0)
        #expect(await absent.runner.callCount(Self.pathA, "server") == 1)
        #expect(absent.recorder.state(of: Self.pathA, Self.diskA.id) == .notConnected)
        // Not even an explicit request starts it.
        await absent.engine.syncNow()
        #expect(await eventually { await absent.runner.callCount(Self.pathA, "server") == 2 })
        await settle()
        #expect(await absent.runner.callCount(Self.pathA, Self.diskA.id) == 0)
        #expect(absent.recorder.state(of: Self.pathA, Self.diskA.id) == .notConnected)
        await absent.engine.stop()

        // The disk is present: another disk being mounted starts nothing.
        let present = Self.make(Self.config([Self.bothA]), timing: Self.slow)
        await present.engine.start()
        #expect(await eventually { present.recorder.state(of: Self.pathA, Self.diskA.id) == .synced })
        present.volumes.mount(other)
        await settle()
        #expect(await present.runner.callCount(Self.pathA, Self.diskA.id) == 1)
        #expect(await present.runner.callCount(Self.pathA, "server") == 1)
        #expect(present.recorder.state(of: Self.pathA, Self.diskA.id) == .synced)
        await present.engine.stop()
    }

    @Test func changesWhileAbsentAreSyncedOnMount() async {
        let h = Self.make(Self.config([Self.bothA]))
        await h.engine.start()
        #expect(await eventually {
            h.recorder.state(of: Self.pathA) == .synced && h.recorder.state(of: Self.pathA, Self.diskA.id) == .synced
        })
        h.volumes.willUnmount(Self.volumeU1)
        h.volumes.unmount(path: Self.volumeU1.mountPath)
        #expect(await eventually { h.recorder.state(of: Self.pathA, Self.diskA.id) == .notConnected })

        h.watchers.trigger(Self.pathA)
        #expect(await eventually { await h.runner.callCount(Self.pathA, "server") == 2 })
        await settle(0.8)  // beyond maxWait (0.5)
        #expect(await h.runner.callCount(Self.pathA, Self.diskA.id) == 1)
        #expect(await h.engine.schedule(of: Self.pathA, destinationID: Self.diskA.id)?.isDirty == true)
        #expect(h.recorder.state(of: Self.pathA, Self.diskA.id) == .notConnected)

        h.volumes.mount(Self.volumeU1)
        #expect(await eventually { await h.runner.callCount(Self.pathA, Self.diskA.id) == 2 })
        #expect(await eventually { h.recorder.state(of: Self.pathA, Self.diskA.id) == .synced })
        await h.engine.stop()
    }

    @Test func willUnmountCancelsRunningDiskSync() async {
        let runner = FakeRunner(delay: 30)
        let h = Self.make(Self.diskOnly([Self.diskOnlyA]), runner: runner)
        await h.engine.start()
        #expect(await eventually { await runner.callCount(Self.pathA, Self.diskA.id) == 1 })
        #expect(await eventually { h.recorder.state(of: Self.pathA, Self.diskA.id) == .syncing })

        h.volumes.willUnmount(Self.volumeU1)
        #expect(await eventually { await runner.cancelledKeys == [FakeRunner.key(Self.pathA, Self.diskA.id)] })
        h.volumes.unmount(path: Self.volumeU1.mountPath)
        #expect(await eventually { h.recorder.state(of: Self.pathA, Self.diskA.id) == .notConnected })
        await settle()
        // The cancelled sync is discarded: no error, no notice, no retry; the change is still owed.
        #expect(h.recorder.notices.isEmpty)
        #expect(!h.recorder.statuses.contains { $0.folders.contains { if case .error = $0.state { true } else { false } } })
        #expect(await runner.callCount(Self.pathA, Self.diskA.id) == 1)
        #expect(await h.engine.schedule(of: Self.pathA, destinationID: Self.diskA.id)?.isDirty == true)
        #expect(await h.engine.schedule(of: Self.pathA, destinationID: Self.diskA.id)?.failureCount == 0)
        await h.engine.stop()
    }

    @Test func syncNowLeavesAbsentDiskAlone() async {
        let h = Self.make(Self.config([Self.bothA]), timing: Self.slow, volumes: FakeVolumes())
        await h.engine.start()
        #expect(await eventually { await h.runner.callCount(Self.pathA, "server") == 1 })
        await h.engine.setPaused(true)
        await h.engine.syncNow()
        #expect(await eventually { await h.runner.callCount(Self.pathA, "server") == 2 })
        await settle()
        #expect(await h.runner.callCount(Self.pathA, Self.diskA.id) == 0)
        #expect(h.recorder.state(of: Self.pathA, Self.diskA.id) == .notConnected)

        // Resuming does not start it either.
        await h.engine.setPaused(false)
        #expect(await eventually { await h.runner.callCount(Self.pathA, "server") == 3 })
        await settle()
        #expect(await h.runner.callCount(Self.pathA, Self.diskA.id) == 0)
        await h.engine.stop()
    }

    @Test func absentDiskDoesNotChangeOverallState() async {
        let h = Self.make(Self.config([Self.bothA]), volumes: FakeVolumes())
        await h.engine.start()
        #expect(await eventually { h.recorder.state(of: Self.pathA) == .synced })
        #expect(h.recorder.state(of: Self.pathA, Self.diskA.id) == .notConnected)
        #expect(h.recorder.latest?.overall == .synced)
        await h.engine.stop()
    }

    @Test func onlyAbsentDisksGiveOverallNotConnected() async {
        let h = Self.make(Self.diskOnly([Self.diskOnlyA]), volumes: FakeVolumes())
        await h.engine.start()
        await settle()
        #expect(await h.runner.totalCalls == 0)
        #expect(h.recorder.latest?.overall == .notConnected)

        h.volumes.mount(Self.volumeU1)
        #expect(await eventually { h.recorder.latest?.overall == .synced })
        await h.engine.stop()
    }

    @Test func folderOnMissingSourceVolumeHoldsAllItsDestinations() async {
        let source = VolumeInfo(uuid: "S1", name: "Data", mountPath: "/filsynk-test", format: .apfs, isSystem: false)
        var onData = Self.bothA
        onData.sourceVolumeUUID = "S1"
        let h = Self.make(Self.config([onData, Self.folderB]))
        await h.engine.start()
        #expect(await eventually { await h.runner.callCount(Self.pathB) == 1 })
        #expect(await eventually {
            h.recorder.state(of: Self.pathA) == .notConnected && h.recorder.state(of: Self.pathA, Self.diskA.id) == .notConnected
        })
        await h.engine.syncNow()
        await settle()
        #expect(await h.runner.callCount(Self.pathA) == 0)

        h.volumes.mount(source)
        #expect(await eventually {
            let server = await h.runner.callCount(Self.pathA, "server")
            let disk = await h.runner.callCount(Self.pathA, Self.diskA.id)
            return server == 1 && disk == 1
        })
        #expect(await eventually {
            h.recorder.state(of: Self.pathA) == .synced && h.recorder.state(of: Self.pathA, Self.diskA.id) == .synced
        })
        await h.engine.stop()
    }

    @Test func duplicateVolumesShowAnErrorRow() async {
        var twin = Self.volumeU1
        twin.mountPath = "/filsynk-test/mnt/HDD 1"
        let h = Self.make(Self.config([Self.bothA]), volumes: FakeVolumes([Self.volumeU1, twin]))
        await h.engine.start()
        #expect(await eventually { h.recorder.state(of: Self.pathA) == .synced })
        await h.engine.syncNow()
        await settle()
        #expect(await h.runner.callCount(Self.pathA, Self.diskA.id) == 0)
        #expect(h.recorder.state(of: Self.pathA, Self.diskA.id) == .error("Två inkopplade diskar har samma id."))
        #expect(h.recorder.notices.isEmpty)
        await h.engine.stop()
    }

    @Test func lastSuccessIsRestoredAfterRestart() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("filsynk-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))

        let first = Self.make(Self.config([Self.bothA]), state: store)
        await first.engine.start()
        #expect(await eventually {
            first.recorder.state(of: Self.pathA) == .synced && first.recorder.state(of: Self.pathA, Self.diskA.id) == .synced
        })
        await first.engine.stop()
        let disk = try #require(await first.engine.schedule(of: Self.pathA, destinationID: Self.diskA.id)?.lastSuccess)
        let server = try #require(await first.engine.schedule(of: Self.pathA)?.lastSuccess)

        // A new engine with the disk absent shows the dates before anything has synced.
        let second = Self.make(Self.config([Self.bothA]), volumes: FakeVolumes(), state: store)
        let row = try #require(second.recorder.row(of: Self.pathA, Self.diskA.id))
        #expect(abs((row.lastSuccess ?? .distantPast).timeIntervalSince(disk)) < 0.01)
        let serverRow = try #require(second.recorder.row(of: Self.pathA))
        #expect(abs((serverRow.lastSuccess ?? .distantPast).timeIntervalSince(server)) < 0.01)
        await second.engine.start()
        #expect(await eventually { second.recorder.state(of: Self.pathA, Self.diskA.id) == .notConnected })
        #expect(second.recorder.row(of: Self.pathA, Self.diskA.id)?.lastSuccess == row.lastSuccess)
        await second.engine.stop()

        // A destination that is gone is dropped at the next save.
        let third = Self.make(Self.config([Self.folderA]), state: store)
        await third.engine.start()
        #expect(await eventually { third.recorder.state(of: Self.pathA) == .synced })
        await third.engine.stop()
        #expect(await eventually { store.load().keys.sorted() == [FakeRunner.key(Self.pathA)] })
    }

    @Test func networkChangeLeavesDirtyDiskDestinationAlone() async {
        let timing = EngineTiming(quiet: 0.05, maxWait: 0.5, backoff: [60], noticeCheckInterval: 0.05)
        let runner = FakeRunner()
        await runner.setOutcomes([.failed("x")], for: Self.pathA, destinationID: Self.diskA.id)
        let h = Self.make(Self.config([Self.bothA]), timing: timing, runner: runner)
        await h.engine.start()
        #expect(await eventually { h.recorder.state(of: Self.pathA, Self.diskA.id) == .error("x") })
        #expect(await h.engine.schedule(of: Self.pathA, destinationID: Self.diskA.id)?.isDirty == true)

        h.network.change()
        await settle()
        #expect(await runner.callCount(Self.pathA, Self.diskA.id) == 1)
        await h.engine.stop()
    }

    @Test func runningDiskSyncSurvivesServerChangeOnReload() async {
        let runner = FakeRunner(delay: 0.3)
        let h = Self.make(Self.config([Self.bothA]), runner: runner)
        await h.engine.start()
        #expect(await eventually { await runner.currentTotal == 2 })

        await h.engine.reload(Self.config([Self.bothA], server: "other@server"))
        #expect(await eventually { await runner.cancelledKeys == [FakeRunner.key(Self.pathA)] })
        #expect(await eventually { h.recorder.state(of: Self.pathA, Self.diskA.id) == .synced })
        #expect(await h.engine.schedule(of: Self.pathA, destinationID: Self.diskA.id)?.lastSuccess != nil)
        #expect(await eventually { h.recorder.state(of: Self.pathA) == .synced })
        await settle()
        #expect(await runner.cancelledKeys == [FakeRunner.key(Self.pathA)])
        #expect(await runner.maxConcurrent[FakeRunner.key(Self.pathA, Self.diskA.id)] == 1)
        #expect(h.recorder.notices.isEmpty)
        await h.engine.stop()
    }
    // MARK: Ejecting

    @Test func unmountGraceIsAMinuteByDefault() {
        #expect(EngineTiming(config: Config(server: "", folders: [])).unmountGrace == 60)
    }

    static func ejecting(grace: TimeInterval) -> EngineTiming {
        EngineTiming(quiet: 30, maxWait: 60, backoff: [60], noticeCheckInterval: 0.05, unmountGrace: grace)
    }

    @Test func refusedEjectSyncsTheDiskAgainAfterTheGrace() async {
        let runner = FakeRunner(delay: 30)
        let h = Self.make(Self.diskOnly([Self.diskOnlyA]), timing: Self.ejecting(grace: 0.5), runner: runner)
        await h.engine.start()
        #expect(await eventually { await runner.callCount(Self.pathA, Self.diskA.id) == 1 })
        await runner.setDelay(0)

        // The eject is refused: the disk stays mounted and no further event comes.
        h.volumes.willUnmount(Self.volumeU1)
        #expect(await eventually { await runner.cancelledKeys == [FakeRunner.key(Self.pathA, Self.diskA.id)] })
        #expect(await eventually { h.recorder.state(of: Self.pathA, Self.diskA.id) == .notConnected })
        #expect(await runner.callCount(Self.pathA, Self.diskA.id) == 1)

        #expect(await eventually { await runner.callCount(Self.pathA, Self.diskA.id) == 2 })
        #expect(await eventually { h.recorder.state(of: Self.pathA, Self.diskA.id) == .synced })
        await h.engine.stop()
    }

    @Test func mountWhileEjectingStartsNothingOnTheLeavingDisk() async {
        let runner = FakeRunner(delay: 30)
        let h = Self.make(Self.diskOnly([Self.diskOnlyA]), timing: Self.ejecting(grace: 60), runner: runner)
        await h.engine.start()
        #expect(await eventually { await runner.callCount(Self.pathA, Self.diskA.id) == 1 })
        await runner.setDelay(0)

        h.volumes.willUnmount(Self.volumeU1)
        #expect(await eventually { await runner.cancelledKeys.count == 1 })
        // Another disk is mounted before the first one is gone; the list still holds the leaving one.
        h.volumes.mount(VolumeInfo(uuid: "U2", name: "Other", mountPath: "/filsynk-test/mnt/Other", format: .apfs, isSystem: false))
        await settle()
        #expect(await runner.callCount(Self.pathA, Self.diskA.id) == 1)
        #expect(h.recorder.state(of: Self.pathA, Self.diskA.id) == .notConnected)
        await h.engine.stop()
    }

    @Test func normalEjectStaysNotConnectedAfterTheGrace() async {
        let runner = FakeRunner(delay: 30)
        let h = Self.make(Self.diskOnly([Self.diskOnlyA]), timing: Self.ejecting(grace: 0.1), runner: runner)
        await h.engine.start()
        #expect(await eventually { await runner.callCount(Self.pathA, Self.diskA.id) == 1 })
        await runner.setDelay(0)

        // The cancelled sync is owed at once; only the missing disk holds it back.
        h.volumes.willUnmount(Self.volumeU1)
        #expect(await eventually { await runner.cancelledKeys.count == 1 })
        h.volumes.unmount(path: Self.volumeU1.mountPath)
        #expect(await eventually { h.recorder.state(of: Self.pathA, Self.diskA.id) == .notConnected })
        await settle(0.6)  // several times the grace
        #expect(await runner.callCount(Self.pathA, Self.diskA.id) == 1)
        #expect(h.recorder.state(of: Self.pathA, Self.diskA.id) == .notConnected)
        await h.engine.stop()
    }

    @Test func volumeMountedWhileStartingIsSeen() async {
        let volumes = FakeVolumes()
        volumes.mountsWhileStarting = [Self.volumeU1]
        let h = Self.make(Self.diskOnly([Self.diskOnlyA]), volumes: volumes)
        await h.engine.start()
        #expect(await eventually { await h.runner.callCount(Self.pathA, Self.diskA.id) == 1 })
        #expect(await eventually { h.recorder.state(of: Self.pathA, Self.diskA.id) == .synced })
        await h.engine.stop()
    }

    @Test func recordingTheSourceVolumeKeepsLastSuccess() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("filsynk-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        let h = Self.make(Self.config([Self.bothA, Self.folderB]), state: store)
        await h.engine.start()
        #expect(await eventually {
            h.recorder.state(of: Self.pathA) == .synced && h.recorder.state(of: Self.pathA, Self.diskA.id) == .synced
                && h.recorder.state(of: Self.pathB) == .synced
        })
        let server = try #require(h.recorder.row(of: Self.pathA)?.lastSuccess)
        let disk = try #require(h.recorder.row(of: Self.pathA, Self.diskA.id)?.lastSuccess)

        // The folder's volume is recorded; that volume is not mounted, so the folder waits.
        var recorded = Self.bothA
        recorded.sourceVolumeUUID = "S1"
        await h.engine.reload(Self.config([recorded, Self.folderB]))
        #expect(await eventually { h.recorder.state(of: Self.pathA) == .notConnected })
        #expect(h.recorder.row(of: Self.pathA)?.lastSuccess == server)
        #expect(h.recorder.row(of: Self.pathA, Self.diskA.id)?.lastSuccess == disk)

        // The next save keeps them (the restart syncs B once more, then the explicit request).
        #expect(await eventually { await h.runner.callCount(Self.pathB) == 2 })
        await h.engine.syncNow()
        #expect(await eventually { await h.runner.callCount(Self.pathB) == 3 })
        let keyA = FakeRunner.key(Self.pathA), keyDisk = FakeRunner.key(Self.pathA, Self.diskA.id)
        #expect(await eventually { store.load().keys.sorted() == [keyA, keyDisk, FakeRunner.key(Self.pathB)].sorted() })
        await h.engine.stop()
    }

    @Test func folderOnAnotherDiskThanItsRecordedVolumeIsHeld() async {
        // Two disks named Data; the folder's path points into the one that is not its own.
        let own = VolumeInfo(uuid: "S1", name: "Data", mountPath: "/filsynk-test/mnt/Data 1", format: .apfs, isSystem: false)
        let other = VolumeInfo(uuid: "S2", name: "Data", mountPath: "/filsynk-test/mnt/Data", format: .apfs, isSystem: false)
        let path = "/filsynk-test/mnt/Data/A"
        let folder = FolderConfig(path: path, destinations: [.server(path: "/srv/A"), Self.diskA], sourceVolumeUUID: "S1")
        let h = Self.make(Self.config([folder, Self.folderB]), volumes: FakeVolumes([Self.volumeU1, own, other]))
        await h.engine.start()
        #expect(await eventually { await h.runner.callCount(Self.pathB) == 1 })
        await h.engine.syncNow()
        #expect(await eventually { await h.runner.callCount(Self.pathB) == 2 })
        await settle()
        #expect(await h.runner.callCount(path) == 0)
        #expect(h.recorder.state(of: path) == .notConnected)
        #expect(h.recorder.state(of: path, Self.diskA.id) == .notConnected)
        await h.engine.stop()
    }

    @Test func sourceVolumeMountedAgainGetsANewWatcher() async {
        let source = VolumeInfo(uuid: "S1", name: "Data", mountPath: "/filsynk-test", format: .apfs, isSystem: false)
        var onData = Self.bothA
        onData.sourceVolumeUUID = "S1"
        let h = Self.make(Self.config([onData]), volumes: FakeVolumes([Self.volumeU1, source]))
        await h.engine.start()
        #expect(await eventually {
            h.recorder.state(of: Self.pathA) == .synced && h.recorder.state(of: Self.pathA, Self.diskA.id) == .synced
        })
        #expect(h.watchers.creations(Self.pathA) == 1)

        h.volumes.willUnmount(source)
        h.volumes.unmount(path: source.mountPath)
        #expect(await eventually { h.recorder.state(of: Self.pathA) == .notConnected })
        h.volumes.mount(source)
        #expect(await eventually { await h.runner.callCount(Self.pathA, "server") == 2 })
        #expect(h.watchers.creations(Self.pathA) == 2)
        #expect(h.watchers.stopped.contains(Self.pathA))
        #expect(h.watchers.active == [Self.pathA])

        // The new watcher is the one that reports changes.
        #expect(await eventually { h.recorder.state(of: Self.pathA) == .synced })
        h.watchers.trigger(Self.pathA)
        #expect(await eventually { await h.runner.callCount(Self.pathA, "server") == 3 })
        await h.engine.stop()
    }
}
