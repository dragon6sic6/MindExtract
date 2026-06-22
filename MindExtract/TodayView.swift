import SwiftUI
import AppKit

private typealias CalEvent = MeetingCalendar.CalEvent

// MARK: - Today
//
// The home you open even on a day with no meetings. It ties the three "daily love"
// threads together: what's on your calendar today (with a prep card so you never
// walk in cold), every open commitment across all your meetings, and your latest
// recaps. All on-device — it reads only what MindExtract already wrote.

struct TodayView: View {
    @ObservedObject private var memory = MeetingMemory.shared
    @ObservedObject private var calendar = MeetingCalendar.shared
    @ObservedObject private var recorder = MeetingRecorder.shared

    /// Open a saved transcript (host switches to the Transcripts tab via the
    /// transcription manager's showTranscriptionView change).
    var onOpenTranscript: (TranscriptionHistoryItem) -> Void
    var onGoToRecord: () -> Void

    @State private var todays: [CalEvent] = []
    @State private var showCompleted = false

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
                meetingsSection
                actionItemsSection
                recapsSection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reload()
        }
    }

    private func reload() {
        memory.refreshIfNeeded()
        todays = calendar.todaysEvents()
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(greeting)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.title3)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Today's meetings

    @ViewBuilder
    private var meetingsSection: some View {
        sectionHeader("Today", systemImage: "calendar", count: todays.count)
        if !calendar.accessGranted {
            hintCard(icon: "calendar.badge.exclamationmark",
                     text: "Connect your calendar in Settings → Calendar to see today's meetings and prep for them automatically.")
        } else if todays.isEmpty {
            hintCard(icon: "checkmark.circle",
                     text: "Nothing on your calendar today. Hit Record whenever a conversation starts.")
        } else {
            VStack(spacing: 10) {
                ForEach(todays) { event in
                    MeetingRow(event: event,
                               prep: memory.prep(forAttendees: event.attendees),
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

    // MARK: Open action items (across all meetings)

    @ViewBuilder
    private var actionItemsSection: some View {
        sectionHeader("Open commitments", systemImage: "checklist", count: memory.openActionItems.count)
        if memory.openActionItems.isEmpty {
            hintCard(icon: "checkmark.seal",
                     text: "No open action items. Everything you committed to is done.")
        } else {
            VStack(spacing: 0) {
                ForEach(memory.openActionItems) { item in
                    ActionItemRow(item: item,
                                  onToggle: { memory.toggle(item) },
                                  onOpen: { openTranscript(id: item.transcriptID) })
                    if item.id != memory.openActionItems.last?.id { Divider().opacity(0.4) }
                }
            }
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Colors.rowFill))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Colors.hairline))
        }
        if !memory.doneActionItems.isEmpty {
            DisclosureGroup(isExpanded: $showCompleted) {
                VStack(spacing: 0) {
                    ForEach(memory.doneActionItems.prefix(30)) { item in
                        ActionItemRow(item: item,
                                      onToggle: { memory.toggle(item) },
                                      onOpen: { openTranscript(id: item.transcriptID) })
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Completed (\(memory.doneActionItems.count))")
                    .font(.callout).foregroundColor(.secondary)
            }
            .padding(.top, 4)
        }
    }

    // MARK: Recent recaps

    @ViewBuilder
    private var recapsSection: some View {
        if !memory.recentMeetings.isEmpty {
            sectionHeader("Recent recaps", systemImage: "sparkles.rectangle.stack", count: nil)
            VStack(spacing: 8) {
                ForEach(memory.recentMeetings) { item in
                    Button { onOpenTranscript(item) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text")
                                .foregroundColor(DS.Colors.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(DS.Typography.rowTitle).lineLimit(1)
                                Text(relativeDate(item.transcriptionDate))
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
    }

    // MARK: helpers

    private func openTranscript(id: UUID) {
        if let item = TranscriptionHistoryManager.shared.history.first(where: { $0.id == id }) {
            onOpenTranscript(item)
        }
    }

    private func sectionHeader(_ title: String, systemImage: String, count: Int?) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage).foregroundColor(.secondary)
            Text(title).font(.system(.title3, design: .rounded).weight(.semibold))
            if let count, count > 0 {
                Text("\(count)")
                    .font(.caption.weight(.semibold))
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

// MARK: - Meeting row + prep

private struct MeetingRow: View {
    let event: CalEvent
    let prep: (meetings: [TranscriptionHistoryItem], openItems: [TrackedActionItem])
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
                    Text(event.start.formatted(.dateTime.hour().minute()))
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    if event.isLive {
                        Text("now").font(.caption2.weight(.bold)).foregroundColor(.green)
                    }
                }
                .frame(width: 52, alignment: .trailing)
                .foregroundColor(ended && !event.isLive ? .secondary : .primary)

                Rectangle()
                    .fill(event.isLive ? Color.green : (ended ? DS.Colors.hairline : DS.Colors.accent))
                    .frame(width: 3)
                    .cornerRadius(1.5)

                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(DS.Typography.rowTitle)
                        .foregroundColor(ended && !event.isLive ? .secondary : .primary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if !event.attendees.isEmpty {
                            Label("\(event.attendees.count)", systemImage: "person.2")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        if hasPrep {
                            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                                Label(expanded ? "Hide prep" : "Prep", systemImage: "sparkles")
                                    .font(.caption.weight(.medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(DS.Colors.accent)
                        }
                    }
                }
                Spacer()
                if !ended || event.isLive {
                    Button(action: onRecord) {
                        Label("Record", systemImage: "record.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(event.isLive ? .green : DS.Colors.accent)
                    .disabled(recorder.isBusy)
                }
            }
            .padding(12)

            if expanded && hasPrep {
                prepCard.padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Colors.rowFill))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(
            event.isLive ? Color.green.opacity(0.4) : DS.Colors.hairline))
    }

    private var prepCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !prep.openItems.isEmpty {
                Text("Open with these people")
                    .font(.caption.weight(.semibold)).foregroundColor(.secondary)
                ForEach(prep.openItems.prefix(4)) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "circle").font(.system(size: 6)).foregroundColor(.orange).padding(.top, 5)
                        Text(item.text).font(.caption)
                    }
                }
            }
            if !prep.meetings.isEmpty {
                Text("Last met")
                    .font(.caption.weight(.semibold)).foregroundColor(.secondary)
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

// MARK: - Action item row

private struct ActionItemRow: View {
    let item: TrackedActionItem
    var onToggle: () -> Void
    var onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(item.done ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(.system(size: 13))
                    .strikethrough(item.done, color: .secondary)
                    .foregroundColor(item.done ? .secondary : .primary)
                Button(action: onOpen) {
                    HStack(spacing: 5) {
                        Text(item.transcriptTitle).lineLimit(1)
                        Text("·")
                        Text(relativeDate(item.date))
                    }
                    .font(.caption).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contentShape(Rectangle())
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
