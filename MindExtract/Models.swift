import Foundation
import UserNotifications
import SwiftUI
import AVFoundation
import os

// MARK: - Diagnostic logging
//
// Routes diagnostics to the unified log (Console.app / `log stream`) instead of
// scattered print(). Debug level → not persisted to disk, so transcript-adjacent
// details never linger in system logs.
private let appLogger = Logger(subsystem: "com.mindact.mindextract", category: "app")
func appLog(_ message: String) { appLogger.debug("\(message, privacy: .public)") }

// MARK: - Video Format

struct VideoFormat: Identifiable, Hashable {
    let id: String
    let ext: String
    let resolution: String
    let filesize: String
    let filesizeBytes: Int64
    let note: String
    let isAudioOnly: Bool
    let isVideoOnly: Bool

    var displayName: String {
        if isAudioOnly {
            return "\(ext.uppercased()) — \(note) \(filesize)"
        } else if isVideoOnly {
            return "\(resolution) \(ext.uppercased()) (video only) \(filesize)"
        } else {
            return "\(resolution) \(ext.uppercased()) \(filesize)"
        }
    }
}

struct VideoInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let thumbnail: String?
    let duration: String
    let uploader: String
    let url: String
    var formats: [VideoFormat]

    static func == (lhs: VideoInfo, rhs: VideoInfo) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct PageScanResult {
    let title: String
    let videos: [VideoInfo]
}

enum DownloadState: Equatable {
    case idle
    case fetchingFormats
    case scanningPage
    case downloading(progress: Double, speed: String)
    case completed
    case error(String)
    case timeout(String)  // Shows when operation takes too long
}

enum AppMode {
    case singleVideo
    case pageScan
    case localFile
}

// MARK: - Local File

struct LocalFileInfo: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let name: String
    let size: Int64
    let duration: String?

    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.name = url.lastPathComponent

        // Get file size
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = attributes[.size] as? Int64 {
            self.size = fileSize
        } else {
            self.size = 0
        }

        // Try to get duration using AVFoundation
        self.duration = LocalFileInfo.getVideoDuration(url: url)
    }

    var sizeFormatted: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    private static func getVideoDuration(url: URL) -> String? {
        let asset = AVAsset(url: url)
        let duration = asset.duration
        let seconds = CMTimeGetSeconds(duration)

        if seconds.isNaN || seconds.isInfinite {
            return nil
        }

        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
}

// MARK: - Download Queue

struct QueueItem: Identifiable, Equatable {
    let id: UUID
    let url: String
    let title: String
    let thumbnail: String?
    var status: QueueItemStatus
    var progress: Double
    var speed: String
    var isAudioOnly: Bool

    init(url: String, title: String, thumbnail: String? = nil, isAudioOnly: Bool = false) {
        self.id = UUID()
        self.url = url
        self.title = title
        self.thumbnail = thumbnail
        self.status = .pending
        self.progress = 0
        self.speed = ""
        self.isAudioOnly = isAudioOnly
    }
}

enum QueueItemStatus: Equatable {
    case pending
    case downloading
    case completed
    case failed(String)
}

enum Platform: String, CaseIterable {
    case youtube = "YouTube"
    case twitter = "X (Twitter)"
    case linkedin = "LinkedIn"
    case facebook = "Facebook"
    case instagram = "Instagram"
    case tiktok = "TikTok"
    case other = "Other"

    static func detect(from url: String) -> Platform {
        let lowercased = url.lowercased()
        if lowercased.contains("youtube.com") || lowercased.contains("youtu.be") {
            return .youtube
        } else if lowercased.contains("twitter.com") || lowercased.contains("x.com") {
            return .twitter
        } else if lowercased.contains("linkedin.com") {
            return .linkedin
        } else if lowercased.contains("facebook.com") || lowercased.contains("fb.com") || lowercased.contains("fb.watch") {
            return .facebook
        } else if lowercased.contains("instagram.com") {
            return .instagram
        } else if lowercased.contains("tiktok.com") {
            return .tiktok
        }
        return .other
    }

    var icon: String {
        switch self {
        case .youtube: return "play.rectangle.fill"
        case .twitter: return "bird.fill"
        case .linkedin: return "briefcase.fill"
        case .facebook: return "person.2.fill"
        case .instagram: return "camera.fill"
        case .tiktok: return "music.note"
        case .other: return "globe"
        }
    }
}

// MARK: - Download History

