import SwiftUI
import AppKit

// MARK: - A note is one page
//
// Before, during and after the recording you stay on the same page: the title and
// your notes in the middle, the transcript in a panel on the right (live while
// recording, with speakers once it's done). After "Finish" the page shows each
// step — saving, transcribing the whole conversation, writing the notes — and
// then offers Ask, Continue recording and Share.

/// Shows a meeting as a document, or — on request — the full transcript view.
struct MeetingPage: View {
    var onBack: () -> Void
    @State private var showDetails = false
    @ObservedObject private var tm = TranscriptionManager.shared

    var body: some View {
        if showDetails {
            TranscriptionResultView(transcriptionManager: tm, onClose: { showDetails = false })
        } else {
            MeetingDocumentView(onBack: onBack, onOpenDetails: { showDetails = true })
        }
    }
}

struct MeetingDocumentView: View {
    var onBack: () -> Void = {}
    var onOpenDetails: () -> Void = {}

    @ObservedObject private var recorder = MeetingRecorder.shared
    @ObservedObject private var live = MeetingRecorder.shared.live
    @ObservedObject private var tm = TranscriptionManager.shared
    @ObservedObject private var chat = TranscriptChat.shared
    @ObservedObject private var history = TranscriptionHistoryManager.shared
    @StateObject private var player = AudioPlayerManager()

    @AppStorage("showTranscriptPanel") private var showTranscript = true
    @State private var askText = ""
    @State private var showAnswers = false
    @State private var enhanced: EnhancedNotes?
    @State private var savedNotes = ""
    @State private var consentAt: Double?
    @State private var showMine = false
    @State private var followUpBusy = false
    @State private var followUpError: String?
    @FocusState private var notesFocused: Bool

    private enum Phase { case recording, finishing, finished }
    private var phase: Phase {
        if recorder.isRecording { return .recording }
        if recorder.state == .finishing { return .finishing }
        return .finished
    }

    private var path: String? { tm.lastSavedPath }
    private var isEnhancing: Bool { path.map { tm.enhancingPaths.contains($0) } ?? false }
    private var enhanceError: String? { path.flatMap { tm.enhanceErrors[$0] } }
    private var transcriptReady: Bool {
        if case .completed = tm.transcriptionState { return !tm.segments.isEmpty }
        return false
    }
    /// Between "Finish" and ready notes: saving, transcribing, writing.
    private var isProcessing: Bool {
        phase == .finishing || tm.isTranscribing || (isEnhancing && enhanced == nil)
    }

