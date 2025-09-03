import SwiftUI

@main
struct TheSoftLifeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(PlayerVM())
        }
    }
}
