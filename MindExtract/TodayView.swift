import SwiftUI
import AppKit

private typealias CalEvent = MeetingCalendar.CalEvent

// MARK: - Today  (calm command center)
//
// The home you open every day. It doesn't just show the day — it lets you act on
// it: a short Focus list of what to do now, today's meetings with one-tap Join &
// Record, and commitments you can complete / snooze / reschedule / chase. Calm by
// default (no red alarms, soft counts, one primary action per row); fast depth via
// each row's actions. It never tells you how behind you are — only what's next.

struct TodayView: View {
    @ObservedObject private var memory = MeetingMemory.shared
    @ObservedObject private var calendar = MeetingCalendar.shared
    @ObservedObject private var recorder = MeetingRecorder.shared
    @ObservedObject private var settings = AppSettings.shared

    var onOpenTranscript: (TranscriptionHistoryItem) -> Void
    var onGoToRecord: () -> Void

    @State private var meetings: [CalEvent] = []
    @State private var showCompleted = false
    @State private var focusMode = false
    @State private var editing: TrackedActionItem?
    @State private var editText = ""
    @State private var rescheduling: TrackedActionItem?
    @State private var rescheduleDate = Date()

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Hi"
        }
    }

    // The next meeting that hasn't ended (live preferred).
    private var nextMeeting: CalEvent? {
        meetings.first { $0.isLive } ?? meetings.first { $0.end > Date() }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                header
                focusSection
                if !focusMode {
                    meetingsSection
                    commitmentsSection
                    recapsSection
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 22)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
        .alert("Edit commitment", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Task", text: $editText)
            Button("Save") { if let e = editing { memory.edit(e, to: editText) }; editing = nil }
            Button("Cancel", role: .cancel) { editing = nil }
        }
        .sheet(item: $rescheduling) { item in
            reschedulePopover(item)
        }
    }

    private func reload() {
        memory.refreshIfNeeded()
        meetings = calendar.upcomingEvents(daysAhead: settings.todayLookaheadDays)
    }

    // MARK: Header + quick actions

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting).font(.system(.largeTitle, design: .rounded).weight(.bold))
                Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.title3).foregroundColor(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Toggle(isOn: $focusMode) { Image(systemName: "scope") }
                    .toggleStyle(.button).help("Focus mode — show only what to do now")
                Menu {
                    if nextMeeting != nil {
                        Button("Record next meeting", systemImage: "record.circle") { if let m = nextMeeting { record(m) } }
                    }
                    let overdue = memory.openActionItems.filter { $0.urgency() == .overdue }
                    if !overdue.isEmpty {
                        Button("Snooze \(overdue.count) overdue to tomorrow", systemImage: "moon.zzz") {
                            overdue.forEach { memory.snooze($0, until: MeetingMemory.tomorrow) }
                        }
                    }
                    let waiting = memory.waitingOnItems
                    if !waiting.isEmpty {
                        Button("Nudge everyone who owes me (\(waiting.count))", systemImage: "paperplane") {
                            nudgeAll(waiting)
                        }
                    }
                } label: { Image(systemName: "bolt") }
                    .menuStyle(.borderlessButton).help("Quick actions")
            }
        }
    }

    // MARK: Focus — what to do now (Top 3 across meetings + commitments)

    @ViewBuilder
    private var focusSection: some View {
        let items = focusItems
        if items.isEmpty {
            calmCard(icon: "checkmark.circle", text: "You're all set. Hit Record whenever a conversation starts.")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Focus", systemImage: "scope")
                    .font(.caption.weight(.semibold)).foregroundColor(.secondary)
                VStack(spacing: 8) {
                    ForEach(items) { item in focusRow(item) }
                }
            }
        }
    }

    private enum FocusItem: Identifiable {
        case meeting(CalEvent)
        case commitment(TrackedActionItem)
        var id: String {
            switch self { case .meeting(let m): return "m-\(m.id)"; case .commitment(let c): return "c-\(c.id)" }
        }
    }

    private var focusItems: [FocusItem] {
        var out: [FocusItem] = []
        if let m = nextMeeting { out.append(.meeting(m)) }
        // Most pressing of my own commitments (overdue + due today), newest urgency first.
        let pressing = memory.myOpenItems.filter { $0.urgency() == .overdue || $0.urgency() == .today }
        for c in pressing.prefix(3 - out.count) { out.append(.commitment(c)) }
        return out
    }

    @ViewBuilder
    private func focusRow(_ item: FocusItem) -> some View {
        switch item {
        case .meeting(let m):
            HStack(spacing: 11) {
                Image(systemName: m.isLive ? "record.circle.fill" : "calendar")
                    .foregroundColor(m.isLive ? .green : DS.Colors.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.isLive ? "Happening now: \(m.title)" : "Next: \(m.title)")
                        .font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Text(m.start.formatted(.dateTime.hour().minute())).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                meetingPrimaryButton(m)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Colors.accent.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(
                (m.isLive ? Color.green : DS.Colors.accent).opacity(0.22)))
        case .commitment(let c):
            HStack(alignment: .top, spacing: 10) {
                completeButton(c)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.text).font(.system(size: 14, weight: .medium))
                    if let due = c.dueLabel { Text(due).font(.caption).foregroundColor(c.urgency().tint) }
                }
                Spacer()
                commitmentMenu(c)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Colors.rowFill))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Colors.hairline))
        }
    }

    // MARK: Meetings

    @ViewBuilder
    private var meetingsSection: some View {
        let title = settings.todayLookaheadDays > 0 ? "Upcoming" : "Today"
        sectionHeader(title, systemImage: "calendar", count: meetings.count)
        if !calendar.accessGranted {
            calmCard(icon: "calendar.badge.exclamationmark",
                     text: "Connect your calendar in Settings → Calendar to see meetings and prep for them.")
        } else if meetings.isEmpty {
            calmCard(icon: "checkmark.circle", text: "Nothing on your calendar. Hit Record whenever a conversation starts.")
        } else {
            VStack(spacing: 10) {
                ForEach(meetings) { event in
                    MeetingRow(event: event,
                               prep: memory.prep(forAttendees: event.attendees),
                               showDay: settings.todayLookaheadDays > 0,
                               onOpenTranscript: onOpenTranscript,
                               onJoinRecord: { joinAndRecord(event) },
                               onRecord: { record(event) })
                }
            }
        }
    }

    private func record(_ event: CalEvent) {
        guard !recorder.isBusy else { return }
        let prefill = event.attendees.isEmpty ? "" :
            "Attendees: " + event.attendees.joined(separator: ", ") + "\n\n"
        recorder.start(meetingTitle: event.title, notesPrefill: prefill,
                       attendees: event.attendees, attendeeEmails: event.attendeeEmails)
        onGoToRecord()
    }

    private func joinAndRecord(_ event: CalEvent) {
        if let s = event.meetingURL, let url = URL(string: s) { NSWorkspace.shared.open(url) }
        record(event)
    }

    @ViewBuilder
    private func meetingPrimaryButton(_ m: CalEvent) -> some View {
        if m.meetingURL != nil {
            Button { joinAndRecord(m) } label: { Label("Join & Record", systemImage: "video").font(.caption.weight(.semibold)) }
                .buttonStyle(.borderedProminent).controlSize(.small).tint(m.isLive ? .green : DS.Colors.accent)
                .disabled(recorder.isBusy)
        } else {
            Button { record(m) } label: { Label("Record", systemImage: "record.circle").font(.caption.weight(.semibold)) }
                .buttonStyle(.borderedProminent).controlSize(.small).tint(m.isLive ? .green : DS.Colors.accent)
                .disabled(recorder.isBusy)
        }
    }

    // MARK: Commitments

    @ViewBuilder
    private var commitmentsSection: some View {
        let mine = memory.myOpenItems
        let theirs = memory.waitingOnItems
        sectionHeader("Open commitments", systemImage: "checklist", count: mine.count + theirs.count)
        if mine.isEmpty && theirs.isEmpty {
            calmCard(icon: "checkmark.seal", text: "Nothing open. Everything you committed to is done.")
        } else {
            if !mine.isEmpty { commitmentGroup(title: "Yours", systemImage: "person.fill", items: mine) }
            if !theirs.isEmpty { commitmentGroup(title: "Waiting on others", systemImage: "person.2", items: theirs) }
        }
        if !memory.doneActionItems.isEmpty {
            DisclosureGroup(isExpanded: $showCompleted) {
                VStack(spacing: 0) { ForEach(memory.doneActionItems.prefix(30)) { commitmentRow($0) } }.padding(.top, 4)
            } label: { Text("Completed (\(memory.doneActionItems.count))").font(.callout).foregroundColor(.secondary) }
            .padding(.top, 4)
        }
    }

    private func commitmentGroup(title: String, systemImage: String, items: [TrackedActionItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage).font(.caption.weight(.semibold)).foregroundColor(.secondary).padding(.leading, 2)
            VStack(spacing: 0) {
                ForEach(items) { item in
                    commitmentRow(item)
                    if item.id != items.last?.id { Divider().opacity(0.4) }
                }
            }
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Colors.rowFill))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Colors.hairline))
        }
    }

    private func commitmentRow(_ item: TrackedActionItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            completeButton(item)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text).font(.system(size: 13))
                    .strikethrough(item.done, color: .secondary).foregroundColor(item.done ? .secondary : .primary)
                HStack(spacing: 6) {
                    if let owner = item.owner, !item.ownedByMe {
                        Label(owner, systemImage: "person").font(.caption2).foregroundColor(.secondary)
                    }
                    if !item.done, let due = item.dueLabel {
                        let u = item.urgency()
                        Text(due).font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(u.tint.opacity(0.16))).foregroundColor(u.tint)
                    }
                    Button { openTranscript(id: item.transcriptID) } label: {
                        Text(item.transcriptTitle).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    }.buttonStyle(.plain)
                }
            }
            Spacer()
            commitmentMenu(item)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contentShape(Rectangle())
        .contextMenu { commitmentActions(item) }
    }

    private func completeButton(_ item: TrackedActionItem) -> some View {
        Button { memory.toggle(item) } label: {
            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16)).foregroundColor(item.done ? .green : .secondary)
        }.buttonStyle(.plain).padding(.top, 1)
    }

    private func commitmentMenu(_ item: TrackedActionItem) -> some View {
        Menu { commitmentActions(item) } label: {
            Image(systemName: "ellipsis").font(.system(size: 13)).foregroundColor(.secondary)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    @ViewBuilder
    private func commitmentActions(_ item: TrackedActionItem) -> some View {
        if !item.done {
            Button("Snooze to tomorrow", systemImage: "moon.zzz") { memory.snooze(item, until: MeetingMemory.tomorrow) }
            Button("Reschedule…", systemImage: "calendar") {
                rescheduleDate = item.dueDate ?? MeetingMemory.tomorrow; rescheduling = item
            }
            if !item.ownedByMe { Button("Nudge…", systemImage: "paperplane") { nudge(item) } }
            Button("Add to Reminders", systemImage: "checklist") {
                Task { try? await RemindersExporter.shared.export(items: [item.text], meetingTitle: item.transcriptTitle, dueDate: item.dueDate) }
            }
        }
        Button("Open meeting", systemImage: "doc.text") { openTranscript(id: item.transcriptID) }
        Button("Edit…", systemImage: "pencil") { editing = item; editText = item.text }
        Divider()
        Button("Not a task — remove", systemImage: "trash", role: .destructive) { memory.delete(item) }
    }

    private func reschedulePopover(_ item: TrackedActionItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reschedule").font(.headline)
            Text(item.text).font(.system(size: 13)).foregroundColor(.secondary).lineLimit(2)
            DatePicker("Due", selection: $rescheduleDate, displayedComponents: .date)
                .datePickerStyle(.graphical).labelsHidden()
            HStack {
                Spacer()
                Button("Cancel") { rescheduling = nil }
                Button("Set due date") { memory.reschedule(item, due: rescheduleDate); rescheduling = nil }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 320)
    }

    // MARK: Recents

    @ViewBuilder
    private var recapsSection: some View {
        if !memory.recentMeetings.isEmpty {
            sectionHeader("Recent recaps", systemImage: "sparkles.rectangle.stack", count: nil)
            VStack(spacing: 8) {
                ForEach(memory.recentMeetings) { item in
                    Button { onOpenTranscript(item) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text").foregroundColor(DS.Colors.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(DS.Typography.rowTitle).lineLimit(1)
                                Text(relativeDate(item.transcriptionDate)).font(.caption).foregroundColor(.secondary)
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
    }

    // MARK: Nudge (draft a follow-up — never auto-sent)

    private func nudge(_ item: TrackedActionItem) {
        let who = item.owner ?? "there"
        let subject = "Quick follow-up"
        let body = "Hi \(who),\n\nFollowing up on this from \(item.transcriptTitle): \(item.text).\n\nAny update? Thanks!"
        openMailDraft(subject: subject, body: body)
    }

    private func nudgeAll(_ items: [TrackedActionItem]) {
        let lines = items.map { "• \($0.text) (from \($0.transcriptTitle))" }.joined(separator: "\n")
        openMailDraft(subject: "Quick follow-ups", body: "Hi,\n\nFollowing up on a few things:\n\n\(lines)\n\nAny updates? Thanks!")
    }

    private func openMailDraft(subject: String, body: String) {
        if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [body]) {
            service.subject = subject
            service.perform(withItems: [body])
        } else {
            let s = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let b = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "mailto:?subject=\(s)&body=\(b)") { NSWorkspace.shared.open(url) }
        }
    }

    // MARK: helpers

    private func openTranscript(id: UUID) {
        if let item = TranscriptionHistoryManager.shared.history.first(where: { $0.id == id }) { onOpenTranscript(item) }
    }

    private func sectionHeader(_ title: String, systemImage: String, count: Int?) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage).foregroundColor(.secondary)
            Text(title).font(.system(.title3, design: .rounded).weight(.semibold))
            if let count, count > 0 {
                Text("\(count)").font(.caption.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(DS.Colors.accent.opacity(0.18))).foregroundColor(DS.Colors.accent)
            }
            Spacer()
        }
    }

    private func calmCard(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(.secondary)
            Text(text).font(.callout).foregroundColor(.secondary)
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Colors.rowFill))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Colors.hairline))
    }
}

