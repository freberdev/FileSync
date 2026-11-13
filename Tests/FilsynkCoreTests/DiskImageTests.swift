import Testing
import Foundation
@testable import FilsynkCore

/// Prov mot riktiga volymer utan någon fysisk disk. Valfritt: sätt FILSYNK_DISK_IMAGE_TESTS=1.
/// Varje test skapar sina egna diskavbilder i en ny temporär katalog och monterar dem med
/// `hdiutil attach -mountrandom` på en plats i samma katalog, så att inget hamnar under /Volumes.
/// Utan `-nobrowse`: en sådan volym räknas som dold och listas inte av `SystemVolumeMonitor`.
/// Det som testet kopplat in kopplas loss igen med enhetsnoden `hdiutil attach` gav, och
/// katalogen tas bort, också när ett steg misslyckas.
private enum DiskImageEnvironment {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["FILSYNK_DISK_IMAGE_TESTS"] == "1" }
}

enum DiskImageFormat: String, CustomTestStringConvertible, Sendable {
    case apfs = "APFS"
    case exfat = "ExFAT"
    var testDescription: String { rawValue }
}

private struct ImageError: Error, CustomStringConvertible {
    var description: String
}

/// Samlar allt motorn rapporterar.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _statuses: [EngineStatus] = []
    private var _notices: [Notice] = []

    func status(_ s: EngineStatus) { lock.lock(); _statuses.append(s); lock.unlock() }
    func notice(_ n: Notice) { lock.lock(); _notices.append(n); lock.unlock() }
    var statuses: [EngineStatus] { lock.lock(); defer { lock.unlock() }; return _statuses }
    var notices: [Notice] { lock.lock(); defer { lock.unlock() }; return _notices }
    var lastState: FolderState? { statuses.last?.folders.first?.state }
    var errors: [String] {
        statuses.compactMap { status in
            if case .error(let message)? = status.folders.first?.state { return message }
            return nil
        }
    }
}

private struct AttachedImage {
    let file: URL
    /// Enheten hela avbilden hänger på; det enda som kopplas loss.
    let device: String
    let mountPath: String
}

/// Allt ett test äger: den temporära katalogen, avbilderna det kopplat in och motorn.
private final class Rig: @unchecked Sendable {
    let root: URL
    let source: URL
    let mountParent: URL
    let process = SystemProcessRunner()
    let monitor = SystemVolumeMonitor()
    let recorder = Recorder()
    private(set) var engine: SyncEngine?
    private var attachedDevices: [String] = []
    private var imageCount = 0

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("filsynk-diskprov-\(UUID().uuidString)")
        source = root.appendingPathComponent("kalla")
        mountParent = root.appendingPathComponent("monteringar")
        for dir in [root, source, mountParent] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: Avbilder

    func makeImage(_ format: DiskImageFormat, name: String = "FilsynkProv") async throws -> URL {
        imageCount += 1
        let file = root.appendingPathComponent("avbild-\(imageCount).dmg")
        let result = try await process.run(
            "/usr/bin/hdiutil",
            ["create", "-size", "40m", "-fs", format.rawValue, "-volname", name, file.path])
        guard result.exitCode == 0 else {
            throw ImageError(description: "hdiutil create \(format.rawValue): \(result.stderr)")
        }
        return file
    }

