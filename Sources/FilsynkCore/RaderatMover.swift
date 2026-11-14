import Foundation

public struct MoveReport: Equatable, Sendable {
    public var moved: [String] = []              // relativa sökvägar som flyttades
    public var kept: [String] = []               // listade men lämnade orörda
    public var removedDirectories: [String] = [] // tomma mappar som togs bort

    public init(moved: [String] = [], kept: [String] = [], removedDirectories: [String] = []) {
        self.moved = moved; self.kept = kept; self.removedDirectories = removedDirectories
    }
}

public enum RaderatMoverError: Error, Equatable, LocalizedError {
    case invalidTimestamp(String)
    case missingFolder(String)
    case cannotCreateFolder(String, Int32)
    case moveFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidTimestamp(let t): return "Ogiltig tidsstämpel: \(t)"
        case .missingFolder(let p): return "Mappen finns inte: \(p)"
        case .cannotCreateFolder(let p, let e): return "Kunde inte skapa mappen \(p): \(String(cString: strerror(e)))"
        case .moveFailed(let p, let e): return "Kunde inte flytta \(p): \(String(cString: strerror(e)))"
        }
    }
}

/// Flyttar det rsync skulle ha tagit bort till `Raderat/<tidsstämpel>/` i målet. Ingenting raderas:
/// filer och länkar byter plats med `rename`, och en mapp tas bara bort med `rmdir` när den är tom.
public enum RaderatMover {
    public static func move(_ listed: [String], source: String, destination: String,
                            timestamp: String) throws -> MoveReport {
        guard isSingleComponent(timestamp) else { throw RaderatMoverError.invalidTimestamp(timestamp) }
        let src = trimmedRoot(source), dst = trimmedRoot(destination)
        // Roten avgörs genom länkar: en länk som pekar ingenstans räknas som att källan saknas.
        var rootStat = stat()
        guard stat(src, &rootStat) == 0, rootStat.st_mode & S_IFMT == S_IFDIR else {
            throw RaderatMoverError.missingFolder(source)
        }
        guard case .entry(let d) = lookup(dst), d.isDirectory else { throw RaderatMoverError.missingFolder(destination) }
        let dstReal = realPath(dst) ?? dst

        let raderatRoot = dst + "/Raderat"
        var report = MoveReport()
        var files: [Candidate] = [], folders: [Candidate] = []
        for entry in listed {
            guard var c = Candidate(entry) else { report.kept.append(entry); continue }
            // Snedstrecket räcker inte: rsync i macOS 15 listar en mapp utan. Det som är en riktig
            // mapp i målet behandlas som en mapp: den tas bara bort när den är tom.
            if !c.isFolder, case .entry(let info) = lookup(dst + "/" + c.relative), info.isDirectory {
                c.isFolder = true
            }
            if c.isFolder { folders.append(c) } else { files.append(c) }
        }
        // Djupast först; lika djupa behåller listans ordning.
        folders = folders.enumerated()
            .sorted { ($0.element.components.count, $1.offset) > ($1.element.components.count, $0.offset) }
            .map(\.element)

        for c in files {
            guard qualifies(c, source: src, destination: dst, destinationReal: dstReal) else {
                report.kept.append(c.listed); continue
            }
            let target = raderatRoot + "/" + timestamp + "/" + c.relative
            guard isInside(target, root: dst), isInside(dst + "/" + c.relative, root: dst) else {
                report.kept.append(c.listed); continue
            }
            // Något som redan ligger på platsen i Raderat skrivs aldrig över.
            guard case .absent = lookup(target) else { report.kept.append(c.listed); continue }
            try makeFolders(dst: dst, timestamp: timestamp, parents: c.components.dropLast())
            switch renameWithoutReplacing(dst + "/" + c.relative, target) {
            case .done: report.moved.append(c.listed)
            case .occupied: report.kept.append(c.listed)
            case .failed(let e): throw RaderatMoverError.moveFailed(c.listed, e)
            }
        }

        for c in folders {
            guard qualifies(c, source: src, destination: dst, destinationReal: dstReal),
                  isInside(dst + "/" + c.relative, root: dst) else {
                report.kept.append(c.listed); continue
            }
            // rmdir lyckas bara på en tom mapp.
            if rmdir(dst + "/" + c.relative) == 0 {
                report.removedDirectories.append(c.listed)
            } else {
                report.kept.append(c.listed)
            }
        }
        return report
    }

    // MARK: Listad sökväg

    private struct Candidate {
        let listed: String
        let components: [String]
        var isFolder: Bool
        var relative: String { components.joined(separator: "/") }