// MARK: - Meeting row + prep

private struct MeetingRow: View {
    let event: CalEvent
    let prep: (meetings: [TranscriptionHistoryItem], openItems: [TrackedActionItem])
    var showDay: Bool = false
    var onOpenTranscript: (TranscriptionHistoryItem) -> Void
    var onJoinRecord: () -> Void
    var onRecord: () -> Void

    @ObservedObject private var recorder = MeetingRecorder.shared
    @State private var expanded = false

    private var hasPrep: Bool { !prep.meetings.isEmpty || !prep.openItems.isEmpty }
    private var ended: Bool { event.end <= Date() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .trailing, spacing: 1) {
                    if showDay {
                        Text(event.start.formatted(.dateTime.weekday(.abbreviated))).font(.caption2).foregroundColor(.secondary)
                    }
                    Text(event.start.formatted(.dateTime.hour().minute()))
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    if event.isLive { Text("now").font(.caption2.weight(.bold)).foregroundColor(.green) }
                }
                .frame(width: 54, alignment: .trailing)
                .foregroundColor(ended && !event.isLive ? .secondary : .primary)

                Rectangle().fill(event.isLive ? Color.green : (ended ? DS.Colors.hairline : DS.Colors.accent))
                    .frame(width: 3).cornerRadius(1.5)

                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title).font(DS.Typography.rowTitle)
                        .foregroundColor(ended && !event.isLive ? .secondary : .primary).lineLimit(1)
                    HStack(spacing: 8) {
                        if !event.attendees.isEmpty {
                            Label("\(event.attendees.count)", systemImage: "person.2").font(.caption).foregroundColor(.secondary)
                        }
                        if !event.calendarTitle.isEmpty {
                            Label(event.calendarTitle, systemImage: "calendar").font(.caption2).foregroundColor(.secondary.opacity(0.8)).lineLimit(1)
                        }
                        if hasPrep {
                            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                                Label(expanded ? "Hide prep" : "Prep", systemImage: "sparkles").font(.caption.weight(.medium))
                            }.buttonStyle(.plain).foregroundColor(DS.Colors.accent)
                        }
                    }
                }
                Spacer()
                if !ended || event.isLive {
                    if event.meetingURL != nil {
                        Button(action: onJoinRecord) { Label("Join & Record", systemImage: "video").font(.caption.weight(.semibold)) }
                            .buttonStyle(.borderedProminent).controlSize(.small).tint(event.isLive ? .green : DS.Colors.accent).disabled(recorder.isBusy)
                    } else {
                        Button(action: onRecord) { Label("Record", systemImage: "record.circle").font(.caption.weight(.semibold)) }
                            .buttonStyle(.borderedProminent).controlSize(.small).tint(event.isLive ? .green : DS.Colors.accent).disabled(recorder.isBusy)
                    }
                }
            }
            .padding(12)
            if expanded && hasPrep { prepCard.padding(.horizontal, 12).padding(.bottom, 12) }
        }
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Colors.rowFill))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(
            event.isLive ? Color.green.opacity(0.4) : DS.Colors.hairline))
    }

    private var prepCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !prep.openItems.isEmpty {
                Text("Open with these people").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                ForEach(prep.openItems.prefix(4)) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "circle").font(.system(size: 6)).foregroundColor(.orange).padding(.top, 5)
                        Text(item.text).font(.caption)
                    }
                }
            }
            if !prep.meetings.isEmpty {
                Text("Last met").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                    .padding(.top, prep.openItems.isEmpty ? 0 : 4)
                ForEach(prep.meetings.prefix(3)) { m in
                    Button { onOpenTranscript(m) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text").font(.caption2).foregroundColor(DS.Colors.accent)
                            Text(m.title).font(.caption).lineLimit(1)
                            Spacer()
                            Text(relativeDate(m.transcriptionDate)).font(.caption2).foregroundColor(.secondary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(Color.black.opacity(0.15)))
    }
}

// MARK: - Shared relative-date helper

func relativeDate(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return "Today" }
    if cal.isDateInYesterday(date) { return "Yesterday" }
    let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
    if days > 0 && days < 7 { return "\(days) days ago" }
    return date.formatted(.dateTime.month(.abbreviated).day())
}
