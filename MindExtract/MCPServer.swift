import Foundation

// MARK: - MCP server (stdio)
//
// Runs when MindExtract is launched with `--mcp` (Claude Desktop / any MCP client
// spawns it as a subprocess). Exposes the user's transcripts as MCP tools so they
// can search and pull them straight into Claude/ChatGPT. Fully local: the server
// reads the same on-device transcript files the app writes; nothing is uploaded
// by us — only what the AI client itself sends when the user asks.
//
// Transport: newline-delimited JSON-RPC 2.0 over stdin/stdout. NOTHING may be
// written to stdout except protocol messages (logs go to stderr).

enum MCPServer {
    static func run() {
        // Duplicate the REAL stdout to a private fd for protocol output, then point
        // fd 1 at /dev/null so any stray print()/library logging can't corrupt the
        // JSON-RPC stream. (freopen redirects fd 1 itself, which is why we dup first.)
        let realOut = dup(STDOUT_FILENO)
        freopen("/dev/null", "w", stdout)
        let out = FileHandle(fileDescriptor: realOut >= 0 ? realOut : STDOUT_FILENO, closeOnDealloc: false)
        MCPServerImpl(out: out).serve()
    }
}

private final class MCPServerImpl {
    private let protocolVersion = "2024-11-05"
    private let out: FileHandle

    init(out: FileHandle) { self.out = out }

    func serve() {
        log("MindExtract MCP server started")
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8),
                  let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            handle(msg)
        }
    }

    // MARK: Dispatch

    private func handle(_ msg: [String: Any]) {
        let method = msg["method"] as? String ?? ""
        let id = msg["id"]   // absent for notifications
        switch method {
        case "initialize":
            reply(id, [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [String: Any](), "resources": [String: Any]()],
                "serverInfo": ["name": "MindExtract", "version": appVersion()]
            ])
        case "notifications/initialized", "notifications/cancelled":
            break   // notifications: no response
        case "ping":
            reply(id, [String: Any]())
        case "tools/list":
            reply(id, ["tools": toolDefinitions()])
        case "tools/call":
            handleToolCall(id, params: msg["params"] as? [String: Any] ?? [:])
        case "resources/list":
            reply(id, ["resources": resourceList()])
        case "resources/read":
            handleResourceRead(id, params: msg["params"] as? [String: Any] ?? [:])
        default:
            if id != nil { replyError(id, code: -32601, message: "Method not found: \(method)") }
        }
    }

    // MARK: Tools

    private func toolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "list_transcripts",
                "description": "List the user's saved MindExtract transcripts (title, date, type, id). Use this to discover what's available before fetching one.",
                "inputSchema": ["type": "object", "properties": [String: Any]()]
            ],
            [
                "name": "search_transcripts",
                "description": "Full-text search across every saved transcript. Returns matching transcripts with a short snippet around the match. Use this to find where something was discussed.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["query": ["type": "string", "description": "Text to search for"]],
                    "required": ["query"]
                ]
            ],
            [
                "name": "get_transcript",
                "description": "Return the full text of one transcript, by its id (from list_transcripts/search_transcripts) or by exact title.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "Transcript id"],
                        "title": ["type": "string", "description": "Exact transcript title (alternative to id)"]
                    ]
                ]
            ]
        ]
    }

    private func handleToolCall(_ id: Any?, params: [String: Any]) {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        switch name {
        case "list_transcripts":
            let lines = loadItems().map { item in
                "• \(item.title) [id: \(item.id.uuidString)] — \(item.sourceType?.displayName ?? "Transcript"), \(Self.dateString(item.transcriptionDate))"
            }
            toolText(id, lines.isEmpty ? "No transcripts saved yet." : lines.joined(separator: "\n"))
        case "search_transcripts":
            guard let q = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else {
                toolText(id, "Provide a non-empty 'query'."); return
            }
            let hits = search(q)
            if hits.isEmpty { toolText(id, "No transcripts mention “\(q)”."); return }
            let out = hits.map { "## \($0.title) [id: \($0.id)]\n…\($0.snippet)…" }.joined(separator: "\n\n")
            toolText(id, out)
        case "get_transcript":
            let items = loadItems()
            let match: TranscriptionHistoryItem?
            if let idStr = args["id"] as? String {
                match = items.first { $0.id.uuidString == idStr }
            } else if let title = args["title"] as? String {
                match = items.first { $0.title.caseInsensitiveCompare(title) == .orderedSame }
            } else {
                match = nil
            }
            guard let item = match, let text = item.transcriptionText else {
                toolText(id, "Transcript not found. Use list_transcripts to see available ids/titles.", isError: true); return
            }
            toolText(id, "# \(item.title)\n\n\(text)")
        default:
            toolText(id, "Unknown tool: \(name)", isError: true)
        }
    }

    private func toolText(_ id: Any?, _ text: String, isError: Bool = false) {
        reply(id, ["content": [["type": "text", "text": text]], "isError": isError])
    }

    // MARK: Resources (each transcript as a readable resource)

    private func resourceList() -> [[String: Any]] {
        loadItems().map { item in
            [
                "uri": "mindextract://transcript/\(item.id.uuidString)",
                "name": item.title,
                "description": "\(item.sourceType?.displayName ?? "Transcript") · \(Self.dateString(item.transcriptionDate))",
                "mimeType": "text/plain"
            ]
        }
    }

    private func handleResourceRead(_ id: Any?, params: [String: Any]) {
        guard let uri = params["uri"] as? String,
              let parsed = URL(string: uri), parsed.scheme == "mindextract", parsed.host == "transcript",
              let item = loadItems().first(where: { $0.id.uuidString == parsed.lastPathComponent }),
              let text = item.transcriptionText else {
            replyError(id, code: -32602, message: "Resource not found"); return
        }
        reply(id, ["contents": [["uri": uri, "mimeType": "text/plain", "text": text]]])
    }

    // MARK: Data access (reads the same files the app writes)

    private var itemCache: [TranscriptionHistoryItem]?
    private var itemCacheTime: Date?

    private func loadItems() -> [TranscriptionHistoryItem] {
        // Reuse within a short window so a burst of tool calls doesn't re-decode
        // the history file each time.
        if let cache = itemCache, let t = itemCacheTime, Date().timeIntervalSince(t) < 5 { return cache }
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return [] }
        let url = base.appendingPathComponent("MindExtract/transcriptionHistory.json")
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([TranscriptionHistoryItem].self, from: data) else { return [] }
        let result = items.filter { $0.fileExists }
        itemCache = result; itemCacheTime = Date()
        return result
    }

    private struct Hit { let title: String; let id: String; let snippet: String }

    private func search(_ query: String) -> [Hit] {
        var hits: [Hit] = []
        for item in loadItems() {
            guard let text = item.transcriptionText else { continue }
            guard let range = text.range(of: query, options: .caseInsensitive) else { continue }
            let pad = 90
            let start = text.index(range.lowerBound, offsetBy: -pad, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: pad, limitedBy: text.endIndex) ?? text.endIndex
            let snippet = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
            hits.append(Hit(title: item.title, id: item.id.uuidString, snippet: snippet))
        }
        return hits
    }

    // MARK: JSON-RPC plumbing

    private func reply(_ id: Any?, _ result: [String: Any]) {
        guard let id else { return }   // don't respond to notifications
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func replyError(_ id: Any?, code: Int, message: String) {
        guard let id else { return }
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func send(_ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)   // newline-delimited; single atomic write to the real stdout
        out.write(data)
    }

    private func log(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8) ?? Data())
    }

    private func appVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private static func dateString(_ date: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }
}
