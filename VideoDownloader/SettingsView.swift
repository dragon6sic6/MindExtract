import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var downloader: YTDLPWrapper
    @Environment(\.dismiss) var dismiss
    @State private var showingTranscriptionSettings = false
    @State private var showAdvancedAuth = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Download Settings
                    SettingsSection(title: "Download", icon: "arrow.down.circle") {
                        // Default Format
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

                        // Parallel Downloads
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

                        // Download Path
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
                    }

                    // YouTube Account
                    SettingsSection(title: "YouTube Account", icon: "person.crop.circle") {
                        youtubeAuthContent
                    }

                    // Subtitles
                    SettingsSection(title: "Subtitles", icon: "captions.bubble") {
                        Toggle("Download subtitles when available", isOn: $settings.downloadSubtitles)

                        if settings.downloadSubtitles {
                            HStack {
                                Text("Preferred Language")
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

                    // Appearance
                    SettingsSection(title: "Appearance", icon: "paintbrush") {
                        HStack {
                            Text("Theme")
                            Spacer()
                            Picker("", selection: $settings.appearanceMode) {
                                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .frame(width: 180)
                            .pickerStyle(.segmented)
                        }
                    }

                    // Transcription
                    SettingsSection(title: "Transcription", icon: "text.bubble") {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Whisper Models")
                                Text("Download models to transcribe video audio")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Manage Models...") {
                                showingTranscriptionSettings = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    // Behavior
                    SettingsSection(title: "Behavior", icon: "gearshape") {
                        Toggle("Play sound when download completes", isOn: $settings.playSoundOnComplete)
                        Toggle("Show notifications", isOn: $settings.showNotifications)
                    }

                    // Keyboard Shortcuts Info
                    SettingsSection(title: "Keyboard Shortcuts", icon: "keyboard") {
                        ShortcutRow(keys: "⌘V", description: "Paste URL and fetch")
                        ShortcutRow(keys: "⌘D", description: "Start download")
                        ShortcutRow(keys: "⌘M", description: "Download as MP3")
                        ShortcutRow(keys: "⌘,", description: "Open settings")
                    }
                }
                .padding()
            }
        }
        .frame(width: 500, height: 600)
        .sheet(isPresented: $showingTranscriptionSettings) {
            TranscriptionSettingsView()
        }
    }

    // MARK: - YouTube Auth Content

    @ViewBuilder
    private var youtubeAuthContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Status and main action
            switch downloader.youtubeSignInState {
            case .idle:
                if settings.youtubeSignedIn {
                    // Signed in
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
                    // Not signed in
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
                                    .foregroundColor(.accentColor)
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
                        .background(Color.accentColor.opacity(0.08))
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

            // Advanced fallback options
            Divider()

            DisclosureGroup("Advanced", isExpanded: $showAdvancedAuth) {
                VStack(alignment: .leading, spacing: 10) {
                    // Cookies file
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

                    // Browser cookies
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

struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
        }
    }
}

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