    func attach(_ file: URL) async throws -> AttachedImage {
        let result = try await process.run(
            "/usr/bin/hdiutil",
            ["attach", "-mountrandom", mountParent.path, "-plist", file.path])
        guard result.exitCode == 0 else { throw ImageError(description: "hdiutil attach: \(result.stderr)") }
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(result.stdout.utf8), format: nil),
              let entities = (plist as? [String: Any])?["system-entities"] as? [[String: Any]] else {
            throw ImageError(description: "hdiutil attach gav ingen läsbar lista: \(result.stdout)")
        }
        // Hela enheter har namnet disk<N>. Avbildens egen har lägst nummer; en syntetiserad
        // APFS-enhet kommer efter den och försvinner med den.
        let wholeDisks = entities.compactMap { $0["dev-entry"] as? String }.compactMap { dev -> (Int, String)? in
            guard dev.hasPrefix("/dev/disk"), let n = Int(dev.dropFirst("/dev/disk".count)) else { return nil }
            return (n, dev)
        }
        let device = wholeDisks.min { $0.0 < $1.0 }?.1
        let mount = entities.compactMap { $0["mount-point"] as? String }.first
        // Enheten noteras innan något annat kan gå fel, så att den alltid kopplas loss.
        if let device { attachedDevices.append(device) }
        guard let device, let mount else {
            throw ImageError(description: "hdiutil attach gav ingen enhet eller monteringspunkt: \(result.stdout)")
        }
        return AttachedImage(file: file, device: device, mountPath: mount)
    }

    func detach(_ image: AttachedImage) async throws {
        var last = ""
        for attempt in 0..<8 {
            let result = try await process.run("/usr/bin/hdiutil", ["detach", image.device])
            if result.exitCode == 0 {
                attachedDevices.removeAll { $0 == image.device }
                return
            }
            last = result.stderr
            try await Task.sleep(for: .seconds(attempt < 3 ? 1 : 2))
        }
        throw ImageError(description: "hdiutil detach \(image.device): \(last)")
    }

    /// Volymen som `SystemVolumeMonitor` ser för avbilden.
    func volume(of image: AttachedImage) -> VolumeInfo? {
        let wanted = URL(fileURLWithPath: image.mountPath).resolvingSymlinksInPath().path
        return monitor.mountedVolumes().first {
            URL(fileURLWithPath: $0.mountPath).resolvingSymlinksInPath().path == wanted
        }
    }

    // MARK: Konfiguration och motor

    /// Tar en ny mapp på avbilden i bruk som mål för källmappen, som inställningsfönstret gör.
    func configure(_ config: Config, image: AttachedImage, folder: String = "Backup") throws -> Config {
        let picked = URL(fileURLWithPath: image.mountPath).appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        let flow = SetupFlow(process: process)
        switch flow.addDiskDestination(
            to: config, localPath: source.path, pickedPath: picked.path, volumes: monitor.mountedVolumes()) {
        case .added(let updated): return updated
        case .rejected(let text): throw ImageError(description: "målet togs inte i bruk: \(text)")
        }
    }

    func startEngine(_ config: Config) async {
        let recorder = self.recorder
        let created = SyncEngine(
            config: config,
            timing: EngineTiming(quiet: 1, maxWait: 5, backoff: [2, 4], noticeCheckInterval: 60, unmountGrace: 3),
            runner: DestinationRunner(
                server: SyncRunner(process: process),
                disk: DiskSyncRunner(process: process, volumes: monitor)),
            makeWatcher: { path, onChange in FolderWatcher(path: path, onChange: onChange) },
            network: SystemNetworkMonitor(), volumes: monitor,
            onStatus: { recorder.status($0) },
            onNotice: { recorder.notice($0) })
        engine = created
        await created.start()
    }

    /// Stoppar motorn och kopplar loss allt som är kvar, sedan tas katalogen bort.
    func tearDown() async -> [String] {
        var problems: [String] = []
        if let engine { await engine.stop() }
        try? await Task.sleep(for: .seconds(1))
        for device in attachedDevices {
            if let result = try? await process.run("/usr/bin/hdiutil", ["detach", "-force", device]),
               result.exitCode == 0 { continue }
            problems.append("kunde inte koppla loss \(device)")
        }
        attachedDevices = []
        try? FileManager.default.removeItem(at: root)
        return problems
    }

    // MARK: Källan

    func write(_ name: String, _ text: String) throws {
        try text.write(to: source.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func remove(_ name: String) {
        try? FileManager.default.removeItem(at: source.appendingPathComponent(name))
    }

    /// Skapar filen med exakt de bytes namnet har, utan att Foundation väljer Unicode-form.
    func writeRaw(_ relative: String, _ text: String) throws {
        let path = source.path + "/" + relative
        var folder = ""
        for part in (path as NSString).deletingLastPathComponent.split(separator: "/", omittingEmptySubsequences: true) {
            folder += "/" + part
            if mkdir(folder, 0o755) != 0, errno != EEXIST { throw CocoaError(.fileWriteUnknown) }
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        guard Darwin.write(fd, bytes, bytes.count) == bytes.count else { throw CocoaError(.fileWriteUnknown) }
    }

    // MARK: Väntan

    /// Väntar på en synk som startar och slutar efter anropet.
    func waitForSyncCycle(after index: Int, timeout: TimeInterval = 40) async -> Bool {
        await eventually(timeout: timeout) {
            let tail = Array(self.recorder.statuses.dropFirst(index))
            guard let started = tail.firstIndex(where: { $0.folders.first?.state == .syncing }) else { return false }
            return tail[started...].contains { $0.folders.first?.state == .synced }
        }
    }
}

private func eventually(timeout: TimeInterval = 30, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(250))
    }
    return await condition()
}

