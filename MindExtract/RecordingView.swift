import SwiftUI
import AVFoundation

// MARK: - Meetings
//
// The Meetings page: what's happening now (a detected call or calendar meeting),
// what's coming up today, and every meeting you've recorded. While recording, the
// page becomes the notepad (MeetingNotepadView).

struct RecordingView: View {
    var onOpenTranscripts: () -> Void = {}

    @ObservedObject private var recorder = MeetingRecorder.shared
    @ObservedObject private var transcriptionManager = TranscriptionManager.shared
    @ObservedObject private var history = TranscriptionHistoryManager.shared
    @ObservedObject private var calendar = MeetingCalendar.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var activeMeeting = ActiveMeetingDetector.shared

    @State private var meetingLinkInput = ""
    @State private var upcoming: [MeetingCalendar.CalEvent] = []

    var body: some View {
        Group {
            if recorder.isRecording {
                MeetingNotepadView()
            } else {
                page
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            recorder.recoverInterruptedSessions()
            recorder.refreshPermissions()
            calendar.refreshAccessStatus()
            upcoming = calendar.todaysEvents().filter { $0.end > Date() }
        }
        .onChange(of: calendar.currentMeeting) { _, _ in
            upcoming = calendar.todaysEvents().filter { $0.end > Date() }
        }
        // When a finished recording starts transcribing, show it in the Library.
        .onChange(of: transcriptionManager.showTranscriptionView) { _, shown in
            if shown { onOpenTranscripts() }
        }
    }

    // MARK: Page

    private var page: some View {
        VStack(alignment: .leading, spacing: 28) {
            if !recorder.micGranted || !recorder.screenGranted {
                permissionsCard
            }
            if case .error(let message, let kind) = recorder.state {
                errorCard(message, kind)
            }
            if recorder.state == .finishing {
                BusyRow(text: "Saving the recording…")
                    .contentCard()
            }
            nowSection
            if !laterToday.isEmpty {
                upcomingSection
            }
            recentSection
        }
        .pageLayout()
    }

    // MARK: Now

    private var nowSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Now")
            if let app = activeMeeting.activeApp {
                nowCard(
                    icon: "dot.radiowaves.left.and.right",
                    eyebrow: "Call in progress",
                    title: calendar.currentMeeting?.isLive == true ? calendar.currentMeeting!.title
                        : (activeMeeting.activeIsBrowser ? String(localized: "Video call in your browser") : String(localized: "\(app) call")),
                    detail: nil
                ) { recorder.startInContext() }
            } else if let m = calendar.currentMeeting {
                nowCard(
                    icon: "calendar",
                    eyebrow: m.isLive ? "Happening now" : "Starting soon",
                    title: m.title,
                    detail: m.attendees.isEmpty ? nil : m.attendees.joined(separator: ", ")
                ) { recorder.start(event: m) }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                    TextField("Paste a meeting link to record it", text: $meetingLinkInput)
                        .textFieldStyle(.plain)
                        .onSubmit(recordFromLink)
                    if let provider = meetingProvider(from: meetingLinkInput) {
                        Button("Record \(provider) Meeting", action: recordFromLink)
                            .primaryGlassButton()
                            .tint(DS.Colors.recording)
                    } else {
                        Button {
                            recorder.startInContext()
                        } label: {
                            Label("Record", systemImage: "record.circle")
                        }
                        .primaryGlassButton()
                        .tint(DS.Colors.recording)
                        .disabled(recorder.isBusy)
                    }
                }
                .padding(12)
                .rowChrome()
                Text("No bot joins the call. MindExtract records your microphone and the meeting audio on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func nowCard(icon: String, eyebrow: LocalizedStringKey, title: String, detail: String?,
                         record: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(DS.Colors.recording)
                .symbolEffect(.pulse, options: .repeating)
                .frame(width: 36, height: 36)
                .background(Circle().fill(DS.Colors.recording.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow).font(.callout).foregroundStyle(.secondary)
                Text(title).font(.headline).lineLimit(1)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button(action: record) {
                Label("Record", systemImage: "record.circle")
            }
            .primaryGlassButton()
            .tint(DS.Colors.recording)
            .controlSize(.large)
            .disabled(recorder.isBusy)
        }
        .padding(14)
        .rowChrome()
    }

    // MARK: Later today

    private var laterToday: [MeetingCalendar.CalEvent] {
        upcoming.filter { $0.id != calendar.currentMeeting?.id }
    }

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Later today", count: laterToday.count)
            VStack(spacing: 8) {
                ForEach(laterToday) { event in
                    HStack(spacing: 12) {
                        Text(event.start.formatted(date: .omitted, time: .shortened))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title).font(.body.weight(.medium)).lineLimit(1)
                            Text(event.attendees.isEmpty ? event.calendarTitle : event.attendees.joined(separator: ", "))
                                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if let link = event.meetingURL, let url = URL(string: link) {
                            Button("Join") { NSWorkspace.shared.open(url) }
                                .secondaryGlassButton()
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .rowChrome()
                }
            }
        }
    }

