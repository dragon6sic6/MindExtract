import SwiftUI
import UniformTypeIdentifiers

/// The Settings window's panes. An overview of what does what, then one pane per
/// area — so a setting has exactly one home and every pane looks the same.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case overview
    case general
    case recording
    case transcription
    case dictation
    case ai
    case imports

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .overview: return "Overview"
        case .general: return "General"
        case .recording: return "Recording"
        case .transcription: return "Transcription"
        case .dictation: return "Dictation"
        case .ai: return "AI"
        case .imports: return "Import"
        }
    }

    var windowTitle: String {
        switch self {
        case .overview: return String(localized: "Overview")
        case .general: return String(localized: "General")
        case .recording: return String(localized: "Recording")
        case .transcription: return String(localized: "Transcription")
        case .dictation: return String(localized: "Dictation")
        case .ai: return String(localized: "AI")
        case .imports: return String(localized: "Import")
        }
    }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .general: return "gearshape"
        case .recording: return "record.circle"
        case .transcription: return "text.bubble"
        case .dictation: return "keyboard"
        case .ai: return "sparkles"
        case .imports: return "square.and.arrow.down"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var downloader: YTDLPWrapper
    @ObservedObject var transcriptionManager = TranscriptionManager.shared
    @ObservedObject var dictation = DictationController.shared
    @ObservedObject private var recorder = MeetingRecorder.shared
    /// Persisted so other parts of the app can deep-link a pane before opening Settings.
    @AppStorage("settingsCategory") private var category: SettingsCategory = .overview
    @State private var showResetConfirmation = false
    @State private var confirmRemoveLegacyKB = false
    @State private var showYouTubeSignOutConfirm = false
    @State private var ollamaModels: [String] = []
    @State private var ollamaDetectFailed = false
    @State private var keyTests: [String: KeyTestState] = [:]   // keyed by Keychain account

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsCategory.allCases, selection: Binding(
                get: { Optional(category) },
                set: { if let c = $0 { category = c } })) { c in
                Label(c.title, systemImage: c.icon).tag(c)
            }
            .listStyle(.sidebar)
            .frame(width: 200)
            Divider()
            Form {
                categoryContent
            }
            .formStyle(.grouped)
        }
        .navigationTitle(category.windowTitle)
        .frame(minWidth: 760, idealWidth: 820, minHeight: 540, idealHeight: 640)
        .onAppear {
            transcriptionManager.loadDownloadedModels()
            recorder.refreshPermissions()
        }
        .confirmationDialog("Reset all settings?", isPresented: $showResetConfirmation, titleVisibility: .visible) {
            Button("Reset Settings", role: .destructive) { resetSettingsToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every preference goes back to its default. Your transcripts, recordings and API keys are not touched.")
        }
        .confirmationDialog("Sign out of YouTube?", isPresented: $showYouTubeSignOutConfirm, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { downloader.signOutYouTube() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to sign in again to download members-only or age-restricted videos.")
        }
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch category {
        case .overview: overviewPane
        case .general: generalPane
        case .recording: recordingPane
        case .transcription: transcriptionPane
        case .dictation: dictationPane
        case .ai: aiPane
        case .imports: importPane
        }
    }

    // MARK: - Shared rows

    /// A permission's status with a Grant button when missing.
    private func permissionRow(_ title: LocalizedStringKey, granted: Bool, action: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Allow…", action: action)
            }
        }
    }

    /// A one-line warning inside a section.
    private func warningRow(_ text: LocalizedStringKey) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
    }

    // MARK: - Overview

    /// Where a job runs — the one thing people ask about most.
    private enum Where { case onMac, internet, sentTo(String) }

    /// Every job MindExtract does, the engine doing it right now, and where it runs.
    @ViewBuilder
    private var overviewPane: some View {
        Section {
            engineRow("Transcribing Swedish", icon: "text.bubble",
                      engine: swedishEngine, where: .onMac, pane: .transcription,
                      warning: transcriptionManager.isModelDownloaded(.pianissimo) ? nil : "Download Pianissimo for the best Swedish.")
            engineRow("Transcribing other languages", icon: "globe",
                      engine: otherLanguagesEngine, where: .onMac, pane: .transcription)
            engineRow("Live text while recording", icon: "waveform",
                      engine: liveEngine, where: .onMac, pane: .transcription)
            engineRow("Telling speakers apart", icon: "person.2",
                      engine: settings.enableSpeakerDiarization ? "SpeakerKit" : String(localized: "Off"),
                      where: .onMac, pane: .transcription)
            engineRow("Dictation (hold \(settings.dictationKey.name))", icon: "keyboard",
                      engine: dictationEngine, where: .onMac, pane: .dictation)
        } header: {
            Text("Speech to text")
        } footer: {
            Text("Turning speech into text always happens on your Mac, whatever you choose below.")
        }

        Section {
            engineRow("Notes and titles after a recording", icon: "sparkles",
                      engine: aiEngineName, where: aiWhere, pane: .ai)
            engineRow("Ask anything and follow-up email", icon: "bubble.left.and.text.bubble.right",
                      engine: aiEngineName, where: aiWhere, pane: .ai)
        } header: {
            Text("Writing with AI")
        } footer: {
            Text("The AI engine only works with text that has already been transcribed. It never hears the audio.")
        }

        Section {
            engineRow("Downloading from a link", icon: "arrow.down.circle",
                      engine: "yt-dlp", where: .internet, pane: .imports)
        } header: {
            Text("Downloads")
        }
    }

    private func engineRow(_ job: LocalizedStringKey, icon: String, engine: String, where place: Where,
                           pane: SettingsCategory, warning: LocalizedStringKey? = nil) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(verbatim: engine).fontWeight(.medium)
                    whereBadge(place)
                }
                Button {
                    category = pane
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .help("Change")
                .accessibilityLabel("Change")
            }
        } label: {
            Label {
                Text(job)
                if let warning {
                    Text(warning).foregroundStyle(.orange)
                }
            } icon: {
                Image(systemName: icon)
            }
        }
    }

    @ViewBuilder
    private func whereBadge(_ place: Where) -> some View {
        switch place {
        case .onMac:
            Label("On your Mac", systemImage: "lock.fill")
                .font(.caption).foregroundStyle(.green)
        case .internet:
            Label("Fetches from the website", systemImage: "network")
                .font(.caption).foregroundStyle(.secondary)
        case .sentTo(let name):
            Label("Text is sent to \(name)", systemImage: "icloud.and.arrow.up")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private var swedishEngine: String {
        transcriptionManager.isModelDownloaded(.pianissimo) ? "Pianissimo" : otherLanguagesEngine
    }

    private var otherLanguagesEngine: String {
        if transcriptionManager.useAppleSpeech() { return String(localized: "Apple speech recognition") }
        return "Whisper · \(settings.defaultWhisperModel.displayName)"
    }

    private var liveEngine: String {
        let swedish = transcriptionManager.isModelDownloaded(.pianissimo) ? "Pianissimo" : nil
        let other = MeetingRecorder.defaultLiveModel(for: "en").map { "Whisper · \($0.displayName)" }
        switch (swedish, other) {
        case let (s?, o?): return String(localized: "\(s) (Swedish), \(o)")
        case let (s?, nil): return String(localized: "\(s) (Swedish only)")
        case let (nil, o?): return o
        default: return String(localized: "None — download a speech model")
        }
    }

    private var dictationEngine: String {
        guard settings.dictationEnabled else { return String(localized: "Off") }
        if settings.dictationLanguage == "sv", transcriptionManager.isModelDownloaded(.pianissimo) { return "Pianissimo" }
        return "Whisper · \(transcriptionManager.multilingualBaseModel().displayName)"
    }

    private var aiEngineName: String {
        switch settings.aiBackend {
        case .ollama: return settings.ollamaModel.isEmpty ? "Ollama" : "Ollama · \(settings.ollamaModel)"
        default: return settings.aiBackend.rawValue
        }
    }

    private var aiWhere: Where {
        switch settings.aiBackend {
        case .apple, .ollama: return .onMac
        default: return .sentTo(settings.aiBackend.shortName)
        }
    }

    // MARK: - General

    @ViewBuilder
    private var generalPane: some View {
        Section {
            Picker("Appearance", selection: $settings.appAppearance) {
                Text("Automatic").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Appearance")
        } footer: {
            Text("Automatic follows your Mac's light or dark mode and accent color.")
        }

        Section {
            Toggle(isOn: $settings.appLockEnabled) {
                Text("Require Touch ID or password")
                Text("Locks MindExtract when you switch away, so client or patient material isn't visible on an unlocked Mac.")
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text("Everything stays on your Mac. For encryption of the files on disk, turn on FileVault in System Settings → Privacy & Security.")
        }

        Section {
            TextField("Business name", text: $settings.brandName, prompt: Text("Shown at the top of PDFs"))
            LabeledContent("Logo") {
                HStack {
                    if !settings.brandLogoPath.isEmpty {
                        Text(URL(fileURLWithPath: settings.brandLogoPath).lastPathComponent)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Remove") { settings.brandLogoPath = "" }
                    }
                    Button(settings.brandLogoPath.isEmpty ? "Choose…" : "Change…") { selectLogo() }
                }
            }
        } header: {
            Text("PDF letterhead")
        } footer: {
            Text("Your name and logo on exported PDFs you hand to clients. PNG or JPG.")
        }

        Section("About MindExtract") {
            LabeledContent("Version") {
                HStack {
                    Text(appVersion).foregroundStyle(.secondary)
                    Button("Check for Updates…") {
                        NotificationCenter.default.post(name: .checkForUpdates, object: nil)
                    }
                }
            }
            LabeledContent("Your data") {
                Button("Show in Finder") {
                    // Recordings and models live in one folder, the notes list in another.
                    let notesList = appDataFolder.deletingLastPathComponent().appendingPathComponent("MindExtract")
                    NSWorkspace.shared.activateFileViewerSelecting([appDataFolder, notesList])
                }
            }
            DisclosureGroup("Acknowledgements") {
                acknowledgementRow("Klang Pianissimo (Klang AI AB)", "CC BY 4.0", "https://huggingface.co/KlangAI/pianissimo-sv")
                acknowledgementRow("FluidAudio", "Apache 2.0", "https://github.com/FluidInference/FluidAudio")
                acknowledgementRow("WhisperKit & SpeakerKit (Argmax)", "MIT", "https://github.com/argmaxinc/argmax-oss-swift")
                acknowledgementRow("yt-dlp", "Unlicense", "https://github.com/yt-dlp/yt-dlp")
                acknowledgementRow("FFmpeg", "LGPL 2.1+", "https://ffmpeg.org/legal.html")
                acknowledgementRow("Sparkle", "MIT", "https://github.com/sparkle-project/Sparkle")
            }
            Text("Download and transcribe only content you have the right to use.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        Section {
            LabeledContent("Reset all settings") {
                Button("Reset…", role: .destructive) { showResetConfirmation = true }
            }
        } footer: {
            Text("Transcripts, recordings and API keys are kept.")
        }
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(short) (\(build))"
    }

    private func acknowledgementRow(_ name: String, _ license: String, _ url: String) -> some View {
        LabeledContent {
            Link(license, destination: URL(string: url)!)
        } label: {
            Text(verbatim: name)
        }
    }

    // MARK: - Recording

    @ViewBuilder
    private var recordingPane: some View {
        Section {
            permissionRow("Microphone", granted: recorder.micGranted) {
                Task { _ = await recorder.requestMicPermission() }
            }
            permissionRow("Meeting audio", granted: recorder.screenGranted) {
                recorder.requestScreenPermission()
            }
            Picker("Microphone to use", selection: $settings.preferredMicrophoneID) {
                Text("System default").tag("")
                ForEach(MeetingRecorder.availableMicrophones(), id: \.uniqueID) { dev in
                    Text(verbatim: dev.localizedName).tag(dev.uniqueID)
                }
            }
        } header: {
            Text("Audio")
        } footer: {
            Text("MindExtract records your microphone and the other participants' audio. No bot joins the call, and nothing leaves your Mac. \"System default\" follows AirPods and headsets automatically.")
        }

        Section {
            LabeledContent("Live text") {
                Text(verbatim: liveEngine)
            }
            Toggle(isOn: $settings.autoShowCaptions) {
                Text("Show live captions")
                Text("A floating window with the live text, on top of Zoom and Teams.")
            }
            Toggle(isOn: $settings.confirmBeforeTranscribing) {
                Text("Ask before transcribing")
                Text("Off: when you finish, the whole recording is transcribed again (more accurate than the live text) in the language that's spoken.")
            }
        } header: {
            Text("While and after recording")
        }
    }

    // MARK: - Transcription

    @ViewBuilder
    private var transcriptionPane: some View {
        if !transcriptionManager.isFfmpegAvailable {
            Section {
                warningRow("Audio tools are missing, so transcription is unavailable. Reinstall MindExtract to fix it.")
            }
        }

        Section {
            Picker("Spoken language", selection: $settings.defaultTranscriptionLanguage) {
                ForEach(AppSettings.transcriptionLanguages, id: \.code) { lang in
                    Text(verbatim: lang.name).tag(lang.code)
                }
            }
            Toggle(isOn: $settings.enableSpeakerDiarization) {
                Text("Tell speakers apart")
                Text("Labels who said what. You can rename speakers afterwards.")
            }
            Picker("Save transcripts as", selection: $settings.transcriptionOutputFormat) {
                ForEach(TranscriptionOutputFormat.allCases, id: \.self) { format in
                    Text(format.displayName).tag(format)
                }
            }
            Toggle("Notify me when a transcript is ready", isOn: $settings.notifyOnTranscriptionComplete)
        } header: {
            Text("Transcripts")
        } footer: {
            Text("Automatic detects the language of each recording. You can always transcribe again in another language.")
        }

        Section {
            LabeledContent {
                Text(verbatim: transcriptionManager.isModelDownloaded(.pianissimo) ? "Pianissimo" : String(localized: "Not downloaded"))
            } label: {
                Text("Swedish")
                Text("Always Pianissimo when it's downloaded — the best at Swedish.")
            }
            Picker(selection: Binding(
                get: { settings.transcriptionEngine == .whisperKit ? TranscriptionEngineChoice.whisperKit : .appleSpeech },
                set: { settings.transcriptionEngine = $0 })) {
                Text("Apple speech recognition").tag(TranscriptionEngineChoice.appleSpeech)
                Text("Whisper").tag(TranscriptionEngineChoice.whisperKit)
            } label: {
                Text("Other languages")
                Text(settings.transcriptionEngine == .whisperKit
                     ? "Whisper: downloadable models, handles the most languages."
                     : "Apple: built into macOS, no download. Falls back to Whisper for languages Apple can't do.")
            }
            Picker(selection: $settings.defaultWhisperModel) {
                ForEach(WhisperModel.allCases.filter { !$0.isSwedishOnly }) { model in
                    Text(model.displayName).tag(model)
                }
            } label: {
                Text("Whisper model")
                Text("Used for other languages when Whisper is chosen, and for live text and dictation in other languages.")
            }
        } header: {
            Text("Which engine is used")
        } footer: {
            Text("Everything here runs on your Mac. Notes and summaries are written afterwards by the AI engine (Settings → AI), from the finished transcript.")
        }

        Section {
            ForEach(WhisperModel.allCases.filter { $0.isSwedishOnly }) { model in
                ModelRow(model: model)
            }
            ModelRow(model: .small)
            DisclosureGroup("More models") {
                ForEach(WhisperModel.allCases.filter { !$0.isSwedishOnly && $0 != .small }) { model in
                    ModelRow(model: model)
                }
            }
            if let legacy = transcriptionManager.legacyKBModelsSize() {
                LabeledContent {
                    Button("Remove", role: .destructive) { confirmRemoveLegacyKB = true }
                } label: {
                    Text("Old KB-Whisper models")
                    Text("No longer used. \(transcriptionManager.formatBytes(legacy)) on disk.")
                }
                .confirmationDialog("Remove the old KB-Whisper models?", isPresented: $confirmRemoveLegacyKB) {
                    Button("Remove \(transcriptionManager.formatBytes(legacy))", role: .destructive) {
                        transcriptionManager.removeLegacyKBModels()
                    }
                } message: {
                    Text("They aren't used anymore. Your transcripts aren't affected.")
                }
            }
            LabeledContent("Space used", value: transcriptionManager.formatBytes(transcriptionManager.totalStorageUsed()))
        } header: {
            Text("Speech models")
        } footer: {
            Text("Downloaded once, then they work offline. Pianissimo by Klang AI AB, CC BY 4.0.")
        }

        Section {
            TextEditor(text: $settings.customVocabulary)
                .font(.body.monospaced())
                .frame(minHeight: 80)
                .accessibilityLabel("Names and terms")
        } header: {
            Text("Names and terms")
        } footer: {
            Text("People, places, companies and jargon to spell correctly — one per line. Only the Whisper models read this list; Pianissimo and Apple don't.")
        }
    }

    // MARK: - Dictation

    @ViewBuilder
    private var dictationPane: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settings.dictationEnabled },
                set: { settings.dictationEnabled = $0; dictation.refresh() })) {
                Text("Hold \(settings.dictationKey.name) to dictate")
                Text("Hold the key anywhere, speak, let go — the text is typed where your cursor is.")
            }
            if settings.dictationEnabled {
                Picker(selection: Binding(
                    get: { settings.dictationKey },
                    set: { settings.dictationKey = $0; dictation.refresh() })) {
                    ForEach(DictationKey.allCases) { key in
                        Text(verbatim: key.name.prefix(1).uppercased() + key.name.dropFirst()).tag(key)
                    }
                } label: {
                    Text("Key to hold")
                    if let note = settings.dictationKey.note { Text(verbatim: note) }
                }
                permissionRow("Accessibility", granted: dictation.accessibilityGranted) {
                    dictation.requestAccessibility()
                    dictation.openAccessibilitySettings()
                }
                Picker("Language", selection: Binding(
                    get: { settings.dictationLanguage },
                    set: { settings.dictationLanguage = $0; dictation.refresh() })) {
                    ForEach(AppSettings.transcriptionLanguages, id: \.code) { lang in
                        Text(verbatim: lang.name).tag(lang.code)
                    }
                }
                if (settings.dictationLanguage == "sv" || settings.dictationLanguage == "auto"),
                   !transcriptionManager.isModelDownloaded(.pianissimo) {
                    ModelRow(model: .pianissimo)
                }
            }
            LabeledContent("Engine") {
                Text(verbatim: dictationEngine)
            }
        } header: {
            Text("Dictation")
        } footer: {
            Text("Swedish uses Pianissimo, other languages the Whisper model — on your Mac, no AI rewriting. Accessibility lets MindExtract notice the key and type into other apps; it never reads what you type. Audio is discarded right after.")
        }

        if !dictation.recent.isEmpty {
            Section {
                ForEach(dictation.recent) { entry in
                    LabeledContent {
                        Button { dictation.copy(entry) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copy")
                            .accessibilityLabel("Copy")
                    } label: {
                        Text(verbatim: entry.text).textSelection(.enabled)
                    }
                }
            } header: {
                Text("Recent dictations")
            } footer: {
                Text("Kept until you quit, in case the text landed where there was no text field.")
            }
        }
    }

    // MARK: - AI

    @ViewBuilder
    private var aiPane: some View {
        Section {
            Picker("AI engine", selection: $settings.aiBackend) {
                ForEach(AIBackendChoice.allCases) { choice in
                    Text(verbatim: choice.rawValue).tag(choice)
                }
            }
            switch settings.aiBackend {
            case .apple:
                EmptyView()
            case .ollama:
                LabeledContent("Model") {
                    HStack {
                        if ollamaModels.isEmpty {
                            TextField("Model", text: $settings.ollamaModel, prompt: Text("e.g. llama3.2"))
                                .labelsHidden()
                        } else {
                            Picker("Model", selection: $settings.ollamaModel) {
                                ForEach(ollamaModels, id: \.self) { Text(verbatim: $0).tag($0) }
                            }
                            .labelsHidden()
                        }
                        Button("Find Models") { detectOllamaModels() }
                    }
                }
                if ollamaDetectFailed {
                    warningRow("Couldn't reach Ollama. Make sure the Ollama app is running.")
                } else if !ollamaModels.isEmpty, !ollamaModels.contains(settings.ollamaModel) {
                    warningRow("The selected model isn't installed in Ollama.")
                }
            default:
                cloudProviderConfig(settings.aiBackend)
            }
        } header: {
            Text("AI engine")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Used for: notes and titles after a recording, Ask anything and follow-up emails. Not used for transcribing — that's Settings → Transcription.")
                Label(settings.aiBackend.detail,
                      systemImage: [.apple, .ollama].contains(settings.aiBackend) ? "lock.fill" : "icloud.and.arrow.up")
                    .foregroundStyle([.apple, .ollama].contains(settings.aiBackend) ? .green : .orange)
            }
        }

        Section {
            Toggle(isOn: $settings.autoGenerateMeetingNotes) {
                Text("Write notes after every recording")
                Text("Notes, decisions and tasks — and a title — are ready when the transcript is.")
            }
        } header: {
            Text("After a recording")
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
        guard !key.isEmpty else { keyTests[kc] = .fail(String(localized: "Enter a key first")); return }
        keyTests[kc] = .testing
        var req: URLRequest
        if provider == .anthropic {
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if let cfg = provider.compatConfig(settings) {
            let base = cfg.baseURL.hasSuffix("/") ? String(cfg.baseURL.dropLast()) : cfg.baseURL
            guard !base.isEmpty, let u = URL(string: base + "/models") else {
                keyTests[kc] = .fail(String(localized: "Set the server address first")); return
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
                result = code == 200 ? .ok : .fail(String(localized: "Key rejected (HTTP \(code))"))
            } catch {
                result = .fail(String(localized: "Couldn't reach the server"))
            }
            keyTests[kc] = result
        }
    }

    /// Key + model (+ server address for custom) for any cloud provider.
    @ViewBuilder
    private func cloudProviderConfig(_ choice: AIBackendChoice) -> some View {
        if choice == .custom {
            TextField("Server address", text: $settings.customBaseURL, prompt: Text(verbatim: "https://your-host/v1"))
        }
        if let kc = choice.keychainKey {
            LabeledContent("API key") {
                HStack {
                    SecureField("API key", text: keychainBinding(kc), prompt: Text("Paste your key"))
                        .labelsHidden()
                    Button("Test") { testKey(choice) }
                }
            }
            switch keyTests[kc] ?? .idle {
            case .idle: EmptyView()
            case .testing: ProgressView().controlSize(.small)
            case .ok: Label("The key works", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .fail(let msg): Label(msg, systemImage: "xmark.circle.fill").foregroundStyle(.orange)
            }
            if (KeychainHelper.get(kc) ?? "").isEmpty, let url = choice.keyURL, let u = URL(string: url) {
                Link("Get an API key", destination: u)
            }
        }
        if let mb = cloudModelBinding(choice) {
            TextField("Model", text: mb)
        }
    }

    private func detectOllamaModels() {
        Task {
            let models = await OllamaBackend.installedModels()
            ollamaModels = models
            ollamaDetectFailed = models.isEmpty
            if (settings.ollamaModel.isEmpty || !models.contains(settings.ollamaModel)), let first = models.first {
                settings.ollamaModel = first
            }
        }
    }

    // MARK: - Import

    @ViewBuilder
    private var importPane: some View {
        Section {
            LabeledContent("Save to") {
                HStack {
                    Text(verbatim: (settings.downloadPath as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Change…") { selectDownloadFolder() }
                }
            }
            Picker("Video quality", selection: $settings.downloadQuality) {
                ForEach(DownloadQuality.allCases) { q in
                    Text(q.displayName).tag(q)
                }
            }
            Picker("Downloads at a time", selection: $settings.parallelDownloads) {
                Text(verbatim: "1").tag(1); Text(verbatim: "2").tag(2); Text(verbatim: "3").tag(3); Text(verbatim: "4").tag(4)
            }
            Toggle(isOn: $settings.autoTranscribeOnDownload) {
                Text("Transcribe after downloading")
                Text("Uses the spoken language from Transcription settings.")
            }
            Toggle("Save subtitles when available", isOn: $settings.downloadSubtitles)
            if settings.downloadSubtitles {
                Picker("Subtitle language", selection: $settings.subtitleLanguage) {
                    ForEach(AppSettings.transcriptionLanguages, id: \.code) { lang in
                        Text(verbatim: lang.name).tag(lang.code)
                    }
                }
            }
        } header: {
            Text("Links and videos")
        }

        Section {
            Toggle("Notify me when a download finishes", isOn: $settings.showNotifications)
            Toggle("Play a sound", isOn: $settings.playSoundOnComplete)
        } header: {
            Text("Notifications")
        }

        Section {
            youtubeAuthContent
        } header: {
            Text("YouTube")
        } footer: {
            Text("Most videos download without signing in. Sign in only if YouTube blocks a download, for example age-restricted or members-only videos.")
        }
    }

    @ViewBuilder
    private var youtubeAuthContent: some View {
        switch downloader.youtubeSignInState {
        case .idle, .signedIn:
            if settings.youtubeSignedIn || downloader.youtubeSignInState == .signedIn {
                LabeledContent("Signed in") {
                    Button("Sign Out…") { showYouTubeSignOutConfirm = true }
                }
            } else {
                LabeledContent("Not signed in") {
                    Button("Sign In…") { downloader.startYouTubeSignIn() }
                }
            }
        case .signingIn:
            LabeledContent("Waiting for sign-in…") {
                Button("Cancel") { downloader.cancelSignIn() }
            }
            if !downloader.youtubeDeviceCode.isEmpty {
                LabeledContent("Code to enter") {
                    HStack {
                        Text(verbatim: downloader.youtubeDeviceCode)
                            .font(.body.monospaced().weight(.bold))
                            .textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(downloader.youtubeDeviceCode, forType: .string)
                        }
                    }
                }
                if let url = URL(string: downloader.youtubeVerificationURL), !downloader.youtubeVerificationURL.isEmpty {
                    Link("Open the sign-in page again", destination: url)
                }
            }
        case .error(let message):
            warningRow(LocalizedStringKey(message))
            Button("Try Again") { downloader.startYouTubeSignIn() }
        }
        DisclosureGroup("Advanced") {
            LabeledContent("Cookies file") {
                HStack {
                    if !settings.cookiesFilePath.isEmpty {
                        Text(verbatim: URL(fileURLWithPath: settings.cookiesFilePath).lastPathComponent)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("Remove") { settings.cookiesFilePath = "" }
                    }
                    Button(settings.cookiesFilePath.isEmpty ? "Choose…" : "Change…") { selectCookiesFile() }
                }
            }
            Picker("Use a browser's sign-in", selection: $settings.cookieBrowser) {
                ForEach(CookieBrowser.allCases, id: \.self) { browser in
                    Text(browser.displayName).tag(browser)
                }
            }
        }
    }

    // MARK: - Actions

    private var appDataFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mindact.mindextract")
    }

    private func resetSettingsToDefaults() {
        settings.resetToDefaults()
        // Re-sync the live services with the restored defaults.
        dictation.refresh()
        AppDelegate.applyAppearance(settings.appAppearance)
        category = .overview
    }

    private func selectCookiesFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .data]
        panel.title = String(localized: "Choose a cookies file")
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
        panel.title = String(localized: "Choose a logo")
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
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url {
            settings.downloadPath = url.path
        }
    }
}

