import CryptoKit
import Foundation

public enum AssumptionRadarError: LocalizedError {
    case unreadable(String)
    case noAssumptions
    case noCurrentMilestone

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path): return "无法读取执行上下文：\(path)"
        case .noAssumptions: return "关键假设库中没有可识别的当前控制假设"
        case .noCurrentMilestone: return "业务里程碑总控台中没有可识别的当前里程碑"
        }
    }
}

public enum AssumptionRadarScanner {
    public static func scan(
        assumptionsURL: URL,
        dependenciesURL: URL,
        milestoneURL: URL,
        priorityURL: URL,
        businessContext: BusinessContextSnapshot
    ) throws -> AssumptionRadarSnapshot {
        let documents = try [assumptionsURL, dependenciesURL, milestoneURL, priorityURL].map { url -> String in
            guard let value = try? String(contentsOf: url, encoding: .utf8) else {
                throw AssumptionRadarError.unreadable(url.path)
            }
            return value
        }
        return try parse(
            assumptionsMarkdown: documents[0],
            dependenciesMarkdown: documents[1],
            milestoneMarkdown: documents[2],
            priorityMarkdown: documents[3],
            businessContext: businessContext
        )
    }

    public static func parse(
        assumptionsMarkdown: String,
        dependenciesMarkdown: String,
        milestoneMarkdown: String,
        priorityMarkdown: String,
        businessContext: BusinessContextSnapshot
    ) throws -> AssumptionRadarSnapshot {
        let dependencyMap = parseDependencies(dependenciesMarkdown)
        let assumptionDrafts = parseAssumptions(assumptionsMarkdown)
        guard !assumptionDrafts.isEmpty else { throw AssumptionRadarError.noAssumptions }

        let milestone = try parseMilestone(milestoneMarkdown)
        let executionTracks = parseExecutionTracks(priorityMarkdown)
        let priorityIDs = parsePriorityIDs(priorityMarkdown)
        let requiredIDs = Set(milestone.requiredAssumptionIDs)
        let topIDs = Set(priorityIDs)
        let mainStage = FiveStepKind.from(stageName: businessContext.mainStage?.name) ?? .solution

        let nodes = assumptionDrafts.map { draft -> AssumptionNode in
            let dependency = dependencyMap[draft.id]
            let role = activationRole(
                for: draft,
                dependency: dependency,
                isTop: topIDs.contains(draft.id),
                isMilestoneRequired: requiredIDs.contains(draft.id),
                mainStage: mainStage
            )
            let order = priorityIDs.firstIndex(of: draft.id) ?? 999
            return AssumptionNode(
                id: draft.id,
                title: draft.title,
                stage: draft.stage,
                level: draft.level,
                sourceStatus: draft.status,
                dependencyIDs: extractIDs(dependency?.upstream ?? draft.dependencies),
                dependencyDescription: dependency?.upstream ?? draft.dependencies,
                dependencyType: dependency?.type ?? "",
                summary: draft.summary,
                failureImpact: draft.failureImpact,
                currentAction: dependency?.currentAction ?? defaultAction(for: role),
                decisionGate: dependency?.decisionGate ?? "门槛待当前证据校准",
                role: role,
                activationReason: activationReason(
                    role: role,
                    milestone: milestone,
                    dependency: dependency,
                    mainStage: mainStage
                ),
                selectionOrder: order
            )
        }
        .sorted {
            if $0.role.order != $1.role.order { return $0.role.order < $1.role.order }
            if $0.selectionOrder != $1.selectionOrder { return $0.selectionOrder < $1.selectionOrder }
            if $0.stage.order != $1.stage.order { return $0.stage.order < $1.stage.order }
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }

        let assumptionVersion = metadataValue(named: "版本", in: assumptionsMarkdown)
        let poolCount = firstInteger(matching: #"原始\s*(\d+)\s*条"#, in: assumptionsMarkdown) ?? nodes.count
        let combined = [assumptionsMarkdown, dependenciesMarkdown, milestoneMarkdown, priorityMarkdown].joined(separator: "\n---\n")
        let fingerprint = SHA256.hash(data: Data(combined.utf8)).map { String(format: "%02x", $0) }.joined()
        return AssumptionRadarSnapshot(
            businessContextVersion: businessContext.contextVersion,
            assumptionVersion: assumptionVersion,
            milestone: milestone,
            executionTracks: executionTracks,
            assumptions: nodes,
            originalPoolCount: poolCount,
            contentFingerprint: fingerprint
        )
    }
}

private extension AssumptionRadarScanner {
    struct AssumptionDraft {
        let id: String
        let title: String
        let stage: FiveStepKind
        let level: String
        let status: String
        let dependencies: String
        let summary: String
        let failureImpact: String
    }

