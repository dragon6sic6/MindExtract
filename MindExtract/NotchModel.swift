import SwiftUI
import Combine

// MARK: - What the notch is doing
//
// One item at a time: a pasted link or a dropped file. From there you download
// it or transcribe it, and a finished transcript is copied with one click for
// Claude, ChatGPT or any other model. The engines (yt-dlp, Pianissimo, Whisper,
// Apple Speech) do the work; this keeps track of where we are.

@MainActor
final class NotchModel: ObservableObject {
    static let shared = NotchModel()

    struct Item: Equatable {
        var title: String
        var subtitle: String
        var thumbnail: URL?
        var url: String?        // a link
        var filePath: String?   // a file on disk
    }

    enum Work: Equatable { case download, transcribe }

    enum Stage: Equatable {
        case idle
        case loadingInfo(url: String)
        case ready(Item)
        case working(Item, Work, phase: String, progress: Double?)
        case transcribed(Item, path: String)
        case downloaded(Item, path: String)
        case failed(Item?, message: String, needsSpeechModel: Bool)
    }

    // Presentation (driven by NotchController)
    @Published var isOpen = false
    @Published var isDropTargeted = false
    /// A job finished while the notch was closed — shown until it's opened.
    @Published var hasUnseenResult = false
    /// The text field has focus; the notch stays open while typing.
    @Published var isEditing = false
    /// Size of the open panel's content, so the controller knows where the mouse may go.
    @Published var openSize: CGSize = .zero
    /// A menu from the notch is showing.
    var isMenuOpen = false
    @Published var geometry = NotchGeometry.current()

    // Content
    @Published var input = ""
    @Published private(set) var stage: Stage = .idle
    @Published var language: String = AppSettings.shared.defaultTranscriptionLanguage
    @Published var audioOnly = false
    /// A link on the clipboard that hasn't been pasted yet.
    @Published private(set) var clipboardLink: String?
    @Published private(set) var justCopied: String?   // path of the transcript just copied

    private let downloader = YTDLPWrapper.shared
    private let tm = TranscriptionManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var lastPasteboardCount = -1

