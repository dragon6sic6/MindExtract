import SwiftUI

struct HistoryView: View {
    @ObservedObject var historyManager = HistoryManager.shared
    @Environment(\.dismiss) var dismiss
    var onRedownload: (HistoryItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Download History")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                if !historyManager.history.isEmpty {
                    Button(action: { historyManager.clearHistory() }) {
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
            .padding()

            Divider()

            if historyManager.history.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No download history yet")
                        .foregroundColor(.secondary)
                    Text("Your downloaded videos will appear here")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(historyManager.history) { item in
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
                    .padding()
                }
            }
        }
        .frame(width: 550, height: 500)
    }
}

struct HistoryItemRow: View {
    let item: HistoryItem
    let onRedownload: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            AsyncImage(url: URL(string: item.thumbnail ?? "")) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill).clipped()
                default:
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.2))
                        .overlay(
                            Image(systemName: item.isAudioOnly ? "music.note" : "play.fill")
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
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.2))
                            .cornerRadius(3)
                    }
                }

                HStack(spacing: 8) {
                    // Platform
                    Text(item.platform)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("•")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Date
                    Text(item.downloadDate, style: .relative)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let size = item.fileSize {
                        Text("•")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(size)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Actions
            HStack(spacing: 8) {
                Button(action: onRedownload) {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .help("Download again")

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.url, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Copy URL")

                Button(action: onRemove) {
                    Image(systemName: "xmark.circle")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Remove from history")
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
}

#Preview {
    HistoryView(onRedownload: { _ in })
}
