import AppKit
import Carbon
import Combine
import QuartzCore
import SwiftUI

final class WorkbenchPanel: NSPanel {
    var onUserActivity: (() -> Void)?
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown,
           modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v",
           NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) {
            onUserActivity?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            onUserActivity?()
            onEscape?()
            return
        }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
             .mouseMoved, .scrollWheel, .keyDown:
            onUserActivity?()
        default:
            break
        }
        // Hover can reveal the dashboard without activating the app. Promote the
        // panel on the first real click so SwiftUI text fields receive key input.
        if event.type == .leftMouseDown, !isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            makeKeyAndOrderFront(nil)
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

private enum IslandMode: Equatable {
    case compact
    case preview
    case dashboard
}

@MainActor
private final class IslandPresentation: ObservableObject {
    @Published var mode: IslandMode = .compact
    @Published var notchBarWidth: CGFloat = 369
    @Published var notchBarHeight: CGFloat = 38
    @Published var notchCutoutWidth: CGFloat = 209
}

private struct NotchLayout {
    let barWidth: CGFloat
    let barHeight: CGFloat
    let cutoutWidth: CGFloat
}

@MainActor
final class WorkbenchPanelController {
    private let store: WorkbenchStore
    private let presentation = IslandPresentation()
    private let panel: WorkbenchPanel
    private var localKeyMonitor: Any?
    private var systemObservers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private var repositionWorkItems: [DispatchWorkItem] = []
    private var screenRecoveryRequestWorkItem: DispatchWorkItem?
    private var pendingScreenRecoveryReasons: [String] = []
    private var pendingHotKeyReinstall = false
    private var pendingLiveTaskRefresh = false
    private var observedUnreadRevisions: [String: String] = [:]
    private var observedWaitingTaskIDs = Set<String>()
    private var hasObservedAttentionState = false
    private var hoverWorkItem: DispatchWorkItem?
    private var previewCollapseWorkItem: DispatchWorkItem?
    private var idleCollapseWorkItem: DispatchWorkItem?
    private var resignWorkItem: DispatchWorkItem?
    private var presentationWorkItem: DispatchWorkItem?
    private var globalHotKey: GlobalHotKey?
    private var dashboardEscapeHotKey: GlobalHotKey?
    private var hoverRequiresExit = false
    private var automaticPresentationSuppressedUntil: TimeInterval = 0
    private let idleCollapseDelay: TimeInterval = 60
    private let postCollapseSuppressionDelay: TimeInterval = 1.2

