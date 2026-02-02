import SwiftUI

@main
struct MindExtractApp: App {
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(settings.appearanceMode.colorScheme)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 700, height: 700)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
}
