import Foundation
import Testing
@testable import FilsynkCore

/// En lista över monterade volymer som testet ändrar, och monteringshändelserna. Händelserna
/// levereras i tur och ordning från en egen kö, som systemets.
final class FakeVolumes: VolumeMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var list: [VolumeInfo]
    private var onMount: (@Sendable (VolumeInfo) -> Void)?
    private var onWillUnmount: (@Sendable (VolumeInfo) -> Void)?
    private var onUnmount: (@Sendable (String) -> Void)?
    private let queue = DispatchQueue(label: "fake-volumes")

    init(_ volumes: [VolumeInfo] = []) { list = volumes }

    var volumes: [VolumeInfo] {
        get { lock.withLock { list } }
        set { lock.withLock { list = newValue } }
    }

    private var queries = 0
    /// Töms när uppslagning nummer så många görs (1 är den första).
    var vanishAtQuery: Int?

    func mountedVolumes() -> [VolumeInfo] {
        lock.withLock {
            queries += 1
            if let n = vanishAtQuery, queries >= n { list = [] }
            return list
        }
    }
    /// Läggs till i listan när övervakningen startar, utan någon händelse: en disk som monteras
    /// precis när övervakningen kommer igång.
    var mountsWhileStarting: [VolumeInfo] {
        get { lock.withLock { pendingMounts } }
        set { lock.withLock { pendingMounts = newValue } }
    }
    private var pendingMounts: [VolumeInfo] = []

    func start(onMount: @escaping @Sendable (VolumeInfo) -> Void,
               onWillUnmount: @escaping @Sendable (VolumeInfo) -> Void,
               onUnmount: @escaping @Sendable (String) -> Void) {
        lock.withLock {
            list += pendingMounts
            pendingMounts = []
            self.onMount = onMount
            self.onWillUnmount = onWillUnmount
            self.onUnmount = onUnmount
        }
    }

    func stop() {
        lock.withLock { onMount = nil; onWillUnmount = nil; onUnmount = nil }
    }

    var isStarted: Bool { lock.withLock { onMount != nil } }

    func mount(_ volume: VolumeInfo) {
        let callback = lock.withLock { list.append(volume); return onMount }
        queue.async { callback?(volume) }
    }

    /// Volymen är fortfarande monterad när det här levereras.
    func willUnmount(_ volume: VolumeInfo) {
        let callback = lock.withLock { onWillUnmount }
        queue.async { callback?(volume) }
    }

    func unmount(path: String) {
        let callback = lock.withLock { list.removeAll { $0.mountPath == path }; return onUnmount }
        queue.async { callback?(path) }
    }
}

/// Kör riktig rsync men låter testet gripa in efter att en körning börjat eller slutat.
final class HookedProcess: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let real = SystemProcessRunner()
    var afterRun: (@Sendable (Int) -> Void)?

    var runs: Int { lock.withLock { count } }

    func run(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
        let number = lock.withLock { count += 1; return count }
        let result = try await real.run(executable, arguments)
        afterRun?(number)
        return result
    }
}

/// Svarar med färdiga resultat, i ordning, och bokför vad som anropades.
final class ScriptedRsync: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ProcessResult]
    private var _calls: [[String]] = []
    var onRun: (@Sendable (Int, [String]) -> Void)?

    init(_ results: [ProcessResult]) { self.results = results }

    var calls: [[String]] { lock.withLock { _calls } }

    func run(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
        let (number, result) = lock.withLock { () -> (Int, ProcessResult) in
            _calls.append(arguments)
            return (_calls.count, results.isEmpty ? ProcessResult(exitCode: 0, stdout: "", stderr: "") : results.removeFirst())
        }
        onRun?(number, arguments)
        return result
    }
}

struct DiskSyncRunnerTests {
    /// En källmapp och en "disk" i en temporär katalog. Båda sidor är lokala, som för en riktig disk.
    final class Setup {
        let base: String
        let source: String
        let mount: String
        let destination: String
        let volumes: FakeVolumes
        let disk = DiskLocation(volumeUUID: "U1", volumeName: "Testdisk", path: "Filsynk/A")
        let timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_794_922_325)

        init(marker: Bool = true, createDestination: Bool = true) throws {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("filsynk-disk-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            base = realpath(dir.path, nil).map { String(cString: $0) } ?? dir.resolvingSymlinksInPath().path
            source = base + "/src"
            mount = base + "/disk"
            destination = mount + "/Filsynk/A"
            try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: mount, withIntermediateDirectories: true)
            if createDestination {
                try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
                if marker { try DiskMarker.write(in: destination, folder: source) }
            }
            volumes = FakeVolumes([VolumeInfo(uuid: "U1", name: "Testdisk", mountPath: mount, format: .apfs, isSystem: false)])
        }

