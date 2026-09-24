# AI 工作台 · Community

一个运行在本机 macOS 刘海/菜单栏的开源工作台。它把你自己维护的经营资料、关键假设、Codex 任务与执行日志放在同一个界面，但不会预置任何人的商业模式、客户档案或任务记录。

> 当前版本是 macOS + Codex 任务连接器。你可以在 **Codex 或 WorkBuddy** 中打开本仓库，让 AI 通过对话帮你完成个性化配置、修改源码和安装；**WorkBuddy 的任务状态目前不会被自动读取**。如果你不使用 Codex，经营画布与本地资料仍可使用，但任务监控、额度和草稿跳转不可用。

## 安装

需要 macOS 14 或更新版本、Xcode Command Line Tools（提供 `swift`、`codesign`）。实时任务功能需要本机已安装并登录 Codex。

```bash
git clone https://github.com/zainosl/ai-workbench-community.git
cd ai-workbench-community
./scripts/install.sh
open "$HOME/Applications/AI Workbench Community.app"
```

如果你把这个项目 Fork 到自己的账号，请把克隆地址换成你的仓库地址。

脚本会在独立名称下编译、签名并安装到 `~/Applications/AI Workbench Community.app`，不会覆盖其他版本。若已有同名开源版，旧包会先备份。首次启动会在 `~/Library/Application Support/AIWorkbenchCommunity/` 创建个人配置与空白模板；这些数据**不在仓库里**。

用 `⌃⇧Space` 展开/收起工作台；展开时按 `Esc` 收起。也可以点刘海入口。外接无刘海屏会显示紧凑悬浮条。

### 用 AI 对话完成首次设置

在 Codex 或 WorkBuddy 中把**此仓库**设为工作目录。WorkBuddy 可在创建任务时选择本地目录并引用仓库说明。把下面这段话发给 AI：

> 请先阅读 README.md、AGENTS.md 和 Resources/Templates。和我对话，弄清我的用户任务、解决方案、单元模型、增长、壁垒、当前里程碑与关键假设。只在我本机 `~/Library/Application Support/AIWorkbenchCommunity/Workspace/` 填写经营资料，不把个人信息提交到 Git。先给我预览；经我确认后再把同目录 `config.json` 中的 `configured` 设为 `true`，然后运行 `./scripts/install.sh` 并打开应用。不要替我编造业务证据，也不要自动发送或发布内容。

不想通过 AI，也可以点首次配置页的“打开资料目录”和“打开配置文件”，手动填写后把 `configured` 改为 `true`，再点“我已填好，重新读取”。模板内的“示例”只是格式说明，启用前应换成自己的真实信息。

## 工作方式

```text
你维护的经营资料 ──手动更新经营──> 五步法画布 / 当前里程碑 / 假设
                                              │
Codex 本地任务 ──轻量状态同步──> 任务状态 / 新结果 │
         │                                    ▼
         └── 精确关联任务 ID ──手动更新此假设──> 任务上下文与 AI 建议
                                              │
                                    证据核对 / 新假设 / 沉淀草稿
                                              │
                                          你审阅、决定
```

“读取 → 执行 → 学习 → 沉淀”是产品框架，不是自动化放权：

1. **读取**：经营页解析六份本地 Markdown，显示五步法的需求、解决方案、单元模型、增长、壁垒，以及当前里程碑和假设优先级。业务信息由你维护；工作台只读取。
2. **执行**：任务页读取本机 Codex 会话，包括归档历史；显示项目、任务名称、状态、上下文百分比、额度与结果。假设页可粘贴 `codex://threads/<UUID>` 精确关联任务。由工作台开启的下一步任务会记录父子任务链。
3. **学习**：任务右键可创建“核对已有假设的证据与反证”或“提炼新假设”的 Codex 草稿。任务运行中的流式文字不算新结果；完成轮次进入可已读的结果收件箱。AI 生成的文档或计划**不等于**真实用户/市场/交付证据。
4. **沉淀**：右键“提出沉淀建议”只创建待审阅草稿，说明建议写什么、为什么、写到哪里；不会自动改经营底库，也不会自动发送或发布。

