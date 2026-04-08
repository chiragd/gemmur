import SwiftUI

@main
struct GemmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings window — opened via the menu bar menu
        WindowGroup("Settings", id: "settings") {
            SettingsView()
                .frame(minWidth: 480, minHeight: 360)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commandsRemoved()
    }
}
