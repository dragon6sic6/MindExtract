import SwiftUI
import Combine

// MARK: - What the notch is doing
//
// One item at a time: a pasted link or a dropped file. From there you save it
// or transcribe it, and a finished transcript lands on the clipboard for Claude,
// ChatGPT or any other model. The engines (yt-dlp, Pianissimo, Whisper, Apple
// Speech) do the work; this keeps track of where we are.

@MainActor
final class NotchModel: ObservableObject {
    static let shared = NotchModel()

    struct Item: Equatable {
        var title: String
        var channel: String = ""
        var duration: String = ""
        var detail: String = ""          // file type and size, for files
        var thumbnail: URL?
        var url: String?                 // a link
        var filePath: String?            // a file on disk

        var subtitle: String {
            [channel, duration, detail].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    enum Work: Equatable { case download, transcribe }

    enum Problem: Equatable {
        case general
        case needsSpeechModel(WhisperModel)
        case needsSignIn
    }

    enum Stage: Equatable {
        case idle
        case loadingInfo(url: String, then: Work?)
        case ready(Item)
        case working(Item, Work, phase: String, progress: Double?)
        case transcribed(Item, path: String)
        case downloaded(Item, path: String)
        case failed(Item?, work: Work?, message: String, problem: Problem, url: String?)

        /// Which screen this is, ignoring progress — drives the height animation.
        var screen: Int {
            switch self {
            case .idle: return 0
            case .loadingInfo: return 1
            case .ready: return 2
            case .working: return 3
            case .transcribed: return 4
            case .downloaded: return 5
            case .failed: return 6
            }
        }
    }

    enum DragKind { case file, link }

    // Presentation (driven by NotchController)
    @Published var isOpen = false
    /// A file or link is being dragged near the notch.
    @Published var dragKind: DragKind?
    /// A job finished (or failed) while the notch was closed.
    @Published var hasUnseenResult = false
    /// The unseen result has been shown for a while; the wings shrink to a dot.
    @Published var unseenIsQuiet = false
    /// Bumped when something finishes, for a one-time "pop".
    @Published private(set) var popCount = 0
    /// Bumped to move keyboard focus to the link field.
    @Published private(set) var focusCount = 0
    @Published var isEditing = false
    /// The first-run introduction's page, while it's showing.
    @Published var onboardingStep: Int?
    @Published var openSize: CGSize = .zero
    @Published var geometry = NotchGeometry.current()
    /// A menu from the notch is showing.
    var isMenuOpen = false

    // Content
    @Published var input = ""
    @Published private(set) var stage: Stage = .idle
    @Published var language: String = AppSettings.shared.defaultTranscriptionLanguage
    @Published var audioOnly = false
    @Published private(set) var clipboardLink: String?
    /// The transcript path that's on the clipboard right now (for "Copied").
    @Published private(set) var copiedPath: String?
    @Published private(set) var autoCopiedPath: String?

    private let downloader = YTDLPWrapper.shared
    private let tm = TranscriptionManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var lastPasteboardCount = -1
    /// Clipboard state when the job started; auto-copy only if it's unchanged.
    private var jobPasteboardCount = -1
    /// A speech model we're downloading so a transcription can continue.
    private var awaitedModel: WhisperModel?
    private var quietWork: DispatchWorkItem?

    private init() {
        downloader.$state.combineLatest(downloader.$videoInfo)
            .receive(on: RunLoop.main)
            .sink { [weak self] state, info in self?.downloaderChanged(state, info) }
            .store(in: &cancellables)
        tm.$transcriptionState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.transcriptionChanged(state) }
            .store(in: &cancellables)
        tm.$downloadedModels.combineLatest(tm.$downloadingModel, tm.$modelDownloadProgress)
            .receive(on: RunLoop.main)
            .sink { [weak self] models, downloading, progress in self?.modelsChanged(models, downloading, progress) }
            .store(in: &cancellables)
    }

