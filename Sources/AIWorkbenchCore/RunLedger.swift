import Foundation

public enum RunLedgerError: LocalizedError {
    case cannotEncodeEvent
    case cannotCreateLogFile

    public var errorDescription: String? {
        switch self {
        case .cannotEncodeEvent: return "无法编码运行日志"
        case .cannotCreateLogFile: return "无法创建运行日志文件"
        }
    }
}

public final class RunLedger: @unchecked Sendable {
    public let rootURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "local.aiworkbench.next.run-ledger")

    public init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL
        self.fileManager = fileManager
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    @discardableResult
    public func beginRun(
        trigger: String,
        contextVersion: String? = nil,
        details: [String: String] = [:]
    ) throws -> String {
        let runID = "run-" + UUID().uuidString.lowercased()
        try append(RunEvent(
            runID: runID,
            phase: .trigger,
            summary: trigger,
            details: details,
            contextVersion: contextVersion,
            ruleIDs: ["RUN-001"]
        ))
        return runID
    }

    public func append(_ event: RunEvent) throws {
        try queue.sync {
            guard var data = try? CoreCoding.encoder().encode(event) else {
                throw RunLedgerError.cannotEncodeEvent
            }
            data.append(0x0A)
            let url = logURL(for: event.timestamp)
            if !fileManager.fileExists(atPath: url.path) {
                guard fileManager.createFile(atPath: url.path, contents: nil) else {
                    throw RunLedgerError.cannotCreateLogFile
                }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
    }

    public func events(runID: String? = nil, since: Date? = nil, limit: Int = 300) throws -> [RunEvent] {
        try queue.sync {
            let files = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
                .filter { $0.pathExtension == "jsonl" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            var output: [RunEvent] = []
            for file in files {
                let data = try Data(contentsOf: file)
                for line in data.split(separator: 0x0A) {
                    guard let event = try? CoreCoding.decoder().decode(RunEvent.self, from: Data(line)) else { continue }
                    if let runID, event.runID != runID { continue }
                    if let since, event.timestamp < since { continue }
                    output.append(event)
                }
            }
            output.sort { $0.timestamp < $1.timestamp }
            return Array(output.suffix(max(0, limit)))
        }
    }

    public func purge(olderThan cutoff: Date) throws {
        try queue.sync {
            let files = try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.contentModificationDateKey])
            for file in files where file.pathExtension == "jsonl" {
                let values = try file.resourceValues(forKeys: [.contentModificationDateKey])
                if let modified = values.contentModificationDate, modified < cutoff {
                    try fileManager.removeItem(at: file)
                }
            }
        }
    }

    private func logURL(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return rootURL.appendingPathComponent("events-\(formatter.string(from: date)).jsonl")
    }
}
