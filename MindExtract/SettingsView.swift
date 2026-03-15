import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = true
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var downloader: YTDLPWrapper
    @ObservedObject var transcriptionManager = TranscriptionManager.shared
    @State private var showAdvancedAuth = false

    var body: some View {
        VStack(spacing: 0) {
            // Header — matches Download / Transcribe header style
            HStack {
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // MARK: Downloads
                    SettingsSection(title: "Downloads", icon: "arrow.down.circle") {
                        HStack {
                            Text("Default Format")
                            Spacer()
                            Picker("", selection: $settings.defaultFormatPreset) {
                                ForEach(FormatPreset.allCases, id: \.self) { preset in
                                    Label(preset.rawValue, systemImage: preset.icon)
                                        .tag(preset)
                                }
                            }
                            .frame(width: 180)
                        }

                        HStack {
                            Text("Resolution Preset")
                            Spacer()
                            Picker("", selection: $settings.preferredResolution) {
                                Text("720p").tag("720p")
                                Text("1080p").tag("1080p")
                                Text("1440p").tag("1440p")
                                Text("4K (2160p)").tag("2160p")
                            }
                            .frame(width: 180)
                        }

                        HStack {
                            Text("Parallel Downloads")
                            Spacer()
                            Picker("", selection: $settings.parallelDownloads) {
                                Text("1 (Sequential)").tag(1)
                                Text("2").tag(2)
                                Text("3").tag(3)
                                Text("4").tag(4)
                            }
                            .frame(width: 180)
                        }

                        HStack {
                            Text("Save to")
                            Spacer()
                            Text(settings.downloadPath)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 150)
                            Button("Change...") {
                                selectDownloadFolder()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Toggle("Download subtitles when available", isOn: $settings.downloadSubtitles)

                        if settings.downloadSubtitles {
                            HStack {
                                Text("Subtitle Language")
                                Spacer()
                                Picker("", selection: $settings.subtitleLanguage) {
                                    Text("English").tag("en")
                                    Text("Swedish").tag("sv")
                                    Text("Spanish").tag("es")
                                    Text("French").tag("fr")
                                    Text("German").tag("de")
                                    Text("Auto").tag("auto")
                                }
                                .frame(width: 180)
                            }
                        }
                    }

                    // MARK: Transcription
                    SettingsSection(title: "Transcription", icon: "text.bubble") {
                        // Engine status
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("WhisperKit")
                            Spacer()
                            Text("Core ML")
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Image(systemName: transcriptionManager.isFfmpegAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(transcriptionManager.isFfmpegAvailable ? .green : .red)
                            Text("FFmpeg")
                            Spacer()
                            Text(transcriptionManager.isFfmpegAvailable ? "Available" : "Not Found")
                                .foregroundColor(.secondary)
                        }

                        if !transcriptionManager.areBinariesAvailable {
                            Text("FFmpeg is required for audio extraction. Bundle it in the app's Resources folder.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Divider()
                            .padding(.vertical, 2)

                        HStack {
                            Text("Default Model")
                            Spacer()
                            Picker("", selection: $settings.defaultWhisperModel) {
                                ForEach(WhisperModel.allCases) { model in
                                    Text(model.displayName).tag(model)
                                }
                            }
                            .frame(width: 180)
                        }

                        HStack {
                            Text("Output Format")
                            Spacer()
                            Picker("", selection: $settings.transcriptionOutputFormat) {
                                ForEach(TranscriptionOutputFormat.allCases, id: \.self) { format in
                                    Text(format.displayName).tag(format)
                                }
                            }
                            .frame(width: 180)
                        }

                        Toggle(isOn: $settings.enableSpeakerDiarization) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Speaker Diarization")
                                Text("Identify different speakers in transcriptions (uses Pyannote AI model)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Divider()
                            .padding(.vertical, 2)

                        // Model downloads
                        VStack(spacing: 0) {
                            ForEach(WhisperModel.allCases) { model in
                                ModelRow(model: model)
                            }
                        }

                        Divider()
                            .padding(.vertical, 4)

                        HStack {
                            Text("Storage Used")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(transcriptionManager.formatBytes(transcriptionManager.totalStorageUsed()))
                                .foregroundColor(.secondary)
                                .fontWeight(.medium)
                        }
                    }

                    // MARK: Appearance
                    SettingsSection(title: "Appearance", icon: "paintbrush") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Theme")
                            Picker("", selection: $settings.appearanceMode) {
                                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: .infinity)
                        }
                    }

                    // MARK: YouTube Account
                    SettingsSection(title: "YouTube Account", icon: "person.crop.circle") {
                        youtubeAuthContent
                    }

                    // MARK: Behavior
                    SettingsSection(title: "Behavior", icon: "gearshape") {
                        Toggle("Play sound when download completes", isOn: $settings.playSoundOnComplete)
                        Toggle("Show notifications", isOn: $settings.showNotifications)
                    }

                    // MARK: Keyboard Shortcuts
                    SettingsSection(title: "Keyboard Shortcuts", icon: "keyboard") {
                        ShortcutRow(keys: "⌘V", description: "Paste URL and fetch")
                        ShortcutRow(keys: "⌘D", description: "Start download")
                        ShortcutRow(keys: "⌘M", description: "Download as MP3")
                        ShortcutRow(keys: "⌘,", description: "Open settings")
                    }

                    // MARK: About
                    SettingsSection(title: "About", icon: "info.circle") {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Setup Guide")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text("Re-run the first-launch walkthrough")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Re-run Guide") {
                                hasSeenOnboarding = false
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding()
            }
        }
        .onAppear {
            transcriptionManager.loadDownloadedModels()
        }
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
                        .buttonStyle(.bordered)
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
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                }

            case .signingIn:
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Waiting for sign-in...")
                            .fontWeight(.medium)
                        Spacer()
                        Button("Cancel") {
                            downloader.cancelSignIn()
                        }
                        .buttonStyle(.bordered)
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
                        .background(Color.primary.opacity(0.05))
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
                    .buttonStyle(.bordered)
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
                    .buttonStyle(.borderedProminent)
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
                        Button(settings.cookiesFilePath.isEmpty ? "Select..." : "Change...") {
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
                        .frame(width: 120)
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
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
        }
    }
}

// MARK: - Shortcut Row

struct ShortcutRow: View {
    let keys: String
    let description: String

    var body: some View {
        HStack {
            Text(keys)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.tertiaryLabelColor).opacity(0.2))
                .cornerRadius(4)
            Text(description)
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}

#Preview {
    SettingsView(downloader: YTDLPWrapper())
}
