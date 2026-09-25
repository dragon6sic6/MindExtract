import Foundation
import Combine

// MARK: - One way to start a note
//
// Every "New Note" button (toolbar, empty state, menu bar, ⌘N) goes through this,
// so a recording always starts the same way. Nothing starts on its own.

extension MeetingRecorder {
    /// Starts a new note: your microphone, plus the others' audio in a call.
    func startNote() {
        guard !isBusy, ensurePermissions() else { return }
        start(language: AppSettings.shared.defaultTranscriptionLanguage)
    }

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

// MARK: - Live captions
//
// Shows the floating captions while a note is recording (if turned on).

@MainActor
final class MeetingAutomation {
    static let shared = MeetingAutomation()

    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func activate() {
        guard cancellables.isEmpty else { return }
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
}
