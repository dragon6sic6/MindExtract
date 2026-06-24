import SwiftUI
import AppKit
import Combine

// MARK: - Floating "meeting detected — record?" prompt
//
// When MindExtract notices a call (mic captured by Zoom/Teams/Meet/…), a small
// floating panel slides in near the menu bar asking whether to record. Unlike a
// system notification it can't be silenced by a Focus mode or a missing
// notification permission — it's impossible to miss, and one click records. Calm:
// once per call, dismissible, auto-fades after a while. Fully on-device.

@MainActor
final class MeetingPromptController: ObservableObject {
    static let shared = MeetingPromptController()

    private var panel: NSPanel?
    private var dismissedApp: String?   // a call the user said "not now" to — don't nag again
    private var autoHide: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Once recording starts, the prompt is moot — hide it.
        MeetingRecorder.shared.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in if MeetingRecorder.shared.isBusy { self?.hide() } }
            .store(in: &cancellables)
    }

    /// Show the prompt for a newly-detected call. Once per call; respects dismissals.
    func present(app: String, isBrowser: Bool) {
        guard AppSettings.shared.meetingNudge, !MeetingRecorder.shared.isBusy, app != dismissedApp else { return }
        let headline = isBrowser ? "Call detected in \(app)" : "\(app) call detected"
        let view = MeetingPromptView(
            headline: headline,
            onRecord: { [weak self] in self?.startRecording(app: app, isBrowser: isBrowser) },
            onDismiss: { [weak self] in self?.dismissedApp = app; self?.hide() }
        )
        showPanel(view)
        // Auto-fade if ignored — but the menu-bar dot stays, so it's not lost.
        autoHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        autoHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    /// The call ended — allow a fresh prompt next time, and hide.
    func callEnded() {
        dismissedApp = nil
        hide()
    }

    private func startRecording(app: String, isBrowser: Bool) {
        hide()
        if let m = MeetingCalendar.shared.currentMeeting, m.isLive {
            MeetingRecorder.shared.start(meetingTitle: m.title, attendees: m.attendees, attendeeEmails: m.attendeeEmails)
        } else {
            MeetingRecorder.shared.start(meetingTitle: isBrowser ? "Video call" : "\(app) call")
        }
    }

    private func showPanel(_ view: MeetingPromptView) {
        let hosting = NSHostingView(rootView: view)
        if let panel {
            panel.contentView = hosting
            panel.orderFrontRegardless()
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 310, height: 110),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.contentView = hosting
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Top-right, just under the menu bar.
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - 326, y: f.maxY - 126))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func hide() {
        autoHide?.cancel(); autoHide = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}

private struct MeetingPromptView: View {
    let headline: String
    var onRecord: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Color.orange).frame(width: 9, height: 9)
                Text(headline).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundColor(.white.opacity(0.55))
                }
                .buttonStyle(.plain).help("Not now")
            }
            Text("Record this meeting on-device?")
                .font(.caption).foregroundColor(.white.opacity(0.75))
            HStack(spacing: 8) {
                Button(action: onRecord) {
                    Label("Record", systemImage: "record.circle").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
                Button("Not now", action: onDismiss).buttonStyle(.bordered).controlSize(.small)
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 310, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.82)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.orange.opacity(0.45), lineWidth: 1))
    }
}
