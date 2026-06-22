import Foundation
import AppKit
import WebKit
import NaturalLanguage

// MARK: - PII redaction (on-device)
//
// Masks personal names, emails and phone numbers so a transcript can be shared
// without exposing identities — built for the legal/medical/research users who
// can't hand out raw names. Uses Apple's NaturalLanguage name tagger plus regex
// for contact info. Same person → same token ([Person 1]) so the conversation
// still reads coherently. Entirely on-device.

enum Redactor {
    /// NOTE: NLTagger name recall is lower for Swedish (and other non-English)
    /// text than for English — some names will slip through. The redacted export
    /// surfaces a visible "review before sharing" notice; never treat this as a
    /// guarantee of complete anonymization.
    static func redact(_ text: String, knownNames: [String] = []) -> String {
        guard !text.isEmpty else { return text }
        var personMap: [String: String] = [:]
        func token(for name: String) -> String {
            let key = name.lowercased()
            if let t = personMap[key] { return t }
            let t = "[Person \(personMap.count + 1)]"
            personMap[key] = t
            return t
        }

        // 1. Personal names via NaturalLanguage (joined multi-word names).
        var replacements: [(Range<String.Index>, String)] = []
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let opts: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: opts) { tag, range in
            if tag == .personalName {
                replacements.append((range, token(for: String(text[range]))))
            }
            return true
        }
        var result = text
        for (range, replacement) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            result.replaceSubrange(range, with: replacement)
        }

        // 2. User-assigned speaker names the tagger may have missed (e.g. single
        //    first names used as labels). Whole-word, case-insensitive.
        for name in knownNames where name.count > 1 {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            result = result.replacingOccurrences(
                of: "\\b\(escaped)\\b", with: token(for: name),
                options: [.regularExpression, .caseInsensitive])
        }

        // 3. Emails and phone numbers.
        result = result.replacingOccurrences(
            of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            with: "[email]", options: [.regularExpression, .caseInsensitive])
        // Bounded length so we don't swallow long ID/number runs; phone-shaped only.
        result = result.replacingOccurrences(
            of: #"(?<![\d-])(\+?\d[\d \-\(\)]{5,13}\d)(?![\d-])"#,
            with: "[phone]", options: .regularExpression)
        return result
    }
}

// MARK: - PDF export (formatted, paginated)
//
// Renders styled HTML to a paginated PDF via WKWebView — gives clean, printable
// transcripts/notes (with speaker labels and timestamps) without hand-rolling
// Core Text pagination.

@MainActor
final class PDFExporter: NSObject, WKNavigationDelegate {
    static let shared = PDFExporter()

    // Run requests one at a time — a single shared web view can't render two at once.
    private var queue: [(html: String, completion: (Data?) -> Void)] = []
    private var busy = false
    private var activeWebView: WKWebView?
    private var activeCompletion: ((Data?) -> Void)?

    private override init() { super.init() }

    func makePDF(html: String, completion: @escaping (Data?) -> Void) {
        queue.append((html, completion))
        drain()
    }

    private func drain() {
        guard !busy, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        busy = true
        // Letter width; height grows with content, WKPDFConfiguration paginates.
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 612, height: 792),
                           configuration: WKWebViewConfiguration())
        wv.navigationDelegate = self
        activeWebView = wv
        activeCompletion = next.completion
        wv.loadHTMLString(next.html, baseURL: nil)
    }

    private func finish(_ data: Data?) {
        activeCompletion?(data)
        activeCompletion = nil
        activeWebView = nil
        busy = false
        drain()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Wait for fonts/layout to settle (DOM-parsed ≠ laid out) before snapshotting.
        webView.evaluateJavaScript("document.fonts.ready.then(() => true)") { [weak self] _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard let self else { return }
                webView.createPDF(configuration: WKPDFConfiguration()) { result in
                    Task { @MainActor in self.finish(try? result.get()) }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    /// Build a styled HTML document for a transcript. `paragraphs` is a list of
    /// (speaker?, timestamp?, text) rows; `extraSections` are title→body blocks
    /// (e.g. Summary, Action Items) appended after the transcript.
    static func transcriptHTML(title: String,
                               paragraphs: [(speaker: String?, time: String?, text: String)],
                               extraSections: [(String, String)] = [],
                               notice: String? = nil) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var body = ""
        for p in paragraphs {
            var meta = ""
            if let sp = p.speaker { meta += "<span class='spk'>\(esc(sp))</span>" }
            if let t = p.time { meta += "<span class='ts'>\(esc(t))</span>" }
            body += "<p>\(meta.isEmpty ? "" : "<span class='meta'>\(meta)</span>")\(esc(p.text))</p>\n"
        }
        var extras = ""
        for (heading, text) in extraSections where !text.isEmpty {
            let paras = text.components(separatedBy: "\n").filter { !$0.isEmpty }
                .map { "<p>\(esc($0))</p>" }.joined()
            extras += "<h2>\(esc(heading))</h2>\(paras)"
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        * { -webkit-print-color-adjust: exact; }
        body { font: 13px/1.55 -apple-system, 'Helvetica Neue', sans-serif; color: #1d1d1f; margin: 48px 56px; }
        h1 { font-size: 20px; margin: 0 0 4px; }
        h2 { font-size: 15px; margin: 22px 0 6px; border-bottom: 1px solid #e5e5ea; padding-bottom: 3px; }
        .sub { color: #8e8e93; font-size: 11px; margin: 0 0 18px; }
        p { margin: 0 0 9px; }
        .meta { display: inline; margin-right: 6px; }
        .spk { font-weight: 600; color: #007aff; margin-right: 6px; }
        .ts { color: #aeaeb2; font-variant-numeric: tabular-nums; font-size: 11px; margin-right: 6px; }
        .notice { background:#fff4e5; border:1px solid #ffd8a8; color:#8a5a00; border-radius:6px; padding:8px 10px; font-size:11px; margin:0 0 16px; }
        </style></head><body>
        <h1>\(esc(title))</h1>
        <p class="sub">Generated by MindExtract</p>
        \(notice.map { "<p class='notice'>\(esc($0))</p>" } ?? "")
        \(body)
        \(extras)
        </body></html>
        """
    }
}
