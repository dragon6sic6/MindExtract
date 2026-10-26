import Foundation
import CoreML
import CryptoKit
import FluidAudio

// MARK: - The speech model
//
// NVIDIA Parakeet TDT 0.6B v3 (CC BY 4.0): one model for 25 European languages
// that recognizes the spoken language by itself. We run the Core ML build
// published by FluidInference (FluidInference/parakeet-tdt-0.6b-v3-coreml)
// through FluidAudio's Parakeet runtime, fully on-device.
//
// It isn't bundled (every app update would carry 630 MB again). It downloads
// once on first launch; every file is pinned to a revision and checked against
// its SHA-256, so a changed upstream repo can't slip in new weights.

/// One recognized word with timing (seconds) and model confidence (0 to 1).
struct SpeechWord: Sendable, Equatable {
    var word: String
    var start: Double
    var end: Double
    var confidence: Float
}

struct SpeechOutput: Sendable {
    let text: String
    let words: [SpeechWord]
    let duration: Double
}

enum ParakeetError: LocalizedError {
    case notInstalled
    case checksumMismatch(String)
    case badResponse(String, Int)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return String(localized: "The speech model isn't downloaded yet.")
        case .checksumMismatch:
            return String(localized: "The speech model download was damaged. Try again.")
        case .badResponse(_, let code):
            return String(localized: "The speech model couldn't be downloaded (HTTP \(code)). Try again later.")
        }
    }
}

