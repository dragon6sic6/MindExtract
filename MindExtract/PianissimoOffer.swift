import SwiftUI

// MARK: - Getting Pianissimo to Swedish users
//
// Pianissimo (~690 MB) isn't bundled — every app update would carry it again.
// Swedish users get it automatically on first launch instead; the notch shows
// the download while it runs, and Settings → Transcription offers it again.

enum PianissimoOffer {
    /// The Mac speaks Swedish, or Swedish is the chosen transcription language.
    @MainActor static var isForThisUser: Bool {
        Locale.preferredLanguages.contains { $0.hasPrefix("sv") }
            || AppSettings.shared.defaultTranscriptionLanguage == "sv"
    }

    private static let autoStartedKey = "pianissimoAutoDownloadStarted"

    /// Starts the one-time download on first launch for Swedish users.
    @MainActor static func autoStartIfNeeded() {
        let tm = TranscriptionManager.shared
        guard isForThisUser, !tm.isModelDownloaded(.pianissimo), tm.downloadingModel == nil,
              !UserDefaults.standard.bool(forKey: autoStartedKey) else { return }
        UserDefaults.standard.set(true, forKey: autoStartedKey)
        tm.downloadModel(.pianissimo)
    }
}

/// Download button, progress with Cancel, or "preparing" — one control for every
/// place Pianissimo is offered.
struct PianissimoDownloadControl: View {
    @ObservedObject private var tm = TranscriptionManager.shared

    var body: some View {
        if tm.downloadingModel == .pianissimo {
            HStack(spacing: 8) {
                ProgressView(value: tm.modelDownloadProgress)
                    .frame(width: 110)
                Text(tm.modelDownloadProgress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Cancel") { tm.cancelModelDownload() }
            }
        } else if tm.isModelDownloaded(.pianissimo) {
            if tm.prewarmingModel == .pianissimo {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Preparing…").foregroundStyle(.secondary)
                }
            } else {
                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else {
            Button {
                tm.downloadModel(.pianissimo)
            } label: {
                Label(tm.modelDownloadError?.model == .pianissimo ? "Try Again" : "Download",
                      systemImage: "arrow.down.circle")
            }
            .disabled(tm.downloadingModel != nil)
        }
    }
}