        deinit { try? FileManager.default.removeItem(atPath: base) }

        func volume(uuid: String? = "U1", format: VolumeFormat = .apfs, isSystem: Bool = false,
                    mountPath: String? = nil) -> VolumeInfo {
            VolumeInfo(uuid: uuid, name: "Testdisk", mountPath: mountPath ?? mount, format: format, isSystem: isSystem)
        }

        var config: Config { Config(folders: []) }
        var folder: FolderConfig { FolderConfig(path: source, destinations: [.disk(disk)]) }
        var timestamp: String { RsyncCommand.timestamp(Date(timeIntervalSince1970: now.timeIntervalSince1970), timeZone: timeZone) }

        func runner(_ process: any ProcessRunning, log: (@Sendable (String) -> Void)? = nil) -> DiskSyncRunner {
            DiskSyncRunner(process: process, volumes: volumes, timeZone: timeZone, log: log)
        }

        func sync(_ runner: DiskSyncRunner, folder: FolderConfig? = nil, config: Config? = nil,
                  now: Date? = nil) async -> SyncOutcome {
            await runner.sync(folder: folder ?? self.folder, disk: disk, config: config ?? self.config, now: now ?? self.now)
        }

        func write(_ root: String, _ relative: String, _ text: String) throws {
            let path = root + "/" + relative
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }

        func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

