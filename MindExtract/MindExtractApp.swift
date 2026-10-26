import SwiftUI
import Sparkle
import AppKit
import UserNotifications

// MARK: - App Delegate (Sparkle)

final class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate, UNUserNotificationCenterDelegate {
    let updaterController: SPUStandardUpdaterController

    override init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    /// Applies the Settings → General appearance to every window and panel.
    static func applyAppearance(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        updaterController.startUpdater()
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Clicking the Dock icon with every window closed brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindow.show() }
        return true
    }
}

// MARK: - Main App

@main
struct MindExtractApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        Window("MindExtract", id: MainWindow.id) {
            // Follows the system appearance (light/dark) and accent color unless
            // the user picked one in Settings → General.
            ContentView()
                .onAppear { AppDelegate.applyAppearance(settings.appAppearance) }
                .onChange(of: settings.appAppearance) { _, value in AppDelegate.applyAppearance(value) }
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
            CommandGroup(replacing: .help) {
                Button("MindExtract Help") {
                    if let url = URL(string: "https://github.com/dragon6sic6/MindExtract#readme") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .keyboardShortcut("?", modifiers: .command)
            }
            AppCommands()
        }

        // Native Settings window (⌘,).
        Settings {
            SettingsView(downloader: .shared)
        }
    }
}

// MARK: - Menu commands

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Lets AppKit code reopen the main window once it has been closed.
        let _ = { MainWindow.opener = openWindow }()
        CommandGroup(replacing: .newItem) {
            Button("Download or Transcribe…") { MainWindow.show(.downloads) }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("Transcript") {
            Button("Search & Ask…") {
                MainWindow.show()
                NotificationCenter.default.post(name: .openSearch, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)
        }
        CommandGroup(before: .windowList) {
            Button("Download") { MainWindow.show(.downloads) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Transcripts") { MainWindow.show(.transcripts) }
                .keyboardShortcut("2", modifiers: .command)
            Divider()
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
    static let showDownloads = Notification.Name("showDownloads")
    static let checkForUpdates = Notification.Name("checkForUpdates")
    static let openSearch = Notification.Name("openSearch")
}
