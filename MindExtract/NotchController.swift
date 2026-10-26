import AppKit
import SwiftUI
import Combine

// MARK: - The notch window
//
// A transparent panel pinned to the top of the screen with the notch (or the
// main screen as a small pill when there's no notch). It ignores the mouse
// while closed, so the menu bar around it keeps working; hovering the notch, or
// dragging a file to it, opens it.

/// Size of the hardware notch on a screen, or a stand-in pill when it has none.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchSize: CGSize
    var hasNotch: Bool

    static func current() -> NotchGeometry {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchGeometry(screenFrame: screen.frame, notchSize: CGSize(width: width, height: top), hasNotch: true)
        }
        let menuBar = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        return NotchGeometry(screenFrame: screen.frame, notchSize: CGSize(width: 190, height: menuBar), hasNotch: false)
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchController {
    static let shared = NotchController()

    /// Room for the open panel plus its shadow.
    static let panelSize = CGSize(width: 680, height: 460)

    private var panel: NotchPanel?
    private let model = NotchModel.shared
    private var geometry: NotchGeometry { model.geometry }
    private var monitors: [Any] = []
    private var closeWork: DispatchWorkItem?
    private var openWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    /// Opened on purpose (app reopened, a file dropped): stays open until the
    /// mouse has been inside and left, a click lands outside, or Esc.
    private var stickyOpen = false
    private var mouseWasInside = false

    func start() {
        let panel = NotchPanel(contentRect: .zero,
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: NotchRootView().environmentObject(model))
        self.panel = panel
        place()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NotchController.shared.place() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                               object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { NotchController.shared.model.isEditing = false }
        }
        // Menus opened from the notch (settings, copy options) keep it open.
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NotchController.shared.model.isMenuOpen = true }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NotchController.shared.model.isMenuOpen = false }
        }
        installMonitors()
    }

    private func place() {
        model.geometry = NotchGeometry.current()
        guard let panel else { return }
        let size = Self.panelSize
        let frame = CGRect(x: geometry.screenFrame.midX - size.width / 2,
                           y: geometry.screenFrame.maxY - size.height,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
    }

    // MARK: Opening and closing

    func open(asDropTarget: Bool = false, sticky: Bool = false) {
        closeWork?.cancel()
        model.isDropTargeted = asDropTarget
        if sticky { stickyOpen = true; mouseWasInside = false }
        guard !model.isOpen else { return }
        model.refreshClipboard()
        model.hasUnseenResult = false
        panel?.ignoresMouseEvents = false
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { model.isOpen = true }
    }

    func close() {
        openWork?.cancel()
        stickyOpen = false
        guard model.isOpen else { return }
        model.isDropTargeted = false
        model.isEditing = false
        panel?.makeFirstResponder(nil)
        panel?.ignoresMouseEvents = true
        if panel?.isKeyWindow == true { panel?.resignKey() }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { model.isOpen = false }
    }

    func toggle() { model.isOpen ? close() : open() }

    // MARK: Mouse

    private func installMonitors() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp, .leftMouseDown]) { event in
            let type = event.type
            MainActor.assumeIsolated { NotchController.shared.mouse(type) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]) { event in
            let type = event.type
            MainActor.assumeIsolated { NotchController.shared.mouse(type) }
            return event
        }
        monitors = [global, local].compactMap { $0 }
    }

    /// The closed notch, a little larger so it's easy to hit.
    private var hoverRect: CGRect {
        let s = model.isBusy || model.hasUnseenResult
            ? CGSize(width: geometry.notchSize.width + 2 * NotchMetrics.activitySide, height: geometry.notchSize.height)
            : geometry.notchSize
        return CGRect(x: geometry.screenFrame.midX - s.width / 2 - 8,
                      y: geometry.screenFrame.maxY - s.height - 6,
                      width: s.width + 16, height: s.height + 6)
    }

    /// The open panel, with some slack before it closes.
    private var openRect: CGRect {
        let s = model.openSize == .zero ? CGSize(width: NotchMetrics.openWidth, height: 200) : model.openSize
        return CGRect(x: geometry.screenFrame.midX - s.width / 2 - 24,
                      y: geometry.screenFrame.maxY - s.height - 30,
                      width: s.width + 48, height: s.height + 30)
    }

    private func mouse(_ type: NSEvent.EventType) {
        let p = NSEvent.mouseLocation
        let dragging = type == .leftMouseDragged && Self.dragHasFiles

        if !model.isOpen {
            guard hoverRect.contains(p) else { openWork?.cancel(); openWork = nil; return }
            if dragging { open(asDropTarget: true); return }
            guard type == .mouseMoved, openWork == nil else { return }
            // A short dwell so passing the mouse along the menu bar doesn't open it.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hoverRect.contains(NSEvent.mouseLocation) else { return }
                self.open()
            }
            openWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            return
        }

        openWork = nil
        let inside = openRect.contains(p)
        if inside { mouseWasInside = true }
        // A click somewhere else closes it (global monitor: only other apps' clicks).
        if type == .leftMouseDown { if !inside { close() }; return }
        if stickyOpen && !mouseWasInside { return }
        if dragging { model.isDropTargeted = openRect.contains(p) || hoverRect.contains(p) }
        if type == .leftMouseUp { model.isDropTargeted = false }
        if openRect.contains(p) || model.isEditing || model.isMenuOpen {
            closeWork?.cancel(); closeWork = nil
        } else if closeWork == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.closeWork = nil
                if !self.openRect.contains(NSEvent.mouseLocation), !self.model.isEditing, !self.model.isMenuOpen {
                    self.close()
                }
            }
            closeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    /// The drag pasteboard holds files (a drag that started in Finder or another app).
    private static var dragHasFiles: Bool {
        NSPasteboard(name: .drag).canReadObject(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true])
    }
}

/// Shared sizes for the notch's shapes.
enum NotchMetrics {
    static let openWidth: CGFloat = 520
    /// Width added on each side of the notch for the activity indicators.
    static let activitySide: CGFloat = 40
}
