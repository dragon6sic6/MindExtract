import SwiftUI

// MARK: - Main window: your notes
//
// One list of everything you've recorded or imported, and the open note beside
// it. "New Note" records (your voice, and the others in a call) with live text;
// downloading from a link lives in its own small window.

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @StateObject private var settings = AppSettings.shared
    @ObservedObject private var tm = TranscriptionManager.shared
    @ObservedObject private var history = TranscriptionHistoryManager.shared
    @ObservedObject private var recorder = MeetingRecorder.shared
    @ObservedObject private var appLock = AppLock.shared

    /// File path of the open note, or `liveTag` for the one in progress (recording,
    /// or being transcribed before it has a file).
    @State private var selection: String?
    private static let liveTag = "live-recording"

    @State private var searchText = ""
    @State private var searchHits: [TranscriptLibrary.SearchHit] = []
    @State private var renaming: TranscriptionHistoryItem?
    @State private var draftTitle = ""

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
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 360)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(DS.Colors.backdrop.ignoresSafeArea())
                .toolbar { toolbar }
        }
        .navigationTitle("")
        .frame(minWidth: 760, minHeight: 540)
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
            if isLive { selection = Self.liveTag }
            // A link handed over at launch goes straight to the download window.
            if UserDefaults.standard.string(forKey: "pendingURL")?.isEmpty == false {
                openWindow(id: DownloaderWindow.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            openSettings()
        }
        // Keep the list selection in step with what's open.
        .onChange(of: selection) { _, path in open(path) }
        .onChange(of: tm.showTranscriptionView) { _, show in
            if show { selection = tm.lastSavedPath ?? Self.liveTag }
        }
        .onChange(of: tm.lastSavedPath) { _, p in
            if tm.showTranscriptionView, let p, selection != Self.liveTag || !isLive { selection = p }
        }
        .onChange(of: recorder.isRecording) { _, recording in
            if recording { selection = Self.liveTag }
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
                        if item.fileExists { selection = item.filePath }
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
        .task(id: searchText) {
            // Debounce keystrokes; search reads files so we don't run it per frame.
            guard !searchText.isEmpty else { searchHits = []; return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            searchHits = TranscriptLibrary.shared.search(searchText)
        }
    }

    // MARK: - Sidebar

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

    private var sidebar: some View {
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
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar, prompt: Text("Search notes"))
        .overlay {
            if history.history.isEmpty && !isLive {
                ContentUnavailableView("No notes yet", systemImage: "note.text",
                                       description: Text("Your notes and transcripts show up here."))
            } else if !searchText.isEmpty && results.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
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
        .contextMenu {
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
            Button("Remove from List", role: .destructive) {
                if selection == item.filePath { selection = nil }
                history.removeFromHistory(item)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if selection == Self.liveTag, isLive || (tm.showTranscriptionView && tm.currentTranscriptSource == .meeting) {
            MeetingPage(onBack: { selection = nil })
        } else if selection != nil, tm.showTranscriptionView {
            if tm.currentTranscriptSource == .meeting {
                MeetingPage(onBack: { selection = nil })
            } else {
                TranscriptionResultView(transcriptionManager: tm)
            }
        } else {
            emptyState
        }
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
            HStack(spacing: 12) {
                Button {
                    startNote()
                } label: {
                    Label("New Note", systemImage: "record.circle")
                }
                .buttonStyle(.glassProminent)
                .tint(DS.Colors.recording)
                .controlSize(.extraLarge)
                .disabled(recorder.isBusy)
                Button {
                    openWindow(id: DownloaderWindow.id)
                } label: {
                    Label("Download from Link…", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.glass)
                .controlSize(.extraLarge)
            }
            if settings.dictationEnabled {
                Label("Hold right ⌥ Option anywhere to dictate into any app.", systemImage: "mic")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
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
            Button {
                openWindow(id: DownloaderWindow.id)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .help("Download the video or audio behind a link (⇧⌘D)")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
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

    private func startNote() {
        guard !recorder.isBusy else { return }
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

enum DownloaderWindow {
    static let id = "downloader"
}

enum MainWindow {
    static let id = "main"

    /// Captured from the app's commands at launch, so AppKit code (menu bar,
    /// recording pill, Dock) can reopen the notes window after it was closed.
    @MainActor static var opener: OpenWindowAction?

    /// Brings the notes window forward, opening it if it was closed.
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

    @MainActor
    static func bringToFront(_ openWindow: OpenWindowAction) {
        if opener == nil { opener = openWindow }
        show()
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
