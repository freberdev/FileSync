import Foundation
import Network

public protocol NetworkMonitoring: AnyObject, Sendable {
    var isMetered: Bool { get }                               // dyr eller begränsad anslutning
    func start(onChange: @escaping @Sendable () -> Void)      // anropas när nätverket ändras
    func stop()
}

/// Network status from `NWPathMonitor`. The first path delivered at start only sets
/// `isMetered`; `onChange` is called for every later path update.
public final class SystemNetworkMonitor: NetworkMonitoring, @unchecked Sendable {
    private let lock = NSLock()  // guards `monitor`, `metered`, `seenFirstUpdate`
    private var monitor: NWPathMonitor?
    private var metered = false
    private var seenFirstUpdate = false
    private let queue = DispatchQueue(label: "dev.freber.filsynk.networkmonitor")

    public init() {}

    deinit { monitor?.cancel() }

    public var isMetered: Bool {
        lock.lock(); defer { lock.unlock() }
        return metered
    }

    public func start(onChange: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard monitor == nil else { return }
        seenFirstUpdate = false
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            guard let self, let monitor else { return }
            self.lock.lock()
            let isCurrent = self.monitor === monitor
            var shouldNotify = false
            if isCurrent {
                self.metered = path.isExpensive || path.isConstrained
                shouldNotify = self.seenFirstUpdate
                self.seenFirstUpdate = true
            }
            self.lock.unlock()
            if shouldNotify { onChange() }
        }
        self.monitor = monitor
        monitor.start(queue: queue)
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        monitor?.cancel()
        monitor = nil
    }
}
