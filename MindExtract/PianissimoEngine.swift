import Foundation
import CoreML
import CryptoKit
import FluidAudio

// Klang Pianissimo — the Swedish speech engine.
//
// "Klang Pianissimo" by Klang AI AB (https://huggingface.co/KlangAI/pianissimo-sv),
// licensed CC BY 4.0, a fine-tune of NVIDIA Parakeet TDT 0.6B v3. We run the
// community Core ML conversion (markstrom/pianissimo-sv-coreml, also CC BY 4.0)
// through FluidAudio's Parakeet TDT v3 runtime — fully on-device.
//
// This file deliberately does NOT import WhisperKit: both modules export
// `WordTiming`, and `WhisperKit.WordTiming` can't be spelled (the module has a
// class of the same name). Output is plain `PianissimoWord`s; TranscriptionManager
// turns them into WhisperKit results so diarization runs unchanged.

/// One recognized word with timing (seconds) and model confidence (0–1).
struct PianissimoWord: Sendable, Equatable {
    var word: String
    var start: Double
    var end: Double
    var confidence: Float
}

struct PianissimoOutput: Sendable {
    let text: String
    let words: [PianissimoWord]
    let duration: Double
}

enum PianissimoError: LocalizedError {
    case notInstalled
    case checksumMismatch(String)
    case badResponse(String, Int)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Model not downloaded"
        case .checksumMismatch(let f): return "Download of \(f) was corrupted (checksum mismatch). Please try again."
        case .badResponse(let f, let code): return "Couldn't download \(f) (HTTP \(code))."
        }
    }
}

