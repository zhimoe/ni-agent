# Ni 与 Pi、Codex CLI、Claude Code 的功能对比

当前版本的逐操作验收、已知缺漏和发布检查见 [Ni 0.5.0 功能验收清单](feature-checklist.md)。下文保留第二轮审计的版本基线。

第二轮审计日期为 2026-11-26。Ni 基线为当时的 0.2.0 工作树，含 `2466e13` 之后上一轮尚未提交的实现。对照本机 Pi 1.6.0、Codex CLI 0.172.0、Claude Code 2.1.316 的版本和 CLI 帮助，并参考官方文档中的产品能力。OpenCode 和 Gemini CLI 用来补充同类实现。表中注明由扩展提供、实验中或属于关联服务的能力。0.3.0 的会话写入、尾行恢复和启动参数修复见 [TODO](../TODO.md)。

Ni 已能完成单 Agent 的多供应商编程、文件与 Shell 操作、会话树、原生 TUI、MCP 和脚本驱动。会话 ID、临时 fork、运行结束状态、配置重载和两处 Pi 协议差异已修复。剩余的基础工作包括异常会话恢复、权限边界验证和协议生命周期对照。可验收的工作顺序见 [TODO](../TODO.md)。

| 对比维度 | Ni 0.2.0 | Pi 1.6.0 | Codex CLI 0.172.0 | Claude Code 2.1.316 |
| --- | --- | --- | --- | --- |
| 模型 | 多供应商，兼容自定义端点 | 多供应商、原生登录、模型目录与路由 | OpenAI 和兼容/本地 provider 入口 | Claude，支持不同身份及模型平台 |
| 自动化 | print、JSONL、stdio RPC | print、JSONL、RPC、TypeScript SDK | exec、review、Schema、SDK、App Server | print、JSON/stream JSON、Schema、Agent SDK |
| 项目工作流 | 单工作区、工具 diff、交互提问 | 内置核心工具，可装计划、子 Agent、检查点等扩展 | 工作区 diff/review、Plan、子 Agent、托管 worktree | Plan、子 Agent、worktree、文件检查点和后台会话 |
| 可移植状态 | Pi v3 常见条目、活动分支和导出 | 完整会话树、扩展条目、树摘要与分享 | 会话恢复、分叉、跨进程排队与归档 | 会话恢复、分叉、跨会话管理、PR 关联 |
| 扩展 | Skills、模板、MCP、deferred 工具 | TypeScript 扩展、包、Skills、主题、MCP 和 CodeMode | Skills、插件、Hooks、MCP | Skills、插件、Hooks、MCP、自定义 Agent |
| 本地执行权限 | 工具名单、信任、三档权限、macOS/Linux 受限模式 | 信任和工具名单，可用扩展或外部隔离 | 平台沙箱、规则、审批策略 | 权限模式、工具规则和平台沙箱 |