        init?(_ listed: String) {
            var parts = listed.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
            var folder = false
            if parts.count > 1, parts.last?.isEmpty == true { parts.removeLast(); folder = true }
            guard !listed.isEmpty, !listed.utf8.contains(0) else { return nil }
            var names: [String] = []
            for p in parts {
                let name = String(decoding: p, as: UTF8.self)
                guard isSingleComponent(name) else { return nil }
                names.append(name)
            }
            // Exakt och skiftlägeskänsligt på det som står i listan.
            guard names.first.map({ Array($0.utf8) != Array("Raderat".utf8) }) == true else { return nil }
            self.listed = listed; self.components = names; self.isFolder = folder
        }
    }

    /// Får posten flyttas undan? Den ska finnas i målet, inte vara Raderat eller ligga i den, och saknas
    /// i källan eller vara en annan sorts post där (fil, mapp eller länk).
    private static func qualifies(_ c: Candidate, source: String, destination: String, destinationReal: String) -> Bool {
        // Varje mapp på vägen i målet ska vara en riktig mapp, aldrig en länk.
        var prefix = destination
        for name in c.components.dropLast() {
            prefix += "/" + name
            guard case .entry(let info) = lookup(prefix), info.isDirectory else { return false }
        }
        let raderat = lookup(destination + "/Raderat")
        if case .entry(let r) = raderat, case .entry(let first) = lookup(destination + "/" + c.components[0]),
           r.device == first.device, r.inode == first.inode { return false }
        if c.components.count > 1 {
            guard let parent = realPath(destination + "/" + c.components.dropLast().joined(separator: "/")),
                  parent.hasPrefix(destinationReal + "/") else { return false }
            let rest = parent.dropFirst(destinationReal.count + 1)
            if rest == "Raderat" || rest.hasPrefix("Raderat/") { return false }
        }
        guard case .entry(let inTarget) = lookup(destination + "/" + c.relative) else { return false }
        guard inTarget.isDirectory == c.isFolder else { return false }
        switch lookup(source + "/" + c.relative) {
        case .absent: return true
        case .failed: return false
        case .entry(let inSource): return inSource.mode & S_IFMT != inTarget.mode & S_IFMT
        }
    }

    // MARK: Filsystem

    private struct Info { let mode: mode_t; let device: dev_t; let inode: ino_t
        var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
        var isLink: Bool { mode & S_IFMT == S_IFLNK }
    }
    private enum Lookup { case entry(Info), absent, failed }

    private static func lookup(_ path: String) -> Lookup {
        var st = stat()
        if lstat(path, &st) == 0 { return .entry(Info(mode: st.st_mode, device: st.st_dev, inode: st.st_ino)) }
        return errno == ENOENT || errno == ENOTDIR ? .absent : .failed
    }

    private static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    private static func trimmedRoot(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func isSingleComponent(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && !s.utf8.contains(UInt8(ascii: "/")) && !s.utf8.contains(0)
    }

    private static func isInside(_ path: String, root: String) -> Bool {
        let p = URL(fileURLWithPath: path).standardized.path
        let r = URL(fileURLWithPath: root).standardized.path
        return p.hasPrefix(r == "/" ? "/" : r + "/")
    }

    /// Skapar Raderat/<tidsstämpel>/ och mapparna under den, en i taget, och går aldrig genom en länk.
    private static func makeFolders(dst: String, timestamp: String, parents: ArraySlice<String>) throws {
        var path = dst
        for name in ["Raderat", timestamp] + parents {
            path += "/" + name
            switch lookup(path) {
            case .entry(let info):
                guard info.isDirectory else { throw RaderatMoverError.cannotCreateFolder(path, EEXIST) }
            case .absent:
                if mkdir(path, 0o755) != 0, errno != EEXIST { throw RaderatMoverError.cannotCreateFolder(path, errno) }
                guard case .entry(let info) = lookup(path), info.isDirectory else {
                    throw RaderatMoverError.cannotCreateFolder(path, EEXIST)
                }
            case .failed:
                throw RaderatMoverError.cannotCreateFolder(path, errno)
            }
        }
    }

    private enum RenameResult { case done, occupied, failed(Int32) }

    private static func renameWithoutReplacing(_ from: String, _ to: String) -> RenameResult {
        if renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 { return .done }
        switch errno {
        case EEXIST: return .occupied
        case ENOTSUP, EINVAL:
            // Filsystem utan stöd för att nekas ersättning: kontrollera i stället precis före.
            guard case .absent = lookup(to) else { return .occupied }
            return rename(from, to) == 0 ? .done : .failed(errno)
        default: return .failed(errno)
        }
    }
}
