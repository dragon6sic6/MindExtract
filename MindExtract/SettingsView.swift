import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Settings
//
// The same look as the notch: black, white, cards, one accent — white. Four
// tabs, each setting in exactly one place.

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, transcription, downloads, about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: return "General"
        case .transcription: return "Transcription"
        case .downloads: return "Downloads"
        case .about: return "About"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var downloader: YTDLPWrapper
    @ObservedObject var transcriptionManager = TranscriptionManager.shared
    /// Persisted so the notch can open a tab directly (e.g. YouTube sign-in).
    @AppStorage("settingsCategory") private var category: SettingsCategory = .general
    @State private var showResetConfirmation = false
    @State private var loginItemOn = LoginItem.isEnabled
    @State private var showCookiesFile = false
    @State private var showAcknowledgements = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch category {
                    case .general: generalTab
                    case .transcription: transcriptionTab
                    case .downloads: downloadsTab
                    case .about: aboutTab
                    }
                }
                .padding(.horizontal, NotchStyle.side)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 480, idealHeight: 660)
        .background(NotchStyle.surface)
        .foregroundStyle(NotchStyle.text)
        .preferredColorScheme(.dark)
        .tint(.white)
        .onAppear {
            if !SettingsCategory.allCases.map(\.rawValue).contains(UserDefaults.standard.string(forKey: "settingsCategory") ?? "") {
                category = .general
            }
        }
        .confirmationDialog("Reset all settings?", isPresented: $showResetConfirmation, titleVisibility: .visible) {
            Button("Reset Settings", role: .destructive) {
                settings.resetToDefaults()
                GlobalHotKey.shared.set(.standard)
                NotchController.shared.place()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every preference goes back to its default. Your transcripts and downloads are not touched.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.5))
                Text("Settings").font(.system(size: 20, weight: .semibold))
            }
            HStack(spacing: 4) {
                ForEach(SettingsCategory.allCases) { c in
                    TabChip(title: c.title, selected: category == c) { category = c }
                }
            }
        }
        .padding(.horizontal, NotchStyle.side)
        .padding(.top, 38)   // below the transparent title bar
        .padding(.bottom, 14)
    }

    // MARK: General

    @ViewBuilder private var generalTab: some View {
        SettingsSection("Notch") {
            SettingsRow("Open the notch", detail: "Works in any app. Hovering or clicking the notch always works too.") {
                HotKeyRecorder()
            }
            if NSScreen.screens.count > 1 {
                SettingsRow("Show on", detail: "Which screen the notch lives on.") {
                    MonoMenu(selection: Binding(
                        get: { settings.notchScreen },
                        set: { settings.notchScreen = $0; NotchController.shared.place() }),
                             options: [("notch", String(localized: "The screen with the notch")),
                                       ("main", String(localized: "The main screen"))])
                }
            }
            if LoginItem.needsApproval {
                SettingsRow("Open at login", detail: "Waiting for your approval in System Settings, under Login Items.") {
                    SmallButton("Open System Settings") { SMAppService.openSystemSettingsLoginItems() }
                }
            } else {
                SettingsRow("Open at login", detail: "Without a Dock icon, this keeps the notch there after a restart.") {
                    Toggle("", isOn: Binding(get: { loginItemOn }, set: { loginItemOn = $0; LoginItem.set($0) }))
                        .toggleStyle(MonoToggleStyle())
                }
            }
        }

        SettingsSection("When it's done") {
            SettingsRow("Copy the transcript automatically", detail: "Only if you haven't copied anything else in the meantime.") {
                Toggle("", isOn: $settings.autoCopyWhenDone).toggleStyle(MonoToggleStyle())
            }
            SettingsRow("Include timestamps", detail: "Puts [12:04] before each passage. Without them it reads like an article.") {
                Toggle("", isOn: $settings.copyWithTimestamps).toggleStyle(MonoToggleStyle())
            }
            SettingsRow("Notify me", detail: "When the notch is closed and a transcript or download is ready.") {
                Toggle("", isOn: $settings.notifyOnTranscriptionComplete).toggleStyle(MonoToggleStyle())
            }
        }
    }

    // MARK: Transcription

    @ViewBuilder private var transcriptionTab: some View {
        SettingsSection("Language and speakers",
                        footer: "Automatic recognizes the language by itself. You can pick another one in the notch before transcribing.") {
            SettingsRow("Spoken language") {
                MonoMenu(selection: $settings.defaultTranscriptionLanguage,
                         options: AppSettings.transcriptionLanguages.map { ($0.code, $0.name) })
            }
            SettingsRow("Tell speakers apart", detail: "Marks who said what when there's more than one voice.") {
                Toggle("", isOn: $settings.enableSpeakerDiarization).toggleStyle(MonoToggleStyle())
            }
        }

        SettingsSection("Speech recognition", footer: "Everything runs on your Mac. Nothing is uploaded.") {
            SettingsRow("NVIDIA Parakeet", detail: parakeetDetail) {
                ModelAction()
            }
            SettingsRow("Other languages",
                        detail: "Japanese, Chinese, Korean, Hindi and more use Apple's speech recognition, built into macOS.") {
                ValueLabel(text: "Apple")
            }
        }
    }

    private var parakeetDetail: LocalizedStringKey {
        if let error = transcriptionManager.modelDownloadError, !transcriptionManager.isDownloadingModel {
            return LocalizedStringKey(error)
        }
        if let size = transcriptionManager.modelSizeOnDisk {
            return "25 European languages, including English. \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) on this Mac."
        }
        return "25 European languages, including English. 630 MB, downloaded once."
    }

    // MARK: Downloads

    @ViewBuilder private var downloadsTab: some View {
        SettingsSection("Saving", footer: "Transcripts of links are saved in the same folder; a file's transcript is saved next to the file.") {
            SettingsRow("Save to") {
                HStack(spacing: 8) {
                    ValueLabel(text: (settings.downloadPath as NSString).abbreviatingWithTildeInPath)
                    SmallButton("Change…") { selectDownloadFolder() }
                }
            }
            SettingsRow("Video quality", detail: "Choose video or audio only in the notch.") {
                MonoMenu(selection: $settings.downloadQuality,
                         options: DownloadQuality.allCases.filter { $0 != .audioOnly }.map { ($0, $0.displayName) })
            }
            SettingsRow("Save subtitles when available") {
                Toggle("", isOn: $settings.downloadSubtitles).toggleStyle(MonoToggleStyle())
            }
            if settings.downloadSubtitles {
                SettingsRow("Subtitle language") {
                    MonoMenu(selection: $settings.subtitleLanguage,
                             options: AppSettings.transcriptionLanguages.filter { $0.code != "auto" }.map { ($0.code, $0.name) })
                }
            }
        }

        SettingsSection("Signing in",
                        footer: "Most videos download without signing in. If a site blocks one, for example an age-restricted or members-only video, borrow the sign-in from a browser where you're logged in.") {
            SettingsRow("Use the sign-in from",
                        detail: settings.cookieBrowser == .safari
                            ? "Safari needs Full Disk Access for MindExtract in System Settings."
                            : "A browser on this Mac.") {
                MonoMenu(selection: $settings.cookieBrowser,
                         options: CookieBrowser.allCases.map { ($0, $0.displayName) })
            }
            DisclosureRow(title: "Use a cookies file instead", isOpen: $showCookiesFile)
            if showCookiesFile || !settings.cookiesFilePath.isEmpty {
                SettingsRow("Cookies file", detail: settings.cookiesFilePath.isEmpty
                                ? "A cookies.txt exported from your browser."
                                : LocalizedStringKey(URL(fileURLWithPath: settings.cookiesFilePath).lastPathComponent)) {
                    HStack(spacing: 8) {
                        if !settings.cookiesFilePath.isEmpty { SmallButton("Remove") { settings.cookiesFilePath = "" } }
                        SmallButton(settings.cookiesFilePath.isEmpty ? "Choose…" : "Change…") { selectCookiesFile() }
                    }
                }
            }
        }
    }

    // MARK: About

    @ViewBuilder private var aboutTab: some View {
        SettingsSection(nil) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "MindExtract").font(.system(size: 15, weight: .semibold))
                    Text("Version \(appVersion)").font(NotchStyle.small).foregroundStyle(NotchStyle.secondary)
                }
                Spacer()
                SmallButton("Check for Updates…") { NotificationCenter.default.post(name: .checkForUpdates, object: nil) }
            }
            .padding(16)
        }

        SettingsSection("Your data", footer: "Download and transcribe only content you have the right to use.") {
            SettingsRow("Speech models and history", detail: "Stored on this Mac only.") {
                SmallButton("Show in Finder") {
                    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    NSWorkspace.shared.activateFileViewerSelecting([
                        support.appendingPathComponent("com.mindact.mindextract"),
                        support.appendingPathComponent("MindExtract")])
                }
            }
            SettingsRow("Introduction", detail: "The short tour the notch gives the first time.") {
                SmallButton("Show Again") {
                    NSApp.keyWindow?.close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Onboarding.start() }
                }
            }
            SettingsRow("Reset all settings", detail: "Transcripts and downloads are kept.") {
                SmallButton("Reset…") { showResetConfirmation = true }
            }
        }

        SettingsSection("Acknowledgements") {
            DisclosureRow(title: "Open-source software MindExtract builds on", isOpen: $showAcknowledgements)
            if showAcknowledgements {
                acknowledgement("NVIDIA Parakeet TDT 0.6B v3", "CC BY 4.0", "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3")
                acknowledgement("pyannote speaker-diarization-community-1", "CC BY 4.0", "https://huggingface.co/pyannote/speaker-diarization-community-1")
                acknowledgement("FluidAudio", "Apache 2.0", "https://github.com/FluidInference/FluidAudio")
                acknowledgement("yt-dlp", "Unlicense", "https://github.com/yt-dlp/yt-dlp")
                acknowledgement("FFmpeg", "LGPL 2.1+", "https://ffmpeg.org/legal.html")
                acknowledgement("Sparkle", "MIT", "https://github.com/sparkle-project/Sparkle")
            }
        }
    }

    private func acknowledgement(_ name: String, _ license: String, _ url: String) -> some View {
        SettingsRow(LocalizedStringKey(name)) {
            Link(destination: URL(string: url)!) {
                HStack(spacing: 4) {
                    Text(verbatim: license)
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                }
                .font(NotchStyle.small)
                .foregroundStyle(NotchStyle.secondary)
            }
        }
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(short) (\(build))"
    }

    // MARK: Actions

    private func selectCookiesFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .data]
        panel.title = String(localized: "Choose a cookies file")
        if panel.runModal() == .OK, let url = panel.url { settings.cookiesFilePath = url.path }
    }

    private func selectDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url { settings.downloadPath = url.path }
    }
}

