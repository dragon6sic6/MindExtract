import Foundation
import UserNotifications
import SwiftUI
import AVFoundation

// MARK: - Video Format

struct VideoFormat: Identifiable, Hashable {
    let id: String
    let ext: String
    let resolution: String
    let filesize: String
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

    init(url: String, title: String, thumbnail: String?, platform: Platform, isAudioOnly: Bool, fileSize: String? = nil) {
        self.id = UUID()
        self.url = url
        self.title = title
        self.thumbnail = thumbnail
        self.platform = platform.rawValue
        self.downloadDate = Date()
        self.isAudioOnly = isAudioOnly
        self.fileSize = fileSize
    }
}

// MARK: - App Settings

enum FormatPreset: String, CaseIterable, Codable {
    case bestVideo = "Best Video"
    case hd1080p = "1080p"
    case hd720p = "720p"
    case sd480p = "480p"
    case audioOnly = "Audio Only (MP3)"

    var ytdlpFormat: String {
        switch self {
        case .bestVideo: return "bestvideo+bestaudio/best"
        case .hd1080p: return "bestvideo[height<=1080]+bestaudio/best[height<=1080]"
        case .hd720p: return "bestvideo[height<=720]+bestaudio/best[height<=720]"
        case .sd480p: return "bestvideo[height<=480]+bestaudio/best[height<=480]"
        case .audioOnly: return "bestaudio"
        }
    }

    var icon: String {
        switch self {
        case .bestVideo: return "star.fill"
        case .hd1080p: return "4k.tv"
        case .hd720p: return "tv"
        case .sd480p: return "tv.fill"
        case .audioOnly: return "music.note"
        }
    }
}

enum AppearanceMode: String, CaseIterable, Codable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .small: return "Small"
        case .medium: return "Medium"
        case .largev3: return "Large v3"
        case .largev3turbo: return "Large v3 Turbo"
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
        }
    }

    var isRecommended: Bool {
        self == .small
    }

    /// The WhisperKit model identifier used for download/init
    var whisperKitModelId: String {
        rawValue
    }
}

enum TranscriptionOutputFormat: String, CaseIterable, Codable {
    case txt = "txt"
    case srt = "srt"

    var displayName: String {
        switch self {
        case .txt: return "Plain Text (.txt)"
        case .srt: return "Subtitles (.srt)"
        }
    }
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
    case loadingModel
    case extractingAudio
    case transcribing(progress: Double)
    case completed(outputPath: String)
    case error(String)
    case modelNotDownloaded
}

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("defaultFormatPreset") var defaultFormatPreset: FormatPreset = .bestVideo
    @AppStorage("appearanceMode") var appearanceMode: AppearanceMode = .light
    @AppStorage("downloadSubtitles") var downloadSubtitles: Bool = false
    @AppStorage("subtitleLanguage") var subtitleLanguage: String = "en"
    @AppStorage("parallelDownloads") var parallelDownloads: Int = 2
    @AppStorage("preferredResolution") var preferredResolution: String = "720p"
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
    @AppStorage("enableSpeakerDiarization") var enableSpeakerDiarization: Bool = false

    private init() {}
}

// MARK: - Transcription History Item

struct TranscriptionHistoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let filePath: String
    let transcriptionDate: Date
    let duration: String?
    let modelUsed: String

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

class HistoryManager: ObservableObject {
    static let shared = HistoryManager()

    @Published var history: [HistoryItem] = []

    private let historyKey = "downloadHistory"
    private let maxHistoryItems = 100

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
        if let encoded = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(encoded, forKey: historyKey)
        }
    }

    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            history = decoded
        }
    }
}

// MARK: - Transcription History Manager

class TranscriptionHistoryManager: ObservableObject {
    static let shared = TranscriptionHistoryManager()

    @Published var history: [TranscriptionHistoryItem] = []

    private let historyKey = "transcriptionHistory"
    private let maxHistoryItems = 50

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
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    private func saveHistory() {
        if let encoded = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(encoded, forKey: historyKey)
        }
    }

    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([TranscriptionHistoryItem].self, from: data) {
            history = decoded
        }
    }
}
