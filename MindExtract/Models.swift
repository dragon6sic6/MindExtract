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
            return "\(ext.uppercased()) · \(note) \(filesize)"
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

    /// Plain-language name for the picker.
    var displayName: String {
        switch self {
        case .automatic: return String(localized: "Automatic")
        case .appleSpeech: return String(localized: "Apple")
        case .whisperKit: return String(localized: "Whisper")
        }
    }

    var detail: String {
        switch self {
        case .automatic: return String(localized: "Picks the best engine for each language. Swedish uses Pianissimo when it's downloaded.")
        case .appleSpeech: return String(localized: "Apple's built-in speech recognition. No download needed.")
        case .whisperKit: return String(localized: "Downloadable Whisper models. Supports the most languages.")
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
    // Klang Pianissimo (Klang AI AB, CC BY 4.0) — Swedish Parakeet-TDT model run
    // through FluidAudio, not WhisperKit. See PianissimoEngine.
    case pianissimo = "pianissimo-sv"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .small: return "Small"
        case .medium: return "Medium"
        case .largev3: return "Large v3"
        case .largev3turbo: return "Large v3 Turbo"
        case .pianissimo: return String(localized: "Pianissimo (Swedish)")
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
        case .pianissimo: return "~690 MB"
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
        case .pianissimo: return 690_000_000
        }
    }

    var description: String {
        switch self {
        case .tiny: return String(localized: "Fastest, basic accuracy")
        case .base: return String(localized: "Good balance of speed and accuracy")
        case .small: return String(localized: "Better accuracy, moderate speed")
        case .medium: return String(localized: "High accuracy, slower")
        case .largev3: return String(localized: "Best accuracy, requires more RAM")
        case .largev3turbo: return String(localized: "Near-best accuracy, optimized speed")
        case .pianissimo: return String(localized: "Best Swedish. Trained by Klang AI, fast and punctuated")
        }
    }

    var isRecommended: Bool {
        self == .small
    }

    /// Swedish-only models — should only be offered when transcribing Swedish.
    var isSwedishOnly: Bool {
        self == .pianissimo
    }

    /// Runs on WhisperKit (vs. Pianissimo on FluidAudio). Only WhisperKit models can
    /// detect language, translate, or drive the live preview.
    var usesWhisperKit: Bool {
        self != .pianissimo
    }

    /// HuggingFace repo the WhisperKit Core ML files come from.
    var repo: String {
        usesWhisperKit ? "argmaxinc/whisperkit-coreml" : PianissimoEngine.repo
    }

    /// Variant folder name inside `repo`.
    var variant: String {
        rawValue
    }

    /// The best default model for a given spoken language — Pianissimo for Swedish.
    static func recommended(for language: String) -> WhisperModel {
        language == "sv" ? .pianissimo : .small
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
        case .txt: return String(localized: "Plain Text (.txt)")
        case .srt: return String(localized: "Subtitles (.srt)")
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

enum CookieBrowser: String, CaseIterable, Codable {
    case none = "none"
    case safari = "safari"
    case chrome = "chrome"
    case firefox = "firefox"
    case brave = "brave"
    case edge = "edge"

    var displayName: String {
        switch self {
        case .none: return String(localized: "None")
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
        case .best: return String(localized: "Best available")
        case .hd1080: return String(localized: "1080p max")
        case .hd720: return String(localized: "720p max")
        case .audioOnly: return String(localized: "Audio only")
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

    // Signing in: a browser's cookies, or an exported cookies file
    @AppStorage("cookieBrowser") var cookieBrowser: CookieBrowser = .none
    @AppStorage("cookiesFilePath") var cookiesFilePath: String = ""

    // Transcription settings
    @AppStorage("defaultWhisperModel") var defaultWhisperModel: WhisperModel = .small
    @AppStorage("transcriptionOutputFormat") var transcriptionOutputFormat: TranscriptionOutputFormat = .txt
    @AppStorage("enableSpeakerDiarization") var enableSpeakerDiarization: Bool = true
    @AppStorage("transcriptionEngine") var transcriptionEngine: TranscriptionEngineChoice = .automatic
    /// WhisperKit-only: translate speech directly to English while transcribing
    /// (Whisper's built-in translate task — runs on-device, English target only).
    @AppStorage("translateToEnglish") var translateToEnglish: Bool = false
    /// Custom vocabulary — names and domain terms (one per line or comma-separated)
    /// fed to WhisperKit as a conditioning prompt so it spells them correctly.
    @AppStorage("customVocabulary") var customVocabulary: String = ""
    /// "system" (default), "light" or "dark".
    @AppStorage("appAppearance") var appAppearance: String = "system"

    // MARK: Downloads (quality + automation)
    /// Preferred quality for the "best" download path. Explicit format picks in
    /// the UI are respected as-is and ignore this.
    @AppStorage("downloadQuality") var downloadQuality: DownloadQuality = .best

    // MARK: Notifications
    /// Post a notification when a transcription finishes.
    @AppStorage("notifyOnTranscriptionComplete") var notifyOnTranscriptionComplete: Bool = true

    // MARK: Notch
    /// Copy a finished transcript automatically (only if the clipboard wasn't used meanwhile).
    @AppStorage("autoCopyWhenDone") var autoCopyWhenDone: Bool = true
    /// Copy with "[00:12]" before each passage.
    @AppStorage("copyWithTimestamps") var copyWithTimestamps: Bool = false
    /// "notch" = the screen with the notch (or the main one), "main" = the screen with the menu bar.
    @AppStorage("notchScreen") var notchScreen: String = "notch"

    // Default language a new transcription starts with (the picker pre-selects it).
    @AppStorage("defaultTranscriptionLanguage") var defaultTranscriptionLanguage: String = "auto"

    /// The languages offered for transcription (shared by every language picker).
    /// Names come from the system, so they read naturally in the UI language.
    static var transcriptionLanguages: [(name: String, code: String)] {
        let codes = ["en", "sv", "no", "da", "fi", "de", "fr", "es", "it", "nl", "pt",
                     "pl", "ru", "ar", "hi", "ja", "ko", "zh"]
        let named = codes.map { code in
            (name: Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code, code: code)
        }
        let sorted = named.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        return [(name: String(localized: "Automatic"), code: "auto")] + sorted
    }

    /// Every preference "Reset all settings" restores. Transcripts, API keys
    /// and sign-ins are not preferences and are never touched.
    static let resettableKeys = [
        "downloadSubtitles", "subtitleLanguage", "parallelDownloads", "playSoundOnComplete", "showNotifications",
        "downloadPath", "cookieBrowser", "cookiesFilePath", "defaultWhisperModel", "transcriptionOutputFormat",
        "enableSpeakerDiarization", "transcriptionEngine", "translateToEnglish",
        "customVocabulary", "appAppearance", "downloadQuality", "notifyOnTranscriptionComplete",
        "defaultTranscriptionLanguage", "autoCopyWhenDone", "copyWithTimestamps", "notchScreen",
        "settingsCategory",
    ]

    /// Restores every preference to its default.
    func resetToDefaults() {
        objectWillChange.send()
        for key in Self.resettableKeys { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// Tidies settings left by older versions. Runs once per launch, cheap.
    func migrate() {
        let d = UserDefaults.standard
        d.removeObject(forKey: "youtubeSignedIn")           // YouTube ended yt-dlp's own login
        if translateToEnglish { translateToEnglish = false } // no switch for it in 3.0
        if downloadQuality == .audioOnly { downloadQuality = .best }   // the notch chooses audio now
        if transcriptionEngine == .automatic { transcriptionEngine = .appleSpeech }
        if subtitleLanguage == "auto" { subtitleLanguage = "en" }      // yt-dlp has no "auto" subtitles
    }

    private init() {}
}

// MARK: - Transcription History Item

/// Where a transcript came from — drives the type badge + filter in the list.
/// `meeting` is kept only so older history still decodes; meeting recordings
/// aren't shown anymore.
enum TranscriptSource: String, Codable, CaseIterable {
    case meeting, download, file

    var displayName: String {
        switch self {
        case .meeting: return String(localized: "Meeting")
        case .download: return String(localized: "Link")
        case .file: return String(localized: "File")
        }
    }
    var icon: String {
        switch self {
        case .meeting: return "person.2.wave.2"
        case .download: return "link"
        case .file: return "doc"
        }
    }
    /// One quiet hue per kind — the same everywhere a transcript is listed.
    var tint: Color {
        switch self {
        case .meeting: return Color(nsColor: .systemIndigo)
        case .download: return Color(nsColor: .systemTeal)
        case .file: return Color(nsColor: .systemOrange)
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
    /// The link a transcript was made from, so copying it later keeps the source.
    var sourceURL: String?
    /// Thumbnail and channel of that link, so reopening it looks the same.
    var thumbnailURL: String?
    var channel: String?
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
    /// Meeting recordings from older versions. Not shown, but written back on
    /// save so the history file never loses them.
    private var hiddenMeetings: [TranscriptionHistoryItem] = []

    /// Where 2.x kept meeting recordings.
    static var recordingsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mindact.mindextract/Recordings", isDirectory: true)
    }

    /// Someone coming from 2.x who recorded meetings.
    var hasOldMeetings: Bool {
        if !hiddenMeetings.isEmpty { return true }
        let items = (try? FileManager.default.contentsOfDirectory(atPath: Self.recordingsFolder.path)) ?? []
        return items.contains { !$0.hasPrefix(".") }
    }

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

    func setSource(url: String?, thumbnail: String?, channel: String?, forPath path: String) {
        guard let i = history.firstIndex(where: { $0.filePath == path }) else { return }
        history[i].sourceURL = url
        history[i].thumbnailURL = thumbnail
        history[i].channel = channel
        saveHistory()
    }

    func removeFromHistory(_ item: TranscriptionHistoryItem) {
        history.removeAll { $0.id == item.id }
        saveHistory()
    }

    /// Moves notes to the Trash (recoverable there): the transcript and its
    /// sidecars — and for a recording, its whole session folder with the audio.
    /// A downloaded video next to a transcript is a download, not the note, so
    /// it stays.
    func moveToTrash(_ items: [TranscriptionHistoryItem]) {
        let fm = FileManager.default
        let recordings = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mindact.mindextract/Recordings", isDirectory: true)
            .standardizedFileURL.path
        for item in items {
            let file = URL(fileURLWithPath: item.filePath)
            let dir = file.deletingLastPathComponent()
            if dir.deletingLastPathComponent().standardizedFileURL.path == recordings {
                try? fm.trashItem(at: dir, resultingItemURL: nil)
            } else {
                for suffix in ["", ".segments.json", ".mindex-ai.json"] {
                    let url = URL(fileURLWithPath: item.filePath + suffix)
                    if fm.fileExists(atPath: url.path) { try? fm.trashItem(at: url, resultingItemURL: nil) }
                }
            }
        }
        let ids = Set(items.map(\.id))
        history.removeAll { ids.contains($0.id) }
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
        saveHistory()
    }

    private func saveHistory() {
        let snapshot = history + hiddenMeetings
        ioQueue.async { [fileURL] in
            if let encoded = try? JSONEncoder().encode(snapshot) {
                try? encoded.write(to: fileURL, options: .atomic)
            }
        }
    }

    private func setLoaded(_ items: [TranscriptionHistoryItem]) {
        // Older meetings may have no source; they live in the Recordings folder.
        func isMeeting(_ i: TranscriptionHistoryItem) -> Bool {
            i.sourceType == .meeting || i.filePath.contains("/com.mindact.mindextract/Recordings/")
        }
        hiddenMeetings = items.filter(isMeeting)
        history = items.filter { !isMeeting($0) }
    }

    private func loadHistory() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([TranscriptionHistoryItem].self, from: data) {
            setLoaded(decoded)
            return
        }
        if let data = UserDefaults.standard.data(forKey: legacyKey),
           let decoded = try? JSONDecoder().decode([TranscriptionHistoryItem].self, from: data) {
            setLoaded(decoded)
            saveHistory()
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
    }
}
