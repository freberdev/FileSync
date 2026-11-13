import Foundation
import Testing
@testable import FilsynkCore

// MARK: - Fakes

/// Records every sync, answers with queued outcomes per folder (default `.success`) and can
/// hold each sync for `delay` seconds. Measures concurrency per folder and in total.
private actor FakeRunner: SyncRunning {
    private(set) var calls: [(path: String, at: Date)] = []
    private(set) var cancelled: [String] = []
    private(set) var maxConcurrent: [String: Int] = [:]
    private(set) var maxTotalConcurrent = 0
    private var current: [String: Int] = [:]
    private var outcomes: [String: [SyncOutcome]] = [:]
    private var delay: TimeInterval

    init(delay: TimeInterval = 0) { self.delay = delay }

    func setOutcomes(_ list: [SyncOutcome], for path: String) { outcomes[path] = list }
    func setDelay(_ value: TimeInterval) { delay = value }

    func callCount(_ path: String) -> Int { calls.filter { $0.path == path }.count }
    var totalCalls: Int { calls.count }
    func callDates(_ path: String) -> [Date] { calls.filter { $0.path == path }.map(\.at) }

    func sync(folder: FolderConfig, config: Config, now: Date) async -> SyncOutcome {
        let path = folder.path
        calls.append((path, Date()))
        current[path, default: 0] += 1
        maxConcurrent[path] = max(maxConcurrent[path] ?? 0, current[path]!)
        maxTotalConcurrent = max(maxTotalConcurrent, current.values.reduce(0, +))
        defer { current[path]! -= 1 }

        if delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled {
                cancelled.append(path)
                // Like a terminated rsync, ending takes a moment (not itself cancellable).
                await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
                // Like the real runner: a terminated rsync is an ordinary failure.
                return .failed("rsync avbröts")
            }
        }
        if var queue = outcomes[path], !queue.isEmpty {
            let outcome = queue.removeFirst()
            outcomes[path] = queue
            return outcome
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

    private final class Watcher: FolderWatching, @unchecked Sendable {
        let path: String
        weak var owner: FakeWatchers?
        init(path: String, owner: FakeWatchers) { self.path = path; self.owner = owner }
        func start() { owner?.mark(path, active: true) }
        func stop() { owner?.mark(path, active: false) }
    }

    var factory: WatcherFactory {
        { [self] path, onChange in
            lock.lock(); callbacks[path] = onChange; lock.unlock()
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

    func state(of path: String) -> FolderState? {
        latest?.folders.first { $0.path == path }?.state
    }
}

/// Polls `condition` until it holds or `timeout` seconds have passed.
private func eventually(
    timeout: TimeInterval = 2, _ condition: @Sendable () async -> Bool
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

    fileprivate struct Harness {
        let engine: SyncEngine
        let runner: FakeRunner
        let watchers: FakeWatchers
        let network: FakeNetwork
        let recorder: Recorder
    }

    fileprivate static func make(
        _ config: Config, timing: EngineTiming = timing,
        runner: FakeRunner = FakeRunner(), network: FakeNetwork = FakeNetwork()
    ) -> Harness {
        let watchers = FakeWatchers()
        let recorder = Recorder()
        let engine = SyncEngine(
            config: config, timing: timing, runner: runner,
            makeWatcher: watchers.factory, network: network,
            onStatus: { recorder.record($0) },
            onNotice: { recorder.record($0) })
        return Harness(engine: engine, runner: runner, watchers: watchers, network: network, recorder: recorder)
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
        #expect(await eventually(timeout: 5) { await runner.callCount(Self.pathA) >= 2 })
        // A reload cancels the running syncs; the restarted ones must wait until they have ended.
        await h.engine.reload(Self.config([Self.folderA, Self.folderB]))
        #expect(await eventually(timeout: 5) { await runner.callCount(Self.pathA) >= 3 })
        await settle()
        #expect(await runner.maxConcurrent[Self.pathA] == 1)
        #expect(await runner.maxConcurrent[Self.pathB] == 1)
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
            folder: StatusPresentation.displayPath(Self.pathA, home: NSHomeDirectory()), message: "x")
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
}
