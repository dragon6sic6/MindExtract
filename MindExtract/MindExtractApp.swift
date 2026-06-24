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

    func applicationDidFinishLaunching(_ notification: Notification) {
        updaterController.startUpdater()
        // Register the notification delegate + category FIRST, so the very first
        // nudge (a call already in progress at launch) carries its "Record" action.
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let record = UNNotificationAction(identifier: "RECORD", title: "Record", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "MEETING_DETECTED", actions: [record],
                                   intentIdentifiers: [], options: [])
        ])
        // Ask for notification permission up front — without it macOS silently drops
        // the "meeting detected" banner. (The floating prompt works regardless.)
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // Menu-bar control so you can start/stop a recording mid-call from any app.
        if MeetingRecorder.isSupported {
            menuBar = MenuBarController()
            // Run call + calendar detection app-wide (not just on the Record tab)
            // so the nudge can fire whenever you're in / about to be in a meeting.
            ActiveMeetingDetector.shared.startMonitoring()
            MeetingCalendar.shared.startMonitoring()
        }
        // Light up the intelligence layer on existing meetings: generate any missing
        // AI briefs in the background shortly after launch (idempotent, capped).
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            TranscriptionManager.shared.backfillMeetingBriefs()
        }
    }

    // postNudge already only fires when backgrounded, so a banner is always the
    // right call here. (Kept simple — completionHandler isn't Sendable, so no hop.)
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        // Pull Sendable values out before hopping to the main actor (the response
        // object itself isn't Sendable).
        let info = response.notification.request.content.userInfo
        let app = info["app"] as? String
        let isCalendar = info["calendar"] as? Bool == true
        let isRecordAction = response.actionIdentifier == "RECORD"
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            if isRecordAction, !MeetingRecorder.shared.isBusy {
                if isCalendar, let m = MeetingCalendar.shared.currentMeeting {
                    // Record the scheduled meeting with its title + attendees (for the recap).
                    let prefill = m.attendees.isEmpty ? "" : "Attendees: " + m.attendees.joined(separator: ", ") + "\n\n"
                    MeetingRecorder.shared.start(meetingTitle: m.title, notesPrefill: prefill,
                                                 attendees: m.attendees, attendeeEmails: m.attendeeEmails)
                } else {
                    MeetingRecorder.shared.start(meetingTitle: app.map { "\($0) call" })
                }
            } else {
                NotificationCenter.default.post(name: .navigate, object: SidebarItem.record)
            }
        }
        completionHandler()   // macOS keeps the app alive; safe to ack now
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
        // Reflect a detected meeting (active call or calendar event) in the menu bar,
        // so the user gets a calm, always-present "record this?" without a popup.
        ActiveMeetingDetector.shared.$activeApp.sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        MeetingCalendar.shared.$currentMeeting.sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        refresh()
    }

    /// A meeting MindExtract has detected and could record right now (live calendar
    /// event preferred, else an app/browser actively in a call).
    private var detectedMeeting: (title: String, attendees: [String], emails: [String])? {
        if let m = MeetingCalendar.shared.currentMeeting, m.isLive {
            return (m.title, m.attendees, m.attendeeEmails)
        }
        if let app = ActiveMeetingDetector.shared.activeApp {
            return (ActiveMeetingDetector.shared.activeIsBrowser ? "Video call" : "\(app) call", [], [])
        }
        return nil
    }

    private func refresh() {
        let recorder = MeetingRecorder.shared
        guard let button = item.button else { return }
        let detected = detectedMeeting

        if recorder.isRecording {
            let img = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            img?.isTemplate = true   // so the tint actually applies (was rendering black)
            button.image = img
            // White icon + white timer text, readable on any menu-bar tint. The
            // ticking timer is the unmistakable "recording" cue. monospaced digits
            // keep it from jittering.
            button.attributedTitle = NSAttributedString(
                string: " " + RecordingView.formatElapsed(recorder.elapsed),
                attributes: [
                    .foregroundColor: NSColor.white,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
                ])
            button.contentTintColor = .white
        } else if detected != nil, !recorder.isBusy {
            // A meeting is happening — a calm orange dot (distinct from the red
            // "recording" state). The actual prompt is the banner notification; we
            // keep the menu-bar text empty so it can't render as invisible black.
            let img = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Meeting detected — record?")
            img?.isTemplate = true   // template image so contentTintColor actually applies
            button.image = img
            button.attributedTitle = NSAttributedString(string: "")
            button.contentTintColor = .systemOrange
        } else {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Record")
            button.attributedTitle = NSAttributedString(string: "")
            button.contentTintColor = nil
        }

        let menu = NSMenu()
        if recorder.isRecording {
            menu.addItem(withTitle: "Stop & Transcribe", action: #selector(stopTapped), keyEquivalent: "").target = self
        } else if recorder.isBusy {
            let starting = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
            starting.isEnabled = false
            menu.addItem(starting)
        } else if let detected {
            let header = NSMenuItem(title: "Meeting detected", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(withTitle: "Record “\(detected.title)”", action: #selector(recordDetectedTapped), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Start a blank recording", action: #selector(startTapped), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "Start Recording", action: #selector(startTapped), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open MindExtract", action: #selector(openTapped), keyEquivalent: "").target = self
        item.menu = menu
    }

    @objc private func startTapped() { MeetingRecorder.shared.start() }
    @objc private func recordDetectedTapped() {
        guard let d = detectedMeeting else { MeetingRecorder.shared.start(); return }
        MeetingRecorder.shared.start(meetingTitle: d.title, attendees: d.attendees, attendeeEmails: d.emails)
    }
    @objc private func stopTapped() {
        // Bring the app forward now (user-initiated, so macOS honors the activate);
        // the "Recording finished" sheet appears once finalization completes.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
        MeetingRecorder.shared.stop()
    }
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
                Button("Today") { NotificationCenter.default.post(name: .navigate, object: SidebarItem.today) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Meetings") { NotificationCenter.default.post(name: .navigate, object: SidebarItem.record) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Transcribe") { NotificationCenter.default.post(name: .navigate, object: SidebarItem.download) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Library") { NotificationCenter.default.post(name: .navigate, object: SidebarItem.transcripts) }
                    .keyboardShortcut("4", modifiers: .command)
                Button("People") { NotificationCenter.default.post(name: .navigate, object: SidebarItem.people) }
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
