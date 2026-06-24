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

    func testParseCommitmentLineSplitsOwnerTaskAndDue() {
        // The brief format: "- Owner — task (due if stated)".
        let p = MeetingMemory.parseCommitmentLine("- Anna — Send the spec (due Friday)")
        XCTAssertEqual(p?.owner, "Anna")
        XCTAssertEqual(p?.task, "Send the spec")
        XCTAssertEqual(p?.dueText?.lowercased(), "friday")
        // No owner dash → owner nil, whole thing is the task.
        let p2 = MeetingMemory.parseCommitmentLine("1. Follow up with the vendor")
        XCTAssertNil(p2?.owner)
        XCTAssertEqual(p2?.task, "Follow up with the vendor")
        // "No owner mentioned" is noise, not an owner.
        let p3 = MeetingMemory.parseCommitmentLine("- No owner mentioned — Test the app")
        XCTAssertNil(p3?.owner)
        XCTAssertEqual(p3?.task, "Test the app")
        // "- None" and prose are dropped.
        XCTAssertNil(MeetingMemory.parseCommitmentLine("- None"))
        XCTAssertNil(MeetingMemory.parseCommitmentLine("Here are the next steps:"))
    }

    func testDeriveCommitmentsFromBriefStructuresAndDedupes() {
        let brief = """
        ## TL;DR
        We agreed to ship the beta.

        ## Decisions
        - Ship Friday

        ## Action items
        - Mathias — Send the spec (due 2026-06-25)
        - Anna — Book the room
        - Mathias — Send the spec
        - None
        """
        let me = Set(["mathias"])
        let cs = MeetingMemory.deriveCommitments(fromBrief: brief, meetingDate: Date())
        XCTAssertEqual(cs.count, 2, "duplicate 'Send the spec' collapses; 'None' dropped")
        let spec = cs.first { $0.task == "Send the spec" }
        XCTAssertEqual(spec?.dueISO, "2026-06-25")
        XCTAssertTrue(MeetingMemory.isMine(owner: spec?.owner, me: me))
        XCTAssertFalse(MeetingMemory.isMine(owner: cs.first { $0.task == "Book the room" }?.owner, me: me))
    }

    func testResolveDueParsesISOAndRelative() {
        let base = MeetingMemory.dateFromISO("2026-06-22")!   // a Monday
        XCTAssertEqual(MeetingMemory.resolveDue("2026-06-25", relativeTo: base).map(MeetingMemory.isoFromDate), "2026-06-25")
        XCTAssertEqual(MeetingMemory.resolveDue("tomorrow", relativeTo: base).map(MeetingMemory.isoFromDate), "2026-06-23")
        // Next Friday after Monday the 22nd is the 26th.
        XCTAssertEqual(MeetingMemory.resolveDue("Friday", relativeTo: base).map(MeetingMemory.isoFromDate), "2026-06-26")
        XCTAssertNil(MeetingMemory.resolveDue("whenever", relativeTo: base))
    }

    func testGenericTitleDetectionAndSuggestion() {
        XCTAssertTrue(MeetingMemory.isGenericTitle("Meeting 2026-06-22 15.30"))
        XCTAssertFalse(MeetingMemory.isGenericTitle("Aspia GO - Bokföring"))
        let brief = "## TL;DR\nBudget review for Q3 with the finance team.\n## Action items\n- None"
        XCTAssertEqual(MeetingMemory.suggestedTitle(fromBrief: brief), "Budget review for Q3")
    }

    func testDetectLooseEndsFindsRecurringUnclosedCommitments() {
        let cal = Calendar.current
        let now = Date()
        func item(_ text: String, _ tid: UUID, daysAgo: Int) -> TrackedActionItem {
            TrackedActionItem(key: actionItemKey(tid, text), text: text, owner: nil, ownedByMe: true,
                              dueDate: nil, dueText: nil, transcriptID: tid, transcriptTitle: "M",
                              date: cal.date(byAdding: .day, value: -daysAgo, to: now)!,
                              done: false, completedAt: nil)
        }
        let m1 = UUID(), m2 = UUID(), m3 = UUID()
        let items = [
            item("Send the signed contract to Anna", m1, daysAgo: 30),
            item("Send signed contract over to Anna", m2, daysAgo: 15),   // same loose end, new meeting
            item("Book the venue", m3, daysAgo: 2),                       // one-off, not a loose end
        ]
        let ends = MeetingMemory.detectLooseEnds(items)
        XCTAssertEqual(ends.count, 1, "the recurring contract item is a loose end; the one-off is not")
        XCTAssertEqual(ends.first?.count, 2)
        XCTAssertTrue(ends.first?.text.lowercased().contains("contract") ?? false)
    }

    func testActionItemKeyIsStableAndCaseInsensitive() {
        let id = UUID()
        let k1 = actionItemKey(id, "Send the report")
        let k2 = actionItemKey(id, "  send the report  ")
        XCTAssertEqual(k1, k2, "key normalizes case + surrounding whitespace")
        XCTAssertNotEqual(k1, actionItemKey(UUID(), "Send the report"))
    }
}
