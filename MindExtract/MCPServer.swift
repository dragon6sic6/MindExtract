import Foundation

// MARK: - MCP server (stdio)
//
// Runs when MindExtract is launched with `--mcp` (Claude Desktop / any MCP client
// spawns it as a subprocess). Exposes the user's meetings, briefs, action items
// and people as MCP tools, resources and prompts — so an AI assistant can run
// workflows over them and file results into the user's own tools (Notion, Linear,
// Slack, a CRM…) via the assistant's own integrations. Fully local + READ-ONLY:
// the server only reads the on-device files the app writes; we upload nothing.
//
// Transport: newline-delimited JSON-RPC 2.0 over stdin/stdout. NOTHING may be
// written to stdout except protocol messages (logs go to stderr). Spec target:
// MCP revision 2025-06-18 (with back-compat negotiation for older clients).

enum MCPServer {
    static func run() {
        // Duplicate the REAL stdout to a private fd for protocol output, then point
        // fd 1 at /dev/null so any stray print()/library logging can't corrupt the
        // JSON-RPC stream. (freopen redirects fd 1 itself, which is why we dup first.)
        let realOut = dup(STDOUT_FILENO)
        // If dup fails we MUST NOT freopen — otherwise every reply goes to /dev/null
        // and the server looks hung to the client. Abort loudly on stderr instead.
        guard realOut >= 0 else {
            fputs("MindExtract MCP: dup(stdout) failed: \(String(cString: strerror(errno)))\n", stderr)
            exit(1)
        }
        freopen("/dev/null", "w", stdout)
        let out = FileHandle(fileDescriptor: realOut, closeOnDealloc: false)
        MCPServerImpl(out: out).serve()
    }
}

// NOTE: MCPServerImpl is single-threaded by design — serve() is the only entry
// point and runs a synchronous readLine loop. The caches below are therefore safe
// without locking; do not call its methods from a concurrent queue.
private final class MCPServerImpl {
    // Versions we speak, newest first. We echo the client's requested version when
    // we support it, else our latest (per the lifecycle spec).
    private let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    private var latestVersion: String { supportedVersions[0] }
    private let pageSize = 100
    private let maxQueryLength = 500
    private let maxTextOutput = 200_000   // cap tool text payloads (huge transcripts)
    private let out: FileHandle

    init(out: FileHandle) { self.out = out }

