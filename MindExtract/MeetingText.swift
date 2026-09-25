import Foundation

// MARK: - Meeting text helpers
//
// Small, pure helpers for reading a meeting's brief and naming the meeting from it.

/// A commitment parsed from a brief. No longer produced, but kept so older AI
/// sidecars that stored commitments still decode.
struct MeetingCommitment: Codable, Hashable {
    var task: String
    var owner: String?
    var dueISO: String?
    var dueText: String?
    var deleted: Bool?
    var dueOverrideISO: String?
    var snoozedUntilISO: String?
}

enum MeetingText {
    /// "Meeting 2026-06-22 15.30" and similar timestamp-only titles.
    static func isGenericTitle(_ t: String) -> Bool {
        t.range(of: #"^Meeting \d{4}-\d{2}-\d{2} \d{2}\.\d{2}$"#, options: .regularExpression) != nil
    }

    /// A short title from the brief's TL;DR — first sentence, ≤6 words.
    static func suggestedTitle(fromBrief brief: String) -> String? {
        let tldr = briefSection(brief, "TL;DR")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })
        guard let line = tldr, !line.isEmpty else { return nil }
        let sentence = line.components(separatedBy: CharacterSet(charactersIn: ".!?")).first ?? line
        var words = sentence.split(separator: " ").prefix(6).map(String.init)
        // Trim trailing connectors so titles don't end on "with"/"the".
        let stop: Set<String> = ["the","a","an","with","for","to","and","of","in","on","at","by","that","this","our"]
        while let last = words.last?.lowercased(), stop.contains(last) { words.removeLast() }
        let cleaned = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;:—–-"))
        guard cleaned.count >= 3 else { return nil }
        return cleaned
    }

    /// The lines under a "## Header" in a brief (localized "Action items" headers included).
    static func briefSection(_ text: String, _ header: String) -> String {
        let actionItemsAliases: Set<String> = [
            "action items", "åtgärdspunkter", "aktionspunkter", "att göra",
            "action points", "maßnahmen", "aufgaben", "tâches", "points d'action",
            "acciones", "tareas", "azioni", "punti d'azione"
        ]
        var out: [String] = []
        var inSection = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                let h = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                inSection = h.caseInsensitiveCompare(header) == .orderedSame
                    || (header == "Action items" && actionItemsAliases.contains(h.lowercased()))
                continue
            }
            if inSection { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    /// Renames "Meeting 2026-06-22 15.30"-style titles once a brief exists.
    @MainActor
    static func retitleGenericMeetings() {
        let history = TranscriptionHistoryManager.shared
        for item in history.history where isGenericTitle(item.title) && item.fileExists {
            guard let brief = TranscriptAIStore.load(for: item.filePath)?
                    .templateOutputs?[PromptTemplateLibrary.meetingBriefID.uuidString]?.text,
                  let better = suggestedTitle(fromBrief: brief) else { continue }
            history.rename(item, to: better)
        }
    }
}
