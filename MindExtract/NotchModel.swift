import SwiftUI
import UniformTypeIdentifiers
import Combine
import UserNotifications

// MARK: - What the notch is doing
//
// One item at a time: a pasted link or a dropped file. From there you save it
// or transcribe it, and a finished transcript lands on the clipboard for Claude,
// ChatGPT or any other model. The engines (yt-dlp, NVIDIA Parakeet, Apple
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
        var isLive = false               // a live stream or premiere: nothing to fetch yet

        var subtitle: String {
            [channel, duration, detail].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    enum Work: Equatable { case download, transcribe }

    enum Problem: Equatable {
        case general
        case needsSpeechModel
        case needsSignIn
        /// Trying again won't help (removed, private, unsupported site).
        case permanent
        /// The save folder is missing or can't be written to.
        case needsFolder
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
    /// Where the first-run introduction is, while it runs.
    @Published var onboarding: Onboarding.Beat?
    /// A short line shown under the closed notch (during and right after the introduction).
    @Published var onboardingCaption: String?
    /// What you pasted into the introduction's paste step.
    @Published var onboardingPaste: String?
    /// You just opened the notch yourself in the introduction.
    @Published var onboardingJustSummoned = false
    /// The sample's transcript, line by line, for the captions while it plays.
    @Published var onboardingCaptions: [Onboarding.Caption] = []
    @Published var openSize: CGSize = .zero
    @Published var geometry = NotchGeometry.current()
    /// A menu from the notch is showing.
    var isMenuOpen = false

    // Content
    @Published var input = ""
    @Published private(set) var stage: Stage = .idle {
        didSet { keepAwake(isBusy) }
    }
    @Published var language: String = AppSettings.shared.defaultTranscriptionLanguage
    /// What Save saves: the Settings quality, a size picked for this link, or just the sound.
    /// `original`: the site's own file at that size, not converted (VP9 or AV1:
    /// plays in VLC or IINA, not QuickTime).
    enum SaveChoice: Hashable {
        case standard, video(Int), original(Int), audio
        /// A size picked for one link, which the next link doesn't keep.
        var isSize: Bool {
            switch self {
            case .video, .original: return true
            default: return false
            }
        }
    }
    @Published var saveChoice: SaveChoice = .standard
    var audioOnly: Bool { saveChoice == .audio }
    /// The sizes the current link comes in, once the full lookup is in.
    @Published private(set) var qualities: [VideoQuality] = []
    /// The card showed from the instant preview and the sizes are still on their way.
    @Published private(set) var findingSizes = false
    /// The size Save picks on its own (Settings: up to 1080p or 720p), if known.
    /// Save fetches exactly this one, so the ticked size is what you get.
    /// "Best available" means the best that plays as is when that's 1080p or more
    /// (4K on Vimeo, 1080p on YouTube, whose 4K needs converting), else the best there is.
    var standardHeight: Int? {
        switch AppSettings.shared.downloadQuality {
        case .hd720, .hd1080:
            let cap = AppSettings.shared.downloadQuality == .hd720 ? 720 : 1080
            return qualities.first { $0.height <= cap }?.height ?? qualities.last?.height
        default:
            if let playing = qualities.first(where: { !$0.converts }), playing.height >= 1080 { return playing.height }
            return qualities.first?.height
        }
    }
    /// What Save saves right now, with "standard" spelled out as its size once known.
    var effectiveSaveChoice: SaveChoice {
        if saveChoice == .standard, let usual = standardHeight { return .video(usual) }
        return saveChoice
    }
    @Published private(set) var clipboardLink: String?
    /// The page open in your browser when the notch opened. On a video site it's
    /// a video, already looked up (sizes and all). Any other page is only an offer:
    /// nothing is fetched from it until you click Find Video.
    struct BrowserPage: Equatable {
        let link: String
        let title: String
        let browser: String
        var thumbnail: URL?
        var isVideo: Bool
    }
    @Published private(set) var browserPage: BrowserPage?
    /// A browser we may ask for its page, once you say yes (macOS asks too).
    @Published private(set) var browserToAsk: BrowserTab.Browser?
    /// macOS's question is open, or it was answered no.
    enum BrowserAnswer: Equatable { case waiting(String), denied(String) }
    @Published private(set) var browserAnswer: BrowserAnswer?
    var isAskingBrowser: Bool { if case .waiting = browserAnswer { return true } else { return false } }
    /// The copied link was copied since the notch last opened: it's what you want now.
    private var clipboardIsFresh = false
    /// The clipboard as the notch last opened (or the app started): a link copied
    /// before that isn't fresh, even on the first opening after launch.
    private var clipboardAtLastOpen = NSPasteboard.general.changeCount
    /// The open page on a video site, while its quiet lookup says whether it's one video.
    private var pendingTab: BrowserTab.Tab?
    /// Video-site pages that aren't one video (a home page, a channel), and when we learned it.
    private var notOneVideo: [String: Date] = [:]
    /// Bumped by every look at the browser, so a slow answer about an older page is dropped.
    private var tabCheck = 0
    /// The browser is being asked right now (each opening doesn't start another).
    private var readingTab = false
    /// The page the item on show came from, when it came from the browser. Until
    /// you save or transcribe it, the notch follows you to another tab.
    private var browserItemLink: String?

    /// Idle, or showing what the browser offered and nothing started on it yet.
    private var followsBrowser: Bool {
        switch stage {
        case .idle: return true
        case .loadingInfo(_, nil), .ready, .failed: return browserItemLink != nil
        default: return false
        }
    }
    /// The transcript path that's on the clipboard right now (for "Copied").
    @Published private(set) var copiedPath: String?
    @Published private(set) var autoCopiedPath: String?

    private let downloader = YTDLPWrapper.shared
    private let tm = TranscriptionManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var lastPasteboardCount = -1
    /// Clipboard state when the job started; auto-copy only if it's unchanged.
    private var jobPasteboardCount = -1
    /// A transcription is waiting for the speech model to finish downloading.
    private var awaitingModel = false
    private var quietWork: DispatchWorkItem?
    /// The downloader's lookup that belongs to the link we're waiting on.
    private var awaitedLoad = -1
    /// Bumped by every start and cancel, so audio that arrives after Cancel isn't transcribed.
    private var jobToken = 0
    /// The copied link being looked up ahead, so its card can offer sizes too.
    private var prefetchedLink: String?
    /// Holds off idle sleep while a job runs (a long podcast can take a while).
    private var activity: NSObjectProtocol?

    private init() {
        downloader.$state.combineLatest(downloader.$videoInfo)
            .receive(on: RunLoop.main)
            .sink { [weak self] state, info in self?.downloaderChanged(state, info) }
            .store(in: &cancellables)
        tm.$transcriptionState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.transcriptionChanged(state) }
            .store(in: &cancellables)
        tm.$isModelInstalled.combineLatest(tm.$isDownloadingModel, tm.$modelDownloadProgress)
            .receive(on: RunLoop.main)
            .sink { [weak self] installed, downloading, progress in self?.modelChanged(installed, downloading, progress) }
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

    /// `opening`: the notch is opening now, so a link copied earlier is no longer fresh.
    func refreshClipboard(opening: Bool = false) {
        let pb = NSPasteboard.general
        if pb.changeCount != lastPasteboardCount {
            lastPasteboardCount = pb.changeCount
            let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // A link on its own, or in a short bit of text (a chat message, a share sheet's text).
            let link = text.count <= 500 ? Self.link(in: text).map(Self.cleanLink) : nil
            clipboardLink = link.flatMap { isRecent(link: $0) ? nil : $0 }
            if !opening { clipboardIsFresh = clipboardLink != nil }
            if case .idle = stage { language = AppSettings.shared.defaultTranscriptionLanguage }
        }
        if opening {
            clipboardIsFresh = clipboardLink != nil && pb.changeCount != clipboardAtLastOpen
            clipboardAtLastOpen = pb.changeCount
        }
        prefetchCopiedLink()
    }

    // MARK: The page open in your browser

    /// The one suggestion card the idle notch shows: a link you just copied wins,
    /// then the video on the page you're looking at, then an older copied link.
    /// Typing a link of your own puts the page's card away.
    var showsBrowserVideo: Bool {
        browserPage?.isVideo == true && !(clipboardIsFresh && clipboardLink != nil) && input.isEmpty
    }
    /// Any other page: a one-line offer that fetches it only when clicked.
    var showsPageOffer: Bool { browserPage?.isVideo == false && input.isEmpty }
    /// Held back while the open page is being checked, so the card doesn't swap under the pointer.
    var showsCopiedLink: Bool { clipboardLink != nil && !showsBrowserVideo && pendingTab == nil }

    /// Called as the notch opens, while the browser is still the app in front.
    func refreshBrowserTab() {
        if case .denied = browserAnswer { browserAnswer = nil }
        guard AppSettings.shared.suggestFromBrowser, followsBrowser, onboarding == nil,
              !(clipboardIsFresh && clipboardLink != nil), let browser = BrowserTab.frontmost() else {
            appLog("Browser: skipped (setting \(AppSettings.shared.suggestFromBrowser), idle \(stage == .idle ? 1 : 0), onboarding \(onboarding != nil), fresh copy \(clipboardIsFresh && clipboardLink != nil), front \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"))")
            tabCheck += 1
            forgetTab()
            return
        }
        guard !readingTab else { return }       // the look already under way answers for this opening
        tabCheck += 1
        let check = tabCheck
        Task { @MainActor in
            let permission = await BrowserTab.permission(for: browser, ask: false)
            appLog("Browser: \(browser.bundleID) permission \(permission), asked before \(UserDefaults.standard.bool(forKey: Self.askedKey(browser)))")
            switch permission {
            case .allowed:
                Self.setDenied(browser, false)
                await checkTab(of: browser, check: check)
            case .notAsked:
                guard check == tabCheck else { return }
                forgetTab()
                // Shown at most three times per browser: unanswered after that counts as no.
                let shownKey = "askShown." + browser.bundleID
                let shown = UserDefaults.standard.integer(forKey: shownKey)
                if onboarding == nil, shown < 3, !UserDefaults.standard.bool(forKey: Self.askedKey(browser)) {
                    UserDefaults.standard.set(shown + 1, forKey: shownKey)
                    browserToAsk = browser
                }
            case .denied:
                Self.setDenied(browser, true)
                guard check == tabCheck else { return }
                forgetTab()
            case .unavailable:
                guard check == tabCheck else { return }
                forgetTab()
            }
        }
    }

    /// Continue: macOS asks its own question (the notch stays open meanwhile), then we look.
    func allowBrowser() {
        guard let browser = browserToAsk else { return }
        UserDefaults.standard.set(true, forKey: Self.askedKey(browser))
        browserToAsk = nil
        browserAnswer = .waiting(browser.name)
        tabCheck += 1
        let check = tabCheck
        Task { @MainActor in
            let answer = await BrowserTab.permission(for: browser, ask: true)
            browserAnswer = nil
            switch answer {
            case .allowed:
                Self.setDenied(browser, false)
                await checkTab(of: browser, check: check)
            case .denied:
                Self.setDenied(browser, true)
                browserAnswer = .denied(browser.name)
            default:
                break
            }
        }
    }

    /// No thanks: the suggestions are turned off, as Settings then shows.
    func declineBrowser() {
        browserToAsk = nil
        AppSettings.shared.suggestFromBrowser = false
    }

    func dismissBrowserAnswer() { browserAnswer = nil }

    /// Privacy & Security, Automation, where a browser can be allowed after all.
    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    func openAutomationSettingsFromNotch() {
        browserAnswer = nil
        Self.openAutomationSettings()
    }

    static func askedKey(_ browser: BrowserTab.Browser) -> String { "askedBrowser." + browser.bundleID }

    /// Browsers macOS said no for, as last seen (Settings lists them).
    static var deniedBrowsers: [String] {
        Array(Set(BrowserTab.known.filter { UserDefaults.standard.bool(forKey: "deniedBrowser." + $0.key) }.map(\.value))).sorted()
    }

    private static func setDenied(_ browser: BrowserTab.Browser, _ denied: Bool) {
        UserDefaults.standard.set(denied, forKey: "deniedBrowser." + browser.bundleID)
    }

    /// Settings turned the suggestions back on: every browser may be asked again.
    static func resetBrowserQuestions() {
        for id in BrowserTab.known.keys {
            UserDefaults.standard.removeObject(forKey: "askedBrowser." + id)
            UserDefaults.standard.removeObject(forKey: "askShown." + id)
        }
    }

    private func checkTab(of browser: BrowserTab.Browser, check: Int) async {
        readingTab = true
        let found = await BrowserTab.currentTab(of: browser)
        readingTab = false
        guard check == tabCheck, followsBrowser else { return }
        guard let found else { forgetTab(); return }          // a private window, a new tab, no window
        let link = Self.fullLink(found.url)
        if stage != .idle {
            // Still the page whose video is on show: it stays. Another tab: start over there.
            guard link != browserItemLink else { return }
            clear()
        }
        if browserPage?.link == link || pendingTab?.url == link { return }     // already showing or checking
        let skip = notOneVideo[link].map { Date().timeIntervalSince($0) < 600 } ?? false
        // Sign-in, payment and mail pages, links with a key in them, this Mac: never touched.
        // (A page saved before is still offered: you're looking at it now.)
        guard !skip, PageScanner.isScannable(link) else { forgetTab(); return }
        let tab = BrowserTab.Tab(url: link, title: found.title, browser: browser)
        if Self.isVideoSite(link) {
            browserPage = nil
            // Looked up already (it's the copied link too): no need to ask again.
            if prefetchedLink == link, downloader.loadGeneration == awaitedLoad,
               let info = downloader.videoInfo, info.url == link {
                showTabVideo(tab, info: info)
                return
            }
            // A video site's home or search page isn't one video: the quiet lookup says.
            pendingTab = tab
            prefetchCopiedLink()
        } else {
            // Any other page is only offered; it's fetched when you click.
            pendingTab = nil
            browserPage = BrowserPage(link: link, title: found.title, browser: browser.name, isVideo: false)
            prefetchCopiedLink()
        }
    }

    private func showTabVideo(_ tab: BrowserTab.Tab, info: VideoInfo?) {
        pendingTab = nil
        let title = info.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? tab.title
        browserPage = BrowserPage(link: tab.url, title: title, browser: tab.browser.name,
                                  thumbnail: info?.thumbnail.flatMap(URL.init(string:)), isVideo: true)
        if isOpen {
            AccessibilityNotification.Announcement(String(localized: "Video found on the page in \(tab.browser.name)")).post()
        }
    }

    private func forgetTab() {
        let had = browserPage != nil || pendingTab != nil
        browserPage = nil
        pendingTab = nil
        browserToAsk = nil
        if had { prefetchCopiedLink() }
    }

    func saveBrowserVideo() {
        guard let page = browserPage else { return }
        browserPage = nil
        load(page.link, then: .download)
    }

    func transcribeBrowserVideo() {
        guard let page = browserPage else { return }
        browserPage = nil
        load(page.link, then: .transcribe)
    }

    /// Find Video on any other page: yt-dlp first (it knows thousands of sites),
    /// then the page itself is searched for its player.
    func findPageVideo() {
        guard let page = browserPage else { return }
        browserPage = nil
        load(page.link, then: nil)
        browserItemLink = page.link
    }

    /// Looks up the copied link (or the open page's video) in the background
    /// while its card shows, so Save lists the same sizes as for a pasted link.
    private func prefetchCopiedLink() {
        // Only video sites: any other copied address (a password reset, a sign-in
        // link) is never fetched without being asked.
        guard case .idle = stage else { return }
        let tab = pendingTab?.url ?? (showsBrowserVideo ? browserPage?.link : nil)
        guard let copied = tab ?? clipboardLink.flatMap({ Self.isVideoSite($0) ? $0 : nil }) else {
            // Another kind of link now: the previous one's sizes don't belong to it.
            if prefetchedLink != nil {
                prefetchedLink = nil
                qualities = []
                if saveChoice.isSize { saveChoice = .standard }
                downloader.cancelLoad()
            }
            return
        }
        let link = Self.fullLink(copied)
        guard link != prefetchedLink else { return }
        prefetchedLink = link
        qualities = []
        if saveChoice.isSize { saveChoice = .standard }
        downloader.loadURL(link, quiet: true)
        awaitedLoad = downloader.loadGeneration
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
        // Return in the empty field does what the card's main button does.
        if text.isEmpty, case .idle = stage {
            if showsBrowserVideo { transcribeBrowserVideo() } else if showsCopiedLink { transcribeCopiedLink() }
            return
        }
        guard !text.isEmpty, !isBusy else { return }
        let path = (text as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: path) {
            useFile(URL(fileURLWithPath: path))
            return
        }
        guard let link = Self.link(in: text) else {
            fail(nil, work: nil, String(localized: "That isn't a link. Paste a web address or drag a file here."))
            return
        }
        load(link, then: nil)
    }

    private func load(_ link: String, then next: Work?) {
        guard !isBusy else { return }
        let url = Self.fullLink(link)
        input = url
        // The copied link's lookup, if it's this one and still good: carry on from it.
        let ahead = url == prefetchedLink && downloader.loadGeneration == awaitedLoad
            && (downloader.videoInfo?.url == url || downloader.state == .fetchingFormats)
        prefetchedLink = nil
        if !ahead {
            qualities = []
            if saveChoice.isSize { saveChoice = .standard }   // a size belongs to one link
        }
        if let copied = clipboardLink, Self.fullLink(copied) == url { clipboardLink = nil }
        // Another link now: the open page's card doesn't come back after this job.
        tabCheck += 1
        browserItemLink = nil
        browserPage = nil
        pendingTab = nil
        stage = .loadingInfo(url: url, then: next)
        if ahead {
            if downloader.videoInfo != nil { downloaderChanged(downloader.state, downloader.videoInfo) }
            return
        }
        downloader.loadURL(url)
        awaitedLoad = downloader.loadGeneration
    }

    func useFile(_ url: URL) {
        guard !isBusy else { return }
        input = ""
        guard Self.isMedia(url) else {
            fail(nil, work: nil, String(localized: "That isn't a video or audio file. Drag a video or a recording here."))
            return
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map {
            Int64($0).fileSizeText
        } ?? ""
        stage = .ready(Item(title: url.deletingPathExtension().lastPathComponent,
                            detail: [url.pathExtension.uppercased(), size].filter { !$0.isEmpty }.joined(separator: " · "),
                            filePath: url.path))
    }

    func clear() {
        if isBusy { cancel() } else { downloader.cancelLoad() }   // a lookup may still run behind a preview
        input = ""
        prefetchedLink = nil
        qualities = []
        if saveChoice.isSize { saveChoice = .standard }
        awaitingModel = false
        browserItemLink = nil
        language = AppSettings.shared.defaultTranscriptionLanguage
        stage = .idle
        prefetchCopiedLink()        // the copied link's card shows again, with its sizes
    }

    /// Video or audio, including formats macOS doesn't know by name.
    static func isMedia(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type.conforms(to: .audiovisualContent) { return true }
        return ["mkv", "webm", "opus", "ogg", "oga", "flac", "wma", "wmv", "flv", "avi", "ts", "mts", "m2ts", "3gp"]
            .contains(url.pathExtension.lowercased())
    }

    // MARK: Actions

    func download() {
        guard case .ready(let item) = stage, let url = item.url else { return }
        if item.isLive { fail(item, work: .download, classifyDownloadError(DownloadFailure.live).message, problem: .permanent); return }
        if let reason = Self.saveFolderProblem() { fail(item, work: .download, reason, problem: .needsFolder); return }
        jobPasteboardCount = NSPasteboard.general.changeCount
        stage = .working(item, .download, phase: String(localized: "Saving…"), progress: nil)
        downloader.cancelLoad(keepInfo: true)   // a slower lookup finishing now would reset the download's state
        let folder = AppSettings.shared.downloadPath
        func fetch(_ size: Int?) -> Int? { size.map { s in qualities.first { $0.height == s }?.fetchHeight ?? s } }
        func name(_ size: Int?) -> String? { size.map { VideoQuality(height: $0, converts: false).name } }
        switch saveChoice {
        case .audio: downloader.downloadAudio(url: url, outputPath: folder)
        case .video(let height):
            downloader.downloadBest(url: url, outputPath: folder, height: fetch(height), label: name(height))
        case .original(let height):
            let size = qualities.first { $0.height == height }?.originalHeight ?? height
            downloader.downloadBest(url: url, outputPath: folder, height: size,
                                    label: name(height).map { "\($0) Original" }, keepOriginal: true)
        case .standard:
            // Before the sizes are known, yt-dlp applies the same rule from Settings.
            downloader.downloadBest(url: url, outputPath: folder, height: fetch(standardHeight), label: name(standardHeight))
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
        if item.isLive { fail(item, work: .transcribe, classifyDownloadError(DownloadFailure.live).message, problem: .permanent); return }
        if item.filePath == nil, let reason = Self.saveFolderProblem() {
            fail(item, work: .transcribe, reason, problem: .needsFolder)
            return
        }
        // The speech model downloads on first launch; wait for it, or offer it.
        if TranscriptionManager.needsSpeechModel(language), !tm.isModelInstalled {
            waitForModel(item)
            return
        }
        start(item)
    }

    private func start(_ item: Item) {
        let language = language
        jobToken += 1
        let token = jobToken
        jobPasteboardCount = NSPasteboard.general.changeCount
        stage = .working(item, .transcribe, phase: String(localized: "Getting ready…"), progress: nil)

        if let path = item.filePath {
            let isSample = path == Self.sampleURL?.path
            if isSample { try? FileManager.default.removeItem(atPath: Self.sampleTranscriptPath) }
            tm.transcribe(mediaPath: path, title: item.title, language: language, source: .file,
                          outputPath: isSample ? Self.sampleTranscriptPath : nil)
        } else if let url = item.url {
            downloader.cancelLoad(keepInfo: true)
            tm.transcriptionState = .downloadingAudio(progress: 0)
            downloader.downloadAudioForTranscription(url: url) { [weak self] audioPath, error, spoken in
                guard let self, token == self.jobToken else {
                    if let audioPath { try? FileManager.default.removeItem(atPath: audioPath) }
                    return
                }
                guard let audioPath, error == nil else {
                    self.tm.transcriptionState = .error(error ?? String(localized: "Couldn't get the audio."))
                    return
                }
                let base = TranscriptionManager.safeFileBase(item.title, fallback: "Transcript")
                let out = TranscriptionManager.uniqueFilePath(dir: AppSettings.shared.downloadPath, base: base, ext: "txt")
                self.tm.transcribe(mediaPath: audioPath, title: item.title,
                                   language: Self.language(language, spoken: spoken), source: .download,
                                   outputPath: out, removeMediaAfter: true)
            }
        }
    }

    /// Downloads the speech model the failed job needs, then carries on by itself.
    func downloadModelAndContinue() {
        guard case .failed(let item?, _, _, .needsSpeechModel, _) = stage else { return }
        tm.downloadModel()
        waitForModel(item)
    }

    /// Shows the model download in the notch while it runs, then starts the job.
    private func waitForModel(_ item: Item) {
        if tm.isDownloadingModel {
            awaitingModel = true
            stage = .working(item, .transcribe, phase: String(localized: "Downloading the speech model…"),
                             progress: tm.modelDownloadProgress > 0 ? tm.modelDownloadProgress : nil)
        } else {
            fail(item, work: .transcribe,
                 String(localized: "Transcribing needs the speech model (630 MB). It downloads once, then works offline."),
                 problem: .needsSpeechModel)
        }
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
        jobToken += 1
        switch stage {
        case .working(let item, let work, _, _):
            if awaitingModel {
                awaitingModel = false   // the model keeps downloading; only this job stops
            } else {
                downloader.cancelDownload()
                if work == .transcribe { tm.cancel() }
            }
            stage = .ready(item)
        case .loadingInfo:
            downloader.cancelLoad()
            stage = .idle
        default:
            break
        }
    }

    func signIn() {
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

    private func downloaderChanged(_ emittedState: DownloadState, _ emittedInfo: VideoInfo?) {
        // Updates arrive a moment late, so an older link's info or error can
        // still be in flight. While loading, trust only the downloader's
        // current values, and only for the lookup we started.
        var state = emittedState
        var info = emittedInfo
        if case .loadingInfo = stage {
            guard downloader.loadGeneration == awaitedLoad else { return }
            state = downloader.state
            info = downloader.videoInfo
        }
        defer {
            var finding = false
            if case .fetchingFormats = downloader.state {
                if case .ready = stage { finding = true }
                if case .idle = stage, prefetchedLink != nil { finding = true }
            }
            if findingSizes != finding { findingSizes = finding }
        }
        switch stage {
        case .idle:
            // The copied link's lookup: only its sizes matter, never its errors.
            // Only this link's info: the previous link's can still be in flight.
            if let info, let link = prefetchedLink, info.url == link, downloader.loadGeneration == awaitedLoad, !info.formats.isEmpty {
                qualities = YTDLPWrapper.qualities(in: info.formats)
            }
            // The open page on a video site: one video shows its card, anything else
            // (a home page, a search, a channel) quietly doesn't.
            if let tab = pendingTab, prefetchedLink == tab.url, downloader.loadGeneration == awaitedLoad {
                if let info, info.url == tab.url {
                    showTabVideo(tab, info: info)
                } else if downloader.state != .fetchingFormats {
                    if downloader.lastErrorNeedsAuth {
                        // A post that needs your sign-in (Instagram, X): the quiet lookup
                        // has none, but Save uses the browser's, so offer it anyway.
                        showTabVideo(tab, info: nil)
                    } else {
                        pendingTab = nil
                        // Surely not one video (a home page, a channel): skipped for a while.
                        // A lookup that just failed may work next time.
                        if !downloader.scannedVideos.isEmpty { notOneVideo[tab.url] = Date() }
                        prefetchCopiedLink()        // the copied link's sizes, if there is one
                    }
                }
            }
        case .loadingInfo(let url, let next):
            if let info {
                if !info.formats.isEmpty { qualities = YTDLPWrapper.qualities(in: info.formats) }
                let item = Item(title: info.title,
                                channel: info.uploader == "Unknown" ? "" : info.uploader,
                                duration: info.duration == "Unknown" ? "" : info.duration,
                                thumbnail: info.thumbnail.flatMap(URL.init(string:)),
                                url: info.url.isEmpty ? url : info.url,
                                isLive: info.isLive)
                stage = .ready(item)
                switch next {
                case .transcribe: transcribe()
                case .download: download()
                case nil: break
                }
            } else if case .error(let message) = state {
                fail(nil, work: nil, message, problem: downloadProblem, url: url)
            } else if case .timeout(let message) = state {
                fail(nil, work: nil, message, url: url)
            } else if !downloader.scannedVideos.isEmpty {
                fail(nil, work: nil, String(localized: "That link has several videos (a playlist, channel or post with more than one). Paste the link to one video."),
                     problem: .permanent)
            }
        case .ready(let item):
            // The instant preview showed first; the full lookup adds what it lacked.
            guard let info, downloader.loadGeneration == awaitedLoad, item.url != nil, item.url == info.url else { break }
            if !info.formats.isEmpty { qualities = YTDLPWrapper.qualities(in: info.formats) }
            var full = item
            if full.duration.isEmpty { full.duration = info.duration }
            if full.channel.isEmpty, info.uploader != "Unknown" { full.channel = info.uploader }
            full.isLive = info.isLive
            if full != item { stage = .ready(full) }
        case .working(let item, .download, _, _):
            switch state {
            case .downloading(let p, let detail):
                let phase = detail == YTDLPWrapper.convertingPhase
                    ? String(localized: "Converting for your Mac…") : String(localized: "Saving…")
                stage = .working(item, .download, phase: phase, progress: p > 0 ? p : nil)
            case .completed:
                if let path = downloader.lastDownloadedFilePath {
                    finish(.downloaded(item, path: path))
                } else {
                    fail(item, work: .download, String(localized: "The download finished but the file wasn't found."))
                }
            case .error(let message):
                fail(item, work: .download, message, problem: downloadProblem)
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
        guard case .working(let item, .transcribe, _, _) = stage, !awaitingModel else { return }
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
            if path == Self.sampleTranscriptPath { Self.spellSampleNames(at: path) }
            // The length of what was transcribed, when the link didn't say.
            var item = item
            if item.duration.isEmpty,
               let length = TranscriptionHistoryManager.shared.history.first(where: { $0.filePath == path })?.duration {
                item.duration = length
            }
            TranscriptionHistoryManager.shared.setSource(url: item.url, thumbnail: item.thumbnail?.absoluteString,
                                                         channel: item.channel.isEmpty ? nil : item.channel, forPath: path)
            autoCopiedPath = nil
            if AppSettings.shared.autoCopyWhenDone, NSPasteboard.general.changeCount == jobPasteboardCount {
                copyTranscript(path: path, item: item)
                autoCopiedPath = path
            }
            finish(.transcribed(item, path: path))
        case .error(let message):
            fail(item, work: .transcribe, message, problem: item.filePath == nil ? downloadProblem : .general)
        case .modelNotDownloaded:
            waitForModel(item)
        case .idle:
            break
        }
    }

    private func modelChanged(_ installed: Bool, _ downloading: Bool, _ progress: Double) {
        guard awaitingModel, case .working(let item, .transcribe, _, _) = stage else { return }
        if installed {
            awaitingModel = false
            start(item)
        } else if downloading {
            stage = .working(item, .transcribe, phase: String(localized: "Downloading the speech model…"),
                             progress: progress > 0 ? progress : nil)
        } else {
            awaitingModel = false
            fail(item, work: .transcribe, tm.modelDownloadError ?? String(localized: "The speech model didn't download."),
                 problem: .needsSpeechModel)
        }
    }

    private func fail(_ item: Item?, work: Work?, _ message: String, problem: Problem = .general, url: String? = nil) {
        finish(.failed(item, work: work, message: message, problem: problem, url: url))
    }

    private func finish(_ result: Stage) {
        stage = result
        input = ""
        // The introduction's first transcript: straight on to pasting it.
        if onboarding == .tryIt, case .transcribed(let item, let path) = result {
            // The paste step needs it on the clipboard, even if something else was copied meanwhile.
            if autoCopiedPath != path { copyTranscript(path: path, item: item); autoCopiedPath = path }
            if item.filePath == Self.sampleURL?.path {
                Onboarding.listen(to: path)      // hear it, with the words appearing, then paste
            } else {
                Onboarding.advance(to: .paste)
            }
            NotchController.shared.open(.reopen)
            return
        }
        guard !isOpen else { return }
        // No notification (or permission prompt) in the middle of the introduction.
        if onboarding == nil { notify(result) }
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

    /// The one notification a job sends, and only while the notch is closed.
    /// Permission is asked the first time there's something to say.
    private func notify(_ result: Stage) {
        guard AppSettings.shared.notifyOnTranscriptionComplete else { return }
        let content = UNMutableNotificationContent()
        switch result {
        case .transcribed(let item, _):
            content.title = autoCopiedPath != nil
                ? String(localized: "Transcript ready and copied") : String(localized: "Transcript ready")
            content.body = item.title
        case .downloaded(let item, _):
            content.title = String(localized: "Download finished")
            content.body = item.title
        case .failed(let item?, _, let message, _, _):
            content.title = String(localized: "That didn't work")
            content.body = item.title + "\n" + message
        default:
            return
        }
        content.sound = .default
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func markSeen() {
        hasUnseenResult = false
        unseenIsQuiet = false
        quietWork?.cancel()
    }

    // MARK: Helpers

    /// What the downloader's last error calls for.
    private var downloadProblem: Problem {
        downloader.lastErrorNeedsAuth ? .needsSignIn : downloader.lastErrorIsPermanent ? .permanent : .general
    }

    private func keepAwake(_ busy: Bool) {
        if busy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "Saving or transcribing")
        } else if !busy, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }

    /// Why the save folder can't take a file right now, or nil when it can. A
    /// missing folder is made, if what it lives in is there.
    static func saveFolderProblem() -> String? {
        let dir = AppSettings.shared.downloadPath
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: dir, isDirectory: &isDir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: false)
        }
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return String(localized: "The save folder isn't there. Choose another one in Settings.")
        }
        guard fm.isWritableFile(atPath: dir) else {
            return String(localized: "MindExtract can't save to that folder. Choose another one in Settings, or allow access in System Settings.")
        }
        return nil
    }

    /// The language to transcribe in. On Automatic, a language only Apple's
    /// speech recognition knows (Japanese, Hindi…) goes to it, when the site
    /// says the video is in that language; Parakeet would guess at it.
    static func language(_ chosen: String, spoken: String?) -> String {
        guard chosen == "auto", let spoken else { return chosen }
        let code = String(spoken.lowercased().split(separator: "-").first ?? "")
        return TranscriptionManager.appleOnlyLanguages.contains(code) ? code : chosen
    }

    /// The first web link in `text`: all of it when it's a link, else one inside it.
    static func link(in text: String) -> String? {
        if isLink(text) { return text }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        // Only a written-out web address: "notes in notion.so" isn't a link to paste.
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let url = match.url else { continue }
            let written = text[range].lowercased()
            if written.hasPrefix("https://") || written.hasPrefix("http://") { return url.absoluteString }
        }
        return nil
    }

    /// A link as it's fetched: with https:// when it was written without, and clean.
    static func fullLink(_ link: String) -> String {
        cleanLink(link.lowercased().hasPrefix("http") ? link : "https://" + link)
    }

    /// Sites whose links are videos, so a copied one may be looked up ahead.
    static func isVideoSite(_ link: String) -> Bool {
        guard let host = URLComponents(string: fullLink(link))?.host?.lowercased() else { return false }
        let sites = ["youtube.com", "youtu.be", "vimeo.com", "tiktok.com", "instagram.com", "x.com", "twitter.com",
                     "facebook.com", "fb.watch", "dailymotion.com", "twitch.tv", "reddit.com", "redd.it",
                     "linkedin.com", "soundcloud.com", "bilibili.com", "rumble.com", "streamable.com"]
        return sites.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The link without tracking parameters ("?si=…", "&igsh=…", "utm_…"), so it
    /// reads cleanly in the transcript's Source line.
    static func cleanLink(_ link: String) -> String {
        // The query as written (percent-encoded), so values like "a%2Bb" stay exactly as they were.
        guard var comps = URLComponents(string: link), let items = comps.percentEncodedQueryItems, !items.isEmpty else { return link }
        let tracking: Set<String> = ["si", "igsh", "igshid", "srtk", "fbclid", "gclid", "mibextid", "feature", "pp", "ref_src", "ref_url", "_r", "_t"]
        let kept = items.filter { !tracking.contains($0.name.lowercased()) && !$0.name.lowercased().hasPrefix("utm_") }
        guard kept.count != items.count else { return link }
        comps.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return comps.string ?? link
    }

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

    // MARK: The introduction's sample

    /// A short spoken clip bundled with the app, for a first transcript without a link.
    static var sampleURL: URL? { Bundle.main.url(forResource: "Sample", withExtension: "m4a") }

    /// Its transcript goes to the app's own folder, not the user's Downloads.
    private static var sampleTranscriptPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mindact.mindextract")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Welcome to MindExtract.txt").path
    }

    /// The speech model spells names the usual English way; the sample's speaker
    /// spells his own name with one t.
    private static func spellSampleNames(at path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let fixed = text.replacingOccurrences(of: "Matthias", with: "Mathias")
        if fixed != text { try? fixed.write(toFile: path, atomically: true, encoding: .utf8) }
    }

    func transcribeSample() {
        guard let url = Self.sampleURL, !isBusy else { return }
        input = ""
        stage = .ready(Item(title: String(localized: "Welcome to MindExtract"), duration: "0:18",
                            detail: String(localized: "Sample"), filePath: url.path))
        transcribe()
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
            // The date line is written in the Mac's language ("26 oktober 2026 08:10",
            // "October 26, 2026 at 8:10 AM"): a short line with a year, not a passage.
            if let next = lines.first, !next.hasPrefix("["), next.count < 60,
               next.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) != nil {
                lines.removeFirst()
            }
            while let next = lines.first, next.trimmingCharacters(in: .whitespaces).isEmpty {
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
        var candidates: [(name: String?, rest: String, line: String)] = []
        for block in withoutHeader(raw).components(separatedBy: "\n") {
            var line = block.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let r = line.range(of: pattern, options: .regularExpression) { line.removeSubrange(r) }
            var name: String?
            var rest = line
            if let colon = line.firstIndex(of: ":"), line.distance(from: line.startIndex, to: colon) <= 30 {
                let before = String(line[..<colon])
                if before.range(of: #"^[\p{L}][\p{L}\p{N} .'/-]*$"#, options: .regularExpression) != nil, before.split(separator: " ").count <= 3 {
                    name = before
                    rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            candidates.append((name, rest, line))
        }
        // A word before a colon is a speaker only if it's "Speaker N" or comes back:
        // "Note: …" once in a talk is just a sentence.
        var counts: [String: Int] = [:]
        for c in candidates { if let n = c.name { counts[n, default: 0] += 1 } }
        func isSpeaker(_ n: String) -> Bool {
            n.range(of: #"^Speaker \d"#, options: .regularExpression) != nil || counts[n, default: 0] >= 2
        }
        var rows: [(speaker: String?, text: String)] = []
        for c in candidates {
            if let n = c.name, isSpeaker(n) {
                if !c.rest.isEmpty { rows.append((n, c.rest)) }
            } else {
                rows.append((nil, c.line))
            }
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
