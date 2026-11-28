# Ni 浏览器、子 Agent 和桌面操作评估

基于当前 Ni 的工具权限、Pi Skills、MCP 和 JSONL RPC。建议先验证 Ego Browser 的用户路径，再实现只读子 Agent，最后用 macOS 上的本地测试应用验证桌面操作。

| 能力 | 首版交付 | 工作量 |
| --- | --- | --- |
| Ego Browser | 通过可选 Skill 连接已安装的 Ego Browser，复用任务空间完成网页操作 | 小，结构化 MCP 接入是下一步 |
| 子 Agent | 并行读取项目，独立返回结果，父任务能等待和取消 | 中，需要任务管理、权限和用量统计 |
| Computer Use | macOS 指定应用窗口截图、点击、滚动和输入，用户能随时停止 | 大，需要桌面辅助进程、图片回传和授权界面 |

## Ego Browser

Ni 已可加载用户 Skills，也可启动 stdio MCP 服务。已在本机用 `ego-browser nodejs` 创建独立 TaskSpace，打开测试页面，根据快照中的元素引用按下按钮，回读页面状态并关闭 TaskSpace。每次脚本启动独立的 Node.js 进程，任务空间和页面标签可以跨脚本继续使用。当前验证覆盖 Ego Browser CLI v2.2.1 的 macOS 环境。 [Ni Skills](../src/ni/skills.nim) · [Ni MCP](../src/ni/mcp.nim)

首版由用户安装 Ego Browser，再通过可选 Skill 使用已有 CLI。验证 Ni 能把任务空间 ID 与当前会话关联，从运行中断和用户接管中恢复。沙箱阻止桌面连接时，报告连接状态并由用户显式配置接入。后续用 MCP 暴露导航、快照、点击、输入、截图和交接等结构化操作。浏览器内部能执行 JavaScript 和使用 CDP，开放这些能力需要单独的权限和接口设计。

验收涵盖本地页面的语义定位和截图、多个操作共用一个 TaskSpace、接管后停止输入，以及结束时只关闭本任务创建的页面。

## 子 Agent

Codex CLI 为子 Agent 提供独立线程、并发上限和状态管理，子 Agent 继承父任务的沙箱与审批配置。公开实现把启动、等待、发送消息和中断拆成独立处理器，启动可选择继承的上下文范围。 [Codex 子 Agent 文档](https://learn.chatgpt.com/docs/agent-configuration/subagents?surface=cli) · [Codex 启动处理器](https://github.com/openai/codex/blob/main/codex-rs/core/src/tools/handlers/multi_agents_v2/spawn.rs)

Ni 首版使用内部 JSONL 管道启动多个 Ni 子进程，对外沿用现有工具和 RPC 事件。每个子 Agent 使用独立的内存会话、显式任务说明和继承的只读工具名单。父任务可以派发、查询、等待和取消，读取各子任务的输出、状态与供应商报告的 token 用量。 [子 Agent 使用说明](../README.md#subagents) · [子进程管理](../src/ni/subagents.nim) · [Ni 权限策略](../src/ni/trust.nim)

验收用两个并行读取任务检查会话相互独立、父任务取消能回收子进程、子任务失败能被识别、运行预算生效。后续再支持续跑和并行改代码，为各写任务建立隔离工作树并由父任务处理合并。

## Computer Use

OpenAI 将通用桌面控制放在 ChatGPT 桌面应用的 Codex 和 Work 中。macOS 需要系统录屏与辅助功能权限，Windows 控制当前可见桌面。每个目标应用还有独立使用授权。Codex 的公开配置支持按应用标识管理访问规则。OpenAI API 的计算机操作接口由调用方执行动作，并按 `call_id` 回传截图。这些接口可作为 Ni 的协议和权限设计参考。 [OpenAI 桌面 Computer Use](https://learn.chatgpt.com/docs/computer-use) · [Codex 应用访问配置](https://github.com/openai/codex/blob/main/codex-rs/config/src/computer_use.rs) · [OpenAI API 动作与截图协议](https://developers.openai.com/api/docs/guides/tools-computer-use)

Ni 可以先做一个按需启动的 macOS 辅助进程。它接收指定应用或窗口的截图和操作请求，在每次输入前验证窗口与坐标。Ni 负责应用级授权、显示目标、接收中断和把截图传给模型。Ni 的 Responses 适配器已有图片输入，仍需补齐原生 Computer Use 的事件解析与截图回传。兼容其他供应商时可先验证结构化 MCP 工具和图片结果。Windows 的前台焦点、多显示器 DPI 和 Linux 的显示系统分别验收。 [Ni Responses 适配器](../src/ni/provider.nim)

验收覆盖系统权限拒绝、切换目标窗口、高 DPI 下的坐标、截图与点击对应，以及取消后停止发送输入。外部页面和窗口文字作为观察结果处理，应用授权仍由 Ni 和用户控制。
