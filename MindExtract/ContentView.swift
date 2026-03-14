import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sidebar Navigation

enum SidebarItem: String, Hashable {
    case download = "Download"
    case transcribe = "Transcribe"
    case history = "History"
    case settings = "Settings"
}

// MARK: - Drop Zone View

struct DropZoneView: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isDragging: Bool
    let dropTypes: [UTType]
    let onDrop: ([NSItemProvider]) -> Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    isDragging ? Color.primary.opacity(0.5) : Color.secondary.opacity(0.22),
                    style: StrokeStyle(lineWidth: isDragging ? 2 : 1.5, dash: [9, 5])
                )
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(isDragging ? Color.primary.opacity(0.04) : Color.clear)
                )

            VStack(spacing: 10) {
                Image(systemName: isDragging ? "arrow.down" : icon)
                    .font(.system(size: 24))
                    .foregroundColor(isDragging ? .primary : .secondary.opacity(0.45))
                    .scaleEffect(isDragging ? 1.15 : 1.0)
                    .animation(.spring(response: 0.25), value: isDragging)

                VStack(spacing: 3) {
                    Text(isDragging ? "Drop here" : title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(isDragging ? .primary : .secondary)

                    if !isDragging {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 112)
        .animation(.easeInOut(duration: 0.15), value: isDragging)
        .onDrop(of: dropTypes, isTargeted: $isDragging, perform: onDrop)
    }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var downloader = YTDLPWrapper()
    @StateObject private var settings = AppSettings.shared
    @StateObject private var historyManager = HistoryManager.shared
    @StateObject private var transcriptionManager = TranscriptionManager.shared

    // Navigation
    @State private var selectedSidebarItem: SidebarItem? = .download

    // Download state
    @State private var urlInput: String = ""
    @State private var selectedFormat: VideoFormat?
    @State private var selectedVideos: Set<String> = []
    @State private var showingLog = false
    @State private var appMode: AppMode = .singleVideo
    @State private var isDraggingOverDownload = false

    // Transcribe state
    @State private var isDraggingOverTranscribe = false
    @State private var selectedLocalFiles: [LocalFileInfo] = []
    @State private var showTranscriptionLanguagePicker = false
    @State private var selectedTranscriptionLanguage = "auto"
    @State private var pendingTranscriptionFile: LocalFileInfo? = nil
    @State private var pendingTranscriptionFilePath: String? = nil
    @State private var transcribeAppMode: AppMode = .singleVideo  // for transcribe section

    // Modals
    @State private var showHistory = false

    private var detectedPlatform: Platform {
        Platform.detect(from: urlInput)
    }

    var body: some View {
        NavigationSplitView {
            sidebarView
                .navigationSplitViewColumnWidth(min: 160, ideal: 185, max: 210)
        } detail: {
            detailView
        }
        .frame(minWidth: 740, minHeight: 560)
        .onAppear { checkPendingURL() }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            selectedSidebarItem = .settings
        }
        .sheet(isPresented: $showHistory) {
            HistoryView { item in
                urlInput = item.url
                selectedSidebarItem = .download
                appMode = .singleVideo
                performAction()
            }
        }
        .onChange(of: transcriptionManager.showTranscriptionView) { show in
            if show {
                TranscriptionWindowController.shared.showWindow(manager: transcriptionManager)
            } else {
                TranscriptionWindowController.shared.close()
            }
        }
        // Bridge downloader progress to transcription window when downloading audio for transcription
        .onChange(of: downloader.state) { newState in
            if case .downloadingAudio = transcriptionManager.transcriptionState {
                if case .downloading(let progress, _) = newState {
                    transcriptionManager.transcriptionState = .downloadingAudio(progress: progress)
                }
            }
        }
        .sheet(isPresented: $showTranscriptionLanguagePicker) {
            TranscriptionLanguagePickerSheet(
                selectedLanguage: $selectedTranscriptionLanguage,
                onStart: {
                    showTranscriptionLanguagePicker = false
                    if let file = pendingTranscriptionFile {
                        transcribeLocalFile(file)
                    } else if let filePath = pendingTranscriptionFilePath {
                        startTranscription(filePath: filePath)
                    } else {
                        transcribeFromURL()
                    }
                    pendingTranscriptionFile = nil
                    pendingTranscriptionFilePath = nil
                },
                onCancel: {
                    showTranscriptionLanguagePicker = false
                    pendingTranscriptionFile = nil
                    pendingTranscriptionFilePath = nil
                }
            )
        }
    }

    // MARK: - Sidebar

    private var sidebarView: some View {
        VStack(spacing: 0) {
            // App logo
            HStack(spacing: 10) {
                Image(systemName: "waveform.and.magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                Text("MindExtract")
                    .font(.system(size: 14, weight: .bold))
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // Primary navigation
            VStack(spacing: 4) {
                sidebarNavItem(item: .download, icon: "arrow.down.circle", label: "Download")
                sidebarNavItem(item: .transcribe, icon: "text.bubble", label: "Transcribe")
            }
            .padding(.top, 12)
            .padding(.horizontal, 10)

            Spacer()

            Divider()

            // Secondary navigation
            VStack(spacing: 4) {
                sidebarNavItem(item: .history, icon: "clock", label: "History")
                sidebarNavItem(item: .settings, icon: "gearshape", label: "Settings")
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 10)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private func sidebarNavItem(item: SidebarItem, icon: String, label: String) -> some View {
        Button(action: { selectedSidebarItem = item }) {
            sidebarNavRow(icon: icon, label: label, isSelected: selectedSidebarItem == item)
        }
        .buttonStyle(.plain)
    }

    private func sidebarNavRow(icon: String, label: String, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .primary : Color(NSColor.tertiaryLabelColor))
                .frame(width: 22)
            Text(label)
                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .primary : Color(NSColor.secondaryLabelColor))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isSelected ? Color.primary.opacity(0.08) : Color.clear)
        .cornerRadius(9)
        .contentShape(Rectangle())
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        switch selectedSidebarItem ?? .download {
        case .download:
            downloadDetailView
        case .transcribe:
            transcribeDetailView
        case .history:
            historyDetailView
        case .settings:
            SettingsView(downloader: downloader)
        }
    }

    // MARK: - Download Detail

    private var downloadDetailView: some View {
        VStack(spacing: 0) {
            // Section header
            HStack(spacing: 12) {
                Text("Download")
                    .font(.title2)
                    .fontWeight(.bold)

                if downloader.videoInfo != nil || !downloader.scannedVideos.isEmpty {
                    Button(action: clearAll) {
                        Image(systemName: "xmark.circle")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }

                Spacer()

                // Mode picker (Video / Scan Page)
                Picker("", selection: Binding(
                    get: { appMode == .pageScan ? AppMode.pageScan : AppMode.singleVideo },
                    set: { newMode in
                        appMode = newMode
                        downloader.reset()
                        selectedFormat = nil
                        selectedVideos = []
                    }
                )) {
                    Text("Video").tag(AppMode.singleVideo)
                    Text("Scan Page").tag(AppMode.pageScan)
                }
                .pickerStyle(.segmented)
                .frame(width: 164)
                .labelsHidden()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // yt-dlp warning banner
            if !downloader.isYTDLPInstalled {
                ytdlpWarningBanner
            }

            ScrollView {
                VStack(spacing: 16) {
                    // Drop zone (shown when no content loaded)
                    if downloader.videoInfo == nil &&
                       downloader.scannedVideos.isEmpty &&
                       !(downloader.state == .fetchingFormats) &&
                       !(downloader.state == .scanningPage) {
                        VStack(spacing: 12) {
                            urlInputField
                                .padding(.horizontal, 20)
                                .padding(.top, 20)

                            HStack(spacing: 8) {
                                Rectangle()
                                    .frame(height: 1)
                                    .foregroundColor(Color.secondary.opacity(0.18))
                                Text("or")
                                    .font(.caption)
                                    .foregroundColor(.secondary.opacity(0.6))
                                Rectangle()
                                    .frame(height: 1)
                                    .foregroundColor(Color.secondary.opacity(0.18))
                            }
                            .padding(.horizontal, 28)

                            DropZoneView(
                                icon: "link.badge.plus",
                                title: "Drag & drop a URL here",
                                subtitle: "drag & drop from your browser",
                                isDragging: $isDraggingOverDownload,
                                dropTypes: [.url, .text, .fileURL],
                                onDrop: { providers in
                                    handleDrop(providers: providers)
                                    return true
                                }
                            )
                            .padding(.horizontal, 20)

                            Text("Supports: YouTube, Vimeo, Twitter/X, TikTok, and 1000+ sites")
                                .font(.caption2)
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                    } else if case .fetchingFormats = downloader.state {
                        VStack(spacing: 12) {
                            urlInputField.padding(.horizontal, 20).padding(.top, 20)
                            ProgressView("Fetching video info...")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(40)
                        }
                    } else if case .scanningPage = downloader.state {
                        VStack(spacing: 12) {
                            urlInputField.padding(.horizontal, 20).padding(.top, 20)
                            ProgressView("Scanning page for videos...")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(40)
                        }
                    } else if appMode == .singleVideo, let info = downloader.videoInfo {
                        videoAndFormatsSection(info: info)
                    } else if appMode == .pageScan, !downloader.scannedVideos.isEmpty {
                        scannedVideosSection
                    }

                    // Inline Queue Panel — always visible when items are queued
                    if !downloader.downloadQueue.isEmpty {
                        inlineQueueSection
                            .padding(.horizontal, 20)
                    }

                    // Bottom section
                    VStack(spacing: 12) {
                        if appMode == .singleVideo && downloader.videoInfo != nil {
                            downloadLocationSection
                            actionButtonsSection
                        } else if appMode == .pageScan && !selectedVideos.isEmpty {
                            downloadLocationSection
                            actionButtonsSection
                        }
                        statusSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
            }

            // Log section
            if !downloader.outputLog.isEmpty {
                logSection
            }
        }
    }

    // MARK: - URL Input Field (shared)

    private var urlInputField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: detectedPlatform.icon)
                    .foregroundColor(.secondary)
                    .frame(width: 16)

                TextField(
                    appMode == .singleVideo
                        ? "Paste a YouTube, Vimeo, TikTok or other URL…"
                        : "https://youtube.com/playlist?list=...",
                    text: $urlInput
                )
                .textFieldStyle(.plain)
                .font(.body)
                .onSubmit { performAction() }

                if !urlInput.isEmpty {
                    Button(action: clearAll) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: pasteFromClipboard) {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Paste (⌘V)")
            }
            .padding(14)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 4, y: 2)

            Button(action: performAction) {
                if case .fetchingFormats = downloader.state {
                    ProgressView().scaleEffect(0.7).frame(width: 70)
                } else if case .scanningPage = downloader.state {
                    ProgressView().scaleEffect(0.7).frame(width: 70)
                } else {
                    Text(appMode == .singleVideo ? "Fetch" : "Scan")
                        .frame(width: 70)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(urlInput.isEmpty ||
                      downloader.state == .fetchingFormats ||
                      downloader.state == .scanningPage)
        }
    }

    // MARK: - Transcribe Detail

    private var transcribeDetailView: some View {
        VStack(spacing: 0) {
            // Section header
            HStack(spacing: 12) {
                Text("Transcribe")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                // Mode picker (URL / Local File)
                Picker("", selection: Binding(
                    get: { transcribeAppMode == .localFile ? AppMode.localFile : AppMode.singleVideo },
                    set: { newMode in
                        transcribeAppMode = newMode
                        if newMode == .singleVideo { downloader.reset() }
                        selectedLocalFiles = []
                        transcriptionManager.resetState()
                    }
                )) {
                    Text("From URL").tag(AppMode.singleVideo)
                    Text("Local File").tag(AppMode.localFile)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .labelsHidden()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    if transcribeAppMode == .localFile {
                        // ── Local File mode ──
                        if selectedLocalFiles.isEmpty {
                            VStack(spacing: 12) {
                                DropZoneView(
                                    icon: "doc.badge.plus",
                                    title: "Drop media files here",
                                    subtitle: "drag & drop  ·  or browse below",
                                    isDragging: $isDraggingOverTranscribe,
                                    dropTypes: [.fileURL, .movie, .video, .audio],
                                    onDrop: { providers in
                                        handleDropForTranscription(providers: providers)
                                        return true
                                    }
                                )
                                .padding(.horizontal, 20)
                                .padding(.top, 20)

                                Button(action: selectLocalFiles) {
                                    Label("Browse Files...", systemImage: "folder")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                                .padding(.horizontal, 20)
                            }
                        } else {
                            localFileListSection
                        }

                        // Status / model prompt
                        VStack(spacing: 8) {
                            localFileTranscriptionStatus
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)

                    } else {
                        // ── URL mode — paste URL, press Transcribe ──
                        VStack(spacing: 12) {
                            transcribeURLInputField
                                .padding(.horizontal, 20)
                                .padding(.top, 20)

                            HStack(spacing: 8) {
                                Rectangle()
                                    .frame(height: 1)
                                    .foregroundColor(Color.secondary.opacity(0.18))
                                Text("or")
                                    .font(.caption)
                                    .foregroundColor(.secondary.opacity(0.6))
                                Rectangle()
                                    .frame(height: 1)
                                    .foregroundColor(Color.secondary.opacity(0.18))
                            }
                            .padding(.horizontal, 28)

                            DropZoneView(
                                icon: "link.badge.plus",
                                title: "Drag & drop a video URL here",
                                subtitle: "drag & drop from your browser",
                                isDragging: $isDraggingOverTranscribe,
                                dropTypes: [.url, .text],
                                onDrop: { providers in
                                    handleDropForTranscribeURL(providers: providers)
                                    return true
                                }
                            )
                            .padding(.horizontal, 20)

                            Text("Supports: YouTube, Vimeo, Twitter/X, TikTok, and 1000+ sites")
                                .font(.caption2)
                                .foregroundColor(.secondary.opacity(0.6))
                        }

                        // Transcription status (progress, errors, completed)
                        VStack(spacing: 12) {
                            transcriptionStatusView
                                .padding(.top, 4)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                    }
                }
            }
        }
    }

    // URL input for transcribe section — no Fetch needed, go straight to Transcribe
    private var transcribeURLInputField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: detectedPlatform.icon)
                    .foregroundColor(.secondary)
                    .frame(width: 16)

                TextField("Paste a YouTube, Vimeo, TikTok or other URL…", text: $urlInput)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .onSubmit { triggerTranscribeFromURL() }

                if !urlInput.isEmpty {
                    Button(action: { urlInput = ""; transcriptionManager.resetState() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: {
                    if let str = NSPasteboard.general.string(forType: .string) {
                        urlInput = str.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }) {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Paste (⌘V)")
            }
            .padding(14)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 4, y: 2)

            Button(action: triggerTranscribeFromURL) {
                if isTranscribing {
                    ProgressView().scaleEffect(0.7).frame(width: 90)
                } else {
                    Text("Transcribe").frame(width: 90)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(urlInput.isEmpty || isTranscribing)
        }
    }

    private var transcribeURLButton: some View {
        Group {
            if transcriptionManager.areBinariesAvailable {
                Button(action: {
                    if transcriptionManager.downloadedModels.isEmpty {
                        transcriptionManager.transcriptionState = .modelNotDownloaded
                    } else {
                        pendingTranscriptionFile = nil
                        pendingTranscriptionFilePath = nil
                        showTranscriptionLanguagePicker = true
                    }
                }) {
                    HStack {
                        Image(systemName: "text.bubble.fill")
                        Text(isTranscribing ? "Transcribing..." : "Transcribe with WhisperKit")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.large)
                .disabled(isTranscribing)
            }
        }
    }

    // MARK: - History Detail

    private var historyDetailView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            RecentActivityView(onRedownload: { item in
                urlInput = item.url
                selectedSidebarItem = .download
                appMode = .singleVideo
                performAction()
            })
        }
    }

    // MARK: - yt-dlp Warning Banner

    private var ytdlpWarningBanner: some View {
        Group {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                (Text("yt-dlp not found — downloading is unavailable. Run ")
                    .font(.footnote)
                + Text("setup_binaries.sh")
                    .font(.system(.footnote, design: .monospaced))
                + Text(" to install it.")
                    .font(.footnote))
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))

            Divider()
        }
    }

    // MARK: - Local File Content (reused in transcribe section)

    private var localFileListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(selectedLocalFiles.count) File\(selectedLocalFiles.count == 1 ? "" : "s") Selected")
                    .font(.headline)
                Spacer()

                Button(action: selectLocalFiles) {
                    Label("Add More", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: { selectedLocalFiles.removeAll() }) {
                    Label("Clear", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(selectedLocalFiles) { file in
                        LocalFileRow(
                            file: file,
                            transcriptionState: transcriptionManager.transcriptionState,
                            onRemove: { selectedLocalFiles.removeAll { $0.id == file.id } },
                            onTranscribe: {
                                pendingTranscriptionFile = file
                                pendingTranscriptionFilePath = nil
                                showTranscriptionLanguagePicker = true
                            }
                        )
                    }
                }
                .padding(.horizontal, 20)
            }
            .frame(height: 250)
        }
    }

    private func selectLocalFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            UTType.movie, UTType.video, UTType.mpeg4Movie, UTType.quickTimeMovie, UTType.avi,
            UTType(filenameExtension: "mkv") ?? UTType.movie,
            UTType(filenameExtension: "webm") ?? UTType.movie,
            UTType.mp3, UTType.audio, UTType.wav
        ].compactMap { $0 }
        panel.prompt = "Select Video Files"

        if panel.runModal() == .OK {
            let newFiles = panel.urls.map { LocalFileInfo(url: $0) }
            for file in newFiles {
                if !selectedLocalFiles.contains(where: { $0.url == file.url }) {
                    selectedLocalFiles.append(file)
                }
            }
        }
    }

    private func transcribeLocalFile(_ file: LocalFileInfo) {
        if transcriptionManager.downloadedModels.isEmpty {
            transcriptionManager.transcriptionState = .modelNotDownloaded
            return
        }
        let model = settings.defaultWhisperModel
        let modelToUse = transcriptionManager.isModelDownloaded(model) ? model : transcriptionManager.downloadedModels.first!
        transcriptionManager.startNewTranscription(title: file.name, model: modelToUse)
        transcriptionManager.transcribe(
            videoPath: file.url.path,
            model: modelToUse,
            outputFormat: settings.transcriptionOutputFormat,
            language: selectedTranscriptionLanguage
        )
    }

    // MARK: - Inline Queue Panel

    private var inlineQueueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Queue · \(downloader.downloadQueue.count) video\(downloader.downloadQueue.count == 1 ? "" : "s")", systemImage: "list.bullet")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                Spacer()
                Button(action: { downloader.clearQueue() }) {
                    Text("Clear").font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if !downloader.isProcessingQueue {
                    Button(action: { downloader.startQueue(outputPath: settings.downloadPath) }) {
                        Label("Download All", systemImage: "arrow.down.circle.fill").font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            LazyVStack(spacing: 6) {
                ForEach(downloader.downloadQueue) { item in
                    QueueItemRow(
                        item: item,
                        onRemove: { downloader.removeFromQueue(id: item.id) }
                    )
                }
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    // MARK: - Video and Formats Section

    private func videoAndFormatsSection(info: VideoInfo) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                AsyncImage(url: URL(string: info.thumbnail ?? "")) { phase in
                    switch phase {
                    case .empty:
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.2))
                            .overlay(ProgressView().scaleEffect(0.7))
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill).clipped()
                    case .failure:
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.2))
                            .overlay(Image(systemName: "play.fill").font(.title).foregroundColor(.secondary))
                    @unknown default:
                        RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.2))
                    }
                }
                .frame(width: 180, height: 100)
                .cornerRadius(8)

                VStack(alignment: .leading, spacing: 6) {
                    Text(info.title).font(.headline).lineLimit(2)
                    HStack {
                        Label(info.uploader, systemImage: "person.fill")
                        Spacer()
                        Label(info.duration, systemImage: "clock.fill")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    Text("\(info.formats.count) formats available")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Add to Queue — visible right in the card so it's easy to find
                Button(action: addVideoToQueue) {
                    VStack(spacing: 4) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 20))
                        Text("Queue")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                    .frame(width: 48)
                }
                .buttonStyle(.plain)
                .help("Add to queue and load another video")
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
            .padding(.horizontal, 20)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Select Format").font(.headline)
                    Spacer()
                    HStack(spacing: 6) {
                        QuickFormatButton(title: "Best", icon: "star.fill", isSelected: isFormatSelected(type: .best)) {
                            selectedFormat = info.formats.first { !$0.isAudioOnly }
                        }
                        QuickFormatButton(title: "Audio", icon: "music.note", isSelected: isFormatSelected(type: .audio)) {
                            selectedFormat = info.formats.first { $0.isAudioOnly }
                        }
                        QuickFormatButton(title: settings.preferredResolution, icon: "tv", isSelected: isFormatSelected(type: .preferredRes)) {
                            selectedFormat = info.formats.first { $0.resolution == settings.preferredResolution && !$0.isVideoOnly }
                                ?? info.formats.first { $0.resolution == settings.preferredResolution }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(info.formats) { format in
                            FormatRow(format: format, isSelected: selectedFormat == format)
                                .onTapGesture { selectedFormat = format }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .frame(height: 180)
            }
        }
    }

    // MARK: - Scanned Videos Section

    private var scannedVideosSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Found \(downloader.scannedVideos.count) Videos").font(.headline)
                Spacer()
                Button(action: selectAllVideos) {
                    Text(selectedVideos.count == downloader.scannedVideos.count ? "Deselect All" : "Select All")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(downloader.scannedVideos) { video in
                        VideoRow(
                            video: video,
                            isSelected: selectedVideos.contains(video.id),
                            onToggle: { toggleVideoSelection(video) },
                            onDownload: { downloadSingleVideo(video) }
                        )
                    }
                }
                .padding(.horizontal, 20)
            }
            .frame(height: 250)
        }
    }

    // MARK: - Download Location

    private var downloadLocationSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder").foregroundColor(.secondary)
            Text(settings.downloadPath)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Change...") { selectDownloadFolder() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Action Buttons

    private var actionButtonsSection: some View {
        VStack(spacing: 16) {
            if appMode == .singleVideo && downloader.videoInfo != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Actions")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    HStack(spacing: 10) {
                        Button(action: startDownload) {
                            HStack {
                                Image(systemName: "arrow.down.circle.fill")
                                Text(isDownloading ? "Downloading..." : "Download Video")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!canDownload || isTranscribing)

                        Button(action: downloadAsAudio) {
                            HStack {
                                Image(systemName: "music.note")
                                Text("Download Audio")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(isDownloading || isTranscribing)

                        if transcriptionManager.areBinariesAvailable {
                            Button(action: {
                                if transcriptionManager.downloadedModels.isEmpty {
                                    transcriptionManager.transcriptionState = .modelNotDownloaded
                                } else {
                                    pendingTranscriptionFile = nil
                                    pendingTranscriptionFilePath = nil
                                    showTranscriptionLanguagePicker = true
                                }
                            }) {
                                HStack {
                                    Image(systemName: "text.bubble")
                                    Text("Transcribe")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                            .controlSize(.large)
                            .disabled(isDownloading || isTranscribing)
                        }

                        if isDownloading {
                            Button(action: { downloader.cancelDownload() }) {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .controlSize(.large)
                        }
                    }
                }
            } else if appMode == .pageScan && !selectedVideos.isEmpty {
                HStack(spacing: 10) {
                    Button(action: startDownload) {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Download \(selectedVideos.count) Video\(selectedVideos.count == 1 ? "" : "s")")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isDownloading)

                    if isDownloading {
                        Button(action: { downloader.cancelDownload() }) {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .controlSize(.large)
                    }
                }
            }

        }
    }

    private var isDownloading: Bool {
        if case .downloading = downloader.state { return true }
        return false
    }

    private var isTranscribing: Bool {
        switch transcriptionManager.transcriptionState {
        case .extractingAudio, .transcribing, .loadingModel: return true
        default: return false
        }
    }

    // Trigger the transcribe-from-URL flow directly (no Fetch step)
    private func triggerTranscribeFromURL() {
        guard !urlInput.isEmpty else { return }
        if transcriptionManager.downloadedModels.isEmpty {
            transcriptionManager.transcriptionState = .modelNotDownloaded
            return
        }
        pendingTranscriptionFile = nil
        pendingTranscriptionFilePath = nil
        showTranscriptionLanguagePicker = true
    }

    // Drop handler for the URL transcribe zone — sets URL and triggers transcription
    private func handleDropForTranscribeURL(providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url = url, !url.isFileURL else { return }
                    DispatchQueue.main.async {
                        self.urlInput = url.absoluteString
                        self.triggerTranscribeFromURL()
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    if let text = text {
                        DispatchQueue.main.async {
                            self.urlInput = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            self.triggerTranscribeFromURL()
                        }
                    }
                }
            }
        }
    }

    private func transcribeFromURL() {
        if transcriptionManager.downloadedModels.isEmpty {
            transcriptionManager.transcriptionState = .modelNotDownloaded
            return
        }
        let model = settings.defaultWhisperModel
        let modelToUse = transcriptionManager.isModelDownloaded(model) ? model : transcriptionManager.downloadedModels.first!
        let title = downloader.videoInfo?.title ?? "Video Transcription"
        transcriptionManager.startNewTranscription(title: title, model: modelToUse)
        transcriptionManager.transcriptionState = .downloadingAudio(progress: 0)

        downloader.downloadAudioForTranscription(url: urlInput) { [self] audioPath, error in
            if let error = error {
                transcriptionManager.transcriptionState = .error("Failed to download audio: \(error)")
                return
            }
            guard let audioPath = audioPath else {
                transcriptionManager.transcriptionState = .error("No audio file received")
                return
            }
            let outputFileName: String
            if let info = downloader.videoInfo {
                let sanitizedTitle = info.title
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                    .prefix(80)
                outputFileName = String(sanitizedTitle)
            } else {
                outputFileName = "transcription_\(UUID().uuidString.prefix(8))"
            }
            let outputPath = settings.downloadPath + "/" + outputFileName + "." + settings.transcriptionOutputFormat.rawValue
            transcriptionManager.transcribeAudioFile(
                audioPath: audioPath,
                model: modelToUse,
                outputPath: outputPath,
                outputFormat: settings.transcriptionOutputFormat,
                language: self.selectedTranscriptionLanguage
            )
        }
    }

    private var canDownload: Bool {
        if case .downloading = downloader.state { return false }
        if appMode == .singleVideo {
            return selectedFormat != nil && !urlInput.isEmpty
        } else {
            return !selectedVideos.isEmpty
        }
    }

    private func downloadAsAudio() {
        guard downloader.videoInfo != nil else { return }
        downloader.downloadAudio(url: urlInput, outputPath: settings.downloadPath)
    }

    private func addVideoToQueue() {
        if appMode == .singleVideo {
            downloader.addCurrentVideoToQueue(isAudioOnly: false)
        } else {
            let selectedVids = downloader.scannedVideos.filter { selectedVideos.contains($0.id) }
            downloader.addSelectedVideosToQueue(videos: selectedVids, isAudioOnly: false)
        }
        // Reset so user can immediately paste the next URL
        urlInput = ""
        downloader.reset()
        selectedFormat = nil
        selectedVideos = []
    }

    // MARK: - Status

    private var statusSection: some View {
        Group {
            switch downloader.state {
            case .idle, .fetchingFormats, .scanningPage:
                EmptyView()

            case .downloading(let progress, let speed):
                VStack(spacing: 8) {
                    ProgressView(value: progress).progressViewStyle(.linear)
                    HStack {
                        Text("\(Int(progress * 100))%").font(.headline)
                        Spacer()
                        Text(speed).foregroundColor(.secondary)
                    }
                    .font(.caption)
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)

            case .completed:
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        Text("Download completed!").fontWeight(.medium)
                        Spacer()
                        Button("Open Folder") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: settings.downloadPath))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if transcriptionManager.areBinariesAvailable,
                           let filePath = downloader.lastDownloadedFilePath {
                            Button(action: {
                                if transcriptionManager.downloadedModels.isEmpty {
                                    transcriptionManager.transcriptionState = .modelNotDownloaded
                                } else {
                                    pendingTranscriptionFile = nil
                                    pendingTranscriptionFilePath = filePath
                                    showTranscriptionLanguagePicker = true
                                }
                            }) {
                                Label("Transcribe", systemImage: "text.bubble")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.orange)
                        }
                    }
                    transcriptionStatusView
                }
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)

            case .error(let message):
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                    Text(message).foregroundColor(.red).lineLimit(2).font(.system(size: 12))
                    Spacer()
                    Button("Dismiss") { downloader.retry() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)

            case .timeout(let message):
                HStack {
                    Image(systemName: "clock.badge.exclamationmark.fill").foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Operation Timed Out").fontWeight(.medium).foregroundColor(.orange)
                        Text(message).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Try Again") {
                        downloader.retry()
                        performAction()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }
        }
    }

    // MARK: - Transcription Status

    @ViewBuilder
    private var transcriptionStatusView: some View {
        switch transcriptionManager.transcriptionState {
        case .idle:
            EmptyView()

        case .downloadingAudio(let progress):
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Downloading audio…").font(.system(size: 13)).fontWeight(.medium)
                    Spacer()
                    if progress > 0 {
                        Text("\(Int(progress * 100))%").font(.caption).foregroundColor(.secondary)
                    }
                }
                if progress > 0 {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.orange)
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.08))
            .cornerRadius(8)

        case .loadingModel:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Loading AI model…").font(.system(size: 13)).fontWeight(.medium)
                    Text("Preparing WhisperKit for transcription").font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(Color.blue.opacity(0.08))
            .cornerRadius(8)

        case .extractingAudio:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Extracting audio…").font(.system(size: 13)).fontWeight(.medium)
                    Text("Converting media to audio for transcription").font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(Color.blue.opacity(0.08))
            .cornerRadius(8)

        case .transcribing(let progress):
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Transcribing audio…").font(.system(size: 13)).fontWeight(.medium)
                    Spacer()
                    if progress > 0 {
                        Text("\(Int(progress * 100))%").font(.caption).foregroundColor(.secondary)
                    }
                    Button(action: { transcriptionManager.cancelTranscription() }) {
                        Image(systemName: "xmark.circle").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                ProgressView(value: max(progress, 0.02))
                    .progressViewStyle(.linear)
            }
            .padding(10)
            .background(Color.blue.opacity(0.08))
            .cornerRadius(8)

        case .completed(let outputPath):
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill").foregroundColor(.orange)
                Text("Transcription saved!").font(.system(size: 13)).fontWeight(.medium)
                Spacer()
                Button("Open") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: outputPath)])
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                Button("Dismiss") { transcriptionManager.resetState() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }

        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                Text(message).font(.system(size: 12)).foregroundColor(.red).lineLimit(2)
                Spacer()
                Button("Dismiss") { transcriptionManager.resetState() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }

        case .modelNotDownloaded:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "brain.head.profile")
                        .font(.title2)
                        .foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("AI Model Required")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text("Transcription uses WhisperKit, which runs locally on your Mac. Download a model once to start transcribing.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button(action: { selectedSidebarItem = .settings }) {
                    Label("Download a Model", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(14)
            .background(Color.blue.opacity(0.08))
            .cornerRadius(10)
        }
    }

    @ViewBuilder
    private var localFileTranscriptionStatus: some View {
        switch transcriptionManager.transcriptionState {
        case .idle:
            if !transcriptionManager.areBinariesAvailable {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("FFmpeg binary not found").font(.system(size: 12)).foregroundColor(.orange)
                    Spacer()
                    Button("Settings") { selectedSidebarItem = .settings }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            } else if transcriptionManager.downloadedModels.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "brain.head.profile")
                            .font(.title2)
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("AI Model Required")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text("Download a WhisperKit model to start transcribing locally on your Mac.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button(action: { selectedSidebarItem = .settings }) {
                        Label("Download a Model", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                .padding(14)
                .background(Color.blue.opacity(0.08))
                .cornerRadius(10)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("Ready to transcribe").font(.system(size: 13)).foregroundColor(.secondary)
                    Spacer()
                    Text("WhisperKit · \(settings.defaultWhisperModel.displayName)")
                        .font(.system(size: 13)).foregroundColor(.secondary)
                }
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            }

        case .downloadingAudio, .loadingModel, .extractingAudio, .transcribing:
            VStack(spacing: 8) { transcriptionStatusView }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)

        case .completed:
            VStack(spacing: 8) { transcriptionStatusView }
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)

        case .error, .modelNotDownloaded:
            VStack(spacing: 8) { transcriptionStatusView }
                .padding()
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
        }
    }

    private func startTranscription(filePath: String) {
        let model = settings.defaultWhisperModel
        // Clear previous result before starting so stale state isn't shown
        transcriptionManager.clearTranscription()
        if transcriptionManager.isModelDownloaded(model) {
            transcriptionManager.transcribe(
                videoPath: filePath,
                model: model,
                outputFormat: settings.transcriptionOutputFormat,
                language: selectedTranscriptionLanguage
            )
        } else {
            transcriptionManager.transcriptionState = .modelNotDownloaded
        }
    }

    // MARK: - Log Section

    private var logSection: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button(action: { showingLog.toggle() }) {
                    HStack {
                        Image(systemName: showingLog ? "chevron.down" : "chevron.right")
                        Text("Output Log").font(.caption)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                if showingLog && !downloader.outputLog.isEmpty {
                    Button(action: copyLogToClipboard) {
                        Label("Copy", systemImage: "doc.on.doc").font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Button(action: { downloader.outputLog = "" }) {
                        Label("Clear", systemImage: "trash").font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            if showingLog {
                ScrollView {
                    Text(downloader.outputLog)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
                .frame(height: 150)
                .background(Color(NSColor.textBackgroundColor))
            }
        }
    }

    private func copyLogToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(downloader.outputLog, forType: .string)
    }

    // MARK: - Helper Methods

    private func checkPendingURL() {
        if let pendingURL = UserDefaults.standard.string(forKey: "pendingURL"), !pendingURL.isEmpty {
            UserDefaults.standard.removeObject(forKey: "pendingURL")
            urlInput = pendingURL
            performAction()
        }
    }

    // MARK: - Drag and Drop

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url { self.handleDroppedURL(url) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url { self.handleDroppedURL(url) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    if let text = text {
                        DispatchQueue.main.async {
                            self.urlInput = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            self.performAction()
                        }
                    }
                }
            }
        }
    }

    private func handleDropForTranscription(providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url = url, url.isFileURL else { return }
                    let videoExtensions = ["mp4", "mkv", "webm", "avi", "mov", "m4v", "wmv", "flv", "mp3", "m4a", "wav", "flac"]
                    guard videoExtensions.contains(url.pathExtension.lowercased()) else { return }
                    DispatchQueue.main.async {
                        let fileInfo = LocalFileInfo(url: url)
                        if !self.selectedLocalFiles.contains(where: { $0.url == url }) {
                            self.selectedLocalFiles.append(fileInfo)
                        }
                    }
                }
            }
        }
    }

    private func handleDroppedURL(_ url: URL) {
        DispatchQueue.main.async {
            if url.isFileURL {
                let videoExtensions = ["mp4", "mkv", "webm", "avi", "mov", "m4v", "wmv", "flv", "mp3", "m4a", "wav", "flac"]
                if videoExtensions.contains(url.pathExtension.lowercased()) {
                    // If in transcribe section, add to local files
                    if self.selectedSidebarItem == .transcribe {
                        self.transcribeAppMode = .localFile
                        let fileInfo = LocalFileInfo(url: url)
                        if !self.selectedLocalFiles.contains(where: { $0.url == url }) {
                            self.selectedLocalFiles.append(fileInfo)
                        }
                    }
                }
            } else {
                self.urlInput = url.absoluteString
                self.performAction()
            }
        }
    }

    private enum FormatType { case best, audio, preferredRes }

    private func isFormatSelected(type: FormatType) -> Bool {
        guard let selected = selectedFormat, let info = downloader.videoInfo else { return false }
        switch type {
        case .best: return selected == info.formats.first { !$0.isAudioOnly }
        case .audio: return selected.isAudioOnly
        case .preferredRes: return selected.resolution == settings.preferredResolution
        }
    }

    private func performAction() {
        guard !urlInput.isEmpty else { return }
        downloader.reset()
        selectedFormat = nil
        selectedVideos = []

        if appMode == .singleVideo {
            downloader.fetchFormats(url: urlInput)
        } else if appMode == .pageScan {
            downloader.scanPage(url: urlInput)
        }
    }

    private func clearAll() {
        urlInput = ""
        downloader.reset()
        selectedFormat = nil
        selectedVideos = []
    }

    private func pasteFromClipboard() {
        if let string = NSPasteboard.general.string(forType: .string) {
            urlInput = string.trimmingCharacters(in: .whitespacesAndNewlines)
            performAction()
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

    private func toggleVideoSelection(_ video: VideoInfo) {
        if selectedVideos.contains(video.id) {
            selectedVideos.remove(video.id)
        } else {
            selectedVideos.insert(video.id)
        }
    }

    private func selectAllVideos() {
        if selectedVideos.count == downloader.scannedVideos.count {
            selectedVideos.removeAll()
        } else {
            selectedVideos = Set(downloader.scannedVideos.map { $0.id })
        }
    }

    private func downloadSingleVideo(_ video: VideoInfo) {
        downloader.downloadBest(url: video.url, outputPath: settings.downloadPath)
    }

    private func startDownload() {
        if appMode == .singleVideo {
            guard let format = selectedFormat else { return }
            downloader.download(url: urlInput, formatId: format.id, outputPath: settings.downloadPath)
        } else {
            guard let firstId = selectedVideos.first,
                  let video = downloader.scannedVideos.first(where: { $0.id == firstId }) else { return }
            downloader.downloadBest(url: video.url, outputPath: settings.downloadPath)
        }
    }
}

// MARK: - Supporting Views

struct QuickFormatButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.caption)
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? .primary : .secondary)
    }
}

