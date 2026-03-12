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

    @State private var selectedTab: ActivityTab = .downloads

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("Activity", selection: $selectedTab) {
                ForEach(ActivityTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)

            Divider()

            // Content
            switch selectedTab {
            case .downloads:
                downloadsContent
            case .transcriptions:
                transcriptionsContent
            }
        }
    }

    // MARK: - Downloads Tab

    @ViewBuilder
    private var downloadsContent: some View {
        if historyManager.history.isEmpty {
            emptyState(
                icon: "arrow.down.circle",
                title: "No Downloads",
                subtitle: "Downloaded videos appear here"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(historyManager.history.prefix(30)) { item in
                        DownloadHistoryRow(item: item, downloadPath: settings.downloadPath)
                            .contextMenu {
                                Button("Copy URL") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(item.url, forType: .string)
                                }
                                Divider()
                                Button("Remove from History", role: .destructive) {
                                    historyManager.removeFromHistory(item)
                                }
                            }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Transcriptions Tab

    @ViewBuilder
    private var transcriptionsContent: some View {
        if transcriptionHistory.history.isEmpty {
            emptyState(
                icon: "text.bubble",
                title: "No Transcriptions",
                subtitle: "Your transcriptions appear here"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(transcriptionHistory.history.prefix(30)) { item in
                        TranscriptionHistoryRow(item: item) {
                            // Open transcription in viewer
                            transcriptionManager.openTranscriptionFromHistory(item)
                        }
                        .contextMenu {
                            if item.fileExists {
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
                            Button("Remove from History", role: .destructive) {
                                transcriptionHistory.removeFromHistory(item)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Empty State

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.4))
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

// MARK: - Download History Row

struct DownloadHistoryRow: View {
    let item: HistoryItem
    let downloadPath: String

    private var timeAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: item.downloadDate, relativeTo: Date())
    }

    var body: some View {
        HStack(spacing: 10) {
            // Type indicator
            Image(systemName: item.isAudioOnly ? "music.note" : "film")
                .font(.system(size: 12))
                .foregroundColor(item.isAudioOnly ? .purple : .blue)
                .frame(width: 20)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .foregroundColor(.primary)

                HStack(spacing: 4) {
                    Text(item.platform)
                        .font(.caption)
                    Text("•")
                        .font(.caption)
                    Text(timeAgo)
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }

            Spacer(minLength: 4)

            // Open folder button
            Button(action: {
                // Try to find the file in downloads, otherwise open the folder
                let folderURL = URL(fileURLWithPath: downloadPath)
                NSWorkspace.shared.open(folderURL)
            }) {
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open Downloads folder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Transcription History Row

struct TranscriptionHistoryRow: View {
    let item: TranscriptionHistoryItem
    let onSelect: () -> Void

    private var timeAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: item.transcriptionDate, relativeTo: Date())
    }

    var body: some View {
        Button(action: {
            if item.fileExists {
                onSelect()
            }
        }) {
            HStack(spacing: 10) {
                // Icon
                Image(systemName: "doc.text")
                    .font(.system(size: 12))
                    .foregroundColor(item.fileExists ? .orange : .gray)
                    .frame(width: 20)

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(2)
                        .foregroundColor(item.fileExists ? .primary : .secondary)

                    HStack(spacing: 4) {
                        Text(item.modelUsed)
                            .font(.caption)
                        Text("•")
                            .font(.caption)
                        Text(timeAgo)
                            .font(.caption)
                        if !item.fileExists {
                            Text("• Missing")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                    .foregroundColor(.secondary)
                }

                Spacer(minLength: 4)

                // Chevron to indicate it's clickable
                if item.fileExists {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.5))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.fileExists)
    }
}

#Preview {
    RecentActivityView()
        .frame(width: 300, height: 400)
}
