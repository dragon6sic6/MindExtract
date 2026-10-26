import XCTest
import AVFoundation
@testable import MindExtract

/// Unit tests for the pure, bug-prone logic that powers MindExtract. These lock
/// behaviour so a regression is caught automatically (not just by manual review).
@MainActor
final class CoreLogicTests: XCTestCase {

    // MARK: PII redaction (privacy-critical — must never silently stop masking)

    func testRedactorMasksEmailAndPhone() {
        let input = "Email me at jane.doe@example.com or call 070-123 45 67 tomorrow."
        let out = Redactor.redact(input)
        XCTAssertFalse(out.contains("jane.doe@example.com"), "email should be redacted")
        XCTAssertTrue(out.contains("[email]"))
        XCTAssertFalse(out.contains("070-123 45 67"), "phone should be redacted")
        XCTAssertTrue(out.contains("[phone]"))
    }

    func testRedactorKnownNamesAreConsistentTokens() {
        let input = "Anna said hello. Then Anna left. Bertil stayed."
        let out = Redactor.redact(input, knownNames: ["Anna", "Bertil"])
        XCTAssertFalse(out.contains("Anna"))
        XCTAssertFalse(out.contains("Bertil"))
        // Same name → same token both times.
        let firstToken = out.contains("[Person 1]")
        XCTAssertTrue(firstToken)
        // Two distinct names → two distinct tokens.
        XCTAssertTrue(out.contains("[Person 2]"))
    }

    func testRedactorEmptyInput() {
        XCTAssertEqual(Redactor.redact(""), "")
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

    func testTranscriptAISidecarDecodesMinimalOldJSON() throws {
        let json = #"{"chat":[]}"#.data(using: .utf8)!
        let sidecar = try JSONDecoder().decode(TranscriptAISidecar.self, from: json)
        XCTAssertNil(sidecar.summary)
        XCTAssertNil(sidecar.speakerNames)
        XCTAssertNil(sidecar.speakerSuggestions)
        XCTAssertNil(sidecar.userNotes)
        XCTAssertTrue(sidecar.chat.isEmpty)
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
