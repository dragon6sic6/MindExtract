import XCTest
import AVFoundation
@testable import MindExtract

/// Unit tests for the pure, bug-prone logic that powers MindExtract. These lock
/// behaviour so a regression is caught automatically (not just by manual review).
@MainActor
final class CoreLogicTests: XCTestCase {

    // MARK: Copying a transcript for a language model

    func testPlainCopyDropsTimestampsAndSingleSpeakerLabel() {
        let raw = "[00:00] Speaker 1: Hello there.\n\n[00:04] Speaker 1: Second line."
        XCTAssertEqual(TranscriptCopy.plain(raw), "Hello there. Second line.")
    }

    func testPlainCopyKeepsSpeakersAndMergesTurns() {
        let raw = """
        [00:00] Anna: Hej.

        [00:02] Anna: Hur mår du?

        [00:05] Speaker 2: Bra!

        [1:02:03] Anna: Skönt.
        """
        let other = TranscriptCopy.localizedSpeaker("Speaker 2")
        XCTAssertEqual(TranscriptCopy.plain(raw), "Anna: Hej. Hur mår du?\n\n\(other): Bra!\n\nAnna: Skönt.")
    }

    func testPlainCopySkipsTheFilesOwnTitleHeader() {
        let raw = "# Möte\n2026-10-26 08:12\n\n[00:00] Speaker 1: Hej allihop."
        XCTAssertEqual(TranscriptCopy.plain(raw), "Hej allihop.")
    }

    func testPlainCopyLeavesSentencesWithColonsAlone() {
        let raw = "[00:01] The plan for this year is simple: ship it."
        XCTAssertEqual(TranscriptCopy.plain(raw), "The plan for this year is simple: ship it.")
    }

    func testPlainCopySkipsALocalizedDateLine() {
        let sv = "# Möte\n26 oktober 2026 08:12\n\n[00:00] Hej allihop."
        XCTAssertEqual(TranscriptCopy.plain(sv), "Hej allihop.")
        let en = "# Meeting\nOctober 26, 2026 at 8:12 AM\n\n[00:00] Hello all."
        XCTAssertEqual(TranscriptCopy.withoutHeader(en), "[00:00] Hello all.")
    }

    func testPlainCopyIgnoresAOneOffWordBeforeAColon() {
        let raw = "[00:00] Note: this is important.\n\n[00:04] Anna: Hej.\n\n[00:06] Anna: Igen."
        XCTAssertEqual(TranscriptCopy.plain(raw), "Note: this is important. Hej. Igen.")
    }

    @MainActor
    func testLinkDetection() {
        XCTAssertTrue(NotchModel.isLink("https://youtu.be/W-HVaV3OoPw"))
        XCTAssertTrue(NotchModel.isLink("youtube.com/watch?v=abc"))
        XCTAssertFalse(NotchModel.isLink("hello world"))
        XCTAssertFalse(NotchModel.isLink("not a link"))
        XCTAssertFalse(NotchModel.isLink(""))
    }

    // MARK: Custom vocabulary normalization

    func testVocabularyPromptDedupesAndSplits() {
        let raw = "Mathias, Mindact\nMathias\nKB-Whisper"
        let prompt = TranscriptionManager.vocabularyPrompt(raw)
        // Dedup is case-insensitive and order-preserving.
        XCTAssertEqual(prompt, "Mathias, Mindact, KB-Whisper")
    }

    func testVocabularyPromptEmpty() {
        XCTAssertEqual(TranscriptionManager.vocabularyPrompt("  \n , "), "")
    }

    func testVocabularyPromptDoesNotSliceMidTerm() {
        // 200 ten-char terms → far over the 800-char budget; result must not end
        // mid-term (no trailing partial word).
        let terms = (0..<200).map { "term\(String(format: "%05d", $0))" }
        let prompt = TranscriptionManager.vocabularyPrompt(terms.joined(separator: "\n"))
        XCTAssertLessThanOrEqual(prompt.count, 800)
        for piece in prompt.components(separatedBy: ", ") {
            XCTAssertTrue(piece.hasPrefix("term") && piece.count == 9, "no partial term: \(piece)")
        }
    }

    // MARK: Codable backward-compatibility (silent data-loss guard)

