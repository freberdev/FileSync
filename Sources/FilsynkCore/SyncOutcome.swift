import Foundation

public enum SyncOutcome: Equatable, Sendable {
    case success
    case unreachable
    case authDenied
    case failed(String)

    public var message: String? {
        switch self {
        case .success: return nil
        case .unreachable: return "Servern nås inte"
        case .authDenied: return "Inloggningen nekades"
        case .failed(let m): return m
        }
    }
}

public enum OutcomeClassifier {
    private static let authMarkers = [
        "Host key verification failed",
        "REMOTE HOST IDENTIFICATION HAS CHANGED",
        "Too many authentication failures",
    ]
    private static let unreachableMarkers = [
        "Connection refused", "Connection timed out", "Operation timed out",
        "No route to host", "Network is unreachable", "Could not resolve hostname",
        "Connection closed", "Connection reset", "Broken pipe",
    ]

    public static func classify(exitCode: Int32, stderr: String) -> SyncOutcome {
        if exitCode == 0 || exitCode == 24 { return .success }
        if authMarkers.contains(where: stderr.contains) || containsSSHPermissionDenied(stderr) {
            return .authDenied
        }
        if stderr.contains("No space left on device") { return .failed("Disken på servern är full") }
        if unreachableMarkers.contains(where: stderr.contains) { return .unreachable }
        let last = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        guard let last else { return .failed("rsync avslutades med kod \(exitCode)") }
        return .failed(String(last.prefix(200)))
    }

    /// ssh lists auth methods after "Permission denied (", rsync writes an errno number.
    private static func containsSSHPermissionDenied(_ text: String) -> Bool {
        let marker = "Permission denied ("
        var rest = text[...]
        while let r = rest.range(of: marker) {
            if let next = rest[r.upperBound...].first, next.isLetter { return true }
            rest = rest[r.upperBound...]
        }
        return false
    }
}