struct HistoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    let url: String
    let title: String
    let thumbnail: String?
    let platform: String
    let downloadDate: Date
    let isAudioOnly: Bool
    let fileSize: String?
    // Added 2.1.4 — optional so older history (saved without them) still decodes.
    var filePath: String?
    var formatId: String?
    var resolution: String?

    init(url: String, title: String, thumbnail: String?, platform: Platform, isAudioOnly: Bool, fileSize: String? = nil, filePath: String? = nil, formatId: String? = nil, resolution: String? = nil) {
        self.id = UUID()
        self.url = url
        self.title = title
        self.thumbnail = thumbnail
        self.platform = platform.rawValue
        self.downloadDate = Date()
        self.isAudioOnly = isAudioOnly
        self.fileSize = fileSize
        self.filePath = filePath
        self.formatId = formatId
        self.resolution = resolution
    }

    /// True only when we recorded a path AND the file is still on disk. Old
    /// items without a path return nil-ish (treated as "unknown", not missing).
    var fileExists: Bool {
        guard let filePath else { return true }   // unknown → don't flag as missing
        return FileManager.default.fileExists(atPath: filePath)
    }

    var hasKnownPath: Bool { filePath != nil }
}

// MARK: - App Settings

// MARK: - Transcription Engine Choice

/// Which on-device transcription engine to use.
/// - automatic: Apple SpeechAnalyzer on macOS 26+, else WhisperKit.
/// - appleSpeech: force Apple SpeechAnalyzer (macOS 26+ only).
/// - whisperKit: force WhisperKit (works on all supported macOS versions).
enum TranscriptionEngineChoice: String, CaseIterable, Codable, Identifiable {
    case automatic = "Automatic"
    case appleSpeech = "Apple Speech"
    case whisperKit = "WhisperKit"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .automatic: return "Apple's built-in speech on macOS 26+, otherwise WhisperKit"
        case .appleSpeech: return "Fast, free, no model download (requires macOS 26)"
        case .whisperKit: return "Open-source Whisper models, works on all Macs"
        }
    }
}

// MARK: - Whisper Transcription Models (WhisperKit Core ML)

enum WhisperModel: String, CaseIterable, Codable, Identifiable {
    case tiny = "openai_whisper-tiny"
    case base = "openai_whisper-base"
    case small = "openai_whisper-small"
    case medium = "openai_whisper-medium"
    case largev3 = "openai_whisper-large-v3"
    case largev3turbo = "openai_whisper-large-v3_turbo"
    // KB-Whisper (KBLab / National Library of Sweden) — Swedish-optimized, beats
    // OpenAI Whisper on Swedish. Distributed as WhisperKit Core ML by mickekringai
    // (repo ships base/small/medium/large variants).
    case kbWhisperBase = "kb_whisper-base"
    case kbWhisperSmall = "kb_whisper-small"
    case kbWhisperMedium = "kb_whisper-medium"
    case kbWhisperLarge = "kb_whisper-large"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .small: return "Small"
        case .medium: return "Medium"
        case .largev3: return "Large v3"
        case .largev3turbo: return "Large v3 Turbo"
        case .kbWhisperBase: return "KB-Whisper Base (Swedish)"
        case .kbWhisperSmall: return "KB-Whisper Small (Swedish)"
        case .kbWhisperMedium: return "KB-Whisper Medium (Swedish)"
        case .kbWhisperLarge: return "KB-Whisper Large (Swedish)"
        }
    }

    var sizeDescription: String {
        switch self {
        case .tiny: return "~70 MB"
        case .base: return "~150 MB"
        case .small: return "~500 MB"
        case .medium: return "~1.5 GB"
        case .largev3: return "~3 GB"
        case .largev3turbo: return "~1.6 GB"
        case .kbWhisperBase: return "~150 MB"
        case .kbWhisperSmall: return "~500 MB"
        case .kbWhisperMedium: return "~1.5 GB"
        case .kbWhisperLarge: return "~3 GB"
        }
    }

    var sizeInBytes: Int64 {
        switch self {
        case .tiny: return 70_000_000
        case .base: return 150_000_000
        case .small: return 500_000_000
        case .medium: return 1_500_000_000
        case .largev3: return 3_000_000_000
        case .largev3turbo: return 1_600_000_000
        case .kbWhisperBase: return 150_000_000
        case .kbWhisperSmall: return 500_000_000
        case .kbWhisperMedium: return 1_500_000_000
        case .kbWhisperLarge: return 3_000_000_000
        }
    }

    var description: String {
        switch self {
        case .tiny: return "Fastest, basic accuracy"
        case .base: return "Good balance of speed and accuracy"
        case .small: return "Better accuracy, moderate speed"
        case .medium: return "High accuracy, slower"
        case .largev3: return "Best accuracy, requires more RAM"
        case .largev3turbo: return "Near-best accuracy, optimized speed"
        case .kbWhisperBase: return "Fast Swedish, small download"
        case .kbWhisperSmall: return "Best Swedish accuracy at this size — beats OpenAI Large on Swedish"
        case .kbWhisperMedium: return "Higher Swedish accuracy, slower"
        case .kbWhisperLarge: return "Highest Swedish accuracy, requires more RAM"
        }
    }

    var isRecommended: Bool {
        self == .small
    }

    /// Swedish-only fine-tunes — should only be offered when transcribing Swedish.
    var isSwedishOnly: Bool {
        rawValue.hasPrefix("kb_whisper-")
    }

    /// HuggingFace repo the WhisperKit Core ML files come from.
    var repo: String {
        isSwedishOnly ? "mickekringai/kb-whisper-coreml" : "argmaxinc/whisperkit-coreml"
    }

    /// Variant folder name inside `repo` (KB folders are "base"/"small"/… — the
    /// rawValue without the "kb_whisper-" prefix).
    var variant: String {
        isSwedishOnly ? String(rawValue.dropFirst("kb_whisper-".count)) : rawValue
    }

    /// The best default model for a given spoken language — KB-Whisper for Swedish.
    static func recommended(for language: String) -> WhisperModel {
        language == "sv" ? .kbWhisperSmall : .small
    }

    /// The WhisperKit model identifier used for download/init
    var whisperKitModelId: String {
        variant
    }
}

