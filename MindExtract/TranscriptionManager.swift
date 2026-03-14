import Foundation
import SwiftUI
import WhisperKit

// MARK: - Transcription Manager (WhisperKit)

class TranscriptionManager: ObservableObject {
    static let shared = TranscriptionManager()

    @Published var transcriptionState: TranscriptionState = .idle
    @Published var downloadingModel: WhisperModel?
    @Published var modelDownloadProgress: Double = 0
    @Published var downloadedModels: Set<WhisperModel> = []

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

    func loadDownloadedModels() {
        var models: Set<WhisperModel> = []
        for model in WhisperModel.allCases {
            if findModelFolder(model) != nil {
                models.insert(model)
            }
        }
        DispatchQueue.main.async {
            self.downloadedModels = models
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
                    self.downloadedModels.insert(model)
                    self.downloadingModel = nil
                    self.modelDownloadProgress = 1.0
                }
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
            self.transcriptionState = .loadingModel
        }

        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            verbose: false,
            load: true,
            download: false
        )

        let kit = try await WhisperKit(config)
        self.whisperKit = kit
        self.currentLoadedModel = model
        return kit
    }

    // MARK: - Transcription

    func transcribe(videoPath: String, model: WhisperModel, outputFormat: TranscriptionOutputFormat, language: String = "auto") {
        guard let ffmpegPath = ffmpegBinaryPath else {
            DispatchQueue.main.async {
                self.transcriptionState = .error("FFmpeg binary not found")
            }
            return
        }

        guard isModelDownloaded(model) else {
            DispatchQueue.main.async {
                self.transcriptionState = .modelNotDownloaded
            }
            return
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

            // Run WhisperKit transcription
            self.runWhisperKit(audioPath: tempAudioPath, model: model, outputPath: outputPath, outputFormat: outputFormat, language: language) {
                // Clean up temp audio
                try? self.fileManager.removeItem(atPath: tempAudioPath)
            }
        }
    }

    // MARK: - Transcribe Audio File Directly (for URL transcription)

    func transcribeAudioFile(audioPath: String, model: WhisperModel, outputPath: String, outputFormat: TranscriptionOutputFormat, language: String = "auto") {
        guard isModelDownloaded(model) else {
            DispatchQueue.main.async {
                self.transcriptionState = .modelNotDownloaded
            }
            try? fileManager.removeItem(atPath: audioPath)
            return
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

            self.runWhisperKit(audioPath: tempWavPath, model: model, outputPath: outputPath, outputFormat: .txt, language: language) {
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

        DispatchQueue.main.async {
            self.transcriptionState = .transcribing(progress: 0)
            self.liveTranscriptionText = ""
            self.segments = []
            self.audioDuration = 0
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
                    let newSegmentData = discoveredSegments.map { seg in
                        TranscriptionSegmentData(
                            start: seg.start,
                            end: seg.end,
                            text: seg.text.trimmingCharacters(in: .whitespacesAndNewlines),
                            speaker: nil,
                            words: (seg.words ?? []).map { w in
                                WordTimingData(word: w.word, start: w.start, end: w.end, probability: w.probability)
                            },
                            avgLogprob: seg.avgLogprob
                        )
                    }
                    Task { @MainActor in
                        self.segments.append(contentsOf: newSegmentData)
                        self.liveTranscriptionText = self.segments.map { $0.text }.joined(separator: " ")
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
                        allSegments.append(TranscriptionSegmentData(
                            start: seg.start,
                            end: seg.end,
                            text: seg.text.trimmingCharacters(in: .whitespacesAndNewlines),
                            speaker: nil,
                            words: (seg.words ?? []).map { w in
                                WordTimingData(word: w.word, start: w.start, end: w.end, probability: w.probability)
                            },
                            avgLogprob: seg.avgLogprob
                        ))
                    }
                    if let lastSeg = result.segments.last {
                        self.audioDuration = max(self.audioDuration, lastSeg.end)
                    }
                }

                // Build output text based on format
                let fullText: String
                switch outputFormat {
                case .srt:
                    fullText = buildSRT(from: results)
                case .vtt:
                    fullText = buildVTT(from: allSegments)
                case .json:
                    fullText = buildJSON(from: allSegments)
                case .txt:
                    fullText = allSegments.map { $0.text }.joined(separator: " ")
                }

                // Save to file
                try fullText.write(toFile: outputPath, atomically: true, encoding: .utf8)

                await MainActor.run {
                    self.segments = allSegments
                    self.liveTranscriptionText = allSegments.map { $0.text }.joined(separator: " ")
                    self.lastSavedPath = outputPath
                    self.transcriptionState = .completed(outputPath: outputPath)
                    self.saveToHistory(title: self.currentTranscriptionTitle, filePath: outputPath)
                }

                cleanup()

            } catch {
                if Task.isCancelled {
                    await MainActor.run {
                        self.transcriptionState = .idle
                    }
                } else {
                    await MainActor.run {
                        self.transcriptionState = .error("Transcription failed: \(error.localizedDescription)")
                    }
                }
                cleanup()
            }
        }
    }

    // MARK: - SRT Builder

    private func buildSRT(from results: [TranscriptionResult]) -> String {
        var srt = ""
        var index = 1

        for result in results {
            for segment in result.segments {
                let startTime = formatSRTTime(segment.start)
                let endTime = formatSRTTime(segment.end)
                srt += "\(index)\n"
                srt += "\(startTime) --> \(endTime)\n"
                srt += "\(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
                index += 1
            }
        }

        return srt
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
                content = liveTranscriptionText
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
            srt += "\(seg.text)\n\n"
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
            self.showTranscriptionView = true
            self.currentModelUsed = model
        }
    }

    private func saveToHistory(title: String, filePath: String) {
        let historyItem = TranscriptionHistoryItem(
            title: title,
            filePath: filePath,
            duration: nil,
            modelUsed: currentModelUsed?.displayName ?? "Unknown"
        )
        transcriptionHistory.addToHistory(historyItem)
    }

    func openTranscriptionFromHistory(_ item: TranscriptionHistoryItem) {
        guard let text = item.transcriptionText else {
            transcriptionState = .error("Transcription file not found")
            return
        }

        DispatchQueue.main.async {
            self.currentTranscriptionTitle = item.title
            self.liveTranscriptionText = text
            self.lastSavedPath = item.filePath
            self.showTranscriptionView = true
            self.transcriptionState = .completed(outputPath: item.filePath)
        }
    }
}
