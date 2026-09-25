import Foundation

// MARK: - Enhanced meeting notes
//
// The Granola-style loop, done on-device: the user jots rough cues during the
// meeting; afterwards the AI writes full notes around them from the transcript.
// Every line keeps track of which words are the user's (shown in the primary
// color) and which the AI added (secondary), plus the moment in the recording
// it came from so ▶ can jump straight to it in the local audio.

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

enum EnhancedNotesGenerator {
    static let instructions = """
    You write enhanced meeting notes. You are given the user's own rough notes and a timestamped transcript. \
    Output markdown only: "## " section headings and "- " bullets, nothing else. Rules: \
    1) Keep every one of the user's notes: start that bullet with the user's note copied word for word, then continue with " — " and the missing details from the transcript. \
    2) Add bullets for important points the user did not write down. \
    3) End every bullet with the timestamp where it was discussed, in square brackets, e.g. [12:04]. \
    4) Include a section for decisions and a section for action items ("Owner — task — due date if stated") when there are any. \
    5) Be concise and factual; never invent anything that is not in the transcript. \
    Write the headings and the notes in the same language as the transcript.
    """

    static let condenseInstructions = """
    You condense part of a meeting transcript. Output only "- " bullets: every key point, decision, number, name and action item, \
    each ending with the timestamp where it was said in square brackets, e.g. [12:04]. Never invent anything. \
    Write in the same language as the transcript.
    """

