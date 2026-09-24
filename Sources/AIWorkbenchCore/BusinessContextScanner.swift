import CryptoKit
import Foundation

public enum BusinessContextError: LocalizedError {
    case unreadable(String)
    case missingCanvas

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path): return "无法读取商业模式底库：\(path)"
        case .missingCanvas: return "商业模式底库中没有可识别的五步法总画布"
        }
    }
}

public enum BusinessContextScanner {
    public static func scan(entryURL: URL) throws -> BusinessContextSnapshot {
        guard let markdown = try? String(contentsOf: entryURL, encoding: .utf8) else {
            throw BusinessContextError.unreadable(entryURL.path)
        }
        return try parse(markdown: markdown, sourcePath: entryURL.path)
    }

    public static func parse(markdown: String, sourcePath: String) throws -> BusinessContextSnapshot {
        let lines = markdown.components(separatedBy: .newlines)
        let version = metadataValue(named: "版本", in: lines)
        let calibratedAt = metadataValue(named: "最后校准", in: lines)
        let progress = metadataValue(named: "当前进度", in: lines)
        let businessModelSummary = businessModelSummary(in: lines)
        let demandUserSummary = demandAudienceSummary(in: lines)
        let demandTaskSummary = firstParagraph(inSubsection: "用户任务", withinDemandSection: lines)
        let demandExclusionSummary = listSummary(inSubsection: "当前不服务", withinDemandSection: lines)

        guard let headingIndex = lines.firstIndex(where: {
            let value = $0.trimmingCharacters(in: .whitespaces)
            return value.hasPrefix("## ") && value.contains("五步法") && value.contains("画布")
        }) else { throw BusinessContextError.missingCanvas }

        var stages: [BusinessStage] = []
        var emphasizedActionStageIDs = Set<String>()
        for line in lines.dropFirst(headingIndex + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") { break }
            guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { continue }
            let cells = trimmed
                .dropFirst()
                .dropLast()
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard cells.count >= 4 else { continue }
            let sourceName = cells[0]
            if sourceName == "格子" || sourceName.allSatisfy({ $0 == "-" || $0 == ":" }) { continue }
            // 五步法第三格统一显示为“单元模型”。兼容底库历史版本中的“商业模式”旧标签。
            let name = sourceName == "商业模式" ? "单元模型" : sourceName
            let stageID = stableStageID(name)
            if cells[3].contains("**") { emphasizedActionStageIDs.insert(stageID) }
            let stage = BusinessStage(
                id: stageID,
                name: name,
                definition: cells[1],
                status: strippingMarkdown(cells[2]),
                currentAction: strippingMarkdown(cells[3])
            )
            stages.append(stage)
        }
        guard !stages.isEmpty else { throw BusinessContextError.missingCanvas }

        let main = stages.first(where: {
            $0.currentAction.contains("当前主") || $0.currentAction.contains("主任务") || $0.currentAction.contains("主要资源")
        }) ?? stages.first(where: { emphasizedActionStageIDs.contains($0.id) })
            ?? stages.first(where: { $0.status.contains("正在验证") })

        let mainIndex = main.flatMap { selected in stages.firstIndex(where: { $0.id == selected.id }) }
        let parallel = stages.enumerated().compactMap { index, stage -> BusinessStage? in
            guard stage.id != main?.id else { return nil }
            // 顶层“并行阶段”只表示在主阶段之前仍被重新打开的验证。
            // 主阶段之后的轻量动作属于当前验证的支持动作，不能提前升级为后置阶段正在验证。
            if let mainIndex, index > mainIndex { return nil }
            let isExplicitlyParallel = stage.currentAction.contains("并行") ||
                stage.currentAction.contains("低成本验证") ||
                stage.status.contains("正在验证")
            return isExplicitlyParallel ? stage : nil
        }

        let nextStage: BusinessStage?
        if let main, let index = stages.firstIndex(where: { $0.id == main.id }), stages.indices.contains(index + 1) {
            nextStage = stages[index + 1]
        } else {
            nextStage = nil
        }

        let hash = SHA256.hash(data: Data(markdown.utf8)).map { String(format: "%02x", $0) }.joined()
        return BusinessContextSnapshot(
            sourcePath: sourcePath,
            version: version,
            calibratedAt: calibratedAt,
            businessModelSummary: businessModelSummary,
            progressSummary: progress,
            stages: stages,
            mainStageID: main?.id,
            parallelStageIDs: parallel.map(\.id),
            nextStageID: nextStage?.id,
            contentFingerprint: hash,
            demandUserSummary: demandUserSummary,
            demandTaskSummary: demandTaskSummary,
            demandExclusionSummary: demandExclusionSummary
        )
    }

