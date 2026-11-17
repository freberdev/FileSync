import Foundation

/// The repository's source files and string tables, read from disk.
enum Repository {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func stringsTable(_ language: String) throws -> [String: String] {
        let url = root.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let table = object as? [String: String] else { throw ScanError.notATable(url.path) }
        return table
    }

    /// Every `.swift` file under `Sources/`, by path relative to the repository.
    static func sourceFiles() throws -> [(path: String, text: String)] {
        let sources = root.appendingPathComponent("Sources")
        guard let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            throw ScanError.notATable(sources.path)
        }
        var result: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            result.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        return result.sorted { $0.0 < $1.0 }
    }

    enum ScanError: Error { case notATable(String) }
}

/// A string literal in Swift source, with what stands right before it.
struct SourceLiteral: Equatable {
    var file: String
    var line: Int
    /// The text with escapes resolved; an interpolation is kept as `\(…)`.
    var value: String
    var hasInterpolation: Bool
    var isMultiLine: Bool
    var isRaw: Bool
    /// The tokens before the literal on its nesting level, nearest last: for `L("x")` this is `["L", "("]`.
    var before: [String]
    /// The call whose parentheses most closely enclose the literal (`"x"` in `f(a ? "x" : y)` is in `f`),
    /// nil when it is closer inside `[…]` or `{…}`, or outside any call.
    var call: String? = nil
    /// Which argument of `call` the literal stands in, from 0.
    var argumentIndex = 0
    /// The argument has a label, as in `Text(verbatim: "x")`.
    var isLabeled = false
    /// For a key of `L`: the number of arguments after it.
    var argumentCount: Int? = nil

    /// The first argument of a call to the lookup function `L`.
    var isLookupKey: Bool {
        guard before.count >= 2, before[before.count - 1] == "(", before[before.count - 2] == "L" else { return false }
        return before.count < 3 || before[before.count - 3] != "."
    }

    /// The literal is the first argument of a call to `name` (a free function or a method).
    func isFirstArgument(of name: String) -> Bool {
        before.count >= 2 && before[before.count - 1] == "(" && before[before.count - 2] == name
    }

    var location: String { "\(file):\(line)" }
}

/// Finds the string literals in Swift source. Comments are skipped; literals inside an
/// interpolation are found too.
struct SwiftLiteralScanner {
    private let scalars: [Unicode.Scalar]
    private let file: String
    private var index = 0
    private var line = 1
    private(set) var literals: [SourceLiteral] = []
    private(set) var problems: [String] = []

    static func scan(_ text: String, file: String) -> (literals: [SourceLiteral], problems: [String]) {
        var scanner = SwiftLiteralScanner(text: text, file: file)
        scanner.scanCode(untilClosingParen: false)
        return (scanner.literals, scanner.problems)
    }

    private init(text: String, file: String) {
        self.scalars = Array(text.unicodeScalars)
        self.file = file
    }

    private func peek(_ offset: Int = 0) -> Unicode.Scalar? {
        index + offset < scalars.count ? scalars[index + offset] : nil
    }

    private mutating func advance() {
        if scalars[index] == "\n" { line += 1 }
        index += 1
    }

    private func isIdentifierScalar(_ s: Unicode.Scalar) -> Bool {
        s == "_" || s.properties.isAlphabetic || ("0"..."9").contains(s)
    }

    /// Code: tokens, comments and literals. Inside an interpolation it ends at the matching `)`.
    private struct Frame {
        /// `(`, `[` or `{`.
        var opener: Character
        var call: String?
        var argumentIndex = 0
        /// The tokens of the current argument so far.
        var argumentTokens: [String] = []
        /// The index in `literals` of the key, when this is a call of `L` with a literal first.
        var key: Int?
    }

    private mutating func scanCode(untilClosingParen: Bool) {
        var tokens: [String] = []
        var depth = 0
        var frames: [Frame] = []
        func push(_ token: String) {
            tokens.append(token)
            if tokens.count > 8 { tokens.removeFirst() }
            if !frames.isEmpty { frames[frames.count - 1].argumentTokens.append(token) }
        }
        func isWord(_ token: String) -> Bool {
            token.unicodeScalars.first.map { $0 == "_" || $0.properties.isAlphabetic } ?? false
        }
        while let c = peek() {
            if c == "/" && peek(1) == "/" {
                while let d = peek(), d != "\n" { advance() }
            } else if c == "/" && peek(1) == "*" {
                skipBlockComment()
            } else if c == "\"" || (c == "#" && (peek(1) == "\"" || peek(1) == "#")) && startsRawLiteral() {
                let first = frames.last.map { $0.argumentIndex == 0 && $0.argumentTokens.isEmpty } ?? false
                scanLiteral(before: tokens)
                if var frame = frames.last, frame.opener == "(" {
                    literals[literals.count - 1].call = frame.call
                    literals[literals.count - 1].argumentIndex = frame.argumentIndex
                    let argument = frame.argumentTokens
                    literals[literals.count - 1].isLabeled = argument.count >= 2 && isWord(argument[0]) && argument[1] == ":"
                    if first && frame.call == "L" && literals[literals.count - 1].isLookupKey {
                        frame.key = literals.count - 1
                        frames[frames.count - 1] = frame
                    }
                }
                push("\"…\"")
            } else if isIdentifierScalar(c) {
                var word = ""
                while let d = peek(), isIdentifierScalar(d) { word.unicodeScalars.append(d); advance() }
                push(word)
            } else if c == " " || c == "\t" || c == "\n" || c == "\r" {
                advance()
            } else {
                if c == "(" { depth += 1 }
                if c == ")" {
                    if untilClosingParen && depth == 0 { advance(); return }
                    depth -= 1
                }
                if c == "(" || c == "[" || c == "{" {
                    // The callee: `f(`, `x.f(`, `f?(`; `L` only as a free function.
                    var call: String?
                    if c == "(" {
                        var previous = tokens
                        if previous.last == "?" { previous.removeLast() }
                        if let name = previous.last, isWord(name) {
                            call = name == "L" && previous.dropLast().last == "." ? nil : name
                        }
                    }
                    push(String(c))
                    frames.append(Frame(opener: Character(String(c)), call: call))
                } else if c == ")" || c == "]" || c == "}" {
                    if let frame = frames.popLast(), let key = frame.key {
                        literals[key].argumentCount = frame.argumentIndex
                    }
                    push(String(c))
                } else if c == ",", !frames.isEmpty {
                    push(",")
                    frames[frames.count - 1].argumentIndex += 1
                    frames[frames.count - 1].argumentTokens = []
                } else {
                    push(String(c))
                }
                advance()
            }
        }
        if untilClosingParen { problems.append("\(file):\(line): an interpolation is not closed") }
    }

