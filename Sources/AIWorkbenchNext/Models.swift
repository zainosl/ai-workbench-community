import AIWorkbenchCore
import Foundation
import SwiftUI

struct QuotaMetric: Identifiable, Equatable {
    let id: String
    let icon: String
    let remainingPercent: Int
    let label: String
    let resetAt: Date?
}

struct WorkbenchUpdateProgress: Equatable {
    let assumptionID: String?
    let startedAt: Date
    var step: Int
    var totalSteps: Int
    var title: String
    var detail: String
    var percent: Int

    var stepLabel: String { "第 \(step) / \(totalSteps) 步" }
}

enum WorkbenchUpdateKind: String, Codable {
    case business
    case assumption
}

struct WorkbenchUpdateReceipt: Codable, Equatable {
    let kind: WorkbenchUpdateKind
    let scopeID: String
    let completedAt: Date
    let summary: String
    let changedAreas: [String]
    let sourceCount: Int
    let changedSourceCount: Int
    let relatedTaskCount: Int
    let contextVersion: String?
    let runID: String

    var relativeTime: String {
        let seconds = max(0, Int(Date().timeIntervalSince(completedAt)))
        if seconds < 60 { return "刚刚" }
        if seconds < 3_600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86_400 { return "\(seconds / 3_600) 小时前" }
        return "\(seconds / 86_400) 天前"
    }

    var changeLabel: String {
        let visibleChangeCount = max(changedSourceCount, changedAreas.count)
        return visibleChangeCount == 0 ? "无变化" : "\(visibleChangeCount) 处变化"
    }
}

enum WorkbenchOperationScope: String, Equatable {
    case item
    case workspace
}

struct WorkbenchOperationState: Identifiable, Equatable {
    let key: String
    let title: String
    let detail: String
    let scope: WorkbenchOperationScope
    let targetTaskID: String?
    let startedAt: Date

    var id: String { key }
}

enum CodexTaskStatus: String, Codable, CaseIterable {
    case running
    case waiting
    case completed
    case idle
    case error

    var title: String {
        switch self {
        case .running: return "运行中"
        case .waiting: return "等待回复"
        case .completed: return "已完成"
        case .idle: return "空闲"
        case .error: return "异常"
        }
    }

    var icon: String {
        switch self {
        case .running: return "circle.fill"
        case .waiting: return "clock"
        case .completed: return "checkmark.circle"
        case .idle: return "pause.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .running: return WorkbenchPalette.mint
        case .waiting: return WorkbenchPalette.amber
        case .completed, .idle: return .secondary
        case .error: return WorkbenchPalette.coral
        }
    }
}

struct CodexTask: Identifiable, Equatable {
    let id: String
    var title: String
    var projectName: String
    var projectKey: String
    var path: String
    var status: CodexTaskStatus
    var updatedAt: Date
    var totalTokens: Int64
    var projectTokens: Int64
    var contextTokens: Int64
    var contextWindow: Int64
    var waitingPrompt: String?
    var resultSummary: String?
    var latestActivity: String?
    var completionRevision: String? = nil
    var isGoalTask = false
    var goalStatus: String? = nil
    var automaticTitleSuggestion: String? = nil
    var titleContentRevision: String? = nil
    var titleMessageCount = 0
    var isArchived = false

    var displayStatusTitle: String { isArchived ? "已归档" : status.title }
    var displayStatusIcon: String { isArchived ? "archivebox" : status.icon }
    var displayStatusColor: Color { isArchived ? Color.secondary : status.color }

    var contextPercent: Int {
        guard contextWindow > 0 else { return 0 }
        return min(100, max(0, Int((Double(contextTokens) / Double(contextWindow) * 100).rounded())))
    }

    var tokenLabel: String { Self.formatTokens(projectTokens > 0 ? projectTokens : totalTokens) }

    /// Human-readable task text. Transport markers such as `<heartbeat>` are
    /// useful to Codex internally, but should never leak into the workbench UI.
    var displayWaitingPrompt: String? { Self.cleanDisplayText(waitingPrompt) }
    var displayResultSummary: String? { Self.cleanDisplayText(resultSummary) }
    var displayLatestActivity: String? { Self.cleanDisplayText(latestActivity) }

    /// A completed Codex turn is a new observable result even when its first-line
    /// summary happens to be identical to the previous turn.
    var resultRevision: String? {
        guard status == .completed, let resultSummary, !resultSummary.isEmpty else { return nil }
        return completionRevision ?? String(updatedAt.timeIntervalSince1970)
    }