    private static func metadataValue(named name: String, in lines: [String]) -> String {
        let marker = "\(name)："
        for line in lines.prefix(40) {
            let cleaned = line.trimmingCharacters(in: CharacterSet(charactersIn: "> "))
            if cleaned.hasPrefix(marker) {
                return strippingMarkdown(String(cleaned.dropFirst(marker.count)))
            }
        }
        return ""
    }

    private static func businessModelSummary(in lines: [String]) -> String {
        guard let headingIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("## 一句话商业模式")
        }) else { return "" }

        var fallback = ""
        var insideCodeFence = false
        for line in lines.dropFirst(headingIndex + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("## ") { break }
            if trimmed.hasPrefix("```") {
                insideCodeFence.toggle()
                continue
            }
            guard !trimmed.isEmpty, trimmed != "简单来说：" else { continue }
            if insideCodeFence { return strippingMarkdown(trimmed) }
            if fallback.isEmpty, !trimmed.hasPrefix(">") {
                fallback = strippingMarkdown(trimmed)
            }
        }
        return fallback
    }

    private static func demandAudienceSummary(in lines: [String]) -> String? {
        let body = subsectionLines(named: "用户", withinDemandSection: lines)
        guard !body.isEmpty else { return nil }
        var fragments: [String] = []
        for raw in body {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "当前核心保留：" || trimmed.hasPrefix("```") { break }
            guard !trimmed.isEmpty else { continue }
            let cleaned = strippingListMarker(trimmed)
            if !cleaned.isEmpty { fragments.append(cleaned) }
        }
        guard !fragments.isEmpty else { return nil }
        return compactJoined(fragments, maximum: 112)
    }

    private static func firstParagraph(inSubsection name: String, withinDemandSection lines: [String]) -> String? {
        let body = subsectionLines(named: name, withinDemandSection: lines)
        var fragments: [String] = []
        var started = false
        for raw in body {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") { continue }
            if trimmed.isEmpty {
                if started { break }
                continue
            }
            if trimmed.hasPrefix("-") || trimmed.first?.isNumber == true { break }
            started = true
            fragments.append(strippingMarkdown(trimmed))
        }
        guard !fragments.isEmpty else { return nil }
        return compactJoined(fragments, maximum: 120)
    }

    private static func listSummary(inSubsection name: String, withinDemandSection lines: [String]) -> String? {
        let items = subsectionLines(named: name, withinDemandSection: lines).compactMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("-") else { return nil }
            let value = strippingListMarker(trimmed)
            return value.isEmpty ? nil : value
        }
        guard !items.isEmpty else { return nil }
        return compactJoined(items, separator: "；", maximum: 108)
    }

    private static func subsectionLines(named name: String, withinDemandSection lines: [String]) -> [String] {
        guard let demandStart = lines.firstIndex(where: { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix("## "), !value.hasPrefix("### "), !value.contains("画布") else { return false }
            return value.contains("需求")
        }) else { return [] }
        let demandEnd = lines[(demandStart + 1)...].firstIndex(where: { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.hasPrefix("## ") && !value.hasPrefix("### ")
        }) ?? lines.endIndex
        guard let subsectionStart = lines[(demandStart + 1)..<demandEnd].firstIndex(where: { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix("### ") else { return false }
            return String(value.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines) == name
        }) else { return [] }
        let subsectionEnd = lines[(subsectionStart + 1)..<demandEnd].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("### ")
        }) ?? demandEnd
        return Array(lines[(subsectionStart + 1)..<subsectionEnd])
    }

    private static func strippingListMarker(_ value: String) -> String {
        let stripped = value.replacingOccurrences(
            of: #"^[-*+]\s+|^\d+[.\u3001]\s*"#,
            with: "",
            options: .regularExpression
        )
        return strippingMarkdown(stripped)
    }

    private static func compactJoined(
        _ fragments: [String],
        separator: String = " ",
        maximum: Int
    ) -> String {
        let value = fragments.joined(separator: separator)
            .replacingOccurrences(of: "。；", with: "；")
            .replacingOccurrences(of: "；。", with: "。")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > maximum else { return value }
        return String(value.prefix(maximum)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func stableStageID(_ name: String) -> String {
        Data(name.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func strippingMarkdown(_ value: String) -> String {
        value
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