actor ParakeetEngine {
    static let shared = ParakeetEngine()

    static let displayName = "NVIDIA Parakeet v3"
    static let attribution = "NVIDIA Parakeet TDT 0.6B v3, CC BY 4.0"

    // MARK: Pinned files

    static let repo = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
    static let revision = "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe"

    struct RemoteFile: Sendable {
        let path: String
        let size: Int64
        let sha256: String
    }

    /// Preprocessor, the int8 per-channel encoder (FluidAudio's `.int8V2`, which
    /// avoids the word corruption the original palettized encoder can show),
    /// decoder, the v3 joint, and the vocabulary. Already compiled for Core ML.
    static let files: [RemoteFile] = [
        .init(path: "Decoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350"),
        .init(path: "Decoder.mlmodelc/coremldata.bin", size: 554, sha256: "18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99"),
        .init(path: "Decoder.mlmodelc/metadata.json", size: 3427, sha256: "a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9"),
        .init(path: "Decoder.mlmodelc/model.mil", size: 13110, sha256: "ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35"),
        .init(path: "Decoder.mlmodelc/weights/weight.bin", size: 23604992, sha256: "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41"),
        .init(path: "Encoder_v2.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "af98d71151609799efbbffc00112fcba4bd91adf0b01135a982c574e91822f9c"),
        .init(path: "Encoder_v2.mlmodelc/coremldata.bin", size: 478, sha256: "70628bd4fd25fb554cc0cebc31356723930c885480132bf3ecd1b5dbe71dd0a2"),
        .init(path: "Encoder_v2.mlmodelc/model.mil", size: 1002653, sha256: "abc621390840dd064e6833dc098101706621e47e17119ead904f8c383211dd1d"),
        .init(path: "Encoder_v2.mlmodelc/weights/weight.bin", size: 594211328, sha256: "8d2c79e15a4545e08fe3a21fe741e42b8bf24329db81de8fdfacd92388ea5a66"),
        .init(path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c"),
        .init(path: "JointDecisionv3.mlmodelc/coremldata.bin", size: 521, sha256: "f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342"),
        .init(path: "JointDecisionv3.mlmodelc/metadata.json", size: 3453, sha256: "d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f"),
        .init(path: "JointDecisionv3.mlmodelc/model.mil", size: 11775, sha256: "be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d"),
        .init(path: "JointDecisionv3.mlmodelc/weights/weight.bin", size: 12642764, sha256: "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e"),
        .init(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
        .init(path: "Preprocessor.mlmodelc/coremldata.bin", size: 486, sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
        .init(path: "Preprocessor.mlmodelc/metadata.json", size: 2841, sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
        .init(path: "Preprocessor.mlmodelc/model.mil", size: 28181, sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
        .init(path: "Preprocessor.mlmodelc/weights/weight.bin", size: 491072, sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
        .init(path: "parakeet_vocab.json", size: 151122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
    ]

    static let totalDownloadBytes: Int64 = files.reduce(0) { $0 + $1.size }

    // MARK: Locations

    static var rootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mindact.mindextract")
            .appendingPathComponent("SpeechModels")
    }

    /// Ready-to-load model folder for the pinned revision.
    static var modelDirectory: URL {
        rootDirectory.appendingPathComponent("parakeet-v3-\(revision.prefix(8))")
    }

    private static let completeMarker = ".complete"

    static var isInstalled: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelDirectory.appendingPathComponent(completeMarker).path) else { return false }
        return files.allSatisfy { fm.fileExists(atPath: modelDirectory.appendingPathComponent($0.path).path) }
    }

    static func installedSize() -> Int64? {
        guard isInstalled else { return nil }
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: modelDirectory, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in e {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    // MARK: Install

    /// Downloads every pinned file into a staging folder, verifies each SHA-256,
    /// then moves the folder into place in one step. `progress` is 0 to 1.
    static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        removeLeftoverStaging()
        let staging = rootDirectory.appendingPathComponent(".staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var doneBytes: Int64 = 0
        let total = Double(totalDownloadBytes)
        for file in files {
            try Task.checkCancellation()
            let dest = staging.appendingPathComponent(file.path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = doneBytes
            try await download(file, to: dest) { written in
                progress(Double(base + written) / total)
            }
            guard try sha256(of: dest) == file.sha256 else {
                throw ParakeetError.checksumMismatch(file.path)
            }
            doneBytes += file.size
        }
        try Data().write(to: staging.appendingPathComponent(completeMarker))

        if fm.fileExists(atPath: modelDirectory.path) { try fm.removeItem(at: modelDirectory) }
        try fm.moveItem(at: staging, to: modelDirectory)
        progress(1)
    }

    /// A download that was cut off by quitting leaves its staging folder behind.
    static func removeLeftoverStaging() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: rootDirectory.path) else { return }
        for name in items where name.hasPrefix(".staging-") {
            try? fm.removeItem(at: rootDirectory.appendingPathComponent(name))
        }
    }

    static func uninstall() async throws {
        await shared.unload()
        if FileManager.default.fileExists(atPath: rootDirectory.path) {
            try FileManager.default.removeItem(at: rootDirectory)
        }
    }

    private static func download(_ file: RemoteFile, to dest: URL,
                                 progress: @escaping @Sendable (Int64) -> Void) async throws {
        let url = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.path)")!
        let delegate = DownloadDelegate(destination: dest, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                // Cancelled before we got here: the session may already be invalidated.
                if Task.isCancelled { cont.resume(throwing: CancellationError()); return }
                delegate.continuation = cont
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
        if let code = delegate.statusCode, !(200..<300).contains(code) {
            throw ParakeetError.badResponse(file.path, code)
        }
    }

    /// Streams the file through SHA-256 so the 590 MB encoder never sits in memory.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Runtime

    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?

    var isLoaded: Bool { manager != nil }

    /// Loads the models. The first load after install also builds Core ML's cache,
    /// which takes a while; later loads are quick.
    func load() async throws -> AsrManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        guard Self.isInstalled else { throw ParakeetError.notInstalled }
        let task = Task { () async throws -> AsrManager in
            let models = try AsrModels.loadLocal(from: Self.modelDirectory, version: .v3, encoderPrecision: .int8V2)
            let asr = AsrManager(config: .default)
            try await asr.loadModels(models)
            return asr
        }
        loading = task
        defer { loading = nil }
        let asr = try await task.value
        manager = asr
        return asr
    }

    func unload() async {
        if let manager { await manager.cleanup() }
        manager = nil
    }

    /// Transcribes a 16 kHz mono WAV. Long files are read from disk in chunks.
    /// `progress` reports 0 to 1.
    func transcribe(audioURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> SpeechOutput {
        let asr = try await load()
        let stream = await asr.transcriptionProgressStream
        let progressTask = Task {
            do { for try await p in stream { progress(p) } } catch {}
        }
        defer { progressTask.cancel() }
        var state = TdtDecoderState.make(decoderLayers: 2)
        let result = try await asr.transcribe(audioURL, decoderState: &state)
        return SpeechOutput(text: result.text, words: Self.words(from: result.tokenTimings ?? []),
                            duration: result.duration)
    }

    /// Groups SentencePiece tokens into words (a piece starting with `▁` or a
    /// space starts a new word), keeping each word's average confidence.
    static func words(from tokens: [TokenTiming]) -> [SpeechWord] {
        var words: [SpeechWord] = []
        var current: SpeechWord?
        var confidences: [Float] = []

        func flush() {
            guard var w = current else { return }
            w.word = w.word.trimmingCharacters(in: .whitespaces)
            if !w.word.isEmpty {
                w.confidence = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Float(confidences.count)
                words.append(w)
            }
            current = nil
            confidences = []
        }

        for t in tokens {
            let piece = t.token
            if piece.isEmpty || piece == "<blank>" || piece == "<pad>" || piece.hasPrefix("<|") { continue }
            let startsWord = piece.hasPrefix("▁") || piece.hasPrefix(" ")
            let text = piece.replacingOccurrences(of: "▁", with: " ")
            if startsWord || current == nil {
                flush()
                current = SpeechWord(word: text, start: t.startTime, end: t.endTime, confidence: 0)
            } else {
                current?.word += text
                current?.end = t.endTime
            }
            confidences.append(t.confidence)
        }
        flush()
        return words
    }
}

/// Per-download URLSession delegate: reports bytes written and moves the finished
/// file into place before URLSession deletes its temporary copy.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progress: @Sendable (Int64) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    var statusCode: Int?
    private var moveError: Error?

    init(destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error ?? moveError {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}

// MARK: - Sentences

/// A readable chunk of a transcript. Parakeet returns one long stream of words,
/// so the words are cut into passages at sentence ends and pauses.
struct SpeechSegment: Sendable, Equatable {
    var start: Double
    var end: Double
    var words: [SpeechWord]
    var text: String { words.map(\.word).joined(separator: " ") }
}

enum TranscriptSegmenter {
    /// Splits at sentence ends once a passage has some length, at long pauses,
    /// and hard-caps very long run-ons.
    static func segments(from words: [SpeechWord],
                         pause: Double = 1.2,
                         minSentence: Double = 2.5,
                         maxDuration: Double = 20,
                         maxWords: Int = 60) -> [SpeechSegment] {
        var out: [SpeechSegment] = []
        var current: [SpeechWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(SpeechSegment(start: first.start, end: last.end, words: current))
            current = []
        }

        for w in words {
            if let last = current.last, w.start - last.end >= pause { flush() }
            current.append(w)
            let span = (current.last?.end ?? 0) - (current.first?.start ?? 0)
            let endsSentence = w.word.last.map { ".?!…".contains($0) } ?? false
            if (endsSentence && span >= minSentence) || span >= maxDuration || current.count >= maxWords {
                flush()
            }
        }
        flush()
        return out
    }
}

// MARK: - Who spoke when

struct SpeakerTurn: Sendable, Equatable {
    var start: Double
    var end: Double
    /// 1, 2, 3… in the order the voices first appear.
    var speaker: Int
}

/// Speaker separation with FluidAudio's offline diarizer (pyannote segmentation
/// and WeSpeaker voice embeddings), on-device. Its models (about 30 MB) are
/// fetched the first time it runs.
enum SpeakerSeparator {
    static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mindact.mindextract")
            .appendingPathComponent("SpeakerModels")
    }

    static func turns(audioURL: URL) async throws -> [SpeakerTurn] {
        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels(directory: modelsDirectory)
        let result = try await manager.process(audioURL)
        var numbers: [String: Int] = [:]
        return result.segments
            .sorted { $0.startTimeSeconds < $1.startTimeSeconds }
            .map { seg in
                let n = numbers[seg.speakerId] ?? (numbers.count + 1)
                numbers[seg.speakerId] = n
                return SpeakerTurn(start: Double(seg.startTimeSeconds), end: Double(seg.endTimeSeconds), speaker: n)
            }
    }

    /// The speaker who talks most during `start...end`, or nil if nobody does.
    static func speaker(from turns: [SpeakerTurn], start: Double, end: Double) -> Int? {
        var best: (speaker: Int, overlap: Double)?
        for t in turns {
            let overlap = min(end, t.end) - max(start, t.start)
            if overlap > 0, overlap > (best?.overlap ?? 0) { best = (t.speaker, overlap) }
        }
        return best?.speaker
    }
}