    var relativeTime: String {
        let seconds = max(0, Int(Date().timeIntervalSince(updatedAt)))
        if seconds < 60 { return "刚刚" }
        if seconds < 3_600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86_400 { return "\(seconds / 3_600) 小时前" }
        return "\(seconds / 86_400) 天前"
    }

    static func formatTokens(_ value: Int64) -> String {
        if value >= 1_000_000_000 { return String(format: "%.2fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0fK", Double(value) / 1_000) }
        return "\(value)"
    }

    private static func cleanDisplayText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let lines = raw.replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard !line.isEmpty else { return false }
                let isControlTag = line.hasPrefix("<") && line.hasSuffix(">") && !line.contains(" ")
                let isWritingFence = line.hasPrefix(":::writing") || line == ":::"
                return !isControlTag && !isWritingFence
            }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: " ")
    }
}

enum TaskHypothesisAnalysisKind: String, CaseIterable {
    case existingEvidence
    case emergingHypotheses

    var menuTitle: String {
        switch self {
        case .existingEvidence: return "核对假设证据与反证"
        case .emergingHypotheses: return "提炼新假设"
        }
    }

    var taskTitle: String {
        switch self {
        case .existingEvidence: return "证据与反证核对"
        case .emergingHypotheses: return "新假设提炼"
        }
    }

    var icon: String {
        switch self {
        case .existingEvidence: return "checkmark.seal"
        case .emergingHypotheses: return "sparkles.rectangle.stack"
        }
    }
}

struct TaskContextGroup: Identifiable {
    let rootTaskID: String
    let rootTask: CodexTask?
    let tasks: [CodexTask]
    let hasRelationship: Bool

    var id: String { rootTaskID }
}

struct TokenSnapshot: Equatable {
    var totalTokens: Int64 = 0
    var contextTokens: Int64 = 0
    var contextWindow: Int64 = 0
}

enum WorkbenchSection: String, CaseIterable, Identifiable {
    case business
    case execution
    case codex
    case logic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .business: return "经营"
        case .execution: return "执行"
        case .codex: return "Codex"
        case .logic: return "工作逻辑"
        }
    }

    var icon: String {
        switch self {
        case .business: return "point.3.connected.trianglepath.dotted"
        case .execution: return "scope"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .logic: return "waveform.path.ecg.rectangle"
        }
    }
}

enum TrackRuntimeState: String {
    case needsUser
    case aiRunning
    case evidenceReview
    case linked
    case suggestionOnly
    case unlinked

    var title: String {
        switch self {
        case .needsUser: return "需要你"
        case .aiRunning: return "AI 推进中"
        case .evidenceReview: return "待评价证据"
        case .linked: return "已关联"
        case .suggestionOnly: return "关联候选"
        case .unlinked: return "待可靠关联"
        }
    }

    var icon: String {
        switch self {
        case .needsUser: return "person.crop.circle.badge.exclamationmark"
        case .aiRunning: return "sparkles"
        case .evidenceReview: return "checkmark.seal"
        case .linked: return "link"
        case .suggestionOnly: return "link.badge.plus"
        case .unlinked: return "circle.dashed"
        }
    }

    var color: Color {
        switch self {
        case .needsUser: return WorkbenchPalette.amber
        case .aiRunning: return WorkbenchPalette.mint
        case .evidenceReview: return WorkbenchPalette.purple
        case .linked: return WorkbenchPalette.blue
        case .suggestionOnly: return Color.white.opacity(0.55)
        case .unlinked: return Color.white.opacity(0.34)
        }
    }
}

struct ExecutionTrackRuntime: Identifiable {
    let track: ExecutionTrack
    let confirmedTasks: [CodexTask]
    let suggestedTasks: [CodexTask]

    var id: String { track.id }

    var state: TrackRuntimeState {
        if confirmedTasks.contains(where: { $0.status == .waiting }) { return .needsUser }
        if confirmedTasks.contains(where: { $0.status == .running }) { return .aiRunning }
        if confirmedTasks.contains(where: { $0.status == .completed }) { return .evidenceReview }
        if !confirmedTasks.isEmpty { return .linked }
        if !suggestedTasks.isEmpty { return .suggestionOnly }
        return .unlinked
    }
}

struct RecommendedAIAction: Identifiable, Equatable {
    let id: String
    let priority: Int
    let priorityLabel: String
    let priorityReason: String
    let title: String
    let summary: String
    let taskTitle: String
    let supportingAssumptionIDs: [String]
    let promptGoal: String
    var parentTaskID: String? = nil
}

