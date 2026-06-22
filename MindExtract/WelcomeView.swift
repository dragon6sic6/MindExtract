import SwiftUI

// MARK: - First-run welcome
//
// A light, one-time welcome that shows the three things MindExtract does and
// drops the user straight into one of them. Not a multi-step onboarding wall —
// the app is usable immediately; this just surfaces the magic.

struct WelcomeView: View {
    var onRecord: () -> Void
    var onTranscribe: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(DS.Colors.accent)
                    .padding(.top, 28)
                Text("Welcome to MindExtract")
                    .font(.system(size: 22, weight: .bold))
                Text("Turn anything spoken into searchable, private text — entirely on your Mac.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .padding(.bottom, 20)

            VStack(spacing: 10) {
                row(icon: "record.circle", color: .red,
                    title: "Record a meeting",
                    detail: "Zoom, Teams, anything on screen + your mic — transcribed and summarized after.")
                row(icon: "tray.and.arrow.down", color: DS.Colors.accent,
                    title: "Transcribe a file or link",
                    detail: "Drop an audio/video file, or paste a URL. Apple Speech or WhisperKit, on-device.")
                row(icon: "sparkles", color: .purple,
                    title: "Ask across everything",
                    detail: "Search the text of every transcript, and ask questions across all your recordings.")
            }
            .padding(.horizontal, 28)

            HStack(spacing: 10) {
                Button(action: onTranscribe) {
                    Label("Transcribe something", systemImage: "tray.and.arrow.down").frame(maxWidth: .infinity)
                }
                .secondaryGlassButton().controlSize(.large)
                Button(action: onRecord) {
                    Label("Record a meeting", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .primaryGlassButton().controlSize(.large)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)

            Button("Maybe later", action: onDismiss)
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 12)
                .padding(.bottom, 22)

            Text("Everything stays on your Mac. Nothing is uploaded unless you choose a cloud AI provider.")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(.bottom, 20)
        }
        .frame(width: 520)
    }

    private func row(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.Colors.hairline, lineWidth: 1))
    }
}
