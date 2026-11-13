import Foundation
import Network

/// `onChange` is called for every update, including the first after start; `isMetered` is only
/// meaningful after the first call. A `start()` after `stop()` delivers a new first update.
public protocol NetworkMonitoring: AnyObject, Sendable {
    var isMetered: Bool { get }                               // dyr eller begränsad anslutning
    func start(onChange: @escaping @Sendable () -> Void)      // anropas vid varje uppdatering, även den första
    func stop()
}

/// Network status from `NWPathMonitor`. Every path update, including the first one after
/// `start()`, sets `isMetered` and then calls `onChange`.
public final class SystemNetworkMonitor: NetworkMonitoring, @unchecked Sendable {
    private let lock = NSLock()  // guards `monitor`, `metered`
    private var monitor: NWPathMonitor?
    private var metered = false
    private let queue = DispatchQueue(label: "com.freberdev.filsynk.networkmonitor")

    public init() {}

    deinit { monitor?.cancel() }

    public var isMetered: Bool {
        lock.lock(); defer { lock.unlock() }
        return metered
    }

    public func start(onChange: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard monitor == nil else { return }
        metered = false  // no stale value from an earlier start; meaningful after the first update
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            guard let self, let monitor else { return }
            self.lock.lock()
            let isCurrent = self.monitor === monitor
            if isCurrent {
                self.metered = path.isExpensive || path.isConstrained
            }
            self.lock.unlock()
            if isCurrent { onChange() }
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