/// A presentation snapshot for one hypothesis. Historical Codex work is kept
/// separate from business evidence: it explains what work has happened, but it
/// never changes confidence or unlocks a milestone by itself.
struct AssumptionWorkSnapshot: Equatable {
    let contextLabel: String
    let historyMilestones: [String]
    let currentPosition: String?
    let humanAction: String?
    let humanNote: String?
}

enum TaskContextFilter: String, CaseIterable, Identifiable {
    case unclosed
    case closed
    case all

    var id: String { rawValue }
    var title: String {
        switch self {
        case .unclosed: return "未闭环"
        case .closed: return "已闭环"
        case .all: return "全部"
        }
    }
}

enum TaskContextOrigin: String {
    case historical
    case workbench
    case manual

    var title: String {
        switch self {
        case .historical: return "历史识别"
        case .workbench: return "工作台创建"
        case .manual: return "手动关联"
        }
    }

    var icon: String {
        switch self {
        case .historical: return "clock.arrow.circlepath"
        case .workbench: return "sparkles"
        case .manual: return "link"
        }
    }

    var color: Color {
        switch self {
        case .historical: return Color.secondary
        case .workbench: return WorkbenchPalette.mintDim
        case .manual: return WorkbenchPalette.blue
        }
    }
}

enum TaskContextRole: String {
    case historical
    case manual
    case aiPreparation
    case userNextStep
    case evidenceAudit
    case emergingHypothesis
    case workbenchLearning

    var title: String {
        switch self {
        case .historical: return "历史任务"
        case .manual: return "手动导入"
        case .aiPreparation: return "AI 准备"
        case .userNextStep: return "你定义的下一步"
        case .evidenceAudit: return "假设证据与反证核对"
        case .emergingHypothesis: return "新假设提炼"
        case .workbenchLearning: return "工作台学习"
        }
    }

    var shortTitle: String {
        switch self {
        case .historical: return "历史"
        case .manual: return "导入"
        case .aiPreparation: return "AI 准备"
        case .userNextStep: return "下一步"
        case .evidenceAudit: return "证据与反证"
        case .emergingHypothesis: return "新假设"
        case .workbenchLearning: return "工作台学习"
        }
    }

    var icon: String {
        switch self {
        case .historical: return "clock.arrow.circlepath"
        case .manual: return "link"
        case .aiPreparation: return "sparkles"
        case .userNextStep: return "arrow.triangle.branch"
        case .evidenceAudit: return "checkmark.seal"
        case .emergingHypothesis: return "sparkles.rectangle.stack"
        case .workbenchLearning: return "brain.head.profile"
        }
    }

    var color: Color {
        switch self {
        case .historical: return Color.secondary
        case .manual: return WorkbenchPalette.blue
        case .aiPreparation: return WorkbenchPalette.mintDim
        case .userNextStep: return WorkbenchPalette.purple
        case .evidenceAudit: return WorkbenchPalette.blue
        case .emergingHypothesis: return WorkbenchPalette.purple
        case .workbenchLearning: return WorkbenchPalette.mint
        }
    }
}

struct NextTaskComposerContext: Identifiable, Equatable {
    let sourceTask: CodexTask
    var id: String { sourceTask.id }
}

struct TaskResultInsight: Equatable {
    let stageImpact: String
    let gained: String
    let evidence: String
    let nextStep: String
}

struct ResultInboxItem: Identifiable, Equatable {
    let task: CodexTask
    let projectName: String
    let assumptionID: String?
    let assumptionTitle: String
    let stageTitle: String

    var id: String { task.id }
}

struct WorkbenchResultNavigation: Equatable {
    let id = UUID()
    let assumptionID: String
    let taskID: String
}

enum TaskFilter: String, CaseIterable, Identifiable {
    case all
    case running
    case waiting
    case completed

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .running: return "运行中"
        case .waiting: return "等待"
        case .completed: return "已完成"
        }
    }
}

enum WorkbenchPalette {
    static let mint = Color(red: 0.31, green: 0.88, blue: 0.73)
    static let mintDim = Color(red: 0.32, green: 0.69, blue: 0.61)
    static let blue = Color(red: 0.34, green: 0.68, blue: 1.0)
    static let amber = Color(red: 1.0, green: 0.68, blue: 0.04)
    static let coral = Color(red: 1.0, green: 0.36, blue: 0.36)
    static let purple = Color(red: 0.69, green: 0.56, blue: 1.0)
}
