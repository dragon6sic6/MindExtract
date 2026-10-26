import Foundation
import Combine
import UserNotifications
import AVFoundation
import AppKit

// MARK: - Friendly error classification

struct DownloadErrorInfo {
    let message: String
    let needsYouTubeAuth: Bool
}

/// Maps raw yt-dlp stderr to a short, human, actionable message so users never
/// see Python tracebacks or `ERROR: [youtube] …` dumps. The raw text is still
/// kept in the output log for power users.
func classifyDownloadError(_ raw: String) -> DownloadErrorInfo {
    let s = raw.lowercased()
    func has(_ needles: String...) -> Bool { needles.contains { s.contains($0) } }

    if has("http error 403", "403: forbidden") {
        return DownloadErrorInfo(message: String(localized: "The site blocked the download. Try again in a moment, and if it keeps happening, update MindExtract."), needsYouTubeAuth: false)
    }
    if has("ffmpeg not found", "ffmpeg is not installed", "ffprobe and ffmpeg not found", "bad cpu type") {
        return DownloadErrorInfo(message: String(localized: "A conversion tool is missing, so this download can't be finished. Reinstall MindExtract."), needsYouTubeAuth: false)
    }

    if has("sign in to confirm you're not a bot", "sign in to confirm you’re not a bot", "confirm you're not a bot", "confirm you’re not a bot", "sign in to confirm") {
        return DownloadErrorInfo(message: String(localized: "YouTube wants to confirm you're not a bot. Sign in to YouTube to continue."), needsYouTubeAuth: true)
    }
    if has("confirm your age", "age-restricted", "age restricted", "inappropriate for some users") {
        return DownloadErrorInfo(message: String(localized: "This video is age-restricted. Sign in to YouTube to download it."), needsYouTubeAuth: true)
    }
    if has("members-only", "join this channel", "available to this channel's members") {
        return DownloadErrorInfo(message: String(localized: "This is members-only content. Sign in with an account that has access."), needsYouTubeAuth: true)
    }
    if has("private video", "this video is private") {
        return DownloadErrorInfo(message: String(localized: "This video is private and can't be downloaded."), needsYouTubeAuth: false)
    }
    if has("video unavailable", "is not available", "no longer available", "has been removed", "this video has been removed") {
        return DownloadErrorInfo(message: String(localized: "This video is unavailable or has been removed."), needsYouTubeAuth: false)
    }
    if has("requested format is not available", "requested format not available") {
        return DownloadErrorInfo(message: String(localized: "The selected quality isn't available for this video. Try a different format."), needsYouTubeAuth: false)
    }
    if has("not available in your country", "not available from your location", "blocked in your country", "geo restrict") {
        return DownloadErrorInfo(message: String(localized: "This video isn't available in your region."), needsYouTubeAuth: false)
    }
    if has("failed to resolve", "temporary failure in name resolution", "could not resolve host", "connection refused", "network is unreachable", "timed out", "connection timed out") {
        return DownloadErrorInfo(message: String(localized: "Network problem. Check your internet connection and try again."), needsYouTubeAuth: false)
    }
    if has("http error 404", "unable to download webpage", "404: not found") {
        return DownloadErrorInfo(message: String(localized: "Couldn't reach that page. Check the link and try again."), needsYouTubeAuth: false)
    }
    if has("unsupported url", "no video formats found", "unable to extract", "unable to find") {
        return DownloadErrorInfo(message: String(localized: "This link isn't supported, or the site changed. Updating the app may help."), needsYouTubeAuth: false)
    }

    // Fallback: surface the last ERROR line (not a WARNING), cleaned.
    let lines = raw
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    let firstLine = lines.last(where: { $0.hasPrefix("ERROR") })
        ?? lines.first(where: { !$0.hasPrefix("WARNING") && !$0.hasPrefix("[") })
        ?? String(localized: "The download didn't finish. Try again.")
    let cleaned = firstLine
        .replacingOccurrences(of: "ERROR: ", with: "")
        .replacingOccurrences(of: "\u{001B}[0;31m", with: "")
        .replacingOccurrences(of: "\u{001B}[0m", with: "")
    return DownloadErrorInfo(message: String(cleaned.prefix(200)), needsYouTubeAuth: false)
}

@MainActor
class YTDLPWrapper: ObservableObject {
    /// One instance shared by the main window and the Settings window.
    static let shared = YTDLPWrapper()