        /// Relativa sökvägar under en katalog, mappar med avslutande snedstreck.
        func tree(_ root: String) -> [String] {
            var result: [String] = []
            let items = (try? FileManager.default.subpathsOfDirectory(atPath: root)) ?? []
            for item in items.sorted() {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: root + "/" + item, isDirectory: &isDir)
                result.append(isDir.boolValue ? item + "/" : item)
            }
            return result
        }

        var raderat: String { destination + "/Raderat" }
    }

    // MARK: Det som kommer fram

    @Test func newFileArrives() async throws {
        let s = try Setup()
        try s.write(s.source, "a.txt", "hej")
        try s.write(s.source, "sub/b.txt", "djup")
        let log = LogSink()
        let outcome = await s.sync(s.runner(SystemProcessRunner(), log: { log.add($0) }))
        #expect(outcome == .success)
        #expect(s.read(s.destination + "/a.txt") == "hej")
        #expect(s.read(s.destination + "/sub/b.txt") == "djup")
        #expect(!s.exists(s.raderat))
        #expect(log.lines.count == 1)
        #expect(log.lines[0].contains(s.source) && log.lines[0].contains("klar"))
    }

    @Test func overwrittenFileGoesToRaderat() async throws {
        let s = try Setup()
        try s.write(s.destination, "a.txt", "gammalt")
        try s.write(s.source, "a.txt", "nytt och längre")
        #expect(await s.sync(s.runner(SystemProcessRunner())) == .success)
        #expect(s.read(s.destination + "/a.txt") == "nytt och längre")
        #expect(s.read(s.raderat + "/" + s.timestamp + "/a.txt") == "gammalt")
        #expect(s.tree(s.raderat) == [s.timestamp + "/", s.timestamp + "/a.txt"])
    }

    @Test func deletedFileGoesToRaderat() async throws {
        let s = try Setup()
        try s.write(s.destination, "kvar.txt", "kvar")
        try s.write(s.destination, "borta.txt", "borta")
        try s.write(s.source, "kvar.txt", "kvar")
        #expect(await s.sync(s.runner(SystemProcessRunner())) == .success)
        #expect(!s.exists(s.destination + "/borta.txt"))
        #expect(s.read(s.raderat + "/" + s.timestamp + "/borta.txt") == "borta")
        #expect(s.read(s.destination + "/kvar.txt") == "kvar")
        #expect(!s.exists(s.raderat + "/" + s.timestamp + "/kvar.txt"))
    }

    @Test func deletedFolderGoesToRaderatAndIsRemoved() async throws {
        let s = try Setup()
        try s.write(s.destination, "gammal/djup/f.txt", "innehåll")
        try s.write(s.destination, "gammal/g.txt", "g")
        try s.write(s.source, "a.txt", "a")
        #expect(await s.sync(s.runner(SystemProcessRunner())) == .success)
        #expect(!s.exists(s.destination + "/gammal"))
        #expect(s.read(s.raderat + "/" + s.timestamp + "/gammal/djup/f.txt") == "innehåll")
        #expect(s.read(s.raderat + "/" + s.timestamp + "/gammal/g.txt") == "g")
    }

    @Test func excludedFileInDestinationIsLeftAlone() async throws {
        let s = try Setup()
        var config = s.config; config.exclude = ["*.tmp"]
        try s.write(s.destination, "gammal.tmp", "ligger kvar")
        try s.write(s.source, "ny.tmp", "kopieras inte")
        try s.write(s.source, "a.txt", "a")
        #expect(await s.sync(s.runner(SystemProcessRunner()), config: config) == .success)
        #expect(s.read(s.destination + "/gammal.tmp") == "ligger kvar")
        #expect(!s.exists(s.destination + "/ny.tmp"))
        #expect(s.read(s.destination + "/a.txt") == "a")
        #expect(!s.exists(s.raderat))
    }

    @Test func raderatSurvivesAndIsNeverSyncedBack() async throws {
        let s = try Setup()
        try s.write(s.destination, "Raderat/2020-01-01_000000/gammal.txt", "sparad")
        try s.write(s.source, "a.txt", "a")
        let before = s.tree(s.source)
        #expect(await s.sync(s.runner(SystemProcessRunner())) == .success)
        #expect(s.read(s.raderat + "/2020-01-01_000000/gammal.txt") == "sparad")
        #expect(s.tree(s.raderat) == ["2020-01-01_000000/", "2020-01-01_000000/gammal.txt"])
        #expect(s.tree(s.source) == before)
    }

    @Test func markerIsNeitherCopiedOverNorMoved() async throws {
        let s = try Setup()
        let original = s.read(s.destination + "/.filsynk")
        #expect(original != nil)
        try s.write(s.source, ".filsynk", "en fil i källan med samma namn")
        try s.write(s.source, "a.txt", "a")
        #expect(await s.sync(s.runner(SystemProcessRunner())) == .success)
        #expect(s.read(s.destination + "/.filsynk") == original)
        #expect(!s.exists(s.raderat))
        #expect(DiskMarker.exists(in: s.destination))
    }

    @Test func markerSurvivesWhenSourceIsEmpty() async throws {
        let s = try Setup()
        try s.write(s.destination, "gammal.txt", "x")
        #expect(await s.sync(s.runner(SystemProcessRunner())) == .success)
        #expect(DiskMarker.exists(in: s.destination))
        #expect(s.read(s.raderat + "/" + s.timestamp + "/gammal.txt") == "x")
        #expect(!s.exists(s.raderat + "/" + s.timestamp + "/.filsynk"))
    }

    @Test func secondRunWithoutChangesCreatesNoRaderatFolder() async throws {
        let s = try Setup()
        try s.write(s.source, "a.txt", "a")
        try s.write(s.source, "sub/b.txt", "b")
        let runner = s.runner(SystemProcessRunner())
        #expect(await s.sync(runner) == .success)
        #expect(await s.sync(runner, now: s.now.addingTimeInterval(60)) == .success)
        #expect(!s.exists(s.raderat))
        #expect(s.tree(s.destination) == [".filsynk", "a.txt", "sub/", "sub/b.txt"])
    }

    @Test func swedishNamesAreStable() async throws {
        let s = try Setup()
        try s.write(s.source, "Varumärke/Räksmörgås anteckning.txt", "smörgås")
        let runner = s.runner(SystemProcessRunner())
        #expect(await s.sync(runner) == .success)
        #expect(await s.sync(runner, now: s.now.addingTimeInterval(60)) == .success)
        #expect(!s.exists(s.raderat))
        #expect(s.read(s.destination + "/Varumärke/Räksmörgås anteckning.txt") == "smörgås")
    }

    @Test func swedishNameDeletedGoesToRaderat() async throws {
        let s = try Setup()
        try s.write(s.destination, "Varumärke/Räksmörgås.txt", "borta")
        try s.write(s.source, "a.txt", "a")
        #expect(await s.sync(s.runner(SystemProcessRunner())) == .success)
        #expect(!s.exists(s.destination + "/Varumärke"))
        #expect(s.read(s.raderat + "/" + s.timestamp + "/Varumärke/Räksmörgås.txt") == "borta")
    }

    @Test func decomposedSwedishNameDeletedGoesToRaderat() async throws {
        let s = try Setup()
        // Den form Finder och de flesta program lagrar: bokstaven följd av ett kombinerande tecken.
        let name = "Åäö räksmörgås.txt".decomposedStringWithCanonicalMapping
        try s.write(s.destination, name, "borta")
        try s.write(s.source, "a.txt", "a")
        #expect(await s.sync(s.runner(SystemProcessRunner())) == .success)
        #expect(!s.exists(s.destination + "/" + name))
        #expect(s.read(s.raderat + "/" + s.timestamp + "/" + name) == "borta")
    }

    @Test func nameWithControlCharacterDeletedGoesToRaderat() async throws {
        let s = try Setup()
        try s.write(s.destination, "rad\nbrytning.txt", "borta")
        try s.write(s.destination, "back\\#303slash.txt", "också borta")
        try s.write(s.source, "a.txt", "a")
        #expect(await s.sync(s.runner(SystemProcessRunner())) == .success)
        #expect(s.tree(s.destination).filter { !$0.hasPrefix("Raderat/") } == [".filsynk", "a.txt"])
        #expect(s.read(s.raderat + "/" + s.timestamp + "/rad\nbrytning.txt") == "borta")
        #expect(s.read(s.raderat + "/" + s.timestamp + "/back\\#303slash.txt") == "också borta")
    }

    @Test func folderReplacingFileWithControlCharacterInName() async throws {
        let s = try Setup()
        try s.write(s.destination, "ny\nrad", "var en fil")
        try s.write(s.source, "ny\nrad/inne.txt", "nu en mapp")
        #expect(await s.sync(s.runner(SystemProcessRunner())) == .success)
        #expect(s.read(s.destination + "/ny\nrad/inne.txt") == "nu en mapp")
        #expect(s.read(s.raderat + "/" + s.timestamp + "/ny\nrad") == "var en fil")
    }

    @Test func fileReplacedByFolderEndsUpRight() async throws {
        let s = try Setup()
        try s.write(s.destination, "x", "var en fil")
        try s.write(s.source, "x/y.txt", "nu en mapp")
        #expect(await s.sync(s.runner(SystemProcessRunner())) == .success)
        var isDir: ObjCBool = false
        #expect(s.exists(s.destination + "/x") && FileManager.default.fileExists(atPath: s.destination + "/x", isDirectory: &isDir) && isDir.boolValue)
        #expect(s.read(s.destination + "/x/y.txt") == "nu en mapp")
        #expect(s.read(s.raderat + "/" + s.timestamp + "/x") == "var en fil")
    }

    @Test func folderReplacedByFileEndsUpRight() async throws {
        let s = try Setup()
        try s.write(s.destination, "x/y.txt", "låg i mappen")
        try s.write(s.source, "x", "nu en fil")
        #expect(await s.sync(s.runner(SystemProcessRunner())) == .success)
        #expect(s.read(s.destination + "/x") == "nu en fil")
        #expect(s.read(s.raderat + "/" + s.timestamp + "/x/y.txt") == "låg i mappen")
    }

    @Test func fileReplacedByLinkEndsUpRight() async throws {
        let s = try Setup()
        try s.write(s.destination, "x", "var en fil")
        try s.write(s.source, "mål.txt", "m")
        try FileManager.default.createSymbolicLink(atPath: s.source + "/x", withDestinationPath: "mål.txt")
        #expect(await s.sync(s.runner(SystemProcessRunner())) == .success)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: s.destination + "/x") == "mål.txt")
        #expect(s.read(s.raderat + "/" + s.timestamp + "/x") == "var en fil")
    }

    @Test func exFATFormatSyncsToo() async throws {
        let s = try Setup()
        s.volumes.volumes = [s.volume(format: .exfat)]
        try s.write(s.destination, "gammal.txt", "g")
        try s.write(s.source, "a.txt", "a")
        #expect(await s.sync(s.runner(SystemProcessRunner())) == .success)
        #expect(s.read(s.destination + "/a.txt") == "a")
        #expect(s.read(s.raderat + "/" + s.timestamp + "/gammal.txt") == "g")
    }

    @Test func timestampsNeverRepeat() async throws {
        let s = try Setup()
        let runner = s.runner(SystemProcessRunner())
        try s.write(s.source, "a.txt", "a")
        try s.write(s.destination, "ett.txt", "1")
        #expect(await s.sync(runner) == .success)
        try s.write(s.destination, "två.txt", "2")
        #expect(await s.sync(runner) == .success)
        let later = RsyncCommand.timestamp(s.now.addingTimeInterval(1), timeZone: s.timeZone)
        #expect(s.timestamp != later)
        #expect(s.read(s.raderat + "/" + s.timestamp + "/ett.txt") == "1")
        #expect(s.read(s.raderat + "/" + later + "/två.txt") == "2")
    }

    // MARK: Disken saknas eller är fel

    @Test func notMountedIsUnreachableAndWritesNothing() async throws {
        let s = try Setup()
        s.volumes.volumes = []
        try s.write(s.destination, "gammal.txt", "g")
        let process = FakeProcess()
        #expect(await s.sync(s.runner(process)) == .unreachable)
        #expect(process.calls.isEmpty)
        #expect(s.tree(s.destination) == [".filsynk", "gammal.txt"])
    }

    @Test func otherVolumeWithSameNameIsUnreachable() async throws {
        let s = try Setup()
        s.volumes.volumes = [s.volume(uuid: "U2")]
        let process = FakeProcess()
        #expect(await s.sync(s.runner(process)) == .unreachable)
        #expect(process.calls.isEmpty)
    }

    @Test func volumeWithoutIdIsUnreachable() async throws {
        let s = try Setup()
        s.volumes.volumes = [s.volume(uuid: nil), s.volume(uuid: "")]
        let process = FakeProcess()
        #expect(await s.sync(s.runner(process)) == .unreachable)
        #expect(process.calls.isEmpty)
    }

    @Test func duplicateVolumesFail() async throws {
        let s = try Setup()
        s.volumes.volumes = [s.volume(uuid: "U1"), s.volume(uuid: "u1", mountPath: s.base + "/annan")]
        let process = FakeProcess()
        #expect(await s.sync(s.runner(process)) == .failed("Två inkopplade diskar har samma id."))
        #expect(process.calls.isEmpty)
    }

    @Test func unsupportedFormatFails() async throws {
        let s = try Setup()
        s.volumes.volumes = [s.volume(format: .other("ntfs"))]
        let process = FakeProcess()
        #expect(await s.sync(s.runner(process)) == .failed("Diskens format stöds inte."))
        #expect(process.calls.isEmpty)
    }

    @Test func systemVolumeFails() async throws {
        let s = try Setup()
        s.volumes.volumes = [s.volume(isSystem: true)]
        let process = FakeProcess()
        #expect(await s.sync(s.runner(process)) == .failed("Systemdisken kan inte vara mål."))
        #expect(process.calls.isEmpty)
    }

    @Test func refusesDestinationWithoutMarker() async throws {
        let s = try Setup(marker: false)
        try s.write(s.destination, "viktig.txt", "orörd")
        try s.write(s.source, "a.txt", "a")
        let process = FakeProcess()
        #expect(await s.sync(s.runner(process))
            == .failed("Mappen på disken känns inte igen. Lägg till målet igen."))
        #expect(process.calls.isEmpty)
        #expect(s.tree(s.destination) == ["viktig.txt"])
        #expect(s.read(s.destination + "/viktig.txt") == "orörd")
    }

    @Test func refusesDestinationWhoseMarkerNamesAnotherFolder() async throws {
        let s = try Setup(marker: false)
        try DiskMarker.write(in: s.destination, folder: s.base + "/annan")
        try s.write(s.destination, "gammal.txt", "orörd")
        try s.write(s.source, "a.txt", "a")
        let process = FakeProcess()
        #expect(await s.sync(s.runner(process))
            == .failed("Mappen på disken känns inte igen. Lägg till målet igen."))
        #expect(process.calls.isEmpty)
        #expect(s.tree(s.destination) == [".filsynk", "gammal.txt"])
        #expect(s.read(s.destination + "/gammal.txt") == "orörd")
    }

    @Test func refusesMissingDestinationFolder() async throws {
        let s = try Setup(createDestination: false)
        try s.write(s.source, "a.txt", "a")
        let process = FakeProcess()
        #expect(await s.sync(s.runner(process))
            == .failed("Mappen på disken känns inte igen. Lägg till målet igen."))
        #expect(process.calls.isEmpty)
        #expect(!s.exists(s.mount + "/Filsynk"))
        #expect(s.tree(s.mount).isEmpty)
    }

    // MARK: Källan

    @Test func missingSourceFailsWithoutRunningAnything() async throws {
        let s = try Setup()
        let missing = FolderConfig(path: s.base + "/finns-inte", destinations: [.disk(s.disk)])
        let process = FakeProcess()
        #expect(await s.sync(s.runner(process), folder: missing)
            == .failed("Mappen \(s.base)/finns-inte saknas eller går inte att läsa"))
        #expect(process.calls.isEmpty)
    }

    @Test func sourceOnMissingVolumeIsUnreachable() async throws {
        let s = try Setup()
        let folder = FolderConfig(path: s.source, destinations: [.disk(s.disk)], sourceVolumeUUID: "U9")
        let process = FakeProcess()
        #expect(await s.sync(s.runner(process), folder: folder) == .unreachable)
        #expect(process.calls.isEmpty)
    }

    @Test func sourceMustLieOnItsVolume() async throws {
        let s = try Setup()
        try s.write(s.source, "a.txt", "a")
        let home = VolumeInfo(uuid: "U2", name: "Hem", mountPath: s.base, format: .apfs, isSystem: false)
        s.volumes.volumes = [s.volume(), home]
        let onHome = FolderConfig(path: s.source, destinations: [.disk(s.disk)], sourceVolumeUUID: "u2")
        #expect(await s.sync(s.runner(SystemProcessRunner()), folder: onHome) == .success)
        #expect(s.read(s.destination + "/a.txt") == "a")

        let wrong = FolderConfig(path: s.source, destinations: [.disk(s.disk)], sourceVolumeUUID: "U1")
        let process = FakeProcess()
        #expect(await s.sync(s.runner(process), folder: wrong) == .unreachable)
        #expect(process.calls.isEmpty)
    }

    // MARK: Disken försvinner under körningen

    @Test func volumeGoneBetweenPhasesStopsWithoutWriting() async throws {
        let s = try Setup()
        try s.write(s.destination, "borta.txt", "borta")
        try s.write(s.source, "a.txt", "a")
        let process = HookedProcess()
        process.afterRun = { [volumes = s.volumes] _ in volumes.volumes = [] }
        #expect(await s.sync(s.runner(process)) == .unreachable)
        #expect(process.runs == 1)
        #expect(!s.exists(s.raderat))
        #expect(s.read(s.destination + "/borta.txt") == "borta")
        #expect(!s.exists(s.destination + "/a.txt"))
    }

    @Test func volumeMountedElsewhereBetweenPhasesStopsWithoutWriting() async throws {
        let s = try Setup()
        try s.write(s.destination, "borta.txt", "borta")
        let process = HookedProcess()
        process.afterRun = { [volumes = s.volumes, other = s.base + "/annan-plats"] _ in
            volumes.volumes = [VolumeInfo(uuid: "U1", name: "Testdisk", mountPath: other, format: .apfs, isSystem: false)]
        }
        #expect(await s.sync(s.runner(process)) == .unreachable)
        #expect(process.runs == 1)
        #expect(!s.exists(s.raderat))
        #expect(s.read(s.destination + "/borta.txt") == "borta")
    }

    // MARK: Med färdiga svar

    @Test func failedDryRunMovesNothing() async throws {
        let s = try Setup()
        try s.write(s.destination, "borta.txt", "borta")
        let process = ScriptedRsync([ProcessResult(exitCode: 23, stdout: "*deleting borta.txt\n", stderr: "något gick fel\n")])
        #expect(await s.sync(s.runner(process)) == .failed("något gick fel"))
        #expect(process.calls.count == 1)
        #expect(s.read(s.destination + "/borta.txt") == "borta")
        #expect(!s.exists(s.raderat))
    }

    @Test func realRunUsesTheSameTimestampAsTheMove() async throws {
        let s = try Setup()
        try s.write(s.destination, "borta.txt", "borta")
        let process = ScriptedRsync([
            ProcessResult(exitCode: 0, stdout: "*deleting borta.txt\n", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
        ])
        let excludePaths = ExcludePaths()
        process.onRun = { _, arguments in
            if let a = arguments.first(where: { $0.hasPrefix("--exclude-from=") }) {
                excludePaths.add(String(a.dropFirst("--exclude-from=".count)))
            }
        }
        #expect(await s.sync(s.runner(process)) == .success)
        #expect(process.calls.count == 2)
        let real = process.calls[1]
        #expect(real.contains("--backup-dir=\(s.destination)/Raderat/\(s.timestamp)"))
        #expect(s.read(s.raderat + "/" + s.timestamp + "/borta.txt") == "borta")
        #expect(!real.contains("--delete") && !real.contains("-e"))
        #expect(process.calls[0].contains("--delete") && process.calls[0].contains("-n"))
        #expect(real.suffix(2) == [s.source + "/", s.destination + "/"])
        // Undantagsfilen är borta när körningen är klar.
        #expect(excludePaths.paths.count == 2 && Set(excludePaths.paths).count == 1)
        #expect(!s.exists(excludePaths.paths[0]))
    }

    @Test func failedRealRunIsClassified() async throws {
        let s = try Setup()
        let process = ScriptedRsync([
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
            ProcessResult(exitCode: 11, stdout: "", stderr: "rsync: write failed: No space left on device\n"),
        ])
        #expect(await s.sync(s.runner(process)) == .failed("Disken är full"))
    }

    @Test func failedRealRunWithVolumeGoneIsUnreachable() async throws {
        let s = try Setup()
        let process = ScriptedRsync([
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
            ProcessResult(exitCode: 23, stdout: "", stderr: "rsync: mkstemp failed\n"),
        ])
        process.onRun = { [volumes = s.volumes] number, _ in if number == 2 { volumes.volumes = [] } }
        #expect(await s.sync(s.runner(process)) == .unreachable)
    }

    @Test func brokenPipeOnAMountedDiskIsAFailureNotAMissingDisk() async throws {
        let s = try Setup()
        let real = ScriptedRsync([
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
            ProcessResult(exitCode: 12, stdout: "", stderr: "rsync: [sender] write error: Broken pipe (32)\n"),
        ])
        let afterRealRun = await s.sync(s.runner(real))
        #expect(afterRealRun == .failed("rsync: [sender] write error: Broken pipe (32)"))
        let dry = ScriptedRsync([
            ProcessResult(exitCode: 12, stdout: "", stderr: "rsync: read error: Connection reset by peer (54)\n"),
        ])
        let afterDryRun = await s.sync(s.runner(dry))
        #expect(afterDryRun == .failed("rsync: read error: Connection reset by peer (54)"))
        #expect(dry.calls.count == 1)
    }

    @Test func brokenPipeWithTheDiskGoneIsUnreachable() async throws {
        let s = try Setup()
        let process = ScriptedRsync([
            ProcessResult(exitCode: 12, stdout: "", stderr: "rsync: write error: Broken pipe (32)\n"),
        ])
        process.onRun = { [volumes = s.volumes] _, _ in volumes.volumes = [] }
        #expect(await s.sync(s.runner(process)) == .unreachable)
    }

    @Test func dryRunExitingWith24StillMovesAndSyncs() async throws {
        let s = try Setup()
        try s.write(s.destination, "borta.txt", "borta")
        let process = ScriptedRsync([
            ProcessResult(exitCode: 24, stdout: "*deleting borta.txt\n", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
        ])
        #expect(await s.sync(s.runner(process)) == .success)
        #expect(process.calls.count == 2)
        #expect(s.read(s.raderat + "/" + s.timestamp + "/borta.txt") == "borta")
    }

    @Test func dryRunFailureGivesNoSecondInvocation() async throws {
        let s = try Setup()
        let process = ScriptedRsync([ProcessResult(exitCode: 23, stdout: "", stderr: "fel\n")])
        let outcome = await s.sync(s.runner(process))
        #expect(outcome == .failed("fel"))
        #expect(process.calls.count == 1)
    }

    @Test func cancelDuringTheDryRunMovesNothingAndStartsNoRealRun() async throws {
        let s = try Setup()
        try s.write(s.destination, "borta.txt", "borta")
        let process = ScriptedRsync([
            ProcessResult(exitCode: 0, stdout: "*deleting borta.txt\n", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
        ])
        // Avbryts medan torrkörningen pågår.
        process.onRun = { number, _ in
            if number == 1 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let outcome = await s.sync(s.runner(process))
        #expect(outcome != .success)
        #expect(process.calls.count == 1)
        #expect(s.read(s.destination + "/borta.txt") == "borta")
        #expect(!s.exists(s.raderat))
    }

    @Test func volumeGoneAfterTheMoveStopsBeforeTheRealRun() async throws {
        let s = try Setup()
        try s.write(s.destination, "borta.txt", "borta")
        // Uppslagningar: början, efter torrkörningen, före den riktiga körningen.
        s.volumes.vanishAtQuery = 3
        let process = ScriptedRsync([ProcessResult(exitCode: 0, stdout: "*deleting borta.txt\n", stderr: "")])
        #expect(await s.sync(s.runner(process)) == .unreachable)
        #expect(process.calls.count == 1)
        #expect(s.read(s.raderat + "/" + s.timestamp + "/borta.txt") == "borta")
    }

    @Test func earlierBackupInRaderatIsNeverReplaced() async throws {
        let s = try Setup()
        try s.write(s.destination, "Raderat/\(s.timestamp)/a", "tidigare kopia")
        try s.write(s.destination, "a", "gammalt")
        try s.write(s.source, "a", "nytt och längre")
        #expect(await s.sync(s.runner(SystemProcessRunner())) == .success)
        let later = RsyncCommand.timestamp(s.now.addingTimeInterval(1), timeZone: s.timeZone)
        #expect(s.read(s.raderat + "/" + s.timestamp + "/a") == "tidigare kopia")
        #expect(s.read(s.raderat + "/" + later + "/a") == "gammalt")
        #expect(s.read(s.destination + "/a") == "nytt och längre")
    }

    @Test func linkInTheMiddleOfTheDiskPathIsRefused() async throws {
        let s = try Setup()
        let outside = s.base + "/utanfor"
        try FileManager.default.createDirectory(atPath: outside + "/A", withIntermediateDirectories: true)
        try DiskMarker.write(in: outside + "/A", folder: s.source)
        try FileManager.default.createSymbolicLink(atPath: s.mount + "/F", withDestinationPath: outside)
        try s.write(s.source, "a.txt", "a")
        let process = FakeProcess()
        let moved = DiskLocation(volumeUUID: "U1", volumeName: "Testdisk", path: "F/A")
        let outcome = await s.runner(process).sync(folder: s.folder, disk: moved, config: s.config, now: s.now)
        #expect(outcome == .failed("Mappen på disken känns inte igen. Lägg till målet igen."))
        #expect(process.calls.isEmpty)
        #expect(s.tree(outside) == ["A/", "A/.filsynk"])
    }

    @Test func linkAsTheLastComponentOfTheDiskPathIsRefused() async throws {
        let s = try Setup()
        let outside = s.base + "/utanfor"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try DiskMarker.write(in: outside, folder: s.source)
        try FileManager.default.createSymbolicLink(atPath: s.mount + "/Filsynk/L", withDestinationPath: outside)
        try s.write(s.source, "a.txt", "a")
        let process = FakeProcess()
        let moved = DiskLocation(volumeUUID: "U1", volumeName: "Testdisk", path: "Filsynk/L")
        let outcome = await s.runner(process).sync(folder: s.folder, disk: moved, config: s.config, now: s.now)
        #expect(outcome == .failed("Mappen på disken känns inte igen. Lägg till målet igen."))
        #expect(process.calls.isEmpty)
        #expect(s.tree(outside) == [".filsynk"])
    }

    @Test func invalidDiskPathIsRefusedByTheRunner() async throws {
        let s = try Setup()
        let process = FakeProcess()
        for bad in ["", "/Filsynk/A", "Filsynk//A", "Filsynk/../Filsynk/A", "./Filsynk/A", "Filsynk/A/"] {
            let location = DiskLocation(volumeUUID: "U1", volumeName: "Testdisk", path: bad)
            let outcome = await s.runner(process).sync(folder: s.folder, disk: location, config: s.config, now: s.now)
            #expect(outcome == .failed("Mappen på disken känns inte igen. Lägg till målet igen."), "\(bad)")
        }
        #expect(process.calls.isEmpty)
    }

    @Test func raderatThatIsALinkStopsBeforeTheRealRun() async throws {
        let s = try Setup()
        let elsewhere = s.base + "/annanstans"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: s.destination + "/Raderat", withDestinationPath: elsewhere)
        try s.write(s.destination, "a", "gammalt")
        try s.write(s.source, "a", "nytt och längre")
        let outcome = await s.sync(s.runner(SystemProcessRunner()))
        #expect(outcome == .failed("Mappen Raderat på disken är inte en vanlig mapp."))
        #expect(s.tree(elsewhere).isEmpty)
        #expect(s.read(s.destination + "/a") == "gammalt")
    }

    @Test func fileNamedLikeALinkDoesNotHideTheReplacedFile() async throws {
        let s = try Setup()
        try s.write(s.source, "m", "mål")
        try FileManager.default.createSymbolicLink(atPath: s.source + "/x", withDestinationPath: "m")
        try s.write(s.source, "x -> m", "fil med pil")
        try s.write(s.destination, "x -> m", "fil med pil")
        try s.write(s.destination, "x", "gamla x")
        #expect(await s.sync(s.runner(SystemProcessRunner())) == .success)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: s.destination + "/x") == "m")
        #expect(s.read(s.raderat + "/" + s.timestamp + "/x") == "gamla x")
        #expect(s.read(s.destination + "/x -> m") == "fil med pil")
    }

    @Test func reservedNamesHoldRegardlessOfCase() async throws {
        let s = try Setup()
        let marker = s.read(s.destination + "/.filsynk")
        try s.write(s.source, ".FILSYNK", "angripare")
        try s.write(s.source, "raderat/x.txt", "ska inte kopieras")
        try s.write(s.source, "a.txt", "a")
        #expect(await s.sync(s.runner(SystemProcessRunner())) == .success)
        #expect(s.read(s.destination + "/.filsynk") == marker)
        #expect(s.tree(s.destination) == [".filsynk", "a.txt"])
    }

    @Test func moveFailureStopsBeforeTheRealRun() async throws {
        let s = try Setup()
        // Raderat är en fil, så mappen under den går inte att skapa.
        try s.write(s.destination, "Raderat", "i vägen")
        try s.write(s.destination, "borta.txt", "borta")
        let process = ScriptedRsync([ProcessResult(exitCode: 0, stdout: "*deleting borta.txt\n", stderr: "")])
        let outcome = await s.sync(s.runner(process))
        guard case .failed(let message) = outcome else { Issue.record("väntade .failed, fick \(outcome)"); return }
        #expect(message.hasPrefix("Kunde inte flytta undan raderade filer: "))
        #expect(process.calls.count == 1)
        #expect(s.read(s.destination + "/borta.txt") == "borta")
    }
}

final class ExcludePaths: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ p: String) { lock.withLock { list.append(p) } }
    var paths: [String] { lock.withLock { list } }
}