// MARK: - Building blocks (same tokens as the notch)

struct TabChip: View {
    let title: LocalizedStringKey
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? NotchStyle.text : (hovering ? NotchStyle.text : NotchStyle.secondary))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: NotchStyle.radiusSmall, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.14) : (hovering ? Color.white.opacity(0.06) : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SettingsSection<Content: View>: View {
    let title: LocalizedStringKey?
    let footer: LocalizedStringKey?
    @ViewBuilder let content: () -> Content

    init(_ title: LocalizedStringKey?, footer: LocalizedStringKey? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NotchStyle.tertiary)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) {
                content()
            }
            .padding(.top, -1)   // hides the first row's divider
            .clipShape(RoundedRectangle(cornerRadius: NotchStyle.radiusLarge, style: .continuous))
            .background(RoundedRectangle(cornerRadius: NotchStyle.radiusLarge, style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: NotchStyle.radiusLarge, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
            if let footer {
                Text(footer)
                    .font(NotchStyle.small)
                    .foregroundStyle(NotchStyle.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

extension EnvironmentValues {
    /// The row a control sits in, so VoiceOver can name an unlabelled switch or menu.
    @Entry var settingsRowTitle: LocalizedStringKey? = nil
}

struct SettingsRow<Control: View>: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey?
    @ViewBuilder let control: () -> Control

    init(_ title: LocalizedStringKey, detail: LocalizedStringKey? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(NotchStyle.small)
                        .foregroundStyle(NotchStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
                .environment(\.settingsRowTitle, title)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 16)
        }
    }
}

/// Opens or closes a group of rows inside a card.
struct DisclosureRow: View {
    let title: LocalizedStringKey
    @Binding var isOpen: Bool

    var body: some View {
        Button { withAnimation(NotchStyle.snappy) { isOpen.toggle() } } label: {
            HStack {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(NotchStyle.secondary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NotchStyle.tertiary)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 16)
        }
    }
}

struct ValueLabel: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(NotchStyle.small)
            .foregroundStyle(NotchStyle.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// A 28 pt secondary button.
struct SmallButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    init(_ title: LocalizedStringKey, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) { Text(title) }
            .buttonStyle(NotchButtonStyle(kind: .secondary, height: 28))
            .font(.system(size: 12, weight: .semibold))
    }
}

/// A choice shown as its current value; opens a menu.
struct MonoMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @State private var hovering = false
    @Environment(\.settingsRowTitle) private var rowTitle

    var body: some View {
        Menu {
            Picker("", selection: $selection) {
                ForEach(options, id: \.0) { value, name in Text(verbatim: name).tag(value) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(verbatim: options.first { $0.0 == selection }?.1 ?? "")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchStyle.text)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.leading, 10)
        .padding(.trailing, 24)
        .frame(height: 28)
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(NotchStyle.tertiary)
                .padding(.trailing, 9)
                .allowsHitTesting(false)
        }
        .background(RoundedRectangle(cornerRadius: NotchStyle.radiusSmall, style: .continuous)
            .fill(hovering ? NotchStyle.fieldHover : NotchStyle.field))
        .onHover { hovering = $0 }
        .accessibilityLabel(rowTitle.map { Text($0) } ?? Text(verbatim: ""))
        .accessibilityValue(options.first { $0.0 == selection }?.1 ?? "")
    }
}

/// A black-and-white switch: a white track with a black knob when on.
struct MonoToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        MonoSwitch(configuration: configuration)
    }
}

