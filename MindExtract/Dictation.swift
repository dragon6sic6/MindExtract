import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox

// MARK: - Push-to-talk dictation
//
// Hold the right ⌥ Option key anywhere on the Mac, speak, let go — the text is
// typed where the cursor is. Swedish runs on Pianissimo, other languages on
// Whisper; audio never leaves the Mac and is discarded right after transcription.
//
// Right Option doubles as the "Alt Gr" key on Swedish keyboards (@ £ $ [ ] { } |),
// so a hold only counts as dictation if no other key is pressed while it's down,
// and a quick tap is ignored.

@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    enum Phase: Equatable {
        case idle
        case listening
        case transcribing
        case failed(String)
    }

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let date: Date
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var level: Float = 0          // 0…1 mic level for the HUD
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    /// Recent dictations — kept in memory only, so a paste that landed nowhere can be copied.
    @Published private(set) var recent: [Entry] = []

    /// A hold shorter than this is a tap (or a modifier chord) — not dictation.
    static let minimumHold: TimeInterval = 0.3
    static let rightOptionKeyCode = UInt16(kVK_RightOption)

    private var monitors: [Any] = []
    private var permissionPoll: Timer?
    private var keyDownAt: Date?
    private var chordUsed = false
    private let recorder = DictationRecorder()
    private var hud: DictationHUD?

    private init() {
        recorder.onLevel = { [weak self] value in
            Task { @MainActor in self?.level = value }
        }
    }

    // MARK: Lifecycle

    /// Call at launch and whenever the setting changes.
    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        removeMonitors()
        guard AppSettings.shared.dictationEnabled else {
            permissionPoll?.invalidate(); permissionPoll = nil
            return
        }
        prewarm()
        if accessibilityGranted {
            permissionPoll?.invalidate(); permissionPoll = nil
            installMonitors()
        } else {
            // Global key monitors only work once Accessibility is granted — and macOS
            // doesn't tell us when that happens, so check once a second until it does.
            if permissionPoll == nil {
                permissionPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    Task { @MainActor in
                        let c = DictationController.shared
                        if AXIsProcessTrusted() { c.refresh() }
                    }
                }
            }
        }
    }

    /// Shows the system prompt that sends the user to Privacy & Security → Accessibility.
    func requestAccessibility() {
        // Value of kAXTrustedCheckOptionPrompt (the global isn't concurrency-safe in Swift 6).
        let key = "AXTrustedCheckOptionPrompt"
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        refresh()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Load the Swedish model up front so the first dictation is instant.
    private func prewarm() {
        let lang = AppSettings.shared.dictationLanguage
        guard lang == "sv" || lang == "auto", PianissimoEngine.isInstalled else { return }
        Task.detached(priority: .utility) { _ = try? await PianissimoEngine.shared.load() }
    }

    // MARK: Hotkey

    private func installMonitors() {
        let handler: (NSEvent) -> Void = { event in
            MainActor.assumeIsolated { DictationController.shared.handle(event) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            // Any key while right ⌥ is held = an Option chord (e.g. ⌥2 → @), not dictation.
            if keyDownAt != nil { chordUsed = true; cancelCapture() }
        case .flagsChanged:
            guard event.keyCode == Self.rightOptionKeyCode else {
                // Another modifier joined in (⌘, ⇧…) — treat as a shortcut, not speech.
                if keyDownAt != nil { chordUsed = true; cancelCapture() }
                return
            }
            // Device-specific bit for the RIGHT Option key (NX_DEVICERALTKEYMASK), so
            // holding left ⌥ at the same time can't confuse press/release.
            let down = event.modifierFlags.rawValue & 0x40 != 0
            down ? keyPressed() : keyReleased()
        default:
            break
        }
    }

    private func keyPressed() {
        guard keyDownAt == nil, phase != .transcribing else { return }
        keyDownAt = Date()
        chordUsed = false
        // Start the mic immediately so the first word isn't clipped; the HUD only
        // appears once the hold is long enough to be deliberate.
        Task {
            guard await DictationRecorder.ensureMicrophoneAccess() else {
                fail("MindExtract needs microphone access — allow it in System Settings → Privacy.")
                keyDownAt = nil
                return
            }
            guard keyDownAt != nil, !chordUsed else { return }
            do {
                try recorder.start()
            } catch {
                fail("Couldn't start the microphone: \(error.localizedDescription)")
                keyDownAt = nil
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.minimumHold * 1_000_000_000))
            if keyDownAt != nil, !chordUsed {
                phase = .listening
                showHUD()
            }
        }
    }

    private func keyReleased() {
        guard let start = keyDownAt else { return }
        keyDownAt = nil
        let held = Date().timeIntervalSince(start)
        let samples = recorder.stop()
        guard !chordUsed, held >= Self.minimumHold else {
            chordUsed = false
            if phase == .listening { phase = .idle; hideHUD() }
            return
        }
        // Too little audio to hold a word.
        guard samples.count > 16_000 / 4 else { phase = .idle; hideHUD(); return }
        phase = .transcribing
        showHUD()
        let language = AppSettings.shared.dictationLanguage
        Task {
            do {
                let raw = try await TranscriptionManager.shared.transcribeDictation(samples: samples, language: language)
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    recent.insert(Entry(text: text, date: Date()), at: 0)
                    if recent.count > 20 { recent.removeLast(recent.count - 20) }
                    TextInserter.insert(text + " ")
                }
                phase = .idle
                hideHUD()
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func cancelCapture() {
        _ = recorder.stop()
        if phase == .listening { phase = .idle; hideHUD() }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        showHUD()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, case .failed = self.phase else { return }
            self.phase = .idle
            self.hideHUD()
        }
    }

    func copy(_ entry: Entry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
    }

    // MARK: HUD

    private func showHUD() {
        if hud == nil { hud = DictationHUD() }
        hud?.show()
    }

    private func hideHUD() {
        level = 0
        hud?.hide()
    }
}

// MARK: - Microphone capture (16 kHz mono)

/// Records the default input into 16 kHz mono Float samples — the format both
/// Pianissimo and Whisper expect. Samples live only in memory.
final class DictationRecorder: @unchecked Sendable {
    var onLevel: (@Sendable (Float) -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var running = false

    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                            channels: 1, interleaved: false)!

    static func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() throws {
        lock.lock(); samples = []; lock.unlock()
        guard !running else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: format, to: Self.targetFormat) else {
            throw NSError(domain: "Dictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported microphone format"])
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(for: self, converter: converter))
        engine.prepare()
        try engine.start()
        running = true
    }

    /// Stops the mic and hands back everything recorded since `start()`.
    func stop() -> [Float] {
        if running {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            running = false
        }
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples = []
        return out
    }

    // Built outside any actor so the tap (which runs on the audio thread) isn't
    // treated as main-actor code.
    private static func tapBlock(for recorder: DictationRecorder, converter: AVAudioConverter) -> AVAudioNodeTapBlock {
        { buffer, _ in
            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let data = out.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
            var sum: Float = 0
            for v in chunk { sum += v * v }
            let rms = chunk.isEmpty ? 0 : (sum / Float(chunk.count)).squareRoot()
            recorder.lock.lock(); recorder.samples += chunk; recorder.lock.unlock()
            recorder.onLevel?(min(1, rms * 12))
        }
    }
}

