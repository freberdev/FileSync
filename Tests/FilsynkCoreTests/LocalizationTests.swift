import Foundation
import Testing
@testable import FilsynkCore

@Suite struct LocalizationTests {
    /// Texts that really are the same in Swedish and English.
    static let sameInBothLanguages: Set<String> = [
        "Server",
        "Server: %@",
    ]

    @Test func lookupWithoutTableGivesTheSwedishText() {
        #expect(L("Synka nu") == "Synka nu")
        #expect(L("100 % klart") == "100 % klart")
    }

    @Test func lookupFillsInArguments() {
        #expect(L("Kunde inte skapa mappen %@: %@", "/a b", "ingen plats") == "Kunde inte skapa mappen /a b: ingen plats")
        #expect(L("Tecknen . _ %% och %@", "x") == "Tecknen . _ % och x")
        #expect(L("%@ filer", String(12)) == "12 filer")
        #expect(L("Kod %d", Int32(255)) == "Kod 255")
    }

    @Test func argumentsAreNotReadAsFormats() {
        #expect(L("Mappen %@ saknas", "/a/100%d") == "Mappen /a/100%d saknas")
    }

    @Test func formatSpecifiersAreReadInArgumentOrder() {
        #expect(formatSpecifiers("a %@ b %d c %%") == ["@", "d"])
        #expect(formatSpecifiers("%2$@ before %1$d") == ["d", "@"])
        #expect(formatSpecifiers("%lld and %.1f") == ["lld", "f"])
        #expect(formatSpecifiers("100 %% done") == [])
    }

    @Test func tablesParseAndHaveTheSameKeys() throws {
        let sv = try Repository.stringsTable("sv")
        let en = try Repository.stringsTable("en")
        #expect(Set(sv.keys) == Set(en.keys))
        #expect(Set(sv.keys).subtracting(en.keys).isEmpty)
        #expect(Set(en.keys).subtracting(sv.keys).isEmpty)
    }

    @Test func swedishMapsEveryKeyToItself() throws {
        for (key, value) in try Repository.stringsTable("sv") {
            #expect(value == key)
        }
    }

    @Test func englishKeepsTheFormatOfEveryKey() throws {
        for (key, value) in try Repository.stringsTable("en") {
            #expect(!value.trimmingCharacters(in: .whitespaces).isEmpty, "empty: \(key)")
            #expect(formatSpecifiers(value) == formatSpecifiers(key), "\(key) → \(value)")
        }
    }

    @Test func englishIsTranslated() throws {
        for (key, value) in try Repository.stringsTable("en") where !Self.sameInBothLanguages.contains(key) {
            #expect(value != key, "not translated: \(key)")
        }
        let keys = try Repository.stringsTable("en").keys
        for same in Self.sameInBothLanguages {
            #expect(keys.contains(same), "not in the table: \(same)")
        }
    }

    @Test func everyLookupKeyIsInTheTablesAndEveryEntryIsUsed() throws {
        let (literals, problems) = try scanSources()
        #expect(problems == [])
        let keys = literals.filter(\.isLookupKey)
        for key in keys where key.hasInterpolation || key.isMultiLine || key.isRaw {
            Issue.record("\(key.location): the key is to be a plain literal, with arguments as %@: \(key.value)")
        }
        let used = Set(keys.map(\.value))
        let table = Set(try Repository.stringsTable("sv").keys)
        for missing in used.subtracting(table).sorted() {
            Issue.record("not in the tables: \(missing)")
        }
        for unused in table.subtracting(used).sorted() {
            Issue.record("not used in Sources: \(unused)")
        }
    }

    @Test func scannerFindsLookupKeys() {
        let source = #"""
        // L("in a comment")
        /* L("in a /* nested */ comment") */
        let a = L("plain \"quoted\" text")
        let b = L(
            "on the next line", x)
        let c = "\(L("inside"))"
        let d = L("with \(x)")
        let e = Text("här")
        let f = x.L("member")
        """#
        let (literals, problems) = SwiftLiteralScanner.scan(source, file: "x.swift")
        #expect(problems == [])
        #expect(literals.filter(\.isLookupKey).map(\.value)
            == [#"plain "quoted" text"#, "on the next line", "inside", #"with \(x)"#])
        #expect(literals.first { $0.value == #"with \(x)"# }?.hasInterpolation == true)
        #expect(literals.first { $0.value == "här" }?.isFirstArgument(of: "Text") == true)
        #expect(!literals.contains { $0.value.contains("comment") })
    }

    @Test func scannerCountsArgumentsAndFindsTheCall() {
        let source = #"""
        let a = L("%@ och %@", f(x, y), [1, 2].map { $0 + z })
        let b = L("utan")
        let c = Button(flag ? "en" : L("två")) { run(p, q) }
        let d = Text(verbatim: "rak")
        let e = log?("logg")
        """#
        let (literals, problems) = SwiftLiteralScanner.scan(source, file: "x.swift")
        #expect(problems == [])
        func find(_ value: String) -> SourceLiteral? { literals.first { $0.value == value } }
        #expect(find("%@ och %@")?.argumentCount == 2)
        #expect(find("utan")?.argumentCount == 0)
        #expect(find("två")?.argumentCount == 0)
        #expect(find("en")?.call == "Button")
        #expect(find("en")?.argumentIndex == 0)
        #expect(find("en")?.isLabeled == false)
        #expect(find("två")?.call == "L")
        #expect(find("rak")?.isLabeled == true)
        #expect(find("logg")?.call == "log")
    }
}
