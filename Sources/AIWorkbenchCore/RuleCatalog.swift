import Foundation

/// Only rules implemented by the community edition belong here.
public enum RuleCatalog {
    public static let logicVersion = "community-logic-v0.1"

    public static var defaults: [WorkbenchRule] {
        [
            WorkbenchRule(id: "SOURCE-001", name: "经营资料由用户控制", category: "读取",
                          reason: "工作台不预装任何人的商业模式或客户档案",
                          trigger: "首次配置或用户点击更新经营信息",
                          action: "只读取本机 config.json 指向的 Workspace 文档；不自动改写来源文件"),
            WorkbenchRule(id: "PROGRESS-001", name: "整体进展按五步法呈现", category: "读取",
                          reason: "先看业务推进到了哪里，再看局部任务",
                          trigger: "经营资料更新成功",
                          action: "展示需求、解决方案、单元模型、增长、壁垒与当前里程碑"),
            WorkbenchRule(id: "UPDATE-001", name: "经营与假设分域更新", category: "执行",
                          reason: "商业模式变化和单条假设的任务进展不是同一种更新",
                          trigger: "用户点击相应更新按钮",
                          action: "经营更新解析六份资料；假设更新扫描任务与已配置项目资料；更新时暂停工作台操作"),
            WorkbenchRule(id: "TASK-001", name: "Codex 任务保留项目与链路", category: "执行",
                          reason: "任务不是孤立列表，来源和下一步关系必须可追踪",
                          trigger: "扫描 Codex 或从任务创建草稿",
                          action: "读取任务 ID、项目、名称、状态；工作台创建的后续任务记录父子关系"),
            WorkbenchRule(id: "ARCHIVE-001", name: "归档只进入历史", category: "执行",
                          reason: "归档会话仍有上下文价值，但不应作为正在运行",
                          trigger: "Codex 任务扫描或状态同步",
                          action: "读取活跃及归档会话；归档任务不计入运行、等待或新结果"),
            WorkbenchRule(id: "RESULT-001", name: "结果与过程分开", category: "学习",
                          reason: "流式进展不是完成结果，不能频繁打断用户",
                          trigger: "Codex 任务轮次完成",
                          action: "完成结果按版本进入收件箱；可逐条或批量标记已读"),
            WorkbenchRule(id: "EVIDENCE-001", name: "先查反证再查支持", category: "学习",
                          reason: "任务完成或 AI 的文字推断不能单独证明商业假设",
                          trigger: "用户从任务发起证据核对",
                          action: "创建待发送的核对草稿，要求列出证伪、削弱、支持与未知及其来源"),
            WorkbenchRule(id: "HUMAN-001", name: "经营判断保留人工决策", category: "沉淀",
                          reason: "是否采纳新认知、改变方向或投入资源属于用户",
                          trigger: "AI 生成验证、沉淀或下一步建议",
                          action: "只打开可审阅的 Codex 草稿；不自动发送、发布或改写商业资料",
                          requiresApproval: true),
            WorkbenchRule(id: "LOG-001", name: "关键操作可追查", category: "解释",
                          reason: "工作台的更新与任务创建应当能被检查和纠错",
                          trigger: "用户操作与受控更新",
                          action: "把运行 ID、范围、结果、规则编号和错误写入本地日志")
        ]
    }
}