    struct DependencyDraft {
        let upstream: String
        let type: String
        let currentAction: String
        let decisionGate: String
    }

    static func parseAssumptions(_ markdown: String) -> [AssumptionDraft] {
        let lines = markdown.components(separatedBy: .newlines)
        var output: [AssumptionDraft] = []
        var currentID: String?
        var currentTitle = ""
        var body: [String] = []

        func finish() {
            guard let id = currentID else { return }
            let metadata = parseMetadata(body)
            output.append(AssumptionDraft(
                id: id,
                title: currentTitle,
                stage: FiveStepKind.from(assumptionID: id),
                level: metadata["层级"] ?? "母假设",
                status: metadata["状态"] ?? "待验证",
                dependencies: metadata["依赖"] ?? "",
                summary: firstNarrativeLine(body) ?? currentTitle,
                failureImpact: line(afterMarker: "若证伪", in: body) ?? "将重新评估该假设影响的经营决定"
            ))
        }

        for line in lines {
            if let match = firstMatch(#"^#{3,4}\s+((?:[SB]-[A-Z]\d+)|(?:[DGM]\d+))[:：]\s*(.+)$"#, in: line),
               match.count >= 3 {
                finish()
                currentID = canonicalID(match[1])
                currentTitle = strippingMarkdown(match[2])
                body = []
            } else if currentID != nil {
                body.append(line)
            }

            let cells = tableCells(line)
            if cells.count >= 4, cells[0].range(of: #"^C\d+$"#, options: .regularExpression) != nil {
                output.append(AssumptionDraft(
                    id: cells[0],
                    title: strippingMarkdown(cells[1]),
                    stage: .solution,
                    level: "控制变量",
                    status: strippingMarkdown(cells[2]),
                    dependencies: "随当前解决方案案例记录",
                    summary: strippingMarkdown(cells[3]),
                    failureImpact: "用于解释结果，当前不单独改变资源投入"
                ))
            }
        }
        finish()
        return orderedUniqueDrafts(output)
    }

    static func parseDependencies(_ markdown: String) -> [String: DependencyDraft] {
        var output: [String: DependencyDraft] = [:]
        for line in markdown.components(separatedBy: .newlines) {
            let cells = tableCells(line)
            guard cells.count >= 5 else { continue }
            let ids = extractIDs(cells[0])
            guard ids.count == 1, cells[1] != "上游依赖" else { continue }
            output[ids[0]] = DependencyDraft(
                upstream: strippingMarkdown(cells[1]),
                type: strippingMarkdown(cells[2]),
                currentAction: strippingMarkdown(cells[3]),
                decisionGate: strippingMarkdown(cells[4])
            )
        }
        return output
    }

    static func parsePriorityIDs(_ markdown: String) -> [String] {
        let topSection = section(named: "当前 Top", in: markdown, headingLevel: 2)
        var output: [String] = []
        for line in topSection.components(separatedBy: .newlines) {
            let cells = tableCells(line)
            guard cells.count >= 2, Int(cells[0]) != nil else { continue }
            output.append(contentsOf: extractIDs(cells[1]))
        }
        return orderedUnique(output)
    }

    static func parseExecutionTracks(_ markdown: String) -> [ExecutionTrack] {
        let lines = markdown.components(separatedBy: .newlines)
        var output: [ExecutionTrack] = []
        var currentID: String?
        var currentTitle = ""
        var currentOrder = 0
        var body: [String] = []

        func finish() {
            guard let id = currentID else { return }
            let sectionText = body.joined(separator: "\n")
            let assumptionValue = fieldValue(named: "假设编号", in: body) ?? sectionText
            output.append(ExecutionTrack(
                id: id,
                title: currentTitle,
                assumptionIDs: extractIDs(assumptionValue),
                decisionImpact: fieldValue(named: "影响决定", in: body) ?? "等待商业库定义影响决定",
                currentSample: fieldValue(named: "当前样本", in: body) ?? "当前样本待识别",
                confidence: fieldValue(named: "当前信心与依据", in: body) ?? "待校准",
                learningGoal: fieldValue(named: "本轮唯一主要学习目标", in: body) ?? "等待商业库定义本轮学习目标",
                minimumAction: firstMinimumActionLine(section(named: "最小验证动作", in: sectionText, headingLevel: 3)) ?? "等待定义最小验证动作",
                successGate: firstActionLine(section(named: "成功门槛", in: sectionText, headingLevel: 3)) ?? "成功门槛待校准",
                failureGate: firstActionLine(section(named: "失败门槛", in: sectionText, headingLevel: 3)) ?? "失败门槛待校准",
                grayAction: firstActionLine(section(named: "灰区处理", in: sectionText, headingLevel: 3)) ?? "灰区只补最短证据",
                order: currentOrder
            ))
        }

        for line in lines {
            if let match = firstMatch(#"^##\s+\d+\.\s*实验\s*([A-Z0-9]+)[｜|]\s*(.+)$"#, in: line), match.count >= 3 {
                finish()
                currentID = match[1]
                currentTitle = strippingMarkdown(match[2])
                currentOrder = output.count
                body = []
            } else if currentID != nil {
                if line.hasPrefix("## ") {
                    finish()
                    currentID = nil
                    body = []
                } else {
                    body.append(line)
                }
            }
        }
        finish()
        return output.sorted { $0.order < $1.order }
    }

    static func parseMilestone(_ markdown: String) throws -> BusinessMilestoneSnapshot {
        guard let match = firstMatch(#"\*\*(BM\d+)[：:]([^*]+)\*\*"#, in: markdown), match.count >= 3 else {
            throw AssumptionRadarError.noCurrentMilestone
        }
        let id = match[1]
        let title = strippingMarkdown(match[2])
        let decision = firstNarrativeLine(section(named: "要解锁的决定", in: markdown, headingLevel: 3).components(separatedBy: .newlines))
            ?? "等待里程碑总控台给出要解锁的决定"
        let currentStage = firstNarrativeLine(section(named: "当前阶段", in: markdown, headingLevel: 3).components(separatedBy: .newlines))
            ?? "当前阶段待识别"
        let required = orderedUnique(extractIDs(section(named: "关键假设", in: markdown, headingLevel: 3)))
        let unlocked = bulletLines(section(named: "通过后解锁", in: markdown, headingLevel: 3))
        let locked = bulletLines(section(named: "当前禁止解锁", in: markdown, headingLevel: 3))
        return BusinessMilestoneSnapshot(
            id: id,
            title: title,
            decisionToUnlock: strippingMarkdown(decision),
            currentStage: strippingMarkdown(currentStage),
            requiredAssumptionIDs: required,
            unlockedResources: unlocked,
            lockedResources: locked
        )
    }

    static func fieldValue(named name: String, in lines: [String]) -> String? {
        for line in lines {
            var value = strippingMarkdown(line)
            if value.hasPrefix("- ") { value = String(value.dropFirst(2)) }
            let marker = "\(name)："
            guard value.hasPrefix(marker) else { continue }
            let result = String(value.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !result.isEmpty { return result }
        }
        return nil
    }

    static func firstActionLine(_ value: String) -> String? {
        let lines = value.components(separatedBy: .newlines)
        if let bullet = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }) {
            return strippingMarkdown(String(bullet.trimmingCharacters(in: .whitespaces).dropFirst(2)))
        }
        return firstNarrativeLine(lines)
    }

