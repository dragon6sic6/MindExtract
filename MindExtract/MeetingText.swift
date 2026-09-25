import Foundation

// MARK: - Meeting text helpers
//
// Small, pure helpers for reading a meeting's brief and recognizing placeholder titles.

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
    /// "Meeting 2026-06-22 15.30" / "Möte 2026-06-22 15.30" — timestamp-only titles.
    static func isGenericTitle(_ t: String) -> Bool {
        t.range(of: #"^\S+ \d{4}-\d{2}-\d{2} \d{2}\.\d{2}$"#, options: .regularExpression) != nil
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
}
