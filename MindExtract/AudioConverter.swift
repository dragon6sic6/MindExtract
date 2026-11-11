import Foundation
import AVFoundation
import VideoToolbox

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

    static func toSpeechWav(input: URL, output: URL) async throws {
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

// MARK: - Playable video

/// Sites don't always offer their best video in a codec a Mac can play: Instagram
/// serves full-resolution reels only as VP9, and AV1 needs an M3 or later. Such a
/// file still ends in .mp4, but QuickTime and Finder can't open it. This re-encodes
/// it with the Mac's own H.264 encoder, so every saved video just plays.
@MainActor
enum VideoConverter {
    /// Whether this Mac decodes AV1 (M3 and later). The bundled ffmpeg can't decode
    /// it in software, so on other Macs AV1 is neither playable nor convertible.
    nonisolated static let canPlayAV1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

    /// The path of a version of `path` this Mac can play: `path` itself when it
    /// already plays (or can't be converted), else a converted .mp4 that replaces it.
    /// `started` hands over each ffmpeg process, so a Cancel can stop it,
    /// `cancelled` tells it to stop trying, and `progress` follows a re-encode.
    static func makePlayable(_ path: String, started: (Process) -> Void, cancelled: () -> Bool,
                             progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }) async -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let tracks = (try? await asset.load(.tracks)) ?? []
        let video = tracks.first { $0.mediaType == .video }
        let audio = tracks.first { $0.mediaType == .audio }

        var videoArgs: [String]?    // nil: re-encode the picture
        var audioPlays = false
        var size = CGSize(width: 1920, height: 1080)
        if let video {
            // A file AVFoundation can open: check what's inside.
            let videoCodec = await codec(of: video)
            var audioCodec: String?
            if let audio { audioCodec = await codec(of: audio) }
            audioPlays = audio == nil || ["aac ", ".mp3", "alac", "ac-3", "ec-3", "opus"].contains(audioCodec)
            if videoCodec == "av01", !canPlayAV1 { return path }   // can't be decoded here
            let playable = (try? await asset.load(.isPlayable)) ?? false
            switch videoCodec {
            case "avc1", "avc3", "hvc1", "av01":
                if playable && audioPlays { return path }
                videoArgs = ["-c:v", "copy"]
            case "hev1":
                videoArgs = ["-c:v", "copy", "-tag:v", "hvc1"]      // same HEVC, the tag QuickTime wants
            default:
                break
            }
            size = (try? await video.load(.naturalSize)) ?? size
        } else if !["webm", "mkv"].contains(ext) {
            return path     // not a video, or not one we can do anything about
        }
        guard let ffmpeg = BundledTools.ffmpegPath else { return path }

        let output = ((path as NSString).deletingPathExtension as NSString).appendingPathExtension("mp4")!
        let temp = path + ".converting.mp4"
        let audioArgs = audioPlays ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", "192k"]

        let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let attempts: [[String]]
        if let videoArgs {
            attempts = [videoArgs]
        } else {
            // The picture as ffmpeg sees it (AVFoundation can't open webm, and
            // doesn't say whether VP9 is 10-bit HDR).
            let source = await probe(path, ffmpeg: ffmpeg)
            if let w = source?.width, let h = source?.height { size = CGSize(width: w, height: h) }
            let format = source?.pixelFormat ?? ""
            let tenBit = format.hasSuffix("10le") || format.hasSuffix("10be") || format == "p010le"
            let pixels = Int(abs(size.width * size.height))
            // Constant quality where the encoder supports it (Apple silicon), else a
            // bitrate sized to the picture (Intel).
            let h264 = ["-c:v", "h264_videotoolbox", "-pix_fmt", "yuv420p", "-tag:v", "avc1"]
            let h264Attempts = [h264 + ["-q:v", "65"], h264 + ["-b:v", String(max(2_000_000, pixels * 3))]]
            if min(size.width, size.height) > 1080 || tenBit {
                // Above 1080p, and for HDR, HEVC: Apple's own format for it, about twice as
                // fast here as H.264 at the same quality and a third smaller. 10-bit stays
                // 10-bit, so HDR keeps its colours. QuickTime wants the hvc1 tag.
                let hevc = ["-c:v", "hevc_videotoolbox", "-tag:v", "hvc1"]
                    + (tenBit ? ["-profile:v", "main10", "-pix_fmt", "p010le"] : ["-pix_fmt", "yuv420p"])
                // H.264 last, but not for HDR: 8-bit would band, so then the original stays.
                attempts = [hevc + ["-q:v", "65", "-prio_speed", "1"], hevc + ["-b:v", String(max(4_000_000, pixels * 2)), "-allow_sw", "1"]]
                    + (tenBit ? [] : h264Attempts.suffix(1))
            } else {
                attempts = h264Attempts
            }
        }

        for videoArgs in attempts {
            guard !cancelled() else { break }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-nostats", "-progress", "pipe:1",
                                 "-y", "-i", path, "-map", "0:v:0", "-map", "0:a?", "-map", "0:s?"]
                + videoArgs + audioArgs + ["-c:s", "mov_text", "-movflags", "+faststart", temp]
            // "-progress" writes "out_time_us=…" lines: how far into the video it is.
            let report = Pipe()
            process.standardOutput = report
            process.standardError = FileHandle.nullDevice
            report.fileHandleForReading.readabilityHandler = { handle in
                // Always drain the pipe, or ffmpeg stalls once it's full.
                let data = handle.availableData
                guard seconds > 0, let text = String(data: data, encoding: .utf8) else { return }
                // A chunk can end mid-line: only whole lines count.
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                guard let line = (text.hasSuffix("\n") ? lines[...] : lines.dropLast()).last(where: { $0.hasPrefix("out_time_us=") }),
                      let micros = Double(line.dropFirst("out_time_us=".count)) else { return }
                let done = min(max(micros / 1_000_000 / seconds, 0), 1)
                Task { @MainActor in progress(done) }
            }
            defer { report.fileHandleForReading.readabilityHandler = nil }
            let ok: Bool = await withCheckedContinuation { done in
                process.terminationHandler = { done.resume(returning: $0.terminationStatus == 0) }
                do {
                    try process.run()
                    started(process)
                } catch {
                    process.terminationHandler = nil
                    done.resume(returning: false)
                }
            }
            if ok, !cancelled(), replace(path, with: temp, at: output) { return output }
            try? FileManager.default.removeItem(atPath: temp)
        }
        return path
    }

    /// Puts the converted file in place of the original. The original is only
    /// removed once the new one is safely there.
    private static func replace(_ original: String, with temp: String, at output: String) -> Bool {
        let fm = FileManager.default
        if output == original {
            return (try? fm.replaceItemAt(URL(fileURLWithPath: original), withItemAt: URL(fileURLWithPath: temp))) != nil
        }
        try? fm.removeItem(atPath: output)
        guard (try? fm.moveItem(atPath: temp, toPath: output)) != nil else { return false }
        try? fm.removeItem(atPath: original)
        return true
    }

    /// The first video stream's size and pixel format, from ffprobe next to ffmpeg.
    private static func probe(_ path: String, ffmpeg: String) async -> (width: Int, height: Int, pixelFormat: String)? {
        let ffprobe = ((ffmpeg as NSString).deletingLastPathComponent as NSString).appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffprobe) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        process.arguments = ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height,pix_fmt",
                             "-of", "csv=p=0", path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let text: String = await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                guard (try? process.run()) != nil else { done.resume(returning: ""); return }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                done.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
        // "3840,2160,yuv420p10le"
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",").map(String.init)
        guard parts.count >= 3, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
        return (w, h, parts[2])
    }

    private static func codec(of track: AVAssetTrack) async -> String? {
        guard let format = try? await track.load(.formatDescriptions).first else { return nil }
        let code = CMFormatDescriptionGetMediaSubType(format)
        return String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, encoding: .ascii)
    }
}
