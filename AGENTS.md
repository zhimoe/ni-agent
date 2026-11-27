# Ni 开发约定

本文记录 Ni 的 TUI 渲染约定。入口与文件职责见 [架构文档](docs/architecture.md)。跨语言实现对照与回归数据见 [TUI 渲染学习总结](docs/tui-rendering-study.md)。

## 帧与终端输出

- 先用 `composeScreen` 合成完整帧，再用 `paintDiff` 与上一帧按行比较。正常滚动、流式输出和状态栏刷新只写变化行。变化行用绝对坐标定位，写完后用 `CSI K` 擦掉旧行尾。连续两帧相同应产生空输出。`CSI 2 J` 留给尺寸变化或显式清屏。`CSI 3 J` 会擦除终端保存的历史。 [Ratatui 双缓冲与差量绘制](https://www.ratatui.rs/concepts/rendering/under-the-hood/) · [XTerm 控制序列](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)
- 全屏时把消息、工具输出和提示交给 `Transcript` 或 dock。全屏帧由 `paintScreen` 统一写入。弹窗或外部编辑器临时接管时用 `suspendDock` 和 `resumeDock`，恢复时使上一帧缓存失效。新增终端模式时把进入和清理写成对，覆盖正常退出、中断和可捕获的错误。 [Ratatui 的终端恢复](https://ratatui.rs/recipes/apps/panic-hooks/) · [Pi 的组件与弹窗](https://github.com/earendil-works/pi/blob/v1.6.0/packages/coding-agent/docs/tui.md)
- `redrawDock` 提交状态并请求绘制。滚轮、模型增量和状态提示共用 17 ms 帧间隔。回复结尾和弹窗恢复可立即提交最新状态。排查高频事件先测帧数，兼顾空闲后最后一帧的提交。 [Bubble Tea 帧调度](https://github.com/charmbracelet/bubbletea/blob/v2.2.0/tea.go)
- 将一次帧提交放在 `CSI ? 2026 h` 与 `CSI ? 2026 l` 之间并及时刷新。同步输出取决于终端和中间层是否支持，差量输出和事件合并在任何终端都需要独立成立。 [Contour 同步输出规范](https://contour-terminal.org/vt-extensions/synchronized-output/) · [ncurses 的批量刷新](https://invisible-island.net/ncurses/ncurses-intro.html#flush)
- Windows CMD 可能未设置 `TERM`。根据 `GetConsoleMode` 和启用虚拟终端输出的结果选择全屏。交互终端在全屏不可用时仍须显示行内编辑器或原生行提示。Windows 全屏每次提交帧后应把控制台光标定位到输入框的实际单元格，供输入法定位候选窗口。退出时先刷新输出，再恢复代码页和输出模式。 [Windows 控制台模式](https://learn.microsoft.com/en-us/windows/console/setconsolemode) · [Windows Unicode 行输入](https://learn.microsoft.com/en-us/windows/console/readconsole)

## 视口和滚动

- 用扣除输入框、自动补全和状态栏后的实际历史区行数计算滚动边界。`scrollUp` 的上限是 `max(0, 总历史行数 - 可见历史行数)`。滚到顶部应该保留最老的一整页。曾用 `总历史行数 - 1` 作为上限，导致顶部只剩第一行，其余区域被刷空。
- `scrollUp == 0` 表示跟随最新输出。用户停在历史中时，追加行和更新流式尾部应保持阅读位置。尺寸或 dock 高度变化后按新行数重新限制偏移。悬浮标题应算入行预算，在很矮的视口中至少保留一行正文。
- 悬浮标题跟随首条可见消息的裁剪状态。回到底部时继续使用相同的行布局，避免最后一格额外挪动内容。历史区高度相同且重叠行逐行匹配时，可以用 `DECSTBM`、`CSI S` 或 `CSI T` 移动正文，随后恢复滚动范围并补绘新露出的行。标题和输入栏在滚动范围之外。重叠行不匹配时按原坐标差量绘制。 [XTerm 的滚动区域与滚动指令](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)
- 输入变化先更新状态，再合并渲染。Ni 在 `handleDockKey` 中用 12 ms 窗口最多收集 64 个连续滚轮事件，按到达顺序应用偏移，并把遇到的第一个非滚轮按键交还输入循环。保持等待和批次有上限，覆盖空闲及流式响应中的滚动。曾对每个滚轮事件提交一帧，同一批下滑到底发出 12 次重绘，合并后只发 1 次。 [Pi 的渲染请求合并](https://github.com/earendil-works/pi/blob/v1.6.0/packages/coding-agent/docs/tui.md)

### SGR 鼠标输入与触底滚动

- `decodeCsiSequence` 只从以 `M` 结尾的 SGR 报告产生纵向滚动事件。只屏蔽 Shift、Meta、Ctrl 的 `4`、`8`、`16` 修饰位，再精确匹配按钮号 `64`（向上）和 `65`（向下）。横向 `66`、`67` 和以 `m` 结尾的释放报告保持纵向视口位置。仅凭滚轮位和奇偶性判断方向会把横向输入转换成纵向输入。 [XTerm 鼠标报告格式](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h3-Extended-coordinates)
- 历史区在两页之间来回跳三行且输入栏稳定时，先对照鼠标输入与视口偏移，再检查帧输出。触控板手势可以同时产生纵向与横向报告。旧版在触底后把 `66` 当成向上滚一格，下一条 `65` 又把历史推回底部。复现与实测见 [触底跳动故障记录](docs/tui-rendering-study.md#触控板到达底部后的跳动)。
- 修改鼠标解码、事件合并或滚动边界时，保留混合滚轮方向的 PTY 回归。让报告分别跨过 12 ms 合并窗口，当前测试对每条报告观察 150 ms。空闲触底时，逐条断言额外向下、横向和释放报告产生零字节 PTY 输出。另须验证带修饰键的纵向报告仍能滚动，紧随滚轮的普通按键仍能输入。只比较最后一帧会漏掉中间跳动。 [PTY 滚动回归](tests/check_tui_scroll.py)

## 行宽、Unicode 和 ANSI

- 按终端可见列数布局，用 `visibleWidth`、`truncateVisible`、`wrapAnsiText` 处理样式文本。字符串的字节长度适合切片和字节限额，显示宽度还取决于宽字符、组合字符和 emoji。修改宽度或裁剪逻辑时，验证中日韩字符、组合重音、带变体选择符的 emoji 与 ZWJ 序列。单个 Unicode 属性给出的宽度需要按实际终端验证。 [Unicode UAX #11](https://unicode.org/reports/tr11/) · [Unicode UAX #29](https://unicode.org/reports/tr29/)
- 所有全屏行经过 `fitScreenRow`，包括代码、diff、悬浮标题和 dock。Ni 按两列计算制表符，实际提交前也应展开为两个空格。曾因把原始 `\t` 送到终端，使窗口边缘的代码按终端制表位折入相邻行。保留最右一列空白，让 `DECAWM` 的关闭与恢复限定在帧内。检查文本中的回车、换行和光标控制序列，特别是来自 Shell 或模型的内容。 [XTerm 的制表、擦除和自动换行协议](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)
- 内容行传递文字、SGR 样式和 OSC 8 链接。光标、清屏和终端模式由绘制层控制。Shell 输出中的清屏指令曾在滚回底部时被重放，擦掉差量缓存仍视为已显示的行。加入新的可显示序列时，检查它按行重放对帧缓存和终端状态的影响。
- 样式与链接的作用域应在各行内闭合。裁剪后继续检查 SGR 的复位和 OSC 8 链接的关闭，防止颜色或链接污染下一行。全屏内容被分行重画时，每行应能独立显示。 [Pi 的行宽与每行样式约定](https://github.com/earendil-works/pi/blob/v1.6.0/packages/coding-agent/docs/tui.md)

## 闪烁回归验收

用可以滚动多页的会话复现，先在底部取一帧，再向上滚几屏，然后分别用快速下滑和慢速逐格滚动回到最底。比较回到底部的画面与原帧。确认同一批滚轮事件只提交一次变化行，最后一格滚动优先复用历史行，边界处继续滚动时终端输出为空，滚轮后的普通按键仍能输入。

- 改视口或合成逻辑时，检查到顶、到底、短历史、窄窗口、尺寸变化和流式新增行。带样式、中文、制表符、长代码与 diff 的会话更容易暴露越界。相关单元测试在 [TUI 测试](tests/test_tui_markdown_rpc.nim)。
- 改输入批处理或帧提交时，检查 PTY 原始 ANSI 和终端实际画面。用 tmux 的 `pipe-pane` 计数同步帧和擦屏指令，再用 `capture-pane` 比较最终画面。若只在某个环境闪烁，记录终端、复用器、`TERM`、窗口尺寸和复现顺序，并在对应环境复测。 [tmux 的窗格输出捕获](https://github.com/tmux/tmux/wiki/Advanced-Use)

在仓库根目录运行 `nimble test`。构建后可单独运行滚动回归，适用于 macOS 和 Linux。

```sh
python3 tests/check_tui_scroll.py "$PWD/ni"
```