enum TranscriptionOutputFormat: String, CaseIterable, Codable {
    case txt = "txt"
    case srt = "srt"
    case vtt = "vtt"
    case json = "json"

    var displayName: String {
        switch self {
        case .txt: return "Plain Text (.txt)"
        case .srt: return "Subtitles (.srt)"
        case .vtt: return "WebVTT (.vtt)"
        case .json: return "JSON (.json)"
        }
    }
}

// MARK: - Transcription Segment Data

struct TranscriptionSegmentData: Identifiable {
    let id = UUID()
    let start: Float
    let end: Float
    var text: String          // editable in the transcript editor
    var speaker: String?
    let words: [WordTimingData]
    let avgLogprob: Float

    var formattedStart: String { formatTimestamp(start) }
    var formattedEnd: String { formatTimestamp(end) }
    var formattedRange: String { "\(formattedStart) → \(formattedEnd)" }
    var duration: Float { end - start }

    /// Confidence 0–1 derived from avgLogprob (higher = more confident)
    var confidence: Double {
        // avgLogprob ranges roughly from -2 (bad) to 0 (perfect)
        let clamped = max(min(Double(avgLogprob), 0), -2)
        return (clamped + 2) / 2  // maps [-2,0] → [0,1]
    }

    private func formatTimestamp(_ seconds: Float) -> String {
        let totalSeconds = Int(seconds)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        let ms = Int((seconds - Float(totalSeconds)) * 10)
        if h > 0 {
            return String(format: "%d:%02d:%02d.%d", h, m, s, ms)
        }
        return String(format: "%d:%02d.%d", m, s, ms)
    }
}

struct WordTimingData: Identifiable {
    let id = UUID()
    let word: String
    let start: Float
    let end: Float
    let probability: Float // 0–1 confidence
}

enum YouTubeSignInState: Equatable {
    case idle
    case signingIn
    case signedIn
    case error(String)
}

enum CookieBrowser: String, CaseIterable, Codable {
    case none = "none"
    case safari = "safari"
    case chrome = "chrome"
    case firefox = "firefox"
    case brave = "brave"
    case edge = "edge"

    var displayName: String {
        switch self {
        case .none: return "None"
        case .safari: return "Safari"
        case .chrome: return "Chrome"
        case .firefox: return "Firefox"
        case .brave: return "Brave"
        case .edge: return "Edge"
        }
    }
}

enum TranscriptionState: Equatable {
    case idle
    case downloadingAudio(progress: Double)  // Downloading video/audio from URL
    case loadingModel(modelName: String = "")
    case extractingAudio
    case transcribing(progress: Double)
    case completed(outputPath: String)
    case error(String)
    case modelNotDownloaded
}

