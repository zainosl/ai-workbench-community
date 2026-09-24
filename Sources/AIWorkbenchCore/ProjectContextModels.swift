import CryptoKit
import Foundation

public struct ProjectContextSnapshot: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let rootPath: String
    public let currentState: String
    public let currentStage: String
    public let nextDecision: String
    public let completedItems: [String]
    public let candidateDirections: [String]
    public let unknowns: [String]
    public let communicationGuidance: [String]
    public let privacyLevel: String
    public let sourcePaths: [String]
    public let contentFingerprint: String
    public let scannedAt: Date

    public init(
        id: String,
        displayName: String,
        rootPath: String,
        currentState: String,
        currentStage: String,
        nextDecision: String,
        completedItems: [String],
        candidateDirections: [String],
        unknowns: [String],
        communicationGuidance: [String],
        privacyLevel: String,
        sourcePaths: [String],
        contentFingerprint: String,
        scannedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.rootPath = rootPath
        self.currentState = currentState
        self.currentStage = currentStage
        self.nextDecision = nextDecision
        self.completedItems = completedItems
        self.candidateDirections = candidateDirections
        self.unknowns = unknowns
        self.communicationGuidance = communicationGuidance
        self.privacyLevel = privacyLevel
        self.sourcePaths = sourcePaths
        self.contentFingerprint = contentFingerprint
        self.scannedAt = scannedAt
    }
}

public enum ProjectContextError: LocalizedError {
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path): return "无法读取项目资料：\(path)"
        }
    }
}

/// Reads structured project records without making the project type part of the workbench domain model.
public enum ProjectContextScanner {
    public static func scan(
        id: String,
        displayName: String,
        rootPath: String,
        overviewURL: URL,
        progressURL: URL,
        preferenceURL: URL,
        assumptionsURL: URL,
        resultURL: URL
    ) throws -> ProjectContextSnapshot {
        let urls = [overviewURL, progressURL, preferenceURL, assumptionsURL, resultURL]
        let documents = try urls.map { url -> String in
            guard let value = try? String(contentsOf: url, encoding: .utf8) else {
                throw ProjectContextError.unreadable(url.path)
            }
            return value
        }
        return parse(
            id: id,
            displayName: displayName,
            rootPath: rootPath,
            overview: documents[0],
            progress: documents[1],
            preferences: documents[2],
            assumptions: documents[3],
            result: documents[4],
            sourcePaths: urls.map(\.path)
        )
    }

    public static func parse(
        id: String,
        displayName: String,
        rootPath: String,
        overview: String,
        progress: String,
        preferences: String,
        assumptions: String,
        result: String,
        sourcePaths: [String]
    ) -> ProjectContextSnapshot {
        let combined = [overview, progress, preferences, assumptions, result].joined(separator: "\n---\n")
        let fingerprint = SHA256.hash(data: Data(combined.utf8)).map { String(format: "%02x", $0) }.joined()
        let currentState = metadata(named: "当前状态", in: overview)
        let privacy = metadata(named: "隐私级别", in: overview)
        let stage = firstTableValue(label: "当前阶段", in: overview) ?? "待识别"
        let humanDecisionRow = firstTableRow(containing: "待真人介入", in: progress)
        let activeRow = tableRows(in: progress).first { row in
            row.contains(where: { $0.contains("进行中") || $0.contains("待确认") || $0.contains("尚未完成") })
        } ?? []
        let nextDecision = humanDecisionRow.last ?? activeRow.last ?? "等待下一步决策"

        let completed = tableRows(in: progress)
            .filter { $0.count >= 3 && $0[1].contains("完成") }
            .map { $0[0].replacingOccurrences(of: "第一步：", with: "").replacingOccurrences(of: "第二步：", with: "").replacingOccurrences(of: "第三步：", with: "") }

        let directions = result.components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("### 0"), let divider = trimmed.range(of: "｜") else { return nil }
            let number = trimmed.dropFirst(4)[...].split(separator: "｜").first.map(String.init) ?? ""
            let title = String(trimmed[divider.upperBound...]).trimmingCharacters(in: .whitespaces)
            return number.isEmpty ? title : "M\(number) \(title)"
        }

        let unknowns = tableRows(in: result)
            .filter { $0.count >= 2 && $0[0] == "当前未知" }
            .map { $0[1] }

        let guidance = tableRows(in: preferences)
            .filter { $0.count >= 2 && $0[0] != "偏好" }
            .prefix(4)
            .map { "\($0[0])：\($0[1])" }

