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

    if has("sign in to confirm you're not a bot", "sign in to confirm you’re not a bot", "confirm you're not a bot", "confirm you’re not a bot", "sign in to confirm") {
        return DownloadErrorInfo(message: "YouTube wants to confirm you're not a bot. Sign in to YouTube to continue.", needsYouTubeAuth: true)
    }
    if has("confirm your age", "age-restricted", "age restricted", "inappropriate for some users") {
        return DownloadErrorInfo(message: "This video is age-restricted. Sign in to YouTube to download it.", needsYouTubeAuth: true)
    }
    if has("members-only", "join this channel", "available to this channel's members") {
        return DownloadErrorInfo(message: "This is members-only content. Sign in with an account that has access.", needsYouTubeAuth: true)
    }
    if has("private video", "this video is private") {
        return DownloadErrorInfo(message: "This video is private and can't be downloaded.", needsYouTubeAuth: false)
    }
    if has("video unavailable", "is not available", "no longer available", "has been removed", "this video has been removed") {
        return DownloadErrorInfo(message: "This video is unavailable or has been removed.", needsYouTubeAuth: false)
    }
    if has("requested format is not available", "requested format not available") {
        return DownloadErrorInfo(message: "The selected quality isn't available for this video. Try a different format.", needsYouTubeAuth: false)
    }
    if has("not available in your country", "not available from your location", "blocked in your country", "geo restrict") {
        return DownloadErrorInfo(message: "This video isn't available in your region.", needsYouTubeAuth: false)
    }
    if has("failed to resolve", "temporary failure in name resolution", "could not resolve host", "connection refused", "network is unreachable", "timed out", "connection timed out") {
        return DownloadErrorInfo(message: "Network problem — check your internet connection and try again.", needsYouTubeAuth: false)
    }
    if has("http error 404", "unable to download webpage", "404: not found") {
        return DownloadErrorInfo(message: "Couldn't reach that page. Check the link and try again.", needsYouTubeAuth: false)
    }
    if has("unsupported url", "no video formats found", "unable to extract", "unable to find") {
        return DownloadErrorInfo(message: "This link isn't supported, or the site changed. Updating the app may help.", needsYouTubeAuth: false)
    }

    // Fallback: surface a cleaned first meaningful line, not the whole dump.
    let firstLine = raw
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first(where: { !$0.isEmpty }) ?? "Something went wrong."
    let cleaned = firstLine
        .replacingOccurrences(of: "ERROR: ", with: "")
        .replacingOccurrences(of: "\u{001B}[0;31m", with: "")
        .replacingOccurrences(of: "\u{001B}[0m", with: "")
    return DownloadErrorInfo(message: String(cleaned.prefix(200)), needsYouTubeAuth: false)
}

