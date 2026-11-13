import Foundation

public struct ProcessResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) async throws -> ProcessResult
}

/// Runs a child process, draining stdout and stderr concurrently while it runs.
/// Cancelling the calling task terminates the child.
public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
        let job = Job(executable: executable, arguments: arguments)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job.start(continuation)
            }
        } onCancel: {
            job.cancel()
        }
    }
}

private final class Job: @unchecked Sendable {
    private let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var running = false
    private var cancelled = false

    init(executable: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe
    }

    func start(_ continuation: CheckedContinuation<ProcessResult, any Error>) {
        let group = DispatchGroup()
        group.enter(); group.enter(); group.enter()

        drain(outPipe, group: group) { [self] in stdout.append($0) }
        drain(errPipe, group: group) { [self] in stderr.append($0) }
        process.terminationHandler = { _ in group.leave() }

        lock.lock()
        do {
            try process.run()
            running = true
            let shouldTerminate = cancelled
            lock.unlock()
            if shouldTerminate { process.terminate() }
        } catch {
            lock.unlock()
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            continuation.resume(throwing: error)
            return
        }

        group.notify(queue: .global()) { [self] in
            lock.lock()
            let result = ProcessResult(
                exitCode: process.terminationStatus,
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self))
            lock.unlock()
            continuation.resume(returning: result)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let shouldTerminate = running && process.isRunning
        lock.unlock()
        if shouldTerminate { process.terminate() }
    }

    private func drain(_ pipe: Pipe, group: DispatchGroup, append: @escaping @Sendable (Data) -> Void) {
        pipe.fileHandleForReading.readabilityHandler = { [lock] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                lock.lock(); append(data); lock.unlock()
            }
        }
    }
}
