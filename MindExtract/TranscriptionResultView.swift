import SwiftUI
import AppKit
import AVFoundation

// MARK: - Speaker Colors

enum SpeakerColors {
    static let palette: [Color] = [.blue, .purple, .orange, .teal, .pink, .green, .indigo, .mint]

    static func color(for speaker: String) -> Color {
        if let num = Int(speaker.replacingOccurrences(of: "Speaker ", with: "")),
           num > 0 {
            return palette[(num - 1) % palette.count]
        }
        return .accentColor
    }
}

// MARK: - Tab Selection

enum TranscriptionTab: String, CaseIterable {
    case text = "Text"
    case timeline = "Timeline"
    case summary = "Summary"
}

// MARK: - Audio Player

@MainActor
class AudioPlayerManager: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var playbackRate: Float = 1.0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(path: String) {
        stop()
        let url = URL(fileURLWithPath: path)
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        player = p
        p.prepareToPlay()
        duration = p.duration
    }

    func togglePlayPause() {
        guard let p = player else { return }
        if p.isPlaying {
            p.pause()
            isPlaying = false
            timer?.invalidate()
        } else {
            p.rate = playbackRate
            p.enableRate = true
            p.play()
            isPlaying = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self, let p = self.player else { return }
                    self.currentTime = p.currentTime
                    if !p.isPlaying && self.isPlaying {
                        self.isPlaying = false
                        self.timer?.invalidate()
                    }
                }
            }
        }
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        currentTime = time
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        if let p = player, p.isPlaying {
            p.rate = rate
        }
    }

    func stop() {
        timer?.invalidate()
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    isolated deinit {
        stop()
    }
}

// MARK: - Main View

struct TranscriptionResultView: View {
    @ObservedObject var transcriptionManager: TranscriptionManager
    var onClose: (() -> Void)?

    @StateObject private var audioPlayer = AudioPlayerManager()
    @State private var showCopiedAlert = false
    @State private var selectedTab: TranscriptionTab = .text
    @State private var searchText: String = ""
    @State private var showSearch = false
    @State private var editingSpeaker: String?
    @State private var editingName: String = ""
    @ObservedObject private var summarizer = TranscriptSummarizer.shared
    @ObservedObject private var chat = TranscriptChat.shared
    // Same UserDefaults key AppSettings uses, so switching here is instantly
    // reflected by AIBackends.current() on the next question.
    @AppStorage("aiBackend") private var aiBackend: AIBackendChoice = .apple
    @State private var summaryCopied = false
    @State private var chatInput = ""

    private var availableTabs: [TranscriptionTab] { TranscriptionTab.allCases }

    private func commitRename(for speaker: String) {
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        transcriptionManager.speakerNameOverrides[speaker] = trimmed.isEmpty ? nil : trimmed
        editingSpeaker = nil
    }

    /// The segment currently under the audio playhead (while playing), for live
    /// highlight + follow-along scrolling in the Timeline tab.
    private var activeSegmentID: UUID? {
        guard audioPlayer.isPlaying else { return nil }
        let t = Float(audioPlayer.currentTime)
        if let exact = transcriptionManager.segments.first(where: { t >= $0.start && t < $0.end }) {
            return exact.id
        }
        return transcriptionManager.segments.last(where: { $0.start <= t })?.id
    }

    private var isTranscribing: Bool {
        switch transcriptionManager.transcriptionState {
        case .downloadingAudio, .extractingAudio, .transcribing, .loadingModel:
            return true
        default:
            return false
        }
    }

    private var isCompleted: Bool {
        if case .completed = transcriptionManager.transcriptionState {
            return true
        }
        return false
    }

    private var hasError: Bool {
        if case .error = transcriptionManager.transcriptionState {
            return true
        }
        return false
    }

    private var wordCount: Int {
        transcriptionManager.liveTranscriptionText
            .split(whereSeparator: { $0.isWhitespace })
            .count
    }

    private var formattedDuration: String {
        let d = transcriptionManager.audioDuration
        if d <= 0 { return "--:--" }
        let m = Int(d) / 60
        let s = Int(d) % 60
        return String(format: "%d:%02d", m, s)
    }