/// Preferred quality for the "best" download path.
enum DownloadQuality: String, CaseIterable, Identifiable, Codable {
    case best, hd1080, hd720, audioOnly
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .best: return "Best available"
        case .hd1080: return "1080p max"
        case .hd720: return "720p max"
        case .audioOnly: return "Audio only"
        }
    }
}

@MainActor
class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("downloadSubtitles") var downloadSubtitles: Bool = false
    @AppStorage("subtitleLanguage") var subtitleLanguage: String = "en"
    @AppStorage("parallelDownloads") var parallelDownloads: Int = 2
    @AppStorage("playSoundOnComplete") var playSoundOnComplete: Bool = true
    @AppStorage("showNotifications") var showNotifications: Bool = true
    @AppStorage("downloadPath") var downloadPath: String = NSHomeDirectory() + "/Downloads"

    // YouTube authentication
    @AppStorage("youtubeSignedIn") var youtubeSignedIn: Bool = false

    // Fallback: Browser cookies for authentication
    @AppStorage("cookieBrowser") var cookieBrowser: CookieBrowser = .none
    @AppStorage("cookiesFilePath") var cookiesFilePath: String = ""

    // Transcription settings
    @AppStorage("defaultWhisperModel") var defaultWhisperModel: WhisperModel = .small
    @AppStorage("transcriptionOutputFormat") var transcriptionOutputFormat: TranscriptionOutputFormat = .txt
    @AppStorage("enableSpeakerDiarization") var enableSpeakerDiarization: Bool = true
    @AppStorage("transcriptionEngine") var transcriptionEngine: TranscriptionEngineChoice = .automatic
    /// After a meeting recording finishes transcribing, auto-generate Meeting
    /// Minutes + Action Items so the user gets finished notes with no extra click.
    @AppStorage("autoGenerateMeetingNotes") var autoGenerateMeetingNotes: Bool = true
    /// WhisperKit-only: translate speech directly to English while transcribing
    /// (Whisper's built-in translate task — runs on-device, English target only).
    @AppStorage("translateToEnglish") var translateToEnglish: Bool = false
    /// Custom vocabulary — names and domain terms (one per line or comma-separated)
    /// fed to WhisperKit as a conditioning prompt so it spells them correctly.
    @AppStorage("customVocabulary") var customVocabulary: String = ""

    // MARK: Calendar (meeting auto-detection)
    /// The app's own on/off switch — lets the user stop MindExtract from using
    /// the calendar without revoking the macOS permission (only System Settings
    /// can revoke TCC). Off = no meeting suggestions anywhere in the app.
    @AppStorage("calendarSuggestionsEnabled") var calendarSuggestionsEnabled: Bool = true
    /// How many minutes ahead of a meeting's start we begin suggesting it.
    @AppStorage("calendarLeadMinutes") var calendarLeadMinutes: Int = 5
    /// Comma-separated EKCalendar identifiers to NOT scan. Empty = scan all.
    @AppStorage("excludedCalendarIDs") var excludedCalendarIDs: String = ""
    var excludedCalendarIDSet: Set<String> {
        Set(excludedCalendarIDs.split(separator: ",").map(String.init))
    }
    func setCalendarExcluded(_ id: String, _ excluded: Bool) {
        var s = excludedCalendarIDSet
        if excluded { s.insert(id) } else { s.remove(id) }
        excludedCalendarIDs = s.sorted().joined(separator: ",")
    }

    // MARK: Recording
    /// Automatically show the floating live-caption window when a recording starts.
    @AppStorage("autoShowCaptions") var autoShowCaptions: Bool = false
    /// Detect when a call app (Zoom, Teams, …) is in an active call and offer to
    /// record it — provider-agnostic, complements calendar detection.
    @AppStorage("detectActiveMeetings") var detectActiveMeetings: Bool = true
    /// Auto-start recording when a meeting/call is detected (opt-in; thoughtless
    /// capture). The user can stop with one tap.
    @AppStorage("autoRecordMeetings") var autoRecordMeetings: Bool = false
    /// Notify "in a call — record it?" when a meeting is detected and MindExtract
    /// is in the background, so you don't have to be looking at the app.
    @AppStorage("meetingNudge") var meetingNudge: Bool = true
    /// Preferred microphone uniqueID for meeting recording. Empty = follow the
    /// macOS system default (auto-switches to AirPods etc.).
    @AppStorage("preferredMicrophoneID") var preferredMicrophoneID: String = ""

    // MARK: Downloads (quality + automation)
    /// Preferred quality for the "best" download path. Explicit format picks in
    /// the UI are respected as-is and ignore this.
    @AppStorage("downloadQuality") var downloadQuality: DownloadQuality = .best
    /// Start transcription automatically once a download finishes.
    @AppStorage("autoTranscribeOnDownload") var autoTranscribeOnDownload: Bool = false

    // MARK: Notifications
    /// Post a notification when a transcription finishes.
    @AppStorage("notifyOnTranscriptionComplete") var notifyOnTranscriptionComplete: Bool = true

    // MARK: Branding (professional PDF deliverables)
    /// Business/practice name printed as the PDF letterhead.
    @AppStorage("brandName") var brandName: String = ""
    /// Path to a logo image (PNG/JPG) shown in the PDF letterhead.
    @AppStorage("brandLogoPath") var brandLogoPath: String = ""

    // MARK: Privacy & security
    /// Require Touch ID / device password to open the app.
    @AppStorage("appLockEnabled") var appLockEnabled: Bool = false

    // AI summaries & chat
    @AppStorage("aiBackend") var aiBackend: AIBackendChoice = .apple
    @AppStorage("ollamaModel") var ollamaModel: String = ""
    @AppStorage("openAIModel") var openAIModel: String = "gpt-4o-mini"
    @AppStorage("anthropicModel") var anthropicModel: String = "claude-haiku-4-5-20251001"
    @AppStorage("geminiModel") var geminiModel: String = "gemini-2.5-flash"
    @AppStorage("grokModel") var grokModel: String = "grok-4.3"
    @AppStorage("mistralModel") var mistralModel: String = "mistral-small-latest"
    @AppStorage("groqModel") var groqModel: String = "openai/gpt-oss-120b"
    @AppStorage("openRouterModel") var openRouterModel: String = "google/gemini-2.5-flash"
    @AppStorage("customBaseURL") var customBaseURL: String = ""
    @AppStorage("customModel") var customModel: String = ""

    // Default language a new transcription starts with (the picker pre-selects it).
    @AppStorage("defaultTranscriptionLanguage") var defaultTranscriptionLanguage: String = "auto"

    /// The languages offered for transcription (shared by the start sheet and Settings).
    static let transcriptionLanguages: [(name: String, code: String)] = [
        ("Auto-detect", "auto"), ("English", "en"), ("Swedish", "sv"),
        ("Spanish", "es"), ("French", "fr"), ("German", "de"),
        ("Portuguese", "pt"), ("Japanese", "ja"), ("Chinese", "zh"),
        ("Korean", "ko"), ("Italian", "it"), ("Dutch", "nl"),
        ("Russian", "ru"), ("Arabic", "ar"), ("Hindi", "hi")
    ]

    private init() {}
}