@MainActor
class YTDLPWrapper: ObservableObject {
    @Published var state: DownloadState = .idle
    @Published var videoInfo: VideoInfo?
    @Published var scannedVideos: [VideoInfo] = []
    @Published var outputLog: String = "" {
        didSet {
            // Cap the in-memory log so long downloads / large queues don't grow it
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

    // YouTube OAuth sign-in
    @Published var youtubeSignInState: YouTubeSignInState = .idle
    @Published var youtubeDeviceCode: String = ""
    @Published var youtubeVerificationURL: String = ""
    private var signInTask: Process?

    // Download Queue
    @Published var downloadQueue: [QueueItem] = []
    @Published var isProcessingQueue: Bool = false
    private var currentQueueIndex: Int = 0
    private var activeDownloads: Int = 0
    private var downloadTasks: [UUID: Process] = [:]

    private var downloadTask: Process?
    private var fetchTask: Process?
    private var ytdlpPath: String?
    private var timeoutTimer: Timer?
    private var lastProgressTime: Date?

    // Settings and managers
    private let settings = AppSettings.shared
    private let historyManager = HistoryManager.shared

    // Timeout settings (in seconds)
    private let fetchTimeout: TimeInterval = 45
    private let downloadStallTimeout: TimeInterval = 30

    // yt-dlp cache directory (persists OAuth tokens)
    private var ytdlpCacheDir: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let cacheDir = appSupport.appendingPathComponent("com.mindact.mindextract/yt-dlp-cache").path
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        return cacheDir
    }

    // Common args to work around YouTube issues
    private var youtubeWorkaroundArgs: [String] {
        var args = ["--cache-dir", ytdlpCacheDir]

        // Authentication methods are mutually exclusive. Sending OAuth *and* a cookies
        // file together makes yt-dlp use conflicting credentials and can invalidate the
        // OAuth token. Priority: OAuth → cookies file → browser cookies.
        if settings.youtubeSignedIn {
            args += ["--username", "oauth2", "--password", ""]
        } else {
            let cookiesFile = settings.cookiesFilePath
            if !cookiesFile.isEmpty && FileManager.default.fileExists(atPath: cookiesFile) {
                args += ["--cookies", cookiesFile]
            } else if settings.cookieBrowser != .none {
                args += ["--cookies-from-browser", settings.cookieBrowser.rawValue]
            }
        }
        return args
    }

    // Sound player for completion
    private var soundPlayer: AVAudioPlayer?

    init() {
        findYTDLP()
        requestNotificationPermission()
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

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted {
                print("Notification permission granted")
            }
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
                print("Found bundled yt-dlp at: \(bundledPath)")
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
                print("Found system yt-dlp at: \(path)")
                return
            }
        }

