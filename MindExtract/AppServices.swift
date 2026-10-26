import AppKit
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Language

extension Locale {
    /// The app is in English everywhere, so dates and numbers follow English
    /// too, even on a Mac set to another language.
    static let appEnglish = Locale(identifier: "en_US")
}

extension Int64 {
    /// "632.2 MB", in English whatever the Mac's language.
    var fileSizeText: String { formatted(.byteCount(style: .file).locale(.appEnglish)) }
}

// MARK: - Global shortcut
//
// One system-wide shortcut opens the notch with the link field focused
// (⌃⌥Space by default, changeable in Settings). Carbon's hot keys need no
// Accessibility permission.

@MainActor
final class GlobalHotKey: ObservableObject {
    static let shared = GlobalHotKey()

    struct Combo: Equatable {
        var keyCode: UInt32
        var modifiers: NSEvent.ModifierFlags
        var keyName: String

        static let standard = Combo(keyCode: UInt32(kVK_Space), modifiers: [.control, .option], keyName: "Space")

        var display: String {
            var s = ""
            if modifiers.contains(.control) { s += "⌃" }
            if modifiers.contains(.option) { s += "⌥" }
            if modifiers.contains(.shift) { s += "⇧" }
            if modifiers.contains(.command) { s += "⌘" }
            return s + (keyName == "Space" ? String(localized: "Space") : keyName)
        }

        var carbonModifiers: UInt32 {
            var m: UInt32 = 0
            if modifiers.contains(.control) { m |= UInt32(controlKey) }
            if modifiers.contains(.option) { m |= UInt32(optionKey) }
            if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
            if modifiers.contains(.command) { m |= UInt32(cmdKey) }
            return m
        }
    }

    /// nil = turned off.
    @Published private(set) var combo: Combo?
    var action: (() -> Void)?

    private var ref: EventHotKeyRef?
    private var handlerInstalled = false
    private let defaults = UserDefaults.standard

    private init() {
        if defaults.bool(forKey: "hotKeyOff") {
            combo = nil
        } else if defaults.object(forKey: "hotKeyCode") != nil {
            combo = Combo(keyCode: UInt32(defaults.integer(forKey: "hotKeyCode")),
                          modifiers: NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: "hotKeyModifiers"))),
                          keyName: defaults.string(forKey: "hotKeyName") ?? "?")
        } else {
            combo = .standard
        }
    }

    func install() {
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { GlobalHotKey.shared.action?() }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        register()
    }

    /// Saves and registers a shortcut. False if another app already owns it;
    /// the previous shortcut stays then.
    @discardableResult
    func set(_ new: Combo?) -> Bool {
        let previous = combo
        combo = new
        guard register() else {
            combo = previous
            register()
            return false
        }
        if let new {
            defaults.set(false, forKey: "hotKeyOff")
            defaults.set(Int(new.keyCode), forKey: "hotKeyCode")
            defaults.set(Int(new.modifiers.rawValue), forKey: "hotKeyModifiers")
            defaults.set(new.keyName, forKey: "hotKeyName")
        } else {
            defaults.set(true, forKey: "hotKeyOff")
        }
        return true
    }

    @discardableResult
    private func register() -> Bool {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        guard let combo else { return true }
        let id = EventHotKeyID(signature: OSType(0x4D455854), id: 1)   // 'MEXT'
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { appLog("[MindExtract] Shortcut \(combo.display) not registered: \(status)") }
        return status == noErr
    }

    /// Turns a key press into a combo. It needs ⌃, or ⌘ together with ⌥:
    /// ⌘ alone would take Copy, Paste and Quit from every app, and ⌥ alone
    /// types characters such as @ on many keyboards.
    static func combo(from event: NSEvent) -> Combo? {
        let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard mods.contains(.control) || mods.isSuperset(of: [.command, .option]) else { return nil }
        let name: String
        switch Int(event.keyCode) {
        case kVK_Space: name = "Space"
        case kVK_Return: name = "↩"
        case kVK_Tab: name = "⇥"
        default: name = (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
        return Combo(keyCode: UInt32(event.keyCode), modifiers: mods, keyName: name)
    }
}

// MARK: - Open at login

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    /// Turned on, but macOS wants the user to allow it in System Settings.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            appLog("[MindExtract] Open at login: \(error.localizedDescription)")
        }
    }

    /// Turned on once, the first time the app runs from an Applications folder
    /// (never for a build run from somewhere temporary).
    static func enableOnFirstRun() {
        let key = "didSetUpOpenAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/") else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }
}
