import AIWorkbenchCore
import AppKit
import Foundation
import SwiftUI

@MainActor
final class WorkbenchStore: ObservableObject {
    @Published var configuration: WorkbenchConfiguration
    @Published var section: WorkbenchSection = .business
    @Published var tasks: [CodexTask] = []
    @Published var businessContext: BusinessContextSnapshot?
    @Published var assumptionRadar: AssumptionRadarSnapshot?
    @Published var emergingHypotheses: EmergingHypothesisSnapshot?
    @Published var projectContexts: [String: ProjectContextSnapshot] = [:]
    @Published var taskAssociations: [HypothesisTaskAssociationRecord] = []
    @Published var taskChains: [TaskChainRecord] = []
    @Published var readResultRevisions: [String: String] = [:]
    @Published var recentEvents: [RunEvent] = []
    @Published var quotas: [QuotaMetric] = []
    @Published var creditBalance = "—"
    @Published var connectionMessage = "正在连接 Codex"
    @Published var isRefreshing = false
    @Published var isLiveTaskSyncing = false
    @Published var isResultInboxPresented = false
    @Published var operationMessage: String?
    @Published var errorMessage: String?
    @Published var selectedAssumptionID: String?

    let appVersion = "0.1.0"
    let runtimeRoot: URL
    private let client = AppServerClient()
    private let ledger: RunLedger
    private let associationStore: HypothesisTaskAssociationStore
    private let chainStore: TaskChainStore
    private let readRevisionsURL: URL
    private var liveTimer: Timer?
    private var liveScanInFlight = false
    private var allScanInFlight = false
    private var currentRunID: String?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        runtimeRoot = support.appendingPathComponent("AIWorkbenchCommunity", isDirectory: true)
        configuration = try! WorkbenchConfiguration.bootstrap(at: runtimeRoot)
        ledger = try! RunLedger(rootURL: runtimeRoot.appendingPathComponent("Logs", isDirectory: true))
        associationStore = HypothesisTaskAssociationStore(
            fileURL: runtimeRoot.appendingPathComponent("Associations/hypothesis-task-links.json")
        )
        chainStore = TaskChainStore(
            fileURL: runtimeRoot.appendingPathComponent("Associations/task-chains.json")
        )
        readRevisionsURL = runtimeRoot.appendingPathComponent("Results/read-revisions.json")
        taskAssociations = (try? associationStore.load()) ?? []
        taskChains = (try? chainStore.load()) ?? []
        if let data = try? Data(contentsOf: readRevisionsURL) {
            readResultRevisions = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        reloadEvents()
    }

