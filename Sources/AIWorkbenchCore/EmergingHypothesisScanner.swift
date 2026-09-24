import CryptoKit
import Foundation

public enum EmergingHypothesisScannerError: LocalizedError {
    case unreadable(String)
    case noObservations

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path): return "无法读取新兴假设观察池：\(path)"
        case .noObservations: return "新兴假设观察池中没有可识别的观察"
        }
    }
}

public enum EmergingHypothesisScanner {
    public static func scan(url: URL) throws -> EmergingHypothesisSnapshot {
        guard let markdown = try? String(contentsOf: url, encoding: .utf8) else {
            throw EmergingHypothesisScannerError.unreadable(url.path)
        }
        return try parse(markdown: markdown)
    }

    public static func parse(markdown: String) throws -> EmergingHypothesisSnapshot {
        let sourceTaskIDs = UUIDPattern.matches(in: markdown)
        var observations: [EmergingHypothesisObservation] = []

        for line in markdown.components(separatedBy: .newlines) {
            let cells = tableCells(line)
            guard cells.count >= 9,
                  cells[0].range(of: #"^O-[A-Z0-9-]+$"#, options: .regularExpression) != nil,
                  let priority = Int(cells.count >= 11 ? cells[7] : (cells.count >= 10 ? cells[6] : cells[5])) else { continue }
            let relation = clean(cells[3])
            let handling = EmergingHypothesisHandling.from(clean(cells[4]))
            let hasExecutionModeColumn = cells.count >= 10
            let hasExecutionKeyColumn = cells.count >= 11
            let id = clean(cells[0])
            let executionMode = EmergingHypothesisExecutionMode.from(
                hasExecutionModeColumn ? clean(cells[5]) : "",
                handling: handling
            )
            observations.append(EmergingHypothesisObservation(
                id: id,
                statement: clean(cells[1]),
                businessStage: clean(cells[2]),
                relatedAssumptionIDs: assumptionIDs(in: relation),
                relationDescription: relation,
                handling: handling,
                executionMode: executionMode,
                executionKey: hasExecutionKeyColumn ? clean(cells[6]) : "legacy",
                priority: priority,
                minimumEvidenceAction: clean(cells[hasExecutionKeyColumn ? 8 : (hasExecutionModeColumn ? 7 : 6)]),
                decisionGate: clean(cells[hasExecutionKeyColumn ? 9 : (hasExecutionModeColumn ? 8 : 7)]),
                promotionGate: clean(cells[hasExecutionKeyColumn ? 10 : (hasExecutionModeColumn ? 9 : 8)]),
                sourceTaskIDs: sourceTaskIDs
            ))
        }

        guard !observations.isEmpty else { throw EmergingHypothesisScannerError.noObservations }
        let fingerprint = SHA256.hash(data: Data(markdown.utf8)).map { String(format: "%02x", $0) }.joined()
        return EmergingHypothesisSnapshot(
            version: metadataValue(named: "版本", in: markdown),
            observations: observations.sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            },
            contentFingerprint: fingerprint
        )
    }
}

private extension EmergingHypothesisScanner {
    static let UUIDPattern = Pattern(#"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#)
    static let assumptionPattern = Pattern(#"\b(?:[SB]-[A-Z]\d+|[DGM]\d+|C\d+)\b"#)

    struct Pattern {
        let regex: NSRegularExpression
        init(_ pattern: String) { regex = try! NSRegularExpression(pattern: pattern) }
        func matches(in value: String) -> [String] {
            let range = NSRange(value.startIndex..., in: value)
            return regex.matches(in: value, range: range).compactMap { match in
                guard let swiftRange = Range(match.range, in: value) else { return nil }
                return String(value[swiftRange])
            }
        }
    }

    static func tableCells(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("|") else { return [] }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false)
            .dropFirst().dropLast()
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func assumptionIDs(in value: String) -> [String] {
        var seen = Set<String>()
        return assumptionPattern.matches(in: value).filter { seen.insert($0).inserted }
    }

    static func clean(_ value: String) -> String {
        value
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func metadataValue(named name: String, in markdown: String) -> String {
        for line in markdown.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: CharacterSet(charactersIn: "> "))
            for separator in ["：", ":"] {
                let marker = "\(name)\(separator)"
                if value.hasPrefix(marker) {
                    return clean(String(value.dropFirst(marker.count)))
                }
            }
        }
        return ""
    }
}
