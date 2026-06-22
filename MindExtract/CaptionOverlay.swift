import SwiftUI
import AppKit
import Combine

// MARK: - Floating live-caption overlay
//
// A small, always-on-top, translucent window that shows the live transcription
// while a meeting is being recorded — so the captions stay visible on top of
// Zoom/Teams/Meet even when MindExtract is in the background. Borderless and
// draggable; floats above full-screen apps. Fully on-device, like everything else.

@MainActor
final class CaptionOverlayController: ObservableObject {
    static let shared = CaptionOverlayController()

    @Published private(set) var isVisible = false
    private var panel: NSPanel?
    private var savedOrigin: NSPoint?   // remember where the user dragged it
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // The captions only make sense while recording — hide them whenever the
        // live transcriber stops, regardless of which view (or the menu bar)
        // triggered the stop. This survives the Record tab not being on screen.
        MeetingRecorder.shared.live.$isActive
            .filter { !$0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.hide() }
            .store(in: &cancellables)
    }

    func toggle(transcriber: LiveTranscriber) {
        isVisible ? hide() : show(transcriber: transcriber)
    }

    func show(transcriber: LiveTranscriber) {
        if let panel {
            // Rebind to the current transcriber in case a new session started.
            panel.contentView = NSHostingView(rootView: CaptionOverlayView(transcriber: transcriber) { [weak self] in self?.hide() })
            panel.orderFrontRegardless()
            isVisible = true
            return
        }
        let view = CaptionOverlayView(transcriber: transcriber) { [weak self] in self?.hide() }
        let hosting = NSHostingView(rootView: view)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 120),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isReleasedWhenClosed = false   // we keep a Swift ref; avoid use-after-free
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        // Restore the user's last position, else bottom-center above the Dock.
        if let origin = savedOrigin {
            panel.setFrameOrigin(origin)
        } else if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - 260, y: f.minY + 90))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        isVisible = true
    }

    func hide() {
        // Remember where the user dragged the window so the next show reuses it.
        if let panel { savedOrigin = panel.frame.origin }
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        isVisible = false
    }
}

private struct CaptionOverlayView: View {
    @ObservedObject var transcriber: LiveTranscriber
    var onClose: () -> Void
    @State private var hovering = false

    /// Show only the tail so the box stays compact and readable.
    private var caption: String {
        let text = transcriber.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "Listening…" }
        return String(text.suffix(220))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("Live captions")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                }
                Text(caption)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeOut(duration: 0.15), value: caption)
            }
            .padding(14)
            .frame(width: 520, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.black.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )

            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("Hide captions")
            }
        }
        .onHover { hovering = $0 }
    }
}
