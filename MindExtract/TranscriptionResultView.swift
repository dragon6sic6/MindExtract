import SwiftUI
import AppKit

struct TranscriptionResultView: View {
    @ObservedObject var transcriptionManager: TranscriptionManager
    @Binding var isPresented: Bool

    @State private var showCopiedAlert = false

    private var isTranscribing: Bool {
        switch transcriptionManager.transcriptionState {
        case .extractingAudio, .transcribing, .loadingModel:
            return true
        default:
            return false
        }
    }

    private var isCompleted: Bool {
        if case .completed = transcriptionManager.transcriptionState {
            return true
        }
        return false
    }

    private var hasError: Bool {
        if case .error = transcriptionManager.transcriptionState {
            return true
        }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Main content
            VStack(spacing: 16) {
                // Status indicator
                statusView

                // Transcription text area
                transcriptionTextArea

                // Action buttons
                if !transcriptionManager.liveTranscriptionText.isEmpty {
                    actionButtons
                }
            }
            .padding(20)
        }
        .frame(minWidth: 600, idealWidth: 700, maxWidth: 900,
               minHeight: 500, idealHeight: 600, maxHeight: 800)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(systemName: "text.bubble.fill")
                .font(.title2)
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Transcription")
                    .font(.headline)

                if !transcriptionManager.currentTranscriptionTitle.isEmpty {
                    Text(transcriptionManager.currentTranscriptionTitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Close button
            Button(action: {
                if !isTranscribing {
                    transcriptionManager.clearTranscription()
                    isPresented = false
                }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isTranscribing)
        }
        .padding()
    }

    // MARK: - Status View

    @ViewBuilder
    private var statusView: some View {
        switch transcriptionManager.transcriptionState {
        case .loadingModel:
            HStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Loading WhisperKit model...")
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding()
            .background(Color.blue.opacity(0.1))
            .cornerRadius(8)

        case .extractingAudio:
            HStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Extracting audio...")
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding()
            .background(Color.blue.opacity(0.1))
            .cornerRadius(8)

        case .transcribing(let progress):
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Transcribing...")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(action: {
                        transcriptionManager.cancelTranscription()
                    }) {
                        Image(systemName: "xmark.circle")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel transcription")
                }
                if progress > 0 {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                }
            }
            .padding()
            .background(Color.blue.opacity(0.1))
            .cornerRadius(8)

        case .completed:
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Transcription complete!")
                    .fontWeight(.medium)
                Spacer()
                if let path = transcriptionManager.lastSavedPath {
                    Button(action: {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }) {
                        Label("Show in Finder", systemImage: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding()
            .background(Color.green.opacity(0.1))
            .cornerRadius(8)

        case .error(let message):
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
                Spacer()
            }
            .padding()
            .background(Color.red.opacity(0.1))
            .cornerRadius(8)

        default:
            EmptyView()
        }
    }

    // MARK: - Transcription Text Area

    private var transcriptionTextArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transcript")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)

                Spacer()

                if !transcriptionManager.liveTranscriptionText.isEmpty {
                    Text("\(transcriptionManager.liveTranscriptionText.count) characters")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if transcriptionManager.liveTranscriptionText.isEmpty && isTranscribing {
                            WaitingAnimationView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(32)
                        } else {
                            Text(transcriptionManager.liveTranscriptionText.isEmpty ? "Waiting for transcription..." : transcriptionManager.liveTranscriptionText)
                                .font(.system(.body, design: .default))
                                .foregroundColor(transcriptionManager.liveTranscriptionText.isEmpty ? .secondary : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .textSelection(.enabled)
                        }
                    }
                    .id("transcriptionText")
                }
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .onChange(of: transcriptionManager.liveTranscriptionText) { _ in
                    // Auto-scroll to bottom when new text arrives
                    if isTranscribing {
                        withAnimation {
                            proxy.scrollTo("transcriptionText", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            // Copy button
            Button(action: {
                transcriptionManager.copyTranscriptionToClipboard()
                showCopiedAlert = true

                // Hide alert after 2 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    showCopiedAlert = false
                }
            }) {
                Label(showCopiedAlert ? "Copied!" : "Copy", systemImage: showCopiedAlert ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .tint(showCopiedAlert ? .green : nil)

            // Save As button
            Button(action: {
                transcriptionManager.saveTranscriptionAs()
            }) {
                Label("Save As...", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)

            Spacer()

            // Done button (only show when complete)
            if isCompleted || hasError {
                Button(action: {
                    transcriptionManager.clearTranscription()
                    isPresented = false
                }) {
                    Text("Done")
                        .frame(width: 80)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Waiting Animation View

struct WaitingAnimationView: View {
    @State private var animating = false

    private let barCount = 5
    private let barWidth: CGFloat = 4
    private let barSpacing: CGFloat = 5
    private let minHeight: CGFloat = 8
    private let maxHeight: CGFloat = 36

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: barWidth, height: animating ? maxHeight : minHeight)
                        .animation(
                            Animation
                                .easeInOut(duration: 0.55)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.1),
                            value: animating
                        )
                }
            }
            .frame(height: maxHeight)

            Text("Transcribing audio…")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .onAppear { animating = true }
        .onDisappear { animating = false }
    }
}

#Preview {
    TranscriptionResultView(
        transcriptionManager: TranscriptionManager.shared,
        isPresented: .constant(true)
    )
}