actor PianissimoEngine {
    static let shared = PianissimoEngine()

    // MARK: - Pinned model files

    /// Pinned revision of markstrom/pianissimo-sv-coreml — every file is verified
    /// against the sha256 below, so a changed upstream repo can't slip in new weights.
    static let repo = "markstrom/pianissimo-sv-coreml"
    static let revision = "106fa163a138a0db6737e0c50494269e07f508d0"
    static let attribution = "Klang Pianissimo by Klang AI AB · CC BY 4.0"

    struct RemoteFile: Sendable {
        let path: String
        let size: Int64
        let sha256: String
    }

    static let files: [RemoteFile] = [
        .init(path: "Decoder.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 11811, sha256: "4a36039f091573251bd8bcb55e8f5fa6dc3bad32052d825b1e3b2a3840879990"),
        .init(path: "Decoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 23604992, sha256: "9e34a5cc5da3477cf0e49126f55d4754a6a332b5df52a22812d6ddbd84af0e39"),
        .init(path: "Decoder.mlpackage/Manifest.json", size: 617, sha256: "99e8049015d297e58291cfe279c832f01e88959ca91894be939753b19f694827"),
        .init(path: "Encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 677050, sha256: "9c9e8a95b18b35142f00ac3c8c186c669057f7ca4a097b2e463c99486eb8eeb8"),
        .init(path: "Encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 649181632, sha256: "e9623b969e8f31ba12bfbec7cdcdacb3bfb74e5a3a9bd3a812e4a942c1b1b9ed"),
        .init(path: "Encoder.mlpackage/Manifest.json", size: 617, sha256: "6d235c39782d2e839142f0df9a6fc3096a6258da05f8be1c1d95547d936cf619"),
        .init(path: "JointDecisionv3.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 10827, sha256: "af1b876c8677cc8c6676573801038ce6da4972eba4817b1caa2eb09b9ff5ed32"),
        .init(path: "JointDecisionv3.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 12642764, sha256: "1f841daf3a6ce483ac136cd7a5e48d6071543e7c5eddcbba4525bda74695cb61"),
        .init(path: "JointDecisionv3.mlpackage/Manifest.json", size: 617, sha256: "42ab119e793f459e4a8d4a86f77714f093a54ebea55a14786981962985e8121d"),
        .init(path: "Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 17913, sha256: "44426745838b32d86e0de13054eea2b7c4439e95dadef0bcfa528bdfc93eb630"),
        .init(path: "Preprocessor.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 1953088, sha256: "c69139820fc62c199f92c83d2c97458f8aaff337e5026abd9606ff03ba52b8e1"),
        .init(path: "Preprocessor.mlpackage/Manifest.json", size: 617, sha256: "caffd54a12af3df9bb673f100239919e1047ece8c4035f75819f4adc1d71b6a9"),
        .init(path: "parakeet_vocab.json", size: 151122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
        .init(path: "LICENSE-and-attribution.txt", size: 2402, sha256: "cebcc87c23d9b4df78a1e1655b20c5f82e66babde45362a58fe6a2cb64f3dc91"),
    ]

    /// Core ML packages compiled on-device into the `.mlmodelc` names FluidAudio's v3 loader expects.
    static let packages = ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"]
    static let totalDownloadBytes: Int64 = files.reduce(0) { $0 + $1.size }

    // MARK: - Locations

    static var rootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mindact.mindextract")
            .appendingPathComponent("PianissimoModels")
    }

    /// Compiled, ready-to-load model folder for the pinned revision.
    static var modelDirectory: URL {
        rootDirectory.appendingPathComponent("pianissimo-sv-\(revision.prefix(8))")
    }

    private static let completeMarker = ".complete"

    static var isInstalled: Bool {
        let fm = FileManager.default
        let dir = modelDirectory
        guard fm.fileExists(atPath: dir.appendingPathComponent(completeMarker).path),
              fm.fileExists(atPath: dir.appendingPathComponent("parakeet_vocab.json").path) else { return false }
        return packages.allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent("\($0).mlmodelc").path) }
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

    // MARK: - Install (download → verify → compile)

    /// Downloads the pinned files, verifies every sha256, compiles the packages
    /// on-device and atomically moves the result into `modelDirectory`.
    /// `progress` is 0…1 (download ≈ 90 %, compile ≈ 10 %).
    static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let staging = rootDirectory.appendingPathComponent(".staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let raw = staging.appendingPathComponent("raw")
        let out = staging.appendingPathComponent("compiled")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)

        var doneBytes: Int64 = 0
        let total = Double(totalDownloadBytes)
        for file in files {
            try Task.checkCancellation()
            let dest = raw.appendingPathComponent(file.path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = doneBytes
            try await download(file, to: dest) { written in
                progress(0.9 * Double(base + written) / total)
            }
            guard try sha256(of: dest) == file.sha256 else {
                throw PianissimoError.checksumMismatch(file.path)
            }
            doneBytes += file.size
        }

        for (i, name) in packages.enumerated() {
            try Task.checkCancellation()
            let pkg = raw.appendingPathComponent("\(name).mlpackage")
            let compiled = try await MLModel.compileModel(at: pkg)
            try fm.moveItem(at: compiled, to: out.appendingPathComponent("\(name).mlmodelc"))
            // Drop the source package right away — keeps peak disk use near 1× the model.
            try? fm.removeItem(at: pkg)
            progress(0.9 + 0.1 * Double(i + 1) / Double(packages.count))
        }
        for extra in ["parakeet_vocab.json", "LICENSE-and-attribution.txt"] {
            try fm.moveItem(at: raw.appendingPathComponent(extra), to: out.appendingPathComponent(extra))
        }
        try Data().write(to: out.appendingPathComponent(completeMarker))

        if fm.fileExists(atPath: modelDirectory.path) { try fm.removeItem(at: modelDirectory) }
        try fm.moveItem(at: out, to: modelDirectory)
        progress(1)
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
                delegate.continuation = cont
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
        if let code = delegate.statusCode, !(200..<300).contains(code) {
            throw PianissimoError.badResponse(file.path, code)
        }
    }

    /// Streams the file through SHA-256 so the 650 MB encoder never sits in memory.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Runtime

    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?
    /// Tail of the work queue — file transcription and dictation share one model,
    /// so jobs run one at a time (a dictation waits for, never corrupts, a file job).
    private var queueTail: Task<Void, Never>?

    var isLoaded: Bool { manager != nil }

    /// Loads the compiled models (first load after install also warms Core ML's cache).
    func load() async throws -> AsrManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        guard Self.isInstalled else { throw PianissimoError.notInstalled }
        let task = Task { () async throws -> AsrManager in
            let models = try AsrModels.loadLocal(from: Self.modelDirectory, version: .v3)
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

    private func enqueue<T: Sendable>(_ job: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = queueTail
        let task = Task { () async throws -> T in
            await previous?.value
            return try await job()
        }
        queueTail = Task { _ = try? await task.value }
        return try await task.value
    }

    /// Transcribes an audio file (any format AVAudioFile reads; long files are
    /// processed disk-backed in chunks). `progress` reports 0…1.
    func transcribe(audioURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> PianissimoOutput {
        let asr = try await load()
        return try await enqueue {
            let stream = await asr.transcriptionProgressStream
            let progressTask = Task {
                do { for try await p in stream { progress(p) } } catch {}
            }
            defer { progressTask.cancel() }
            var state = TdtDecoderState.make(decoderLayers: 2)
            let result = try await asr.transcribe(audioURL, decoderState: &state)
            return PianissimoOutput(text: result.text, words: Self.words(from: result.tokenTimings ?? []),
                                    duration: result.duration)
        }
    }

    /// Transcribes 16 kHz mono samples (dictation). Short clips are padded with
    /// silence — the model needs at least a second of audio.
    func transcribe(samples: [Float]) async throws -> PianissimoOutput {
        let asr = try await load()
        let pad = [Float](repeating: 0, count: 4_800)                 // 0.3 s each side
        var audio = pad + samples + pad
        if audio.count < 24_000 { audio += [Float](repeating: 0, count: 24_000 - audio.count) }
        let input = audio
        return try await enqueue {
            var state = TdtDecoderState.make(decoderLayers: 2)
            let result = try await asr.transcribe(input, decoderState: &state)
            return PianissimoOutput(text: result.text, words: Self.words(from: result.tokenTimings ?? []),
                                    duration: result.duration)
        }
    }

    /// Groups SentencePiece tokens into words (a `▁`/space-prefixed piece starts a
    /// new word) — like FluidAudio's `buildWordTimings`, but keeps confidence.
    static func words(from tokens: [TokenTiming]) -> [PianissimoWord] {
        var words: [PianissimoWord] = []
        var current: PianissimoWord?
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
                current = PianissimoWord(word: text, start: t.startTime, end: t.endTime, confidence: 0)
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

// MARK: - Sentence segmentation

/// A caption-sized chunk of Pianissimo output (Parakeet returns one long token
/// stream, not Whisper-style segments).
struct PianissimoSegment: Sendable, Equatable {
    var start: Double
    var end: Double
    var words: [PianissimoWord]
    var text: String { words.map(\.word).joined(separator: " ") }
}

enum PianissimoSegmenter {
    /// Splits words into readable segments: at sentence ends once a segment has
    /// some length, at long pauses, and hard-caps very long run-ons.
    static func segments(from words: [PianissimoWord],
                         pause: Double = 1.2,
                         minSentence: Double = 2.5,
                         maxDuration: Double = 20,
                         maxWords: Int = 60) -> [PianissimoSegment] {
        var out: [PianissimoSegment] = []
        var current: [PianissimoWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(PianissimoSegment(start: first.start, end: last.end, words: current))
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
