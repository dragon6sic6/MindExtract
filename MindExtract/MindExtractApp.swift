import SwiftUI
import Sparkle

// MARK: - App Delegate (Sparkle)

final class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    let updaterController: SPUStandardUpdaterController

    override init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        updaterController.startUpdater()
    }
}

// MARK: - Main App

@main
struct MindExtractApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(DS.Colors.accent)
                .preferredColorScheme(.dark)
                .onAppear { NSApp.appearance = NSAppearance(named: .darkAqua) }
                .onReceive(NotificationCenter.default.publisher(for: .checkForUpdates)) { _ in
                    appDelegate.updaterController.checkForUpdates(nil)
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1000, height: 740)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    appDelegate.updaterController.checkForUpdates(nil)
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("MindExtract Help") {
                    if let url = URL(string: "https://github.com/dragon6sic6/MindExtract#readme") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .keyboardShortcut("?", modifiers: .command)
            }
            CommandMenu("Go") {
                Button("Media") { NotificationCenter.default.post(name: .navigate, object: SidebarItem.download) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Transcripts") { NotificationCenter.default.post(name: .navigate, object: SidebarItem.transcripts) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("History") { NotificationCenter.default.post(name: .navigate, object: SidebarItem.history) }
                    .keyboardShortcut("3", modifiers: .command)
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
    static let navigate = Notification.Name("navigate")
    static let checkForUpdates = Notification.Name("checkForUpdates")
}
