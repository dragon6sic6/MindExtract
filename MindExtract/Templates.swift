import Foundation
import SwiftUI

// MARK: - Prompt Templates ("Actions")

/// A reusable AI action applied to a transcript — "Meeting Minutes", "SOAP Note",
/// etc. Runs through the user's selected AI backend exactly like the summarizer,
/// so on-device (Apple/Ollama) stays private. Built-ins ship with the app; users
/// can add their own later.
struct PromptTemplate: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String
    var icon: String            // SF Symbol
    var instructions: String    // system prompt (the role)
    var task: String            // how to frame the transcript to the model
    var builtIn: Bool

    init(id: UUID, name: String, icon: String, instructions: String, task: String, builtIn: Bool = true) {
        self.id = id
        self.name = name
        self.icon = icon
        self.instructions = instructions
        self.task = task
        self.builtIn = builtIn
    }
}

/// A finished template result plus the AI backend that produced it, so the
/// provenance survives persistence and provider switches.
struct TemplateOutput: Codable, Equatable {
    var text: String
    var badge: String
}

enum PromptTemplateLibrary {
    /// Special action (not in the picker) — merges the user's live meeting notes
    /// with the transcript. The input passed to it is "notes + transcript".
    static let polishNotes = PromptTemplate(
        id: UUID(uuidString: "11111111-0000-0000-0000-0000000000FF")!,
        name: "Polished Notes", icon: "wand.and.stars",
        instructions: "You turn a person's rough live meeting notes into polished, well-structured notes, using the transcript to fill gaps, correct names/terms and add missed details. Keep the user's intent and structure; never invent facts not supported by the transcript. Answer in the same language as the notes/transcript.",
        task: "Below are the user's rough notes followed by the full transcript. Produce clean, well-structured meeting notes that expand and correct the user's notes using the transcript.")

    /// Stable IDs for the two templates auto-generated after a meeting.
    static let meetingMinutesID = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
    static let actionItemsID    = UUID(uuidString: "11111111-0000-0000-0000-000000000002")!

