import SwiftUI
import AppKit

private typealias CalEvent = MeetingCalendar.CalEvent

// MARK: - Today
//
// The home you open even on a day with no meetings. A one-line plan of the day,
// today's calendar meetings (with a prep card so you never walk in cold), every
// open commitment split into "yours" vs "waiting on others" and grouped by
// urgency, and your latest recaps. All on-device.

struct TodayView: View {
    @ObservedObject private var memory = MeetingMemory.shared
    @ObservedObject private var calendar = MeetingCalendar.shared
    @ObservedObject private var recorder = MeetingRecorder.shared
    @ObservedObject private var settings = AppSettings.shared

    var onOpenTranscript: (TranscriptionHistoryItem) -> Void
    var onGoToRecord: () -> Void

    @State private var meetings: [CalEvent] = []
    @State private var showCompleted = false
    @State private var editing: TrackedActionItem?
    @State private var editText = ""

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Hi"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                header
                if settings.todayShowDailyBrief { dailyBrief }
                meetingsSection
                commitmentsSection
                recapsSection
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
    }

    private func reload() {
        memory.refreshIfNeeded()
        meetings = calendar.upcomingEvents(daysAhead: settings.todayLookaheadDays)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(greeting).font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.title3).foregroundColor(.secondary)
        }
    }

    // MARK: Plan-my-day brief (instant, heuristic — no AI latency)

    private var dailyBrief: some View {
        let todayMeetings = meetings.filter { Calendar.current.isDateInToday($0.start) && $0.end > Date() }.count
        let overdue = memory.openActionItems.filter { $0.urgency() == .overdue }.count
        let dueToday = memory.openActionItems.filter { $0.urgency() == .today }.count
        let next = memory.myOpenItems.first

        var parts: [String] = []
        if todayMeetings > 0 { parts.append("\(todayMeetings) meeting\(todayMeetings == 1 ? "" : "s") left today") }
        if overdue > 0 { parts.append("\(overdue) overdue") }
        if dueToday > 0 { parts.append("\(dueToday) due today") }

        return HStack(alignment: .top, spacing: 11) {
            Image(systemName: "sparkles").foregroundColor(DS.Colors.accent).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                if parts.isEmpty {
                    Text("You're all caught up. Hit Record whenever a conversation starts.")
                        .font(.callout)
                } else {
                    Text(parts.joined(separator: " · ")).font(.callout.weight(.medium))
                    if let next {
                        Text("Next up: \(next.text)").font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Colors.accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Colors.accent.opacity(0.18)))
    }

    // MARK: Meetings

    @ViewBuilder
    private var meetingsSection: some View {
        let title = settings.todayLookaheadDays > 0 ? "Upcoming" : "Today"
        sectionHeader(title, systemImage: "calendar", count: meetings.count)
        if !calendar.accessGranted {
            hintCard(icon: "calendar.badge.exclamationmark",
                     text: "Connect your calendar in Settings → Calendar to see meetings and prep for them automatically.")
        } else if meetings.isEmpty {
            hintCard(icon: "checkmark.circle",
                     text: "Nothing on your calendar. Hit Record whenever a conversation starts.")
        } else {
            VStack(spacing: 10) {
                ForEach(meetings) { event in
                    MeetingRow(event: event,
                               prep: memory.prep(forAttendees: event.attendees),
                               showDay: settings.todayLookaheadDays > 0,
                               onOpenTranscript: onOpenTranscript,
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

    // MARK: Commitments — mine vs theirs, grouped by urgency

    @ViewBuilder
    private var commitmentsSection: some View {
        let mine = memory.myOpenItems
        let theirs = memory.waitingOnItems
        sectionHeader("Open commitments", systemImage: "checklist", count: mine.count + theirs.count)

        if mine.isEmpty && theirs.isEmpty {
            hintCard(icon: "checkmark.seal", text: "No open action items. Everything you committed to is done.")
        } else {
            if !mine.isEmpty { commitmentGroup(title: "Yours", systemImage: "person.fill", items: mine) }
            if !theirs.isEmpty { commitmentGroup(title: "Waiting on others", systemImage: "person.2", items: theirs) }
        }

        if !memory.doneActionItems.isEmpty {
            DisclosureGroup(isExpanded: $showCompleted) {
                VStack(spacing: 0) {
                    ForEach(memory.doneActionItems.prefix(30)) { item in commitmentRow(item) }
                }.padding(.top, 4)
            } label: {
                Text("Completed (\(memory.doneActionItems.count))").font(.callout).foregroundColor(.secondary)
            }
            .padding(.top, 4)
        }
    }

    private func commitmentGroup(title: String, systemImage: String, items: [TrackedActionItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold)).foregroundColor(.secondary)
                .padding(.leading, 2)
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
        CommitmentRow(item: item,
                      onToggle: { memory.toggle(item) },
                      onOpen: { openTranscript(id: item.transcriptID) },
                      onEdit: { editing = item; editText = item.text },
                      onDelete: { memory.delete(item) })
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
                    .background(Capsule().fill(DS.Colors.accent.opacity(0.18)))
                    .foregroundColor(DS.Colors.accent)
            }
            Spacer()
        }
    }

    private func hintCard(icon: String, text: String) -> some View {
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

// MARK: - Commitment row

private struct CommitmentRow: View {
    let item: TrackedActionItem
    var onToggle: () -> Void
    var onOpen: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16)).foregroundColor(item.done ? .green : .secondary)
            }
            .buttonStyle(.plain).padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .font(.system(size: 13))
                    .strikethrough(item.done, color: .secondary)
                    .foregroundColor(item.done ? .secondary : .primary)
                HStack(spacing: 6) {
                    if let owner = item.owner, !item.ownedByMe {
                        Label(owner, systemImage: "person").font(.caption2).foregroundColor(.secondary)
                    }
                    if !item.done, let due = item.dueLabel {
                        let u = item.urgency()
                        Text(due).font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(u.tint.opacity(0.16)))
                            .foregroundColor(u.tint)
                    }
                    Button(action: onOpen) {
                        Text(item.transcriptTitle).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    }.buttonStyle(.plain)
                    Text("·").font(.caption2).foregroundColor(.secondary)
                    Text(relativeDate(item.date)).font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Open meeting", systemImage: "doc.text", action: onOpen)
            Button("Edit…", systemImage: "pencil", action: onEdit)
            Button("Add to Reminders", systemImage: "checklist") {
                Task { try? await RemindersExporter.shared.export(items: [item.text], meetingTitle: item.transcriptTitle, dueDate: item.dueDate) }
            }
            Divider()
            Button("Not a task — remove", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}

// MARK: - Meeting row + prep

private struct MeetingRow: View {
    let event: CalEvent
    let prep: (meetings: [TranscriptionHistoryItem], openItems: [TrackedActionItem])
    var showDay: Bool = false
    var onOpenTranscript: (TranscriptionHistoryItem) -> Void
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
                        Text(event.start.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Text(event.start.formatted(.dateTime.hour().minute()))
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    if event.isLive { Text("now").font(.caption2.weight(.bold)).foregroundColor(.green) }
                }
                .frame(width: 54, alignment: .trailing)
                .foregroundColor(ended && !event.isLive ? .secondary : .primary)

                Rectangle()
                    .fill(event.isLive ? Color.green : (ended ? DS.Colors.hairline : DS.Colors.accent))
                    .frame(width: 3).cornerRadius(1.5)

                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title).font(DS.Typography.rowTitle)
                        .foregroundColor(ended && !event.isLive ? .secondary : .primary).lineLimit(1)
                    HStack(spacing: 8) {
                        if !event.attendees.isEmpty {
                            Label("\(event.attendees.count)", systemImage: "person.2").font(.caption).foregroundColor(.secondary)
                        }
                        if hasPrep {
                            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                                Label(expanded ? "Hide prep" : "Prep", systemImage: "sparkles").font(.caption.weight(.medium))
                            }
                            .buttonStyle(.plain).foregroundColor(DS.Colors.accent)
                        }
                    }
                }
                Spacer()
                if !ended || event.isLive {
                    Button(action: onRecord) {
                        Label("Record", systemImage: "record.circle").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .tint(event.isLive ? .green : DS.Colors.accent).disabled(recorder.isBusy)
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
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
