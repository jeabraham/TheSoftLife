import SwiftUI
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        SubliminalFolderBuilder.buildFromBundleFolder("subliminal_phrases") { result in
            print("Build finished:", result)
        }
        return true
        
        // Called when user taps a notification or action
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            print("User tapped notification:", response.actionIdentifier)
            // TODO: resume playback etc.
            completionHandler()
        }
        
    }
}

@main
struct TheSoftLifeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        requestNotificationPermissionIfNeeded()
        registerNotificationCategories()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(PlayerVM())
        }
    }
}

func registerNotificationCategories() {
    let start = UNNotificationAction(
        identifier: "START_NOW",
        title: "Start now",
        options: [.foreground]
    )
    let snooze10 = UNNotificationAction(
        identifier: "SNOOZE_10",
        title: "Snooze 10 min",
        options: []
    )
    let cat = UNNotificationCategory(
        identifier: "NEXT_FILE_CATEGORY",
        actions: [start, snooze10],
        intentIdentifiers: [],
        options: []
    )
    UNUserNotificationCenter.current().setNotificationCategories([cat])
}

func requestNotificationPermissionIfNeeded() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
}
