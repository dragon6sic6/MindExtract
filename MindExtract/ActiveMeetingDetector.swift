import Foundation
import SwiftUI
import AppKit
import CoreAudio

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

    /// Native conferencing apps → display name.
    private static let conferencingApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams": "Microsoft Teams",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoftedge.msteams": "Microsoft Teams",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.webex.meetingmanager": "Webex",
        "Cisco-Systems.Spark": "Webex",
        "com.logmein.GoToMeeting": "GoToMeeting",
        "com.ringcentral.glip": "RingCentral",
        "com.skype.skype": "Skype",
        "com.hnc.Discord": "Discord"
    ]

    /// Browsers — a browser process capturing the mic means a web call (Google
    /// Meet, Zoom/Teams web, Whereby, …). Now reliable thanks to per-process
    /// attribution: we only flag the browser if *it* is the one holding the mic.
    private static let browsers: [String: String] = [
        "com.google.Chrome": "Chrome",
        "com.apple.Safari": "Safari",
        "com.microsoft.edgemac": "Edge",
        "company.thebrowser.Browser": "Arc",
        "com.brave.Browser": "Brave",
        "org.mozilla.firefox": "Firefox",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "com.operasoftware.Opera": "Opera"
    ]

    /// Deterministic display order when several native call apps run at once.
    private static let priority = ["Zoom", "Microsoft Teams", "Webex", "GoToMeeting",
                                   "RingCentral", "Skype", "Discord"]

    private var timer: Timer?

    private init() {}

    func startMonitoring() {
        timer?.invalidate(); timer = nil
        guard AppSettings.shared.detectActiveMeetings else { activeApp = nil; activeIsBrowser = false; return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopMonitoring() { timer?.invalidate(); timer = nil }

    func setEnabled(_ on: Bool) {
        AppSettings.shared.detectActiveMeetings = on
        if on { startMonitoring() }
        else { stopMonitoring(); activeApp = nil; activeIsBrowser = false }
    }

    func refresh() {
        guard AppSettings.shared.detectActiveMeetings else { activeApp = nil; activeIsBrowser = false; return }
        // Don't suggest while we're already recording (our own capture holds the mic).
        guard !MeetingRecorder.shared.isBusy else { activeApp = nil; activeIsBrowser = false; return }

        let capturing = Self.inputCapturingPIDs()
        guard !capturing.isEmpty else { activeApp = nil; activeIsBrowser = false; return }

        var natives = Set<String>()
        var browserCalls = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier, capturing.contains(app.processIdentifier) else { continue }
            if let n = Self.conferencingApps[bid] { natives.insert(n) }
            else if let b = Self.browsers[bid] { browserCalls.insert(b) }
        }

        // Native call apps win over browser tabs when both are capturing.
        if let n = Self.priority.first(where: natives.contains) ?? natives.sorted().first {
            activeApp = n; activeIsBrowser = false
        } else if let b = browserCalls.sorted().first {
            activeApp = b; activeIsBrowser = true
        } else {
            activeApp = nil; activeIsBrowser = false
        }
    }

    // MARK: Core Audio per-process input detection (macOS 14+)

    /// PIDs of every process currently capturing the microphone, via the public
    /// Core Audio process-object API. This is the precise signal that replaces the
    /// old "is *any* process using the mic" heuristic.
    static func inputCapturingPIDs() -> Set<pid_t> {
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
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var result = Set<pid_t>()
        for proc in procs {
            var running: UInt32 = 0
            var rSize = UInt32(MemoryLayout<UInt32>.stride)
            guard AudioObjectGetPropertyData(proc, &inAddr, 0, nil, &rSize, &running) == noErr,
                  running != 0 else { continue }
            var pid: pid_t = -1
            var pSize = UInt32(MemoryLayout<pid_t>.stride)
            guard AudioObjectGetPropertyData(proc, &pidAddr, 0, nil, &pSize, &pid) == noErr,
                  pid > 0 else { continue }
            result.insert(pid)
        }
        return result
    }
}
