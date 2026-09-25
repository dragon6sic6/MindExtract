import SwiftUI
import Sparkle
import AppKit
import Combine
import UserNotifications

// MARK: - App Delegate (Sparkle + menu bar)

final class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate, UNUserNotificationCenterDelegate {
    let updaterController: SPUStandardUpdaterController
    private var menuBar: MenuBarController?

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
        // Menu-bar control so you can start/stop a note from any app.
        if MeetingRecorder.isSupported {
            menuBar = MenuBarController()
        }
        // Push-to-talk dictation (hold the chosen key).
        DictationController.shared.refresh()
        // Floating pill while recording in another app.
        RecordingPillController.shared.activate()
        // Live captions while recording (if turned on).
        MeetingAutomation.shared.activate()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Clicking the Dock icon with every window closed brings the notes back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindow.show() }
        return true
    }

    // Don't let a recording die silently on quit — offer to stop & transcribe.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Also wait through .finishing so a quit during finalization can't truncate the file.
        if MeetingRecorder.shared.state == .finishing { return .terminateCancel }
        guard MeetingRecorder.shared.isRecording else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "You're still recording"
        alert.informativeText = "Stop and transcribe the recording before quitting, or discard it?"
        alert.addButton(withTitle: "Stop & Transcribe")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard & Quit")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            MeetingRecorder.shared.stop()   // finalizes; user gets the confirm sheet
            return .terminateCancel
        case .alertThirdButtonReturn:
            MeetingRecorder.shared.discardActiveRecording()   // delete the audio, don't leave it for recovery
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}

// MARK: - Menu bar recorder control

/// A status-bar item that starts/stops a note from anywhere and shows elapsed
/// time while recording, plus a way to download from a link.
@MainActor
final class MenuBarController {
    private let item: NSStatusItem
    private var cancellables = Set<AnyCancellable>()

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "MindExtract")
        let recorder = MeetingRecorder.shared
        recorder.$state.sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        recorder.$elapsed.sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        refresh()
    }

    private func refresh() {
        let recorder = MeetingRecorder.shared
        guard let button = item.button else { return }

        if recorder.isRecording {
            let img = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            img?.isTemplate = true   // so the tint actually applies
            button.image = img
            // White icon + white timer text, readable on any menu-bar tint;
            // monospaced digits keep it from jittering.
            button.attributedTitle = NSAttributedString(
                string: " " + AppUtil.formatElapsed(recorder.elapsed),
                attributes: [
                    .foregroundColor: NSColor.white,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
                ])
            button.contentTintColor = .white
        } else {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "MindExtract")
            button.attributedTitle = NSAttributedString(string: "")
            button.contentTintColor = nil
        }

        let menu = NSMenu()
        if recorder.isRecording {
            menu.addItem(withTitle: String(localized: "Stop & Transcribe"), action: #selector(stopTapped), keyEquivalent: "").target = self
        } else if recorder.isBusy {
            let starting = NSMenuItem(title: String(localized: "Starting…"), action: nil, keyEquivalent: "")
            starting.isEnabled = false
            menu.addItem(starting)
        } else {
            menu.addItem(withTitle: String(localized: "New Note"), action: #selector(startTapped), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: String(localized: "Download from Link…"), action: #selector(downloadTapped), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Open MindExtract"), action: #selector(openTapped), keyEquivalent: "").target = self
        item.menu = menu
    }

    @objc private func startTapped() {
        openTapped()
        MeetingRecorder.shared.startNote()
    }
    @objc private func stopTapped() {
        // Bring the app forward now (user-initiated, so macOS honors the activate);
        // the note fills in once finalization completes.
        openTapped()
        MeetingRecorder.shared.stop()
    }
    @objc private func downloadTapped() { MainWindow.show(.downloads) }
    @objc private func openTapped() { MainWindow.show() }
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
            NotesCommands()
        }

        // Native Settings window (⌘,).
        Settings {
            SettingsView(downloader: .shared)
        }
    }
}

// MARK: - Menu commands

struct NotesCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Lets AppKit code reopen the notes window once it has been closed.
        let _ = { MainWindow.opener = openWindow }()
        CommandGroup(replacing: .newItem) {
            Button("New Note") {
                MainWindow.show(.notes)
                MeetingRecorder.shared.startNote()
            }
            .keyboardShortcut("n", modifiers: .command)
            Button("Download from Link…") { MainWindow.show(.downloads) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }
        CommandMenu("Note") {
            Button("Search & Ask…") {
                MainWindow.show()
                NotificationCenter.default.post(name: .openSearch, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)
            // No .disabled — SwiftUI Commands aren't re-evaluated on @Published
            // changes. markMoment() itself no-ops unless recording.
            Button("Mark Moment") { MeetingRecorder.shared.markMoment() }
                .keyboardShortcut("m", modifiers: .command)
        }
        CommandGroup(before: .windowList) {
            Button("Notes") { MainWindow.show(.notes) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Downloads") { MainWindow.show(.downloads) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Dictation") { MainWindow.show(.dictation) }
                .keyboardShortcut("3", modifiers: .command)
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
