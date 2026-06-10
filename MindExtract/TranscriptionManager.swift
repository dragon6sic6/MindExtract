import Foundation
import SwiftUI
import WhisperKit
import SpeakerKit
import Speech
import AVFoundation

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

    private var whisperKit: WhisperKit?
    private var currentLoadedModel: WhisperModel?
    private var currentTask: Task<Void, Never>?
    private var currentProcess: Process? // for ffmpeg
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
        let modelDir = modelsDirectory
            .appendingPathComponent("models")
            .appendingPathComponent("argmaxinc")
            .appendingPathComponent("whisperkit-coreml")
            .appendingPathComponent(model.whisperKitModelId)

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

                // Use the static download method with downloadBase pointing to our models dir
                let _ = try await WhisperKit.download(
                    variant: model.whisperKitModelId,
                    downloadBase: modelsDirectory
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
                        // Always set newly downloaded model as default — user chose to download it
                        AppSettings.shared.defaultWhisperModel = model
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
        print("[MindExtract] Loading \(model.displayName) model from \(modelFolder.path)...")

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
        print("[MindExtract] \(model.displayName) model loaded in \(String(format: "%.1f", elapsed))s")

        return kit
    }

    /// Prewarm a model in the background after download, triggering CoreML compilation
    /// so the first transcription is fast.
    private func prewarmModel(_ model: WhisperModel) {
        guard let modelFolder = findModelFolder(model) else { return }

        Task.detached(priority: .utility) {
            await MainActor.run { self.prewarmingModel = model }

            let start = CFAbsoluteTimeGetCurrent()
            print("[MindExtract] Prewarming \(model.displayName) model (CoreML compilation)...")

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
                print("[MindExtract] \(model.displayName) prewarm complete in \(String(format: "%.1f", elapsed))s")
            } catch {
                await MainActor.run { self.prewarmingModel = nil }
                print("[MindExtract] Prewarm failed: \(error.localizedDescription)")
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
                        print("[MindExtract] Starting speaker diarization...")
                        let audioArray = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath)
                        print("[MindExtract] Audio loaded: \(audioArray.count) samples")
                        let config = PyannoteConfig(verbose: true)
                        let speakerKit = try await SpeakerKit(config)
                        print("[MindExtract] SpeakerKit initialized, running diarization...")

                        // Use tuned diarization options for better speaker separation
                        let diarizationOptions = PyannoteDiarizationOptions(
                            clusterDistanceThreshold: 0.7,  // Higher = merge more aggressively (default 0.6), reduces phantom speakers
                            useExclusiveReconciliation: true
                        )
                        let diarizationResult = try await speakerKit.diarize(audioArray: audioArray, options: diarizationOptions)
                        print("[MindExtract] Diarization complete: \(diarizationResult.speakerCount) speakers found")
                        print("[MindExtract] Diarization timings: \(diarizationResult.timings)")

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
                        print("[MindExtract] Speaker diarization failed: \(error)")
                    }
                    print("[MindExtract] Post-diarization segments count: \(allSegments.count)")
                }

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

                print("[MindExtract] Completing transcription: \(allSegments.count) segments, title: '\(self.currentTranscriptionTitle)', output: \(outputPath)")
                await MainActor.run {
                    self.segments = allSegments
                    self.liveTranscriptionText = allSegments.map { $0.text }.joined(separator: "\n\n")
                    self.lastSavedPath = outputPath
                    self.transcriptionState = .completed(outputPath: outputPath)
                    self.saveToHistory(title: self.currentTranscriptionTitle, filePath: outputPath)
                    print("[MindExtract] Final state: segments=\(self.segments.count), title='\(self.currentTranscriptionTitle)', liveText length=\(self.liveTranscriptionText.count)")
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

        print("[MindExtract] Merged \(segments.count) segments into \(merged.count) speaker turns")
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
        DispatchQueue.main.async {
            self.transcriptionState = .idle
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
                print("Failed to save transcription: \(error)")
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
                print("Failed to export transcription: \(error)")
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

    func startNewTranscription(title: String, model: WhisperModel? = nil) {
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
        let historyItem = TranscriptionHistoryItem(
            title: resolvedTitle,
            filePath: filePath,
            duration: duration,
            modelUsed: currentModelUsed?.displayName ?? "Unknown"
        )
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
            print("[MindExtract] Apple-path diarization failed: \(error)")
            return segments
        }
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
    func runTranscription(audioPath: String, model: WhisperModel, outputPath: String, outputFormat: TranscriptionOutputFormat, language: String, cleanup: @escaping () -> Void = {}) {
        if useAppleSpeech(), #available(macOS 26.0, *) {
            runSpeechAnalyzer(audioPath: audioPath, outputPath: outputPath, outputFormat: outputFormat, language: language, cleanup: cleanup)
        } else {
            runWhisperKit(audioPath: audioPath, model: model, outputPath: outputPath, outputFormat: outputFormat, language: language, cleanup: cleanup)
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

                let fullText = buildTranscriptText(finalSegments, format: outputFormat)
                try fullText.write(toFile: outputPath, atomically: true, encoding: .utf8)

                segments = finalSegments
                liveTranscriptionText = finalSegments.map { $0.text }.joined(separator: "\n\n")
                lastSavedPath = outputPath
                transcriptionState = .completed(outputPath: outputPath)
                saveToHistory(title: currentTranscriptionTitle, filePath: outputPath)
                cleanup()
            } catch {
                if Task.isCancelled {
                    transcriptionState = .idle
                } else {
                    transcriptionState = .error("Transcription failed: \(error.localizedDescription)")
                }
                cleanup()
            }
        }
    }
}
