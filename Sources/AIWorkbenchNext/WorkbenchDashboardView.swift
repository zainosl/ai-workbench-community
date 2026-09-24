import AIWorkbenchCore
import AppKit
import SwiftUI

private enum DeskStyle {
    static let background = Color(red: 0.055, green: 0.064, blue: 0.069)
    static let card = Color(red: 0.105, green: 0.119, blue: 0.123)
    static let stroke = Color.white.opacity(0.09)
    static let mint = Color(red: 0.42, green: 0.91, blue: 0.76)
    static let amber = Color(red: 1.00, green: 0.74, blue: 0.37)
}

private struct DisplayTaskGroup: Identifiable {
    let id: String
    let tasks: [CodexTask]
}

struct WorkbenchDashboardView: View {
    @ObservedObject var store: WorkbenchStore
    let onClose: () -> Void
    @State private var taskLink = ""
    @State private var nextSource: CodexTask?
    @State private var nextTitle = ""
    @State private var nextGoal = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DeskStyle.stroke)
            Group {
                if !store.configuration.configured { setup }
                else {
                    switch store.section {
                    case .business: business
                    case .execution: execution
                    case .codex: codex
                    case .logic: logic
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DeskStyle.background)
        .foregroundStyle(.white)
        .sheet(item: $nextSource) { task in
            VStack(alignment: .leading, spacing: 18) {
                Text("从当前任务开启下一步").font(.title2.bold())
                Text(task.title).foregroundStyle(.secondary)
                TextField("新任务名称", text: $nextTitle)
                TextField("这一步要达成什么目标？", text: $nextGoal, axis: .vertical)
                    .lineLimit(3...6)
                HStack {
                    Spacer()
                    Button("取消") { nextSource = nil }
                    Button("创建草稿") {
                        store.createNextTask(from: task, title: nextTitle, goal: nextGoal)
                        nextSource = nil
                    }
                    .disabled(nextTitle.trimmingCharacters(in: .whitespaces).isEmpty || nextGoal.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(26)
            .frame(width: 490)
        }
        .overlay {
            if store.isControlledUpdating {
                ZStack {
                    Color.black.opacity(0.64)
                    VStack(spacing: 16) {
                        ProgressView().controlSize(.large)
                        Text(store.operationMessage ?? "正在更新资料")
                            .font(.title3.bold())
                        Text("本次更新会记录在工作逻辑中")
                            .foregroundStyle(.secondary)
                    }
                    .padding(34)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 20) {
            Label(store.configuration.displayName, systemImage: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(DeskStyle.mint)
            if store.configuration.configured {
                ForEach(WorkbenchSection.allCases) { section in
                    Button {
                        store.select(section)
                    } label: {
                        Label(section.title, systemImage: section.icon)
                            .font(.system(size: 14, weight: store.section == section ? .semibold : .regular))
                            .foregroundStyle(store.section == section ? .white : .secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(store.section == section ? Color.white.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            if let message = store.operationMessage, !store.isRefreshing {
                Label(message, systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(DeskStyle.amber)
            }
            if store.unreadResultCount > 0 {
                Button { store.isResultInboxPresented.toggle() } label: {
                    Label("新结果 \(store.unreadResultCount)", systemImage: "sparkles")
                        .foregroundStyle(DeskStyle.mint)
                }
                .popover(isPresented: $store.isResultInboxPresented) { resultInbox }
            }
            Button { store.refreshLiveTasks(showSync: true) } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("同步 Codex 任务")
            Button(action: onClose) { Image(systemName: "xmark") }
                .help("收起工作台")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 22)
        .frame(height: 64)
        .background(Color.black.opacity(0.24))
        .overlay(alignment: .bottom) {
            if let error = store.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color(red: 0.24, green: 0.08, blue: 0.08), in: Capsule())
                    .offset(y: 28)
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("先写入你的资料")
                .font(.system(size: 34, weight: .bold))
            Text("工作台不会预装任何人的业务数据。用 Codex 或 WorkBuddy 打开本仓库，让 AI 根据你的情况填写本地模板。")
                .font(.title3)
                .foregroundStyle(.secondary)
            HStack(spacing: 18) {
                setupStep("1", "编辑资料", "打开本机 Workspace 中的 6 个 Markdown 模板")
                setupStep("2", "配置项目", "在 config.json 填写名称与可选项目源")
                setupStep("3", "启用工作台", "资料核对后把 configured 改为 true")
            }
            HStack(spacing: 12) {
                Button("打开资料目录") { store.revealWorkspace() }
                    .buttonStyle(.borderedProminent)
                Button("打开配置文件") { store.revealConfiguration() }
                Button("我已填好，重新读取") { store.refreshConfiguration() }
            }
            .controlSize(.large)
            Text("本地目录：\(store.runtimeRoot.path)")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: 940, alignment: .leading)
        .padding(40)
    }

    private func setupStep(_ number: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(number).font(.title.bold()).foregroundStyle(DeskStyle.mint)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .padding(18)
        .background(DeskStyle.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private var business: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                titleRow("经营画布", subtitle: "读取最新商业模式；不会把任务完成误判为商业证据") {
                    Button("更新经营信息") { store.refreshBusiness() }
                        .buttonStyle(.borderedProminent)
                }
                if let context = store.businessContext {
                    HStack(alignment: .top, spacing: 18) {
                        infoCard("商业模式", context.businessModelSummary)
                        infoCard("整体进展", context.progressSummary)
                        if let milestone = store.assumptionRadar?.milestone {
                            infoCard("当前里程碑 · \(milestone.id)", milestone.title)
                        }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(context.stages) { stage in
                            VStack(alignment: .leading, spacing: 11) {
                                HStack {
                                    Circle().fill(stage.id == context.mainStageID ? DeskStyle.mint : Color.secondary)
                                        .frame(width: 8, height: 8)
                                    Text(stage.name).font(.headline)
                                    Spacer()
                                    Text(stage.status).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(stage.definition)
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.82))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Spacer(minLength: 0)
                                Text(stage.currentAction)
                                    .font(.caption)
                                    .foregroundStyle(DeskStyle.mint)
                            }
                            .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
                            .padding(16)
                            .background(DeskStyle.card, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(DeskStyle.stroke))
                        }
                    }
                    if let user = context.demandUserSummary, let task = context.demandTaskSummary {
                        infoCard("需求 · 用户任务", "\(user)\n\n\(task)")
                    }
                } else {
                    emptyState("还没有读取经营资料", "请检查本地模板，或点击更新经营信息。")
                }
            }
            .padding(24)
        }
    }

    private var execution: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    Text("关键假设").font(.title2.bold())
                    Text("按当前里程碑与依赖判断优先级")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(store.assumptions) { assumption in
                        Button { store.selectedAssumptionID = assumption.id } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text(assumption.id).foregroundStyle(DeskStyle.mint)
                                    Text(assumption.role.title)
                                        .font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(assumption.stage.rawValue)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(assumption.title)
                                    .font(.subheadline.weight(.semibold))
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(store.selectedAssumptionID == assumption.id ? DeskStyle.mint.opacity(0.13) : DeskStyle.card,
                                        in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(18)
            }
            .frame(width: 290)
            Divider().overlay(DeskStyle.stroke)
            if let assumption = store.assumptions.first(where: { $0.id == store.selectedAssumptionID }) {
                assumptionDetail(assumption)
            } else {
                emptyState("还没有假设", "先完善 assumptions.md 与里程碑文件，再更新经营信息。")
            }
        }
    }

    private func assumptionDetail(_ assumption: AssumptionNode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                titleRow("\(assumption.id) · \(assumption.title)",
                         subtitle: "\(assumption.stage.rawValue) · \(assumption.role.title)") {
                    Button("更新此假设") { store.refreshAssumption(assumption.id) }
                        .buttonStyle(.borderedProminent)
                }
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 14) {
                        infoCard("为什么现在验证", assumption.activationReason)
                        infoCard("现在等你做", assumption.currentAction)
                        infoCard("证据门槛", assumption.decisionGate)
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 13) {
                            Text("AI 建议").font(.headline)
                            if let action = store.recommendedAction(for: assumption) {
                                Text(action.summary).font(.subheadline)
                                Text(action.priorityReason)
                                    .font(.caption).foregroundStyle(.secondary)
                                Button(store.task(for: action) == nil ? "准备 Codex 任务草稿" : "打开已有任务") {
                                    store.startRecommendedTask(action, assumption: assumption)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(store.operationMessage != nil)
                            } else {
                                Text("当前不主动推荐新任务；先完成依赖或补充证据。")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .cardStyle()
                        infoCard("证伪的影响", assumption.failureImpact)
                    }
                    .frame(maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("任务上下文").font(.title3.bold())
                        Text("\(store.associatedTasks(for: assumption.id).count)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("历史 / 工作台创建 / 手动关联").font(.caption).foregroundStyle(.secondary)
                    }
                    let linked = store.associatedTasks(for: assumption.id)
                    if linked.isEmpty {
                        Text("暂无关联任务。可以粘贴 Codex 深度链接，也可以从 AI 建议创建草稿。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        taskGrid(linked)
                    }
                    HStack {
                        TextField("粘贴 codex://threads/…", text: $taskLink)
                            .textFieldStyle(.roundedBorder)
                        Button("关联") {
                            store.linkTask(taskLink, to: assumption.id)
                            taskLink = ""
                        }
                        .disabled(taskLink.isEmpty)
                    }
                }
                .cardStyle()
            }
            .padding(22)
        }
    }

    private var codex: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                titleRow("Codex 任务", subtitle: store.connectionMessage) {
                    HStack(spacing: 15) {
                        Label("\(store.runningCount) 运行", systemImage: "circle.fill")
                            .foregroundStyle(DeskStyle.mint)
                        Label("\(store.waitingCount) 等你", systemImage: "clock")
                            .foregroundStyle(DeskStyle.amber)
                        ForEach(store.quotas) { quota in
                            Label("\(quota.label)剩余 \(quota.remainingPercent)%", systemImage: quota.icon)
                        }
                    }
                    .font(.subheadline)
                }
                if store.tasks.isEmpty {
                    emptyState("还没有读取到 Codex 任务", "打开 Codex 并运行任务后，点击右上角同步。")
                } else {
                    taskGrid(store.tasks)
                }
            }
            .padding(24)
        }
    }

    private func taskGrid(_ tasks: [CodexTask]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(taskGroups(tasks)) { group in
                VStack(alignment: .leading, spacing: 10) {
                    if group.tasks.count > 1 {
                        Label("任务链 · \(group.tasks.count) 步", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DeskStyle.mint)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                        ForEach(group.tasks) { task in taskCard(task) }
                    }
                }
                .padding(group.tasks.count > 1 ? 12 : 0)
                .background(group.tasks.count > 1 ? DeskStyle.mint.opacity(0.055) : .clear,
                            in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .stroke(group.tasks.count > 1 ? DeskStyle.mint.opacity(0.25) : .clear))
            }
        }
    }

    private func taskGroups(_ visibleTasks: [CodexTask]) -> [DisplayTaskGroup] {
        let parentByChild = Dictionary(uniqueKeysWithValues: store.taskChains.map {
            ($0.childTaskID, $0.parentTaskID)
        })
        func root(for id: String) -> String {
            var current = id
            var seen = Set<String>()
            while let parent = parentByChild[current], seen.insert(current).inserted {
                current = parent
            }
            return current
        }
        func depth(for id: String) -> Int {
            var current = id
            var seen = Set<String>()
            while let parent = parentByChild[current], seen.insert(current).inserted {
                current = parent
            }
            return seen.count
        }
        let grouped = Dictionary(grouping: visibleTasks, by: { root(for: $0.id) })
        return grouped.map { key, values in
            DisplayTaskGroup(id: key, tasks: values.sorted {
                let left = depth(for: $0.id)
                let right = depth(for: $1.id)
                return left == right ? $0.updatedAt < $1.updatedAt : left < right
            })
        }
        .sorted { ($0.tasks.map(\.updatedAt).max() ?? .distantPast) >
                  ($1.tasks.map(\.updatedAt).max() ?? .distantPast) }
    }

    private func taskCard(_ task: CodexTask) -> some View {
        let parent = store.taskChains.first(where: { $0.childTaskID == task.id })
        return Button {
            store.markResultRead(task)
            store.open(task)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Image(systemName: task.displayStatusIcon)
                        .foregroundStyle(task.displayStatusColor)
                    Text(task.displayStatusTitle)
                        .foregroundStyle(task.displayStatusColor)
                    Spacer()
                    Text(task.relativeTime).foregroundStyle(.tertiary)
                }
                .font(.caption)
                Text(task.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(task.projectName)
                    .font(.caption).foregroundStyle(DeskStyle.mint)
                    .lineLimit(1)
                if let parent {
                    Text("↳ 来自 \(store.tasks.first(where: { $0.id == parent.parentTaskID })?.title ?? "上一步任务")")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let activity = task.displayLatestActivity {
                    Text(activity).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                HStack {
                    Text("上下文 \(task.contextPercent)%")
                    Spacer()
                    Text(task.tokenLabel)
                }
                .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 125, alignment: .topLeading)
            .padding(14)
            .background(DeskStyle.card, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(DeskStyle.stroke))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("从此任务开启下一步") {
                nextTitle = "\(task.title) · 下一步"
                nextGoal = ""
                nextSource = task
            }
            Button("核对已有假设的证据与反证") {
                store.startAnalysis(for: task, kind: .existingEvidence)
            }
            Button("提炼新假设") {
                store.startAnalysis(for: task, kind: .emergingHypotheses)
            }
            Button("提出沉淀建议") { store.startDepositReview(for: task) }
        }
    }

    private var logic: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                titleRow("工作逻辑与更新历史", subtitle: "每次读取、判断和操作均记录为可追查的本地日志") {
                    Button("打开本地配置") { store.revealConfiguration() }
                }
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("运行原则").font(.title3.bold())
                        ForEach(store.rules.filter(\.enabled)) { rule in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(rule.id) · \(rule.name)").font(.subheadline.bold())
                                Text(rule.reason).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    .cardStyle()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("最近事件").font(.title3.bold())
                        ForEach(store.recentEvents) { event in
                            HStack(alignment: .top) {
                                Text(event.timestamp, style: .time)
                                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(event.summary).font(.subheadline)
                                    Text(event.ruleIDs.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(DeskStyle.mint)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 5)
                            Divider().overlay(DeskStyle.stroke)
                        }
                    }
                    .cardStyle()
                }
            }
            .padding(24)
        }
    }

    private var resultInbox: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("新结果").font(.headline)
                Spacer()
                Button("全部已读") { store.markAllResultsRead() }
            }
            ForEach(store.unreadResultTasks) { task in
                Button {
                    store.markResultRead(task)
                    store.isResultInboxPresented = false
                    store.select(.codex)
                    store.open(task)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title).lineLimit(1)
                        Text(task.projectName).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(18)
        .frame(width: 360)
    }

    private func titleRow<Actions: View>(_ title: String, subtitle: String,
                                         @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 25, weight: .bold))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            actions()
        }
    }

    private func infoCard(_ title: String, _ content: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).foregroundStyle(DeskStyle.mint)
            Text(content.isEmpty ? "待填写" : content)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.84))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .cardStyle()
    }

    private func emptyState(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "square.dashed").font(.largeTitle).foregroundStyle(DeskStyle.mint)
            Text(title).font(.title3.bold())
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension View {
    func cardStyle() -> some View {
        self.padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(DeskStyle.card, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(DeskStyle.stroke))
    }
}
