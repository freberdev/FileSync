import Testing
import Foundation
@testable import FilsynkCore

@Suite struct RaderatMoverTests {
    private let fm = FileManager.default
    private let ts = "2026-11-13_120000"

    private struct Area {
        let root: URL
        var source: String { root.appendingPathComponent("kalla").path }
        var destination: String { root.appendingPathComponent("mal").path }
        func src(_ p: String) -> String { source + "/" + p }
        func dst(_ p: String) -> String { destination + "/" + p }
        func raderat(_ ts: String, _ p: String) -> String { destination + "/Raderat/" + ts + "/" + p }
    }

    private func withArea(_ body: (Area) throws -> Void) throws {
        let root = fm.temporaryDirectory.appendingPathComponent("filsynk-raderat-\(UUID().uuidString)")
        try fm.createDirectory(atPath: root.path + "/kalla", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root.path + "/mal", withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try body(Area(root: root))
    }

    private func write(_ path: String, _ text: String) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
    private func exists(_ path: String) -> Bool {
        var st = stat(); return lstat(path, &st) == 0
    }
    private func isDirectory(_ path: String) -> Bool {
        var st = stat(); return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }
    private func names(_ path: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted()
    }

    /// Skapar filen med exakt de bytes namnet har, utan att Foundation väljer Unicode-form.
    private func writeRaw(_ path: String, _ text: String) throws {
        var folder = ""
        for part in (path as NSString).deletingLastPathComponent.split(separator: "/", omittingEmptySubsequences: true) {
            folder += "/" + part
            if mkdir(folder, 0o755) != 0, errno != EEXIST { throw CocoaError(.fileWriteUnknown) }
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        guard Darwin.write(fd, bytes, bytes.count) == bytes.count else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Namnen i en mapp som råa bytes, som readdir ger dem.
    private func rawNames(_ path: String) -> [[UInt8]] {
        guard let dir = opendir(path) else { return [] }
        defer { closedir(dir) }
        var result: [[UInt8]] = []
        while let e = readdir(dir) {
            let name = withUnsafeBytes(of: e.pointee.d_name) { raw in
                Array(raw.prefix(Int(e.pointee.d_namlen)))
            }
            if name == [0x2E] || name == [0x2E, 0x2E] { continue }
            result.append(name)
        }
        return result
    }

    @Test func movesFileMissingInSource() throws {
        try withArea { a in
            try write(a.dst("a.txt"), "innehåll")
            let r = try RaderatMover.move(["a.txt"], source: a.source, destination: a.destination, timestamp: ts)
            #expect(r.moved == ["a.txt"]); #expect(r.kept == []); #expect(r.removedDirectories == [])
            #expect(read(a.raderat(ts, "a.txt")) == "innehåll")
            #expect(!exists(a.dst("a.txt")))
        }
    }

    @Test func keepsFileThatStillExistsInSource() throws {
        try withArea { a in
            try write(a.dst("a.txt"), "mål"); try write(a.src("a.txt"), "källa")
            let r = try RaderatMover.move(["a.txt"], source: a.source, destination: a.destination, timestamp: ts)
            #expect(r.moved == []); #expect(r.kept == ["a.txt"])
            #expect(read(a.dst("a.txt")) == "mål")
            #expect(!exists(a.destination + "/Raderat"))
        }
    }

    @Test func nameInOtherUnicodeFormIsNotMoved() throws {
        try withArea { a in
            let nfc = "Åäö.txt".precomposedStringWithCanonicalMapping
            let nfd = "Åäö.txt".decomposedStringWithCanonicalMapping
            try writeRaw(a.src(nfc), "källa")
            try writeRaw(a.dst(nfd), "mål")
            // Källan har NFC-byten på disken, listan NFD, och de är olika.
            #expect(rawNames(a.source) == [Array(nfc.utf8)])
            #expect(Array(nfc.utf8) != Array(nfd.utf8))
            #expect(rawNames(a.source) != [Array(nfd.utf8)])
            let r = try RaderatMover.move([nfd], source: a.source, destination: a.destination, timestamp: ts)
            #expect(r.moved == []); #expect(r.kept == [nfd])
            #expect(read(a.dst(nfd)) == "mål")
            #expect(rawNames(a.destination) == [Array(nfd.utf8)])
            #expect(!exists(a.destination + "/Raderat"))
        }
    }

    @Test func fileUnderFolderNamedInOtherUnicodeFormIsNotMoved() throws {
        try withArea { a in
            let nfc = "Varumärke".precomposedStringWithCanonicalMapping
            let nfd = "Varumärke".decomposedStringWithCanonicalMapping
            try writeRaw(a.src(nfc + "/plain.txt"), "k")
            try writeRaw(a.dst(nfd + "/plain.txt"), "m")
            #expect(rawNames(a.source) == [Array(nfc.utf8)])
            #expect(Array(nfc.utf8) != Array(nfd.utf8))
            #expect(rawNames(a.source) != [Array(nfd.utf8)])
            let r = try RaderatMover.move([nfd + "/plain.txt", nfd + "/"], source: a.source,
                                          destination: a.destination, timestamp: ts)
            #expect(r.moved == []); #expect(r.removedDirectories == [])
            #expect(Set(r.kept) == [nfd + "/plain.txt", nfd + "/"])
            #expect(read(a.dst(nfd + "/plain.txt")) == "m")
            #expect(rawNames(a.destination) == [Array(nfd.utf8)])
            #expect(!exists(a.destination + "/Raderat"))
        }
    }

    @Test func throwsWhenSourceIsADanglingSymbolicLink() throws {
        try withArea { a in
            try write(a.dst("a.txt"), "a")
            let link = a.root.path + "/kalla-lank"
            try fm.createSymbolicLink(atPath: link, withDestinationPath: a.root.path + "/finns-inte")
            #expect(throws: (any Error).self) {
                try RaderatMover.move(["a.txt"], source: link, destination: a.destination, timestamp: ts)
            }
            #expect(read(a.dst("a.txt")) == "a")
            #expect(!exists(a.destination + "/Raderat"))
        }
    }

    @Test func throwsWhenSourceIsASymbolicLinkToAFile() throws {
        try withArea { a in
            try write(a.dst("b.txt"), "b"); try write(a.root.path + "/fil.txt", "x")
            let link = a.root.path + "/kalla-lank"
            try fm.createSymbolicLink(atPath: link, withDestinationPath: a.root.path + "/fil.txt")
            #expect(throws: (any Error).self) {
                try RaderatMover.move(["b.txt"], source: link, destination: a.destination, timestamp: ts)
            }
            #expect(read(a.dst("b.txt")) == "b")
            #expect(!exists(a.destination + "/Raderat"))
        }
    }

    @Test func worksWhenSourceIsASymbolicLinkToAFolder() throws {
        try withArea { a in
            try write(a.dst("finns.txt"), "m1"); try write(a.dst("borta.txt"), "m2")
            try write(a.root.path + "/riktig/finns.txt", "k")
            let link = a.root.path + "/kalla-lank"
            try fm.createSymbolicLink(atPath: link, withDestinationPath: a.root.path + "/riktig")
            let r = try RaderatMover.move(["finns.txt", "borta.txt"], source: link, destination: a.destination, timestamp: ts)
            #expect(r.moved == ["borta.txt"]); #expect(r.kept == ["finns.txt"])
            #expect(read(a.dst("finns.txt")) == "m1")
            #expect(read(a.raderat(ts, "borta.txt")) == "m2")
            #expect(!exists(a.dst("borta.txt")))
            #expect(read(a.root.path + "/riktig/finns.txt") == "k")
        }
    }

    @Test func movesFilesInNestedFoldersAndRemovesEmptyFolders() throws {
        try withArea { a in
            try write(a.src("sub/b.txt"), "b")
            try write(a.dst("sub/b.txt"), "b"); try write(a.dst("sub/djup/c.txt"), "c")
            let r = try RaderatMover.move(["sub/djup/c.txt", "sub/djup/"], source: a.source,
                                          destination: a.destination, timestamp: ts)
            #expect(r.moved == ["sub/djup/c.txt"]); #expect(r.removedDirectories == ["sub/djup/"]); #expect(r.kept == [])
            #expect(read(a.raderat(ts, "sub/djup/c.txt")) == "c")
            #expect(!exists(a.dst("sub/djup")))
            #expect(read(a.dst("sub/b.txt")) == "b")
        }
    }

    @Test func removesFoldersDeepestFirstEvenWhenListedParentFirst() throws {
        try withArea { a in
            try fm.createDirectory(atPath: a.dst("x/y"), withIntermediateDirectories: true)
            let r = try RaderatMover.move(["x/", "x/y/"], source: a.source, destination: a.destination, timestamp: ts)
            #expect(r.removedDirectories == ["x/y/", "x/"]); #expect(r.kept == [])
            #expect(names(a.destination) == [])
        }
    }

    @Test func leavesFolderThatIsNotEmpty() throws {
        try withArea { a in
            try write(a.dst("mapp/olistad.txt"), "kvar"); try write(a.dst("mapp/c.txt"), "c")
            let r = try RaderatMover.move(["mapp/c.txt", "mapp/"], source: a.source,
                                          destination: a.destination, timestamp: ts)
            #expect(r.moved == ["mapp/c.txt"]); #expect(r.kept == ["mapp/"]); #expect(r.removedDirectories == [])
            #expect(read(a.dst("mapp/olistad.txt")) == "kvar")
            #expect(read(a.raderat(ts, "mapp/c.txt")) == "c")
        }
    }

    @Test func keepsFolderThatStillExistsInSource() throws {
        try withArea { a in
            try fm.createDirectory(atPath: a.src("mapp"), withIntermediateDirectories: true)
            try fm.createDirectory(atPath: a.dst("mapp"), withIntermediateDirectories: true)
            let r = try RaderatMover.move(["mapp/"], source: a.source, destination: a.destination, timestamp: ts)
            #expect(r.kept == ["mapp/"]); #expect(r.removedDirectories == [])
            #expect(isDirectory(a.dst("mapp")))
        }
    }

    @Test func movesOldFileWhenSourceNowHasAFolderThere() throws {
        try withArea { a in
            try fm.createDirectory(atPath: a.src("x"), withIntermediateDirectories: true)
            try write(a.dst("x"), "gammal fil")
            let r = try RaderatMover.move(["x"], source: a.source, destination: a.destination, timestamp: ts)
            #expect(r.moved == ["x"])
            #expect(read(a.raderat(ts, "x")) == "gammal fil")
            #expect(!exists(a.dst("x")))
            #expect(isDirectory(a.src("x")))
        }
    }

    @Test func movesOldFileWhenSourceNowHasALinkThere() throws {
        try withArea { a in
            try write(a.src("mal.txt"), "mål")
            try fm.createSymbolicLink(atPath: a.src("x"), withDestinationPath: "mal.txt")
            try write(a.dst("x"), "gammal fil")
            let r = try RaderatMover.move(["x"], source: a.source, destination: a.destination, timestamp: ts)
            #expect(r.moved == ["x"])
            #expect(read(a.raderat(ts, "x")) == "gammal fil")
            #expect(!exists(a.dst("x")))
        }
    }

    @Test func movesOldFolderWhenSourceNowHasAFileThereOnlyIfEmpty() throws {
        try withArea { a in
            try write(a.src("x"), "fil nu")
            try fm.createDirectory(atPath: a.dst("x"), withIntermediateDirectories: true)
            let r = try RaderatMover.move(["x/"], source: a.source, destination: a.destination, timestamp: ts)
            #expect(r.removedDirectories == ["x/"])
            #expect(!exists(a.dst("x")))
            #expect(read(a.src("x")) == "fil nu")
        }
    }

    @Test func movesSymbolicLinkWithoutFollowingIt() throws {
        try withArea { a in
            try write(a.dst("riktig.txt"), "mål för länken")
            try write(a.src("riktig.txt"), "k")
            try fm.createSymbolicLink(atPath: a.dst("lank"), withDestinationPath: "riktig.txt")
            let r = try RaderatMover.move(["lank"], source: a.source, destination: a.destination, timestamp: ts)
            #expect(r.moved == ["lank"])
            #expect((try? fm.destinationOfSymbolicLink(atPath: a.raderat(ts, "lank"))) == "riktig.txt")
            #expect(!exists(a.dst("lank")))
            #expect(read(a.dst("riktig.txt")) == "mål för länken")
        }
    }

    @Test func movesSymbolicLinkPointingToFolderWithoutTouchingTheFolder() throws {
        try withArea { a in
            try write(a.dst("data/f.txt"), "f")
            try write(a.src("data/f.txt"), "f")
            try fm.createSymbolicLink(atPath: a.dst("lank"), withDestinationPath: "data")
            let r = try RaderatMover.move(["lank"], source: a.source, destination: a.destination, timestamp: ts)
            #expect(r.moved == ["lank"])
            #expect((try? fm.destinationOfSymbolicLink(atPath: a.raderat(ts, "lank"))) == "data")
            #expect(read(a.dst("data/f.txt")) == "f")
        }
    }

    @Test func doesNotFollowSymbolicLinkedFolderInDestination() throws {
        try withArea { a in
            try write(a.root.path + "/utanfor/f.txt", "utanför")
            try fm.createSymbolicLink(atPath: a.dst("lank"), withDestinationPath: a.root.path + "/utanfor")
            let r = try RaderatMover.move(["lank/f.txt"], source: a.source, destination: a.destination, timestamp: ts)
            #expect(r.moved == []); #expect(r.kept == ["lank/f.txt"])
            #expect(read(a.root.path + "/utanfor/f.txt") == "utanför")
            #expect(!exists(a.destination + "/Raderat"))
        }
    }

    @Test func rejectsUnsafePaths() throws {
        try withArea { a in
            try write(a.root.path + "/x", "utanför")
            try write(a.dst("x"), "i målet")
            try write(a.dst("Raderat/2026/x"), "arkiverat")
            let listed = ["../x", "/etc/passwd", "a/../../x", "Raderat/2026/x", "", "./x", "a/./b", "a//b", "x\0y", "Raderat/"]
            let r = try RaderatMover.move(listed, source: a.source, destination: a.destination, timestamp: ts)
            #expect(r.moved == []); #expect(r.removedDirectories == [])
            #expect(Set(r.kept) == Set(listed)); #expect(r.kept.count == listed.count)
            #expect(read(a.root.path + "/x") == "utanför")
            #expect(read(a.dst("x")) == "i målet")
            #expect(read(a.dst("Raderat/2026/x")) == "arkiverat")
            #expect(names(a.destination + "/Raderat") == ["2026"])
        }
    }

    @Test func neverMovesAnythingInsideRaderatThroughAnotherSpelling() throws {
        try withArea { a in
            try write(a.dst("Raderat/gammal/k.txt"), "k")
            try fm.createSymbolicLink(atPath: a.dst("genvag"), withDestinationPath: "Raderat")
            let r = try RaderatMover.move(["genvag/gammal/k.txt", "genvag/gammal/", "genvag/"], source: a.source,
                                          destination: a.destination, timestamp: ts)
            #expect(r.moved == []); #expect(r.removedDirectories == [])
            #expect(read(a.dst("Raderat/gammal/k.txt")) == "k")
            #expect(names(a.dst("Raderat")) == ["gammal"])
        }
    }

    @Test func toleratesPathAlreadyGone() throws {
        try withArea { a in
            let r = try RaderatMover.move(["borta.txt", "mapp/", "mapp/borta.txt"], source: a.source,
                                          destination: a.destination, timestamp: ts)
            #expect(r.moved == []); #expect(r.removedDirectories == [])
            #expect(Set(r.kept) == ["borta.txt", "mapp/", "mapp/borta.txt"])
            #expect(!exists(a.destination + "/Raderat"))
        }
    }

    @Test func createsNoRaderatFolderWhenNothingMoves() throws {
        try withArea { a in
            try write(a.dst("a.txt"), "a"); try write(a.src("a.txt"), "a")
            _ = try RaderatMover.move(["a.txt", "finns-inte.txt"], source: a.source, destination: a.destination, timestamp: ts)
            #expect(names(a.destination) == ["a.txt"])
        }
    }

    @Test func neverTouchesExistingRaderatContent() throws {
        try withArea { a in
            try write(a.dst("Raderat/gammal/k.txt"), "k"); try write(a.dst("a.txt"), "a")
            let r = try RaderatMover.move(["a.txt"], source: a.source, destination: a.destination, timestamp: ts)
            #expect(r.moved == ["a.txt"])
            #expect(read(a.dst("Raderat/gammal/k.txt")) == "k")
            #expect(read(a.raderat(ts, "a.txt")) == "a")
            #expect(names(a.dst("Raderat")) == ["2026-11-13_120000", "gammal"])
        }
    }

    @Test func doesNotOverwriteAnEntryAlreadyInRaderat() throws {
        try withArea { a in
            try write(a.dst("a.txt"), "nytt"); try write(a.raderat(ts, "a.txt"), "tidigare")
            let r = try RaderatMover.move(["a.txt"], source: a.source, destination: a.destination, timestamp: ts)
            #expect(r.moved == []); #expect(r.kept == ["a.txt"])
            #expect(read(a.dst("a.txt")) == "nytt")
            #expect(read(a.raderat(ts, "a.txt")) == "tidigare")
        }
    }

    @Test func movesTwoFilesWithSameNameFromDifferentFolders() throws {
        try withArea { a in
            try write(a.dst("p/a.txt"), "1"); try write(a.dst("q/a.txt"), "2")
            let r = try RaderatMover.move(["p/a.txt", "q/a.txt"], source: a.source, destination: a.destination, timestamp: ts)
            #expect(r.moved == ["p/a.txt", "q/a.txt"])
            #expect(read(a.raderat(ts, "p/a.txt")) == "1"); #expect(read(a.raderat(ts, "q/a.txt")) == "2")
        }
    }

    @Test func listedTwiceMovesOnce() throws {
        try withArea { a in
            try write(a.dst("a.txt"), "a")
            let r = try RaderatMover.move(["a.txt", "a.txt"], source: a.source, destination: a.destination, timestamp: ts)
            #expect(r.moved == ["a.txt"]); #expect(r.kept == ["a.txt"])
            #expect(read(a.raderat(ts, "a.txt")) == "a")
        }
    }

    @Test func throwsWhenSourceFolderIsMissingAndMovesNothing() throws {
        try withArea { a in
            try write(a.dst("a.txt"), "a")
            #expect(throws: (any Error).self) {
                try RaderatMover.move(["a.txt"], source: a.root.path + "/finns-inte", destination: a.destination, timestamp: ts)
            }
            #expect(read(a.dst("a.txt")) == "a")
            #expect(!exists(a.destination + "/Raderat"))
        }
    }

