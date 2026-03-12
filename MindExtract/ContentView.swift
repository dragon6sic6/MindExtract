import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var downloader = YTDLPWrapper()
    @StateObject private var settings = AppSettings.shared
    @StateObject private var historyManager = HistoryManager.shared
    @StateObject private var transcriptionManager = TranscriptionManager.shared
    @State private var urlInput: String = ""
    @State private var selectedFormat: VideoFormat?
    @State private var selectedVideos: Set<String> = []
    @State private var showingLog = false
    @State private var appMode: AppMode = .singleVideo
    @State private var showQueue = false
    @State private var isDraggingOver = false
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showModelDownloadPrompt = false
    @State private var selectedLocalFiles: [LocalFileInfo] = []
    @State private var showActivityPanel = true
    @State private var showTranscriptionLanguagePicker = false
    @State private var selectedTranscriptionLanguage = "auto"
    @State private var pendingTranscriptionFile: LocalFileInfo? = nil
    @State private var pendingTranscriptionFilePath: String? = nil

    private var detectedPlatform: Platform {
        Platform.detect(from: urlInput)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Main content
            VStack(spacing: 0) {
                // Header
                headerView

                Divider()

                // yt-dlp missing warning banner
                if !downloader.isYTDLPInstalled {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("yt-dlp not found — downloading is unavailable. Run ")
                            .font(.footnote)
                        + Text("setup_binaries.sh")
                            .font(.system(.footnote, design: .monospaced))
                        + Text(" to install it.")
                            .font(.footnote)
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12))

                    Divider()
                }

                // Scrollable main content
                ScrollView {
                    VStack(spacing: 16) {
                        // Mode Picker + URL Input
                        urlInputSection
                            .padding(.horizontal, 20)
                            .padding(.top, 16)

                        // Content based on mode
                        if showQueue {
                            queueView
                        } else if appMode == .singleVideo {
                            singleVideoContent
                        } else if appMode == .pageScan {
                            pageScanContent
                        } else {
                            localFileContent
                        }

                        // Bottom section - context-dependent
                        VStack(spacing: 12) {
                            if appMode != .localFile {
                                downloadLocationSection
                                actionButtonsSection
                            }
                            statusSection

                            // Transcription status for local file mode
                            if appMode == .localFile {
                                localFileTranscriptionStatus
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                    }
                }

                // Log toggle
                if !downloader.outputLog.isEmpty {
                    logSection
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity)

            // Activity Panel (right side)
            if showActivityPanel {
                Divider()

                VStack(spacing: 0) {
                    // Panel header
                    HStack {
                        Text("History")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                        Button(action: { showActivityPanel = false }) {
                            Image(systemName: "xmark")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Hide panel")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                    Divider()

                    RecentActivityView()
                }
                .frame(width: 240, alignment: .leading)
                .background(Color(NSColor.windowBackgroundColor))
            }
        }
        .frame(minWidth: 500, minHeight: 600)
        .navigationTitle("MindExtract")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: { showActivityPanel.toggle() }) {
                    Image(systemName: showActivityPanel ? "sidebar.right" : "sidebar.left")
                }
                .help(showActivityPanel ? "Hide history" : "Show history")
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        // Drag and drop support
        .onDrop(of: [.fileURL, .url, .text, .movie, .video, .audio], isTargeted: $isDraggingOver) { providers in
            handleDrop(providers: providers)
            return true
        }
        .overlay(
            // Drop overlay
            Group {
                if isDraggingOver {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.accentColor, lineWidth: 3)
                        .background(Color.accentColor.opacity(0.1))
                        .overlay(
                            VStack(spacing: 12) {
                                Image(systemName: appMode == .localFile ? "doc.badge.plus" : "arrow.down.doc.fill")
                                    .font(.system(size: 48))
                                Text(appMode == .localFile ? "Drop video files here" : "Drop URL here")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                            }
                            .foregroundColor(.accentColor)
                        )
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isDraggingOver)
        )
        // Check for pending URL from menubar on appear
        .onAppear {
            checkPendingURL()
        }
        // Open settings from menu (toggle if already open)
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            showSettings.toggle()
        }
        // Settings sheet
        .sheet(isPresented: $showSettings) {
            SettingsView(downloader: downloader)
        }
        // History sheet
        .sheet(isPresented: $showHistory) {
            HistoryView { item in
                urlInput = item.url
                performAction()
            }
        }
        // Transcription result sheet
        .sheet(isPresented: $transcriptionManager.showTranscriptionView) {
            TranscriptionResultView(
                transcriptionManager: transcriptionManager,
                isPresented: $transcriptionManager.showTranscriptionView
            )
        }
        // Language picker sheet before transcription
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

    private func checkPendingURL() {
        if let pendingURL = UserDefaults.standard.string(forKey: "pendingURL"), !pendingURL.isEmpty {
            UserDefaults.standard.removeObject(forKey: "pendingURL")
            urlInput = pendingURL
            performAction()
        }
    }

    // MARK: - Drag and Drop Handler

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            // Try file URL first (for local files)
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    if let url = url {
                        self.handleDroppedURL(url)
                    }
                }
            }
            // Try web URL
            else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    if let url = url {
                        self.handleDroppedURL(url)
                    }
                }
            }
            // Try plain text (for pasted URLs)
            else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                _ = provider.loadObject(ofClass: String.self) { text, error in
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

    private func handleDroppedURL(_ url: URL) {
        DispatchQueue.main.async {
            if url.isFileURL {
                // Local file - switch to local file mode and add the file
                let videoExtensions = ["mp4", "mkv", "webm", "avi", "mov", "m4v", "wmv", "flv", "mp3", "m4a", "wav", "flac"]
                if videoExtensions.contains(url.pathExtension.lowercased()) {
                    self.appMode = .localFile
                    let fileInfo = LocalFileInfo(url: url)
                    if !self.selectedLocalFiles.contains(where: { $0.url == url }) {
                        self.selectedLocalFiles.append(fileInfo)
                    }
                }
            } else {
                // Web URL - use for download
                self.urlInput = url.absoluteString
                self.performAction()
            }
        }
    }

    // MARK: - Single Video Content

    private var singleVideoContent: some View {
        Group {
            if let info = downloader.videoInfo {
                videoAndFormatsSection(info: info)
            } else if case .fetchingFormats = downloader.state {
                Spacer()
                ProgressView("Fetching video information...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Spacer()
            } else {
                emptyStateView
            }
        }
    }

    // MARK: - Page Scan Content

    private var pageScanContent: some View {
        Group {
            if !downloader.scannedVideos.isEmpty {
                scannedVideosSection
            } else if case .scanningPage = downloader.state {
                Spacer()
                ProgressView("Scanning page for videos...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Spacer()
            } else {
                emptyStateView
            }
        }
    }

    // MARK: - Local File Content

    private var localFileContent: some View {
        VStack(spacing: 16) {
            if selectedLocalFiles.isEmpty {
                localFileEmptyState
            } else {
                localFileListSection
            }
        }
    }

    private var localFileEmptyState: some View {
        VStack {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary.opacity(0.5))

                Text("Select video files to transcribe")
                    .foregroundColor(.secondary)

                Text("Drag & drop files or click the button below")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.7))

                Button(action: selectLocalFiles) {
                    Label("Choose Files...", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Spacer()
        }
    }

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
            UTType.movie,
            UTType.video,
            UTType.mpeg4Movie,
            UTType.quickTimeMovie,
            UTType.avi,
            UTType(filenameExtension: "mkv") ?? UTType.movie,
            UTType(filenameExtension: "webm") ?? UTType.movie,
            UTType.mp3,
            UTType.audio,
            UTType.wav
        ].compactMap { $0 }
        panel.prompt = "Select Video Files"

        if panel.runModal() == .OK {
            let newFiles = panel.urls.map { LocalFileInfo(url: $0) }
            // Avoid duplicates
            for file in newFiles {
                if !selectedLocalFiles.contains(where: { $0.url == file.url }) {
                    selectedLocalFiles.append(file)
                }
            }
        }
    }

    private func transcribeLocalFile(_ file: LocalFileInfo) {
        // First check if any model is downloaded
        if transcriptionManager.downloadedModels.isEmpty {
            transcriptionManager.transcriptionState = .modelNotDownloaded
            return
        }

        let model = settings.defaultWhisperModel
        let modelToUse = transcriptionManager.isModelDownloaded(model) ? model : transcriptionManager.downloadedModels.first!

        // Set the title for the transcription view
        transcriptionManager.startNewTranscription(title: file.name, model: modelToUse)

        transcriptionManager.transcribe(
            videoPath: file.url.path,
            model: modelToUse,
            outputFormat: settings.transcriptionOutputFormat,
            language: selectedTranscriptionLanguage
        )
    }

    private var emptyStateView: some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: emptyStateIcon)
                    .font(.system(size: 48))
                    .foregroundColor(.secondary.opacity(0.5))
                Text(emptyStateMessage)
                    .foregroundColor(.secondary)
                Text(emptyStateTip)
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Spacer()
        }
    }

    private var emptyStateIcon: String {
        switch appMode {
        case .singleVideo: return "arrow.down.circle"
        case .pageScan: return "doc.text.magnifyingglass"
        case .localFile: return "doc.badge.plus"
        }
    }

    private var emptyStateMessage: String {
        switch appMode {
        case .singleVideo: return "Paste a video URL and click Fetch"
        case .pageScan: return "Paste a page URL to scan for videos"
        case .localFile: return "Select video files to transcribe"
        }
    }

    private var emptyStateTip: String {
        switch appMode {
        case .singleVideo, .pageScan: return "Tip: Drag & drop URLs or use Cmd+V to paste"
        case .localFile: return "Tip: Drag & drop video files onto the window"
        }
    }

    // MARK: - Queue View

    private var queueView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Queue header
            HStack {
                Text("Download Queue")
                    .font(.headline)

                Spacer()

                if !downloader.downloadQueue.isEmpty {
                    Button(action: { downloader.clearQueue() }) {
                        Label("Clear", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if !downloader.isProcessingQueue {
                        Button(action: { downloader.startQueue(outputPath: settings.downloadPath) }) {
                            Label("Start Queue", systemImage: "play.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            if downloader.downloadQueue.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Queue is empty")
                        .foregroundColor(.secondary)
                    Text("Add videos using the 'Add to Queue' button")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(downloader.downloadQueue) { item in
                            QueueItemRow(
                                item: item,
                                onRemove: { downloader.removeFromQueue(id: item.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .frame(height: 250)
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 16) {
            // App icon and name
            HStack(spacing: 10) {
                Image(systemName: "waveform.and.magnifyingglass")
                    .font(.system(size: 24))
                    .foregroundColor(.accentColor)

                Text("MindExtract")
                    .font(.title3)
                    .fontWeight(.semibold)
            }

            Spacer()

            // Settings button
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - URL Input

    private var urlInputSection: some View {
        VStack(spacing: 16) {
            // Mode Picker
            VStack(alignment: .leading, spacing: 8) {
                Picker("Mode", selection: $appMode) {
                    Text("Download Video").tag(AppMode.singleVideo)
                    Text("Scan Page").tag(AppMode.pageScan)
                    Text("Transcribe Local").tag(AppMode.localFile)
                }
                .pickerStyle(.segmented)
                .onChange(of: appMode) { _ in
                    downloader.reset()
                    selectedFormat = nil
                    selectedVideos = []
                    selectedLocalFiles = []
                }

                // Mode description
                Text(modeDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // URL Input (hidden for local file mode)
            if appMode != .localFile {
                VStack(alignment: .leading, spacing: 8) {
                    Text(appMode == .singleVideo ? "Video URL" : "Page URL")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    HStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: detectedPlatform.icon)
                                .foregroundColor(.accentColor)
                                .frame(width: 16)

                            TextField(appMode == .singleVideo
                                      ? "https://youtube.com/watch?v=..."
                                      : "https://youtube.com/playlist?list=...",
                                      text: $urlInput)
                                .textFieldStyle(.plain)
                                .font(.system(.body, design: .monospaced))
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
                            .help("Paste from clipboard")
                        }
                        .padding(10)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )

                        Button(action: performAction) {
                            if case .fetchingFormats = downloader.state {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 70)
                            } else if case .scanningPage = downloader.state {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 70)
                            } else {
                                Text(appMode == .singleVideo ? "Fetch" : "Scan")
                                    .frame(width: 70)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(urlInput.isEmpty || downloader.state == .fetchingFormats || downloader.state == .scanningPage)
                    }

                    Text("Supports: YouTube, Vimeo, Twitter, TikTok, and 1000+ sites")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
        }
    }

    private var modeDescription: String {
        switch appMode {
        case .singleVideo:
            return "Paste a video URL to download or transcribe it"
        case .pageScan:
            return "Scan a playlist, channel, or webpage for multiple videos"
        case .localFile:
            return "Select video files from your computer to transcribe"
        }
    }

    // MARK: - Video and Formats Section (Single Video Mode)

    private func videoAndFormatsSection(info: VideoInfo) -> some View {
        VStack(spacing: 0) {
            // Video Info Card
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
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
            .padding(.horizontal, 20)

            // Format Selection
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
                        QuickFormatButton(title: "720p", icon: "tv", isSelected: isFormatSelected(type: .p720)) {
                            selectedFormat = info.formats.first { $0.resolution == "720p" && !$0.isVideoOnly }
                                ?? info.formats.first { $0.resolution == "720p" }
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

    // MARK: - Scanned Videos Section (Page Scan Mode)

    private var scannedVideosSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Found \(downloader.scannedVideos.count) Videos")
                    .font(.headline)
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
            // Action buttons - main row (only show when video info is loaded)
            if appMode == .singleVideo && downloader.videoInfo != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Actions")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    HStack(spacing: 10) {
                        // Download button - primary action
                        Button(action: startDownload) {
                            HStack {
                                Image(systemName: "arrow.down.circle.fill")
                                Text(isDownloading ? "Downloading..." : "Download")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!canDownload || isTranscribing)

                        // MP3 button
                        Button(action: downloadAsAudio) {
                            HStack {
                                Image(systemName: "music.note")
                                Text("MP3")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(isDownloading || isTranscribing)

                        // Transcribe button
                        if transcriptionManager.areBinariesAvailable {
                            Button(action: {
                                pendingTranscriptionFile = nil
                                pendingTranscriptionFilePath = nil
                                showTranscriptionLanguagePicker = true
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

                        // Cancel button (only when downloading)
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
                // Page scan mode with selections
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

            // Queue section - secondary actions
            if (appMode == .singleVideo && downloader.videoInfo != nil) ||
               (appMode == .pageScan && !selectedVideos.isEmpty) {
                HStack(spacing: 8) {
                    Button(action: addVideoToQueue) {
                        Label("Queue", systemImage: "plus.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(action: addAudioToQueue) {
                        Label("Queue MP3", systemImage: "music.note.list")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()

                    Button(action: { showQueue.toggle() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "list.bullet")
                            if !downloader.downloadQueue.isEmpty {
                                Text("\(downloader.downloadQueue.count)")
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(showQueue ? .accentColor : nil)
                    .help("View download queue")
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
        case .extractingAudio, .transcribing:
            return true
        default:
            return false
        }
    }

    private func transcribeFromURL() {
        // Check if any model is downloaded
        if transcriptionManager.downloadedModels.isEmpty {
            transcriptionManager.transcriptionState = .modelNotDownloaded
            return
        }

        let model = settings.defaultWhisperModel
        let modelToUse = transcriptionManager.isModelDownloaded(model) ? model : transcriptionManager.downloadedModels.first!

        // Set the title for the transcription view
        let title = downloader.videoInfo?.title ?? "Video Transcription"
        transcriptionManager.startNewTranscription(title: title, model: modelToUse)

        // Download audio to temp, then transcribe
        downloader.downloadAudioForTranscription(url: urlInput) { [self] audioPath, error in
            if let error = error {
                transcriptionManager.transcriptionState = .error("Failed to download audio: \(error)")
                return
            }

            guard let audioPath = audioPath else {
                transcriptionManager.transcriptionState = .error("No audio file received")
                return
            }

            // Create output path in download folder with video title
            let outputFileName: String
            if let info = downloader.videoInfo {
                // Sanitize title for filename
                let sanitizedTitle = info.title
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                    .prefix(80)
                outputFileName = String(sanitizedTitle)
            } else {
                outputFileName = "transcription_\(UUID().uuidString.prefix(8))"
            }

            let outputPath = settings.downloadPath + "/" + outputFileName + "." + settings.transcriptionOutputFormat.rawValue

            // Run transcription
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
    }

    private func addAudioToQueue() {
        if appMode == .singleVideo {
            downloader.addCurrentVideoToQueue(isAudioOnly: true)
        } else {
            let selectedVids = downloader.scannedVideos.filter { selectedVideos.contains($0.id) }
            downloader.addSelectedVideosToQueue(videos: selectedVids, isAudioOnly: true)
        }
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

                        // Transcribe button
                        if transcriptionManager.areBinariesAvailable,
                           let filePath = downloader.lastDownloadedFilePath {
                            Button(action: {
                                pendingTranscriptionFile = nil
                                pendingTranscriptionFilePath = filePath
                                showTranscriptionLanguagePicker = true
                            }) {
                                Label("Transcribe", systemImage: "text.bubble")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.orange)
                        }
                    }

                    // Transcription status
                    transcriptionStatusView
                }
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)

            case .error(let message):
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                    Text(message).foregroundColor(.red).lineLimit(2).font(.caption)
                    Spacer()
                    Button("Dismiss") {
                        downloader.retry()
                    }
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

        case .extractingAudio:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text("Extracting audio...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

        case .transcribing(let progress):
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Transcribing...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: {
                        transcriptionManager.cancelTranscription()
                    }) {
                        Image(systemName: "xmark.circle")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                if progress > 0 {
                    ProgressView(value: progress)
                }
            }

        case .completed(let outputPath):
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill").foregroundColor(.orange)
                Text("Transcription saved!")
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                Button("Open") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: outputPath)])
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                Button("Dismiss") {
                    transcriptionManager.resetState()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
                Spacer()
                Button("Dismiss") {
                    transcriptionManager.resetState()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

        case .modelNotDownloaded:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text("Whisper model not downloaded")
                    .font(.caption)
                    .foregroundColor(.orange)
                Spacer()
                Button("Download Model") {
                    showSettings = true
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
    }

    @ViewBuilder
    private var localFileTranscriptionStatus: some View {
        switch transcriptionManager.transcriptionState {
        case .idle:
            // First check if binaries are available
            if !transcriptionManager.areBinariesAvailable {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("Whisper or FFmpeg binary not found")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Spacer()
                    Button("Settings") {
                        showSettings = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }
            // Then check if any model is downloaded
            else if transcriptionManager.downloadedModels.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Download a Whisper model to start transcribing")
                            .font(.caption)
                            .fontWeight(.medium)
                        Text("Go to Settings → Transcription → Manage Models")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Download Model") {
                        showSettings = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            }
            // Ready to transcribe
            else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("Ready to transcribe")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("Model: \(settings.defaultWhisperModel.displayName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            }

        case .extractingAudio, .transcribing:
            VStack(spacing: 8) {
                transcriptionStatusView
            }
            .padding()
            .background(Color.blue.opacity(0.1))
            .cornerRadius(8)

        case .completed:
            VStack(spacing: 8) {
                transcriptionStatusView
            }
            .padding()
            .background(Color.green.opacity(0.1))
            .cornerRadius(8)

        case .error, .modelNotDownloaded:
            VStack(spacing: 8) {
                transcriptionStatusView
            }
            .padding()
            .background(Color.red.opacity(0.1))
            .cornerRadius(8)
        }
    }

    private func startTranscription(filePath: String) {
        let model = settings.defaultWhisperModel
        if transcriptionManager.isModelDownloaded(model) {
            transcriptionManager.transcribe(
                videoPath: filePath,
                model: model,
                outputFormat: settings.transcriptionOutputFormat,
                language: selectedTranscriptionLanguage
            )
        } else {
            // Model not downloaded, show prompt
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
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Button(action: { downloader.outputLog = "" }) {
                        Label("Clear", systemImage: "trash")
                            .font(.caption)
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

    private enum FormatType { case best, audio, p720 }

    private func isFormatSelected(type: FormatType) -> Bool {
        guard let selected = selectedFormat, let info = downloader.videoInfo else { return false }
        switch type {
        case .best: return selected == info.formats.first { !$0.isAudioOnly }
        case .audio: return selected.isAudioOnly
        case .p720: return selected.resolution == "720p"
        }
    }

    private func performAction() {
        guard !urlInput.isEmpty else { return }
        downloader.reset()
        selectedFormat = nil
        selectedVideos = []

        if appMode == .singleVideo {
            downloader.fetchFormats(url: urlInput)
        } else {
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
            // Download first selected video (for now - batch download could be added later)
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
        .tint(isSelected ? .accentColor : .secondary)
    }
}

struct FormatRow: View {
    let format: VideoFormat
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: format.isAudioOnly ? "music.note" : "film")
                .foregroundColor(format.isAudioOnly ? .purple : .blue)
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
                        .background(Color.accentColor.opacity(0.15))
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
                Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
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
            // Checkbox
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)

            // Thumbnail
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

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(video.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)

                HStack {
                    if !video.uploader.isEmpty && video.uploader != "Unknown" {
                        Text(video.uploader)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if video.duration != "--:--" {
                        Text("•")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(video.duration)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Quick download button
            Button(action: onDownload) {
                Image(systemName: "arrow.down.circle")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            .help("Download this video")
        }
        .padding(10)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
}

struct QueueItemRow: View {
    let item: QueueItem
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            Group {
                switch item.status {
                case .pending:
                    Image(systemName: "clock")
                        .foregroundColor(.secondary)
                case .downloading:
                    ProgressView()
                        .scaleEffect(0.7)
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.red)
                }
            }
            .frame(width: 24)

            // Thumbnail
            AsyncImage(url: URL(string: item.thumbnail ?? "")) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill).clipped()
                default:
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                        .overlay(
                            Image(systemName: item.isAudioOnly ? "music.note" : "play.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        )
                }
            }
            .frame(width: 60, height: 34)
            .cornerRadius(4)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    if item.isAudioOnly {
                        Text("MP3")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.2))
                            .cornerRadius(3)
                    }
                }

                // Progress or status
                if case .downloading = item.status {
                    HStack(spacing: 8) {
                        ProgressView(value: item.progress)
                            .frame(width: 100)
                        Text("\(Int(item.progress * 100))%")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if !item.speed.isEmpty {
                            Text(item.speed)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                } else if case .failed(let error) = item.status {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(1)
                } else if case .completed = item.status {
                    Text("Completed")
                        .font(.caption2)
                        .foregroundColor(.green)
                } else {
                    Text("Waiting...")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Remove button (only if not downloading)
            if case .downloading = item.status {
                // Can't remove while downloading
            } else {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle")
                        .foregroundColor(.secondary)
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
        case .extractingAudio, .transcribing:
            return true
        default:
            return false
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // File icon
            Image(systemName: fileIcon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(8)

            // File info
            VStack(alignment: .leading, spacing: 4) {
                Text(file.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(file.sizeFormatted)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let duration = file.duration {
                        Text("•")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(duration)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text(file.url.pathExtension.uppercased())
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .cornerRadius(4)
                }
            }

            Spacer()

            // Transcribe button
            Button(action: onTranscribe) {
                if isTranscribing {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 80)
                } else {
                    Label("Transcribe", systemImage: "text.bubble")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isTranscribing)

            // Remove button
            Button(action: onRemove) {
                Image(systemName: "xmark.circle")
                    .foregroundColor(.secondary)
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
        case "mp3", "m4a", "wav", "flac", "aac":
            return "music.note"
        default:
            return "film"
        }
    }
}

struct TranscriptionLanguagePickerSheet: View {
    @Binding var selectedLanguage: String
    let onStart: () -> Void
    let onCancel: () -> Void

    private let languages: [(name: String, code: String)] = [
        ("Auto-Detect", "auto"),
        ("English", "en"),
        ("Swedish", "sv"),
        ("Spanish", "es"),
        ("French", "fr"),
        ("German", "de"),
        ("Portuguese", "pt"),
        ("Japanese", "ja"),
        ("Chinese", "zh"),
        ("Korean", "ko"),
        ("Italian", "it"),
        ("Dutch", "nl"),
        ("Russian", "ru"),
        ("Arabic", "ar"),
        ("Hindi", "hi")
    ]

    var body: some View {
        VStack(spacing: 16) {
            Text("Transcription Language")
                .font(.headline)

            Text("Select the spoken language of the audio, or use Auto-Detect.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Picker("Language", selection: $selectedLanguage) {
                ForEach(languages, id: \.code) { lang in
                    Text(lang.name).tag(lang.code)
                }
            }
            .pickerStyle(.radioGroup)
            .padding(.vertical, 4)

            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                Button(action: onStart) {
                    Text("Start Transcription")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 280)
    }
}

#Preview {
    ContentView()
}
