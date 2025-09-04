import UserNotifications

enum NotificationHelper {
    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    static func schedulePrompt(after seconds: TimeInterval, title: String, body: String, id: String) {
        // Placeholder for future “prompt to resume” feature
    }
    static func cancelAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}
