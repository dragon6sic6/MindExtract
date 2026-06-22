import SwiftUI
import UniformTypeIdentifiers
import EventKit

/// Helpers to connect MindExtract's MCP server to Claude Desktop / other clients.
@MainActor
enum MCPSetup {
    static var executablePath: String { Bundle.main.executablePath ?? "" }

    static var configSnippet: String {
        // Build via JSONSerialization so an unusual path (quotes/backslashes) can't
        // produce invalid JSON.
        let obj: [String: Any] = ["mcpServers": ["mindextract": ["command": executablePath, "args": ["--mcp"]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return "" }
        return str
    }

    static var claudeConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    /// Merge our server into Claude Desktop's config (preserving any existing servers).
    @discardableResult
    static func installToClaude() -> Bool {
        let url = claudeConfigURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root = obj
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["mindextract"] = ["command": executablePath, "args": ["--mcp"]]
        root["mcpServers"] = servers
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return false }
        return (try? out.write(to: url, options: .atomic)) != nil
    }

    static func copyConfig() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(configSnippet, forType: .string)
    }
}

/// Top-level Settings categories, shown as an in-pane navigator (the app already
/// owns the main window sidebar, so this is a lightweight second column).
enum SettingsCategory: String, CaseIterable, Identifiable {
    case transcription = "Transcription"
    case recording = "Recording"
    case calendar = "Calendar"
    case ai = "AI & Summaries"
    case downloads = "Downloads"
    case notifications = "Notifications"
    case about = "About"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .transcription: return "text.bubble"
        case .recording: return "record.circle"
        case .calendar: return "calendar"
        case .ai: return "sparkles"
        case .downloads: return "arrow.down.circle"
        case .notifications: return "bell"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var downloader: YTDLPWrapper
    @ObservedObject var transcriptionManager = TranscriptionManager.shared
    @ObservedObject private var calendar = MeetingCalendar.shared
    @ObservedObject private var recorder = MeetingRecorder.shared
    @ObservedObject private var activeMeeting = ActiveMeetingDetector.shared
    @State private var category: SettingsCategory = .transcription
    @State private var showAdvancedAuth = false
    @State private var showResetConfirmation = false
    @State private var showYouTubeSignOutConfirm = false
    @State private var ollamaModels: [String] = []
    @State private var ollamaDetectFailed = false
    @State private var mcpStatus: String?
    @State private var mcpConfigCopied = false
    @State private var keyTests: [String: KeyTestState] = [:]   // keyed by Keychain account

    private func acknowledgementRow(_ name: String, _ license: String, _ url: String) -> some View {
        HStack {
            Text(name).font(.caption).fontWeight(.medium).chromeText()
            Text("· \(license)").font(.caption2).foregroundColor(.secondary).chromeText()
            Spacer(minLength: 8)
            Button("License") {
                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            }
            .buttonStyle(.link)
            .font(.caption2)
        }
    }

    private func detectOllamaModels() {
        Task {
            let models = await OllamaBackend.installedModels()
            ollamaModels = models
            ollamaDetectFailed = models.isEmpty
            if settings.ollamaModel.isEmpty, let first = models.first {
                settings.ollamaModel = first
            }
        }
    }

    enum KeyTestState: Equatable { case idle, testing, ok, fail(String) }

