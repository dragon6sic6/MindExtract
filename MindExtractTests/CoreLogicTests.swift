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
        XCTAssertEqual(TranscriptCopy.plain(raw), "Anna: Hej. Hur mår du?\n\nSpeaker 2: Bra!\n\nAnna: Skönt.")
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

    // MARK: Speech engines

    private func w(_ word: String, _ start: Double, _ end: Double) -> SpeechWord {
        SpeechWord(word: word, start: start, end: end, confidence: 0.9)
    }

    func testLanguagesRouteToTheRightEngine() {
        XCTAssertEqual(TranscriptionManager.engine(for: "auto"), .parakeet)
        XCTAssertEqual(TranscriptionManager.engine(for: "sv"), .parakeet)
        XCTAssertEqual(TranscriptionManager.engine(for: "en"), .parakeet)
        XCTAssertEqual(TranscriptionManager.engine(for: "ja"), .apple)
        XCTAssertEqual(TranscriptionManager.engine(for: "zh"), .apple)
        XCTAssertEqual(TranscriptionManager.engine(for: "no"), .unsupported)
        XCTAssertEqual(TranscriptionManager.parakeetLanguages.count, 25)
        XCTAssertTrue(TranscriptionManager.parakeetLanguages.isDisjoint(with: TranscriptionManager.appleOnlyLanguages))
    }

    func testEveryOfferedLanguageHasAnEngine() {
        for language in AppSettings.transcriptionLanguages {
            XCTAssertNotEqual(TranscriptionManager.engine(for: language.code), .unsupported, language.code)
            XCTAssertNotEqual(language.name, language.code, "\(language.code) has an English name")
        }
    }

    func testTranscriptTextNamesSpeakersOnlyWhenThereAreSeveral() {
        let one = [TranscriptPassage(start: 1, end: 3, text: "Hello.", speaker: 1),
                   TranscriptPassage(start: 65, end: 70, text: "Again.", speaker: 1)]
        XCTAssertEqual(TranscriptionManager.transcriptText(title: "Talk", passages: one),
                       "# Talk\n\n[00:01] Hello.\n\n[01:05] Again.\n")
        let two = [TranscriptPassage(start: 0, end: 2, text: "Hi.", speaker: 1),
                   TranscriptPassage(start: 3700, end: 3702, text: "Hey.", speaker: 2)]
        XCTAssertEqual(TranscriptionManager.transcriptText(title: "", passages: two),
                       "[00:00] Speaker 1: Hi.\n\n[1:01:40] Speaker 2: Hey.\n")
    }

    func testTranscriptTextRoundTripsThroughCopy() {
        let passages = [TranscriptPassage(start: 0, end: 2, text: "Hi there.", speaker: 1),
                        TranscriptPassage(start: 3, end: 5, text: "Hello.", speaker: 2)]
        let file = TranscriptionManager.transcriptText(title: "Chat", passages: passages)
        XCTAssertEqual(TranscriptCopy.plain(file), "Speaker 1: Hi there.\n\nSpeaker 2: Hello.")
    }

    func testStraySpeakerInOneShortPassageIsMerged() {
        let p = { (start: Double, end: Double, speaker: Int) in TranscriptPassage(start: start, end: end, text: "x", speaker: speaker) }
        let merged = TranscriptionManager.mergeStraySpeakers([p(0, 4, 1), p(4, 12, 1), p(16, 19, 2)])
        XCTAssertEqual(merged.map(\.speaker), [1, 1, 1])
        // A real second voice (several passages, or a long one) stays.
        let talk = [p(0, 4, 1), p(4, 6, 2), p(6, 9, 1), p(9, 12, 2)]
        XCTAssertEqual(TranscriptionManager.mergeStraySpeakers(talk).map(\.speaker), [1, 2, 1, 2])
        let long = [p(0, 4, 1), p(4, 14, 2)]
        XCTAssertEqual(TranscriptionManager.mergeStraySpeakers(long).map(\.speaker), [1, 2])
    }

    func testSpeakerIsTheOneWhoTalksMost() {
        let turns = [SpeakerTurn(start: 0, end: 4, speaker: 1), SpeakerTurn(start: 4, end: 10, speaker: 2)]
        XCTAssertEqual(SpeakerSeparator.speaker(from: turns, start: 3, end: 8), 2)
        XCTAssertEqual(SpeakerSeparator.speaker(from: turns, start: 0, end: 3), 1)
        XCTAssertNil(SpeakerSeparator.speaker(from: turns, start: 20, end: 25))
    }

    func testSegmenterSplitsAtSentenceEndsAndPauses() {
        let words = [
            w("Hej", 0.0, 0.3), w("och", 0.4, 0.6), w("välkommen", 0.7, 1.4), w("hit.", 1.5, 2.8),
            w("Vi", 3.0, 3.2), w("börjar", 3.3, 3.8),
            w("nu.", 6.0, 6.4),                      // 2.2 s pause before this word
        ]
        let segs = TranscriptSegmenter.segments(from: words)
        XCTAssertEqual(segs.map(\.text), ["Hej och välkommen hit.", "Vi börjar", "nu."])
        XCTAssertEqual(segs.first?.start, 0.0)
        XCTAssertEqual(segs.first?.end, 2.8)
    }

    func testSegmenterKeepsShortSentencesTogetherAndCapsRunOns() {
        // "Ja." is too short to stand alone as a passage.
        let short = TranscriptSegmenter.segments(from: [w("Ja.", 0, 0.3), w("Precis", 0.4, 0.9), w("så.", 1.0, 3.0)])
        XCTAssertEqual(short.map(\.text), ["Ja. Precis så."])

        let runOn = (0..<130).map { i in w("ord", Double(i) * 0.3, Double(i) * 0.3 + 0.25) }
        let segs = TranscriptSegmenter.segments(from: runOn)
        XCTAssertTrue(segs.allSatisfy { $0.words.count <= 60 && $0.end - $0.start <= 20.5 })
        XCTAssertEqual(segs.reduce(0) { $0 + $1.words.count }, 130, "no words lost")
    }

    func testSpeechModelFilesArePinnedAndComplete() {
        XCTAssertEqual(ParakeetEngine.revision.count, 40)
        for folder in ["Preprocessor", "Encoder_v2", "Decoder", "JointDecisionv3"] {
            XCTAssertTrue(ParakeetEngine.files.contains { $0.path == "\(folder).mlmodelc/weights/weight.bin" }, folder)
            XCTAssertTrue(ParakeetEngine.files.contains { $0.path == "\(folder).mlmodelc/coremldata.bin" }, folder)
        }
        XCTAssertTrue(ParakeetEngine.files.contains { $0.path == "parakeet_vocab.json" })
        XCTAssertTrue(ParakeetEngine.files.allSatisfy { $0.sha256.count == 64 && $0.size > 0 })
        XCTAssertEqual(Double(ParakeetEngine.totalDownloadBytes) / 1e6, 632, accuracy: 5)
    }

    /// Opt-in end-to-end check (downloads about 630 MB): set SPEECH_E2E_AUDIO to
    /// a colon separated list of audio files.
    func testSpeechModelEndToEnd() async throws {
        guard let list = ProcessInfo.processInfo.environment["SPEECH_E2E_AUDIO"] else {
            throw XCTSkip("Set SPEECH_E2E_AUDIO to run")
        }
        if !ParakeetEngine.isInstalled {
            try await ParakeetEngine.install { _ in }
        }
        XCTAssertTrue(ParakeetEngine.isInstalled)
        for path in list.split(separator: ":").map(String.init) {
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            try await TranscriptionManager.extractAudio(from: URL(fileURLWithPath: path), to: wav)
            let t = CFAbsoluteTimeGetCurrent()
            let out = try await ParakeetEngine.shared.transcribe(audioURL: wav) { _ in }
            print("SPEECH \(String(format: "%.1f", out.duration))s audio in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t))s: \(out.text.prefix(300))")
            XCTAssertFalse(out.text.isEmpty)
            let turns = try await SpeakerSeparator.turns(audioURL: wav)
            print("SPEECH speakers: \(Set(turns.map(\.speaker)).count), turns: \(turns.count)")
        }
    }

    /// Opt-in: native conversion of a real recording (set CONVERT_E2E_AUDIO).
    func testNativeAudioConversion() async throws {
        guard let path = ProcessInfo.processInfo.environment["CONVERT_E2E_AUDIO"] else { throw XCTSkip("Set CONVERT_E2E_AUDIO") }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("conv-test.wav")
        try await AudioConverter.toSpeechWav(input: URL(fileURLWithPath: path), output: out)
        let file = try AVAudioFile(forReading: out)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertGreaterThan(file.length, 16_000)
    }
}