    func serve() {
        log("MindExtract MCP server started")
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) else {
                // Parse error: we have no id to attribute it to → null id (JSON-RPC).
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            // Be lenient about (removed) batch arrays: handle each element.
            if let batch = parsed as? [[String: Any]] {
                for m in batch { handleSafely(m) }
            } else if let msg = parsed as? [String: Any] {
                handleSafely(msg)
            }
            // Anything else (bare value) is ignored — never crash the loop.
        }
    }

    /// One malformed message must never take down the server.
    private func handleSafely(_ msg: [String: Any]) {
        handle(msg)
    }

    // MARK: Dispatch

    private func handle(_ msg: [String: Any]) {
        let method = msg["method"] as? String ?? ""
        let rawID = msg["id"]
        // A request has a string/number id. Absent or null ⇒ notification ⇒ no reply.
        let id: Any? = (rawID == nil || rawID is NSNull) ? nil : rawID

        switch method {
        case "initialize":
            let params = msg["params"] as? [String: Any] ?? [:]
            let requested = params["protocolVersion"] as? String
            let negotiated = (requested != nil && supportedVersions.contains(requested!)) ? requested! : latestVersion
            reply(id, [
                "protocolVersion": negotiated,
                "capabilities": [
                    "tools": ["listChanged": false],
                    "resources": [String: Any](),
                    "prompts": [String: Any](),
                    "completions": [String: Any]()
                ],
                "serverInfo": ["name": "mindextract", "title": "MindExtract", "version": appVersion()],
                "instructions": serverInstructions
            ])
        case "notifications/initialized", "notifications/cancelled", "notifications/roots/list_changed":
            break   // notifications: never respond
        case "ping":
            reply(id, [String: Any]())
        case "tools/list":
            reply(id, ["tools": toolDefinitions()])
        case "tools/call":
            handleToolCall(id, params: msg["params"] as? [String: Any] ?? [:])
        case "resources/list":
            let (items, next) = paginate(loadItems(), cursor: (msg["params"] as? [String: Any])?["cursor"] as? String)
            var result: [String: Any] = ["resources": items.map(resourceEntry)]
            if let next { result["nextCursor"] = next }
            reply(id, result)
        case "resources/templates/list":
            reply(id, ["resourceTemplates": resourceTemplates()])
        case "resources/read":
            handleResourceRead(id, params: msg["params"] as? [String: Any] ?? [:])
        case "prompts/list":
            reply(id, ["prompts": promptDefinitions()])
        case "prompts/get":
            handlePromptGet(id, params: msg["params"] as? [String: Any] ?? [:])
        case "completion/complete":
            handleCompletion(id, params: msg["params"] as? [String: Any] ?? [:])
        case "logging/setLevel":
            reply(id, [String: Any]())   // accepted; we log to stderr only
        default:
            if id != nil { replyError(id, code: -32601, message: "Method not found: \(method)") }
        }
    }

    private var serverInstructions: String {
        """
        Read-only, on-device access to the user's meetings, AI briefs, action items and people. Nothing is uploaded by this server.
        Discovery: call list_transcripts to see meetings/recordings. Use search_transcripts to find where a topic, decision or person was discussed.
        Detail: get_transcript = full text; get_meeting_brief = the structured AI summary (TL;DR, Decisions, Action items) — prefer this when filing a meeting into another tool.
        Workflows: list_action_items returns commitments as "- Owner — task (due)" grouped by meeting; list_people / get_person give relationship history. When the user wants to "file" or "send" results somewhere (Notion, Linear, Slack, a CRM, Reminders), use your OWN integrations for that destination and keep the source meeting noted for traceability.
        Prompts catch_me_up / prep_for / file_action_items provide ready-made workflows.
        """
    }

    // MARK: Tools

    private func readOnlyAnnotations(_ title: String) -> [String: Any] {
        ["title": title, "readOnlyHint": true, "destructiveHint": false,
         "idempotentHint": true, "openWorldHint": false]
    }

    private func toolDefinitions() -> [[String: Any]] {
        let stringArray: [String: Any] = ["type": "array", "items": ["type": "string"]]
        let meetingGroupSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "meetings": ["type": "array", "items": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string"], "title": ["type": "string"],
                        "date": ["type": "string"], "actionItems": stringArray
                    ]
                ]]
            ]
        ]
        let peopleSchema: [String: Any] = [
            "type": "object",
            "properties": ["people": ["type": "array", "items": [
                "type": "object",
                "properties": [
                    "name": ["type": "string"], "meetingCount": ["type": "integer"],
                    "lastMet": ["type": "string"]
                ]
            ]]]
        ]
        return [
            [
                "name": "list_transcripts",
                "title": "List Transcripts",
                "description": "List the user's saved transcripts and meeting recordings (title, date, type, id, whether an AI brief exists). Start here to discover what's available before fetching details.",
                "inputSchema": ["type": "object", "properties": [String: Any]()],
                "annotations": readOnlyAnnotations("List Transcripts")
            ],
            [
                "name": "search_transcripts",
                "title": "Search Transcripts",
                "description": "Full-text search across every saved transcript and meeting. Returns matches with a short snippet. Use to find where a topic, decision, or person was discussed.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["query": ["type": "string", "description": "Text to search for"]],
                    "required": ["query"]
                ],
                "annotations": readOnlyAnnotations("Search Transcripts")
            ],
            [
                "name": "get_transcript",
                "title": "Get Transcript",
                "description": "Return the full text of one transcript/meeting, by its id (from list_transcripts/search_transcripts) or exact title. For the AI summary instead, use get_meeting_brief.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "Transcript id"],
                        "title": ["type": "string", "description": "Exact transcript title (alternative to id)"]
                    ]
                ],
                "annotations": readOnlyAnnotations("Get Transcript")
            ],
            [
                "name": "get_meeting_brief",
                "title": "Get Meeting Brief",
                "description": "Return the AI Meeting Brief for one meeting — TL;DR, Decisions, and Action items — by id or exact title. This is the structured summary to file into the user's tools (Notion, Linear, Slack, a CRM…).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "Meeting/transcript id"],
                        "title": ["type": "string", "description": "Exact title (alternative to id)"]
                    ]
                ],
                "annotations": readOnlyAnnotations("Get Meeting Brief")
            ],
            [
                "name": "list_action_items",
                "title": "List Action Items",
                "description": "List action items / commitments from meeting briefs as '- Owner — task (due)' lines grouped by meeting. Pass an id to scope to one meeting, else returns recent meetings. Use to push tasks into the user's task/CRM tools.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["id": ["type": "string", "description": "Optional: limit to one meeting id"]]
                ],
                "outputSchema": meetingGroupSchema,
                "annotations": readOnlyAnnotations("List Action Items")
            ],
            [
                "name": "list_people",
                "title": "List People",
                "description": "List people the user has met (from meeting attendees and named speakers), with how many meetings and when they last met. Use to find who to prepare for or follow up with.",
                "inputSchema": ["type": "object", "properties": [String: Any]()],
                "outputSchema": peopleSchema,
                "annotations": readOnlyAnnotations("List People")
            ],
            [
                "name": "get_person",
                "title": "Get Person",
                "description": "Everything about meetings with one person (by name): their meetings (title, date, id) and the action items from those meetings. Use to prepare for a meeting or summarize a relationship.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["name": ["type": "string", "description": "Person's name (full or partial)"]],
                    "required": ["name"]
                ],
                "outputSchema": meetingGroupSchema,
                "annotations": readOnlyAnnotations("Get Person")
            ]
        ]
    }

    private func handleToolCall(_ id: Any?, params: [String: Any]) {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        switch name {
        case "list_transcripts":
            let lines = loadItems().map { item in
                "• \(item.title) [id: \(item.id.uuidString)] — \(item.sourceType?.displayName ?? "Transcript"), \(Self.dateString(item.transcriptionDate))\(briefText(item) != nil ? ", brief ✓" : "")"
            }
            toolText(id, lines.isEmpty ? "No transcripts saved yet." : lines.joined(separator: "\n"))
        case "search_transcripts":
            guard let q = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else {
                toolText(id, "Provide a non-empty 'query'.", isError: true); return
            }
            guard q.count <= maxQueryLength else {
                toolText(id, "Query too long (max \(maxQueryLength) characters).", isError: true); return
            }
            let hits = search(q)
            if hits.isEmpty { toolText(id, "No transcripts mention “\(q)”."); return }
            let outText = hits.map { "## \($0.title) [id: \($0.id)]\n…\($0.snippet)…" }.joined(separator: "\n\n")
            toolText(id, outText)
        case "get_transcript":
            guard let item = matchItem(args) else {
                toolText(id, "Transcript not found. Use list_transcripts to see ids/titles.", isError: true); return
            }
            guard let text = item.transcriptionText else {
                toolText(id, "Transcript file is missing on disk.", isError: true); return
            }
            toolText(id, truncated("# \(item.title)\n\n\(text)"))
        case "get_meeting_brief":
            guard let item = matchItem(args) else {
                toolText(id, "Meeting not found. Use list_transcripts to see ids/titles.", isError: true); return
            }
            guard let brief = briefText(item) else {
                toolText(id, "No AI brief exists for “\(item.title)” yet. Use get_transcript for the raw text.", isError: true); return
            }
            toolText(id, "# \(item.title) — Brief\n_\(Self.dateString(item.transcriptionDate))_\n\n\(brief)")
        case "list_action_items":
            let scope = matchItem(args).map { [$0] } ?? Array(meetingItems().prefix(15))
            var structured: [[String: Any]] = []
            var blocks: [String] = []
            for item in scope {
                guard let brief = briefText(item) else { continue }
                let section = MeetingMemory.briefSection(brief, "Action items").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !section.isEmpty, section.lowercased() != "- none", section.lowercased() != "none" else { continue }
                let lines = section.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                blocks.append("## \(item.title)  [id: \(item.id.uuidString)] — \(Self.dateString(item.transcriptionDate))\n\(section)")
                structured.append(["id": item.id.uuidString, "title": item.title,
                                   "date": Self.dateString(item.transcriptionDate), "actionItems": lines])
            }
            toolResult(id, text: blocks.isEmpty ? "No action items found in recent meeting briefs." : blocks.joined(separator: "\n\n"),
                       structured: ["meetings": structured])
        case "list_people":
            let people = peopleIndex()
            let lines = people.map { "• \($0.name) — \($0.meetings.count) meeting\($0.meetings.count == 1 ? "" : "s"), last \(Self.dateString($0.lastMet))" }
            let structured = people.map { ["name": $0.name, "meetingCount": $0.meetings.count, "lastMet": Self.dateString($0.lastMet)] as [String: Any] }
            toolResult(id, text: people.isEmpty ? "No named people yet — people come from meeting attendees and named speakers." : lines.joined(separator: "\n"),
                       structured: ["people": structured])
        case "get_person":
            guard let q = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else {
                toolText(id, "Provide a 'name'.", isError: true); return
            }
            guard let p = bestPersonMatch(q) else {
                toolText(id, "No one matching “\(q)”. Use list_people."); return
            }
            var outText = "# \(p.name)\n\(p.meetings.count) meetings · last \(Self.dateString(p.lastMet))\n"
            var structured: [[String: Any]] = []
            for m in p.meetings.sorted(by: { $0.transcriptionDate > $1.transcriptionDate }) {
                outText += "\n## \(m.title)  [id: \(m.id.uuidString)] — \(Self.dateString(m.transcriptionDate))"
                var lines: [String] = []
                if let brief = briefText(m) {
                    let acts = MeetingMemory.briefSection(brief, "Action items").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !acts.isEmpty, acts.lowercased() != "- none", acts.lowercased() != "none" {
                        outText += "\n\(acts)"
                        lines = acts.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
                }
                structured.append(["id": m.id.uuidString, "title": m.title,
                                   "date": Self.dateString(m.transcriptionDate), "actionItems": lines])
            }
            toolResult(id, text: truncated(outText), structured: ["meetings": structured])
        default:
            toolText(id, "Unknown tool: \(name)", isError: true)
        }
    }

    private func toolText(_ id: Any?, _ text: String, isError: Bool = false) {
        reply(id, ["content": [["type": "text", "text": text]], "isError": isError])
    }

    /// Result carrying both human-readable text and machine-readable structuredContent.
    private func toolResult(_ id: Any?, text: String, structured: [String: Any]) {
        reply(id, [
            "content": [["type": "text", "text": text]],
            "structuredContent": structured,
            "isError": false
        ])
    }

    /// Resolve a meeting/transcript from {id} or {title} arguments.
    private func matchItem(_ args: [String: Any]) -> TranscriptionHistoryItem? {
        let items = loadItems()
        if let idStr = args["id"] as? String, !idStr.isEmpty { return items.first { $0.id.uuidString == idStr } }
        if let title = args["title"] as? String, !title.isEmpty { return items.first { $0.title.caseInsensitiveCompare(title) == .orderedSame } }
        return nil
    }

    private func briefText(_ item: TranscriptionHistoryItem) -> String? {
        guard let sidecar = TranscriptAIStore.load(for: item.filePath),
              let brief = sidecar.templateOutputs?[PromptTemplateLibrary.meetingBriefID.uuidString]?.text,
              !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return brief
    }

    private func meetingItems() -> [TranscriptionHistoryItem] {
        loadItems()
            .filter { $0.sourceType == .meeting || $0.sourceType == nil }
            .sorted { $0.transcriptionDate > $1.transcriptionDate }
    }

    private struct PersonRef { let name: String; var meetings: [TranscriptionHistoryItem]; var lastMet: Date }

    /// Match a person by exact name, then substring, then shared-token overlap —
    /// so "Anna", "Anna Lindqvist" and "Lindqvist" all resolve sensibly, without a
    /// short query wrongly swallowing a longer name.
    private func bestPersonMatch(_ query: String) -> PersonRef? {
        let people = peopleIndex()
        let ql = query.lowercased()
        if let exact = people.first(where: { $0.name.lowercased() == ql }) { return exact }
        if let sub = people.first(where: { $0.name.lowercased().contains(ql) }) { return sub }
        let qTokens = Set(ql.split { !$0.isLetter }.map(String.init).filter { $0.count > 1 })
        guard !qTokens.isEmpty else { return nil }
        return people
            .map { (p: $0, overlap: Set($0.name.lowercased().split { !$0.isLetter }.map(String.init)).intersection(qTokens).count) }
            .filter { $0.overlap > 0 }
            .max { $0.overlap < $1.overlap }?.p
    }

    private func peopleIndex() -> [PersonRef] {
        var map: [String: PersonRef] = [:]
        for item in meetingItems() {
            guard let sidecar = TranscriptAIStore.load(for: item.filePath) else { continue }
            for name in Self.attendees(sidecar) {
                let key = name.lowercased()
                if var ref = map[key] {
                    ref.meetings.append(item); ref.lastMet = max(ref.lastMet, item.transcriptionDate); map[key] = ref
                } else {
                    map[key] = PersonRef(name: name, meetings: [item], lastMet: item.transcriptionDate)
                }
            }
        }
        return map.values.sorted { $0.lastMet > $1.lastMet }
    }

    private static func attendees(_ sidecar: TranscriptAISidecar) -> [String] {
        func isDefault(_ s: String) -> Bool {
            let t = s.trimmingCharacters(in: .whitespaces).lowercased()
            if t.isEmpty || ["you", "others", "unknown", "speaker", "guest"].contains(t) { return true }
            return t.range(of: #"^speaker\s*\d+$"#, options: .regularExpression) != nil
        }
        var names: [String] = []; var seen = Set<String>()
        for raw in (sidecar.speakerSuggestions ?? []) + Array((sidecar.speakerNames ?? [:]).values) {
            let n = raw.trimmingCharacters(in: .whitespaces)
            guard !isDefault(n), seen.insert(n.lowercased()).inserted else { continue }
            names.append(n)
        }
        return names
    }

    // MARK: Resources

    private func resourceEntry(_ item: TranscriptionHistoryItem) -> [String: Any] {
        [
            "uri": "mindextract://transcript/\(item.id.uuidString)",
            "name": item.title,
            "title": item.title,
            "description": "\(item.sourceType?.displayName ?? "Transcript") · \(Self.dateString(item.transcriptionDate))",
            "mimeType": "text/plain"
        ]
    }

    private func resourceTemplates() -> [[String: Any]] {
        [[
            "uriTemplate": "mindextract://transcript/{id}",
            "name": "transcript",
            "title": "Transcript by id",
            "description": "Full text of a transcript by its id (see list_transcripts).",
            "mimeType": "text/plain"
        ]]
    }

    private func handleResourceRead(_ id: Any?, params: [String: Any]) {
        // Match strictly against loaded item ids — never resolve to an arbitrary path.
        guard let uri = params["uri"] as? String,
              let parsed = URL(string: uri), parsed.scheme == "mindextract", parsed.host == "transcript",
              let item = loadItems().first(where: { $0.id.uuidString == parsed.lastPathComponent }),
              let text = item.transcriptionText else {
            replyError(id, code: -32002, message: "Resource not found"); return
        }
        reply(id, ["contents": [["uri": uri, "mimeType": "text/plain", "text": text]]])
    }

    // MARK: Prompts

    private func promptDefinitions() -> [[String: Any]] {
        [
            ["name": "catch_me_up", "title": "Catch me up",
             "description": "Summarize recent meetings and list everything still open, then offer to file items into your tools."],
            ["name": "prep_for", "title": "Prep for a person",
             "description": "Build a pre-meeting brief for a person: last discussion, open items both ways, recurring topics.",
             "arguments": [["name": "person", "description": "Who you're meeting", "required": true]]],
            ["name": "file_action_items", "title": "File action items",
             "description": "Take a meeting's action items and file them into your connected tools (Notion, Linear, Slack, Reminders…).",
             "arguments": [["name": "meeting", "description": "Meeting title or id", "required": true]]]
        ]
    }

    private func handlePromptGet(_ id: Any?, params: [String: Any]) {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        let text: String
        switch name {
        case "catch_me_up":
            text = "Using the MindExtract tools, catch me up: call list_transcripts, then get_meeting_brief for my most recent meetings, and list_action_items across them. Give me a tight summary of what happened and a single consolidated list of open action items grouped by meeting. Then ask whether I want to file any of them into my connected tools."
        case "prep_for":
            let person = (args["person"] as? String) ?? "the person"
            text = "Use get_person(name: \"\(person)\") to pull every meeting and action item I have with \(person). Then write a concise pre-meeting brief: what we discussed last time, what's still open on my side and theirs, and the topics that keep recurring. Keep it to what the data supports — don't invent."
        case "file_action_items":
            let meeting = (args["meeting"] as? String) ?? "the meeting"
            text = "Get the action items for \"\(meeting)\" using list_action_items (or get_meeting_brief). Then help me file each one into the right connected tool — Notion, Linear, Slack, a CRM, or Reminders — using your own integrations. Confirm the destination with me before creating anything, and keep the source meeting noted for traceability."
        default:
            replyError(id, code: -32602, message: "Unknown prompt: \(name)"); return
        }
        reply(id, ["messages": [["role": "user", "content": ["type": "text", "text": text]]]])
    }

    // MARK: Completion (argument autocompletion)

    private func handleCompletion(_ id: Any?, params: [String: Any]) {
        let ref = params["ref"] as? [String: Any] ?? [:]
        let arg = params["argument"] as? [String: Any] ?? [:]
        let refType = ref["type"] as? String ?? ""
        let refName = ref["name"] as? String ?? ""
        let argName = arg["name"] as? String ?? ""
        let value = (arg["value"] as? String ?? "").lowercased()

        var values: [String] = []
        if refType == "ref/prompt", refName == "prep_for", argName == "person" {
            values = peopleIndex().map(\.name)
        } else if refType == "ref/prompt", refName == "file_action_items", argName == "meeting" {
            values = meetingItems().map(\.title)
        } else if refType == "ref/resource", argName == "id" {
            values = loadItems().map { $0.id.uuidString }
        }
        if !value.isEmpty { values = values.filter { $0.lowercased().contains(value) } }
        let limited = Array(values.prefix(100))
        reply(id, ["completion": ["values": limited, "total": values.count, "hasMore": values.count > limited.count]])
    }

    // MARK: Data access (reads the same files the app writes)

    private var itemCache: [TranscriptionHistoryItem]?
    private var itemCacheTime: Date?
    private var itemCacheMTime: Date?

    private var historyURL: URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return nil }
        return base.appendingPathComponent("MindExtract/transcriptionHistory.json")
    }

    private func loadItems() -> [TranscriptionHistoryItem] {
        guard let url = historyURL else { return [] }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        // Serve the cache only if the file hasn't changed AND within a short window
        // (so a concurrent GUI write is picked up promptly).
        if let cache = itemCache, let t = itemCacheTime, Date().timeIntervalSince(t) < 5,
           mtime == itemCacheMTime {
            return cache
        }
        let items: [TranscriptionHistoryItem]
        do {
            let data = try Data(contentsOf: url)
            items = try JSONDecoder().decode([TranscriptionHistoryItem].self, from: data)
        } catch {
            // A torn write mid-save or a missing file: reuse the last good snapshot
            // rather than reporting "no transcripts", and log for diagnosis.
            log("loadItems: \(error.localizedDescription)")
            return itemCache ?? []
        }
        // Defense-in-depth: confine reads to the user's home directory (transcripts
        // legitimately live in several places — the app's Recordings folder, Downloads,
        // user-chosen folders). Standardizing collapses any ".." so a tampered history
        // can't escape to system paths like /etc.
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let result = items.filter { item in
            guard item.fileExists else { return false }
            return URL(fileURLWithPath: item.filePath).standardizedFileURL.path.hasPrefix(home)
        }
        itemCache = result; itemCacheTime = Date(); itemCacheMTime = mtime
        return result
    }

    private struct Hit { let title: String; let id: String; let snippet: String }

    private func search(_ query: String) -> [Hit] {
        let maxScan = 1_000_000      // cap per-transcript scan to avoid pathological cost
        let maxHits = 50
        var hits: [Hit] = []
        for item in loadItems() {
            guard let full = item.transcriptionText else { continue }
            let text = full.count > maxScan ? String(full.prefix(maxScan)) : full
            guard let range = text.range(of: query, options: .caseInsensitive) else { continue }
            let pad = 90
            let start = text.index(range.lowerBound, offsetBy: -pad, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: pad, limitedBy: text.endIndex) ?? text.endIndex
            let snippet = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
            hits.append(Hit(title: item.title, id: item.id.uuidString, snippet: snippet))
            if hits.count >= maxHits { break }
        }
        return hits
    }

    /// Opaque offset-based cursor pagination.
    private func paginate<T>(_ all: [T], cursor: String?) -> (page: [T], next: String?) {
        let offset = cursor.flatMap(Int.init).map { max(0, $0) } ?? 0
        guard offset < all.count else { return ([], nil) }
        let end = min(offset + pageSize, all.count)
        let next = end < all.count ? String(end) : nil
        return (Array(all[offset..<end]), next)
    }

    // MARK: JSON-RPC plumbing

    private func reply(_ id: Any?, _ result: [String: Any]) {
        guard let id else { return }   // never respond to notifications
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func replyError(_ id: Any?, code: Int, message: String) {
        guard let id else { return }
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func send(_ obj: [String: Any]) {
        // JSONSerialization can throw on non-conforming objects; never crash, never
        // recurse (the offending id might be what failed). Emit one safe error.
        guard JSONSerialization.isValidJSONObject(obj),
              let payload = try? JSONSerialization.data(withJSONObject: obj) else {
            log("send: failed to serialize response; emitting fallback error")
            if let fb = try? JSONSerialization.data(withJSONObject:
                ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32603, "message": "Internal error"]] as [String: Any]) {
                var d = fb; d.append(0x0A); out.write(d)
            }
            return
        }
        var data = payload
        data.append(0x0A)   // newline-delimited; single atomic write to the real stdout
        out.write(data)
    }

    private func log(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8) ?? Data())
    }

    private func appVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private func truncated(_ text: String) -> String {
        guard text.count > maxTextOutput else { return text }
        return String(text.prefix(maxTextOutput)) + "\n\n[… truncated — \(text.count) total characters. Fetch the resource or narrow your request for the rest.]"
    }

    // DateFormatter is costly to build; reuse one (server loop is single-threaded).
    private static let sharedDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    private static func dateString(_ date: Date) -> String {
        sharedDateFormatter.string(from: date)
    }
}
