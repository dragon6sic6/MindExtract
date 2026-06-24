import Foundation
import SwiftUI
import AppKit

// MARK: - Recipes (deterministic, on-device post-meeting automation)
//
// A Recipe is a small, fixed bundle of the actions MindExtract already does, run
// in a canonical order — so the repeatable after-meeting ritual becomes one click
// (or fully automatic). Deliberately NOT a workflow engine: a closed set of steps,
// no conditionals, no third-party integrations. Anything that must leave the Mac
// is delegated to the user's own AI via MCP (the "Hand to my AI" step copies a
// ready-to-paste prompt). On-device steps run silently; interactive steps (recap
// draft, export, AI hand-off) only run on a manual run, never on auto.

struct Recipe: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// Built-in template UUID string to shape the output as (nil = just the Brief).
    var formatTemplateID: String?
    var addToReminders: Bool = false
    var draftRecap: Bool = false        // interactive
    var exportMarkdown: Bool = false    // interactive
    var aiHandoff: Bool = false         // interactive (copies a prompt for Claude/ChatGPT)
    var runOnEveryMeeting: Bool = false

    /// A one-line human description of what it does, in run order.
    var summary: String {
        var parts = ["Brief"]
        if let f = formatTemplateID, let t = Self.formatName(f) { parts[0] = t }
        if addToReminders { parts.append("Reminders") }
        if draftRecap { parts.append("recap email") }
        if exportMarkdown { parts.append("export") }
        if aiHandoff { parts.append("hand to AI") }
        return parts.joined(separator: " · ")
    }

    static func formatName(_ id: String) -> String? {
        PromptTemplateLibrary.builtIns.first { $0.id.uuidString == id }?.name
    }
}

@MainActor
final class RecipeStore: ObservableObject {
    static let shared = RecipeStore()
    @Published var recipes: [Recipe] = []

    private let url = recipeFileURL()

    private init() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([Recipe].self, from: data), !decoded.isEmpty {
            recipes = decoded
        } else {
            recipes = Self.defaults
            save()
        }
    }

    func save() {
        let snapshot = recipes
        let url = url
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    func upsert(_ recipe: Recipe) {
        if let i = recipes.firstIndex(where: { $0.id == recipe.id }) { recipes[i] = recipe }
        else { recipes.append(recipe) }
        save()
    }

    func delete(_ recipe: Recipe) { recipes.removeAll { $0.id == recipe.id }; save() }

    var autoRecipes: [Recipe] { recipes.filter { $0.runOnEveryMeeting } }

    // The four shipped defaults (the strategist's recommended set).
    private static let soapID = "11111111-0000-0000-0000-000000000003"
    private static let legalID = "11111111-0000-0000-0000-000000000005"
    static let defaults: [Recipe] = [
        Recipe(name: "Meeting close-out", formatTemplateID: nil,
               addToReminders: true, draftRecap: true),
        Recipe(name: "Clinical session (SOAP)", formatTemplateID: soapID,
               exportMarkdown: true),
        Recipe(name: "Legal intake", formatTemplateID: legalID,
               addToReminders: true, exportMarkdown: true),
        Recipe(name: "File to my stack", formatTemplateID: nil,
               addToReminders: true, aiHandoff: true)
    ]
}

