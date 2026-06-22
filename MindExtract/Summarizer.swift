import Foundation
import SwiftUI

// MARK: - Transcript summarization (routed through the selected AI backend)

/// Summarizes transcripts via the user's chosen AI backend — Apple Intelligence
/// (on-device) by default, or Ollama / OpenAI / Anthropic from Settings.
@MainActor
final class TranscriptSummarizer: ObservableObject {
    static let shared = TranscriptSummarizer()

    enum State: Equatable {
        case idle
        case working(String)     // progress message
        case done(String)        // the summary
        case failed(String)      // human-readable error
    }

    @Published var state: State = .idle

    /// Backend that actually produced the current summary (captured at completion)
    /// so switching providers afterwards can't mislabel an existing result.
    @Published private(set) var resultBadge: String = ""

    /// Hash of the text the current `state` belongs to, so a new transcript
    /// automatically invalidates the old summary.
    private var currentTextHash: Int = 0
    private var task: Task<Void, Never>?

    private init() {}

    func summarize(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let hash = trimmed.hashValue
        if hash == currentTextHash, state != .idle, !isFailed { return }
        currentTextHash = hash

        let backend = AIBackends.current()
        let badge = backend.badge
        state = .working("Summarizing…")
        task = Task {
            do {
                let summary = try await Self.generateSummary(for: trimmed, backend: backend) { [weak self] progress in
                    await MainActor.run { self?.state = .working(progress) }
                }
                if Task.isCancelled { return }
                if self.currentTextHash == hash {
                    self.resultBadge = badge
                    self.state = .done(summary)
                }
            } catch {
                if Task.isCancelled { return }
                if self.currentTextHash == hash {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Stop an in-progress summary (long transcripts chunk-summarize and can run
    /// for minutes) and return to the CTA.
    func cancel() {
        task?.cancel()
        task = nil
        currentTextHash = 0
        state = .idle
    }

    func reset() {
        task?.cancel()
        task = nil
        state = .idle
        currentTextHash = 0
    }

    /// Bind the summarizer to a transcript: restore a saved summary if we have
    /// one, otherwise reset to the CTA when this is a different transcript than
    /// the one currently shown (the singleton is shared across transcripts).
    func bind(toText text: String, restoredSummary: String?) {
        let hash = text.trimmingCharacters(in: .whitespacesAndNewlines).hashValue
        if let summary = restoredSummary, !summary.isEmpty {
            currentTextHash = hash
            state = .done(summary)
        } else if currentTextHash != hash {
            currentTextHash = hash
            state = .idle
        }
    }

    /// The finished summary text, if any (for persistence).
    var currentSummary: String? {
        if case .done(let s) = state { return s }
        return nil
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// Single-pass when the transcript fits the backend's context; otherwise
    /// map-reduce (chunk summaries → final synthesis).
    private static func generateSummary(
        for text: String,
        backend: AIBackend,
        progress: @escaping (String) async -> Void
    ) async throws -> String {
        let instructions = """
        You summarize transcripts of videos, meetings and podcasts. \
        Be concise and factual. Never invent content. \
        Always answer in the same language as the transcript.
        """

        let chunkSize = max(4_000, backend.maxPromptChars - 1_000)

        if text.count <= chunkSize {
            return try await backend.respond(instructions: instructions, prompt: Self.finalPrompt(for: text))
        }

        // Map: summarize each chunk briefly.
        let chunks = Self.split(text, size: chunkSize)
        var partials: [String] = []
        for (i, chunk) in chunks.enumerated() {
            await progress("Summarizing part \(i + 1) of \(chunks.count)…")
            let part = try await backend.respond(
                instructions: instructions,
                prompt: "Summarize the key points of this part of a longer transcript in 3–5 short bullet points:\n\n\(chunk)"
            )
            partials.append(part)
        }

        // Reduce: synthesize the final summary from the partials.
        await progress("Writing the final summary…")
        let combined = partials.enumerated()
            .map { "Part \($0.offset + 1):\n\($0.element)" }
            .joined(separator: "\n\n")
        return try await backend.respond(
            instructions: instructions,
            prompt: Self.finalPrompt(for: combined, isPartials: true)
        )
    }

    private static func finalPrompt(for text: String, isPartials: Bool = false) -> String {
        let source = isPartials
            ? "These are summaries of consecutive parts of one transcript."
            : "This is a transcript."
        return """
        \(source) Write a summary with exactly this structure:

        A 2–3 sentence overview paragraph.

        Key points:
        - 3 to 6 short bullet points with the most important content.

        If the transcript contains decisions, tasks or action items, add:

        Action items:
        - each one as a short bullet.

        \(text)
        """
    }

    static func split(_ text: String, size: Int) -> [String] {
        var chunks: [String] = []
        var remaining = Substring(text)
        while remaining.count > size {
            // Prefer breaking on a paragraph/sentence boundary near the limit.
            let hardEnd = remaining.index(remaining.startIndex, offsetBy: size)
            let window = remaining[..<hardEnd]
            if let br = window.lastIndex(of: "\n") ?? window.lastIndex(of: ".") {
                // Keep the boundary char (e.g. ".") with the CURRENT chunk; the
                // next chunk starts cleanly after it instead of with a stray ".".
                let after = remaining.index(after: br)
                chunks.append(String(remaining[..<after]))
                remaining = remaining[after...]
            } else {
                chunks.append(String(remaining[..<hardEnd]))
                remaining = remaining[hardEnd...]
            }
        }
        if !remaining.isEmpty { chunks.append(String(remaining)) }
        return chunks
    }
}

// MARK: - Ask the transcript (Q&A via the selected AI backend)

struct ChatMessage: Identifiable, Equatable, Codable {
    var id = UUID()
    let isUser: Bool
    let text: String
    var isError: Bool = false
}

/// On-disk summary + chat saved next to a transcript, so reopening it restores
/// the AI work instead of forcing the user to regenerate.
struct TranscriptAISidecar: Codable {
    var summary: String?
    var chat: [ChatMessage]
    // Saved translation + the target language code it was made into, so reopening
    // a transcript restores the translation (optional for backward compatibility).
    var translation: String?
    var translationLanguageCode: String?
    // Saved AI-template outputs, keyed by template UUID string (Meeting Minutes,
    // SOAP Note, …) so they persist across reopen like the summary. Each carries
    // the text plus the backend badge that produced it.
    var templateOutputs: [String: TemplateOutput]?
    // Raw notes the user jotted live during a meeting recording.
    var userNotes: String?
    // Custom speaker names, keyed by the original diarization label
    // ("Speaker 1", "Others", …) → the name the user assigned ("Anna").
    // "You" stays as-is unless the user renames it too. Persisted per transcript
    // so renaming a speaker survives reopen.
    var speakerNames: [String: String]?
    // Speaker-name suggestions captured at record time ("You" + calendar
    // attendees), persisted so reopening the transcript still offers them.
    var speakerSuggestions: [String]?
    // Moments (seconds from start) bookmarked live during the meeting, shown as
    // jump-to chips in the Brief.
    var markedMoments: [Double]?
}

enum TranscriptAIStore {
    private static func url(for transcriptPath: String) -> URL {
        URL(fileURLWithPath: transcriptPath).appendingPathExtension("mindex-ai.json")
    }
    static func load(for transcriptPath: String) -> TranscriptAISidecar? {
        guard let data = try? Data(contentsOf: url(for: transcriptPath)) else { return nil }
        return try? JSONDecoder().decode(TranscriptAISidecar.self, from: data)
    }
    static func save(_ sidecar: TranscriptAISidecar, for transcriptPath: String) {
        guard let data = try? JSONEncoder().encode(sidecar) else { return }
        try? data.write(to: url(for: transcriptPath))
    }
}

/// Q&A over a transcript. Backends with small contexts (Apple) get the most
/// relevant excerpts via lexical retrieval; big-context backends (cloud) get
/// the whole transcript when it fits.
@MainActor
final class TranscriptChat: ObservableObject {
    static let shared = TranscriptChat()

    @Published var messages: [ChatMessage] = []
    @Published var isAnswering = false

    private var transcriptHash: Int = 0
    private var transcript: String = ""
    private var chunks: [String] = []
    private(set) var lastQuestion: String = ""

    private init() {}

    func prepare(transcript: String) {
        let hash = transcript.hashValue
        guard hash != transcriptHash else { return }
        transcriptHash = hash
        messages = []
        self.transcript = transcript
        chunks = TranscriptSummarizer.split(transcript, size: 1_600)
    }

    func reset() {
        messages = []
        transcriptHash = 0
        transcript = ""
        chunks = []
    }

    /// Restore a saved conversation (call after `prepare`, which clears messages
    /// for a new transcript).
    func restore(messages: [ChatMessage]) {
        guard !messages.isEmpty else { return }
        self.messages = messages
    }

    /// Re-ask the previous question with the CURRENT provider — for when a
    /// question failed (e.g. missing API key) and the user switched models.
    func retryLast() {
        guard !isAnswering, !lastQuestion.isEmpty else { return }
        // Drop the trailing error bubble (and the question that produced it) so
        // we don't duplicate them — ask() re-appends the question.
        if messages.last?.isError == true {
            messages.removeLast()
            if messages.last?.isUser == true { messages.removeLast() }
        }
        ask(lastQuestion)
    }

    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isAnswering else { return }

        lastQuestion = q
        messages.append(ChatMessage(isUser: true, text: q))
        isAnswering = true

        let backend = AIBackends.current()
        let budget = backend.maxPromptChars - 1_500
        let source: String
        if transcript.count <= budget {
            source = transcript                      // whole transcript fits
        } else {
            source = relevantExcerpts(for: q, budget: budget)
        }
        let history = messages.suffix(5).dropLast()
            .map { ($0.isUser ? "User: " : "Assistant: ") + $0.text }
            .joined(separator: "\n")

        Task {
            do {
                let answer = try await backend.respond(
                    instructions: """
                    You answer questions about a transcript. Base your answers ONLY on \
                    the provided transcript content. If it doesn't contain the answer, \
                    say you can't find it in the transcript. Be concise. \
                    Answer in the same language as the question.
                    """,
                    prompt: """
                    Transcript:
                    \(source)

                    \(history.isEmpty ? "" : "Recent conversation:\n\(history)\n")
                    Question: \(q)
                    """
                )
                self.messages.append(ChatMessage(isUser: false, text: answer))
            } catch {
                self.messages.append(ChatMessage(isUser: false, text: error.localizedDescription, isError: true))
            }
            self.isAnswering = false
        }
    }

    /// Picks the transcript chunks most relevant to the question by simple
    /// language-agnostic word overlap (works for Swedish, English, anything).
    private func relevantExcerpts(for question: String, budget: Int) -> String {
        guard !chunks.isEmpty else { return "" }
        let qWords = Set(
            question.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 }
        )
        let ranked: [String]
        if qWords.isEmpty {
            ranked = chunks
        } else {
            ranked = chunks
                .map { chunk -> (score: Int, chunk: String) in
                    let cWords = Set(
                        chunk.lowercased()
                            .components(separatedBy: CharacterSet.alphanumerics.inverted)
                            .filter { $0.count > 2 }
                    )
                    return (qWords.intersection(cWords).count, chunk)
                }
                .sorted { $0.score > $1.score }
                .map(\.chunk)
        }
        var result: [String] = []
        var used = 0
        for chunk in ranked {
            if used + chunk.count > budget { break }
            result.append(chunk)
            used += chunk.count
        }
        return result.joined(separator: "\n…\n")
    }
}
