import Foundation
import SwiftUI

// MARK: - Meeting Memory
//
// The "daily love" layer. Meetings aren't isolated files — they're episodes in
// ongoing relationships (people) and recurring threads (topics/projects), and
// each one leaves commitments behind. This aggregates everything we already have
// on disk (transcript history + the per-transcript AI sidecars) into:
//
//   • Structured commitments across ALL meetings — task + owner + due date, split
//     into "mine" vs "waiting on others", grouped by urgency
//   • People — every person you've met, threaded with their meetings + open items
//   • Topics — recurring meeting titles, threaded the same way ("projects")
//
// Commitments are parsed STRUCTURALLY from the Meeting Brief's "## Action items"
// section (the prompt enforces "- Owner — task (due if stated)"), not by scraping
// arbitrary nested markdown — so we get clean data, never "Owner: No owner
// mentioned" noise. Everything is on-device: it only reads files we already wrote.

/// Stable identity for a commitment across rebuilds: its transcript + its task.
func actionItemKey(_ transcriptID: UUID, _ text: String) -> String {
    transcriptID.uuidString + "|" + text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Persisted structured commitment (lives in the transcript's AI sidecar)

/// A commitment as parsed once from the brief and then owned by the user (they can
/// edit text or delete a bad one). Cached in the sidecar so parsing + edits persist.
struct MeetingCommitment: Codable, Hashable {
    var task: String
    var owner: String?       // nil when unassigned / "no owner"
    var dueISO: String?      // resolved yyyy-MM-dd, when we could parse a date
    var dueText: String?     // original phrase ("next Friday") when unresolved
    var deleted: Bool?       // user removed a bad extraction
}

// MARK: - In-memory commitment (what the UI renders)

struct TrackedActionItem: Identifiable, Hashable {
    let key: String
    var id: String { key }
    let text: String
    let owner: String?
    let ownedByMe: Bool
    let dueDate: Date?
    let dueText: String?
    let transcriptID: UUID
    let transcriptTitle: String
    let date: Date           // the meeting's date
    var done: Bool
    var completedAt: Date?

    enum Urgency: Int, Comparable {
        case overdue, today, week, later, none
        static func < (l: Urgency, r: Urgency) -> Bool { l.rawValue < r.rawValue }
        var label: String {
            switch self {
            case .overdue: return "Overdue"
            case .today: return "Due today"
            case .week: return "This week"
            case .later: return "Later"
            case .none: return "No date"
            }
        }
        var tint: Color {
            switch self {
            case .overdue: return .red
            case .today: return .orange
            case .week: return .yellow
            case .later: return .secondary
            case .none: return .secondary
            }
        }
    }

    func urgency(now: Date = Date()) -> Urgency {
        guard let due = dueDate else { return .none }
        let cal = Calendar.current
        let startToday = cal.startOfDay(for: now)
        let startDue = cal.startOfDay(for: due)
        if startDue < startToday { return .overdue }
        if startDue == startToday { return .today }
        if let weekEnd = cal.date(byAdding: .day, value: 7, to: startToday), startDue <= weekEnd { return .week }
        return .later
    }

    /// A short human due string for the row ("Today", "Fri", "Jun 25", or the raw phrase).
    var dueLabel: String? {
        if let due = dueDate {
            let cal = Calendar.current
            if cal.isDateInToday(due) { return "Today" }
            if cal.isDateInTomorrow(due) { return "Tomorrow" }
            if let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: due)).day,
               days > 0 && days < 7 {
                return due.formatted(.dateTime.weekday(.abbreviated))
            }
            return due.formatted(.dateTime.month(.abbreviated).day())
        }
        return dueText
    }
}

/// Everything we know about meetings with one person.
struct PersonThread: Identifiable, Hashable {
    let name: String
    var id: String { name.lowercased() }
    let meetings: [TranscriptionHistoryItem]   // newest first
    let openItems: [TrackedActionItem]
    var lastMet: Date? { meetings.first?.transcriptionDate }
    static func == (l: PersonThread, r: PersonThread) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    var initials: String {
        let parts = name.split(separator: " ")
        let first = parts.first?.first.map(String.init) ?? ""
        let last = parts.count > 1 ? (parts.last?.first.map(String.init) ?? "") : ""
        return (first + last).uppercased()
    }
}

