import Foundation
import AVFoundation
import Speech

// MARK: - Transcription
//
// One job at a time: media in, a text file out.
//
//   1. The audio is read into a 16 kHz mono WAV (AVFoundation, ffmpeg as fallback).
//   2. Speech becomes text on this Mac:
//        NVIDIA Parakeet for "Automatic" and its 25 European languages,
//        Apple's speech recognition for the other languages Apple supports.
//   3. Optionally, voices are told apart (FluidAudio's diarizer).
//   4. The transcript is written as "[mm:ss] Speaker 1: text" passages.
//
// Every job gets an id. Cancel bumps it, so work that finishes afterwards
// (a slow conversion, a model that doesn't stop mid-file) is dropped instead
// of reporting a result for the next job.

/// A passage of the finished transcript.
struct TranscriptPassage: Sendable, Equatable {
    var start: Double
    var end: Double
    var text: String
    var speaker: Int?
}

@MainActor
final class TranscriptionManager: ObservableObject {
    static let shared = TranscriptionManager()

    @Published var transcriptionState: TranscriptionState = .idle

    // MARK: Speech model state

    @Published private(set) var isModelInstalled = ParakeetEngine.isInstalled
    @Published private(set) var isDownloadingModel = false
    @Published private(set) var modelDownloadProgress: Double = 0
    @Published private(set) var modelDownloadError: String?
    private var modelDownloadTask: Task<Void, Never>?
    /// Bumped per download and by cancel, so a cancelled download that unwinds
    /// late can't reset the state of the one that replaced it.
    private var modelDownloadID = 0

    // MARK: Job state

    private var jobID = 0
    private var currentTask: Task<Void, Never>?

    private init() {
        removeOldModels()
        ParakeetEngine.removeLeftoverStaging()
        preloadModel()
    }