    var isBusy: Bool {
        switch stage {
        case .loadingInfo, .working: return true
        default: return false
        }
    }

    var activityProgress: Double? {
        if case .working(_, _, _, let p) = stage { return p }
        return nil
    }

    // MARK: Input

    func refreshClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastPasteboardCount else { return }
        lastPasteboardCount = pb.changeCount
        let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        clipboardLink = Self.isLink(text) && !isRecent(link: text) ? text : nil
        if case .idle = stage { language = AppSettings.shared.defaultTranscriptionLanguage }
    }

    func requestFocus() { focusCount += 1 }

    /// The one-click path: fetch the copied link and start transcribing.
    func transcribeCopiedLink() {
        guard let link = clipboardLink else { return }
        clipboardLink = nil
        load(link, then: .transcribe)
    }

    /// Fetch the copied link and save the video.
    func saveCopiedLink() {
        guard let link = clipboardLink else { return }
        clipboardLink = nil
        load(link, then: .download)
    }

    func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        let path = (text as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: path) {
            useFile(URL(fileURLWithPath: path))
            return
        }
        guard Self.isLink(text) else {
            fail(nil, work: nil, String(localized: "That isn't a link. Paste a web address or drag a file here."))
            return
        }
        load(text, then: nil)
    }

    private func load(_ link: String, then next: Work?) {
        guard !isBusy else { return }
        let url = link.hasPrefix("http") ? link : "https://" + link
        input = url
        if clipboardLink == url { clipboardLink = nil }
        stage = .loadingInfo(url: url, then: next)
        downloader.loadURL(url)
    }

    func useFile(_ url: URL) {
        guard !isBusy else { return }
        input = ""
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        } ?? ""
        stage = .ready(Item(title: url.deletingPathExtension().lastPathComponent,
                            detail: [url.pathExtension.uppercased(), size].filter { !$0.isEmpty }.joined(separator: " · "),
                            filePath: url.path))
    }

    func clear() {
        if isBusy { cancel() }
        input = ""
        awaitedModel = nil
        language = AppSettings.shared.defaultTranscriptionLanguage
        stage = .idle
    }

    // MARK: Actions

    func download() {
        guard case .ready(let item) = stage, let url = item.url else { return }
        jobPasteboardCount = NSPasteboard.general.changeCount
        stage = .working(item, .download, phase: String(localized: "Saving…"), progress: nil)
        if audioOnly {
            downloader.downloadAudio(url: url, outputPath: AppSettings.shared.downloadPath)
        } else {
            downloader.downloadBest(url: url, outputPath: AppSettings.shared.downloadPath)
        }
    }

    func transcribe() {
        let item: Item
        switch stage {
        case .ready(let i): item = i
        case .downloaded(let i, let path): item = Item(title: i.title, channel: i.channel, duration: i.duration,
                                                       thumbnail: i.thumbnail, url: i.url, filePath: path)
        case .failed(let i?, _, _, _, _): item = i
        default: return
        }
        // Swedish deserves Pianissimo; offer it rather than falling back quietly.
        if language == "sv", !tm.isModelDownloaded(.pianissimo) {
            if tm.downloadingModel == .pianissimo {
                awaitedModel = .pianissimo
                stage = .working(item, .transcribe, phase: String(localized: "Downloading the Swedish speech model…"),
                                 progress: tm.modelDownloadProgress)
            } else {
                fail(item, work: .transcribe,
                     String(localized: "Swedish needs the Pianissimo speech model (690 MB). It downloads once, then works offline."),
                     problem: .needsSpeechModel(.pianissimo))
            }
            return
        }
        start(item)
    }

    private func start(_ item: Item) {
        let model = AppSettings.shared.defaultWhisperModel
        let language = language
        jobPasteboardCount = NSPasteboard.general.changeCount
        stage = .working(item, .transcribe, phase: String(localized: "Getting ready…"), progress: nil)

        if let path = item.filePath {
            tm.startNewTranscription(title: item.title, model: model, source: .file)
            tm.transcribe(videoPath: path, model: model, outputFormat: .txt, language: language)
        } else if let url = item.url {
            tm.startNewTranscription(title: item.title, model: model, source: .download)
            tm.transcriptionState = .downloadingAudio(progress: 0)
            downloader.downloadAudioForTranscription(url: url) { [weak self] audioPath, error in
                guard let self else { return }
                guard let audioPath, error == nil else {
                    self.tm.transcriptionState = .error(error ?? String(localized: "Couldn't get the audio."))
                    return
                }
                let base = TranscriptionManager.safeFileBase(item.title, fallback: "Transcript")
                let out = TranscriptionManager.uniqueFilePath(dir: AppSettings.shared.downloadPath, base: base, ext: "txt")
                self.tm.transcribeAudioFile(audioPath: audioPath, model: model, outputPath: out,
                                            outputFormat: .txt, language: language)
            }
        }
    }

    /// Downloads the speech model the failed job needs, then carries on by itself.
    func downloadModelAndContinue() {
        guard case .failed(let item?, _, _, .needsSpeechModel(let model), _) = stage else { return }
        awaitedModel = model
        if tm.downloadingModel != model { tm.downloadModel(model) }
        stage = .working(item, .transcribe, phase: String(localized: "Downloading the speech model…"), progress: nil)
    }

    func retry() {
        guard case .failed(let item, let work, _, _, let url) = stage else { return }
        if let item {
            stage = .ready(item)
            work == .download ? download() : transcribe()
        } else if let url {
            load(url, then: nil)
        }
    }

    func cancel() {
        switch stage {
        case .working(let item, let work, _, _):
            if awaitedModel != nil {
                awaitedModel = nil
                tm.cancelModelDownload()
            } else {
                downloader.cancelDownload()
                if work == .transcribe { tm.cancelTranscription() }
            }
            stage = .ready(item)
        case .loadingInfo:
            downloader.cancelDownload()
            stage = .idle
        default:
            break
        }
    }

    func signInToYouTube() {
        UserDefaults.standard.set("downloads", forKey: "settingsCategory")
        SettingsWindow.show()
    }

    // MARK: Copy

    func copyTranscript(path: String, item: Item, timestamps: Bool = AppSettings.shared.copyWithTimestamps) {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let body = timestamps ? TranscriptCopy.withoutHeader(raw) : TranscriptCopy.plain(raw)
        var lines = ["# \(item.title)"]
        if let url = item.url { lines.append(String(localized: "Source: \(url)")) }
        var facts: [String] = []
        if !item.channel.isEmpty { facts.append(String(localized: "Channel: \(item.channel)")) }
        if !item.duration.isEmpty { facts.append(String(localized: "Length: \(item.duration)")) }
        if !facts.isEmpty { lines.append(facts.joined(separator: " · ")) }
        lines.append(String(localized: "(Automatic transcript. May contain errors.)"))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n") + "\n\n" + body, forType: .string)
        lastPasteboardCount = NSPasteboard.general.changeCount   // don't offer our own copy back
        clipboardLink = nil
        copiedPath = path
        AccessibilityNotification.Announcement(String(localized: "Transcript copied")).post()
    }

    /// The transcript on the clipboard is still ours.
    func isOnClipboard(_ path: String) -> Bool {
        copiedPath == path && NSPasteboard.general.changeCount == lastPasteboardCount
    }

    func openRecent(_ entry: RecentEntry) {
        guard let path = entry.path, !isBusy else { return }
        let item = entry.item
        switch entry.kind {
        case .transcript: stage = .transcribed(item, path: path)
        case .download: stage = .downloaded(item, path: path)
        }
    }

    // MARK: Engine updates

    private func downloaderChanged(_ state: DownloadState, _ info: VideoInfo?) {
        switch stage {
        case .loadingInfo(let url, let next):
            if let info {
                let item = Item(title: info.title,
                                channel: info.uploader == "Unknown" ? "" : info.uploader,
                                duration: info.duration == "Unknown" ? "" : info.duration,
                                thumbnail: info.thumbnail.flatMap(URL.init(string:)),
                                url: info.url.isEmpty ? url : info.url)
                stage = .ready(item)
                switch next {
                case .transcribe: transcribe()
                case .download: download()
                case nil: break
                }
            } else if case .error(let message) = state {
                fail(nil, work: nil, message, problem: downloader.lastErrorNeedsAuth ? .needsSignIn : .general, url: url)
            } else if case .timeout(let message) = state {
                fail(nil, work: nil, message, url: url)
            } else if !downloader.scannedVideos.isEmpty {
                fail(nil, work: nil, String(localized: "That's a playlist or a page with several videos. Paste the link to one video."))
            }
        case .working(let item, .download, _, _):
            switch state {
            case .downloading(let p, _):
                stage = .working(item, .download, phase: String(localized: "Saving…"), progress: p > 0 ? p : nil)
            case .completed:
                if let path = downloader.lastDownloadedFilePath {
                    finish(.downloaded(item, path: path))
                } else {
                    fail(item, work: .download, String(localized: "The download finished but the file wasn't found."))
                }
            case .error(let message):
                fail(item, work: .download, message, problem: downloader.lastErrorNeedsAuth ? .needsSignIn : .general)
            case .timeout(let message):
                fail(item, work: .download, message)
            default: break
            }
        case .working(let item, .transcribe, _, _):
            if case .downloading(let p, _) = state, case .downloadingAudio = tm.transcriptionState {
                stage = .working(item, .transcribe, phase: String(localized: "Getting the audio…"), progress: p > 0 ? p : nil)
            }
        default: break
        }
    }

    private func transcriptionChanged(_ state: TranscriptionState) {
        guard case .working(let item, .transcribe, _, _) = stage, awaitedModel == nil else { return }
        switch state {
        case .downloadingAudio:
            break   // progress comes from the downloader
        case .extractingAudio:
            stage = .working(item, .transcribe, phase: String(localized: "Reading the audio…"), progress: nil)
        case .loadingModel:
            stage = .working(item, .transcribe, phase: String(localized: "Starting speech recognition…"), progress: nil)
        case .transcribing(let p):
            stage = .working(item, .transcribe, phase: String(localized: "Transcribing…"), progress: p > 0 ? p : nil)
        case .completed(let path):
            TranscriptionHistoryManager.shared.setSource(url: item.url, thumbnail: item.thumbnail?.absoluteString,
                                                         channel: item.channel.isEmpty ? nil : item.channel, forPath: path)
            finish(.transcribed(item, path: path))
            if AppSettings.shared.autoCopyWhenDone, NSPasteboard.general.changeCount == jobPasteboardCount {
                copyTranscript(path: path, item: item)
                autoCopiedPath = path
            }
        case .error(let message):
            fail(item, work: .transcribe, message, problem: downloader.lastErrorNeedsAuth ? .needsSignIn : .general)
        case .modelNotDownloaded:
            let model = language == "sv" ? WhisperModel.pianissimo : tm.multilingualBaseModel()
            fail(item, work: .transcribe,
                 String(localized: "This language needs a speech model (\(model.sizeDescription)). It downloads once, then works offline."),
                 problem: .needsSpeechModel(model))
        case .idle:
            break
        }
    }

    private func modelsChanged(_ models: Set<WhisperModel>, _ downloading: WhisperModel?, _ progress: Double) {
        guard let awaited = awaitedModel, case .working(let item, .transcribe, _, _) = stage else { return }
        if models.contains(awaited) {
            awaitedModel = nil
            start(item)
        } else if downloading == awaited {
            stage = .working(item, .transcribe, phase: String(localized: "Downloading the speech model…"),
                             progress: progress > 0 ? progress : nil)
        } else if downloading == nil {
            awaitedModel = nil
            let message = tm.modelDownloadError?.message ?? String(localized: "The speech model didn't download.")
            fail(item, work: .transcribe, message, problem: .needsSpeechModel(awaited))
        }
    }

    private func fail(_ item: Item?, work: Work?, _ message: String, problem: Problem = .general, url: String? = nil) {
        finish(.failed(item, work: work, message: message, problem: problem, url: url))
    }

    private func finish(_ result: Stage) {
        stage = result
        input = ""
        guard !isOpen else { return }
        hasUnseenResult = true
        unseenIsQuiet = false
        popCount += 1
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        // After a while the wings shrink to a dot, so menu bar items show again.
        quietWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.unseenIsQuiet = true }
        quietWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    func markSeen() {
        hasUnseenResult = false
        unseenIsQuiet = false
        quietWork?.cancel()
    }

    // MARK: Helpers

    private func isRecent(link: String) -> Bool {
        if case .transcribed(let item, _) = stage, item.url == link { return true }
        return RecentEntry.latest(4).contains { $0.url == link }
    }

    static func isLink(_ text: String) -> Bool {
        guard !text.isEmpty, !text.contains(" "), !text.contains("\n") else { return false }
        if let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil { return true }
        // "youtube.com/watch?v=…" without a scheme
        return text.range(of: #"^[\w-]+(\.[\w-]+)+(/\S*)?$"#, options: .regularExpression) != nil
    }

    static func wordCount(ofTranscriptAt path: String) -> Int {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        return TranscriptCopy.plain(raw).split(whereSeparator: { $0.isWhitespace }).count
    }
}

