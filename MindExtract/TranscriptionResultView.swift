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
}

// MARK: - Audio Player

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
                guard let self = self, let p = self.player else { return }
                DispatchQueue.main.async {
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

    deinit {
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
                HStack(spacing: 16) {
                    ForEach(speakersInSegments, id: \.self) { speaker in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(SpeakerColors.color(for: speaker))
                                .frame(width: 8, height: 8)
                            Text(speaker)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.4))

                Divider()
            }

            // Content area
            Group {
                switch selectedTab {
                case .text:
                    textView
                case .timeline:
                    timelineView
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
        .frame(minWidth: 600, idealWidth: 750, maxWidth: 1000,
               minHeight: 500, idealHeight: 650, maxHeight: 900)
        .background(Color(NSColor.windowBackgroundColor))
        .onChange(of: transcriptionManager.audioFilePath) { path in
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
            // Back / title area
            VStack(alignment: .leading, spacing: 2) {
                Text(transcriptionManager.currentTranscriptionTitle.isEmpty
                     ? "Transcription"
                     : transcriptionManager.currentTranscriptionTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }

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
            }

            // Close
            Button(action: {
                if !isTranscribing {
                    audioPlayer.stop()
                    transcriptionManager.clearTranscription()
                    onClose?()
                }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .disabled(isTranscribing)
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
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("Search transcription...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .offset(y: 20)
        .zIndex(1)
    }

    // MARK: - Tab Picker (Segmented)

    private var tabPicker: some View {
        HStack(spacing: 0) {
            ForEach(TranscriptionTab.allCases, id: \.self) { tab in
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab } }) {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                        .foregroundColor(selectedTab == tab ? .primary : .secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(
                            selectedTab == tab
                                ? Color(NSColor.controlBackgroundColor)
                                : Color.clear
                        )
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color(NSColor.separatorColor).opacity(0.2))
        .cornerRadius(7)
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
            .background(Color.blue.opacity(0.08))
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
                if progress > 0 {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Button("Cancel") {
                    transcriptionManager.cancelTranscription()
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundColor(.red.opacity(0.8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.blue.opacity(0.08))
            .cornerRadius(12)

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
        .background(Color.blue.opacity(0.08))
        .cornerRadius(12)
    }

    // MARK: - Status View (banners)

    @ViewBuilder
    private var statusView: some View {
        switch transcriptionManager.transcriptionState {
        case .downloadingAudio(let progress) where progress > 0:
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(.orange)
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
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.green.opacity(0.05))

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
            .background(Color.red.opacity(0.05))

        default:
            EmptyView()
        }
    }

    // MARK: - Text View

    private var textView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if transcriptionManager.liveTranscriptionText.isEmpty && isTranscribing {
                    WaitingAnimationView(state: transcriptionManager.transcriptionState)
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .padding(32)
                } else if transcriptionManager.segments.isEmpty && !isTranscribing && !isCompleted {
                    Text("Waiting for transcription...")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .padding(32)
                } else {
                    confidenceTextView
                        .padding(20)
                        .padding(.top, showSearch ? 16 : 0)
                        .id("textBottom")
                }
            }
            .onChange(of: transcriptionManager.segments.count) { _ in
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
            ConfidenceTextBlock(segments: segments, searchText: searchText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    // MARK: - Timeline View (MacWhisper style)

    private var timelineView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if transcriptionManager.segments.isEmpty && isTranscribing {
                    WaitingAnimationView(state: transcriptionManager.transcriptionState)
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .padding(32)
                } else if filteredSegments.isEmpty && !searchText.isEmpty {
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
            .onChange(of: transcriptionManager.segments.count) { _ in
                if isTranscribing, let lastId = transcriptionManager.segments.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
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
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
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
                .buttonStyle(.bordered)
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
                .menuStyle(.borderedButton)
                .controlSize(.small)
            }

            // Done
            if isCompleted || hasError {
                Button(action: {
                    audioPlayer.stop()
                    transcriptionManager.clearTranscription()
                    onClose?()
                }) {
                    Text("Done")
                        .font(.system(size: 12))
                        .frame(width: 50)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
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

    var body: some View {
        let textView = segments.enumerated().reduce(Text("")) { result, pair in
            let (index, segment) = pair
            let prefix = index > 0 ? Text("\n\n") : Text("")

            // Speaker label when speaker changes from previous segment
            var speakerLabel = Text("")
            if let speaker = segment.speaker {
                let prevSpeaker = index > 0 ? segments[index - 1].speaker : nil
                if speaker != prevSpeaker {
                    let color = SpeakerColors.color(for: speaker)
                    if index > 0 {
                        speakerLabel = Text("\n\(speaker)\n").foregroundColor(color).font(.system(size: 13, weight: .bold))
                    } else {
                        speakerLabel = Text("\(speaker)\n").foregroundColor(color).font(.system(size: 13, weight: .bold))
                    }
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
            .lineSpacing(6)
    }
}

// MARK: - Segment Row (MacWhisper-style)

struct SegmentRow: View {
    let segment: TranscriptionSegmentData
    let searchText: String
    let isEven: Bool
    var onTap: (() -> Void)?

    @State private var isHovered = false

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
            // Left accent bar
            Rectangle()
                .fill(accentColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                // Speaker label (if available)
                if let speaker = segment.speaker {
                    Text(speaker)
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
            isHovered
                ? Color.accentColor.opacity(0.06)
                : (isEven ? Color(NSColor.controlBackgroundColor).opacity(0.3) : Color.clear)
        )
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

    private let barCount = 7
    private let barWidth: CGFloat = 3.5
    private let barSpacing: CGFloat = 4
    private let minHeight: CGFloat = 6
    private let maxHeight: CGFloat = 32

    private var titleText: String {
        switch state {
        case .downloadingAudio(let progress):
            return progress > 0 ? "Downloading audio... \(Int(progress * 100))%" : "Downloading audio..."
        case .loadingModel(let modelName):
            return modelName.isEmpty ? "Loading AI model..." : "Loading \(modelName) model..."
        case .extractingAudio:
            return "Extracting audio..."
        case .transcribing:
            return "Transcribing audio..."
        default:
            return "Preparing..."
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
            return "Please wait..."
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
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)

                Text(subtitleText)
                    .font(.system(size: 12))
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
