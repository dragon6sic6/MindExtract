import XCTest
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

    func testTopicKeyClustersRecurringTitles() {
        // Same recurring meeting on different dates → same clustering key.
        let a = MeetingMemory.topicKey("Weekly sync — 2026-06-22")
        let b = MeetingMemory.topicKey("Weekly Sync #12")
        let c = MeetingMemory.topicKey("Weekly sync (Monday)")
        XCTAssertEqual(a, b)
        XCTAssertEqual(b, c)
        XCTAssertEqual(a, "weekly sync")
        // A different meeting must NOT collide.
        XCTAssertNotEqual(a, MeetingMemory.topicKey("Budget review"))
    }

    func testParseActionItemsStripsMarkersAndSkipsNone() {
        let text = """
        - Anna — send the spec by Friday
        * Bertil to book the room
        1. Follow up with the vendor
        - None
        Just some prose, not a task
        """
        let items = MeetingMemory.parseActionItems(text)
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items.contains("Anna — send the spec by Friday"))
        XCTAssertTrue(items.contains("Bertil to book the room"))
        XCTAssertTrue(items.contains("Follow up with the vendor"))
        XCTAssertFalse(items.contains(where: { $0.caseInsensitiveCompare("none") == .orderedSame }))
        // Prose without a list marker is not turned into a junk task.
        XCTAssertFalse(items.contains(where: { $0.contains("prose") }))
    }

    func testActionItemKeyIsStableAndCaseInsensitive() {
        let id = UUID()
        let k1 = actionItemKey(id, "Send the report")
        let k2 = actionItemKey(id, "  send the report  ")
        XCTAssertEqual(k1, k2, "key normalizes case + surrounding whitespace")
        XCTAssertNotEqual(k1, actionItemKey(UUID(), "Send the report"))
    }
}
