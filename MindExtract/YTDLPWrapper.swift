import Foundation
import Combine
import UserNotifications
import AVFoundation
import AppKit

// MARK: - Friendly error classification

struct DownloadErrorInfo {
    let message: String
    /// Signing in on the site (cookies from a browser) would fix it.
    var needsSignIn = false
    /// Trying again won't help (removed, private, DRM, unsupported).
    var permanent = false
}

/// Markers the app passes through the classifier for failures it detects itself.
enum DownloadFailure {
    static let stalled = "MindExtract: the download stalled"
    static let live = "MindExtract: live stream"
    static let noVideoOnPage = "MindExtract: no video on the page"
}

/// Maps raw yt-dlp stderr to a short, human, actionable message so users never
/// see Python tracebacks or `ERROR: [youtube] …` dumps. The raw text is still
/// kept in the output log for power users.
func classifyDownloadError(_ raw: String) -> DownloadErrorInfo {
    let s = raw.lowercased()
    func has(_ needles: String...) -> Bool { needles.contains { s.contains($0) } }

    if raw == DownloadFailure.noVideoOnPage {
        return DownloadErrorInfo(message: String(localized: "MindExtract couldn't find a video on this page. If the video plays somewhere else, open that page and try again."), permanent: true)
    }
    if raw == DownloadFailure.stalled {
        return DownloadErrorInfo(message: String(localized: "The download stopped moving. Check your connection and try again."))
    }
    // YouTube says this for a stream that's live now and for one that ended unrecorded.
    if has("live stream recording is not available", "recording is not available") {
        return DownloadErrorInfo(message: String(localized: "This live stream can't be saved. Try again once the site has a recording of it."), permanent: true)
    }
    if raw == DownloadFailure.live || has("live event will begin", "premieres in", "this live event", "is_live") {
        return DownloadErrorInfo(message: String(localized: "This is a live stream. Paste the link again after it ends."), permanent: true)
    }
    if has("http error 429", "too many requests") {
        return DownloadErrorInfo(message: String(localized: "The site is getting too many requests right now. Wait a few minutes and try again."))
    }
    if has("http error 403", "403: forbidden") {
        return DownloadErrorInfo(message: String(localized: "The site blocked the download. Try again in a moment, and if it keeps happening, update MindExtract."))
    }
    if has("ffmpeg not found", "ffmpeg is not installed", "ffprobe and ffmpeg not found", "bad cpu type") {
        return DownloadErrorInfo(message: String(localized: "A conversion tool is missing, so this download can't be finished. Reinstall MindExtract."))
    }

    // Before the bot check: "Sign in to confirm your age" would match it too.
    if has("confirm your age", "age-restricted", "age restricted", "inappropriate for some users") {
        return DownloadErrorInfo(message: String(localized: "This video is age-restricted. Sign in to YouTube to continue."), needsSignIn: true)
    }
    if has("sign in to confirm you're not a bot", "sign in to confirm you’re not a bot", "confirm you're not a bot", "confirm you’re not a bot", "sign in to confirm") {
        return DownloadErrorInfo(message: String(localized: "YouTube wants to confirm you're not a bot. Sign in to YouTube to continue."), needsSignIn: true)
    }
    if has("members-only", "join this channel", "available to this channel's members") {
        return DownloadErrorInfo(message: String(localized: "This is members-only content. Sign in with an account that has access."), needsSignIn: true)
    }
    if has("private video", "this video is private") {
        return DownloadErrorInfo(message: String(localized: "This video is private, so MindExtract can't get it."), permanent: true)
    }
    // Instagram, Facebook and others: before "is not available", which their
    // login message also contains.
    if has("login required", "log in to", "logged-in", "empty media response", "cookies-from-browser", "--cookies", "requires authentication", "registered users") {
        return DownloadErrorInfo(message: String(localized: "This post is only shown to people who are signed in. Pick the browser you're signed in with, then try again."), needsSignIn: true)
    }
    if has("drm protection", "drm-protected", "drm protected", "[drm]") {
        return DownloadErrorInfo(message: String(localized: "This service locks its media with DRM, so MindExtract can't get it."), permanent: true)
    }
    if has("video unavailable", "video is unavailable", "is not available", "no longer available", "has been removed", "this video has been removed") {
        return DownloadErrorInfo(message: String(localized: "This video is unavailable or has been removed."), permanent: true)
    }
    if has("requested format is not available", "requested format not available") {
        return DownloadErrorInfo(message: String(localized: "That size isn't available for this video. Pick another one from the arrow next to Save."))
    }
    if has("not available in your country", "not available from your location", "blocked in your country", "geo restrict") {
        return DownloadErrorInfo(message: String(localized: "This video isn't available in your region."), permanent: true)
    }
    if has("failed to resolve", "temporary failure in name resolution", "could not resolve host", "connection refused", "network is unreachable", "timed out", "connection timed out") {
        return DownloadErrorInfo(message: String(localized: "Network problem. Check your internet connection and try again."))
    }
    if has("http error 404", "unable to download webpage", "404: not found") {
        return DownloadErrorInfo(message: String(localized: "Couldn't reach that page. Check the link and try again."))
    }
    if has("unsupported url") {
        return DownloadErrorInfo(message: String(localized: "MindExtract can't get media from this site. Paste the link to the page where the video or episode plays."), permanent: true)
    }
    if has("no video formats found", "no video could be found", "there is no video", "unable to extract", "unable to find") {
        return DownloadErrorInfo(message: String(localized: "Couldn't find a video on that page. If it plays in your browser, updating MindExtract may help."))
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
        // "[youtube] abc123: " in front of the message
        .replacingOccurrences(of: #"^\[[^\]]+\]\s*[^:\s]+:\s*"#, with: "", options: .regularExpression)
    return DownloadErrorInfo(message: String(cleaned.prefix(200)))
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

    /// Set when the most recent error is one that signing in on the site would fix,
    /// so the UI can offer an inline "Sign In" action.
    @Published var lastErrorNeedsAuth: Bool = false
    /// The most recent error won't go away by trying again.
    @Published var lastErrorIsPermanent: Bool = false

    /// Centralizes error presentation: classify raw stderr into a friendly message,
    /// flag whether auth would help, and keep the raw text in the log.
    private func setDownloadError(_ raw: String) {
        let info = classifyDownloadError(raw)
        lastErrorNeedsAuth = info.needsSignIn
        lastErrorIsPermanent = info.permanent
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
    /// When yt-dlp last showed progress. nil while it post-processes (merging,
    /// converting), which shows none and can take minutes for long media.
    private var lastProgressTime: Date?
    private var sawProgress = false
    /// The stall check stopped yt-dlp: report that rather than its exit.
    private var stalled = false
    /// Streams in this download (video + audio = 2) and which one is running,
    /// so the progress bar runs once from 0 to 100 instead of once per stream.
    private var streamCount = 1
    private var streamIndex = 0
    /// yt-dlp is fetching a subtitle file: its progress isn't the video's.
    private var inSubtitle = false
    /// yt-dlp found the file already saved by an earlier download.
    private var reusedExisting = false
    /// The running save's "where did it go" file, removed on cancel.
    private var pendingSavedPathFile: String?

    // Settings and managers
    private let settings = AppSettings.shared
    private let historyManager = HistoryManager.shared

    // Timeout settings (in seconds)
    private let fetchTimeout: TimeInterval = 45
    private let downloadStallTimeout: TimeInterval = 30
    /// Before the first progress: looking up the video can take a while.
    private let downloadStartTimeout: TimeInterval = 90

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
        guard !quietLookup else { return args }

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
    /// A lookup nobody asked for yet (a copied link): no browser cookies, so
    /// it can't bring up a Keychain prompt. The real lookup or save uses them.
    private var quietLookup = false

    func loadURL(_ url: String, quiet: Bool = false) {
        quietLookup = quiet
        defer { quietLookup = false }
        guard let ytdlp = ytdlpPath else {
            state = .error("yt-dlp not found. Please install it with: brew install yt-dlp")
            return
        }

        PageVideos.shared.dropIfStale(url)      // a signed stream link may have expired: search the page again
        loadGeneration += 1
        let generation = loadGeneration
        fetchTask?.terminate()
        // State first, so nothing reads the previous video's info as this one's.
        state = .fetchingFormats
        scannedVideos = []
        videoInfo = nil
        lastErrorNeedsAuth = false
        lastErrorIsPermanent = false
        outputLog = "Loading: \(url)\n"
        fetchQuickPreview(for: url, generation: generation)
        startFetchTimeout()
        let toolArgs = youtubeWorkaroundArgs     // now, while quietLookup applies
        probe(url, ytdlp: ytdlp, generation: generation, toolArgs: toolArgs, scanned: false)
    }

    /// The lookup itself. `scanned`: the page was already searched for its video.
    private func probe(_ url: String, ytdlp: String, generation: Int, toolArgs: [String], scanned: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let task = Process()
            self.fetchTask = task
            task.executableURL = URL(fileURLWithPath: ytdlp)
            // Fast probe: list entries flat (no per-video metadata) to detect playlists.
            task.arguments = ["-J", "--flat-playlist", "--no-warnings"] + toolArgs + Self.target(url)

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
                        // A site yt-dlp doesn't know (a webinar platform, a company
                        // page): look for the video on the page itself, as a browser
                        // extension would, and fetch that.
                        if !scanned, errorString.contains("Unsupported URL"),
                           PageVideos.shared.video(for: url) == nil, PageScanner.isScannable(url) {
                            self.startFetchTimeout()
                            Task { @MainActor in
                                let found = await PageScanner.scan(url)
                                // Not after a cancel, a newer link, or the timeout's message.
                                guard generation == self.loadGeneration, case .fetchingFormats = self.state else { return }
                                guard let found else {
                                    self.cancelTimeoutTimer()
                                    self.setDownloadError(DownloadFailure.noVideoOnPage)
                                    return
                                }
                                PageVideos.shared.add(found)
                                self.outputLog += "Found the video on the page: \(found.mediaURL)\n"
                                self.probe(url, ytdlp: ytdlp, generation: generation, toolArgs: toolArgs, scanned: true)
                            }
                            return
                        }
                        self.setDownloadError(errorString)
                        return
                    }

                    guard let json = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any] else {
                        self.state = .error("Couldn't read that page. Check the link and try again.")
                        return
                    }

                    let entries = json["entries"] as? [[String: Any]]
                    if let entries, entries.count > 1 {
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
                        // A wrapper around one video (a channel or playlist with a
                        // single entry): fetch that video, not the wrapper.
                        let entry = entries?.first
                        let inner = entry?["webpage_url"] as? String ?? entry?["url"] as? String
                        self.fetchFormats(url: inner.flatMap { $0.hasPrefix("http") ? $0 : nil } ?? url, generation: generation)
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
            task.arguments = ["-J", "--no-warnings", "--no-playlist"] + youtubeWorkaroundArgs + Self.target(url)

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
        sawProgress = false
        stalled = false
        streamCount = 1
        streamIndex = 0
        ffmpegDuration = nil
        ffmpegTime = nil
        ffmpegPending = ""
        inSubtitle = false
        reusedExisting = false
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
        if stallTime > (sawProgress ? downloadStallTimeout : downloadStartTimeout) {
            // The run's own completion reports it, so the job's caller hears about it too.
            stalled = true
            downloadTask?.terminate()
            cancelTimeoutTimer()
            outputLog += "\n⚠️ STALL DETECTED: No download progress for \(Int(stallTime)) seconds.\n"
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
        let liveStatus = json["live_status"] as? String
        let isLive = json["is_live"] as? Bool == true || liveStatus == "is_live" || liveStatus == "is_upcoming"
        let language = (json["language"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        var formats: [VideoFormat] = []

        if let formatList = json["formats"] as? [[String: Any]] {
            for format in formatList {
                let formatId = format["format_id"] as? String ?? ""
                let ext = format["ext"] as? String ?? ""

                let height = format["height"] as? Int
                let width = format["width"] as? Int
                let shortSide = min(width ?? .max, height ?? .max)
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
                    isVideoOnly: isVideoOnly,
                    shortSide: shortSide == .max ? 0 : shortSide,
                    vcodec: vcodec
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

        // A stream found on a page knows nothing about itself ("hls"): the page does.
        if let page = PageVideos.shared.video(for: url), page.pageNamesIt {
            return VideoInfo(id: id, title: page.title ?? title, thumbnail: page.thumbnail ?? thumbnail, duration: duration,
                             uploader: page.site ?? uploader, url: url, formats: formats, isLive: isLive, language: language)
        }
        return VideoInfo(id: id, title: title, thumbnail: thumbnail, duration: duration, uploader: uploader, url: url,
                         formats: formats, isLive: isLive, language: language)
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds <= 0 { return "" }
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
        let runGeneration = downloadGeneration
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let output = String(data: data, encoding: .utf8) {
                // Output that arrives after a Cancel mustn't bring "downloading" back.
                Task { @MainActor in
                    guard let self, runGeneration == self.downloadGeneration else { return }
                    progressHandler(output)
                }
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
                Task { @MainActor in
                    guard let self else { return }
                    self.outputLog += output
                    // A stream yt-dlp hands to ffmpeg (an encrypted HLS track) reports
                    // its progress here, as ffmpeg's "time=": it counts as progress too.
                    guard runGeneration == self.downloadGeneration else { return }
                    self.readFFmpeg(output)
                }
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
            // The last lines can still be in the pipe ("does not pass filter", the saved path).
            let rest = String(data: runPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

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
                if !rest.isEmpty { progressHandler(rest) }
                self.downloadTask = nil
                let error = self.stalled ? DownloadFailure.stalled : errorOutput
                self.stalled = false
                // After a success the job decides what's temporary (its own file may be).
                if !success { self.removeTempFiles() }
                completion(success, error)
            }
        }
    }

    /// yt-dlp's format choice for the user's preferred quality. The highest
    /// resolution wins, sized by the short side so phone videos aren't cut down.
    /// A format the Mac plays as is (H.264, HEVC) is taken when it reaches the
    /// quality asked for; otherwise the sharper format is fetched and converted
    /// afterwards (Instagram's full-size reels only exist as VP9). AV1 is skipped
    /// on Macs that can't decode it, since it can't be converted there either.
    /// `height` is a size picked in the notch (4K…); without one, Settings decide.
    private func videoFormatArgs(height: Int?) -> [String] {
        let setting: Int? = switch settings.downloadQuality {
        case .hd1080: 1080
        case .hd720: 720
        default: nil
        }
        let cap = height ?? setting
        let enough = cap ?? 1080
        let codecs = VideoConverter.canPlayAV1 ? "avc|h26[45]|hvc|hev|av01" : "avc|h26[45]|hvc|hev"
        let plays = "[vcodec~='^(\(codecs))'][height>=?\(enough)][width>=?\(enough)]"
        let av1 = VideoConverter.canPlayAV1 ? "" : "[vcodec!^=?av01]"
        let sound = "[format_id!=audio]"    // TikTok's "audio" is the post's song, not its sound
        return [
            "-f", "bv*\(plays)+ba\(sound)/bv*\(av1)+ba\(sound)/b\(av1)/b",
            "-S", "\(cap.map { "res:\($0)" } ?? "res"),vcodec:h265,acodec:aac",
            "--merge-output-format", "mp4",
        ]
    }

    /// Where the finished file goes, and a private folder for the parts while it
    /// downloads: a cancelled or failed download leaves nothing in the user's folder.
    /// `label` names the size ("720p", "4K Original") so a second save at
    /// another size is a new file, not yt-dlp's "already downloaded" old one.
    private func outputArgs(_ outputPath: String, url: String, label: String? = nil) -> [String] {
        let work = NSTemporaryDirectory() + "mindextract-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        tempPrefixes = [work]
        let suffix = label.map { " " + $0.replacingOccurrences(of: "%", with: "%%") } ?? ""
        // A stream found on a page is named after the page, not itself ("hls [hls]"),
        // with a short mark of the stream so two pages with one title stay two files.
        if let page = PageVideos.shared.video(for: url), page.pageNamesIt,
           let title = page.title.map(Self.fileName), !title.isEmpty {
            return ["-P", outputPath, "-P", "temp:" + work, "-o", "\(title) [\(Self.shortMark(page.mediaURL))]\(suffix).%(ext)s"]
        }
        return ["-P", outputPath, "-P", "temp:" + work, "-o", "%(title).120B [%(id)s]\(suffix).%(ext)s"]
    }

    /// A page title as a file name, written for yt-dlp's -o (where % is special).
    /// yt-dlp expands $VARIABLES and a leading ~ in -o, so those go too: a page
    /// can't steer the file out of the save folder. At most 180 bytes, since a
    /// file name may be 255 and the size and extension follow.
    nonisolated static func fileName(_ title: String) -> String {
        var bad = CharacterSet(charactersIn: "/:\\$\u{7F}").union(.newlines)
        bad.insert(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(0x1F))
        let clean = title.components(separatedBy: bad).joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        var short = ""
        for ch in clean {
            if short.utf8.count + String(ch).utf8.count > 180 { break }
            short.append(ch)
        }
        short = short.trimmingCharacters(in: CharacterSet(charactersIn: " .~"))
        return short.replacingOccurrences(of: "%", with: "%%")
    }

    /// Six letters that stay the same for one stream (FNV-1a), for its file name.
    nonisolated static func shortMark(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(String(hash, radix: 36).suffix(6))
    }

    /// The address to hand yt-dlp. A plain vimeo.com video page now wants a
    /// login; the same video's player page doesn't.
    nonisolated static func fetchableURL(_ url: String) -> String {
        // A page whose video was found on it: the stream or player it plays.
        if let page = PageVideos.shared.video(for: url) { return page.mediaURL }
        guard let comps = URLComponents(string: url), let host = comps.host?.lowercased(),
              host == "vimeo.com" || host == "www.vimeo.com",
              let id = comps.path.split(separator: "/").first, id.allSatisfy(\.isNumber) else { return url }
        // An unlisted video's link carries its key as the second part: vimeo.com/123/abcdef12
        let parts = comps.path.split(separator: "/")
        if parts.count > 1, parts[1].allSatisfy(\.isHexDigit) {
            return "https://player.vimeo.com/video/\(id)?h=\(parts[1])"
        }
        return "https://player.vimeo.com/video/\(id)"
    }

    /// The link to hand yt-dlp, last on its command line. A video found on a
    /// page is fetched as that page would fetch it (some streams check that).
    nonisolated static func target(_ url: String) -> [String] {
        guard let page = PageVideos.shared.video(for: url) else { return [fetchableURL(url)] }
        // Only the origin, as a browser sends it to another site: the page's own
        // address (a webinar's member id) stays with the page.
        return (page.referer.map { ["--referer", $0] } ?? []) + [page.mediaURL]
    }

    /// Live streams have nothing to save until they end; yt-dlp would record forever.
    private let notLive = ["--match-filters", "live_status!=?is_live & live_status!=?is_upcoming"]

    private func removeTempFiles() {
        let fm = FileManager.default
        for prefix in tempPrefixes {
            let dir = (prefix as NSString).deletingLastPathComponent
            let name = (prefix as NSString).lastPathComponent
            for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where item.hasPrefix(name) {
                try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(item))
            }
        }
        tempPrefixes = []
    }

    /// The sizes `formats` come in, highest first. AV1 counts only on Macs that
    /// can decode it; a size only in VP9 (or AV1) is marked as converted.
    static func qualities(in formats: [VideoFormat]) -> [VideoQuality] {
        var playsAsIs: [Int: Bool] = [:]
        var largest: [Int: Int] = [:]
        var largestPlaying: [Int: Int] = [:]
        for f in formats where !f.isAudioOnly && f.shortSide > 0 && f.vcodec != "none" {
            let codec = f.vcodec.lowercased()
            if codec.hasPrefix("av01") && !VideoConverter.canPlayAV1 { continue }
            guard let size = VideoQuality.size(for: f.shortSide) else { continue }
            let plays = ["avc", "h264", "h265", "hvc", "hev"].contains { codec.hasPrefix($0) }
                || (codec.hasPrefix("av01") && VideoConverter.canPlayAV1)
            playsAsIs[size] = (playsAsIs[size] ?? false) || plays
            largest[size] = max(largest[size] ?? 0, f.shortSide)
            if plays { largestPlaying[size] = max(largestPlaying[size] ?? 0, f.shortSide) }
        }
        // A size that plays as is asks for its largest playable format, so a
        // slightly bigger VP9 in the same size isn't fetched and converted.
        return playsAsIs.map { VideoQuality(height: $0.key, converts: !$0.value,
                                            fetchHeight: largestPlaying[$0.key] ?? largest[$0.key] ?? $0.key,
                                            originalHeight: largest[$0.key] ?? $0.key) }
            .sorted { $0.height > $1.height }
    }

    /// `keepOriginal`: the site's own file at that size, never converted, in an
    /// .mkv (which holds any codec, so Finder hands it to VLC or IINA instead of
    /// QuickTime showing a black picture).
    func downloadBest(url: String, outputPath: String, height: Int? = nil, label: String? = nil, keepOriginal: Bool = false) {
        state = .downloading(progress: 0, speed: "Starting…")
        startDownloadStallDetection()
        outputLog = "Starting download (\(height.map { "\($0)p" } ?? "best quality")\(keepOriginal ? ", original" : ""))...\n"

        let formatArgs = keepOriginal
            ? ["-f", "bv*+ba[format_id!=audio]/b", "-S", height.map { "res:\($0)" } ?? "res", "--merge-output-format", "mkv"]
            : videoFormatArgs(height: height)
        var args = formatArgs + outputArgs(outputPath, url: url, label: label) + notLive + ["--newline", "--progress", "--no-playlist"]
        args.append(contentsOf: youtubeWorkaroundArgs)
        if settings.downloadSubtitles {
            // Inside the video, where QuickTime shows them. Only the language
            // itself: "en.*" also asks for every machine translation into it,
            // which YouTube answers with "Too Many Requests". A subtitle that
            // still fails doesn't stop the video (--ignore-errors).
            args.append(contentsOf: ["--embed-subs", "--write-auto-subs", "--sub-langs", settings.subtitleLanguage, "--ignore-errors"])
        }
        let savedPathFile = Self.makeSavedPathFile()
        pendingSavedPathFile = savedPathFile
        args.append(contentsOf: ["--print-to-file", "after_move:filepath", savedPathFile])
        args += Self.target(url)

        runYTDLP(arguments: args, progressHandler: { [weak self] in self?.parseProgress($0) }) { [weak self] success, errorOutput in
            guard let self = self else { return }
            self.cancelTimeoutTimer()
            // The file is what counts: with --ignore-errors a failed subtitle ends
            // the run with an error even though the video was saved.
            guard let saved = Self.savedPath(from: savedPathFile) else {
                if success && self.outputLog.contains("does not pass filter") {
                    self.setDownloadError(DownloadFailure.live)
                } else if success {
                    self.removeTempFiles()
                    self.finishDownload(url: url, path: nil)    // reported as "file wasn't found"
                } else {
                    self.setDownloadError(errorOutput ?? "Unknown error")
                }
                return
            }
            self.removeTempFiles()
            if keepOriginal {
                self.finishDownload(url: url, path: saved)
                return
            }
            // A video in a codec this Mac can't play (VP9, or AV1 before M3) is
            // re-encoded to H.264 first. Cancel stops ffmpeg and removes the new
            // file, but never one an earlier download saved.
            self.tempPrefixes = [self.reusedExisting ? saved + ".converting" : saved]
            let generation = self.downloadGeneration
            Task { @MainActor in
                let playable = await VideoConverter.makePlayable(saved, started: { process in
                    guard generation == self.downloadGeneration else { process.terminate(); return }
                    self.downloadTask = process
                    self.state = .downloading(progress: 0, speed: Self.convertingPhase)
                }, cancelled: { generation != self.downloadGeneration }, progress: { p in
                    // A late update after the job finished mustn't bring "downloading" back.
                    guard generation == self.downloadGeneration, case .downloading = self.state else { return }
                    self.state = .downloading(progress: p, speed: Self.convertingPhase)
                })
                guard generation == self.downloadGeneration else { return }
                self.downloadTask = nil
                self.tempPrefixes = []
                if playable != saved { self.outputLog += "Converted so it plays on this Mac.\n" }
                self.finishDownload(url: url, path: playable)
            }
        }
    }

    /// The `speed` text while a saved video is converted, for the notch's phase line.
    static let convertingPhase = "Converting…"

    private func finishDownload(url: String, path: String?, audioOnly: Bool = false) {
        state = .completed
        outputLog += "\nDownload completed!\n"
        lastDownloadedFilePath = path
        if let info = videoInfo {
            let historyItem = HistoryItem(
                url: url,
                title: info.title,
                thumbnail: info.thumbnail,
                platform: Platform.detect(from: url),
                isAudioOnly: audioOnly,
                filePath: path
            )
            historyManager.addToHistory(historyItem)
        }
    }

    // MARK: ffmpeg's progress

    /// The length ffmpeg reported for the stream it's fetching, for its percentage.
    private var ffmpegDuration: Double?
    /// How far it got, so only moving forward counts as progress.
    private var ffmpegTime: Double?
    /// A line ffmpeg hasn't finished writing yet (it ends its lines with \r).
    private var ffmpegPending = ""

    /// One line of ffmpeg's log: the stream's length ("Duration: 00:37:16.58")
    /// or how far it got ("size=… time=00:10:30.03 …").
    nonisolated static func ffmpegLine(_ line: Substring) -> (duration: Double?, time: Double?) {
        func seconds(_ t: Substring) -> Double? {
            let parts = t.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 3 else { return nil }
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
        }
        let duration = line.firstMatch(of: #/Duration:\s*(\d+:\d+:\d+(?:\.\d+)?)/#).flatMap { seconds($0.1) }.flatMap { $0 > 0 ? $0 : nil }
        let time = line.firstMatch(of: #/time=\s*(\d+:\d+:\d+(?:\.\d+)?)/#).flatMap { seconds($0.1) }
        return (duration, time)
    }

    /// ffmpeg's log as it arrives, whole lines only. Its clock moving forward
    /// keeps the stall check quiet; with the length known it's a percentage too.
    private func readFFmpeg(_ chunk: String) {
        ffmpegPending += chunk
        guard let end = ffmpegPending.lastIndex(where: { $0 == "\r" || $0 == "\n" }) else {
            if ffmpegPending.count > 4096 { ffmpegPending = "" }
            return
        }
        let complete = ffmpegPending[..<end]
        ffmpegPending = String(ffmpegPending[ffmpegPending.index(after: end)...])
        for line in complete.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            let (duration, time) = Self.ffmpegLine(line)
            if let duration { ffmpegDuration = duration }
            guard let time, time > (ffmpegTime ?? -1), case .downloading = state else { continue }
            ffmpegTime = time
            lastProgressTime = Date()
            sawProgress = true
            if let length = ffmpegDuration { setStreamProgress(min(100, time / length * 100), speed: "") }
        }
    }

    /// Reads yt-dlp's output line by line: download progress, and the steps
    /// after it (merging, extracting audio), which show no progress of their own.
    private func parseProgress(_ output: String) {
        outputLog += output
        for line in output.split(whereSeparator: \.isNewline) {
            if line.contains("has already been downloaded") { reusedExisting = true }
            // "[info] abc: Downloading 1 format(s): 137+140"
            if let r = line.range(of: "Downloading 1 format(s): ") {
                streamCount = max(1, line[r.upperBound...].split(separator: "+").count)
            }
            // A subtitle's Destination line isn't a stream, and its progress isn't ours.
            if line.hasPrefix("[download] Destination:") {
                let ext = (String(line) as NSString).pathExtension.lowercased()
                inSubtitle = ["vtt", "srt", "ttml", "dfxp", "sbv", "json", "json3", "srv1", "srv2", "srv3", "ass", "ssa", "lrc"].contains(ext)
                if !inSubtitle {
                    streamIndex += 1
                    ffmpegTime = nil        // a new stream: ffmpeg's clock starts over
                    ffmpegDuration = nil
                }
            }
            if inSubtitle { continue }
            if ["[Merger]", "[ExtractAudio]", "[EmbedSubtitle]", "[Fixup", "[VideoRemuxer]", "[VideoConvertor]", "[MoveFiles]"]
                .contains(where: { line.hasPrefix($0) }) {
                lastProgressTime = nil      // working, just without a percentage
                continue
            }
            guard line.contains("%"),
                  let match = line.firstMatch(of: #/(\d+\.?\d*)%.*?at\s+(\S+)/#),
                  let percent = Double(match.1) else { continue }
            setStreamProgress(percent, speed: String(match.2))
        }
    }

    /// One stream's percentage as the whole download's progress.
    private func setStreamProgress(_ percent: Double, speed: String) {
        do {
            // The video stream is most of the bytes; the audio after it the rest.
            let index = min(max(streamIndex, 1), streamCount)
            let progress: Double
            if streamCount > 1 {
                let videoShare = 0.85
                progress = index == 1 ? percent / 100 * videoShare
                    : videoShare + (1 - videoShare) * (Double(index - 2) + percent / 100) / Double(streamCount - 1)
            } else {
                progress = percent / 100
            }
            state = .downloading(progress: min(progress, 1), speed: speed)
            lastProgressTime = Date()
            sawProgress = true
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
        if let file = pendingSavedPathFile { try? FileManager.default.removeItem(atPath: file) }
        pendingSavedPathFile = nil
        if let task = downloadTask, task.isRunning { task.terminate() }
        downloadTask = nil
        removeTempFiles()
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

    /// yt-dlp's audio choice. TikTok lists the post's background song as an
    /// audio format ("audio"); the video's own sound is the video file's track.
    /// AAC first, so saving needs no re-encode.
    private static let audioFormat = "ba[ext=m4a][format_id!=audio]/ba[format_id!=audio]/b"

    func downloadAudio(url: String, outputPath: String) {
        state = .downloading(progress: 0, speed: "Starting audio extraction…")
        startDownloadStallDetection()
        outputLog = "Starting audio download (M4A)...\n"

        var args = [
            "-f", Self.audioFormat,
            "-x",  // Extract audio
            "--audio-format", "m4a",
            "--audio-quality", "0",  // Best quality
        // Its own name: on sites without a separate audio stream yt-dlp fetches the
        // video and deletes it after taking the sound, which must never be a video
        // the user saved earlier under the same name.
        ] + outputArgs(outputPath, url: url, label: "Audio") + notLive + ["--newline", "--progress", "--no-playlist"]
        args.append(contentsOf: youtubeWorkaroundArgs)
        let savedPathFile = Self.makeSavedPathFile()
        pendingSavedPathFile = savedPathFile
        args.append(contentsOf: ["--print-to-file", "after_move:filepath", savedPathFile])
        args += Self.target(url)

        runYTDLP(arguments: args, progressHandler: { [weak self] in self?.parseProgress($0) }) { [weak self] success, errorOutput in
            guard let self = self else { return }
            self.cancelTimeoutTimer()
            let saved = Self.savedPath(from: savedPathFile)
            if success, saved == nil, self.outputLog.contains("does not pass filter") {
                self.setDownloadError(DownloadFailure.live)
            } else if success {
                self.removeTempFiles()
                self.finishDownload(url: url, path: saved, audioOnly: true)
            } else {
                self.setDownloadError(errorOutput ?? "Unknown error")
            }
        }
    }

    // MARK: - Download Audio for Transcription (to temp folder)

    /// Fetches a link's audio to the temp folder as the site serves it (m4a,
    /// webm…): the transcriber reads any of them, so there's no slow conversion
    /// to a huge WAV first. Calls back with the file, an error, and the spoken
    /// language when the site says.
    func downloadAudioForTranscription(url: String, completion: @escaping (_ path: String?, _ error: String?, _ language: String?) -> Void) {
        state = .downloading(progress: 0, speed: "Downloading audio for transcription…")
        startDownloadStallDetection()
        outputLog = "Downloading audio for transcription...\n"

        let tempDir = NSTemporaryDirectory()
        let tempFileName = UUID().uuidString
        let outputTemplate = "\(tempDir)\(tempFileName).%(ext)s"
        let languageFile = "\(tempDir)\(tempFileName)-language.txt"
        tempPrefixes = [tempDir + tempFileName]

        var args = [
            "-f", Self.audioFormat,
            // The original language first (not a dub), normal AAC quality (not
            // the 48 kbps loudness-squashed variant), then the smallest file: for
            // a video without a separate audio stream that's still the sound.
            "-S", "lang,abr~128,+size",
            "-o", outputTemplate,
            "--print-to-file", "before_dl:%(language)s", languageFile,
            "--newline", "--progress", "--no-playlist",
        ] + notLive
        args.append(contentsOf: youtubeWorkaroundArgs)
        args += Self.target(url)

        runYTDLP(arguments: args, progressHandler: { [weak self] in self?.parseProgress($0) }) { [weak self] success, errorOutput in
            guard let self = self else { return }
            self.cancelTimeoutTimer()
            let language = (try? String(contentsOfFile: languageFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(atPath: languageFile)
            let spoken = language.flatMap { $0.isEmpty || $0 == "NA" ? nil : $0 }
            self.tempPrefixes = []      // the audio stays for the transcriber, which removes it
            guard success else {
                let msg = errorOutput ?? "Unknown error"
                self.setDownloadError(msg)
                completion(nil, classifyDownloadError(msg).message, nil)
                return
            }
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: tempDir)) ?? []
            if let file = contents.first(where: { $0.hasPrefix(tempFileName) && !$0.hasSuffix(".part") }) {
                self.state = .idle
                self.outputLog += "\nAudio downloaded for transcription.\n"
                completion(tempDir + file, nil, spoken)
            } else {
                let msg = self.outputLog.contains("does not pass filter") ? DownloadFailure.live : "Could not find downloaded audio file"
                self.setDownloadError(msg)
                completion(nil, classifyDownloadError(msg).message, nil)
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