    init(store: WorkbenchStore) {
        self.store = store
        panel = WorkbenchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 38),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.onUserActivity = { [weak self] in self?.scheduleIdleCollapse() }
        panel.onEscape = { [weak self] in self?.hide() }
        updateNotchMetrics()
        panel.contentView = NSHostingView(rootView: WorkbenchIslandRoot(
            store: store,
            presentation: presentation,
            onOpen: { [weak self] in self?.show() },
            onClose: { [weak self] in self?.hide() },
            onHover: { [weak self] in self?.handleHover($0) }
        ))
        panel.setFrame(compactFrame(), display: false)
        installMonitors()
        installGlobalHotKey()
        installSystemObservers()
        observeAttentionChanges()
        panel.orderFrontRegardless()
        if ProcessInfo.processInfo.arguments.contains("--expanded") {
            DispatchQueue.main.async { [weak self] in self?.show() }
        }
    }

    func show(activate: Bool = true) {
        hoverWorkItem?.cancel()
        previewCollapseWorkItem?.cancel()
        idleCollapseWorkItem?.cancel()
        resignWorkItem?.cancel()
        presentationWorkItem?.cancel()
        // Expanding is an explicit request to see the current Codex state.
        // Reconcile titles as well as status before the user starts reading.
        store.refreshLiveTasks(showSync: true)
        store.recordUserAction("展开工作台")
        updateNotchMetrics()
        installDashboardEscapeHotKey()
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else { panel.orderFrontRegardless() }
        // Resizing a complex SwiftUI dashboard every animation frame causes
        // visible hitching. Give the window its final geometry once, then let
        // only the lightweight content transition animate.
        panel.setFrame(expandedFrame(), display: false)
        withAnimation(.easeOut(duration: 0.18)) { presentation.mode = .dashboard }
        scheduleIdleCollapse()
    }

    func hide() {
        hoverWorkItem?.cancel()
        previewCollapseWorkItem?.cancel()
        idleCollapseWorkItem?.cancel()
        resignWorkItem?.cancel()
        presentationWorkItem?.cancel()
        guard presentation.mode != .compact else { return }
        // The pointer often remains over the notch after a click or keyboard
        // collapse. Requiring one real hover exit prevents the hover preview
        // from immediately reopening what Esc/the shortcut just closed.
        hoverRequiresExit = true
        automaticPresentationSuppressedUntil = ProcessInfo.processInfo.systemUptime + postCollapseSuppressionDelay
        dashboardEscapeHotKey = nil
        store.recordUserAction("收起工作台")
        withAnimation(.easeIn(duration: 0.12)) { presentation.mode = .compact }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.presentation.mode == .compact else { return }
            self.panel.setFrame(self.compactFrame(), display: false)
            self.panel.resignKey()
            self.panel.orderFrontRegardless()
        }
        presentationWorkItem = item
        resignWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    private func toggleFromGlobalHotKey() {
        store.recordUserAction("使用全局快捷键", details: [
            "shortcut": "Control+Shift+Space",
            "action": presentation.mode == .dashboard ? "collapse" : "expand"
        ])
        if presentation.mode == .dashboard {
            hide()
        } else {
            store.prepareNotchDestination()
            show()
        }
    }

    private func installGlobalHotKey() {
        globalHotKey = GlobalHotKey(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey | shiftKey)
        ) { [weak self] in
            self?.toggleFromGlobalHotKey()
        }
        store.recordUserAction(
            globalHotKey == nil ? "全局快捷键注册失败" : "全局快捷键已启用",
            details: ["shortcut": "Control+Shift+Space"]
        )
    }

    private func reinstallGlobalHotKey(reason: String) {
        globalHotKey = nil
        installGlobalHotKey()
        store.recordUserAction("重新注册全局快捷键", details: [
            "shortcut": "Control+Shift+Space",
            "reason": reason
        ])
    }

    private func installDashboardEscapeHotKey() {
        guard dashboardEscapeHotKey == nil else { return }
        dashboardEscapeHotKey = GlobalHotKey(
            keyCode: UInt32(kVK_Escape),
            modifiers: 0,
            identifier: 2
        ) { [weak self] in
            self?.store.recordUserAction("使用 Esc 收起工作台", details: ["scope": "global-while-expanded"])
            self?.hide()
        }
        store.recordUserAction(
            dashboardEscapeHotKey == nil ? "展开期 Esc 注册失败" : "展开期 Esc 已启用",
            details: ["scope": "global-while-expanded"]
        )
    }

    func tearDown() {
        hoverWorkItem?.cancel()
        previewCollapseWorkItem?.cancel()
        idleCollapseWorkItem?.cancel()
        resignWorkItem?.cancel()
        presentationWorkItem?.cancel()
        globalHotKey = nil
        dashboardEscapeHotKey = nil
        repositionWorkItems.forEach { $0.cancel() }
        repositionWorkItems.removeAll()
        if let monitor = localKeyMonitor { NSEvent.removeMonitor(monitor) }
        systemObservers.forEach { observer in
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        systemObservers.removeAll()
        cancellables.removeAll()
    }

    private var targetScreen: NSScreen? {
        NSScreen.screens.first {
            $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil && $0.safeAreaInsets.top > 0
        } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func notchLayout(for screen: NSScreen) -> NotchLayout {
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           screen.safeAreaInsets.top > 0 {
            let cutoutWidth = max(0, right.minX - left.maxX)
            let barHeight = max(32, screen.safeAreaInsets.top)
            let wingWidth: CGFloat = 80
            return NotchLayout(
                barWidth: cutoutWidth + wingWidth * 2,
                barHeight: barHeight,
                cutoutWidth: cutoutWidth
            )
        }
        return NotchLayout(barWidth: 360, barHeight: 36, cutoutWidth: 0)
    }

    private func updateNotchMetrics() {
        guard let screen = targetScreen else { return }
        let layout = notchLayout(for: screen)
        presentation.notchBarWidth = layout.barWidth
        presentation.notchBarHeight = layout.barHeight
        presentation.notchCutoutWidth = layout.cutoutWidth
    }

    private func compactFrame() -> NSRect {
        guard let screen = targetScreen else { return .zero }
        let layout = notchLayout(for: screen)
        return NSRect(
            x: screen.frame.midX - layout.barWidth / 2,
            y: screen.frame.maxY - layout.barHeight,
            width: layout.barWidth,
            height: layout.barHeight
        )
    }

    private func expandedFrame() -> NSRect {
        guard let screen = targetScreen else { return panel.frame }
        let width = min(1460, screen.frame.width - 28)
        let height: CGFloat = min(680, screen.frame.height - 48)
        return NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
    }

    private func handleHover(_ hovering: Bool) {
        hoverWorkItem?.cancel()
        previewCollapseWorkItem?.cancel()
        if !hovering {
            hoverRequiresExit = false
            if presentation.mode == .preview {
                let item = DispatchWorkItem { [weak self] in
                    guard let self, self.presentation.mode == .preview else { return }
                    withAnimation(.easeOut(duration: 0.18)) { self.presentation.mode = .compact }
                }
                previewCollapseWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: item)
            }
            return
        }
        guard presentation.mode != .dashboard,
              !hoverRequiresExit,
              ProcessInfo.processInfo.systemUptime >= automaticPresentationSuppressedUntil else { return }
        if hovering {
            if presentation.mode == .compact {
                withAnimation(.easeOut(duration: 0.18)) { presentation.mode = .preview }
            }
            let item = DispatchWorkItem { [weak self] in self?.show(activate: false) }
            hoverWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: item)
        }
    }

    private func scheduleIdleCollapse() {
        guard presentation.mode == .dashboard else { return }
        idleCollapseWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.presentation.mode == .dashboard else { return }
            if self.store.isControlledUpdating {
                self.scheduleIdleCollapse()
                return
            }
            self.store.recordUserAction("工作台闲置自动收起", details: ["idleSeconds": "60"])
            self.hide()
        }
        idleCollapseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + idleCollapseDelay, execute: item)
    }

    private func installMonitors() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in self?.hide() }
                return nil
            }
            let navigationModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if navigationModifiers.isEmpty,
               event.keyCode == 123 || event.keyCode == 124,
               self?.isEditingText != true {
                let offset = event.keyCode == 123 ? -1 : 1
                Task { @MainActor in self?.switchSection(offset: offset) }
                return nil
            }
            return event
        }
    }

    private var isEditingText: Bool {
        guard let textView = panel.firstResponder as? NSTextView else { return false }
        return textView.isEditable
    }

    private func switchSection(offset: Int) {
        guard presentation.mode == .dashboard else { return }
        let sections = WorkbenchSection.allCases
        guard let currentIndex = sections.firstIndex(of: store.section) else { return }
        let nextIndex = (currentIndex + offset + sections.count) % sections.count
        store.isResultInboxPresented = false
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            store.select(sections[nextIndex])
        }
        scheduleIdleCollapse()
    }

    private func installSystemObservers() {
        let center = NotificationCenter.default
        systemObservers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.requestScreenRecovery(
                    reason: "屏幕配置变化",
                    reinstallHotKey: true
                )
            }
        })
        systemObservers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.requestScreenRecovery(reason: "应用恢复活动") }
        })

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.activeSpaceDidChangeNotification
        ] {
            systemObservers.append(workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    let woke = notification.name == NSWorkspace.didWakeNotification ||
                        notification.name == NSWorkspace.screensDidWakeNotification
                    self?.requestScreenRecovery(
                        reason: notification.name.rawValue,
                        reinstallHotKey: woke,
                        refreshLiveTasks: woke
                    )
                }
            })
        }
    }

    /// macOS commonly emits several screen/activity notifications for one
    /// physical display change. Coalescing that burst prevents repeated hot-key
    /// registration and panel frame writes from competing with one another.
    private func requestScreenRecovery(
        reason: String,
        reinstallHotKey: Bool = false,
        refreshLiveTasks: Bool = false
    ) {
        if !pendingScreenRecoveryReasons.contains(reason) {
            pendingScreenRecoveryReasons.append(reason)
        }
        pendingHotKeyReinstall = pendingHotKeyReinstall || reinstallHotKey
        pendingLiveTaskRefresh = pendingLiveTaskRefresh || refreshLiveTasks
        screenRecoveryRequestWorkItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let reasons = self.pendingScreenRecoveryReasons
            let shouldReinstall = self.pendingHotKeyReinstall
            let shouldRefresh = self.pendingLiveTaskRefresh
            self.pendingScreenRecoveryReasons.removeAll()
            self.pendingHotKeyReinstall = false
            self.pendingLiveTaskRefresh = false
            let combinedReason = reasons.contains("屏幕配置变化")
                ? "屏幕配置变化"
                : (reasons.first ?? "系统状态变化")
            if shouldReinstall {
                self.reinstallGlobalHotKey(reason: combinedReason)
            }
            self.scheduleScreenRecovery(reason: combinedReason)
            if shouldRefresh {
                self.store.refreshLiveTasks(showSync: true)
            }
        }
        screenRecoveryRequestWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: item)
    }

    private func scheduleScreenRecovery(reason: String) {
        repositionWorkItems.forEach { $0.cancel() }
        repositionWorkItems.removeAll()
        for delay in [0.0, 0.25, 1.0, 2.5] {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.repositionPanel()
            }
            repositionWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
        store.recordUserAction("重新对齐刘海面板", details: ["reason": reason])
    }

    private func repositionPanel() {
        guard targetScreen != nil else { return }
        updateNotchMetrics()
        let target: NSRect
        switch presentation.mode {
        case .compact, .preview: target = compactFrame()
        case .dashboard: target = expandedFrame()
        }
        panel.setFrame(target, display: true)
        panel.orderFrontRegardless()
    }

    private func observeAttentionChanges() {
        Publishers.CombineLatest3(store.$tasks, store.$readResultRevisions, store.$taskAssociations)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.handleAttentionChanges()
            }
            .store(in: &cancellables)
    }

    private func handleAttentionChanges() {
        guard store.configuration.configured else { return }
        let unreadRevisions = Dictionary(uniqueKeysWithValues: store.unreadResultTasks.compactMap { task in
            task.resultRevision.map { (task.id, $0) }
        })
        let executionTaskIDs = Set(store.taskAssociations.filter {
            $0.effectiveRelationship == .execution
        }.map(\.taskID))
        let waitingTaskIDs = Set(store.tasks.filter {
            executionTaskIDs.contains($0.id) && $0.status == .waiting
        }.map(\.id))

        guard hasObservedAttentionState else {
            observedUnreadRevisions = unreadRevisions
            observedWaitingTaskIDs = waitingTaskIDs
            hasObservedAttentionState = true
            if !unreadRevisions.isEmpty || !waitingTaskIDs.isEmpty {
                presentAttentionUpdate(
                    resultCount: unreadRevisions.count,
                    waitingCount: waitingTaskIDs.count,
                    reason: "启动时存在未处理更新"
                )
            }
            return
        }

        let changedResults = unreadRevisions.filter { observedUnreadRevisions[$0.key] != $0.value }
        let newWaiting = waitingTaskIDs.subtracting(observedWaitingTaskIDs)
        observedUnreadRevisions = unreadRevisions
        observedWaitingTaskIDs = waitingTaskIDs
        guard !changedResults.isEmpty || !newWaiting.isEmpty else { return }
        presentAttentionUpdate(
            resultCount: changedResults.count,
            waitingCount: newWaiting.count,
            reason: "已关联任务状态变化"
        )
    }

    private func presentAttentionUpdate(resultCount: Int, waitingCount: Int, reason: String) {
        store.recordUserAction("工作台更新自动展开", details: [
            "newResults": "\(resultCount)",
            "waiting": "\(waitingCount)",
            "reason": reason
        ])
        if presentation.mode == .dashboard {
            scheduleIdleCollapse()
        } else if ProcessInfo.processInfo.systemUptime < automaticPresentationSuppressedUntil {
            store.recordUserAction("自动展开已延后", details: [
                "reason": "刚刚由用户收起",
                "newResults": "\(resultCount)",
                "waiting": "\(waitingCount)"
            ])
        } else {
            store.prepareNotchDestination()
            show(activate: false)
        }
    }
}

