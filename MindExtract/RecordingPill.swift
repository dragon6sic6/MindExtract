import SwiftUI
import AppKit
import Combine

// MARK: - Floating recording pill
//
// While recording and MindExtract isn't frontmost, a small glass pill floats in
// the top-right corner: time, level, a way back to your notes, and Stop.

@MainActor
final class RecordingPillController: ObservableObject {
    static let shared = RecordingPillController()

    private var panel: NSPanel?
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

    func stopNow() {
        MeetingRecorder.shared.stop()
        openNotes()
    }

    func openNotes() { MainWindow.show() }

    private func update() {
        if MeetingRecorder.shared.isRecording && !NSApp.isActive {
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
        // The content settles after this runloop pass; refit then, keeping the
        // right edge where the user left it.
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
            Text(AppUtil.formatElapsed(recorder.elapsed))
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
