import Foundation
import Testing
@testable import FilsynkCore

@Suite struct NoticePolicyTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeSchedule() -> FolderSchedule {
        FolderSchedule(quiet: 60, maxWait: 600)
    }

    private func finishSync(_ schedule: inout FolderSchedule, _ outcome: SyncOutcome, at date: Date) {
        schedule.syncStarted(at: date)
        schedule.syncFinished(outcome, at: date)
    }

    @Test func authDeniedNotifiesOnceUntilSuccess() {
        var policy = NoticePolicy()
        var schedule = makeSchedule()
        finishSync(&schedule, .authDenied, at: t0)
        #expect(policy.evaluate(folder: "~/Sync", schedule: schedule, now: t0) == [.authDenied(folder: "~/Sync")])
        #expect(policy.evaluate(folder: "~/Sync", schedule: schedule, now: t0.addingTimeInterval(60)) == [])

        finishSync(&schedule, .success, at: t0.addingTimeInterval(120))
        #expect(policy.evaluate(folder: "~/Sync", schedule: schedule, now: t0.addingTimeInterval(120)) == [])

        finishSync(&schedule, .authDenied, at: t0.addingTimeInterval(240))
        #expect(policy.evaluate(folder: "~/Sync", schedule: schedule, now: t0.addingTimeInterval(240)) == [.authDenied(folder: "~/Sync")])
    }

    @Test func thirdFailureNotifiesExactlyOnce() {
        var policy = NoticePolicy()
        var schedule = makeSchedule()
        finishSync(&schedule, .failed("x"), at: t0)
        #expect(policy.evaluate(folder: "~/Sync", schedule: schedule, now: t0) == [])
        finishSync(&schedule, .failed("x"), at: t0.addingTimeInterval(60))
        #expect(policy.evaluate(folder: "~/Sync", schedule: schedule, now: t0.addingTimeInterval(60)) == [])
        finishSync(&schedule, .failed("x"), at: t0.addingTimeInterval(120))
        let third = policy.evaluate(folder: "~/Sync", schedule: schedule, now: t0.addingTimeInterval(120))
        #expect(third == [.repeatedFailure(folder: "~/Sync", message: "x")])
        // Repeated periodic checks with the same schedule do not repeat the notice.
        #expect(policy.evaluate(folder: "~/Sync", schedule: schedule, now: t0.addingTimeInterval(130)) == [])
        finishSync(&schedule, .failed("x"), at: t0.addingTimeInterval(180))
        #expect(policy.evaluate(folder: "~/Sync", schedule: schedule, now: t0.addingTimeInterval(180)) == [])
    }

    @Test func firstFailureAfterThreeUnreachableNotifies() {
        var policy = NoticePolicy()
        var schedule = makeSchedule()
        for i in 0..<3 {
            finishSync(&schedule, .unreachable, at: t0.addingTimeInterval(Double(i)))
            #expect(policy.evaluate(folder: "~/Sync", schedule: schedule, now: t0.addingTimeInterval(Double(i))) == [])
        }
        finishSync(&schedule, .failed("Disken på servern är full"), at: t0.addingTimeInterval(10))
        #expect(policy.evaluate(folder: "~/Sync", schedule: schedule, now: t0.addingTimeInterval(10))
            == [.repeatedFailure(folder: "~/Sync", message: "Disken på servern är full")])
        // Once per series.
        finishSync(&schedule, .failed("Disken på servern är full"), at: t0.addingTimeInterval(20))
        #expect(policy.evaluate(folder: "~/Sync", schedule: schedule, now: t0.addingTimeInterval(20)) == [])
    }

    @Test func newFailureSeriesNotifiesAgain() {
        var policy = NoticePolicy()
        var schedule = makeSchedule()
        for i in 0..<3 { finishSync(&schedule, .failed("x"), at: t0.addingTimeInterval(Double(i))) }
        #expect(policy.evaluate(folder: "~/Sync", schedule: schedule, now: t0).count == 1)
        finishSync(&schedule, .success, at: t0.addingTimeInterval(10))
        #expect(policy.evaluate(folder: "~/Sync", schedule: schedule, now: t0.addingTimeInterval(10)) == [])
        for i in 0..<3 { finishSync(&schedule, .failed("y"), at: t0.addingTimeInterval(20 + Double(i))) }
        #expect(policy.evaluate(folder: "~/Sync", schedule: schedule, now: t0.addingTimeInterval(30))
            == [.repeatedFailure(folder: "~/Sync", message: "y")])
    }

    @Test func unreachableAloneNeverNotifiesBefore24h() {
        var policy = NoticePolicy()
        var schedule = makeSchedule()
        schedule.changeDetected(at: t0)
        // 20 attempts, one per hour: the last runs 19 h after dirtySince.
        var now = t0
        for _ in 0..<20 {
            finishSync(&schedule, .unreachable, at: now)
            #expect(policy.evaluate(folder: "~/Sync", schedule: schedule, now: now) == [])
            now = now.addingTimeInterval(3600)
        }
    }

    @Test func staleAfter24hOncePerDay() {
        var policy = NoticePolicy()
        var schedule = makeSchedule()
        schedule.changeDetected(at: t0)
        let day: TimeInterval = 24 * 3600
        #expect(policy.evaluate(folder: "~/Sync", schedule: schedule, now: t0.addingTimeInterval(day)) == [])
        let first = t0.addingTimeInterval(day + 1)
        #expect(policy.evaluate(folder: "~/Sync", schedule: schedule, now: first) == [.stale(folder: "~/Sync")])
        #expect(policy.evaluate(folder: "~/Sync", schedule: schedule, now: first.addingTimeInterval(3600)) == [])
        #expect(policy.evaluate(folder: "~/Sync", schedule: schedule, now: first.addingTimeInterval(day)) == [.stale(folder: "~/Sync")])
    }

    @Test func foldersAreTrackedIndependently() {
        var policy = NoticePolicy()
        var schedule = makeSchedule()
        finishSync(&schedule, .authDenied, at: t0)
        #expect(policy.evaluate(folder: "~/A", schedule: schedule, now: t0) == [.authDenied(folder: "~/A")])
        #expect(policy.evaluate(folder: "~/B", schedule: schedule, now: t0) == [.authDenied(folder: "~/B")])
    }

    @Test func noticeTexts() {
        let auth = Notice.authDenied(folder: "~/Sync")
        #expect(auth.title == "FileSync: inloggningen nekades")
        #expect(auth.body == "Servern accepterar inte nyckeln. Öppna Inställningar och testa anslutningen.")
        let failure = Notice.repeatedFailure(folder: "~/Sync", message: "Disken på servern är full")
        #expect(failure.title == "FileSync: synken misslyckas")
        #expect(failure.body == "~/Sync: Disken på servern är full")
        let stale = Notice.stale(folder: "~/Sync")
        #expect(stale.title == "FileSync: osynkade ändringar")
        #expect(stale.body == "~/Sync har inte kunnat säkerhetskopieras på över ett dygn.")
    }

    @Test func noStaleNoticeForDiskDestination() {
        var policy = NoticePolicy()
        var schedule = makeSchedule()
        schedule.changeDetected(at: t0)
        let later = t0.addingTimeInterval(2 * 24 * 3600)
        #expect(policy.evaluate(folder: "~/Sync → HDD: Filsynk/Sync", schedule: schedule, now: later, allowStale: false) == [])
        // Other notices still apply.
        finishSync(&schedule, .failed("x"), at: later)
        finishSync(&schedule, .failed("x"), at: later)
        finishSync(&schedule, .failed("x"), at: later)
        #expect(policy.evaluate(folder: "~/Sync → HDD: Filsynk/Sync", schedule: schedule, now: later, allowStale: false)
            == [.repeatedFailure(folder: "~/Sync → HDD: Filsynk/Sync", message: "x")])
        #expect(policy.evaluate(folder: "~/Sync → Server: ~/Sync", schedule: schedule, now: later, allowStale: true)
            .contains(.stale(folder: "~/Sync → Server: ~/Sync")))
    }
}
