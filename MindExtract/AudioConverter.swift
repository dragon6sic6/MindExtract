import Foundation
import AVFoundation

// MARK: - Native audio conversion
//
// Turns any audio or video file AVFoundation can read (m4a, mp3, wav, aiff, caf,
// mp4, mov…) into the 16 kHz mono 16-bit WAV the speech engines expect — with no
// external tools, on any Mac. ffmpeg is only the fallback for formats Apple can't
// open (e.g. webm/mkv).

enum AudioConverter {
    enum ConversionError: LocalizedError {
        case noAudio
        case cannotRead(String)

        var errorDescription: String? {
            switch self {
            case .noAudio: return String(localized: "The file has no audio to transcribe.")
            case .cannotRead(let detail): return String(localized: "Couldn't read the audio: \(detail)")
            }
        }
    }

    static let sampleRate: Double = 16_000

    static func toWhisperWav(input: URL, output: URL) async throws {
        let asset = AVURLAsset(url: input)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw ConversionError.noAudio }

        let reader = try AVAssetReader(asset: asset)
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // The mix output also folds several audio tracks (and stereo) into one.
        let trackOutput = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: pcmSettings)
        trackOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOutput) else { throw ConversionError.cannotRead("unsupported track") }
        reader.add(trackOutput)
        guard reader.startReading() else {
            throw ConversionError.cannotRead(reader.error?.localizedDescription ?? "unknown")
        }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                                         channels: 1, interleaved: true) else {
            throw ConversionError.cannotRead("format")
        }
        try? FileManager.default.removeItem(at: output)
        let file = try AVAudioFile(forWriting: output, settings: format.settings,
                                   commonFormat: .pcmFormatInt16, interleaved: true)

        while let sample = trackOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let dest = buffer.int16ChannelData?[0] else { continue }
            let byteCount = frames * MemoryLayout<Int16>.size
            let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: dest)
            guard status == kCMBlockBufferNoErr else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)
            try file.write(from: buffer)
        }

        if reader.status == .failed {
            throw ConversionError.cannotRead(reader.error?.localizedDescription ?? "unknown")
        }
    }
}

// MARK: - External tools

/// The ffmpeg to use: the bundled one if it can actually run on this Mac (right
/// processor type), else a Homebrew install. Checked once per launch.
enum BundledTools {
    static let ffmpegPath: String? = {
        var candidates: [String] = []
        if let bundled = Bundle.main.path(forResource: "ffmpeg", ofType: nil) { candidates.append(bundled) }
        candidates += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        return candidates.first { runs($0) }
    }()

    /// The folder holding that ffmpeg (and ffprobe), for yt-dlp's --ffmpeg-location.
    static var ffmpegDirectory: String? {
        ffmpegPath.map { ($0 as NSString).deletingLastPathComponent }
    }

    private static func runs(_ path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-version"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }   // e.g. "Bad CPU type" without Rosetta
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