// MARK: - Transcription History Item

/// Where a transcript came from — drives the type badge + filter in the list.
enum TranscriptSource: String, Codable, CaseIterable {
    case meeting, download, file

    var displayName: String {
        switch self {
        case .meeting: return "Meeting"
        case .download: return "Download"
        case .file: return "File"
        }
    }
    var icon: String {
        switch self {
        case .meeting: return "person.2.wave.2.fill"
        case .download: return "arrow.down.circle.fill"
        case .file: return "doc.fill"
        }
    }
    var tint: Color {
        switch self {
        case .meeting: return .green
        case .download: return .blue
        case .file: return .orange
        }
    }
}

struct TranscriptionHistoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    let filePath: String
    let transcriptionDate: Date
    let duration: String?
    let modelUsed: String
    /// Optional so older saved history (without the key) still decodes. nil = not starred.
    var isFavorite: Bool?
    /// Source category (meeting/download/file). Optional for backward compat.
    var source: String?
    var sourceType: TranscriptSource? { source.flatMap(TranscriptSource.init(rawValue:)) }

    init(title: String, filePath: String, duration: String? = nil, modelUsed: String) {
        self.id = UUID()
        self.title = title
        self.filePath = filePath
        self.transcriptionDate = Date()
        self.duration = duration
        self.modelUsed = modelUsed
    }

    var fileExists: Bool {
        FileManager.default.fileExists(atPath: filePath)
    }

    var transcriptionText: String? {
        guard fileExists else { return nil }
        return try? String(contentsOfFile: filePath, encoding: .utf8)
    }
}