    /// A binding that reads/writes an API key straight to the Keychain.
    private func keychainBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { KeychainHelper.get(key) ?? "" },
            // Trim — a pasted key with a trailing newline/space otherwise 401s forever.
            set: { KeychainHelper.set($0.trimmingCharacters(in: .whitespacesAndNewlines), key: key); keyTests[key] = .idle }
        )
    }

    /// The Settings model field for a given cloud provider.
    private func cloudModelBinding(_ c: AIBackendChoice) -> Binding<String>? {
        switch c {
        case .openAI: return $settings.openAIModel
        case .anthropic: return $settings.anthropicModel
        case .gemini: return $settings.geminiModel
        case .grok: return $settings.grokModel
        case .mistral: return $settings.mistralModel
        case .groq: return $settings.groqModel
        case .openRouter: return $settings.openRouterModel
        case .custom: return $settings.customModel
        case .apple, .ollama: return nil
        }
    }

    /// Validate a key by hitting the provider's "list models" endpoint.
    private func testKey(_ provider: AIBackendChoice) {
        guard let kc = provider.keychainKey else { return }
        let key = KeychainHelper.get(kc) ?? ""
        guard !key.isEmpty else { keyTests[kc] = .fail("Enter a key first"); return }
        keyTests[kc] = .testing
        var req: URLRequest
        if provider == .anthropic {
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if let cfg = provider.compatConfig(settings) {
            let base = cfg.baseURL.hasSuffix("/") ? String(cfg.baseURL.dropLast()) : cfg.baseURL
            guard !base.isEmpty, let u = URL(string: base + "/models") else {
                keyTests[kc] = .fail("Set the endpoint URL first"); return
            }
            req = URLRequest(url: u)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        } else { return }
        req.timeoutInterval = 12
        Task { @MainActor in
            let result: KeyTestState
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                result = code == 200 ? .ok : .fail("Key rejected (HTTP \(code))")
            } catch {
                result = .fail("Couldn't reach the server")
            }
            keyTests[kc] = result
        }
    }

    @ViewBuilder
    private func keyTestControl(_ provider: AIBackendChoice) -> some View {
        let state = keyTests[provider.keychainKey ?? ""] ?? .idle
        HStack(spacing: 6) {
            Button("Test") { testKey(provider) }
                .secondaryGlassButton()
                .controlSize(.small)
            switch state {
            case .idle: EmptyView()
            case .testing: ProgressView().controlSize(.small)
            case .ok:
                Label("Valid", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green).font(.caption).labelStyle(.titleAndIcon)
            case .fail(let msg):
                Label(msg, systemImage: "xmark.circle.fill")
                    .foregroundColor(.orange).font(.caption).labelStyle(.titleAndIcon)
            }
        }
    }

    /// Key + model (+ endpoint for custom) for any OpenAI-compatible cloud provider.
    @ViewBuilder
    private func cloudProviderConfig(_ choice: AIBackendChoice) -> some View {
        if choice == .custom {
            HStack {
                Text("Endpoint URL")
                Spacer()
                TextField("https://your-host/v1", text: $settings.customBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
        }
        if let kc = choice.keychainKey {
            HStack {
                Text("API key")
                Spacer()
                SecureField("key…", text: keychainBinding(kc))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            HStack { Spacer(); keyTestControl(choice) }
        }
        if let mb = cloudModelBinding(choice) {
            HStack {
                Text("Model")
                Spacer()
                TextField("model name", text: mb)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
        }
        if let url = choice.keyURL {
            HStack {
                Spacer()
                Button("Get an API key →") {
                    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        Text("Keys are stored securely in your Keychain.")
            .font(.caption)
            .foregroundColor(.secondary)
    }

    private var appleSpeechAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 0) {
            categoryNavigator
                .frame(width: 190)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    categoryContent
                }
                .padding(20)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            transcriptionManager.loadDownloadedModels()
            calendar.refreshAccessStatus()
            recorder.refreshPermissions()
        }
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $showResetConfirmation, titleVisibility: .visible) {
            Button("Reset Settings", role: .destructive) { resetSettingsToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This restores preferences like engine, language, and download options. Your downloads, transcripts, history, and API keys are not touched.")
        }
        .confirmationDialog("Sign out of YouTube?", isPresented: $showYouTubeSignOutConfirm, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { downloader.signOutYouTube() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to sign in again to download members-only or age-restricted videos.")
        }
    }

    // MARK: - Category navigator

    private var categoryNavigator: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsCategory.allCases) { c in
                Button { category = c } label: {
                    HStack(spacing: 9) {
                        Image(systemName: c.icon).frame(width: 18)
                        Text(c.rawValue).font(.system(size: 13))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(category == c ? DS.Colors.accent.opacity(0.18) : Color.clear))
                    .foregroundColor(category == c ? DS.Colors.accent : .primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.vertical, 14).padding(.horizontal, 10)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch category {
        case .transcription: transcriptionPane
        case .recording: recordingPane
        case .calendar: calendarPane
        case .ai: aiPane
        case .downloads: downloadsPane
        case .notifications: notificationsPane
        case .about: aboutPane
        }
    }

    /// Small section subheader used to separate model families in the list.
    private func modelGroupHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Full-width orange callout for blocking/important warnings.
    private func warningBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text(text).font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.4), lineWidth: 1))
    }

    // MARK: - Transcription pane

    @ViewBuilder
    private var transcriptionPane: some View {
        if !transcriptionManager.isFfmpegAvailable {
            warningBanner("Audio tools are missing — transcription is unavailable. Reinstall MindExtract to fix this.")
        }
        SettingsSection(title: "Engine", icon: "waveform") {
            HStack {
                Text("Engine")
                Spacer()
                Picker("", selection: $settings.transcriptionEngine) {
                    ForEach(TranscriptionEngineChoice.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .frame(width: 200)
                .help("Which speech engine transcribes your audio. Automatic picks the best one for your Mac.")
            }
            Text(settings.transcriptionEngine.detail)
                .font(.caption).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if settings.transcriptionEngine == .appleSpeech && !appleSpeechAvailable {
                Text("Apple Speech requires macOS 26 — WhisperKit will be used instead until you upgrade.")
                    .font(.caption).foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().padding(.vertical, 2)
            HStack {
                Text("Default language")
                Spacer()
                Picker("", selection: $settings.defaultTranscriptionLanguage) {
                    ForEach(AppSettings.transcriptionLanguages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .frame(width: 200)
                .help("The language a new transcription starts with. You can still change it each time. Auto-detect works for most content.")
            }
            HStack {
                Text("Save transcripts as")
                Spacer()
                Picker("", selection: $settings.transcriptionOutputFormat) {
                    ForEach(TranscriptionOutputFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .frame(width: 200)
                .help("The file format used when a transcript is saved. SRT and VTT are subtitle formats.")
            }
            Divider().padding(.vertical, 2)
            Toggle(isOn: $settings.enableSpeakerDiarization) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speaker labels")
                    Text("Identify who said what in conversations and interviews. You can rename speakers afterwards.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }

        SettingsSection(title: "WhisperKit Models", icon: "cpu") {
            if transcriptionManager.useAppleSpeech() {
                Text("You're using Apple's built-in speech — these models are only needed if you switch the engine to WhisperKit.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Default model")
                Spacer()
                // Swedish-only models (KB-Whisper) are excluded from the global
                // default — auto-selected only for Swedish, never for English audio.
                Picker("", selection: $settings.defaultWhisperModel) {
                    ForEach(WhisperModel.allCases.filter { !$0.isSwedishOnly }) { model in
                        HStack {
                            Text(model.displayName)
                            if !transcriptionManager.isModelDownloaded(model) {
                                Text("(not downloaded)").foregroundColor(.secondary)
                            }
                        }
                        .tag(model)
                    }
                }
                .frame(width: 200)
            }
            // Multilingual (OpenAI Whisper) models.
            modelGroupHeader("Multilingual", systemImage: "globe")
            VStack(spacing: 0) {
                ForEach(WhisperModel.allCases.filter { !$0.isSwedishOnly }) { model in
                    ModelRow(model: model)
                }
            }
            // Swedish-optimized KB-Whisper models (auto-used when transcribing Swedish).
            modelGroupHeader("Swedish — KB-Whisper", systemImage: "character.bubble")
            Text("Fine-tuned by the National Library of Sweden. Picked automatically for Swedish audio; not used for other languages.")
                .font(.caption2).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(WhisperModel.allCases.filter { $0.isSwedishOnly }) { model in
                    ModelRow(model: model)
                }
            }
            Divider().padding(.vertical, 2)
            Toggle(isOn: $settings.translateToEnglish) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Translate to English while transcribing")
                    Text("WhisperKit only — uses Whisper's built-in translate task. Output is always English. Runs on-device.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Divider().padding(.vertical, 2)
            HStack {
                Text("Storage used").foregroundColor(.secondary)
                Spacer()
                Text(transcriptionManager.formatBytes(transcriptionManager.totalStorageUsed()))
                    .foregroundColor(.secondary).fontWeight(.medium)
            }
        }

        SettingsSection(title: "Custom Vocabulary", icon: "character.book.closed") {
            Text("Add names and terms WhisperKit should spell correctly — client and people names, places, medical or legal terms, product names. One per line or comma-separated.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $settings.customVocabulary)
                .font(.system(size: 13, design: .monospaced))
                .frame(height: 90)
                .padding(6)
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.Colors.hairline, lineWidth: 1))
            Text("Applies to WhisperKit (incl. KB-Whisper). Apple Speech doesn't support custom terms. Runs on-device.")
                .font(.caption2).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Recording pane

    @ViewBuilder
    private var recordingPane: some View {
        if !MeetingRecorder.isSupported {
            SettingsSection(title: "Recording", icon: "record.circle") {
                Text("Meeting recording requires macOS 15 or later.")
                    .font(.caption).foregroundColor(.secondary)
            }
        } else {
            SettingsSection(title: "Permissions", icon: "lock.shield") {
                permissionStatusRow(title: "Screen & system audio", granted: recorder.screenGranted) {
                    recorder.requestScreenPermission()
                }
                Divider().padding(.vertical, 2)
                permissionStatusRow(title: "Microphone", granted: recorder.micGranted) {
                    Task { _ = await recorder.requestMicPermission() }
                }
                Text("MindExtract captures system audio and your microphone to record meetings. Audio is processed entirely on your Mac. Revoke access any time in System Settings.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsSection(title: "Microphone", icon: "mic") {
                HStack {
                    Text("Input device")
                    Spacer()
                    Picker("", selection: $settings.preferredMicrophoneID) {
                        Text("System default").tag("")
                        ForEach(MeetingRecorder.availableMicrophones(), id: \.uniqueID) { dev in
                            Text(dev.localizedName).tag(dev.uniqueID)
                        }
                    }
                    .frame(width: 220)
                }
                Text("Which microphone to record. “System default” follows your Mac's current input — it switches automatically when you connect AirPods or a headset.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsSection(title: "Meeting Detection", icon: "dot.radiowaves.left.and.right") {
                Toggle(isOn: Binding(
                    get: { settings.detectActiveMeetings },
                    set: { activeMeeting.setEnabled($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Detect active calls (Zoom, Teams, Meet…)")
                        Text("Offers one-tap recording when an app — or a browser tab (Google Meet, Zoom/Teams web) — is in a live call, even without a calendar event. On-device: checks per-app which process is capturing the mic, never what's said.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }

            SettingsSection(title: "Live Captions", icon: "captions.bubble") {
                Toggle(isOn: $settings.autoShowCaptions) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show floating captions automatically")
                        Text("When a recording starts, display the live transcript in a window that stays on top of Zoom and Teams. You can also toggle it during a recording.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private func permissionStatusRow(title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Label(granted ? "\(title) — granted" : "\(title) — not granted",
                  systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundColor(granted ? .green : .orange)
                .labelStyle(.titleAndIcon).font(.system(size: 13))
            Spacer()
            if !granted {
                Button("Grant", action: action).secondaryGlassButton().controlSize(.small)
            }
        }
    }

    // MARK: - Calendar pane

    @ViewBuilder
    private var calendarPane: some View {
        SettingsSection(title: "Calendar Access", icon: "calendar") {
            HStack {
                Label(calendar.accessGranted ? "Access granted" : "Not granted",
                      systemImage: calendar.accessGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundColor(calendar.accessGranted ? .green : .orange)
                    .labelStyle(.titleAndIcon).font(.system(size: 13))
                Spacer()
                if calendar.accessGranted {
                    Button("Manage in System Settings") { calendar.openSystemSettings() }
                        .secondaryGlassButton().controlSize(.small)
                } else {
                    Button("Connect") { Task { await calendar.requestAccess() } }
                        .secondaryGlassButton().controlSize(.small)
                }
            }
            Text("MindExtract reads today's events on your Mac to offer one-tap recording of the meeting you're in. Nothing is written to your calendar.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 2)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "person.2.badge.gearshape").foregroundStyle(DS.Colors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Google or Microsoft calendar?").font(.system(size: 13, weight: .medium))
                    Text("Add the account in System Settings → Internet Accounts. Those calendars then sync into your Mac and show up here automatically — Teams, Google and Zoom meetings included. No sign-in inside MindExtract; nothing leaves your Mac through us.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Spacer()
                Button("Add an account…") { calendar.openInternetAccounts() }
                    .secondaryGlassButton().controlSize(.small)
            }
        }

        SettingsSection(title: "Meeting Suggestions", icon: "sparkle.magnifyingglass") {
            Toggle(isOn: Binding(
                get: { settings.calendarSuggestionsEnabled },
                set: { on in
                    calendar.setSuggestionsEnabled(on)
                    if on && !calendar.accessGranted { Task { await calendar.requestAccess() } }
                })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Suggest meetings from my calendar")
                    Text("Turning this off stops MindExtract from reading events. The macOS permission is unchanged — re-enable any time without another prompt.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            if settings.calendarSuggestionsEnabled {
                Divider().padding(.vertical, 2)
                HStack {
                    Text("Suggest meetings starting within")
                    Spacer()
                    Picker("", selection: $settings.calendarLeadMinutes) {
                        Text("Now only").tag(0)
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                    }
                    .frame(width: 160)
                    .onChange(of: settings.calendarLeadMinutes) { _, _ in calendar.refresh() }
                }
            }
        }

        if settings.calendarSuggestionsEnabled && calendar.accessGranted, !calendar.calendars.isEmpty {
            SettingsSection(title: "Calendars to Scan", icon: "calendar.badge.checkmark") {
                ForEach(calendar.calendars, id: \.calendarIdentifier) { cal in
                    Toggle(isOn: Binding(
                        get: { !settings.excludedCalendarIDSet.contains(cal.calendarIdentifier) },
                        set: { include in
                            settings.setCalendarExcluded(cal.calendarIdentifier, !include)
                            calendar.refresh()
                        })) {
                        HStack(spacing: 7) {
                            Circle().fill(Color(nsColor: NSColor(cgColor: cal.cgColor) ?? .systemBlue))
                                .frame(width: 9, height: 9)
                            Text(cal.title).font(.system(size: 13))
                        }
                    }
                }
            }
        }

        SettingsSection(title: "After a Meeting", icon: "doc.text.magnifyingglass") {
            Toggle(isOn: $settings.autoGenerateMeetingNotes) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-generate meeting notes")
                    Text("Creates Meeting Minutes and Action Items automatically when a recording finishes transcribing. Uses your selected AI provider.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Text("Attendee names from the detected event are pre-filled into recording notes and suggested as speaker names after transcription.")
                .font(.caption2).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - AI pane

    @ViewBuilder
    private var aiPane: some View {
        SettingsSection(title: "AI Summaries & Chat", icon: "sparkles") {
            HStack {
                Text("Provider")
                Spacer()
                Picker("", selection: $settings.aiBackend) {
                    ForEach(AIBackendChoice.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .frame(width: 200)
                .help("Who generates summaries and answers about your transcripts.")
            }
            Text(settings.aiBackend.detail)
                .font(.caption).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let kc = settings.aiBackend.keychainKey,
               (KeychainHelper.get(kc) ?? "").isEmpty {
                Label("Add an API key below to use this provider.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            switch settings.aiBackend {
            case .apple:
                EmptyView()
            case .ollama:
                HStack {
                    Text("Model")
                    Spacer()
                    if ollamaModels.isEmpty {
                        TextField("e.g. llama3.2, gemma2, mistral", text: $settings.ollamaModel)
                            .textFieldStyle(.roundedBorder).frame(width: 200)
                    } else {
                        Picker("", selection: $settings.ollamaModel) {
                            ForEach(ollamaModels, id: \.self) { Text($0).tag($0) }
                        }
                        .frame(width: 200)
                    }
                    Button("Detect") { detectOllamaModels() }
                        .secondaryGlassButton().controlSize(.small)
                        .help("List the models you've pulled in Ollama")
                }
                if ollamaDetectFailed {
                    Text("Couldn't reach Ollama — make sure the Ollama app is running.")
                        .font(.caption).foregroundColor(.orange)
                }
            default:
                cloudProviderConfig(settings.aiBackend)
            }
        }

        SettingsSection(title: "Connect to Claude & ChatGPT (MCP)", icon: "link") {
            Text("Expose your transcripts to Claude Desktop (or any MCP client) as a local tool — then ask Claude/ChatGPT to search and pull from your recordings. Runs on your Mac via stdio; only what you actually ask about is sent to that AI.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    let ok = MCPSetup.installToClaude()
                    mcpStatus = ok ? "Added to Claude Desktop — restart Claude to use it." : "Couldn't write Claude's config."
                } label: {
                    Label("Set up Claude Desktop", systemImage: "checkmark.seal")
                }
                .secondaryGlassButton().controlSize(.small)

                Button {
                    MCPSetup.copyConfig()
                    mcpConfigCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { mcpConfigCopied = false }
                } label: {
                    Label(mcpConfigCopied ? "Copied" : "Copy config (other clients)", systemImage: mcpConfigCopied ? "checkmark" : "doc.on.doc")
                }
                .secondaryGlassButton().controlSize(.small)
                Spacer()
            }
            if let mcpStatus {
                Text(mcpStatus).font(.caption).foregroundColor(.secondary)
            }
            Text("Exposes: search_transcripts, get_transcript, list_transcripts. Your transcripts never leave your Mac through MindExtract.")
                .font(.caption2).foregroundColor(.secondary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Downloads pane

    @ViewBuilder
    private var downloadsPane: some View {
        SettingsSection(title: "Downloads", icon: "arrow.down.circle") {
            HStack {
                Text("Save downloads to")
                Spacer()
                Text(settings.downloadPath)
                    .font(.caption).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 160)
                Button("Show") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: settings.downloadPath))
                }
                .secondaryGlassButton().controlSize(.small)
                .help("Reveal the downloads folder in Finder")
                Button("Change…") { selectDownloadFolder() }
                    .secondaryGlassButton().controlSize(.small)
            }
            HStack {
                Text("Preferred quality")
                Spacer()
                Picker("", selection: $settings.downloadQuality) {
                    ForEach(DownloadQuality.allCases) { q in
                        Text(q.displayName).tag(q)
                    }
                }
                .frame(width: 160)
                .help("Used for one-click \u{201C}best\u{201D} downloads. Picking a specific format in the download view always overrides this.")
            }
            HStack {
                Text("Simultaneous downloads")
                Spacer()
                Picker("", selection: $settings.parallelDownloads) {
                    Text("1").tag(1); Text("2").tag(2); Text("3").tag(3); Text("4").tag(4)
                }
                .frame(width: 160)
                .help("How many videos download at the same time when you queue several.")
            }
            Divider().padding(.vertical, 2)
            Toggle(isOn: $settings.autoTranscribeOnDownload) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcribe automatically after download")
                    Text("Starts transcription as soon as a download finishes, using your default engine and language.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Divider().padding(.vertical, 2)
            Toggle("Download subtitles when available", isOn: $settings.downloadSubtitles)
                .help("Saves the video's subtitle file alongside the download, when the site provides one.")
            if settings.downloadSubtitles {
                HStack {
                    Text("Subtitle language")
                    Spacer()
                    Picker("", selection: $settings.subtitleLanguage) {
                        Text("English").tag("en")
                        Text("Swedish").tag("sv")
                        Text("Spanish").tag("es")
                        Text("French").tag("fr")
                        Text("German").tag("de")
                        Text("Auto").tag("auto")
                    }
                    .frame(width: 160)
                }
            }
        }

        SettingsSection(title: "YouTube Sign-in", icon: "play.rectangle.fill") {
            Text("Most videos download without signing in. Sign in only if YouTube blocks a download — for example age-restricted or members-only videos, or a “confirm you're not a bot” error.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            youtubeAuthContent
        }
    }

    // MARK: - Notifications pane

    @ViewBuilder
    private var notificationsPane: some View {
        SettingsSection(title: "Notifications", icon: "bell") {
            Toggle("Show a notification when a download finishes", isOn: $settings.showNotifications)
            Toggle("Play a sound when a download finishes", isOn: $settings.playSoundOnComplete)
            Divider().padding(.vertical, 2)
            Toggle("Show a notification when a transcription finishes", isOn: $settings.notifyOnTranscriptionComplete)
        }
    }

    // MARK: - About pane

    @ViewBuilder
    private var aboutPane: some View {
        SettingsSection(title: "About", icon: "info.circle") {
            HStack {
                Text("Version")
                Spacer()
                Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))")
                    .foregroundColor(.secondary)
                Button("Check for Updates") {
                    NotificationCenter.default.post(name: .checkForUpdates, object: nil)
                }
                .secondaryGlassButton().controlSize(.small)
            }
            HStack {
                Text("App data").foregroundColor(.secondary)
                Spacer()
                Button("Open App Data Folder") { NSWorkspace.shared.open(appDataFolder) }
                    .secondaryGlassButton().controlSize(.small)
                    .help("Where transcripts, history, and models are stored")
            }
            Text("Everything runs on your Mac — no audio or video ever leaves your computer unless you choose a cloud AI provider.")
                .font(.caption).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            Text("Please use MindExtract responsibly: download and transcribe only content you have the right to use, and respect the terms of the platforms and the rights of creators. You are responsible for how you use downloaded material.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            DisclosureGroup("Open-source acknowledgements") {
                VStack(alignment: .leading, spacing: 6) {
                    acknowledgementRow("yt-dlp", "Public domain (Unlicense)", "https://github.com/yt-dlp/yt-dlp")
                    acknowledgementRow("FFmpeg", "LGPL v2.1+", "https://ffmpeg.org/legal.html")
                    acknowledgementRow("WhisperKit & SpeakerKit (Argmax)", "MIT License", "https://github.com/argmaxinc/argmax-oss-swift")
                    acknowledgementRow("Sparkle", "MIT License", "https://github.com/sparkle-project/Sparkle")
                }
                .padding(.top, 6)
            }
            .font(.caption).foregroundColor(.secondary)
        }

        SettingsSection(title: "Privacy & Security", icon: "lock.shield") {
            Toggle(isOn: $settings.appLockEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Require Touch ID or password to open")
                    Text("Locks MindExtract when it's not frontmost, so transcripts (client, patient or case material) aren't visible to anyone at an unlocked Mac.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Divider().padding(.vertical, 2)
            Text("Everything already stays on your Mac. For full at-rest encryption of the files on disk, turn on macOS FileVault (System Settings → Privacy & Security → FileVault) — it encrypts your whole drive, including MindExtract's transcripts.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        SettingsSection(title: "Branding (PDF deliverables)", icon: "signature") {
            Text("Add your practice/business name and logo to exported PDFs — a letterhead for transcripts and notes you hand to clients.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Business name")
                Spacer()
                TextField("e.g. Mindact Solutions AB", text: $settings.brandName)
                    .textFieldStyle(.roundedBorder).frame(width: 240)
            }
            HStack {
                Text("Logo")
                Spacer()
                if !settings.brandLogoPath.isEmpty {
                    Text(URL(fileURLWithPath: settings.brandLogoPath).lastPathComponent)
                        .font(.caption).foregroundColor(.secondary).lineLimit(1).frame(maxWidth: 140)
                    Button("Clear") { settings.brandLogoPath = "" }
                        .secondaryGlassButton().controlSize(.small)
                }
                Button(settings.brandLogoPath.isEmpty ? "Choose…" : "Change…") { selectLogo() }
                    .secondaryGlassButton().controlSize(.small)
            }
            Text("PNG or JPG. Appears at the top of branded PDF exports.")
                .font(.caption2).foregroundColor(.secondary)
        }

        // Destructive action — isolated at the very bottom.
        SettingsSection(title: "Reset", icon: "arrow.counterclockwise") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reset all settings")
                    Text("Restores preferences to defaults. Your downloads, transcripts, history, and API keys are not touched.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("Reset…") { showResetConfirmation = true }
                    .secondaryGlassButton().controlSize(.small).tint(.red)
            }
        }
    }

    private var appDataFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MindExtract")
    }

    private func resetSettingsToDefaults() {
        settings.transcriptionEngine = .automatic
        settings.transcriptionOutputFormat = .txt
        settings.defaultTranscriptionLanguage = "auto"
        settings.enableSpeakerDiarization = true
        settings.customVocabulary = ""
        settings.parallelDownloads = 2
        settings.downloadSubtitles = false
        settings.aiBackend = .apple
        settings.showNotifications = true
        settings.playSoundOnComplete = true
        settings.autoGenerateMeetingNotes = true
        settings.translateToEnglish = false
        settings.calendarSuggestionsEnabled = true
        settings.calendarLeadMinutes = 5
        settings.excludedCalendarIDs = ""
        settings.autoShowCaptions = false
        settings.preferredMicrophoneID = ""
        activeMeeting.setEnabled(true)
        settings.downloadQuality = .best
        settings.autoTranscribeOnDownload = false
        settings.notifyOnTranscriptionComplete = true
        settings.brandName = ""
        settings.brandLogoPath = ""
        settings.appLockEnabled = false
        // Re-sync the live calendar monitor with the restored setting.
        calendar.setSuggestionsEnabled(settings.calendarSuggestionsEnabled)
    }

    // MARK: - YouTube Auth Content

    @ViewBuilder
    private var youtubeAuthContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch downloader.youtubeSignInState {
            case .idle:
                if settings.youtubeSignedIn {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Signed in to YouTube")
                            .fontWeight(.medium)
                        Spacer()
                        Button("Sign Out") {
                            showYouTubeSignOutConfirm = true
                        }
                        .secondaryGlassButton()
                        .controlSize(.small)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Some YouTube videos require authentication to download or transcribe.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button(action: {
                            downloader.startYouTubeSignIn()
                        }) {
                            HStack {
                                Image(systemName: "person.badge.key")
                                Text("Sign in to YouTube")
                            }
                        }
                        .primaryGlassButton()
                        .controlSize(.regular)
                    }
                }

            case .signingIn:
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Waiting for sign-in…")
                            .fontWeight(.medium)
                        Spacer()
                        Button("Cancel") {
                            downloader.cancelSignIn()
                        }
                        .secondaryGlassButton()
                        .controlSize(.small)
                    }

                    if !downloader.youtubeDeviceCode.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("A browser window should open automatically.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack {
                                Text("Enter this code:")
                                    .font(.caption)
                                Text(downloader.youtubeDeviceCode)
                                    .font(.system(.body, design: .monospaced))
                                    .fontWeight(.bold)
                                    .foregroundColor(.primary)
                                    .textSelection(.enabled)
                                Button(action: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(downloader.youtubeDeviceCode, forType: .string)
                                }) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption)
                                        .frame(width: 24, height: 24)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Copy code")
                            }
                            if !downloader.youtubeVerificationURL.isEmpty {
                                Button("Open sign-in page again") {
                                    if let url = URL(string: downloader.youtubeVerificationURL) {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .buttonStyle(.link)
                                .font(.caption)
                            }
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(8)
                    }
                }

            case .signedIn:
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Signed in to YouTube")
                        .fontWeight(.medium)
                    Spacer()
                    Button("Sign Out") {
                        showYouTubeSignOutConfirm = true
                    }
                    .secondaryGlassButton()
                    .controlSize(.small)
                }

            case .error(let message):
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Button(action: {
                        downloader.startYouTubeSignIn()
                    }) {
                        HStack {
                            Image(systemName: "person.badge.key")
                            Text("Try Again")
                        }
                    }
                    .primaryGlassButton()
                    .controlSize(.regular)
                }
            }

            Divider()

            DisclosureGroup("Advanced", isExpanded: $showAdvancedAuth) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cookies File")
                                .font(.caption)
                                .fontWeight(.medium)
                            Text("Use an exported cookies.txt file")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if !settings.cookiesFilePath.isEmpty {
                            Text(URL(fileURLWithPath: settings.cookiesFilePath).lastPathComponent)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Button("Clear") {
                                settings.cookiesFilePath = ""
                            }
                            .controlSize(.mini)
                        }
                        Button(settings.cookiesFilePath.isEmpty ? "Select…" : "Change…") {
                            selectCookiesFile()
                        }
                        .controlSize(.mini)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Browser Cookies")
                                .font(.caption)
                                .fontWeight(.medium)
                            Text("Read cookies from a browser")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $settings.cookieBrowser) {
                            ForEach(CookieBrowser.allCases, id: \.self) { browser in
                                Text(browser.displayName).tag(browser)
                            }
                        }
                        .frame(width: 160)
                        .controlSize(.small)
                    }
                }
                .padding(.top, 6)
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    // MARK: - File Pickers

    private func selectCookiesFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .data]
        panel.title = "Select cookies.txt File"
        panel.message = "Export cookies.txt from your browser using a browser extension like \"Get cookies.txt LOCALLY\""
        if panel.runModal() == .OK, let url = panel.url {
            settings.cookiesFilePath = url.path
        }
    }

    private func selectLogo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.title = "Choose a logo image"
        if panel.runModal() == .OK, let url = panel.url {
            settings.brandLogoPath = url.path
        }
    }

    private func selectDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select Download Folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.downloadPath = url.path
        }
    }
}

// MARK: - Settings Section

struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundColor(.primary)

            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .glassCard(padding: 16, cornerRadius: 12)
        }
    }
}


// MARK: - WhisperKit Model Row

struct ModelRow: View {
    let model: WhisperModel
    @ObservedObject var transcriptionManager = TranscriptionManager.shared

    private var isDownloaded: Bool { transcriptionManager.isModelDownloaded(model) }
    private var isDownloading: Bool { transcriptionManager.downloadingModel == model }
    private var isPrewarming: Bool { transcriptionManager.prewarmingModel == model }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(model.displayName).fontWeight(.medium).chromeText()
                    if model.isRecommended {
                        Text("Recommended")
                            .font(.caption)
                            .chromeText()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08))
                            .foregroundColor(.primary)
                            .cornerRadius(4)
                    }
                }
                Text(model.description).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Text(model.sizeDescription)
                .font(.caption).foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: 70, alignment: .trailing)

            if isDownloading {
                HStack(spacing: 8) {
                    ProgressView(value: transcriptionManager.modelDownloadProgress).frame(width: 60)
                    Button(action: { transcriptionManager.cancelModelDownload() }) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Cancel download")
                }
                .frame(width: 100, alignment: .trailing)
            } else if isDownloaded {
                HStack(spacing: 8) {
                    if isPrewarming {
                        ProgressView().scaleEffect(0.5).help("Optimizing model for your device…")
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    }
                    Button(action: { transcriptionManager.deleteModel(model) }) {
                        Image(systemName: "trash").foregroundColor(.red)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Delete model")
                }
                .frame(width: 100, alignment: .trailing)
            } else {
                Button(action: { transcriptionManager.downloadModel(model) }) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 17))
                        .foregroundStyle(transcriptionManager.downloadingModel == nil
                                         ? DS.Colors.accent : Color.secondary.opacity(0.4))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Download model")
                .disabled(transcriptionManager.downloadingModel != nil)
                .frame(width: 100, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    SettingsView(downloader: YTDLPWrapper())
}
