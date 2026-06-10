import SwiftUI
import AppKit


struct RecentActivityView: View {
    @ObservedObject var historyManager = HistoryManager.shared
    @ObservedObject var transcriptionHistory = TranscriptionHistoryManager.shared
    @ObservedObject var transcriptionManager = TranscriptionManager.shared
    @ObservedObject var settings = AppSettings.shared

    var onRedownload: ((HistoryItem) -> Void)? = nil

    @State private var searchText = ""
    @State private var showClearDownloadsConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Search + clear row (History = downloads; transcripts live under Transcripts)
            if !historyManager.history.isEmpty {
                HStack(spacing: 8) {
                    SearchField(text: $searchText)

                    Button(action: { showClearDownloadsConfirmation = true }) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
        guard !searchText.isEmpty else { return historyManager.history }
        return historyManager.history.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.platform.localizedCaseInsensitiveContains(searchText)
        }
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
                                        onRemove: { historyManager.removeFromHistory(item) }
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

    var body: some View {
        HStack(spacing: 10) {
            // Type icon
            Image(systemName: item.isAudioOnly ? "music.note" : "film")
                .font(.system(size: 13))
                .foregroundColor(item.isAudioOnly ? .purple : .blue)
                .frame(width: 22)

            // Info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(item.title)
                        .font(DS.Typography.rowTitle)
                        .lineLimit(1)
                        .foregroundColor(.primary)

                    if item.isAudioOnly {
                        Text("MP3")
                            .font(.caption)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.12))
                            .foregroundColor(.purple)
                            .cornerRadius(3)
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: Platform.detect(from: item.url).icon)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(item.platform)
                        .font(.caption)
                    if let size = item.fileSize {
                        Text("·")
                            .font(.caption)
                        Text(size)
                            .font(.caption)
                    }
                }
                .foregroundColor(.secondary)
            }

            Spacer(minLength: 4)

            // Actions (always visible)
            HStack(spacing: 2) {
                if let onRedownload {
                    HistoryActionButton(icon: "arrow.down.circle", help: "Download again", action: onRedownload)
                }
                HistoryActionButton(icon: "doc.on.doc", help: "Copy URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.url, forType: .string)
                }
                HistoryActionButton(icon: "folder", help: "Open downloads folder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: downloadPath))
                }
                HistoryActionButton(icon: "trash", help: "Remove from history", color: .red, action: onRemove)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .rowChrome()
        .contextMenu {
            if let onRedownload {
                Button("Download Again") { onRedownload() }
            }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url, forType: .string)
            }
            Button("Open Downloads Folder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: downloadPath))
            }
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

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(color)
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.06))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
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
                            .foregroundColor(.secondary)
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
                                        onRemove: { transcriptionHistory.removeFromHistory(item) }
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
                        Text("·")
                            .font(.caption)
                    }
                    Text(item.transcriptionDate, style: .date)
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }

            Spacer(minLength: 4)

            // Actions (always visible — same pattern as download rows)
            HStack(spacing: 2) {
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
                Divider()
            }
            Button("Remove from List", role: .destructive, action: onRemove)
        }
    }
}

#Preview {
    RecentActivityView()
        .frame(width: 500, height: 500)
}
