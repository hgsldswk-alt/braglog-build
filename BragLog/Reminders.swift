import Foundation
import UserNotifications

actor WeeklyReminder {
    static let identifier = "weekly-win"

    func apply(_ reminder: Reminder, ask: Bool) async throws -> Bool {
        if Launch.testing { return reminder.enabled && !Launch.testFlag("-deny-notifications") }
        let center = UNUserNotificationCenter.current()
        guard reminder.enabled else {
            center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
            return false
        }
        let state = await center.notificationSettings().authorizationStatus
        let allowed: Bool
        switch state {
        case .authorized, .provisional, .ephemeral: allowed = true
        case .notDetermined where ask:
            allowed = try await center.requestAuthorization(options: [.alert, .sound])
        default: allowed = false
        }
        try Task.checkCancellation()
        if allowed {
            let content = UNMutableNotificationContent()
            content.title = L.t("app.name")
            content.body = L.t("reminder.body")
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: reminder.components, repeats: true)
            try await center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: trigger))
        } else {
            center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        }
        return allowed
    }
}
