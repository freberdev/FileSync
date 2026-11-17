import Foundation
import FilsynkCore

/// Reads and stores the language choice as the app's own `AppleLanguages` default.
enum AppLanguage {
    private static let key = "AppleLanguages"

    /// Only the app's own domain: `UserDefaults.standard.object(forKey:)` would also find the system's list.
    static var choice: LanguageChoice {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
        return LanguageChoice(appleLanguages: domain?[key] as? [String])
    }

    static func setChoice(_ choice: LanguageChoice) {
        if let languages = choice.appleLanguages {
            UserDefaults.standard.set(languages, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// True when the choice gives another language than the one the app is running in.
    static func needsRestart(_ choice: LanguageChoice) -> Bool {
        // The user's list for all apps; `Locale.preferredLanguages` would include this app's own choice.
        let system = CFPreferencesCopyValue(
            key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
        return choice.needsRestart(
            runningLocalization: Bundle.main.preferredLocalizations.first,
            systemLanguages: system ?? [])
    }
}