    /// Fixed UUIDs so persisted outputs keep matching their template across launches.
    static let builtIns: [PromptTemplate] = [
        PromptTemplate(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000001")!,
            name: "Meeting Minutes", icon: "list.clipboard",
            instructions: "You write clear, professional meeting minutes from transcripts. Be factual, never invent content, and answer in the same language as the transcript.",
            task: "Write structured meeting minutes from this transcript. Include: attendees (if identifiable), key discussion points, decisions made, and action items with owners where stated."
        ),
        PromptTemplate(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000002")!,
            name: "Action Items", icon: "checklist",
            instructions: "You extract concrete action items from transcripts. Be precise and never invent tasks. Answer in the same language as the transcript.",
            task: "List every action item, task, or commitment mentioned in this transcript as a checklist. For each, note the owner and any deadline if stated."
        ),
        PromptTemplate(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000003")!,
            name: "SOAP Note", icon: "stethoscope",
            instructions: "You are a clinical documentation assistant. Produce a SOAP note from a clinician–patient conversation. Use only information present in the transcript; never fabricate findings. Answer in the same language as the transcript. This is a drafting aid, not medical advice.",
            task: "Write a SOAP note (Subjective, Objective, Assessment, Plan) from this clinical conversation transcript."
        ),
        PromptTemplate(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000004")!,
            name: "Session Notes (DAP)", icon: "brain.head.profile",
            instructions: "You are a behavioral-health documentation assistant. Produce concise therapy session notes in DAP format (Data, Assessment, Plan). Use only what is in the transcript; never fabricate. Answer in the same language as the transcript. This is a drafting aid, not clinical advice.",
            task: "Write therapy session notes in DAP format (Data, Assessment, Plan) from this session transcript."
        ),
        PromptTemplate(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000005")!,
            name: "Legal Summary", icon: "building.columns",
            instructions: "You summarize legal conversations (intake, depositions, consultations) factually and precisely. Quote key statements verbatim where important. Never invent facts. Answer in the same language as the transcript.",
            task: "Summarize this legal conversation: the parties, the key facts and claims stated, important verbatim quotes, and any next steps or commitments."
        ),
        PromptTemplate(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000006")!,
            name: "Key Quotes", icon: "quote.bubble",
            instructions: "You pull out the most important verbatim quotes from a transcript. Quote exactly; do not paraphrase. Answer in the same language as the transcript.",
            task: "Extract the most important and quotable verbatim statements from this transcript, each with the speaker (if known) and a one-line note on why it matters."
        ),
        PromptTemplate(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000007")!,
            name: "Show Notes", icon: "music.mic",
            instructions: "You write engaging podcast/episode show notes from transcripts. Be accurate and never invent content. Answer in the same language as the transcript.",
            task: "Write podcast show notes from this transcript: a short episode summary, the main topics with rough order, notable quotes, and any names/resources mentioned."
        ),
        PromptTemplate(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000008")!,
            name: "Blog Draft", icon: "doc.text",
            instructions: "You turn spoken content into a well-structured written blog article while preserving the speaker's meaning. Never invent facts beyond the transcript. Answer in the same language as the transcript.",
            task: "Turn this transcript into a clear, readable blog article draft with a title, short intro, sectioned body with headings, and a brief conclusion."
        ),
        PromptTemplate(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000009")!,
            name: "Email Follow-up", icon: "envelope",
            instructions: "You draft concise, professional follow-up emails from meeting transcripts. Never invent commitments. Answer in the same language as the transcript.",
            task: "Draft a concise follow-up email recapping this conversation: what was discussed, decisions, and clear next steps with owners."
        ),
        PromptTemplate(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000010")!,
            name: "FAQ", icon: "questionmark.circle",
            instructions: "You distill transcripts into a clear question-and-answer FAQ. Base every answer only on the transcript. Answer in the same language as the transcript.",
            task: "Create an FAQ from this transcript: the most useful questions a reader might have, each with a concise answer drawn from the content."
        ),
    ]
}

// MARK: - Template store (built-ins + user-authored, persisted to disk)

/// Holds the built-in templates plus any the user creates. User templates are
/// saved as JSON in Application Support (non-secret config, so not Keychain).
@MainActor
final class TemplateStore: ObservableObject {
    static let shared = TemplateStore()

    @Published private(set) var userTemplates: [PromptTemplate] = []

    /// Built-ins first, then the user's own.
    var all: [PromptTemplate] { PromptTemplateLibrary.builtIns + userTemplates }

    /// Curated SF Symbols offered in the editor's icon picker.
    static let iconChoices = [
        "wand.and.stars", "doc.text", "list.clipboard", "checklist", "stethoscope",
        "brain.head.profile", "building.columns", "quote.bubble", "music.mic",
        "envelope", "questionmark.circle", "sparkles", "star", "tag",
        "text.book.closed", "lightbulb", "person.2", "calendar", "flag", "pencil"
    ]

    private init() { load() }

    func template(id: UUID) -> PromptTemplate? { all.first { $0.id == id } }

    func isUserTemplate(_ id: UUID) -> Bool { userTemplates.contains { $0.id == id } }

    func save(_ template: PromptTemplate) {
        if let idx = userTemplates.firstIndex(where: { $0.id == template.id }) {
            userTemplates[idx] = template
        } else {
            userTemplates.append(template)
        }
        persist()
    }

    func delete(id: UUID) {
        userTemplates.removeAll { $0.id == id }
        persist()
    }

    /// Resolved once; creates the directory a single time rather than per access.
    private static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mindact.mindextract", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("templates.json")
    }()

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        do {
            let decoded = try JSONDecoder().decode([PromptTemplate].self, from: data)
            userTemplates = decoded.map { var t = $0; t.builtIn = false; return t }
        } catch {
            // Corrupt file: keep it for manual recovery, don't reset to empty
            // (which would then be persisted over the user's templates).
            appLog("[TemplateStore] Failed to decode templates.json: \(error)")
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(userTemplates)
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            appLog("[TemplateStore] Failed to save templates: \(error)")
        }
    }
}