struct FormatRow: View {
    let format: VideoFormat
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: format.isAudioOnly ? "music.note" : "film")
                .foregroundColor(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(format.resolution)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)

                    Text(format.ext.uppercased())
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08))
                        .cornerRadius(4)

                    if format.isVideoOnly {
                        Text("video only")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .cornerRadius(4)
                    }

                    if !format.filesize.isEmpty {
                        Text(format.filesize).font(.caption).foregroundColor(.secondary)
                    }
                }

                if !format.note.isEmpty && format.note != format.resolution {
                    Text(format.note).font(.caption2).foregroundColor(.secondary)
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.primary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isSelected ? Color.primary.opacity(0.08) : Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

struct VideoRow: View {
    let video: VideoInfo
    let isSelected: Bool
    let onToggle: () -> Void
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundColor(isSelected ? .primary : .secondary)
            }
            .buttonStyle(.plain)

            AsyncImage(url: URL(string: video.thumbnail ?? "")) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill).clipped()
                default:
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.2))
                        .overlay(Image(systemName: "play.fill").foregroundColor(.secondary))
                }
            }
            .frame(width: 120, height: 68)
            .cornerRadius(6)

            VStack(alignment: .leading, spacing: 4) {
                Text(video.title).font(.subheadline).fontWeight(.medium).lineLimit(2)
                HStack {
                    if !video.uploader.isEmpty && video.uploader != "Unknown" {
                        Text(video.uploader).font(.caption).foregroundColor(.secondary)
                    }
                    if video.duration != "--:--" {
                        Text("•").font(.caption).foregroundColor(.secondary)
                        Text(video.duration).font(.caption).foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            Button(action: onDownload) {
                Image(systemName: "arrow.down.circle").font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundColor(.primary)
            .help("Download this video")
        }
        .padding(10)
        .background(isSelected ? Color.primary.opacity(0.07) : Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
}

struct QueueItemRow: View {
    let item: QueueItem
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                switch item.status {
                case .pending:
                    Image(systemName: "clock").foregroundColor(.secondary)
                case .downloading:
                    ProgressView().scaleEffect(0.7)
                case .completed:
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill").foregroundColor(.red)
                }
            }
            .frame(width: 24)

            AsyncImage(url: URL(string: item.thumbnail ?? "")) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill).clipped()
                default:
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                        .overlay(
                            Image(systemName: item.isAudioOnly ? "music.note" : "play.fill")
                                .font(.caption).foregroundColor(.secondary)
                        )
                }
            }
            .frame(width: 60, height: 34)
            .cornerRadius(4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).font(.caption).fontWeight(.medium).lineLimit(1)
                    if item.isAudioOnly {
                        Text("MP3")
                            .font(.caption2)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.purple.opacity(0.2))
                            .cornerRadius(3)
                    }
                }

                if case .downloading = item.status {
                    HStack(spacing: 8) {
                        ProgressView(value: item.progress).frame(width: 100)
                        Text("\(Int(item.progress * 100))%").font(.caption2).foregroundColor(.secondary)
                        if !item.speed.isEmpty {
                            Text(item.speed).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                } else if case .failed(let error) = item.status {
                    Text(error).font(.caption2).foregroundColor(.red).lineLimit(1)
                } else if case .completed = item.status {
                    Text("Completed").font(.caption2).foregroundColor(.green)
                } else {
                    Text("Waiting...").font(.caption2).foregroundColor(.secondary)
                }
            }

            Spacer()

            if case .downloading = item.status {
                // Can't remove while downloading
            } else {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

struct LocalFileRow: View {
    let file: LocalFileInfo
    let transcriptionState: TranscriptionState
    let onRemove: () -> Void
    let onTranscribe: () -> Void

    private var isTranscribing: Bool {
        switch transcriptionState {
        case .extractingAudio, .transcribing, .loadingModel: return true
        default: return false
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: fileIcon)
                .font(.title2)
                .foregroundColor(.primary)
                .frame(width: 40, height: 40)
                .background(Color.primary.opacity(0.07))
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                Text(file.name).font(.subheadline).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 8) {
                    Text(file.sizeFormatted).font(.caption).foregroundColor(.secondary)
                    if let duration = file.duration {
                        Text("•").font(.caption).foregroundColor(.secondary)
                        Text(duration).font(.caption).foregroundColor(.secondary)
                    }
                    Text(file.url.pathExtension.uppercased())
                        .font(.caption2).fontWeight(.medium)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08))
                        .cornerRadius(4)
                }
            }

            Spacer()

            Button(action: onTranscribe) {
                if isTranscribing {
                    ProgressView().scaleEffect(0.7).frame(width: 80)
                } else {
                    Label("Transcribe", systemImage: "text.bubble")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isTranscribing)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle").foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isTranscribing)
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }

    private var fileIcon: String {
        let ext = file.url.pathExtension.lowercased()
        switch ext {
        case "mp3", "m4a", "wav", "flac", "aac": return "music.note"
        default: return "film"
        }
    }
}

