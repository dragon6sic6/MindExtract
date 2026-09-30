import Foundation
import NaturalLanguage
import SwiftUI
import WhisperKit
import SpeakerKit
import Speech
import AVFoundation
import UserNotifications

// MARK: - Transcription Manager (WhisperKit)

@MainActor
class TranscriptionManager: ObservableObject {
    static let shared = TranscriptionManager()

    @Published var transcriptionState: TranscriptionState = .idle

    /// True only when a WhisperKit model must be downloaded before transcription is
    /// possible. Apple Speech needs no model, so this is false whenever it's active.
    var needsModelDownload: Bool {
        !useAppleSpeech() && downloadedModels.isEmpty
    }

    /// User-assigned names for diarized speakers (e.g. "Speaker 1" → "Anna").
    /// Applied in the result view and in copied/exported text.
    @Published var speakerNameOverrides: [String: String] = [:]

    /// Resolves a raw speaker label to its user-assigned name, if any.
    func speakerDisplayName(_ original: String) -> String {
        let trimmed = speakerNameOverrides[original]?.trimmingCharacters(in: .whitespaces)
        if trimmed?.isEmpty == false { return trimmed! }
        // Diarization labels are "Speaker N" — show them in the app's language.
        if original.hasPrefix("Speaker "), let n = Int(original.dropFirst(8)) {
            return String(localized: "Speaker \(n)")
        }
        if original == "You" { return String(localized: "Me") }
        return original
    }

    /// True while a transcription pipeline is actively running (download → model
    /// load → extract → transcribe). Used to guard against closing the window mid-run.
    var isTranscribing: Bool {
        switch transcriptionState {
        case .downloadingAudio, .extractingAudio, .transcribing, .loadingModel:
            return true
        default:
            return false
        }
    }

    @Published var downloadingModel: WhisperModel?
    @Published var modelDownloadProgress: Double = 0
    /// The model whose last download failed, and why (shown where it was offered).
    @Published var modelDownloadError: (model: WhisperModel, message: String)?
    /// Its own task, so a model download and a transcription never cancel each other.
    private var modelDownloadTask: Task<Void, Never>?
    @Published var downloadedModels: Set<WhisperModel> = []
    @Published var prewarmingModel: WhisperModel?

    // Real-time transcription output
    @Published var liveTranscriptionText: String = ""
    @Published var currentTranscriptionTitle: String = ""
    @Published var showTranscriptionView: Bool = false
    @Published var lastSavedPath: String?

    // Segment-level data for timeline view
    @Published var segments: [TranscriptionSegmentData] = []
    @Published var audioDuration: Float = 0
    @Published var audioFilePath: String?  // Keep audio for playback
    /// Notes the user typed during a meeting recording, handed to the next
    /// transcript so the result view can save + AI-merge them. Consumed once.
    var pendingMeetingNotes: String?
    /// Notes + consent from the meeting being transcribed, consumed on completion
    /// (independently of the view, which consumes `pendingMeetingNotes` early).
    var pendingMeetingExtras: (notes: String, consentAt: Double?)?
    /// Transcript paths whose enhanced notes are being written right now.
    @Published private(set) var enhancingPaths: Set<String> = []
    /// Why the notes couldn't be written, per transcript path (cleared on retry).
    @Published var enhanceErrors: [String: String] = [:]
    /// Separate mic/system tracks from a meeting recording, for channel-aware
    /// "you vs them" speaker attribution. Consumed (and the files deleted) once.
    var pendingChannelSources: (mic: String, system: String)?
    /// Speaker-name suggestions for the next transcript ("You" + calendar
    /// attendees), shown in the rename popover. Set when a meeting is confirmed.
    var pendingSpeakerSuggestions: [String] = []
    /// Marked moments (seconds from start) bookmarked during recording, and the
    /// meeting's attendee emails — handed to the result view for the Brief + recap.
    var pendingMarkedMoments: [TimeInterval] = []
    var pendingAttendeeEmails: [String] = []
    /// True when the next transcript comes from a meeting recording, so the result
    /// view can auto-generate notes once. Consumed on first open.
    private(set) var pendingIsMeeting = false
    func markPendingMeeting() { pendingIsMeeting = true }
    /// Reads and clears the flag atomically so only the first result view to open
    /// after a recording auto-generates notes.
    func consumePendingIsMeeting() -> Bool {
        let v = pendingIsMeeting
        pendingIsMeeting = false
        return v
    }

    // MARK: - AI engine readiness

    private func aiEngineConfigured() -> Bool {
        switch AppSettings.shared.aiBackend {
        case .apple: return true   // on-device; fails gracefully if AI is off
        case .ollama: return !AppSettings.shared.ollamaModel.isEmpty
        case .custom:
            return !AppSettings.shared.customBaseURL.isEmpty
                && !(KeychainHelper.get("custom-api-key") ?? "").isEmpty
        default:
            guard let kc = AppSettings.shared.aiBackend.keychainKey else { return true }
            return !(KeychainHelper.get(kc) ?? "").isEmpty
        }
    }

    // MARK: - Meeting notes (enhanced)

    /// True when a finished recording can be transcribed without asking — some
    /// engine is ready. Otherwise the confirm sheet appears (it offers downloads).
    var canAutoTranscribe: Bool {
        useAppleSpeech() || !downloadedModels.isEmpty
    }

    /// Saves the meeting's notes + consent next to the transcript, then writes the
    /// notes in the background — always, with the user's own lines woven in.
    private func finishMeetingExtras(path: String) {
        guard let extras = pendingMeetingExtras else { return }
        pendingMeetingExtras = nil
        var sidecar = TranscriptAIStore.load(for: path)
            ?? TranscriptAISidecar(summary: nil, chat: [], translation: nil, translationLanguageCode: nil,
                                   templateOutputs: nil, userNotes: nil, speakerNames: nil,
                                   speakerSuggestions: nil, markedMoments: nil)
        let notes = extras.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty, (sidecar.userNotes ?? "").isEmpty { sidecar.userNotes = notes }
        if let at = extras.consentAt { sidecar.consentConfirmedAt = at }
        TranscriptAIStore.save(sidecar, for: path)
        if AppSettings.shared.autoGenerateMeetingNotes {
            generateEnhancedNotes(path: path, userNotes: notes, segments: segments)
        }
    }

    /// Writes (or rewrites) the enhanced notes for a transcript and saves them.
    func generateEnhancedNotes(path: String, userNotes: String, segments: [TranscriptionSegmentData]) {
        guard !enhancingPaths.contains(path), !segments.isEmpty else { return }
        enhanceErrors[path] = nil
        guard aiEngineConfigured() else {
            enhanceErrors[path] = String(localized: "The notes need an AI engine. Choose one in Settings → AI — Apple Intelligence works on this Mac.")
            return
        }
        enhancingPaths.insert(path)
        let backend = AIBackends.current()
        Task { @MainActor in
            defer {
                self.enhancingPaths.remove(path)
                NotificationCenter.default.post(name: .enhancedNotesUpdated, object: path)
            }
            do {
                let notes = try await EnhancedNotesGenerator.generate(userNotes: userNotes, segments: segments, backend: backend)
                guard !notes.isEmpty else { return }
                var sidecar = TranscriptAIStore.load(for: path)
                    ?? TranscriptAISidecar(summary: nil, chat: [], translation: nil, translationLanguageCode: nil,
                                           templateOutputs: nil, userNotes: nil, speakerNames: nil,
                                           speakerSuggestions: nil, markedMoments: nil)
                sidecar.enhancedNotes = notes
                if (sidecar.userNotes ?? "").isEmpty, !userNotes.isEmpty { sidecar.userNotes = userNotes }
                TranscriptAIStore.save(sidecar, for: path)
                self.adoptTitle(notes.title, for: path)
                appLog("[MindExtract] Enhanced notes written: \(path)")
            } catch is CancellationError {
            } catch {
                self.enhanceErrors[path] = String(localized: "Couldn't write the notes: \(error.localizedDescription)")
                appLog("[MindExtract] Enhanced notes failed: \(error.localizedDescription)")
            }
        }
    }

    /// Replaces a timestamp-only title ("Möte 2026-09-25 16.06") with the one
    /// written with the notes. A title the user typed is never touched.
    private func adoptTitle(_ title: String?, for path: String) {
        guard let title, !title.isEmpty,
              let item = transcriptionHistory.history.first(where: { $0.filePath == path }),
              MeetingText.isGenericTitle(item.title) else { return }
        transcriptionHistory.rename(item, to: title)
        if lastSavedPath == path { currentTranscriptionTitle = title }
    }

