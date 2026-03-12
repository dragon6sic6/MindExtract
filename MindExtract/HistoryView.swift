import SwiftUI

struct HistoryView: View {
    @ObservedObject var historyManager = HistoryManager.shared
    @Environment(\.dismiss) var dismiss
    var onRedownload: (HistoryItem) -> Void

    @State private var searchText = ""
    @State private var showClearConfirmation = false

    private var filtered: [HistoryItem] {
        guard !searchText.isEmpty else { return historyManager.history }
        return historyManager.history.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.platform.localizedCaseInsensitiveContains(searchText)
        }
    }

    // Group items by relative date bucket
    private var groupedItems: [(label: String, items: [HistoryItem])] {
        let calendar = Calendar.current
        let now = Date()
        var today: [HistoryItem] = []
        var yesterday: [HistoryItem] = []
        var thisWeek: [HistoryItem] = []
        var older: [HistoryItem] = []

        for item in filtered {
            if calendar.isDateInToday(item.downloadDate) {
                today.append(item)
            } else if calendar.isDateInYesterday(item.downloadDate) {
                yesterday.append(item)
            } else if let days = calendar.dateComponents([.day], from: item.downloadDate, to: now).day, days < 7 {
                thisWeek.append(item)
            } else {
                older.append(item)
            }
        }

        return [
            ("Today", today),
            ("Yesterday", yesterday),
            ("This Week", thisWeek),
            ("Older", older)
        ].filter { !$0.items.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("History")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                if !historyManager.history.isEmpty {
                    Button(action: { showClearConfirmation = true }) {
                        Label("Clear All", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Search bar
            if !historyManager.history.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                    TextField("Search history…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            Divider()

            if historyManager.history.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("No results for \"\(searchText)\"")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(groupedItems, id: \.label) { group in
                            Section {
                                VStack(spacing: 6) {
                                    ForEach(group.items) { item in
                                        HistoryItemRow(
                                            item: item,
                                            onRedownload: {
                                                dismiss()
                                                onRedownload(item)
                                            },
                                            onRemove: { historyManager.removeFromHistory(item) }
                                        )
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.bottom, 12)
                            } header: {
                                HStack {
                                    Text(group.label)
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.secondary)
                                        .textCase(.uppercase)
                                    Spacer()
                                    Text("\(group.items.count)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.12))
                                        .cornerRadius(4)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color(NSColor.windowBackgroundColor))
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .frame(width: 580, height: 520)
        .confirmationDialog("Clear all download history?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) { historyManager.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 44))
                .foregroundColor(.secondary.opacity(0.4))
            Text("No history yet")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Downloaded videos will appear here")
                .font(.subheadline)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HistoryItemRow: View {
    let item: HistoryItem
    let onRedownload: () -> Void
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            AsyncImage(url: URL(string: item.thumbnail ?? "")) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill).clipped()
                default:
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.15))
                        .overlay(
                            Image(systemName: item.isAudioOnly ? "music.note" : "play.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        )
                }
            }
            .frame(width: 80, height: 45)
            .cornerRadius(6)

            // Info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    if item.isAudioOnly {
                        Text("MP3")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.15))
                            .foregroundColor(.purple)
                            .cornerRadius(4)
                    }
                }

                HStack(spacing: 6) {
                    // Platform icon + name
                    Image(systemName: Platform.detect(from: item.url).icon)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(item.platform)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("·")
                        .foregroundColor(.secondary.opacity(0.5))
                        .font(.caption)

                    Text(item.downloadDate, style: .relative)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let size = item.fileSize {
                        Text("·")
                            .foregroundColor(.secondary.opacity(0.5))
                            .font(.caption)
                        Text(size)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Actions — show on hover
            if isHovered {
                HStack(spacing: 4) {
                    ActionIconButton(icon: "arrow.down.circle", help: "Download again", action: onRedownload)
                    ActionIconButton(icon: "doc.on.doc", help: "Copy URL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.url, forType: .string)
                    }
                    ActionIconButton(icon: "trash", help: "Remove from history", color: .red, action: onRemove)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? Color(NSColor.controlBackgroundColor).opacity(1.0) : Color(NSColor.controlBackgroundColor).opacity(0.6))
        )
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

struct ActionIconButton: View {
    let icon: String
    let help: String
    var color: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundColor(color)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

#Preview {
    HistoryView(onRedownload: { _ in })
}