private struct WorkbenchIslandRoot: View {
    @ObservedObject var store: WorkbenchStore
    @ObservedObject var presentation: IslandPresentation
    let onOpen: () -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            WorkbenchNotchBar(
                store: store,
                mode: presentation.mode,
                cutoutWidth: presentation.notchCutoutWidth,
                onTap: {
                    if presentation.mode == .dashboard {
                        onClose()
                    } else {
                        store.prepareNotchDestination()
                        onOpen()
                    }
                },
                onHover: onHover
            )
                .frame(width: presentation.notchBarWidth, height: presentation.notchBarHeight)
                .zIndex(3)
            if presentation.mode == .dashboard {
                Capsule().fill(WorkbenchPalette.mint.opacity(0.22)).frame(width: 1, height: 4)
                WorkbenchDashboardView(store: store, onClose: onClose)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .onExitCommand {
            if presentation.mode == .dashboard { onClose() }
        }
    }
}

private struct WorkbenchNotchBar: View {
    @ObservedObject var store: WorkbenchStore
    let mode: IslandMode
    let cutoutWidth: CGFloat
    let onTap: () -> Void
    let onHover: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        Button(action: onTap) {
            GeometryReader { proxy in
                let wingWidth = max(0, (proxy.size.width - cutoutWidth) / 2)
                HStack(spacing: 0) {
                    HStack(spacing: 7) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(WorkbenchPalette.mint)
                        Text("AI 工作台")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.9))
                            .lineLimit(1)
                    }
                    .padding(.leading, 10)
                    .frame(width: wingWidth, height: proxy.size.height, alignment: .leading)