// MARK: - Template editor

/// Create or edit a user template. Built-ins are not editable (they have no
/// Delete and are opened as a starting point via "Duplicate" only).
struct TemplateEditorView: View {
    @State var template: PromptTemplate
    var title: String = "Template"
    var transcript: String = ""
    let onSave: (PromptTemplate) -> Void
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    @StateObject private var preview = TemplateRunner()

    private var canSave: Bool {
        !template.name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !template.instructions.trimmingCharacters(in: .whitespaces).isEmpty &&
        !template.task.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canPreview: Bool {
        !template.instructions.trimmingCharacters(in: .whitespaces).isEmpty &&
        !template.task.trimmingCharacters(in: .whitespaces).isEmpty &&
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Image(systemName: template.icon.isEmpty ? "wand.and.stars" : template.icon)
                    .font(.system(size: 24))
                    .foregroundStyle(DS.Colors.accent)
                Text(title)
                    .font(.title3).fontWeight(.semibold)
            }
            .padding(.top, 22).padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field("Name") {
                        TextField("e.g. Weekly Standup Notes", text: $template.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    field("Icon") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(TemplateStore.iconChoices, id: \.self) { symbol in
                                    Button {
                                        template.icon = symbol
                                    } label: {
                                        Image(systemName: symbol)
                                            .font(.system(size: 15))
                                            .frame(width: 34, height: 34)
                                            .background(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .fill(template.icon == symbol ? DS.Colors.accent.opacity(0.25) : Color.white.opacity(0.05))
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .strokeBorder(template.icon == symbol ? DS.Colors.accent : Color.clear, lineWidth: 1)
                                            )
                                            .foregroundColor(template.icon == symbol ? .white : .secondary)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    field("Instructions", hint: "How the AI should behave and what role it plays. Tip: end with “answer in the same language as the transcript.”") {
                        editor($template.instructions, minHeight: 70)
                    }

                    field("What to generate", hint: "What to produce from the transcript — the transcript text is added automatically after this line.") {
                        editor($template.task, minHeight: 70)
                    }

                    previewSection
                }
                .padding(20)
            }
            .frame(height: 380)

            Divider()

            HStack(spacing: 10) {
                if let onDelete {
                    Button(role: .destructive) { onDelete() } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .secondaryGlassButton()
                    .controlSize(.large)
                }
                Button("Cancel", action: onCancel)
                    .secondaryGlassButton()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                Button {
                    onSave(template)
                } label: {
                    Label("Save", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .primaryGlassButton()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .frame(maxWidth: .infinity)
                .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 480)
    }

    @ViewBuilder
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preview").font(.system(size: 13, weight: .semibold))
                Spacer()
                if case .working = preview.state {
                    Button("Cancel") { preview.cancel() }
                        .secondaryGlassButton()
                        .controlSize(.small)
                } else {
                    Button { runPreview() } label: {
                        Label("Run on this transcript", systemImage: "play.fill")
                    }
                    .secondaryGlassButton()
                    .controlSize(.small)
                    .disabled(!canPreview)
                }
            }
            switch preview.state {
            case .idle:
                Text(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "Open a transcript to preview this template."
                     : "Run to see the result on the current transcript before saving.")
                    .font(.caption).foregroundColor(.secondary)
            case .working(let m):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(m).font(.caption).foregroundColor(.secondary)
                }
            case .done(let output):
                ScrollView {
                    Text(output)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.Colors.inputStroke, lineWidth: 1))
            case .failed(let m):
                Text(m).font(.caption).foregroundColor(.orange)
            }
        }
    }

    private func runPreview() {
        let draft = PromptTemplate(
            id: template.id,
            name: template.name.isEmpty ? "Preview" : template.name,
            icon: template.icon,
            instructions: template.instructions,
            task: template.task,
            builtIn: false
        )
        preview.run(draft, on: transcript)
    }

    @ViewBuilder
    private func field<Content: View>(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
            if let hint {
                Text(hint).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func editor(_ text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.system(size: 13))
            .frame(minHeight: minHeight)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.Colors.inputStroke, lineWidth: 1))
            .scrollContentBackground(.hidden)
    }
}