    @Published var state: DownloadState = .idle
    @Published var videoInfo: VideoInfo?
    @Published var scannedVideos: [VideoInfo] = []
    @Published var outputLog: String = "" {
        didSet {
            // Cap the in-memory log so long downloads don't grow it
            // unbounded (several MB of yt-dlp output otherwise accumulates here).
            // Re-assigning inside didSet does not retrigger the observer.
            if outputLog.count > Self.maxOutputLogChars {
                outputLog = String(outputLog.suffix(Self.maxOutputLogChars))
            }
        }
    }
    private static let maxOutputLogChars = 200_000
    @Published var lastDownloadedFilePath: String?

    /// Set when the most recent error is one that signing in to YouTube would fix,
    /// so the UI can offer an inline "Sign in to YouTube" action.
    @Published var lastErrorNeedsAuth: Bool = false

    /// Centralizes error presentation: classify raw stderr into a friendly message,
    /// flag whether auth would help, and keep the raw text in the log.
    private func setDownloadError(_ raw: String) {
        let info = classifyDownloadError(raw)
        lastErrorNeedsAuth = info.needsYouTubeAuth
        state = .error(info.message)
        outputLog += "\nError: \(raw)\n"
    }


    private var downloadTask: Process?
    /// Bumped by cancelDownload, so a killed yt-dlp's late callback is dropped.
    private var downloadGeneration = 0
    /// Temporary files of the running download (by path prefix): removed on cancel.
    private var tempPrefixes: [String] = []
    private var fetchTask: Process?
    /// Bumped by every loadURL / cancelLoad, so a slow lookup that finishes after
    /// a newer one started (or was cancelled) can't write its results.
    private(set) var loadGeneration = 0
    private var ytdlpPath: String?
    private var timeoutTimer: Timer?
    private var lastProgressTime: Date?

    // Settings and managers
    private let settings = AppSettings.shared
    private let historyManager = HistoryManager.shared

    // Timeout settings (in seconds)
    private let fetchTimeout: TimeInterval = 45
    private let downloadStallTimeout: TimeInterval = 30