                    Color.clear
                        .frame(width: cutoutWidth, height: proxy.size.height)

                    HStack(spacing: 5) {
                        ZStack {
                            if shouldPulse {
                                Circle()
                                    .stroke(activeColor.opacity(0.55), lineWidth: 1)
                                    .frame(width: 10, height: 10)
                                    .scaleEffect(isPulsing ? 1.45 : 0.75)
                                    .opacity(isPulsing ? 0 : 0.9)
                            }
                            Image(systemName: statusIcon)
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(activeColor)
                        }
                        .frame(width: 12, height: 12)
                        Text(statusLabel)
                            .font(.system(size: 9.2, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.88))
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 21)
                    .background(activeColor.opacity(0.13), in: Capsule())
                    .overlay(Capsule().stroke(activeColor.opacity(0.22), lineWidth: 0.6))
                    .padding(.trailing, 8)
                    .frame(width: wingWidth, height: proxy.size.height, alignment: .trailing)
                }
            }
            .background(Color.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 11, bottomTrailingRadius: 11))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode == .dashboard ? "收起 AI 工作台" : "展开 AI 工作台")
        .help("⌃⇧Space 展开或收起 AI 工作台")
        .onHover(perform: onHover)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.05).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
    }

    private var statusLabel: String {
        if !store.configuration.configured { return "待设置" }
        if store.unreadResultCount > 0 { return "新结果 \(store.unreadResultCount)" }
        if store.waitingCount > 0 { return "等你 \(store.waitingCount)" }
        if store.runningCount > 0 { return "运行中 \(store.runningCount)" }
        if store.isRefreshing || store.isLiveTaskSyncing { return "同步" }
        return "空闲"
    }

    private var activeColor: Color {
        if !store.configuration.configured { return WorkbenchPalette.mint }
        if store.unreadResultCount > 0 { return WorkbenchPalette.purple }
        if store.waitingCount > 0 { return WorkbenchPalette.amber }
        if store.runningCount > 0 || store.isRefreshing || store.isLiveTaskSyncing { return WorkbenchPalette.mint }
        return Color.white.opacity(0.34)
    }

    private var statusIcon: String {
        if !store.configuration.configured { return "slider.horizontal.3" }
        if store.unreadResultCount > 0 { return "sparkles" }
        if store.waitingCount > 0 { return "person.crop.circle.badge.questionmark" }
        if store.runningCount > 0 { return "waveform.path.ecg" }
        if store.isRefreshing || store.isLiveTaskSyncing { return "arrow.triangle.2.circlepath" }
        return "checkmark"
    }

    private var shouldPulse: Bool {
        store.configuration.configured && !reduceMotion &&
            (store.unreadResultCount > 0 || store.waitingCount > 0 || store.runningCount > 0)
    }
}
