import SwiftUI

// MARK: - Getting Pianissimo to Swedish users
//
// Pianissimo (~690 MB) isn't bundled — every app update would carry it again.
// Swedish users get it automatically on first launch instead, with a clear bar
// showing what's downloading; if they cancel or it fails, the bar offers it again
// until they have it or close the bar.

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

/// A slim bar above the notes while Swedish users don't have Pianissimo yet.
struct PianissimoBanner: View {
    @ObservedObject private var tm = TranscriptionManager.shared
    @AppStorage("pianissimoBannerClosed") private var closed = false

    private var visible: Bool {
        guard PianissimoOffer.isForThisUser else { return false }
        if tm.downloadingModel == .pianissimo { return true }
        if tm.isModelDownloaded(.pianissimo) { return tm.prewarmingModel == .pianissimo }
        return !closed
    }

    var body: some View {
        if visible {
            HStack(spacing: 12) {
                Image(systemName: "waveform.badge.plus")
                    .font(.title3)
                    .foregroundStyle(DS.Colors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(tm.modelDownloadError?.model == .pianissimo && tm.downloadingModel == nil ? .orange : .secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                PianissimoDownloadControl()
                if tm.downloadingModel != .pianissimo && !tm.isModelDownloaded(.pianissimo) {
                    Button {
                        closed = true
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Hide — you can download it later in Settings → Transcription")
                    .accessibilityLabel("Hide")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(DS.Colors.accent.opacity(0.08))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var title: LocalizedStringKey {
        if tm.downloadingModel == .pianissimo { return "Downloading Pianissimo, the Swedish speech model" }
        if tm.isModelDownloaded(.pianissimo) { return "Pianissimo is downloaded" }
        return "Get Pianissimo for the best Swedish"
    }

    private var detail: String {
        if tm.downloadingModel == .pianissimo {
            return String(localized: "\(WhisperModel.pianissimo.sizeDescription), once. You can keep using MindExtract meanwhile.")
        }
        if tm.isModelDownloaded(.pianissimo) {
            return String(localized: "Preparing it for your Mac — a few minutes the first time.")
        }
        if let failure = tm.modelDownloadError, failure.model == .pianissimo {
            return failure.message
        }
        return String(localized: "\(WhisperModel.pianissimo.sizeDescription), downloaded once, then works offline. Until then Swedish uses a less accurate engine.")
    }
}
