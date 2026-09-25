import SwiftUI
import AppKit

// MARK: - Notepad-first recording screen
//
// While a meeting records, the screen is a calm notepad: title, who's there and a
// big editor for rough cues. The live transcript sits in a panel you can fold
// away, and the recording controls float at the bottom on Liquid Glass. After
// Stop, the cues become enhanced notes (EnhancedNotes.swift).

struct MeetingNotepadView: View {
    @ObservedObject private var recorder = MeetingRecorder.shared
    @ObservedObject private var live = MeetingRecorder.shared.live
    @ObservedObject private var captionOverlay = CaptionOverlayController.shared
    @AppStorage("notepadShowsTranscript") private var showTranscript = true
    @FocusState private var notesFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                notepad
                controlBar
                    .padding(.bottom, 22)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showTranscript {
                Divider()
                transcriptPanel
                    .frame(width: 320)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showTranscript)
        .onAppear { notesFocused = true }
    }

    // MARK: Notepad

    private var notepad: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                chip(startedLabel, systemImage: "calendar")
                consentChip
                Spacer(minLength: 0)
            }

            TextField("Meeting title", text: $recorder.liveTitle)
                .textFieldStyle(.plain)
                .font(.largeTitle.weight(.bold))

            if !recorder.attendees.isEmpty {
                Label(recorder.attendees.joined(separator: ", "), systemImage: "person.2")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Divider()

            ZStack(alignment: .topLeading) {
                TextEditor(text: $recorder.liveNotes)
                    .font(.title3)
                    .lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .focused($notesFocused)
                    .accessibilityLabel("Your notes")
                if recorder.liveNotes.isEmpty {
                    Text("Jot down cues — a name, a number, a decision. When the meeting ends, MindExtract writes the rest from the transcript.")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal, 56)
        .padding(.top, 12)
        .padding(.bottom, 96)   // room for the floating control bar
        .frame(maxWidth: 820, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
    }

    private var startedLabel: String {
        let start = recorder.startedAt ?? Date()
        return start.formatted(date: .abbreviated, time: .shortened)
    }

    private func chip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(DS.Colors.rowFill))
    }

    @ViewBuilder
    private var consentChip: some View {
        if let at = recorder.consentAt {
            Label("Consent confirmed · \(RecordingView.formatElapsed(at))", systemImage: "checkmark.shield")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.green.opacity(0.12)))
        } else {
            Menu {
                Button("Everyone agreed to the recording", systemImage: "checkmark.shield") {
                    recorder.confirmConsent()
                }
                Divider()
                Button("Copy notice in Swedish", systemImage: "doc.on.doc") { copy(ConsentNotice.swedish) }
                Button("Copy notice in English", systemImage: "doc.on.doc") { copy(ConsentNotice.english) }
            } label: {
                Label("Confirm consent", systemImage: "exclamationmark.shield")
                    .font(.caption.weight(.semibold))
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(.orange)
            .fixedSize()
            .help("Tell participants you're recording, then mark that they agreed. Saved with the meeting.")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Floating controls

    private var controlBar: some View {
        HStack(spacing: 4) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(DS.Colors.recording)
                .symbolEffect(.pulse, options: .repeating)
                .padding(.leading, 12)
            Text(RecordingView.formatElapsed(recorder.elapsed))
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 4)
            MiniLevelBars(level: recorder.level)
                .padding(.trailing, 6)

            Divider().frame(height: 20)

            Button {
                recorder.markMoment()
            } label: {
                Label(recorder.markedMoments.isEmpty ? "Mark" : "Mark · \(recorder.markedMoments.count)", systemImage: "flag")
            }
            .help("Bookmark this moment (⌘M)")

            Button {
                showTranscript.toggle()
            } label: {
                Label(showTranscript ? "Hide transcript" : "Transcript", systemImage: "text.alignleft")
            }

            if live.isActive {
                Button {
                    captionOverlay.toggle(transcriber: live)
                } label: {
                    Label("Captions", systemImage: captionOverlay.isVisible ? "captions.bubble.fill" : "captions.bubble")
                        .labelStyle(.iconOnly)
                }
                .help("Floating captions on top of Zoom/Teams")
            }

            Button {
                recorder.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.glassProminent)
            .tint(DS.Colors.recording)
            .padding(.leading, 4)
            .help("Stop and write the notes")
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
        .padding(6)
        .glassEffect(.regular, in: .capsule)
    }

    // MARK: Transcript panel

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Live transcript").font(.headline)
                Spacer()
                Button {
                    showTranscript = false
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .buttonStyle(.borderless)
                .help("Hide the transcript")
                .accessibilityLabel("Hide transcript")
            }

            // What's being heard, and by what — so nothing is a mystery.
            VStack(alignment: .leading, spacing: 6) {
                sourceRow("Your microphone", systemImage: "mic", active: recorder.micActive)
                sourceRow("Meeting audio", systemImage: "speaker.wave.2", active: recorder.systemActive)
                if !live.engineLabel.isEmpty {
                    Label(live.engineLabel, systemImage: "waveform")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(DS.Colors.inputFill))

            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if live.displayText.isEmpty {
                            Text(live.isActive ? (live.status.isEmpty ? String(localized: "Listening…") : live.status)
                                               : String(localized: "No live preview — download a speech model in Settings to see text while you record. The full transcript is written when you stop."))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(live.displayText)
                        }
                    }
                    .font(.callout)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .id("bottom")
                }
                .onChange(of: live.displayText) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            Text("A quick preview. The final transcript — with speakers — is written when you stop. Everything stays on this Mac.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.Colors.rowFill)
    }

    private func sourceRow(_ title: LocalizedStringKey, systemImage: String, active: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(title).font(.callout)
            Spacer(minLength: 4)
            Circle()
                .fill(active ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(active ? "Sound" : "Silent")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Five little bars that follow the input level.
struct MiniLevelBars: View {
    let level: Double
    private let weights: [Double] = [0.45, 0.8, 1.0, 0.7, 0.5]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(DS.Colors.recording)
                    .frame(width: 3, height: 4 + 14 * min(1, level * 1.6 * weights[i]))
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.1), value: level)
        .accessibilityHidden(true)
    }
}

/// Ready-made recording notices — say or paste them at the start of a meeting.
enum ConsentNotice {
    static let swedish = "Hej! Jag spelar in det här mötet lokalt på min dator för att kunna föra anteckningar. Inget skickas till molnet. Säg till om du inte vill att jag spelar in."
    static let english = "Hi! I'm recording this meeting locally on my computer so I can take notes. Nothing is sent to the cloud. Let me know if you'd rather I didn't record."
}
