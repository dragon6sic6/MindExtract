import Foundation

// MARK: - Meeting commitments (legacy)

/// A commitment parsed from a brief. No longer produced, but kept so older AI
/// sidecars that stored commitments still decode.
struct MeetingCommitment: Codable, Hashable {
    var task: String
    var owner: String?
    var dueISO: String?
    var dueText: String?
    var deleted: Bool?
    var dueOverrideISO: String?
    var snoozedUntilISO: String?
}
