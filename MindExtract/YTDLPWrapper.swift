import Foundation
import Combine
import UserNotifications
import AVFoundation
import AppKit

class YTDLPWrapper: ObservableObject {
    @Published var state: DownloadState = .idle
    @Published var videoInfo: VideoInfo?
    @Published var scannedVideos: [VideoInfo] = []
    @Published var outputLog: String = ""
    @Published var lastDownloadedFilePath: String?

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

        // Only use OAuth when signed in (web_creator client needs auth)
        if settings.youtubeSignedIn {
            args += ["--username", "oauth2", "--password", ""]
        }

        // Fallback: cookies file or browser cookies
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
        requestNotificationPermission()
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted {
                print("Notification permission granted")
            }
        }
    }

    private func findYTDLP() {
        // First, check for bundled yt-dlp in app Resources
        if let bundledPath = Bundle.main.path(forResource: "yt-dlp", ofType: nil) {
            ytdlpPath = bundledPath
            print("Found bundled yt-dlp at: \(bundledPath)")
            return
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
                        self.state = .error("Failed to scan page: \(errorString)")
                        self.outputLog += "Error: \(errorString)\n"
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
                        self.state = .error("Failed to fetch video info: \(errorString)")
                        self.outputLog += "Error: \(errorString)\n"
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

    func download(url: String, formatId: String, outputPath: String) {
        guard let ytdlp = ytdlpPath else {
            state = .error("yt-dlp not found")
            return
        }

        state = .downloading(progress: 0, speed: "Starting...")
        startDownloadStallDetection()
        outputLog = "Starting download...\n"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let task = Process()
            task.executableURL = URL(fileURLWithPath: ytdlp)

            // Use truncated title (max 80 chars) + video ID to avoid "filename too long" errors
            let outputTemplate = "\(outputPath)/%(title).80s [%(id)s].%(ext)s"

            var args = [
                "-f", formatId,
                "-o", outputTemplate,
                "--newline",
                "--progress",
                "--no-playlist",
                "--restrict-filenames"
            ]
            args.append(contentsOf: self.youtubeWorkaroundArgs)

            if let info = self.videoInfo,
               let format = info.formats.first(where: { $0.id == formatId }),
               format.isVideoOnly {
                // Video-only stream: merge with best audio, output as mp4
                args = [
                    "-f", "\(formatId)+bestaudio[ext=m4a]/\(formatId)+bestaudio",
                    "-o", outputTemplate,
                    "--newline",
                    "--progress",
                    "--no-playlist",
                    "--restrict-filenames",
                    "--merge-output-format", "mp4"
                ]
                args.append(contentsOf: self.youtubeWorkaroundArgs)
            }

            // Add subtitle options if enabled
            if self.settings.downloadSubtitles {
                args.append(contentsOf: ["--write-subs", "--write-auto-subs", "--sub-langs", self.settings.subtitleLanguage])
            }

            args.append(url)

            task.arguments = args

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            task.environment = env

            let pipe = Pipe()
            let errorPipe = Pipe()
            task.standardOutput = pipe
            task.standardError = errorPipe

            self.downloadTask = task

            do {
                try task.run()

                pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    if data.isEmpty { return }

                    if let output = String(data: data, encoding: .utf8) {
                        DispatchQueue.main.async {
                            self?.parseProgress(output)
                        }
                    }
                }

                errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    if data.isEmpty { return }

                    if let output = String(data: data, encoding: .utf8) {
                        DispatchQueue.main.async {
                            self?.outputLog += output
                        }
                    }
                }

                task.waitUntilExit()

                pipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                DispatchQueue.main.async {
                    self.cancelTimeoutTimer()

                    if task.terminationStatus == 0 {
                        self.state = .completed
                        self.outputLog += "\nDownload completed!\n"

                        // Try to find the downloaded file
                        self.lastDownloadedFilePath = self.findLatestDownloadedFile(in: outputPath)

                        // Add to history
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
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        self.state = .error("Download failed: \(errorString)")
                        self.outputLog += "\nError: \(errorString)\n"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.cancelTimeoutTimer()
                    self.state = .error("Error: \(error.localizedDescription)")
                }
            }
        }
    }

    func downloadBest(url: String, outputPath: String) {
        guard let ytdlp = ytdlpPath else {
            state = .error("yt-dlp not found")
            return
        }

        state = .downloading(progress: 0, speed: "Starting...")
        startDownloadStallDetection()
        outputLog = "Starting download (best quality)...\n"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let task = Process()
            task.executableURL = URL(fileURLWithPath: ytdlp)

            // Use truncated title (max 80 chars) + video ID to avoid "filename too long" errors
            let outputTemplate = "\(outputPath)/%(title).80s [%(id)s].%(ext)s"

            // Prefer H.264 (avc1) for QuickTime/macOS compatibility.
            // Falls back to any best video if H.264 is unavailable.
            let h264Format = "bestvideo[vcodec^=avc1]+bestaudio/bestvideo[vcodec^=avc]+bestaudio/bestvideo+bestaudio/best"
            var args = [
                "-f", h264Format,
                "-o", outputTemplate,
                "--newline",
                "--progress",
                "--no-playlist",
                "--restrict-filenames",
                "--merge-output-format", "mp4"
            ]
            args.append(contentsOf: self.youtubeWorkaroundArgs)

            // Add subtitle options if enabled
            if self.settings.downloadSubtitles {
                args.append(contentsOf: ["--write-subs", "--write-auto-subs", "--sub-langs", self.settings.subtitleLanguage])
            }

            args.append(url)
            task.arguments = args

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            task.environment = env

            let pipe = Pipe()
            let errorPipe = Pipe()
            task.standardOutput = pipe
            task.standardError = errorPipe

            self.downloadTask = task

            do {
                try task.run()

                pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    if data.isEmpty { return }

                    if let output = String(data: data, encoding: .utf8) {
                        DispatchQueue.main.async {
                            self?.parseProgress(output)
                        }
                    }
                }

                errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    if data.isEmpty { return }

                    if let output = String(data: data, encoding: .utf8) {
                        DispatchQueue.main.async {
                            self?.outputLog += output
                        }
                    }
                }

                task.waitUntilExit()

                pipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                DispatchQueue.main.async {
                    self.cancelTimeoutTimer()

                    if task.terminationStatus == 0 {
                        self.state = .completed
                        self.outputLog += "\nDownload completed!\n"

                        // Try to find the downloaded file
                        self.lastDownloadedFilePath = self.findLatestDownloadedFile(in: outputPath)

                        // Add to history
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
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        self.state = .error("Download failed: \(errorString)")
                        self.outputLog += "\nError: \(errorString)\n"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.cancelTimeoutTimer()
                    self.state = .error("Error: \(error.localizedDescription)")
                }
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
        state = .idle
        isProcessingQueue = false
        outputLog += "\nDownload cancelled.\n"
    }

    func reset() {
        state = .idle
        videoInfo = nil
        scannedVideos = []
        outputLog = ""
        lastDownloadedFilePath = nil
    }

    // MARK: - Audio-Only Download (MP3)

    func downloadAudio(url: String, outputPath: String) {
        guard let ytdlp = ytdlpPath else {
            state = .error("yt-dlp not found")
            return
        }

        state = .downloading(progress: 0, speed: "Starting audio extraction...")
        startDownloadStallDetection()
        outputLog = "Starting audio download (MP3)...\n"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let task = Process()
            task.executableURL = URL(fileURLWithPath: ytdlp)

            // Use truncated title + video ID for filename
            let outputTemplate = "\(outputPath)/%(title).80s [%(id)s].%(ext)s"

            var args = [
                "-f", "bestaudio",
                "-x",  // Extract audio
                "--audio-format", "mp3",
                "--audio-quality", "0",  // Best quality
                "-o", outputTemplate,
                "--newline",
                "--progress",
                "--no-playlist",
                "--restrict-filenames"
            ]
            args.append(contentsOf: self.youtubeWorkaroundArgs)
            args.append(url)

            task.arguments = args

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            task.environment = env

            let pipe = Pipe()
            let errorPipe = Pipe()
            task.standardOutput = pipe
            task.standardError = errorPipe

            self.downloadTask = task

            do {
                try task.run()

                pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    if data.isEmpty { return }

                    if let output = String(data: data, encoding: .utf8) {
                        DispatchQueue.main.async {
                            self?.parseProgress(output)
                        }
                    }
                }

                errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    if data.isEmpty { return }

                    if let output = String(data: data, encoding: .utf8) {
                        DispatchQueue.main.async {
                            self?.outputLog += output
                        }
                    }
                }

                task.waitUntilExit()

                pipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                DispatchQueue.main.async {
                    self.cancelTimeoutTimer()

                    if task.terminationStatus == 0 {
                        self.state = .completed
                        self.outputLog += "\nAudio download completed!\n"

                        // Try to find the downloaded file
                        self.lastDownloadedFilePath = self.findLatestDownloadedFile(in: outputPath)

                        self.sendNotification(title: "Download Complete", body: "Audio file saved to Downloads")
                        self.playCompletionSound()
                    } else {
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        self.state = .error("Audio download failed: \(errorString)")
                        self.outputLog += "\nError: \(errorString)\n"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.cancelTimeoutTimer()
                    self.state = .error("Error: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Download Audio for Transcription (to temp folder)

    func downloadAudioForTranscription(url: String, completion: @escaping (String?, String?) -> Void) {
        guard let ytdlp = ytdlpPath else {
            completion(nil, "yt-dlp not found")
            return
        }

        state = .downloading(progress: 0, speed: "Downloading audio for transcription...")
        startDownloadStallDetection()
        outputLog = "Downloading audio for transcription...\n"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let task = Process()
            task.executableURL = URL(fileURLWithPath: ytdlp)

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
                "--newline",
                "--progress",
                "--no-playlist"
            ]
            args.append(contentsOf: self.youtubeWorkaroundArgs)
            args.append(url)

            task.arguments = args

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            task.environment = env

            let pipe = Pipe()
            let errorPipe = Pipe()
            task.standardOutput = pipe
            task.standardError = errorPipe

            self.downloadTask = task

            do {
                try task.run()

                pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    if data.isEmpty { return }

                    if let output = String(data: data, encoding: .utf8) {
                        DispatchQueue.main.async {
                            self?.parseProgress(output)
                        }
                    }
                }

                errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    if data.isEmpty { return }

                    if let output = String(data: data, encoding: .utf8) {
                        DispatchQueue.main.async {
                            self?.outputLog += output
                        }
                    }
                }

                task.waitUntilExit()

                pipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                DispatchQueue.main.async {
                    self.cancelTimeoutTimer()

                    if task.terminationStatus == 0 {
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
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        self.state = .error("Audio download failed: \(errorString)")
                        self.outputLog += "\nError: \(errorString)\n"
                        completion(nil, errorString)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.cancelTimeoutTimer()
                    self.state = .error("Error: \(error.localizedDescription)")
                    completion(nil, error.localizedDescription)
                }
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
            let itemIndex = nextIndex
            outputLog += "\n--- Starting [\(nextIndex + 1)/\(downloadQueue.count)]: \(item.title) ---\n"

            downloadQueueItem(item: item, outputPath: outputPath) { [weak self] success, error in
                guard let self = self else { return }

                DispatchQueue.main.async {
                    self.activeDownloads -= 1

                    if success {
                        self.downloadQueue[itemIndex].status = .completed
                        self.downloadQueue[itemIndex].progress = 1.0

                        // Add to history
                        let historyItem = HistoryItem(
                            url: item.url,
                            title: item.title,
                            thumbnail: item.thumbnail,
                            platform: Platform.detect(from: item.url),
                            isAudioOnly: item.isAudioOnly
                        )
                        self.historyManager.addToHistory(historyItem)
                    } else {
                        self.downloadQueue[itemIndex].status = .failed(error ?? "Unknown error")
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

    private func processNextInQueue(outputPath: String) {
        // Find next pending item
        guard let nextIndex = downloadQueue.firstIndex(where: { $0.status == .pending }) else {
            // Queue complete
            isProcessingQueue = false
            state = .completed
            if settings.showNotifications {
                sendNotification(title: "Queue Complete", body: "All \(downloadQueue.count) downloads finished")
            }
            if settings.playSoundOnComplete {
                playCompletionSound()
            }
            outputLog += "\n✅ Download queue completed!\n"
            return
        }

        currentQueueIndex = nextIndex
        downloadQueue[nextIndex].status = .downloading

        let item = downloadQueue[nextIndex]
        outputLog += "\n--- Downloading [\(nextIndex + 1)/\(downloadQueue.count)]: \(item.title) ---\n"

        downloadQueueItem(item: item, outputPath: outputPath) { [weak self] success, error in
            guard let self = self else { return }

            DispatchQueue.main.async {
                if success {
                    self.downloadQueue[nextIndex].status = .completed
                    self.downloadQueue[nextIndex].progress = 1.0
                } else {
                    self.downloadQueue[nextIndex].status = .failed(error ?? "Unknown error")
                }

                // Process next item
                self.processNextInQueue(outputPath: outputPath)
            }
        }
    }

    private func downloadQueueItem(item: QueueItem, outputPath: String, completion: @escaping (Bool, String?) -> Void) {
        guard let ytdlp = ytdlpPath else {
            completion(false, "yt-dlp not found")
            return
        }

        state = .downloading(progress: 0, speed: "Starting...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let task = Process()
            task.executableURL = URL(fileURLWithPath: ytdlp)

            let outputTemplate = "\(outputPath)/%(title).80s [%(id)s].%(ext)s"

            var args: [String]
            if item.isAudioOnly {
                args = [
                    "-f", "bestaudio",
                    "-x",
                    "--audio-format", "mp3",
                    "--audio-quality", "0",
                    "-o", outputTemplate,
                    "--newline",
                    "--progress",
                    "--no-playlist",
                    "--restrict-filenames"
                ]
            } else {
                // Prefer H.264 for QuickTime/macOS compatibility
                let h264Format = "bestvideo[vcodec^=avc1]+bestaudio/bestvideo[vcodec^=avc]+bestaudio/bestvideo+bestaudio/best"
                args = [
                    "-f", h264Format,
                    "-o", outputTemplate,
                    "--newline",
                    "--progress",
                    "--no-playlist",
                    "--restrict-filenames",
                    "--merge-output-format", "mp4"
                ]
            }
            args.append(contentsOf: self.youtubeWorkaroundArgs)
            args.append(item.url)

            task.arguments = args

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            task.environment = env

            let pipe = Pipe()
            let errorPipe = Pipe()
            task.standardOutput = pipe
            task.standardError = errorPipe

            self.downloadTask = task

            do {
                try task.run()

                pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    if data.isEmpty { return }

                    if let output = String(data: data, encoding: .utf8) {
                        DispatchQueue.main.async {
                            self?.parseQueueProgress(output, itemIndex: self?.currentQueueIndex ?? 0)
                        }
                    }
                }

                errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    if data.isEmpty { return }

                    if let output = String(data: data, encoding: .utf8) {
                        DispatchQueue.main.async {
                            self?.outputLog += output
                        }
                    }
                }

                task.waitUntilExit()

                pipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                if task.terminationStatus == 0 {
                    completion(true, nil)
                } else {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    completion(false, errorString)
                }
            } catch {
                completion(false, error.localizedDescription)
            }
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
