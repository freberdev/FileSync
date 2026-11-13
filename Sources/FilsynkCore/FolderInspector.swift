import Foundation

public struct FolderReport: Equatable, Sendable {
    public var fileCount: Int
    public var cloudOnlyCount: Int
    public var cloudOnlyBytes: Int64
    public var hasReservedRaderat: Bool

    public init(fileCount: Int, cloudOnlyCount: Int, cloudOnlyBytes: Int64, hasReservedRaderat: Bool) {
        self.fileCount = fileCount
        self.cloudOnlyCount = cloudOnlyCount
        self.cloudOnlyBytes = cloudOnlyBytes
        self.hasReservedRaderat = hasReservedRaderat
    }

    public var warnings: [String] {
        var result: [String] = []
        if fileCount > FolderInspector.largeFolderThreshold {
            result.append("Mappen innehåller \(fileCount) filer. Över 100 000 kan synken bli märkbar. Lägg till undantag eller välj en undermapp.")
        }
        if cloudOnlyCount > 0 {
            let size = ByteCountFormatter.string(fromByteCount: cloudOnlyBytes, countStyle: .file)
            result.append("\(cloudOnlyCount) filer (\(size)) finns bara i iCloud och laddas ner vid första synken.")
        }
        if hasReservedRaderat {
            result.append("Mappen \"Raderat\" i toppnivån säkerhetskopieras inte. Namnet är reserverat.")
        }
        return result
    }
}

public enum FolderInspector {
    public static let largeFolderThreshold = 100_000

    private static let datalessFlag = UInt32(0x4000_0000) // SF_DATALESS

    /// Counts regular files below `path` without following symlinks or reading file contents.
    /// Unreadable subdirectories are skipped.
    public static func inspect(path: String) -> FolderReport {
        var report = FolderReport(fileCount: 0, cloudOnlyCount: 0, cloudOnlyBytes: 0, hasReservedRaderat: false)

        var rootInfo = stat()
        if lstat(path + "/Raderat", &rootInfo) == 0 { report.hasReservedRaderat = true }

        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in true })
        else { return report }

        for case let url as URL in enumerator {
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            report.fileCount += 1
            if info.st_flags & datalessFlag != 0 {
                report.cloudOnlyCount += 1
                report.cloudOnlyBytes += Int64(info.st_size)
            }
        }
        return report
    }
}