    func testTranscriptionHistoryItemDecodesOldJSONWithoutNewKeys() throws {
        // Simulates history saved before source/isFavorite existed.
        let json = """
        [{"id":"\(UUID().uuidString)","title":"Old transcript","filePath":"/tmp/x.txt",
          "transcriptionDate":700000000,"duration":"1:00","modelUsed":"Small"}]
        """.data(using: .utf8)!
        let items = try JSONDecoder().decode([TranscriptionHistoryItem].self, from: json)
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].source)
        XCTAssertNil(items[0].isFavorite)
        XCTAssertNil(items[0].sourceType)
        XCTAssertEqual(items[0].title, "Old transcript")
    }

    func testTranscriptionHistoryItemRoundTripPreservesSourceAndFavorite() throws {
        var item = TranscriptionHistoryItem(title: "M", filePath: "/tmp/m.txt", duration: "2:00", modelUsed: "Small")
        item.source = TranscriptSource.meeting.rawValue
        item.isFavorite = true
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(TranscriptionHistoryItem.self, from: data)
        XCTAssertEqual(decoded.sourceType, .meeting)
        XCTAssertEqual(decoded.isFavorite, true)
    }

    // MARK: Stable identifiers / enums

    func testTranscriptSourceRoundTrip() {
        for s in TranscriptSource.allCases {
            XCTAssertEqual(TranscriptSource(rawValue: s.rawValue), s)
            XCTAssertFalse(s.displayName.isEmpty)
        }
    }

    func testDownloadQualityHasDistinctDisplayNames() {
        let names = Set(DownloadQuality.allCases.map(\.displayName))
        XCTAssertEqual(names.count, DownloadQuality.allCases.count)
    }

    // MARK: Pianissimo (Swedish engine)

    private func w(_ word: String, _ start: Double, _ end: Double) -> PianissimoWord {
        PianissimoWord(word: word, start: start, end: end, confidence: 0.9)
    }

    func testSwedishRecommendsPianissimoAndItStaysOutOfWhisperKit() {
        XCTAssertEqual(WhisperModel.recommended(for: "sv"), .pianissimo)
        XCTAssertEqual(WhisperModel.recommended(for: "en"), .small)
        XCTAssertTrue(WhisperModel.pianissimo.isSwedishOnly)
        XCTAssertFalse(WhisperModel.pianissimo.usesWhisperKit)
        XCTAssertTrue(WhisperModel.allCases.filter { $0 != .pianissimo }.allSatisfy { $0.usesWhisperKit && !$0.isSwedishOnly })
    }

    func testRemovedKBWhisperRawValueDoesNotDecode() {
        // Old installs stored "kb_whisper-small" as the default — must fall back, not crash.
        XCTAssertNil(WhisperModel(rawValue: "kb_whisper-small"))
    }

    func testSegmenterSplitsAtSentenceEndsAndPauses() {
        let words = [
            w("Hej", 0.0, 0.3), w("och", 0.4, 0.6), w("välkommen", 0.7, 1.4), w("hit.", 1.5, 2.8),
            w("Vi", 3.0, 3.2), w("börjar", 3.3, 3.8),
            w("nu.", 6.0, 6.4),                      // 2.2 s pause before this word
        ]
        let segs = PianissimoSegmenter.segments(from: words)
        XCTAssertEqual(segs.map(\.text), ["Hej och välkommen hit.", "Vi börjar", "nu."])
        XCTAssertEqual(segs.first?.start, 0.0)
        XCTAssertEqual(segs.first?.end, 2.8)
    }

    func testSegmenterKeepsShortSentencesTogetherAndCapsRunOns() {
        // "Ja." is too short to stand alone as a caption.
        let short = PianissimoSegmenter.segments(from: [w("Ja.", 0, 0.3), w("Precis", 0.4, 0.9), w("så.", 1.0, 3.0)])
        XCTAssertEqual(short.map(\.text), ["Ja. Precis så."])

        let runOn = (0..<130).map { i in w("ord", Double(i) * 0.3, Double(i) * 0.3 + 0.25) }
        let segs = PianissimoSegmenter.segments(from: runOn)
        XCTAssertTrue(segs.allSatisfy { $0.words.count <= 60 && $0.end - $0.start <= 20.5 })
        XCTAssertEqual(segs.reduce(0) { $0 + $1.words.count }, 130, "no words lost")
    }

    func testPianissimoFileListIsPinnedAndComplete() {
        XCTAssertEqual(PianissimoEngine.revision.count, 40)
        for pkg in PianissimoEngine.packages {
            XCTAssertTrue(PianissimoEngine.files.contains { $0.path.hasPrefix("\(pkg).mlpackage/") }, pkg)
        }
        XCTAssertTrue(PianissimoEngine.files.contains { $0.path == "parakeet_vocab.json" })
        XCTAssertTrue(PianissimoEngine.files.allSatisfy { $0.sha256.count == 64 })
    }

    /// Opt-in end-to-end check (downloads ~690 MB): set PIANISSIMO_E2E_AUDIO to a
    /// colon-separated list of audio files.
    func testPianissimoEndToEnd() async throws {
        guard let list = ProcessInfo.processInfo.environment["PIANISSIMO_E2E_AUDIO"] else {
            throw XCTSkip("Set PIANISSIMO_E2E_AUDIO to run")
        }
        if !PianissimoEngine.isInstalled {
            let t = CFAbsoluteTimeGetCurrent()
            try await PianissimoEngine.install { _ in }
            print("PIANISSIMO install: \(Int(CFAbsoluteTimeGetCurrent() - t))s, \(PianissimoEngine.installedSize() ?? 0) bytes")
        }
        XCTAssertTrue(PianissimoEngine.isInstalled)
        for path in list.split(separator: ":").map(String.init) {
            let t = CFAbsoluteTimeGetCurrent()
            let out = try await PianissimoEngine.shared.transcribe(audioURL: URL(fileURLWithPath: path)) { _ in }
            let segs = PianissimoSegmenter.segments(from: out.words)
            print("PIANISSIMO \(String(format: "%.1f", out.duration))s audio in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t))s: \(out.text)")
            for s in segs { print("PIANISSIMO   [\(String(format: "%.1f", s.start))-\(String(format: "%.1f", s.end))] \(s.text)") }
            XCTAssertFalse(out.text.isEmpty)
        }
    }

    /// Opt-in: native conversion of a real recording (set CONVERT_E2E_AUDIO).
    func testNativeAudioConversion() async throws {
        guard let path = ProcessInfo.processInfo.environment["CONVERT_E2E_AUDIO"] else { throw XCTSkip("Set CONVERT_E2E_AUDIO") }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("conv-test.wav")
        try await AudioConverter.toWhisperWav(input: URL(fileURLWithPath: path), output: out)
        let file = try AVAudioFile(forReading: out)
        print("CONVERT \(file.fileFormat.sampleRate) Hz, \(file.fileFormat.channelCount) ch, \(Double(file.length) / file.fileFormat.sampleRate) s")
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertGreaterThan(file.length, 16_000)
    }

    /// Opt-in: Pianissimo confidence per file (LANG_E2E = colon-separated paths).
    func testPianissimoConfidenceAsLanguageSignal() async throws {
        guard let list = ProcessInfo.processInfo.environment["LANG_E2E"] else { throw XCTSkip("Set LANG_E2E") }
        for path in list.split(separator: ":").map(String.init) {
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            try await AudioConverter.toWhisperWav(input: URL(fileURLWithPath: path), output: wav)
            let samples = try TranscriptionManager.loadSamples(wavPath: wav.path, maxSeconds: 30)
            let out = try await PianissimoEngine.shared.transcribe(samples: samples)
            let conf = out.words.isEmpty ? 0 : out.words.map(\.confidence).reduce(0, +) / Float(out.words.count)
            print("LANGSIG \((path as NSString).lastPathComponent): conf=\(conf) words=\(out.words.count) text=\(out.text.prefix(120))")
        }
    }

    /// Opt-in: full language detection per file (LANG_E2E).
    func testDetectSpokenLanguage() async throws {
        guard let list = ProcessInfo.processInfo.environment["LANG_E2E"] else { throw XCTSkip("Set LANG_E2E") }
        for path in list.split(separator: ":").map(String.init) {
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            try await AudioConverter.toWhisperWav(input: URL(fileURLWithPath: path), output: wav)
            let lang = await TranscriptionManager.shared.detectSpokenLanguage(audioPath: wav.path)
            print("DETECT \((path as NSString).lastPathComponent) → \(lang)")
        }
    }
}