    /// `#"`, `##"` and so on start a raw literal; a `#` before anything else is a directive.
    private func startsRawLiteral() -> Bool {
        if peek() == "\"" { return true }
        var offset = 0
        while peek(offset) == "#" { offset += 1 }
        return peek(offset) == "\""
    }

    private mutating func skipBlockComment() {
        var depth = 0
        repeat {
            if peek() == "/" && peek(1) == "*" { depth += 1; advance(); advance() }
            else if peek() == "*" && peek(1) == "/" { depth -= 1; advance(); advance() }
            else if peek() != nil { advance() }
            else { return }
        } while depth > 0
    }

    private mutating func scanLiteral(before: [String]) {
        let startLine = line
        var hashes = 0
        while peek() == "#" { hashes += 1; advance() }
        let multiLine = peek() == "\"" && peek(1) == "\"" && peek(2) == "\""
        let quotes = multiLine ? 3 : 1
        for _ in 0..<quotes { advance() }
        let rawMarker = String(repeating: "#", count: hashes)

        var value = ""
        var interpolated = false
        while true {
            guard let c = peek() else {
                problems.append("\(file):\(startLine): a string literal is not closed")
                return
            }
            if c == "\"" && closes(quotes: quotes, hashes: hashes) {
                for _ in 0..<(quotes + hashes) { advance() }
                break
            }
            if !multiLine && c == "\n" {
                problems.append("\(file):\(startLine): a string literal is not closed")
                return
            }
            if c == "\\" && hashesFollow(hashes, at: 1) {
                let escaped = peek(1 + hashes)
                for _ in 0..<(1 + hashes) { advance() }
                switch escaped {
                case "(":
                    advance()
                    interpolated = true
                    value += "\\" + rawMarker + "("
                    let start = index
                    scanCode(untilClosingParen: true)
                    var expression = String.UnicodeScalarView()
                    expression.append(contentsOf: scalars[start..<max(start, index - 1)])
                    value += String(expression) + ")"
                case "n": value += "\n"; advance()
                case "t": value += "\t"; advance()
                case "r": value += "\r"; advance()
                case "0": value += "\0"; advance()
                case "\\": value += "\\"; advance()
                case "\"": value += "\""; advance()
                case "'": value += "'"; advance()
                case "u":
                    advance()
                    var hex = ""
                    if peek() == "{" { advance() }
                    while let d = peek(), d != "}" { hex.unicodeScalars.append(d); advance() }
                    advance()
                    if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                        value.unicodeScalars.append(scalar)
                    }
                case "\n", " ", "\t":
                    // A line continuation in a multi-line literal.
                    while let d = peek(), d != "\n" { advance() }
                    if peek() == "\n" { advance() }
                default:
                    problems.append("\(file):\(line): unknown escape in a string literal")
                }
                continue
            }
            value.unicodeScalars.append(c)
            advance()
        }
        literals.append(SourceLiteral(
            file: file, line: startLine, value: value, hasInterpolation: interpolated,
            isMultiLine: multiLine, isRaw: hashes > 0, before: before))
    }

    private func closes(quotes: Int, hashes: Int) -> Bool {
        for offset in 0..<quotes where peek(offset) != "\"" { return false }
        return hashesFollow(hashes, at: quotes)
    }

    private func hashesFollow(_ hashes: Int, at offset: Int) -> Bool {
        for i in 0..<hashes where peek(offset + i) != "#" { return false }
        return true
    }
}

/// The literals of every source file under `Sources/`.
func scanSources() throws -> (literals: [SourceLiteral], problems: [String]) {
    var literals: [SourceLiteral] = []
    var problems: [String] = []
    for file in try Repository.sourceFiles() {
        let result = SwiftLiteralScanner.scan(file.text, file: file.path)
        literals += result.literals
        problems += result.problems
    }
    return (literals, problems)
}

/// The format specifiers of a `String(format:)` text as their types in argument order; `%%` is not one.
/// Positional forms (`%2$@`) count at their position.
func formatSpecifiers(_ text: String) -> [String] {
    let pattern = #"%(?:(\d+)\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA%])"#
    let regex = try! NSRegularExpression(pattern: pattern)
    var next = 1
    var found: [(Int, String)] = []
    let ns = text as NSString
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        let conversion = ns.substring(with: match.range(at: 3))
        if conversion == "%" { continue }
        let length = match.range(at: 2).location == NSNotFound ? "" : ns.substring(with: match.range(at: 2))
        let position: Int
        if match.range(at: 1).location != NSNotFound {
            position = Int(ns.substring(with: match.range(at: 1)))!
        } else {
            position = next
            next += 1
        }
        found.append((position, length + conversion))
    }
    return found.sorted { $0.0 < $1.0 }.map(\.1)
}
