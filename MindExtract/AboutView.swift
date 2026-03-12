import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            // App Icon
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)

            // App Name
            Text("MindExtract")
                .font(.title)
                .fontWeight(.bold)

            // Version
            Text("Version 1.0.0")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Divider()
                .frame(width: 200)

            // Company
            VStack(spacing: 8) {
                Text("Created by")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Mindact")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.accentColor)
            }

            // Description
            Text("Download videos and transcribe audio using AI-powered speech recognition.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            Divider()
                .frame(width: 200)

            // Powered by
            VStack(spacing: 4) {
                Text("Powered by")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("yt-dlp & whisper.cpp")
                    .font(.caption)
                    .fontWeight(.medium)
            }

            // Copyright
            Text("© 2025 Mindact. All rights reserved.")
                .font(.caption2)
                .foregroundColor(.secondary)

            Spacer()

            Button("Close") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(30)
        .frame(width: 350, height: 420)
    }
}

#Preview {
    AboutView()
}