// MARK: - Speech model row

struct ModelRow: View {
    let model: WhisperModel
    @ObservedObject var transcriptionManager = TranscriptionManager.shared

    private var isDownloaded: Bool { transcriptionManager.isModelDownloaded(model) }
    private var isDownloading: Bool { transcriptionManager.downloadingModel == model }
    private var isPrewarming: Bool { transcriptionManager.prewarmingModel == model }

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Text(model.sizeDescription)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if isDownloading {
                    ProgressView(value: transcriptionManager.modelDownloadProgress)
                        .frame(width: 70)
                    Button("Cancel") { transcriptionManager.cancelModelDownload() }
                } else if isDownloaded {
                    if isPrewarming {
                        ProgressView().controlSize(.small).help("Preparing the model for your Mac…")
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            .accessibilityLabel("Downloaded")
                    }
                    Button(role: .destructive) { transcriptionManager.deleteModel(model) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete model")
                    .accessibilityLabel("Delete model")
                } else {
                    Button("Download") { transcriptionManager.downloadModel(model) }
                        .disabled(transcriptionManager.downloadingModel != nil)
                }
            }
        } label: {
            Text(model.displayName)
            Text(model.description)
        }
    }
}

#Preview {
    SettingsView(downloader: YTDLPWrapper())
}
