import Foundation
import SwiftUI
import AppKit
import CoreAudio
import UserNotifications

// MARK: - Active call detection (provider-agnostic, per-process precise)
//
// Calendar detection only catches *scheduled* meetings. This catches a call
// that's actually happening right now — Zoom, Teams, a Google Meet tab, … —
// regardless of which calendar (or no calendar) it came from.
//
// Fully on-device. We use the macOS 14+ Core Audio process API to ask, per
// process, "is THIS app capturing the microphone right now?" That's exact: a
// background call app plus an unrelated mic user (Dictation, Voice Memos) no
// longer looks like a call. We never read audio content; only the running flag.

@MainActor
final class ActiveMeetingDetector: ObservableObject {
    static let shared = ActiveMeetingDetector()

    /// Display name of the app currently in a call (nil = none detected).
    @Published private(set) var activeApp: String?
    /// True when the call is happening in a web browser (Meet/Zoom web/Teams web…).
    @Published private(set) var activeIsBrowser = false

    // Matched as case-insensitive PREFIXES against the bundle ID of whatever
    // process is actually capturing the mic — so helper/renderer processes count
    // too (new Teams captures via "com.microsoft.teams2.helper"; Google Meet via a
    // Chrome renderer helper). Order = display priority.
    private static let conferencingPrefixes: [(String, String)] = [
        ("us.zoom", "Zoom"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.microsoftedge.msteams", "Microsoft Teams"),
        ("com.cisco.webex", "Webex"), ("com.webex", "Webex"), ("cisco-systems.spark", "Webex"),
        ("com.logmein.gotomeeting", "GoToMeeting"),
        ("com.ringcentral", "RingCentral"),
        ("com.skype", "Skype"),
        ("com.hnc.discord", "Discord")
    ]

    /// A browser process capturing the mic = a web call (Google Meet, Zoom/Teams
    /// web, Whereby…). Prefixes catch the renderer helpers too.
    private static let browserPrefixes: [(String, String)] = [
        ("com.google.chrome", "Chrome"), ("org.chromium", "Chromium"),
        ("com.apple.safari", "Safari"), ("com.apple.webkit", "Safari"),
        ("com.microsoft.edgemac", "Edge"),
        ("company.thebrowser", "Arc"),
        ("com.brave.browser", "Brave"),
        ("org.mozilla.firefox", "Firefox"), ("org.mozilla.nightly", "Firefox"),
        ("com.vivaldi", "Vivaldi"),
        ("com.operasoftware", "Opera")
    ]

    private var timer: Timer?

    private init() {}

    func startMonitoring() {
        timer?.invalidate(); timer = nil
        guard AppSettings.shared.detectActiveMeetings else { activeApp = nil; activeIsBrowser = false; return }
        refresh()
        scheduleNext()
    }

    /// Self-rescheduling tick: poll briskly (5s) while a call is active or the app
    /// is frontmost, but back off to 20s when idle in the background to save power.
    private func scheduleNext() {
        timer?.invalidate()
        let interval: TimeInterval = (activeApp != nil || NSApp.isActive) ? 5 : 20
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, AppSettings.shared.detectActiveMeetings else { return }
                self.refresh()
                self.scheduleNext()
            }
        }
    }

    func stopMonitoring() { timer?.invalidate(); timer = nil }

    func setEnabled(_ on: Bool) {
        AppSettings.shared.detectActiveMeetings = on
        if on { startMonitoring() }
        else { stopMonitoring(); activeApp = nil; activeIsBrowser = false }
    }

    /// App last nudged about, so we notify once per continuous call.
    private var nudgedApp: String?

    func refresh() {
        let previous = activeApp
        let result = detect()
        activeApp = result?.name
        activeIsBrowser = result?.isBrowser ?? false

        // App-wide nudge: when a NEW call appears and MindExtract is in the
        // background, surface a notification so the user doesn't have to be looking.
        if let app = result?.name {
            if app != nudgedApp, !NSApp.isActive, AppSettings.shared.meetingNudge, !MeetingRecorder.shared.isBusy {
                nudgedApp = app
                postNudge(app)
            }
        } else if previous != nil {
            nudgedApp = nil   // call ended — allow a fresh nudge next time
        }
    }

    private func detect() -> (name: String, isBrowser: Bool)? {
        guard AppSettings.shared.detectActiveMeetings else { return nil }
        // Don't suggest while we're already recording (our own capture holds the mic).
        guard !MeetingRecorder.shared.isBusy else { return nil }
        let bundles = Self.capturingBundleIDs()
            .map { $0.lowercased() }
            .filter { !$0.hasPrefix("com.mindact.mindextract") }
        guard !bundles.isEmpty else { return nil }
        // Native call apps win over browser tabs when both are capturing.
        for (prefix, name) in Self.conferencingPrefixes where bundles.contains(where: { $0.hasPrefix(prefix) }) {
            return (name, false)
        }
        for (prefix, name) in Self.browserPrefixes where bundles.contains(where: { $0.hasPrefix(prefix) }) {
            return (name, true)
        }
        return nil
    }

    private func postNudge(_ app: String) {
        let content = UNMutableNotificationContent()
        content.title = "In a \(app) call"
        content.body = "Tap to record it in MindExtract."
        content.sound = .default
        content.categoryIdentifier = "MEETING_DETECTED"
        content.userInfo = ["app": app]
        let request = UNNotificationRequest(identifier: "meeting-nudge", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Core Audio per-process input detection (macOS 14+)

    /// Bundle IDs of every process currently capturing the microphone — read
    /// straight from the audio process object, so helper/renderer processes (which
    /// aren't NSRunningApplications) are still identified. This is what makes new
    /// Teams (a WebView helper) and browser-based Meet detectable.
    static func capturingBundleIDs() -> [String] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &listAddr, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.stride
        var procs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &listAddr, 0, nil, &dataSize, &procs) == noErr else { return [] }

        var inAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var bidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var result: [String] = []
        for proc in procs {
            var running: UInt32 = 0
            var rSize = UInt32(MemoryLayout<UInt32>.stride)
            guard AudioObjectGetPropertyData(proc, &inAddr, 0, nil, &rSize, &running) == noErr,
                  running != 0 else { continue }
            var cf: Unmanaged<CFString>? = nil
            var cs = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(proc, &bidAddr, 0, nil, &cs, &cf) == noErr,
               let bid = cf?.takeRetainedValue() as String?, !bid.isEmpty {
                result.append(bid)
            }
        }
        return result
    }
}
