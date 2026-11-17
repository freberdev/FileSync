import Foundation

/// The language picked in the settings. It is kept as the app's own `AppleLanguages` default,
/// which macOS reads when the app starts, so a change takes effect at the next start.
public enum LanguageChoice: String, CaseIterable, Sendable {
    case system, swedish, english

    /// The localizations the app has; the first is used when the system prefers neither.
    static let localizations = ["en", "sv"]

    /// The value to store as the app's `AppleLanguages`; nil means the key is removed.
    public var appleLanguages: [String]? {
        switch self {
        case .system: return nil
        case .swedish: return ["sv"]
        case .english: return ["en"]
        }
    }

    /// The choice a stored `AppleLanguages` value stands for: the first language in it that the app
    /// has decides, as when macOS picks the localization. Nothing stored, or none of them, is `.system`.
    public init(appleLanguages: [String]?) {
        switch Self.firstLocalization(in: appleLanguages ?? []) {
        case "sv": self = .swedish
        case "en": self = .english
        default: self = .system
        }
    }

    /// The localization ("sv" or "en") the app runs in with this choice, given the system's languages.
    public func localization(systemLanguages: [String]) -> String {
        switch self {
        case .swedish: return "sv"
        case .english: return "en"
        case .system: return Self.firstLocalization(in: systemLanguages) ?? Self.localizations[0]
        }
    }

    /// True when the app runs in another localization than this choice gives, so that the choice
    /// takes effect only at the next start. Without a known running localization, false.
    public func needsRestart(runningLocalization: String?, systemLanguages: [String]) -> Bool {
        guard let running = runningLocalization.map(Self.languageCode) else { return false }
        return running != localization(systemLanguages: systemLanguages)
    }

    private static func firstLocalization(in languages: [String]) -> String? {
        languages.map(languageCode).first(where: localizations.contains)
    }

    /// "sv-SE" and "sv_SE" are "sv".
    private static func languageCode(_ identifier: String) -> String {
        String(identifier.prefix { $0 != "-" && $0 != "_" }).lowercased()
    }
}
