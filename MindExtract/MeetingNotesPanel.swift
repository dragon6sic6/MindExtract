import SwiftUI
import AppKit

// MARK: - Notes tab (enhanced meeting notes)
//
// Your words in the primary color, what the AI added from the transcript in the
// secondary color, and a ▶ chip on each line that plays that moment of the
// recording. "My notes" shows exactly what you typed.

struct MeetingNotesPanel<Summary: View>: View {
    enum Mode: Hashable { case enhanced, mine, summary }

    let path: String?
    let userNotes: String?
    let segments: [TranscriptionSegmentData]
    let isTranscribing: Bool
    let hasAudio: Bool
    var onSeek: (Double) -> Void
    /// The summary / note-style view, shown under "Summary".
    @ViewBuilder var summary: () -> Summary

    @ObservedObject private var manager = TranscriptionManager.shared
    @State private var enhanced: EnhancedNotes?
    @State private var consentAt: Double?
    @State private var mode: Mode = .enhanced
    @State private var copied = false

    private var notesText: String { (userNotes ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isEnhancing: Bool { path.map { manager.enhancingPaths.contains($0) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            if mode == .summary {
                summary()
            } else {
                notesScroll
            }
        }
        .onAppear(perform: load)
        .onChange(of: path) { _, _ in load() }
        .onReceive(NotificationCenter.default.publisher(for: .enhancedNotesUpdated)) { note in
            if (note.object as? String) == path { load() }
        }
    }

    private var notesScroll: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let consentAt {
                        Label("Everyone agreed to the recording · \(EnhancedNotesGenerator.clock(consentAt))",
                              systemImage: "checkmark.shield")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.green)
                    }
                    content
                }
                .padding(.horizontal, DS.Layout.pageHorizontal).padding(.vertical, 24)
                .frame(maxWidth: DS.Layout.readingWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Picker("Show", selection: $mode) {
                Text("Notes").tag(Mode.enhanced)
                if !notesText.isEmpty {
                    Text("What I wrote").tag(Mode.mine)
                }
                Text("Summary").tag(Mode.summary)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            if mode == .summary {
                EmptyView()
            } else if let enhanced, mode == .enhanced {
                Text(enhanced.badge)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(enhanced.markdown, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .secondaryGlassButton()
            }
            if mode != .summary {
            Button {
                enhance()
            } label: {
                Label(enhanced == nil ? "Enhance notes" : "Regenerate",
                      systemImage: enhanced == nil ? "sparkles" : "arrow.clockwise")
            }
            .primaryGlassButton()
            .disabled(isEnhancing || isTranscribing || segments.isEmpty)
            .help("Write full notes from your cues and the transcript — with your AI engine from Settings")
            }
        }
        .controlSize(.regular)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if isEnhancing {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Writing your notes from the transcript…").foregroundStyle(.secondary)
            }
        } else if let enhanced, mode == .enhanced {
            enhancedView(enhanced)
        } else if !notesText.isEmpty {
            Text(notesText)
                .font(.title3)
                .lineSpacing(5)
                .textSelection(.enabled)
            if enhanced == nil && !isTranscribing {
                Text("Tap Enhance notes to fill in the details from the transcript.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else if isTranscribing {
            Text("Your notes appear here when the transcript is ready.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("No notes for this meeting").font(.title3.weight(.semibold))
                Text("Enhance notes writes structured notes — decisions, action items and key points — from the transcript alone.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func enhancedView(_ notes: EnhancedNotes) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(notes.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 8) {
                    if !section.heading.isEmpty {
                        Text(section.heading)
                            .font(.title3.weight(.bold))
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                        lineView(line)
                    }
                }
            }
            legend
        }
    }

    private func lineView(_ line: EnhancedNotes.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.tertiary)
            line.parts.reduce(Text("")) { text, part in
                text + Text(part.text).foregroundStyle(part.isUser ? .primary : .secondary)
            }
            .font(.body)
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let at = line.at, hasAudio {
                Button {
                    onSeek(at)
                } label: {
                    Label(EnhancedNotesGenerator.clock(at), systemImage: "play.fill")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .help("Play this moment of the recording")
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            Label { Text("your notes") } icon: { Circle().fill(Color.primary).frame(width: 7, height: 7) }
            Label { Text("added from the transcript") } icon: { Circle().fill(Color.secondary).frame(width: 7, height: 7) }
            if hasAudio {
                Label("plays that moment", systemImage: "play.fill")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 8)
    }

    // MARK: Actions

    private func load() {
        guard let path else { enhanced = nil; consentAt = nil; return }
        let sidecar = TranscriptAIStore.load(for: path)
        enhanced = sidecar?.enhancedNotes
        consentAt = sidecar?.consentConfirmedAt
    }

    private func enhance() {
        guard let path else { return }
        mode = .enhanced
        manager.generateEnhancedNotes(path: path, userNotes: notesText, segments: segments)
    }
}