/// A recurring meeting title clustered across dates — a pragmatic "project" view.
struct TopicThread: Identifiable, Hashable {
    let key: String
    var id: String { key }
    let title: String
    let meetings: [TranscriptionHistoryItem]   // newest first
    let openItems: [TrackedActionItem]
    var lastMet: Date? { meetings.first?.transcriptionDate }
    static func == (l: TopicThread, r: TopicThread) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Completion state (persisted)

/// Remembers which commitments the user has checked off, keyed by `actionItemKey`.
@MainActor
final class ActionItemStateStore {
    static let shared = ActionItemStateStore()

    private var completed: [String: Date] = [:]
    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "com.mindact.mindextract.actionitems")

    private init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("MindExtract", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        fileURL = dir.appendingPathComponent("actionItemState.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            completed = decoded
        }
    }

    func isDone(_ key: String) -> Bool { completed[key] != nil }
    func completedAt(_ key: String) -> Date? { completed[key] }

    func set(_ key: String, done: Bool) {
        if done { completed[key] = Date() } else { completed.removeValue(forKey: key) }
        let snapshot = completed
        ioQueue.async { [fileURL] in
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}

// MARK: - Aggregator

@MainActor
final class MeetingMemory: ObservableObject {
    static let shared = MeetingMemory()

    @Published private(set) var openActionItems: [TrackedActionItem] = []
    @Published private(set) var doneActionItems: [TrackedActionItem] = []
    @Published private(set) var people: [PersonThread] = []
    @Published private(set) var topics: [TopicThread] = []
    @Published private(set) var recentMeetings: [TranscriptionHistoryItem] = []

    private var lastSignature: Int = -1

    private init() {}

    func refreshIfNeeded() {
        let history = TranscriptionHistoryManager.shared.history
        let sig = history.reduce(into: Hasher()) { h, item in
            h.combine(item.id); h.combine(item.title)
        }.finalize() ^ Self.identitySignature()
        guard sig != lastSignature else { return }
        rebuild()
    }

    /// Changes when "who am I" changes, so ownership re-evaluates without a title bump.
    private static func identitySignature() -> Int {
        var h = Hasher()
        h.combine(AppSettings.shared.myName)
        h.combine(AppSettings.shared.myEmail)
        return h.finalize()
    }

    func rebuild() {
        let history = TranscriptionHistoryManager.shared.history
        lastSignature = history.reduce(into: Hasher()) { h, item in
            h.combine(item.id); h.combine(item.title)
        }.finalize() ^ Self.identitySignature()

        let me = MeetingMemory.myTokens()
        var allItems: [TrackedActionItem] = []
        var personMeetings: [String: (display: String, items: [TranscriptionHistoryItem])] = [:]
        var topicMeetings: [String: (title: String, items: [TranscriptionHistoryItem])] = [:]
        var recents: [TranscriptionHistoryItem] = []
        var renames: [(TranscriptionHistoryItem, String)] = []

        let sorted = history.sorted { $0.transcriptionDate > $1.transcriptionDate }

        for h in sorted {
            let isMeeting = h.sourceType == .meeting || h.sourceType == nil
            guard isMeeting, h.fileExists else { continue }
            guard var sidecar = TranscriptAIStore.load(for: h.filePath) else { continue }

            // Auto-name generic "Meeting 2026-06-22 15.30" titles from the brief, so
            // People/Topics cluster and the UI reads cleanly. Applied after the loop.
            if Self.isGenericTitle(h.title),
               let brief = sidecar.templateOutputs?[PromptTemplateLibrary.meetingBriefID.uuidString]?.text,
               let better = Self.suggestedTitle(fromBrief: brief) {
                renames.append((h, better))
            }

            // Commitments — use cached structured ones, else derive from the brief once.
            let commitments = Self.commitments(for: h, sidecar: &sidecar)

            for c in commitments where !(c.deleted ?? false) {
                let key = actionItemKey(h.id, c.task)
                let ownedByMe = Self.isMine(owner: c.owner, me: me)
                allItems.append(TrackedActionItem(
                    key: key, text: c.task, owner: c.owner, ownedByMe: ownedByMe,
                    dueDate: c.dueISO.flatMap(Self.dateFromISO), dueText: c.dueText,
                    transcriptID: h.id, transcriptTitle: h.title, date: h.transcriptionDate,
                    done: ActionItemStateStore.shared.isDone(key),
                    completedAt: ActionItemStateStore.shared.completedAt(key)))
            }

            for name in Self.peopleNames(sidecar) {
                let id = name.lowercased()
                if personMeetings[id] == nil { personMeetings[id] = (name, []) }
                personMeetings[id]?.items.append(h)
            }

            let tkey = Self.topicKey(h.title)
            if !tkey.isEmpty {
                if topicMeetings[tkey] == nil { topicMeetings[tkey] = (h.title, []) }
                topicMeetings[tkey]?.items.append(h)
            }

            if recents.count < 6,
               sidecar.templateOutputs?[PromptTemplateLibrary.meetingBriefID.uuidString] != nil
                || sidecar.summary?.isEmpty == false {
                recents.append(h)
            }
        }

        let open = allItems.filter { !$0.done }.sorted(by: Self.byUrgencyThenDate)
        let done = allItems.filter { $0.done }.sorted { ($0.completedAt ?? $0.date) > ($1.completedAt ?? $1.date) }
        openActionItems = open
        doneActionItems = done

        let openByTranscript = Dictionary(grouping: open, by: { $0.transcriptID })

        people = personMeetings.values.map { entry in
            let ids = Set(entry.items.map(\.id))
            let items = ids.flatMap { openByTranscript[$0] ?? [] }.sorted(by: Self.byUrgencyThenDate)
            return PersonThread(name: entry.display, meetings: entry.items, openItems: items)
        }
        .sorted { ($0.lastMet ?? .distantPast) > ($1.lastMet ?? .distantPast) }

        topics = topicMeetings.values
            .filter { $0.items.count >= 2 }
            .map { entry in
                let ids = Set(entry.items.map(\.id))
                let items = ids.flatMap { openByTranscript[$0] ?? [] }.sorted(by: Self.byUrgencyThenDate)
                return TopicThread(key: Self.topicKey(entry.title), title: entry.title,
                                   meetings: entry.items, openItems: items)
            }
            .sorted { ($0.lastMet ?? .distantPast) > ($1.lastMet ?? .distantPast) }

        recentMeetings = recents

        // Apply auto-renames last (mutating history triggers one extra rebuild that
        // then finds no generic titles — converges immediately).
        for (item, title) in renames {
            TranscriptionHistoryManager.shared.rename(item, to: title)
        }
    }

    // MARK: Auto-naming

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
        // First sentence.
        let sentence = line.components(separatedBy: CharacterSet(charactersIn: ".!?")).first ?? line
        var words = sentence.split(separator: " ").prefix(6).map(String.init)
        // Trim trailing connectors so titles don't end on "with"/"the".
        let stop: Set<String> = ["the","a","an","with","for","to","and","of","in","on","at","by","that","this","our"]
        while let last = words.last?.lowercased(), stop.contains(last) { words.removeLast() }
        let cleaned = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;:—–-"))
        guard cleaned.count >= 3 else { return nil }
        return cleaned
    }

    /// Sort: most urgent first; within a bucket, earliest due / newest meeting.
    private static func byUrgencyThenDate(_ a: TrackedActionItem, _ b: TrackedActionItem) -> Bool {
        let ua = a.urgency(), ub = b.urgency()
        if ua != ub { return ua < ub }
        if let da = a.dueDate, let db = b.dueDate, da != db { return da < db }
        if a.dueDate != nil && b.dueDate == nil { return true }
        if a.dueDate == nil && b.dueDate != nil { return false }
        return a.date > b.date
    }

    // MARK: Mine vs theirs (computed views over openActionItems)

    var myOpenItems: [TrackedActionItem] { openActionItems.filter { $0.ownedByMe || $0.owner == nil } }
    var waitingOnItems: [TrackedActionItem] { openActionItems.filter { !$0.ownedByMe && $0.owner != nil } }

    func toggle(_ item: TrackedActionItem) {
        let nowDone = !item.done
        ActionItemStateStore.shared.set(item.key, done: nowDone)
        let merged = (openActionItems + doneActionItems).map { i -> TrackedActionItem in
            guard i.key == item.key else { return i }
            var c = i; c.done = nowDone; c.completedAt = nowDone ? Date() : nil; return c
        }
        openActionItems = merged.filter { !$0.done }.sorted(by: Self.byUrgencyThenDate)
        doneActionItems = merged.filter { $0.done }.sorted { ($0.completedAt ?? $0.date) > ($1.completedAt ?? $1.date) }
        rebuildPeopleTopicOpenLists()
    }

    /// Permanently remove a bad extraction (persists `deleted` in the sidecar).
    func delete(_ item: TrackedActionItem) {
        guard let h = TranscriptionHistoryManager.shared.history.first(where: { $0.id == item.transcriptID }),
              var sidecar = TranscriptAIStore.load(for: h.filePath) else { return }
        var list = sidecar.commitments ?? []
        if let idx = list.firstIndex(where: { actionItemKey(item.transcriptID, $0.task) == item.key }) {
            list[idx].deleted = true
        }
        sidecar.commitments = list
        TranscriptAIStore.save(sidecar, for: h.filePath)
        ActionItemStateStore.shared.set(item.key, done: false)
        rebuild()
    }

    /// Edit the task text (persists; completion + identity re-key off the new text).
    func edit(_ item: TrackedActionItem, to newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.text,
              let h = TranscriptionHistoryManager.shared.history.first(where: { $0.id == item.transcriptID }),
              var sidecar = TranscriptAIStore.load(for: h.filePath) else { return }
        var list = sidecar.commitments ?? []
        if let idx = list.firstIndex(where: { actionItemKey(item.transcriptID, $0.task) == item.key }) {
            list[idx].task = trimmed
        }
        sidecar.commitments = list
        TranscriptAIStore.save(sidecar, for: h.filePath)
        if item.done {  // carry completion to the new key
            ActionItemStateStore.shared.set(item.key, done: false)
            ActionItemStateStore.shared.set(actionItemKey(item.transcriptID, trimmed), done: true)
        }
        rebuild()
    }

    private func rebuildPeopleTopicOpenLists() {
        let openByTranscript = Dictionary(grouping: openActionItems, by: { $0.transcriptID })
        people = people.map { p in
            let ids = Set(p.meetings.map(\.id))
            let items = ids.flatMap { openByTranscript[$0] ?? [] }.sorted(by: Self.byUrgencyThenDate)
            return PersonThread(name: p.name, meetings: p.meetings, openItems: items)
        }
        topics = topics.map { t in
            let ids = Set(t.meetings.map(\.id))
            let items = ids.flatMap { openByTranscript[$0] ?? [] }.sorted(by: Self.byUrgencyThenDate)
            return TopicThread(key: t.key, title: t.title, meetings: t.meetings, openItems: items)
        }
    }

    // MARK: Pre-meeting prep

    func prep(forAttendees names: [String]) -> (meetings: [TranscriptionHistoryItem], openItems: [TrackedActionItem]) {
        let wanted = Set(names.flatMap { Self.matchTokens($0) }).subtracting(["you"])
        guard !wanted.isEmpty else { return ([], []) }
        let matched = people.filter { !Self.matchTokens($0.name).isDisjoint(with: wanted) }
        var seen = Set<UUID>()
        var meetings: [TranscriptionHistoryItem] = []
        for m in matched.flatMap(\.meetings).sorted(by: { $0.transcriptionDate > $1.transcriptionDate }) {
            if seen.insert(m.id).inserted { meetings.append(m) }
        }
        let mIds = Set(meetings.map(\.id))
        let items = openActionItems.filter { mIds.contains($0.transcriptID) }
        return (Array(meetings.prefix(5)), items)
    }

    // MARK: - Commitment sourcing (brief → structured, cached in sidecar)

    /// Returns the structured commitments for a meeting, deriving + caching them
    /// from the brief on first access (and whenever the brief changed).
    private static func commitments(for h: TranscriptionHistoryItem, sidecar: inout TranscriptAISidecar) -> [MeetingCommitment] {
        let briefText = sidecar.templateOutputs?[PromptTemplateLibrary.meetingBriefID.uuidString]?.text
        // Re-derive if we have none cached, or if there's a brief but the cache is empty
        // and not user-emptied (all-deleted is fine to keep).
        if let cached = sidecar.commitments, !cached.isEmpty {
            return cached
        }
        guard let brief = briefText else { return sidecar.commitments ?? [] }
        let derived = deriveCommitments(fromBrief: brief, meetingDate: h.transcriptionDate)
        if !derived.isEmpty {
            sidecar.commitments = derived
            TranscriptAIStore.save(sidecar, for: h.filePath)
        }
        return derived
    }

    /// Parse the "## Action items" section of a brief into structured commitments.
    static func deriveCommitments(fromBrief brief: String, meetingDate: Date) -> [MeetingCommitment] {
        let section = briefSection(brief, "Action items")
        guard !section.isEmpty else { return [] }
        var out: [MeetingCommitment] = []
        var seen = Set<String>()
        for raw in section.components(separatedBy: .newlines) {
            guard let parsed = parseCommitmentLine(raw) else { continue }
            let normalized = parsed.task.lowercased()
            guard seen.insert(normalized).inserted else { continue }   // dedupe within a meeting
            let resolved = resolveDue(parsed.dueText, relativeTo: meetingDate)
            out.append(MeetingCommitment(
                task: parsed.task, owner: parsed.owner,
                dueISO: resolved.map(isoFromDate), dueText: resolved == nil ? parsed.dueText : nil,
                deleted: false))
        }
        return out
    }

    /// Parse one brief action-item line ("- Anna — Send the spec (due Friday)") into
    /// owner / task / due. Returns nil for non-tasks ("- None").
    static func parseCommitmentLine(_ raw: String) -> (owner: String?, task: String, dueText: String?)? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        // Require a list marker — prose lines ("Here are the next steps:") aren't tasks.
        var hadMarker = false
        let markers = ["- [ ]", "- [x]", "* [ ]", "☐", "□", "•", "-", "*", "·"]
        for m in markers where s.hasPrefix(m) {
            s = String(s.dropFirst(m.count)).trimmingCharacters(in: .whitespaces); hadMarker = true; break
        }
        if let r = s.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
            s = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces); hadMarker = true
        }
        guard hadMarker else { return nil }
        s = s.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s.hasPrefix("#") { return nil }
        let low = s.lowercased()
        if low == "none" || low == "n/a" || low.hasPrefix("none ") { return nil }

        // Trailing "(due …)" / "(by …)" parenthetical.
        var dueText: String? = nil
        if let r = s.range(of: #"\(([^)]*)\)\s*$"#, options: .regularExpression) {
            let inner = String(s[r]).trimmingCharacters(in: CharacterSet(charactersIn: "() ")).trimmingCharacters(in: .whitespaces)
            let il = inner.lowercased()
            if il.contains("due") || il.contains("by ") || il.hasPrefix("by") || il.contains("deadline")
                || il.range(of: #"\d"#, options: .regularExpression) != nil
                || Self.weekdayIndex(il) != nil || il.contains("tomorrow") || il.contains("today") {
                dueText = inner
                    .replacingOccurrences(of: "due ", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: "by ", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: "deadline:", with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: .whitespaces)
                s.removeSubrange(r)
                s = s.trimmingCharacters(in: .whitespaces)
            }
        }

        // Owner — task. Owner only if the lead segment is short (a name, not a sentence).
        var owner: String? = nil
        for sep in [" — ", " – ", " -- ", " - "] {
            if let r = s.range(of: sep) {
                let lead = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let rest = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !lead.isEmpty, !rest.isEmpty, lead.split(separator: " ").count <= 4 {
                    owner = lead; s = rest
                }
                break
            }
        }
        if let o = owner, Self.isNoOwner(o) { owner = nil }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " .—–-"))
        guard s.count > 2 else { return nil }
        return (owner, s, dueText?.isEmpty == true ? nil : dueText)
    }

    private static func isNoOwner(_ owner: String) -> Bool {
        let o = owner.lowercased()
        return o.contains("no owner") || o.contains("unassigned") || o == "team"
            || o == "tbd" || o.contains("not assigned") || o.contains("ingen ägare") || o.contains("okänd")
    }

    // MARK: Ownership ("who am I")

    static func myTokens() -> Set<String> {
        var set = Set<String>()
        set.formUnion(matchTokens(AppSettings.shared.myName))
        let email = AppSettings.shared.myEmail.lowercased()
        if let local = email.split(separator: "@").first { set.formUnion(matchTokens(String(local))) }
        return set.subtracting(["you"])
    }

    static func isMine(owner: String?, me: Set<String>) -> Bool {
        guard let owner = owner else { return false }
        let o = owner.lowercased().trimmingCharacters(in: .whitespaces)
        if ["me", "i", "myself", "jag", "mig"].contains(o) { return true }
        if o == "you" { return true }   // the recorder labels the local speaker "You"
        guard !me.isEmpty else { return false }
        return !matchTokens(owner).isDisjoint(with: me)
    }

    // MARK: Due-date resolution

    static func resolveDue(_ text: String?, relativeTo base: Date) -> Date? {
        guard let raw = text?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let s = raw.lowercased()
        let cal = Calendar.current
        // ISO date anywhere in the string.
        if let m = s.range(of: #"\d{4}[-/]\d{1,2}[-/]\d{1,2}"#, options: .regularExpression) {
            let iso = s[m].replacingOccurrences(of: "/", with: "-")
            if let d = dateFromISO(iso) { return d }
        }
        if s.contains("today") || s.contains("idag") { return cal.startOfDay(for: base) }
        if s.contains("tomorrow") || s.contains("imorgon") || s.contains("i morgon") {
            return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: base))
        }
        if s.contains("end of week") || s.contains("eow") || s.contains("veckans slut") {
            return nextWeekday(5, after: base)   // Friday
        }
        if let wd = weekdayIndex(s) { return nextWeekday(wd, after: base) }
        return nil
    }

    /// Next occurrence of an ISO weekday (1=Mon…7=Sun) on/after the day after `base`.
    private static func nextWeekday(_ isoWeekday: Int, after base: Date) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let start = cal.startOfDay(for: base)
        // Convert ISO (1=Mon) to Gregorian weekday (1=Sun).
        let target = isoWeekday == 7 ? 1 : isoWeekday + 1
        for offset in 1...7 {
            if let d = cal.date(byAdding: .day, value: offset, to: start),
               cal.component(.weekday, from: d) == target { return d }
        }
        return nil
    }

    /// Returns ISO weekday (1=Mon…7=Sun) if the string names a weekday (en + sv).
    static func weekdayIndex(_ s: String) -> Int? {
        let map: [(String, Int)] = [
            ("monday",1),("måndag",1),("mon ",1),
            ("tuesday",2),("tisdag",2),("tue",2),
            ("wednesday",3),("onsdag",3),("wed",3),
            ("thursday",4),("torsdag",4),("thu",4),
            ("friday",5),("fredag",5),("fri",5),
            ("saturday",6),("lördag",6),("sat",6),
            ("sunday",7),("söndag",7),("sun",7)
        ]
        for (k, v) in map where s.contains(k) { return v }
        return nil
    }

    static func dateFromISO(_ iso: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: iso.trimmingCharacters(in: .whitespaces))
    }
    static func isoFromDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    // MARK: People / topic parsing

    private static func matchTokens(_ name: String) -> Set<String> {
        Set(name.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count > 1 })
    }

    private static let defaultSpeakerLabels: Set<String> = ["you", "others", "unknown", "speaker", "guest"]

    private static func isDefaultLabel(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty { return true }
        if defaultSpeakerLabels.contains(t) { return true }
        if t.range(of: #"^speaker\s*\d+$"#, options: .regularExpression) != nil { return true }
        return false
    }

    private static func peopleNames(_ sidecar: TranscriptAISidecar) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            let n = raw.trimmingCharacters(in: .whitespaces)
            guard !isDefaultLabel(n) else { return }
            let k = n.lowercased()
            if seen.insert(k).inserted { names.append(n) }
        }
        (sidecar.speakerSuggestions ?? []).forEach(add)
        (sidecar.speakerNames ?? [:]).values.forEach(add)
        return names
    }

    private static let actionItemsAliases: Set<String> = [
        "action items", "åtgärdspunkter", "aktionspunkter", "att göra",
        "action points", "maßnahmen", "aufgaben", "tâches", "points d'action",
        "acciones", "tareas", "azioni", "punti d'azione"
    ]

    static func briefSection(_ text: String, _ header: String) -> String {
        var out: [String] = []
        var inSection = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                let h = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                let isMatch = h.caseInsensitiveCompare(header) == .orderedSame
                    || (header == "Action items" && actionItemsAliases.contains(h.lowercased()))
                inSection = isMatch
                continue
            }
            if inSection { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    /// Bullet/numbered list items, markers stripped (used only by tests / legacy).
    static func parseActionItems(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).compactMap { parseCommitmentLine($0)?.task }
    }

    /// Normalizes a meeting title into a clustering key.
    static func topicKey(_ title: String) -> String {
        var s = title.lowercased()
        s = s.replacingOccurrences(of: #"\b\d{4}[-/]\d{1,2}[-/]\d{1,2}\b"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b\d{1,2}[:.]\d{2}\b"#, with: "", options: .regularExpression)
        let calWords = ["monday","tuesday","wednesday","thursday","friday","saturday","sunday",
                        "måndag","tisdag","onsdag","torsdag","fredag","lördag","söndag",
                        "january","february","march","april","may","june","july","august",
                        "september","october","november","december",
                        "januari","februari","mars","april","maj","juni","juli","augusti","oktober"]
        var tokens = s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        tokens = tokens.filter { tok in
            if calWords.contains(tok) { return false }
            if tok.allSatisfy(\.isNumber) { return false }
            return tok.count > 1
        }
        return tokens.joined(separator: " ")
    }
}
