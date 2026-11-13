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
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            result.append(String(decoding: name, as: UTF8.self))
        }
        return result
    }
}
