import Foundation
import SwiftUI

// MARK: - Transcript Library (corpus-wide search + "ask across everything")
//
// Turns the pile of saved transcripts into a private, searchable memory: search
// the *text* of every transcript at once, and ask questions across all of them.
// Fully on-device — the only network call is the AI answer if the user chose a
// cloud provider (same as single-transcript chat).

@MainActor
final class TranscriptLibrary: ObservableObject {
    static let shared = TranscriptLibrary()

    struct Doc { let item: TranscriptionHistoryItem; let text: String }

    struct SearchHit: Identifiable {
        let item: TranscriptionHistoryItem
        let snippet: String
        let matchCount: Int
        var id: String { item.filePath }
    }

    /// filePath → (modificationDate, fileText). Avoids re-reading unchanged files.
    private var cache: [String: (mod: Date, text: String)] = [:]

    private init() {}

    private func loadAll() -> [Doc] {
        TranscriptionHistoryManager.shared.history.compactMap { item in
            guard item.fileExists else { return nil }
            let path = item.filePath
            let mod = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date ?? .distantPast
            if let cached = cache[path], cached.mod == mod { return Doc(item: item, text: cached.text) }
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            cache[path] = (mod, text)
            return Doc(item: item, text: text)
        }
    }

    // MARK: Search

    /// Case-insensitive keyword search across every transcript's text + title.
    /// Returns hits sorted by match count, each with a context snippet.
    func search(_ query: String) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for doc in loadAll() {
            if let range = doc.text.range(of: q, options: .caseInsensitive) {
                let count = doc.text.lowercased().components(separatedBy: q.lowercased()).count - 1
                hits.append(SearchHit(item: doc.item,
                                      snippet: Self.snippet(around: range, in: doc.text),
                                      matchCount: max(count, 1)))
            } else if doc.item.title.localizedCaseInsensitiveContains(q) {
                hits.append(SearchHit(item: doc.item,
                                      snippet: String(doc.text.prefix(120)).replacingOccurrences(of: "\n", with: " "),
                                      matchCount: 0))
            }
        }
        return hits.sorted { $0.matchCount > $1.matchCount }
    }

    private static func snippet(around range: Range<String.Index>, in text: String) -> String {
        let pad = 70
        let start = text.index(range.lowerBound, offsetBy: -pad, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: pad, limitedBy: text.endIndex) ?? text.endIndex
        var s = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
        s = s.trimmingCharacters(in: .whitespaces)
        if start != text.startIndex { s = "…" + s }
        if end != text.endIndex { s += "…" }
        return s
    }

    // MARK: Retrieval for cross-transcript chat

    /// Top excerpts across ALL transcripts most relevant to `question`, each
    /// labeled with its source title, packed to `budget` characters.
    func corpusExcerpts(for question: String, budget: Int) -> String {
        let qWords = Set(question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 })

        struct Scored { let score: Int; let title: String; let chunk: String }
        var scored: [Scored] = []
        for doc in loadAll() {
            for chunk in TranscriptSummarizer.split(doc.text, size: 1_200) {
                let cWords = Set(chunk.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count > 2 })
                let score = qWords.isEmpty ? 1 : qWords.intersection(cWords).count
                if score > 0 { scored.append(Scored(score: score, title: doc.item.title, chunk: chunk)) }
            }
        }
        let ranked = scored.sorted { $0.score > $1.score }
        var out: [String] = []
        var used = 0
        for s in ranked {
            let block = "From “\(s.title)”:\n\(s.chunk)"
            if used + block.count > budget { break }
            out.append(block)
            used += block.count
        }
        return out.joined(separator: "\n\n—\n\n")
    }

    var transcriptCount: Int { TranscriptionHistoryManager.shared.history.filter { $0.fileExists }.count }

    /// Drop cached text for a removed transcript so it can't linger in memory.
    func evict(path: String) { cache.removeValue(forKey: path) }
    func evictAll() { cache.removeAll() }
}

// MARK: - Cross-transcript chat

@MainActor
final class CorpusChat: ObservableObject {
    static let shared = CorpusChat()

    @Published var messages: [ChatMessage] = []
    @Published var isAnswering = false
    private(set) var lastQuestion = ""

    private init() {}

    func reset() { messages = []; lastQuestion = "" }

