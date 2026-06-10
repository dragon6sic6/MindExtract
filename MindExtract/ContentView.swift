import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sidebar Navigation

enum SidebarItem: String, Hashable {
    case download = "Download"
    case transcripts = "Transcripts"
    case history = "History"
    case settings = "Settings"
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var downloader = YTDLPWrapper()
    @StateObject private var settings = AppSettings.shared
    @StateObject private var historyManager = HistoryManager.shared
    @StateObject private var transcriptionManager = TranscriptionManager.shared
    @StateObject private var transcriptionHistory = TranscriptionHistoryManager.shared

    // Navigation
    @State private var selectedSidebarItem: SidebarItem? = .download

    // Download state
    @State private var urlInput: String = ""
    @State private var selectedFormat: VideoFormat?

    /// One clean "best" format per resolution (MP4 preferred for compatibility),
    /// sorted high→low — instead of dumping all ~30 raw yt-dlp formats.
    private func tieredVideoFormats(_ formats: [VideoFormat]) -> [VideoFormat] {
        let videos = formats.filter { !$0.isAudioOnly && !$0.resolution.isEmpty }
        var best: [String: VideoFormat] = [:]
        for f in videos {
            if let existing = best[f.resolution] {
                if f.ext.lowercased() == "mp4" && existing.ext.lowercased() != "mp4" {
                    best[f.resolution] = f
                }
            } else {
                best[f.resolution] = f
            }
        }
        func height(_ r: String) -> Int { Int(r.filter(\.isNumber)) ?? 0 }
        return best.values.sorted { height($0.resolution) > height($1.resolution) }
    }

    /// Live download progress (0–1) while a download is running, else nil.
    private var currentDownloadProgress: Double? {
        if case .downloading(let p, _) = downloader.state { return p }
        return nil
    }

    @State private var selectedVideos: Set<String> = []
    @State private var showingLog = false
    @State private var isDraggingOverDownload = false

    // Transcribe state
    @State private var selectedLocalFiles: [LocalFileInfo] = []
    @State private var showTranscriptionLanguagePicker = false
    @State private var selectedTranscriptionLanguage = "auto"
    @State private var pendingTranscriptionFile: LocalFileInfo? = nil
    @State private var pendingTranscriptionFilePath: String? = nil

    private var detectedPlatform: Platform {
        Platform.detect(from: urlInput)
    }

    /// Soft, premium depth backdrop so Liquid Glass surfaces have something to
    /// refract (glass looks flat over a plain white window). Stays subtle enough
    /// to keep content fully readable.
    private var appBackdrop: some View {
        // Clean, uniform Messages-style dark gray — no gradients or glows.
        Color(red: 0.11, green: 0.11, blue: 0.12)
            .ignoresSafeArea()
    }

    /// Label for the engine that will actually run the next transcription.
    private var activeEngineLabel: String {
        if transcriptionManager.useAppleSpeech() {
            return "Apple Speech"
        }
        return "WhisperKit · \(settings.defaultWhisperModel.displayName)"
    }

