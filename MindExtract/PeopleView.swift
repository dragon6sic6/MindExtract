import SwiftUI

// MARK: - People & Topics
//
// Meetings are episodes in ongoing relationships and recurring threads. This
// surfaces that structure automatically — no tagging, no data entry. "People"
// is built from attendees + renamed speakers; "Topics" clusters recurring meeting
// titles into project-like threads. Tap one to see every meeting and every open
// commitment with them.

struct PeopleView: View {
    @ObservedObject private var memory = MeetingMemory.shared
    var onOpenTranscript: (TranscriptionHistoryItem) -> Void

    enum Mode: String, CaseIterable { case people = "People", topics = "Topics" }
    @State private var mode: Mode = .people

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 12)

                if mode == .people { peopleList } else { topicsList }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationDestination(for: PersonThread.self) { person in
                ThreadDetail(title: person.name, subtitle: subtitle(person.meetings.count, person.lastMet),
                             avatar: person.initials, meetings: person.meetings, openItems: person.openItems,
                             onOpenTranscript: onOpenTranscript)
            }
            .navigationDestination(for: TopicThread.self) { topic in
                ThreadDetail(title: topic.title, subtitle: subtitle(topic.meetings.count, topic.lastMet),
                             avatar: nil, meetings: topic.meetings, openItems: topic.openItems,
                             onOpenTranscript: onOpenTranscript)
            }
        }
        .onAppear { memory.refreshIfNeeded() }
    }

    private func subtitle(_ count: Int, _ last: Date?) -> String {
        var s = "\(count) meeting\(count == 1 ? "" : "s")"
        if let last { s += " · last \(relativeDate(last))" }
        return s
    }

    // MARK: People

    @ViewBuilder
    private var peopleList: some View {
        if memory.people.isEmpty {
            emptyState(icon: "person.2",
                       text: "People appear here once you record meetings with named attendees, or rename speakers in a transcript.")
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(memory.people) { person in
                        NavigationLink(value: person) {
                            HStack(spacing: 12) {
                                AvatarView(initials: person.initials)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(person.name).font(DS.Typography.rowTitle)
                                    Text(subtitle(person.meetings.count, person.lastMet))
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                if !person.openItems.isEmpty { openBadge(person.openItems.count) }
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
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Topics

    @ViewBuilder
    private var topicsList: some View {
        if memory.topics.isEmpty {
            emptyState(icon: "rectangle.3.group",
                       text: "Topics group recurring meetings (same title across dates) into project threads. They'll appear once you've recorded a meeting more than once.")
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(memory.topics) { topic in
                        NavigationLink(value: topic) {
                            HStack(spacing: 12) {
                                Image(systemName: "rectangle.3.group.fill")
                                    .foregroundColor(DS.Colors.accent)
                                    .frame(width: 34, height: 34)
                                    .background(Circle().fill(DS.Colors.accent.opacity(0.15)))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(topic.title).font(DS.Typography.rowTitle).lineLimit(1)
                                    Text(subtitle(topic.meetings.count, topic.lastMet))
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
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func openBadge(_ n: Int) -> some View {
        Text("\(n) open")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.18)))
            .foregroundColor(.orange)
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 38)).foregroundColor(.secondary.opacity(0.5))
            Text(text).font(.callout).foregroundColor(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Avatar

private struct AvatarView: View {
    let initials: String
    var body: some View {
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
            .frame(width: 34, height: 34)
            .background(Circle().fill(DS.Colors.accent.opacity(0.85)))
    }
}

// MARK: - Thread detail (shared by people + topics)

private struct ThreadDetail: View {
    let title: String
    let subtitle: String
    let avatar: String?
    let meetings: [TranscriptionHistoryItem]
    let openItems: [TrackedActionItem]
    var onOpenTranscript: (TranscriptionHistoryItem) -> Void

    @ObservedObject private var memory = MeetingMemory.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                HStack(spacing: 14) {
                    if let avatar {
                        Text(avatar.isEmpty ? "?" : avatar)
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .frame(width: 56, height: 56)
                            .background(Circle().fill(DS.Colors.accent.opacity(0.85)))
                    } else {
                        Image(systemName: "rectangle.3.group.fill")
                            .font(.system(size: 24)).foregroundColor(DS.Colors.accent)
                            .frame(width: 56, height: 56)
                            .background(Circle().fill(DS.Colors.accent.opacity(0.15)))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(.title2, design: .rounded).weight(.bold))
                        Text(subtitle).font(.callout).foregroundColor(.secondary)
                    }
                    Spacer()
                }

                if !openItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Open commitments", systemImage: "checklist")
                            .font(.headline).foregroundColor(.secondary)
                        VStack(spacing: 0) {
                            ForEach(openItems) { item in
                                HStack(alignment: .top, spacing: 10) {
                                    Button { memory.toggle(item) } label: {
                                        Image(systemName: "circle").font(.system(size: 16)).foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain).padding(.top, 1)
                                    Text(item.text).font(.system(size: 13))
                                    Spacer()
                                    Text(relativeDate(item.date)).font(.caption2).foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                if item.id != openItems.last?.id { Divider().opacity(0.4) }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Colors.rowFill))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Colors.hairline))
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Meetings", systemImage: "calendar")
                        .font(.headline).foregroundColor(.secondary)
                    ForEach(meetings) { m in
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
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}
