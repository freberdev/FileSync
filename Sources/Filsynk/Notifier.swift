import Foundation
@preconcurrency import UserNotifications
import FilsynkCore

/// Posts user notifications; asks for permission the first time one is posted.
/// Falls back to the log when permission is missing, posting fails or the process has no app bundle.
struct Notifier: Sendable {
    let log: FileLog

    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    func post(_ notice: Notice) {
        let line = "\(notice.title): \(notice.body)"
        guard canNotify else {
            log.write(L("Avisering (inte tillgänglig): %@", line))
            return
        }
        let log = self.log
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                log.write(L("Avisering nekad: %@", line))
                return
            }
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { error in
                if let error { log.write(L("Avisering misslyckades (%@): %@", error.localizedDescription, line)) }
            }
        }
    }
}