[Pi 文档](https://docs.pi.dev/) · [Codex CLI](https://learn.chatgpt.com/docs/codex/cli) · [Claude CLI](https://code.claude.com/docs/en/cli-reference)

## 上一轮交付状态

| 能力 | 当前实现与边界 |
| --- | --- |
| 工具权限 | 模型工具执行入口检查启用状态，支持 `--no-tools`、名单和值增删，覆盖 MCP 与 deferred 工具。`/reload` 保留工具名单和 MCP 启动开关。 |
| 进程沙箱 | `read-only` 和 `workspace-write` 已接入文件工具、Shell 和 stdio MCP。macOS 用 Seatbelt，Linux 用 bubblewrap，Windows 受限模式会报错。模型与配置的 HTTP MCP 仍由 Ni 进程连接。默认模式为 `off`。 |
| UTF-8 和 JSONL | 已有统一编码入口、历史会话修复和 RPC Bash 测试。字符编码、终端控制字符处理和协议字段兼容是各自可验证的范围。 |
| 取消与压缩 | 模型流、重试等待、Shell 和 MCP 有取消路径。请求前可按估算压缩，识别部分溢出和长度终止后最多额外压缩重试一次。压缩切点保留同一轮工具调用与结果，支持衔接旧摘要。 |
| 会话恢复 | `--continue`、`/resume`、`/tree` 重建活动分支和历史画面，恢复已知模型和推理档位。会话选择器已移除近期 15 条限制，分支游标通过 `.leaf` 持久化。 |
| RPC / JSONL | 模型与档位轮换、取消重试和 RPC Bash、fork/clone、增量历史、消息与工具事件、压缩、队列和 settled 均已有入口。精确字段与顺序仍需补齐。 |
| MCP OAuth | 已有浏览器 PKCE、动态注册与预配置客户端、令牌存储和刷新、重连、认证错误分类及服务或工具启停。覆盖本地 OAuth 模拟服务。 |

## 当前实现需要补齐的行为

显式会话 ID 按工作区精确查找，临时 fork 保留源历史，截断和轮数上限有独立退出码。重载保留启动覆盖项。JSONL 增加 `session` 首帧，RPC 补齐分角色计数和 `contextUsage`。见 [修复记录](../TODO.md#第二轮已修复)。

| 优先级 | 问题 | 证据与补齐标准 |
| --- | --- | --- |
| P0 | 会话损坏和并发写入缺恢复约定 | 日志逐条追加，没有写锁，解析失败或未知类型的行会跳过。进程在工具调用和结果之间终止、未知条目位于父链中、两个进程同时恢复同一会话，都应有明确定义。见 [会话存储](../src/ni/session.nim)。 |
| P0 | 权限边界需要贯穿入口 | 工具白名单约束模型工具。用户直接执行的 TUI Shell 和 RPC Bash 使用独立入口。`@file` 附件、配置值解析和 MCP 管理子命令也各有自己的路径。应明确进程及文件权限覆盖范围，把沙箱模式、环境变量、凭据访问和 HTTP 连接纳入一组跨入口测试。见 [附件](../src/ni/agent.nim#L138)、[信任策略](../src/ni/trust.nim)、[沙箱](../src/ni/sandbox.nim) 与 [MCP 子命令](../src/ni.nim#L149)。 |
| P1 | Pi JSONL 和 RPC 生命周期 | 助手流的块边界、重试与分支摘要事件、abort 后队列、工具结果与 UI 请求的细节仍需固定版本做用例对照。见 [Ni JSONL](../src/ni/tui.nim#L864) 与 [Ni RPC](../src/ni/rpc.nim)。 |
| P1 | 参数错误需要确定的诊断 | **实测。** 无效 `--mode` 和 `--security` 值可以继续执行并返回 0。缺少参数值的行为也需在各子命令统一。应在连模型或加载 MCP 前报错。见 [CLI 参数解析](../src/ni.nim#L423)。 |
| P1 | 取消、压缩与实际用量的细节 | 自动压缩有取消路径，TUI 手动 `/compact` 未接入同一交互取消链。用量在请求、中间重试、工具与摘要间缺同口径持久化。见 [手动压缩](../src/ni/tui.nim#L1651) 与 [摘要](../src/ni/agent.nim#L269)。 |

[Pi JSON 事件](https://github.com/earendil-works/pi/blob/v1.6.0/packages/coding-agent/docs/json.md) · [Pi RPC 命令](https://github.com/earendil-works/pi/blob/v1.6.0/packages/coding-agent/docs/rpc-commands.md) · [Pi 会话格式](https://github.com/earendil-works/pi/blob/v1.6.0/packages/coding-agent/docs/session-format.md) · [Codex 非交互模式](https://learn.chatgpt.com/docs/non-interactive-mode) · [Claude CLI](https://code.claude.com/docs/en/cli-reference)

## 编程、命令执行与任务

| 能力 | Ni 当前覆盖及差距 | 竞品对照 |
| --- | --- | --- |
| 文件读写与搜索 | 已有 read/write/edit/grep/find/ls，支持多处替换、模糊编辑、BOM、换行和工具 diff。大文件配额、二进制类型识别和附件失败反馈仍可完善。 | 覆盖 Pi 核心工具。Codex、Claude 有各自的文件或补丁工具。 |
| 跨文件补丁 | 可连续编辑多个文件。缺统一预览、修改前状态校验、部分失败后的恢复。 | Codex 和 OpenCode 提供补丁工具。 |
| Git diff 与评审 | 可展示和复制上次工具 diff。缺工作区 staged/unstaged diff、分支基线、只读 review、文件和行号定位、结构化 findings。 | Codex `/diff`、`codex review`。Claude 有 diff 和按需评审。 |
| 文件检查点与回退 | 有编辑器撤销和会话分支。缺受工具管理的文件快照、回滚预览、恢复时识别用户后续改动。 | Claude `/rewind`，OpenCode 与 Gemini CLI 有快照，Pi 有 Git checkpoint 扩展示例。 |
| 工作区范围 | 启动目录是工具根目录。缺 `-C`、额外根目录、托管 Git worktree、切换后重算配置与授权范围。 | Codex 有 `-C`、`--add-dir`、`--worktree`；Claude 有额外目录和 worktree。 |
| Shell 与后台命令 | 有 Bash、Windows PowerShell、进程终止、超时、完整输出文件和 JSONL/RPC 增量。缺 TUI 实时日志面板、交互 PTY、后台任务列表、附着与分别终止。 | Codex 有背景终端，Claude 有后台 Shell 和任务管理。 |
| 并行工具 | 单轮可接多个调用，工具逐个执行。缺按读写范围调度、并发上限和独立取消。 | Codex 会并行批量读取，Claude 提供并行工具能力。 |
| 语义导航与诊断 | 有文件与纯文本搜索。缺符号、定义、引用、实时诊断、改后格式化。 | Claude Code Intelligence 插件，OpenCode 有 LSP 或格式化工具。 |
| 计划与任务跟踪 | 有状态行、计时和提问工具。缺受工具限制的只读 Plan Mode、计划确认、持久任务列表和依赖。 | Codex、Claude 有计划模式；Pi 提供扩展示例；Gemini CLI 有 Todo 与实验计划功能。 |
| 子 Agent | 单运行时可 steer、follow-up、手动 fork。缺独立上下文、角色配置、权限和预算继承、取消、结果归并、worktree 并行。 | Codex、Claude、OpenCode 有子 Agent。Claude Agent Teams 属实验能力。Pi 可用扩展。 |
| 持久目标与后台会话 | 有固定 64 轮运行上限和可恢复的对话日志。缺目标状态、预算和验收条件，以及后台 attach/logs/cancel 和阶段恢复。 | Codex 有目标与会话管理，Claude 有后台会话和循环。Pi Durable 是独立运行时。 |
| 网页查询与获取 | 可通过 MCP 添加。缺原生搜索、URL 内容提取、引用、网络策略和缓存。 | Codex 有 Web Search。Claude、OpenCode、Gemini CLI 有网页查询或获取工具。 |

[Pi 扩展示例](https://github.com/earendil-works/pi/tree/v1.6.0/packages/coding-agent/examples/extensions) · [Pi Durable](https://earendil.com/posts/pi-durable/) · [Codex CLI 命令](https://learn.chatgpt.com/docs/developer-commands?surface=cli) · [Codex 子 Agent](https://learn.chatgpt.com/docs/agent-configuration/subagents?surface=cli) · [Claude 工具](https://code.claude.com/docs/en/tools-reference) · [Claude 检查点](https://code.claude.com/docs/en/checkpointing) · [Claude Agent Teams](https://code.claude.com/docs/en/agent-teams) · [OpenCode 格式化](https://opencode.ai/docs/formatters/) · [Gemini 检查点](https://geminicli.com/docs/cli/checkpointing/)

## 配置、权限、扩展与 MCP

| 能力 | Ni 当前覆盖及差距 | 竞品对照 |
| --- | --- | --- |
| 配置兼容与自检 | 共用 Pi 目录与部分 setting、模型、凭据、信任、Skills、模板。缺配置来源解释、严格 schema、profile、逐来源启停和设置界面。 | Pi 有 `config` 与 `/settings`，Codex 有 profile、严格配置与 doctor，Claude 有 settings scope。 |
| 指令与记忆 | 读取用户与启动目录祖先链的指令文件。缺目录级按需规则、导入、`/init`、已加载来源展示和持久记忆。 | Codex 有分目录 `AGENTS.md`；Claude 有路径规则、导入与 Auto Memory；Gemini CLI 有上下文管理。 |
| Skills 与命令 | 支持发现、显式添加、`/skill:`、模板参数。缺包内资源筛选、命名空间、参数化 Skill、工具策略及子 Agent 隔离执行。 | Pi 有包资源过滤，Claude Skills 可使用独立上下文与参数。 |
| 扩展运行时 | 有内部 Nim 注册接口。缺公开版本化 API、动态加载、扩展命令与快捷键、provider 注册、自定义 UI/事件/会话条目。 | Pi 的核心区别是 TypeScript 扩展 API；OpenCode 有插件；Codex、Claude 有自己的插件模型。 |
| 包安装与治理 | 缺从本地、Git、注册表安装与更新、版本锁定、项目级依赖和资源开关。 | Pi 支持 npm、Git、本地包。Codex、Claude 有插件管理和市场。 |
| Hooks | 有内部 Agent 事件。缺配置级的工具前后、会话、审批、压缩等 Hooks，以及超时、取消和决策返回值。 | Pi 通过扩展事件，Codex、Claude 和 Gemini CLI 有配置式 Hooks。 |
| 权限与审批 | 有信任、启用名单、三档权限和交互确认。缺可配置的 allow/ask/deny、按命令参数、目录或域名匹配、作用域、审批记忆与 headless 审批协议。 | Codex 有 sandbox、审批策略和命令规则；Claude 有工具规则和模式。Pi 能通过扩展增加审批。 |
| 沙箱与运行环境 | 有两个受限模式。缺 Windows 运行时隔离、Linux 实机测试、额外读写根和网络/环境规则配置，以及可解释的拒绝原因。 | Codex 有平台沙箱与环境策略。Claude 的沙箱可配置文件与网络规则。 |
| MCP 连接与 OAuth | stdio、Streamable HTTP、资源读列、静态 headers、OAuth 和逐项启停已覆盖。缺懒连接、并行启动、按 scope 的配置界面、旧 SSE（迁移需求）和更完整的 OAuth 互操作测试。 | Pi、Codex、Claude 有 stdio/HTTP 与 OAuth，Claude 仍有旧 SSE。 |
| MCP 协议覆盖 | 工具分页、结果与 stdio roots/ping 已有。缺 prompts 和资源模板、异步 list-changed 与服务器消息、结构化结果保真、进度、elicitation/sampling 及能力协商测试。 | 以 MCP 规范作能力清单。Claude 的动态工具、Channels 和 Tasks 有各自的版本或功能开关。 |
| MCP 反向集成 | Ni 可作为客户端通过 stdio RPC 控制的进程。缺将 Ni 能力作为 MCP 服务公开的入口。 | Claude 提供 `claude mcp serve`。 |
| Deferred 工具与 CodeMode | `tool_search` 可以启用 deferred MCP 工具。CodeMode VM 为占位。缺脚本内组合工具、配额与执行日志。 | Pi 有原生 CodeMode，可发现和编排工具。 |
| 组织治理与数据 | 有本地信任与凭据。缺受管策略、集中审计、凭据后端、统一数据保留与遥测配置。 | Codex、Claude 有组织管理与政策；Claude 支持企业身份和外部模型平台。 |

[Pi 设置](https://github.com/earendil-works/pi/blob/v1.6.0/packages/coding-agent/docs/settings.md) · [Pi 扩展](https://github.com/earendil-works/pi/blob/v1.6.0/packages/coding-agent/docs/extensions.md) · [Pi MCP](https://github.com/earendil-works/pi/blob/v1.6.0/packages/coding-agent/docs/mcp.md) · [Pi CodeMode](https://github.com/earendil-works/pi/blob/v1.6.0/packages/coding-agent/docs/codemode.md) · [Codex 配置](https://learn.chatgpt.com/docs/config-file/config-reference) · [Codex Hooks](https://learn.chatgpt.com/docs/hooks) · [Codex Windows 沙箱](https://learn.chatgpt.com/docs/windows/windows-sandbox) · [Claude 权限](https://code.claude.com/docs/en/permissions) · [Claude Hooks](https://code.claude.com/docs/en/hooks-guide) · [Claude MCP](https://code.claude.com/docs/en/mcp) · [MCP 规范](https://modelcontextprotocol.io/specification/2025-11-25)

## 模型、会话与上下文

| 能力 | Ni 当前覆盖及差距 | 竞品对照 |
| --- | --- | --- |
| 供应商与登录 | 原生 OpenAI Completions/Responses、Anthropic Messages、Gemini 和兼容 API，支持 DeepSeek、Kimi、本地端点。模型登录交互主要保存 API Key，可读取已有 OAuth 凭据，内置刷新主要针对 Kimi。 | Pi 有更多供应商、登录方法和原生 API，例如 Bedrock、Vertex、Copilot；Codex 有 ChatGPT 登录；Claude 有订阅和企业入口。 |
| 模型目录与路由 | 可读 Pi `models.json` 与 `models-store.json`，有模型选择和 RPC 轮换。缺 `--models` 范围轮换、每模型预设、目录主动刷新、虚拟路由、故障 fallback、自动本地模型管理。 | Pi 有 scoped models、目录更新和虚拟模型。Claude CLI 有 fallback。Codex CLI 有本地模型入口。 |
| Provider 协议一致性 | 已有多种 thinking/tool signature 和缓存支持。缺统一多内容块回放、工具图像一致性、精确的停止原因与 provider 能力验证。 | Pi 可作为多供应商 replay 和模型定义基线。 |
| 多模态输入 | CLI、RPC 能传图，文件工具能读图。缺 TUI 剪贴板图片、终端预览和缩放，缺 PDF 等文档的统一输入和大小检查。 | Pi 支持终端图片；Codex 有 `--image`；Claude CLI 支持图像工作流。 |
| Token、费用与预算 | 显示估算和部分用量、费用、缓存。缺按 provider/工具/摘要/分支归因、剩余上下文构成、缓存诊断与预热，以及运行预算。 | Pi 有上下文与缓存相关工具，Claude 有 `/context` 与预算参数，Codex 有使用量视图。 |
| 压缩与上下文 | 有阈值、摘要继承和溢出重试。缺分模型策略、可持久化压缩用量、分支切换摘要、自定义摘要器和上下文文件/工具 schema 用量明细。 | Pi 有 branch summary、自定义摘要，Claude 有压缩指令和上下文视图。 |
| 会话格式与迁移 | 兼容 Pi v3 的常见条目、标签和树。缺旧版本迁移、`branch_summary`、扩展条目保真、损坏诊断、运行恢复。 | Pi 有完整的扩展会话格式。Codex CLI 有旧 rollout 迁移。 |
| 查找与管理 | 有当前目录选择器、命名与重命名、分支游标、ID 或路径查找，ID 查找可跨项目。缺跨项目选择器、全内容索引、归档/删除入口与保留期、从 PR 恢复。 | Codex 有 agents/queue/archive/delete；Claude 支持跨会话管理和 PR 关联。 |
| 导入、导出和分享 | TUI 有 HTML、Markdown 和 JSONL 导出，启动可读取 JSONL。缺单独的离线 `--export`、带格式检查的导入、分享与脱敏。 | Pi 有 `--export`、`/import`、`/share`；Codex 和 Claude 有各自的会话导入或接力流程。 |
| 运行内多会话 | 可切换本地会话、fork 和排消息。缺侧聊、跨进程队列、并行会话概览和事件重放。 | Codex 有 CLI 会话命令中心和异步队列。Claude 有后台会话与并行工作流。 |

[Pi 供应商](https://github.com/earendil-works/pi/blob/v1.6.0/packages/coding-agent/docs/providers.md) · [Pi 压缩](https://github.com/earendil-works/pi/blob/v1.6.0/packages/coding-agent/docs/compaction.md) · [Pi 会话格式](https://github.com/earendil-works/pi/blob/v1.6.0/packages/coding-agent/docs/session-format.md) · [Claude 指令和记忆](https://code.claude.com/docs/en/memory) · [Claude CLI](https://code.claude.com/docs/en/cli-reference) · [Codex CLI](https://learn.chatgpt.com/docs/codex/cli)

## 终端、自动化与发布

| 能力 | Ni 当前覆盖及差距 | 竞品对照 |
| --- | --- | --- |
| 终端与编辑器 | 已有全屏、固定输入栏、滚动、中文、Markdown、搜索选择器、消息队列、外部编辑器和复制。缺会话全文搜索、工具日志折叠、可选原始 transcript、统一的全屏/普通模式参数。 | Pi 有 TUI 模式与设置，Codex 有 `--no-alt-screen`，Claude 有 transcript 界面。 |
| 外观与辅助 | follow-up 快捷键可配。缺通用按键映射、主题、Vim、状态行和标题配置、无障碍模式、图表渲染和建议输入。 | Pi 有自定义主题、快捷键与 Mermaid。Claude 有 Vim、状态行和屏幕阅读器参数。 |
| 普通脚本与 CI | 有 stdin、print、JSONL 和运行退出分类。缺最终 JSON 对象、JSON Schema、最终输出文件、`max-turns`/预算与超时参数。 | Codex `exec --json --output-schema -o`，Claude 有 `--output-format`、`--json-schema`、预算参数，Gemini CLI 有 JSON 与 stream JSON。 |
| Pi 脚本兼容 | 工具、模型、会话、事件骨架已有。还缺工具通配符和独立 denylist、`--no-builtin-tools`、`--offline`、多条位置参数的消息语义、精确 JSONL/RPC 契约。 | Pi CLI、RPC 和 JSON 事件规范可当验收基准。 |
| SDK、常驻服务和跨进程协议 | 有内部 Nim 模块与单会话 stdio RPC。缺公开客户端 SDK、可复用服务、事件游标与断线重连、远端认证和并行会话。 | Pi 有 TypeScript SDK/RpcClient，Codex 有 SDK 和 App Server，Claude 有 Agent SDK，OpenCode 有 API 和 CLI serve/attach。 |
| IDE 与 ACP | 可由第三方直接驱动 stdio RPC。缺 ACP 适配、IDE 选区、诊断和 diff 交互。 | OpenCode 和 Gemini CLI 有 ACP，Codex 与 Claude 有 IDE 集成。 |
| CLI 安装及更新 | 有 Nim 构建、Windows x64/ARM64 打包脚本。缺 CI 平台矩阵、正式发行与校验、installer、升级回滚及 shell completion。 | Pi 有安装脚本和更新，Codex 有 `update` 和 `completion`，Claude 有安装与更新渠道。 |
| 诊断与可观测性 | 有 stderr 与部分错误分类，MCP 可列状态。缺 `doctor`、配置与模型来源、脱敏 debug、可导出的追踪与 OTEL。 | Codex、Claude 有诊断入口，Gemini CLI 有遥测配置。 |

[Pi CLI 帮助](https://github.com/earendil-works/pi/blob/v1.6.0/packages/coding-agent/docs/cli.md) · [Pi SDK](https://github.com/earendil-works/pi/blob/v1.6.0/packages/coding-agent/docs/sdk.md) · [Codex App Server](https://learn.chatgpt.com/docs/app-server) · [Codex 非交互模式](https://learn.chatgpt.com/docs/non-interactive-mode) · [Claude 交互](https://code.claude.com/docs/en/interactive-mode) · [Claude 非交互](https://code.claude.com/docs/en/headless) · [OpenCode CLI](https://opencode.ai/docs/cli/commands/) · [OpenCode ACP](https://opencode.ai/docs/cli/acp/) · [Gemini IDE](https://geminicli.com/docs/ide-integration/)

## CLI 关联服务

Ni 可在 SSH 或 tmux 运行，也可接入现成 CI 和 MCP。若产品目标扩展到托管工作流，还涉及远程控制、移动设备接力、云端执行与本地迁移、事件触发与调度、官方 PR/CI 回传、浏览器/GUI 控制、应用连接器、带访问控制的会话与产物分享。Codex 和 Claude 的相应能力受产品表面、账号、平台和实验开关限制。它们单独评估，Ni 的 Pi 配置和 RPC 兼容验收可独立完成。 [Codex CLI 命令](https://learn.chatgpt.com/docs/developer-commands?surface=cli) · [Claude Remote Control](https://code.claude.com/docs/en/remote-control) · [Claude Code 云端](https://code.claude.com/docs/en/claude-code-on-the-web)

## 验证范围

macOS ARM64、Nim 2.4.2 的 `nimble test` 通过 36 个用例，覆盖显式会话 ID、临时 fork、64 轮上限、输出截断、Pi JSONL 首帧和 RPC 统计。另用本地模拟模型在伪终端验证 `/reload` 保留启动参数。Linux 与 Windows amd64 通过 `nim check`。竞品本机验证覆盖 CLI 帮助和 Pi 协议对照，其他能力来自官方资料。Linux bubblewrap、Windows 交互和竞品托管能力未做实机验证。
