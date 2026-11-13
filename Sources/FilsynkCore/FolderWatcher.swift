import CoreServices
import Foundation

public protocol FolderWatching: AnyObject, Sendable { func start(); func stop() }
public typealias WatcherFactory = @Sendable (_ path: String, _ onChange: @escaping @Sendable () -> Void) -> any FolderWatching

/// Watches a directory recursively with FSEvents and calls `onChange` once per event group.
/// The callback carries no information about which files changed.
public final class FolderWatcher: FolderWatching, @unchecked Sendable {
    /// Callback context. Owned by the watcher (strongly) and passed to the stream unretained, so
    /// the stream never keeps the watcher alive; `stop()` keeps it alive past any queued callback.
    private final class Context: @unchecked Sendable {  // isActive is queue-confined
        let onChange: @Sendable () -> Void
        var isActive = true  // only touched on `queue`
        init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    }

    private let path: String
    private let latency: TimeInterval
    private let onChange: @Sendable () -> Void
    // Serial queue: runs FSEvents callbacks and guards `stream` / `context`.
    private let queue = DispatchQueue(label: "dev.freber.filsynk.folderwatcher")
    private let queueKey = DispatchSpecificKey<Void>()
    private var stream: FSEventStreamRef?
    private var context: Context?

    public init(path: String, latency: TimeInterval = 1.0, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.latency = latency
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit { stop() }

    public func start() {
        onQueue {
            guard stream == nil else { return }
            let realPath = Self.realPath(of: path)
            let context = Context(onChange: onChange)
            var streamContext = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(context).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                guard let info else { return }
                let context = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue()
                if context.isActive { context.onChange() }
            }
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &streamContext,
                [realPath] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
            ) else { return }
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                return
            }
            self.stream = stream
            self.context = context
        }
    }

    /// After `stop()` returns, `onChange` is not called again (callbacks run on `queue`,
    /// and stop runs there synchronously).
    public func stop() {
        onQueue {
            let retiring = context
            retiring?.isActive = false
            context = nil
            if let stream {
                self.stream = nil
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            // A callback block may already be queued: keep the context alive until it has run.
            if let retiring { queue.async { withExtendedLifetime(retiring) {} } }
        }
    }

    /// Canonical path (resolves symlinks such as /tmp -> /private/tmp); the original on failure.
    private static func realPath(of path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Runs `body` on `queue`, directly if already there (e.g. `stop()` called from `onChange`).
    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { body() } else { queue.sync(execute: body) }
    }
}
