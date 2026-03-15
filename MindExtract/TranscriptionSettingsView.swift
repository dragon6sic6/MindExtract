import SwiftUI

struct TranscriptionSettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var transcriptionManager = TranscriptionManager.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.title3)
                    Text("Back")
                }
                .buttonStyle(.plain)
                .foregroundColor(.primary)

                Spacer()

                Text("Transcription")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                // Invisible spacer to balance header
                Text("Back")
                    .opacity(0)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Engine info
                    engineInfoSection

                    // Default Settings
                    SettingsSection(title: "Settings", icon: "gearshape") {
                        HStack {
                            Text("Default Model")
                            Spacer()
                            Picker("", selection: $settings.defaultWhisperModel) {
                                ForEach(WhisperModel.allCases) { model in
                                    Text(model.displayName).tag(model)
                                }
                            }
                            .frame(width: 180)
                        }

                        HStack {
                            Text("Output Format")
                            Spacer()
                            Picker("", selection: $settings.transcriptionOutputFormat) {
                                ForEach(TranscriptionOutputFormat.allCases, id: \.self) { format in
                                    Text(format.displayName).tag(format)
                                }
                            }
                            .frame(width: 180)
                        }

                        Toggle("Speaker Diarization", isOn: $settings.enableSpeakerDiarization)
                            .help("Identify different speakers in the transcription (experimental)")
                    }

                    // Models Section
                    SettingsSection(title: "Download Models", icon: "square.and.arrow.down") {
                        ForEach(WhisperModel.allCases) { model in
                            ModelRow(model: model)
                        }

                        Divider()
                            .padding(.vertical, 4)

                        // Storage info
                        HStack {
                            Text("Storage Used")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(transcriptionManager.formatBytes(transcriptionManager.totalStorageUsed()))
                                .foregroundColor(.secondary)
                                .fontWeight(.medium)
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 500, height: 650)
        .onAppear {
            transcriptionManager.loadDownloadedModels()
        }
    }

    private var engineInfoSection: some View {
        SettingsSection(title: "Engine", icon: "cpu") {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("WhisperKit")
                        .fontWeight(.medium)
                    Text("Core ML · Neural Engine + GPU accelerated")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            HStack {
                Image(systemName: transcriptionManager.isFfmpegAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(transcriptionManager.isFfmpegAvailable ? .green : .red)
                Text("FFmpeg")
                Spacer()
                Text(transcriptionManager.isFfmpegAvailable ? "Available" : "Not Found")
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct ModelRow: View {
    let model: WhisperModel
    @ObservedObject var transcriptionManager = TranscriptionManager.shared

    private var isDownloaded: Bool {
        transcriptionManager.isModelDownloaded(model)
    }

    private var isDownloading: Bool {
        transcriptionManager.downloadingModel == model
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(model.displayName)
                        .fontWeight(.medium)
                    if model.isRecommended {
                        Text("Recommended")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08))
                            .foregroundColor(.primary)
                            .cornerRadius(4)
                    }
                }
                Text(model.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(model.sizeDescription)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .trailing)

            if isDownloading {
                downloadingView
            } else if isDownloaded {
                downloadedView
            } else {
                downloadButton
            }
        }
        .padding(.vertical, 4)
    }

    private var downloadingView: some View {
        HStack(spacing: 8) {
            ProgressView(value: transcriptionManager.modelDownloadProgress)
                .frame(width: 60)

            Button(action: {
                transcriptionManager.cancelModelDownload()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 100)
    }

    private var isPrewarming: Bool {
        transcriptionManager.prewarmingModel == model
    }

    private var downloadedView: some View {
        HStack(spacing: 8) {
            if isPrewarming {
                ProgressView()
                    .scaleEffect(0.5)
                    .help("Optimizing model for your device…")
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }

            Button(action: {
                transcriptionManager.deleteModel(model)
            }) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .help("Delete model")
        }
        .frame(width: 100)
    }

    private var downloadButton: some View {
        Button(action: {
            transcriptionManager.downloadModel(model)
        }) {
            Label("Download", systemImage: "arrow.down.circle")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(transcriptionManager.downloadingModel != nil)
        .frame(width: 100)
    }
}

#Preview {
    TranscriptionSettingsView()
}