    func retryLast() {
        guard !isAnswering, !lastQuestion.isEmpty else { return }
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
        let budget = max(2_000, backend.maxPromptChars - 1_800)
        let history = messages.suffix(5).dropLast()
            .map { ($0.isUser ? "User: " : "Assistant: ") + $0.text }
            .joined(separator: "\n")

        Task {
            // Read + chunk the corpus inside the task so file I/O doesn't block the UI.
            let context = TranscriptLibrary.shared.corpusExcerpts(for: q, budget: budget)
            do {
                let answer = try await backend.respond(
                    instructions: """
                    You answer questions across a person's private library of meeting and \
                    voice transcripts. Each excerpt is labeled with its source transcript \
                    title. Base your answer ONLY on the provided excerpts. When you use one, \
                    cite its source title in parentheses, e.g. (from “Team sync”). If the \
                    answer isn't in the excerpts, say you couldn't find it. Be concise. \
                    Answer in the same language as the question.
                    """,
                    prompt: """
                    Excerpts from transcripts:
                    \(context.isEmpty ? "(no transcripts found)" : context)

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
}

// MARK: - Command / search palette (⌘K)

/// A search-first palette reachable from anywhere via ⌘K. Type to search the
/// text of every transcript; press Return (or the top row) to ask the AI across
/// all of them. The single, discoverable entry point to the "second brain".
struct CommandPaletteView: View {
    var onOpenTranscript: (TranscriptionHistoryItem) -> Void
    var onAsk: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [TranscriptLibrary.SearchHit] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search all transcripts, or ask a question…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { if !trimmed.isEmpty { onAsk(trimmed) } }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                        .buttonStyle(.plain)
                        .help("Clear")
                }
                // Explicit close affordance — not everyone reaches for Escape.
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                        .overlay(Circle().strokeBorder(DS.Colors.hairline))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close (esc)")
            }
            .padding(14)
            Divider()

            ScrollView {
                VStack(spacing: 2) {
                    if !trimmed.isEmpty {
                        Button { onAsk(trimmed) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "sparkles").foregroundStyle(DS.Colors.accent).frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Ask AI across all transcripts").font(.system(size: 13, weight: .medium))
                                    Text("“\(trimmed)”").font(.caption).foregroundColor(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text("↩").font(.caption).foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 8).fill(DS.Colors.accent.opacity(0.10)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if !hits.isEmpty {
                            Text("Transcripts").font(.caption2).foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.top, 8)
                        }
                        ForEach(hits) { hit in
                            Button { onOpenTranscript(hit.item) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: hit.item.sourceType?.icon ?? "text.bubble")
                                        .foregroundColor(hit.item.sourceType?.tint ?? DS.Colors.accent).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(hit.item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Text(hit.snippet).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        Text("Type to search every transcript, or ask a question across all of them.")
                            .font(.caption).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 600, height: 460)
        .task(id: query) {
            guard !trimmed.isEmpty else { hits = []; return }
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            hits = Array(TranscriptLibrary.shared.search(trimmed).prefix(20))
        }
        .onAppear { focused = true }
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Ask-everything chat view (sheet)

struct CorpusChatView: View {
    @ObservedObject private var chat = CorpusChat.shared
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""

    private let suggestions = [
        "What action items came up across my recent meetings?",
        "Summarize the key decisions from this week.",
        "What did we say about pricing?"
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ask across all transcripts").font(.headline)
                    Text("^[\(TranscriptLibrary.shared.transcriptCount) transcript](inflect: true) searched")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if !chat.messages.isEmpty {
                    Button("Clear") { chat.reset() }.secondaryGlassButton().controlSize(.small)
                }
                Button("Done") { dismiss() }.secondaryGlassButton().controlSize(.small)
            }
            .padding(14)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if chat.messages.isEmpty {
                            emptyState
                        }
                        ForEach(chat.messages) { msg in
                            bubble(msg).id(msg.id.uuidString)
                        }
                        if chat.isAnswering {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Searching your transcripts…").font(.caption).foregroundColor(.secondary)
                            }
                            .id("thinking")
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: chat.messages.count) { _, _ in
                    withAnimation { proxy.scrollTo(chat.messages.last?.id.uuidString ?? "thinking", anchor: .bottom) }
                }
            }

            Divider()
            HStack(spacing: 8) {
                TextField("Ask about anything you've recorded…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.Colors.hairline, lineWidth: 1))
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                        .foregroundStyle(canSend ? DS.Colors.accent : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain).disabled(!canSend)
            }
            .padding(12)
        }
        .frame(width: 620, height: 560)
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chat.isAnswering
    }

    private func send() {
        guard canSend else { return }
        let q = input
        input = ""
        chat.ask(q)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles.rectangle.stack").foregroundStyle(DS.Colors.accent)
                Text("Ask anything across every transcript you've saved.")
                    .font(.system(size: 14, weight: .medium))
            }
            Text("Answers cite which transcript they came from. Try:")
                .font(.caption).foregroundColor(.secondary)
            ForEach(suggestions, id: \.self) { s in
                Button {
                    input = s; send()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right.circle").font(.caption2)
                        Text(s).font(.caption).multilineTextAlignment(.leading)
                    }
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func bubble(_ msg: ChatMessage) -> some View {
        HStack {
            if msg.isUser { Spacer(minLength: 40) }
            Text(msg.text)
                .font(.system(size: 13))
                .foregroundColor(msg.isError ? .orange : .primary)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(msg.isUser ? DS.Colors.accent.opacity(0.18) : Color.white.opacity(0.05)))
                .frame(maxWidth: 460, alignment: msg.isUser ? .trailing : .leading)
            if !msg.isUser { Spacer(minLength: 40) }
        }
    }
}