        return ProjectContextSnapshot(
            id: id,
            displayName: displayName,
            rootPath: rootPath,
            currentState: currentState.isEmpty ? stage : currentState,
            currentStage: stage,
            nextDecision: nextDecision,
            completedItems: Array(completed.prefix(5)),
            candidateDirections: directions,
            unknowns: Array(unknowns.prefix(5)),
            communicationGuidance: Array(guidance),
            privacyLevel: privacy,
            sourcePaths: sourcePaths,
            contentFingerprint: fingerprint
        )
    }

    private static func metadata(named name: String, in markdown: String) -> String {
        let prefix = "\(name)："
        for line in markdown.components(separatedBy: .newlines).prefix(30) {
            let value = line.trimmingCharacters(in: CharacterSet(charactersIn: "> "))
            if value.hasPrefix(prefix) { return String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        }
        return ""
    }

    private static func firstTableValue(label: String, in markdown: String) -> String? {
        tableRows(in: markdown).first { $0.first == label }.flatMap { $0.count > 1 ? $0[1] : nil }
    }

    private static func firstTableRow(containing value: String, in markdown: String) -> [String] {
        tableRows(in: markdown).first { $0.contains(where: { $0.contains(value) }) } ?? []
    }

    private static func tableRows(in markdown: String) -> [[String]] {
        markdown.components(separatedBy: .newlines).compactMap { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("|"), value.hasSuffix("|") else { return nil }
            let cells = value.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" } }) else { return nil }
            return cells
        }
    }
}

public struct HypothesisTaskAssociationRecord: Codable, Identifiable, Equatable, Sendable {
    public let taskID: String
    public let projectID: String
    public let primaryAssumptionID: String
    public let supportingAssumptionIDs: [String]
    public let businessContextVersion: String
    public let projectContextFingerprint: String
    public let source: TaskAssociationSource
    public let relationship: TaskAssociationRelationship?
    public let actionID: String?
    public let createdAt: Date

    public var id: String { taskID }

    public init(
        taskID: String,
        projectID: String,
        primaryAssumptionID: String,
        supportingAssumptionIDs: [String],
        businessContextVersion: String,
        projectContextFingerprint: String,
        source: TaskAssociationSource,
        relationship: TaskAssociationRelationship = .execution,
        actionID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.taskID = taskID
        self.projectID = projectID
        self.primaryAssumptionID = primaryAssumptionID
        self.supportingAssumptionIDs = supportingAssumptionIDs
        self.businessContextVersion = businessContextVersion
        self.projectContextFingerprint = projectContextFingerprint
        self.source = source
        self.relationship = relationship
        self.actionID = actionID
        self.createdAt = createdAt
    }

    public var effectiveRelationship: TaskAssociationRelationship { relationship ?? .execution }
}

public enum TaskAssociationRelationship: String, Codable, Sendable {
    case contextSource
    case execution
}

public final class HypothesisTaskAssociationStore: @unchecked Sendable {
    public let fileURL: URL
    private let queue = DispatchQueue(label: "local.aiworkbench.next.hypothesis-task-associations")

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() throws -> [HypothesisTaskAssociationRecord] {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
            return try CoreCoding.decoder().decode([HypothesisTaskAssociationRecord].self, from: Data(contentsOf: fileURL))
        }
    }

    public func save(_ records: [HypothesisTaskAssociationRecord]) throws {
        try queue.sync {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try CoreCoding.encoder(pretty: true).encode(records).write(to: fileURL, options: .atomic)
        }
    }
}

/// A durable parent → child edge between two Codex tasks. This is independent
/// from assumptions so the same chain model can be used from every task card.
public struct TaskChainRecord: Codable, Identifiable, Equatable, Sendable {
    public let parentTaskID: String
    public let childTaskID: String
    public let userDefinedGoal: String
    public let createdAt: Date

    public var id: String { "\(parentTaskID)->\(childTaskID)" }

    public init(
        parentTaskID: String,
        childTaskID: String,
        userDefinedGoal: String,
        createdAt: Date = Date()
    ) {
        self.parentTaskID = parentTaskID
        self.childTaskID = childTaskID
        self.userDefinedGoal = userDefinedGoal
        self.createdAt = createdAt
    }
}

public final class TaskChainStore: @unchecked Sendable {
    public let fileURL: URL
    private let queue = DispatchQueue(label: "local.aiworkbench.next.task-chains")

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() throws -> [TaskChainRecord] {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
            return try CoreCoding.decoder().decode([TaskChainRecord].self, from: Data(contentsOf: fileURL))
        }
    }

    public func save(_ records: [TaskChainRecord]) throws {
        try queue.sync {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try CoreCoding.encoder(pretty: true).encode(records).write(to: fileURL, options: .atomic)
        }
    }
}
