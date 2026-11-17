import Testing
@testable import FilsynkCore

@Suite struct LanguageChoiceTests {
    @Test func storedValueOfEachChoice() {
        #expect(LanguageChoice.system.appleLanguages == nil)
        #expect(LanguageChoice.swedish.appleLanguages == ["sv"])
        #expect(LanguageChoice.english.appleLanguages == ["en"])
    }

    @Test func choiceReadBackFromWhatItStores() {
        for choice in LanguageChoice.allCases {
            #expect(LanguageChoice(appleLanguages: choice.appleLanguages) == choice)
        }
    }

    @Test func choiceFromAStoredValue() {
        #expect(LanguageChoice(appleLanguages: nil) == .system)
        #expect(LanguageChoice(appleLanguages: []) == .system)
        #expect(LanguageChoice(appleLanguages: ["sv-SE", "en"]) == .swedish)
        #expect(LanguageChoice(appleLanguages: ["en-GB", "sv"]) == .english)
        #expect(LanguageChoice(appleLanguages: ["sv_SE"]) == .swedish)
        // The first language the app has decides, as when macOS picks the localization.
        #expect(LanguageChoice(appleLanguages: ["de", "sv"]) == .swedish)
        #expect(LanguageChoice(appleLanguages: ["de", "fr"]) == .system)
    }

    @Test func localizationOfEachChoice() {
        #expect(LanguageChoice.swedish.localization(systemLanguages: ["en-US"]) == "sv")
        #expect(LanguageChoice.english.localization(systemLanguages: ["sv-SE"]) == "en")
        #expect(LanguageChoice.system.localization(systemLanguages: ["sv-SE", "en-US"]) == "sv")
        #expect(LanguageChoice.system.localization(systemLanguages: ["de-DE", "sv-SE"]) == "sv")
        #expect(LanguageChoice.system.localization(systemLanguages: ["de-DE", "fr-FR"]) == "en")
        #expect(LanguageChoice.system.localization(systemLanguages: []) == "en")
    }

    @Test func restartNeededOnlyWhenTheLanguageWouldChange() {
        #expect(!LanguageChoice.swedish.needsRestart(runningLocalization: "sv", systemLanguages: ["en"]))
        #expect(LanguageChoice.swedish.needsRestart(runningLocalization: "en", systemLanguages: ["en"]))
        #expect(LanguageChoice.english.needsRestart(runningLocalization: "sv", systemLanguages: ["sv"]))
        #expect(!LanguageChoice.system.needsRestart(runningLocalization: "sv", systemLanguages: ["sv-SE"]))
        #expect(LanguageChoice.system.needsRestart(runningLocalization: "en", systemLanguages: ["sv-SE"]))
        #expect(!LanguageChoice.system.needsRestart(runningLocalization: "en", systemLanguages: ["de-DE"]))
        #expect(!LanguageChoice.swedish.needsRestart(runningLocalization: "sv-SE", systemLanguages: []))
        #expect(!LanguageChoice.english.needsRestart(runningLocalization: nil, systemLanguages: ["sv"]))
    }
}
