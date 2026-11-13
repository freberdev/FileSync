import Foundation

/// En liten textfil i en målmapp på en disk. Appen speglar bara in i mappar där den själv lagt den.
public enum DiskMarker {
    public static let name = ".filsynk"

    /// Skriver markören i `destination` med mappens lokala sökväg och dagens datum. Mappen måste finnas;
    /// den skapas aldrig här. En befintlig markör skrivs aldrig över eller ändras. Misslyckas skrivningen
    /// efter att filen skapats tas just den ofärdiga filen bort igen.
    public static func write(in destination: String, folder: String) throws {
        let path = markerPath(in: destination)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        var failure: Int32?
        let date = ISO8601DateFormatter().string(from: Date())
        let bytes = Array("\(folder)\n\(date)\n".utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { failure = errno; break }
            offset += n
        }
        if close(fd) != 0, failure == nil { failure = errno }
        if let failure {
            unlink(path)
            throw POSIXError(POSIXError.Code(rawValue: failure) ?? .EIO)
        }
    }

    /// Mappen som markören säger att målet hör till (dess första rad), eller nil när det inte finns
    /// någon giltig markör: filen saknas, är inte en vanlig fil, går inte att läsa eller första raden är tom eller bara blanktecken.
    public static func folder(in destination: String) -> String? {
        let path = markerPath(in: destination)
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { return nil }
        // Första raden precis som den skrevs, eftersom ett mappnamn kan börja eller sluta med mellanslag.
        // Bara "\r" i ett CRLF-radslut tas bort. Delas på byten, eftersom Swift ser "\r\n" som ett tecken.
        var line = buffer[0..<n].prefix { $0 != UInt8(ascii: "\n") }
        if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
        let first = String(decoding: line, as: UTF8.self)
        return first.allSatisfy(\.isWhitespace) ? nil : first
    }

    /// Sant när sökvägen kan stå som markörens första rad, alltså saknar radbrytning.
    public static func canRecord(_ folder: String) -> Bool {
        !folder.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
    }

    public static func exists(in destination: String) -> Bool {
        folder(in: destination) != nil
    }

    private static func markerPath(in destination: String) -> String {
        var base = destination
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        return base + "/" + name
    }
}
