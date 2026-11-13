import Foundation
import Testing
@testable import FilsynkCore

@Suite struct FolderScheduleTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private func t(_ n: TimeInterval) -> Date { base.addingTimeInterval(n) }
    private func makeSchedule() -> FolderSchedule { FolderSchedule(quiet: 60, maxWait: 600) }

    @Test func cleanScheduleHasNothingToDo() {
        let s = makeSchedule()
        #expect(s.nextFireDate() == nil)
        #expect(!s.isDirty)
    }

    @Test func firesQuietSecondsAfterLastChange() {
        var s = makeSchedule()
        s.changeDetected(at: t(0)); s.changeDetected(at: t(30))
        #expect(s.nextFireDate() == t(90))
    }

    @Test func continuousChangesFireAtMaxWait() {
        var s = makeSchedule()
        for i in stride(from: 0, through: 590, by: 10) { s.changeDetected(at: t(TimeInterval(i))) }
        #expect(s.nextFireDate() == t(600))
    }

    @Test func nothingScheduledWhileSyncing() {
        var s = makeSchedule()
        s.changeDetected(at: t(0)); s.syncStarted(at: t(60))
        #expect(s.isSyncing)
        #expect(!s.isDirty)
        #expect(s.nextFireDate() == nil)
    }

    @Test func changeDuringSyncRunsAgainAfterwards() {
        var s = makeSchedule()
        s.changeDetected(at: t(0)); s.syncStarted(at: t(60))
        s.changeDetected(at: t(65))
        #expect(s.nextFireDate() == nil)
        s.syncFinished(.success, at: t(70))
        #expect(s.isDirty)
        #expect(s.nextFireDate() == t(125))
        #expect(s.dirtySince == t(65))
    }

    @Test func successClearsEverything() {
        var s = makeSchedule()
        s.changeDetected(at: t(0)); s.syncStarted(at: t(60)); s.syncFinished(.success, at: t(65))
        #expect(!s.isDirty)
        #expect(!s.isSyncing)
        #expect(s.dirtySince == nil)
        #expect(s.failureCount == 0)
        #expect(s.lastSuccess == t(65))
        #expect(s.lastOutcome == .success)
        #expect(s.nextFireDate() == nil)
    }

    @Test func backoffSequenceThenStaysAt900() {
        var s = makeSchedule()
        s.changeDetected(at: t(0))
        var now = s.nextFireDate()!
        var waits: [TimeInterval] = []
        for _ in 0..<5 {
            s.syncStarted(at: now)
            let finish = now.addingTimeInterval(1)
            s.syncFinished(.unreachable, at: finish)
            let next = s.nextFireDate()!
            waits.append(next.timeIntervalSince(finish))
            now = next
        }
        #expect(waits == [60, 120, 300, 900, 900])
        #expect(s.failureCount == 5)
    }

    @Test func otherFailuresAlsoCountAndBackOff() {
        var s = makeSchedule()
        s.changeDetected(at: t(0)); s.syncStarted(at: t(60))
        s.syncFinished(.failed("x"), at: t(61))
        #expect(s.failureCount == 1)
        s.syncStarted(at: t(121)); s.syncFinished(.unreachable, at: t(122))
        #expect(s.failureCount == 2)
        #expect(s.nextFireDate() == t(242))
        #expect(s.lastOutcome == .unreachable)
    }

    @Test func deniedLoginWaitsTheLongestBackoffStep() {
        var s = makeSchedule()
        s.changeDetected(at: t(0)); s.syncStarted(at: t(60))
        s.syncFinished(.authDenied, at: t(61))
        #expect(s.failureCount == 1)
        #expect(s.lastOutcome == .authDenied)
        #expect(s.nextFireDate() == t(961))
        // A user request still runs at once.
        s.requestImmediate(at: t(100))
        #expect(s.nextFireDate() == t(100))
    }

    @Test func retimedScheduleKeepsItsState() {
        var s = makeSchedule()
        s.changeDetected(at: t(0)); s.syncStarted(at: t(60)); s.syncFinished(.success, at: t(61))
        s.changeDetected(at: t(100))
        let r = s.retimed(quiet: 10, maxWait: 20, backoff: [5])
        #expect(r.lastSuccess == t(61))
        #expect(r.dirtySince == t(100))
        #expect(r.isDirty)
        #expect(r.nextFireDate() == t(110))
    }

    @Test func successResetsFailureCount() {
        var s = makeSchedule()
        s.changeDetected(at: t(0)); s.syncStarted(at: t(60)); s.syncFinished(.unreachable, at: t(61))
        s.syncStarted(at: t(121)); s.syncFinished(.success, at: t(125))
        #expect(s.failureCount == 0)
        #expect(!s.isDirty)
        #expect(s.nextFireDate() == nil)
    }

    @Test func failureKeepsOriginalDirtySince() {
        var s = makeSchedule()
        s.changeDetected(at: t(0)); s.syncStarted(at: t(60)); s.syncFinished(.unreachable, at: t(61))
        #expect(s.dirtySince == t(0))
        #expect(s.isDirty)
    }

    @Test func changeDuringBackoffDoesNotFireEarlier() {
        var s = makeSchedule()
        s.changeDetected(at: t(0)); s.syncStarted(at: t(60)); s.syncFinished(.unreachable, at: t(61))
        s.changeDetected(at: t(62))
        #expect(s.nextFireDate() == t(121))
    }

    @Test func requestImmediateCancelsBackoff() {
        var s = makeSchedule()
        s.changeDetected(at: t(0)); s.syncStarted(at: t(60)); s.syncFinished(.unreachable, at: t(61))
        s.requestImmediate(at: t(70))
        #expect(s.nextFireDate() == t(70))
    }

    @Test func requestImmediateOnCleanScheduleStillSyncs() {
        var s = makeSchedule()
        s.requestImmediate(at: t(5))
        #expect(s.isDirty)
        #expect(s.dirtySince == t(5))
        #expect(s.nextFireDate() == t(5))
    }

    @Test func requestImmediateDuringSyncFiresAfterFinish() {
        var s = makeSchedule()
        s.changeDetected(at: t(0)); s.syncStarted(at: t(60))
        s.requestImmediate(at: t(65))
        #expect(s.nextFireDate() == nil)
        s.syncFinished(.success, at: t(70))
        #expect(s.isDirty)
        #expect(s.nextFireDate() == t(65))
    }

    @Test func maxWaitCountsFromFirstChangeSinceLastStart() {
        var s = makeSchedule()
        s.changeDetected(at: t(0)); s.syncStarted(at: t(60)); s.syncFinished(.success, at: t(61))
        s.changeDetected(at: t(100)); s.changeDetected(at: t(150))
        #expect(s.nextFireDate() == t(210))
    }
}
