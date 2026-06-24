import SwiftUI
import AppKit

// MARK: - Demo person (so the value is tangible before any real meetings)

extension TranscriptionHistoryItem {
    /// A fabricated history item with a back-dated date — used only to build the
    /// clickable sample person in the empty state.
    init(demoTitle: String, daysAgo: Int) {
        self.id = UUID()
        self.title = demoTitle
        self.filePath = "/dev/null/mindextract-sample"
        self.transcriptionDate = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        self.duration = nil
        self.modelUsed = "sample"
        self.isFavorite = nil
        self.source = TranscriptSource.meeting.rawValue
    }
}

enum PeopleSample {
    @MainActor static func person() -> PersonThread {
        let m1 = TranscriptionHistoryItem(demoTitle: "Pricing & onboarding", daysAgo: 38)
        let m2 = TranscriptionHistoryItem(demoTitle: "Q3 roadmap review", daysAgo: 23)
        let m3 = TranscriptionHistoryItem(demoTitle: "Q3 roadmap review", daysAgo: 9)
        let meetings = [m3, m2, m1]   // newest first
        func item(_ text: String, _ m: TranscriptionHistoryItem, mine: Bool, owner: String?, done: Bool, due: Date? = nil) -> TrackedActionItem {
            TrackedActionItem(key: actionItemKey(m.id, text), text: text, owner: owner, ownedByMe: mine,
                              dueDate: due, dueText: nil, transcriptID: m.id, transcriptTitle: m.title,
                              date: m.transcriptionDate, done: done, completedAt: done ? m.transcriptionDate : nil)
        }
        let soon = Calendar.current.date(byAdding: .day, value: 2, to: Date())
        let items = [
            item("Send the partnership proposal", m1, mine: true, owner: "You", done: false),
            item("Send partnership proposal over", m2, mine: true, owner: "You", done: false), // loose end (recurs)
            item("Share the Q3 budget numbers", m3, mine: false, owner: "Anna", done: false, due: soon),
            item("Book the venue for the offsite", m3, mine: true, owner: "You", done: false),
            item("Confirm the pilot scope", m2, mine: true, owner: "You", done: true),
            item("Intro the design lead", m1, mine: false, owner: "Anna", done: true),
        ]
        let insights = MeetingMemory.computeInsights(name: "Anna Lindqvist", meetings: meetings, items: items)
        let open = items.filter { !$0.done }
        return PersonThread(name: "Anna Lindqvist", meetings: meetings,
                            openItems: open, allItems: items, insights: insights)
    }
}

// MARK: - People & Topics  ("Relationship Memory")
//
// A self-writing memory of everyone you meet — built entirely from recorded
// meetings, zero manual entry, fully on-device. Open a name and instantly recall
// what you discussed, what's still open both ways, how often you meet, and how
// reliably commitments get closed. Descriptive, never a verdict; every insight is
// traceable back to the meeting it came from.

struct PeopleView: View {
    @ObservedObject private var memory = MeetingMemory.shared
    var onOpenTranscript: (TranscriptionHistoryItem) -> Void
    var onGoToRecord: () -> Void = {}

