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

    /// Applies the Settings → General appearance to the settings window.
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
        NotchController.shared.start()
        LoginItem.enableOnFirstRun()
        NotificationCenter.default.addObserver(forName: .checkForUpdates, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updaterController.checkForUpdates(nil) }
        }
        // Swedish users get Pianissimo on first launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { PianissimoOffer.autoStartIfNeeded() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Opening the app again (Spotlight, Finder) opens the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotchController.shared.open(.reopen)
        return false
    }
}

// MARK: - Main App

@main
struct MindExtractApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Everything happens in the notch. Settings is its own black window;
        // ⌘, opens that one rather than a system settings window.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsWindow.show() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let checkForUpdates = Notification.Name("checkForUpdates")
}
