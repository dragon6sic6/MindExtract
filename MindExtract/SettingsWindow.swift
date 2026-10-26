import AppKit
import SwiftUI

// MARK: - Settings window
//
// The app has no Dock icon or main window, so Settings is a plain window opened
// from the notch's menu.

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static var isVisible: Bool { window?.isVisible == true }

    static func show() {
        NotchController.shared.close()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 660),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = String(localized: "MindExtract Settings")
            // The same black as the notch.
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.backgroundColor = .black
            w.appearance = NSAppearance(named: .darkAqua)
            w.minSize = NSSize(width: 560, height: 480)
            w.isMovableByWindowBackground = true
            w.contentView = NSHostingView(rootView: SettingsView(downloader: .shared).environment(\.locale, .appEnglish))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