    var body: some View {
        // A plain side-by-side panel rather than .inspector: in a narrow window the
        // inspector's split-view constraints loop until AppKit aborts.
        HStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                ScrollView {
                    document
                        .frame(maxWidth: DS.Layout.readingWidth, alignment: .leading)
                        .padding(.horizontal, DS.Layout.pageHorizontal)
                        .padding(.top, 12)
                        .padding(.bottom, 180)
                        .frame(maxWidth: .infinity)
                }

                VStack(spacing: 10) {
                    if showAnswers && (!chat.messages.isEmpty || chat.isAnswering) {
                        answersPanel
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if phase == .finished, transcriptReady, enhanced == nil, !isProcessing, enhanceError == nil {
                        Button {
                            writeNotes()
                        } label: {
                            Label("Write Notes", systemImage: "sparkles")
                                .font(.body.weight(.semibold))
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                    }
                    bottomBar
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .animation(.snappy(duration: 0.25), value: showAnswers)
            }
            .frame(maxWidth: .infinity)

            if showTranscript {
                Divider()
                transcriptPanel
                    .frame(width: 300)
                    .background(DS.Colors.rowFill)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.snappy(duration: 0.25), value: showTranscript)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showTranscript.toggle()
                } label: {
                    Label("Transcript", systemImage: "sidebar.right")
                }
                .help(showTranscript ? "Hide the transcript" : "Show the transcript")
            }
        }
        .onAppear(perform: load)
        .onChange(of: tm.lastSavedPath) { _, _ in load() }
        .onChange(of: tm.audioFilePath) { _, p in if let p { player.load(path: p) } }
        .onChange(of: tm.transcriptionState) { _, _ in load() }
        .onReceive(NotificationCenter.default.publisher(for: .enhancedNotesUpdated)) { note in
            if (note.object as? String) == path { load() }
        }
        .onDisappear { player.stop() }
    }

    // MARK: Document

    @ViewBuilder
    private var document: some View {
        VStack(alignment: .leading, spacing: 14) {
            if phase == .recording {
                TextField("New note", text: $recorder.liveTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 34, weight: .semibold, design: .serif))
            } else {
                Text(title)
                    .font(.system(size: 34, weight: .semibold, design: .serif))
                    .textSelection(.enabled)
            }

            chips

            switch phase {
            case .recording:
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $recorder.liveNotes)
                        .font(.title3)
                        .lineSpacing(5)
                        .scrollContentBackground(.hidden)
                        .scrollDisabled(true)
                        .frame(minHeight: 320)
                        .focused($notesFocused)
                        .accessibilityLabel("Your notes")
                    if recorder.liveNotes.isEmpty {
                        Text("Write notes — or just listen. Notes are written from the conversation when you finish.")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .onAppear { notesFocused = true }
            case .finishing:
                steps
                notesText(recorder.liveNotes)
            case .finished:
                finishedBody
            }
        }
    }

    private var title: String {
        if phase != .finished {
            let live = recorder.liveTitle.trimmingCharacters(in: .whitespaces)
            return live.isEmpty ? String(localized: "New note") : live
        }
        let t = tm.currentTranscriptionTitle.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? String(localized: "New note") : t
    }

    private var historyItem: TranscriptionHistoryItem? {
        guard let path else { return nil }
        return history.history.first { $0.filePath == path }
    }

    private var chips: some View {
        HStack(spacing: 8) {
            chip(dateLabel, systemImage: "calendar")
            chip(peopleLabel, systemImage: "person.2")
            if phase == .recording {
                consentMenu
            } else if let consentAt {
                Label("Consent · \(EnhancedNotesGenerator.clock(consentAt))", systemImage: "checkmark.shield")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.green.opacity(0.12)))
            }
            if phase == .finished, enhanced != nil, !isProcessing {
                Menu {
                    Button("Enhanced Notes", systemImage: "sparkles") { showMine = false }
                    Button("What I Wrote", systemImage: "pencil") { showMine = true }
                } label: {
                    Label(showMine ? "What I wrote" : "Enhanced", systemImage: showMine ? "pencil" : "sparkles")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .fixedSize()
            }
            Spacer(minLength: 0)
            if phase == .finished, tm.canRetranscribe, !isProcessing {
                moreMenu
            }
        }
    }

    private func chip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().strokeBorder(DS.Colors.hairline, lineWidth: 1))
    }

    private var dateLabel: String {
        let date = phase == .finished ? (historyItem?.transcriptionDate ?? Date()) : (recorder.startedAt ?? Date())
        return Calendar.current.isDateInToday(date)
            ? String(localized: "Today")
            : date.formatted(date: .abbreviated, time: .omitted)
    }

    private var peopleLabel: String {
        if phase != .finished || tm.segments.isEmpty {
            return String(localized: "Me")
        }
        let speakers = Set(tm.segments.compactMap(\.speaker)).count
        return speakers <= 1 ? String(localized: "Me") : String(localized: "\(speakers) people")
    }

    @ViewBuilder
    private var consentMenu: some View {
        if let at = recorder.consentAt {
            Label("Consent · \(AppUtil.formatElapsed(at))", systemImage: "checkmark.shield")
                .font(.callout)
                .foregroundStyle(.green)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.green.opacity(0.12)))
        } else {
            Menu {
                Button("Everyone agreed to the recording", systemImage: "checkmark.shield") { recorder.confirmConsent() }
                Divider()
                Button("Copy notice in Swedish", systemImage: "doc.on.doc") { copy(ConsentNotice.swedish) }
                Button("Copy notice in English", systemImage: "doc.on.doc") { copy(ConsentNotice.english) }
            } label: {
                Label("Confirm consent", systemImage: "exclamationmark.shield")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(.orange)
            .fixedSize()
        }
    }

    private var moreMenu: some View {
        Menu {
            Menu("Transcribe Again in", systemImage: "arrow.triangle.2.circlepath") {
                ForEach(AppSettings.transcriptionLanguages, id: \.code) { lang in
                    Button(lang.name) { tm.retranscribe(language: lang.code) }
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .labelStyle(.iconOnly)
        .fixedSize()
        .help("More")
    }

    // MARK: After "Finish"

    /// The three things that happen after a recording, each with its state.
    /// Labels read as "doing" while active and "done" once finished.
    private var steps: some View {
        let saving: StepState = phase == .finishing ? .active : .done
        let transcribing: StepState = phase == .finishing ? .waiting : (tm.isTranscribing ? .active : .done)
        let writing: StepState = isEnhancing ? .active : (transcribing == .done ? .done : .waiting)
        return VStack(alignment: .leading, spacing: 10) {
            step(saving == .done ? "Recording saved" : "Saving the recording", state: saving)
            step(transcribing == .done ? "Whole conversation transcribed and speakers told apart" : transcribeStepTitle,
                 detail: transcribing == .active ? "More accurate than the live text, which was a quick draft." : nil,
                 state: transcribing, progress: transcribeProgress)
            step(writing == .done ? "Notes written" : "Writing the notes", state: writing)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.rowFill))
        .accessibilityElement(children: .combine)
    }

    private enum StepState { case waiting, active, done }

    private func step(_ title: LocalizedStringKey, detail: LocalizedStringKey? = nil,
                      state: StepState, progress: Double? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                switch state {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .active: ProgressView().controlSize(.small)
                case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(state == .waiting ? .secondary : .primary)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
            }
            if state == .active, let progress, progress > 0 {
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.body)
    }

    private var transcribeStepTitle: LocalizedStringKey {
        if case .loadingModel = tm.transcriptionState { return "Getting the speech model ready" }
        return "Transcribing the whole conversation again and telling speakers apart"
    }

    private var transcribeProgress: Double? {
        if case .transcribing(let p) = tm.transcriptionState { return p }
        return nil
    }

    @ViewBuilder
    private var finishedBody: some View {
        if case .error(let message) = tm.transcriptionState {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        if isProcessing {
            steps
            if !savedNotes.isEmpty { notesText(savedNotes) }
        } else if isEnhancing {
            notesText(savedNotes)
            BusyRow(text: "Writing your notes from the transcript…")
        } else if let enhanced, !showMine {
            enhancedView(enhanced)
        } else if !savedNotes.isEmpty {
            notesText(savedNotes)
        } else if transcriptReady, enhanceError == nil {
            Text("No notes yet. Press Write Notes and MindExtract writes them from the transcript.")
                .foregroundStyle(.secondary)
        }
        if let enhanceError, !isProcessing {
            VStack(alignment: .leading, spacing: 10) {
                Label(enhanceError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                HStack {
                    Button("Open AI Settings") {
                        UserDefaults.standard.set(SettingsCategory.ai.rawValue, forKey: "settingsCategory")
                        NotificationCenter.default.post(name: .openSettings, object: nil)
                    }
                    Button("Try Again") { writeNotes() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .contentCard(tint: .orange)
        }
        if let followUpError {
            Label(followUpError, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }

    private func notesText(_ text: String) -> some View {
        Text(text)
            .font(.title3)
            .lineSpacing(5)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func enhancedView(_ notes: EnhancedNotes) -> some View {
        // Jump-to buttons only help when the notes point at different moments.
        let moments = Set(notes.sections.flatMap { $0.lines.compactMap(\.at) })
        let showMoments = moments.count > 1 && tm.audioFilePath != nil
        return VStack(alignment: .leading, spacing: 22) {
            ForEach(Array(notes.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 8) {
                    if !section.heading.isEmpty {
                        Text(section.heading)
                            .font(.system(.title2, design: .serif).weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("•").foregroundStyle(.tertiary)
                            line.parts.reduce(Text("")) { text, part in
                                text + Text(part.text).foregroundStyle(part.isUser ? .primary : .secondary)
                            }
                            .font(.title3)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if let at = line.at, showMoments {
                                Button {
                                    play(from: at)
                                } label: {
                                    Label(EnhancedNotesGenerator.clock(at), systemImage: "play.fill")
                                        .font(.caption.weight(.semibold))
                                        .monospacedDigit()
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .controlSize(.small)
                                .help("Play this moment")
                            }
                        }
                    }
                }
            }
            HStack(spacing: 16) {
                if !savedNotes.isEmpty {
                    Label { Text("your notes") } icon: { Circle().fill(Color.primary).frame(width: 7, height: 7) }
                    Label { Text("added from the transcript") } icon: { Circle().fill(Color.secondary).frame(width: 7, height: 7) }
                }
                Spacer()
                Button("Rewrite") { writeNotes() }
                    .buttonStyle(.borderless)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            switch phase {
            case .recording:
                HStack(spacing: 8) {
                    MiniLevelBars(level: recorder.level)
                    Text("Listening")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .glassEffect(.regular, in: .capsule)
                .accessibilityElement(children: .combine)
            case .finishing:
                EmptyView()
            case .finished:
                if !isProcessing {
                    Button {
                        resume()
                    } label: {
                        Label("Continue Recording", systemImage: "record.circle")
                            .foregroundStyle(DS.Colors.recording)
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .glassEffect(.regular, in: .capsule)
                    .disabled(recorder.isBusy || path == nil)
                    .help("Record more into this note")
                }
            }

            HStack(spacing: 8) {
                TextField(phase == .recording ? "Ask about what's been said" : "Ask anything", text: $askText)
                    .textFieldStyle(.plain)
                    .onSubmit(ask)
                if phase == .finished && transcriptReady && !isProcessing {
                    shareMenu
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .frame(height: 44)
            .glassEffect(.regular, in: .capsule)
        }
    }

    private var shareMenu: some View {
        Menu {
            Button("Copy Notes", systemImage: "doc.on.doc") {
                copy(enhanced?.markdown ?? savedNotes)
            }
            .disabled(enhanced == nil && savedNotes.isEmpty)
            Button("Copy Transcript", systemImage: "text.quote") { copy(transcriptPlainText) }
            Button("Write Follow-up Email", systemImage: "envelope") { writeFollowUp() }
                .disabled(followUpBusy)
            Divider()
            Button("Export and Full Transcript…", systemImage: "square.and.arrow.up") { onOpenDetails() }
            if let path {
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
        } label: {
            if followUpBusy {
                ProgressView().controlSize(.small)
            } else {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .fixedSize()
    }

    // MARK: Transcript panel

    private var transcriptPanel: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcript").font(.headline)
                    Text(transcriptSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    copy(transcriptPlainText)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy the transcript").accessibilityLabel("Copy")
                    .disabled(bubbles.isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            if phase == .recording {
                Text("Always ask for consent before recording others.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            if bubbles.isEmpty {
                ContentUnavailableView {
                    Label(phase == .recording ? "Listening…" : "No transcript", systemImage: "waveform")
                } description: {
                    Text(phase == .recording ? "The words show up here as they're spoken." : "Nothing was transcribed.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(bubbles) { b in
                                bubble(b)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                        .opacity(isPreview ? 0.7 : 1)
                    }
                    .onChange(of: bubbles.count) { _, _ in
                        if phase == .recording { proxy.scrollTo("end", anchor: .bottom) }
                    }
                    .onAppear { if phase == .recording { proxy.scrollTo("end", anchor: .bottom) } }
                }
            }

            if phase == .recording {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 14) {
                        sourceDot("mic", active: recorder.micActive, label: "Your microphone")
                        sourceDot("speaker.wave.2", active: recorder.systemActive, label: "Meeting audio")
                        Spacer()
                    }
                    HStack(spacing: 10) {
                        Menu {
                            Button("System Default") { recorder.setMicrophone("") }
                            Divider()
                            ForEach(MeetingRecorder.availableMicrophones(), id: \.uniqueID) { dev in
                                Button(dev.localizedName) { recorder.setMicrophone(dev.uniqueID) }
                            }
                        } label: {
                            Label(currentMicName, systemImage: "mic")
                        }
                        .menuStyle(.button).buttonStyle(.borderless).fixedSize()
                        Menu {
                            ForEach(AppSettings.transcriptionLanguages, id: \.code) { lang in
                                Button(lang.name) { recorder.setLanguage(lang.code) }
                            }
                        } label: {
                            Label(languageName(recorder.currentLanguage), systemImage: "character.bubble")
                        }
                        .menuStyle(.button).buttonStyle(.borderless).fixedSize()
                    }
                }
                .font(.callout)
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
    }

    private var transcriptSubtitle: String {
        switch phase {
        case .recording:
            return live.engineLabel.isEmpty ? String(localized: "Live") : String(localized: "Live · \(live.engineLabel)")
        case .finishing:
            return String(localized: "Preview — the full transcript follows")
        case .finished:
            if isPreview { return String(localized: "Preview — the full transcript follows") }
            let speakers = Set(tm.segments.compactMap(\.speaker)).count
            return speakers <= 1 ? String(localized: "One speaker") : String(localized: "\(speakers) speakers")
        }
    }

    private struct Bubble: Identifiable {
        let id: String
        let isMe: Bool
        let speaker: String?
        let text: String
        let start: Double?
        var isTentative = false
    }

    /// The live text stands in until the full transcript is ready.
    private var isPreview: Bool {
        phase == .finishing || (phase == .finished && tm.isTranscribing && tm.segments.isEmpty)
    }

    private var bubbles: [Bubble] {
        if phase == .recording || isPreview {
            var out = live.utterances.map { Bubble(id: $0.id.uuidString, isMe: $0.isMe, speaker: nil, text: $0.text, start: $0.start) }
            if !live.theirTail.isEmpty { out.append(Bubble(id: "their-tail", isMe: false, speaker: nil, text: live.theirTail, start: nil, isTentative: true)) }
            if !live.myTail.isEmpty { out.append(Bubble(id: "my-tail", isMe: true, speaker: nil, text: live.myTail, start: nil, isTentative: true)) }
            // Engines without per-side preview (Whisper) only have flat text.
            if out.isEmpty, !live.displayText.isEmpty {
                out.append(Bubble(id: "flat", isMe: false, speaker: nil, text: live.displayText, start: nil))
            }
            return out
        }
        return tm.segments.map { seg in
            let isMe = seg.speaker == "You"
            return Bubble(id: seg.id.uuidString, isMe: isMe,
                          speaker: isMe ? nil : seg.speaker.map { tm.speakerDisplayName($0) },
                          text: seg.text, start: Double(seg.start))
        }
    }

    private func bubble(_ b: Bubble) -> some View {
        HStack {
            if b.isMe { Spacer(minLength: 36) }
            VStack(alignment: b.isMe ? .trailing : .leading, spacing: 2) {
                if let speaker = b.speaker {
                    Text(speaker).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(b.text)
                    .font(.callout)
                    .foregroundStyle(b.isTentative ? .secondary : .primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(b.isMe ? DS.Colors.accent.opacity(0.14) : DS.Colors.inputFill)
                    )
                    .onTapGesture {
                        if let s = b.start, phase == .finished, !isPreview, tm.audioFilePath != nil { play(from: s) }
                    }
            }
            if !b.isMe { Spacer(minLength: 36) }
        }
    }

    private func sourceDot(_ icon: String, active: Bool, label: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Circle().fill(active ? Color.green : Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
        }
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(active ? Text("Sound") : Text("Silent"))
    }

    private var currentMicName: String {
        let pref = AppSettings.shared.preferredMicrophoneID
        if !pref.isEmpty, let dev = MeetingRecorder.availableMicrophones().first(where: { $0.uniqueID == pref }) {
            return dev.localizedName
        }
        return String(localized: "System Default")
    }

    private func languageName(_ code: String) -> String {
        AppSettings.transcriptionLanguages.first { $0.code == code }?.name ?? code
    }

    private var transcriptPlainText: String {
        bubbles.map { ($0.isMe ? String(localized: "Me") : ($0.speaker ?? String(localized: "Others"))) + ": " + $0.text }
            .joined(separator: "\n")
    }

    // MARK: Answers

    private var answersPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Answers").font(.headline)
                Spacer()
                Button { showAnswers = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).accessibilityLabel("Close")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(chat.messages) { m in
                        HStack {
                            if m.isUser { Spacer(minLength: 60) }
                            Text(m.text)
                                .font(.callout)
                                .foregroundStyle(m.isError ? .orange : .primary)
                                .textSelection(.enabled)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(m.isUser ? DS.Colors.accent.opacity(0.14) : DS.Colors.inputFill))
                            if !m.isUser { Spacer(minLength: 60) }
                        }
                    }
                    if chat.isAnswering {
                        BusyRow(text: "Thinking…")
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
        .frame(maxHeight: 300)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: Actions

    private func load() {
        if let pending = tm.pendingMeetingNotes {
            savedNotes = pending
            tm.pendingMeetingNotes = nil
        }
        guard let path else { enhanced = nil; consentAt = nil; return }
        let sidecar = TranscriptAIStore.load(for: path)
        enhanced = sidecar?.enhancedNotes
        consentAt = sidecar?.consentConfirmedAt
        if let notes = sidecar?.userNotes, !notes.isEmpty { savedNotes = notes }
        if let audio = tm.audioFilePath { player.load(path: audio) }
    }

    private func writeNotes() {
        guard let path else { return }
        showMine = false
        tm.generateEnhancedNotes(path: path, userNotes: savedNotes, segments: tm.segments)
    }

    private func resume() {
        guard let path else { return }
        player.stop()
        recorder.resume(transcriptPath: path, title: title, notes: savedNotes)
    }

    private func play(from time: Double) {
        player.seek(to: time)
        if !player.isPlaying { player.togglePlayPause() }
    }

    private func ask() {
        let q = askText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let context = phase == .finished && !isPreview ? tm.liveTranscriptionText : transcriptPlainText
        chat.prepare(transcript: context)
        chat.ask(q)
        askText = ""
        showAnswers = true
    }

    private func writeFollowUp() {
        followUpBusy = true
        followUpError = nil
        let source = enhanced?.markdown ?? String(tm.liveTranscriptionText.prefix(12_000))
        let meeting = title
        let backend = AIBackends.current()
        Task { @MainActor in
            defer { followUpBusy = false }
            do {
                let body = try await backend.respond(
                    instructions: "You write a short, warm follow-up email after a meeting: a thank-you, the key decisions, and next steps with owners and dates. Plain text, no subject line, no placeholders. Write in the same language as the notes.",
                    prompt: source)
                let subject = String(localized: "Follow-up: \(meeting)")
                if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [body]) {
                    service.subject = subject
                    service.perform(withItems: [body])
                } else {
                    copy(body)
                    let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "" }
                    if let url = URL(string: "mailto:?subject=\(enc(subject))&body=\(enc(body))") { NSWorkspace.shared.open(url) }
                }
            } catch {
                followUpError = String(localized: "Couldn't write the email: \(error.localizedDescription)")
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Five little bars that follow the input level.
struct MiniLevelBars: View {
    let level: Double
    private let weights: [Double] = [0.45, 0.8, 1.0, 0.7, 0.5]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(DS.Colors.recording)
                    .frame(width: 3, height: 4 + 14 * min(1, level * 1.6 * weights[i]))
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.1), value: level)
        .accessibilityHidden(true)
    }
}

/// Ready-made recording notices — say or paste them at the start of a meeting.
enum ConsentNotice {
    static let swedish = "Hej! Jag spelar in det här mötet lokalt på min dator för att kunna föra anteckningar. Inget skickas till molnet. Säg till om du inte vill att jag spelar in."
    static let english = "Hi! I'm recording this meeting locally on my computer so I can take notes. Nothing is sent to the cloud. Let me know if you'd rather I didn't record."
}
