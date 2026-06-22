import Foundation
import SwiftUI
import AVFoundation
import WhisperKit

// MARK: - Live (streaming) transcription during recording
//
// ScreenCaptureKit audio (system + mic) is resampled to 16 kHz mono with a
// persistent converter per source, incrementally mixed, and a ~1.2s tick loop
// re-transcribes only the UNCONFIRMED tail (clipTimestamps) — with front-purging
// so memory and decode cost stay bounded for arbitrarily long meetings. This is
// a live PREVIEW; the high-quality final transcript is produced from the full
// recording after stop (KB-Whisper + diarization).

/// Thread-safe audio store: per-source resample (own queue) + incremental mix
/// with front-purge. Mixed samples are addressed by ABSOLUTE index; `purged`
/// tracks how many were dropped from the front.
private final class AudioRing: @unchecked Sendable {
    nonisolated(unsafe) static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private let lock = NSLock()
    private var systemTail: [Float] = []
    private var micTail: [Float] = []
    private var systemStarted = false
    private var mixed: [Float] = []
    private var purged = 0

    // Persistent converters — each is only ever touched by its own capture queue.
    private var sysConv: AVAudioConverter?
    private var sysInFmt: AVAudioFormat?
    private var micConv: AVAudioConverter?
    private var micInFmt: AVAudioFormat?

    func appendSystem(_ sb: CMSampleBuffer) {
        guard let s = resample(sb, conv: &sysConv, inFmt: &sysInFmt) else { return }
        lock.lock(); systemStarted = true; systemTail.append(contentsOf: s); lock.unlock()
    }
    func appendMic(_ sb: CMSampleBuffer) {
        guard let s = resample(sb, conv: &micConv, inFmt: &micInFmt) else { return }
        lock.lock(); micTail.append(contentsOf: s); lock.unlock()
    }

    /// Mix newly-available aligned samples and return (mixed snapshot, purgedCount).
    func produceAndSnapshot() -> (buffer: [Float], purged: Int) {
        lock.lock(); defer { lock.unlock() }
        if systemStarted {
            let n = min(systemTail.count, micTail.count)
            if n > 0 {
                mixed.reserveCapacity(mixed.count + n)
                for i in 0..<n {
                    var v = (systemTail[i] + micTail[i]) * 0.5   // average → no clip distortion
                    if v > 1 { v = 1 } else if v < -1 { v = -1 }
                    mixed.append(v)
                }
                systemTail.removeFirst(n); micTail.removeFirst(n)
            }
        } else if !micTail.isEmpty {
            mixed.append(contentsOf: micTail)   // no system audio yet → mic only
            micTail.removeAll(keepingCapacity: true)
        }
        return (mixed, purged)
    }

    /// Drop confirmed audio from the front so memory/decode stay bounded.
    func purge(keepFromAbsoluteSample keepFrom: Int) {
        lock.lock(); defer { lock.unlock() }
        let dropTo = keepFrom - purged
        guard dropTo > 0, dropTo <= mixed.count else { return }
        mixed.removeFirst(dropTo)
        purged += dropTo
    }

    func reset() {
        lock.lock(); systemTail = []; micTail = []; mixed = []; purged = 0; systemStarted = false; lock.unlock()
        sysConv = nil; sysInFmt = nil; micConv = nil; micInFmt = nil
    }

    /// CMSampleBuffer → 16 kHz mono Float32, reusing one converter per source.
    private func resample(_ sb: CMSampleBuffer, conv: inout AVAudioConverter?, inFmt: inout AVAudioFormat?) -> [Float]? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sb),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)?.pointee,
              let inFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return nil }
        inBuf.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: inBuf.mutableAudioBufferList) == noErr else { return nil }

        if conv == nil || inFmt != inFormat {       // (re)build only on first buffer / format change
            conv = AVAudioConverter(from: inFormat, to: Self.target)
            inFmt = inFormat
        }
        guard let converter = conv else { return nil }
        let cap = AVAudioFrameCount(Double(frames) * (Self.target.sampleRate / inFormat.sampleRate) + 1024)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        converter.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        if err != nil { return nil }
        guard let ch = outBuf.floatChannelData, outBuf.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
    }
}

@MainActor
final class LiveTranscriber: ObservableObject {
    @Published private(set) var confirmedText = ""
    @Published private(set) var liveTail = ""
    @Published private(set) var isActive = false
    @Published private(set) var status = ""

    var displayText: String {
        let tail = liveTail.trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.isEmpty { return confirmedText }
        return (confirmedText + (confirmedText.isEmpty ? "" : " ") + tail)
    }

