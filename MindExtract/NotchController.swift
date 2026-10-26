import AppKit
import SwiftUI
import Combine

// MARK: - The notch window
//
// A transparent panel pinned to the top of the screen with the notch (or the
// main screen, where it draws nothing until needed). It ignores the mouse while
// closed, so the menu bar around it keeps working.
//
//   Opens:  resting on the notch ~0.25 s · a click on it · the shortcut ·
//           reopening the app · dragging a file or link to it
//   Closes: leaving it (0.35 s) · a click elsewhere · Esc · handing off to
//           another window (Settings, Finder, the transcript)
//   Stays:  while typing a link, while a menu is open, and — when opened on
//           purpose — until the pointer has been inside and left.

/// Size of the hardware notch on a screen, or a stand-in when it has none.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchSize: CGSize
    var hasNotch: Bool

    static func current() -> NotchGeometry {
        let menuBarScreen = NSScreen.screens.first ?? NSScreen.main!
        let screen = UserDefaults.standard.string(forKey: "notchScreen") == "main"
            ? menuBarScreen
            : (NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? menuBarScreen)
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
    /// Esc, even while the text field has focus.
    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { NotchController.shared.close() }
    }

    /// The app is never active while you use the notch, so the Edit menu never
    /// sees ⌘V and friends — send them to the text field directly.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command || mods == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let action: Selector?
        switch (key, mods.contains(.shift)) {
        case ("v", false): action = #selector(NSText.paste(_:))
        case ("c", false): action = #selector(NSText.copy(_:))
        case ("x", false): action = #selector(NSText.cut(_:))
        case ("a", false): action = #selector(NSText.selectAll(_:))
        case ("z", false): action = Selector(("undo:"))
        case ("z", true): action = Selector(("redo:"))
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Shared sizes for the notch's shapes.
enum NotchMetrics {
    static let openWidth: CGFloat = 520
    /// Width added on each side of the notch for the activity indicators.
    static let activitySide: CGFloat = 42
    /// The quieter version once a finished result has waited a while.
    static let quietSide: CGFloat = 18
}

@MainActor
final class NotchController {
    static let shared = NotchController()

    /// Room for the open panel plus its shadow.
    static let panelSize = CGSize(width: 680, height: 480)

    enum OpenReason { case hover, click, keyboard, reopen, drag }

    private var panel: NotchPanel?
    private let model = NotchModel.shared
    private var geometry: NotchGeometry { model.geometry }
    private var monitors: [Any] = []
    private var closeWork: DispatchWorkItem?
    private var openWork: DispatchWorkItem?
    private var seenWork: DispatchWorkItem?
    private var dwellAnchor: CGPoint?
    /// Opened on purpose: stays until the pointer has been inside and left.
    private var stickyOpen = false
    private var mouseWasInside = false
    private var openedByDrag = false
    /// The drag pasteboard's change count at the last mouse-down, so an old
    /// drag's contents can't make an unrelated drag look like a file drag.
    private var dragCountAtMouseDown = NSPasteboard(name: .drag).changeCount

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
        // A click in the notch takes the keyboard (SwiftUI's field doesn't ask for
        // it on its own); close() hands it straight back.
        panel.becomesKeyOnlyIfNeeded = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: NotchRootView().environmentObject(model))
        self.panel = panel
        place()
        panel.orderFrontRegardless()

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NotchController.shared.place() }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { NotchController.shared.place() }
            }
        }
        center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { NotchController.shared.model.isEditing = false }
        }
        // Menus opened from the notch keep it open.
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NotchController.shared.model.isMenuOpen = true }
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NotchController.shared.model.isMenuOpen = false }
        }
        installMonitors()

        GlobalHotKey.shared.action = { NotchController.shared.toggle(reason: .keyboard) }
        GlobalHotKey.shared.install()
    }

    func place() {
        model.geometry = NotchGeometry.current()
        guard let panel else { return }
        let size = Self.panelSize
        let frame = CGRect(x: geometry.screenFrame.midX - size.width / 2,
                           y: geometry.screenFrame.maxY - size.height,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    // MARK: Opening and closing

    func open(_ reason: OpenReason = .hover) {
        closeWork?.cancel(); closeWork = nil
        openWork?.cancel(); openWork = nil
        if reason != .hover {
            stickyOpen = true
            mouseWasInside = false
        }
        openedByDrag = reason == .drag
        let wantsKeyboard = reason == .click || reason == .keyboard || reason == .reopen
        if !model.isOpen {
            model.refreshClipboard()
            panel?.ignoresMouseEvents = false
            withAnimation(NotchStyle.openAnimation) { model.isOpen = true }
            // A result counts as seen once the notch has really been open a moment.
            seenWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.model.isOpen else { return }
                self.model.markSeen()
            }
            seenWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
        if wantsKeyboard {
            // Hover never takes the keyboard from the app you're typing in.
            takeKeyboard()
            model.requestFocus()
        }
    }

    /// Typing needs MindExtract to be the active app: a panel above the menu bar
    /// doesn't reliably get key presses otherwise. close() gives them back.
    private func takeKeyboard() {
        if !NSApp.isActive { NSApp.activate() }
        panel?.makeKey()
    }

    func close() {
        openWork?.cancel(); openWork = nil
        closeWork?.cancel(); closeWork = nil
        seenWork?.cancel()
        stickyOpen = false
        openedByDrag = false
        guard model.isOpen else { return }
        model.dragKind = nil
        model.isEditing = false
        panel?.makeFirstResponder(nil)
        panel?.ignoresMouseEvents = true
        if let panel, panel.isKeyWindow {
            // Hand the keyboard back so ⌘V lands in the app you paste into.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        if NSApp.isActive, !SettingsWindow.isVisible { NSApp.deactivate() }
        withAnimation(NotchStyle.closeAnimation) { model.isOpen = false }
    }

    func toggle(reason: OpenReason) {
        model.isOpen ? close() : open(reason)
    }

    /// For buttons that hand off to another window.
    func closeAfterHandOff() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.close() }
    }

    // MARK: Mouse

    private func installMonitors() {
        let types: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp, .leftMouseDown, .rightMouseDown]
        let global = NSEvent.addGlobalMonitorForEvents(matching: types) { event in
            let type = event.type
            MainActor.assumeIsolated { NotchController.shared.mouse(type, ownWindow: false) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: types) { event in
            let type = event.type
            MainActor.assumeIsolated { NotchController.shared.mouse(type, ownWindow: true) }
            return event
        }
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53, MainActor.assumeIsolated({ NotchController.shared.model.isOpen }) {
                MainActor.assumeIsolated { NotchController.shared.close() }
                return nil
            }
            return event
        }
        monitors = [global, local, keys].compactMap { $0 }
    }

    /// The closed notch (plus its wings), a little larger so it's easy to hit,
    /// and reaching 1 pt past the top so a pointer pinned to the edge counts.
    private var hoverRect: CGRect {
        let side = model.isBusy || (model.hasUnseenResult && !model.unseenIsQuiet) ? NotchMetrics.activitySide
            : (model.hasUnseenResult ? NotchMetrics.quietSide : 0)
        let s = CGSize(width: geometry.notchSize.width + 2 * side, height: geometry.notchSize.height)
        return CGRect(x: geometry.screenFrame.midX - s.width / 2 - 8,
                      y: geometry.screenFrame.maxY - s.height - 6,
                      width: s.width + 16, height: s.height + 7)
    }

    /// Where a dragged file starts to pull the notch open.
    private var dragRect: CGRect { hoverRect.insetBy(dx: -60, dy: -50) }

    /// The open panel, with some slack before it closes.
    private var openRect: CGRect {
        let s = model.openSize == .zero ? CGSize(width: NotchMetrics.openWidth, height: 200) : model.openSize
        return CGRect(x: geometry.screenFrame.midX - s.width / 2 - 24,
                      y: geometry.screenFrame.maxY - s.height - 30,
                      width: s.width + 48, height: s.height + 31)
    }

    private func mouse(_ type: NSEvent.EventType, ownWindow: Bool) {
        let p = NSEvent.mouseLocation

        if type == .leftMouseDown {
            dragCountAtMouseDown = NSPasteboard(name: .drag).changeCount
        }

        if !model.isOpen {
            if type == .leftMouseDown, hoverRect.contains(p) { open(.click); return }
            if type == .leftMouseDragged, dragRect.contains(p), let kind = draggedKind() {
                model.dragKind = kind
                open(.drag)
                return
            }
            guard type == .mouseMoved, hoverRect.contains(p) else {
                openWork?.cancel(); openWork = nil; dwellAnchor = nil
                return
            }
            // Rest on the notch to open it, so sweeping along the menu bar doesn't.
            if let anchor = dwellAnchor, hypot(p.x - anchor.x, p.y - anchor.y) < 4, openWork != nil { return }
            dwellAnchor = p
            openWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hoverRect.contains(NSEvent.mouseLocation) else { return }
                self.open(.hover)
            }
            openWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            return
        }

        let inside = openRect.contains(p)
        if inside { mouseWasInside = true }

        // A click in the notch: it gets the keyboard, before SwiftUI handles the click.
        if type == .leftMouseDown, ownWindow, inside { takeKeyboard() }

        // A click somewhere else closes it. (The global monitor only sees other
        // apps' clicks; our own windows report through the local one.)
        if type == .leftMouseDown || type == .rightMouseDown {
            if !inside && !ownWindow { close() }
            return
        }
        if type == .leftMouseDragged, model.dragKind == nil, let kind = draggedKind() { model.dragKind = kind }
        if type == .leftMouseUp, model.dragKind != nil {
            model.dragKind = nil
            if openedByDrag { stickyOpen = false; mouseWasInside = true }   // a cancelled drag lets it close
        }

        let typing = model.isEditing && !model.input.isEmpty
        let onboarding = model.onboardingStep != nil   // the introduction stays until it's finished
        if (stickyOpen && !mouseWasInside) || inside || typing || model.isMenuOpen || model.dragKind != nil || onboarding {
            closeWork?.cancel(); closeWork = nil
        } else if closeWork == nil {
            let delay = openedByDrag ? 0.5 : 0.35
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.closeWork = nil
                let typing = self.model.isEditing && !self.model.input.isEmpty
                if !self.openRect.contains(NSEvent.mouseLocation), !typing, !self.model.isMenuOpen, self.model.dragKind == nil,
                   self.model.onboardingStep == nil {
                    self.close()
                }
            }
            closeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// What a drag that started since the last mouse-down carries, if anything we can use.
    private func draggedKind() -> NotchModel.DragKind? {
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != dragCountAtMouseDown else { return nil }
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return .file }
        if pb.canReadObject(forClasses: [NSURL.self], options: nil) { return .link }
        return nil
    }
}
