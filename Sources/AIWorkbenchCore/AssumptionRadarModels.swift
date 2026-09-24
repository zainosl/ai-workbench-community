import Foundation

public enum FiveStepKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case demand = "需求"
    case solution = "解决方案"
    case unitModel = "单元模型"
    case growth = "增长"
    case moat = "壁垒"

    public var id: String { rawValue }
    public var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public static func from(assumptionID: String) -> FiveStepKind {
        if assumptionID.hasPrefix("D") { return .demand }
        if assumptionID.hasPrefix("S-") || assumptionID.hasPrefix("C") { return .solution }
        if assumptionID.hasPrefix("B-") { return .unitModel }
        if assumptionID.hasPrefix("G") { return .growth }
        return .moat
    }

    public static func from(stageName: String?) -> FiveStepKind? {
        guard let stageName else { return nil }
        if stageName.contains("单元模型") || stageName.contains("商业模式") { return .unitModel }
        return allCases.first { stageName.contains($0.rawValue) }
    }
}

public enum AssumptionActivationRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case primary
    case supporting
    case monitoring
    case dependencyBlocked
    case resourceLocked

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .primary: return "主验证"
        case .supporting: return "随行取证"
        case .monitoring: return "反证监测"
        case .dependencyBlocked: return "依赖阻塞"
        case .resourceLocked: return "资源未解锁"
        }
    }

    public var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

public struct AssumptionNode: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let stage: FiveStepKind
    public let level: String
    public let sourceStatus: String
    public let dependencyIDs: [String]
    public let dependencyDescription: String
    public let dependencyType: String
    public let summary: String
    public let failureImpact: String
    public let currentAction: String
    public let decisionGate: String
    public let role: AssumptionActivationRole
    public let activationReason: String
    public let selectionOrder: Int

    public init(
        id: String,
        title: String,
        stage: FiveStepKind,
        level: String,
        sourceStatus: String,
        dependencyIDs: [String],
        dependencyDescription: String,
        dependencyType: String,
        summary: String,
        failureImpact: String,
        currentAction: String,
        decisionGate: String,
        role: AssumptionActivationRole,
        activationReason: String,
        selectionOrder: Int
    ) {
        self.id = id
        self.title = title
        self.stage = stage
        self.level = level
        self.sourceStatus = sourceStatus
        self.dependencyIDs = dependencyIDs
        self.dependencyDescription = dependencyDescription
        self.dependencyType = dependencyType
        self.summary = summary
        self.failureImpact = failureImpact
        self.currentAction = currentAction
        self.decisionGate = decisionGate
        self.role = role
        self.activationReason = activationReason
        self.selectionOrder = selectionOrder
    }
}

public struct BusinessMilestoneSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let decisionToUnlock: String
    public let currentStage: String
    public let requiredAssumptionIDs: [String]
    public let unlockedResources: [String]
    public let lockedResources: [String]

    public init(
        id: String,
        title: String,
        decisionToUnlock: String,
        currentStage: String,
        requiredAssumptionIDs: [String],
        unlockedResources: [String],
        lockedResources: [String]
    ) {
        self.id = id
        self.title = title
        self.decisionToUnlock = decisionToUnlock
        self.currentStage = currentStage
        self.requiredAssumptionIDs = requiredAssumptionIDs
        self.unlockedResources = unlockedResources
        self.lockedResources = lockedResources
    }
}

public struct AssumptionRadarSnapshot: Codable, Equatable, Sendable {
    public let businessContextVersion: String
    public let assumptionVersion: String
    public let milestone: BusinessMilestoneSnapshot
    public let executionTracks: [ExecutionTrack]
    public let assumptions: [AssumptionNode]
    public let originalPoolCount: Int
    public let contentFingerprint: String
    public let scannedAt: Date

    public init(
        businessContextVersion: String,
        assumptionVersion: String,
        milestone: BusinessMilestoneSnapshot,
        executionTracks: [ExecutionTrack],
        assumptions: [AssumptionNode],
        originalPoolCount: Int,
        contentFingerprint: String,
        scannedAt: Date = Date()
    ) {
        self.businessContextVersion = businessContextVersion
        self.assumptionVersion = assumptionVersion
        self.milestone = milestone
        self.executionTracks = executionTracks
        self.assumptions = assumptions
        self.originalPoolCount = originalPoolCount
        self.contentFingerprint = contentFingerprint
        self.scannedAt = scannedAt
    }

    public var activeAssumptions: [AssumptionNode] {
        assumptions.filter { $0.role == .primary || $0.role == .supporting }
    }

    public func assumptions(in stage: FiveStepKind) -> [AssumptionNode] {
        assumptions.filter { $0.stage == stage }
    }

    public func count(for role: AssumptionActivationRole) -> Int {
        assumptions.filter { $0.role == role }.count
    }
}