    enum Mode: String, CaseIterable { case people = "People", topics = "Topics" }
    @State private var mode: Mode = .people
    @State private var search = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .frame(maxWidth: 260)
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 12)

                if mode == .people { peopleList } else { topicsList }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear { memory.refreshIfNeeded() }
    }

    private var filteredPeople: [PersonThread] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return memory.people }
        return memory.people.filter {
            $0.name.lowercased().contains(q)
            || $0.meetings.contains { $0.title.lowercased().contains(q) }
        }
    }

    // MARK: People list

    @ViewBuilder
    private var peopleList: some View {
        if memory.people.isEmpty {
            PeopleEmptyState(onGoToRecord: onGoToRecord)
        } else {
            ScrollView {
                VStack(spacing: 14) {
                    // Reconnect strip — gentle nudges, only when there's something to act on.
                    if !memory.reconnectSuggestions.isEmpty {
                        reconnectStrip
                    }
                    VStack(spacing: 8) {
                        ForEach(filteredPeople) { person in
                            NavigationLink {
                                PersonDetail(person: person, onOpenTranscript: onOpenTranscript)
                            } label: { PersonRow(person: person) }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 22)
                .frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
            .searchable(text: $search, placement: .toolbar, prompt: "Search people")
        }
    }

    private var reconnectStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Reconnect", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption.weight(.semibold)).foregroundColor(.secondary)
            ForEach(memory.reconnectSuggestions.prefix(3)) { p in
                NavigationLink {
                    PersonDetail(person: p, onOpenTranscript: onOpenTranscript)
                } label: {
                    HStack(spacing: 10) {
                        AvatarView(initials: p.initials, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).font(.system(size: 13, weight: .medium))
                            Text(reconnectReason(p)).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(DS.Colors.accent.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).strokeBorder(DS.Colors.accent.opacity(0.18)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func reconnectReason(_ p: PersonThread) -> String {
        var bits: [String] = []
        if let d = p.insights.daysSinceLast { bits.append("\(weeksAgo(d)) since you met") }
        if !p.openItems.isEmpty { bits.append("\(p.openItems.count) open") }
        return bits.joined(separator: " · ")
    }

    // MARK: Topics list

    @ViewBuilder
    private var topicsList: some View {
        if memory.topics.isEmpty {
            emptyState(icon: "rectangle.3.group",
                       text: "Topics group recurring meetings (same title across dates) into project threads. They'll appear once you've recorded a meeting more than once.")
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(memory.topics) { topic in
                        NavigationLink {
                            TopicDetail(topic: topic, onOpenTranscript: onOpenTranscript)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "rectangle.3.group.fill")
                                    .foregroundColor(DS.Colors.accent)
                                    .frame(width: 34, height: 34)
                                    .background(Circle().fill(DS.Colors.accent.opacity(0.15)))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(topic.title).font(DS.Typography.rowTitle).lineLimit(1)
                                    Text("\(topic.meetings.count) meetings · last \(relativeDate(topic.lastMet ?? Date()))")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                if !topic.openItems.isEmpty { openBadge(topic.openItems.count) }
                                Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Colors.rowFill))
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Colors.hairline))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 22)
                .frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
        }
    }

    private func openBadge(_ n: Int) -> some View {
        Text("\(n) open").font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.18))).foregroundColor(.orange)
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 38)).foregroundColor(.secondary.opacity(0.5))
            Text(text).font(.callout).foregroundColor(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }
}

// MARK: - Person row

private struct PersonRow: View {
    let person: PersonThread
    var body: some View {
        HStack(spacing: 12) {
            AvatarView(initials: person.initials, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(person.name).font(DS.Typography.rowTitle)
                    if person.insights.overdueToReconnect {
                        Text("Fading").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.16))).foregroundColor(.orange)
                    }
                }
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if !person.openItems.isEmpty {
                Text("\(person.openItems.count) open").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.18))).foregroundColor(.orange)
            }
            Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Colors.rowFill))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Colors.hairline))
        .contentShape(Rectangle())
    }
    private var subtitle: String {
        let n = person.meetings.count
        var s = "\(n) meeting\(n == 1 ? "" : "s")"
        if let last = person.lastMet { s += " · last \(relativeDate(last))" }
        return s
    }
}

// MARK: - Avatar

struct AvatarView: View {
    let initials: String
    var size: CGFloat = 34
    var body: some View {
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(DS.Colors.accent.opacity(0.85)))
    }
}

// MARK: - Person detail

private struct PersonDetail: View {
    let person: PersonThread
    var onOpenTranscript: (TranscriptionHistoryItem) -> Void
    @ObservedObject private var memory = MeetingMemory.shared
    @State private var showPrep = false
    @State private var showStory = false

