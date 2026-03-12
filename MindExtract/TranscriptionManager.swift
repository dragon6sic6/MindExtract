import Foundation
import SwiftUI

// MARK: - Transcription Manager

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

    private var currentProcess: Process?
    private var downloadTask: URLSessionDownloadTask?

    private let fileManager = FileManager.default
    private let transcriptionHistory = TranscriptionHistoryManager.shared
    private var currentModelUsed: WhisperModel?

    private init() {
        loadDownloadedModels()
    }

    // MARK: - Paths

    private var applicationSupportPath: URL {
        let paths = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths[0].appendingPathComponent("com.mindact.mindextract")
        return appSupport
    }

    private var modelsDirectory: URL {
        applicationSupportPath.appendingPathComponent("WhisperModels")
    }

    func modelPath(for model: WhisperModel) -> URL {
        modelsDirectory.appendingPathComponent(model.fileName)
    }

    private var whisperBinaryPath: String? {
        // Check bundled binary first
        if let bundledPath = Bundle.main.path(forResource: "whisper", ofType: nil) {
            return bundledPath
        }
        // Fallback to common locations
        let paths = [
            "/opt/homebrew/bin/whisper",
            "/usr/local/bin/whisper",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cpp"
        ]
        for path in paths {
            if fileManager.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    private var ffmpegBinaryPath: String? {
        // Check bundled binary first
        if let bundledPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) {
            return bundledPath
        }
        // Fallback to common locations
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

    var isWhisperAvailable: Bool {
        whisperBinaryPath != nil
    }

    var isFfmpegAvailable: Bool {
        ffmpegBinaryPath != nil
    }

    var areBinariesAvailable: Bool {
        isWhisperAvailable && isFfmpegAvailable
    }

    // MARK: - Model Management

    func isModelDownloaded(_ model: WhisperModel) -> Bool {
        downloadedModels.contains(model)
    }

    func loadDownloadedModels() {
        var models: Set<WhisperModel> = []
        for model in WhisperModel.allCases {
            let path = modelPath(for: model)
            if fileManager.fileExists(atPath: path.path) {
                models.insert(model)
            }
        }
        DispatchQueue.main.async {
            self.downloadedModels = models
        }
    }

    func modelFileSize(_ model: WhisperModel) -> Int64? {
        let path = modelPath(for: model)
        guard let attributes = try? fileManager.attributesOfItem(atPath: path.path),
              let size = attributes[.size] as? Int64 else {
            return nil
        }
        return size
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

        // Create models directory if needed
        do {
            try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        } catch {
            DispatchQueue.main.async {
                self.transcriptionState = .error("Failed to create models directory: \(error.localizedDescription)")
            }
            return
        }

        DispatchQueue.main.async {
            self.downloadingModel = model
            self.modelDownloadProgress = 0
        }

        let destinationPath = modelPath(for: model)

        let configuration = URLSessionConfiguration.default
        let session = URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)

        var request = URLRequest(url: model.downloadURL)
        request.timeoutInterval = 600 // 10 minutes for large models

        downloadTask = session.downloadTask(with: request) { [weak self] tempURL, response, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.downloadingModel = nil
                    self.modelDownloadProgress = 0
                    self.transcriptionState = .error("Download failed: \(error.localizedDescription)")
                }
                return
            }

            guard let tempURL = tempURL else {
                DispatchQueue.main.async {
                    self.downloadingModel = nil
                    self.modelDownloadProgress = 0
                    self.transcriptionState = .error("Download failed: No file received")
                }
                return
            }

            do {
                // Remove existing file if present
                if self.fileManager.fileExists(atPath: destinationPath.path) {
                    try self.fileManager.removeItem(at: destinationPath)
                }
                try self.fileManager.moveItem(at: tempURL, to: destinationPath)

                DispatchQueue.main.async {
                    self.downloadedModels.insert(model)
                    self.downloadingModel = nil
                    self.modelDownloadProgress = 1.0
                }
            } catch {
                DispatchQueue.main.async {
                    self.downloadingModel = nil
                    self.modelDownloadProgress = 0
                    self.transcriptionState = .error("Failed to save model: \(error.localizedDescription)")
                }
            }
        }

        // Observe download progress
        let observation = downloadTask?.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.modelDownloadProgress = progress.fractionCompleted
            }
        }

        // Store observation to prevent it from being deallocated
        objc_setAssociatedObject(downloadTask as Any, "progressObservation", observation, .OBJC_ASSOCIATION_RETAIN)

        downloadTask?.resume()
    }

    func cancelModelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        DispatchQueue.main.async {
            self.downloadingModel = nil
            self.modelDownloadProgress = 0
        }
    }

    func deleteModel(_ model: WhisperModel) {
        let path = modelPath(for: model)
        do {
            if fileManager.fileExists(atPath: path.path) {
                try fileManager.removeItem(at: path)
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

    // MARK: - Transcription

    func transcribe(videoPath: String, model: WhisperModel, outputFormat: TranscriptionOutputFormat, language: String = "auto") {
        guard let whisperPath = whisperBinaryPath else {
            DispatchQueue.main.async {
                self.transcriptionState = .error("Whisper binary not found")
            }
            return
        }

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

        let modelFile = modelPath(for: model).path
        let videoURL = URL(fileURLWithPath: videoPath)
        let videoDirectory = videoURL.deletingLastPathComponent().path
        let videoBaseName = videoURL.deletingPathExtension().lastPathComponent
        let tempAudioPath = NSTemporaryDirectory() + UUID().uuidString + ".wav"
        let outputPath = videoDirectory + "/" + videoBaseName + "." + outputFormat.rawValue

        DispatchQueue.main.async {
            self.transcriptionState = .extractingAudio
        }

        // Extract audio using ffmpeg
        extractAudio(ffmpegPath: ffmpegPath, videoPath: videoPath, outputPath: tempAudioPath) { [weak self] success, error in
            guard let self = self else { return }

            if !success {
                DispatchQueue.main.async {
                    self.transcriptionState = .error(error ?? "Failed to extract audio")
                }
                // Clean up temp file
                try? self.fileManager.removeItem(atPath: tempAudioPath)
                return
            }

            // Run whisper transcription
            self.runWhisper(whisperPath: whisperPath, modelPath: modelFile, audioPath: tempAudioPath, outputPath: outputPath, outputFormat: outputFormat, language: language) { success, error in

                // Clean up temp audio file
                try? self.fileManager.removeItem(atPath: tempAudioPath)

                if success {
                    DispatchQueue.main.async {
                        self.transcriptionState = .completed(outputPath: outputPath)
                    }
                } else {
                    DispatchQueue.main.async {
                        self.transcriptionState = .error(error ?? "Transcription failed")
                    }
                }
            }
        }
    }

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
                "-ar", "16000",        // 16kHz sample rate (whisper requirement)
                "-ac", "1",            // Mono audio
                "-c:a", "pcm_s16le",   // 16-bit PCM
                "-y",                  // Overwrite output
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

    private func runWhisper(whisperPath: String, modelPath: String, audioPath: String, outputPath: String, outputFormat: TranscriptionOutputFormat, language: String = "auto", completion: @escaping (Bool, String?) -> Void) {
        DispatchQueue.main.async {
            self.transcriptionState = .transcribing(progress: 0)
            self.liveTranscriptionText = ""
            self.showTranscriptionView = true
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                completion(false, "Manager deallocated")
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: whisperPath)

            // Get output path without extension for -of flag
            let outputURL = URL(fileURLWithPath: outputPath)
            let outputBase = outputURL.deletingPathExtension().path

            // Build arguments - output to both file and stdout for real-time display
            // whisper-cli uses: -m model -f audio -of output_base -otxt/-osrt
            var args = [
                "-m", modelPath,
                "-f", audioPath,
                "-of", outputBase,
                "--print-progress"  // Show progress
            ]

            // Add language
            args.append(contentsOf: ["-l", language])

            // Add output format flag
            if outputFormat == .srt {
                args.append("-osrt")
            } else {
                args.append("-otxt")
            }

            process.arguments = args

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            self.currentProcess = process

            // Capture stdout for real-time transcription display
            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if !data.isEmpty, let output = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self?.liveTranscriptionText += output
                    }
                }
            }

            // Track progress by monitoring stderr
            errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if !data.isEmpty, let output = String(data: data, encoding: .utf8) {
                    // whisper.cpp outputs progress to stderr like "progress = 42%"
                    if let match = output.range(of: #"progress\s*=\s*(\d+)"#, options: .regularExpression) {
                        let progressStr = output[match]
                        if let percentMatch = progressStr.range(of: #"\d+"#, options: .regularExpression) {
                            let percent = Double(progressStr[percentMatch]) ?? 0
                            DispatchQueue.main.async {
                                self?.transcriptionState = .transcribing(progress: percent / 100.0)
                            }
                        }
                    }
                }
            }

            do {
                try process.run()
                process.waitUntilExit()

                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                if process.terminationStatus == 0 {
                    // Read the final output file for clean text
                    var finalPath = outputPath
                    if !self.fileManager.fileExists(atPath: outputPath) {
                        let altPath = outputBase + "." + outputFormat.rawValue
                        if self.fileManager.fileExists(atPath: altPath) {
                            finalPath = altPath
                        }
                    }

                    // Read clean text from file if stdout was messy
                    if self.fileManager.fileExists(atPath: finalPath),
                       let cleanText = try? String(contentsOfFile: finalPath, encoding: .utf8) {
                        DispatchQueue.main.async {
                            self.liveTranscriptionText = cleanText
                            self.lastSavedPath = finalPath
                            // Save to history
                            self.saveToHistory(title: self.currentTranscriptionTitle, filePath: finalPath)
                        }
                    }

                    completion(true, nil)
                } else {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    completion(false, "Whisper error (code \(process.terminationStatus)): \(errorMessage.prefix(200))")
                }
            } catch {
                completion(false, "Failed to run whisper: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Transcribe Audio File Directly (for URL transcription)

    func transcribeAudioFile(audioPath: String, model: WhisperModel, outputPath: String, outputFormat: TranscriptionOutputFormat, language: String = "auto") {
        guard let whisperPath = whisperBinaryPath else {
            DispatchQueue.main.async {
                self.transcriptionState = .error("Whisper binary not found")
            }
            // Clean up temp audio
            try? fileManager.removeItem(atPath: audioPath)
            return
        }

        guard isModelDownloaded(model) else {
            DispatchQueue.main.async {
                self.transcriptionState = .modelNotDownloaded
            }
            // Clean up temp audio
            try? fileManager.removeItem(atPath: audioPath)
            return
        }

        let modelFile = modelPath(for: model).path

        // The audio might not be in the right format for whisper, so convert it first
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

            // Run whisper transcription
            self.runWhisper(whisperPath: whisperPath, modelPath: modelFile, audioPath: tempWavPath, outputPath: outputPath, outputFormat: outputFormat, language: language) { success, error in

                // Clean up temp wav file
                try? self.fileManager.removeItem(atPath: tempWavPath)

                if success {
                    DispatchQueue.main.async {
                        self.transcriptionState = .completed(outputPath: outputPath)
                    }
                } else {
                    DispatchQueue.main.async {
                        self.transcriptionState = .error(error ?? "Transcription failed")
                    }
                }
            }
        }
    }

    func cancelTranscription() {
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

    func clearTranscription() {
        DispatchQueue.main.async {
            self.liveTranscriptionText = ""
            self.currentTranscriptionTitle = ""
            self.showTranscriptionView = false
            self.lastSavedPath = nil
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
