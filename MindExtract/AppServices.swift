import AppKit
import Carbon.HIToolbox
import ServiceManagement

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

    func set(_ new: Combo?) {
        combo = new
        if let new {
            defaults.set(false, forKey: "hotKeyOff")
            defaults.set(Int(new.keyCode), forKey: "hotKeyCode")
            defaults.set(Int(new.modifiers.rawValue), forKey: "hotKeyModifiers")
            defaults.set(new.keyName, forKey: "hotKeyName")
        } else {
            defaults.set(true, forKey: "hotKeyOff")
        }
        register()
    }

    private func register() {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        guard let combo else { return }
        let id = EventHotKeyID(signature: OSType(0x4D455854), id: 1)   // 'MEXT'
        RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    /// Turns a key press into a combo. Needs ⌃, ⌥ or ⌘ so ordinary typing can't be taken.
    static func combo(from event: NSEvent) -> Combo? {
        let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !mods.intersection([.control, .option, .command]).isEmpty else { return nil }
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

// MARK: - Open the transcript's destination

enum Assistant: String, CaseIterable, Identifiable {
    case claude, chatgpt, none

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT"
        case .none: return String(localized: "None")
        }
    }

    private var bundleIDs: [String] {
        switch self {
        case .claude: return ["com.anthropic.claudefordesktop"]
        case .chatgpt: return ["com.openai.codex", "com.openai.chat"]
        case .none: return []
        }
    }

    private var webURL: URL? {
        switch self {
        case .claude: return URL(string: "https://claude.ai/new")
        case .chatgpt: return URL(string: "https://chatgpt.com")
        case .none: return nil
        }
    }

    var isInstalled: Bool {
        bundleIDs.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    /// The chosen one, or — before anything is chosen — the first one installed.
    @MainActor static var preferred: Assistant {
        if let chosen = Assistant(rawValue: AppSettings.shared.preferredAssistant) { return chosen }
        return [.claude, .chatgpt].first { $0.isInstalled } ?? .none
    }

    /// Opens the app, or the website when the app isn't installed. Never puts
    /// the transcript in a URL — it's on the clipboard.
    func open() {
        for id in bundleIDs {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        if let webURL { NSWorkspace.shared.open(webURL) }
    }
}
