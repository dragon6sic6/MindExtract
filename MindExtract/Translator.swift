import Foundation
import SwiftUI

// MARK: - Transcript translation (routed through the selected AI backend)

/// Translates a finished transcript into any target language via the user's
/// chosen AI backend — Apple Intelligence (on-device) by default, or Ollama /
/// OpenAI / Anthropic / Gemini etc. from Settings. Mirrors `TranscriptSummarizer`:
/// single-pass when the transcript fits the backend's context, otherwise
/// chunk-by-chunk so long transcripts don't overflow small-context models.
@MainActor
final class TranscriptTranslator: ObservableObject {
    static let shared = TranscriptTranslator()

    enum State: Equatable {
        case idle
        case working(String)     // progress message
        case done(String)        // the translated transcript
        case failed(String)      // human-readable error
    }

    @Published var state: State = .idle

    /// The AI backend badge that actually produced the current translation,
    /// captured at completion so switching providers afterwards can't mislabel
    /// it (a cloud result must never read "On-device").
    @Published private(set) var resultBadge: String = ""

    /// Hash of (text + target language) the current `state` belongs to, so a new
    /// transcript OR a new target language invalidates the old translation.
    private var currentKey: Int = 0
    private var task: Task<Void, Never>?

    private init() {}

    func translate(_ text: String, into languageName: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let key = "\(languageName)\u{1}\(trimmed)".hashValue
        if key == currentKey, state != .idle, !isFailed { return }
        currentKey = key

        let backend = AIBackends.current()
        let badge = backend.badge
        state = .working("Translating to \(languageName)…")
        task = Task {
            do {
                let translation = try await Self.generate(text: trimmed, into: languageName, backend: backend) { [weak self] progress in
                    await MainActor.run { self?.state = .working(progress) }
                }
                if Task.isCancelled { return }
                if self.currentKey == key {
                    self.resultBadge = badge
                    self.state = .done(translation)
                }
            } catch {
                if Task.isCancelled { return }
                if self.currentKey == key {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Stop an in-progress translation and return to the CTA.
    func cancel() {
        task?.cancel()
        task = nil
        currentKey = 0
        state = .idle
    }

    func reset() {
        task?.cancel()
        task = nil
        state = .idle
        currentKey = 0
        boundTextHash = 0
    }

    /// Hash of the transcript this translator's state currently belongs to.
    private var boundTextHash: Int = 0

    /// Bind to a transcript. The translator is a shared singleton, so when a
    /// different transcript is opened we clear any stale translation back to the
    /// CTA. Re-binding the same transcript keeps an in-progress/finished result.
    func bind(toText text: String) {
        let hash = text.trimmingCharacters(in: .whitespacesAndNewlines).hashValue
        guard hash != boundTextHash else { return }
        boundTextHash = hash
        task?.cancel()
        task = nil
        currentKey = 0
        state = .idle
    }

    /// The finished translation text, if any.
    var currentTranslation: String? {
        if case .done(let t) = state { return t }
        return nil
    }

    /// Restore a saved translation (from the on-disk sidecar) so reopening a
    /// transcript shows it again instead of an empty CTA — mirrors the summary.
    func restore(translation: String, forText text: String) {
        guard !translation.isEmpty else { return }
        boundTextHash = text.trimmingCharacters(in: .whitespacesAndNewlines).hashValue
        currentKey = 0
        resultBadge = ""
        state = .done(translation)
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// Single-pass when the transcript fits the backend's context; otherwise
    /// translate chunk by chunk and stitch the results back together.
    private static func generate(
        text: String,
        into languageName: String,
        backend: AIBackend,
        progress: @escaping (String) async -> Void
    ) async throws -> String {
        let instructions = """
        You are a professional translator. Translate the user's text into \(languageName). \
        Preserve the original meaning, tone and any speaker labels or line breaks. \
        Output ONLY the translation — no preface, notes or explanations.
        """

        // Unlike summarizing (short output), a translation is ~as long as the
        // input, and on-device models share one window between prompt AND
        // response. So budget for BOTH: roughly half the context, minus overhead.
        let chunkSize = max(1_500, backend.maxPromptChars / 2 - 800)

        if text.count <= chunkSize {
            return try await backend.respond(instructions: instructions, prompt: text)
        }

        // Translate each chunk and join — translation is per-segment so chunking
        // doesn't hurt quality the way it could for a single flowing summary.
        let chunks = TranscriptSummarizer.split(text, size: chunkSize)
        var parts: [String] = []
        for (i, chunk) in chunks.enumerated() {
            // Stop promptly between chunks when the user cancels (a long
            // on-device run can be dozens of sequential calls).
            try Task.checkCancellation()
            await progress("Translating part \(i + 1) of \(chunks.count)…")
            let part = try await backend.respond(instructions: instructions, prompt: chunk)
            parts.append(part)
        }
        return parts.joined(separator: "\n\n")
    }
}