        print("yt-dlp not found")
    }

    var isYTDLPInstalled: Bool {
        ytdlpPath != nil
    }

    // MARK: - YouTube OAuth Sign-In

    func startYouTubeSignIn() {
        guard let ytdlp = ytdlpPath else { return }

        DispatchQueue.main.async {
            self.youtubeSignInState = .signingIn
            self.youtubeDeviceCode = ""
            self.youtubeVerificationURL = ""
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let task = Process()
            self.signInTask = task
            task.executableURL = URL(fileURLWithPath: ytdlp)
            // Use a short public video to trigger OAuth flow
            task.arguments = [
                "--username", "oauth2",
                "--password", "",
                "--cache-dir", self.ytdlpCacheDir,
                "--skip-download",
                "-J",
                "https://www.youtube.com/watch?v=jNQXAC9IVRw"
            ]

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            task.environment = env

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            task.standardOutput = outputPipe
            task.standardError = errorPipe
            // Provide empty stdin so yt-dlp doesn't hang waiting for input
            task.standardInput = Pipe()

            // Read stderr in real-time to capture the device code
            errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }

                print("yt-dlp OAuth: \(line)")

                // Parse device code output
                // yt-dlp outputs something like:
                // "To give yt-dlp access to your account, go to  https://www.google.com/device  and enter code XXX-XXX-XXX"
                if line.contains("google.com/device") || line.contains("verification") || line.contains("enter code") {
                    // Extract URL
                    if let urlRange = line.range(of: "https://[^\\s]+", options: .regularExpression) {
                        let url = String(line[urlRange])
                        DispatchQueue.main.async {
                            self?.youtubeVerificationURL = url
                        }
                        // Auto-open the URL in browser
                        if let nsurl = URL(string: url) {
                            NSWorkspace.shared.open(nsurl)
                        }
                    }
                    // Extract code (typically formatted as XXX-XXX-XXX or similar)
                    if let codeRange = line.range(of: "[A-Z0-9]{3,}-[A-Z0-9]{3,}(-[A-Z0-9]{3,})?", options: .regularExpression) {
                        let code = String(line[codeRange])
                        DispatchQueue.main.async {
                            self?.youtubeDeviceCode = code
                        }
                    }
                }
            }

            do {
                try task.run()
                task.waitUntilExit()

                errorPipe.fileHandleForReading.readabilityHandler = nil

                let exitCode = task.terminationStatus

                DispatchQueue.main.async {
                    if exitCode == 0 {
                        self.youtubeSignInState = .signedIn
                        self.settings.youtubeSignedIn = true
                    } else {
                        // Read any remaining error output
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorStr = String(data: errorData, encoding: .utf8) ?? ""
                        if errorStr.contains("already") || exitCode == 0 {
                            self.youtubeSignInState = .signedIn
                            self.settings.youtubeSignedIn = true
                        } else {
                            self.youtubeSignInState = .error("Sign-in failed. Please try again.")
                            print("OAuth error: \(errorStr)")
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.youtubeSignInState = .error("Failed to start sign-in: \(error.localizedDescription)")
                }
            }
        }
    }

    func signOutYouTube() {
        // Remove cached OAuth token
        let cacheDir = ytdlpCacheDir
        let tokenPath = "\(cacheDir)/youtube-nsig"
        try? FileManager.default.removeItem(atPath: tokenPath)
        // Also try removing the oauth2 token files
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: cacheDir) {
            for file in contents where file.contains("oauth") || file.contains("token") {
                try? FileManager.default.removeItem(atPath: "\(cacheDir)/\(file)")
            }
        }
        settings.youtubeSignedIn = false
        youtubeSignInState = .idle
    }

    func cancelSignIn() {
        signInTask?.terminate()
        signInTask = nil
        DispatchQueue.main.async {
            self.youtubeSignInState = .idle
        }
    }

    // MARK: - Scan Page for Videos

    /// Instant preview via oEmbed (~300 ms) so the media card appears immediately
    /// while yt-dlp fetches the full format list in the background. YouTube and
    /// Vimeo support it; other sites simply skip the preview.
    private func fetchQuickPreview(for url: String) {
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
            guard self.videoInfo == nil, case .fetchingFormats = self.state else { return }
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

        state = .fetchingFormats
        scannedVideos = []
        videoInfo = nil
        lastErrorNeedsAuth = false
        outputLog = "Loading: \(url)\n"
        fetchQuickPreview(for: url)
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
                        self.fetchFormats(url: url)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.cancelTimeoutTimer()
                    self.fetchTask = nil
                    self.state = .error("Error: \(error.localizedDescription)")
                }
            }
        }
    }

    func scanPage(url: String) {
        guard let ytdlp = ytdlpPath else {
            state = .error("yt-dlp not found. Please install it with: brew install yt-dlp")
            return
        }

        state = .scanningPage
        scannedVideos = []
        outputLog = "Scanning page for videos: \(url)\n"

        // Start timeout timer
        startFetchTimeout()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let task = Process()
            self.fetchTask = task
            task.executableURL = URL(fileURLWithPath: ytdlp)
            // Use --flat-playlist to quickly list videos without fetching all metadata
            task.arguments = ["-J", "--flat-playlist", "--no-warnings", url]

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
                    self.cancelTimeoutTimer()
                    self.fetchTask = nil

                    if task.terminationStatus != 0 {
                        let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        self.setDownloadError(errorString)
                        return
                    }

                    do {
                        if let json = try JSONSerialization.jsonObject(with: outputData) as? [String: Any] {
                            let videos = self.parsePageScan(json: json, originalUrl: url)
                            self.scannedVideos = videos
                            self.state = .idle

                            if videos.isEmpty {
                                self.outputLog += "No videos found on this page.\n"
                            } else {
                                self.outputLog += "Found \(videos.count) video(s)\n"
                            }
                        } else {
                            self.state = .error("Failed to parse page data")
                            self.outputLog += "Error: Could not parse JSON response\n"
                        }
                    } catch {
                        self.state = .error("JSON parsing error: \(error.localizedDescription)")
                        self.outputLog += "Error parsing JSON: \(error.localizedDescription)\n"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.cancelTimeoutTimer()
                    self.fetchTask = nil
                    self.state = .error("Error: \(error.localizedDescription)")
                    self.outputLog += "Error: \(error.localizedDescription)\n"
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

    func fetchFormats(url: String) {
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
        state = .timeout("Operation is taking too long. The server might be slow or unresponsive.")
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
            state = .timeout("Download appears to be stalled. No progress for \(Int(stallTime)) seconds.")
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
        if bytes == 0 { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Download

    /// Shared yt-dlp process runner used by every download path.
    ///
    /// Spawns yt-dlp with the assembled `arguments`, streams stdout to
    /// `progressHandler` and stderr to `outputLog`, waits for exit, then calls
    /// `completion` on the main thread with the success flag and captured stderr.
    /// If `queueItemId` is provided the process is tracked in `downloadTasks`
    /// (so parallel-queue cancellation can reach it); otherwise it is tracked as
    /// the single `downloadTask`. `progressHandler` is invoked on the main thread.
    private func runYTDLP(
        arguments: [String],
        queueItemId: UUID? = nil,
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

        // Track the process on the main actor so cancelDownload() can reach it.
        if let id = queueItemId {
            downloadTasks[id] = task
        } else {
            downloadTask = task
        }

        // Stream output. Handlers run on a Foundation I/O queue; hop to the main actor.
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let output = String(data: data, encoding: .utf8) {
                Task { @MainActor in progressHandler(output) }
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let output = String(data: data, encoding: .utf8) {
                Task { @MainActor in self?.outputLog += output }
            }
        }

        // Process and Pipe are non-Sendable but are safe to run/read on the
        // background queue here; vouch for the cross-thread hand-off.
        nonisolated(unsafe) let runTask = task
        nonisolated(unsafe) let runPipe = pipe
        nonisolated(unsafe) let runErrorPipe = errorPipe

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try runTask.run()
                runTask.waitUntilExit()

                runPipe.fileHandleForReading.readabilityHandler = nil
                runErrorPipe.fileHandleForReading.readabilityHandler = nil

                let success = runTask.terminationStatus == 0
                let errorOutput: String?
                if success {
                    errorOutput = nil
                } else {
                    let errorData = runErrorPipe.fileHandleForReading.readDataToEndOfFile()
                    errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                }

                Task { @MainActor in
                    if let id = queueItemId { self?.downloadTasks[id] = nil }
                    completion(success, errorOutput)
                }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in
                    if let id = queueItemId { self?.downloadTasks[id] = nil }
                    completion(false, message)
                }
            }
        }
    }

    func download(url: String, formatId: String, outputPath: String) {
        state = .downloading(progress: 0, speed: "Starting…")
        startDownloadStallDetection()
        outputLog = "Starting download...\n"

        // Use truncated title (max 80 chars) + video ID to avoid "filename too long" errors
        let outputTemplate = "\(outputPath)/%(title).80s [%(id)s].%(ext)s"

        var args: [String]
        if let info = videoInfo,
           let format = info.formats.first(where: { $0.id == formatId }),
           format.isVideoOnly {
            // Pick a QuickTime-playable codec at the chosen resolution: H.264 first,
            // then AV1 (both play on modern macOS), avoiding VP9 (which QuickTime can't
            // open). Always merge AAC audio into an mp4 container.
            let height = Int(format.resolution.filter(\.isNumber)) ?? 0
            let cap = height > 0 ? "[height<=\(height)]" : ""
            let selector = [
                "bestvideo\(cap)[vcodec^=avc1]+bestaudio[ext=m4a]",
                "bestvideo\(cap)[vcodec^=av01]+bestaudio[ext=m4a]",
                "bestvideo\(cap)[vcodec^=av01]+bestaudio",
                "bestvideo\(cap)[vcodec^=avc]+bestaudio",
                "bestvideo\(cap)+bestaudio",
                "best\(cap)"
            ].joined(separator: "/")
            args = [
                "-f", selector,
                "-o", outputTemplate,
                "--newline", "--progress", "--no-playlist", "--restrict-filenames",
                "--merge-output-format", "mp4"
            ]
        } else {
            args = [
                "-f", formatId,
                "-o", outputTemplate,
                "--newline", "--progress", "--no-playlist", "--restrict-filenames"
            ]
        }
        args.append(contentsOf: youtubeWorkaroundArgs)
        if settings.downloadSubtitles {
            args.append(contentsOf: ["--write-subs", "--write-auto-subs", "--sub-langs", settings.subtitleLanguage])
        }
        args.append(url)

        runYTDLP(arguments: args, progressHandler: { [weak self] in self?.parseProgress($0) }) { [weak self] success, errorOutput in
            guard let self = self else { return }
            self.cancelTimeoutTimer()
            if success {
                self.state = .completed
                self.outputLog += "\nDownload completed!\n"
                self.lastDownloadedFilePath = self.findLatestDownloadedFile(in: outputPath)
                if let info = self.videoInfo {
                    let historyItem = HistoryItem(
                        url: url,
                        title: info.title,
                        thumbnail: info.thumbnail,
                        platform: Platform.detect(from: url),
                        isAudioOnly: false
                    )
                    self.historyManager.addToHistory(historyItem)
                }
                if self.settings.showNotifications {
                    self.sendNotification(title: "Download Complete", body: "Video saved to Downloads")
                }
                if self.settings.playSoundOnComplete {
                    self.playCompletionSound()
                }
            } else {
                self.setDownloadError(errorOutput ?? "Unknown error")
            }
        }
    }

    func downloadBest(url: String, outputPath: String) {
        state = .downloading(progress: 0, speed: "Starting…")
        startDownloadStallDetection()
        outputLog = "Starting download (best quality)...\n"

        let outputTemplate = "\(outputPath)/%(title).80s [%(id)s].%(ext)s"

        // Prefer H.264 (avc1) for QuickTime/macOS compatibility.
        // Falls back to any best video if H.264 is unavailable.
        let h264Format = "bestvideo[vcodec^=avc1]+bestaudio[ext=m4a]/bestvideo[vcodec^=av01]+bestaudio/bestvideo[vcodec^=avc]+bestaudio/bestvideo+bestaudio/best"
        var args = [
            "-f", h264Format,
            "-o", outputTemplate,
            "--newline", "--progress", "--no-playlist", "--restrict-filenames",
            "--merge-output-format", "mp4"
        ]
        args.append(contentsOf: youtubeWorkaroundArgs)
        if settings.downloadSubtitles {
            args.append(contentsOf: ["--write-subs", "--write-auto-subs", "--sub-langs", settings.subtitleLanguage])
        }
        args.append(url)

        runYTDLP(arguments: args, progressHandler: { [weak self] in self?.parseProgress($0) }) { [weak self] success, errorOutput in
            guard let self = self else { return }
            self.cancelTimeoutTimer()
            if success {
                self.state = .completed
                self.outputLog += "\nDownload completed!\n"
                self.lastDownloadedFilePath = self.findLatestDownloadedFile(in: outputPath)
                if let info = self.videoInfo {
                    let historyItem = HistoryItem(
                        url: url,
                        title: info.title,
                        thumbnail: info.thumbnail,
                        platform: Platform.detect(from: url),
                        isAudioOnly: false
                    )
                    self.historyManager.addToHistory(historyItem)
                }
                if self.settings.showNotifications {
                    self.sendNotification(title: "Download Complete", body: "Video saved to Downloads")
                }
                if self.settings.playSoundOnComplete {
                    self.playCompletionSound()
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

    func cancelDownload() {
        downloadTask?.terminate()
        downloadTask = nil
        // Terminate every in-flight parallel queue download, not just the last one.
        for task in downloadTasks.values {
            task.terminate()
        }
        downloadTasks.removeAll()
        activeDownloads = 0
        state = .idle
        isProcessingQueue = false
        outputLog += "\nDownload cancelled.\n"
    }

    func reset() {
        // Terminate any in-flight work first, so a stale completion handler can't
        // later mutate state for a URL the user has already moved on from.
        fetchTask?.terminate()
        fetchTask = nil
        downloadTask?.terminate()
        downloadTask = nil
        for task in downloadTasks.values { task.terminate() }
        downloadTasks.removeAll()
        cancelTimeoutTimer()
        activeDownloads = 0

        state = .idle
        videoInfo = nil
        scannedVideos = []
        outputLog = ""
        lastDownloadedFilePath = nil
    }

    // MARK: - Audio-Only Download (MP3)

    func downloadAudio(url: String, outputPath: String) {
        state = .downloading(progress: 0, speed: "Starting audio extraction…")
        startDownloadStallDetection()
        outputLog = "Starting audio download (MP3)...\n"

        // Use truncated title + video ID for filename
        let outputTemplate = "\(outputPath)/%(title).80s [%(id)s].%(ext)s"

        var args = [
            "-f", "bestaudio",
            "-x",  // Extract audio
            "--audio-format", "mp3",
            "--audio-quality", "0",  // Best quality
            "-o", outputTemplate,
            "--newline", "--progress", "--no-playlist", "--restrict-filenames"
        ]
        args.append(contentsOf: youtubeWorkaroundArgs)
        args.append(url)

        runYTDLP(arguments: args, progressHandler: { [weak self] in self?.parseProgress($0) }) { [weak self] success, errorOutput in
            guard let self = self else { return }
            self.cancelTimeoutTimer()
            if success {
                self.state = .completed
                self.outputLog += "\nAudio download completed!\n"
                self.lastDownloadedFilePath = self.findLatestDownloadedFile(in: outputPath)
                if self.settings.showNotifications {
                    self.sendNotification(title: "Download Complete", body: "Audio file saved to Downloads")
                }
                if self.settings.playSoundOnComplete {
                    self.playCompletionSound()
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

        var args = [
            "-f", "bestaudio",
            "-x",  // Extract audio
            "--audio-format", "wav",  // WAV for whisper compatibility
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
                completion(nil, msg)
            }
        }
    }

    // MARK: - Download Queue

    func addToQueue(url: String, title: String, thumbnail: String? = nil, isAudioOnly: Bool = false) {
        let item = QueueItem(url: url, title: title, thumbnail: thumbnail, isAudioOnly: isAudioOnly)
        downloadQueue.append(item)
        outputLog += "Added to queue: \(title)\n"
    }

    func addCurrentVideoToQueue(isAudioOnly: Bool = false) {
        guard let info = videoInfo else { return }
        addToQueue(url: info.url, title: info.title, thumbnail: info.thumbnail, isAudioOnly: isAudioOnly)
    }

    func addSelectedVideosToQueue(videos: [VideoInfo], isAudioOnly: Bool = false) {
        for video in videos {
            addToQueue(url: video.url, title: video.title, thumbnail: video.thumbnail, isAudioOnly: isAudioOnly)
        }
    }

    func removeFromQueue(id: UUID) {
        downloadQueue.removeAll { $0.id == id }
    }

    func clearQueue() {
        downloadQueue.removeAll()
        currentQueueIndex = 0
        isProcessingQueue = false
    }

    func startQueue(outputPath: String) {
        guard !downloadQueue.isEmpty else { return }
        guard !isProcessingQueue else { return }

        isProcessingQueue = true
        activeDownloads = 0
        processParallelQueue(outputPath: outputPath)
    }

    private func processParallelQueue(outputPath: String) {
        let maxParallel = settings.parallelDownloads

        // Start downloads up to the parallel limit
        while activeDownloads < maxParallel {
            guard let nextIndex = downloadQueue.firstIndex(where: { $0.status == .pending }) else {
                // No more pending items
                break
            }

            downloadQueue[nextIndex].status = .downloading
            activeDownloads += 1

            let item = downloadQueue[nextIndex]
            outputLog += "\n--- Starting [\(nextIndex + 1)/\(downloadQueue.count)]: \(item.title) ---\n"

            downloadQueueItem(item: item, outputPath: outputPath) { [weak self] success, error in
                guard let self = self else { return }

                DispatchQueue.main.async {
                    self.activeDownloads -= 1

                    // Resolve the item's *current* index by id — the array may have
                    // shifted (e.g. a removed item) since this download started.
                    let idx = self.downloadQueue.firstIndex(where: { $0.id == item.id })

                    if success {
                        if let idx {
                            self.downloadQueue[idx].status = .completed
                            self.downloadQueue[idx].progress = 1.0
                        }

                        // Add to history
                        let historyItem = HistoryItem(
                            url: item.url,
                            title: item.title,
                            thumbnail: item.thumbnail,
                            platform: Platform.detect(from: item.url),
                            isAudioOnly: item.isAudioOnly
                        )
                        self.historyManager.addToHistory(historyItem)
                    } else if let idx {
                        self.downloadQueue[idx].status = .failed(error ?? "Unknown error")
                    }

                    // Check if queue is complete
                    if self.downloadQueue.allSatisfy({ $0.status != .pending && $0.status != .downloading }) {
                        // Queue complete
                        self.isProcessingQueue = false
                        self.state = .completed

                        let completedCount = self.downloadQueue.filter { $0.status == .completed }.count
                        if self.settings.showNotifications {
                            self.sendNotification(title: "Queue Complete", body: "\(completedCount) of \(self.downloadQueue.count) downloads finished")
                        }
                        if self.settings.playSoundOnComplete {
                            self.playCompletionSound()
                        }
                        self.outputLog += "\n✅ Download queue completed!\n"
                    } else {
                        // Start more downloads
                        self.processParallelQueue(outputPath: outputPath)
                    }
                }
            }
        }
    }

    private func downloadQueueItem(item: QueueItem, outputPath: String, completion: @escaping (Bool, String?) -> Void) {
        state = .downloading(progress: 0, speed: "Starting…")

        let outputTemplate = "\(outputPath)/%(title).80s [%(id)s].%(ext)s"

        var args: [String]
        if item.isAudioOnly {
            args = [
                "-f", "bestaudio",
                "-x",
                "--audio-format", "mp3",
                "--audio-quality", "0",
                "-o", outputTemplate,
                "--newline", "--progress", "--no-playlist", "--restrict-filenames"
            ]
        } else {
            // Prefer H.264 for QuickTime/macOS compatibility
            let h264Format = "bestvideo[vcodec^=avc1]+bestaudio[ext=m4a]/bestvideo[vcodec^=av01]+bestaudio/bestvideo[vcodec^=avc]+bestaudio/bestvideo+bestaudio/best"
            args = [
                "-f", h264Format,
                "-o", outputTemplate,
                "--newline", "--progress", "--no-playlist", "--restrict-filenames",
                "--merge-output-format", "mp4"
            ]
        }
        args.append(contentsOf: youtubeWorkaroundArgs)
        args.append(item.url)

        runYTDLP(
            arguments: args,
            queueItemId: item.id,
            progressHandler: { [weak self] output in
                guard let self = self else { return }
                // Look up the item's *current* index by id so parallel downloads
                // each update their own row (currentQueueIndex was never assigned).
                if let idx = self.downloadQueue.firstIndex(where: { $0.id == item.id }) {
                    self.parseQueueProgress(output, itemIndex: idx)
                }
            }
        ) { success, errorOutput in
            completion(success, errorOutput)
        }
    }

    private func parseQueueProgress(_ output: String, itemIndex: Int) {
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

                    // Update queue item progress
                    if itemIndex < downloadQueue.count {
                        downloadQueue[itemIndex].progress = percent / 100
                        downloadQueue[itemIndex].speed = speed
                    }
                }
            }
        }
    }

    // MARK: - Notifications & Sound

    func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func playCompletionSound() {
        // Play system sound for completion
        NSSound(named: "Glass")?.play()
    }

    // MARK: - File Path Helper

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
