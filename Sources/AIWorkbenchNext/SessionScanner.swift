import AIWorkbenchCore
import Foundation

struct SessionScanResult {
    var tasks: [CodexTask]
}

enum SessionScanner {
    private static var activeSessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    private static var archivedSessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/archived_sessions", isDirectory: true)
    }

    private struct ThreadCatalogRow: Decodable {
        let id: String
        let title: String?
        let name: String?
        let cwd: String?
        let rollout_path: String?
        let updated_at: Int64?
        let tokens_used: Int64?
        let archived: Int?
        let preview: String?
    }

    private struct ConversationState {
        var isGoalTask = false
        var goalStatus: String?
        var goalObjective: String?
        var userMessages: [String] = []
    }

    private struct TailState {
        var lastTaskComplete = -1
        var lastTaskStarted = -1
        var lastTaskAborted = -1
        var lastUserMessage = -1
        var lastWaitingRequest = -1
        var lastWaitingResolution = -1
        var hasSystemError = false
        var waitingPrompt: String?
        var resultSummary: String?
        var completionRevision: String?
        var latestActivity: String?
        var isWaiting: Bool { lastWaitingRequest > lastWaitingResolution }
        var isRunning: Bool { lastTaskStarted > max(lastTaskComplete, lastTaskAborted) }
    }

    static func scan(limit: Int = 120, candidateFloor: Int = 160) -> SessionScanResult {
        scanSessionRoots(
            [activeSessionsRoot],
            limit: limit,
            candidateFloor: candidateFloor
        )
    }

    /// Scans one or more physical Codex session stores. Normal live refreshes
    /// intentionally use only the active store; explicit historical indexing
    /// also includes `archived_sessions`, where Codex moves the full rollout
    /// after `set_thread_archived` is called.
    private static func scanSessionRoots(
        _ roots: [URL],
        limit: Int,
        candidateFloor: Int
    ) -> SessionScanResult {
        let titles = loadThreadTitles()
        let archivedIDs = archivedThreadIDs()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        var files: [(URL, Date)] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: keys)
                guard values?.isRegularFile == true else { continue }
                files.append((url, values?.contentModificationDate ?? .distantPast))
            }
        }
        files.sort { $0.1 > $1.1 }

        // 首屏只需要最近任务。限制扫描文件数，避免历史会话增长后阻塞整个面板。
        let candidates = Array(files.prefix(max(limit, candidateFloor)))
        var seen = Set<String>()
        var all = candidates.compactMap {
            readSession(url: $0.0, modified: $0.1, titles: titles, archivedIDs: archivedIDs)
        }
            .filter { seen.insert($0.id).inserted }
        let recent = Array(all.prefix(limit))
        let totals = Dictionary(grouping: all, by: \CodexTask.projectKey)
            .mapValues { $0.reduce(Int64(0)) { $0 + $1.totalTokens } }
        all = recent
        for index in all.indices {
            all[index].projectTokens = totals[all[index].projectKey] ?? all[index].totalTokens
        }
        return SessionScanResult(tasks: all)
    }

    /// Reads every locally retained Codex session once. This is intentionally
    /// used only by explicit/startup context indexing; the three-second live
    /// status loop continues to use the small active-session scan above.
    /// Archived rollouts remain historical context and never become live state.
    static func scanAll() -> SessionScanResult {
        let sessionTasks = scanSessionRoots(
            [activeSessionsRoot, archivedSessionsRoot],
            limit: .max,
            candidateFloor: .max
        ).tasks
        var merged = Dictionary(uniqueKeysWithValues: catalogTasks().map { ($0.id, $0) })
        for task in sessionTasks { merged[task.id] = task }
        var tasks = merged.values.sorted { $0.updatedAt > $1.updatedAt }
        let totals = Dictionary(grouping: tasks, by: \CodexTask.projectKey)
            .mapValues { $0.reduce(Int64(0)) { $0 + $1.totalTokens } }
        for index in tasks.indices {
            tasks[index].projectTokens = totals[tasks[index].projectKey] ?? tasks[index].totalTokens
        }
        return SessionScanResult(tasks: tasks)
    }

    /// Codex's SQLite catalog remains authoritative for old tasks whose rollout
    /// file has been migrated or removed. The catalog supplies lightweight
    /// historical cards; a live rollout, when present, replaces this record.
    private static func catalogTasks() -> [CodexTask] {
        let database = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/state_5.sqlite")
        guard FileManager.default.fileExists(atPath: database.path),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else { return [] }

        let query = """
        SELECT id, title, name, cwd, rollout_path, updated_at, tokens_used, archived, preview
        FROM threads ORDER BY updated_at DESC;
        """
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-json", database.path, query]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let rows = try JSONDecoder().decode([ThreadCatalogRow].self, from: data)
            return rows.compactMap { row in
                let cwd = row.cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let path = row.rollout_path ?? ""
                let projectKey = cwd.isEmpty
                    ? URL(fileURLWithPath: path).deletingLastPathComponent().path
                    : cwd
                let component = URL(fileURLWithPath: projectKey).lastPathComponent
                // `name` is the current user-visible title in modern Codex.
                // `title` remains the original prompt-derived fallback.
                let currentName = row.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = cleanTitle(currentName.isEmpty ? (row.title ?? "") : currentName, maximum: 120)
                guard !row.id.isEmpty else { return nil }
                return CodexTask(
                    id: row.id,
                    title: title.isEmpty ? "未命名任务" : title,
                    projectName: component.isEmpty ? "Codex" : component,
                    projectKey: projectKey,
                    path: path,
                    // Catalog-only records do not expose a stable completion
                    // turn ID. Treat them as historical/idle so an old preview
                    // can never masquerade as a newly completed result.
                    status: .idle,
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(row.updated_at ?? 0)),
                    totalTokens: row.tokens_used ?? 0,
                    projectTokens: row.tokens_used ?? 0,
                    contextTokens: 0,
                    contextWindow: 0,
                    waitingPrompt: nil,
                    resultSummary: cleanSummary(row.preview ?? ""),
                    latestActivity: cleanSummary(row.preview ?? ""),
                    completionRevision: nil,
                    isArchived: row.archived == 1
                )
            }
        } catch {
            return []
        }
    }

    static func task(id: String) -> CodexTask? {
        guard !id.isEmpty else { return nil }
        let titles = loadThreadTitles()
        let archivedIDs = archivedThreadIDs()
        for root in [activeSessionsRoot, archivedSessionsRoot] {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator
                where url.pathExtension == "jsonl" && url.deletingPathExtension().lastPathComponent.hasSuffix(id) {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return readSession(url: url, modified: modified, titles: titles, archivedIDs: archivedIDs)
            }
        }
        return nil
    }

    /// Reads Codex's append-only title index without reopening every rollout.
    /// This makes an outside rename visible even when the renamed conversation
    /// is old and its session file modification date did not change.
    static func currentThreadTitles() -> [String: String] {
        loadThreadTitles()
    }

    /// Codex's thread catalog is authoritative for archive state. Archive and
    /// unarchive do not modify rollout files, so this must be checked independently
    /// from the session modification date used by the live activity scanner.
    static func archivedThreadIDs() -> Set<String> {
        let database = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/state_5.sqlite")
        guard FileManager.default.fileExists(atPath: database.path),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else { return [] }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, "SELECT id FROM threads WHERE archived = 1;"]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let value = String(data: data, encoding: .utf8) else { return [] }
            return Set(value.split(whereSeparator: \.isNewline).map(String.init))
        } catch {
            return []
        }
    }

    private static func readSession(
        url: URL,
        modified: Date,
        titles: [String: String],
        archivedIDs: Set<String>
    ) -> CodexTask? {
        let prefix = readPrefix(url: url, maximumBytes: 96_000)
        let tail = readTail(url: url, maximumBytes: 320_000)
        var id = url.deletingPathExtension().lastPathComponent
        var cwd = ""
        var title = ""
        var foundCurrentSessionMeta = false

        for line in prefix.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any] else { continue }
            // Forked Codex sessions can embed the parent's session_meta directly
            // after their own. The first record belongs to this file; later ones
            // are history and must never replace the current task identity.
            if type == "session_meta", !foundCurrentSessionMeta {
                id = payload["id"] as? String ?? id
                cwd = payload["cwd"] as? String ?? cwd
                foundCurrentSessionMeta = true
            }
            if type == "event_msg", payload["type"] as? String == "user_message", title.isEmpty {
                let candidate = cleanTitle(payload["message"] as? String ?? "")
                if !isBoilerplate(candidate) { title = candidate }
            }
        }
        if let indexed = titles[id], !indexed.isEmpty { title = cleanTitle(indexed, maximum: 120) }

        let token = tokenSnapshot(in: tail)
        let state = inspectTail(tail)
        let conversation = inspectConversation(prefix: prefix, tail: tail)
        if title.isEmpty, let firstMessage = conversation.userMessages.first {
            title = cleanTitle(firstMessage)
        }
        let isArchived = archivedIDs.contains(id)
        // Archive is a stronger lifecycle signal than an incomplete rollout
        // tail. Keep the task as history, but never surface it as live work.
        let status = isArchived ? CodexTaskStatus.idle : inferStatus(state: state, modified: modified)
        let projectKey = cwd.isEmpty ? url.deletingLastPathComponent().path : cwd
        let component = URL(fileURLWithPath: projectKey).lastPathComponent
        let projectName = component.isEmpty ? "Codex" : component
        if title.isEmpty { title = "未命名任务" }
        let titleSuggestion = conversation.isGoalTask
            ? ConversationTitleSynthesizer.suggest(
                existingTitle: title,
                goalObjective: conversation.goalObjective,
                userMessages: conversation.userMessages
            )
            : nil

        return CodexTask(
            id: id,
            title: title,
            projectName: projectName,
            projectKey: projectKey,
            path: url.path,
            status: status,
            updatedAt: modified,
            totalTokens: token.totalTokens,
            projectTokens: token.totalTokens,
            contextTokens: token.contextTokens,
            contextWindow: token.contextWindow,
            waitingPrompt: !isArchived && state.isWaiting ? (state.waitingPrompt ?? "这个任务正在等待你的选择") : nil,
            resultSummary: state.resultSummary,
            latestActivity: state.latestActivity,
            completionRevision: state.completionRevision,
            isGoalTask: conversation.isGoalTask,
            goalStatus: conversation.goalStatus,
            automaticTitleSuggestion: titleSuggestion?.title,
            titleContentRevision: titleSuggestion?.contentRevision,
            titleMessageCount: titleSuggestion?.messageCount ?? 0,
            isArchived: isArchived
        )
    }

    private static func inspectConversation(prefix: Data, tail: Data) -> ConversationState {
        var state = ConversationState()
        var seenLines = Set<Data>()
        var seenMessages = Set<String>()

        for data in [prefix, tail] {
            for rawLine in data.split(separator: 0x0A) {
                let line = Data(rawLine)
                guard seenLines.insert(line).inserted,
                      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let type = object["type"] as? String,
                      let payload = object["payload"] as? [String: Any] else { continue }

                if type == "event_msg" {
                    let event = payload["type"] as? String ?? ""
                    if event == "thread_goal_updated", let goal = payload["goal"] as? [String: Any] {
                        state.isGoalTask = true
                        state.goalStatus = goal["status"] as? String
                        if let objective = goal["objective"] as? String {
                            state.goalObjective = objective
                        }
                    } else if event == "thread_goal_cleared" {
                        state.isGoalTask = true
                        state.goalStatus = "cleared"
                    } else if event == "user_message", let message = payload["message"] as? String {
                        appendUserMessage(message, to: &state, seen: &seenMessages)
                    }
                }

                if type == "response_item",
                   payload["type"] as? String == "message",
                   payload["role"] as? String == "user" {
                    let content = payload["content"] as? [[String: Any]] ?? []
                    let message = content.compactMap { item -> String? in
                        let kind = item["type"] as? String ?? ""
                        guard kind == "input_text" || kind == "output_text" else { return nil }
                        return item["text"] as? String
                    }.joined(separator: "\n")
                    appendUserMessage(message, to: &state, seen: &seenMessages)
                }
            }
        }
        return state
    }

    private static func appendUserMessage(
        _ raw: String,
        to state: inout ConversationState,
        seen: inout Set<String>
    ) {
        guard let message = ConversationTitleSynthesizer.cleanMessage(raw),
              seen.insert(message).inserted else { return }
        state.userMessages.append(message)
    }

    private static func tokenSnapshot(in tail: Data) -> TokenSnapshot {
        for line in tail.split(separator: 0x0A).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any] else { continue }
            let total = info["total_token_usage"] as? [String: Any]
            let last = info["last_token_usage"] as? [String: Any]
            return TokenSnapshot(
                totalTokens: AppServerClient.int64(total?["total_tokens"]) ?? 0,
                contextTokens: AppServerClient.int64(last?["total_tokens"]) ?? 0,
                contextWindow: AppServerClient.int64(info["model_context_window"]) ?? 0
            )
        }
        return TokenSnapshot()
    }

    private static func loadThreadTitles() -> [String: String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/session_index.jsonl")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        var output: [String: String] = [:]
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = object["id"] as? String,
                  let raw = object["thread_name"] as? String else { continue }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { output[id] = value }
        }
        return output
    }

    private static func inferStatus(state: TailState, modified: Date) -> CodexTaskStatus {
        if state.isWaiting { return .waiting }
        if state.hasSystemError { return .error }
        if state.isRunning { return .running }
        if Date().timeIntervalSince(modified) < 150 {
            if state.lastUserMessage > state.lastTaskComplete || state.lastTaskComplete < 0 { return .running }
        }
        if state.lastTaskComplete >= 0 { return .completed }
        return .idle
    }

    private static func inspectTail(_ data: Data) -> TailState {
        var state = TailState()
        for (index, line) in data.split(separator: 0x0A).enumerated() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any] else { continue }
            if type == "event_msg" {
                let event = payload["type"] as? String ?? ""
                if event == "task_started" || event == "turn_started" {
                    state.lastTaskStarted = index
                } else if event == "turn_aborted" {
                    state.lastTaskAborted = index
                } else if event == "task_complete" || event == "turn_complete" {
                    state.lastTaskComplete = index
                    state.completionRevision = (payload["turn_id"] as? String)
                        ?? (object["timestamp"] as? String)
                        ?? "completion-\(index)"
                    if let message = payload["last_agent_message"] as? String {
                        state.resultSummary = cleanSummary(message)
                    }
                }
                else if event == "user_message" {
                    state.lastUserMessage = index
                    state.lastWaitingResolution = max(state.lastWaitingResolution, index)
                } else if event == "agent_message",
                          let message = (payload["message"] as? String) ?? (payload["last_agent_message"] as? String) {
                    state.latestActivity = cleanSummary(message)
                } else if event == "system_error" || event == "turn_failed" { state.hasSystemError = true }
            }
            if type == "response_item" {
                let item = payload["type"] as? String ?? ""
                if item == "function_call" {
                    let name = payload["name"] as? String ?? ""
                    if name.hasSuffix("request_user_input") || name == "request_user_input" {
                        state.lastWaitingRequest = index
                        state.waitingPrompt = promptFromArguments(payload["arguments"])
                    }
                } else if item == "function_call_output" || item == "custom_tool_call_output" {
                    state.lastWaitingResolution = max(state.lastWaitingResolution, index)
                }
            }
        }
        return state
    }

    private static func cleanSummary(_ raw: String) -> String? {
        let lines = raw.replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "#", with: "").replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { line in
                let isControlTag = line.hasPrefix("<") && line.hasSuffix(">") && !line.contains(" ")
                return !line.isEmpty && !line.hasPrefix("[") && !line.hasPrefix("依据：") && !isControlTag
            }
        let preferredPrefixes = ["一句话判断", "最终判断", "当前判断", "核心结论", "最终结论"]
        let preferred = lines.first { line in
            preferredPrefixes.contains { line.hasPrefix($0) }
        }
        let genericHeadings: Set<String> = ["修正版", "完成", "已完成", "结果", "总结", "最终结果"]
        let first = preferred ?? lines.first { line in
            !genericHeadings.contains(line) && !line.contains("结论被替代")
        }
        guard let first else { return nil }
        return first.count <= 96 ? first : String(first.prefix(96)) + "…"
    }

    private static func promptFromArguments(_ raw: Any?) -> String? {
        let object: [String: Any]?
        if let string = raw as? String, let data = string.data(using: .utf8) {
            object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } else { object = raw as? [String: Any] }
        guard let object else { return nil }
        if let questions = object["questions"] as? [[String: Any]],
           let question = questions.first?["question"] as? String { return cleanTitle(question, maximum: 54) }
        if let question = object["question"] as? String { return cleanTitle(question, maximum: 54) }
        return nil
    }

    private static func cleanTitle(_ raw: String, maximum: Int = 32) -> String {
        let first = raw.replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n").map(String.init)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
        let clean = first.replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count <= maximum ? clean : String(clean.prefix(maximum)) + "…"
    }

    private static func isBoilerplate(_ title: String) -> Bool {
        let value = title.lowercased()
        return value.hasPrefix("files mentioned by the user") || value.hasPrefix("environment_context") ||
            value.hasPrefix("recommended_plugins") || value.hasPrefix("image_resize_notice") ||
            value.hasPrefix("<app-context") || value.hasPrefix("<developer") ||
            value.hasPrefix("distinguish instructions")
    }

    private static func readPrefix(url: URL, maximumBytes: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: maximumBytes)) ?? Data()
    }

    private static func readTail(url: URL, maximumBytes: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
        try? handle.seek(toOffset: offset)
        var data = (try? handle.readToEnd()) ?? Data()
        if offset > 0, let newline = data.firstIndex(of: 0x0A) { data.removeSubrange(...newline) }
        return data
    }
}