    private var ins: PersonInsights { person.insights }
    private var youOwe: [TrackedActionItem] { person.openItems.filter { $0.ownedByMe || $0.owner == nil } }
    private var theyOwe: [TrackedActionItem] { person.openItems.filter { !$0.ownedByMe && $0.owner != nil } }
    private var yourTotal: Int { person.allItems.filter { $0.ownedByMe }.count }
    private var yourClosed: Int { person.allItems.filter { $0.ownedByMe && $0.done }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                header
                actionRow
                pulse
                if !ins.looseEnds.isEmpty { looseEndsCallout }
                if !youOwe.isEmpty { commitments("Your turn", systemImage: "person.fill", items: youOwe) }
                if !theyOwe.isEmpty { commitments("Their turn", systemImage: "person.2", items: theyOwe) }
                if !ins.recurringTopics.isEmpty { topicsRow }
                timeline
            }
            .padding(.horizontal, 24).padding(.vertical, 22)
            .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showPrep) {
            PrepSheet(person: person, onOpenTranscript: { m in showPrep = false; onOpenTranscript(m) })
        }
        .sheet(isPresented: $showStory) { StorySheet(person: person) }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button { showPrep = true } label: {
                Label("Prep me", systemImage: "sparkles").font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent).controlSize(.small).tint(DS.Colors.accent)
            Button { showStory = true } label: {
                Label("Our story", systemImage: "book").font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered).controlSize(.small)
            Spacer()
        }
    }

    private var looseEndsCallout: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ins.looseEnds.prefix(3), id: \.self) { le in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.arrow.circlepath").foregroundColor(.orange).font(.caption)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(le.text).font(.caption.weight(.medium))
                        Text("Raised \(le.count)× since \(relativeDate(le.firstSeen)) · still open")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.orange.opacity(0.22)))
    }

    private var header: some View {
        HStack(spacing: 14) {
            AvatarView(initials: person.initials, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(person.name).font(.system(.title2, design: .rounded).weight(.bold))
                HStack(spacing: 14) {
                    stat("\(ins.meetingCount)", "meetings")
                    stat("\(person.openItems.count)", "open")
                    if let last = ins.lastMet {
                        stat(relativeDate(last), "last seen")
                    }
                }
            }
            Spacer()
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded))
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
    }

    // The "Pulse" — calm, descriptive relationship vitals. No verdicts.
    private var pulse: some View {
        HStack(spacing: 10) {
            pulseChip(icon: cadenceIcon, text: cadenceText, tint: ins.overdueToReconnect ? .orange : DS.Colors.accent)
            if yourTotal >= 2 {
                pulseChip(icon: "checkmark.seal", text: "You close \(yourClosed)/\(yourTotal)", tint: .secondary)
            }
            if let age = relationshipAge {
                pulseChip(icon: "calendar", text: age, tint: .secondary)
            }
            Spacer()
        }
    }

    private func pulseChip(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption.weight(.medium))
        }
        .foregroundColor(tint == .secondary ? .secondary : tint)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill((tint == .secondary ? Color.secondary : tint).opacity(0.12)))
    }

    private var cadenceIcon: String { ins.overdueToReconnect ? "wind" : "waveform.path.ecg" }
    private var cadenceText: String {
        if ins.overdueToReconnect, let d = ins.daysSinceLast { return "Fading · \(weeksAgo(d)) since" }
        if let detail = ins.cadenceDetail { return "\(ins.cadenceLabel) · \(detail)" }
        return ins.cadenceLabel
    }
    private var relationshipAge: String? {
        guard let first = ins.firstMet, ins.meetingCount >= 2 else { return nil }
        let months = Calendar.current.dateComponents([.month], from: first, to: Date()).month ?? 0
        if months >= 12 { return "Known \(months/12)y" }
        if months >= 1 { return "Known \(months)mo" }
        return "Met recently"
    }

    private func commitments(_ title: String, systemImage: String, items: [TrackedActionItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage).font(.headline).foregroundColor(.secondary)
            VStack(spacing: 0) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Button { memory.toggle(item) } label: {
                            Image(systemName: "circle").font(.system(size: 15)).foregroundColor(.secondary)
                        }.buttonStyle(.plain).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.text).font(.system(size: 13))
                            Button { onOpenTranscript(meetingFor(item)) } label: {
                                Text(item.transcriptTitle).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                            }.buttonStyle(.plain)
                        }
                        Spacer()
                        if let due = item.dueLabel {
                            Text(due).font(.caption2.weight(.medium))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(item.urgency().tint.opacity(0.16)))
                                .foregroundColor(item.urgency().tint)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    if item.id != items.last?.id { Divider().opacity(0.4) }
                }
            }
            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Colors.rowFill))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Colors.hairline))
        }
    }

    private var topicsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Recurring topics", systemImage: "tag").font(.headline).foregroundColor(.secondary)
            FlowChips(items: ins.recurringTopics, onTap: { _ in })
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Meetings", systemImage: "calendar").font(.headline).foregroundColor(.secondary)
            ForEach(Array(person.meetings.enumerated()), id: \.element.id) { idx, m in
                Button { onOpenTranscript(m) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text").foregroundColor(DS.Colors.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.title).font(DS.Typography.rowTitle).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(m.transcriptionDate.formatted(.dateTime.month(.abbreviated).day().year()))
                                if let gap = gapLabel(idx) {
                                    Text("· \(gap)").foregroundColor(.secondary.opacity(0.7))
                                }
                            }
                            .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Colors.rowFill))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Colors.hairline))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// "3 weeks later" relative to the previous (older) meeting in the list.
    private func gapLabel(_ idx: Int) -> String? {
        guard idx + 1 < person.meetings.count else { return nil }
        let newer = person.meetings[idx].transcriptionDate
        let older = person.meetings[idx + 1].transcriptionDate
        let days = Calendar.current.dateComponents([.day], from: older, to: newer).day ?? 0
        if days <= 0 { return "same day" }
        if days == 1 { return "next day" }
        if days < 14 { return "\(days) days later" }
        return "\(days / 7) weeks later"
    }

    private func meetingFor(_ item: TrackedActionItem) -> TranscriptionHistoryItem {
        person.meetings.first { $0.id == item.transcriptID }
            ?? TranscriptionHistoryManager.shared.history.first { $0.id == item.transcriptID }
            ?? person.meetings[0]
    }
}