// MARK: - History Manager

/// Resolves a JSON file URL inside `~/Library/Application Support/MindExtract/`,
/// creating the directory if needed. Used for history persistence so we don't
/// store growing JSON blobs in UserDefaults (which Apple caps at a few KB).
private func historyFileURL(named fileName: String) -> URL {
    let fm = FileManager.default
    let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
        ?? fm.temporaryDirectory
    let dir = base.appendingPathComponent("MindExtract", isDirectory: true)
    if !fm.fileExists(atPath: dir.path) {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return dir.appendingPathComponent(fileName)
}

@MainActor
class HistoryManager: ObservableObject {
    static let shared = HistoryManager()

    @Published var history: [HistoryItem] = []

    private let fileURL = historyFileURL(named: "downloadHistory.json")
    private let legacyKey = "downloadHistory"
    private let maxHistoryItems = 100
    private let ioQueue = DispatchQueue(label: "com.mindact.mindextract.history.download")

    private init() {
        loadHistory()
    }

    func addToHistory(_ item: HistoryItem) {
        // Remove duplicate if exists
        history.removeAll { $0.url == item.url }

        // Add to beginning
        history.insert(item, at: 0)

        // Trim to max size
        if history.count > maxHistoryItems {
            history = Array(history.prefix(maxHistoryItems))
        }

        saveHistory()
    }

    func removeFromHistory(_ item: HistoryItem) {
        history.removeAll { $0.id == item.id }
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    private func saveHistory() {
        // Write off the main thread; atomic write avoids partial/corrupt files.
        let snapshot = history
        ioQueue.async { [fileURL] in
            if let encoded = try? JSONEncoder().encode(snapshot) {
                try? encoded.write(to: fileURL, options: .atomic)
            }
        }
    }

    private func loadHistory() {
        // Prefer the JSON file.
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            history = decoded
            return
        }
        // One-time migration from the legacy UserDefaults blob.
        if let data = UserDefaults.standard.data(forKey: legacyKey),
           let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            history = decoded
            saveHistory()
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
    }
}

// MARK: - Transcription History Manager

@MainActor
class TranscriptionHistoryManager: ObservableObject {
    static let shared = TranscriptionHistoryManager()

    @Published var history: [TranscriptionHistoryItem] = []

    private let fileURL = historyFileURL(named: "transcriptionHistory.json")
    private let legacyKey = "transcriptionHistory"
    private let maxHistoryItems = 50
    private let ioQueue = DispatchQueue(label: "com.mindact.mindextract.history.transcription")

    private init() {
        loadHistory()
    }

    func addToHistory(_ item: TranscriptionHistoryItem) {
        // Remove duplicate if exists (same file path)
        history.removeAll { $0.filePath == item.filePath }

        // Add to beginning
        history.insert(item, at: 0)

        // Trim to max size
        if history.count > maxHistoryItems {
            history = Array(history.prefix(maxHistoryItems))
        }

        saveHistory()
    }

    func removeFromHistory(_ item: TranscriptionHistoryItem) {
        history.removeAll { $0.id == item.id }
        TranscriptLibrary.shared.evict(path: item.filePath)
        saveHistory()
    }

    func rename(_ item: TranscriptionHistoryItem, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = history.firstIndex(where: { $0.id == item.id }) else { return }
        history[idx].title = trimmed
        saveHistory()
    }

    func toggleFavorite(_ item: TranscriptionHistoryItem) {
        guard let idx = history.firstIndex(where: { $0.id == item.id }) else { return }
        history[idx].isFavorite = !(history[idx].isFavorite ?? false)
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        TranscriptLibrary.shared.evictAll()
        saveHistory()
    }

    private func saveHistory() {
        let snapshot = history
        ioQueue.async { [fileURL] in
            if let encoded = try? JSONEncoder().encode(snapshot) {
                try? encoded.write(to: fileURL, options: .atomic)
            }
        }
    }

    private func loadHistory() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([TranscriptionHistoryItem].self, from: data) {
            history = decoded
            return
        }
        if let data = UserDefaults.standard.data(forKey: legacyKey),
           let decoded = try? JSONDecoder().decode([TranscriptionHistoryItem].self, from: data) {
            history = decoded
            saveHistory()
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
    }
}