    static func firstMinimumActionLine(_ value: String) -> String? {
        let lines = value.components(separatedBy: .newlines)
        if let narrative = firstNarrativeLine(lines) { return narrative }
        return firstActionLine(value)
    }

    static func activationRole(
        for draft: AssumptionDraft,
        dependency: DependencyDraft?,
        isTop: Bool,
        isMilestoneRequired: Bool,
        mainStage: FiveStepKind
    ) -> AssumptionActivationRole {
        if isTop { return .primary }
        if draft.id.hasPrefix("C") || draft.status.contains("已降级") { return .supporting }
        if draft.status.contains("成本基线") || dependency?.currentAction.contains("记录交付成本") == true {
            return .supporting
        }
        if isMilestoneRequired {
            if dependency?.type.contains("证据依赖") == true { return .supporting }
            if draft.status.contains("正在验证") || dependency?.type.contains("并行") == true { return .supporting }
        }
        if draft.status.contains("初步成立") || draft.status.contains("单点支持") { return .monitoring }
        if draft.stage == .moat { return .resourceLocked }
        if draft.status.contains("待验证") || dependency?.type.contains("硬依赖") == true {
            return .dependencyBlocked
        }
        if draft.stage.order > mainStage.order { return .resourceLocked }
        if draft.status.contains("正在验证") { return .supporting }
        return .monitoring
    }