// MARK: - Topic detail (simpler — no person insights)

private struct TopicDetail: View {
    let topic: TopicThread
    var onOpenTranscript: (TranscriptionHistoryItem) -> Void
    @ObservedObject private var memory = MeetingMemory.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                HStack(spacing: 14) {
                    Image(systemName: "rectangle.3.group.fill").font(.system(size: 24)).foregroundColor(DS.Colors.accent)
                        .frame(width: 56, height: 56).background(Circle().fill(DS.Colors.accent.opacity(0.15)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(topic.title).font(.system(.title2, design: .rounded).weight(.bold))
                        Text("\(topic.meetings.count) meetings · last \(relativeDate(topic.lastMet ?? Date()))")
                            .font(.callout).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                if !topic.openItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Open commitments", systemImage: "checklist").font(.headline).foregroundColor(.secondary)
                        VStack(spacing: 0) {
                            ForEach(topic.openItems) { item in
                                HStack(alignment: .top, spacing: 10) {
                                    Button { memory.toggle(item) } label: {
                                        Image(systemName: "circle").font(.system(size: 15)).foregroundColor(.secondary)
                                    }.buttonStyle(.plain).padding(.top, 1)
                                    Text(item.text).font(.system(size: 13))
                                    Spacer()
                                }
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                if item.id != topic.openItems.last?.id { Divider().opacity(0.4) }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Colors.rowFill))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Colors.hairline))
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label("Meetings", systemImage: "calendar").font(.headline).foregroundColor(.secondary)
                    ForEach(topic.meetings) { m in
                        Button { onOpenTranscript(m) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.text").foregroundColor(DS.Colors.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.title).font(DS.Typography.rowTitle).lineLimit(1)
                                    Text(m.transcriptionDate.formatted(.dateTime.month(.abbreviated).day().year()))
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Colors.rowFill))
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Colors.hairline))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 22)
            .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Empty state (preview-led, value on day one)

