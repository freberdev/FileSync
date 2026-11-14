import Testing
import Foundation
@testable import FilsynkCore

@Suite struct DeletionListTests {
    @Test func parsesDeletingLinesOnly() {
        let out = "*deleting sub/djup/c.txt\n*deleting sub/djup/\n*deleting a.txt\n>f.s..... sub/b.txt\nskipping non-regular file \"x\"\n"
        #expect(DeletionList.parse(out) == ["sub/djup/c.txt", "sub/djup/", "a.txt"])
    }

    @Test func removesDuplicatesAndKeepsOrder() {
        let out = "*deleting b.txt\n*deleting a.txt\n*deleting b.txt\n*deleting a.txt\n*deleting c.txt\n"
        #expect(DeletionList.parse(out) == ["b.txt", "a.txt", "c.txt"])
    }

    @Test func keepsNamesWithSpacesAndSwedishLetters() {
        #expect(DeletionList.parse("*deleting Räksmörgås fil.txt\n") == ["Räksmörgås fil.txt"])
        #expect(DeletionList.parse("*deleting  två mellanslag \n") == [" två mellanslag "])
    }

    @Test func ignoresWarningsThatMentionDeleting() {
        let out = "rsync(1): warning: /x: not empty, cannot delete\n  *deleting indented.txt\nnot *deleting here.txt\n*deleting\n"
        #expect(DeletionList.parse(out) == [])
    }

    @Test func emptyOutputGivesEmptyList() {
        #expect(DeletionList.parse("") == [])
        #expect(DeletionList.parse("\n\n") == [])
    }

    @Test func handlesWindowsLineEndingsAndMissingFinalNewline() {
        #expect(DeletionList.parse("*deleting a.txt\r\n*deleting b/\r\n*deleting c.txt") == ["a.txt", "b/", "c.txt"])
    }

    @Test func realisticOutputFromRsync() {
        let out = """
        rsync(28587): warning: /Volumes/X/c//./Varumärke-nfc: not empty, cannot delete
        *deleting Varumärke-nfc/idéer.md
        *deleting Varumärke-nfc/plain.txt
        *deleting Varumärke-nfc/idéer.md
        *deleting sub/djup/c.txt
        *deleting sub/djup/
        *deleting a.txt
        >f.st.... sub/b.txt
        skipping non-regular file "lank-till-a"

        """
        #expect(DeletionList.parse(out) == [
            "Varumärke-nfc/idéer.md", "Varumärke-nfc/plain.txt", "sub/djup/c.txt", "sub/djup/", "a.txt",
        ])
    }

    @Test func doesNotMergeNamesInDifferentUnicodeForms() {
        let nfc = "Åäö.txt".precomposedStringWithCanonicalMapping
        let nfd = "Åäö.txt".decomposedStringWithCanonicalMapping
        let parsed = DeletionList.parse("*deleting \(nfc)\n*deleting \(nfd)\n")
        #expect(parsed.count == 2)
        #expect(parsed[0].unicodeScalars.map(\.value) == nfc.unicodeScalars.map(\.value))
        #expect(parsed[1].unicodeScalars.map(\.value) == nfd.unicodeScalars.map(\.value))
    }

    @Test func decodesEscapedBytes() {
        // rsync skriver styrtecken som "\#" och tre oktala siffror.
        #expect(DeletionList.parse("*deleting rad\\#012brytning.txt\n") == ["rad\nbrytning.txt"])
        #expect(DeletionList.parse("*deleting vagnretur\\#015\n") == ["vagnretur\r"])
        // Ett namn kodat byte för byte, som en äldre rsync gör med tecken utanför ASCII.
        #expect(DeletionList.parse("*deleting a\\#314\\#210.txt\n") == ["a\u{308}.txt"])
    }

    @Test func escapedBackslashIsNotDecodedTwice() {
        // Filen heter bokstavligen "back\#303slash.txt"; rsync kodar då bara det omvända snedstrecket.
        #expect(DeletionList.parse("*deleting back\\#134#303slash.txt\n") == ["back\\#303slash.txt"])
    }

    @Test func leavesWhatIsNotAnEscapeAlone() {
        #expect(DeletionList.parse("*deleting a\\#12.txt\n") == ["a\\#12.txt"])
        #expect(DeletionList.parse("*deleting a\\#128.txt\n") == ["a\\#128.txt"])
        #expect(DeletionList.parse("*deleting a\\#400.txt\n") == ["a\\#400.txt"])
        #expect(DeletionList.parse("*deleting a\\b#101.txt\n") == ["a\\b#101.txt"])
        #expect(DeletionList.parse("*deleting slut\\#\n") == ["slut\\#"])
    }
}
