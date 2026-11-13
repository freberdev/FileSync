import Foundation

/// Append-only log file with one-step rotation: when a line would take the file over
/// `maxBytes`, the file is renamed to `<name>.1` (replacing any older one) and a new file starts.
public final class FileLog: @unchecked Sendable {
    private let url: URL
    private let maxBytes: Int
    private let lock = NSLock()  // serialises file access and guards `formatter`
    private let formatter: DateFormatter

    public init(url: URL, maxBytes: Int = 1_000_000) {
        self.url = url
        self.maxBytes = maxBytes
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Filsynk/filsynk.log")
    }

    /// Never throws: a logger must not take the app down, so failures are dropped.
    public func write(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        let line = Data("\(formatter.string(from: Date())) \(message)\n".utf8)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            if let size, size > 0, size + line.count > maxBytes {
                let rotated = URL(fileURLWithPath: url.path + ".1")
                try? fm.removeItem(at: rotated)
                try fm.moveItem(at: url, to: rotated)
            }
            if !fm.fileExists(atPath: url.path) {
                guard fm.createFile(atPath: url.path, contents: line) else { return }
                return
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // Intentionally dropped.
        }
    }
}