    // yt-dlp's cache directory
    private var ytdlpCacheDir: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let cacheDir = appSupport.appendingPathComponent("com.mindact.mindextract/yt-dlp-cache").path
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        return cacheDir
    }

    // Common args to work around YouTube issues
    private var youtubeWorkaroundArgs: [String] {
        var args = ["--cache-dir", ytdlpCacheDir, "--no-update"]
        // Point yt-dlp at an ffmpeg that runs on this Mac (merging video + audio).
        if let dir = BundledTools.ffmpegDirectory { args += ["--ffmpeg-location", dir] }

        // Sign-in comes from a browser's cookies (YouTube ended yt-dlp's own
        // OAuth login). A cookies file, if chosen, wins over the browser.
        let cookiesFile = settings.cookiesFilePath
        if !cookiesFile.isEmpty && FileManager.default.fileExists(atPath: cookiesFile) {
            args += ["--cookies", cookiesFile]
        } else if settings.cookieBrowser != .none {
            args += ["--cookies-from-browser", settings.cookieBrowser.rawValue]
        }
        return args
    }

    // Sound player for completion
    private var soundPlayer: AVAudioPlayer?

    init() {
        findYTDLP()
        warmUpYTDLP()
    }

    /// First launch of the bundled yt-dlp triggers a one-time macOS security scan
    /// (~10 s). Running it once in the background at launch absorbs that cost, so
    /// every paste afterwards starts in ~0.3 s.
    private func warmUpYTDLP() {
        guard let ytdlp = ytdlpPath else { return }
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: ytdlp)
            task.arguments = ["--version"]
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            try? task.run()
            task.waitUntilExit()
        }
    }

    private func findYTDLP() {
        // First, check for the bundled yt-dlp (onedir build — starts ~30× faster
        // than the old self-extracting single binary, which re-triggered a macOS
        // security scan on every launch).
        if let resourcePath = Bundle.main.resourcePath {
            let bundledPath = resourcePath + "/ytdlp/yt-dlp_macos"
            if FileManager.default.isExecutableFile(atPath: bundledPath) {
                ytdlpPath = bundledPath
                appLog("Found bundled yt-dlp at: \(bundledPath)")
                return
            }
        }

        // Fallback: check common installation paths
        let paths = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp",
            "\(NSHomeDirectory())/.local/bin/yt-dlp",
            "\(NSHomeDirectory())/Library/Python/3.11/bin/yt-dlp",
            "\(NSHomeDirectory())/Library/Python/3.12/bin/yt-dlp",
            "\(NSHomeDirectory())/Library/Python/3.13/bin/yt-dlp",
            "\(NSHomeDirectory())/Library/Python/3.14/bin/yt-dlp"
        ]

        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                ytdlpPath = path
                appLog("Found system yt-dlp at: \(path)")
                return
            }
        }

        appLog("yt-dlp not found")
    }

    var isYTDLPInstalled: Bool {
        ytdlpPath != nil
    }

    // MARK: - Looking up a link

    /// Instant preview via oEmbed (~300 ms) so the media card appears immediately
    /// while yt-dlp fetches the full format list in the background. YouTube and
    /// Vimeo support it; other sites simply skip the preview.
    private func fetchQuickPreview(for url: String, generation: Int) {
        let lower = url.lowercased()
        let oembedURL: String?
        if lower.contains("youtube.com/watch") || lower.contains("youtu.be/") || lower.contains("youtube.com/shorts") {
            oembedURL = "https://www.youtube.com/oembed?format=json&url=" +
                (url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url)
        } else if lower.contains("vimeo.com/") {
            oembedURL = "https://vimeo.com/api/oembed.json?url=" +
                (url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url)
        } else {
            oembedURL = nil
        }
        guard let oembedURL, let requestURL = URL(string: oembedURL) else { return }

        Task {
            var request = URLRequest(url: requestURL)
            request.timeoutInterval = 4
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = json["title"] as? String else { return }
            // Only show the preview if the full info hasn't already arrived.
            guard generation == self.loadGeneration, self.videoInfo == nil, case .fetchingFormats = self.state else { return }
            self.videoInfo = VideoInfo(
                id: url,
                title: title,
                thumbnail: json["thumbnail_url"] as? String,
                duration: "",
                uploader: json["author_name"] as? String ?? "",
                url: url,
                formats: []     // formats arrive when yt-dlp finishes
            )
        }
    }

    /// Unified entry point: figures out whether the URL is a single video or a
    /// playlist/channel/page and routes accordingly — so the user never has to
    /// pre-choose "Video" vs "Scan Page". Uses a fast `--flat-playlist` probe.
    func loadURL(_ url: String) {
        guard let ytdlp = ytdlpPath else {
            state = .error("yt-dlp not found. Please install it with: brew install yt-dlp")
            return
        }

        loadGeneration += 1
        let generation = loadGeneration
        fetchTask?.terminate()
        // State first, so nothing reads the previous video's info as this one's.
        state = .fetchingFormats
        scannedVideos = []
        videoInfo = nil
        lastErrorNeedsAuth = false
        outputLog = "Loading: \(url)\n"
        fetchQuickPreview(for: url, generation: generation)
        startFetchTimeout()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let task = Process()
            self.fetchTask = task
            task.executableURL = URL(fileURLWithPath: ytdlp)
            // Fast probe: list entries flat (no per-video metadata) to detect playlists.
            task.arguments = ["-J", "--flat-playlist", "--no-warnings"] + youtubeWorkaroundArgs + [url]

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            task.environment = env

            let pipe = Pipe()
            let errorPipe = Pipe()
            task.standardOutput = pipe
            task.standardError = errorPipe

            do {
                try task.run()
                var outputData = Data()
                let outputHandle = pipe.fileHandleForReading
                while true {
                    let chunk = outputHandle.availableData
                    if chunk.isEmpty { break }
                    outputData.append(chunk)
                }
                task.waitUntilExit()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                DispatchQueue.main.async {
                    guard generation == self.loadGeneration else { return }
                    self.cancelTimeoutTimer()
                    self.fetchTask = nil

                    if task.terminationStatus != 0 {
                        let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        self.setDownloadError(errorString)
                        return
                    }

                    guard let json = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any] else {
                        self.state = .error("Couldn't read that page. Check the link and try again.")
                        return
                    }

                    if let entries = json["entries"] as? [[String: Any]], entries.count > 1 {
                        // Playlist / channel / multi-video page → show the scan list.
                        let videos = self.parsePageScan(json: json, originalUrl: url)
                        self.scannedVideos = videos
                        self.state = .idle
                        self.outputLog += "Found \(videos.count) video(s)\n"
                    } else if json["formats"] != nil {
                        // Single video — the probe response already contains the full
                        // format list (--flat-playlist only affects playlists), so we
                        // can parse it directly instead of running yt-dlp a second time.
                        let info = self.parseVideoInfo(json: json, url: url)
                        self.videoInfo = info
                        self.state = .idle
                        self.outputLog += "Loaded: \(info.title)\n"
                    } else {
                        // Rare: 1-item playlist wrapper without formats → full fetch.
                        self.fetchFormats(url: url, generation: generation)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard generation == self.loadGeneration else { return }
                    self.cancelTimeoutTimer()
                    self.fetchTask = nil
                    self.state = .error("Error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func parsePageScan(json: [String: Any], originalUrl: String) -> [VideoInfo] {
        var videos: [VideoInfo] = []

        // Check if it's a playlist/channel with entries
        if let entries = json["entries"] as? [[String: Any]] {
            for entry in entries {
                if let video = parseVideoEntry(entry) {
                    videos.append(video)
                }
            }
        } else {
            // Single video
            if let video = parseVideoEntry(json) {
                videos.append(video)
            }
        }

        return videos
    }

    private func parseVideoEntry(_ entry: [String: Any]) -> VideoInfo? {
        let id = entry["id"] as? String ?? UUID().uuidString
        let title = entry["title"] as? String ?? "Unknown"
        let thumbnail = entry["thumbnail"] as? String ?? entry["thumbnails"] as? String
        let duration = formatDuration(entry["duration"] as? Double ?? 0)
        let uploader = entry["uploader"] as? String ?? entry["channel"] as? String ?? "Unknown"
        let url = entry["url"] as? String ?? entry["webpage_url"] as? String ?? ""

        // Skip if no valid URL
        if url.isEmpty && id.isEmpty { return nil }

        return VideoInfo(
            id: id,
            title: title,
            thumbnail: thumbnail,
            duration: duration,
            uploader: uploader,
            url: url.isEmpty ? id : url,
            formats: []
        )
    }

    // MARK: - Fetch Formats for Single Video

    func fetchFormats(url: String, generation: Int? = nil) {
        guard let ytdlp = ytdlpPath else {
            state = .error("yt-dlp not found. Please install it with: brew install yt-dlp")
            return
        }

        state = .fetchingFormats
        outputLog = "Fetching video information from: \(url)\n"
        outputLog += "Using yt-dlp at: \(ytdlp)\n"

        // Start timeout timer
        startFetchTimeout()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let task = Process()
            self.fetchTask = task
            task.executableURL = URL(fileURLWithPath: ytdlp)
            task.arguments = ["-J", "--no-warnings", "--no-playlist"] + youtubeWorkaroundArgs + [url]

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            task.environment = env

            let pipe = Pipe()
            let errorPipe = Pipe()
            task.standardOutput = pipe
            task.standardError = errorPipe

            do {
                try task.run()

                var outputData = Data()
                let outputHandle = pipe.fileHandleForReading

                while true {
                    let chunk = outputHandle.availableData
                    if chunk.isEmpty { break }
                    outputData.append(chunk)
                }

                task.waitUntilExit()

                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                DispatchQueue.main.async {
                    if let generation, generation != self.loadGeneration { return }
                    self.cancelTimeoutTimer()
                    self.fetchTask = nil

                    if task.terminationStatus != 0 {
                        let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        self.setDownloadError(errorString)
                        return
                    }

                    do {
                        if let json = try JSONSerialization.jsonObject(with: outputData) as? [String: Any] {
                            let info = self.parseVideoInfo(json: json, url: url)
                            self.videoInfo = info
                            self.state = .idle
                            self.outputLog += "Successfully found \(info.formats.count) formats\n"
                            self.outputLog += "Title: \(info.title)\n"
                        } else {
                            self.state = .error("Failed to parse video info")
                            self.outputLog += "Error: Could not parse JSON response\n"
                        }
                    } catch {
                        self.state = .error("JSON parsing error: \(error.localizedDescription)")
                        self.outputLog += "Error parsing JSON: \(error.localizedDescription)\n"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    if let generation, generation != self.loadGeneration { return }
                    self.cancelTimeoutTimer()
                    self.fetchTask = nil
                    self.state = .error("Error: \(error.localizedDescription)")
                    self.outputLog += "Error: \(error.localizedDescription)\n"
                }
            }
        }
    }

    // MARK: - Timeout Handling

    private func startFetchTimeout() {
        cancelTimeoutTimer()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.timeoutTimer = Timer.scheduledTimer(withTimeInterval: self.fetchTimeout, repeats: false) { [weak self] _ in
                self?.handleFetchTimeout()
            }
        }
    }

    private func startDownloadStallDetection() {
        lastProgressTime = Date()
        cancelTimeoutTimer()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.timeoutTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.checkDownloadStall()
            }
        }
    }

    private func cancelTimeoutTimer() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
    }

    private func handleFetchTimeout() {
        fetchTask?.terminate()
        fetchTask = nil
        state = .timeout(String(localized: "This is taking unusually long. The site may be slow, so try again in a moment."))
        outputLog += "\n⚠️ TIMEOUT: Operation exceeded \(Int(fetchTimeout)) seconds.\n"
        outputLog += "You can try again or check if the URL is correct.\n"
    }

    private func checkDownloadStall() {
        guard case .downloading = state,
              let lastProgress = lastProgressTime else { return }

        let stallTime = Date().timeIntervalSince(lastProgress)
        if stallTime > downloadStallTimeout {
            downloadTask?.terminate()
            downloadTask = nil
            cancelTimeoutTimer()
            state = .timeout(String(localized: "The download stopped moving. Check your connection and try again."))
            outputLog += "\n⚠️ STALL DETECTED: No download progress for \(Int(stallTime)) seconds.\n"
            outputLog += "The connection may have been lost. You can try again.\n"
        }
    }

    func retry() {
        // Reset state to allow retry
        cancelTimeoutTimer()
        fetchTask?.terminate()
        fetchTask = nil
        downloadTask?.terminate()
        downloadTask = nil
        state = .idle
        outputLog += "\n--- Retry requested ---\n"
    }

    private func parseVideoInfo(json: [String: Any], url: String) -> VideoInfo {
        let id = json["id"] as? String ?? UUID().uuidString
        let title = json["title"] as? String ?? "Unknown"
        let thumbnail = json["thumbnail"] as? String
        let duration = formatDuration(json["duration"] as? Double ?? 0)
        let uploader = json["uploader"] as? String ?? json["channel"] as? String ?? "Unknown"

        var formats: [VideoFormat] = []

        if let formatList = json["formats"] as? [[String: Any]] {
            for format in formatList {
                let formatId = format["format_id"] as? String ?? ""
                let ext = format["ext"] as? String ?? ""

                let height = format["height"] as? Int
                let resolution: String
                if let h = height, h > 0 {
                    resolution = "\(h)p"
                } else {
                    resolution = format["resolution"] as? String ?? "N/A"
                }

                var filesizeNum: Int64 = 0
                if let fs = format["filesize"] as? Int64 {
                    filesizeNum = fs
                } else if let fs = format["filesize"] as? Int {
                    filesizeNum = Int64(fs)
                } else if let fs = format["filesize_approx"] as? Int64 {
                    filesizeNum = fs
                } else if let fs = format["filesize_approx"] as? Int {
                    filesizeNum = Int64(fs)
                } else if let fs = format["filesize_approx"] as? Double {
                    filesizeNum = Int64(fs)
                }
                let filesize = formatFileSize(filesizeNum)

                let formatNote = format["format_note"] as? String ?? ""
                let vcodec = format["vcodec"] as? String ?? "none"
                let acodec = format["acodec"] as? String ?? "none"

                let isVideoOnly = acodec == "none" && vcodec != "none"
                let isAudioOnly = vcodec == "none" && acodec != "none"

                if ext == "mhtml" { continue }

                let videoFormat = VideoFormat(
                    id: formatId,
                    ext: ext,
                    resolution: resolution,
                    filesize: filesize,
                    filesizeBytes: filesizeNum,
                    note: formatNote,
                    isAudioOnly: isAudioOnly,
                    isVideoOnly: isVideoOnly
                )
                formats.append(videoFormat)
            }
        }

        formats.sort { f1, f2 in
            if f1.isAudioOnly != f2.isAudioOnly {
                return !f1.isAudioOnly
            }
            let r1 = Int(f1.resolution.replacingOccurrences(of: "p", with: "")) ?? 0
            let r2 = Int(f2.resolution.replacingOccurrences(of: "p", with: "")) ?? 0
            return r1 > r2
        }

        return VideoInfo(id: id, title: title, thumbnail: thumbnail, duration: duration, uploader: uploader, url: url, formats: formats)
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds == 0 { return "--:--" }
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        bytes.fileSizeText
    }

    // MARK: - Download

    /// Runs yt-dlp for a download: streams stdout to `progressHandler`, keeps
    /// stderr for the log and for classifying errors, and calls `completion` on
    /// the main actor. A run that was cancelled never calls back, so it can't
    /// touch the state of the job that came after it.
    private func runYTDLP(
        arguments: [String],
        progressHandler: @escaping @MainActor @Sendable (String) -> Void,
        completion: @escaping @MainActor @Sendable (_ success: Bool, _ errorOutput: String?) -> Void
    ) {
        guard let ytdlp = ytdlpPath else {
            completion(false, "yt-dlp not found")
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: ytdlp)
        task.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        task.environment = env

        let pipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = pipe
        task.standardError = errorPipe

        downloadTask = task
        let generation = downloadGeneration

        // Stream output. Handlers run on a Foundation I/O queue; hop to the main actor.
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let output = String(data: data, encoding: .utf8) {
                Task { @MainActor in progressHandler(output) }
            }
        }
        // The handler drains stderr as it arrives, so keep a copy: it's what
        // the error is classified from when the run fails.
        let errorBuffer = ErrorBuffer()
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            errorBuffer.append(data)
            if let output = String(data: data, encoding: .utf8) {
                Task { @MainActor in self?.outputLog += output }
            }
        }

        // Process and Pipe are non-Sendable but are safe to run/read on the
        // background queue here; vouch for the cross-thread hand-off.
        nonisolated(unsafe) let runTask = task
        nonisolated(unsafe) let runPipe = pipe
        nonisolated(unsafe) let runErrorPipe = errorPipe

        // Launch here on the main actor, so a Cancel can never meet a process
        // that hasn't started yet; only the waiting happens in the background.
        do {
            try task.run()
        } catch {
            downloadTask = nil
            completion(false, error.localizedDescription)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            runTask.waitUntilExit()

            runPipe.fileHandleForReading.readabilityHandler = nil
            runErrorPipe.fileHandleForReading.readabilityHandler = nil

            let success = runTask.terminationStatus == 0
            let errorOutput: String?
            if success {
                errorOutput = nil
            } else {
                errorBuffer.append(runErrorPipe.fileHandleForReading.readDataToEndOfFile())
                let text = errorBuffer.text
                errorOutput = text.isEmpty ? "Unknown error" : text
            }

            Task { @MainActor in
                guard let self, generation == self.downloadGeneration else { return }
                self.downloadTask = nil
                self.tempPrefixes = []
                completion(success, errorOutput)
            }
        }
    }

    /// yt-dlp format selector for the user's preferred quality. Applies to the
    /// "best" download path only — explicit per-format picks are respected as-is.
    private var qualityFormatSelector: String {
        switch settings.downloadQuality {
        case .best:
            return "bestvideo[vcodec^=avc1]+bestaudio[ext=m4a]/bestvideo[vcodec^=av01]+bestaudio/bestvideo[vcodec^=avc]+bestaudio/bestvideo+bestaudio/best"
        case .hd1080, .hd720:
            let cap = settings.downloadQuality == .hd1080 ? 1080 : 720
            return "bestvideo[height<=\(cap)][vcodec^=avc1]+bestaudio[ext=m4a]/bestvideo[height<=\(cap)][vcodec^=av01]+bestaudio/bestvideo[height<=\(cap)]+bestaudio/best[height<=\(cap)]/best"
        case .audioOnly:
            return "bestaudio[ext=m4a]/bestaudio/best"
        }
    }
    private var qualityMergeFormat: String { settings.downloadQuality == .audioOnly ? "m4a" : "mp4" }

    func downloadBest(url: String, outputPath: String) {
        state = .downloading(progress: 0, speed: "Starting…")
        startDownloadStallDetection()
        outputLog = "Starting download (best quality)...\n"

        let outputTemplate = "\(outputPath)/%(title).80s [%(id)s] %(height)sp.%(ext)s"

        // Quality-aware selector (H.264 preferred for QuickTime/macOS), honoring
        // the user's "best/1080p/720p/audio only" preference.
        var args = [
            "-f", qualityFormatSelector,
            "-o", outputTemplate,
            "--newline", "--progress", "--no-playlist", "--restrict-filenames",
            "--merge-output-format", qualityMergeFormat
        ]
        args.append(contentsOf: youtubeWorkaroundArgs)
        if settings.downloadSubtitles {
            args.append(contentsOf: ["--write-subs", "--write-auto-subs", "--sub-langs", settings.subtitleLanguage + ".*"])
        }
        let savedPathFile = Self.makeSavedPathFile()
        tempPrefixes = [savedPathFile]
        args.append(contentsOf: ["--print-to-file", "after_move:filepath", savedPathFile])
        args.append(url)

        runYTDLP(arguments: args, progressHandler: { [weak self] in self?.parseProgress($0) }) { [weak self] success, errorOutput in
            guard let self = self else { return }
            self.cancelTimeoutTimer()
            if success {
                self.state = .completed
                self.outputLog += "\nDownload completed!\n"
                self.lastDownloadedFilePath = Self.savedPath(from: savedPathFile) ?? self.findLatestDownloadedFile(in: outputPath)
                if let info = self.videoInfo {
                    let historyItem = HistoryItem(
                        url: url,
                        title: info.title,
                        thumbnail: info.thumbnail,
                        platform: Platform.detect(from: url),
                        isAudioOnly: self.settings.downloadQuality == .audioOnly,
                        filePath: self.lastDownloadedFilePath
                    )
                    self.historyManager.addToHistory(historyItem)
                }
            } else {
                self.setDownloadError(errorOutput ?? "Unknown error")
            }
        }
    }

    private func parseProgress(_ output: String) {
        outputLog += output

        if output.contains("%") {
            let pattern = #"(\d+\.?\d*)%.*?at\s+(\S+)"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) {

                if let percentRange = Range(match.range(at: 1), in: output),
                   let speedRange = Range(match.range(at: 2), in: output) {
                    let percent = Double(output[percentRange]) ?? 0
                    let speed = String(output[speedRange])
                    state = .downloading(progress: percent / 100, speed: speed)
                    // Update last progress time for stall detection
                    lastProgressTime = Date()
                }
            }
        }
    }

    /// Stops looking up a link: the lookup's late results are ignored.
    /// A job about to start keeps the info it already has (for its history entry).
    func cancelLoad(keepInfo: Bool = false) {
        loadGeneration += 1
        fetchTask?.terminate()
        fetchTask = nil
        cancelTimeoutTimer()
        if !keepInfo {
            videoInfo = nil
            scannedVideos = []
        }
        if case .fetchingFormats = state { state = .idle }
    }

    func cancelDownload() {
        downloadGeneration += 1
        if let task = downloadTask, task.isRunning { task.terminate() }
        downloadTask = nil
        let fm = FileManager.default
        for prefix in tempPrefixes {
            let dir = (prefix as NSString).deletingLastPathComponent
            let name = (prefix as NSString).lastPathComponent
            for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where item.hasPrefix(name) {
                try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(item))
            }
        }
        tempPrefixes = []
        cancelTimeoutTimer()
        state = .idle
        outputLog += "\nDownload cancelled.\n"
    }

    func reset() {
        // Terminate any in-flight work first, so a stale completion handler can't
        // later mutate state for a URL the user has already moved on from.
        fetchTask?.terminate()
        fetchTask = nil
        downloadGeneration += 1
        downloadTask?.terminate()
        downloadTask = nil
        cancelTimeoutTimer()

        state = .idle
        videoInfo = nil
        scannedVideos = []
        outputLog = ""
        lastDownloadedFilePath = nil
    }

    // MARK: - Audio only

    func downloadAudio(url: String, outputPath: String) {
        state = .downloading(progress: 0, speed: "Starting audio extraction…")
        startDownloadStallDetection()
        outputLog = "Starting audio download (M4A)...\n"

        // Use truncated title + video ID for filename
        let outputTemplate = "\(outputPath)/%(title).80s [%(id)s].%(ext)s"

        var args = [
            "-f", "bestaudio",
            "-x",  // Extract audio
            "--audio-format", "m4a",
            "--audio-quality", "0",  // Best quality
            "-o", outputTemplate,
            "--newline", "--progress", "--no-playlist", "--restrict-filenames"
        ]
        args.append(contentsOf: youtubeWorkaroundArgs)
        let savedPathFile = Self.makeSavedPathFile()
        tempPrefixes = [savedPathFile]
        args.append(contentsOf: ["--print-to-file", "after_move:filepath", savedPathFile])
        args.append(url)

        runYTDLP(arguments: args, progressHandler: { [weak self] in self?.parseProgress($0) }) { [weak self] success, errorOutput in
            guard let self = self else { return }
            self.cancelTimeoutTimer()
            if success {
                self.state = .completed
                self.outputLog += "\nAudio download completed!\n"
                self.lastDownloadedFilePath = Self.savedPath(from: savedPathFile) ?? self.findLatestDownloadedFile(in: outputPath)
                // Record audio downloads in History too (this was missing — only
                // video downloads were saved, so audio files vanished from History).
                if let info = self.videoInfo {
                    let historyItem = HistoryItem(
                        url: url,
                        title: info.title,
                        thumbnail: info.thumbnail,
                        platform: Platform.detect(from: url),
                        isAudioOnly: true,
                        filePath: self.lastDownloadedFilePath
                    )
                    self.historyManager.addToHistory(historyItem)
                }
            } else {
                self.setDownloadError(errorOutput ?? "Unknown error")
            }
        }
    }

    // MARK: - Download Audio for Transcription (to temp folder)

    func downloadAudioForTranscription(url: String, completion: @escaping (String?, String?) -> Void) {
        state = .downloading(progress: 0, speed: "Downloading audio for transcription…")
        startDownloadStallDetection()
        outputLog = "Downloading audio for transcription...\n"

        // Create temp directory for audio
        let tempDir = NSTemporaryDirectory()
        let tempFileName = UUID().uuidString
        let outputTemplate = "\(tempDir)\(tempFileName).%(ext)s"
        tempPrefixes = [tempDir + tempFileName]

        var args = [
            "-f", "bestaudio",
            "-x",  // Extract audio
            "--audio-format", "wav",
            "--audio-quality", "0",
            "-o", outputTemplate,
            "--newline", "--progress", "--no-playlist"
        ]
        args.append(contentsOf: youtubeWorkaroundArgs)
        args.append(url)

        runYTDLP(arguments: args, progressHandler: { [weak self] in self?.parseProgress($0) }) { [weak self] success, errorOutput in
            guard let self = self else { return }
            self.cancelTimeoutTimer()
            if success {
                // Find the downloaded audio file
                let expectedPath = "\(tempDir)\(tempFileName).wav"
                if FileManager.default.fileExists(atPath: expectedPath) {
                    self.state = .idle
                    self.outputLog += "\nAudio downloaded for transcription.\n"
                    completion(expectedPath, nil)
                } else {
                    // Try to find any file with the temp name
                    let contents = try? FileManager.default.contentsOfDirectory(atPath: tempDir)
                    if let file = contents?.first(where: { $0.hasPrefix(tempFileName) }) {
                        let fullPath = tempDir + file
                        self.state = .idle
                        self.outputLog += "\nAudio downloaded for transcription.\n"
                        completion(fullPath, nil)
                    } else {
                        self.state = .error("Could not find downloaded audio file")
                        completion(nil, "Could not find downloaded audio file")
                    }
                }
            } else {
                let msg = errorOutput ?? "Unknown error"
                self.setDownloadError(msg)
                completion(nil, classifyDownloadError(msg).message)
            }
        }
    }

    // MARK: - Download Queue

    // MARK: - File Path Helper

    /// A temp file yt-dlp writes the final path into, so we know exactly what
    /// was saved instead of guessing from the newest file in the folder.
    private static func makeSavedPathFile() -> String {
        NSTemporaryDirectory() + "mindextract-saved-\(UUID().uuidString).txt"
    }

    private static func savedPath(from file: String) -> String? {
        defer { try? FileManager.default.removeItem(atPath: file) }
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        let path = text.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    private func findLatestDownloadedFile(in directory: String) -> String? {
        let fileManager = FileManager.default
        let directoryURL = URL(fileURLWithPath: directory)

        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return nil
        }

        // Video/audio extensions
        let mediaExtensions = ["mp4", "mkv", "webm", "avi", "mov", "mp3", "m4a", "wav", "flac", "ogg"]

        // Find the most recently modified media file
        var latestFile: URL?
        var latestDate: Date?

        for url in contents {
            let ext = url.pathExtension.lowercased()
            guard mediaExtensions.contains(ext) else { continue }

            if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
               let modDate = attributes[.modificationDate] as? Date {
                if latestDate == nil || modDate > latestDate! {
                    latestDate = modDate
                    latestFile = url
                }
            }
        }

        return latestFile?.path
    }
}


/// Collects a process's stderr from a background handler.
private final class ErrorBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