    @Test func throwsOnUnusableTimestamp() throws {
        try withArea { a in
            try write(a.dst("a.txt"), "a")
            for bad in ["", ".", "..", "a/b"] {
                #expect(throws: (any Error).self) {
                    try RaderatMover.move(["a.txt"], source: a.source, destination: a.destination, timestamp: bad)
                }
            }
            #expect(read(a.dst("a.txt")) == "a")
            #expect(!exists(a.destination + "/Raderat"))
        }
    }

    @Test func throwsWhenRaderatIsNotAFolderAndLeavesEntryInPlace() throws {
        try withArea { a in
            try write(a.dst("Raderat"), "i vägen"); try write(a.dst("a.txt"), "a")
            #expect(throws: (any Error).self) {
                try RaderatMover.move(["a.txt"], source: a.source, destination: a.destination, timestamp: ts)
            }
            #expect(read(a.dst("a.txt")) == "a"); #expect(read(a.dst("Raderat")) == "i vägen")
        }
    }

    @Test func keepsWhatWasAlreadyMovedWhenALaterMoveFails() throws {
        try withArea { a in
            try write(a.dst("a.txt"), "a"); try write(a.dst("d/f.txt"), "f")
            try write(a.raderat(ts, "d"), "en fil där mappen skulle ligga")
            #expect(throws: (any Error).self) {
                try RaderatMover.move(["a.txt", "d/f.txt"], source: a.source, destination: a.destination, timestamp: ts)
            }
            #expect(read(a.raderat(ts, "a.txt")) == "a")
            #expect(read(a.dst("d/f.txt")) == "f")
            #expect(read(a.raderat(ts, "d")) == "en fil där mappen skulle ligga")
        }
    }

    // rsync i macOS 15 listar en borttagen mapp utan avslutande snedstreck.
    @Test func foldersListedWithoutSlashAreRemovedWhenEmptied() throws {
        try withArea { a in
            try write(a.dst("gammal/djup/f.txt"), "f")
            try write(a.dst("gammal/g.txt"), "g")
            try fm.createDirectory(atPath: a.dst("tom"), withIntermediateDirectories: true)
            let report = try RaderatMover.move(
                ["gammal/djup/f.txt", "gammal/djup", "gammal/g.txt", "gammal", "tom"],
                source: a.source, destination: a.destination, timestamp: ts)
            #expect(!exists(a.dst("gammal")))
            #expect(!exists(a.dst("tom")))
            #expect(read(a.raderat(ts, "gammal/djup/f.txt")) == "f")
            #expect(read(a.raderat(ts, "gammal/g.txt")) == "g")
            #expect(!exists(a.raderat(ts, "tom")))
            #expect(report.moved == ["gammal/djup/f.txt", "gammal/g.txt"])
            #expect(report.removedDirectories == ["gammal/djup", "gammal", "tom"])
            #expect(report.kept.isEmpty)
        }
    }

    @Test func folderListedWithoutSlashBeforeItsContentsIsHandledTheSame() throws {
        try withArea { a in
            try write(a.dst("gammal/g.txt"), "g")
            _ = try RaderatMover.move(
                ["gammal", "gammal/g.txt"], source: a.source, destination: a.destination, timestamp: ts)
            #expect(!exists(a.dst("gammal")))
            #expect(read(a.raderat(ts, "gammal/g.txt")) == "g")
        }
    }

    @Test func folderListedWithoutSlashThatStillHoldsSomethingStays() throws {
        try withArea { a in
            try write(a.dst("gammal/kvar.txt"), "inte listad")
            let report = try RaderatMover.move(
                ["gammal"], source: a.source, destination: a.destination, timestamp: ts)
            #expect(read(a.dst("gammal/kvar.txt")) == "inte listad")
            #expect(!exists(a.destination + "/Raderat"))
            #expect(report.kept == ["gammal"])
        }
    }

    @Test func linkToFolderListedWithoutSlashIsMovedAsALink() throws {
        try withArea { a in
            try write(a.dst("riktig/f.txt"), "f")
            try write(a.src("riktig/f.txt"), "f")
            try fm.createSymbolicLink(atPath: a.dst("lank"), withDestinationPath: "riktig")
            _ = try RaderatMover.move(["lank"], source: a.source, destination: a.destination, timestamp: ts)
            #expect(!exists(a.dst("lank")))
            #expect((try? fm.destinationOfSymbolicLink(atPath: a.raderat(ts, "lank"))) == "riktig")
            #expect(read(a.dst("riktig/f.txt")) == "f")
        }
    }
}
