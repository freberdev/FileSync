import Testing
import Foundation
@testable import FilsynkCore

struct ProcessRunnerTests {
    @Test func capturesExitCodeAndStreams() async throws {
        let r = try await SystemProcessRunner().run("/bin/sh", ["-c", "echo out; echo err 1>&2; exit 3"])
        #expect(r == ProcessResult(exitCode: 3, stdout: "out\n", stderr: "err\n"))
    }

    @Test(.timeLimit(.minutes(1))) func largeOutputDoesNotDeadlock() async throws {
        let r = try await SystemProcessRunner().run("/bin/sh", ["-c", "yes | head -c 2000000; yes | head -c 2000000 1>&2"])
        #expect(r.stdout.utf8.count == 2_000_000)
        #expect(r.stderr.utf8.count == 2_000_000)
    }

    @Test func missingExecutableThrows() async {
        await #expect(throws: (any Error).self) {
            try await SystemProcessRunner().run("/nonexistent/x", [])
        }
    }

    @Test(.timeLimit(.minutes(1))) func cancellingTheTaskTerminatesTheChild() async throws {
        let started = Date()
        let task = Task { try await SystemProcessRunner().run("/bin/sleep", ["30"]) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = try? await task.value
        #expect(Date().timeIntervalSince(started) < 10)
    }
}
