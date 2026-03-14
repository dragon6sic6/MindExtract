import AppKit
import SwiftUI

final class TranscriptionWindowController {
    static let shared = TranscriptionWindowController()

    private var window: NSWindow?

    func showWindow(manager: TranscriptionManager) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
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
}
