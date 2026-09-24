import Foundation

public enum DiagnosticExporter {
    public static func export(
        to parentURL: URL,
        appVersion: String,
        logicVersion: String,
        selectedRunID: String? = nil,
        events: [RunEvent],
        rules: [WorkbenchRule],
        businessContext: BusinessContextSnapshot?
    ) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = parentURL.appendingPathComponent("AI-Workbench-Diagnostic-\(formatter.string(from: Date()))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let filtered = selectedRunID.map { id in events.filter { $0.runID == id } } ?? events
        let safeEvents = filtered.map { $0.redacted() }
        let manifest = DiagnosticManifest(
            generatedAt: Date(),
            appVersion: appVersion,
            logicVersion: logicVersion,
            selectedRunID: selectedRunID,
            eventCount: safeEvents.count,
            businessContextVersion: businessContext?.contextVersion,
            privacyMode: "metadata-only-redacted"
        )

        try CoreCoding.encoder(pretty: true).encode(manifest)
            .write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        try CoreCoding.encoder(pretty: true).encode(rules)
            .write(to: folder.appendingPathComponent("rules.json"), options: .atomic)
        if let businessContext {
            try CoreCoding.encoder(pretty: true).encode(redactedContext(businessContext))
                .write(to: folder.appendingPathComponent("business-context.json"), options: .atomic)
        }

        var eventData = Data()
        for event in safeEvents {
            eventData.append(try CoreCoding.encoder().encode(event))
            eventData.append(0x0A)
        }
        try eventData.write(to: folder.appendingPathComponent("events.jsonl"), options: .atomic)

        let readme = """
        # AI Workbench Next 诊断包

        - 生成时间：\(ISO8601DateFormatter().string(from: Date()))
        - 应用版本：\(appVersion)
        - 逻辑版本：\(logicVersion)
        - 运行编号：\(selectedRunID ?? "全部选定事件")
        - 隐私模式：默认脱敏，不含客户原文、提示词、密钥或完整文件内容

        文件说明：

        - `manifest.json`：诊断范围与版本
        - `events.jsonl`：结构化运行轨迹
        - `rules.json`：当时启用的工作规则
        - `business-context.json`：脱敏后的商业上下文摘要（如可用）
        """
        try readme.write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        return folder
    }

    private static func redactedContext(_ context: BusinessContextSnapshot) -> BusinessContextSnapshot {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        return BusinessContextSnapshot(
            sourcePath: context.sourcePath.replacingOccurrences(of: homePath, with: "$USER_HOME"),
            version: context.version,
            calibratedAt: context.calibratedAt,
            businessModelSummary: context.businessModelSummary,
            progressSummary: context.progressSummary,
            stages: context.stages,
            mainStageID: context.mainStageID,
            parallelStageIDs: context.parallelStageIDs,
            nextStageID: context.nextStageID,
            contentFingerprint: context.contentFingerprint,
            demandUserSummary: context.demandUserSummary,
            demandTaskSummary: context.demandTaskSummary,
            demandExclusionSummary: context.demandExclusionSummary,
            scannedAt: context.scannedAt
        )
    }
}
