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

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 2.8 could run as an MCP server for Claude Desktop, which may still
        // launch us with --mcp. That's gone; leave at once instead of
        // starting a hidden second copy.
        if CommandLine.arguments.contains("--mcp") { exit(0) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchedAtLogin = Self.isLoginLaunch()
        updaterController.startUpdater()
        AppSettings.shared.migrate()
        UNUserNotificationCenter.current().delegate = self
        NotchController.shared.start()
        LoginItem.enableOnFirstRun()
        // First run: the notch introduces itself.
        if !Onboarding.hasBeenSeen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { Onboarding.start() }
        } else if !launchedAtLogin {
            // Opened by hand (Finder, Spotlight): show where it went.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NotchController.shared.open(.reopen) }
        }
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

    /// Started by "Open at login" rather than by the user.
    private static func isLoginLaunch() -> Bool {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        return ProcessInfo.processInfo.systemUptime < 120   // right after a restart or login
    }

    /// Quitting mid-job would leave yt-dlp or ffmpeg running, so ask, then stop them.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard NotchModel.shared.isBusy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "Quit while it's working?")
        alert.informativeText = String(localized: "The download or transcription in progress will stop.")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Keep Working"))
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotchModel.shared.cancel()
        YTDLPWrapper.shared.reset()
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
