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
        let calendarTitle: String   // which calendar it came from (shown for transparency)
        let meetingURL: String?     // Zoom/Teams/Meet link, for one-tap "Join & Record"
        var isLive: Bool            // happening right now (vs. starting soon)
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
        let now = Date()
        let relevant = store.events(matching: predicate).filter { isRelevantEvent($0) }
        return deduplicate(relevant)
            .sorted { $0.startDate < $1.startDate }
            .map { makeEvent($0, now: now) }
    }

    // MARK: De-duplication
    //
    // The same meeting often lands in more than one calendar you can see — your own
    // copy plus a delegate's / shared ("ombud") calendar. EventKit returns each as a
    // separate event, so the meeting shows up twice. Collapse copies of the same
    // meeting (same title + time + organizer) and keep the one most clearly "yours".

    private func deduplicate(_ events: [EKEvent]) -> [EKEvent] {
        var best: [String: EKEvent] = [:]
        var order: [String] = []
        for e in events {
            let key = dedupKey(e)
            if let existing = best[key] {
                if preferenceScore(e) > preferenceScore(existing) { best[key] = e }
            } else {
                best[key] = e
                order.append(key)
            }
        }
        return order.compactMap { best[$0] }
    }

    private func dedupKey(_ e: EKEvent) -> String {
        let title = (e.title ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        // Title + exact time window identifies one meeting across calendars. We avoid
        // keying on organizer — a delegate/shared copy can carry different or missing
        // organizer info, which would defeat the dedup. Two genuinely distinct meetings
        // with the same title at the same minute is vanishingly rare.
        return "\(title)|\(e.startDate.timeIntervalSinceReferenceDate)|\(e.endDate.timeIntervalSinceReferenceDate)"
    }

    /// Higher = more clearly the user's own copy (vs. a delegate/shared duplicate).
    private func preferenceScore(_ e: EKEvent) -> Int {
        var score = 0
        if e.organizer?.isCurrentUser == true { score += 8 }
        if let me = e.attendees?.first(where: { $0.isCurrentUser }) {
            if me.participantStatus == .accepted { score += 4 }
            else if me.participantStatus == .tentative { score += 2 }
        }
        if e.calendar?.allowsContentModifications == true { score += 1 }   // your editable calendar
        return score
    }

    // MARK: Relevance — only the user's own meetings

    /// A calendar worth scanning for meetings (excludes birthdays + subscribed feeds).
    private func isScannableCalendar(_ cal: EKCalendar?) -> Bool {
        guard let cal else { return false }
        if cal.type == .birthday || cal.type == .subscription { return false }
        return true
    }

    /// An event the user actually takes part in — so a colleague's event on a shared
    /// calendar (where the user isn't invited) doesn't show up as "your" meeting.
    private func isMyEvent(_ e: EKEvent) -> Bool {
        // Explicitly declined → never surface.
        if let me = e.attendees?.first(where: { $0.isCurrentUser }), me.participantStatus == .declined {
            return false
        }
        if e.organizer?.isCurrentUser == true { return true }              // I organize it
        if e.attendees?.contains(where: { $0.isCurrentUser }) == true { return true }  // I'm invited
        // A personal entry (no participants) on a calendar I own/can edit.
        let noParticipants = (e.attendees?.isEmpty ?? true) && e.organizer == nil
        return noParticipants && (e.calendar?.allowsContentModifications ?? false)
    }

    /// Shared filter for both the Today list and the live nudge.
    private func isRelevantEvent(_ e: EKEvent) -> Bool {
        guard !e.isAllDay, e.status != .canceled, isScannableCalendar(e.calendar) else { return false }
        if settings.excludedCalendarIDSet.contains(e.calendar?.calendarIdentifier ?? "") { return false }
        if settings.calendarOnlyMyEvents, !isMyEvent(e) { return false }
        return true
    }

    private func makeEvent(_ e: EKEvent, now: Date) -> CalEvent {
        CalEvent(
            id: e.eventIdentifier ?? UUID().uuidString,
            title: e.title ?? "Meeting",
            start: e.startDate,
            end: e.endDate,
            attendees: (e.attendees ?? []).compactMap { $0.isCurrentUser ? nil : $0.name }.filter { !$0.isEmpty },
            // EKParticipant.url is a mailto: URL — pull the email for recap recipients.
            attendeeEmails: (e.attendees ?? []).compactMap { p in
                guard !p.isCurrentUser else { return nil }
                let s = p.url.absoluteString
                return s.hasPrefix("mailto:") ? String(s.dropFirst("mailto:".count)) : nil
            }.filter { $0.contains("@") },
            calendarTitle: e.calendar?.title ?? "",
            meetingURL: Self.conferencingURL(e),
            isLive: e.startDate <= now && e.endDate > now)
    }

    /// Best guess at the join link: the event's own URL, else the first known
    /// conferencing link found in the location or notes.
    private static func conferencingURL(_ e: EKEvent) -> String? {
        if let u = e.url?.absoluteString, isConferencingLink(u) { return u }
        let blob = [e.location, e.notes].compactMap { $0 }.joined(separator: "\n")
        if !blob.isEmpty, let re = try? NSRegularExpression(pattern: "https://[^\\s]+") {
            let ns = blob as NSString
            for m in re.matches(in: blob, range: NSRange(location: 0, length: ns.length)) {
                let url = ns.substring(with: m.range)
                if isConferencingLink(url) { return url }
            }
        }
        return e.url?.absoluteString   // fall back to any event URL
    }

    private static func isConferencingLink(_ s: String) -> Bool {
        let l = s.lowercased()
        return ["zoom.us", "teams.microsoft", "teams.live", "meet.google", "webex.com",
                "whereby.com", "gotomeeting", "bluejeans", "around.co"].contains { l.contains($0) }
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
        let candidate = events
            .filter { isRelevantEvent($0) }
            .filter { $0.endDate > now && $0.startDate <= soonWindow }
            .sorted { $0.startDate < $1.startDate }
            .first

        let previousID = currentMeeting?.id
        currentMeeting = candidate.map { makeEvent($0, now: now) }

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