// MARK: - Recent items

struct RecentEntry: Identifiable {
    enum Kind { case transcript, download }
    let id: UUID
    let kind: Kind
    let title: String
    let date: Date
    let path: String?
    let url: String?
    var thumbnail: String? = nil
    var channel: String? = nil
    var duration: String? = nil
    /// The same video was also saved (for a transcript) — shown as a second icon.
    var alsoDownloaded = false

    var item: NotchModel.Item {
        NotchModel.Item(title: title, channel: channel ?? "", duration: duration ?? "",
                        thumbnail: (thumbnail ?? Self.youTubeThumbnail(url)).flatMap(URL.init(string:)),
                        url: url, filePath: path)
    }

    /// YouTube's own still for a video link, for transcripts saved without one.
    static func youTubeThumbnail(_ link: String?) -> String? {
        guard let link, let comps = URLComponents(string: link), let host = comps.host else { return nil }
        let id: String?
        if host.hasSuffix("youtu.be") {
            id = comps.path.split(separator: "/").first.map(String.init)
        } else if host.contains("youtube.com") {
            id = comps.queryItems?.first { $0.name == "v" }?.value
                ?? (comps.path.hasPrefix("/shorts/") ? comps.path.split(separator: "/").last.map(String.init) : nil)
        } else {
            id = nil
        }
        return id.map { "https://i.ytimg.com/vi/\($0)/hqdefault.jpg" }
    }

