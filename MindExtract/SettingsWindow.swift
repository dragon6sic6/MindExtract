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
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = String(localized: "MindExtract Settings")
            w.contentView = NSHostingView(rootView: SettingsView(downloader: .shared))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