    // MARK: Recorded

    private var recordedMeetings: [TranscriptionHistoryItem] {
        history.history.filter { $0.sourceType == .meeting }
    }

    @ViewBuilder
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Recorded", count: recordedMeetings.count)
            if recordedMeetings.isEmpty {
                ContentUnavailableView {
                    Label("No meetings yet", systemImage: "waveform")
                } description: {
                    Text("Press Record when a meeting starts. You'll get the transcript and notes here.")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(recordedMeetings) { item in
                        TranscriptRow(item: item) {
                            transcriptionManager.openTranscriptionFromHistory(item)
                        }
                    }
                }
            }
        }
    }

    // MARK: Permissions & errors

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("MindExtract needs permission to record", systemImage: "lock.shield")
                .font(.headline)
            permissionRow("Microphone", detail: "Your voice.", granted: recorder.micGranted) {
                Task {
                    let ok = await recorder.requestMicPermission()
                    if !ok { recorder.openMicSettings() }
                }
            }
            permissionRow("Meeting audio", detail: "The other participants — audio only, never video.", granted: recorder.screenGranted) {
                recorder.requestScreenPermission()
                recorder.openScreenRecordingSettings()
            }
            if !recorder.screenGranted {
                HStack {
                    Text("After allowing meeting audio in System Settings, restart MindExtract.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Restart") { Self.relaunch() }
                        .secondaryGlassButton()
                }
            }
        }
        .contentCard(tint: .orange)
    }

    private func permissionRow(_ title: LocalizedStringKey, detail: LocalizedStringKey, granted: Bool,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !granted {
                Button("Allow…", action: action)
                    .secondaryGlassButton()
            }
        }
    }

    private func errorCard(_ message: String, _ kind: MeetingRecorder.ErrorKind) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).frame(maxWidth: .infinity, alignment: .leading)
            switch kind {
            case .screenPermission:
                Button("Open Settings") { recorder.openScreenRecordingSettings() }.secondaryGlassButton()
            case .micPermission:
                Button("Open Settings") { recorder.openMicSettings() }.secondaryGlassButton()
            case .capture:
                EmptyView()
            }
            Button("Dismiss") { recorder.dismissError() }.secondaryGlassButton()
        }
        .contentCard(tint: .orange)
    }

    // MARK: Helpers

    /// Recognize a meeting link (Teams/Zoom/Meet/Webex/…) for one-tap recording.
    private func meetingProvider(from s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: trimmed)?.scheme?.hasPrefix("http") == true else { return nil }
        let l = trimmed.lowercased()
        if l.contains("teams.microsoft.com") || l.contains("teams.live.com") { return "Teams" }
        if l.contains("zoom.us") || l.contains("zoom.com") { return "Zoom" }
        if l.contains("meet.google.com") { return "Google Meet" }
        if l.contains("webex.com") { return "Webex" }
        if l.contains("whereby.com") { return "Whereby" }
        if l.contains("gotomeeting") || l.contains("gotomeet.me") { return "GoToMeeting" }
        return nil
    }

    private func recordFromLink() {
        guard let provider = meetingProvider(from: meetingLinkInput) else { return }
        let link = meetingLinkInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
        recorder.start(language: settings.defaultTranscriptionLanguage,
                       meetingTitle: String(localized: "\(provider) meeting"))
        meetingLinkInput = ""
    }

    /// Relaunch the app (needed for the Screen Recording permission to take effect).
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.4; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    static func formatElapsed(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
