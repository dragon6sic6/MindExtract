import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Flow Chips

/// A simple wrapping row of tappable chips (used for speaker-name suggestions).
struct FlowChips: View {
    let items: [String]
    let onTap: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button { onTap(item) } label: {
                    Text(item)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Minimal flow layout that wraps subviews to the available width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x - bounds.minX + size.width > maxWidth, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Speaker Colors

enum SpeakerColors {
    // Explicit vivid hues tuned for dark mode — several system colors
    // (purple, indigo, teal) read as muddy/low-contrast on a near-black surface.
    static let palette: [Color] = [
        Color(red: 0.20, green: 0.55, blue: 1.00),  // blue
        Color(red: 0.80, green: 0.40, blue: 1.00),  // magenta
        Color(red: 1.00, green: 0.60, blue: 0.10),  // orange
        Color(red: 0.15, green: 0.85, blue: 0.85),  // cyan
        Color(red: 1.00, green: 0.45, blue: 0.68),  // pink
        Color(red: 0.35, green: 0.88, blue: 0.42),  // green
        Color(red: 0.55, green: 0.58, blue: 1.00),  // periwinkle
        Color(red: 0.25, green: 0.92, blue: 0.72),  // turquoise
    ]

    static func color(for speaker: String) -> Color {
        if let num = Int(speaker.replacingOccurrences(of: "Speaker ", with: "")),
           num > 0 {
            return palette[(num - 1) % palette.count]
        }
        return .accentColor
    }

    /// Color for an arbitrary label (renamed speaker, "You", "Others"); uses the
    /// "Speaker N" hue when possible, else a stable per-index palette color.
    static func color(for speaker: String, fallbackIndex: Int) -> Color {
        if let num = Int(speaker.replacingOccurrences(of: "Speaker ", with: "")), num > 0 {
            return palette[(num - 1) % palette.count]
        }
        return palette[fallbackIndex % palette.count]
    }
}

// MARK: - Tab Selection

enum TranscriptionTab: String, CaseIterable {
    case text = "Text"
    case timeline = "Timeline"
    case summary = "Summary"
    case translate = "Translate"
    case chat = "Chat"
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
    // Index of the currently focused search match + the segment to scroll to.
    @State private var searchMatchIndex = 0
    @State private var searchScrollTarget: UUID?
    @State private var editingSpeaker: String?
    @State private var editingName: String = ""
    @State private var isEditingTranscript = false
    // Reminders export feedback, keyed per template-output toolbar.
    @State private var remindersStatus: String?
    @State private var remindersExporting = false
    // Per-transcript speaker-name suggestions (You + calendar attendees).
    @State private var speakerSuggestions: [String] = []
    // Meeting Brief support: bookmarked moments + attendee emails for the recap.
    @State private var markedMoments: [Double] = []
    @State private var attendeeEmails: [String] = []
    // Auto-generate meeting notes once, after a fresh meeting finishes.
    @State private var autoNotesPending = false
    @State private var autoNotesRunning = false
    @State private var autoNotesStatus: String?
    @State private var autoNotesTask: Task<Void, Never>?
    // Memoized talk-time insights — recomputed only when segments or names change,
    // not on every render (the audio timer redraws this view ~10×/s).
    @State private var cachedInsights: MeetingInsights?
    @ObservedObject private var summarizer = TranscriptSummarizer.shared
    @ObservedObject private var translator = TranscriptTranslator.shared
    @ObservedObject private var templateRunner = TemplateRunner.shared
    @ObservedObject private var templateStore = TemplateStore.shared
    @ObservedObject private var chat = TranscriptChat.shared
    // Summary tab doubles as an AI-template workspace. nil = the built-in Summary;
    // any other id = a PromptTemplate. Completed outputs are cached per template.
    @State private var selectedTemplateID: UUID? = nil
    @State private var templateOutputs: [String: TemplateOutput] = [:]
    // Raw notes the user jotted during a meeting recording (merged with transcript).
    @State private var userNotes: String?
    // Which template's Copy button is briefly showing "Copied" (scoped per id so
    // copying one template doesn't flash "Copied" on another).
    @State private var copiedTemplateID: UUID?
    // Non-nil while the template editor sheet is open (new or existing template).
    @State private var editingTemplate: PromptTemplate?
    @State private var editorTitle = "Template"
    // Target language for the Translate tab (default English). Persisted so the
    // user's usual target is remembered across transcripts.
    @AppStorage("translateTargetLanguage") private var translateTargetLanguage: String = TranscriptionResultView.defaultTargetCode
    /// Smart default target: the user's system language (if we support it),
    /// otherwise English. Avoids the common English→English no-op for users whose
    /// Mac is set to another language translating English content.
    private static var defaultTargetCode: String {
        let sys = Locale.current.language.languageCode?.identifier ?? "en"
        let supported = AppSettings.transcriptionLanguages.map(\.code)
        return supported.contains(sys) ? sys : "en"
    }
    // Free-typed target when "Other…" is chosen — any language the model supports.
    @AppStorage("translateCustomLanguage") private var translateCustomLanguage: String = ""
    @State private var translationCopied = false
    // Same UserDefaults key AppSettings uses, so switching here is instantly
    // reflected by AIBackends.current() on the next question.
    @AppStorage("aiBackend") private var aiBackend: AIBackendChoice = .apple
    @State private var summaryCopied = false
    @State private var chatInput = ""

    /// Chat needs a (partial) transcript to talk about, so it only joins the tab
    /// strip once transcription has produced something — matching the old gate.
    private var chatAvailable: Bool {
        isCompleted || !transcriptionManager.segments.isEmpty
    }

    /// Honest privacy line for AI features — only claim on-device when the chosen
    /// backend actually is on-device; otherwise name where the data goes.
    private var aiPrivacyNote: String {
        switch aiBackend {
        case .apple, .ollama:
            return "With Apple Intelligence or Ollama it runs entirely on your Mac."
        default:
            return "Your selected provider (\(AIBackends.current().badge)) processes the text in the cloud."
        }
    }

    private var availableTabs: [TranscriptionTab] {
        TranscriptionTab.allCases.filter { $0 != .chat || chatAvailable }
    }

    private func commitRename(for speaker: String) {
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        transcriptionManager.speakerNameOverrides[speaker] = trimmed.isEmpty ? nil : trimmed
        editingSpeaker = nil
        persistAISidecar()   // remember the name across reopen
    }

    /// Recompute the memoized talk-time insights (cheap to call; O(n) over segments).
    private func refreshInsights() {
        cachedInsights = MeetingInsights.compute(from: transcriptionManager.segments,
                                                 displayName: transcriptionManager.speakerDisplayName)
    }

    /// Whether a template's output is a task list worth pushing to Reminders.
    private func isActionItemsTemplate(_ template: PromptTemplate) -> Bool {
        template.id == PromptTemplateLibrary.actionItemsID
    }

    /// Transcript as (speaker, timestamp, text) rows, optionally PII-redacted.
    private func transcriptParagraphs(redacted: Bool) -> [(speaker: String?, time: String?, text: String)] {
        let known = Array(transcriptionManager.speakerNameOverrides.values)
        let segs = transcriptionManager.segments
        if segs.isEmpty {
            var t = transcriptionManager.liveTranscriptionText
            if redacted { t = Redactor.redact(t, knownNames: known) }
            return [(nil, nil, t)]
        }
        return segs.map { seg in
            let sp = seg.speaker.map { transcriptionManager.speakerDisplayName($0) }
            var text = seg.text
            if redacted { text = Redactor.redact(text, knownNames: known) }
            return (sp, seg.formattedStart, text)
        }
    }

    private func exportTranscriptPDF(redacted: Bool) {
        let title = transcriptionManager.currentTranscriptionTitle.isEmpty ? "Transcript" : transcriptionManager.currentTranscriptionTitle
        // Only attach AI sections to a non-redacted PDF (a summary could re-leak
        // names). templateOutputs are intentionally not exported to PDF; if added
        // later, gate them with !redacted for the same reason.
        var extras: [(String, String)] = []
        if !redacted, let s = summarizer.currentSummary { extras.append(("Summary", s)) }
        let notice = redacted ? "Automatically redacted on-device. Name detection can miss names — especially in non-English text. Review before sharing." : nil
        let brand = AppSettings.shared.brandName
        let logo = PDFExporter.logoDataURI(path: AppSettings.shared.brandLogoPath)
        let html = PDFExporter.transcriptHTML(title: title,
                                              paragraphs: transcriptParagraphs(redacted: redacted),
                                              extraSections: extras,
                                              notice: notice,
                                              brandName: brand.isEmpty ? nil : brand,
                                              logoDataURI: logo)
        PDFExporter.shared.makePDF(html: html) { @MainActor data in
            guard let data else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = title + (redacted ? " (Redacted).pdf" : ".pdf")
            if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
        }
    }

    private func exportRedactedText() {
        let body = transcriptParagraphs(redacted: true).map { p in
            (p.speaker.map { "\($0): " } ?? "") + p.text
        }.joined(separator: "\n\n")
        transcriptionManager.exportPlainText(body, filenameSuffix: " (Redacted)")
    }

    // MARK: - Meeting Brief

    @ViewBuilder
    private func meetingBriefCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles.rectangle.stack").foregroundStyle(DS.Colors.accent)
                Text("Meeting Brief").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.plain).help("Copy brief")
            }
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("## ") {
                    Text(line.dropFirst(3))
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                        .padding(.top, 4)
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(line).font(DS.Typography.readingBody).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !markedMoments.isEmpty {
                Divider().opacity(0.4)
                Text("Key moments").font(.caption2).foregroundColor(.secondary)
                FlowChips(items: markedMoments.map(Self.timeLabel)) { label in
                    if let i = markedMoments.firstIndex(where: { Self.timeLabel($0) == label }) {
                        audioPlayer.seek(to: markedMoments[i])
                        if !audioPlayer.isPlaying { audioPlayer.togglePlayPause() }
                    }
                }
            }
            Divider().opacity(0.4)
            HStack(spacing: 8) {
                Button {
                    exportToReminders(Self.briefSection(text, "Action items"),
                                      meetingTitle: transcriptionManager.currentTranscriptionTitle)
                } label: {
                    if remindersExporting {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Adding…") }
                    } else {
                        Label(remindersStatus ?? "Add to Reminders", systemImage: remindersStatus != nil ? "checkmark" : "checklist")
                    }
                }
                .secondaryGlassButton().controlSize(.small).disabled(remindersExporting)
                Button { sendRecapEmail(brief: text) } label: {
                    Label("Email recap", systemImage: "envelope").font(.caption)
                }
                .secondaryGlassButton().controlSize(.small)
                Spacer()
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.Colors.accent.opacity(0.25), lineWidth: 1))
    }

    private static func timeLabel(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // Fallback header aliases in case a smaller model translates the section
    // header despite the English-header instruction.
    private static let actionItemsAliases: Set<String> = [
        "action items", "åtgärdspunkter", "aktionspunkter", "att göra",
        "action points", "maßnahmen", "aufgaben", "tâches", "points d'action",
        "acciones", "tareas", "azioni", "punti d'azione"
    ]

    /// Lines under a "## <header>" section of the brief, up to the next header.
    private static func briefSection(_ text: String, _ header: String) -> String {
        var out: [String] = []
        var inSection = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                let h = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                let isMatch = h.caseInsensitiveCompare(header) == .orderedSame
                    || (header == "Action items" && actionItemsAliases.contains(h.lowercased()))
                inSection = isMatch
                continue
            }
            if inSection { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    /// Open a Mail compose with the recap pre-filled, addressed to attendees.
    private func sendRecapEmail(brief: String) {
        let title = transcriptionManager.currentTranscriptionTitle
        let subject = "Recap: \(title.isEmpty ? "Meeting" : title)"
        let body = "Hi,\n\nHere's a quick recap of \(title.isEmpty ? "our meeting" : title):\n\n\(brief)\n\n— Sent from MindExtract"
        if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [body]) {
            service.subject = subject
            service.recipients = attendeeEmails
            service.perform(withItems: [body])
        } else {
            // No NSSharingService mail compose — fall back to a mailto: with the
            // recap in the body (also on the clipboard in case a client truncates it).
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body, forType: .string)
            let to = attendeeEmails.joined(separator: ",")
            let encSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let encBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "mailto:\(to)?subject=\(encSubject)&body=\(encBody)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Parse action items from the output and create one reminder each.
    private func exportToReminders(_ output: String, meetingTitle: String) {
        let items = RemindersExporter.parseActionItems(output)
        guard !items.isEmpty else {
            remindersStatus = "Nothing to add"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { remindersStatus = nil }
            return
        }
        remindersExporting = true
        Task {
            do {
                let n = try await RemindersExporter.shared.export(items: items, meetingTitle: meetingTitle)
                remindersStatus = "Added \(n)"
            } catch {
                remindersStatus = "Failed"
                appLog("[MindExtract] Reminders export failed: \(error.localizedDescription)")
            }
            remindersExporting = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { remindersStatus = nil }
        }
    }

    /// Name suggestions for the rename popover: calendar attendees from the
    /// recorded meeting that aren't already assigned to another speaker.
    private func nameSuggestions(for speaker: String) -> [String] {
        let taken = Set(transcriptionManager.speakerNameOverrides
            .filter { $0.key != speaker }
            .values
            .map { $0.trimmingCharacters(in: .whitespaces) })
        return speakerSuggestions
            .filter { !$0.isEmpty && !taken.contains($0) }
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

    /// Segments that match the active search, in order — drives the result
    /// count and next/previous navigation.
    private var searchMatches: [TranscriptionSegmentData] {
        searchText.isEmpty ? [] : filteredSegments
    }

    /// Move to the next/previous match: wrap around, scroll the Timeline to it,
    /// and switch to the Timeline tab (where segments have scroll anchors).
    private func stepSearch(_ delta: Int) {
        let matches = searchMatches
        guard !matches.isEmpty else { return }
        searchMatchIndex = ((searchMatchIndex + delta) % matches.count + matches.count) % matches.count
        if selectedTab != .timeline { selectedTab = .timeline }
        searchScrollTarget = matches[searchMatchIndex].id
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Search row — a real row in the flow (pushes content down) rather
            // than an overlay floating over the status banner + speaker legend.
            if showSearch {
                searchBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Status banner (only when active)
            statusView

            // Speaker legend (shown when diarization data is present)
            let speakersInSegments = Array(Set(transcriptionManager.segments.compactMap { $0.speaker })).sorted()
            if !speakersInSegments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                  HStack(spacing: 16) {
                    // Hints that the chips are editable (rename was easy to miss).
                    Text("^[\(speakersInSegments.count) speaker](inflect: true) · click to rename")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.6))
                        .chromeText()
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
                                    .foregroundColor(.secondary.opacity(0.7))
                            }
                        }
                        .contentShape(Rectangle())
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
                                // Quick-pick from calendar attendees (+ "You").
                                let suggestions = nameSuggestions(for: speaker)
                                if !suggestions.isEmpty {
                                    Text("Suggestions")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    FlowChips(items: suggestions) { name in
                                        editingName = name
                                        commitRename(for: speaker)
                                    }
                                    .frame(width: 190)
                                }
                                HStack {
                                    Button("Reset") {
                                        transcriptionManager.speakerNameOverrides[speaker] = nil
                                        editingSpeaker = nil
                                        persistAISidecar()   // make the reset stick across reopen
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

            // Content area — every view (incl. full-screen Chat) is a tab, so
            // navigation is uniform. The AI already has the transcript, so Chat
            // lets you ask *about* it; tap another tab to jump back to reading.
            Group {
                switch selectedTab {
                case .text:
                    textView
                case .timeline:
                    timelineView
                case .summary:
                    summaryView
                case .translate:
                    translateView
                case .chat:
                    chatFullView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Audio player bar (stays available even while chatting)
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
            // Chat lifecycle lives at the root so it works regardless of tab.
            chat.prepare(transcript: transcriptionManager.liveTranscriptionText)
            restoreAISidecar()
            refreshInsights()
        }
        .onChange(of: summarizer.state) { _, _ in persistAISidecar() }
        .onChange(of: translator.state) { _, _ in persistAISidecar() }
        .onChange(of: transcriptionManager.lastSavedPath) { _, path in
            if path != nil { persistAISidecar() }   // persist notes/AI once the transcript file exists
        }
        .onChange(of: templateRunner.state) { _, newState in
            // Cache a finished template output (keyed by template) and persist it.
            if case .done(let output) = newState, let id = templateRunner.activeTemplateID {
                templateOutputs[id.uuidString] = TemplateOutput(text: output, badge: templateRunner.resultBadge)
                persistAISidecar()
            }
        }
        // A meeting may still be transcribing when the result view opens — kick
        // off auto-notes once it completes.
        .onChange(of: transcriptionManager.transcriptionState) { _, _ in
            maybeAutoGenerateMeetingNotes()
        }
        // Retry auto-notes if the user configures an AI provider after the fact.
        .onChange(of: aiBackend) { _, _ in
            maybeAutoGenerateMeetingNotes()
        }
        // Recompute talk-time insights only when the underlying data changes.
        .onChange(of: transcriptionManager.segments.count) { _, _ in refreshInsights() }
        .onChange(of: transcriptionManager.speakerNameOverrides) { _, _ in refreshInsights() }
        .onChange(of: chat.messages) { _, _ in persistAISidecar() }
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
        .onDisappear {
            audioPlayer.stop()
            autoNotesTask?.cancel()
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isTranscribing)
            .help(isTranscribing ? "Available when transcription finishes" : "Back to transcripts")
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

            // Tab switcher (pill style) — includes Chat as a uniform tab.
            tabPicker

            // ⌘L jumps to the Chat tab (kept as a shortcut now that the
            // standalone Chat button is gone).
            if chatAvailable {
                Button("") { withAnimation(.easeInOut(duration: 0.15)) { selectedTab = .chat } }
                    .buttonStyle(.plain)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .keyboardShortcut("l", modifiers: .command)
                    .accessibilityLabel("Chat with transcript")
            }

            // Re-transcribe in another language — for when it came out wrong.
            if isCompleted, transcriptionManager.audioFilePath != nil {
                Menu {
                    Button("Auto-detect") { transcriptionManager.retranscribe(language: "auto") }
                    Divider()
                    ForEach(AppSettings.transcriptionLanguages.filter { $0.code != "auto" }, id: \.code) { lang in
                        Button(lang.name) { transcriptionManager.retranscribe(language: lang.code) }
                    }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 14))
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(isTranscribing)
                .help("Re-transcribe in another language")
            }

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
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: .command)
                .help("Search transcript (⌘F)")
            }

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            SearchField(text: $searchText)
                .background(DS.Colors.backdrop, in: Capsule())

            if !searchText.isEmpty {
                // Result count + next/previous navigation.
                Text(searchMatches.isEmpty
                     ? "No results"
                     : "\(searchMatchIndex + 1) of \(searchMatches.count)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .chromeText()

                Button { stepSearch(-1) } label: {
                    Image(systemName: "chevron.up").font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(searchMatches.isEmpty)
                .help("Previous match (⇧⌘G)")
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Button { stepSearch(1) } label: {
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(searchMatches.isEmpty)
                .help("Next match (⌘G)")
                .keyboardShortcut("g", modifiers: .command)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showSearch = false; searchText = "" }
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .keyboardShortcut(.cancelAction)
            .help("Close search (Esc)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(DS.Colors.backdrop)
        .overlay(alignment: .bottom) { Divider() }
        .onChange(of: searchText) { _, _ in searchMatchIndex = 0 }
    }

    // MARK: - Tab Picker (Segmented)

    private var tabPicker: some View {
        HStack(spacing: 0) {
            ForEach(availableTabs, id: \.self) { tab in
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab } }) {
                    let isActiveTab = selectedTab == tab
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: isActiveTab ? .semibold : .regular))
                        .foregroundColor(isActiveTab ? .primary : .secondary)
                        .chromeText()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(
                            isActiveTab
                                ? Color.white.opacity(0.12)
                                : Color.clear
                        )
                        .cornerRadius(6)
                        // Whole padded chip is clickable, not just the glyphs —
                        // a transparent background isn't hit-testable on its own.
                        .contentShape(Rectangle())
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
            progressBanner(progress, tint: DS.Colors.accent)

        case .transcribing(let progress) where progress > 0:
            progressBanner(progress, tint: .accentColor)

        case .completed:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.green)
                Text("Transcription complete")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                // Run a recipe (Brief → format → reminders → recap → export → hand to AI).
                if !RecipeStore.shared.recipes.isEmpty, transcriptionManager.lastSavedPath != nil {
                    Menu {
                        ForEach(RecipeStore.shared.recipes) { r in
                            Button { runRecipe(r) } label: { Text("\(r.name)  ·  \(r.summary)") }
                        }
                    } label: {
                        Label("Run recipe", systemImage: "wand.and.stars").font(.system(size: 12))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Run a saved recipe on this transcript")
                }
                // Wrong language? Re-run on the same audio in one click.
                if transcriptionManager.canRetranscribe {
                    Menu {
                        Button("Auto-detect") { transcriptionManager.retranscribe(language: "auto") }
                        Divider()
                        ForEach(AppSettings.transcriptionLanguages.filter { $0.code != "auto" }, id: \.code) { lang in
                            Button(lang.name) { transcriptionManager.retranscribe(language: lang.code) }
                        }
                    } label: {
                        Label("Re-transcribe", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 12))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Came out in the wrong language? Run it again.")
                }
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

    // A self-contained progress banner: solid background + its own divider so
    // the scrolling transcript below never butts up against (or shows through)
    // the thin progress line.
    @ViewBuilder
    private func progressBanner(_ progress: Double, tint: Color) -> some View {
        VStack(spacing: 0) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(tint)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(DS.Colors.backdrop)
            Divider()
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
                        // Cap line length for comfortable reading, but anchor the
                        // column to the left (matches the Timeline tab and reads
                        // naturally for speaker-labelled transcripts) instead of
                        // floating it centered with a big left margin.
                        .frame(maxWidth: 820, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                    // Edit-transcript toggle (correct mis-transcriptions inline).
                    if isCompleted && !transcriptionManager.segments.isEmpty {
                        HStack {
                            if isEditingTranscript {
                                Text("Editing — tap a line to fix it, press Return to save")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button {
                                isEditingTranscript.toggle()
                            } label: {
                                Label(isEditingTranscript ? "Done" : "Edit transcript",
                                      systemImage: isEditingTranscript ? "checkmark" : "pencil")
                                    .font(.caption)
                            }
                            .secondaryGlassButton().controlSize(.small)
                            .disabled(!searchText.isEmpty)   // editing a filtered subset is confusing
                        }
                        .padding(.horizontal, 16).padding(.top, 10)
                    }
                    // Talk-time insights (shown when 2+ speakers are present and
                    // we're not mid-search), from the memoized computation.
                    if searchText.isEmpty, !isTranscribing, !isEditingTranscript, let insights = cachedInsights {
                        MeetingInsightsCard(insights: insights)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                    }
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
                                },
                                isEditing: isEditingTranscript,
                                onCommitEdit: { transcriptionManager.updateSegmentText(id: segment.id, to: $0) }
                            )
                            .id(segment.id)
                        }
                    }
                    .padding(.top, 4)
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
            .onChange(of: searchScrollTarget) { _, target in
                // Jump to the current search match (next/previous buttons).
                if let target {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Summary & Ask (on-device AI, macOS 26+)

    // Summary tab now shows ONLY the AI summary — chat moved to a global panel
    // (chatPanel) available from every tab.
    private var summaryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let status = autoNotesStatus {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(status).font(.caption).foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DS.Colors.accent.opacity(0.08)))
                }
                // One canonical output. The format picker ("Summarize as…") chooses
                // how it's shaped; the Brief is the default. We NEVER show the Brief
                // next to an empty "Generate Summary" — that double-message was the mess.
                templatePickerBar
                if let notes = userNotes, !notes.isEmpty {
                    meetingNotesCard(notes)
                }
                if selectedTemplateID == PromptTemplateLibrary.polishNotes.id {
                    templateSection(PromptTemplateLibrary.polishNotes, inputText: combinedNotesInput(userNotes ?? ""))
                } else if let id = selectedTemplateID, let template = templateStore.template(id: id) {
                    templateSection(template, inputText: transcriptionManager.liveTranscriptionText)
                } else if let brief = templateOutputs[PromptTemplateLibrary.meetingBriefID.uuidString] {
                    // Default format: the Brief (canonical).
                    meetingBriefCard(brief.text)
                } else {
                    // No brief yet (e.g. a non-meeting transcript, or AI not configured):
                    // a single, calm generate path — not a second competing surface.
                    summarySection
                }
            }
            .padding(20)
        }
        .sheet(item: $editingTemplate) { draft in
            TemplateEditorView(
                template: draft,
                title: editorTitle,
                transcript: transcriptionManager.liveTranscriptionText,
                onSave: { saved in
                    templateStore.save(saved)
                    selectedTemplateID = saved.id
                    editingTemplate = nil
                },
                onDelete: templateStore.isUserTemplate(draft.id) ? {
                    templateStore.delete(id: draft.id)
                    templateOutputs[draft.id.uuidString] = nil
                    if selectedTemplateID == draft.id { selectedTemplateID = nil }
                    editingTemplate = nil
                    persistAISidecar()   // drop the deleted template's cached output from disk too
                } : nil,
                onCancel: { editingTemplate = nil }
            )
        }
    }

    /// Lets the Summary tab run any AI template (Meeting Minutes, SOAP Note, …)
    /// plus the user's own. "Summary" is the default (nil) dedicated path.
    private var templatePickerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 13))
                .foregroundStyle(DS.Colors.accent)
            Menu {
                Button { selectedTemplateID = nil } label: {
                    Label("Brief", systemImage: "sparkles")
                }
                Section("Summarize as") {
                    ForEach(PromptTemplateLibrary.builtIns) { t in
                        Button { selectedTemplateID = t.id } label: {
                            Label(t.name, systemImage: t.icon)
                        }
                    }
                }
                if !templateStore.userTemplates.isEmpty {
                    Section("My Templates") {
                        ForEach(templateStore.userTemplates) { t in
                            Button { selectedTemplateID = t.id } label: {
                                Label(t.name, systemImage: t.icon)
                            }
                        }
                    }
                }
                Divider()
                Button { editorTitle = "New Template"; editingTemplate = blankTemplate() } label: {
                    Label("New Template…", systemImage: "plus")
                }
                if let id = selectedTemplateID, let current = templateStore.template(id: id) {
                    if templateStore.isUserTemplate(id) {
                        Button { editorTitle = "Edit Template"; editingTemplate = current } label: {
                            Label("Edit “\(current.name)”…", systemImage: "pencil")
                        }
                    }
                    Button { editorTitle = "Duplicate Template"; editingTemplate = duplicate(of: current) } label: {
                        Label("Duplicate “\(current.name)”…", systemImage: "plus.square.on.square")
                    }
                    if templateStore.isUserTemplate(id) {
                        Button(role: .destructive) {
                            templateStore.delete(id: id)
                            templateOutputs[id.uuidString] = nil
                            selectedTemplateID = nil
                            persistAISidecar()
                        } label: {
                            Label("Delete “\(current.name)”", systemImage: "trash")
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(selectedTemplateName)
                        .font(.system(size: 13, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 10))
                }
            }
            .secondaryMenu()
            .fixedSize()
            Spacer()
        }
    }

    private var selectedTemplateName: String {
        guard let id = selectedTemplateID else { return "Brief" }
        return templateStore.template(id: id)?.name ?? "Brief"
    }

    private func blankTemplate() -> PromptTemplate {
        PromptTemplate(id: UUID(), name: "", icon: "wand.and.stars",
                       instructions: "You are a helpful assistant working from a transcript. Be accurate, never invent content, and answer in the same language as the transcript.",
                       task: "", builtIn: false)
    }

    private func duplicate(of t: PromptTemplate) -> PromptTemplate {
        PromptTemplate(id: UUID(), name: "\(t.name) copy", icon: t.icon,
                       instructions: t.instructions, task: t.task, builtIn: false)
    }

    /// Card shown atop the Notes tab when the user jotted notes during recording.
    private func meetingNotesCard(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Your meeting notes", systemImage: "pencil.line")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button {
                    selectedTemplateID = PromptTemplateLibrary.polishNotes.id
                } label: {
                    Label("Polish with transcript", systemImage: "wand.and.stars")
                }
                .secondaryGlassButton().controlSize(.small)
            }
            Text(notes)
                .font(.system(size: 13)).foregroundColor(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.Colors.hairline, lineWidth: 1))
    }

    /// Feeds the polish action both the user's notes and the transcript.
    private func combinedNotesInput(_ notes: String) -> String {
        "MY ROUGH NOTES:\n\(notes)\n\nFULL TRANSCRIPT:\n\(transcriptionManager.liveTranscriptionText)"
    }

    // MARK: - Translate Tab

    /// Common translation targets — the curated language list minus "auto".
    /// "Other…" (below) lets the user type ANY language the AI model supports.
    private var translateLanguages: [(name: String, code: String)] {
        AppSettings.transcriptionLanguages.filter { $0.code != "auto" }
    }

    /// The human-readable target language passed to the translator: either a
    /// picked language's name, or the free-typed custom language.
    private var translateTargetName: String {
        if translateTargetLanguage == "custom" {
            let t = translateCustomLanguage.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? "English" : t
        }
        return translateLanguages.first { $0.code == translateTargetLanguage }?.name ?? "English"
    }

    /// Whether we have a valid target to translate into (custom needs text).
    private var hasValidTranslateTarget: Bool {
        translateTargetLanguage != "custom"
            || !translateCustomLanguage.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// On-device models translate in many small sequential passes, so long
    /// transcripts genuinely take several minutes — set expectations honestly.
    private var translateDurationHint: String {
        aiBackend == .apple
            ? "On-device translation runs in short passes — a long transcript can take several minutes."
            : "Long transcripts are translated in parts — this can take a minute."
    }

    private var translateView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                translateSection
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var translateSection: some View {
        switch translator.state {
        case .idle:
            VStack(spacing: 16) {
                Image(systemName: "globe")
                    .font(.system(size: 40))
                    .foregroundStyle(DS.Colors.accent)
                Text("Translate this transcript")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Translate the full transcript into another language using your selected AI model. \(aiPrivacyNote)")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                HStack(spacing: 8) {
                    Text("Into")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    Picker("", selection: $translateTargetLanguage) {
                        ForEach(translateLanguages, id: \.code) { Text($0.name).tag($0.code) }
                        Divider()
                        Text("Other…").tag("custom")
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
                if translateTargetLanguage == "custom" {
                    TextField("Language (e.g. Norwegian, Polish, Thai…)", text: $translateCustomLanguage)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }
                Button {
                    translator.translate(transcriptionManager.liveTranscriptionText, into: translateTargetName)
                } label: {
                    Label("Translate", systemImage: "globe")
                }
                .primaryGlassButton()
                .disabled(transcriptionManager.liveTranscriptionText.isEmpty || isTranscribing || !hasValidTranslateTarget)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)

        case .working(let message):
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(translateDurationHint)
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)
                Button("Cancel") { translator.cancel() }
                    .secondaryGlassButton()
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)

        case .done(let translation):
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    // Badge shows the model that ACTUALLY produced this result
                    // (captured at completion), not the currently-selected one.
                    Label(translator.resultBadge.isEmpty ? translateTargetName : "\(translateTargetName) · \(translator.resultBadge)", systemImage: "globe")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(translation, forType: .string)
                        translationCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { translationCopied = false }
                    } label: {
                        Label(translationCopied ? "Copied" : "Copy", systemImage: translationCopied ? "checkmark" : "doc.on.doc")
                    }
                    .secondaryGlassButton()
                    // Re-translate into a different language (Export lives in the
                    // bottom bar's Export menu, the single hub for all output).
                    Menu {
                        ForEach(translateLanguages, id: \.code) { lang in
                            Button(lang.name) {
                                translateTargetLanguage = lang.code
                                translator.reset()
                                translator.translate(transcriptionManager.liveTranscriptionText, into: lang.name)
                            }
                        }
                        Divider()
                        Button("Other…") {
                            // Back to the CTA so the custom-language field shows.
                            translateTargetLanguage = "custom"
                            translator.reset()
                        }
                    } label: {
                        Label("Change Language", systemImage: "globe")
                    }
                    .secondaryMenu()
                    .frame(width: 165)
                }
                Text(translation)
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
                    translator.reset()
                    translator.translate(transcriptionManager.liveTranscriptionText, into: translateTargetName)
                }
                .secondaryGlassButton()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    // MARK: - Chat (full content view, available from any tab)

    /// A roomy, dedicated chat. The AI already has the transcript, so you ask
    /// *about* it here and tap a tab to jump back to reading.
    private var chatFullView: some View {
        VStack(spacing: 0) {
            if !chat.messages.isEmpty {
                HStack {
                    Spacer()
                    Button("Clear") { chat.reset() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundColor(.accentColor)
                        .help("Clear this conversation")
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if chat.messages.isEmpty {
                            chatEmptyState
                        } else {
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
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    // Keep a comfortable reading column on wide windows.
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity, alignment: chat.messages.isEmpty ? .center : .leading)
                }
                .onChange(of: chat.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("chatBottom", anchor: .bottom)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            askBar
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Welcoming empty state — centered, with suggestions.
    private var chatEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "ellipsis.bubble")
                .font(.system(size: 40))
                .foregroundStyle(DS.Colors.accent.opacity(0.8))
            VStack(spacing: 6) {
                Text("Chat with this transcript")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Ask anything — the AI answers from the transcript.")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            if !transcriptionManager.segments.isEmpty && !isTranscribing {
                suggestedQuestions
                    .frame(maxWidth: 460)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: - Ask bar

    /// Whether a provider is usable right now (has its key / model / is on-device).
    private func providerReady(_ choice: AIBackendChoice) -> Bool {
        switch choice {
        case .apple: return true   // on-device; fails gracefully if AI is off
        case .ollama: return !AppSettings.shared.ollamaModel.isEmpty
        case .custom:
            return !AppSettings.shared.customBaseURL.isEmpty
                && !(KeychainHelper.get("custom-api-key") ?? "").isEmpty
        default:
            guard let kc = choice.keychainKey else { return true }
            return !(KeychainHelper.get(kc) ?? "").isEmpty
        }
    }

    /// Menu label that tells the user which providers are set up.
    private func providerMenuLabel(_ choice: AIBackendChoice) -> String {
        if providerReady(choice) {
            if choice == .ollama { return "Ollama · \(AppSettings.shared.ollamaModel)" }
            return choice.shortName
        }
        switch choice {
        case .ollama: return "Ollama — start Ollama / pick a model in Settings"
        case .custom: return "Custom — set endpoint + key in Settings"
        case .apple: return choice.shortName
        default: return "\(choice.shortName) — add API key in Settings"
        }
    }

    private var askBar: some View {
        HStack(spacing: 8) {
            // In-chat AI model switcher — swap providers without leaving the
            // conversation. Each row shows whether it's ready to use.
            Menu {
                Picker("AI model", selection: $aiBackend) {
                    ForEach(AIBackendChoice.allCases) { choice in
                        Text(providerMenuLabel(choice)).tag(choice)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: providerReady(aiBackend) ? "cpu" : "exclamationmark.triangle.fill")
                    Text(aiBackend.shortName)
                        .chromeText()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .opacity(0.7)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(providerReady(aiBackend) ? Color.secondary : Color.orange)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(DS.Colors.inputFill, in: Capsule())
                .overlay(Capsule().strokeBorder(providerReady(aiBackend) ? DS.Colors.inputStroke : Color.orange.opacity(0.5), lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(providerReady(aiBackend) ? "AI model — switch provider for answers" : "\(aiBackend.shortName) isn't set up — pick a ready model or configure it in Settings")

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
            .contentShape(Circle())
            .buttonStyle(.plain)
            .disabled(chatInput.trimmingCharacters(in: .whitespaces).isEmpty || chat.isAnswering)
            .help("Ask")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func sendQuestion() {
        let q = chatInput
        chatInput = ""
        chat.prepare(transcript: transcriptionManager.liveTranscriptionText)
        chat.ask(q)
    }

    /// Load any saved summary + chat for this transcript and bind the AI
    /// singletons to it (they're shared across transcripts).
    private func restoreAISidecar() {
        let saved = transcriptionManager.lastSavedPath.flatMap { TranscriptAIStore.load(for: $0) }
        summarizer.bind(toText: transcriptionManager.liveTranscriptionText,
                        restoredSummary: saved?.summary)
        translator.bind(toText: transcriptionManager.liveTranscriptionText)
        if let savedTranslation = saved?.translation, !savedTranslation.isEmpty {
            if let code = saved?.translationLanguageCode { translateTargetLanguage = code }
            translator.restore(translation: savedTranslation,
                               forText: transcriptionManager.liveTranscriptionText)
        }
        // Template outputs are view-side cache; reset to this transcript's saved
        // set and clear the selection so a previous transcript's template (and
        // its cached output) can't bleed into this one.
        templateOutputs = saved?.templateOutputs ?? [:]
        selectedTemplateID = nil
        templateRunner.reset()
        // Live meeting notes: consume the just-recorded ones, else restore saved.
        if let pending = transcriptionManager.pendingMeetingNotes {
            userNotes = pending
            transcriptionManager.pendingMeetingNotes = nil
        } else {
            userNotes = saved?.userNotes
        }
        if let chatMessages = saved?.chat { chat.restore(messages: chatMessages) }
        // Restore custom speaker names assigned in a previous session.
        transcriptionManager.speakerNameOverrides = saved?.speakerNames ?? [:]
        // Consume just-recorded suggestions (You + attendees); else restore saved.
        if !transcriptionManager.pendingSpeakerSuggestions.isEmpty {
            speakerSuggestions = transcriptionManager.pendingSpeakerSuggestions
            transcriptionManager.pendingSpeakerSuggestions = []
        } else {
            speakerSuggestions = saved?.speakerSuggestions ?? []
        }
        // Marked moments + attendee emails: consume just-recorded, else restore.
        if !transcriptionManager.pendingMarkedMoments.isEmpty {
            markedMoments = transcriptionManager.pendingMarkedMoments
            transcriptionManager.pendingMarkedMoments = []
        } else {
            markedMoments = saved?.markedMoments ?? []
        }
        if !transcriptionManager.pendingAttendeeEmails.isEmpty {
            attendeeEmails = transcriptionManager.pendingAttendeeEmails
            transcriptionManager.pendingAttendeeEmails = []
        }
        // Auto-generate notes only for a fresh meeting (consumed once), when the
        // setting is on and the two target templates aren't already present.
        if transcriptionManager.consumePendingIsMeeting() {
            let alreadyHasBrief = templateOutputs[PromptTemplateLibrary.meetingBriefID.uuidString] != nil
            autoNotesPending = AppSettings.shared.autoGenerateMeetingNotes && !alreadyHasBrief
        }
        maybeAutoGenerateMeetingNotes()
    }

    /// The Meeting Brief, generated in the background right after a meeting
    /// transcription completes, then cached + persisted like a manual run.
    private func maybeAutoGenerateMeetingNotes() {
        guard autoNotesPending, !autoNotesRunning, isCompleted else { return }
        guard !transcriptionManager.liveTranscriptionText.isEmpty else { return }
        // If the AI backend isn't set up yet, keep the request pending — an
        // onChange(of: aiBackend) retries once the user configures a provider.
        guard providerReady(aiBackend) else { return }
        guard templateOutputs[PromptTemplateLibrary.meetingBriefID.uuidString] == nil else { return }
        autoNotesPending = false
        autoNotesRunning = true
        let brief = PromptTemplateLibrary.meetingBrief
        let transcript = transcriptionManager.liveTranscriptionText
        autoNotesTask = Task {
            autoNotesStatus = "Preparing your meeting brief…"
            do {
                let out = try await TemplateRunner.produce(brief, on: transcript)
                if !Task.isCancelled {
                    templateOutputs[brief.id.uuidString] = out
                    persistAISidecar()
                }
            } catch { /* backend not ready / cancelled — user can run it manually */ }
            autoNotesStatus = nil
            autoNotesRunning = false
        }
    }

    /// Run a saved recipe on this transcript (manual = all steps, interactive).
    private func runRecipe(_ r: Recipe) {
        guard let path = transcriptionManager.lastSavedPath else { return }
        let ctx = RecipeRunner.Context(
            transcript: transcriptionManager.liveTranscriptionText,
            title: transcriptionManager.currentTranscriptionTitle,
            path: path)
        Task {
            _ = await RecipeRunner.run(r, on: ctx, interactive: true)
            // Reflect any new brief/format the recipe produced in the Summary tab.
            if let sc = TranscriptAIStore.load(for: path) {
                templateOutputs = sc.templateOutputs ?? templateOutputs
            }
        }
    }

    /// Persist the current summary + chat + translation next to the transcript file.
    private func persistAISidecar() {
        guard let path = transcriptionManager.lastSavedPath else { return }
        let summary = summarizer.currentSummary
        let translation = translator.currentTranslation
        let speakerNames = transcriptionManager.speakerNameOverrides.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        guard summary != nil || translation != nil || !templateOutputs.isEmpty || !chat.messages.isEmpty || userNotes != nil || !speakerNames.isEmpty || !speakerSuggestions.isEmpty || !markedMoments.isEmpty else { return }
        TranscriptAIStore.save(
            TranscriptAISidecar(
                summary: summary,
                chat: chat.messages,
                translation: translation,
                translationLanguageCode: translation != nil ? translateTargetLanguage : nil,
                templateOutputs: templateOutputs.isEmpty ? nil : templateOutputs,
                userNotes: userNotes,
                speakerNames: speakerNames.isEmpty ? nil : speakerNames,
                speakerSuggestions: speakerSuggestions.isEmpty ? nil : speakerSuggestions,
                markedMoments: markedMoments.isEmpty ? nil : markedMoments
            ),
            for: path
        )
    }

    @ViewBuilder
    private func chatBubble(_ msg: ChatMessage) -> some View {
        if msg.isError {
            // Errors (e.g. missing API key) read as a warning, not a normal
            // answer, and offer a one-click retry with the now-current model.
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 13))
                    Text(msg.text)
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                }
                Button {
                    chat.retryLast()
                } label: {
                    Label("Try again with \(aiBackend.shortName)", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .secondaryGlassButton()
                .controlSize(.small)
                .disabled(chat.isAnswering)
            }
            .padding(12)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.orange.opacity(0.3), lineWidth: 1))
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack {
                if msg.isUser { Spacer(minLength: 60) }
                Text(msg.text)
                    .font(.system(size: 14))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        msg.isUser ? DS.Colors.accent : Color.white.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .foregroundColor(msg.isUser ? .white : .primary)
                    .frame(maxWidth: 560, alignment: msg.isUser ? .trailing : .leading)
                    .contextMenu {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(msg.text, forType: .string)
                        }
                    }
                if !msg.isUser { Spacer(minLength: 60) }
            }
        }
    }

    /// Suggested questions adapt to the transcript: a multi-speaker recording gets
    /// a "who said what" prompt; a single-speaker one gets a topics prompt.
    private var suggestionPrompts: [String] {
        let speakers = Set(transcriptionManager.segments.compactMap { $0.speaker }).count
        var prompts = ["Summarize the key points", "What are the action items?"]
        if speakers > 1 {
            prompts.append("Who said what — summarize each speaker's points")
        } else {
            prompts.append("What topics were covered?")
        }
        return prompts
    }

    private var suggestedQuestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try asking")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            ForEach(suggestionPrompts, id: \.self) { prompt in
                Button {
                    chatInput = prompt
                    sendQuestion()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkle").font(.system(size: 13))
                        Text(prompt).font(.system(size: 14))
                        Spacer()
                    }
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var summarySection: some View {
        switch summarizer.state {
        case .idle:
            VStack(spacing: 16) {
                Image(systemName: "sparkles")
                    .font(.system(size: 40))
                    .foregroundStyle(DS.Colors.accent)
                Text("Summarize this transcript")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Overview, key points and action items — generated with your selected AI model. \(aiPrivacyNote)")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button {
                    summarizer.summarize(transcriptionManager.liveTranscriptionText)
                } label: {
                    Label("Generate Summary", systemImage: "sparkles")
                }
                .primaryGlassButton()
                .disabled(transcriptionManager.liveTranscriptionText.isEmpty || isTranscribing)
                // Surface the otherwise-hidden template library.
                Text("Need meeting minutes, a SOAP note, or your own format? Choose a template above ↑")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)

        case .working(let message):
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text("Long transcripts are summarized in parts — this can take a minute.")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
                Button("Cancel") { summarizer.cancel() }
                    .secondaryGlassButton()
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)

        case .done(let summary):
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(summarizer.resultBadge.isEmpty ? "Summary" : summarizer.resultBadge, systemImage: "sparkles")
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

    // MARK: - Template Section (Summary tab, non-Summary templates)

    /// Display state for a template = the runner's live state when it's the active
    /// one, otherwise a cached completed output, otherwise the idle CTA.
    private enum TemplateDisplay {
        case idle, working(String), done(String), failed(String)
    }

    private func templateDisplay(for template: PromptTemplate) -> TemplateDisplay {
        if templateRunner.activeTemplateID == template.id {
            switch templateRunner.state {
            case .working(let m): return .working(m)
            case .failed(let m): return .failed(m)
            case .done(let o): return .done(o)
            case .idle: break
            }
        }
        if let cached = templateOutputs[template.id.uuidString] { return .done(cached.text) }
        return .idle
    }

    /// If a re-run fails but we still have a cached success, keep showing the
    /// success rather than hiding it behind the error.
    private func templateDisplayWithFallback(for template: PromptTemplate) -> TemplateDisplay {
        let d = templateDisplay(for: template)
        if case .failed = d, let cached = templateOutputs[template.id.uuidString] {
            return .done(cached.text)
        }
        return d
    }

    /// The backend that produced the currently-shown result for this template —
    /// the live runner badge while running, else the cached result's badge.
    private func templateBadge(for template: PromptTemplate) -> String {
        if templateRunner.activeTemplateID == template.id, !templateRunner.resultBadge.isEmpty {
            return templateRunner.resultBadge
        }
        if let cached = templateOutputs[template.id.uuidString], !cached.badge.isEmpty {
            return cached.badge
        }
        return template.name
    }

    @ViewBuilder
    private func templateSection(_ template: PromptTemplate, inputText: String) -> some View {
        switch templateDisplayWithFallback(for: template) {
        case .idle:
            VStack(spacing: 16) {
                Image(systemName: template.icon)
                    .font(.system(size: 40))
                    .foregroundStyle(DS.Colors.accent)
                Text(template.name)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Generate “\(template.name)” from this transcript using your selected AI model. \(aiPrivacyNote)")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button {
                    templateRunner.run(template, on: inputText)
                } label: {
                    Label("Generate", systemImage: template.icon)
                }
                .primaryGlassButton()
                .disabled(transcriptionManager.liveTranscriptionText.isEmpty || isTranscribing)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)

        case .working(let message):
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(message).font(.caption).foregroundColor(.secondary)
                }
                Text("Long transcripts are processed in parts — this can take a minute.")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
                Button("Cancel") { templateRunner.cancel() }
                    .secondaryGlassButton()
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)

        case .done(let output):
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(templateBadge(for: template), systemImage: template.icon)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if isActionItemsTemplate(template) {
                        Button {
                            exportToReminders(output, meetingTitle: transcriptionManager.currentTranscriptionTitle)
                        } label: {
                            if remindersExporting {
                                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Adding…") }
                            } else {
                                Label(remindersStatus ?? "Add to Reminders", systemImage: remindersStatus != nil ? "checkmark" : "checklist")
                            }
                        }
                        .secondaryGlassButton()
                        .disabled(remindersExporting)
                        .help("Create a reminder for each action item in your Reminders app")
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(output, forType: .string)
                        copiedTemplateID = template.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            if copiedTemplateID == template.id { copiedTemplateID = nil }
                        }
                    } label: {
                        let isCopied = copiedTemplateID == template.id
                        Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                    }
                    .secondaryGlassButton()
                    Button {
                        templateRunner.run(template, on: inputText)
                    } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                    .secondaryGlassButton()
                }
                Text(output)
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
                    templateRunner.run(template, on: inputText)
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
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help(audioPlayer.isPlaying ? "Pause (Space)" : "Play (Space)")

            // Time
            Text(formatPlayerTime(audioPlayer.currentTime))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 54, alignment: .trailing)

            // Scrubber
            Slider(
                value: Binding(
                    get: { audioPlayer.currentTime },
                    set: { audioPlayer.seek(to: $0) }
                ),
                in: 0...max(audioPlayer.duration, 1)
            )

            // Duration
            Text(formatPlayerTime(audioPlayer.duration))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 54, alignment: .leading)

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
            .help("Playback speed")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassSurface(cornerRadius: 0)
    }

    private func formatPlayerTime(_ time: TimeInterval) -> String {
        let h = Int(time) / 3600
        let m = (Int(time) % 3600) / 60
        let s = Int(time) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
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
                    // Estimated reading time (~200 wpm) — useful framing for long
                    // depositions/interviews.
                    Label("\(max(1, wordCount / 200)) min read", systemImage: "book")
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
                    Label(showCopiedAlert ? "Copied!" : "Copy Transcript", systemImage: showCopiedAlert ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12))
                }
                .secondaryGlassButton()
                .controlSize(.small)
                .tint(showCopiedAlert ? .green : nil)
                .fixedSize()

                // Export menu — the single hub for all output: the transcript in
                // every format, plus the AI summary / translation when they exist.
                Menu {
                    Section("Transcript") {
                        Button("PDF — formatted") { exportTranscriptPDF(redacted: false) }
                        ForEach(TranscriptionOutputFormat.allCases, id: \.self) { format in
                            Button(format.displayName) {
                                transcriptionManager.exportAs(format: format)
                            }
                        }
                    }
                    Section("Privacy") {
                        Button("Redacted transcript (PDF)") { exportTranscriptPDF(redacted: true) }
                            .help("Masks names, emails and phone numbers. Auto-detection may miss some — review before sharing.")
                        Button("Redacted transcript (Text)") { exportRedactedText() }
                            .help("Masks names, emails and phone numbers. Auto-detection may miss some — review before sharing.")
                    }
                    if summarizer.currentSummary != nil || translator.currentTranslation != nil || !templateOutputs.isEmpty {
                        Section("AI") {
                            if let summary = summarizer.currentSummary {
                                Button("Summary (Text)") {
                                    transcriptionManager.exportPlainText(summary, filenameSuffix: " (Summary)")
                                }
                            }
                            if let translation = translator.currentTranslation {
                                Button("Translation — \(translateTargetName) (Text)") {
                                    transcriptionManager.exportPlainText(translation, filenameSuffix: " (\(translateTargetName))")
                                }
                            }
                            ForEach(templateStore.all) { t in
                                if let output = templateOutputs[t.id.uuidString] {
                                    Button("\(t.name) (Text)") {
                                        transcriptionManager.exportPlainText(output.text, filenameSuffix: " (\(t.name))")
                                    }
                                }
                            }
                            if let polished = templateOutputs[PromptTemplateLibrary.polishNotes.id.uuidString] {
                                Button("Polished Notes (Text)") {
                                    transcriptionManager.exportPlainText(polished.text, filenameSuffix: " (Notes)")
                                }
                            }
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
                    // Keep low-confidence words clearly readable — only a gentle
                    // dimming, not the near-invisible 0.4 floor we had before.
                    let opacity = max(0.62, Double(word.probability))
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
            // More breathing room when speaker labels break up the text.
            .lineSpacing(hasSpeakers ? 7 : 5)
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
    var isEditing: Bool = false
    var onCommitEdit: ((String) -> Void)? = nil

    @State private var isHovered = false
    @State private var draft = ""

    /// Only write when the text actually changed — prevents a "Done" tap from
    /// fanning out N file writes across every visible row (and guards against a
    /// recycled row committing the wrong segment's stale draft).
    private func commitIfChanged() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != segment.text { onCommitEdit?(trimmed) }
    }

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

                // Segment text — editable in edit mode, else highlighted display.
                if isEditing {
                    TextField("", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.Colors.accent.opacity(0.4), lineWidth: 1))
                        // Reseed on first show AND when a recycled LazyVStack row is
                        // reused for a different segment (else draft would be stale).
                        .onChange(of: segment.id, initial: true) { draft = segment.text }
                        .onSubmit { commitIfChanged() }
                        .onChange(of: isEditing) { _, editing in
                            if !editing { commitIfChanged() }   // commit when leaving edit mode
                        }
                } else {
                    highlightedText
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }

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
        .onHover { hovering in
            isHovered = hovering
            // Pointer cursor signals the row is clickable (tap = seek + play).
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onTapGesture {
            if !isEditing { onTap?() }   // don't seek while editing text
        }
        .contentShape(Rectangle())
        .help(isEditing ? "Editing — press Return to save" : "Click to play from here")
        .contextMenu {
            Button("Copy text") { copyToPasteboard(segment.text) }
            Button("Copy with timestamp") {
                let speaker = segment.speaker.map { "\(displayName($0)): " } ?? ""
                copyToPasteboard("[\(segment.formattedStart)] \(speaker)\(segment.text)")
            }
            Button("Play from here") { onTap?() }
        }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
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

                // Elapsed time + a reassurance if it's taking a while, so the
                // user knows it's working and hasn't frozen.
                Text(elapsed < 60
                     ? "\(elapsed)s elapsed"
                     : "\(elapsed / 60)m \(elapsed % 60)s elapsed — larger files and first-time model loading take longer")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
                    .padding(.horizontal, 24)
            }
        }
        .onAppear {
            animating = true
            pulseOpacity = 0.8
        }
        .onDisappear {
            animating = false
        }
        .onReceive(elapsedTimer) { _ in elapsed += 1 }
    }

    @State private var elapsed = 0
    private let elapsedTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
