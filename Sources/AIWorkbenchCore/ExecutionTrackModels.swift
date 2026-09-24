import Foundation

public struct ExecutionTrack: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let assumptionIDs: [String]
    public let decisionImpact: String
    public let currentSample: String
    public let confidence: String
    public let learningGoal: String
    public let minimumAction: String
    public let successGate: String
    public let failureGate: String
    public let grayAction: String
    public let order: Int

    public init(
        id: String,
        title: String,
        assumptionIDs: [String],
        decisionImpact: String,
        currentSample: String,
        confidence: String,
        learningGoal: String,
        minimumAction: String,
        successGate: String,
        failureGate: String,
        grayAction: String,
        order: Int
    ) {
        self.id = id
        self.title = title
        self.assumptionIDs = assumptionIDs
        self.decisionImpact = decisionImpact
        self.currentSample = currentSample
        self.confidence = confidence
        self.learningGoal = learningGoal
        self.minimumAction = minimumAction
        self.successGate = successGate
        self.failureGate = failureGate
        self.grayAction = grayAction
        self.order = order
    }
}

public enum TaskAssociationSource: String, Codable, Sendable {
    case workbenchDispatch
    case userConfirmed
    case historicalDetected
    case manualImport
}

/// Only deterministic links are persisted here. Historical-task guesses remain suggestions in the UI.
public struct TaskAssociationRecord: Codable, Identifiable, Equatable, Sendable {
    public let taskID: String
    public let trackID: String
    public let primaryAssumptionID: String?
    public let supportingAssumptionIDs: [String]
    public let businessContextVersion: String
    public let source: TaskAssociationSource
    public let createdAt: Date

    public var id: String { taskID }

    public init(
        taskID: String,
        trackID: String,
        primaryAssumptionID: String?,
        supportingAssumptionIDs: [String],
        businessContextVersion: String,
        source: TaskAssociationSource,
        createdAt: Date = Date()
    ) {
        self.taskID = taskID
        self.trackID = trackID
        self.primaryAssumptionID = primaryAssumptionID
        self.supportingAssumptionIDs = supportingAssumptionIDs
        self.businessContextVersion = businessContextVersion
        self.source = source
        self.createdAt = createdAt
    }
}

public final class TaskAssociationStore: @unchecked Sendable {
    public let fileURL: URL
    private let queue = DispatchQueue(label: "local.aiworkbench.next.task-associations")

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> [TaskAssociationRecord] {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
            return try CoreCoding.decoder().decode([TaskAssociationRecord].self, from: Data(contentsOf: fileURL))
        }
    }

    public func save(_ records: [TaskAssociationRecord]) throws {
        try queue.sync {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try CoreCoding.encoder(pretty: true).encode(records).write(to: fileURL, options: .atomic)
        }
    }
}
