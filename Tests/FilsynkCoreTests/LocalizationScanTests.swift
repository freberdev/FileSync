import Foundation
import Testing

/// Every text the user sees goes through `L`. These scans read the sources under `Sources/`.
@Suite struct LocalizationScanTests {
    /// Literals with å, ä or ö that are not texts for the user: (file, text) and why.
    static let swedishLiteralsOutsideLookup: [(file: String, value: String, reason: String)] = []

    /// Literals passed straight to a call that takes a text, and why they need no translation.
    static let literalsStraightToText: [(file: String, value: String, reason: String)] = [
        ("SyncRunner.swift", #"\(folder.path): \(describe(outcome)) (\(seconds) s)"#,
         "a log line of the folder, the translated outcome and the seconds; s is the same in English"),
        ("DiskSyncRunner.swift", #"\(folder.path) → \(disk.volumeName)/\(disk.path): \(describe(outcome)) (\(seconds) s)"#,
         "a log line of the folder, the disk, the translated outcome and the seconds; s is the same in English"),
        ("AppModel.swift", #"\(notice.title): \(notice.body)"#,
         "a log line of a notice's translated title and body"),
    ]

    /// Calls whose first argument is shown to the user, or becomes a message that is.
    static let textTakingCalls: Set<String> = [
        "Text", "Button", "Label", "Toggle", "Picker", "Section", "help", "Window", "MenuBarExtra",
        "navigationTitle", "TextField", "Menu", "LabeledContent", "TableColumn", "accessibilityLabel",
        "failed", "problem", "rejected", "reject", "unsupportedRsync", "keyCreationFailed", "write", "log",
    ]

    @Test func noSwedishLiteralOutsideLookup() throws {
        let (literals, problems) = try scanSources()
        #expect(problems == [])
        for literal in literals where literal.value.contains(where: { "åäöÅÄÖ".contains($0) }) {
            if literal.isLookupKey {
                if literal.hasInterpolation {
                    Issue.record("\(literal.location): interpolation in a key; use %@: \(literal.value)")
                }
                continue
            }
            let allowed = Self.swedishLiteralsOutsideLookup.contains {
                literal.file.hasSuffix("/" + $0.file) && literal.value == $0.value
            }
            if !allowed { Issue.record("\(literal.location): not passed through L: \(literal.value)") }
        }
    }

    @Test func noLiteralPassedStraightToText() throws {
        let (literals, _) = try scanSources()
        for literal in literals where !literal.isLookupKey && literal.argumentIndex == 0 && !literal.isLabeled {
            guard let name = literal.call, Self.textTakingCalls.contains(name) else { continue }
            if Self.literalsStraightToText.contains(where: { literal.file.hasSuffix("/" + $0.file) && literal.value == $0.value }) {
                continue
            }
            Issue.record("\(literal.location): a literal straight to \(name)(…) is not passed through L: \(literal.value)")
        }
    }

    @Test func everyLookupGetsTheArgumentsItsKeyAsksFor() throws {
        let (literals, _) = try scanSources()
        for key in literals where key.isLookupKey {
            let wanted = formatSpecifiers(key.value).count
            if key.argumentCount != wanted {
                Issue.record("\(key.location): the key has \(wanted) format specifiers but L gets \(key.argumentCount.map(String.init) ?? "?") arguments: \(key.value)")
            }
        }
    }

    @Test func allowListIsInUse() throws {
        let (literals, _) = try scanSources()
        for entry in Self.literalsStraightToText {
            #expect(literals.contains { $0.file.hasSuffix("/" + entry.file) && $0.value == entry.value },
                    "unused: \(entry.file) \(entry.value)")
        }
        for entry in Self.swedishLiteralsOutsideLookup {
            #expect(literals.contains { $0.file.hasSuffix("/" + entry.file) && $0.value == entry.value && !$0.isLookupKey },
                    "unused: \(entry.file) \(entry.value)")
        }
    }
}
