import AppKit
import Foundation

public enum VolumeFormat: Equatable, Sendable {
    case apfs, hfs, exfat, other(String)

    public init(fileSystemTypeName: String) {
        switch fileSystemTypeName {
        case "apfs": self = .apfs
        case "hfs": self = .hfs
        case "exfat": self = .exfat
        default: self = .other(fileSystemTypeName)
        }
    }

    public var isSupported: Bool {
        if case .other = self { return false }
        return true
    }

    /// Whether owner, group and mode survive on the volume.
    public var keepsPermissions: Bool { self == .apfs || self == .hfs }
}

public struct VolumeInfo: Equatable, Sendable {
    public var uuid: String?
    public var name: String
    public var mountPath: String              // utan avslutande snedstreck, utom "/"
    public var format: VolumeFormat
    public var isSystem: Bool                 // monterad på "/" eller "/System/Volumes/Data"

    public init(uuid: String?, name: String, mountPath: String, format: VolumeFormat, isSystem: Bool) {
        self.uuid = uuid
        self.name = name
        self.mountPath = mountPath
        self.format = format
        self.isSystem = isSystem
    }
}

public protocol VolumeMonitoring: AnyObject, Sendable {
    func mountedVolumes() -> [VolumeInfo]
    /// onMount och onWillUnmount får volymen; onUnmount får monteringspunkten.
    func start(onMount: @escaping @Sendable (VolumeInfo) -> Void,
               onWillUnmount: @escaping @Sendable (VolumeInfo) -> Void,
               onUnmount: @escaping @Sendable (String) -> Void)
    func stop()
}

/// Mounted volumes from `FileManager`, and mount events from `NSWorkspace`. `mountedVolumes()` is a
/// plain query and works without `start()`. After `stop()` returns, no callback is delivered.
public final class SystemVolumeMonitor: VolumeMonitoring, @unchecked Sendable {
    private let center = NSWorkspace.shared.notificationCenter
    // Serial queue: runs the notification handlers and guards `observers`.
    private let queue = DispatchQueue(label: "com.freberdev.filsynk.volumemonitor")
    private let queueKey = DispatchSpecificKey<Void>()
    private let operationQueue = OperationQueue()
    private var observers: [NSObjectProtocol] = []

    public init() {
        queue.setSpecific(key: queueKey, value: ())
        operationQueue.underlyingQueue = queue
        operationQueue.maxConcurrentOperationCount = 1
    }

    deinit { stop() }

    public func mountedVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeUUIDStringKey, .volumeNameKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { Self.volumeInfo(for: $0) }
    }

    public func start(onMount: @escaping @Sendable (VolumeInfo) -> Void,
                      onWillUnmount: @escaping @Sendable (VolumeInfo) -> Void,
                      onUnmount: @escaping @Sendable (String) -> Void) {
        onQueue {
            guard observers.isEmpty else { return }
            // Runs on `queue`; `observers` is only emptied there, so a handler that runs after
            // `stop()` finds it empty and stays silent.
            func observe(_ name: Notification.Name, _ handle: @escaping @Sendable (URL) -> Void) {
                let token = center.addObserver(forName: name, object: nil, queue: operationQueue) { [weak self] note in
                    guard let self, !self.observers.isEmpty,
                          let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                    handle(url)
                }
                observers.append(token)
            }
            observe(NSWorkspace.didMountNotification) { url in
                if let volume = Self.volumeInfo(for: url) { onMount(volume) }
            }
            observe(NSWorkspace.willUnmountNotification) { url in
                if let volume = Self.volumeInfo(for: url) { onWillUnmount(volume) }
            }
            observe(NSWorkspace.didUnmountNotification) { url in
                onUnmount(Self.normalizedPath(url.path))
            }
        }
    }

    public func stop() {
        onQueue {
            for token in observers { center.removeObserver(token) }
            observers = []
        }
    }

    private static func volumeInfo(for url: URL) -> VolumeInfo? {
        let path = normalizedPath(url.path)
        guard !path.isEmpty else { return nil }
        let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey])
        let name = values?.volumeName ?? url.lastPathComponent
        return VolumeInfo(
            uuid: values?.volumeUUIDString,
            name: name,
            mountPath: path,
            format: VolumeFormat(fileSystemTypeName: fileSystemTypeName(at: path) ?? ""),
            isSystem: path == "/" || path == "/System/Volumes/Data")
    }

    private static func fileSystemTypeName(at path: String) -> String? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return withUnsafePointer(to: &info.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
    }

    private static func normalizedPath(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// Runs `body` on `queue`, directly if already there (e.g. `stop()` called from a callback).
    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { body() } else { queue.sync(execute: body) }
    }
}

public enum VolumeLookup {
    public enum Problem: Error, Equatable, Sendable { case notMounted, duplicate }

    public static func find(uuid: String, in volumes: [VolumeInfo]) -> Result<VolumeInfo, Problem> {
        let matches = volumes.filter { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame }
        switch matches.count {
        case 0: return .failure(.notMounted)
        case 1: return .success(matches[0])
        default: return .failure(.duplicate)
        }
    }

    /// Volymen vars monteringspunkt är det längsta prefixet av sökvägen, jämfört på komponenter.
    public static func volume(containing path: String, in volumes: [VolumeInfo]) -> VolumeInfo? {
        let target = components(path)
        return volumes
            .filter { target.starts(with: components($0.mountPath)) }
            .max { components($0.mountPath).count < components($1.mountPath).count }
    }

    /// Sökvägen relativ volymens rot, eller nil om den inte ligger på volymen. Roten ger "".
    public static func relativePath(of path: String, on volume: VolumeInfo) -> String? {
        let root = components(volume.mountPath)
        let target = components(path)
        guard target.starts(with: root) else { return nil }
        return target.dropFirst(root.count).joined(separator: "/")
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}
