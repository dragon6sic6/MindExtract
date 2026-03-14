import SwiftUI
import AppKit

// MARK: - Tab Selection

enum TranscriptionTab: String, CaseIterable {
    case text = "Text"
    case timeline = "Timeline"
}

struct TranscriptionResultView: View {
    @ObservedObject var transcriptionManager: TranscriptionManager
    var onClose: (() -> Void)?

    @State private var showCopiedAlert = false
    @State private var selectedTab: TranscriptionTab = .text
    @State private var searchText: String = ""
    @State private var showExportMenu = false

    private var isTranscribing: Bool {
        switch transcriptionManager.transcriptionState {
        case .extractingAudio, .transcribing, .loadingModel:
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
            headerView
            Divider()
            statusView
            tabBar
            Divider()

            // Main content
            Group {
                switch selectedTab {
                case .text:
                    textView
                case .timeline:
                    timelineView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            bottomBar
        }
        .frame(minWidth: 600, idealWidth: 750, maxWidth: 1000,
               minHeight: 500, idealHeight: 650, maxHeight: 900)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 1) {
                Text("Transcription")
                    .font(.headline)

                if !transcriptionManager.currentTranscriptionTitle.isEmpty {
                    Text(transcriptionManager.currentTranscriptionTitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button(action: {
                if !isTranscribing {
                    transcriptionManager.clearTranscription()
                    onClose?()
                }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isTranscribing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Status View

    @ViewBuilder
    private var statusView: some View {
        switch transcriptionManager.transcriptionState {
        case .loadingModel:
            statusBanner(icon: nil, text: "Loading AI model...", showSpinner: true, color: .blue)

        case .extractingAudio:
            statusBanner(icon: nil, text: "Extracting audio...", showSpinner: true, color: .blue)

        case .transcribing(let progress):
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Transcribing...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    if progress > 0 {
                        Text("\(Int(progress * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Button(action: { transcriptionManager.cancelTranscription() }) {
                        Image(systemName: "xmark.circle")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel transcription")
                }
                if progress > 0 {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.blue.opacity(0.06))

        case .completed:
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Transcription complete")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                if let path = transcriptionManager.lastSavedPath {
                    Button(action: {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }) {
                        Label("Show in Finder", systemImage: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.green.opacity(0.06))

        case .error(let message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.red.opacity(0.06))

        default:
            EmptyView()
        }
    }

    private func statusBanner(icon: String?, text: String, showSpinner: Bool, color: Color) -> some View {
        HStack(spacing: 10) {
            if showSpinner {
                ProgressView()
                    .scaleEffect(0.7)
            } else if let icon = icon {
                Image(systemName: icon)
                    .foregroundColor(color)
            }
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(color.opacity(0.06))
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(TranscriptionTab.allCases, id: \.self) { tab in
                Button(action: { selectedTab = tab }) {
                    VStack(spacing: 4) {
                        HStack(spacing: 5) {
                            Image(systemName: tab == .text ? "doc.text" : "list.bullet.rectangle")
                                .font(.caption)
                            Text(tab.rawValue)
                                .font(.subheadline)
                                .fontWeight(selectedTab == tab ? .semibold : .regular)
                        }
                        .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)

                        Rectangle()
                            .fill(selectedTab == tab ? Color.accentColor : Color.clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Search field
            if isCompleted || !transcriptionManager.segments.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .frame(width: 120)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .padding(.trailing, 16)
            }
        }
        .padding(.top, 6)
    }

    // MARK: - Text View (with confidence highlighting)

    private var textView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if transcriptionManager.liveTranscriptionText.isEmpty && isTranscribing {
                    WaitingAnimationView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .padding(32)
                } else if transcriptionManager.segments.isEmpty && !isTranscribing {
                    Text("Waiting for transcription...")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .padding(32)
                } else {
                    // Rich text with confidence-based highlighting
                    confidenceTextView
                        .padding(16)
                        .id("textBottom")
                }
            }
            .background(Color(NSColor.textBackgroundColor))
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
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
        } else {
            // Build an attributed text view with word-level confidence
            ConfidenceTextBlock(segments: segments, searchText: searchText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    // MARK: - Timeline View

    private var timelineView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if transcriptionManager.segments.isEmpty && isTranscribing {
                    WaitingAnimationView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .padding(32)
                } else if filteredSegments.isEmpty && !searchText.isEmpty {
                    Text("No results for \"\(searchText)\"")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredSegments) { segment in
                            SegmentRow(segment: segment, searchText: searchText)
                                .id(segment.id)
                        }
                    }
                    .padding(.vertical, 8)
                    .id("timelineBottom")
                }
            }
            .background(Color(NSColor.textBackgroundColor))
            .onChange(of: transcriptionManager.segments.count) { _ in
                if isTranscribing, let lastId = transcriptionManager.segments.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            // Stats
            HStack(spacing: 16) {
                if wordCount > 0 {
                    Label("\(wordCount) words", systemImage: "textformat.size")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if transcriptionManager.audioDuration > 0 {
                    Label(formattedDuration, systemImage: "clock")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if !transcriptionManager.segments.isEmpty {
                    Label("\(transcriptionManager.segments.count) segments", systemImage: "list.number")
                        .font(.caption)
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
                        .font(.caption)
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
                        .font(.caption)
                }
                .menuStyle(.borderedButton)
                .controlSize(.small)
            }

            // Done
            if isCompleted || hasError {
                Button(action: {
                    transcriptionManager.clearTranscription()
                    onClose?()
                }) {
                    Text("Done")
                        .font(.caption)
                        .frame(width: 60)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Confidence Text Block

struct ConfidenceTextBlock: View {
    let segments: [TranscriptionSegmentData]
    let searchText: String

    var body: some View {
        // Build text with per-word confidence coloring
        let textView = segments.reduce(Text("")) { result, segment in
            if segment.words.isEmpty {
                // No word-level data — show segment text normally
                return result + Text(segment.text + " ")
                    .foregroundColor(.primary)
            } else {
                // Word-level confidence coloring
                return segment.words.reduce(result) { wordResult, word in
                    let opacity = max(0.4, Double(word.probability))
                    let isHighlighted = !searchText.isEmpty &&
                        word.word.localizedCaseInsensitiveContains(searchText)
                    return wordResult + Text(word.word)
                        .foregroundColor(isHighlighted ? .accentColor : .primary.opacity(opacity))
                        .fontWeight(isHighlighted ? .bold : .regular)
                }
            }
        }

        textView
            .font(.system(.body, design: .default))
            .lineSpacing(4)
    }
}

// MARK: - Segment Row (Timeline)

struct SegmentRow: View {
    let segment: TranscriptionSegmentData
    let searchText: String

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Timestamp
            Text(segment.formattedStart)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.accentColor)
                .frame(width: 65, alignment: .trailing)

            // Confidence indicator
            Circle()
                .fill(confidenceColor)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
                .help("Confidence: \(Int(segment.confidence * 100))%")

            // Text
            VStack(alignment: .leading, spacing: 2) {
                if let speaker = segment.speaker {
                    Text(speaker)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.accentColor)
                }

                highlightedText
                    .font(.system(.callout))
                    .lineSpacing(2)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)

            // Duration badge
            Text(String(format: "%.1fs", segment.duration))
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
                .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(isHovered ? Color.primary.opacity(0.03) : Color.clear)
        .onHover { isHovered = $0 }
    }

    private var confidenceColor: Color {
        let c = segment.confidence
        if c > 0.75 { return .green }
        if c > 0.5 { return .yellow }
        return .orange
    }

    @ViewBuilder
    private var highlightedText: some View {
        if searchText.isEmpty {
            Text(segment.text)
                .foregroundColor(.primary)
        } else {
            // Highlight matching text
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
    @State private var animating = false
    @State private var pulseOpacity: Double = 0.3

    private let barCount = 7
    private let barWidth: CGFloat = 3.5
    private let barSpacing: CGFloat = 4
    private let minHeight: CGFloat = 6
    private let maxHeight: CGFloat = 32

    var body: some View {
        VStack(spacing: 20) {
            // Waveform bars
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

            // Pulsing text
            VStack(spacing: 6) {
                Text("Transcribing audio")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)

                Text("Words will appear here in real time")
                    .font(.caption)
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
        // Create varied heights based on index for natural waveform look
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
