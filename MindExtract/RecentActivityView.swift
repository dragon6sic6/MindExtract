import SwiftUI
import AppKit

enum ActivityTab: String, CaseIterable {
    case downloads = "Downloads"
    case transcriptions = "Transcriptions"
}

struct RecentActivityView: View {
    @ObservedObject var historyManager = HistoryManager.shared
    @ObservedObject var transcriptionHistory = TranscriptionHistoryManager.shared
    @ObservedObject var transcriptionManager = TranscriptionManager.shared
    @ObservedObject var settings = AppSettings.shared

    var onRedownload: ((HistoryItem) -> Void)? = nil

    @State private var selectedTab: ActivityTab = .downloads
    @State private var searchText = ""
    @State private var showClearDownloadsConfirmation = false
    @State private var showClearTranscriptionsConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker + search row
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Picker("Activity", selection: $selectedTab) {
                        ForEach(ActivityTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    // Clear all button
                    if canClearCurrentTab {
                        Button(action: {
                            if selectedTab == .downloads {
                                showClearDownloadsConfirmation = true
                            } else {
                                showClearTranscriptionsConfirmation = true
                            }
                        }) {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear all \(selectedTab.rawValue.lowercased())")
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

                // Search bar
                if hasItemsInCurrentTab {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Search…", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.subheadline)
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(7)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: selectedTab)

            Divider()

            // Content
            switch selectedTab {
            case .downloads:
                downloadsContent
            case .transcriptions:
                transcriptionsContent
            }
        }
        .confirmationDialog("Clear all download history?", isPresented: $showClearDownloadsConfirmation, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) { historyManager.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This cannot be undone.") }
        .confirmationDialog("Clear all transcription history?", isPresented: $showClearTranscriptionsConfirmation, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) { transcriptionHistory.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This cannot be undone.") }
    }

    // MARK: - Helpers

    private var canClearCurrentTab: Bool {
        selectedTab == .downloads ? !historyManager.history.isEmpty : !transcriptionHistory.history.isEmpty
    }

    private var hasItemsInCurrentTab: Bool {
        selectedTab == .downloads ? !historyManager.history.isEmpty : !transcriptionHistory.history.isEmpty
    }

    // MARK: - Downloads Tab

    private var filteredDownloads: [HistoryItem] {
        guard !searchText.isEmpty else { return historyManager.history }
        return historyManager.history.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.platform.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var groupedDownloads: [(label: String, items: [HistoryItem])] {
        groupByDate(filteredDownloads, date: { $0.downloadDate })
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
                            groupHeader(label: group.label, count: group.items.count)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Transcriptions Tab

    private var filteredTranscriptions: [TranscriptionHistoryItem] {
        guard !searchText.isEmpty else { return transcriptionHistory.history }
        return transcriptionHistory.history.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var groupedTranscriptions: [(label: String, items: [TranscriptionHistoryItem])] {
        groupByDate(filteredTranscriptions, date: { $0.transcriptionDate })
    }

    @ViewBuilder
    private var transcriptionsContent: some View {
        if transcriptionHistory.history.isEmpty {
            emptyState(icon: "text.bubble", title: "No Transcriptions", subtitle: "Your transcriptions appear here")
        } else if filteredTranscriptions.isEmpty {
            noSearchResults
        } else {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(groupedTranscriptions, id: \.label) { group in
                        Section {
                            VStack(spacing: 4) {
                                ForEach(group.items) { item in
                                    TranscriptionHistoryRowImproved(
                                        item: item,
                                        onSelect: {
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
                            groupHeader(label: group.label, count: group.items.count)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Shared helpers

    private func groupHeader(label: String, count: Int) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Spacer()
            Text("\(count)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func groupByDate<T>(_ items: [T], date: (T) -> Date) -> [(label: String, items: [T])] {
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
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .foregroundColor(.primary)

                    if item.isAudioOnly {
                        Text("MP3")
                            .font(.caption2)
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
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
        )
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

// MARK: - Transcription History Row (improved)

struct TranscriptionHistoryRowImproved: View {
    let item: TranscriptionHistoryItem
    let onSelect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Icon
            Image(systemName: "text.document")
                .font(.system(size: 13))
                .foregroundColor(item.fileExists ? .orange : .secondary)
                .frame(width: 22)

            // Info
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .foregroundColor(item.fileExists ? .primary : .secondary)

                HStack(spacing: 4) {
                    Text(item.modelUsed)
                        .font(.caption)
                    if !item.fileExists {
                        Text("· Missing")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .foregroundColor(.secondary)
            }

            Spacer(minLength: 4)

            // Actions (always visible)
            HStack(spacing: 2) {
                if item.fileExists {
                    HistoryActionButton(icon: "doc.text.magnifyingglass", help: "View transcription", action: onSelect)
                    HistoryActionButton(icon: "folder", help: "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.filePath)])
                    }
                    HistoryActionButton(icon: "doc.on.doc", help: "Copy text") {
                        if let text = item.transcriptionText {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                    }
                }
                HistoryActionButton(icon: "trash", help: "Remove from history", color: .red, action: onRemove)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
        )
        .onTapGesture { if item.fileExists { onSelect() } }
        .contextMenu {
            if item.fileExists {
                Button("View Transcription", action: onSelect)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.filePath)])
                }
                Button("Copy Text") {
                    if let text = item.transcriptionText {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
                Divider()
            }
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
                .font(.caption)
                .foregroundColor(color)
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

#Preview {
    RecentActivityView()
        .frame(width: 500, height: 500)
}
