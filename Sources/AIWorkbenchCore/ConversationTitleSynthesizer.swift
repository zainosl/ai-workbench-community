import Foundation

public struct ConversationTitleSuggestion: Equatable, Sendable {
    public let title: String
    public let contentRevision: String
    public let messageCount: Int

    public init(title: String, contentRevision: String, messageCount: Int) {
        self.title = title
        self.contentRevision = contentRevision
        self.messageCount = messageCount
    }
}

/// Produces a stable, local title from the user's evolving intent. The existing
/// title remains the subject anchor; later substantive messages only replace the
/// short focus after the separator, which prevents titles from thrashing.
public enum ConversationTitleSynthesizer {
    private static let maximumTitleLength = 34

    private static let ignoredWholeMessages: Set<String> = [
        "继续", "好的", "好", "可以", "行", "嗯", "收到", "知道了", "没问题",
        "continue", "ok", "okay", "yes", "thanks", "thank you"
    ]

    private static let intentMarkers = [
        "实现", "新增", "增加", "添加", "支持", "创建", "开发", "搭建", "做一个",
        "修复", "解决", "排查", "优化", "改进", "调整", "重构", "改成", "不要",
        "调研", "研究", "分析", "诊断", "评估", "检查", "审查", "复盘", "验证",
        "设计", "规划", "整理", "总结", "归纳", "提炼", "梳理", "输出", "生成",
        "写", "撰写", "发布", "部署", "上线", "对比", "比较", "聚焦", "补充",
        "implement", "add", "build", "create", "fix", "debug", "improve", "update",
        "refactor", "research", "analyze", "review", "design", "plan", "summarize",
        "write", "publish", "deploy", "compare", "focus"
    ]

    private static let weakFollowupPrefixes = [
        "还有吗", "然后呢", "为什么", "怎么样", "进度", "状态", "你觉得", "能看到吗",
        "接着", "继续", "好的", "可以", "明白", "收到"
    ]

    private static let leadingFillers = [
        "我发现", "我觉得", "我想要", "我想", "我希望", "我需要", "需要你", "请你",
        "请", "麻烦你", "麻烦", "帮我", "能不能", "可不可以", "是否可以", "这个",
        "那个", "然后", "另外", "接下来", "最后请", "最后", "同时", "并且是说", "并且", "就是说",
        "再帮我", "再", "也请", "也", "please", "could you", "can you", "i want to",
        "i'd like to"
    ]

    public static func suggest(
        existingTitle: String,
        goalObjective: String?,
        userMessages: [String]
    ) -> ConversationTitleSuggestion? {
        var messages = userMessages.compactMap(cleanMessage)
        if let objective = goalObjective.flatMap(cleanMessage),
           !messages.contains(objective) {
            messages.insert(objective, at: 0)
        }
        guard !messages.isEmpty else { return nil }

        let revision = stableRevision(messages.joined(separator: "\u{1F}"))
        let base = stableBaseTitle(existingTitle, fallback: messages[0])
        let fullContext = messages.suffix(6).joined(separator: "。")

        if isAutomaticTitleRequest(fullContext) {
            return ConversationTitleSuggestion(
                title: "根据对话自动归纳更新任务标题",
                contentRevision: revision,
                messageCount: messages.count
            )
        }

        guard messages.count > 1,
              let latestIntent = messages.dropFirst().reversed().first(where: isSubstantiveMessage),
              let focus = compactIntent(latestIntent),
              !focus.isEmpty else {
            return ConversationTitleSuggestion(
                title: base,
                contentRevision: revision,
                messageCount: messages.count
            )
        }

        let title: String
        if isSemanticallyContained(focus, in: base) {
            title = base
        } else {
            title = clampTitle("\(base)：\(focus)")
        }
        return ConversationTitleSuggestion(title: title, contentRevision: revision, messageCount: messages.count)
    }

    public static func shouldReplaceInitialTitle(_ title: String) -> Bool {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty || clean == "未命名任务" { return true }
        if clean.count > maximumTitleLength { return true }
        if clean.rangeOfCharacter(from: CharacterSet(charactersIn: "。！？!?，,；;\n")) != nil { return true }
        let lower = clean.lowercased()
        return leadingFillers.contains(where: { lower.hasPrefix($0) }) || clean.hasSuffix("…")
    }

    public static func cleanMessage(_ raw: String) -> String? {
        var value = raw.replacingOccurrences(of: "\r", with: "\n")
        let blockNames = [
            "recommended_plugins", "environment_context", "app-context", "developer",
            "attachments_context", "image_resize_notice"
        ]
        for name in blockNames {
            let pattern = "(?is)<\(name)(?:\\s[^>]*)?>.*?</\(name)>"
            if let expression = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(value.startIndex..., in: value)
                value = expression.stringByReplacingMatches(in: value, range: range, withTemplate: " ")
            }
        }

