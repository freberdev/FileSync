import Foundation

/// En liten textfil i en målmapp på en disk. Appen speglar bara in i mappar där den själv lagt den.
public enum DiskMarker {
    public static let name = ".filsynk"

    /// Skriver markören i `destination` med mappens lokala sökväg och dagens datum. Mappen måste finnas;
    /// den skapas aldrig här. En befintlig markör skrivs aldrig över eller ändras.
    public static func write(in destination: String, folder: String) throws {
        let path = markerPath(in: destination)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        let date = ISO8601DateFormatter().string(from: Date())
        let bytes = Array("\(folder)\n\(date)\n".utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO) }
            offset += n
        }
    }

    public static func exists(in destination: String) -> Bool {
        var info = stat()
        return lstat(markerPath(in: destination), &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    private static func markerPath(in destination: String) -> String {
        var base = destination
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        return base + "/" + name
    }
}
