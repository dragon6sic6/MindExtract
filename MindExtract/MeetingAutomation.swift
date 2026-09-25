import Foundation
import Combine

// MARK: - One way to start a recording
//
// Every Record button (toolbar, Meetings, Today, menu bar, the call prompt,
// notifications) goes through these, so a recording always gets the same title,
// participants and live preview no matter where it was started.

extension MeetingRecorder {
    /// Records with the best context available: the calendar meeting happening now,
    /// else the call that was detected, else a blank recording.
    func startInContext() {
        guard !isBusy, ensurePermissions() else { return }
        if let m = MeetingCalendar.shared.currentMeeting, m.isLive {
            start(event: m)
        } else if let app = ActiveMeetingDetector.shared.activeApp {
            let title = ActiveMeetingDetector.shared.activeIsBrowser
                ? String(localized: "Video call")
                : String(localized: "\(app) call")
            start(language: AppSettings.shared.defaultTranscriptionLanguage, meetingTitle: title)
        } else {
            start(language: AppSettings.shared.defaultTranscriptionLanguage)
        }
    }

    /// Records a specific calendar meeting (title + participants carried over).
    func start(event m: MeetingCalendar.CalEvent) {
        guard !isBusy, ensurePermissions() else { return }
        start(language: AppSettings.shared.defaultTranscriptionLanguage,
              meetingTitle: m.title, attendees: m.attendees, attendeeEmails: m.attendeeEmails)
    }
}

extension MeetingRecorder {
    /// Recording needs the microphone and meeting audio; if either is missing,
    /// show the permissions sheet instead of failing with an error.
    func ensurePermissions() -> Bool {
        refreshPermissions()
        guard micGranted && screenGranted else {
            NotificationCenter.default.post(name: .showPermissions, object: nil)
            return false
        }
        return true
    }
}

// MARK: - App-wide meeting automation
//
// Auto-record and live captions used to live in the Meetings screen's view code,
// so they only worked while that screen was open. They run app-wide now.

@MainActor
final class MeetingAutomation {
    static let shared = MeetingAutomation()

    private var cancellables = Set<AnyCancellable>()
    private var lastAutoRecordKey: String?

    private init() {}

    func activate() {
        guard cancellables.isEmpty else { return }
        // Published values arrive before the property updates, so use the emitted values.
        MeetingCalendar.shared.$currentMeeting
            .combineLatest(ActiveMeetingDetector.shared.$activeApp)
            .receive(on: RunLoop.main)
            .sink { [weak self] meeting, app in self?.autoRecordIfNeeded(meeting: meeting, app: app) }
            .store(in: &cancellables)

        MeetingRecorder.shared.live.$isActive
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { active in
                let overlay = CaptionOverlayController.shared
                if active {
                    if AppSettings.shared.autoShowCaptions { overlay.show(transcriber: MeetingRecorder.shared.live) }
                } else {
                    overlay.hide()
                }
            }
            .store(in: &cancellables)
    }

    /// Starts once per detected meeting/call when "Start recording automatically" is on.
    private func autoRecordIfNeeded(meeting: MeetingCalendar.CalEvent?, app: String?) {
        let settings = AppSettings.shared
        let recorder = MeetingRecorder.shared
        guard settings.autoRecordMeetings, settings.detectActiveMeetings, !recorder.isBusy else { return }
        if let m = meeting, m.isLive, app != nil {
            guard lastAutoRecordKey != m.id else { return }
            lastAutoRecordKey = m.id
            recorder.start(event: m)
        } else if let app {
            let key = "call:\(app)"
            guard lastAutoRecordKey != key else { return }
            lastAutoRecordKey = key
            recorder.startInContext()
        } else {
            lastAutoRecordKey = nil   // call over — the next one may auto-start again
        }
    }
}