    /// Loading the model takes about 15 seconds after a restart. Do it in the
    /// background shortly after launch, so the first transcription is quick.
    private func preloadModel() {
        guard isModelInstalled else { return }
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(5))
            _ = try? await ParakeetEngine.shared.load()
        }
    }

    // MARK: - Languages

    enum Engine: Equatable {
        case parakeet, apple, unsupported
    }

    /// Parakeet's languages, from NVIDIA's model card.
    static let parakeetLanguages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    /// Languages only Apple's speech recognition covers (checked on macOS 26).
    static let appleOnlyLanguages: Set<String> = [
        "ja", "ko", "zh", "yue", "hi", "bn", "gu", "kn", "ml", "mr", "ne", "pa", "ta", "te", "ur",
    ]

    static func engine(for language: String) -> Engine {
        if language == "auto" || parakeetLanguages.contains(language) { return .parakeet }
        if appleOnlyLanguages.contains(language) { return .apple }
        return .unsupported
    }

    /// Whether transcribing `language` needs the downloaded speech model.
    static func needsSpeechModel(_ language: String) -> Bool { engine(for: language) == .parakeet }

    // MARK: - Speech model

    var modelSizeOnDisk: Int64? { ParakeetEngine.installedSize() }

    /// Downloads and verifies the speech model. Safe to call while it's running.
    func downloadModel() {
        guard !isModelInstalled, !isDownloadingModel else { return }
        modelDownloadID += 1
        let download = modelDownloadID
        isDownloadingModel = true
        modelDownloadProgress = 0
        modelDownloadError = nil
        modelDownloadTask = Task { [weak self] in
            do {
                try await ParakeetEngine.install { fraction in
                    Task { @MainActor in
                        guard let self, self.modelDownloadID == download else { return }
                        self.modelDownloadProgress = fraction
                    }
                }
                guard let self, self.modelDownloadID == download else { return }
                self.isModelInstalled = ParakeetEngine.isInstalled
                self.isDownloadingModel = false
                appLog("[MindExtract] Speech model installed")
                // Build Core ML's cache now, so the first transcription doesn't wait for it.
                Task.detached(priority: .utility) { _ = try? await ParakeetEngine.shared.load() }
            } catch {
                guard let self, self.modelDownloadID == download else { return }
                self.isDownloadingModel = false
                if !(error is CancellationError) && !Task.isCancelled {
                    self.modelDownloadError = Self.friendly(error)
                    appLog("[MindExtract] Speech model download failed: \(error)")
                }
            }
        }
    }

    /// Starts the one-time download on first launch, so the first transcription
    /// doesn't wait. Settings and the notch offer it again if it's stopped.
    func downloadModelOnFirstLaunch() {
        let key = "speechModelAutoDownloadStarted"
        guard !isModelInstalled, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        downloadModel()
    }

    func cancelModelDownload() {
        modelDownloadID += 1
        modelDownloadTask?.cancel()
        modelDownloadTask = nil
        isDownloadingModel = false
        modelDownloadProgress = 0
    }

    /// Removes the speech model. A transcription that's using it is stopped first.
    func deleteModel() {
        cancelModelDownload()
        if currentTask != nil { cancel() }
        isModelInstalled = false
        Task {
            try? await ParakeetEngine.uninstall()
            self.isModelInstalled = false
        }
    }

    /// Models from MindExtract 2.x (Whisper, Pianissimo) and its playback copy
    /// of the last audio. Nothing uses them anymore; together they're often 1 GB+.
    private func removeOldModels() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mindact.mindextract")
        for name in ["PianissimoModels", "WhisperKitModels", "WhisperModels", "last_transcription.wav"] {
            let url = support.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                appLog("[MindExtract] Removed old \(name)")
            }
        }
    }

    // MARK: - Transcribe

    /// Transcribes a media file. The transcript goes to `outputPath`, or next to
    /// the file (the save folder if that one is read-only). `removeMediaAfter`
    /// deletes the input when done, for audio fetched just for this job.
    func transcribe(mediaPath: String, title: String, language: String, source: TranscriptSource,
                    outputPath: String? = nil, removeMediaAfter: Bool = false) {
        jobID += 1
        let job = jobID
        let media = URL(fileURLWithPath: mediaPath)
        let cleanupMedia = { if removeMediaAfter { try? FileManager.default.removeItem(at: media) } }

        let engine = Self.engine(for: language)
        isModelInstalled = ParakeetEngine.isInstalled   // the folder may have been removed
        if engine == .parakeet, !isModelInstalled {
            cleanupMedia()
            transcriptionState = .modelNotDownloaded
            return
        }
        if engine == .unsupported {
            cleanupMedia()
            transcriptionState = .error(String(localized: "This language isn't supported. Choose Automatic or another language."))
            return
        }

        let output = outputPath ?? Self.transcriptPath(nextTo: media, title: title)
        transcriptionState = .extractingAudio

        currentTask = Task { [weak self] in
            let wav = URL(fileURLWithPath: NSTemporaryDirectory() + UUID().uuidString + ".wav")
            defer {
                try? FileManager.default.removeItem(at: wav)
                cleanupMedia()
            }
            do {
                try await Self.extractAudio(from: media, to: wav)
                guard let self, self.isCurrent(job) else { return }

                var passages: [TranscriptPassage]
                var duration: Double
                switch engine {
                case .parakeet:
                    if !(await ParakeetEngine.shared.isLoaded), self.isCurrent(job) {
                        self.transcriptionState = .loadingModel(modelName: ParakeetEngine.displayName)
                    }
                    let out = try await ParakeetEngine.shared.transcribe(audioURL: wav) { p in
                        Task { @MainActor in self.report(job, progress: p * 0.9) }
                    }
                    passages = TranscriptSegmenter.segments(from: out.words).map {
                        TranscriptPassage(start: $0.start, end: $0.end, text: $0.text)
                    }
                    if passages.isEmpty, !out.text.isEmpty {
                        passages = [TranscriptPassage(start: 0, end: out.duration, text: out.text)]
                    }
                    duration = out.duration
                case .apple:
                    self.transcriptionState = .loadingModel(modelName: "Apple")
                    (passages, duration) = try await Self.appleTranscribe(wav: wav, language: language) { p in
                        Task { @MainActor in self.report(job, progress: p * 0.9) }
                    }
                case .unsupported:
                    return
                }
                try Task.checkCancellation()
                guard self.isCurrent(job) else { return }
                guard !passages.isEmpty else { throw TranscriptionError.noSpeech }

                if AppSettings.shared.enableSpeakerDiarization, passages.count > 1 {
                    self.transcriptionState = .transcribing(progress: 0.95)
                    do {
                        let turns = try await SpeakerSeparator.turns(audioURL: wav)
                        for i in passages.indices {
                            passages[i].speaker = SpeakerSeparator.speaker(from: turns, start: passages[i].start, end: passages[i].end)
                        }
                        passages = Self.mergeStraySpeakers(passages)
                    } catch {
                        appLog("[MindExtract] Telling speakers apart failed: \(error)")
                    }
                }
                try Task.checkCancellation()
                guard self.isCurrent(job) else { return }

                let text = Self.transcriptText(title: title, passages: passages)
                try text.write(toFile: output, atomically: true, encoding: .utf8)
                self.saveToHistory(title: title, path: output, duration: duration, source: source,
                                   engine: engine == .parakeet ? ParakeetEngine.displayName : "Apple")
                self.currentTask = nil
                self.transcriptionState = .completed(outputPath: output)
            } catch {
                guard let self, self.isCurrent(job), !Task.isCancelled else { return }
                self.currentTask = nil
                appLog("[MindExtract] Transcription failed: \(error)")
                self.transcriptionState = .error(Self.friendly(error))
            }
        }
    }

    /// Stops the job. Nothing half done is saved.
    func cancel() {
        jobID += 1
        currentTask?.cancel()
        currentTask = nil
        transcriptionState = .idle
    }

    private func isCurrent(_ job: Int) -> Bool { job == jobID }

    private func report(_ job: Int, progress: Double) {
        guard isCurrent(job) else { return }
        transcriptionState = .transcribing(progress: min(max(progress, 0), 0.99))
    }

    private func saveToHistory(title: String, path: String, duration: Double, source: TranscriptSource, engine: String) {
        let length = duration > 0 ? String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60) : nil
        var item = TranscriptionHistoryItem(
            title: title.isEmpty ? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent : title,
            filePath: path, duration: length, modelUsed: engine)
        item.source = source.rawValue
        TranscriptionHistoryManager.shared.addToHistory(item)
    }

    // MARK: - Output

    /// Speaker separation sometimes hears a second voice in one short passage
    /// of a single speaker. A "speaker" with only one passage under 4 seconds
    /// is taken to be whoever spoke just before (or after).
    nonisolated static func mergeStraySpeakers(_ passages: [TranscriptPassage]) -> [TranscriptPassage] {
        var byspeaker: [Int: (count: Int, seconds: Double)] = [:]
        for p in passages {
            guard let s = p.speaker else { continue }
            let entry = byspeaker[s] ?? (0, 0)
            byspeaker[s] = (entry.count + 1, entry.seconds + (p.end - p.start))
        }
        guard byspeaker.count > 1 else { return passages }
        let stray = Set(byspeaker.filter { $0.value.count == 1 && $0.value.seconds < 4 }.keys)
        guard !stray.isEmpty, stray.count < byspeaker.count else { return passages }
        var out = passages
        for i in out.indices where out[i].speaker.map(stray.contains) == true {
            let before = out[..<i].last { $0.speaker.map { !stray.contains($0) } == true }?.speaker
            let after = out[(i + 1)...].first { $0.speaker.map { !stray.contains($0) } == true }?.speaker
            out[i].speaker = before ?? after
        }
        return out
    }


    /// "# Title", then one passage per paragraph. Speakers are named only when
    /// there's more than one.
    nonisolated static func transcriptText(title: String, passages: [TranscriptPassage]) -> String {
        let several = Set(passages.compactMap(\.speaker)).count > 1
        let body = passages.map { p in
            let speaker = several ? p.speaker.map { "Speaker \($0): " } ?? "" : ""
            return "\(timestamp(p.start)) \(speaker)\(p.text)"
        }.joined(separator: "\n\n")
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return heading.isEmpty ? body + "\n" : "# \(heading)\n\n\(body)\n"
    }

    nonisolated static func timestamp(_ seconds: Double) -> String {
        let t = max(0, Int(seconds))
        return t >= 3600
            ? String(format: "[%d:%02d:%02d]", t / 3600, (t % 3600) / 60, t % 60)
            : String(format: "[%02d:%02d]", t / 60, t % 60)
    }

    /// Next to the media file, or in the save folder when that folder is read-only.
    static func transcriptPath(nextTo media: URL, title: String) -> String {
        let folder = media.deletingLastPathComponent().path
        let dir = FileManager.default.isWritableFile(atPath: folder) ? folder : AppSettings.shared.downloadPath
        let base = safeFileBase(title, fallback: media.deletingPathExtension().lastPathComponent)
        return uniqueFilePath(dir: dir, base: base, ext: "txt")
    }

    /// A title made safe for a file name (no path characters, at most 80 long).
    static func safeFileBase(_ title: String, fallback: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: illegal).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let bounded = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
        return bounded.isEmpty ? fallback : bounded
    }

    /// A path that doesn't collide with an existing file ("Title 2.txt", "Title 3.txt"…).
    static func uniqueFilePath(dir: String, base: String, ext: String) -> String {
        let fm = FileManager.default
        var candidate = "\(dir)/\(base).\(ext)"
        var n = 2
        while fm.fileExists(atPath: candidate) { candidate = "\(dir)/\(base) \(n).\(ext)"; n += 1 }
        return candidate
    }

    nonisolated static func friendly(_ error: Error) -> String {
        if error is TranscriptionError || error is ParakeetError || error is AudioConverter.ConversionError,
           let text = (error as? LocalizedError)?.errorDescription { return text }
        let raw = String(describing: error).lowercased()
        if raw.contains("at least") && raw.contains("audio") {
            return String(localized: "The recording is too short to transcribe.")
        }
        if raw.contains("not initialized") || raw.contains("model") && raw.contains("load") {
            return String(localized: "The speech model couldn't start. Delete it in Settings and download it again.")
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return String(localized: "Network problem. Check your internet connection and try again.")
        }
        return String(localized: "Transcription failed: \(error.localizedDescription)")
    }

    // MARK: - Audio

    /// Any media to 16 kHz mono WAV: AVFoundation first, the bundled ffmpeg for
    /// formats Apple can't open (webm, mkv…).
    nonisolated static func extractAudio(from input: URL, to output: URL) async throws {
        do {
            try await AudioConverter.toSpeechWav(input: input, output: output)
        } catch AudioConverter.ConversionError.noAudio {
            throw AudioConverter.ConversionError.noAudio
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            appLog("[MindExtract] Native audio conversion failed (\(error.localizedDescription)); trying ffmpeg")
            guard let ffmpeg = BundledTools.ffmpegPath else {
                throw TranscriptionError.unreadable
            }
            try await runFFmpeg(ffmpeg, input: input, output: output)
        }
    }

    private nonisolated static func runFFmpeg(_ ffmpeg: String, input: URL, output: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-nostdin", "-loglevel", "error", "-i", input.path, "-vn",
                             "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", "-y", output.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        nonisolated(unsafe) let running = process
        let detail: String = try await withTaskCancellationHandler {
            try running.run()
            // Read before waiting: a full pipe would stall ffmpeg.
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            running.waitUntilExit()
            return detail
        } onCancel: {
            if running.isRunning { running.terminate() }
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            appLog("[MindExtract] ffmpeg: \(detail)")
            if detail.lowercased().contains("does not contain any stream") {
                throw AudioConverter.ConversionError.noAudio
            }
            throw TranscriptionError.unreadable
        }
    }

    // MARK: - Apple speech recognition

    /// Transcribes with Apple's on-device SpeechAnalyzer, for languages Parakeet
    /// doesn't cover. Returns passages and the audio length.
    private nonisolated static func appleTranscribe(wav: URL, language: String,
                                                    progress: @escaping @Sendable (Double) -> Void) async throws -> ([TranscriptPassage], Double) {
        guard let locale = await resolveTranscriberLocale(language: language) else {
            throw TranscriptionError.languageUnavailable
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [.audioTimeRange])
        // Apple lets an app reserve only a few languages; free a slot first.
        await makeRoomForLocale(locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: wav)
        let duration = file.fileFormat.sampleRate > 0 ? Double(file.length) / file.fileFormat.sampleRate : 0
        let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], finishAfterFile: true)
        _ = analyzer   // kept alive for the results loop

        var passages: [TranscriptPassage] = []
        for try await result in transcriber.results {
            try Task.checkCancellation()
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let end = result.range.end.seconds
            passages.append(TranscriptPassage(start: result.range.start.seconds, end: end, text: text))
            if duration > 0 { progress(end / duration) }
        }
        return (passages, duration)
    }

    /// The supported locale for a language, always the same regional variant
    /// (each new variant takes one of the app's few reserved-language slots).
    nonisolated static func resolveTranscriberLocale(language: String) async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        func pick(_ lang: String?) -> Locale? {
            let candidates = supported.filter { $0.language.languageCode?.identifier == lang }
            if let region = Locale.current.region?.identifier,
               let local = candidates.first(where: { $0.region?.identifier == region }) { return local }
            let usual = ["en-US", "zh-CN", "ja-JP", "ko-KR", "hi-IN", "yue-CN"]
            if let common = candidates.first(where: { usual.contains($0.identifier(.bcp47)) }) { return common }
            return candidates.min { $0.identifier < $1.identifier }
        }
        return pick(language)
    }

    /// Releases other variants of the same language, then the oldest reserved
    /// languages, until `locale` fits within Apple's per-app limit.
    nonisolated static func makeRoomForLocale(_ locale: Locale) async {
        let id = locale.identifier(.bcp47)
        for other in await AssetInventory.reservedLocales
        where other.language.languageCode == locale.language.languageCode && other.identifier(.bcp47) != id {
            await AssetInventory.release(reservedLocale: other)
        }
        let reserved = await AssetInventory.reservedLocales
        guard !reserved.contains(where: { $0.identifier(.bcp47) == id }) else { return }
        let excess = reserved.count - (AssetInventory.maximumReservedLocales - 1)
        guard excess > 0 else { return }
        for old in reserved.prefix(excess) {
            await AssetInventory.release(reservedLocale: old)
        }
    }
}

enum TranscriptionError: LocalizedError {
    case unreadable
    case noSpeech
    case languageUnavailable

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return String(localized: "This file couldn't be read. It may be damaged, or in a format MindExtract doesn't support.")
        case .noSpeech:
            return String(localized: "No speech was found. Check that the video has someone talking, or pick its language in the notch.")
        case .languageUnavailable:
            return String(localized: "Apple's speech recognition doesn't offer this language on this Mac. Choose Automatic or another language.")
        }
    }
}
