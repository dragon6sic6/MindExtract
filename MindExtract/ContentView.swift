import SwiftUI

// MARK: - Main window
//
// MindExtract does one thing: get the words out of any video or audio.
//   • Download — paste a link (YouTube and ~1,000 other sites) or drop a file;
//     download it, transcribe it, or both
//   • Transcripts — read, search, play, summarize, ask, translate and export

enum AppSection: String, CaseIterable, Identifiable {
    case downloads, transcripts

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .downloads: return "Download"
        case .transcripts: return "Transcripts"
        }
    }

    var icon: String {
        switch self {
        case .downloads: return "arrow.down.circle"
        case .transcripts: return "text.quote"
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
    @ObservedObject private var appLock = AppLock.shared

    @AppStorage("appSection") private var section: AppSection = .downloads

    /// File paths of the selected transcripts; `liveTag` stands for the one being
    /// transcribed before it has a file.
    @State private var selection: Set<String> = []
    private static let liveTag = "live-recording"
    private var single: String? { selection.count == 1 ? selection.first : nil }

    @State private var searchText = ""
    @State private var searchHits: [TranscriptLibrary.SearchHit] = []
    @State private var renaming: TranscriptionHistoryItem?
    @State private var draftTitle = ""
    @State private var pendingDelete: [TranscriptionHistoryItem] = []

    // ⌘K search/ask overlay — one stable sheet whose content swaps between the
    // palette and the chat (swapping sheet *identity* would flicker/dismiss).
    enum AppOverlay { case palette, chat }
    @State private var showOverlay = false
    @State private var overlayContent: AppOverlay = .palette

    /// A new transcript is being made and has no file yet.
    private var isInProgress: Bool { tm.isTranscribing && tm.lastSavedPath == nil }

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
        // A transcript opened or started anywhere (e.g. from Download) shows under Transcripts.
        .onChange(of: tm.showTranscriptionView) { _, show in
            if show { self.show(.transcripts, select: tm.lastSavedPath ?? Self.liveTag) }
        }
        .onChange(of: tm.lastSavedPath) { _, p in
            if tm.showTranscriptionView, let p { selection = [p] }
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
            Text("The transcript goes to the Trash. You can put it back from there. A downloaded video stays where it is.")
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
                        if item.fileExists { show(.transcripts, select: item.filePath) }
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
        case .downloads: return downloads.history.count
        case .transcripts: return history.history.count
        }
    }

    @ViewBuilder
    private var sectionDetail: some View {
        VStack(spacing: 0) {
            PianissimoBanner()
            switch section {
            case .downloads:
                DownloaderView()
            case .transcripts:
                HStack(spacing: 0) {
                    transcriptsColumn
                        .frame(width: 280)
                    Divider()
                    transcriptDetail
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }

    // MARK: - Transcripts list

    /// Favorites pinned on top, the rest grouped by date.
    private var groups: [(label: String, items: [TranscriptionHistoryItem])] {
        let items = history.history
        let favs = items.filter { $0.isFavorite ?? false }
        let rest = items.filter { !($0.isFavorite ?? false) }
        let dated = groupHistoryByDate(rest, date: { $0.transcriptionDate })
        return favs.isEmpty ? dated : [(String(localized: "Favorites"), favs)] + dated
    }

    /// Title matches first, then transcripts whose text matches.
    private var results: [TranscriptionHistoryItem] {
        let q = searchText.lowercased()
        let byTitle = history.history.filter { $0.title.lowercased().contains(q) }
        let seen = Set(byTitle.map(\.id))
        return byTitle + searchHits.map(\.item).filter { !seen.contains($0.id) }
    }

    private var transcriptsColumn: some View {
        VStack(spacing: 0) {
            SearchField(text: $searchText, placeholder: String(localized: "Search transcripts"))
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
                if history.history.isEmpty && !isInProgress {
                    ContentUnavailableView("No transcripts yet", systemImage: "text.quote",
                                           description: Text("Paste a link or drop a file under Download."))
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
                                    : String(localized: "Move \(items.count) Transcripts to Trash…"),
                   role: .destructive) {
                pendingDelete = items
            }
        }
    }

    private var liveRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(tm.currentTranscriptionTitle.isEmpty ? String(localized: "Transcribing…") : tm.currentTranscriptionTitle)
                    .lineLimit(1)
                Text("Transcribing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
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
    }

    // MARK: - Transcript detail

    @ViewBuilder
    private var transcriptDetail: some View {
        if selection.count > 1 {
            multipleSelected
        } else if single != nil, tm.showTranscriptionView {
            TranscriptionResultView(transcriptionManager: tm)
        } else {
            emptyState
        }
    }

    private var multipleSelected: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("\(selection.count) transcripts selected")
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
            Image(systemName: "text.quote")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Text(history.history.isEmpty ? "Get the words out of any video" : "Pick a transcript")
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                Text("Paste a link from YouTube or 1,000 other sites, or drop a video or audio file. MindExtract downloads it, transcribes it, or both — on your Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            Button {
                section = .downloads
            } label: {
                Label("Download or Transcribe…", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if section == .transcripts {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    section = .downloads
                } label: {
                    Label("Download or Transcribe…", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.glassProminent)
                .help("Paste a link or drop a file (⌘N)")
            }
        }
    }

    // MARK: - Actions

    private var deleteTitle: String {
        pendingDelete.count == 1
            ? String(localized: "Move “\(pendingDelete[0].title)” to the Trash?")
            : String(localized: "Move \(pendingDelete.count) transcripts to the Trash?")
    }

    private func requestDelete(paths: Set<String>) {
        let items = history.history.filter { paths.contains($0.filePath) }
        if !items.isEmpty { pendingDelete = items }
    }

    private func show(_ s: AppSection, select path: String) {
        section = s
        selection = [path]
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
    /// Dock) can reopen the main window after it was closed.
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
