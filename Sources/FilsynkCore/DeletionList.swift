import Foundation

/// Läser rsyncs torrkörning och plockar ut de sökvägar som rsync skulle ha tagit bort.
public enum DeletionList {
    /// Sökvägarna på rader som börjar med "*deleting ", i samma ordning, utan dubbletter.
    /// En mapp behåller sitt avslutande snedstreck. Alla andra rader hoppas över.
    public static func parse(_ dryRunOutput: String) -> [String] {
        let prefix = Array("*deleting ".utf8)
        var seen = Set<[UInt8]>()
        var result: [String] = []
        // Bytevis så att namn i olika Unicode-former hålls isär och "\r\n" inte blir ett enda tecken.
        for line in dryRunOutput.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard line.starts(with: prefix) else { continue }
            var name = Array(line.dropFirst(prefix.count))
            if name.last == UInt8(ascii: "\r") { name.removeLast() }
            name = unescaped(name)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            result.append(String(decoding: name, as: UTF8.self))
        }
        return result
    }

    /// rsync skriver en byte den inte vill visa som `\#` följt av tre oktala siffror: styrtecken alltid,
    /// och utan `-8` också vissa byte över 127. Ett omvänt snedstreck som i namnet råkar stå före `#` och
    /// tre siffror skrivs självt som `\#134`, så varje sådan följd i utskriften är en kodad byte.
    static func unescaped(_ name: [UInt8]) -> [UInt8] {
        let backslash = UInt8(ascii: "\\"), hash = UInt8(ascii: "#")
        func octal(_ byte: UInt8) -> Int? {
            byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "7") ? Int(byte - UInt8(ascii: "0")) : nil
        }
        var result: [UInt8] = []
        result.reserveCapacity(name.count)
        var i = 0
        while i < name.count {
            if name[i] == backslash, i + 4 < name.count, name[i + 1] == hash,
               let a = octal(name[i + 2]), let b = octal(name[i + 3]), let c = octal(name[i + 4]),
               a <= 3 {
                result.append(UInt8(a * 64 + b * 8 + c))
                i += 5
            } else {
                result.append(name[i])
                i += 1
            }
        }
        return result
    }
}
