import SwiftUI
import AppKit


struct RecentActivityView: View {
    @ObservedObject var historyManager = HistoryManager.shared
    @ObservedObject var transcriptionHistory = TranscriptionHistoryManager.shared
    @ObservedObject var transcriptionManager = TranscriptionManager.shared
    @ObservedObject var settings = AppSettings.shared

    var onRedownload: ((HistoryItem) -> Void)? = nil
    var onTranscribe: ((HistoryItem) -> Void)? = nil

    @State private var searchText = ""
    @State private var showClearDownloadsConfirmation = false
    @State private var mediaFilter: MediaFilter = .all
    @State private var sortMode: SortMode = .newest

    enum MediaFilter: String, CaseIterable { case all = "All", video = "Video", audio = "Audio" }
    enum SortMode: String, CaseIterable {
        case newest = "Newest", oldest = "Oldest", title = "Title"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search + clear row (History = downloads; transcripts live under Transcripts)
            if !historyManager.history.isEmpty {
                HStack(spacing: 8) {
                    SearchField(text: $searchText)

                    // Filter (All / Video / Audio) + sort.
                    Menu {
                        Picker("Show", selection: $mediaFilter) {
                            ForEach(MediaFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Divider()
                        Picker("Sort by", selection: $sortMode) {
                            ForEach(SortMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 14))
                            .foregroundColor(mediaFilter == .all && sortMode == .newest ? .secondary : .accentColor)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Filter and sort")

                    Button(action: { showClearDownloadsConfirmation = true }) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundColor(.red.opacity(0.85))
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Clear download history")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Divider()
            }

            downloadsContent
        }
        .confirmationDialog("Clear all download history?", isPresented: $showClearDownloadsConfirmation, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) { historyManager.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This cannot be undone.") }
    }

    // MARK: - Helpers

    // MARK: - Downloads Tab

    private var filteredDownloads: [HistoryItem] {
        var items = historyManager.history
        switch mediaFilter {
        case .all:   break
        case .video: items = items.filter { !$0.isAudioOnly }
        case .audio: items = items.filter { $0.isAudioOnly }
        }
        if !searchText.isEmpty {
            items = items.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.platform.localizedCaseInsensitiveContains(searchText)
            }
        }
        switch sortMode {
        case .newest: items.sort { $0.downloadDate > $1.downloadDate }
        case .oldest: items.sort { $0.downloadDate < $1.downloadDate }
        case .title:  items.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        return items
    }

    private var groupedDownloads: [(label: String, items: [HistoryItem])] {
        groupHistoryByDate(filteredDownloads, date: { $0.downloadDate })
    }

    @ViewBuilder
    private var downloadsContent: some View {
        if historyManager.history.isEmpty {
            emptyState(icon: "arrow.down.circle", title: "No Downloads", subtitle: "Downloaded videos appear here")
        } else if filteredDownloads.isEmpty {
            noSearchResults
        } else {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(groupedDownloads, id: \.label) { group in
                        Section {
                            VStack(spacing: 4) {
                                ForEach(group.items) { item in
                                    DownloadHistoryRowImproved(
                                        item: item,
                                        downloadPath: settings.downloadPath,
                                        onRedownload: onRedownload != nil ? { onRedownload?(item) } : nil,
                                        onRemove: { historyManager.removeFromHistory(item) },
                                        onTranscribe: onTranscribe != nil ? { onTranscribe?(item) } : nil
                                    )
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                        } header: {
                            HistoryGroupHeader(label: group.label, count: group.items.count)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Shared helpers

    private var noSearchResults: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundColor(.secondary.opacity(0.35))
            Text("No results for \"\(searchText)\"")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.35))
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Download History Row (improved)

struct DownloadHistoryRowImproved: View {
    let item: HistoryItem
    let downloadPath: String
    let onRedownload: (() -> Void)?
    let onRemove: () -> Void
    var onTranscribe: (() -> Void)? = nil

    private var isMissing: Bool { item.hasKnownPath && !item.fileExists }

    /// Reveal the actual file if we know where it is, else just open the folder.
    private func revealInFinder() {
        if let path = item.filePath, item.fileExists {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: downloadPath))
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            // Type icon
            Image(systemName: item.isAudioOnly ? "music.note" : "film")
                .font(.system(size: 13))
                .foregroundColor(isMissing ? .secondary : (item.isAudioOnly ? .purple : DS.Colors.accent))
                .frame(width: 22)

            // Info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(item.title)
                        .font(DS.Typography.rowTitle)
                        .lineLimit(1)
                        .foregroundColor(isMissing ? .secondary : .primary)

                    if item.isAudioOnly {
                        Text("MP3")
                            .font(.caption)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.12))
                            .foregroundColor(.purple)
                            .cornerRadius(3)
                    }

                    if isMissing {
                        Text("Missing")
                            .font(.caption)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.12))
                            .foregroundColor(.orange)
                            .cornerRadius(3)
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: Platform.detect(from: item.url).icon)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(item.platform)
                        .font(.caption)
                        .chromeText()
                    if let res = item.resolution, !res.isEmpty {
                        Text("·").font(.caption)
                        Text(res).font(.caption).chromeText()
                    }
                    if let size = item.fileSize {
                        Text("·")
                            .font(.caption)
                        Text(size)
                            .font(.caption)
                            .chromeText()
                    }
                }
                .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            // Actions (always visible)
            HStack(spacing: 2) {
                if let onTranscribe, item.fileExists, item.hasKnownPath {
                    HistoryActionButton(icon: "text.bubble", help: "Transcribe this download", action: onTranscribe)
                }
                if let onRedownload {
                    HistoryActionButton(icon: "arrow.down.circle", help: "Download again", action: onRedownload)
                }
                HistoryActionButton(icon: "doc.on.doc", help: "Copy URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.url, forType: .string)
                }
                HistoryActionButton(icon: "folder", help: isMissing ? "Open downloads folder" : "Show in Finder") {
                    revealInFinder()
                }
                HistoryActionButton(icon: "trash", help: "Remove from history", color: .red, action: onRemove)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .rowChrome()
        .contentShape(Rectangle())
        .onTapGesture { revealInFinder() }
        .contextMenu {
            if let onTranscribe, item.fileExists, item.hasKnownPath {
                Button("Transcribe", action: onTranscribe)
            }
            if let onRedownload {
                Button("Download Again") { onRedownload() }
            }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url, forType: .string)
            }
            Button(isMissing ? "Open Downloads Folder" : "Show in Finder") { revealInFinder() }
            Divider()
            Button("Remove from History", role: .destructive, action: onRemove)
        }
    }
}

// MARK: - History Action Button

struct HistoryActionButton: View {
    let icon: String
    let help: String
    var color: Color = .secondary
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(color)
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(isHovered ? 0.12 : 0.06))
                .cornerRadius(6)
                // Whole padded square is clickable, not just the glyph.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

// MARK: - Shared history helpers (used by History and Transcripts)

func groupHistoryByDate<T>(_ items: [T], date: (T) -> Date) -> [(label: String, items: [T])] {
    let calendar = Calendar.current
    let now = Date()
    var today: [T] = []
    var yesterday: [T] = []
    var thisWeek: [T] = []
    var older: [T] = []
    for item in items {
        let d = date(item)
        if calendar.isDateInToday(d) {
            today.append(item)
        } else if calendar.isDateInYesterday(d) {
            yesterday.append(item)
        } else if let days = calendar.dateComponents([.day], from: d, to: now).day, days < 7 {
            thisWeek.append(item)
        } else {
            older.append(item)
        }
    }
    return [("Today", today), ("Yesterday", yesterday), ("This Week", thisWeek), ("Older", older)]
        .filter { !$0.items.isEmpty }
}

struct HistoryGroupHeader: View {
    let label: String
    let count: Int

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Spacer()
            Text("\(count)")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(DS.Colors.backdrop)
    }
}

// MARK: - Transcripts List (mirrors the History layout)

struct TranscriptsListView: View {
    @ObservedObject var transcriptionHistory = TranscriptionHistoryManager.shared
    @ObservedObject var transcriptionManager = TranscriptionManager.shared