    var body: some View {
        NavigationSplitView {
            sidebarView
                .navigationSplitViewColumnWidth(min: 160, ideal: 185, max: 210)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(appBackdrop)
                .navigationTitle("")
        }
        .frame(minWidth: 740, minHeight: 560)
        .background(WindowConfigurator())
        .onAppear { checkPendingURL() }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            selectedSidebarItem = .settings
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigate)) { note in
            if let item = note.object as? SidebarItem {
                selectedSidebarItem = item
            }
        }
        // Show the in-app transcription view wherever it's triggered (Media, a
        // completed download, or opening a past transcript from History).
        .onChange(of: transcriptionManager.showTranscriptionView) { _, show in
            if show {
                withAnimation(.easeInOut(duration: 0.25)) { selectedSidebarItem = .transcripts }
            }
        }
        // Bridge downloader progress to the transcription view when downloading audio for transcription
        .onChange(of: downloader.state) { _, newState in
            if case .downloadingAudio = transcriptionManager.transcriptionState {
                if case .downloading(let progress, _) = newState {
                    transcriptionManager.transcriptionState = .downloadingAudio(progress: progress)
                }
            }
        }
        .sheet(isPresented: $showTranscriptionLanguagePicker) {
            TranscriptionOptionsSheet(
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
        List(selection: $selectedSidebarItem) {
            Section("Library") {
                Label("Media", systemImage: "tray.and.arrow.down")
                    .tag(SidebarItem.download)
                Label("Transcripts", systemImage: "text.bubble")
                    .tag(SidebarItem.transcripts)
            }
            Section {
                Label("History", systemImage: "clock")
                    .tag(SidebarItem.history)
                Label("Settings", systemImage: "gearshape")
                    .tag(SidebarItem.settings)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("")
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        switch selectedSidebarItem ?? .download {
        case .download:
            downloadDetailView
        case .transcripts:
            // Live transcription and saved transcripts both live here.
            if transcriptionManager.showTranscriptionView {
                TranscriptionResultView(
                    transcriptionManager: transcriptionManager,
                    onClose: {
                        transcriptionManager.showTranscriptionView = false
                    }
                )
                .transition(.opacity)
            } else {
                transcriptsListView
            }
        case .history:
            historyDetailView
        case .settings:
            SettingsView(downloader: downloader)
        }
    }

    // MARK: - Download Detail

    private var downloadDetailView: some View {
        VStack(spacing: 0) {
            // yt-dlp warning banner
            if !downloader.isYTDLPInstalled {
                ytdlpWarningBanner
            }

            ScrollView {
                VStack(spacing: 16) {
                    // Local media files dropped here → ready to transcribe
                    if !selectedLocalFiles.isEmpty {
                        localFileListSection
                        VStack(spacing: 8) { localFileTranscriptionStatus }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 16)
                    } else if downloader.videoInfo == nil &&
                       downloader.scannedVideos.isEmpty &&
                       !(downloader.state == .fetchingFormats) &&
                       !(downloader.state == .scanningPage) {
                        mediaInputPanel
                    } else if case .fetchingFormats = downloader.state {
                        VStack(spacing: 18) {
                            mediaInputPanel
                            ProgressView("Loading…")
                                .padding(.top, 8)
                        }
                    } else if case .scanningPage = downloader.state {
                        VStack(spacing: 18) {
                            mediaInputPanel
                            ProgressView("Loading…")
                                .padding(.top, 8)
                        }
                    } else if let info = downloader.videoInfo {
                        videoAndFormatsSection(info: info)
                    } else if !downloader.scannedVideos.isEmpty {
                        scannedVideosSection
                    }

                    // Inline Queue Panel — always visible when items are queued
                    if !downloader.downloadQueue.isEmpty {
                        inlineQueueSection
                            .padding(.horizontal, 20)
                    }

                    // Bottom section — single-video actions are now inline on the
                    // selected quality row; only the save location + scan actions live here.
                    VStack(spacing: 12) {
                        if downloader.videoInfo != nil {
                            downloadLocationSection
                        } else if !downloader.scannedVideos.isEmpty && !selectedVideos.isEmpty {
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if downloader.videoInfo != nil || !downloader.scannedVideos.isEmpty || !selectedLocalFiles.isEmpty {
                    Button(action: clearAll) {
                        Image(systemName: "xmark.circle")
                    }
                    .help("Clear and start over")
                }
            }
        }
    }

    // MARK: - Unified media input (URL field + drop, one surface)

    private var mediaInputPanel: some View {
        VStack(spacing: 14) {
            urlInputField
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.doc")
                Text("or drop a video / audio file here to transcribe")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            Text("Supports YouTube, Vimeo, X, TikTok, and 1000+ sites — plus local files")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.55))
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isDraggingOverDownload ? DS.Colors.accent.opacity(0.08) : Color.white.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isDraggingOverDownload ? DS.Colors.accent.opacity(0.6) : Color.white.opacity(0.08),
                    style: StrokeStyle(lineWidth: isDraggingOverDownload ? 2 : 1, dash: [7, 5])
                )
        )
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .animation(.easeInOut(duration: 0.15), value: isDraggingOverDownload)
        .onDrop(of: [.fileURL, .url, .text], isTargeted: $isDraggingOverDownload) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    // MARK: - URL Input Field (shared)

    private var urlInputField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: detectedPlatform.icon)
                    .foregroundColor(.secondary)
                    .frame(width: 16)

                TextField(
                    "Paste a video or website URL…",
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
                    .help("Clear")
                }

                Button(action: pasteFromClipboard) {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Paste (⌘V)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Color.white.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))

            // Circular send-style action button (Messages-like)
            Button(action: performAction) {
                Group {
                    if case .fetchingFormats = downloader.state {
                        ProgressView().controlSize(.small)
                    } else if case .scanningPage = downloader.state {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 32, height: 32)
                .background(
                    (urlInput.isEmpty ? Color.secondary.opacity(0.25) : DS.Colors.accent),
                    in: Circle()
                )
            }
            .buttonStyle(.plain)
            .disabled(urlInput.isEmpty ||
                      downloader.state == .fetchingFormats ||
                      downloader.state == .scanningPage)
            .help("Load")
        }
    }

    // MARK: - History Detail

    private var historyDetailView: some View {
        RecentActivityView(onRedownload: { item in
            urlInput = item.url
            selectedSidebarItem = .download
            performAction()
        })
    }

    // MARK: - Transcripts Destination

    private var transcriptsListView: some View {
        TranscriptsListView(onGoToMedia: { selectedSidebarItem = .download })
    }


    // MARK: - yt-dlp Warning Banner

    private var ytdlpWarningBanner: some View {
        Group {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Downloading isn't available — a component is missing. Reinstall MindExtract to fix this.")
                    .font(.footnote)
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08))

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
                .secondaryGlassButton()
                .controlSize(.small)

                Button(action: { selectedLocalFiles.removeAll() }) {
                    Label("Clear", systemImage: "trash")
                        .font(.caption)
                }
                .secondaryGlassButton()
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
                            showTranscribeButton: selectedLocalFiles.count > 1,
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
            .frame(maxHeight: 250)
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
        if transcriptionManager.needsModelDownload {
            transcriptionManager.transcriptionState = .modelNotDownloaded
            return
        }
        let model = settings.defaultWhisperModel
        let modelToUse = transcriptionManager.isModelDownloaded(model) ? model : (transcriptionManager.downloadedModels.first ?? model)
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
                .secondaryGlassButton()
                .controlSize(.small)

                if !downloader.isProcessingQueue {
                    Button(action: { downloader.startQueue(outputPath: settings.downloadPath) }) {
                        Label("Download All", systemImage: "arrow.down.circle.fill").font(.caption)
                    }
                    .primaryGlassButton()
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
        .glassCard(padding: 14, cornerRadius: 12)
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
                }

                Spacer()
            }
            .padding()
            .glassSurface(cornerRadius: 12)
            .padding(.horizontal, 20)

            // The two things MindExtract does — equal twins, impossible to confuse.
            mediaActionRow(info: info)
        }
    }

    private func mediaActionRow(info: VideoInfo) -> some View {
        HStack(spacing: 10) {
            // Transcribe — the app's namesake, first.
            Button {
                if transcriptionManager.needsModelDownload {
                    transcriptionManager.transcriptionState = .modelNotDownloaded
                } else {
                    pendingTranscriptionFile = nil
                    pendingTranscriptionFilePath = nil
                    showTranscriptionLanguagePicker = true
                }
            } label: {
                Label("Transcribe", systemImage: "text.bubble.fill")
                    .frame(maxWidth: .infinity)
            }
            .primaryGlassButton()
            .disabled(isDownloading || isTranscribing || !transcriptionManager.areBinariesAvailable)

            // Download — click opens the quality menu; picking a quality starts
            // the download immediately. Impossible to miss the quality choice.
            if isDownloading {
                HStack(spacing: 6) {
                    Label("\(Int((currentDownloadProgress ?? 0) * 100))%", systemImage: "arrow.down.circle")
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.vertical, 7)
                .background(
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.3))
                        if let p = currentDownloadProgress {
                            GeometryReader { geo in
                                DS.Colors.accent
                                    .frame(width: max(0, geo.size.width * p))
                                    .animation(.easeOut(duration: 0.25), value: p)
                            }
                        }
                    }
                    .clipShape(Capsule())
                )

                Button { downloader.cancelDownload() } label: {
                    Image(systemName: "xmark")
                }
                .secondaryGlassButton()
                .help("Cancel download")
            } else {
                Menu {
                    ForEach(tieredVideoFormats(info.formats)) { f in
                        Button(qualityMenuLabel(f)) {
                            selectedFormat = f
                            startDownload()
                        }
                    }
                    Menu("All formats…") {
                        ForEach(info.formats) { f in
                            Button(qualityMenuLabel(f)) {
                                selectedFormat = f
                                startDownload()
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Label("Download", systemImage: "arrow.down.circle.fill")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .opacity(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(isTranscribing ? Color.secondary.opacity(0.3) : DS.Colors.accent)
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .disabled(isTranscribing)
                .help("Choose quality and download")
            }

            Spacer(minLength: 4)

            mediaActionPill("Audio", icon: "music.note", action: downloadAsAudio)
                .disabled(isDownloading || isTranscribing)
                .help("Download audio only (MP3)")
            mediaActionPill("Queue", icon: "plus", action: addVideoToQueue)
                .help("Add to queue and load another video")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .onAppear {
            // Auto-select the best available quality so Download is ready.
            if selectedFormat == nil {
                selectedFormat = tieredVideoFormats(info.formats).first ?? info.formats.first
            }
        }
    }

    private func qualityMenuLabel(_ f: VideoFormat) -> String {
        let res = f.isAudioOnly ? "Audio" : f.resolution
        return "\(res) — \(f.ext.uppercased())\(f.filesize.isEmpty ? "" : " · \(f.filesize)")"
    }

    /// Quiet glass pill for a media-level action in the video card header.
    private func mediaActionPill(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
        }
        .secondaryGlassButton()
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
                .secondaryGlassButton()
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
            Button("Change…") { selectDownloadFolder() }
                .secondaryGlassButton()
                .controlSize(.small)
        }
        .padding(12)
        .rowChrome()
    }

    // MARK: - Action Buttons

    private var actionButtonsSection: some View {
        VStack(spacing: 16) {
            if !selectedVideos.isEmpty {
                HStack(spacing: 10) {
                    Button(action: startDownload) {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Download \(selectedVideos.count) Video\(selectedVideos.count == 1 ? "" : "s")")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .primaryGlassButton()
                    .controlSize(.large)
                    .disabled(isDownloading)

                    if isDownloading {
                        Button(action: { downloader.cancelDownload() }) {
                            Image(systemName: "xmark")
                        }
                        .secondaryGlassButton()
                        .help("Cancel download")
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

    private func openCompletedTranscription(outputPath: String) {
        // If segments are already loaded (just completed), force-toggle the view
        if !transcriptionManager.segments.isEmpty {
            transcriptionManager.showTranscriptionView = false
            DispatchQueue.main.async {
                self.transcriptionManager.showTranscriptionView = true
            }
        } else {
            // Segments cleared — reload from history
            let title = transcriptionManager.currentTranscriptionTitle
            let historyItem = TranscriptionHistoryItem(
                title: title.isEmpty ? "Transcription" : title,
                filePath: outputPath,
                modelUsed: settings.defaultWhisperModel.displayName
            )
            transcriptionManager.openTranscriptionFromHistory(historyItem)
        }
    }

    private func transcribeFromURL() {
        if transcriptionManager.needsModelDownload {
            transcriptionManager.transcriptionState = .modelNotDownloaded
            return
        }
        let model = settings.defaultWhisperModel
        let modelToUse = transcriptionManager.isModelDownloaded(model) ? model : (transcriptionManager.downloadedModels.first ?? model)
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
            // Update title now that video info is definitely available
            let outputFileName: String
            if let info = downloader.videoInfo {
                let sanitizedTitle = info.title
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                    .prefix(80)
                outputFileName = String(sanitizedTitle)
                // Re-set title in case videoInfo wasn't available when startNewTranscription was called
                DispatchQueue.main.async {
                    self.transcriptionManager.currentTranscriptionTitle = info.title
                }
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
        if downloader.videoInfo != nil {
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
        if downloader.videoInfo != nil {
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
            case .idle, .fetchingFormats, .scanningPage, .downloading:
                // Download progress is shown inline on the selected format row.
                EmptyView()

            case .completed:
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        Text("Download completed!").fontWeight(.medium)
                        Spacer()
                        Button("Show in Finder") {
                            if let path = downloader.lastDownloadedFilePath {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            } else {
                                NSWorkspace.shared.open(URL(fileURLWithPath: settings.downloadPath))
                            }
                        }
                        .secondaryGlassButton()
                        .controlSize(.small)

                        if transcriptionManager.areBinariesAvailable,
                           let filePath = downloader.lastDownloadedFilePath {
                            Button(action: {
                                if transcriptionManager.needsModelDownload {
                                    transcriptionManager.transcriptionState = .modelNotDownloaded
                                } else {
                                    pendingTranscriptionFile = nil
                                    pendingTranscriptionFilePath = filePath
                                    showTranscriptionLanguagePicker = true
                                }
                            }) {
                                Label("Transcribe", systemImage: "text.bubble")
                            }
                            .secondaryGlassButton()
                            .controlSize(.small)
                            .tint(DS.Colors.accent)
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
                    if downloader.lastErrorNeedsAuth {
                        Button("Sign in to YouTube") {
                            selectedSidebarItem = .settings
                        }
                        .primaryGlassButton()
                        .controlSize(.small)
                    }
                    Button("Dismiss") { downloader.retry() }
                        .secondaryGlassButton()
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
                    .primaryGlassButton()
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
                        .tint(DS.Colors.accent)
                }
            }
            .padding(10)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(8)

        case .loadingModel(let modelName):
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Loading \(modelName.isEmpty ? "AI model" : modelName) model…").font(.system(size: 13)).fontWeight(.medium)
                    Text("First load compiles the model — larger models may take a few minutes").font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                ElapsedTimeText()
            }
            .padding(10)
            .background(Color.blue.opacity(0.1))
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
            .background(Color.blue.opacity(0.1))
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
                    .help("Cancel transcription")
                }
                ProgressView(value: max(progress, 0.02))
                    .progressViewStyle(.linear)
            }
            .padding(10)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(8)

        case .completed(let outputPath):
            HStack(spacing: 8) {
                // Clickable title area — opens transcription window
                Button {
                    openCompletedTranscription(outputPath: outputPath)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(transcriptionManager.currentTranscriptionTitle.isEmpty ? "Transcription saved!" : transcriptionManager.currentTranscriptionTitle)
                                .font(.system(size: 13))
                                .fontWeight(.medium)
                                .lineLimit(1)
                                .foregroundColor(.primary)
                            Text("Transcription complete · Click to view")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    openCompletedTranscription(outputPath: outputPath)
                } label: {
                    Label("View", systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 12))
                }
                .primaryGlassButton()
                .controlSize(.small)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: outputPath)])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                }
                .secondaryGlassButton()
                .controlSize(.small)
                .help("Show in Finder")
                Button {
                    transcriptionManager.resetState()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }

        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                Text(message).font(.system(size: 12)).foregroundColor(.red).lineLimit(2)
                Spacer()
                Button("Dismiss") { transcriptionManager.resetState() }
                    .secondaryGlassButton()
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
                .primaryGlassButton()
                .controlSize(.regular)
            }
            .padding(14)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(8)
        }
    }

    @ViewBuilder
    private var localFileTranscriptionStatus: some View {
        switch transcriptionManager.transcriptionState {
        case .idle:
            if !transcriptionManager.areBinariesAvailable {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("Audio tools are missing — transcription is unavailable").font(.system(size: 12)).foregroundColor(.orange)
                    Spacer()
                    Button("Settings") { selectedSidebarItem = .settings }
                        .secondaryGlassButton()
                        .controlSize(.mini)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            } else if transcriptionManager.needsModelDownload {
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
                    .primaryGlassButton()
                    .controlSize(.regular)
                }
                .padding(14)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            } else {
                VStack(spacing: 10) {
                    // Single file → one prominent, obvious primary action here.
                    if selectedLocalFiles.count <= 1 {
                        Button {
                            pendingTranscriptionFile = selectedLocalFiles.first
                            pendingTranscriptionFilePath = nil
                            showTranscriptionLanguagePicker = true
                        } label: {
                            Label("Transcribe", systemImage: "text.bubble")
                                .frame(maxWidth: .infinity)
                        }
                        .primaryGlassButton()
                        .controlSize(.large)
                        .disabled(selectedLocalFiles.isEmpty)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                        Text(selectedLocalFiles.count > 1
                             ? "Click Transcribe on each file above"
                             : "Ready")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(activeEngineLabel)\(settings.enableSpeakerDiarization ? "  ·  Speaker labels" : "")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
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

        case .error:
            VStack(spacing: 8) { transcriptionStatusView }
                .padding()
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)

        case .modelNotDownloaded:
            // Self-chromed (blue card) — no extra wrapper.
            transcriptionStatusView
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
                    .secondaryGlassButton()
                    .controlSize(.mini)

                    Button(action: { downloader.outputLog = "" }) {
                        Label("Clear", systemImage: "trash").font(.caption)
                    }
                    .secondaryGlassButton()
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
                .background(Color.white.opacity(0.03))
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

    private func handleDroppedURL(_ url: URL) {
        DispatchQueue.main.async {
            if url.isFileURL {
                let videoExtensions = ["mp4", "mkv", "webm", "avi", "mov", "m4v", "wmv", "flv", "mp3", "m4a", "wav", "flac"]
                if videoExtensions.contains(url.pathExtension.lowercased()) {
                    // Add to local files when on the media surface.
                    if self.selectedSidebarItem == .download {
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

    private func performAction() {
        guard !urlInput.isEmpty else { return }
        downloader.reset()
        selectedFormat = nil
        selectedVideos = []
        // One unified entry — the app auto-detects single video vs. playlist/page.
        downloader.loadURL(urlInput)
    }

    private func clearAll() {
        urlInput = ""
        downloader.reset()
        selectedFormat = nil
        selectedVideos = []
        selectedLocalFiles = []
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
        if downloader.videoInfo != nil {
            guard let format = selectedFormat else { return }
            downloader.download(url: urlInput, formatId: format.id, outputPath: settings.downloadPath)
        } else {
            // Download ALL selected videos by enqueuing them and starting the
            // parallel queue (previously only the first selected video downloaded).
            let selectedVids = downloader.scannedVideos.filter { selectedVideos.contains($0.id) }
            guard !selectedVids.isEmpty else { return }
            downloader.addSelectedVideosToQueue(videos: selectedVids, isAudioOnly: false)
            downloader.startQueue(outputPath: settings.downloadPath)
        }
    }
}

// MARK: - Supporting Views

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
        .rowChrome(selected: isSelected)
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
                            .background(Color.purple.opacity(0.12))
                            .foregroundColor(.purple)
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
                    Text("Waiting…").font(.caption2).foregroundColor(.secondary)
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
        .rowChrome()
    }
}

struct LocalFileRow: View {
    let file: LocalFileInfo
    let transcriptionState: TranscriptionState
    var showTranscribeButton: Bool = true
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
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.white.opacity(0.08), in: Capsule())
                }
            }

            Spacer()

            if showTranscribeButton {
                Button(action: onTranscribe) {
                    if isTranscribing {
                        ProgressView().scaleEffect(0.7).frame(width: 80)
                    } else {
                        Label("Transcribe", systemImage: "text.bubble")
                    }
                }
                .primaryGlassButton()
                .controlSize(.small)
                .disabled(isTranscribing)
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle").foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isTranscribing)
        }
        .padding(10)
        .rowChrome()
    }

    private var fileIcon: String {
        let ext = file.url.pathExtension.lowercased()
        switch ext {
        case "mp3", "m4a", "wav", "flac", "aac": return "music.note"
        default: return "film"
        }
    }
}

struct TranscriptionOptionsSheet: View {
    @Binding var selectedLanguage: String
    let onStart: () -> Void
    let onCancel: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var transcriptionManager = TranscriptionManager.shared

    private let languages: [(name: String, code: String)] = [
        ("Auto-detect", "auto"), ("English", "en"), ("Swedish", "sv"),
        ("Spanish", "es"), ("French", "fr"), ("German", "de"),
        ("Portuguese", "pt"), ("Japanese", "ja"), ("Chinese", "zh"),
        ("Korean", "ko"), ("Italian", "it"), ("Dutch", "nl"),
        ("Russian", "ru"), ("Arabic", "ar"), ("Hindi", "hi")
    ]

    private var languageName: String {
        languages.first { $0.code == selectedLanguage }?.name ?? "Auto-detect"
    }

    private var usingApple: Bool { transcriptionManager.useAppleSpeech() }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 4) {
                Image(systemName: "waveform")
                    .font(.system(size: 26))
                    .foregroundStyle(DS.Colors.accent)
                Text("Transcribe")
                    .font(.title2).fontWeight(.semibold)
                Text("Choose how to transcribe this audio. It runs fully on your Mac.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 22)
            .padding(.horizontal, 24)
            .padding(.bottom, 18)

            Divider()

            VStack(spacing: 16) {
                // Engine
                optionRow(title: "Engine",
                          subtitle: usingApple ? "Apple on-device speech — no model download" : "WhisperKit · \(settings.defaultWhisperModel.displayName)") {
                    Picker("", selection: $settings.transcriptionEngine) {
                        ForEach(TranscriptionEngineChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

                // Language
                optionRow(title: "Language", subtitle: "Spoken language of the audio") {
                    Picker("", selection: $selectedLanguage) {
                        ForEach(languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

                // Speaker labels
                optionRow(title: "Speaker labels", subtitle: "Identify who said what") {
                    Toggle("", isOn: $settings.enableSpeakerDiarization)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
            .padding(20)

            Divider()

            HStack(spacing: 10) {
                Button("Cancel", action: onCancel)
                    .secondaryGlassButton()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

                Button(action: onStart) {
                    Label("Start Transcription", systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                }
                .primaryGlassButton()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .frame(maxWidth: .infinity)
            }
            .padding(16)
        }
        .frame(width: 420)
    }

    @ViewBuilder
    private func optionRow<Control: View>(title: String, subtitle: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            control()
        }
    }
}

// MARK: - Elapsed Time View

struct ElapsedTimeText: View {
    @State private var elapsed: Int = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(elapsed < 60 ? "\(elapsed)s" : "\(elapsed / 60)m \(elapsed % 60)s")
            .font(.caption)
            .foregroundColor(.secondary)
            .monospacedDigit()
            .onReceive(timer) { _ in
                elapsed += 1
            }
    }
}

#Preview {
    ContentView()
}