// MARK: - Template runner (routed through the selected AI backend)

/// Runs a PromptTemplate against a transcript. Mirrors `TranscriptSummarizer`:
/// single-pass when it fits the backend's context, otherwise map-reduce so long
/// transcripts work on every model (including small on-device ones).
@MainActor
final class TemplateRunner: ObservableObject {
    static let shared = TemplateRunner()

    enum State: Equatable {
        case idle
        case working(String)
        case done(String)
        case failed(String)
    }

    @Published var state: State = .idle
    /// Backend that actually produced the current result (captured at completion).
    @Published private(set) var resultBadge: String = ""
    /// Which template the current state belongs to (the view scopes display to it).
    @Published private(set) var activeTemplateID: UUID?

    private var task: Task<Void, Never>?
    /// Identifies the in-flight run so a stale completion (after the user
    /// switched template/transcript or cancelled) can't overwrite current state.
    private var currentRunID: UUID?

    /// `shared` drives the Notes tab; the editor creates its own instance for an
    /// isolated live preview, so init is not private.
    init() {}

    func run(_ template: PromptTemplate, on text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        task?.cancel()
        let backend = AIBackends.current()
        let badge = backend.badge
        let runID = UUID()
        currentRunID = runID
        activeTemplateID = template.id
        state = .working("Generating \(template.name)…")
        task = Task {
            do {
                let output = try await Self.generate(template, text: trimmed, backend: backend) { [weak self] progress in
                    await MainActor.run { if self?.currentRunID == runID { self?.state = .working(progress) } }
                }
                guard !Task.isCancelled, self.currentRunID == runID else { return }
                self.resultBadge = badge
                self.state = .done(output)
            } catch {
                guard !Task.isCancelled, self.currentRunID == runID else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        currentRunID = nil
        state = .idle
        activeTemplateID = nil
        resultBadge = ""
    }

    func reset() {
        task?.cancel()
        task = nil
        currentRunID = nil
        state = .idle
        activeTemplateID = nil
        resultBadge = ""
    }

    /// One-shot generation that does NOT touch the shared runner's UI state —
    /// used to auto-generate meeting notes in the background after a recording.
    @MainActor
    static func produce(_ template: PromptTemplate, on text: String) async throws -> TemplateOutput {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CancellationError() }
        let backend = AIBackends.current()
        let output = try await generate(template, text: trimmed, backend: backend) { _ in }
        return TemplateOutput(text: output, badge: backend.badge)
    }

    private static func generate(
        _ template: PromptTemplate,
        text: String,
        backend: AIBackend,
        progress: @escaping (String) async -> Void
    ) async throws -> String {
        let chunkSize = max(4_000, backend.maxPromptChars - 1_000)

        if text.count <= chunkSize {
            let result = try await backend.respond(
                instructions: template.instructions,
                prompt: "\(template.task)\n\n\(text)"
            )
            try Task.checkCancellation()
            return result
        }

        // Map: apply the template to each chunk; Reduce: merge into one result.
        let chunks = TranscriptSummarizer.split(text, size: chunkSize)
        var partials: [String] = []
        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            await progress("Processing part \(i + 1) of \(chunks.count)…")
            let part = try await backend.respond(
                instructions: template.instructions,
                prompt: "\(template.task)\n\nThis is part \(i + 1) of \(chunks.count) of a longer transcript:\n\n\(chunk)"
            )
            partials.append(part)
        }
        await progress("Finishing…")
        let combined = partials.enumerated()
            .map { "Part \($0.offset + 1):\n\($0.element)" }
            .joined(separator: "\n\n")
        return try await backend.respond(
            instructions: template.instructions,
            prompt: "Combine these partial results into one coherent final result for the task: \(template.task)\n\n\(combined)"
        )
    }
}
