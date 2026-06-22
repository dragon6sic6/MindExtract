import Foundation
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
        return (trimmed?.isEmpty == false) ? trimmed! : original
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
    /// Separate mic/system tracks from a meeting recording, for channel-aware
    /// "you vs them" speaker attribution. Consumed (and the files deleted) once.
    var pendingChannelSources: (mic: String, system: String)?
    /// Speaker-name suggestions for the next transcript ("You" + calendar
    /// attendees), shown in the rename popover. Set when a meeting is confirmed.
    var pendingSpeakerSuggestions: [String] = []
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

    private var whisperKit: WhisperKit?
    private var currentLoadedModel: WhisperModel?
    private var currentTask: Task<Void, Never>?
    private var currentProcess: Process? // for ffmpeg
    private var activeOutputPath: String?   // where the in-flight transcript will save
    private var downloadTask: URLSessionDataTask?

    private let fileManager = FileManager.default
    private let transcriptionHistory = TranscriptionHistoryManager.shared
    private var currentModelUsed: WhisperModel?

    private init() {
        loadDownloadedModels()
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

    private var ffmpegBinaryPath: String? {
        if let bundledPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) {
            return bundledPath
        }
        let paths = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        for path in paths {
            if fileManager.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    var isFfmpegAvailable: Bool {
        ffmpegBinaryPath != nil
    }

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
            if findModelFolder(model) != nil {
                models.insert(model)
            }
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
        // Hub stores at downloadBase/models/<repo-owner>/<repo-name>/<variant>/ —
        // build from the model's repo so custom repos (KB-Whisper) resolve too.
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

        DispatchQueue.main.async {
            self.downloadingModel = model
            self.modelDownloadProgress = 0
        }

        currentTask = Task {
            do {
                try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

                // Use the static download method with downloadBase pointing to our
                // models dir; `from:` lets KB-Whisper come from its own repo.
                let _ = try await WhisperKit.download(
                    variant: model.variant,
                    downloadBase: modelsDirectory,
                    from: model.repo
                ) { progress in
                    Task { @MainActor in
                        self.modelDownloadProgress = progress.fractionCompleted
                    }
                }

                await MainActor.run {
                    // Refresh from file system to confirm download actually succeeded
                    self.loadDownloadedModels(synchronous: true)
                    self.downloadingModel = nil
                    self.modelDownloadProgress = 1.0

                    if self.isModelDownloaded(model) {
                        // Make it the default — but NOT a Swedish-only model, which
                        // would then wrongly be used for English/other-language audio.
                        if !model.isSwedishOnly {
                            AppSettings.shared.defaultWhisperModel = model
                        }
                    } else {
                        // Download completed but model not valid on disk
                        self.transcriptionState = .error("Model download completed but files are invalid. Please try again.")
                    }
                }

                // Prewarm in background — triggers CoreML compilation so first transcription is fast
                self.prewarmModel(model)
            } catch {
                await MainActor.run {
                    self.downloadingModel = nil
                    self.modelDownloadProgress = 0
                    self.transcriptionState = .error("Model download failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func cancelModelDownload() {
        currentTask?.cancel()
        currentTask = nil
        DispatchQueue.main.async {
            self.downloadingModel = nil
            self.modelDownloadProgress = 0
        }
    }

    func deleteModel(_ model: WhisperModel) {
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

    private func ensureWhisperKit(model: WhisperModel) async throws -> WhisperKit {
        if let kit = whisperKit, currentLoadedModel == model {
            return kit
        }

        guard let modelFolder = findModelFolder(model) else {
            throw NSError(domain: "TranscriptionManager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Model not downloaded"])
        }

        await MainActor.run {
            self.transcriptionState = .loadingModel(modelName: model.displayName)
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

    func transcribe(videoPath: String, model: WhisperModel, outputFormat: TranscriptionOutputFormat, language: String = "auto") {
        // Sync with file system before checking model availability
        loadDownloadedModels(synchronous: true)

        let usingApple = useAppleSpeech()

        guard let ffmpegPath = ffmpegBinaryPath else {
            DispatchQueue.main.async {
                self.transcriptionState = .error("FFmpeg binary not found")
            }
            return
        }

        // Apple Speech needs no downloaded model; only require one for WhisperKit.
        if !usingApple {
            guard isModelDownloaded(model) else {
                DispatchQueue.main.async {
                    self.transcriptionState = .modelNotDownloaded
                }
                return
            }
        }

        let videoURL = URL(fileURLWithPath: videoPath)
        let videoDirectory = videoURL.deletingLastPathComponent().path
        let videoBaseName = videoURL.deletingPathExtension().lastPathComponent
        let tempAudioPath = NSTemporaryDirectory() + UUID().uuidString + ".wav"
        let outputPath = videoDirectory + "/" + videoBaseName + "." + outputFormat.rawValue

        DispatchQueue.main.async {
            self.transcriptionState = .extractingAudio
        }

        // Extract audio using ffmpeg first
        extractAudio(ffmpegPath: ffmpegPath, videoPath: videoPath, outputPath: tempAudioPath) { [weak self] success, error in
            guard let self = self else { return }

            if !success {
                DispatchQueue.main.async {
                    self.transcriptionState = .error(error ?? "Failed to extract audio")
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

        guard let ffmpegPath = ffmpegBinaryPath else {
            DispatchQueue.main.async {
                self.transcriptionState = .error("FFmpeg binary not found")
            }
            try? fileManager.removeItem(atPath: audioPath)
            return
        }

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
            self.showTranscriptionView = true
        }

        currentTask = Task {
            do {
                let kit = try await ensureWhisperKit(model: model)

                await MainActor.run {
                    self.transcriptionState = .transcribing(progress: 0)
                }

                // Configure transcription options
                var options = DecodingOptions()
                if language != "auto" {
                    options.language = language
                }
                options.wordTimestamps = true
                // Whisper's built-in translate task: transcribe foreign speech
                // straight into English, on-device. UserDefaults read is
                // thread-safe (we're off the main actor here). It's a one-shot
                // per-transcription choice — reset it so it can't silently keep
                // translating later files the user expected in their own language.
                if UserDefaults.standard.bool(forKey: "translateToEnglish") {
                    options.task = .translate
                    UserDefaults.standard.set(false, forKey: "translateToEnglish")
                }
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
                let results = try await kit.transcribe(
                    audioPath: audioPath,
                    decodeOptions: options,
                    callback: callback
                )

                // Clear the callback to avoid retain cycles
                kit.segmentDiscoveryCallback = nil

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
                    fullText = allSegments.map { seg in
                        let ts = self.formatTimestampBracket(seg.start)
                        if let speaker = seg.speaker {
                            return "\(ts) \(speaker): \(seg.text)"
                        }
                        return "\(ts) \(seg.text)"
                    }.joined(separator: "\n\n")
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
                await MainActor.run { self.discardPendingChannelSources() }
                cleanup()
            }
        }
    }

    // MARK: - Speaker Segment Merging

    /// Merges consecutive segments that have the same speaker into larger paragraph-like segments.
    /// This produces output similar to MacWhisper where text is grouped by speaker turn.
    private func mergeSameSpeakerSegments(_ segments: [TranscriptionSegmentData]) -> [TranscriptionSegmentData] {
        guard !segments.isEmpty else { return segments }

        var merged: [TranscriptionSegmentData] = []
        var current = segments[0]

        for i in 1..<segments.count {
            let next = segments[i]

            // Same speaker (or both nil) — merge
            if current.speaker == next.speaker {
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

    private func extractAudio(ffmpegPath: String, videoPath: String, outputPath: String, completion: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                completion(false, "Manager deallocated")
                return
            }

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

            self.currentProcess = process

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    completion(true, nil)
                } else {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown ffmpeg error"
                    completion(false, "FFmpeg error: \(errorMessage)")
                }
            } catch {
                completion(false, "Failed to run ffmpeg: \(error.localizedDescription)")
            }
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

    func startNewTranscription(title: String, model: WhisperModel? = nil, source: TranscriptSource = .file) {
        currentTranscriptSource = source
        DispatchQueue.main.async {
            self.currentTranscriptionTitle = title
            self.liveTranscriptionText = ""
            self.lastSavedPath = nil
            self.currentModelUsed = model
            // Force re-trigger .onChange even if already true
            if self.showTranscriptionView {
                self.showTranscriptionView = false
            }
            DispatchQueue.main.async {
                self.showTranscriptionView = true
            }
        }
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
            modelUsed: currentModelUsed?.displayName ?? "Unknown"
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
            // The temp audio for a past transcription is gone — clear any stale
            // path so the player bar hides instead of trying to play the wrong file.
            self.audioFilePath = nil
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

    /// Routes an already-extracted audio file to the selected engine.
    /// Never use a Swedish-only model (KB-Whisper) for non-Swedish audio, and
    /// never use a multilingual model for Swedish when KB is available isn't forced
    /// here — we only *prevent the harmful mismatch*, not override user choice.
    func effectiveWhisperModel(_ model: WhisperModel, language: String) -> WhisperModel {
        if model.isSwedishOnly && language != "sv" {
            return downloadedModels.first { !$0.isSwedishOnly } ?? .small
        }
        return model
    }

    func runTranscription(audioPath: String, model: WhisperModel, outputPath: String, outputFormat: TranscriptionOutputFormat, language: String, cleanup: @escaping () -> Void = {}) {
        activeOutputPath = outputPath
        if useAppleSpeech(), #available(macOS 26.0, *) {
            // Apple Speech can't do every language. If it can't do this one, route
            // to WhisperKit (which can) so e.g. Swedish isn't transcribed as English.
            currentTask = Task { @MainActor in
                if await Self.appleSpeechSupports(language) {
                    self.runSpeechAnalyzer(audioPath: audioPath, outputPath: outputPath, outputFormat: outputFormat, language: language, cleanup: cleanup)
                } else if self.isModelDownloaded(model) || !self.downloadedModels.isEmpty {
                    let picked = self.isModelDownloaded(model) ? model : (self.downloadedModels.first ?? model)
                    let useModel = self.effectiveWhisperModel(picked, language: language)
                    self.runWhisperKit(audioPath: audioPath, model: useModel, outputPath: outputPath, outputFormat: outputFormat, language: language, cleanup: cleanup)
                } else {
                    let name = AppSettings.transcriptionLanguages.first { $0.code == language }?.name ?? language
                    self.transcriptionState = .error("Apple Speech doesn’t support \(name) yet. Download a WhisperKit model in Settings to transcribe \(name) on your Mac, then try again.")
                    cleanup()
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
        showTranscriptionView = true

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
                cleanup()
            } catch {
                if Task.isCancelled {
                    transcriptionState = .idle
                } else {
                    transcriptionState = .error("Transcription failed: \(error.localizedDescription)")
                }
                discardPendingChannelSources()
                cleanup()
            }
        }
    }
}