        let lines = value.components(separatedBy: .newlines).compactMap { line -> String? in
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return nil }
            let lower = clean.lowercased()
            if lower.hasPrefix("files mentioned by the user") ||
                lower.hasPrefix("environment_context") ||
                lower.hasPrefix("recommended_plugins") ||
                lower.hasPrefix("image_resize_notice") ||
                (clean.hasPrefix("[$") && clean.contains("](")) ||
                (clean.hasPrefix("<") && clean.hasSuffix(">") && !clean.contains(" ")) {
                return nil
            }
            return clean
        }
        value = lines.joined(separator: " ")
        value = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func isAutomaticTitleRequest(_ value: String) -> Bool {
        let lower = value.lowercased()
        let mentionsTitle = lower.contains("任务标题") || lower.contains("task title") || lower.contains("thread title")
        let mentionsConversation = lower.contains("对话") || lower.contains("聊") || lower.contains("conversation") || lower.contains("chat")
        let mentionsEvolution = lower.contains("自动") || lower.contains("更新") || lower.contains("总结") || lower.contains("归纳") || lower.contains("dynamic")
        return mentionsTitle && mentionsConversation && mentionsEvolution
    }

    private static func stableBaseTitle(_ existingTitle: String, fallback: String) -> String {
        let existing = existingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty && existing != "未命名任务" {
            let root = existing.split(separator: "：", maxSplits: 1).first.map(String.init) ?? existing
            return clampTitle(root)
        }
        return compactIntent(fallback).map(clampTitle) ?? "Goal 任务"
    }

    private static func isSubstantiveMessage(_ message: String) -> Bool {
        let normalized = message.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ignoredWholeMessages.contains(normalized) { return false }
        if weakFollowupPrefixes.contains(where: { normalized.hasPrefix($0) }) && normalized.count < 18 { return false }
        return normalized.count >= 4 && intentMarkers.contains(where: { normalized.contains($0) })
    }

    private static func compactIntent(_ message: String) -> String? {
        let clauses = message.components(separatedBy: CharacterSet(charactersIn: "。！？!?；;\n"))
            .flatMap { sentence -> [String] in
                let clean = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                guard clean.count > 42 else { return [clean] }
                return clean.components(separatedBy: CharacterSet(charactersIn: "，,"))
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let ranked = clauses.enumerated().compactMap { index, clause -> (String, Int)? in
            let lower = clause.lowercased()
            guard !ignoredWholeMessages.contains(lower) else { return nil }
            var score = min(28, clause.count) + index * 3
            score += intentMarkers.reduce(0) { $0 + (lower.contains($1) ? 12 : 0) }
            if clause.contains("标题") || clause.contains("报告") || clause.contains("方案") || clause.contains("功能") { score += 8 }
            if weakFollowupPrefixes.contains(where: { lower.hasPrefix($0) }) && clause.count < 18 { score -= 30 }
            return (clause, score)
        }
        guard var candidate = ranked.max(by: { $0.1 < $1.1 })?.0 else { return nil }

        candidate = stripLeadingFillers(candidate)
        let replacements: [(String, String)] = [
            ("可不可以做一个", "实现"), ("能不能做一个", "实现"), ("是否可以做一个", "实现"),
            ("做一个", "制作"), ("加一个", "增加"), ("再去做", "做"), ("去做", "做"),
            ("的一个功能", "功能"), ("这个功能", "功能"), ("改成只", "仅"),
            ("只研究", "聚焦"), ("只调研", "聚焦"), ("不要再", "停止")
        ]
        for (source, replacement) in replacements {
            candidate = candidate.replacingOccurrences(of: source, with: replacement)
        }
        candidate = stripLeadingFillers(candidate)
        candidate = candidate.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard candidate.count >= 3 else { return nil }
        return clampFragment(candidate)
    }

    private static func stripLeadingFillers(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            let lower = result.lowercased()
            if let filler = leadingFillers.first(where: { lower.hasPrefix($0) }) {
                result.removeFirst(filler.count)
                result = result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
                changed = true
            }
        }
        return result
    }

    private static func isSemanticallyContained(_ focus: String, in base: String) -> Bool {
        let lhs = Set(characterBigrams(focus))
        let rhs = Set(characterBigrams(base))
        guard !lhs.isEmpty else { return true }
        let overlap = lhs.intersection(rhs).count
        return Double(overlap) / Double(lhs.count) >= 0.72
    }

    private static func characterBigrams(_ value: String) -> [String] {
        let characters = Array(value.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation })
        guard characters.count > 1 else { return characters.map(String.init) }
        return (0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) }
    }

    private static func clampFragment(_ value: String) -> String {
        if value.count <= 18 { return value }
        let prefix = String(value.prefix(18))
        return prefix.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func clampTitle(_ value: String) -> String {
        let clean = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard clean.count > maximumTitleLength else { return clean }
        return String(clean.prefix(maximumTitleLength - 1)).trimmingCharacters(in: .punctuationCharacters) + "…"
    }

    private static func stableRevision(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