private struct MonoSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.settingsRowTitle) private var rowTitle

    var body: some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? Color.white : Color.white.opacity(0.22))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(configuration.isOn ? 0 : 0.14)))
                Circle()
                    .fill(configuration.isOn ? Color.black : Color.white.opacity(0.9))
                    .padding(2)
            }
            .frame(width: 36, height: 20)
            .animation(NotchStyle.snappy, value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(rowTitle.map { Text($0) } ?? Text(verbatim: ""))
        .accessibilityValue(configuration.isOn ? String(localized: "On") : String(localized: "Off"))
    }
}

/// Download, progress with Cancel, or ready with Delete: the one control for
/// the speech model, in Settings and in the introduction.
struct ModelAction: View {
    @ObservedObject private var tm = TranscriptionManager.shared
    @State private var confirmDelete = false

    var body: some View {
        if tm.isDownloadingModel {
            HStack(spacing: 8) {
                ProgressRing(progress: tm.modelDownloadProgress > 0 ? tm.modelDownloadProgress : nil).frame(width: 14, height: 14)
                if tm.modelDownloadProgress > 0 {
                    Text(tm.modelDownloadProgress, format: .percent.precision(.fractionLength(0)))
                        .font(NotchStyle.small).monospacedDigit().foregroundStyle(NotchStyle.secondary)
                }
                SmallButton("Cancel") { tm.cancelModelDownload() }
            }
        } else if tm.isModelInstalled {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).accessibilityLabel("Downloaded")
                Button { confirmDelete = true } label: {
                    Image(systemName: "trash").font(.system(size: 12, weight: .semibold)).foregroundStyle(NotchStyle.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete the speech model")
                .accessibilityLabel("Delete the speech model")
                .confirmationDialog("Delete the speech model?", isPresented: $confirmDelete) {
                    Button("Delete", role: .destructive) { tm.deleteModel() }
                } message: {
                    Text("Transcribing needs it, so it will download again next time. Your transcripts aren't affected.")
                }
            }
        } else {
            SmallButton(tm.modelDownloadError == nil ? "Download" : "Try Again") { tm.downloadModel() }
        }
    }
}