    var isControlledUpdating: Bool { isRefreshing }
    var runningCount: Int { tasks.filter { !$0.isArchived && $0.status == .running }.count }
    var waitingCount: Int { tasks.filter { !$0.isArchived && $0.status == .waiting }.count }
    var unreadResultTasks: [CodexTask] {
        tasks.filter { task in
            !task.isArchived && task.resultRevision != nil &&
                readResultRevisions[task.id] != task.resultRevision
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
    var unreadResultCount: Int { unreadResultTasks.count }
    var rules: [WorkbenchRule] { RuleCatalog.defaults }
    var assumptions: [AssumptionNode] { assumptionRadar?.assumptions ?? [] }

    func start() {
        recordUserAction("启动工作台")
        client.onNotification = { [weak self] method, _ in
            if method.contains("thread") || method.contains("turn") {
                self?.refreshLiveTasks()
            }
        }
        client.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.connectionMessage = "已连接 Codex"
                self.refreshQuotas()
            case .failure(let error):
                self.connectionMessage = error.localizedDescription
            }
        }
        if configuration.configured { refreshBusiness() }
        refreshAllTasks()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLiveTasks() }
        }
    }

    func stop() {
        liveTimer?.invalidate()
        liveTimer = nil
        client.stop()
    }

    func select(_ value: WorkbenchSection) {
        section = value
        isResultInboxPresented = false
    }

    func prepareNotchDestination() {
        if unreadResultCount > 0 { section = .codex }
        else if waitingCount > 0 { section = .execution }
    }

    func refreshConfiguration() {
        do {
            configuration = try WorkbenchConfiguration.bootstrap(at: runtimeRoot)
            if configuration.configured { refreshBusiness() }
            else {
                businessContext = nil
                assumptionRadar = nil
                emergingHypotheses = nil
            }
        } catch {
            errorMessage = "读取配置失败：\(error.localizedDescription)"
        }
    }

    func revealWorkspace() {
        NSWorkspace.shared.activateFileViewerSelecting([configuration.workspaceURL])
    }

    func revealConfiguration() {
        NSWorkspace.shared.activateFileViewerSelecting([runtimeRoot.appendingPathComponent("config.json")])
    }

    func refreshBusiness() {
        guard !isRefreshing else { return }
        do {
            configuration = try WorkbenchConfiguration.bootstrap(at: runtimeRoot)
            guard configuration.configured else {
                errorMessage = "请先填写资料，并在 config.json 中把 configured 改为 true。"
                return
            }
        } catch {
            errorMessage = "读取配置失败：\(error.localizedDescription)"
            return
        }
        isRefreshing = true
        operationMessage = "读取商业模式、里程碑与假设"
        errorMessage = nil
        let config = configuration
        let runID = beginRun("更新经营页面", details: ["scope": "business"])
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let business = try BusinessContextScanner.scan(entryURL: config.fileURL("business.md"))
                let radar = try AssumptionRadarScanner.scan(
                    assumptionsURL: config.fileURL("assumptions.md"),
                    dependenciesURL: config.fileURL("dependencies.md"),
                    milestoneURL: config.fileURL("milestone.md"),
                    priorityURL: config.fileURL("priorities.md"),
                    businessContext: business
                )
                let emerging = try? EmergingHypothesisScanner.scan(url: config.fileURL("emerging.md"))
                DispatchQueue.main.async {
                    self.businessContext = business
                    self.assumptionRadar = radar
                    self.emergingHypotheses = emerging
                    self.selectedAssumptionID = self.selectedAssumptionID
                        ?? radar.assumptions.first?.id
                    self.record(
                        runID: runID,
                        phase: .result,
                        summary: "经营页面更新完成",
                        details: [
                            "businessVersion": business.contextVersion,
                            "milestone": radar.milestone.id,
                            "assumptions": "\(radar.assumptions.count)"
                        ],
                        rules: ["SOURCE-001", "PROGRESS-001", "UPDATE-001"]
                    )
                    self.isRefreshing = false
                    self.operationMessage = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.record(
                        runID: runID,
                        level: .error,
                        phase: .result,
                        summary: "经营页面更新失败",
                        details: ["error": error.localizedDescription]
                    )
                    self.errorMessage = error.localizedDescription
                    self.isRefreshing = false
                    self.operationMessage = nil
                }
            }
        }
    }

    func refreshAssumption(_ assumptionID: String) {
        guard !isRefreshing, !allScanInFlight else { return }
        let linked = associatedTasks(for: assumptionID)
        guard !linked.contains(where: { $0.status == .running && !$0.isArchived }) else {
            errorMessage = "关联任务还在运行，结束后再更新此假设。"
            return
        }
        isRefreshing = true
        operationMessage = "更新 \(assumptionID) 的任务、项目与结果"
        errorMessage = nil
        let config = configuration
        let runID = beginRun("更新关键假设", details: ["assumption": assumptionID])
        DispatchQueue.global(qos: .userInitiated).async {
            let scanned = SessionScanner.scanAll().tasks
            let projects = Self.scanProjects(config.projects, configuration: config)
            DispatchQueue.main.async {
                self.tasks = scanned
                self.projectContexts = projects
                self.record(
                    runID: runID,
                    phase: .result,
                    summary: "假设任务与项目资料更新完成",
                    details: [
                        "assumption": assumptionID,
                        "linkedTasks": "\(self.associatedTasks(for: assumptionID).count)",
                        "projects": "\(projects.count)"
                    ],
                    rules: ["TASK-001", "ARCHIVE-001", "UPDATE-001"]
                )
                self.isRefreshing = false
                self.operationMessage = nil
            }
        }
    }

    func refreshAllTasks() {
        guard !allScanInFlight else { return }
        allScanInFlight = true
        DispatchQueue.global(qos: .utility).async {
            let scanned = SessionScanner.scanAll().tasks
            DispatchQueue.main.async {
                self.allScanInFlight = false
                self.applyTasks(scanned, replace: true)
            }
        }
    }

    func refreshLiveTasks(showSync: Bool = false) {
        guard !liveScanInFlight, !allScanInFlight else { return }
        liveScanInFlight = true
        if showSync { isLiveTaskSyncing = true }
        DispatchQueue.global(qos: .userInitiated).async {
            let scanned = SessionScanner.scan(limit: 40, candidateFloor: 50).tasks
            let titles = SessionScanner.currentThreadTitles()
            let archived = SessionScanner.archivedThreadIDs()
            DispatchQueue.main.async {
                self.liveScanInFlight = false
                self.isLiveTaskSyncing = false
                var merged = Dictionary(uniqueKeysWithValues: self.tasks.map { ($0.id, $0) })
                for task in scanned { merged[task.id] = task }
                for id in Array(merged.keys) {
                    guard var task = merged[id] else { continue }
                    task.isArchived = archived.contains(id)
                    if task.isArchived {
                        task.status = .idle
                        task.waitingPrompt = nil
                    }
                    if let title = titles[id], !title.isEmpty { task.title = title }
                    merged[id] = task
                }
                self.applyTasks(Array(merged.values), replace: true)
            }
        }
    }

    private func applyTasks(_ scanned: [CodexTask], replace: Bool) {
        let firstLoad = tasks.isEmpty && !FileManager.default.fileExists(atPath: readRevisionsURL.path)
        tasks = scanned.sorted { $0.updatedAt > $1.updatedAt }
        if firstLoad {
            for task in tasks {
                if let revision = task.resultRevision {
                    readResultRevisions[task.id] = revision
                }
            }
            persistReadRevisions()
        }
    }

    nonisolated private static func scanProjects(
        _ sources: [ProjectSource],
        configuration: WorkbenchConfiguration
    ) -> [String: ProjectContextSnapshot] {
        var result: [String: ProjectContextSnapshot] = [:]
        for source in sources {
            let url = { (path: String) in configuration.projectURL(path, rootPath: source.rootPath) }
            guard let snapshot = try? ProjectContextScanner.scan(
                id: source.id,
                displayName: source.name,
                rootPath: source.rootPath,
                overviewURL: url(source.overview),
                progressURL: url(source.progress),
                preferenceURL: url(source.preferences),
                assumptionsURL: url(source.assumptions),
                resultURL: url(source.result)
            ) else { continue }
            result[source.id] = snapshot
        }
        return result
    }

    func associatedTasks(for assumptionID: String) -> [CodexTask] {
        let ids = Set(taskAssociations.filter {
            $0.primaryAssumptionID == assumptionID ||
                $0.supportingAssumptionIDs.contains(assumptionID)
        }.map(\.taskID))
        let explicit = tasks.filter { ids.contains($0.id) }
        let inferred = tasks.filter {
            !ids.contains($0.id) && $0.title.localizedCaseInsensitiveContains(assumptionID)
        }
        return (explicit + inferred).sorted { $0.updatedAt > $1.updatedAt }
    }

    func association(for taskID: String) -> HypothesisTaskAssociationRecord? {
        taskAssociations.filter { $0.taskID == taskID }
            .sorted { $0.createdAt > $1.createdAt }.first
    }

    func project(for assumptionID: String) -> ProjectContextSnapshot? {
        let projectID = taskAssociations.first {
            $0.primaryAssumptionID == assumptionID ||
                $0.supportingAssumptionIDs.contains(assumptionID)
        }?.projectID
        return projectID.flatMap { projectContexts[$0] }
    }

    func recommendedAction(for assumption: AssumptionNode) -> RecommendedAIAction? {
        guard assumption.role == .primary || assumption.role == .supporting else { return nil }
        let action = assumption.currentAction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty else { return nil }
        let project = project(for: assumption.id)
        let source = project?.displayName ?? configuration.displayName
        let prompt = """
        你正在协助推进关键假设 \(assumption.id)：\(assumption.title)。
        当前业务里程碑：\(assumptionRadar?.milestone.id ?? "待配置")。
        这条假设在五步法中属于：\(assumption.stage.rawValue)。
        当前最小动作：\(action)
        判定门槛：\(assumption.decisionGate)
        若证伪的影响：\(assumption.failureImpact)

        请读取 \(configuration.fileURL("business.md").path)、\(configuration.fileURL("assumptions.md").path)、
        \(configuration.fileURL("milestone.md").path) 和 \(configuration.fileURL("priorities.md").path)。
        \(project.map { "也请读取项目资料目录：\($0.rootPath)。" } ?? "")

        先核对已有证据与反证，再决定下一步最短的真实验证动作。若能由 AI 完成准备工作，
        请直接产出可用材料或执行包；若需要人做选择、联系他人或观察现实行为，请清楚指出。
        资料、计划和任务完成本身不能作为业务假设成立的证据。不要自动发送、发布或改写商业底库。
        """
        return RecommendedAIAction(
            id: "verify-\(assumption.id)",
            priority: assumption.selectionOrder == 999 ? 9 : assumption.selectionOrder + 1,
            priorityLabel: assumption.role.title,
            priorityReason: assumption.activationReason,
            title: "准备最小验证",
            summary: action,
            taskTitle: "\(source) · \(assumption.id) · 最小验证",
            supportingAssumptionIDs: [],
            promptGoal: prompt
        )
    }

    func task(for action: RecommendedAIAction) -> CodexTask? {
        guard let link = taskAssociations.first(where: { $0.actionID == action.id }) else { return nil }
        return tasks.first(where: { $0.id == link.taskID }) ?? SessionScanner.task(id: link.taskID)
    }

    func startRecommendedTask(_ action: RecommendedAIAction, assumption: AssumptionNode) {
        if let existing = task(for: action) {
            open(existing)
            return
        }
        let project = project(for: assumption.id)
        startDraft(
            title: action.taskTitle,
            prompt: action.promptGoal,
            cwd: project?.rootPath ?? configuration.workspaceURL.path,
            assumptionID: assumption.id,
            projectID: project?.id ?? "business",
            actionID: action.id
        )
    }

    func startAnalysis(for task: CodexTask, kind: TaskHypothesisAnalysisKind) {
        let actionID = "analysis-\(kind.rawValue)-\(task.id)"
        if let link = taskAssociations.first(where: { $0.actionID == actionID }),
           let existing = tasks.first(where: { $0.id == link.taskID }) ?? SessionScanner.task(id: link.taskID) {
            open(existing)
            return
        }
        let sourceLink = association(for: task.id)
        let instruction: String
        switch kind {
        case .existingEvidence:
            instruction = """
            核对这条任务对当前关键假设库中的假设产生了什么证据。
            先找证伪和强反证，再找削弱、支持和未知。逐条给出来源与原始行为。
            没有真实用户、市场、支付或交付行为时，只能标记为材料或推断。
            输出建议更新清单，等待我决定是否写入底库。
            """
        case .emergingHypotheses:
            instruction = """
            检查这条任务是否带来了新的、可证伪的经营判断。
            与已有假设去重，标明五步法位置、来源事实、关联假设、失败影响、
            最小取证动作与优先级。只给观察池更新建议，等待我决定是否写入。
            """
        }
        let prompt = """
        来源 Codex 任务：codex://threads/\(task.id)
        当前任务名称：\(task.title)
        商业模式资料：\(configuration.fileURL("business.md").path)
        当前关键假设：\(configuration.fileURL("assumptions.md").path)
        新兴观察池：\(configuration.fileURL("emerging.md").path)

        \(instruction)
        """
        startDraft(
            title: "\(task.title) · \(kind.taskTitle)",
            prompt: prompt,
            cwd: task.projectKey,
            assumptionID: sourceLink?.primaryAssumptionID,
            projectID: sourceLink?.projectID ?? "business",
            actionID: actionID,
            parentTaskID: task.id
        )
    }

    func startDepositReview(for task: CodexTask) {
        let sourceLink = association(for: task.id)
        let prompt = """
        来源任务：codex://threads/\(task.id)
        经营资料目录：\(configuration.workspaceURL.path)

        请分析这次结果是否产生了新的经营认知。只提出候选沉淀：
        哪个现有假设得到支持、削弱或证伪；是否出现新假设；哪个里程碑门槛可能变化。
        每条写明原始证据、建议写入的具体文件与位置、写入后的影响，以及“现在写/继续补证/暂不写”。
        先给我可审阅的提案；未经我明确确认，不修改任何商业资料。
        """
        startDraft(
            title: "\(task.title) · 沉淀审阅",
            prompt: prompt,
            cwd: task.projectKey,
            assumptionID: sourceLink?.primaryAssumptionID,
            projectID: sourceLink?.projectID ?? "business",
            actionID: "deposit-\(task.id)",
            parentTaskID: task.id
        )
    }

    func createNextTask(from task: CodexTask, title: String, goal: String) {
        let sourceLink = association(for: task.id)
        let prompt = """
        这是来源任务 codex://threads/\(task.id) 的下一步。
        请先读取来源任务完整上下文。

        本次目标：\(goal)
        当前经营资料：\(configuration.workspaceURL.path)
        请明确已有事实、仍需我决定的事项和可由 AI 独立完成的工作。
        不要把任务完成当作商业验证，也不要自动发送或发布。
        """
        startDraft(
            title: title,
            prompt: prompt,
            cwd: task.projectKey,
            assumptionID: sourceLink?.primaryAssumptionID,
            projectID: sourceLink?.projectID ?? "business",
            actionID: "next-\(UUID().uuidString)",
            parentTaskID: task.id
        )
    }

    private func startDraft(
        title: String,
        prompt: String,
        cwd: String,
        assumptionID: String?,
        projectID: String,
        actionID: String,
        parentTaskID: String? = nil
    ) {
        guard operationMessage == nil else { return }
        operationMessage = "正在创建 Codex 任务草稿"
        errorMessage = nil
        let runID = beginRun("创建任务草稿", details: [
            "actionID": actionID,
            "assumption": assumptionID ?? ""
        ])
        let safeCWD = FileManager.default.fileExists(atPath: cwd)
            ? cwd : configuration.workspaceURL.path
        client.prepareTaskDraft(title: title, cwd: safeCWD) { [weak self] result in
            guard let self else { return }
            self.client.stop {
                self.operationMessage = nil
                switch result {
                case .failure(let error):
                    self.errorMessage = "任务创建失败：\(error.localizedDescription)"
                    self.record(runID: runID, level: .error, phase: .result,
                                summary: "任务草稿创建失败",
                                details: ["error": error.localizedDescription])
                    self.client.start { _ in }
                case .success(let draft):
                    if let assumptionID {
                        self.taskAssociations.removeAll { $0.taskID == draft.threadID }
                        self.taskAssociations.append(HypothesisTaskAssociationRecord(
                            taskID: draft.threadID,
                            projectID: projectID,
                            primaryAssumptionID: assumptionID,
                            supportingAssumptionIDs: [],
                            businessContextVersion: self.businessContext?.contextVersion ?? "",
                            projectContextFingerprint: self.projectContexts[projectID]?.contentFingerprint ?? "",
                            source: .workbenchDispatch,
                            actionID: actionID
                        ))
                        try? self.associationStore.save(self.taskAssociations)
                    }
                    if let parentTaskID {
                        self.taskChains.append(TaskChainRecord(
                            parentTaskID: parentTaskID,
                            childTaskID: draft.threadID,
                            userDefinedGoal: title
                        ))
                        try? self.chainStore.save(self.taskChains)
                    }
                    self.record(runID: runID, phase: .result, summary: "任务草稿已创建",
                                details: ["taskID": draft.threadID, "parentTaskID": parentTaskID ?? ""])
                    self.refreshAllTasks()
                    self.openDraft(threadID: draft.threadID, prompt: prompt)
                    self.client.start { _ in }
                }
            }
        }
    }

    private func openDraft(threadID: String, prompt: String) {
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/\(threadID)"
        components.queryItems = [URLQueryItem(name: "prompt", value: prompt)]
        guard let url = components.url, NSWorkspace.shared.open(url) else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt, forType: .string)
            errorMessage = "Codex 未能打开草稿，提示词已复制，可粘贴到新任务。"
            return
        }
    }

    func linkTask(_ deepLink: String, to assumptionID: String) {
        guard let id = Self.taskID(from: deepLink),
              let task = tasks.first(where: { $0.id == id }) ?? SessionScanner.task(id: id) else {
            errorMessage = "没有找到这条 Codex 任务，请检查链接。"
            return
        }
        taskAssociations.removeAll { $0.taskID == id }
        taskAssociations.append(HypothesisTaskAssociationRecord(
            taskID: id,
            projectID: configuration.projects.first(where: {
                task.projectKey.hasPrefix(($0.rootPath as NSString).expandingTildeInPath)
            })?.id ?? "business",
            primaryAssumptionID: assumptionID,
            supportingAssumptionIDs: [],
            businessContextVersion: businessContext?.contextVersion ?? "",
            projectContextFingerprint: "",
            source: .manualImport
        ))
        do {
            try associationStore.save(taskAssociations)
            if !tasks.contains(where: { $0.id == id }) { tasks.append(task) }
            errorMessage = nil
            recordUserAction("手动关联任务", details: ["taskID": id, "assumption": assumptionID])
        } catch {
            errorMessage = "保存关联失败：\(error.localizedDescription)"
        }
    }

    nonisolated private static func taskID(from link: String) -> String? {
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        guard let range = link.range(of: pattern, options: .regularExpression) else { return nil }
        return String(link[range]).lowercased()
    }

    func open(_ task: CodexTask) {
        guard let url = URL(string: "codex://threads/\(task.id)") else { return }
        if !NSWorkspace.shared.open(url) {
            errorMessage = "Codex 无法打开这条任务。"
        }
    }

    func markResultRead(_ task: CodexTask) {
        guard let revision = task.resultRevision else { return }
        readResultRevisions[task.id] = revision
        persistReadRevisions()
    }

    func markAllResultsRead() {
        for task in unreadResultTasks {
            if let revision = task.resultRevision { readResultRevisions[task.id] = revision }
        }
        persistReadRevisions()
    }

    private func persistReadRevisions() {
        try? FileManager.default.createDirectory(
            at: readRevisionsURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(readResultRevisions) {
            try? data.write(to: readRevisionsURL, options: .atomic)
        }
    }

    func recordUserAction(_ summary: String, details: [String: String] = [:]) {
        record(runID: currentRunID ?? beginRun("工作台交互"), phase: .userAction,
               summary: summary, details: details)
    }

    private func beginRun(_ trigger: String, details: [String: String] = [:]) -> String {
        let id = (try? ledger.beginRun(
            trigger: trigger,
            contextVersion: businessContext?.contextVersion,
            details: details
        )) ?? "run-\(UUID().uuidString)"
        currentRunID = id
        reloadEvents()
        return id
    }

    private func record(
        runID: String,
        level: RunEventLevel = .info,
        phase: RunEventPhase,
        summary: String,
        details: [String: String] = [:],
        rules: [String] = []
    ) {
        try? ledger.append(RunEvent(
            runID: runID,
            level: level,
            phase: phase,
            summary: summary,
            details: details,
            contextVersion: businessContext?.contextVersion,
            ruleIDs: rules
        ))
        reloadEvents()
    }

    func reloadEvents() {
        recentEvents = (try? ledger.events(limit: 100))?.reversed() ?? []
    }

    private func refreshQuotas() {
        client.sendRequest(method: "account/rateLimits/read") { [weak self] result in
            guard let self else { return }
            guard case .success(let payload) = result else { return }
            var metrics: [QuotaMetric] = []
            let namedLimits = payload["rateLimitsByLimitId"] as? [String: Any] ?? [:]
            if !namedLimits.isEmpty {
                for (key, value) in namedLimits.sorted(by: { $0.key < $1.key }) {
                    guard let snapshot = value as? [String: Any] else { continue }
                    let name = (snapshot["limitName"] as? String) ?? (key == "codex" ? "通用" : key)
                    for windowKey in ["primary", "secondary"] {
                        guard let window = snapshot[windowKey] as? [String: Any] else { continue }
                        metrics.append(Self.quota(id: "\(key)-\(windowKey)", fallbackLabel: name,
                                                  icon: "bolt", window: window))
                    }
                }
            } else if let general = payload["rateLimits"] as? [String: Any] {
                for key in ["primary", "secondary"] {
                    guard let window = general[key] as? [String: Any] else { continue }
                    metrics.append(Self.quota(id: "general-\(key)", fallbackLabel: "通用",
                                              icon: "calendar", window: window))
                }
            }
            if let general = payload["rateLimits"] as? [String: Any],
               let credits = general["credits"] as? [String: Any] {
                self.creditBalance = (credits["balance"] as? String)
                    ?? (credits["balance"] as? NSNumber)?.stringValue ?? "—"
            }
            self.quotas = metrics
        }
    }

    private static func quota(id: String, fallbackLabel: String, icon: String,
                              window: [String: Any]) -> QuotaMetric {
        let used = AppServerClient.int(window["usedPercent"]) ?? 0
        let reset = AppServerClient.int64(window["resetsAt"])
        let minutes = AppServerClient.int(window["windowDurationMins"])
        let period: String
        switch minutes {
        case 300: period = "5 小时"
        case 10080: period = "每周"
        case .some(let value): period = "\(value) 分钟"
        case .none: period = "额度"
        }
        return QuotaMetric(
            id: id, icon: icon, remainingPercent: max(0, min(100, 100 - used)),
            label: "\(fallbackLabel) · \(period)",
            resetAt: reset.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}
