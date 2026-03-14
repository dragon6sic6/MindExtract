import AppKit
import SwiftUI

final class TranscriptionWindowController: NSObject, NSWindowDelegate {
    static let shared = TranscriptionWindowController()

    private var window: NSWindow?

    func showWindow(manager: TranscriptionManager) {
        // If window exists and is visible, just bring it forward
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        // If window exists but is not visible (was closed via red X), nil it out
        if window != nil {
            window = nil
        }

        let view = TranscriptionResultView(
            transcriptionManager: manager,
            onClose: { [weak self] in
                self?.close()
            }
        )

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 700, height: 600)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Transcription"
        panel.contentView = hostingView
        panel.isFloatingPanel = false
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.setFrameAutosaveName("TranscriptionWindow")
        panel.minSize = NSSize(width: 500, height: 400)
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        self.window = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
        window = nil
        DispatchQueue.main.async {
            TranscriptionManager.shared.showTranscriptionView = false
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
        DispatchQueue.main.async {
            TranscriptionManager.shared.showTranscriptionView = false
        }
    }
}