    private let ring = AudioRing()
    private var language: String = "auto"
    private var loop: Task<Void, Never>?
    private var isRunning = false             // true from start until run() fully tears down
    private var lastAbsoluteProcessed = 0     // absolute mixed samples seen
    private var lastConfirmedEnd: Float = 0    // absolute seconds
    private let sampleRate: Float = 16_000

    func start(modelFolder: String, language: String) {
        guard !isRunning else { return }      // serialize: never two model instances at once
        isRunning = true
        self.language = language
        confirmedText = ""; liveTail = ""; lastAbsoluteProcessed = 0; lastConfirmedEnd = 0
        ring.reset()
        isActive = true
        status = "Loading model…"
        loop = Task {
            await run(modelFolder: modelFolder)
            isRunning = false                  // run() has loaded → looped → unloaded, fully sequential
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        status = ""
        loop?.cancel()                         // run() observes cancellation, exits the loop, then unloads
        loop = nil
    }

    nonisolated func appendSystemBuffer(_ sb: CMSampleBuffer) { ring.appendSystem(sb) }
    nonisolated func appendMicBuffer(_ sb: CMSampleBuffer) { ring.appendMic(sb) }

    private func run(modelFolder: String) async {
        let loaded: WhisperKit
        do {
            loaded = try await WhisperKit(WhisperKitConfig(modelFolder: modelFolder, verbose: false, prewarm: false, load: true, download: false))
        } catch {
            isActive = false; status = "Live preview unavailable"
            return
        }
        status = "Listening…"

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if Task.isCancelled { break }

            let (buffer, purged) = ring.produceAndSnapshot()
            let absolute = buffer.count + purged
            let newSamples = absolute - lastAbsoluteProcessed
            guard newSamples >= Int(sampleRate) else { continue }    // ≥1s new audio

            // VAD: skip clearly-silent stretches (saves compute, avoids hallucination).
            let tail = buffer.suffix(min(newSamples, buffer.count))
            if rms(tail) < 0.004 { lastAbsoluteProcessed = absolute; continue }
            lastAbsoluteProcessed = absolute

            let purgedSeconds = Float(purged) / sampleRate
            var options = DecodingOptions()
            options.task = .transcribe
            options.language = (language == "auto") ? nil : language
            options.temperature = 0
            options.skipSpecialTokens = true
            options.clipTimestamps = [max(0, lastConfirmedEnd - purgedSeconds)]   // relative to this buffer

            guard let results = try? await loaded.transcribe(audioArray: buffer, decodeOptions: options),
                  let segments = results.first?.segments, !segments.isEmpty else { continue }
            if Task.isCancelled { break }

            // Times in segments are relative to the buffer → make absolute.
            let keepUnconfirmed = 2
            func absEnd(_ s: TranscriptionSegment) -> Float { s.end + purgedSeconds }
            func absStart(_ s: TranscriptionSegment) -> Float { s.start + purgedSeconds }

            if segments.count > keepUnconfirmed {
                let confirmable = Array(segments.prefix(segments.count - keepUnconfirmed))
                // Only append segments that genuinely start after the confirmed boundary.
                let fresh = confirmable.filter { absStart($0) >= lastConfirmedEnd - 0.1 && absEnd($0) > lastConfirmedEnd }
                if let last = fresh.last {
                    lastConfirmedEnd = absEnd(last)
                    let newText = fresh.map { Self.clean($0.text) }.filter { !$0.isEmpty }.joined(separator: " ")
                    if !newText.isEmpty {
                        confirmedText = (confirmedText.isEmpty ? newText : confirmedText + " " + newText)
                    }
                    // Bounded memory: keep ~2s before the confirmed boundary.
                    ring.purge(keepFromAbsoluteSample: max(0, Int((lastConfirmedEnd - 2) * sampleRate)))
                }
                liveTail = segments.suffix(keepUnconfirmed).map { Self.clean($0.text) }.filter { !$0.isEmpty }.joined(separator: " ")
            } else {
                liveTail = segments.map { Self.clean($0.text) }.filter { !$0.isEmpty }.joined(separator: " ")
            }
        }

        // Loop has exited (cancelled) and any in-flight transcribe returned — now
        // it's safe to release the model (sequential, never concurrent with decode).
        await loaded.unloadModels()
    }

    private func rms(_ a: ArraySlice<Float>) -> Float {
        guard !a.isEmpty else { return 0 }
        var sum: Float = 0
        for v in a { sum += v * v }
        return (sum / Float(a.count)).squareRoot()
    }

    private static func clean(_ s: String) -> String {
        // Strip any Whisper special token <|...|> plus stray whitespace.
        let stripped = s.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
