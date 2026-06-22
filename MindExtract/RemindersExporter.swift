import Foundation
import EventKit

// MARK: - Apple Reminders export
//
// Turns the "Action Items" produced from a transcript into real reminders in
// Apple Reminders, so a meeting becomes actual tasks with one tap. On-device:
// nothing leaves the Mac. We write to a dedicated "MindExtract" list so the
// user's other reminders stay untouched and exports are easy to find/clear.

@MainActor
final class RemindersExporter: ObservableObject {
    static let shared = RemindersExporter()

    private let store = EKEventStore()
    private let listName = "MindExtract"

    private init() {}

    enum ExportError: LocalizedError {
        case accessDenied
        case noList
        case saveFailed
        case nothingToExport

        var errorDescription: String? {
            switch self {
            case .accessDenied: return "Reminders access was denied. Enable it in System Settings › Privacy & Security › Reminders."
            case .noList: return "Couldn't find or create a Reminders list."
            case .saveFailed: return "Reminders couldn't be saved. Check Reminders permissions or iCloud sync."
            case .nothingToExport: return "No action items were found to export."
            }
        }
    }

    func requestAccess() async -> Bool {
        if #available(macOS 14.0, *) {
            return (try? await store.requestFullAccessToReminders()) ?? false
        } else {
            return (try? await store.requestAccess(to: .reminder)) ?? false
        }
    }

    /// Parses bullet/numbered/checkbox lines out of an "Action Items" block.
    /// Falls back to non-empty lines if no list markers are present.
    static func parseActionItems(_ text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        // Strip leading markers: "-", "*", "•", "1.", "[ ]", "- [ ]", "☐", etc.
        func clean(_ raw: String) -> String? {
            var s = raw.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return nil }
            let markers = ["- [ ]", "- [x]", "* [ ]", "☐", "□", "•", "-", "*", "·"]
            for m in markers where s.hasPrefix(m) {
                s = String(s.dropFirst(m.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            // Numbered "1." / "1)" prefix.
            if let r = s.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
                s = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            // Drop markdown bold/headers that aren't tasks.
            s = s.replacingOccurrences(of: "**", with: "")
            return s.isEmpty || s.hasPrefix("#") ? nil : s
        }

        let markered = lines.filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("-") || t.hasPrefix("*") || t.hasPrefix("•") || t.hasPrefix("·")
                || t.hasPrefix("☐") || t.hasPrefix("□")
                || t.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) != nil
        }
        // Only export recognised list items — falling back to "every line" turns
        // prose ("Here are the next steps:") into junk reminders.
        return markered.compactMap(clean).filter { $0.count > 2 }
    }

    private func ensureList() -> EKCalendar? {
        let lists = store.calendars(for: .reminder)
        if let existing = lists.first(where: { $0.title == listName }) { return existing }
        // Create one in a source that actually hosts reminders (a CalDAV account
        // with only Calendar enabled would reject saveCalendar and pop an auth UI).
        guard let source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first(where: { !$0.calendars(for: .reminder).isEmpty }) else {
            return store.defaultCalendarForNewReminders()
        }
        let cal = EKCalendar(for: .reminder, eventStore: store)
        cal.title = listName
        cal.source = source
        do { try store.saveCalendar(cal, commit: true); return cal }
        catch { return store.defaultCalendarForNewReminders() }
    }

    /// Creates a reminder per item. `notePrefix` (e.g. the meeting title) is added
    /// to each reminder's notes for context. Returns the number created.
    @discardableResult
    func export(items: [String], meetingTitle: String?, dueDate: Date? = nil) async throws -> Int {
        let trimmed = items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { throw ExportError.nothingToExport }
        guard await requestAccess() else { throw ExportError.accessDenied }
        guard let list = ensureList() else { throw ExportError.noList }

        var created = 0
        for item in trimmed {
            let r = EKReminder(eventStore: store)
            r.calendar = list
            r.title = item
            if let title = meetingTitle, !title.isEmpty {
                r.notes = "From meeting: \(title)"
            }
            if let due = dueDate {
                r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            }
            do { try store.save(r, commit: false); created += 1 }
            catch { continue }
        }
        guard created > 0 else { throw ExportError.saveFailed }
        do { try store.commit() }
        catch { store.reset(); throw ExportError.saveFailed }
        return created
    }
}
