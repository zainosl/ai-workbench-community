import Foundation

public enum RunEventLevel: String, Codable, CaseIterable, Sendable {
    case info
    case notice
    case warning
    case error
}

public enum RunEventPhase: String, Codable, CaseIterable, Sendable {
    case trigger
    case context
    case rule
    case decision
    case execution
    case result
    case learning
    case deposit
    case userAction
    case diagnostic
    case system
}

public struct RunEvent: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let runID: String
    public let timestamp: Date
    public let level: RunEventLevel
    public let phase: RunEventPhase
    public let summary: String
    public let details: [String: String]
    public let contextVersion: String?
    public let ruleIDs: [String]

    public init(
        id: UUID = UUID(),
        runID: String,
        timestamp: Date = Date(),
        level: RunEventLevel = .info,
        phase: RunEventPhase,
        summary: String,
        details: [String: String] = [:],
        contextVersion: String? = nil,
        ruleIDs: [String] = []
    ) {
        self.id = id
        self.runID = runID
        self.timestamp = timestamp
        self.level = level
        self.phase = phase
        self.summary = summary
        self.details = details
        self.contextVersion = contextVersion
        self.ruleIDs = ruleIDs
    }

    public func redacted(homePath: String = FileManager.default.homeDirectoryForCurrentUser.path) -> RunEvent {
        let blockedFragments = ["prompt", "message", "content", "secret", "token", "password", "authorization"]
        let safeDetails = details.reduce(into: [String: String]()) { output, item in
            let lowered = item.key.lowercased()
            if blockedFragments.contains(where: lowered.contains) {
                output[item.key] = "[已脱敏]"
            } else {
                output[item.key] = item.value.replacingOccurrences(of: homePath, with: "$USER_HOME")
            }
        }
        return RunEvent(
            id: id,
            runID: runID,
            timestamp: timestamp,
            level: level,
            phase: phase,
            summary: summary.replacingOccurrences(of: homePath, with: "$USER_HOME"),
            details: safeDetails,
            contextVersion: contextVersion,
            ruleIDs: ruleIDs
        )
    }
}

public struct WorkbenchRule: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var category: String
    public var reason: String
    public var trigger: String
    public var action: String
    public var exceptions: String
    public var requiresApproval: Bool
    public var enabled: Bool
    public var version: Int

    public init(
        id: String,
        name: String,
        category: String,
        reason: String,
        trigger: String,
        action: String,
        exceptions: String = "无",
        requiresApproval: Bool = false,
        enabled: Bool = true,
        version: Int = 1
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.reason = reason
        self.trigger = trigger
        self.action = action
        self.exceptions = exceptions
        self.requiresApproval = requiresApproval
        self.enabled = enabled
        self.version = version
    }
}

public struct BusinessStage: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let definition: String
    public let status: String
    public let currentAction: String

    public init(id: String, name: String, definition: String, status: String, currentAction: String) {
        self.id = id
        self.name = name
        self.definition = definition
        self.status = status
        self.currentAction = currentAction
    }
}

public struct BusinessContextSnapshot: Codable, Equatable, Sendable {
    public let sourcePath: String
    public let version: String
    public let calibratedAt: String
    public let businessModelSummary: String
    public let progressSummary: String
    public let stages: [BusinessStage]
    public let mainStageID: String?
    public let parallelStageIDs: [String]
    public let nextStageID: String?
    public let contentFingerprint: String
    public let demandUserSummary: String?
    public let demandTaskSummary: String?
    public let demandExclusionSummary: String?
    public let scannedAt: Date

    public init(
        sourcePath: String,
        version: String,
        calibratedAt: String,
        businessModelSummary: String = "",
        progressSummary: String,
        stages: [BusinessStage],
        mainStageID: String?,
        parallelStageIDs: [String],
        nextStageID: String?,
        contentFingerprint: String,
        demandUserSummary: String? = nil,
        demandTaskSummary: String? = nil,
        demandExclusionSummary: String? = nil,
        scannedAt: Date = Date()
    ) {
        self.sourcePath = sourcePath
        self.version = version
        self.calibratedAt = calibratedAt
        self.businessModelSummary = businessModelSummary
        self.progressSummary = progressSummary
        self.stages = stages
        self.mainStageID = mainStageID
        self.parallelStageIDs = parallelStageIDs
        self.nextStageID = nextStageID
        self.contentFingerprint = contentFingerprint
        self.demandUserSummary = demandUserSummary
        self.demandTaskSummary = demandTaskSummary
        self.demandExclusionSummary = demandExclusionSummary
        self.scannedAt = scannedAt
    }

    public var mainStage: BusinessStage? { stages.first { $0.id == mainStageID } }
    public var parallelStages: [BusinessStage] { stages.filter { parallelStageIDs.contains($0.id) } }
    public var nextStage: BusinessStage? { stages.first { $0.id == nextStageID } }
    public var contextVersion: String { version.isEmpty ? String(contentFingerprint.prefix(10)) : version }
}

public struct DiagnosticManifest: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let appVersion: String
    public let logicVersion: String
    public let selectedRunID: String?
    public let eventCount: Int
    public let businessContextVersion: String?
    public let privacyMode: String
}

enum CoreCoding {
    static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if pretty { encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