// MARK: - Typing the result

enum TextInserter {
    /// Pastes `text` into the focused app via ⌘V, then puts the user's clipboard
    /// back. Marked transient so clipboard managers don't record it.
    @MainActor
    static func insert(_ text: String) {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ourChange = pb.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        // Give the target app time to read the paste, then restore — unless
        // something else has written to the clipboard in the meantime.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard pb.changeCount == ourChange else { return }
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
    }
}

// MARK: - Floating HUD

@MainActor
private final class DictationHUD {
    private var panel: NSPanel?

    func show() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 260, height: 48),
                styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            panel.contentView = NSHostingView(rootView: DictationHUDView(controller: .shared))
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .statusBar
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            self.panel = panel
        }
        // Bottom-centre of the screen the user is working on.
        if let panel, let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - 130, y: f.minY + 72))
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

private struct DictationHUDView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        HStack(spacing: 10) {
            switch controller.phase {
            case .listening:
                Circle().fill(Color.red).frame(width: 9, height: 9)
                LevelBars(level: controller.level)
                Text("Listening…").foregroundColor(.white)
            case .transcribing:
                ProgressView().controlSize(.small).tint(.white)
                Text("Transcribing…").foregroundColor(.white)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text(message).foregroundColor(.white).lineLimit(2)
            case .idle:
                EmptyView()
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .frame(width: 260, height: 48)
        .background(Capsule().fill(.black.opacity(0.85)))
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}

private struct LevelBars: View {
    let level: Float
    private let weights: [Float] = [0.5, 0.8, 1.0, 0.8, 0.5]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.white)
                    .frame(width: 3, height: CGFloat(4 + 16 * min(1, level * weights[i])))
            }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
