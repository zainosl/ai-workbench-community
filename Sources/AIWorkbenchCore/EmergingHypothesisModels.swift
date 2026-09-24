import Foundation

public enum EmergingHypothesisHandling: String, Codable, CaseIterable, Sendable {
    case mergedMain = "并入当前主验证"
    case accompanyingEvidence = "随主实验取证"
    case dependencyObservation = "依赖观察"
    case implementationObservation = "实现层观察，不独立开主实验"
    case unknown = "待分类"

    public var shortTitle: String {
        switch self {
        case .mergedMain: return "主验证"
        case .accompanyingEvidence: return "随行取证"
        case .dependencyObservation: return "依赖观察"
        case .implementationObservation: return "实现优化"
        case .unknown: return "待分类"
        }
    }

    public static func from(_ value: String) -> Self {
        if value.contains("并入") && value.contains("主验证") { return .mergedMain }
        if value.contains("随主实验") || value.contains("随行取证") { return .accompanyingEvidence }
        if value.contains("依赖观察") { return .dependencyObservation }
        if value.contains("实现层") || value.contains("实现优化") { return .implementationObservation }
        return .unknown
    }
}

/// Decides whether a hypothesis should create a task at all and what that task
/// must deliver. This is intentionally separate from `handling`: handling
/// describes its relationship to the business model, while execution mode
/// describes the shortest route to discriminating real-world evidence.
public enum EmergingHypothesisExecutionMode: String, Codable, CaseIterable, Sendable {
    case followsMain = "跟随主线"
    case directExperiment = "直接实验"
    case humanExecutionPackage = "人工执行包"
    case embeddedEvidence = "嵌入取证"
    case dependencyBlocked = "等待依赖"
    case unknown = "待设计"

    public var shortTitle: String { rawValue }

    public var canCreateTask: Bool {
        self == .directExperiment || self == .humanExecutionPackage
    }

    public static func from(_ value: String, handling: EmergingHypothesisHandling) -> Self {
        if value.contains("直接实验") { return .directExperiment }
        if value.contains("人工执行") { return .humanExecutionPackage }
        if value.contains("嵌入取证") { return .embeddedEvidence }
        if value.contains("等待依赖") || value.contains("依赖阻塞") { return .dependencyBlocked }
        if value.contains("跟随主线") { return .followsMain }
        switch handling {
        case .mergedMain: return .followsMain
        case .dependencyObservation: return .dependencyBlocked
        case .accompanyingEvidence: return .humanExecutionPackage
        case .implementationObservation: return .directExperiment
        case .unknown: return .unknown
        }
    }
}

public struct EmergingHypothesisObservation: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let statement: String
    public let businessStage: String
    public let relatedAssumptionIDs: [String]
    public let relationDescription: String
    public let handling: EmergingHypothesisHandling
    public let executionMode: EmergingHypothesisExecutionMode
    /// Stable identity for one concrete validation cycle. A hypothesis can
    /// keep its ID while later cycles create new work and preserve old tasks.
    public let executionKey: String
    public let priority: Int
    public let minimumEvidenceAction: String
    public let decisionGate: String
    public let promotionGate: String
    public let sourceTaskIDs: [String]

    public init(
        id: String,
        statement: String,
        businessStage: String,
        relatedAssumptionIDs: [String],
        relationDescription: String,
        handling: EmergingHypothesisHandling,
        executionMode: EmergingHypothesisExecutionMode,
        executionKey: String,
        priority: Int,
        minimumEvidenceAction: String,
        decisionGate: String,
        promotionGate: String,
        sourceTaskIDs: [String]
    ) {
        self.id = id
        self.statement = statement
        self.businessStage = businessStage
        self.relatedAssumptionIDs = relatedAssumptionIDs
        self.relationDescription = relationDescription
        self.handling = handling
        self.executionMode = executionMode
        self.executionKey = executionKey
        self.priority = priority
        self.minimumEvidenceAction = minimumEvidenceAction
        self.decisionGate = decisionGate
        self.promotionGate = promotionGate
        self.sourceTaskIDs = sourceTaskIDs
    }

    public var executionActionID: String {
        "emerging:\(id):\(executionKey)"
    }
}

public struct EmergingHypothesisSnapshot: Codable, Equatable, Sendable {
    public let version: String
    public let observations: [EmergingHypothesisObservation]
    public let contentFingerprint: String
    public let scannedAt: Date

    public init(
        version: String,
        observations: [EmergingHypothesisObservation],
        contentFingerprint: String,
        scannedAt: Date = Date()
    ) {
        self.version = version
        self.observations = observations
        self.contentFingerprint = contentFingerprint
        self.scannedAt = scannedAt
    }
}
