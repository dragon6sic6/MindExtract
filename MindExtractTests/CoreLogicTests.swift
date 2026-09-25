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

    // MARK: Meeting insights (talk-time math)

    private func seg(_ start: Float, _ end: Float, _ text: String, _ speaker: String?) -> TranscriptionSegmentData {
        TranscriptionSegmentData(start: start, end: end, text: text, speaker: speaker, words: [], avgLogprob: 0)
    }

    func testMeetingInsightsTalkTimeAndTurns() {
        let segs = [
            seg(0, 10, "Hello there.", "Speaker 1"),
            seg(10, 20, "Hi. How are you?", "Speaker 2"),
            seg(20, 30, "Good thanks.", "Speaker 1"),
            seg(30, 35, "Great.", "Speaker 2"),
        ]
        let insights = MeetingInsights.compute(from: segs, displayName: { $0 })
        let unwrapped = try! XCTUnwrap(insights)
        XCTAssertEqual(unwrapped.speakerCount, 2)
        // Speaker 1: 10+10=20s, Speaker 2: 10+5=15s, total 35.
        let s1 = unwrapped.speakers.first { $0.name == "Speaker 1" }!
        XCTAssertEqual(s1.seconds, 20, accuracy: 0.01)
        XCTAssertEqual(s1.turns, 2)
        XCTAssertEqual(unwrapped.totalSeconds, 35, accuracy: 0.01)
        let fractionSum = unwrapped.speakers.reduce(0) { $0 + $1.fraction }
        XCTAssertEqual(fractionSum, 1.0, accuracy: 0.001)
        // Speaker 2 asked a question.
        XCTAssertEqual(unwrapped.speakers.first { $0.name == "Speaker 2" }!.questions, 1)
    }

    func testMeetingInsightsNilForSingleSpeaker() {
        let segs = [seg(0, 10, "Solo.", "Speaker 1")]
        XCTAssertNil(MeetingInsights.compute(from: segs, displayName: { $0 }))
    }

    func testMeetingInsightsRespectsRenamedSpeakers() {
        let segs = [
            seg(0, 10, "A", "Speaker 1"),
            seg(10, 20, "B", "Speaker 2"),
        ]
        let names = ["Speaker 1": "Anna", "Speaker 2": "Bertil"]
        let insights = MeetingInsights.compute(from: segs, displayName: { names[$0] ?? $0 })
        XCTAssertTrue(insights!.speakers.contains { $0.name == "Anna" })
        XCTAssertFalse(insights!.speakers.contains { $0.name == "Speaker 1" })
    }

    // MARK: Action item parsing (for Reminders)

    func testParseActionItemsBulletsAndNumbers() {
        let text = """
        Here are the next steps:
        - Send the contract to Anna
        * Book the room
        1. Follow up with finance
        ☐ Draft the email
        """
        let items = RemindersExporter.parseActionItems(text)
        XCTAssertEqual(items.count, 4)
        XCTAssertTrue(items.contains("Send the contract to Anna"))
        XCTAssertTrue(items.contains("Follow up with finance"))
        XCTAssertTrue(items.contains("Draft the email"))
        XCTAssertFalse(items.contains { $0.hasPrefix("Here are") }, "prose line must not become a task")
    }

    func testParseActionItemsNoMarkersReturnsEmpty() {
        XCTAssertTrue(RemindersExporter.parseActionItems("Just some prose with no list at all.").isEmpty)
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

    func testMeetingTemplateIDsMatchBuiltIns() {
        let ids = PromptTemplateLibrary.builtIns.map(\.id)
        XCTAssertTrue(ids.contains(PromptTemplateLibrary.meetingMinutesID))
        XCTAssertTrue(ids.contains(PromptTemplateLibrary.actionItemsID))
    }

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

    // MARK: Meeting Memory (daily-love layer)

    func testGenericTitleDetectionAndSuggestion() {
        XCTAssertTrue(MeetingText.isGenericTitle("Meeting 2026-06-22 15.30"))
        XCTAssertFalse(MeetingText.isGenericTitle("Aspia GO - Bokföring"))
        let brief = "## TL;DR\nBudget review for Q3 with the finance team.\n## Action items\n- None"
        XCTAssertEqual(MeetingText.suggestedTitle(fromBrief: brief), "Budget review for Q3")
        XCTAssertEqual(MeetingText.briefSection("## Åtgärdspunkter\n- A\n## Other\n- B", "Action items"), "- A")
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

    /// Opt-in: the dictation path (in-memory 16 kHz samples, short clip) on Pianissimo.
    func testDictationSamplesEndToEnd() async throws {
        guard let path = ProcessInfo.processInfo.environment["PIANISSIMO_E2E_AUDIO"]?.split(separator: ":").first,
              PianissimoEngine.isInstalled else { throw XCTSkip("Set PIANISSIMO_E2E_AUDIO to run") }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: String(path)))
        let target = DictationRecorder.targetFormat
        let converter = try XCTUnwrap(AVAudioConverter(from: file.processingFormat, to: target))
        let inBuf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: inBuf)
        let outBuf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 64))
        var fed = false
        converter.convert(to: outBuf, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        let all = Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
        for seconds in [0.8, 4.0, 12.0] {
            let clip = Array(all.prefix(Int(seconds * 16_000)))
            let t = CFAbsoluteTimeGetCurrent()
            let text = try await TranscriptionManager.shared.transcribeDictation(samples: clip, language: "sv")
            print("DICTATION \(seconds)s in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t))s: \(text)")
        }
    }

    // MARK: Enhanced notes parsing

    func testEnhancedNotesMarkUserWordsAndTimestamps() {
        let md = """
        ## Beslut
        - Sara tar fram kostnadsjämförelse — presenteras 9 oktober. [10:08]
        - **Lanseringen** ligger kvar i november [1:02:14]

        ## Åtgärder
        1. Anna — stäm av budgeten med ekonomi — i dag [03:05]
        """
        let notes = "- sara tar fram kostnadsjämförelse\nbudget"
        let sections = EnhancedNotesGenerator.parse(md, userNotes: notes)
        XCTAssertEqual(sections.map(\.heading), ["Beslut", "Åtgärder"])
        let first = sections[0].lines[0]
        XCTAssertEqual(first.parts.first?.isUser, true)
        XCTAssertEqual(first.parts.first?.text, "Sara tar fram kostnadsjämförelse")
        XCTAssertEqual(first.parts.last?.isUser, false)
        XCTAssertEqual(first.at, 608)
        XCTAssertFalse(first.text.contains("["), "citation removed from visible text")
        XCTAssertEqual(sections[0].lines[1].at, 3734)
        XCTAssertEqual(sections[0].lines[1].text, "Lanseringen ligger kvar i november")
        XCTAssertEqual(sections[1].lines[0].at, 185)
        XCTAssertEqual(sections[1].lines[0].parts.count, 1, "no user note in this line")
    }

    func testEnhancedNotesCitationListsAndPunctuation() {
        let (text, at) = EnhancedNotesGenerator.extractTimestamp("Anna jagar ekonomin i dag [00:02, 00:09] .")
        XCTAssertEqual(text, "Anna jagar ekonomin i dag.")
        XCTAssertEqual(at, 2)
        let (task, due) = EnhancedNotesGenerator.extractTimestamp("Sara — kostnadsjämförelse — [08:08]")
        XCTAssertEqual(task, "Sara — kostnadsjämförelse")
        XCTAssertEqual(due, 488)
        XCTAssertEqual(EnhancedNotesGenerator.extractTimestamp("Ingen tid här").1, nil)
    }

    func testEnhancedNotesWithoutHeadingsOrTimestamps() {
        let sections = EnhancedNotesGenerator.parse("- Point one\n* Point two", userNotes: "")
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].heading, "")
        XCTAssertEqual(sections[0].lines.map(\.text), ["Point one", "Point two"])
        XCTAssertNil(sections[0].lines[0].at)
    }

    func testTimestampedTranscriptAndClock() {
        XCTAssertEqual(EnhancedNotesGenerator.clock(65), "01:05")
        XCTAssertEqual(EnhancedNotesGenerator.clock(3725), "1:02:05")
        let segs = [TranscriptionSegmentData(start: 12, end: 15, text: "Hej", speaker: "You", words: [], avgLogprob: 0)]
        XCTAssertEqual(EnhancedNotesGenerator.timestampedTranscript(segs), "[00:12] You: Hej")
    }

    /// Opt-in: runs enhanced notes on the configured AI backend (set ENHANCE_E2E=1).
    func testEnhancedNotesEndToEnd() async throws {
        guard ProcessInfo.processInfo.environment["ENHANCE_E2E"] != nil else { throw XCTSkip("Set ENHANCE_E2E to run") }
        let lines: [(Float, String, String)] = [
            (2, "You", "Då kör vi, alla är på plats. Första punkten är budgeten för fjärde kvartalet."),
            (9, "Anna", "Ekonomi har inte återkommit om budgeten än. Jag jagar dem i dag, annars riskerar vi att rekryteringen skjuts till nästa år."),
            (185, "Johan", "Lanseringsplanen – jag siktar på att skicka ett utkast på fredag."),
            (488, "Sara", "Jag kan ta fram en kostnadsjämförelse mellan en extern konsult och en intern resurs till nästa styrgrupp den nionde oktober."),
            (671, "Anna", "Vi måste räkna med att juli blir tunt bemannat, så planen behöver vara klar före semestrarna."),
            (854, "You", "Bra, då bestämmer vi att lanseringen ligger kvar i november."),
        ]
        let segs = lines.map { TranscriptionSegmentData(start: $0.0, end: $0.0 + 8, text: $0.2, speaker: $0.1, words: [], avgLogprob: 0) }
        let notes = "budget q4 – ekonomi har inte återkommit\njohan: lanseringsplan klar fre?\nkonsult vs intern → Sara kollar kostnad"
        let t = CFAbsoluteTimeGetCurrent()
        let backend: AIBackend = ProcessInfo.processInfo.environment["ENHANCE_E2E"] == "apple" ? AppleIntelligenceBackend() : AIBackends.current()
        let result = try await EnhancedNotesGenerator.generate(userNotes: notes, segments: segs, backend: backend)
        print("ENHANCED (\(result.badge), \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - t))s)")
        for s in result.sections {
            print("ENHANCED ## \(s.heading)")
            for l in s.lines {
                let marked = l.parts.map { $0.isUser ? "«\($0.text)»" : $0.text }.joined()
                print("ENHANCED - \(marked) \(l.at.map { "@\(EnhancedNotesGenerator.clock($0))" } ?? "")")
            }
        }
        XCTAssertFalse(result.isEmpty)
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
