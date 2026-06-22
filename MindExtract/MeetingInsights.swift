import SwiftUI

// MARK: - Meeting intelligence (talk-time + insights)
//
// Turns diarized segments into at-a-glance meeting stats: who talked how much,
// how many turns each took, questions asked, and the longest single monologue.
// Computed entirely on-device from data we already have. Speaker labels are
// resolved through the user's custom names ("Speaker 1" → "Anna", "You").

struct MeetingInsights {
    struct SpeakerStat: Identifiable {
        let name: String
        let seconds: Double
        let fraction: Double      // 0…1 of total talk time
        let turns: Int            // contiguous runs where this speaker held the floor
        let questions: Int        // segments containing "?"
        let colorIndex: Int       // stable, by first appearance — survives re-sorts/renames
        var id: String { name }
    }

    let speakers: [SpeakerStat]   // sorted by talk time, descending
    let totalSeconds: Double
    let longestMonologue: (speaker: String, seconds: Double)?

    var speakerCount: Int { speakers.count }

    /// Returns nil when there isn't enough labeled data to be meaningful (< 2 speakers).
    static func compute(from segments: [TranscriptionSegmentData],
                        displayName: (String) -> String) -> MeetingInsights? {
        // Map each labeled segment to its display name, in chronological order
        // (diarization doesn't guarantee the array is time-sorted).
        let labeled: [(name: String, seconds: Double, isQuestion: Bool)] = segments
            .filter { $0.speaker != nil }
            .sorted { $0.start < $1.start }
            .map { seg in
                (displayName(seg.speaker!), max(0, Double(seg.end - seg.start)), seg.text.contains("?"))
            }
        guard !labeled.isEmpty else { return nil }

        var seconds: [String: Double] = [:]
        var questions: [String: Int] = [:]
        var colorIndex: [String: Int] = [:]   // first-appearance order → stable color
        for item in labeled {
            seconds[item.name, default: 0] += item.seconds
            if item.isQuestion { questions[item.name, default: 0] += 1 }
            if colorIndex[item.name] == nil { colorIndex[item.name] = colorIndex.count }
        }

        // Turns + longest monologue: walk the ordered segments, collapsing
        // consecutive same-speaker segments into one "run".
        var turns: [String: Int] = [:]
        var longest: (String, Double)? = nil
        var runSpeaker: String? = nil
        var runSeconds: Double = 0
        func closeRun() {
            guard let s = runSpeaker else { return }
            turns[s, default: 0] += 1
            if runSeconds > (longest?.1 ?? -.infinity) { longest = (s, runSeconds) }
        }
        for item in labeled {
            if item.name == runSpeaker {
                runSeconds += item.seconds
            } else {
                closeRun()
                runSpeaker = item.name
                runSeconds = item.seconds
            }
        }
        closeRun()

        let total = seconds.values.reduce(0, +)
        guard total > 0 else { return nil }

        let stats = seconds.map { (name, secs) in
            SpeakerStat(name: name,
                        seconds: secs,
                        fraction: secs / total,
                        turns: turns[name] ?? 0,
                        questions: questions[name] ?? 0,
                        colorIndex: colorIndex[name] ?? 0)
        }.sorted { $0.seconds > $1.seconds }

        guard stats.count >= 2 else { return nil }
        return MeetingInsights(speakers: stats,
                               totalSeconds: total,
                               longestMonologue: longest.map { ($0.0, $0.1) })
    }

    static func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Insights card

struct MeetingInsightsCard: View {
    let insights: MeetingInsights

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 12)).foregroundStyle(DS.Colors.accent)
                Text("Talk time").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                Text("\(insights.speakerCount) speakers · \(MeetingInsights.formatDuration(insights.totalSeconds)) spoken")
                    .font(.caption2).foregroundColor(.secondary.opacity(0.8))
            }

            // Stacked proportional bar (no per-bar minimum, so widths sum to 100%).
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(insights.speakers) { s in
                        Rectangle()
                            .fill(SpeakerColors.color(for: s.name, fallbackIndex: s.colorIndex))
                            .frame(width: geo.size.width * s.fraction)
                    }
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())

            // Per-speaker rows.
            VStack(spacing: 8) {
                ForEach(insights.speakers) { s in
                    HStack(spacing: 8) {
                        Circle().fill(SpeakerColors.color(for: s.name, fallbackIndex: s.colorIndex)).frame(width: 8, height: 8)
                        Text(s.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            .frame(maxWidth: 130, alignment: .leading)
                        Spacer()
                        Text("\(Int((s.fraction * 100).rounded()))%")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                        Text(MeetingInsights.formatDuration(s.seconds))
                            .font(.caption).foregroundColor(.secondary).frame(width: 52, alignment: .trailing)
                        Label("\(s.turns)", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption2).foregroundColor(.secondary).frame(width: 44, alignment: .trailing)
                            .help("Turns (times this person took the floor)")
                        Label("\(s.questions)", systemImage: "questionmark")
                            .font(.caption2).foregroundColor(.secondary).frame(width: 36, alignment: .trailing)
                            .help("Questions asked")
                    }
                }
            }

            if let m = insights.longestMonologue, m.seconds > 20 {
                Divider().opacity(0.4)
                HStack(spacing: 6) {
                    Image(systemName: "megaphone").font(.caption2).foregroundColor(.secondary)
                    Text("Longest monologue: \(m.speaker) · \(MeetingInsights.formatDuration(m.seconds))")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.Colors.hairline, lineWidth: 1))
    }
}
