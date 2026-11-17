import Foundation

/// The text in the app's language. The key is the Swedish text.
///
/// The tables are `sv.lproj` and `en.lproj` in the app bundle. Without them, as in the tests,
/// every text is the Swedish key itself.
public func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// The text in the app's language with the arguments filled in, as by `String(format:)`.
public func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), arguments: arguments)
}