    /// "[mm:ss] Speaker: text" lines — the timestamps are what the model cites back.
    static func timestampedTranscript(_ segments: [TranscriptionSegmentData]) -> String {
        segments.map { seg in
            let who = seg.speaker.map { "\($0): " } ?? ""
            return "[\(clock(Double(seg.start)))] \(who)\(seg.text)"
        }.joined(separator: "\n")
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Writes enhanced notes. Long meetings are condensed chunk by chunk first
    /// (timestamps kept), so the final pass always sees all of the user's notes.
    @MainActor
    static func generate(userNotes: String, segments: [TranscriptionSegmentData],
                         backend: AIBackend) async throws -> EnhancedNotes {
        var transcript = timestampedTranscript(segments)
        let notes = userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let budget = max(4_000, backend.maxPromptChars - 1_500) - notes.count
        if transcript.count > budget {
            var condensed: [String] = []
            for chunk in TranscriptSummarizer.split(transcript, size: max(3_000, budget)) {
                try Task.checkCancellation()
                condensed.append(try await backend.respond(instructions: condenseInstructions, prompt: chunk))
            }
            transcript = condensed.joined(separator: "\n")
        }
        try Task.checkCancellation()
        let prompt = """
        THE USER'S NOTES:
        \(notes.isEmpty ? "(none — write the notes from the transcript alone)" : notes)

        TRANSCRIPT:
        \(transcript)
        """
        let raw = try await backend.respond(instructions: instructions, prompt: prompt)
        return EnhancedNotes(sections: parse(raw, userNotes: notes), badge: backend.badge, generatedAt: Date())
    }

    // MARK: Parsing

    /// Turns the model's markdown into sections/lines, marking the user's own words.
    static func parse(_ markdown: String, userNotes: String) -> [EnhancedNotes.Section] {
        let noteLines = userNotes
            .components(separatedBy: .newlines)
            .map { stripBullet($0) }
            .filter { $0.count >= 3 }

        var sections: [EnhancedNotes.Section] = []
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                let heading = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                sections.append(.init(heading: heading.replacingOccurrences(of: "**", with: ""), lines: []))
                continue
            }
            var body = stripBullet(line)
            guard !body.isEmpty else { continue }
            body = body.replacingOccurrences(of: "**", with: "")
            let (text, at) = extractTimestamp(body)
            guard !text.isEmpty else { continue }
            if sections.isEmpty { sections.append(.init(heading: "", lines: [])) }
            sections[sections.count - 1].lines.append(.init(parts: split(text, userNotes: noteLines), at: at))
        }
        return sections.filter { !$0.lines.isEmpty }
    }

    /// Removes "- ", "* ", "• ", "1. ", "[ ] " prefixes.
    static func stripBullet(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"^([-*•]|\d+[.)])\s+"#, options: .regularExpression) { t.removeSubrange(r) }
        if let r = t.range(of: #"^\[[ xX]\]\s*"#, options: .regularExpression) { t.removeSubrange(r) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Pulls the "[mm:ss]" / "[h:mm:ss]" citations (also lists like "[00:02, 00:09]")
    /// out of the text; the first time in the last citation becomes the ▶ link.
    static func extractTimestamp(_ s: String) -> (String, Double?) {
        let time = #"\d{1,2}:\d{2}(?::\d{2})?"#
        let citation = #"\[\s*"# + time + #"(?:\s*[,;–-]\s*"# + time + #")*\s*\]"#
        guard let citeRegex = try? NSRegularExpression(pattern: citation),
              let timeRegex = try? NSRegularExpression(pattern: #"(\d{1,2}):(\d{2})(?::(\d{2}))?"#) else { return (s, nil) }
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        var seconds: Double?
        if let last = citeRegex.matches(in: s, range: full).last,
           let first = timeRegex.firstMatch(in: s, range: last.range) {
            func n(_ i: Int) -> Double? {
                let r = first.range(at: i)
                return r.location == NSNotFound ? nil : Double(ns.substring(with: r))
            }
            if let a = n(1), let b = n(2) {
                seconds = n(3).map { a * 3600 + b * 60 + $0 } ?? (a * 60 + b)
            }
        }
        var cleaned = citeRegex.stringByReplacingMatches(in: s, range: full, withTemplate: "")
        // Tidy what the citation left behind: "fredag ." → "fredag.", "— ." → ".".
        cleaned = cleaned.replacingOccurrences(of: #"\s+([.,;:!?])"#, with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s*—\s*([.,;])"#, with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        while cleaned.hasSuffix("—") || cleaned.hasSuffix("-") {
            cleaned = String(cleaned.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return (cleaned, seconds)
    }

    /// Marks the span that matches one of the user's notes as theirs.
    static func split(_ text: String, userNotes: [String]) -> [EnhancedNotes.Part] {
        let lower = text.lowercased()
        // Offsets are shared between `text` and `lower`; bail on the rare scripts
        // where lowercasing changes the character count.
        guard lower.count == text.count else { return [.init(text: text, isUser: false)] }
        // Longest note first, so "budget q4 – ekonomi" wins over "budget".
        func isBoundary(_ i: String.Index) -> Bool {
            let before = i > lower.startIndex ? lower[lower.index(before: i)] : " "
            let after = i < lower.endIndex ? lower[i] : " "
            return !(before.isLetter || before.isNumber) || !(after.isLetter || after.isNumber)
        }
        for note in userNotes.sorted(by: { $0.count > $1.count }) {
            // Whole words only — the note "budget" must not claim part of "budgeten".
            var searchFrom = lower.startIndex
            var found: Range<String.Index>?
            while let r = lower.range(of: note.lowercased(), range: searchFrom..<lower.endIndex) {
                if isBoundary(r.lowerBound) && isBoundary(r.upperBound) { found = r; break }
                searchFrom = lower.index(after: r.lowerBound)
            }
            guard let r = found else { continue }
            let start = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: r.lowerBound))
            let end = text.index(start, offsetBy: note.count)
            var parts: [EnhancedNotes.Part] = []
            if start > text.startIndex { parts.append(.init(text: String(text[..<start]), isUser: false)) }
            parts.append(.init(text: String(text[start..<end]), isUser: true))
            if end < text.endIndex { parts.append(.init(text: String(text[end...]), isUser: false)) }
            return parts
        }
        return [.init(text: text, isUser: false)]
    }
}

extension Notification.Name {
    /// Posted with the transcript path (object) when its enhanced notes change.
    static let enhancedNotesUpdated = Notification.Name("enhancedNotesUpdated")
}