// MARK: - Shortcut recorder

struct HotKeyRecorder: View {
    @ObservedObject private var hotKey = GlobalHotKey.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(hint ?? (recording ? String(localized: "Press the shortcut…") : (hotKey.combo?.display ?? String(localized: "Off"))))
                    .monospacedDigit()
                    .frame(minWidth: 96)
            }
            .buttonStyle(NotchButtonStyle(kind: recording ? .done : .secondary, height: 28))
            .font(.system(size: 12, weight: .semibold))
            .accessibilityLabel(String(localized: "Shortcut"))
            .accessibilityValue(hotKey.combo?.display ?? String(localized: "Off"))
            .accessibilityHint(String(localized: "Press to record a new shortcut."))
            if !recording, hotKey.combo != .standard {
                SmallButton("Reset") { hotKey.set(.standard) }
            }
            if !recording, hotKey.combo != nil {
                SmallButton("Turn Off") { hotKey.set(nil) }
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }               // Esc cancels
            if let combo = GlobalHotKey.combo(from: event) {
                if hotKey.set(combo) {
                    stop()
                } else {
                    show(String(localized: "Taken by another app"))
                }
            } else {
                show(String(localized: "Use ⌃, or ⌘ with ⌥"))
            }
            return nil
        }
    }

    private func show(_ text: String) {
        NSSound.beep()
        hint = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if hint == text { hint = nil } }
    }

    private func stop() {
        hint = nil
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
