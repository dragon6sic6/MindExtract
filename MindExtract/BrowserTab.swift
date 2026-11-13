import AppKit
import CoreServices

// MARK: - The page open in your browser

/// Reads the page open in the browser you're using when the notch opens, so
/// the notch can offer that page's video. Asks the browser over Apple Events,
/// which macOS lets an app do only after you allow it once per browser.
enum BrowserTab {
    struct Browser: Equatable, Sendable {
        let bundleID: String
        let name: String
        var isSafari: Bool { bundleID.hasPrefix("com.apple.Safari") }
    }

    struct Tab: Equatable, Sendable {
        let url: String
        let title: String
        let browser: Browser
    }

    enum Permission: Equatable { case allowed, notAsked, denied, unavailable }

    /// Browsers that answer "which page is open". Firefox doesn't.
    static let known: [String: String] = [
        "com.apple.Safari": "Safari",
        "com.apple.SafariTechnologyPreview": "Safari",
        "com.google.Chrome": "Chrome",
        "com.google.Chrome.beta": "Chrome",
        "company.thebrowser.Browser": "Arc",
        "com.microsoft.edgemac": "Edge",
        "com.brave.Browser": "Brave",
        "com.vivaldi.Vivaldi": "Vivaldi",
    ]

    /// The browser you're in right now, if it's one we can ask.
    @MainActor static func frontmost() -> Browser? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let id = app.bundleIdentifier, let name = known[id] else { return nil }
        return Browser(bundleID: id, name: name)
    }

    /// Whether macOS lets us ask `browser`. With `ask`, macOS shows its one
    /// question ("MindExtract wants to control Chrome") when it hasn't yet.
    static func permission(for browser: Browser, ask: Bool) async -> Permission {
        await withCheckedContinuation { done in
            // Asking waits for your answer, so never on the main thread.
            DispatchQueue.global(qos: .userInitiated).async {
                let target = NSAppleEventDescriptor(bundleIdentifier: browser.bundleID)
                let status = AEDeterminePermissionToAutomateTarget(
                    target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
                appLog("Browser: AEDeterminePermission(\(browser.bundleID), ask \(ask)) = \(status)")
                switch Int(status) {
                case Int(noErr): done.resume(returning: .allowed)
                case -1744: done.resume(returning: .notAsked)       // errAEEventWouldRequireUserConsent
                case -1743: done.resume(returning: .denied)         // errAEEventNotPermitted
                default: done.resume(returning: .unavailable)       // not running, or no answer
                }
            }
        }
    }

    /// The page in the front window. Nothing from a private (incognito) window.
    static func currentTab(of browser: Browser) async -> Tab? {
        let script: String
        if browser.isSafari {
            script = """
            tell application id "\(browser.bundleID)"
                if (count of windows) is 0 then return ""
                set t to current tab of front window
                return (URL of t) & linefeed & (name of t)
            end tell
            """
        } else {
            // Chrome, Edge, Brave and Vivaldi call a private window's mode "incognito";
            // Arc has an "incognito" flag. If the check can't be made, nothing is read.
            let isPrivate = browser.bundleID == "company.thebrowser.Browser"
                ? "incognito of w" : "(mode of w) is \"incognito\""
            script = """
            tell application id "\(browser.bundleID)"
                if (count of windows) is 0 then return ""
                set w to front window
                try
                    if \(isPrivate) then return ""
                on error
                    return ""
                end try
                set t to active tab of w
                return (URL of t) & linefeed & (title of t)
            end tell
            """
        }
        // A browser that quit a moment ago would be started again by the script.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).isEmpty else { return nil }
        guard let output = await runAppleScript(script) else { return nil }
        let lines = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let url = lines.first?.trimmingCharacters(in: .whitespaces), url.lowercased().hasPrefix("http") else { return nil }
        let title = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return Tab(url: url, title: title, browser: browser)
    }

    /// osascript in its own process: a browser that hangs can't hang the notch.
    private static func runAppleScript(_ source: String) async -> String? {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                task.arguments = ["-e", source]
                let out = Pipe()
                task.standardOutput = out
                task.standardError = Pipe()
                do { try task.run() } catch { done.resume(returning: nil); return }
                let killer = DispatchWorkItem { if task.isRunning { task.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                killer.cancel()
                guard task.terminationStatus == 0 else { done.resume(returning: nil); return }
                done.resume(returning: String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}

// MARK: - A video found on a web page

/// A video on a page yt-dlp doesn't know (a webinar platform, a company site):
/// the stream, file or embedded player the page plays it from.
struct PageVideo: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case stream, file, player }
    let pageURL: String
    let mediaURL: String
    var kind: Kind = .stream
    /// Sent as Referer when fetching the stream: the origin of the page or frame
    /// it was found in, the way a browser sends it to another site.
    var referer: String?
    var title: String?
    var thumbnail: String?
    var site: String?
    var found = Date()
    /// A stream or file knows nothing about itself ("hls"), so the page names it.
    /// An embedded player (YouTube, Vimeo) has its own title.
    var pageNamesIt: Bool { kind != .player }
}

/// The pages found so far, so every later step (sizes, saving, transcribing)
/// hands yt-dlp the stream while the app keeps showing the page.
final class PageVideos: @unchecked Sendable {
    static let shared = PageVideos()
    private let lock = NSLock()
    private var byPage: [String: PageVideo] = [:]

    func add(_ video: PageVideo) {
        lock.lock(); defer { lock.unlock() }
        byPage[video.pageURL] = video
        if byPage.count > 100, let oldest = byPage.values.min(by: { $0.found < $1.found }) {
            byPage[oldest.pageURL] = nil
        }
    }

    func video(for pageURL: String) -> PageVideo? {
        lock.lock(); defer { lock.unlock() }
        return byPage[pageURL]
    }

    /// Stream links are often signed and expire: a page opened again after a
    /// while is searched again instead of handing yt-dlp a dead link.
    func dropIfStale(_ pageURL: String, after age: TimeInterval = 1800) {
        lock.lock(); defer { lock.unlock() }
        if let v = byPage[pageURL], Date().timeIntervalSince(v.found) > age { byPage[pageURL] = nil }
    }
}

/// Looks through a page (and the frames it embeds) for its video, the way a
/// browser extension would, from the page as the site serves it to anyone: no
/// cookies, no sign-in. Only when asked: pasting the page, or Find Video.
enum PageScanner {
    /// A public web address: http(s), and not this Mac or the local network.
    static func isPublic(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), !host.isEmpty, !host.hasSuffix(".") else { return false }
        guard host.contains("."), !host.contains(":") else { return false }     // "intranet", localhost, IPv6
        let local = [".local", ".localhost", ".internal", ".lan", ".home.arpa", ".intranet", ".corp", ".localdomain"]
        if local.contains(where: { host.hasSuffix($0) }) { return false }
        // An IP address, also written as hex or octal ("0x7f.1").
        if host.range(of: #"^(0x[0-9a-f]+|[0-9]+)(\.(0x[0-9a-f]+|[0-9]+)){0,3}$"#, options: .regularExpression) != nil { return false }
        return true
    }

    /// Pages never looked at: sign-in, payment and mail pages, links that carry
    /// a key or a one-time token, and anything on this Mac or the local network.
    static func isScannable(_ link: String) -> Bool {
        guard let url = URL(string: link), isPublic(url),
              let comps = URLComponents(string: link), let host = comps.host?.lowercased() else { return false }
        let privateHosts = ["accounts.", "account.", "login.", "auth.", "sso.", "id.", "mail.", "secure.", "pay.", "checkout.", "admin."]
        if privateHosts.contains(where: { host.hasPrefix($0) }) { return false }
        let apps = ["docs.google.com", "drive.google.com", "calendar.google.com", "mail.google.com", "outlook.live.com",
                    "outlook.office.com", "outlook.office365.com", "sharepoint.com", "web.whatsapp.com", "app.slack.com",
                    "teams.microsoft.com", "web.telegram.org", "messenger.com", "claude.ai", "chatgpt.com", "notion.so",
                    // Search results and code: no video to find, so no offer either.
                    "bing.com", "duckduckgo.com", "github.com", "stackoverflow.com"]
        if apps.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return false }
        if host.range(of: #"(^|\.)google\.[a-z.]+$"#, options: .regularExpression) != nil, comps.path == "/search" { return false }
        // Whole words of the path ("reset-password"), not parts of others ("accountability").
        let words: Set<String> = ["login", "signin", "logout", "signout", "oauth", "password", "reset", "verify", "confirm",
                                  "activate", "invite", "approve", "rsvp", "optout", "unsubscribe", "checkout", "payment",
                                  "billing", "invoice", "account", "settings", "callback"]
        for segment in comps.path.lowercased().split(separator: "/") {
            let tokens = segment.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            if tokens.contains(where: words.contains) { return false }
            if ["sign-in", "sign_in", "log-in", "opt-out", "sign-out"].contains(where: segment.contains) { return false }
        }
        // A segment that looks like a key: a JWT, or a long unbroken run of letters
        // and digits (a slug with dashes, "lecture-1-the-geometry-of…", is a title).
        if comps.path.split(separator: "/").contains(where: { seg in
            // (A 24-letter lowercase id like a video's "5f8d0d55b54764421b7156c9" is fine.)
            seg.hasPrefix("eyJ") || (seg.allSatisfy { $0.isLetter || $0.isNumber } && seg.contains(where: \.isNumber)
                && ((seg.count >= 32 && seg.contains(where: \.isLetter))
                    || (seg.count >= 20 && seg.contains(where: \.isUppercase) && seg.contains(where: \.isLowercase))))
        }) { return false }
        let keys: Set<String> = ["token", "access_token", "id_token", "code", "key", "apikey", "api_key", "sig", "signature",
                                 "otp", "auth", "password", "pwd", "sessionid", "session_id", "session_token", "ticket", "secret",
                                 "jwt", "state", "nonce", "x-amz-signature", "x-goog-signature", "mkt_tok", "_hsenc", "mc_eid"]
        if let items = comps.queryItems, items.contains(where: { keys.contains($0.name.lowercased()) }) { return false }
        return true
    }

    /// The page's video, or nil when it has none (or none we can reach).
    static func scan(_ pageURL: String) async -> PageVideo? {
        let started = Date()
        guard isScannable(pageURL), let start = URL(string: pageURL), let (html, base) = await fetch(start) else { return nil }
        let page = Found(html, base: base)
        let site = page.meta["og:site_name"] ?? base.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        func video(_ best: (url: String, kind: PageVideo.Kind), in place: URL, inner: Found?) -> PageVideo {
            // The page's own name for itself first: its tab often says only the site.
            let named = [page.meta["og:title"], inner?.meta["og:title"]].compactMap { $0 }.first { !$0.isEmpty }
            let image = page.meta["og:image"].flatMap { URL(string: $0, relativeTo: base)?.absoluteString }
                ?? inner?.meta["og:image"].flatMap { URL(string: $0, relativeTo: place)?.absoluteString }
            return PageVideo(pageURL: pageURL, mediaURL: best.url, kind: best.kind, referer: origin(place),
                             title: named ?? [page.title, inner?.title].compactMap { $0 }.first { !$0.isEmpty },
                             thumbnail: image, site: site)
        }
        if let best = page.best { return video(best, in: base, inner: nil) }
        // The player often sits in a frame of its own (a webinar's recording page).
        // Not past 15 seconds in all: a slow site isn't waited on frame after frame.
        for frame in page.frames.prefix(3) where Date().timeIntervalSince(started) < 15 {
            guard let (inner, frameURL) = await fetch(frame) else { continue }
            let found = Found(inner, base: frameURL)
            if let best = found.best { return video(best, in: frameURL, inner: found) }
        }
        return nil
    }

    /// The name points at the internet, not this Mac or the local network
    /// ("127.0.0.1.nip.io", "fritz.box" pass the name check but not this).
    static func resolvesPublic(_ url: URL) async -> Bool {
        guard let host = url.host else { return false }
        return await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                                     ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
                var list: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { done.resume(returning: false); return }
                defer { freeaddrinfo(first) }
                var node: UnsafeMutablePointer<addrinfo>? = first
                var any = false
                while let n = node {
                    any = true
                    if let addr = n.pointee.ai_addr, isPrivate(addr) { done.resume(returning: false); return }
                    node = n.pointee.ai_next
                }
                done.resume(returning: any)
            }
        }
    }

    private static func isPrivate(_ addr: UnsafeMutablePointer<sockaddr>) -> Bool {
        func v4(_ a: UInt32) -> Bool {      // host byte order
            let b0 = a >> 24, b1 = (a >> 16) & 0xff
            return b0 == 0 || b0 == 10 || b0 == 127 || (b0 == 169 && b1 == 254) || (b0 == 172 && (16...31).contains(b1))
                || (b0 == 192 && b1 == 168) || (b0 == 100 && (64...127).contains(b1)) || b0 >= 224
        }
        switch Int32(addr.pointee.sa_family) {
        case AF_INET:
            return addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { v4(UInt32(bigEndian: $0.pointee.sin_addr.s_addr)) }
        case AF_INET6:
            return addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                let b = withUnsafeBytes(of: p.pointee.sin6_addr) { Array($0) }
                if b[0..<15].allSatisfy({ $0 == 0 }) { return true }                       // :: and ::1
                if b[0] & 0xfe == 0xfc { return true }                                      // fc00::/7
                if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return true }                      // fe80::/10
                if b[0] == 0xff { return true }                                             // multicast
                func v4At(_ i: Int) -> UInt32 { UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]) }
                if b[0..<12].allSatisfy({ $0 == 0 }) { return v4(v4At(12)) }                // ::a.b.c.d
                if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b { return v4(v4At(12)) }   // 64:ff9b:: (NAT64)
                if b[0] == 0x20 && b[1] == 0x02 { return v4(v4At(2)) }                      // 2002::/16 (6to4)
                if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {    // ::ffff:a.b.c.d
                    return v4(UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15]))
                }
                return false
            }
        default:
            return true
        }
    }

    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")/"
    }

    /// Follows a redirect only to another public address, and never from https to http.
    private final class RedirectCheck: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, PageScanner.isScannable(url.absoluteString),
                  await PageScanner.resolvesPublic(url) else { return nil }
            if task.originalRequest?.url?.scheme?.lowercased() == "https", url.scheme?.lowercased() != "https" { return nil }
            return request
        }
    }

    /// The page's HTML (at most 2 MB, within 10 s), and where it ended up after redirects.
    private static func fetch(_ url: URL) async -> (String, URL)? {
        guard isPublic(url), await resolvesPublic(url) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 10
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: RedirectCheck(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              (http.mimeType ?? "text/html").lowercased().contains("html"),
              http.expectedContentLength < 8_000_000 else { return nil }   // -1 when unknown
        let limit = 2_000_000
        var data = Data()
        data.reserveCapacity(min(limit, max(0, Int(http.expectedContentLength))))
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch {
            if data.isEmpty { return nil }
        }
        return (String(decoding: data, as: UTF8.self), http.url ?? url)
    }

    /// What one page's HTML points at. Every pattern here runs in time that grows
    /// with the page, never faster: a broken or hostile page can't stall it.
    struct Found {
        var streams: [String] = []      // HLS (.m3u8), DASH (.mpd)
        var files: [String] = []        // .mp4, .m4v, .mov, .webm
        var players: [String] = []      // YouTube, Vimeo, Wistia, Loom embeds, as links yt-dlp knows
        var frames: [URL] = []          // the page's own frames, which may hold the player
        var meta: [String: String] = [:]
        var title: String?
        /// Every find with how sure we are it's the page's video: what the page
        /// declares (og:video) first, then a player you see (<video controls>, an
        /// embed), then links in its scripts (where ads and previews live too).
        private var ranked: [(url: String, kind: PageVideo.Kind, tier: Int, order: Int)] = []

        var best: (url: String, kind: PageVideo.Kind)? {
            func kindRank(_ k: PageVideo.Kind) -> Int { k == .stream ? 0 : k == .player ? 1 : 2 }
            func master(_ s: String) -> Int { ["master", "manifest", "playlist"].contains { s.lowercased().contains($0) } ? 0 : 1 }
            // HLS before DASH: yt-dlp and ffmpeg open more of it (an encrypted track too).
            func dash(_ s: String) -> Int { URL(string: s)?.pathExtension.lowercased() == "mpd" ? 1 : 0 }
            return ranked.min { a, b in
                (a.tier, kindRank(a.kind), dash(a.url), master(a.url), a.order) < (b.tier, kindRank(b.kind), dash(b.url), master(b.url), b.order)
            }.map { ($0.url, $0.kind) }
        }

        init(_ html: String, base: URL) {
            var found: [(String, Int)] = []      // a link and its tier
            var decorative = Set<String>()
            var seenFrames = Set<String>()
            var seenPlayers = Set<String>()

            var inDecorativeVideo = false
            for (name, attrs) in Self.tags(in: html) {
                switch name {
                case "meta":
                    guard let key = (attrs["property"] ?? attrs["name"])?.lowercased(), let value = attrs["content"],
                          meta[key] == nil else { continue }
                    meta[key] = Self.decode(value)
                    if ["og:video", "og:video:url", "og:video:secure_url", "twitter:player:stream"].contains(key) {
                        found.append((Self.decode(value), 0))
                    }
                case "video":
                    // A muted video without controls plays by itself: decoration, not the talk.
                    inDecorativeVideo = attrs["controls"] == nil && attrs["muted"] != nil
                    if let src = attrs["src"].map(Self.decode) {
                        if inDecorativeVideo { decorative.insert(src) } else { found.append((src, 1)) }
                    }
                case "/video":
                    inDecorativeVideo = false
                case "source":
                    if let src = attrs["src"].map(Self.decode) {
                        if inDecorativeVideo { decorative.insert(src) } else { found.append((src, 1)) }
                    }
                case "iframe":
                    guard let src = attrs["src"].map(Self.decode),
                          let url = URL(string: src, relativeTo: base)?.absoluteURL, PageScanner.isPublic(url) else { continue }
                    if let player = Self.player(url) {
                        // The embed's own address: it's turned into the player link below.
                        if seenPlayers.count < 20, seenPlayers.insert(player).inserted { found.append((url.absoluteString, 1)) }
                    } else if seenFrames.count < 10, Self.sameSite(url.host?.lowercased() ?? "", base.host?.lowercased() ?? ""),
                              PageScanner.isScannable(url.absoluteString), seenFrames.insert(url.absoluteString).inserted {
                        frames.append(url)
                    }
                default:
                    break
                }
            }
            // The page's title, not an icon's <title> inside an <svg> in the body.
            let head = html.range(of: "</head>", options: .caseInsensitive).map { String(html[..<$0.lowerBound]) } ?? html
            if let t = Self.firstGroup(#"<title[^<>]{0,200}+>([^<]{0,500}+)<"#, in: head) {
                let clean = Self.decode(t).trimmingCharacters(in: .whitespacesAndNewlines)
                title = clean.isEmpty ? nil : clean
            }

            // Links anywhere else: in scripts, often written "https:\/\/…" or with "\u0026".
            let text = html.replacingOccurrences(of: "\\/", with: "/")
                .replacingOccurrences(of: "\\u0026", with: "&").replacingOccurrences(of: "\\u002F", with: "/")
                .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
            for link in Self.all(#"(?:https?:)?//[^\s"'<>\\()\[\]{}|^`]++"#, in: text) { found.append((link, 2)) }

            var seen = Set<String>()
            for (order, (candidate, tier)) in found.enumerated() {
                guard ranked.count < 200 else { break }
                let trimmed = candidate.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
                guard !decorative.contains(candidate), let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
                      PageScanner.isPublic(url), !Self.isPlaceholder(url) else { continue }
                var key = URLComponents(url: url, resolvingAgainstBaseURL: false)
                key?.fragment = nil
                guard seen.insert(key?.string ?? url.absoluteString).inserted else { continue }
                let link = url.absoluteString
                let ext = url.pathExtension.lowercased()
                let isStream = ["m3u8", "mpd"].contains(ext) || link.lowercased().contains("format=m3u8")
                let isFile = ["mp4", "m4v", "mov", "webm"].contains(ext)
                if (isStream || isFile), Self.isDecorative(url) { continue }
                if isStream {
                    streams.append(link)
                    ranked.append((link, .stream, tier, order))
                } else if isFile {
                    files.append(link)
                    ranked.append((link, .file, tier, order))
                } else if let player = Self.player(url) {
                    if !players.contains(player), players.count < 20 { players.append(player) }
                    ranked.append((player, .player, tier, order))
                }
            }
        }

        /// A made-up address from a code sample ("example.com/path/to/file.mp4").
        static func isPlaceholder(_ url: URL) -> Bool {
            guard let host = url.host?.lowercased() else { return true }
            return ["example.com", "example.org", "example.net", "example.edu", "test", "invalid"]
                .contains { host == $0 || host.hasSuffix("." + $0) }
        }

        /// Background loops, teasers and thumbnails, judged by the file's own name.
        static func isDecorative(_ url: URL) -> Bool {
            let names = url.pathComponents.suffix(2).joined(separator: "/").lowercased()
            let words = Set(names.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            return !words.isDisjoint(with: ["background", "bg", "loop", "hero", "teaser", "preview", "thumb",
                                            "thumbnail", "ambient", "banner", "promo", "trailer"])
        }

        /// An embedded player, as the link yt-dlp takes for it.
        static func player(_ url: URL) -> String? {
            guard let host = url.host?.lowercased() else { return nil }
            let parts = url.path.split(separator: "/").map(String.init)
            func under(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
            if under("youtube.com") || under("youtube-nocookie.com") {
                guard parts.count >= 2, parts[0] == "embed",
                      parts[1].range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil,
                      !["videoseries", "live_stream"].contains(parts[1]) else { return nil }
                return "https://www.youtube.com/watch?v=\(parts[1])"
            }
            if host == "player.vimeo.com", parts.count >= 2, parts[0] == "video", parts[1].allSatisfy(\.isNumber) {
                return url.absoluteString
            }
            if under("wistia.net") || under("wistia.com"), parts.contains("iframe") || parts.contains("medias") {
                return url.absoluteString
            }
            if under("loom.com"), parts.first == "embed" || parts.first == "share" { return url.absoluteString }
            return nil
        }

        static func sameSite(_ a: String, _ b: String) -> Bool {
            // Sites under a shared suffix (bbc.co.uk, x.github.io) are told apart by one label more.
            let shared: Set<String> = ["co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.nz", "co.jp",
                                       "ne.jp", "com.br", "com.cn", "co.in", "co.za", "com.mx", "com.tr", "github.io",
                                       "vercel.app", "netlify.app", "herokuapp.com", "pages.dev", "web.app", "firebaseapp.com",
                                       "azurewebsites.net", "cloudfront.net", "blogspot.com", "wordpress.com", "lovable.app"]
            func root(_ h: String) -> String {
                let labels = h.split(separator: ".")
                let two = labels.suffix(2).joined(separator: ".")
                return shared.contains(two) ? labels.suffix(3).joined(separator: ".") : two
            }
            return !a.isEmpty && root(a) == root(b)
        }

        /// HTML entities: named ones that turn up in titles, and every numbered one (&#8211; &#xE5;).
        static func decode(_ s: String) -> String {
            guard s.contains("&"), let re = try? NSRegularExpression(pattern: "&(#[xX][0-9a-fA-F]{1,6}|#[0-9]{1,7}|[a-zA-Z]{2,8});") else { return s }
            let named: [String: String] = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": " ",
                                           "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}", "rsquo": "\u{2019}",
                                           "lsquo": "\u{2018}", "rdquo": "\u{201D}", "ldquo": "\u{201C}", "aring": "å",
                                           "auml": "ä", "ouml": "ö", "Aring": "Å", "Auml": "Ä", "Ouml": "Ö", "eacute": "é",
                                           "egrave": "è", "aacute": "á", "iacute": "í", "oacute": "ó", "uacute": "ú",
                                           "uuml": "ü", "Uuml": "Ü", "ntilde": "ñ", "ccedil": "ç", "oslash": "ø",
                                           "aelig": "æ", "szlig": "ß", "copy": "©", "reg": "®", "trade": "™",
                                           "euro": "€", "pound": "£", "middot": "·", "bull": "•", "laquo": "«", "raquo": "»"]
            var out = ""
            var last = s.startIndex
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                guard let whole = Range(m.range, in: s), let body = Range(m.range(at: 1), in: s) else { continue }
                out += s[last..<whole.lowerBound]
                let name = String(s[body])
                var replacement: String?
                // A numbered one that's a control character (&#0;) is left out.
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { $0.value < 0x20 ? "" : String(Character($0)) }
                } else if name.hasPrefix("#") {
                    replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { $0.value < 0x20 ? "" : String(Character($0)) }
                } else {
                    replacement = named[name]
                }
                out += replacement ?? String(s[whole])
                last = whole.upperBound
            }
            return out + s[last...]
        }

        /// The opening tags we care about, with their attributes. A tag ends at the
        /// next ">" (or is skipped at the next "<"), so a page full of broken tags
        /// is still read in one pass.
        static func tags(in html: String) -> [(String, [String: String])] {
            guard let tagRe = try? NSRegularExpression(pattern: #"<(/?(?:meta|iframe|video|source))\b([^<>]{0,4000}+)>"#, options: [.caseInsensitive]),
                  let attrRe = try? NSRegularExpression(pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*+)(?:\s*+=\s*+(?:"([^"]*+)"|'([^']*+)'|([^\s"'>]++)))?"#)
            else { return [] }
            var result: [(String, [String: String])] = []
            for m in tagRe.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let n = Range(m.range(at: 1), in: html), let a = Range(m.range(at: 2), in: html) else { continue }
                let body = String(html[a])
                var attrs: [String: String] = [:]
                for am in attrRe.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                    guard let k = Range(am.range(at: 1), in: body) else { continue }
                    let key = body[k].lowercased()
                    let value = [2, 3, 4].lazy.compactMap { Range(am.range(at: $0), in: body).map { String(body[$0]) } }.first ?? ""
                    if attrs[key] == nil { attrs[key] = value }
                }
                result.append((html[n].lowercased(), attrs))
            }
            return result
        }

        static func all(_ pattern: String, in s: String) -> [String] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
            return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
                Range($0.range, in: s).map { String(s[$0]) }
            }
        }

        static func firstGroup(_ pattern: String, in s: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let r = Range(m.range(at: 1), in: s) else { return nil }
            return String(s[r])
        }
    }
}