    /// The latest distinct videos: a video that was both saved and transcribed
    /// shows once, as its transcript.
    @MainActor
    static func latest(_ count: Int) -> [RecentEntry] {
        let transcripts = TranscriptionHistoryManager.shared.history.compactMap { item -> RecentEntry? in
            guard item.fileExists else { return nil }
            return RecentEntry(id: item.id, kind: .transcript, title: item.title, date: item.transcriptionDate,
                               path: item.filePath, url: item.sourceURL, thumbnail: item.thumbnailURL,
                               channel: item.channel, duration: item.duration)
        }
        let downloads = HistoryManager.shared.history.compactMap { item -> RecentEntry? in
            guard let path = item.filePath, FileManager.default.fileExists(atPath: path) else { return nil }
            return RecentEntry(id: item.id, kind: .download, title: item.title, date: item.downloadDate,
                               path: path, url: item.url, thumbnail: item.thumbnail)
        }
        func key(_ e: RecentEntry) -> String {
            e.title.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let downloadedKeys = Set(downloads.map(key))
        var seen = Set<String>()
        var out: [RecentEntry] = []
        for var e in (transcripts + downloads).sorted(by: { a, b in
            a.date != b.date ? a.date > b.date : a.kind == .transcript
        }) {
            let k = key(e)
            if seen.contains(k) {
                // A later transcript of a video already listed as a download replaces it.
                if e.kind == .transcript, let i = out.firstIndex(where: { key($0) == k && $0.kind == .download }) {
                    e.alsoDownloaded = true
                    if e.thumbnail == nil { e.thumbnail = out[i].thumbnail }
                    out[i] = e
                }
                continue
            }
            seen.insert(k)
            if e.kind == .transcript, downloadedKeys.contains(k) {
                e.alsoDownloaded = true
                if e.thumbnail == nil { e.thumbnail = downloads.first { key($0) == k }?.thumbnail }
            }
            out.append(e)
            if out.count == count { break }
        }
        return out
    }
}

// MARK: - Copy formats

enum TranscriptCopy {
    /// The file without the "# title" / date lines some engines write first.
    static func withoutHeader(_ raw: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("# ") {
            lines.removeFirst()
            while let next = lines.first, next.trimmingCharacters(in: .whitespaces).isEmpty
                || next.range(of: #"^\[?\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil {
                lines.removeFirst()
            }
        }
        return lines.joined(separator: "\n")
    }