private struct PeopleEmptyState: View {
    var onGoToRecord: () -> Void
    @ObservedObject private var calendar = MeetingCalendar.shared
    @State private var upcomingPeople: [String] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "person.2.fill").font(.system(size: 40)).foregroundColor(DS.Colors.accent.opacity(0.85))
                Text("Your people, remembered for you")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                Text("Everyone you meet gets a thread automatically — your meetings together, what's still open both ways, and the topics that keep coming up. No typing, nothing leaves your Mac.")
                    .font(.callout).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)

                // Clickable sample so the full person view is explorable on day one.
                NavigationLink {
                    PersonDetail(person: PeopleSample.person(), onOpenTranscript: { _ in })
                } label: { sampleCard }
                .buttonStyle(.plain)
                .padding(.top, 4)
                Text("Tap the sample to explore a person")
                    .font(.caption2).foregroundColor(.secondary.opacity(0.7))

                if !upcomingPeople.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("People you'll meet soon", systemImage: "calendar")
                            .font(.caption.weight(.semibold)).foregroundColor(.secondary)
                        FlowChips(items: upcomingPeople, onTap: { _ in })
                        Text("Record any of these meetings and their thread starts building.")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: 420, alignment: .leading)
                }

                Button(action: onGoToRecord) {
                    Label("Record a meeting", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(DS.Colors.accent)
                .padding(.top, 4)
            }
            .padding(40).frame(maxWidth: .infinity)
        }
        .onAppear {
            let events = calendar.upcomingEvents(daysAhead: 7)
            var seen = Set<String>(); var names: [String] = []
            for e in events {
                for n in e.attendees where !n.isEmpty {
                    if seen.insert(n.lowercased()).inserted { names.append(n) }
                }
            }
            upcomingPeople = Array(names.prefix(8))
        }
    }

    private var sampleCard: some View {
        HStack(spacing: 12) {
            AvatarView(initials: "AL", size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Anna Lindqvist").font(DS.Typography.rowTitle)
                    Text("Sample").font(.caption2).foregroundColor(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                Text("3 meetings · last 9 days ago · 4 open").font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: 420)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Colors.rowFill))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Colors.accent.opacity(0.3)))
        .contentShape(Rectangle())
    }
}

// MARK: - Prep Me sheet

private struct PrepSheet: View {
    let person: PersonThread
    var onOpenTranscript: (TranscriptionHistoryItem) -> Void
    @Environment(\.dismiss) private var dismiss

    private var blocks: [(title: String, lines: [String])] { MeetingMemory.prepBrief(for: person) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AvatarView(initials: person.initials, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Prep for \(person.name)").font(.headline)
                    Text("Everything still open, so you walk in ready").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button { copyToClipboard() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).help("Copy")
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(blocks, id: \.title) { block in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(block.title.uppercased()).font(.caption2.weight(.bold)).foregroundColor(.secondary)
                            ForEach(block.lines, id: \.self) { line in
                                HStack(alignment: .top, spacing: 7) {
                                    Circle().fill(DS.Colors.accent.opacity(0.5)).frame(width: 5, height: 5).padding(.top, 6)
                                    Text(line).font(.system(size: 13))
                                }
                            }
                        }
                    }
                    if let last = person.meetings.first {
                        Button { onOpenTranscript(last) } label: {
                            Label("Open last meeting", systemImage: "doc.text").font(.caption.weight(.medium))
                        }.buttonStyle(.bordered).controlSize(.small).padding(.top, 2)
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 460, height: 480)
    }

    private func copyToClipboard() {
        var text = "Prep for \(person.name)\n"
        for b in blocks { text += "\n\(b.title):\n" + b.lines.map { "  • \($0)" }.joined(separator: "\n") + "\n" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Our Story sheet

private struct StorySheet: View {
    let person: PersonThread
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AvatarView(initials: person.initials, size: 34)
                Text("Your story with \(person.name)").font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(MeetingMemory.story(for: person), id: \.self) { para in
                        Text(para).font(.system(size: 15)).lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 460, height: 420)
    }
}

// MARK: - Shared helper

func weeksAgo(_ days: Int) -> String {
    if days < 7 { return "\(days)d" }
    let w = days / 7
    return "\(w)w"
}