private func recipeFileURL() -> URL {
    let fm = FileManager.default
    let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
        ?? fm.temporaryDirectory
    let dir = base.appendingPathComponent("MindExtract", isDirectory: true)
    if !fm.fileExists(atPath: dir.path) { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
    return dir.appendingPathComponent("recipes.json")
}

// MARK: - Runner

@MainActor
enum RecipeRunner {
    struct Context {
        let transcript: String
        let title: String
        let path: String   // the transcript file path (sidecar + export live next to it)
    }

    /// Run a recipe. `interactive` = a manual run (does recap/export/AI hand-off);
    /// auto runs (on every meeting) do only the silent on-device steps.
    @discardableResult
    static func run(_ recipe: Recipe, on ctx: Context, interactive: Bool) async -> String {
        var done: [String] = []

        // 1. Ensure the Brief exists (the spine of everything downstream).
        var brief = TranscriptAIStore.load(for: ctx.path)?
            .templateOutputs?[PromptTemplateLibrary.meetingBriefID.uuidString]?.text
        if brief == nil, let out = try? await TemplateRunner.produce(PromptTemplateLibrary.meetingBrief, on: ctx.transcript) {
            brief = out.text
            mergeIntoSidecar(ctx.path) {
                var outs = $0.templateOutputs ?? [:]
                outs[PromptTemplateLibrary.meetingBriefID.uuidString] = out
                $0.templateOutputs = outs
            }
            done.append("brief")
        }

        // 2. Shape it as a chosen format (Minutes/SOAP/Legal).
        if let fmtID = recipe.formatTemplateID,
           let template = PromptTemplateLibrary.builtIns.first(where: { $0.id.uuidString == fmtID }),
           let out = try? await TemplateRunner.produce(template, on: ctx.transcript) {
            mergeIntoSidecar(ctx.path) {
                var outs = $0.templateOutputs ?? [:]; outs[fmtID] = out; $0.templateOutputs = outs
            }
            done.append(template.name)
        }

        // 3. Action items → Reminders (local, reversible).
        if recipe.addToReminders, let brief {
            let items = actionItems(from: brief)
            if !items.isEmpty, (try? await RemindersExporter.shared.export(items: items, meetingTitle: ctx.title)) != nil {
                done.append("\(items.count) reminders")
            }
        }

        guard interactive else {
            return done.isEmpty ? "Nothing to do" : "Auto: " + done.joined(separator: ", ")
        }

        // Interactive-only steps (never auto — they open windows / leave the Mac).
        if recipe.draftRecap, let brief {
            openRecapDraft(title: ctx.title, brief: brief); done.append("recap draft")
        }
        if recipe.exportMarkdown, let brief {
            if exportMarkdown(title: ctx.title, brief: brief, near: ctx.path) { done.append("exported") }
        }
        if recipe.aiHandoff, let brief {
            copyAIHandoff(title: ctx.title, brief: brief); done.append("AI prompt copied")
        }
        return done.isEmpty ? "Nothing to do" : done.joined(separator: ", ")
    }

    // MARK: step helpers

    private static func mergeIntoSidecar(_ path: String, _ change: (inout TranscriptAISidecar) -> Void) {
        var sc = TranscriptAIStore.load(for: path)
            ?? TranscriptAISidecar(summary: nil, chat: [], translation: nil, translationLanguageCode: nil,
                                   templateOutputs: nil, userNotes: nil, speakerNames: nil,
                                   speakerSuggestions: nil, markedMoments: nil, commitments: nil)
        change(&sc)
        TranscriptAIStore.save(sc, for: path)
        MeetingMemory.shared.rebuild()
    }

    private static func actionItems(from brief: String) -> [String] {
        let section = MeetingMemory.briefSection(brief, "Action items")
        return MeetingMemory.parseActionItems(section)
    }

    private static func openRecapDraft(title: String, brief: String) {
        let subject = "Recap: \(title)"
        let body = "Hi,\n\nHere's a quick recap of \(title):\n\n\(brief)\n\n— Sent from MindExtract"
        if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [body]) {
            service.subject = subject; service.perform(withItems: [body])
        } else {
            let s = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let b = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "mailto:?subject=\(s)&body=\(b)") { NSWorkspace.shared.open(url) }
        }
    }

    private static func exportMarkdown(title: String, brief: String, near path: String) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        let safe = TranscriptionManager.safeFileBase(title, fallback: "Brief")
        let out = TranscriptionManager.uniqueFilePath(dir: dir, base: "\(safe) — Brief", ext: "md")
        let md = "# \(title)\n\n\(brief)\n"
        guard (try? md.write(toFile: out, atomically: true, encoding: .utf8)) != nil else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: out)])
        return true
    }

    private static func copyAIHandoff(title: String, brief: String) {
        let prompt = """
        Here is my meeting brief from "\(title)". Please file it for me: add the action items to my task tool, and post a short summary where my team will see it. Use my connected tools.

        \(brief)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
    }
}

// MARK: - Editor

struct RecipeEditorSheet: View {
    @State var recipe: Recipe
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = RecipeStore.shared

    private var isExisting: Bool { store.recipes.contains { $0.id == recipe.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isExisting ? "Edit recipe" : "New recipe").font(.headline)
            TextField("Name", text: $recipe.name).textFieldStyle(.roundedBorder)

            Picker("Summarize as", selection: Binding(
                get: { recipe.formatTemplateID ?? "" },
                set: { recipe.formatTemplateID = $0.isEmpty ? nil : $0 })) {
                Text("Brief (default)").tag("")
                ForEach(PromptTemplateLibrary.builtIns) { t in Text(t.name).tag(t.id.uuidString) }
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Add action items to Reminders", isOn: $recipe.addToReminders)
                Toggle("Draft a recap email", isOn: $recipe.draftRecap)
                Toggle("Export the brief as Markdown", isOn: $recipe.exportMarkdown)
                Toggle("Copy a hand-off prompt for my AI", isOn: $recipe.aiHandoff)
            }
            .font(.system(size: 13))
            Text("Recap, export and AI hand-off run only when you run the recipe by hand — never automatically.")
                .font(.caption2).foregroundColor(.secondary)

            Divider()
            Toggle("Run automatically after each meeting", isOn: $recipe.runOnEveryMeeting)
                .font(.system(size: 13))

            HStack {
                if isExisting {
                    Button("Delete", role: .destructive) { store.delete(recipe); dismiss() }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { store.upsert(recipe); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(recipe.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 440)
    }
}
