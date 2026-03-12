import SwiftUI

struct OnboardingView: View {
    let onDismiss: () -> Void

    @ObservedObject private var transcriptionManager = TranscriptionManager.shared
    @State private var currentStep = 0

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Step dots
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { step in
                        Circle()
                            .fill(currentStep == step ? Color.primary : Color.secondary.opacity(0.22))
                            .frame(width: 7, height: 7)
                            .animation(.easeInOut, value: currentStep)
                    }
                }
                .padding(.top, 32)

                // Step content
                Group {
                    if currentStep == 0 {
                        step1View
                    } else if currentStep == 1 {
                        step2View
                    } else {
                        step3View
                    }
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
                .frame(width: 84, height: 84)
                .cornerRadius(18)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 5)

            Spacer().frame(height: 22)

            Text("Welcome to MindExtract")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Your all‑in‑one tool for downloading\nand transcribing video content.")
                .font(.title3)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)

            Spacer().frame(height: 40)

            VStack(spacing: 12) {
                featureRow(icon: "arrow.down.circle",
                           title: "Download anything",
                           subtitle: "YouTube, Vimeo, TikTok, Twitter, and 1000+ sites")
                featureRow(icon: "music.note.list",
                           title: "Extract audio",
                           subtitle: "Save audio-only as MP3 from any video")
                featureRow(icon: "text.bubble",
                           title: "Transcribe with AI",
                           subtitle: "Local Whisper AI — no internet needed, fully private")
            }
            .padding(.horizontal, 64)

            Spacer()

            Button(action: { withAnimation { currentStep = 1 } }) {
                HStack(spacing: 6) {
                    Text("Get Started")
                    Image(systemName: "arrow.right")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 64)
            .padding(.bottom, 48)
        }
    }

    // MARK: - Step 2: Download AI Model

    private var step2View: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "brain.head.profile")
                .font(.system(size: 52))
                .foregroundColor(.primary)

            Spacer().frame(height: 18)

            Text("Set Up AI Transcription")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("MindExtract uses Whisper AI to transcribe speech locally\non your Mac — fast, private, no internet needed.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 64)

            Spacer().frame(height: 28)

            VStack(spacing: 6) {
                ForEach(WhisperModel.allCases) { model in
                    ModelRow(model: model)
                }
            }
            .padding(.horizontal, 64)

            Spacer()

            VStack(spacing: 12) {
                Button(action: {
                    withAnimation { currentStep = 2 }
                }) {
                    Text(anyModelDownloaded ? "Continue  →" : "Skip for now")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 64)

                if !anyModelDownloaded {
                    Text("You can always download models later in Settings → Transcription")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 48)
        }
    }

    // MARK: - Step 3: Ready

    private var step3View: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 110, height: 110)
                Image(systemName: "checkmark")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(.green)
            }

            Spacer().frame(height: 22)

            Text("You're all set!")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Paste a URL or drop a file to get started.")
                .font(.title3)
                .foregroundColor(.secondary)
                .padding(.top, 8)

            Spacer()

            Button(action: { withAnimation(.easeInOut) { onDismiss() } }) {
                HStack(spacing: 6) {
                    Text("Open MindExtract")
                    Image(systemName: "arrow.right")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 64)
            .padding(.bottom, 48)
        }
    }

    // MARK: - Helpers

    private var anyModelDownloaded: Bool {
        !transcriptionManager.downloadedModels.isEmpty
    }

    private func featureRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .regular))
                .foregroundColor(.primary)
                .frame(width: 40, height: 40)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(10)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }
}

#Preview {
    OnboardingView(onDismiss: {})
        .frame(width: 600, height: 620)
}
