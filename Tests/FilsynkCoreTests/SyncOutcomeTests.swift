import Testing
@testable import FilsynkCore

@Suite struct SyncOutcomeTests {
    @Test func zeroAndVanishedAreSuccess() {
        #expect(OutcomeClassifier.classify(exitCode: 0, stderr: "") == .success)
        #expect(OutcomeClassifier.classify(exitCode: 24, stderr: "file has vanished") == .success)
    }

    @Test func measuredUnreachableOutput() {
        let stderr = """
        ssh: connect to host 192.0.2.1 port 22: Operation timed out
        rsync(1890): error: unexpected end of file
        """
        #expect(OutcomeClassifier.classify(exitCode: 255, stderr: stderr) == .unreachable)
    }

    @Test func measuredAuthDeniedOutput() {
        let stderr = """
        user@192.168.1.10: Permission denied (publickey,password).
        rsync(1895): error: unexpected end of file
        """
        #expect(OutcomeClassifier.classify(exitCode: 255, stderr: stderr) == .authDenied)
    }

    @Test func authWinsOverConnectionClosed() {
        let s = "u@h: Permission denied (publickey,password).\nrsync: connection unexpectedly closed"
        #expect(OutcomeClassifier.classify(exitCode: 255, stderr: s) == .authDenied)
    }

    @Test func filePermissionErrorIsNotAuthDenied() {
        let line = "rsync: send_files failed to open \"/a/x\": Permission denied (13)"
        #expect(OutcomeClassifier.classify(exitCode: 23, stderr: line) == .failed(line))
    }

    @Test func diskFull() {
        #expect(OutcomeClassifier.classify(exitCode: 12, stderr: "write failed: No space left on device (28)")
                == .failed("Disken på servern är full"))
    }

    @Test func unknownErrorWithEmptyStderr() {
        #expect(OutcomeClassifier.classify(exitCode: 1, stderr: "") == .failed("rsync avslutades med kod 1"))
    }

    @Test func longMessageIsTruncatedTo200() {
        let outcome = OutcomeClassifier.classify(exitCode: 1, stderr: String(repeating: "x", count: 500))
        #expect(outcome.message?.count == 200)
    }

    @Test func messagesAreSwedish() {
        #expect(SyncOutcome.success.message == nil)
        #expect(SyncOutcome.unreachable.message == "Servern nås inte")
        #expect(SyncOutcome.authDenied.message == "Inloggningen nekades")
        #expect(SyncOutcome.failed("x").message == "x")
    }

    @Test func lastNonEmptyLineIsUsed() {
        #expect(OutcomeClassifier.classify(exitCode: 1, stderr: "first\nsecond\n\n  \n")
                == .failed("second"))
    }
}