    private var filteredSegments: [TranscriptionSegmentData] {
        if searchText.isEmpty { return transcriptionManager.segments }
        return transcriptionManager.segments.filter {
            $0.text.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Status banner (only when active)
            statusView

            // Speaker legend (shown when diarization data is present)
            let speakersInSegments = Array(Set(transcriptionManager.segments.compactMap { $0.speaker })).sorted()
            if !speakersInSegments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                  HStack(spacing: 16) {
                    ForEach(speakersInSegments, id: \.self) { speaker in
                        Button {
                            editingName = transcriptionManager.speakerDisplayName(speaker)
                            editingSpeaker = speaker
                        } label: {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(SpeakerColors.color(for: speaker))
                                    .frame(width: 8, height: 8)
                                Text(transcriptionManager.speakerDisplayName(speaker))
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .chromeText()
                                Image(systemName: "pencil")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary.opacity(0.45))
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Rename speaker")
                        .popover(isPresented: Binding(
                            get: { editingSpeaker == speaker },
                            set: { if !$0 { editingSpeaker = nil } }
                        )) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Rename \(speaker)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                TextField("Name", text: $editingName)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 190)
                                    .onSubmit { commitRename(for: speaker) }
                                HStack {
                                    Button("Reset") {
                                        transcriptionManager.speakerNameOverrides[speaker] = nil
                                        editingSpeaker = nil
                                    }
                                    Spacer()
                                    Button("Save") { commitRename(for: speaker) }
                                        .keyboardShortcut(.defaultAction)
                                }
                            }
                            .padding(12)
                        }
                    }
                  }
                  .padding(.horizontal, 16)
                  .padding(.vertical, 4)
                }
                .background(Color.white.opacity(0.03))

                Divider()
            }

            // Content area
            Group {
                switch selectedTab {
                case .text:
                    textView
                case .timeline:
                    timelineView
                case .summary:
                    summaryView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Audio player bar
            if transcriptionManager.audioFilePath != nil && (isCompleted || !transcriptionManager.segments.isEmpty) {
                Divider()
                audioPlayerBar
            }

            Divider()

            // Bottom bar
            bottomBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: transcriptionManager.audioFilePath) { _, path in
            if let path = path {
                audioPlayer.load(path: path)
            }
        }
        .onAppear {
            if let path = transcriptionManager.audioFilePath {
                audioPlayer.load(path: path)
            }
        }
        .onDisappear {
            audioPlayer.stop()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 12) {
            // Back to the Transcripts list (kept in memory — not discarded).
            Button(action: { if !isTranscribing { audioPlayer.stop(); onClose?() } }) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                    Text("Transcripts")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isTranscribing ? .secondary.opacity(0.4) : .accentColor)
                .chromeText()
            }
            .buttonStyle(.plain)
            .disabled(isTranscribing)
            .layoutPriority(1)

            Text(transcriptionManager.currentTranscriptionTitle.isEmpty
                 ? "Transcription"
                 : transcriptionManager.currentTranscriptionTitle)
                .font(.system(size: 14, weight: .semibold))
                .chromeText(.tail, flexible: true)

            Spacer()

            // Transcribing indicator
            if isTranscribing {
                HStack(spacing: 6) {
                    transcriberStatusPill
                }
            }

            // Tab switcher (pill style)
            tabPicker

            // Search toggle
            if isCompleted || !transcriptionManager.segments.isEmpty {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSearch.toggle()
                        if !showSearch { searchText = "" }
                    }
                }) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundColor(showSearch ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("Search transcript")
            }

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if showSearch {
                searchBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        SearchField(text: $searchText)
            .background(DS.Colors.backdrop, in: Capsule())
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .offset(y: 20)
            .zIndex(1)
    }

    // MARK: - Tab Picker (Segmented)

    private var tabPicker: some View {
        HStack(spacing: 0) {
            ForEach(availableTabs, id: \.self) { tab in
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab } }) {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                        .foregroundColor(selectedTab == tab ? .primary : .secondary)
                        .chromeText()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(
                            selectedTab == tab
                                ? Color.white.opacity(0.12)
                                : Color.clear
                        )
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.06))
        .cornerRadius(8)
    }

    // MARK: - Status Pill

    @ViewBuilder
    private var transcriberStatusPill: some View {
        switch transcriptionManager.transcriptionState {
        case .downloadingAudio(let progress):
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
                Text("Downloading audio")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                if progress > 0 {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(12)

        case .loadingModel(let modelName):
            statusPill(text: "Loading \(modelName.isEmpty ? "model" : modelName)", showSpinner: true)

        case .extractingAudio:
            statusPill(text: "Extracting audio", showSpinner: true)

        case .transcribing(let progress):
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
                Text("Transcribing")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .chromeText()
                if progress > 0 {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .chromeText()
                }
                Button("Cancel") {
                    transcriptionManager.cancelTranscription()
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundColor(.red.opacity(0.8))
                .chromeText()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(12)
            .fixedSize()

        default:
            EmptyView()
        }
    }

    private func statusPill(text: String, showSpinner: Bool) -> some View {
        HStack(spacing: 6) {
            if showSpinner {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(12)
    }

    // MARK: - Status View (banners)

    @ViewBuilder
    private var statusView: some View {
        switch transcriptionManager.transcriptionState {
        case .downloadingAudio(let progress) where progress > 0:
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(DS.Colors.accent)
                .frame(height: 2)

        case .transcribing(let progress) where progress > 0:
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .frame(height: 2)

        case .completed:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.green)
                Text("Transcription complete")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                if let path = transcriptionManager.lastSavedPath {
                    Button(action: {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }) {
                        Label("Show in Finder", systemImage: "folder")
                            .font(.system(size: 12))
                    }
                    .secondaryGlassButton()
                    .controlSize(.mini)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.green.opacity(0.08))

        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.08))

        default:
            EmptyView()
        }
    }

    // MARK: - Text View

    @ViewBuilder
    private var textView: some View {
        if transcriptionManager.liveTranscriptionText.isEmpty && isTranscribing {
            // Centered in the full content area while we wait for the first words.
            WaitingAnimationView(state: transcriptionManager.transcriptionState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if transcriptionManager.segments.isEmpty && !isTranscribing && !isCompleted {
            Text("Waiting for transcription…")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            textScrollView
        }
    }

    private var textScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    confidenceTextView
                        .padding(20)
                        .padding(.top, showSearch ? 16 : 0)
                        .id("textBottom")
                }
            }
            .onChange(of: transcriptionManager.segments.count) { _, _ in
                if isTranscribing {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("textBottom", anchor: .bottom)
                    }
                }
            }
        }
    }


    @ViewBuilder
    private var confidenceTextView: some View {
        let segments = searchText.isEmpty ? transcriptionManager.segments : filteredSegments
        if segments.isEmpty && !searchText.isEmpty {
            Text("No results for \"\(searchText)\"")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
        } else {
            ConfidenceTextBlock(segments: segments, searchText: searchText, speakerNames: transcriptionManager.speakerNameOverrides)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    // MARK: - Timeline View (MacWhisper style)

    @ViewBuilder
    private var timelineView: some View {
        if transcriptionManager.segments.isEmpty && isTranscribing {
            // Centered in the full content area while we wait for the first segments.
            WaitingAnimationView(state: transcriptionManager.transcriptionState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            timelineScrollView
        }
    }

    private var timelineScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if filteredSegments.isEmpty && !searchText.isEmpty {
                    Text("No results for \"\(searchText)\"")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(filteredSegments.enumerated()), id: \.element.id) { index, segment in
                            SegmentRow(
                                segment: segment,
                                searchText: searchText,
                                isEven: index % 2 == 0,
                                speakerNames: transcriptionManager.speakerNameOverrides,
                                isActive: segment.id == activeSegmentID,
                                onTap: {
                                    audioPlayer.seek(to: TimeInterval(segment.start))
                                    if !audioPlayer.isPlaying {
                                        audioPlayer.togglePlayPause()
                                    }
                                }
                            )
                            .id(segment.id)
                        }
                    }
                    .padding(.top, showSearch ? 20 : 4)
                    .padding(.bottom, 4)
                    .id("timelineBottom")
                }
            }
            .onChange(of: transcriptionManager.segments.count) { _, _ in
                if isTranscribing, let lastId = transcriptionManager.segments.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
            .onChange(of: activeSegmentID) { _, newID in
                // Follow the audio playhead through the transcript.
                if !isTranscribing, let id = newID {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Summary & Ask (on-device AI, macOS 26+)

    private var summaryView: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        summarySection

                        if !chat.messages.isEmpty {
                            Divider()
                            ForEach(chat.messages) { msg in
                                chatBubble(msg)
                            }
                            if chat.isAnswering {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Thinking…").font(.caption).foregroundColor(.secondary)
                                }
                            }
                            Color.clear.frame(height: 1).id("chatBottom")
                        }
                    }
                    .padding(20)
                }
                .onChange(of: chat.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("chatBottom", anchor: .bottom)
                    }
                }
            }

            Divider()

            // Ask bar — model switcher, question in, answer out.
            HStack(spacing: 8) {
                // In-chat AI model switcher — swap providers without leaving the
                // conversation (e.g. when Apple's guardrail blocks a question).
                Menu {
                    Picker("AI model", selection: $aiBackend) {
                        ForEach(AIBackendChoice.allCases) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "cpu")
                        Text(aiBackend.shortName)
                            .chromeText()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .opacity(0.7)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(DS.Colors.inputFill, in: Capsule())
                    .overlay(Capsule().strokeBorder(DS.Colors.inputStroke, lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("AI model — switch provider for answers")

                TextField("Ask about this transcript…", text: $chatInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { sendQuestion() }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(DS.Colors.inputFill, in: Capsule())
                    .overlay(Capsule().strokeBorder(DS.Colors.inputStroke, lineWidth: 1))

                Button(action: sendQuestion) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(
                            chatInput.trimmingCharacters(in: .whitespaces).isEmpty || chat.isAnswering
                                ? Color.secondary.opacity(0.25) : DS.Colors.accent,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(chatInput.trimmingCharacters(in: .whitespaces).isEmpty || chat.isAnswering)
                .help("Ask")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .onAppear { chat.prepare(transcript: transcriptionManager.liveTranscriptionText) }
        .onChange(of: aiBackend) { _, newValue in
            // Switching to Ollama is only useful if a model is selected — grab
            // the first installed one so the switch "just works".
            if newValue == .ollama && AppSettings.shared.ollamaModel.isEmpty {
                Task {
                    let models = await OllamaBackend.installedModels()
                    if let first = models.first {
                        await MainActor.run { AppSettings.shared.ollamaModel = first }
                    }
                }
            }
        }
    }

    private func sendQuestion() {
        let q = chatInput
        chatInput = ""
        chat.prepare(transcript: transcriptionManager.liveTranscriptionText)
        chat.ask(q)
    }

    @ViewBuilder
    private func chatBubble(_ msg: ChatMessage) -> some View {
        HStack {
            if msg.isUser { Spacer(minLength: 60) }
            Text(msg.text)
                .font(.system(size: 13))
                .lineSpacing(4)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    msg.isUser ? DS.Colors.accent : Color.white.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .foregroundColor(msg.isUser ? .white : .primary)
            if !msg.isUser { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        switch summarizer.state {
        case .idle:
            VStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 32))
                    .foregroundStyle(DS.Colors.accent)
                Text("Summarize this transcript")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("Overview, key points and action items — generated entirely on your Mac. Nothing leaves your computer. You can also just ask a question below.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button {
                    summarizer.summarize(transcriptionManager.liveTranscriptionText)
                } label: {
                    Label("Generate Summary", systemImage: "sparkles")
                }
                .primaryGlassButton()
                .disabled(transcriptionManager.liveTranscriptionText.isEmpty || isTranscribing)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)

        case .working(let message):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)

        case .done(let summary):
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(AIBackends.current().badge, systemImage: "sparkles")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(summary, forType: .string)
                        summaryCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { summaryCopied = false }
                    } label: {
                        Label(summaryCopied ? "Copied" : "Copy", systemImage: summaryCopied ? "checkmark" : "doc.on.doc")
                    }
                    .secondaryGlassButton()
                    Button {
                        summarizer.reset()
                        summarizer.summarize(transcriptionManager.liveTranscriptionText)
                    } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                    .secondaryGlassButton()
                }
                Text(summary)
                    .font(DS.Typography.readingBody)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundColor(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button("Try Again") {
                    summarizer.reset()
                    summarizer.summarize(transcriptionManager.liveTranscriptionText)
                }
                .secondaryGlassButton()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    // MARK: - Audio Player Bar

    private var audioPlayerBar: some View {
        HStack(spacing: 12) {
            // Play/pause
            Button(action: { audioPlayer.togglePlayPause() }) {
                Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)

            // Time
            Text(formatPlayerTime(audioPlayer.currentTime))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 50, alignment: .trailing)

            // Scrubber
            Slider(
                value: Binding(
                    get: { audioPlayer.currentTime },
                    set: { audioPlayer.seek(to: $0) }
                ),
                in: 0...max(audioPlayer.duration, 1)
            )
            .controlSize(.small)

            // Duration
            Text(formatPlayerTime(audioPlayer.duration))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 50, alignment: .leading)

            // Speed picker
            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button(action: { audioPlayer.setRate(Float(rate)) }) {
                        HStack {
                            Text("\(rate, specifier: rate == floor(rate) ? "%.0f" : "%.2g")x")
                            if Float(rate) == audioPlayer.playbackRate {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text("\(audioPlayer.playbackRate, specifier: audioPlayer.playbackRate == floor(audioPlayer.playbackRate) ? "%.0f" : "%.2g")x")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(4)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 40)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassSurface(cornerRadius: 0)
    }

    private func formatPlayerTime(_ time: TimeInterval) -> String {
        let m = Int(time) / 60
        let s = Int(time) % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            // Stats
            HStack(spacing: 14) {
                if wordCount > 0 {
                    Label("\(wordCount) words", systemImage: "textformat.size")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                if transcriptionManager.audioDuration > 0 {
                    Label(formattedDuration, systemImage: "clock")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                if !transcriptionManager.segments.isEmpty {
                    Label("\(transcriptionManager.segments.count) segments", systemImage: "list.number")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Copy
            if !transcriptionManager.liveTranscriptionText.isEmpty {
                Button(action: {
                    transcriptionManager.copyTranscriptionToClipboard()
                    showCopiedAlert = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        showCopiedAlert = false
                    }
                }) {
                    Label(showCopiedAlert ? "Copied!" : "Copy", systemImage: showCopiedAlert ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12))
                }
                .secondaryGlassButton()
                .controlSize(.small)
                .tint(showCopiedAlert ? .green : nil)

                // Export menu
                Menu {
                    ForEach(TranscriptionOutputFormat.allCases, id: \.self) { format in
                        Button(format.displayName) {
                            transcriptionManager.exportAs(format: format)
                        }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.system(size: 12))
                }
                .secondaryMenu()
                .controlSize(.small)
                .fixedSize()
            }

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Confidence Text Block

struct ConfidenceTextBlock: View {
    let segments: [TranscriptionSegmentData]
    let searchText: String
    var speakerNames: [String: String] = [:]

    private func displayName(_ s: String) -> String {
        let t = speakerNames[s]?.trimmingCharacters(in: .whitespaces)
        return (t?.isEmpty == false) ? t! : s
    }

    private func formatTimestamp(_ seconds: Float) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    var body: some View {
        let hasSpeakers = segments.contains { $0.speaker != nil }

        let textView = segments.enumerated().reduce(Text("")) { result, pair in
            let (index, segment) = pair
            let prefix = index > 0 ? Text("\n\n") : Text("")

            // Speaker label with timestamp when speaker changes
            var speakerLabel = Text("")
            if let speaker = segment.speaker {
                let prevSpeaker = index > 0 ? segments[index - 1].speaker : nil
                if speaker != prevSpeaker {
                    let color = SpeakerColors.color(for: speaker)
                    let timestamp = formatTimestamp(segment.start)
                    let name = displayName(speaker)
                    let labelText = index > 0 ? "\n\(name)  ·  \(timestamp)\n" : "\(name)  ·  \(timestamp)\n"
                    speakerLabel = Text(labelText).foregroundColor(color).font(.system(size: 13, weight: .bold))
                }
            }

            if segment.words.isEmpty {
                return result + prefix + speakerLabel + Text(segment.text)
                    .foregroundColor(.primary)
            } else {
                let segmentText = segment.words.reduce(Text("")) { wordResult, word in
                    let opacity = max(0.4, Double(word.probability))
                    let isHighlighted = !searchText.isEmpty &&
                        word.word.localizedCaseInsensitiveContains(searchText)
                    return wordResult + Text(word.word + " ")
                        .foregroundColor(isHighlighted ? .accentColor : .primary.opacity(opacity))
                        .fontWeight(isHighlighted ? .bold : .regular)
                }
                return result + prefix + speakerLabel + segmentText
            }
        }

        textView
            .font(.system(size: 14))
            .lineSpacing(hasSpeakers ? 4 : 6)
    }
}

// MARK: - Segment Row (MacWhisper-style)

struct SegmentRow: View {
    let segment: TranscriptionSegmentData
    let searchText: String
    let isEven: Bool
    var speakerNames: [String: String] = [:]
    var isActive: Bool = false
    var onTap: (() -> Void)?

    @State private var isHovered = false

    private func displayName(_ s: String) -> String {
        let t = speakerNames[s]?.trimmingCharacters(in: .whitespaces)
        return (t?.isEmpty == false) ? t! : s
    }

    // Accent colors for left border based on speaker or confidence
    private var accentColor: Color {
        if let speaker = segment.speaker {
            return SpeakerColors.color(for: speaker)
        }
        let c = segment.confidence
        if c > 0.8 { return .blue.opacity(0.6) }
        if c > 0.6 { return .blue.opacity(0.4) }
        return .orange.opacity(0.5)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left accent bar — thicker + full-strength while this segment plays
            Rectangle()
                .fill(isActive ? accentColor : accentColor.opacity(0.85))
                .frame(width: isActive ? 4 : 3)

            VStack(alignment: .leading, spacing: 4) {
                // Speaker label (if available)
                if let speaker = segment.speaker {
                    Text(displayName(speaker))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(SpeakerColors.color(for: speaker))
                }

                // Segment text
                highlightedText
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .textSelection(.enabled)

                // Timestamp
                Text(segment.formattedStart)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isActive
                ? Color.accentColor.opacity(0.14)
                : (isHovered
                    ? Color.accentColor.opacity(0.06)
                    : (isEven ? Color.white.opacity(0.03) : Color.clear))
        )
        .animation(.easeInOut(duration: 0.2), value: isActive)
        .onHover { isHovered = $0 }
        .onTapGesture {
            onTap?()
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var highlightedText: some View {
        if searchText.isEmpty {
            Text(segment.text)
                .foregroundColor(.primary)
        } else {
            let text = segment.text
            let range = text.range(of: searchText, options: .caseInsensitive)
            if let range = range {
                Text(text[text.startIndex..<range.lowerBound])
                    .foregroundColor(.primary) +
                Text(text[range])
                    .foregroundColor(.accentColor)
                    .fontWeight(.bold) +
                Text(text[range.upperBound..<text.endIndex])
                    .foregroundColor(.primary)
            } else {
                Text(text)
                    .foregroundColor(.primary)
            }
        }
    }
}

// MARK: - Waiting Animation View

struct WaitingAnimationView: View {
    var state: TranscriptionState = .transcribing(progress: 0)

    @State private var animating = false
    @State private var pulseOpacity: Double = 0.3

    private let barCount = 9
    private let barWidth: CGFloat = 5
    private let barSpacing: CGFloat = 6
    private let minHeight: CGFloat = 10
    private let maxHeight: CGFloat = 52

    private var titleText: String {
        switch state {
        case .downloadingAudio(let progress):
            return progress > 0 ? "Downloading audio... \(Int(progress * 100))%" : "Downloading audio…"
        case .loadingModel(let modelName):
            return modelName.isEmpty ? "Loading AI model…" : "Loading \(modelName) model…"
        case .extractingAudio:
            return "Extracting audio…"
        case .transcribing:
            return "Transcribing audio…"
        default:
            return "Preparing…"
        }
    }

    private var subtitleText: String {
        switch state {
        case .downloadingAudio:
            return "Fetching audio from the video URL"
        case .loadingModel:
            return "First load compiles the model — this can take a few minutes for larger models"
        case .extractingAudio:
            return "Converting to audio format for transcription"
        case .transcribing:
            return "Words will appear here in real time"
        default:
            return "Please wait…"
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.7), Color.accentColor.opacity(0.3)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: barWidth, height: animating ? randomHeight(index) : minHeight)
                        .animation(
                            Animation
                                .easeInOut(duration: 0.4 + Double(index) * 0.05)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.08),
                            value: animating
                        )
                }
            }
            .frame(height: maxHeight)

            VStack(spacing: 6) {
                Text(titleText)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.secondary)

                Text(subtitleText)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary.opacity(0.6))
                    .opacity(pulseOpacity)
                    .animation(
                        Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                        value: pulseOpacity
                    )
            }
        }
        .onAppear {
            animating = true
            pulseOpacity = 0.8
        }
        .onDisappear {
            animating = false
        }
    }

    private func randomHeight(_ index: Int) -> CGFloat {
        let heights: [CGFloat] = [0.5, 0.8, 1.0, 0.6, 0.9, 0.7, 0.4]
        let factor = heights[index % heights.count]
        return minHeight + (maxHeight - minHeight) * factor
    }
}

#Preview {
    TranscriptionResultView(
        transcriptionManager: TranscriptionManager.shared
    )
}