    /// "[00:12] Speaker 1: text" lines → paragraphs. Speaker names are kept only
    /// when there is more than one (and "Speaker N" reads in the app's
    /// language); timestamps are dropped.
    static func plain(_ raw: String) -> String {
        let pattern = #"^\[(?:\d+:)?\d{1,2}:\d{2}\]\s*"#
        var rows: [(speaker: String?, text: String)] = []
        for block in withoutHeader(raw).components(separatedBy: "\n") {
            var line = block.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let r = line.range(of: pattern, options: .regularExpression) { line.removeSubrange(r) }
            var speaker: String?
            if let colon = line.firstIndex(of: ":"), line.distance(from: line.startIndex, to: colon) <= 30 {
                let name = String(line[..<colon])
                if name.range(of: #"^[\p{L}][\p{L}\p{N} .'-]*$"#, options: .regularExpression) != nil, name.split(separator: " ").count <= 3 {
                    speaker = name
                    line = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            if !line.isEmpty { rows.append((speaker, line)) }
        }
        let speakers = Set(rows.compactMap(\.speaker))
        guard speakers.count > 1 else {
            // One voice: flowing paragraphs, a new one every ~6 lines.
            var paragraphs: [String] = []
            var current: [String] = []
            for row in rows {
                current.append(row.text)
                if current.count >= 6 { paragraphs.append(current.joined(separator: " ")); current = [] }
            }
            if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
            return paragraphs.joined(separator: "\n\n")
        }
        // Several voices: one paragraph per turn.
        var turns: [(String, [String])] = []
        for row in rows {
            let who = row.speaker ?? turns.last?.0 ?? ""
            if turns.last?.0 == who { turns[turns.count - 1].1.append(row.text) } else { turns.append((who, [row.text])) }
        }
        return turns.map { "\(localizedSpeaker($0.0)): \($0.1.joined(separator: " "))" }.joined(separator: "\n\n")
    }

    /// "Speaker 2" → "Talare 2" in Swedish; real names stay.
    static func localizedSpeaker(_ name: String) -> String {
        guard name.hasPrefix("Speaker "), let n = Int(name.dropFirst(8)) else { return name }
        return String(localized: "Speaker \(n)")
    }
}
