import SwiftUI
import Sparkle
import AppKit
import Combine

// MARK: - App Delegate (Sparkle + menu bar)

final class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        updaterController.startUpdater()
        // Menu-bar control so you can start/stop a recording mid-call from any app.
        if MeetingRecorder.isSupported {
            menuBar = MenuBarController()
        }
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

/// A status-bar item that starts/stops meeting recording from anywhere and shows
/// elapsed time while recording — the natural flow when you're in a call and the
/// app isn't frontmost.
@MainActor
final class MenuBarController {
    private let item: NSStatusItem
    private var cancellables = Set<AnyCancellable>()

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "MindExtract recording")
        let recorder = MeetingRecorder.shared
        recorder.$state.sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        recorder.$elapsed.sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        refresh()
    }

    private func refresh() {
        let recorder = MeetingRecorder.shared
        guard let button = item.button else { return }

        if recorder.isRecording {
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            button.title = " " + RecordingView.formatElapsed(recorder.elapsed)
            button.contentTintColor = .systemRed   // unmistakably "recording"
        } else {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Record")
            button.title = ""
            button.contentTintColor = nil
        }

        let menu = NSMenu()
        if recorder.isRecording {
            menu.addItem(withTitle: "Stop & Transcribe", action: #selector(stopTapped), keyEquivalent: "").target = self
        } else if recorder.isBusy {
            let starting = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
            starting.isEnabled = false
            menu.addItem(starting)
        } else {
            menu.addItem(withTitle: "Start Recording", action: #selector(startTapped), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open MindExtract", action: #selector(openTapped), keyEquivalent: "").target = self
        item.menu = menu
    }

    @objc private func startTapped() { MeetingRecorder.shared.start() }
    @objc private func stopTapped() { MeetingRecorder.shared.stop() }
    @objc private func openTapped() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Launcher
//
// When spawned with `--mcp` (by Claude Desktop or another MCP client), run the
// stdio MCP server and never start the GUI. Otherwise launch the normal app.

@main
struct AppLauncher {
    static func main() {
        if CommandLine.arguments.contains("--mcp") {
            MCPServer.run()
            return
        }
        MindExtractApp.main()
    }
}

// MARK: - Main App

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
                Button("Search & Ask…") { NotificationCenter.default.post(name: .openSearch, object: nil) }
                    .keyboardShortcut("k", modifiers: .command)
                // No .disabled — SwiftUI Commands aren't re-evaluated on @Published
                // changes, so a disabled binding would be stuck. markMoment() itself
                // no-ops unless recording, which is the correct HIG behavior.
                Button("Mark Moment") { MeetingRecorder.shared.markMoment() }
                    .keyboardShortcut("m", modifiers: .command)
                Divider()
                Button("Media") { NotificationCenter.default.post(name: .navigate, object: SidebarItem.download) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Record") { NotificationCenter.default.post(name: .navigate, object: SidebarItem.record) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Transcripts") { NotificationCenter.default.post(name: .navigate, object: SidebarItem.transcripts) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("History") { NotificationCenter.default.post(name: .navigate, object: SidebarItem.history) }
                    .keyboardShortcut("4", modifiers: .command)
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
    static let navigate = Notification.Name("navigate")
    static let checkForUpdates = Notification.Name("checkForUpdates")
    static let openSearch = Notification.Name("openSearch")
}