    private init() {
        downloader.$state.combineLatest(downloader.$videoInfo)
            .receive(on: RunLoop.main)
            .sink { [weak self] state, info in self?.downloaderChanged(state, info) }
            .store(in: &cancellables)
        tm.$transcriptionState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.transcriptionChanged(state) }
            .store(in: &cancellables)
    }

    var isBusy: Bool {
        switch stage {
        case .loadingInfo, .working: return true
        default: return false
        }
    }

    /// Progress for the closed notch's activity ring; nil = indeterminate.
    var activityProgress: Double? {
        if case .working(_, _, _, let p) = stage { return p }
        return nil
    }

    // MARK: Input

    /// Called whenever the notch opens: offers a copied link without pasting it.
    func refreshClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastPasteboardCount else { return }
        lastPasteboardCount = pb.changeCount
        let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        clipboardLink = Self.isLink(text) ? text : nil
    }

    func pasteClipboardLink() {
        guard let link = clipboardLink else { return }
        clipboardLink = nil
        input = link
        submit()
    }

    func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        if FileManager.default.fileExists(atPath: (text as NSString).expandingTildeInPath) {
            useFile(URL(fileURLWithPath: (text as NSString).expandingTildeInPath))
            return
        }
        guard Self.isLink(text) else {
            stage = .failed(nil, message: String(localized: "That doesn't look like a link. Paste a web address or drop a file."), needsSpeechModel: false)
            return
        }
        let url = text.hasPrefix("http") ? text : "https://" + text
        input = url
        stage = .loadingInfo(url: url)
        downloader.loadURL(url)
    }

    func useFile(_ url: URL) {
        guard !isBusy else { return }
        input = ""
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        } ?? ""
        let item = Item(title: url.deletingPathExtension().lastPathComponent,
                        subtitle: [url.pathExtension.uppercased(), size].filter { !$0.isEmpty }.joined(separator: " · "),
                        thumbnail: nil, url: nil, filePath: url.path)
        stage = .ready(item)
    }

    func clear() {
        if isBusy { cancel() }
        input = ""
        stage = .idle
    }

    // MARK: Actions

    func download() {
        guard case .ready(let item) = stage, let url = item.url else { return }
        stage = .working(item, .download, phase: String(localized: "Downloading…"), progress: 0)
        let folder = AppSettings.shared.downloadPath
        if audioOnly {
            downloader.downloadAudio(url: url, outputPath: folder)
        } else {
            downloader.downloadBest(url: url, outputPath: folder)
        }
    }

    func transcribe() {
        let item: Item
        switch stage {
        case .ready(let i): item = i
        case .downloaded(let i, let path): item = Item(title: i.title, subtitle: i.subtitle, thumbnail: i.thumbnail, url: i.url, filePath: path)
        case .failed(let i?, _, _): item = i
        default: return
        }
        let model = AppSettings.shared.defaultWhisperModel
        let settings = AppSettings.shared
        stage = .working(item, .transcribe, phase: String(localized: "Getting ready…"), progress: nil)

        if let path = item.filePath {
            tm.startNewTranscription(title: item.title, model: model, source: .file)
            tm.transcribe(videoPath: path, model: model, outputFormat: settings.transcriptionOutputFormat, language: language)
        } else if let url = item.url {
            tm.startNewTranscription(title: item.title, model: model, source: .download)
            tm.transcriptionState = .downloadingAudio(progress: 0)
            let language = language
            downloader.downloadAudioForTranscription(url: url) { [weak self] audioPath, error in
                guard let self else { return }
                guard let audioPath, error == nil else {
                    self.tm.transcriptionState = .error(String(localized: "Couldn't get the audio: \(error ?? "")"))
                    return
                }
                let base = TranscriptionManager.safeFileBase(item.title, fallback: "Transcript")
                let out = TranscriptionManager.uniqueFilePath(dir: settings.downloadPath, base: base,
                                                              ext: settings.transcriptionOutputFormat.rawValue)
                self.tm.transcribeAudioFile(audioPath: audioPath, model: model, outputPath: out,
                                            outputFormat: settings.transcriptionOutputFormat, language: language)
            }
        }
    }

    func cancel() {
        if case .working(let item, let work, _, _) = stage {
            downloader.cancelDownload()
            if work == .transcribe { tm.cancelTranscription() }
            stage = .ready(item)
        } else if case .loadingInfo = stage {
            downloader.cancelDownload()
            stage = .idle
        }
    }

    func downloadSpeechModel() {
        tm.downloadModel(tm.multilingualBaseModel())
    }

    // MARK: Copy

    func copyTranscript(path: String, title: String, url: String?, timestamps: Bool) {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let body = timestamps ? raw : TranscriptCopy.plain(raw)
        var header = "# \(title)"
        if let url { header += "\n\(url)" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(header + "\n\n" + body, forType: .string)
        lastPasteboardCount = NSPasteboard.general.changeCount   // don't offer our own copy back
        justCopied = path
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            if self?.justCopied == path { self?.justCopied = nil }
        }
    }

    // MARK: Engine updates

    private func downloaderChanged(_ state: DownloadState, _ info: VideoInfo?) {
        switch stage {
        case .loadingInfo(let url):
            if let info {
                stage = .ready(Item(title: info.title,
                                    subtitle: [info.duration, info.uploader].filter { !$0.isEmpty && $0 != "Unknown" }.joined(separator: " · "),
                                    thumbnail: info.thumbnail.flatMap(URL.init(string:)),
                                    url: info.url.isEmpty ? url : info.url, filePath: nil))
            } else if case .error(let message) = state {
                stage = .failed(nil, message: message, needsSpeechModel: false)
            } else if case .timeout(let message) = state {
                stage = .failed(nil, message: message, needsSpeechModel: false)
            } else if !downloader.scannedVideos.isEmpty {
                stage = .failed(nil, message: String(localized: "That's a playlist or a page with several videos. Paste the link to one video."), needsSpeechModel: false)
            }
        case .working(let item, .download, _, _):
            switch state {
            case .downloading(let p, _):
                stage = .working(item, .download, phase: String(localized: "Downloading…"), progress: p)
            case .completed:
                if let path = downloader.lastDownloadedFilePath {
                    finished(.downloaded(item, path: path))
                } else {
                    stage = .failed(item, message: String(localized: "The download finished but the file wasn't found."), needsSpeechModel: false)
                }
            case .error(let message), .timeout(let message):
                stage = .failed(item, message: message, needsSpeechModel: false)
            default: break
            }
        case .working(let item, .transcribe, _, _):
            // The audio of a link downloads first.
            if case .downloading(let p, _) = state, case .downloadingAudio = tm.transcriptionState {
                stage = .working(item, .transcribe, phase: String(localized: "Getting the audio…"), progress: p)
            }
        default: break
        }
    }

    private func transcriptionChanged(_ state: TranscriptionState) {
        guard case .working(let item, .transcribe, _, _) = stage else { return }
        switch state {
        case .downloadingAudio:
            break   // progress comes from the downloader
        case .extractingAudio:
            stage = .working(item, .transcribe, phase: String(localized: "Reading the audio…"), progress: nil)
        case .loadingModel(let name):
            stage = .working(item, .transcribe, phase: name.isEmpty ? String(localized: "Loading the speech model…")
                                                                    : String(localized: "Loading \(name)…"), progress: nil)
        case .transcribing(let p):
            stage = .working(item, .transcribe, phase: String(localized: "Transcribing…"), progress: p > 0 ? p : nil)
        case .completed(let path):
            finished(.transcribed(item, path: path))
        case .error(let message):
            stage = .failed(item, message: message, needsSpeechModel: false)
        case .modelNotDownloaded:
            stage = .failed(item, message: String(localized: "A speech model is needed for this language."), needsSpeechModel: true)
        case .idle:
            break
        }
    }

    private func finished(_ result: Stage) {
        stage = result
        input = ""
        if !isOpen { hasUnseenResult = true }
    }

    // MARK: Helpers

    static func isLink(_ text: String) -> Bool {
        guard !text.isEmpty, !text.contains(" "), !text.contains("\n") else { return false }
        if let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil { return true }
        // "youtube.com/watch?v=…" without a scheme
        return text.range(of: #"^[\w-]+(\.[\w-]+)+(/\S*)?$"#, options: .regularExpression) != nil
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

    @MainActor
    static func latest(_ count: Int) -> [RecentEntry] {
        let transcripts = TranscriptionHistoryManager.shared.history.compactMap { item -> RecentEntry? in
            guard item.fileExists else { return nil }
            return RecentEntry(id: item.id, kind: .transcript, title: item.title, date: item.transcriptionDate,
                               path: item.filePath, url: nil)
        }
        let downloads = HistoryManager.shared.history.compactMap { item -> RecentEntry? in
            guard let path = item.filePath, FileManager.default.fileExists(atPath: path) else { return nil }
            return RecentEntry(id: item.id, kind: .download, title: item.title, date: item.downloadDate,
                               path: path, url: item.url)
        }
        return Array((transcripts + downloads).sorted { $0.date > $1.date }.prefix(count))
    }
}

// MARK: - Copy formats

enum TranscriptCopy {
    /// "[00:12] Speaker 1: text" lines → paragraphs. Speaker names are kept only
    /// when there is more than one; timestamps are dropped.
    static func plain(_ raw: String) -> String {
        let pattern = #"^\[(?:\d+:)?\d{1,2}:\d{2}\]\s*"#
        var rows: [(speaker: String?, text: String)] = []
        for block in raw.components(separatedBy: "\n") {
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
            rows.append((speaker, line))
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
        return turns.map { "\($0.0): \($0.1.joined(separator: " "))" }.joined(separator: "\n\n")
    }
}
