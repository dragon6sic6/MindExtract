import Foundation
import SwiftUI
import EventKit
import AppKit
import UserNotifications

// MARK: - Calendar-aware meeting detection
//
// Surfaces the meeting happening right now (or starting within a few minutes)
// from the user's calendars so they can one-tap "Record this meeting" with the
// event's title and attendees pre-filled. Read-only; nothing is written back.

@MainActor
final class MeetingCalendar: ObservableObject {
    static let shared = MeetingCalendar()

    struct CalEvent: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let attendees: [String]
        let attendeeEmails: [String]
        var isLive: Bool          // happening right now (vs. starting soon)
    }

    @Published private(set) var currentMeeting: CalEvent?
    @Published private(set) var accessGranted = false
    /// Published so Settings re-renders the per-calendar list as soon as access
    /// is granted in-session (a plain function call wouldn't trigger a re-render).
    @Published private(set) var calendars: [EKCalendar] = []

    private let store = EKEventStore()
    private var timer: Timer?
    private var settings: AppSettings { AppSettings.shared }

    private init() {
        refreshAccessStatus()
        // Re-evaluate as time passes and when the app returns to the foreground.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refreshAccessStatus() {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            accessGranted = (status == .fullAccess)
        } else {
            accessGranted = (status == .authorized)
        }
        reloadCalendars()
    }

    func requestAccess() async {
        if #available(macOS 14.0, *) {
            _ = try? await store.requestFullAccessToEvents()
        } else {
            _ = try? await store.requestAccess(to: .event)
        }
        refreshAccessStatus()
        if accessGranted { startMonitoring() }
    }

    /// Refresh the published calendar list (drives the Settings include/exclude UI).
    func reloadCalendars() {
        guard accessGranted else { calendars = []; return }
        calendars = store.calendars(for: .event)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Begin periodic detection (cheap — runs every 30s while on the Record tab).
    func startMonitoring() {
        guard accessGranted, settings.calendarSuggestionsEnabled else { return }
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopMonitoring() { timer?.invalidate(); timer = nil }

    /// Called when the user flips the in-app "Suggest meetings" switch. This is
    /// the app-level disable — it does not touch the macOS permission.
    func setSuggestionsEnabled(_ on: Bool) {
        settings.calendarSuggestionsEnabled = on
        if on {
            startMonitoring()
        } else {
            stopMonitoring()
            currentMeeting = nil
        }
    }

    /// Calendars the user can include/exclude from scanning, in Settings.
    func availableCalendars() -> [EKCalendar] {
        guard accessGranted else { return [] }
        return store.calendars(for: .event)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Deep-link to System Settings → Privacy → Calendars so the user can grant
    /// or fully revoke the OS-level permission (an app can't revoke TCC itself).
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open System Settings → Internet Accounts so the user can add a Google or
    /// Microsoft account. Those calendars then sync into macOS and appear here
    /// automatically — no in-app OAuth, nothing leaves the Mac through us.
    func openInternetAccounts() {
        let prefPane = "/System/Library/PreferencePanes/InternetAccounts.prefPane"
        if FileManager.default.fileExists(atPath: prefPane) {
            NSWorkspace.shared.open(URL(fileURLWithPath: prefPane))
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.internetaccounts") {
            NSWorkspace.shared.open(url)
        }
    }

    /// All of today's meetings (non-all-day, not canceled, not in excluded
    /// calendars), sorted by start. Powers the "Today" home — including ones that
    /// have already ended (shown dimmed) so the day reads as a timeline.
    func todaysEvents() -> [CalEvent] { upcomingEvents(daysAhead: 0) }

    /// Today's meetings plus the next `daysAhead` days (0 = today only).
    func upcomingEvents(daysAhead: Int) -> [CalEvent] {
        guard accessGranted, settings.calendarSuggestionsEnabled else { return [] }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: max(0, daysAhead) + 1, to: start) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let excluded = settings.excludedCalendarIDSet
        let now = Date()
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled }
            .filter { excluded.isEmpty || !excluded.contains($0.calendar?.calendarIdentifier ?? "") }
            .sorted { $0.startDate < $1.startDate }
            .map { e in
                CalEvent(
                    id: e.eventIdentifier ?? UUID().uuidString,
                    title: e.title ?? "Meeting",
                    start: e.startDate,
                    end: e.endDate,
                    attendees: (e.attendees ?? []).compactMap { $0.name }.filter { !$0.isEmpty },
                    attendeeEmails: (e.attendees ?? []).compactMap { p in
                        let s = p.url.absoluteString
                        return s.hasPrefix("mailto:") ? String(s.dropFirst("mailto:".count)) : nil
                    }.filter { $0.contains("@") },
                    isLive: e.startDate <= now && e.endDate > now)
            }
    }

    func refresh() {
        guard accessGranted, settings.calendarSuggestionsEnabled else { currentMeeting = nil; return }
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        let end = now.addingTimeInterval(12 * 3600)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)

        // Prefer an event happening right now; else one starting within the lead window.
        let lead = Double(max(0, settings.calendarLeadMinutes)) * 60
        let soonWindow = now.addingTimeInterval(lead)
        let excluded = settings.excludedCalendarIDSet
        let candidate = events
            .filter { !$0.isAllDay && $0.status != .canceled }
            .filter { excluded.isEmpty || !excluded.contains($0.calendar?.calendarIdentifier ?? "") }
            .filter { $0.endDate > now && $0.startDate <= soonWindow }
            .sorted { $0.startDate < $1.startDate }
            .first

        let previousID = currentMeeting?.id
        currentMeeting = candidate.map { e in
            CalEvent(
                id: e.eventIdentifier ?? UUID().uuidString,
                title: e.title ?? "Meeting",
                start: e.startDate,
                end: e.endDate,
                attendees: (e.attendees ?? []).compactMap { $0.name }.filter { !$0.isEmpty },
                // EKParticipant.url is a mailto: URL — pull the email for recap recipients.
                attendeeEmails: (e.attendees ?? []).compactMap { p in
                    let s = p.url.absoluteString
                    return s.hasPrefix("mailto:") ? String(s.dropFirst("mailto:".count)) : nil
                }.filter { $0.contains("@") },
                isLive: e.startDate <= now
            )
        }

        // Calendar nudge (Granola-style): when a NEW meeting surfaces and MindExtract
        // is in the background, notify so you can record it the moment it starts.
        if let m = currentMeeting, m.id != previousID, m.id != nudgedMeetingID,
           !NSApp.isActive, settings.meetingNudge, !MeetingRecorder.shared.isBusy {
            nudgedMeetingID = m.id
            postMeetingNudge(m)
        } else if currentMeeting == nil {
            nudgedMeetingID = nil
        }
    }

    private var nudgedMeetingID: String?

    private func postMeetingNudge(_ m: CalEvent) {
        let content = UNMutableNotificationContent()
        content.title = m.isLive ? "“\(m.title)” is starting" : "“\(m.title)” starts soon"
        content.body = "Tap to record it in MindExtract."
        content.sound = .default
        content.categoryIdentifier = "MEETING_DETECTED"
        content.userInfo = ["calendar": true]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "calendar-nudge", content: content, trigger: nil))
    }
}
