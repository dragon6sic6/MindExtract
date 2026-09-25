import SwiftUI
import AppKit
import Combine

// MARK: - Floating recording pill
//
// While recording and MindExtract isn't frontmost, a small glass pill floats in
// the top-right corner: time, level, a way back to your notes, and Stop. When the
// call app releases the mic it turns into "Call ended · stopping in 20 s" with a
// Keep recording button — so a forgotten recording can't run on for hours.

@MainActor
final class RecordingPillController: ObservableObject {
    static let shared = RecordingPillController()

    /// Seconds left before an automatic stop after the call ended; nil = none.
    @Published private(set) var stopCountdown: Int?

    static let countdownSeconds = 20

    private var panel: NSPanel?
    private var countdownTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        MeetingRecorder.shared.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.update() }
                .store(in: &cancellables)
        }
    }

    /// Call once at launch so the pill follows the recorder from then on.
    func activate() { update() }

    /// The detected call ended — start the cancellable auto-stop countdown.
    func callEnded() {
        guard AppSettings.shared.autoStopWhenCallEnds, MeetingRecorder.shared.isRecording, stopCountdown == nil else { return }
        stopCountdown = Self.countdownSeconds
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in RecordingPillController.shared.tick() }
        }
        update()
    }

    func keepRecording() {
        cancelCountdown()
        update()
    }

    func stopNow() {
        cancelCountdown()
        MeetingRecorder.shared.stop()
        openNotes()
    }

    func openNotes() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeKey && !($0 is NSPanel) }?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .navigate, object: SidebarItem.record)
    }

    private func tick() {
        guard let left = stopCountdown else { return }
        if left <= 1 {
            stopNow()
        } else {
            stopCountdown = left - 1
        }
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        stopCountdown = nil
    }

    private func update() {
        let recording = MeetingRecorder.shared.isRecording
        if !recording { cancelCountdown() }
        if recording && (!NSApp.isActive || stopCountdown != nil) {
            show()
        } else {
            hide()
        }
    }

    // MARK: Panel

    private func show() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 52),
                styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            panel.contentView = NSHostingView(rootView: RecordingPillView())
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            self.panel = panel
        }
        guard let panel else { return }
        if !panel.isVisible {
            fit(panel)
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: f.maxX - panel.frame.width - 16, y: f.maxY - panel.frame.height - 16))
            }
        }
        panel.orderFrontRegardless()
        // The content changes (countdown ↔ timer) after this runloop pass; refit
        // then, keeping the right edge where the user left it.
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            self.fit(panel)
        }
    }

    private func fit(_ panel: NSPanel) {
        guard let hosting = panel.contentView as? NSHostingView<RecordingPillView> else { return }
        let size = hosting.fittingSize
        let right = panel.frame.maxX
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: right - size.width, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    private func hide() {
        panel?.orderOut(nil)
    }
}

private struct RecordingPillView: View {
    @ObservedObject private var recorder = MeetingRecorder.shared
    @ObservedObject private var controller = RecordingPillController.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(DS.Colors.recording)
                .symbolEffect(.pulse, options: .repeating)
            if let left = controller.stopCountdown {
                Text("Call ended · stopping in \(left) s")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Button("Keep recording") { controller.keepRecording() }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            } else {
                Text(RecordingView.formatElapsed(recorder.elapsed))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                MiniLevelBars(level: recorder.level)
                Button {
                    controller.openNotes()
                } label: {
                    Image(systemName: "note.text")
                }
                .buttonStyle(.borderless)
                .help("Open your notes")
                .accessibilityLabel("Open notes")
            }
            Button {
                controller.stopNow()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.glassProminent)
            .tint(DS.Colors.recording)
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .fixedSize()
        .glassEffect(.regular, in: .capsule)
        .padding(6)   // room for the shadow inside the panel
    }
}
