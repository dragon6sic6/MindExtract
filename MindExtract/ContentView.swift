import SwiftUI

// MARK: - Main window
//
// MindExtract does three things, and each has its place in the sidebar:
//   • Notes — record a meeting or a thought, live text, speakers, AI notes
//   • Downloads — paste any link, download the video or audio, transcribe it
//   • Dictation — hold a key anywhere and speak

enum AppSection: String, CaseIterable, Identifiable {
    case notes, downloads, dictation

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .notes: return "Notes"
        case .downloads: return "Downloads"
        case .dictation: return "Dictation"
        }
    }

    var icon: String {
        switch self {
        case .notes: return "note.text"
        case .downloads: return "arrow.down.circle"
        case .dictation: return "mic"
        }
    }
}

extension Notification.Name {
    /// Switch the main window to a section (object: AppSection).
    static let showSection = Notification.Name("showSection")
}

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @StateObject private var settings = AppSettings.shared
    @ObservedObject private var tm = TranscriptionManager.shared
    @ObservedObject private var history = TranscriptionHistoryManager.shared
    @ObservedObject private var downloads = HistoryManager.shared
    @ObservedObject private var recorder = MeetingRecorder.shared
    @ObservedObject private var appLock = AppLock.shared

    @AppStorage("appSection") private var section: AppSection = .notes

    /// File paths of the selected notes; `liveTag` stands for the one in progress
    /// (recording, or being transcribed before it has a file).
    @State private var selection: Set<String> = []
    private static let liveTag = "live-recording"
    private var single: String? { selection.count == 1 ? selection.first : nil }

    @State private var searchText = ""
    @State private var searchHits: [TranscriptLibrary.SearchHit] = []
    @State private var renaming: TranscriptionHistoryItem?
    @State private var draftTitle = ""
    @State private var pendingDelete: [TranscriptionHistoryItem] = []

    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var showWelcome = false

    // ⌘K search/ask overlay — one stable sheet whose content swaps between the
    // palette and the chat (swapping sheet *identity* would flicker/dismiss).
    enum AppOverlay { case palette, chat }
    @State private var showOverlay = false
    @State private var overlayContent: AppOverlay = .palette

    private var isLive: Bool { recorder.isRecording || recorder.state == .finishing }
    /// A new transcript is being made and has no file yet.
    private var isInProgress: Bool { isLive || (tm.isTranscribing && tm.lastSavedPath == nil) }

    var body: some View {
        NavigationSplitView {
            sectionList
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            sectionDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(DS.Colors.backdrop.ignoresSafeArea())
                .toolbar { toolbar }
        }
        .navigationTitle("")
        .frame(minWidth: 860, minHeight: 540)
        // "Recording finished" confirm sheet — shown wherever you stopped from.
        .sheet(item: $recorder.pendingRecording) { pending in
            TranscribeSheet(
                mode: .recording(pending),
                onStart: { name, lang, model in recorder.confirmPending(title: name ?? pending.title, language: lang, model: model) },
                onCancel: { recorder.discardPending() }
            )
            .interactiveDismissDisabled()
        }
        // App-lock gate: cover everything until the user authenticates.
        .overlay {
            if appLock.isLocked { LockView() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            appLock.lockIfEnabled()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Small debounce: the Touch ID / password panel itself fires a spurious
            // resign/become pair — without this the prompt can flicker twice.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if appLock.isLocked { appLock.authenticate() }
            }
        }
        .onAppear {
            appLock.lockIfEnabled()
            if appLock.isLocked { appLock.authenticate() }
            if MainWindow.opener == nil { MainWindow.opener = openWindow }
            recorder.recoverInterruptedSessions()
            recorder.refreshPermissions()
            if !hasSeenWelcome && !showWelcome { showWelcome = true }
            if isLive { show(.notes, select: Self.liveTag) }
            // A link handed over at launch goes straight to Downloads.
            if UserDefaults.standard.string(forKey: "pendingURL")?.isEmpty == false {
                section = .downloads
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            openSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSection)) { note in
            if let s = note.object as? AppSection { section = s }
        }
        // Keep the list selection in step with what's open.
        .onChange(of: selection) { _, sel in
            if sel.count == 1 { open(sel.first) }
        }
        // A transcript opened or started anywhere (e.g. from Downloads) shows in Notes.
        .onChange(of: tm.showTranscriptionView) { _, show in
            if show { self.show(.notes, select: tm.lastSavedPath ?? Self.liveTag) }
        }
        .onChange(of: tm.lastSavedPath) { _, p in
            if tm.showTranscriptionView, let p, single != Self.liveTag || !isLive { selection = [p] }
        }
        .onChange(of: recorder.isRecording) { _, recording in
            if recording { show(.notes, select: Self.liveTag) }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(
            get: { !pendingDelete.isEmpty },
            set: { if !$0 { pendingDelete = [] } }), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                let paths = Set(pendingDelete.map(\.filePath))
                selection.subtract(paths)
                if let open = tm.lastSavedPath, paths.contains(open) { tm.showTranscriptionView = false }
                history.moveToTrash(pendingDelete)
                pendingDelete = []
            }
            Button("Cancel", role: .cancel) { pendingDelete = [] }
        } message: {
            Text("The transcript and its recording go to the Trash. You can put them back from there.")
        }
        .sheet(isPresented: $showWelcome) {
            PermissionsOnboardingView(onDone: {
                hasSeenWelcome = true
                showWelcome = false
            })
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPermissions)) { _ in
            showWelcome = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSearch)) { _ in
            overlayContent = .palette
            showOverlay = true
        }
        .sheet(isPresented: $showOverlay) {
            switch overlayContent {
            case .palette:
                CommandPaletteView(
                    onOpenTranscript: { item in
                        showOverlay = false
                        if item.fileExists { show(.notes, select: item.filePath) }
                    },
                    onAsk: { query in
                        CorpusChat.shared.reset()
                        CorpusChat.shared.ask(query)
                        overlayContent = .chat   // swaps content in the same sheet
                    }
                )
            case .chat:
                CorpusChatView()
            }
        }
        .task {
            // Swedish users get Pianissimo on first launch (once the model list is loaded).
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            PianissimoOffer.autoStartIfNeeded()
        }
        .task(id: searchText) {
            // Debounce keystrokes; search reads files so we don't run it per frame.
            guard !searchText.isEmpty else { searchHits = []; return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            searchHits = TranscriptLibrary.shared.search(searchText)
        }
    }

    // MARK: - Sections

    private var sectionList: some View {
        List(selection: Binding(get: { Optional(section) }, set: { if let s = $0 { section = s } })) {
            ForEach(AppSection.allCases) { s in
                Label(s.title, systemImage: s.icon)
                    .badge(badge(for: s))
                    .tag(s)
            }
        }
        .listStyle(.sidebar)
    }

    private func badge(for s: AppSection) -> Int {
        switch s {
        case .notes: return history.history.count
        case .downloads: return downloads.history.count
        case .dictation: return 0
        }
    }

    @ViewBuilder
    private var sectionDetail: some View {
        switch section {
        case .notes:
            VStack(spacing: 0) {
                PianissimoBanner()
                HStack(spacing: 0) {
                    notesColumn
                        .frame(width: 280)
                    Divider()
                    noteDetail
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        case .downloads:
            DownloaderView()
        case .dictation:
            DictationPage()
        }
    }

    // MARK: - Notes list

    /// Favorites pinned on top, the rest grouped by date.
    private var groups: [(label: String, items: [TranscriptionHistoryItem])] {
        let items = history.history
        let favs = items.filter { $0.isFavorite ?? false }
        let rest = items.filter { !($0.isFavorite ?? false) }
        let dated = groupHistoryByDate(rest, date: { $0.transcriptionDate })
        return favs.isEmpty ? dated : [(String(localized: "Favorites"), favs)] + dated
    }

    /// Title matches first, then notes whose text matches.
    private var results: [TranscriptionHistoryItem] {
        let q = searchText.lowercased()
        let byTitle = history.history.filter { $0.title.lowercased().contains(q) }
        let seen = Set(byTitle.map(\.id))
        return byTitle + searchHits.map(\.item).filter { !seen.contains($0.id) }
    }

    private var notesColumn: some View {
        VStack(spacing: 0) {
            SearchField(text: $searchText, placeholder: String(localized: "Search notes"))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            List(selection: $selection) {
                if isInProgress {
                    liveRow.tag(Self.liveTag)
                }
                if searchText.isEmpty {
                    ForEach(groups, id: \.label) { group in
                        Section(LocalizedStringKey(group.label)) {
                            ForEach(group.items) { noteRow($0) }
                        }
                    }
                } else {
                    Section("Results") {
                        ForEach(results) { noteRow($0) }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .onDeleteCommand { requestDelete(paths: selection) }
            .contextMenu(forSelectionType: String.self) { paths in
                contextMenu(for: paths)
            }
            .overlay {
                if history.history.isEmpty && !isLive {
                    ContentUnavailableView("No notes yet", systemImage: "note.text",
                                           description: Text("Press New Note to record a meeting or a thought."))
                } else if !searchText.isEmpty && results.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .background(DS.Colors.rowFill.opacity(0.5))
        .popover(item: $renaming) { item in
            VStack(alignment: .leading, spacing: 8) {
                TextField("Title", text: $draftTitle)
                    .frame(width: 260)
                    .onSubmit { history.rename(item, to: draftTitle); renaming = nil }
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = nil }
                    Button("Rename") { history.rename(item, to: draftTitle); renaming = nil }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func contextMenu(for paths: Set<String>) -> some View {
        let items = history.history.filter { paths.contains($0.filePath) }
        if items.count == 1, let item = items.first {
            let isFavorite = item.isFavorite ?? false
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites") { history.toggleFavorite(item) }
            Button("Rename…") { draftTitle = item.title; renaming = item }
            if item.fileExists {
                Divider()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.filePath)])
                }
                Button("Copy Text") {
                    if let text = item.transcriptionText {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            }
            Divider()
        }
        if !items.isEmpty {
            Button(items.count == 1 ? String(localized: "Move to Trash…")
                                    : String(localized: "Move \(items.count) Notes to Trash…"),
                   role: .destructive) {
                pendingDelete = items
            }
        }
    }

    private var liveRow: some View {
        HStack(spacing: 8) {
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "hourglass")
                .foregroundStyle(DS.Colors.recording)
                .symbolEffect(.pulse, options: .repeating, isActive: recorder.isRecording)
            VStack(alignment: .leading, spacing: 2) {
                Text(liveRowTitle)
                    .lineLimit(1)
                Text(recorder.isRecording ? AppUtil.formatElapsed(recorder.elapsed)
                     : (isLive ? String(localized: "Saving…") : String(localized: "Transcribing…")))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var liveRowTitle: String {
        if isLive, !recorder.liveTitle.isEmpty { return recorder.liveTitle }
        if !isLive, !tm.currentTranscriptionTitle.isEmpty { return tm.currentTranscriptionTitle }
        return String(localized: "New note")
    }

    private func noteRow(_ item: TranscriptionHistoryItem) -> some View {
        let source = item.sourceType ?? .file
        let isFavorite = item.isFavorite ?? false
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(item.title).lineLimit(1)
                if isFavorite {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                }
            }
            HStack(spacing: 4) {
                Image(systemName: source.icon).foregroundStyle(source.tint)
                Text(item.fileExists ? TranscriptRow.meta(for: item) : String(localized: "Missing"))
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .tag(item.filePath)
        // While recording, the live note stays open.
        .disabled(isLive)
    }

    // MARK: - Note detail

    @ViewBuilder
    private var noteDetail: some View {
        if selection.count > 1 {
            multipleSelected
        } else if single == Self.liveTag, isLive || (tm.showTranscriptionView && tm.currentTranscriptSource == .meeting) {
            MeetingPage(onBack: { selection = [] })
        } else if single != nil, tm.showTranscriptionView {
            if tm.currentTranscriptSource == .meeting {
                MeetingPage(onBack: { selection = [] })
            } else {
                TranscriptionResultView(transcriptionManager: tm)
            }
        } else {
            emptyState
        }
    }

    private var multipleSelected: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("\(selection.count) notes selected")
                .font(.title2.weight(.semibold))
            Button(role: .destructive) {
                requestDelete(paths: selection)
            } label: {
                Label("Move to Trash…", systemImage: "trash")
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            if case .error(let message, let kind) = recorder.state {
                errorBanner(message, kind)
            }
            Image(systemName: "waveform")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Text("Take a note by talking")
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                Text("Write while MindExtract listens — you see the words as they're spoken, and it tells who's speaking when you're more than one.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            Button {
                startNote()
            } label: {
                Label("New Note", systemImage: "record.circle")
            }
            .buttonStyle(.glassProminent)
            .tint(DS.Colors.recording)
            .controlSize(.extraLarge)
            .disabled(recorder.isBusy)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ message: String, _ kind: MeetingRecorder.ErrorKind) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).frame(maxWidth: .infinity, alignment: .leading)
            switch kind {
            case .screenPermission:
                Button("Open Settings") { recorder.openScreenRecordingSettings() }
            case .micPermission:
                Button("Open Settings") { recorder.openMicSettings() }
            case .capture:
                EmptyView()
            }
            Button("Dismiss") { recorder.dismissError() }
        }
        .frame(maxWidth: 520)
        .contentCard(tint: .orange)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if recorder.isRecording {
                Button {
                    recorder.stop()
                } label: {
                    Label("Finish · \(AppUtil.formatElapsed(recorder.elapsed))", systemImage: "stop.fill")
                        .labelStyle(.titleAndIcon)
                        .monospacedDigit()
                }
                .buttonStyle(.glassProminent)
                .tint(DS.Colors.recording)
                .keyboardShortcut(".", modifiers: .command)
                .help("Finish: the whole conversation is transcribed and your notes are written (⌘.)")
            } else {
                Button {
                    startNote()
                } label: {
                    Label("New Note", systemImage: "record.circle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.glassProminent)
                .tint(DS.Colors.recording)
                .disabled(recorder.isBusy)
                .help("Start a note: records your voice and, in a call, the others (⌘N)")
            }
        }
    }

    // MARK: - Actions

    private var deleteTitle: String {
        pendingDelete.count == 1
            ? String(localized: "Move “\(pendingDelete[0].title)” to the Trash?")
            : String(localized: "Move \(pendingDelete.count) notes to the Trash?")
    }

    private func requestDelete(paths: Set<String>) {
        let items = history.history.filter { paths.contains($0.filePath) }
        if !items.isEmpty { pendingDelete = items }
    }

    private func show(_ s: AppSection, select path: String) {
        section = s
        selection = [path]
    }

    private func startNote() {
        guard !recorder.isBusy else { return }
        section = .notes
        recorder.startNote()
    }

    private func open(_ path: String?) {
        guard let path, path != Self.liveTag else { return }
        // Already showing it (e.g. selection synced after a transcription finished).
        if tm.showTranscriptionView && tm.lastSavedPath == path { return }
        guard let item = history.history.first(where: { $0.filePath == path }), item.fileExists else { return }
        tm.openTranscriptionFromHistory(item)
    }
}

// MARK: - Windows

enum MainWindow {
    static let id = "main"

    /// Captured from the app's commands at launch, so AppKit code (menu bar,
    /// recording pill, Dock) can reopen the main window after it was closed.
    @MainActor static var opener: OpenWindowAction?

    /// Brings the main window forward, opening it if it was closed.
    @MainActor
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(id) == true }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            opener?(id: id)
        }
    }

    /// Brings the main window forward on a given section.
    @MainActor
    static func show(_ section: AppSection) {
        UserDefaults.standard.set(section.rawValue, forKey: "appSection")
        show()
        NotificationCenter.default.post(name: .showSection, object: section)
    }
}

// MARK: - Small app-wide helpers

enum AppUtil {
    /// Relaunch the app (needed for the Screen Recording permission to take effect).
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.4; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    static func formatElapsed(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