    static func activationReason(
        role: AssumptionActivationRole,
        milestone: BusinessMilestoneSnapshot,
        dependency: DependencyDraft?,
        mainStage: FiveStepKind
    ) -> String {
        switch role {
        case .primary:
            return "直接影响 \(milestone.id) 要解锁的决定，且已进入本轮优先假设"
        case .supporting:
            return "可随主实验共同取证，不单独增加新的学习目标"
        case .monitoring:
            return "已有初步信号，当前只监测反证和条件变化"
        case .dependencyBlocked:
            let upstream = dependency?.upstream.nilIfBlank ?? "上游假设"
            return "\(upstream) 尚未达到正式判定门槛"
        case .resourceLocked:
            return "当前主阶段是\(mainStage.rawValue)，\(milestone.id) 尚未解锁该阶段的主要投入"
        }
    }

    static func defaultAction(for role: AssumptionActivationRole) -> String {
        switch role {
        case .primary: return "取得能改变当前决定的最短证据"
        case .supporting: return "随当前实验记录证据，不另开验证项目"
        case .monitoring: return "观察结构性反证，不主动增加投入"
        case .dependencyBlocked: return "等待上游证据达到门槛"
        case .resourceLocked: return "保持锁定，等待业务里程碑解锁"
        }
    }

    static func section(named marker: String, in markdown: String, headingLevel: Int) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        let prefix = String(repeating: "#", count: headingLevel) + " "
        guard let start = lines.firstIndex(where: { $0.hasPrefix(prefix) && $0.contains(marker) }) else { return "" }
        var output: [String] = []
        for line in lines.dropFirst(start + 1) {
            if line.hasPrefix(prefix) { break }
            output.append(line)
        }
        return output.joined(separator: "\n")
    }

    static func parseMetadata(_ lines: [String]) -> [String: String] {
        for line in lines where line.contains("层级：") || line.contains("状态：") || line.contains("依赖：") {
            let cleaned = strippingMarkdown(line)
            return cleaned.split(separator: "｜").reduce(into: [String: String]()) { result, part in
                let pieces = part.split(separator: "：", maxSplits: 1).map(String.init)
                if pieces.count == 2 { result[pieces[0].trimmingCharacters(in: .whitespaces)] = pieces[1].trimmingCharacters(in: .whitespaces) }
            }
        }
        return [:]
    }

    static func firstNarrativeLine(_ lines: [String]) -> String? {
        lines.lazy
            .map { strippingMarkdown($0) }
            .first {
                !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("|") && !$0.hasPrefix("-") && !$0.hasPrefix(">") && !$0.hasPrefix("```")
            }
    }

    static func line(afterMarker marker: String, in lines: [String]) -> String? {
        guard let index = lines.firstIndex(where: { $0.contains(marker) }) else { return nil }
        return firstNarrativeLine(Array(lines.dropFirst(index + 1)))
    }

    static func bulletLines(_ value: String) -> [String] {
        value.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { return nil }
            return strippingMarkdown(String(trimmed.dropFirst(2)))
        }
    }

    static func tableCells(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return [] }
        return trimmed.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
            .map { strippingMarkdown(String($0)) }
    }

    static func extractIDs(_ value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?:S-[A-Z]\d+|B-[A-Z]\d+|D\d+(?:-[AB])?|G\d+|M\d+|C\d+)"#) else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        return orderedUnique(regex.matches(in: value, range: range).compactMap { result in
            Range(result.range, in: value).map { canonicalID(String(value[$0])) }
        })
    }

    static func canonicalID(_ value: String) -> String {
        if value.range(of: #"^D\d+-[AB]$"#, options: .regularExpression) != nil {
            return String(value.dropLast(2))
        }
        return value
    }

    static func firstMatch(_ pattern: String, in value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        let range = NSRange(value.startIndex..., in: value)
        guard let result = regex.firstMatch(in: value, range: range) else { return nil }
        return (0..<result.numberOfRanges).map { index in
            guard let swiftRange = Range(result.range(at: index), in: value) else { return "" }
            return String(value[swiftRange])
        }
    }

    static func firstInteger(matching pattern: String, in value: String) -> Int? {
        guard let match = firstMatch(pattern, in: value), match.count > 1 else { return nil }
        return Int(match[1])
    }

    static func metadataValue(named name: String, in markdown: String) -> String {
        let marker = "\(name)："
        for line in markdown.components(separatedBy: .newlines).prefix(30) {
            let cleaned = line.trimmingCharacters(in: CharacterSet(charactersIn: "> "))
            if cleaned.hasPrefix(marker) { return strippingMarkdown(String(cleaned.dropFirst(marker.count))) }
        }
        return ""
    }

    static func strippingMarkdown(_ value: String) -> String {
        value
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    static func orderedUniqueDrafts(_ values: [AssumptionDraft]) -> [AssumptionDraft] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.id).inserted }
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty || self == "无" ? nil : self }
}
