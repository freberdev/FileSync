import Foundation
import Testing
@testable import FilsynkCore

@Suite struct StatusPresentationTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A date whose UTC wall clock reads the given time (epoch day 20_000 = 2024-10-04).
    private func utcTime(hour: Int, minute: Int) -> Date {
        let day: TimeInterval = 20_000 * 86_400
        return Date(timeIntervalSince1970: day + TimeInterval(hour * 3600 + minute * 60))
    }

    private func schedule() -> FolderSchedule { FolderSchedule(quiet: 60, maxWait: 600) }

    private func status(_ state: FolderState, lastSuccess: Date? = nil, paused: Bool = false, configError: String? = nil) -> EngineStatus {
        EngineStatus(folders: [FolderStatus(path: "~/Sync", destination: nil, state: state, lastSuccess: lastSuccess)],
                     isPaused: paused, configError: configError)
    }

    @Test func folderLabelForEachState() {
        func label(_ state: FolderState, _ last: Date? = nil) -> String {
            StatusPresentation.folderLabel(FolderStatus(path: "~/Sync", destination: nil, state: state, lastSuccess: last), timeZone: utc)
        }
        #expect(label(.synced, utcTime(hour: 9, minute: 5)) == "✓ 09:05")
        #expect(label(.synced) == "✓")
        #expect(label(.syncing) == "Synkar…")
        #expect(label(.pending) == "Väntar")
        #expect(label(.waitingForServer) == "Väntar på servern")
        #expect(label(.error("x")) == "Fel")
        #expect(label(.notConfigured) == "Inte inställd")
    }

    @Test func headlineForEachOverallState() {
        // 14:32 UTC on some day
        let at1432 = utcTime(hour: 14, minute: 32)
        let synced = status(.synced, lastSuccess: at1432)
        #expect(StatusPresentation.headline(synced, timeZone: utc) == "Allt synkat · 14:32")
        #expect(StatusPresentation.symbolName(synced.overall) == "checkmark.circle")

        #expect(StatusPresentation.headline(status(.syncing), timeZone: utc) == "Synkar…")
        #expect(StatusPresentation.symbolName(.syncing) == "arrow.triangle.2.circlepath")

        #expect(StatusPresentation.headline(status(.pending), timeZone: utc) == "Ändringar väntar")
        #expect(StatusPresentation.symbolName(.pending) == "hourglass")

        #expect(StatusPresentation.headline(status(.waitingForServer), timeZone: utc) == "Väntar på servern")
        #expect(StatusPresentation.symbolName(.waitingForServer) == "clock.arrow.circlepath")

        #expect(StatusPresentation.headline(status(.error("Disken är full")), timeZone: utc) == "Fel: Disken är full")
        #expect(StatusPresentation.symbolName(.error("x")) == "exclamationmark.triangle")

        #expect(StatusPresentation.headline(status(.synced, paused: true), timeZone: utc) == "Pausad")
        #expect(StatusPresentation.symbolName(.paused) == "pause.circle")

        #expect(StatusPresentation.headline(.empty, timeZone: utc) == "Inte inställd")
        #expect(StatusPresentation.symbolName(.notConfigured) == "gearshape")
    }

    @Test func headlineUsesGivenTimeZoneAnd24HourClock() {
        let at1432 = utcTime(hour: 14, minute: 32)
        let plus2 = TimeZone(secondsFromGMT: 2 * 3600)!
        #expect(StatusPresentation.headline(status(.synced, lastSuccess: at1432), timeZone: plus2) == "Allt synkat · 16:32")
    }

    @Test func syncedHeadlineUsesLatestSuccess() {
        let early = utcTime(hour: 8, minute: 0)
        let late = early.addingTimeInterval(3 * 3600)
        let s = EngineStatus(folders: [
            FolderStatus(path: "~/A", destination: nil, state: .synced, lastSuccess: late),
            FolderStatus(path: "~/B", destination: nil, state: .synced, lastSuccess: early),
        ], isPaused: false, configError: nil)
        #expect(StatusPresentation.headline(s, timeZone: utc) == "Allt synkat · 11:00")
    }

    @Test func waitingForQuietPeriodDoesNotLookLikeARunningSync() {
        #expect(StatusPresentation.symbolName(.pending) != StatusPresentation.symbolName(.syncing))
    }

    @Test func overallPrecedence() {
        let errAndSyncing = EngineStatus(folders: [
            FolderStatus(path: "~/A", destination: nil, state: .syncing, lastSuccess: nil),
            FolderStatus(path: "~/B", destination: nil, state: .error("x"), lastSuccess: nil),
        ], isPaused: false, configError: nil)
        #expect(errAndSyncing.overall == .error("x"))

        var paused = errAndSyncing
        paused.folders = [FolderStatus(path: "~/A", destination: nil, state: .syncing, lastSuccess: nil)]
        paused.isPaused = true
        #expect(paused.overall == .paused)

        var cfg = paused
        cfg.configError = "Kunde inte läsa konfigurationen"
        #expect(cfg.overall == .error("Kunde inte läsa konfigurationen"))

        let order = EngineStatus(folders: [
            FolderStatus(path: "~/A", destination: nil, state: .pending, lastSuccess: nil),
            FolderStatus(path: "~/B", destination: nil, state: .waitingForServer, lastSuccess: nil),
        ], isPaused: false, configError: nil)
        #expect(order.overall == .waitingForServer)

        // One folder not set up outweighs everything but a config error.
        var partly = EngineStatus(folders: [
            FolderStatus(path: "~/A", destination: nil, state: .synced, lastSuccess: t0),
            FolderStatus(path: "~/B", destination: nil, state: .notConfigured, lastSuccess: nil),
        ], isPaused: false, configError: nil)
        #expect(partly.overall == .notConfigured)
        #expect(StatusPresentation.headline(partly, timeZone: utc) == "Inte inställd")
        partly.folders[0].state = .error("x")
        partly.isPaused = true
        #expect(partly.overall == .notConfigured)
        partly.configError = "Kunde inte läsa konfigurationen"
        #expect(partly.overall == .error("Kunde inte läsa konfigurationen"))
    }

    @Test func noReadyFoldersIsNotConfigured() {
        #expect(EngineStatus.empty.overall == .notConfigured)
        #expect(status(.notConfigured, paused: true).overall == .notConfigured)
    }

    @Test func folderStateMapping() {
        var s = schedule()
        #expect(StatusPresentation.folderState(ready: false, schedule: s) == .notConfigured)
        #expect(StatusPresentation.folderState(ready: true, schedule: s) == .synced)
        s.changeDetected(at: t0)
        #expect(StatusPresentation.folderState(ready: true, schedule: s) == .pending)
        s.syncStarted(at: t0)
        #expect(StatusPresentation.folderState(ready: true, schedule: s) == .syncing)
        s.syncFinished(.unreachable, at: t0)
        #expect(StatusPresentation.folderState(ready: true, schedule: s) == .waitingForServer)
        s.syncStarted(at: t0)
        s.syncFinished(.authDenied, at: t0)
        #expect(StatusPresentation.folderState(ready: true, schedule: s) == .error("Inloggningen nekades"))
        s.syncStarted(at: t0)
        s.syncFinished(.failed("boom"), at: t0)
        #expect(StatusPresentation.folderState(ready: true, schedule: s) == .error("boom"))
        s.syncStarted(at: t0)
        s.syncFinished(.success, at: t0)
        #expect(StatusPresentation.folderState(ready: true, schedule: s) == .synced)
    }

    @Test func displayPathAbbreviatesHome() {
        #expect(StatusPresentation.displayPath("/Users/x/Sync", home: "/Users/x") == "~/Sync")
        #expect(StatusPresentation.displayPath("/Users/x", home: "/Users/x") == "~")
        #expect(StatusPresentation.displayPath("/Users/xy/Sync", home: "/Users/x") == "/Users/xy/Sync")
        #expect(StatusPresentation.displayPath("/Volumes/Data", home: "/Users/x") == "/Volumes/Data")
    }
    @Test func destinationLabels() {
        #expect(StatusPresentation.destinationLabel(.server(path: "/home/u/Filsynk/A"), serverHome: "/home/u") == "Server: ~/Filsynk/A")
        #expect(StatusPresentation.destinationLabel(.disk(.init(volumeUUID: "U1", volumeName: "HDD", path: "Filsynk/A")), serverHome: "") == "HDD: Filsynk/A")
        // Without a known home the path is shown as it is.
        #expect(StatusPresentation.destinationLabel(.server(path: "/srv/A"), serverHome: "") == "Server: /srv/A")
    }

    @Test func rowIdentityIsFolderAndDestination() {
        let disk = Destination.disk(.init(volumeUUID: "U1", volumeName: "HDD", path: "Filsynk/A"))
        let server = FolderStatus(path: "/a", destination: .server(path: "/srv/a"), state: .synced, lastSuccess: nil)
        let onDisk = FolderStatus(path: "/a", destination: disk, state: .synced, lastSuccess: nil)
        #expect(server.id == "/a|server")
        #expect(onDisk.id == "/a|" + disk.id)
        #expect(server.destinationID == "server")
    }

    @Test func notConnectedLabels() {
        let disk = Destination.disk(.init(volumeUUID: "U1", volumeName: "HDD", path: "Filsynk/A"))
        // 2024-10-04 23:30 UTC is already 2024-10-05 in UTC+2.
        let late = utcTime(hour: 23, minute: 30)
        let seen = FolderStatus(path: "/a", destination: disk, state: .notConnected, lastSuccess: late)
        #expect(StatusPresentation.folderLabel(seen, timeZone: utc) == "Inte inkopplad · senast 2024-10-04")
        #expect(StatusPresentation.folderLabel(seen, timeZone: TimeZone(secondsFromGMT: 7200)!) == "Inte inkopplad · senast 2024-10-05")
        let never = FolderStatus(path: "/a", destination: disk, state: .notConnected, lastSuccess: nil)
        #expect(StatusPresentation.folderLabel(never, timeZone: utc) == "Inte inkopplad · aldrig synkad")
    }

    @Test func notConnectedHeadlineAndSymbol() {
        let disk = Destination.disk(.init(volumeUUID: "U1", volumeName: "HDD", path: "Filsynk/A"))
        func row(_ state: FolderState, _ destination: Destination? = nil, last: Date? = nil) -> FolderStatus {
            FolderStatus(path: "/a", destination: destination ?? disk, state: state, lastSuccess: last)
        }
        let absent = EngineStatus(folders: [row(.notConnected), row(.notConnected)], isPaused: false, configError: nil)
        #expect(absent.overall == .notConnected)
        #expect(StatusPresentation.headline(absent, timeZone: utc) == "Disken är inte inkopplad")
        #expect(StatusPresentation.symbolName(.notConnected) == "externaldrive.badge.xmark")

        // Rows that are not connected are left out when anything else takes part.
        let at1432 = utcTime(hour: 14, minute: 32)
        let mixed = EngineStatus(folders: [row(.synced, .server(path: "/srv/a"), last: at1432), row(.notConnected)],
                                 isPaused: false, configError: nil)
        #expect(mixed.overall == .synced)
        #expect(StatusPresentation.headline(mixed, timeZone: utc) == "Allt synkat · 14:32")
        var pending = mixed
        pending.folders[0].state = .pending
        #expect(pending.overall == .pending)
        var paused = absent
        paused.isPaused = true
        #expect(paused.overall == .paused)
        // A folder that is not set up still decides.
        let unset = EngineStatus(folders: [row(.notConfigured, .server(path: "~/a")), row(.notConnected)],
                                 isPaused: false, configError: nil)
        #expect(unset.overall == .notConfigured)
    }
}
