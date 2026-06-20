import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var downloader: YTDLPWrapper
    @ObservedObject var transcriptionManager = TranscriptionManager.shared
    @State private var showAdvancedAuth = false
    @State private var showResetConfirmation = false
    @State private var showWhisperKitModels = false
    @State private var openAIKey = KeychainHelper.get("openai-api-key") ?? ""
    @State private var anthropicKey = KeychainHelper.get("anthropic-api-key") ?? ""
    @State private var ollamaModels: [String] = []
    @State private var ollamaDetectFailed = false
    @State private var openAITest: KeyTestState = .idle
    @State private var anthropicTest: KeyTestState = .idle

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

    private func testKey(provider: AIBackendChoice) {
        let key = provider == .openAI ? openAIKey : anthropicKey
        guard !key.isEmpty else {
            if provider == .openAI { openAITest = .fail("Enter a key first") } else { anthropicTest = .fail("Enter a key first") }
            return
        }
        if provider == .openAI { openAITest = .testing } else { anthropicTest = .testing }
        Task { @MainActor in
            var req: URLRequest
            if provider == .openAI {
                req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            } else {
                req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
                req.setValue(key, forHTTPHeaderField: "x-api-key")
                req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            }
            req.timeoutInterval = 12
            let result: KeyTestState
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                result = code == 200 ? .ok : .fail("Key rejected (HTTP \(code))")
            } catch {
                result = .fail("Couldn't reach the server")
            }
            if provider == .openAI { openAITest = result } else { anthropicTest = result }
        }
    }

    @ViewBuilder
    private func keyTestControl(_ state: KeyTestState, provider: AIBackendChoice) -> some View {
        HStack(spacing: 6) {
            Button("Test") { testKey(provider: provider) }
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

    private var appleSpeechAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // MARK: Transcription (the headline feature — first)
                    SettingsSection(title: "Transcription", icon: "text.bubble") {
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
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if settings.transcriptionEngine == .appleSpeech && !appleSpeechAvailable {
                            Text("Apple Speech requires macOS 26 — WhisperKit will be used instead until you upgrade.")
                                .font(.caption)
                                .foregroundColor(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
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

                        Toggle(isOn: $settings.enableSpeakerDiarization) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Speaker labels")
                                Text("Identify who said what in conversations and interviews")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .help("Adds “Speaker 1”, “Speaker 2”… labels to the transcript. You can rename them afterwards.")

                        Divider()
                            .padding(.vertical, 2)

                        // WhisperKit is the optional/advanced engine — tucked away.
                        DisclosureGroup(isExpanded: $showWhisperKitModels) {
                            VStack(alignment: .leading, spacing: 10) {
                                if transcriptionManager.useAppleSpeech() {
                                    Text("You're using Apple's built-in speech — these models are only needed if you switch the engine to WhisperKit.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                HStack {
                                    Text("Default model")
                                    Spacer()
                                    Picker("", selection: $settings.defaultWhisperModel) {
                                        ForEach(WhisperModel.allCases) { model in
                                            HStack {
                                                Text(model.displayName)
                                                if !transcriptionManager.isModelDownloaded(model) {
                                                    Text("(not downloaded)")
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                            .tag(model)
                                        }
                                    }
                                    .frame(width: 200)
                                }

                                VStack(spacing: 0) {
                                    ForEach(WhisperModel.allCases) { model in
                                        ModelRow(model: model)
                                    }
                                }

                                HStack {
                                    Text("Storage used")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(transcriptionManager.formatBytes(transcriptionManager.totalStorageUsed()))
                                        .foregroundColor(.secondary)
                                        .fontWeight(.medium)
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("WhisperKit models")
                                Text("Optional offline models — an alternative to Apple's built-in speech")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        if !transcriptionManager.isFfmpegAvailable {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("Audio tools are missing — transcription is unavailable. Reinstall MindExtract to fix this.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    // MARK: AI summaries & chat
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
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if (settings.aiBackend == .openAI && openAIKey.isEmpty) ||
                           (settings.aiBackend == .anthropic && anthropicKey.isEmpty) {
                            Label("Add an API key below to use this provider.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundColor(.orange)
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
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 200)
                                } else {
                                    Picker("", selection: $settings.ollamaModel) {
                                        ForEach(ollamaModels, id: \.self) { Text($0).tag($0) }
                                    }
                                    .frame(width: 200)
                                }
                                Button("Detect") { detectOllamaModels() }
                                    .secondaryGlassButton()
                                    .controlSize(.small)
                                    .help("List the models you've pulled in Ollama")
                            }
                            if ollamaDetectFailed {
                                Text("Couldn't reach Ollama — make sure the Ollama app is running.")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }

                        case .openAI:
                            HStack {
                                Text("API key")
                                Spacer()
                                SecureField("sk-…", text: $openAIKey)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 200)
                                    .onChange(of: openAIKey) { _, new in
                                        KeychainHelper.set(new, key: "openai-api-key")
                                        openAITest = .idle
                                    }
                            }
                            HStack {
                                Spacer()
                                keyTestControl(openAITest, provider: .openAI)
                            }
                            HStack {
                                Text("Model")
                                Spacer()
                                TextField("gpt-4o-mini", text: $settings.openAIModel)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 200)
                            }
                            Text("Stored securely in your Keychain.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                        case .anthropic:
                            HStack {
                                Text("API key")
                                Spacer()
                                SecureField("sk-ant-…", text: $anthropicKey)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 200)
                                    .onChange(of: anthropicKey) { _, new in
                                        KeychainHelper.set(new, key: "anthropic-api-key")
                                        anthropicTest = .idle
                                    }
                            }
                            HStack {
                                Spacer()
                                keyTestControl(anthropicTest, provider: .anthropic)
                            }
                            HStack {
                                Text("Model")
                                Spacer()
                                TextField("claude-haiku-4-5-20251001", text: $settings.anthropicModel)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 200)
                            }
                            Text("Stored securely in your Keychain.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // MARK: Downloads
                    SettingsSection(title: "Downloads", icon: "arrow.down.circle") {
                        HStack {
                            Text("Save downloads to")
                            Spacer()
                            Text(settings.downloadPath)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 150)
                            Button("Show") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: settings.downloadPath))
                            }
                            .secondaryGlassButton()
                            .controlSize(.small)
                            .help("Reveal the downloads folder in Finder")
                            Button("Change…") {
                                selectDownloadFolder()
                            }
                            .secondaryGlassButton()
                            .controlSize(.small)
                        }

                        HStack {
                            Text("Simultaneous downloads")
                            Spacer()
                            Picker("", selection: $settings.parallelDownloads) {
                                Text("1").tag(1)
                                Text("2").tag(2)
                                Text("3").tag(3)
                                Text("4").tag(4)
                            }
                            .frame(width: 200)
                            .help("How many videos download at the same time when you queue several.")
                        }

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
                                .frame(width: 200)
                            }
                        }
                    }

                    // MARK: YouTube sign-in
                    // MARK: Notifications
                    SettingsSection(title: "Notifications", icon: "bell") {
                        Toggle("Show a notification when a download finishes", isOn: $settings.showNotifications)
                        Toggle("Play a sound when a download finishes", isOn: $settings.playSoundOnComplete)
                    }

                    // MARK: YouTube Sign-in (niche — kept near the bottom)
                    SettingsSection(title: "YouTube Sign-in", icon: "play.rectangle.fill") {
                        Text("Most videos download without signing in. Sign in only if YouTube blocks a download — for example age-restricted or members-only videos, or a “confirm you're not a bot” error.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        youtubeAuthContent
                    }

                    // MARK: About
                    SettingsSection(title: "About", icon: "info.circle") {
                        HStack {
                            Text("Version")
                            Spacer()
                            Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))")
                                .foregroundColor(.secondary)
                            Button("Check for Updates") {
                                NotificationCenter.default.post(name: .checkForUpdates, object: nil)
                            }
                            .secondaryGlassButton()
                            .controlSize(.small)
                        }
                        Text("Everything runs on your Mac — no audio or video ever leaves your computer unless you choose a cloud AI provider.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Divider()

                        Text("Please use MindExtract responsibly: download and transcribe only content you have the right to use, and respect the terms of the platforms and the rights of creators. You are responsible for how you use downloaded material.")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
                        .font(.caption)
                        .foregroundColor(.secondary)

                        Divider().padding(.vertical, 2)

                        HStack {
                            Button("Open App Data Folder") {
                                NSWorkspace.shared.open(appDataFolder)
                            }
                            .secondaryGlassButton()
                            .controlSize(.small)
                            .help("Where transcripts, history, and models are stored")

                            Spacer()

                            Button("Reset Settings…") { showResetConfirmation = true }
                                .secondaryGlassButton()
                                .controlSize(.small)
                                .tint(.red)
                        }
                    }
                }
                .padding()
            }
        }
        .onAppear {
            transcriptionManager.loadDownloadedModels()
        }
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $showResetConfirmation, titleVisibility: .visible) {
            Button("Reset Settings", role: .destructive) { resetSettingsToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This restores preferences like engine, language, and download options. Your downloads, transcripts, history, and API keys are not touched.")
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
        settings.parallelDownloads = 2
        settings.downloadSubtitles = false
        settings.aiBackend = .apple
        settings.showNotifications = true
        settings.playSoundOnComplete = true
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
                            downloader.signOutYouTube()
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
                        downloader.signOutYouTube()
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