/// Namnen i en mapp, sorterade, utan systemfiler som Spotlight lägger på en ny volym.
private func entries(_ dir: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { ![".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems", ".DS_Store"].contains($0) }
        .sorted()
}

private func text(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

private func bytes(_ names: [String]) -> [[UInt8]] { names.map { Array($0.utf8) } }

private func withRig(_ body: (Rig) async throws -> Void) async throws {
    let rig = try Rig()
    var failure: (any Error)?
    do { try await body(rig) } catch { failure = error }
    let problems = await rig.tearDown()
    #expect(problems.isEmpty, "\(problems)")
    if let failure { throw failure }
}

@Suite(.serialized, .enabled(if: DiskImageEnvironment.isEnabled, "Kräver FILSYNK_DISK_IMAGE_TESTS=1"))
struct DiskImageTests {
    /// Monterar en ny avbild, tar mappen `Backup` i bruk och startar motorn.
    private func startOnNewImage(_ rig: Rig, _ format: DiskImageFormat) async throws -> (AttachedImage, String) {
        let image = try await rig.attach(try await rig.makeImage(format))
        let volume = try #require(rig.volume(of: image), "SystemVolumeMonitor ser inte avbilden vid \(image.mountPath)")
        #expect(volume.format == (format == .apfs ? .apfs : .exfat), "format \(volume.format)")
        #expect(!volume.isSystem)
        #expect(!(volume.uuid ?? "").isEmpty, "volymen saknar id")
        let config = try rig.configure(Config(server: ""), image: image)
        await rig.startEngine(config)
        let backup = URL(fileURLWithPath: volume.mountPath).appendingPathComponent("Backup").path
        return (image, backup)
    }

    /// Ny fil, överskriven fil och raderad fil, utan något anrop till syncNow.
    private func overwriteAndDelete(_ format: DiskImageFormat) async throws {
        try await withRig { rig in
            let (_, backup) = try await startOnNewImage(rig, format)

            try rig.write("prov.txt", "v1")
            let arrived = await eventually { text(backup + "/prov.txt") == "v1" }
            #expect(arrived, "prov.txt kom inte fram; status \(String(describing: rig.recorder.lastState))")
            try #require(arrived)

            try rig.write("prov.txt", "v2-längre")
            #expect(await eventually { text(backup + "/prov.txt") == "v2-längre" })
            #expect(await eventually { entries(backup + "/Raderat").count == 1 })
            let afterOverwrite = entries(backup + "/Raderat")
            #expect(afterOverwrite.compactMap { text(backup + "/Raderat/\($0)/prov.txt") } == ["v1"],
                    "Raderat efter överskrivning: \(afterOverwrite)")
            let stamp = try Regex(#"^\d{4}-\d{2}-\d{2}_\d{6}$"#)
            for dir in afterOverwrite { #expect(dir.wholeMatch(of: stamp) != nil, "tidsstämpel \(dir)") }

            rig.remove("prov.txt")
            #expect(await eventually { !FileManager.default.fileExists(atPath: backup + "/prov.txt") })
            #expect(await eventually { entries(backup + "/Raderat").count == 2 })
            let afterDelete = entries(backup + "/Raderat")
            let contents = Set(afterDelete.compactMap { text(backup + "/Raderat/\($0)/prov.txt") })
            #expect(contents == ["v1", "v2-längre"], "Raderat efter radering: \(afterDelete)")

            #expect(await eventually { rig.recorder.lastState == .synced })
            #expect(rig.recorder.notices.isEmpty, "notiser: \(rig.recorder.notices)")
            #expect(rig.recorder.errors.isEmpty, "fel i raden: \(rig.recorder.errors)")
        }
    }

    @Test(.timeLimit(.minutes(3))) func syncsToAPFSImage() async throws {
        try await overwriteAndDelete(.apfs)
    }

    @Test(.timeLimit(.minutes(3))) func deletedAndOverwrittenOnExFAT() async throws {
        try await overwriteAndDelete(.exfat)
    }

    @Test(.timeLimit(.minutes(3))) func swedishNamesAreStableOnExFAT() async throws {
        try await withRig { rig in
            let (_, backup) = try await startOnNewImage(rig, .exfat)

            let rootFile = "Åäö-fil.txt".precomposedStringWithCanonicalMapping
            let folder = "Varumärke".precomposedStringWithCanonicalMapping
            let inner = ["Räksmörgås.txt", "Ärenden och Åtgärder.txt"].map { $0.precomposedStringWithCanonicalMapping }
            try rig.writeRaw(rootFile, "rot")
            for name in inner { try rig.writeRaw("\(folder)/\(name)", "inne") }

            @Sendable func counts(_ dir: String, _ wanted: String) -> Int {
                entries(dir).filter { $0.precomposedStringWithCanonicalMapping == wanted }.count
            }
            @Sendable func complete() -> Bool {
                counts(backup, rootFile) == 1 && counts(backup, folder) == 1
                    && entries(backup + "/" + (entries(backup).first { $0.precomposedStringWithCanonicalMapping == folder } ?? "-"))
                        .count == inner.count
            }
            let arrived = await eventually { complete() }
            let listing = entries(backup)
            #expect(arrived, "filerna kom inte fram; \(bytes(listing)); status \(String(describing: rig.recorder.lastState))")
            try #require(arrived)

            // Låt motorn bli stilla och tvinga sedan en synk till.
            #expect(await eventually { rig.recorder.lastState == .synced })
            try await Task.sleep(for: .seconds(3))
            let mark = rig.recorder.statuses.count
            await rig.engine?.syncNow()
            #expect(await rig.waitForSyncCycle(after: mark), "syncNow gav ingen synkcykel")

            let after = entries(backup)
            #expect(!after.contains("Raderat"), "Raderat finns på disken: \(bytes(after))")
            #expect(counts(backup, rootFile) == 1, "rotfilen: \(bytes(after))")
            #expect(counts(backup, folder) == 1, "mappen: \(bytes(after))")
            let folderOnDisk = try #require(after.first { $0.precomposedStringWithCanonicalMapping == folder })
            let innerOnDisk = entries(backup + "/" + folderOnDisk)
            #expect(innerOnDisk.count == inner.count, "filerna i mappen: \(bytes(innerOnDisk))")
            for name in inner { #expect(counts(backup + "/" + folderOnDisk, name) == 1, "\(bytes(innerOnDisk))") }
            #expect(rig.recorder.errors.isEmpty, "fel i raden: \(rig.recorder.errors)")
        }
    }

    @Test(.timeLimit(.minutes(3))) func symbolicLinkSurvivesOnExFAT() async throws {
        try await withRig { rig in
            let (_, backup) = try await startOnNewImage(rig, .exfat)

            try rig.write("mal.txt", "innehåll")
            try FileManager.default.createSymbolicLink(
                atPath: rig.source.path + "/lank", withDestinationPath: "mal.txt")
            #expect(await eventually { text(backup + "/mal.txt") == "innehåll" })
            #expect(await eventually { rig.recorder.lastState == .synced })

            let mark = rig.recorder.statuses.count
            await rig.engine?.syncNow()
            #expect(await rig.waitForSyncCycle(after: mark), "syncNow gav ingen synkcykel")

            #expect(rig.recorder.errors.isEmpty, "fel i raden: \(rig.recorder.errors)")
            #expect(rig.recorder.lastState == .synced, "status \(String(describing: rig.recorder.lastState))")
            #expect(!FileManager.default.fileExists(atPath: backup + "/Raderat"),
                    "något flyttades till Raderat: \(entries(backup + "/Raderat"))")
            #expect(text(backup + "/mal.txt") == "innehåll")
            // Länken är kvar på Macen och är en länk också på disken.
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: rig.source.path + "/lank")) == "mal.txt")
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: backup + "/lank")) == "mal.txt",
                    "på disken: \(entries(backup))")
        }
    }

    @Test(.timeLimit(.minutes(5)), arguments: [DiskImageFormat.apfs, .exfat])
    func catchesUpWhenImageIsAttachedAgain(_ format: DiskImageFormat) async throws {
        try await withRig { rig in
            let (image, backup) = try await startOnNewImage(rig, format)
            try rig.write("ett.txt", "1")
            #expect(await eventually { text(backup + "/ett.txt") == "1" })
            #expect(await eventually { rig.recorder.lastState == .synced })
            let idBefore = rig.volume(of: image)?.uuid

            try await rig.detach(image)
            // Beroende av riktiga avmonteringsmeddelanden: raden ska bli "ej ansluten".
            let gone = await eventually { rig.recorder.lastState == .notConnected }
            #expect(gone, "raden blev inte .notConnected; status \(String(describing: rig.recorder.lastState))")

            try rig.write("ett.txt", "1 ändrad")
            try rig.write("tva.txt", "2")
            try await Task.sleep(for: .seconds(3))

            // Beroende av riktiga monteringsmeddelanden: ingen synk begärs härifrån.
            let again = try await rig.attach(image.file)
            let volume = try #require(rig.volume(of: again), "avbilden syns inte efter ny montering")
            #expect(volume.uuid == idBefore, "volym-id före \(String(describing: idBefore)) efter \(String(describing: volume.uuid))")
            let newBackup = URL(fileURLWithPath: volume.mountPath).appendingPathComponent("Backup").path
            let arrived = await eventually {
                text(newBackup + "/ett.txt") == "1 ändrad" && text(newBackup + "/tva.txt") == "2"
            }
            #expect(arrived, "ändringarna kom inte fram; \(entries(newBackup)); status \(String(describing: rig.recorder.lastState))")
            #expect(entries(newBackup + "/Raderat").count == 1)
            #expect(rig.recorder.errors.isEmpty, "fel i raden: \(rig.recorder.errors)")
        }
    }

    @Test(.timeLimit(.minutes(5))) func otherImageWithSameNameTriggersNothing() async throws {
        try await withRig { rig in
            let (first, backup) = try await startOnNewImage(rig, .apfs)
            try rig.write("a.txt", "a")
            #expect(await eventually { text(backup + "/a.txt") == "a" })
            #expect(await eventually { rig.recorder.lastState == .synced })

            // En andra avbild med samma volymnamn men eget id.
            let second = try await rig.attach(try await rig.makeImage(.apfs))
            let firstVolume = try #require(rig.volume(of: first))
            let secondVolume = try #require(rig.volume(of: second))
            #expect(firstVolume.name == secondVolume.name)
            #expect(firstVolume.uuid != secondVolume.uuid, "samma id på två avbilder: \(String(describing: firstVolume.uuid))")

            // Ett ändrat innehåll hos källan synkas till den första, inte till den andra.
            try rig.write("b.txt", "b")
            #expect(await eventually { text(backup + "/b.txt") == "b" })
            #expect(entries(second.mountPath).isEmpty, "på den andra avbilden: \(entries(second.mountPath))")

            // När den första är borta nås ingenting; den andra får fortfarande inget.
            try await rig.detach(first)
            #expect(await eventually { rig.recorder.lastState == .notConnected },
                    "status \(String(describing: rig.recorder.lastState))")
            try rig.write("c.txt", "c")
            try await Task.sleep(for: .seconds(4))
            #expect(entries(second.mountPath).isEmpty, "på den andra avbilden: \(entries(second.mountPath))")
            #expect(rig.recorder.lastState == .notConnected, "status \(String(describing: rig.recorder.lastState))")
            #expect(rig.recorder.errors.isEmpty, "fel i raden: \(rig.recorder.errors)")
        }
    }

    @Test(.timeLimit(.minutes(5)), arguments: [DiskImageFormat.apfs, .exfat])
    func detachDuringIdleIsNotAnError(_ format: DiskImageFormat) async throws {
        try await withRig { rig in
            let (image, backup) = try await startOnNewImage(rig, format)
            try rig.write("ett.txt", "1")
            #expect(await eventually { text(backup + "/ett.txt") == "1" })
            #expect(await eventually { rig.recorder.lastState == .synced })
            try await Task.sleep(for: .seconds(2))

            try await rig.detach(image)
            // Längre än tiden som en nekad utmatning väntar, så att också den vägen syns.
            try await Task.sleep(for: .seconds(5))
            #expect(rig.recorder.lastState == .notConnected, "status \(String(describing: rig.recorder.lastState))")
            #expect(rig.recorder.errors.isEmpty, "fel i raden: \(rig.recorder.errors)")
            #expect(rig.recorder.notices.isEmpty, "notiser: \(rig.recorder.notices)")
        }
    }
}
