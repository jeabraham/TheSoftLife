// swift
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        print("User tapped notification:", response.actionIdentifier)
        completionHandler()
    }
}

@main
struct TheSoftLifeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var vm = PlayerVM()

    init() {
        requestNotificationPermissionIfNeeded()
        registerNotificationCategories()
        if UserDefaults.standard.object(forKey: "subliminalBackgrounds") == nil {
            AppAudioSettings.subliminalBackgrounds = false
        }
        // For testing
        AppAudioSettings.subliminalBackgrounds = false
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
                .onAppear {
                    guard AppAudioSettings.subliminalBackgrounds else { return }
                    // Run build in background so launch isn't blocked
                    DispatchQueue.global(qos: .background).async {
                        rebuildBundleSubliminals(vm: vm)
                    }
                }
        }
    }
}

private func rebuildBundleSubliminals(vm: PlayerVM) {
    DispatchQueue.main.async {
        vm.statusText = "Rebuilding bundle subliminals…"
    }

    SubliminalFolderBuilder.buildFromBundleFolder(
        synthQueue: vm.synthQueue,
        progress: { msg in
            DispatchQueue.main.async {
                vm.statusText = msg
            }
        }
    ) { result in
        DispatchQueue.main.async {
            switch result {
            case .success(let urls):
                vm.statusText = "Rebuilt bundle subliminals (\(urls.count))."
            case .failure(let error):
                vm.statusText = "Bundle rebuild failed: \(error.localizedDescription)"
            }
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
