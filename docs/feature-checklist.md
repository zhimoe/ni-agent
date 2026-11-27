# Ni 0.5.0 功能验收清单

更新于 2026-11-27。按用户实际操作检查 Ni 源码、命令入口和回归用例，再从 Pi、Codex CLI、Claude Code 的官方文档核对常用操作。`已覆盖` 表示已有相应入口，验证范围列在每项旁边。`部分` 表示常用路径仍有限制，`缺少` 表示当前版本没有对应入口。更广泛的产品对照见 [上一轮功能对比](cli-agent-comparison.md)。

## 为什么上次漏掉了两处

旧表里一项 Shell 覆盖了模型的 `bash` 工具和 RPC Bash，验收关注进程、输出与退出状态。用户键入 `!` 的编辑器、等待和执行路径需要独立验收。旧版把命令交给非交互 Bash，没加载 Zsh 别名，普通 `echo` 用例照样通过。0.5.0 的终端回归会写一份带 `ll` 别名的 Shell 配置，输入 `!ll` 后检查实际输出。 [终端回归](../tests/check_tui_scroll.py) · [Shell 执行入口](../src/ni/tools.nim)

旧表的复制指的是通过 `/copy` 复制回复、代码块或 diff。全屏开启鼠标上报后，终端把拖动交给 Ni，旧版只处理滚轮。0.5.0 分别验证历史正文和未提交的中文草稿的拖选，检查剪贴板请求中的实际文本。Windows 原生测试另验证拖动高亮和还原，Herdr 中也验证了实际的鼠标转发。 [PTY 测试](../tests/check_tui_scroll.py) · [Windows 控制台测试](../tests/check_windows_console.py) · [Herdr 鼠标路由](https://github.com/herdrdev/herdr/blob/v0.9.5/src/client/shell/mouse.rs)

## 日常交互

| 操作 | Ni 0.5.0 | 核对结果 |
| --- | --- | --- |
| 启动、提交、退出 | 已覆盖 | 普通终端或 Windows CMD 进入交互，终端能力不足时降级为行内或行式输入。`/quit` 或 EOF 退出并还原终端。 |
| 编辑长提示与中英文输入 | 已覆盖 | 多行、光标、按词移动、撤销、粘贴、输入历史、外部编辑器。Windows 自动化注入已转换的 Unicode 字符，实际输入法候选窗口仍需在宿主终端手动验证。 |
| 反向查找历史、找回提交前的草稿 | 部分 | `↑`、`↓` 可找回历史，缺交互式 `Ctrl+R` 搜索、暂存和取回已排队的提示。Codex、Claude 文档明确列出历史搜索，Pi 有取回排队提示的按键。 |
| 补全命令、模型和文件 | 部分 | `/command`、`/model` 和 `@file` 有补全。Shell 模式缺命令历史和路径补全，通用 Shell 启动补全也缺。 |
| `!` 模式提示和提交 | 已覆盖 | 开头键入 ASCII `!` 后边框变色。回车运行，任务进行时延后执行，裸 `!` 和 `!!` 留在编辑器里。PTY 验证模式、队列以及命令没有被当成模型提示。 |
| 本地执行、别名和对话上下文 | 已覆盖 | `!` 输出加入上下文，`!!` 留在本地。macOS/Linux 无沙箱且使用 Bash 或 Zsh 时加载交互配置，Windows 沿用配置的 Shell、Git Bash 或 CMD。模型 Bash、TUI 和 RPC Bash 的行为分别验收。 |
| 命令输出、交互式 Shell 和后台任务 | 部分 | 有结束后显示输出、退出码和中断。缺 TUI 实时 Shell 输出、在 PTY 内运行交互程序、后台命令列表和重新附着。Claude 文档覆盖 Shell 实时输出和后台操作。 |
| 历史滚动与固定输入框 | 已覆盖 | 鼠标滚轮、翻页、触底保持、流式期间浏览旧消息。PTY 验证混合方向滚轮及差量重绘，Herdr 复测触底。 |
| 复制可见历史与未提交草稿 | 已覆盖 | 全屏拖选，松开后读取剪贴板文本，不含 ANSI。PTY 断言复制内容，Windows 原生测试验证拖选高亮。 |
| 复制回复、代码与 diff | 已覆盖 | `/copy last`、`/copy code`、`/copy <N>`、`/copy diff`，与对任意屏幕文字的拖选分开。 |
| 键盘选区、全文搜索与普通终端模式 | 缺少 | 缺键盘选区复制、当前对话全文搜索和显式 `--no-alt-screen`。Ni 有终端降级路径。Pi 有可配置的全屏/普通模式，Codex 有 raw scrollback，Claude 有展开式 transcript。 |
| 流式回复、进度、取消与排队 | 部分 | 文本、思考、工具进度、耗时和 token 显示，支持 `Esc`、steering、follow-up。缺队列编辑、手动压缩的统一取消和按运行设置总预算。 |
| 终端集成、快捷键和无障碍 | 部分 | Herdr 可自动显示名称与工作状态，follow-up 按键可配。缺 Herdr 重启会话恢复、通用键位映射、主题及无障碍渲染模式。 |
| 剪贴板图像与终端预览 | 部分 | 有显式图片输入路径，缺 TUI 粘贴图像和终端图片预览。 |

[Pi 用法](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/usage.md) · [Pi 键位](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/keybindings.md) · [Codex CLI 操作](https://learn.chatgpt.com/docs/developer-commands?surface=cli) · [Claude Code 交互](https://code.claude.com/docs/en/interactive-mode) · [Herdr 状态与恢复](https://herdr.dev/tui/docs/add-herdr-support/)

## 编程、会话与自动化

| 操作 | Ni 0.5.0 | 核对结果 |
| --- | --- | --- |
| 配置模型、凭据和用量 | 部分 | 有环境或 API key 登录、模型列表、切换和多供应商配置。缺主动刷新目录、用量细分和配置来源诊断。 |
| 修改、搜索和执行项目代码 | 已覆盖 | 文件读写、模糊编辑、搜索、模型 Bash 和 Windows PowerShell。有白名单、超时、工具执行结果和逐次修改 diff。 |
| 工作区 diff、只读评审与代码回退 | 缺少 | 能查看末次工具 diff 和分叉对话，缺工作区 `/diff`、只读 review、文件检查点及回退。Codex 有工作区 diff 和 review，Claude 有文件检查点。 |
| Git worktree、多目录和语义导航 | 缺少 | 项目以当前目录为入口，缺 `--add-dir`、工作树管理、符号/引用查询和诊断。 |
| 会话保存、继续、新建与分支 | 已覆盖 | `--continue`、`--session-id`、`/resume`、`/new`、`/tree`、`/fork`、`--no-session` 和同会话单写者保护。覆盖尾行恢复、分支和临时会话。 |
| 会话导入、导出、归档与搜索 | 部分 | `/export` 支持 Markdown、HTML 和 JSONL，`--session` 可打开已有文件。缺离线导出、跨工作区全文搜索、归档和旧 Pi 格式迁移。 |
| 项目指令、权限、Skills、重载 | 部分 | 有工作区指令、项目配置授权、工具名单、重载保留 CLI 覆盖项、Skills 和模板。缺作用域更细的审批规则、配置溯源和动态 Hooks。 |
| 文件、Shell 和 MCP 权限边界 | 部分 | macOS/Linux 提供受限模式。Windows 尚缺进程沙箱后端，跨入口和 Linux bubblewrap 的权限用例还需扩充。 |
| MCP 配置、认证与工具 | 部分 | stdio、HTTP、OAuth、资源与工具启停有端到端用例。缺动态列表、完整资源模板与协议能力协商。 |
| 非交互使用、错误与退出码 | 部分 | 支持管道、`--print`、JSONL 和 RPC，区分成功、截断、上限、失败及取消。缺 JSON Schema、最终输出文件、运行总超时和可配置轮数。 |
| Pi 协议精确兼容 | 部分 | 常见 JSONL、RPC 和会话字段有回归用例。流块边界、取消后队列、压缩/重试与扩展消息仍要逐帧对照。 |
| 计划、后台会话和子 Agent | 缺少 | 可显式提问和分叉对话。缺只读计划审批、持久任务列表、后台会话和子 Agent 运行时。 |
| 安装、更新与诊断 | 部分 | 发布包含 Windows x64/ARM64 便携包，可从源码构建 macOS 和 Linux；缺安装器、自动更新和 `doctor`。 |

[Pi 会话](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sessions.md) · [Codex CLI 参数](https://learn.chatgpt.com/docs/cli/reference) · [Codex 非交互模式](https://learn.chatgpt.com/docs/non-interactive-mode) · [Claude CLI](https://code.claude.com/docs/en/cli-reference) · [Claude 检查点](https://code.claude.com/docs/en/checkpointing) · [Claude 权限](https://code.claude.com/docs/en/permissions)

## 每次发布怎么验收

1. 在 macOS/Linux 上运行 `nimble test`。检查从空编辑器进入 `!`、执行别名、确认 `!!` 上下文行为，再拖选历史和草稿，核对剪贴板内容。模拟流式输出期间重做排队和滚轮操作。
2. 用打包后的 `ni.exe` 在 Windows x64 和 ARM64 运行 `tests/check_windows_console.py` 与 Nim 集成套件。确认无 `TERM` 可启动、行式输入、鼠标高亮、Unicode、退出后终端还原和 RPC Shell；记录实机 IME 和系统剪贴板验证分别做到哪一步。
3. 复用器至少覆盖 Herdr 中的启动识别、拖选、滚动触底和退出。与终端相关的改动，记录复用器版本、终端尺寸和验证过的手势。 [Ni TUI 约定](../AGENTS.md)
4. 下一轮优先补上 `Ctrl+R`、键盘选区复制、对话搜索、显式普通终端模式和 TUI Shell 实时输出。这些都能用日常操作验证。计划、子 Agent 等工作另见 [TODO](../TODO.md)。