    /// The recording that belongs to a transcript: same base name next to it, or
    /// the combined mix in a meeting folder (never the raw mic/system tracks).
    nonisolated static func audioBeside(transcript path: String) -> String? {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let audioExts = ["m4a", "wav", "mp3", "caf", "aac"]
        for ext in audioExts {
            let candidate = dir.appendingPathComponent(base).appendingPathExtension(ext)
            if fm.fileExists(atPath: candidate.path) { return candidate.path }
        }
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path), files.contains("mic.m4a") else { return nil }
        return files
            .filter { audioExts.contains(($0 as NSString).pathExtension.lowercased()) && !["mic.m4a", "system.m4a"].contains($0.lowercased()) }
            .first
            .map { dir.appendingPathComponent($0).path }
    }

    private var whisperKit: WhisperKit?
    private var currentLoadedModel: WhisperModel?
    private var currentTask: Task<Void, Never>?
    private var currentProcess: Process? // for ffmpeg
    private var activeOutputPath: String?   // where the in-flight transcript will save
    private var downloadTask: URLSessionDataTask?

    private let fileManager = FileManager.default
    private let transcriptionHistory = TranscriptionHistoryManager.shared
    private var currentModelUsed: WhisperModel?
    /// The engine that actually ran (the requested model can be rerouted by
    /// language), recorded in the history so "Model" never names the wrong one.
    private var usedEngineName: String?

    private init() {
        loadDownloadedModels()
        removeWhisperCppModels()
    }

    /// Models from the whisper.cpp engine used before WhisperKit (WhisperModels/
    /// ggml-*.bin). Nothing reads them anymore, so they're removed at launch.
    private func removeWhisperCppModels() {
        let dir = applicationSupportPath.appendingPathComponent("WhisperModels")
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Token Cleaning

    /// Strip WhisperKit special tokens like <|5.92|>, <|startoftranscript|>, <|en|>, <|transcribe|>, etc.
    // NSRegularExpression is immutable and thread-safe for matching, so it is
    // safe to reference from the nonisolated cleanTokens().
    nonisolated(unsafe) private static let tokenPattern = try! NSRegularExpression(pattern: "<\\|[^|]*\\|>", options: [])

    nonisolated private func cleanTokens(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let cleaned = Self.tokenPattern.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        // Collapse multiple spaces and trim
        return cleaned.replacingOccurrences(of: "  +", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Paths

    private var applicationSupportPath: URL {
        let paths = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent("com.mindact.mindextract")
    }

    private var modelsDirectory: URL {
        applicationSupportPath.appendingPathComponent("WhisperKitModels")
    }

    private var ffmpegBinaryPath: String? { BundledTools.ffmpegPath }

    /// Transcription converts audio natively, so it never depends on ffmpeg.
    var isFfmpegAvailable: Bool { true }

    /// WhisperKit is always available (compiled in), so we only check ffmpeg
    var areBinariesAvailable: Bool {
        isFfmpegAvailable
    }

    // MARK: - Model Management

    func isModelDownloaded(_ model: WhisperModel) -> Bool {
        downloadedModels.contains(model)
    }

    /// On-disk folder for a downloaded model (used by the live transcriber to load
    /// its own WhisperKit instance). Nil if not present.
    func resolvedModelFolder(for model: WhisperModel) -> String? {
        findModelFolder(model)?.path
    }

    /// Refresh `downloadedModels` from the file system.
    /// When `synchronous` is true (default), updates `downloadedModels` immediately on the current thread
    /// so callers can rely on `isModelDownloaded()` right after calling this.
    func loadDownloadedModels(synchronous: Bool = true) {
        var models: Set<WhisperModel> = []
        for model in WhisperModel.allCases {
            let present = model.usesWhisperKit ? findModelFolder(model) != nil : PianissimoEngine.isInstalled
            if present { models.insert(model) }
        }
        if synchronous && Thread.isMainThread {
            self.downloadedModels = models
        } else {
            DispatchQueue.main.async {
                self.downloadedModels = models
            }
        }
    }

    /// Locate a downloaded model inside the Hub cache structure.
    /// Hub stores files at: downloadBase/models/argmaxinc/whisperkit-coreml/<variant>/
    private func findModelFolder(_ model: WhisperModel) -> URL? {
        // Pianissimo isn't a WhisperKit folder — nil keeps it out of WhisperKit and
        // the live preview.
        guard model.usesWhisperKit else { return nil }
        // Hub stores at downloadBase/models/<repo-owner>/<repo-name>/<variant>/.
        var modelDir = modelsDirectory.appendingPathComponent("models")
        for part in model.repo.split(separator: "/") {
            modelDir = modelDir.appendingPathComponent(String(part))
        }
        modelDir = modelDir.appendingPathComponent(model.variant)

        guard fileManager.fileExists(atPath: modelDir.path),
              let contents = try? fileManager.contentsOfDirectory(atPath: modelDir.path),
              contents.contains(where: { $0.hasSuffix(".mlmodelc") || $0.hasSuffix(".mlpackage") }) else {
            return nil
        }

        // Validate model is complete (not just directory skeleton from a failed download)
        // A valid model should be at least 10MB (even tiny is ~70MB)
        var totalSize: Int64 = 0
        if let enumerator = fileManager.enumerator(at: modelDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += Int64(size)
                }
            }
        }
        guard totalSize > 10_000_000 else {
            // Incomplete download — remove the skeleton
            try? fileManager.removeItem(at: modelDir)
            return nil
        }

        return modelDir
    }

    func modelFileSize(_ model: WhisperModel) -> Int64? {
        if !model.usesWhisperKit { return PianissimoEngine.installedSize() }
        guard let modelDir = findModelFolder(model) else { return nil }

        var totalSize: Int64 = 0
        if let enumerator = fileManager.enumerator(at: modelDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let attrs = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                   let size = attrs.fileSize {
                    totalSize += Int64(size)
                }
            }
        }
        return totalSize > 0 ? totalSize : nil
    }

    func totalStorageUsed() -> Int64 {
        var total: Int64 = 0
        for model in downloadedModels {
            if let size = modelFileSize(model) {
                total += size
            }
        }
        return total
    }

    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Model Download

    func downloadModel(_ model: WhisperModel) {
        guard downloadingModel == nil else { return }

        downloadingModel = model
        modelDownloadProgress = 0
        modelDownloadError = nil

        modelDownloadTask = Task {
            do {
                if model.usesWhisperKit {
                    try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
                    // Use the static download method with downloadBase pointing to our models dir.
                    let _ = try await WhisperKit.download(
                        variant: model.variant,
                        downloadBase: modelsDirectory,
                        from: model.repo
                    ) { progress in
                        Task { @MainActor in
                            self.modelDownloadProgress = progress.fractionCompleted
                        }
                    }
                } else {
                    // Download (pinned + sha256-verified) and compile on-device.
                    try await PianissimoEngine.install { fraction in
                        Task { @MainActor in self.modelDownloadProgress = fraction }
                    }
                }

                await MainActor.run {
                    // Refresh from file system to confirm download actually succeeded
                    self.loadDownloadedModels(synchronous: true)
                    self.downloadingModel = nil
                    self.modelDownloadProgress = 1.0

                    if self.isModelDownloaded(model) {
                        // Only adopt it as the default when the current default isn't
                        // usable — never silently override the user's choice. Never a
                        // Swedish-only model (it would be used for other languages).
                        if !model.isSwedishOnly, !self.isModelDownloaded(AppSettings.shared.defaultWhisperModel) {
                            AppSettings.shared.defaultWhisperModel = model
                        }
                    } else {
                        self.modelDownloadError = (model, String(localized: "The download finished but the files aren't valid. Try again."))
                    }
                }

                // Prewarm in background — triggers CoreML compilation so first transcription is fast
                self.prewarmModel(model)
            } catch {
                await MainActor.run {
                    self.downloadingModel = nil
                    self.modelDownloadProgress = 0
                    if !(error is CancellationError) {
                        self.modelDownloadError = (model, String(localized: "Couldn't download the model: \(error.localizedDescription)"))
                    }
                }
            }
        }
    }

    func cancelModelDownload() {
        modelDownloadTask?.cancel()
        modelDownloadTask = nil
        downloadingModel = nil
        modelDownloadProgress = 0
    }

    func deleteModel(_ model: WhisperModel) {
        if !model.usesWhisperKit {
            Task {
                do {
                    try await PianissimoEngine.uninstall()
                    self.downloadedModels.remove(model)
                } catch {
                    self.transcriptionState = .error("Failed to delete model: \(error.localizedDescription)")
                }
            }
            return
        }
        guard let modelDir = findModelFolder(model) else { return }
        do {
            try fileManager.removeItem(at: modelDir)
            // If this was the loaded model, clear it
            if currentLoadedModel == model {
                whisperKit = nil
                currentLoadedModel = nil
            }
            DispatchQueue.main.async {
                self.downloadedModels.remove(model)
                // If the deleted model was the default, repoint the default at
                // another downloaded model so the next transcribe doesn't fail.
                if AppSettings.shared.defaultWhisperModel == model,
                   let replacement = self.downloadedModels.first {
                    AppSettings.shared.defaultWhisperModel = replacement
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.transcriptionState = .error("Failed to delete model: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - WhisperKit Initialization

    /// A downloaded multilingual model (needed to auto-detect language / transcribe
    /// non-Swedish). Prefers the user's default if it's multilingual.
    func multilingualBaseModel() -> WhisperModel {
        let def = AppSettings.shared.defaultWhisperModel
        if !def.isSwedishOnly, isModelDownloaded(def) { return def }
        for m in [WhisperModel.small, .base, .largev3turbo, .medium, .largev3, .tiny] where isModelDownloaded(m) { return m }
        return def
    }

    /// Re-run transcription on the SAME audio with a different language — for when a
    /// transcript came out in the wrong language. Overwrites the existing transcript
    /// file + history item, and clears the stale AI brief so it regenerates.
    /// The audio that produced the currently shown transcript — the kept playback
    /// copy if it's a fresh transcription, else the source media that lives next to
    /// the transcript file (meeting recordings keep their .m4a in the same folder).
    /// Never the global last_transcription.wav, which would be the WRONG audio for a
    /// transcript reopened from history.
    private var currentAudioForRetranscribe: String? {
        if let a = audioFilePath, fileManager.fileExists(atPath: a) { return a }
        guard let out = lastSavedPath else { return nil }
        let dir = (out as NSString).deletingLastPathComponent
        guard let files = try? fileManager.contentsOfDirectory(atPath: dir) else { return nil }
        let audioExts: Set<String> = ["m4a", "wav", "mp3", "caf", "mp4", "mov"]
        let audio = files.filter { audioExts.contains(($0 as NSString).pathExtension.lowercased()) }
        // Prefer the combined mix over the raw mic/system tracks.
        let main = audio.first { !["mic.m4a", "system.m4a"].contains($0.lowercased()) } ?? audio.first
        return main.map { dir + "/" + $0 }
    }

    var canRetranscribe: Bool { !isTranscribing && lastSavedPath != nil && currentAudioForRetranscribe != nil }

    func retranscribe(language: String) {
        guard !isTranscribing,
              let audio = currentAudioForRetranscribe,
              let outputPath = lastSavedPath else { return }
        // "auto"/non-Swedish need a multilingual model (so detection + English work);
        // explicit Swedish goes straight to Pianissimo. runWhisperKit still swaps to
        // Pianissimo if it detects Swedish under "auto".
        let model: WhisperModel = (language == "sv" && isModelDownloaded(.pianissimo)) ? .pianissimo
                                                                                       : multilingualBaseModel()
        // Drop the stale brief/commitments so they rebuild from the corrected text.
        if var sc = TranscriptAIStore.load(for: outputPath) {
            sc.templateOutputs?[PromptTemplateLibrary.meetingBriefID.uuidString] = nil
            sc.commitments = nil
            TranscriptAIStore.save(sc, for: outputPath)
            if currentTranscriptSource == .meeting { markPendingMeeting() }
        }
        // transcribeAudioFile deletes its input, so feed it a throwaway copy.
        let tmp = NSTemporaryDirectory() + UUID().uuidString + ".wav"
        do { try fileManager.copyItem(atPath: audio, toPath: tmp) }
        catch { transcriptionState = .error("Couldn't access the recording to re-transcribe."); return }
        transcribeAudioFile(audioPath: tmp, model: model, outputPath: outputPath, outputFormat: .txt, language: language)
    }

    // MARK: - Legacy KB-Whisper cleanup

    /// KB-Whisper was replaced by Pianissimo in 2.9. Its files stay on disk until
    /// the user removes them from Settings — never deleted automatically.
    private var legacyKBDirectory: URL {
        modelsDirectory.appendingPathComponent("models/mickekringai")
    }

    /// Bytes still used by old KB-Whisper models, or nil if none are left.
    func legacyKBModelsSize() -> Int64? {
        guard fileManager.fileExists(atPath: legacyKBDirectory.path) else { return nil }
        var total: Int64 = 0
        if let e = fileManager.enumerator(at: legacyKBDirectory, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in e {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    func removeLegacyKBModels() {
        do {
            try fileManager.removeItem(at: legacyKBDirectory)
            objectWillChange.send()
        } catch {
            transcriptionState = .error("Couldn't remove the old KB-Whisper models: \(error.localizedDescription)")
        }
    }

    private func ensureWhisperKit(model: WhisperModel, announce: Bool = true) async throws -> WhisperKit {
        if let kit = whisperKit, currentLoadedModel == model {
            return kit
        }

        guard let modelFolder = findModelFolder(model) else {
            throw NSError(domain: "TranscriptionManager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Model not downloaded"])
        }

        if announce {
            await MainActor.run {
                self.transcriptionState = .loadingModel(modelName: model.displayName)
            }
        }

        let loadStart = CFAbsoluteTimeGetCurrent()
        appLog("[MindExtract] Loading \(model.displayName) model from \(modelFolder.path)...")

        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            computeOptions: ModelComputeOptions(),
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )

        let kit = try await WhisperKit(config)
        self.whisperKit = kit
        self.currentLoadedModel = model

        let elapsed = CFAbsoluteTimeGetCurrent() - loadStart
        appLog("[MindExtract] \(model.displayName) model loaded in \(String(format: "%.1f", elapsed))s")

        return kit
    }

    /// Prewarm a model in the background after download, triggering CoreML compilation
    /// so the first transcription is fast.
    private func prewarmModel(_ model: WhisperModel) {
        if !model.usesWhisperKit {
            // First load specializes the models for this Mac's Neural Engine.
            Task.detached(priority: .utility) {
                await MainActor.run { self.prewarmingModel = model }
                let start = CFAbsoluteTimeGetCurrent()
                do {
                    _ = try await PianissimoEngine.shared.load()
                    appLog("[MindExtract] Pianissimo prewarm complete in \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start))s")
                } catch {
                    appLog("[MindExtract] Pianissimo prewarm failed: \(error.localizedDescription)")
                }
                await MainActor.run { self.prewarmingModel = nil }
            }
            return
        }
        guard let modelFolder = findModelFolder(model) else { return }

        Task.detached(priority: .utility) {
            await MainActor.run { self.prewarmingModel = model }

            let start = CFAbsoluteTimeGetCurrent()
            appLog("[MindExtract] Prewarming \(model.displayName) model (CoreML compilation)...")

            do {
                let config = WhisperKitConfig(
                    modelFolder: modelFolder.path,
                    computeOptions: ModelComputeOptions(),
                    verbose: false,
                    prewarm: true,
                    load: false,
                    download: false
                )
                let kit = try await WhisperKit(config)
                // After prewarm, keep it loaded if no other model is active
                await MainActor.run {
                    if self.whisperKit == nil {
                        self.whisperKit = kit
                        self.currentLoadedModel = model
                    }
                    self.prewarmingModel = nil
                }
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                appLog("[MindExtract] \(model.displayName) prewarm complete in \(String(format: "%.1f", elapsed))s")
            } catch {
                await MainActor.run { self.prewarmingModel = nil }
                appLog("[MindExtract] Prewarm failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Transcription

    /// Turn a title into a filesystem-safe base name (drops path-illegal chars, caps length).
    static func safeFileBase(_ title: String, fallback: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: illegal).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let bounded = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
        return bounded.isEmpty ? fallback : bounded
    }

    /// A path that doesn't collide with an existing file (appends " 2", " 3", …).
    static func uniqueFilePath(dir: String, base: String, ext: String) -> String {
        let fm = FileManager.default
        var candidate = "\(dir)/\(base).\(ext)"
        var n = 2
        while fm.fileExists(atPath: candidate) { candidate = "\(dir)/\(base) \(n).\(ext)"; n += 1 }
        return candidate
    }

    func transcribe(videoPath: String, model: WhisperModel, outputFormat: TranscriptionOutputFormat, language: String = "auto") {
        // Sync with file system before checking model availability
        loadDownloadedModels(synchronous: true)

        let usingApple = useAppleSpeech()
        let ffmpegPath = ffmpegBinaryPath

        // Apple Speech needs no downloaded model; only require one for WhisperKit.
        if !usingApple {
            guard isModelDownloaded(model) else {
                DispatchQueue.main.async {
                    self.transcriptionState = .modelNotDownloaded
                    self.advanceBatchIfNeeded()
                }
                return
            }
        }

        let videoURL = URL(fileURLWithPath: videoPath)
        let videoDirectory = videoURL.deletingLastPathComponent().path
        let videoBaseName = videoURL.deletingPathExtension().lastPathComponent
        let tempAudioPath = NSTemporaryDirectory() + UUID().uuidString + ".wav"
        // Name the transcript after the meeting/title the user gave it (not the raw
        // audio file), so the saved file reads like the meeting. Falls back to the
        // audio name; made unique so two same-named meetings don't overwrite.
        let base = Self.safeFileBase(currentTranscriptionTitle, fallback: videoBaseName)
        let outputPath = Self.uniqueFilePath(dir: videoDirectory, base: base, ext: outputFormat.rawValue)

        DispatchQueue.main.async {
            self.transcriptionState = .extractingAudio
        }

        // Extract the audio (natively; ffmpeg only for formats Apple can't read)
        extractAudio(ffmpegPath: ffmpegPath, videoPath: videoPath, outputPath: tempAudioPath) { [weak self] success, error in
            guard let self = self else { return }

            if !success {
                DispatchQueue.main.async {
                    self.transcriptionState = .error(error ?? "Failed to extract audio")
                    self.advanceBatchIfNeeded()
                }
                try? self.fileManager.removeItem(atPath: tempAudioPath)
                return
            }

            // Run transcription with the selected engine
            self.runTranscription(audioPath: tempAudioPath, model: model, outputPath: outputPath, outputFormat: outputFormat, language: language) {
                // Clean up temp audio
                try? self.fileManager.removeItem(atPath: tempAudioPath)
            }
        }
    }

    // MARK: - Transcribe Audio File Directly (for URL transcription)

    func transcribeAudioFile(audioPath: String, model: WhisperModel, outputPath: String, outputFormat: TranscriptionOutputFormat, language: String = "auto") {
        // Sync with file system before checking model availability
        loadDownloadedModels(synchronous: true)

        let usingApple = useAppleSpeech()

        // Apple Speech needs no downloaded model; only require one for WhisperKit.
        if !usingApple {
            guard isModelDownloaded(model) else {
                DispatchQueue.main.async {
                    self.transcriptionState = .modelNotDownloaded
                }
                try? fileManager.removeItem(atPath: audioPath)
                return
            }
        }

        let ffmpegPath = ffmpegBinaryPath

        let tempWavPath = NSTemporaryDirectory() + UUID().uuidString + "_whisper.wav"

        DispatchQueue.main.async {
            self.transcriptionState = .extractingAudio
        }

        // Convert to whisper-compatible format
        extractAudio(ffmpegPath: ffmpegPath, videoPath: audioPath, outputPath: tempWavPath) { [weak self] success, error in
            guard let self = self else { return }

            // Clean up original temp audio
            try? self.fileManager.removeItem(atPath: audioPath)

            if !success {
                DispatchQueue.main.async {
                    self.transcriptionState = .error(error ?? "Failed to convert audio")
                }
                try? self.fileManager.removeItem(atPath: tempWavPath)
                return
            }

            self.runTranscription(audioPath: tempWavPath, model: model, outputPath: outputPath, outputFormat: .txt, language: language) {
                try? self.fileManager.removeItem(atPath: tempWavPath)
            }
        }
    }

    // MARK: - WhisperKit Transcription

    private func runWhisperKit(audioPath: String, model: WhisperModel, outputPath: String, outputFormat: TranscriptionOutputFormat, language: String, cleanup: @escaping () -> Void = {}) {
        usedEngineName = model == .pianissimo ? "Pianissimo" : "Whisper \(model.displayName)"
        // Copy audio file for playback (keep it around)
        let playbackAudioPath = applicationSupportPath.appendingPathComponent("last_transcription.wav").path
        try? fileManager.removeItem(atPath: playbackAudioPath)
        try? fileManager.copyItem(atPath: audioPath, toPath: playbackAudioPath)

        // Probe the true audio duration up front so the progress estimate has a
        // denominator from the start (previously it stayed at 0% until the first
        // segment streamed in).
        let probedDuration: Float = {
            if let f = try? AVAudioFile(forReading: URL(fileURLWithPath: audioPath)),
               f.fileFormat.sampleRate > 0 {
                return Float(Double(f.length) / f.fileFormat.sampleRate)
            }
            return 0
        }()

        DispatchQueue.main.async {
            self.transcriptionState = .transcribing(progress: 0)
            self.liveTranscriptionText = ""
            self.segments = []
            self.speakerNameOverrides = [:]
            self.audioDuration = probedDuration
            self.audioFilePath = playbackAudioPath
            if !self.suppressAutoShow { self.showTranscriptionView = true }
        }

        currentTask = Task {
            do {
                // Translate-to-English is a one-shot, per-transcription choice — reset
                // it so it can't silently keep translating later files.
                let translate = UserDefaults.standard.bool(forKey: "translateToEnglish")
                if translate { UserDefaults.standard.set(false, forKey: "translateToEnglish") }

                // Auto-detect the spoken language (needs a WhisperKit model), and whenever
                // it's Swedish use Pianissimo — the best Swedish engine — if installed.
                // Detection is a quick first-chunk pass; never fatal.
                var activeModel = model
                var effectiveLanguage = language
                if language == "auto" {
                    let detector = model.usesWhisperKit ? model : self.multilingualBaseModel()
                    if self.findModelFolder(detector) != nil {
                        let detectKit = try await ensureWhisperKit(model: detector)
                        if let detected = try? await detectKit.detectLanguage(audioPath: audioPath) {
                            effectiveLanguage = detected.language
                            appLog("[MindExtract] Detected language: \(detected.language)")
                        }
                    } else if !model.usesWhisperKit {
                        // Only Pianissimo installed — nothing to detect with; it's Swedish.
                        effectiveLanguage = "sv"
                    }
                }
                if effectiveLanguage == "sv", !translate, self.isModelDownloaded(.pianissimo) {
                    if activeModel != .pianissimo { appLog("[MindExtract] Swedish — using Pianissimo") }
                    activeModel = .pianissimo
                } else if !activeModel.usesWhisperKit {
                    // Not Swedish (or translating): Pianissimo can't do it.
                    activeModel = self.multilingualBaseModel()
                }
                await MainActor.run { self.currentModelUsed = activeModel }

                await MainActor.run {
                    self.transcriptionState = .transcribing(progress: 0)
                }

                let results: [TranscriptionResult]
                if activeModel == .pianissimo {
                    results = try await self.transcribeWithPianissimo(audioPath: audioPath)
                } else {
                    let kit = try await ensureWhisperKit(model: activeModel)

                    // Configure transcription options
                    var options = DecodingOptions()
                    if effectiveLanguage != "auto" {
                        options.language = effectiveLanguage
                    }
                    options.wordTimestamps = true
                    // Whisper's built-in translate task: foreign speech straight into English.
                    if translate { options.task = .translate }
                    // Custom vocabulary: bias the decoder toward the user's names/terms
                    // by feeding them as a conditioning prompt. WhisperKit trims and
                    // strips special tokens itself; we just encode the cleaned list.
                    let vocab = Self.vocabularyPrompt(UserDefaults.standard.string(forKey: "customVocabulary") ?? "")
                    if !vocab.isEmpty, let tokenizer = kit.tokenizer {
                        let tokens = tokenizer.encode(text: " " + vocab)
                            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                        if !tokens.isEmpty { options.promptTokens = tokens }
                    }

                    // Set up segment discovery callback for real-time streaming
                    kit.segmentDiscoveryCallback = { [weak self] discoveredSegments in
                        guard let self = self else { return }
                        let newSegmentData = discoveredSegments.compactMap { seg -> TranscriptionSegmentData? in
                            let cleaned = self.cleanTokens(seg.text)
                            guard !cleaned.isEmpty else { return nil }
                            return TranscriptionSegmentData(
                                start: seg.start,
                                end: seg.end,
                                text: cleaned,
                                speaker: nil,
                                words: (seg.words ?? []).map { w in
                                    WordTimingData(word: self.cleanTokens(w.word), start: w.start, end: w.end, probability: w.probability)
                                },
                                avgLogprob: seg.avgLogprob
                            )
                        }
                        Task { @MainActor in
                            self.segments.append(contentsOf: newSegmentData)
                            self.liveTranscriptionText = self.segments.map { $0.text }.joined(separator: "\n\n")
                            if let lastEnd = self.segments.last?.end {
                                self.audioDuration = max(self.audioDuration, lastEnd)
                            }
                        }
                    }

                    // Progress callback for percentage updates
                    let callback: TranscriptionCallback = { [weak self] progress in
                        guard let self = self else { return nil }
                        Task { @MainActor in
                            // Use window progress as a rough percentage estimate
                            let windowId = progress.windowId
                            // Each window is ~30s of audio; estimate progress
                            if self.audioDuration > 0 {
                                let estimatedProgress = min(Double(windowId * 30) / Double(self.audioDuration), 0.99)
                                self.transcriptionState = .transcribing(progress: estimatedProgress)
                            }
                        }
                        return Task.isCancelled ? false : nil
                    }

                    // Run transcription with callbacks
                    let whisperResults = try await kit.transcribe(
                        audioPath: audioPath,
                        decodeOptions: options,
                        callback: callback
                    )

                    // Clear the callback to avoid retain cycles
                    kit.segmentDiscoveryCallback = nil
                    results = whisperResults
                }

                // Build final segment data from results (in case callback missed any)
                var allSegments: [TranscriptionSegmentData] = []
                for result in results {
                    for seg in result.segments {
                        let cleaned = self.cleanTokens(seg.text)
                        guard !cleaned.isEmpty else { continue }
                        allSegments.append(TranscriptionSegmentData(
                            start: seg.start,
                            end: seg.end,
                            text: cleaned,
                            speaker: nil,
                            words: (seg.words ?? []).map { w in
                                WordTimingData(word: self.cleanTokens(w.word), start: w.start, end: w.end, probability: w.probability)
                            },
                            avgLogprob: seg.avgLogprob
                        ))
                    }
                    if let lastSeg = result.segments.last {
                        self.audioDuration = max(self.audioDuration, lastSeg.end)
                    }
                }

                // Speaker diarization (if enabled)
                if AppSettings.shared.enableSpeakerDiarization {
                    await MainActor.run {
                        self.transcriptionState = .transcribing(progress: 0.95)
                    }

                    do {
                        appLog("[MindExtract] Starting speaker diarization...")
                        let audioArray = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath)
                        appLog("[MindExtract] Audio loaded: \(audioArray.count) samples")
                        let config = PyannoteConfig(verbose: true)
                        let speakerKit = try await SpeakerKit(config)
                        appLog("[MindExtract] SpeakerKit initialized, running diarization...")

                        // Use tuned diarization options for better speaker separation
                        let diarizationOptions = PyannoteDiarizationOptions(
                            clusterDistanceThreshold: 0.7,  // Higher = merge more aggressively (default 0.6), reduces phantom speakers
                            useExclusiveReconciliation: true
                        )
                        let diarizationResult = try await speakerKit.diarize(audioArray: audioArray, options: diarizationOptions)
                        appLog("[MindExtract] Diarization complete: \(diarizationResult.speakerCount) speakers found")
                        appLog("[MindExtract] Diarization timings: \(diarizationResult.timings)")

                        // Align speakers with transcription segments
                        let alignedResults = diarizationResult.addSpeakerInfo(to: results, strategy: .subsegment)

                        // Rebuild allSegments with speaker labels
                        var diarizedSegments: [TranscriptionSegmentData] = []
                        for speakerSegments in alignedResults {
                            for seg in speakerSegments {
                                let speakerLabel: String?
                                switch seg.speaker {
                                case .speakerId(let id):
                                    speakerLabel = "Speaker \(id + 1)"
                                case .multiple(let ids):
                                    speakerLabel = "Speaker \(ids.map { "\($0 + 1)" }.joined(separator: "/"))"
                                case .noMatch:
                                    speakerLabel = nil
                                @unknown default:
                                    speakerLabel = nil
                                }

                                let text = seg.text.isEmpty ? (seg.transcription?.text ?? "") : seg.text
                                let cleaned = self.cleanTokens(text)
                                guard !cleaned.isEmpty else { continue }

                                let words: [WordTimingData] = seg.speakerWords.map { w in
                                    WordTimingData(
                                        word: self.cleanTokens(w.wordTiming.word),
                                        start: w.wordTiming.start,
                                        end: w.wordTiming.end,
                                        probability: w.wordTiming.probability
                                    )
                                }

                                diarizedSegments.append(TranscriptionSegmentData(
                                    start: seg.startTime,
                                    end: seg.endTime,
                                    text: cleaned,
                                    speaker: speakerLabel,
                                    words: words,
                                    avgLogprob: seg.transcription?.avgLogprob ?? 0
                                ))
                            }
                        }

                        // Merge consecutive segments from the same speaker into paragraphs
                        if !diarizedSegments.isEmpty {
                            allSegments = mergeSameSpeakerSegments(diarizedSegments)
                        }

                        await speakerKit.unloadModels()
                    } catch {
                        // Diarization failed — continue with non-diarized segments
                        appLog("[MindExtract] Speaker diarization failed: \(error)")
                    }
                    appLog("[MindExtract] Post-diarization segments count: \(allSegments.count)")
                }

                // Channel-aware "you vs them": if this came from a meeting recording
                // with separate mic/system tracks, relabel who's speaking. Runs even
                // when diarization is off (degrades to You / Others).
                allSegments = await applyChannelAttribution(allSegments)

                // Build output text based on format
                let fullText: String
                switch outputFormat {
                case .srt:
                    fullText = buildSRT(from: allSegments)
                case .vtt:
                    fullText = buildVTT(from: allSegments)
                case .json:
                    fullText = buildJSON(from: allSegments)
                case .txt:
                    let body = allSegments.map { seg in
                        let ts = self.formatTimestampBracket(seg.start)
                        if let speaker = seg.speaker {
                            return "\(ts) \(speaker): \(seg.text)"
                        }
                        return "\(ts) \(seg.text)"
                    }.joined(separator: "\n\n")
                    // Lead the transcript with the meeting title + date, so the saved
                    // file reads like a document and the title travels with the text.
                    let titleLine = self.currentTranscriptionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    if titleLine.isEmpty {
                        fullText = body
                    } else {
                        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .short)
                        fullText = "# \(titleLine)\n\(dateStr)\n\n\(body)"
                    }
                }

                // Save to file
                try fullText.write(toFile: outputPath, atomically: true, encoding: .utf8)

                appLog("[MindExtract] Completing transcription: \(allSegments.count) segments, title: '\(self.currentTranscriptionTitle)', output: \(outputPath)")
                await MainActor.run {
                    self.segments = allSegments
                    self.liveTranscriptionText = allSegments.map { $0.text }.joined(separator: "\n\n")
                    self.lastSavedPath = outputPath
                    self.transcriptionState = .completed(outputPath: outputPath)
                    self.saveToHistory(title: self.currentTranscriptionTitle, filePath: outputPath)
                    self.notifyTranscriptionComplete()
                    self.finishMeetingExtras(path: outputPath)
                    self.advanceBatchIfNeeded()
                    appLog("[MindExtract] Final state: segments=\(self.segments.count), title='\(self.currentTranscriptionTitle)', liveText length=\(self.liveTranscriptionText.count)")
                }

                cleanup()

            } catch {
                if Task.isCancelled {
                    await MainActor.run {
                        self.transcriptionState = .idle
                    }
                } else {
                    await MainActor.run {
                        // If the error is about a missing model, show the helpful download prompt
                        if error.localizedDescription.contains("not downloaded") || error.localizedDescription.contains("Model not") {
                            self.transcriptionState = .modelNotDownloaded
                        } else {
                            self.transcriptionState = .error("Transcription failed: \(error.localizedDescription)")
                        }
                    }
                }
                await MainActor.run { self.discardPendingChannelSources(); self.advanceBatchIfNeeded() }
                cleanup()
            }
        }
    }

    /// Reads up to `maxSeconds` of a 16 kHz mono WAV as Float samples.
    nonisolated static func loadSamples(wavPath: String, maxSeconds: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: wavPath))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.processingFormat.sampleRate,
                                   channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(min(Double(file.length), maxSeconds * file.processingFormat.sampleRate))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return [] }
        try file.read(into: buffer, frameCount: frames)
        guard let data = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    // MARK: - Dictation

    enum DictationError: LocalizedError {
        case busy, noModel
        var errorDescription: String? {
            switch self {
            case .busy: return "Busy transcribing a file — try again in a moment."
            case .noModel: return "Download a speech model in Settings first."
            }
        }
    }

    /// Transcribes a short 16 kHz mono clip for push-to-talk dictation. Swedish →
    /// Pianissimo; other languages (and "auto" detection) → a Whisper model.
    /// Never touches the main transcript UI state.
    func transcribeDictation(samples: [Float], language: String) async throws -> String {
        let pianissimoReady = isModelDownloaded(.pianissimo)
        let whisperModel = multilingualBaseModel()
        let whisperReady = findModelFolder(whisperModel) != nil
        var lang = language
        if lang == "auto" {
            if whisperReady && !isTranscribing {
                let kit = try await ensureWhisperKit(model: whisperModel, announce: false)
                if let detected = try? await kit.detectLangauge(audioArray: samples) { lang = detected.language }
            } else if pianissimoReady {
                lang = "sv"
            }
        }
        if lang == "sv", pianissimoReady {
            return try await PianissimoEngine.shared.transcribe(samples: samples).text
        }
        // The shared WhisperKit instance isn't safe to use alongside a file job.
        guard !isTranscribing else { throw DictationError.busy }
        guard whisperReady else { throw DictationError.noModel }
        let kit = try await ensureWhisperKit(model: whisperModel, announce: false)
        var options = DecodingOptions()
        if lang != "auto" { options.language = lang }
        let vocab = Self.vocabularyPrompt(UserDefaults.standard.string(forKey: "customVocabulary") ?? "")
        if !vocab.isEmpty, let tokenizer = kit.tokenizer {
            let tokens = tokenizer.encode(text: " " + vocab).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if !tokens.isEmpty { options.promptTokens = tokens }
        }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return cleanTokens(results.map(\.text).joined(separator: " "))
    }

    // MARK: - Pianissimo Transcription

    /// Runs Pianissimo and returns WhisperKit-shaped results, so speaker
    /// diarization, channel attribution and export run unchanged for both engines.
    private func transcribeWithPianissimo(audioPath: String) async throws -> [TranscriptionResult] {
        usedEngineName = "Pianissimo"
        let isFirstLoad = await !PianissimoEngine.shared.isLoaded
        if isFirstLoad {
            transcriptionState = .loadingModel(modelName: WhisperModel.pianissimo.displayName)
        }
        let start = CFAbsoluteTimeGetCurrent()
        let output = try await PianissimoEngine.shared.transcribe(audioURL: URL(fileURLWithPath: audioPath)) { fraction in
            Task { @MainActor in
                // Leave headroom for diarization, which reports 0.95.
                self.transcriptionState = .transcribing(progress: min(fraction, 1) * 0.9)
            }
        }
        appLog("[MindExtract] Pianissimo: \(output.words.count) words, \(String(format: "%.1f", output.duration))s audio in \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start))s")

        let segments = PianissimoSegmenter.segments(from: output.words).enumerated().map { i, seg in
            TranscriptionSegment(
                id: i,
                start: Float(seg.start),
                end: Float(seg.end),
                text: seg.text,
                avgLogprob: log(max(seg.words.map(\.confidence).reduce(0, +) / Float(max(seg.words.count, 1)), 1e-4)),
                words: seg.words.map {
                    WordTiming(word: " " + $0.word, tokens: [], start: Float($0.start), end: Float($0.end), probability: $0.confidence)
                }
            )
        }
        audioDuration = max(audioDuration, Float(output.duration))
        return [TranscriptionResult(text: output.text, segments: segments, language: "sv", timings: TranscriptionTimings())]
    }

    // MARK: - Speaker Segment Merging

    /// Merges consecutive segments that have the same speaker into larger paragraph-like segments.
    /// This produces output similar to MacWhisper where text is grouped by speaker turn.
    /// Paragraphs stop at ~30 s so a long monologue keeps timestamps the notes can cite.
    static let maxParagraphSeconds: Float = 30

    private func mergeSameSpeakerSegments(_ segments: [TranscriptionSegmentData]) -> [TranscriptionSegmentData] {
        guard !segments.isEmpty else { return segments }

        var merged: [TranscriptionSegmentData] = []
        var current = segments[0]

        for i in 1..<segments.count {
            let next = segments[i]

            // Same speaker (or both nil) — merge, up to a paragraph's length
            if current.speaker == next.speaker, next.end - current.start <= Self.maxParagraphSeconds {
                let combinedText = current.text + " " + next.text
                let combinedWords = current.words + next.words
                let avgProb = (current.avgLogprob + next.avgLogprob) / 2
                current = TranscriptionSegmentData(
                    start: current.start,
                    end: next.end,
                    text: combinedText,
                    speaker: current.speaker,
                    words: combinedWords,
                    avgLogprob: avgProb
                )
            } else {
                // Different speaker — save current and start new
                merged.append(current)
                current = next
            }
        }
        merged.append(current)

        appLog("[MindExtract] Merged \(segments.count) segments into \(merged.count) speaker turns")
        return merged
    }

    // MARK: - SRT Builder

    private func buildSRT(from segments: [TranscriptionSegmentData]) -> String {
        var srt = ""
        for (i, seg) in segments.enumerated() {
            let startTime = formatSRTTime(seg.start)
            let endTime = formatSRTTime(seg.end)
            srt += "\(i + 1)\n"
            srt += "\(startTime) --> \(endTime)\n"
            if let speaker = seg.speaker {
                srt += "\(speaker): \(seg.text)\n\n"
            } else {
                srt += "\(seg.text)\n\n"
            }
        }
        return srt
    }

    private func formatTimestampBracket(_ seconds: Float) -> String {
        let totalSeconds = Int(seconds)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return String(format: "[%d:%02d:%02d]", h, m, s)
        }
        return String(format: "[%02d:%02d]", m, s)
    }

    private func formatSRTTime(_ seconds: Float) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        let milliseconds = Int((seconds - Float(totalSeconds)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, milliseconds)
    }

    // MARK: - VTT Builder

    private func buildVTT(from segments: [TranscriptionSegmentData]) -> String {
        var vtt = "WEBVTT\n\n"
        for (i, seg) in segments.enumerated() {
            let start = formatVTTTime(seg.start)
            let end = formatVTTTime(seg.end)
            vtt += "\(i + 1)\n"
            vtt += "\(start) --> \(end)\n"
            if let speaker = seg.speaker {
                vtt += "<v \(speaker)>\(seg.text)\n\n"
            } else {
                vtt += "\(seg.text)\n\n"
            }
        }
        return vtt
    }

    private func formatVTTTime(_ seconds: Float) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        let milliseconds = Int((seconds - Float(totalSeconds)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, milliseconds)
    }

    // MARK: - JSON Builder

    private func buildJSON(from segments: [TranscriptionSegmentData]) -> String {
        var jsonSegments: [[String: Any]] = []
        for seg in segments {
            var dict: [String: Any] = [
                "start": seg.start,
                "end": seg.end,
                "text": seg.text,
                "confidence": seg.confidence
            ]
            if let speaker = seg.speaker {
                dict["speaker"] = speaker
            }
            if !seg.words.isEmpty {
                dict["words"] = seg.words.map { w in
                    ["word": w.word, "start": w.start, "end": w.end, "probability": w.probability] as [String : Any]
                }
            }
            jsonSegments.append(dict)
        }
        let wrapper: [String: Any] = [
            "duration": audioDuration,
            "segments": jsonSegments
        ]
        if let data = try? JSONSerialization.data(withJSONObject: wrapper, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }

    // MARK: - Audio Extraction (FFmpeg)

    /// Converts any media to 16 kHz mono WAV. Uses AVFoundation first (works on
    /// every Mac, no external tools); falls back to the bundled ffmpeg only for
    /// formats Apple can't open, like webm/mkv. Calls back on the main actor.
    private func extractAudio(ffmpegPath: String?, videoPath: String, outputPath: String,
                              completion: @escaping @MainActor (Bool, String?) -> Void) {
        let input = URL(fileURLWithPath: videoPath)
        let output = URL(fileURLWithPath: outputPath)
        Task.detached(priority: .userInitiated) {
            let result: (Bool, String?)
            do {
                try await AudioConverter.toWhisperWav(input: input, output: output)
                result = (true, nil)
            } catch AudioConverter.ConversionError.noAudio {
                result = (false, AudioConverter.ConversionError.noAudio.localizedDescription)
            } catch {
                appLog("[MindExtract] Native audio conversion failed (\(error.localizedDescription)); trying ffmpeg")
                if let ffmpegPath {
                    result = await Self.runFFmpeg(ffmpegPath: ffmpegPath, videoPath: videoPath, outputPath: outputPath)
                } else {
                    result = (false, String(localized: "This file format isn't supported. Try an audio file such as m4a, mp3 or wav."))
                }
            }
            await MainActor.run { completion(result.0, result.1) }
        }
    }

    private nonisolated static func runFFmpeg(ffmpegPath: String, videoPath: String, outputPath: String) async -> (Bool, String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-i", videoPath,
            "-ar", "16000",
            "-ac", "1",
            "-c:a", "pcm_s16le",
            "-y",
            outputPath
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return (true, nil) }
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            return (false, "FFmpeg error: \(String(data: errorData, encoding: .utf8) ?? "unknown")")
        } catch {
            return (false, String(localized: "This file format needs a conversion tool that couldn't start on this Mac. Try an audio file such as m4a, mp3 or wav."))
        }
    }

    // MARK: - Cancel / Reset

    func cancelTranscription() {
        currentTask?.cancel()
        currentTask = nil
        currentProcess?.terminate()
        currentProcess = nil
        discardPendingChannelSources()
        DispatchQueue.main.async {
            // Don't throw away work already transcribed — save the partial result
            // so the user can still read, copy, and export it.
            if !self.segments.isEmpty, let path = self.activeOutputPath {
                let partialPath = path.replacingOccurrences(of: ".\(URL(fileURLWithPath: path).pathExtension)",
                                                            with: " (partial).\(URL(fileURLWithPath: path).pathExtension)")
                let text = self.segments.map { $0.text }.joined(separator: "\n\n")
                try? text.write(toFile: partialPath, atomically: true, encoding: .utf8)
                self.lastSavedPath = partialPath
                if !self.currentTranscriptionTitle.hasSuffix("(partial)") {
                    self.currentTranscriptionTitle += " (partial)"
                }
                self.saveToHistory(title: self.currentTranscriptionTitle, filePath: partialPath)
                self.transcriptionState = .completed(outputPath: partialPath)
            } else {
                self.transcriptionState = .idle
            }
            self.activeOutputPath = nil
            // Cancelling stops the whole batch (and frees the navigation suppression).
            self.batchActive = false
            self.batchQueue.removeAll()
            self.suppressAutoShow = false
        }
    }

    func resetState() {
        DispatchQueue.main.async {
            self.transcriptionState = .idle
        }
    }

    // MARK: - Transcription Text Actions

    func copyTranscriptionToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(liveTranscriptionText, forType: .string)
    }

    func saveTranscriptionAs() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = (currentTranscriptionTitle.isEmpty ? "transcription" : currentTranscriptionTitle) + ".txt"
        savePanel.canCreateDirectories = true

        if savePanel.runModal() == .OK, let url = savePanel.url {
            do {
                try liveTranscriptionText.write(to: url, atomically: true, encoding: .utf8)
                lastSavedPath = url.path
            } catch {
                Self.presentExportError(error)
            }
        }
    }

    /// Tell the user when a save fails (disk full, permissions) instead of
    /// silently doing nothing after they picked a destination.
    private static func presentExportError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t save the file"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Save an arbitrary plain-text artifact (e.g. a translation) to a .txt file,
    /// pre-naming it after the transcript with a suffix like " (Spanish)".
    func exportPlainText(_ text: String, filenameSuffix: String = "") {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        let baseName = currentTranscriptionTitle.isEmpty ? "transcription" : currentTranscriptionTitle
        savePanel.nameFieldStringValue = "\(baseName)\(filenameSuffix).txt"
        savePanel.canCreateDirectories = true
        if savePanel.runModal() == .OK, let url = savePanel.url {
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Self.presentExportError(error)
            }
        }
    }

    func exportAs(format: TranscriptionOutputFormat) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        let baseName = currentTranscriptionTitle.isEmpty ? "transcription" : currentTranscriptionTitle
        savePanel.nameFieldStringValue = "\(baseName).\(format.rawValue)"
        savePanel.canCreateDirectories = true

        if savePanel.runModal() == .OK, let url = savePanel.url {
            let content: String
            switch format {
            case .txt:
                content = segments.map { seg in
                    let ts = formatTimestampBracket(seg.start)
                    if let speaker = seg.speaker {
                        return "\(ts) \(speakerDisplayName(speaker)): \(seg.text)"
                    }
                    return "\(ts) \(seg.text)"
                }.joined(separator: "\n\n")
            case .srt:
                content = buildSRT(fromSegments: segments)
            case .vtt:
                content = buildVTT(from: segments)
            case .json:
                content = buildJSON(from: segments)
            }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Self.presentExportError(error)
            }
        }
    }

    private func buildSRT(fromSegments segments: [TranscriptionSegmentData]) -> String {
        var srt = ""
        for (i, seg) in segments.enumerated() {
            let start = formatSRTTime(seg.start)
            let end = formatSRTTime(seg.end)
            srt += "\(i + 1)\n"
            srt += "\(start) --> \(end)\n"
            if let speaker = seg.speaker {
                srt += "\(speakerDisplayName(speaker)): \(seg.text)\n\n"
            } else {
                srt += "\(seg.text)\n\n"
            }
        }
        return srt
    }

    func clearTranscription() {
        // Clean up playback audio
        if let path = audioFilePath {
            try? fileManager.removeItem(atPath: path)
        }
        DispatchQueue.main.async {
            self.liveTranscriptionText = ""
            self.currentTranscriptionTitle = ""
            self.showTranscriptionView = false
            self.lastSavedPath = nil
            self.segments = []
            self.audioDuration = 0
            self.audioFilePath = nil
        }
    }

    /// Source category for the next transcript's history entry (meeting/download/file).
    var currentTranscriptSource: TranscriptSource = .file

    // MARK: Batch transcription (folder / many files)
    @Published var batchActive = false
    @Published var batchTotal = 0
    @Published var batchDone = 0
    private var batchQueue: [URL] = []
    private var batchModel: WhisperModel = .small
    private var batchLanguage = "auto"
    /// While true, completing a transcription does NOT navigate to its result
    /// (batch runs in the background; the user stays where they are).
    private var suppressAutoShow = false

    /// Transcribe a list of media files one at a time, saving each to history.
    func startBatch(files: [URL], model: WhisperModel, language: String) {
        guard !files.isEmpty, !batchActive, !isTranscribing else { return }
        batchQueue = files
        batchTotal = files.count
        batchDone = 0
        batchModel = model
        batchLanguage = language
        batchActive = true
        suppressAutoShow = true
        processNextBatch()
    }

    private func processNextBatch() {
        guard !batchQueue.isEmpty else {
            batchActive = false
            suppressAutoShow = false
            return
        }
        let url = batchQueue.removeFirst()
        startNewTranscription(title: url.deletingPathExtension().lastPathComponent, model: batchModel, source: .file)
        transcribe(videoPath: url.path, model: batchModel,
                   outputFormat: AppSettings.shared.transcriptionOutputFormat, language: batchLanguage)
    }

    /// Called when a transcription finishes (success or failure) — advances the
    /// batch to the next file, or ends the batch.
    private func advanceBatchIfNeeded() {
        guard batchActive else { return }
        batchDone += 1
        if batchQueue.isEmpty {
            batchActive = false
            suppressAutoShow = false
        } else {
            processNextBatch()
        }
    }

    func startNewTranscription(title: String, model: WhisperModel? = nil, source: TranscriptSource = .file) {
        currentTranscriptSource = source
        // Set synchronously: transcribe() names the output file from the title
        // right after this call (async here left the previous note's name).
        currentTranscriptionTitle = title
        liveTranscriptionText = ""
        lastSavedPath = nil
        segments = []   // never show the previous note's transcript while this one runs
        usedEngineName = nil
        currentModelUsed = model
        DispatchQueue.main.async {
            // During a batch we transcribe in the background — don't yank the user
            // into each result view.
            guard !self.suppressAutoShow else { return }
            // Force re-trigger .onChange even if already true
            if self.showTranscriptionView {
                self.showTranscriptionView = false
            }
            DispatchQueue.main.async {
                self.showTranscriptionView = true
            }
        }
    }

    /// Edit a segment's text (transcript editor): update in memory, refresh the
    /// plain-text mirror, and re-persist both the saved transcript file and its
    /// segments sidecar so the change survives reopen.
    func updateSegmentText(id: UUID, to newText: String) {
        guard let idx = segments.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard segments[idx].text != trimmed else { return }
        segments[idx].text = trimmed
        liveTranscriptionText = segments.map { $0.text }.joined(separator: "\n\n")
        guard let path = lastSavedPath else { return }
        let format = TranscriptionOutputFormat(rawValue: URL(fileURLWithPath: path).pathExtension) ?? .txt
        try? buildTranscriptText(segments, format: format).write(toFile: path, atomically: true, encoding: .utf8)
        saveSegmentData(to: path + ".segments.json")
    }

    private func saveToHistory(title: String, filePath: String) {
        // Save segment data alongside the transcription for later reload
        let segmentDataPath = filePath + ".segments.json"
        saveSegmentData(to: segmentDataPath)

        // Use a meaningful title: prefer the provided title, fall back to filename
        var resolvedTitle = title
        if resolvedTitle.isEmpty || resolvedTitle == "Video Transcription" {
            let url = URL(fileURLWithPath: filePath)
            resolvedTitle = url.deletingPathExtension().lastPathComponent
        }

        let duration = audioDuration > 0 ? formatDurationForHistory(audioDuration) : nil
        var historyItem = TranscriptionHistoryItem(
            title: resolvedTitle,
            filePath: filePath,
            duration: duration,
            modelUsed: usedEngineName ?? currentModelUsed?.displayName ?? "Unknown"
        )
        historyItem.source = currentTranscriptSource.rawValue
        transcriptionHistory.addToHistory(historyItem)
    }

    private func formatDurationForHistory(_ seconds: Float) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func saveSegmentData(to path: String) {
        let segmentDicts: [[String: Any]] = segments.map { seg in
            var dict: [String: Any] = [
                "start": seg.start,
                "end": seg.end,
                "text": seg.text,
                "avgLogprob": seg.avgLogprob
            ]
            if let speaker = seg.speaker { dict["speaker"] = speaker }
            if !seg.words.isEmpty {
                dict["words"] = seg.words.map { w in
                    ["word": w.word, "start": w.start, "end": w.end, "probability": w.probability] as [String: Any]
                }
            }
            return dict
        }
        if let data = try? JSONSerialization.data(withJSONObject: segmentDicts, options: []),
           let str = String(data: data, encoding: .utf8) {
            try? str.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func loadSegmentData(from filePath: String) -> [TranscriptionSegmentData]? {
        let segPath = filePath + ".segments.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: segPath)),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return arr.compactMap { dict -> TranscriptionSegmentData? in
            guard let start = dict["start"] as? Double,
                  let end = dict["end"] as? Double,
                  let text = dict["text"] as? String,
                  let avgLogprob = dict["avgLogprob"] as? Double else { return nil }
            let speaker = dict["speaker"] as? String
            var words: [WordTimingData] = []
            if let wordArr = dict["words"] as? [[String: Any]] {
                words = wordArr.compactMap { w in
                    guard let word = w["word"] as? String,
                          let ws = w["start"] as? Double,
                          let we = w["end"] as? Double,
                          let wp = w["probability"] as? Double else { return nil }
                    return WordTimingData(word: word, start: Float(ws), end: Float(we), probability: Float(wp))
                }
            }
            return TranscriptionSegmentData(
                start: Float(start), end: Float(end), text: text,
                speaker: speaker, words: words, avgLogprob: Float(avgLogprob)
            )
        }
    }

    func openTranscriptionFromHistory(_ item: TranscriptionHistoryItem) {
        guard let text = item.transcriptionText else {
            transcriptionState = .error("Transcription file not found")
            return
        }

        // Try to load saved segment data
        let loadedSegments = loadSegmentData(from: item.filePath)

        DispatchQueue.main.async {
            self.currentTranscriptionTitle = item.title
            self.liveTranscriptionText = text
            self.lastSavedPath = item.filePath
            // Clear any prior transcript's custom speaker names; restoreAISidecar
            // repopulates them from this item's sidecar.
            self.speakerNameOverrides = [:]
            // Play the recording kept next to the transcript (meetings keep theirs);
            // otherwise hide the player rather than play a stale temp file.
            self.audioFilePath = Self.audioBeside(transcript: item.filePath)
            self.currentTranscriptSource = item.sourceType ?? .file
            self.segments = loadedSegments ?? []
            if let segs = loadedSegments, let last = segs.last {
                self.audioDuration = last.end
            }
            self.transcriptionState = .completed(outputPath: item.filePath)
            // Force re-trigger .onChange even if already true
            if self.showTranscriptionView {
                self.showTranscriptionView = false
            }
            DispatchQueue.main.async {
                self.showTranscriptionView = true
            }
        }
    }
}

