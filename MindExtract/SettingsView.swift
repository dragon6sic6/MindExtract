import SwiftUI
import UniformTypeIdentifiers

/// The Settings window's panes. An overview of what does what, then one pane per
/// area — so a setting has exactly one home and every pane looks the same.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case overview
    case general
    case transcription
    case imports

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .overview: return "Overview"
        case .general: return "General"
        case .transcription: return "Transcription"
        case .imports: return "Import"
        }
    }

    var windowTitle: String {
        switch self {
        case .overview: return String(localized: "Overview")
        case .general: return String(localized: "General")
        case .transcription: return String(localized: "Transcription")
        case .imports: return String(localized: "Import")
        }
    }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .general: return "gearshape"
        case .transcription: return "text.bubble"
        case .imports: return "square.and.arrow.down"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var downloader: YTDLPWrapper
    @ObservedObject var transcriptionManager = TranscriptionManager.shared
    /// Persisted so other parts of the app can deep-link a pane before opening Settings.
    @AppStorage("settingsCategory") private var category: SettingsCategory = .overview
    @State private var showResetConfirmation = false
    @State private var confirmRemoveLegacyKB = false
    @State private var showYouTubeSignOutConfirm = false

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
        }
        .confirmationDialog("Reset all settings?", isPresented: $showResetConfirmation, titleVisibility: .visible) {
            Button("Reset Settings", role: .destructive) { resetSettingsToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every preference goes back to its default. Your transcripts and downloads are not touched.")
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
        case .transcription: transcriptionPane
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
    private enum Where { case onMac, internet }

    /// Every job MindExtract does, the engine doing it right now, and where it runs.
    @ViewBuilder
    private var overviewPane: some View {
        Section {
            engineRow("Transcribing Swedish", icon: "text.bubble",
                      engine: swedishEngine, where: .onMac, pane: .transcription,
                      warning: transcriptionManager.isModelDownloaded(.pianissimo) ? nil : "Download Pianissimo for the best Swedish.")
            engineRow("Transcribing other languages", icon: "globe",
                      engine: otherLanguagesEngine, where: .onMac, pane: .transcription)
            engineRow("Telling speakers apart", icon: "person.2",
                      engine: settings.enableSpeakerDiarization ? "SpeakerKit" : String(localized: "Off"),
                      where: .onMac, pane: .transcription)
        } header: {
            Text("Speech to text")
        } footer: {
            Text("Turning speech into text always happens on your Mac.")
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
        }
    }

    private var swedishEngine: String {
        transcriptionManager.isModelDownloaded(.pianissimo) ? "Pianissimo" : otherLanguagesEngine
    }

    private var otherLanguagesEngine: String {
        if transcriptionManager.useAppleSpeech() { return String(localized: "Apple speech recognition") }
        return "Whisper · \(settings.defaultWhisperModel.displayName)"
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
            Text("Transcripts and downloads are kept.")
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
            Text("Automatic detects the language of each video. You can always transcribe again in another language.")
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
                Text("Used for other languages when Whisper is chosen.")
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
            if let failure = transcriptionManager.modelDownloadError, failure.model == model, !isDownloading, !isDownloaded {
                Text(verbatim: failure.message).foregroundStyle(.orange)
            } else if isDownloaded && isPrewarming {
                Text("Preparing the model for your Mac — a few minutes the first time.")
            } else {
                Text(model.description)
            }
        }
    }
}

#Preview {
    SettingsView(downloader: YTDLPWrapper())
}
