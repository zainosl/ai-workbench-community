import Foundation
import Darwin

enum AppServerError: LocalizedError {
    case executableMissing
    case notRunning
    case malformedResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .executableMissing: return "未找到 Codex 本机程序"
        case .notRunning: return "Codex 本机服务未运行"
        case .malformedResponse: return "Codex 返回了无法识别的数据"
        case .server(let message): return message
        }
    }
}

struct AppServerTaskDraftResult {
    let threadID: String
}

final class AppServerClient {
    typealias JSONObject = [String: Any]
    typealias Completion = (Result<JSONObject, Error>) -> Void

    var onNotification: ((String, JSONObject) -> Void)?
    private let queue = DispatchQueue(label: "local.aiworkbench.next.appserver")
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: Completion] = [:]

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            if self.process?.isRunning == true {
                DispatchQueue.main.async { completion(.success(())) }
                return
            }
            guard let executable = Self.resolveExecutable() else {
                DispatchQueue.main.async { completion(.failure(AppServerError.executableMissing)) }
                return
            }

            let process = Process()
            let input = Pipe()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = executable.lastPathComponent == "env"
                ? ["codex", "app-server", "--stdio"]
                : ["app-server", "--stdio"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self?.queue.async { self?.consume(data) }
            }
            process.terminationHandler = { [weak self] _ in
                self?.queue.async { self?.failPending(AppServerError.notRunning) }
            }

            do {
                try process.run()
                self.process = process
                self.inputPipe = input
                self.outputPipe = output
                self.sendRequest(method: "initialize", params: [
                    "clientInfo": [
                        "name": "ai-workbench-next",
                        "title": "AI Workbench Next",
                    "version": "0.21.1"
                    ],
                    "capabilities": ["experimentalApi": true]
                ]) { result in
                    switch result {
                    case .success:
                        self.sendNotification(method: "initialized", params: [:])
                        DispatchQueue.main.async { completion(.success(())) }
                    case .failure(let error):
                        DispatchQueue.main.async { completion(.failure(error)) }
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        queue.async {
            guard let process = self.process else {
                if let completion { DispatchQueue.main.async { completion() } }
                return
            }

            // Closing stdin is app-server's graceful shutdown path. Terminating
            // it directly can leave a materialized thread loaded indefinitely,
            // which prevents the desktop app from taking ownership of the draft.
            try? self.inputPipe?.fileHandleForWriting.close()
            self.inputPipe = nil

            DispatchQueue.global(qos: .utility).async {
                if !Self.waitForExit(process, timeout: 2.0) {
                    process.interrupt()
                }
                if !Self.waitForExit(process, timeout: 1.0) {
                    process.terminate()
                }
                if !Self.waitForExit(process, timeout: 1.0) {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()

                self.queue.async {
                    self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                    self.process = nil
                    self.outputPipe = nil
                    self.buffer.removeAll(keepingCapacity: false)
                    self.failPending(AppServerError.notRunning)
                    if let completion { DispatchQueue.main.async { completion() } }
                }
            }
        }
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !process.isRunning
    }

    func sendRequest(method: String, params: JSONObject = [:], completion: @escaping Completion) {
        queue.async {
            guard self.process?.isRunning == true else {
                DispatchQueue.main.async { completion(.failure(AppServerError.notRunning)) }
                return
            }
            let id = self.nextID
            self.nextID += 1
            self.pending[id] = completion
            self.write(["id": id, "method": method, "params": params])
        }
    }

    /// Creates and names a persisted Codex task without starting a turn.
    /// The desktop app receives the prompt separately as an editable draft.
    func prepareTaskDraft(
        title: String,
        cwd: String,
        completion: @escaping (Result<AppServerTaskDraftResult, Error>) -> Void
    ) {
        sendRequest(method: "thread/start", params: [
            "cwd": cwd,
            "approvalPolicy": "never",
            "sandbox": "readOnly",
            "personality": "pragmatic",
            "serviceName": "ai-workbench-community",
            "ephemeral": false
        ]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let payload):
                guard let thread = payload["thread"] as? JSONObject,
                      let threadID = thread["id"] as? String,
                      !threadID.isEmpty else {
                    completion(.failure(AppServerError.malformedResponse))
                    return
                }
                self.sendRequest(method: "thread/name/set", params: [
                    "threadId": threadID,
                    "name": title
                ]) { nameResult in
                    switch nameResult {
                    case .failure(let error): completion(.failure(error))
                    case .success:
                        // `thread/start` registers the thread in SQLite but does
                        // not materialize its rollout file until the first item
                        // is persisted. Opening that half-created thread in the
                        // desktop app produces `rollout path ... does not exist`.
                        // Persist an empty assistant item so the task is durable
                        // while the user's real prompt remains an editable draft.
                        self.sendRequest(method: "thread/inject_items", params: [
                            "threadId": threadID,
                            "items": [[
                                "type": "message",
                                "role": "assistant",
                                "content": [[
                                    "type": "output_text",
                                    "text": ""
                                ]]
                            ]]
                        ]) { materializeResult in
                            switch materializeResult {
                            case .failure(let error): completion(.failure(error))
                            case .success: completion(.success(AppServerTaskDraftResult(threadID: threadID)))
                            }
                        }
                    }
                }
            }
        }
    }

    func setTaskName(
        threadID: String,
        title: String,
        completion: @escaping Completion
    ) {
        sendRequest(method: "thread/name/set", params: [
            "threadId": threadID,
            "name": title
        ], completion: completion)
    }

    private func sendNotification(method: String, params: JSONObject) {
        queue.async { self.write(["method": method, "params": params]) }
    }

    private func write(_ object: JSONObject) {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        do { try inputPipe?.fileHandleForWriting.write(contentsOf: data) }
        catch { failPending(error) }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? JSONObject else { continue }
            handle(object)
        }
    }

    private func handle(_ object: JSONObject) {
        if let id = Self.int(object["id"]), let completion = pending.removeValue(forKey: id) {
            if let error = object["error"] as? JSONObject {
                let message = error["message"] as? String ?? "Codex 本机服务请求失败"
                DispatchQueue.main.async { completion(.failure(AppServerError.server(message))) }
            } else if let result = object["result"] as? JSONObject {
                DispatchQueue.main.async { completion(.success(result)) }
            } else {
                DispatchQueue.main.async { completion(.failure(AppServerError.malformedResponse)) }
            }
            return
        }
        if let method = object["method"] as? String {
            let params = object["params"] as? JSONObject ?? [:]
            DispatchQueue.main.async { [weak self] in self?.onNotification?(method, params) }
        }
    }

    private func failPending(_ error: Error) {
        let callbacks = pending.values
        pending.removeAll()
        callbacks.forEach { callback in DispatchQueue.main.async { callback(.failure(error)) } }
    }

    static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }

    private static func resolveExecutable() -> URL? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.isExecutableFile(atPath: "/usr/bin/env")
            ? URL(fileURLWithPath: "/usr/bin/env")
            : nil
    }
}