struct TranscriptionLanguagePickerSheet: View {
    @Binding var selectedLanguage: String
    let onStart: () -> Void
    let onCancel: () -> Void

    private let languages: [(name: String, code: String)] = [
        ("Auto-Detect", "auto"), ("English", "en"), ("Swedish", "sv"),
        ("Spanish", "es"), ("French", "fr"), ("German", "de"),
        ("Portuguese", "pt"), ("Japanese", "ja"), ("Chinese", "zh"),
        ("Korean", "ko"), ("Italian", "it"), ("Dutch", "nl"),
        ("Russian", "ru"), ("Arabic", "ar"), ("Hindi", "hi")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 4) {
                Text("Language")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Select the spoken language of the audio.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 24)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            Divider()

            // Language list
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(languages, id: \.code) { lang in
                        Button(action: { selectedLanguage = lang.code }) {
                            HStack {
                                Text(lang.name)
                                    .font(.body)
                                    .foregroundColor(.primary)
                                Spacer()
                                if selectedLanguage == lang.code {
                                    Image(systemName: "checkmark")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.primary)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(
                                selectedLanguage == lang.code
                                    ? Color.primary.opacity(0.07)
                                    : Color.clear
                            )
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 320)

            Divider()

            // Buttons
            HStack(spacing: 10) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

                Button(action: onStart) {
                    Text("Start Transcription")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
            .padding(16)
        }
        .frame(width: 320)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

#Preview {
    ContentView()
}
