import SwiftUI

// MARK: - Primary Button Style (never inherits system accent / pink)

struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(Color(NSColor.windowBackgroundColor))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color.primary.opacity(configuration.isPressed ? 0.75 : 1))
            .cornerRadius(10)
    }
}

// MARK: - Onboarding View

struct OnboardingView: View {
    let onDismiss: () -> Void

    @ObservedObject private var transcriptionManager = TranscriptionManager.shared
    @State private var currentStep = 0

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).ignoresSafeArea()

            VStack(spacing: 0) {
                // Step dots
                HStack(spacing: 7) {
                    ForEach(0..<3, id: \.self) { step in
                        Circle()
                            .fill(currentStep == step ? Color.primary : Color.primary.opacity(0.18))
                            .frame(width: 6, height: 6)
                            .animation(.easeInOut, value: currentStep)
                    }
                }
                .padding(.top, 28)

                // Step content
                Group {
                    if currentStep == 0 { step1View }
                    else if currentStep == 1 { step2View }
                    else { step3View }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .animation(.easeInOut(duration: 0.3), value: currentStep)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Step 1: Welcome

    private var step1View: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .cornerRadius(16)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)

            Spacer().frame(height: 20)

            Text("Welcome to MindExtract")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.primary)

            Text("Your all‑in‑one tool for downloading\nand transcribing video content.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 6)

            Spacer().frame(height: 36)

            VStack(spacing: 10) {
                featureRow(icon: "arrow.down.circle",
                           title: "Download anything",
                           subtitle: "YouTube, Vimeo, TikTok, Twitter, and 1000+ sites")
                featureRow(icon: "music.note.list",
                           title: "Extract audio",
                           subtitle: "Save audio-only as MP3 from any video")
                featureRow(icon: "text.bubble",
                           title: "Transcribe with AI",
                           subtitle: "WhisperKit with Core ML — no internet needed, fully private")
            }
            .frame(maxWidth: 440)

            Spacer()

            Button(action: { withAnimation { currentStep = 1 } }) {
                HStack(spacing: 6) {
                    Text("Get Started")
                    Image(systemName: "arrow.right").font(.system(size: 13, weight: .semibold))
                }
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .frame(maxWidth: 440)
            .padding(.bottom, 44)
        }
        .padding(.horizontal, 80)
    }

    // MARK: - Step 2: Download AI Model

    private var step2View: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "brain.head.profile")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(.primary)

            Spacer().frame(height: 16)

            Text("Set Up AI Transcription")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.primary)

            Text("MindExtract transcribes speech locally on your Mac.\nFast, private — no internet required.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 6)

            Spacer().frame(height: 28)

            // Model list card
            VStack(spacing: 0) {
                ForEach(Array(WhisperModel.allCases.enumerated()), id: \.element) { index, model in
                    if index > 0 {
                        Divider().padding(.leading, 16)
                    }
                    OnboardingModelRow(model: model)
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
            .frame(maxWidth: 440)

            Spacer()

            VStack(spacing: 8) {
                Button(action: { withAnimation { currentStep = 2 } }) {
                    Text(anyModelDownloaded ? "Continue  →" : "Skip for now")
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .frame(maxWidth: 440)

                if !anyModelDownloaded {
                    Text("You can download models later in Settings → Transcription")
                        .font(.system(size: 12))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
            }
            .padding(.bottom, 44)
        }
        .padding(.horizontal, 80)
    }

    // MARK: - Step 3: Ready

    private var step3View: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.10))
                    .frame(width: 88, height: 88)
                Image(systemName: "checkmark")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundColor(.green)
            }

            Spacer().frame(height: 20)

            Text("You're all set!")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.primary)

            Text("Paste a URL or drop a file to get started.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .padding(.top, 6)

            Spacer()

            Button(action: { withAnimation(.easeInOut) { onDismiss() } }) {
                HStack(spacing: 6) {
                    Text("Open MindExtract")
                    Image(systemName: "arrow.right").font(.system(size: 13, weight: .semibold))
                }
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .frame(maxWidth: 440)
            .padding(.bottom, 44)
        }
        .padding(.horizontal, 80)
    }

    // MARK: - Helpers

    private var anyModelDownloaded: Bool {
        !transcriptionManager.downloadedModels.isEmpty
    }

    private func featureRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(.primary)
                .frame(width: 36, height: 36)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

// MARK: - Compact Model Row for Onboarding

struct OnboardingModelRow: View {
    let model: WhisperModel
    @ObservedObject var transcriptionManager = TranscriptionManager.shared

    private var isDownloaded: Bool { transcriptionManager.isModelDownloaded(model) }
    private var isDownloading: Bool { transcriptionManager.downloadingModel == model }

    var body: some View {
        HStack(spacing: 10) {
            // Left: name + badge + size + description
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(model.sizeDescription)
                        .font(.system(size: 11))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    if model.isRecommended {
                        Text("Recommended")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.07))
                            .foregroundColor(.secondary)
                            .cornerRadius(4)
                    }
                }
                Text(model.description)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            // Right: state button
            if isDownloading {
                HStack(spacing: 6) {
                    ProgressView(value: transcriptionManager.modelDownloadProgress)
                        .frame(width: 52)
                    Button(action: { transcriptionManager.cancelModelDownload() }) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } else if isDownloaded {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Button(action: { transcriptionManager.deleteModel(model) }) {
                        Image(systemName: "trash").foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button(action: { transcriptionManager.downloadModel(model) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 12))
                        Text("Download")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.07))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

#Preview {
    OnboardingView(onDismiss: {})
        .frame(width: 700, height: 580)
}
