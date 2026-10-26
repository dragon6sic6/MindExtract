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

enum DownloadState: Equatable {
    case idle
    case fetchingFormats
    case downloading(progress: Double, speed: String)
    case completed
    case error(String)
    case timeout(String)  // Shows when operation takes too long
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
    @AppStorage("downloadPath") var downloadPath: String = NSHomeDirectory() + "/Downloads"
    /// Quality for saved videos. Audio only is chosen in the notch.
    @AppStorage("downloadQuality") var downloadQuality: DownloadQuality = .best

    // Signing in: a browser's cookies, or an exported cookies file
    @AppStorage("cookieBrowser") var cookieBrowser: CookieBrowser = .none
    @AppStorage("cookiesFilePath") var cookiesFilePath: String = ""

    // Transcription
    @AppStorage("defaultTranscriptionLanguage") var defaultTranscriptionLanguage: String = "auto"
    @AppStorage("enableSpeakerDiarization") var enableSpeakerDiarization: Bool = true

    // When it's done
    /// Copy a finished transcript automatically (only if the clipboard wasn't used meanwhile).
    @AppStorage("autoCopyWhenDone") var autoCopyWhenDone: Bool = true
    /// Copy with "[00:12]" before each passage.
    @AppStorage("copyWithTimestamps") var copyWithTimestamps: Bool = false
    /// A notification when a job finishes while the notch is closed.
    @AppStorage("notifyOnTranscriptionComplete") var notifyOnTranscriptionComplete: Bool = true

    // Notch
    /// "notch" = the screen with the notch (or the main one), "main" = the screen with the menu bar.
    @AppStorage("notchScreen") var notchScreen: String = "notch"

    /// Every language a transcript can be made in: NVIDIA Parakeet's 25, then
    /// the ones only Apple's speech recognition covers. Sorted by English name.
    static var transcriptionLanguages: [(name: String, code: String)] {
        let english = Locale(identifier: "en_US")
        let codes = TranscriptionManager.parakeetLanguages.union(TranscriptionManager.appleOnlyLanguages)
        let named = codes.map { code in
            (name: english.localizedString(forLanguageCode: code) ?? code, code: code)
        }
        let sorted = named.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        return [(name: String(localized: "Automatic"), code: "auto")] + sorted
    }

    /// Every preference "Reset all settings" restores. Transcripts and the
    /// speech model are not preferences and are never touched.
    static let resettableKeys = [
        "downloadSubtitles", "subtitleLanguage", "downloadPath", "downloadQuality",
        "cookieBrowser", "cookiesFilePath", "defaultTranscriptionLanguage", "enableSpeakerDiarization",
        "autoCopyWhenDone", "copyWithTimestamps", "notifyOnTranscriptionComplete", "notchScreen",
        "settingsCategory",
    ]

    /// Restores every preference to its default.
    func resetToDefaults() {
        objectWillChange.send()
        for key in Self.resettableKeys { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// Settings left by 2.x that 3.0 no longer has.
    private static let retiredKeys = [
        "youtubeSignedIn", "translateToEnglish", "transcriptionEngine", "defaultWhisperModel",
        "transcriptionOutputFormat", "customVocabulary", "appAppearance", "parallelDownloads",
        "playSoundOnComplete", "showNotifications", "pianissimoAutoDownloadStarted",
    ]

    /// Tidies settings left by older versions. Runs once per launch, cheap.
    func migrate() {
        for key in Self.retiredKeys { UserDefaults.standard.removeObject(forKey: key) }
        if downloadQuality == .audioOnly { downloadQuality = .best }   // the notch chooses audio now
        if subtitleLanguage == "auto" { subtitleLanguage = "en" }      // yt-dlp has no "auto" subtitles
        let language = defaultTranscriptionLanguage
        if TranscriptionManager.engine(for: language) == .unsupported { defaultTranscriptionLanguage = "auto" }
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
