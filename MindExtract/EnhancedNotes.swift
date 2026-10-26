import Foundation

// MARK: - Enhanced meeting notes (legacy)
//
// Written for meeting recordings by older versions. Kept only so their saved AI
// data still decodes; nothing produces these anymore.

struct EnhancedNotes: Codable, Equatable, Sendable {
    struct Part: Codable, Equatable, Sendable {
        var text: String
        var isUser: Bool
    }

    struct Line: Codable, Equatable, Sendable {
        var parts: [Part]
        /// Seconds from the start of the recording, when the model cited one.
        var at: Double?
        var text: String { parts.map(\.text).joined() }
    }

    struct Section: Codable, Equatable, Sendable {
        var heading: String
        var lines: [Line]
    }

    var sections: [Section]
    /// A short title for the meeting, written with the notes (nil in older notes).
    var title: String?
    /// Which backend wrote it ("Apple Intelligence", "Ollama · gemma…").
    var badge: String
    var generatedAt: Date

    var isEmpty: Bool { sections.allSatisfy { $0.lines.isEmpty } }

    /// Plain markdown for copy/export.
    var markdown: String {
        sections.map { s in
            let lines = s.lines.map { "- " + $0.text }.joined(separator: "\n")
            return s.heading.isEmpty ? lines : "## \(s.heading)\n\(lines)"
        }.joined(separator: "\n\n")
    }
}