    var onGoToMedia: (() -> Void)? = nil

    @State private var searchText = ""
    @State private var showClearConfirmation = false

    private var filteredTranscripts: [TranscriptionHistoryItem] {
        guard !searchText.isEmpty else { return transcriptionHistory.history }
        return transcriptionHistory.history.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var groupedTranscripts: [(label: String, items: [TranscriptionHistoryItem])] {
        groupHistoryByDate(filteredTranscripts, date: { $0.transcriptionDate })
    }

    var body: some View {
        VStack(spacing: 0) {
            if !transcriptionHistory.history.isEmpty {
                HStack(spacing: 8) {
                    SearchField(text: $searchText)

                    Button(action: { showClearConfirmation = true }) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundColor(.red.opacity(0.85))
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Clear all transcripts")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Divider()
            }

            content
        }
        .confirmationDialog("Clear all transcripts?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) { transcriptionHistory.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes the list — saved transcript files stay on disk.") }
    }

    @ViewBuilder
    private var content: some View {
        if transcriptionHistory.history.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "text.bubble")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary.opacity(0.35))
                Text("No transcripts yet")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                Text("Transcribe a video or file from Media — your transcripts appear here")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.7))
                if let onGoToMedia {
                    Button(action: onGoToMedia) {
                        Label("Go to Media", systemImage: "tray.and.arrow.down")
                    }
                    .secondaryGlassButton()
                    .padding(.top, 2)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if filteredTranscripts.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary.opacity(0.35))
                Text("No results for \"\(searchText)\"")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(groupedTranscripts, id: \.label) { group in
                        Section {
                            VStack(spacing: 4) {
                                ForEach(group.items) { item in
                                    TranscriptHistoryRow(
                                        item: item,
                                        onOpen: {
                                            if item.fileExists {
                                                transcriptionManager.openTranscriptionFromHistory(item)
                                            }
                                        },
                                        onRemove: { transcriptionHistory.removeFromHistory(item) },
                                        onRename: { transcriptionHistory.rename(item, to: $0) }
                                    )
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                        } header: {
                            HistoryGroupHeader(label: group.label, count: group.items.count)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Transcript Row (mirrors DownloadHistoryRowImproved)

struct TranscriptHistoryRow: View {
    let item: TranscriptionHistoryItem
    let onOpen: () -> Void
    let onRemove: () -> Void
    var onRename: (String) -> Void = { _ in }

    @State private var isRenaming = false
    @State private var draftTitle = ""

    private func beginRename() {
        draftTitle = item.title
        isRenaming = true
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 13))
                .foregroundColor(item.fileExists ? DS.Colors.accent : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(item.title)
                        .font(DS.Typography.rowTitle)
                        .lineLimit(1)
                        .foregroundColor(item.fileExists ? .primary : .secondary)

                    if !item.fileExists {
                        Text("Missing")
                            .font(.caption)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.12))
                            .foregroundColor(.orange)
                            .cornerRadius(3)
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if let duration = item.duration {
                        Text(duration)
                            .font(.caption)
                            .chromeText()
                        Text("·")
                            .font(.caption)
                    }
                    Text(item.transcriptionDate, style: .date)
                        .font(.caption)
                        .chromeText()
                }
                .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            // Actions (always visible — same pattern as download rows)
            HStack(spacing: 2) {
                HistoryActionButton(icon: "pencil", help: "Rename") { beginRename() }
                    .popover(isPresented: $isRenaming) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Rename transcript")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("Title", text: $draftTitle)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                                .onSubmit { onRename(draftTitle); isRenaming = false }
                            HStack {
                                Spacer()
                                Button("Save") { onRename(draftTitle); isRenaming = false }
                                    .keyboardShortcut(.defaultAction)
                            }
                        }
                        .padding(12)
                    }
                if item.fileExists {
                    HistoryActionButton(icon: "folder", help: "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.filePath)])
                    }
                    HistoryActionButton(icon: "doc.on.doc", help: "Copy text") {
                        if let text = try? String(contentsOfFile: item.filePath, encoding: .utf8) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                    }
                }
                HistoryActionButton(icon: "trash", help: "Remove from list", color: .red, action: onRemove)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .rowChrome()
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        .contextMenu {
            if item.fileExists {
                Button("Open Transcript", action: onOpen)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.filePath)])
                }
                Button("Copy Text") {
                    if let text = try? String(contentsOfFile: item.filePath, encoding: .utf8) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            }
            Button("Rename…") { beginRename() }
            Divider()
            Button("Remove from List", role: .destructive, action: onRemove)
        }
    }
}

#Preview {
    RecentActivityView()
        .frame(width: 500, height: 500)
}