// MARK: - Transcription Engine Routing & Apple SpeechAnalyzer

extension TranscriptionManager {

    /// Resolves a desired language ("auto" or a code) to a locale the SpeechTranscriber
    /// actually supports, falling back to English, then any supported locale.
    @available(macOS 26.0, *)
    static func resolveTranscriberLocale(language: String) async -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        func norm(_ s: String) -> String { s.replacingOccurrences(of: "_", with: "-").lowercased() }
        let desired = (language == "auto") ? Locale.current.identifier : language
        let desiredNorm = norm(desired)
        let desiredLang = Locale(identifier: desired).language.languageCode?.identifier

        if let exact = supported.first(where: { norm($0.identifier) == desiredNorm }) { return exact }
        if let langMatch = supported.first(where: { $0.language.languageCode?.identifier == desiredLang }) { return langMatch }
        if let english = supported.first(where: { norm($0.identifier).hasPrefix("en") }) { return english }
        return supported.first ?? Locale(identifier: "en-US")
    }

    /// Whether Apple's SpeechTranscriber supports a given language code. Apple
    /// only covers ~30 locales (no Swedish, Dutch, Russian, Arabic, Hindi, …), so
    /// for those we must route to WhisperKit instead of silently using English.
    @available(macOS 26.0, *)
    static func appleSpeechSupports(_ language: String) async -> Bool {
        if language == "auto" { return true }   // auto uses the system locale
        let want = Locale(identifier: language).language.languageCode?.identifier ?? language
        let supported = await SpeechTranscriber.supportedLocales
        return supported.contains { $0.language.languageCode?.identifier == want }
    }

    /// Runs SpeakerKit diarization and assigns a speaker label to each transcript
    /// segment by maximum time-overlap. Engine-agnostic (used for the Apple Speech
    /// path, which has no built-in diarization). Returns the input unchanged on failure.
    func assignSpeakersByOverlap(to segments: [TranscriptionSegmentData], audioPath: String) async -> [TranscriptionSegmentData] {
        do {
            let audioArray = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath)
            let speakerKit = try await SpeakerKit(PyannoteConfig(verbose: false))
            let options = PyannoteDiarizationOptions(
                clusterDistanceThreshold: 0.7,
                useExclusiveReconciliation: true
            )
            let result = try await speakerKit.diarize(audioArray: audioArray, options: options)
            await speakerKit.unloadModels()

            let diar = result.segments
            guard !diar.isEmpty else { return segments }

            func label(for info: SpeakerInfo) -> String? {
                switch info {
                case .speakerId(let id): return "Speaker \(id + 1)"
                case .multiple(let ids): return "Speaker \(ids.map { "\($0 + 1)" }.joined(separator: "/"))"
                case .noMatch: return nil
                @unknown default: return nil
                }
            }

            return segments.map { seg in
                var bestSpeaker: SpeakerInfo?
                var bestOverlap: Float = 0
                for d in diar {
                    let overlap = min(seg.end, d.endTime) - max(seg.start, d.startTime)
                    if overlap > bestOverlap {
                        bestOverlap = overlap
                        bestSpeaker = d.speaker
                    }
                }
                var copy = seg
                copy.speaker = bestSpeaker.flatMap(label)
                return copy
            }
        } catch {
            appLog("[MindExtract] Apple-path diarization failed: \(error)")
            return segments
        }
    }

    /// Channel-aware "you vs them" attribution. When a meeting was recorded with
    /// separate mic and system tracks (set via `pendingChannelSources`), this
    /// compares per-segment loudness across the two channels: a segment where the
    /// microphone dominates is *you* speaking; where system audio dominates it's a
    /// remote participant. Overlays on top of any existing SpeakerKit labels:
    ///   • mic-dominant  → relabel as "You"
    ///   • system-dominant → keep the diarized "Speaker N" label, or "Others" if none
    /// Works even with diarization off (degrades to You / Others). Consumes (deletes)
    /// the source files. Returns the input unchanged when no channel sources are set.
    func applyChannelAttribution(_ segments: [TranscriptionSegmentData]) async -> [TranscriptionSegmentData] {
        guard let sources = pendingChannelSources else { return segments }
        pendingChannelSources = nil   // consumed on the main actor before the I/O hop
        // Decode both source files and compute per-segment energy off the main
        // thread — on a long meeting these files are large and would otherwise
        // freeze the UI.
        return await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            defer {
                try? fm.removeItem(atPath: sources.mic)
                try? fm.removeItem(atPath: sources.system)
            }
            guard let mic = try? AudioProcessor.loadAudioAsFloatArray(fromPath: sources.mic),
                  let sys = try? AudioProcessor.loadAudioAsFloatArray(fromPath: sources.system),
                  !mic.isEmpty, !sys.isEmpty else { return segments }

            // loadAudioAsFloatArray returns 16 kHz mono Float32 (WhisperKit's rate).
            let sr = 16000.0
            func rms(_ a: [Float], _ start: Float, _ end: Float) -> Float {
                // Double math for the index — Float loses sample precision past ~30 min.
                let s = max(0, Int(Double(start) * sr))
                let e = min(a.count, Int(Double(end) * sr))
                guard e > s else { return 0 }
                // Subsample long windows so per-segment energy is cheap.
                let step = max(1, (e - s) / 1024)
                var sum: Float = 0
                var n = 0
                var i = s
                while i < e { sum += a[i] * a[i]; i += step; n += 1 }
                return n > 0 ? (sum / Float(n)).squareRoot() : 0
            }

            return segments.map { seg in
                var copy = seg
                let micE = rms(mic, seg.start, seg.end)
                let sysE = rms(sys, seg.start, seg.end)
                // Require a clear margin so cross-talk/echo doesn't flip the label.
                if micE > 0.003 && micE > sysE * 1.3 {
                    copy.speaker = "You"
                } else if sysE > 0.003 && sysE > micE * 1.3 {
                    copy.speaker = copy.speaker ?? "Others"
                }
                return copy
            }
        }.value
    }

    /// Normalize the user's custom-vocabulary text (lines and/or commas) into a
    /// single comma-separated prompt string. Caps length so the conditioning
    /// prompt stays short (WhisperKit also trims to its own max).
    static func vocabularyPrompt(_ raw: String) -> String {
        let terms = raw
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return "" }
        // Dedupe (case-insensitive) preserving order.
        var seen = Set<String>()
        let unique = terms.filter { seen.insert($0.lowercased()).inserted }
        // Pack whole terms up to a budget — never slice mid-word (a partial token
        // is worse than omitting the term).
        var result = ""
        for term in unique {
            let candidate = result.isEmpty ? term : result + ", " + term
            if candidate.count > 800 { break }
            result = candidate
        }
        return result
    }

    /// Post a "transcription complete" notification (if enabled). Useful for long
    /// files or auto-transcribed downloads finishing while the user is elsewhere.
    private func notifyTranscriptionComplete() {
        guard AppSettings.shared.notifyOnTranscriptionComplete else { return }
        let content = UNMutableNotificationContent()
        content.title = "Transcription complete"
        content.body = currentTranscriptionTitle.isEmpty ? "Your transcript is ready." : currentTranscriptionTitle
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { appLog("[MindExtract] transcription notification failed: \(error)") }
        }
    }

    /// Drop unconsumed channel sources (delete the temp mic/system files) so a
    /// failed/cancelled meeting transcription can't leak files or mis-attribute a
    /// later, unrelated transcript.
    func discardPendingChannelSources() {
        guard let sources = pendingChannelSources else { return }
        pendingChannelSources = nil
        let fm = FileManager.default
        try? fm.removeItem(atPath: sources.mic)
        try? fm.removeItem(atPath: sources.system)
    }

    /// Whether to use Apple's SpeechAnalyzer for the next transcription.
    /// Falls back to WhisperKit when SpeechAnalyzer isn't available (macOS < 26).
    func useAppleSpeech() -> Bool {
        let choice = AppSettings.shared.transcriptionEngine
        if choice == .whisperKit { return false }
        if #available(macOS 26.0, *) {
            return choice == .appleSpeech || choice == .automatic
        }
        return false
    }

    /// Never use a Swedish-only model (Pianissimo) for non-Swedish audio. Under
    /// "auto", runWhisperKit decides after detection, so Pianissimo passes through.
    func effectiveWhisperModel(_ model: WhisperModel, language: String) -> WhisperModel {
        if model.isSwedishOnly && language != "sv" && language != "auto" {
            return downloadedModels.first { !$0.isSwedishOnly } ?? .small
        }
        return model
    }

    /// Routes an already-extracted audio file to the right engine. "Automatic"
    /// language is resolved first (see `detectSpokenLanguage`), so no engine has
    /// to guess — Apple Speech, for one, can't detect a language at all.
    func runTranscription(audioPath: String, model: WhisperModel, outputPath: String, outputFormat: TranscriptionOutputFormat, language: String, cleanup: @escaping () -> Void = {}) {
        activeOutputPath = outputPath
        guard language == "auto" else {
            route(audioPath: audioPath, model: model, outputPath: outputPath, outputFormat: outputFormat, language: language, cleanup: cleanup)
            return
        }
        currentTask = Task { @MainActor in
            let detected = await self.detectSpokenLanguage(audioPath: audioPath)
            appLog("[MindExtract] Spoken language: \(detected)")
            self.route(audioPath: audioPath, model: model, outputPath: outputPath, outputFormat: outputFormat, language: detected, cleanup: cleanup)
        }
    }

    /// Which language is spoken. Pianissimo transcribes the first 30 s (≈0.1 s of
    /// work) and Apple's on-device NaturalLanguage reads the text — far steadier
    /// than Whisper's audio-only guess, which calls Swedish English on mixed audio.
    /// Falls back to Whisper's detection, then to the Mac's language.
    func detectSpokenLanguage(audioPath: String) async -> String {
        let supported = Set(AppSettings.transcriptionLanguages.map(\.code))
        if PianissimoEngine.isInstalled,
           let samples = try? Self.loadSamples(wavPath: audioPath, maxSeconds: 30), samples.count > 16_000,
           let out = try? await PianissimoEngine.shared.transcribe(samples: samples), out.words.count >= 4 {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(out.text)
            if let (lang, p) = recognizer.languageHypotheses(withMaximum: 1).first {
                var code = lang.rawValue
                if code == "nb" || code == "nn" { code = "no" }
                if code == "sv", p >= 0.5 { return "sv" }
                if p >= 0.8, supported.contains(code) { return code }
            }
        }
        let detector = multilingualBaseModel()
        if findModelFolder(detector) != nil,
           let kit = try? await ensureWhisperKit(model: detector, announce: false),
           let d = try? await kit.detectLanguage(audioPath: audioPath) {
            return d.language
        }
        let mac = Locale.current.language.languageCode?.identifier ?? "en"
        return supported.contains(mac) ? mac : "en"
    }

    private func route(audioPath: String, model: WhisperModel, outputPath: String, outputFormat: TranscriptionOutputFormat, language: String, cleanup: @escaping () -> Void) {
        // Swedish always goes to Pianissimo when it's downloaded — it beats every
        // other engine on Swedish. The engine setting decides everything else.
        if language == "sv" && isModelDownloaded(.pianissimo) {
            runWhisperKit(audioPath: audioPath, model: .pianissimo, outputPath: outputPath, outputFormat: outputFormat, language: language, cleanup: cleanup)
        } else if useAppleSpeech(), #available(macOS 26.0, *) {
            // Apple Speech can't do every language. If it can't do this one, route
            // to WhisperKit (which can).
            currentTask = Task { @MainActor in
                if await Self.appleSpeechSupports(language) {
                    self.runSpeechAnalyzer(audioPath: audioPath, outputPath: outputPath, outputFormat: outputFormat, language: language, cleanup: cleanup)
                } else if self.isModelDownloaded(model) || !self.downloadedModels.isEmpty {
                    let picked = self.isModelDownloaded(model) ? model : (self.downloadedModels.first ?? model)
                    let useModel = self.effectiveWhisperModel(picked, language: language)
                    self.runWhisperKit(audioPath: audioPath, model: useModel, outputPath: outputPath, outputFormat: outputFormat, language: language, cleanup: cleanup)
                } else {
                    let name = AppSettings.transcriptionLanguages.first { $0.code == language }?.name ?? language
                    self.transcriptionState = .error(String(localized: "Apple's speech recognition doesn't support \(name). Download a speech model in Settings → Transcription and try again."))
                    cleanup()
                    self.advanceBatchIfNeeded()
                }
            }
        } else {
            runWhisperKit(audioPath: audioPath, model: effectiveWhisperModel(model, language: language), outputPath: outputPath, outputFormat: outputFormat, language: language, cleanup: cleanup)
        }
    }

    /// Builds the export text for the chosen format from finished segments.
    func buildTranscriptText(_ segments: [TranscriptionSegmentData], format: TranscriptionOutputFormat) -> String {
        switch format {
        case .srt:
            return buildSRT(from: segments)
        case .vtt:
            return buildVTT(from: segments)
        case .json:
            return buildJSON(from: segments)
        case .txt:
            return segments.map { seg in
                let ts = self.formatTimestampBracket(seg.start)
                if let speaker = seg.speaker {
                    return "\(ts) \(speaker): \(seg.text)"
                }
                return "\(ts) \(seg.text)"
            }.joined(separator: "\n\n")
        }
    }

    /// Transcribes a (WAV) audio file with Apple's on-device SpeechAnalyzer.
    /// Streams segments live, reports true audio-time progress, no model download.
    /// (Speaker diarization is not yet applied on this path.)
    @available(macOS 26.0, *)
    func runSpeechAnalyzer(audioPath: String, outputPath: String, outputFormat: TranscriptionOutputFormat, language: String, cleanup: @escaping () -> Void = {}) {
        usedEngineName = "Apple Speech"
        // Keep a copy of the audio for the result view's player.
        let playbackAudioPath = applicationSupportPath.appendingPathComponent("last_transcription.wav").path
        try? fileManager.removeItem(atPath: playbackAudioPath)
        try? fileManager.copyItem(atPath: audioPath, toPath: playbackAudioPath)

        transcriptionState = .loadingModel(modelName: "Apple Speech")
        liveTranscriptionText = ""
        segments = []
        speakerNameOverrides = [:]
        audioDuration = 0
        audioFilePath = playbackAudioPath
        if !suppressAutoShow { showTranscriptionView = true }

        currentTask = Task {
            do {
                // Match against the engine's actual supported locales — passing a raw
                // region locale (e.g. sv_SE / en_SE) fails with "unsupported locale".
                let locale = await Self.resolveTranscriberLocale(language: language)

                let transcriber = SpeechTranscriber(
                    locale: locale,
                    transcriptionOptions: [],
                    reportingOptions: [],
                    attributeOptions: [.audioTimeRange]
                )

                // Download the locale model on first use.
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    transcriptionState = .loadingModel(modelName: "Apple Speech (installing language model…)")
                    try await request.downloadAndInstall()
                }

                let audioFile = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
                let sampleRate = audioFile.fileFormat.sampleRate
                let totalDuration = sampleRate > 0 ? Double(audioFile.length) / sampleRate : 0
                if totalDuration > 0 { audioDuration = Float(totalDuration) }

                transcriptionState = .transcribing(progress: 0)

                // File-based analysis: processes in the background and ends the
                // results stream when the whole file is done.
                let analyzer = try await SpeechAnalyzer(
                    inputAudioFile: audioFile,
                    modules: [transcriber],
                    finishAfterFile: true
                )
                _ = analyzer  // retained for the duration of the results loop

                var collected: [TranscriptionSegmentData] = []
                for try await result in transcriber.results {
                    if Task.isCancelled { break }
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let start = Float(result.range.start.seconds)
                    let end = Float(result.range.end.seconds)
                    let seg = TranscriptionSegmentData(start: start, end: end, text: text, speaker: nil, words: [], avgLogprob: 0)
                    collected.append(seg)
                    segments.append(seg)
                    liveTranscriptionText = segments.map { $0.text }.joined(separator: "\n\n")
                    if totalDuration > 0 {
                        transcriptionState = .transcribing(progress: min(Double(end) / totalDuration, 0.99))
                    }
                }

                if Task.isCancelled {
                    transcriptionState = .idle
                    cleanup()
                    return
                }

                // Optional speaker diarization (engine-agnostic: assign speakers to
                // the transcript segments by time-overlap with SpeakerKit's output).
                var finalSegments = collected
                if AppSettings.shared.enableSpeakerDiarization && !collected.isEmpty {
                    transcriptionState = .transcribing(progress: 0.97)
                    finalSegments = await assignSpeakersByOverlap(to: collected, audioPath: audioPath)
                }

                // Channel-aware "you vs them" overlay (meeting recordings only).
                finalSegments = await applyChannelAttribution(finalSegments)

                let fullText = buildTranscriptText(finalSegments, format: outputFormat)
                try fullText.write(toFile: outputPath, atomically: true, encoding: .utf8)

                segments = finalSegments
                liveTranscriptionText = finalSegments.map { $0.text }.joined(separator: "\n\n")
                lastSavedPath = outputPath
                transcriptionState = .completed(outputPath: outputPath)
                saveToHistory(title: currentTranscriptionTitle, filePath: outputPath)
                notifyTranscriptionComplete()
                finishMeetingExtras(path: outputPath)
                advanceBatchIfNeeded()
                cleanup()
            } catch {
                if Task.isCancelled {
                    transcriptionState = .idle
                } else {
                    transcriptionState = .error("Transcription failed: \(error.localizedDescription)")
                }
                discardPendingChannelSources()
                advanceBatchIfNeeded()
                cleanup()
            }
        }
    }
}