经营更新与单条假设更新是不同按钮：前者重读商业资料，后者重扫 Codex 任务及配置的项目资料。任务状态会轻量同步，但不会替你自动重算经营判断。工作逻辑页展示当前规则与近期运行事件；更完整的本地日志在 `Logs/`。

## 私人资料怎么放

首次运行生成的目录结构：

```text
~/Library/Application Support/AIWorkbenchCommunity/
├── config.json               # 名称、是否完成设置、资料目录、可选项目源
├── Workspace/
│   ├── business.md            # 商业模式与五步法
│   ├── assumptions.md         # 可证伪的关键假设
│   ├── dependencies.md        # 前置依赖
│   ├── milestone.md           # 当前业务里程碑与解锁门槛
│   ├── priorities.md          # 本轮优先假设和最小验证动作
│   └── emerging.md            # 新发现假设观察池
├── Associations/              # 任务与假设的精确关联、任务链
├── Results/                   # 已读状态
└── Logs/                      # 本地运行事件
```

`config.json` 首次生成时 `configured` 为 `false`。`workspacePath` 默认指向上述 Workspace，也可以改为你已有的本地资料目录。`projects` 可以留空；若需要为假设读取某个项目的工作资料，可按以下结构增加：

```json
{
  "id": "example-project",
  "name": "我的项目",
  "rootPath": "/绝对路径/我的项目",
  "overview": "overview.md",
  "progress": "progress.md",
  "preferences": "preferences.md",
  "assumptions": "assumptions.md",
  "result": "result.md"
}
```

相对文件名相对于 `rootPath`。项目文件可以是你的原有资料，工作台只读。不要把本机 `config.json`、Workspace、客户档案、会话、Logs 或打包后的个人数据提交到公开仓库。

## 隐私与边界

- 应用在本地读取你配置的 Markdown、Codex 本地会话/任务状态，并启动本地 Codex app-server 获取支持的账户使用信息。具体可用额度字段依 Codex 版本与账户返回而变；未提供时显示“—”。
- 开源代码与安装包不带个人资料。个人资料在 Application Support 下创建，Git 忽略本地配置和输出目录。
- AI 建议通过“创建待发送草稿”表达；要不要发送、修改资料、联系用户、发布内容或解锁资源，仍由你决定。
- 对外分享日志前请自行检查；日志可能含有你配置的项目名、任务 ID、错误描述等元数据。不要直接公开整个 Application Support 目录。
- 这是个人效率工具，不是对业务假设的自动证明系统，也不是官方 Codex/WorkBuddy 产品。

## 开发和检查

```bash
swift build
swift run AIWorkbenchCoreSelfTest
swift run AIWorkbenchNext --diagnose
```

`--diagnose` 会检查本地模板与 Codex 扫描是否可用，不会列出会话正文。源码分为 `AIWorkbenchCore`（解析、规则、日志、关系记录）和 `AIWorkbenchNext`（macOS UI、Codex 连接、本地配置）。欢迎通过 issue/PR 改进；提交前请确保补丁、测试样本和截图都不包含真实客户、密钥或私人路径。

## 常见问题

**安装脚本提示找不到 `swift`？** 运行 `xcode-select --install` 安装 Command Line Tools 后重试。

**看不到任务？** 确认 Codex 已在本机产生任务记录，点击右上角同步；纯 WorkBuddy 任务不会自动出现。

**打开后只看到首次设置？** 这是预期行为。填写六份资料后，把 `config.json` 的 `configured` 改为 `true`，在界面点击重新读取。

**任务与假设关联错了？** 在对应假设页粘贴准确的 Codex 深度链接。单靠标题匹配仅帮助查找上下文，不应视作商业证据。

MIT License。欢迎 fork 与二次开发。

相关官方资料：[Codex AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md)、[Codex App Server](https://learn.chatgpt.com/docs/app-server)、[WorkBuddy 选择工作目录与引用文件](https://www.workbuddy.ai/docs/workbuddy/Create-Task)。
