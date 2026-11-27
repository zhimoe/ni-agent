# TUI 滚动与渲染学习总结

Ni 的全屏模式把历史区和输入栏合成一帧，再写入终端。此前的修复处理了顶部越界、制表符换行、滚轮突发和最后一格的重绘范围。后续排查确认了三条故障路径。历史行重放了 Shell 输出里的清屏指令，流式回复在轮询间隙连续提交过多帧，触控板的横向报告被误解为纵向滚动。

## Rust Go TypeScript 的实现对照

| 实现 | 如何控制绘制 | 对 Ni 的启发 |
| --- | --- | --- |
| Rust · Ratatui 与 Crossterm | 组件写入当前单元格缓冲，`Terminal::draw` 根据上一缓冲计算差异，再由后端输出。格子的文本与样式分开表示。Crossterm 提供成对的同步更新命令。 | 先从状态合成可独立比较的行，再交由终端写入。维持一个已提交的帧缓存。同步更新包装整帧。 [Ratatui 渲染实现](https://www.ratatui.rs/concepts/rendering/under-the-hood/) · [Crossterm 同步更新](https://docs.rs/crossterm/latest/crossterm/terminal/struct.BeginSynchronizedUpdate.html) |
| Go · Bubble Tea 2.2.0 与 Ultraviolet | 事件循环更新模型，渲染器保存最新视图。定时器按配置帧率提交，空闲时暂停。同步更新根据终端模式响应启用。该版本在 Windows 关闭 Ultraviolet 的滚动优化。 | 应用状态逐条更新，屏幕提交合并到统一时钟。能力或几何变化时保留坐标差量路径。 [Bubble Tea 事件循环与定时器](https://github.com/charmbracelet/bubbletea/blob/v2.2.0/tea.go) · [Bubble Tea 终端渲染器](https://github.com/charmbracelet/bubbletea/blob/v2.2.0/cursed_renderer.go) |
| Go · tcell v2 | `SetContent` 修改逻辑单元格。`Show` 显示缓冲变化。`Sync` 用于重新同步物理画面。 | 区分普通滚动和缓存失效。显式刷新让渲染器重绘完整帧，避免先清屏再等待下一帧。 [tcell Screen 接口](https://pkg.go.dev/github.com/gdamore/tcell/v2#Screen) |
| TypeScript · Pi 1.6.0 | `requestRender` 合并绘制请求，普通帧有 16 ms 最小间隔。滚动可单独请求视口更新。输出行展开制表符并关闭每行的 SGR 和 OSC 8。 | 将滚轮、流式回复与状态栏接到同一帧边界。最终行的列宽、内容与样式作用域都需要独立成立。 [Pi 调度与行复位](https://github.com/earendil-works/pi/blob/v1.6.0/packages/tui/src/tui.ts) · [Pi 宽度处理](https://github.com/earendil-works/pi/blob/v1.6.0/packages/tui/src/utils.ts) |
| TypeScript · Ink 7.1.1 | 默认以 30 FPS 为渲染上限，可配置增量绘制。交互模式可以接管控制台输出，让日志与视图有序交替。 | 只限制每秒输入报告数会漏掉日志和流式内容。全屏输出由同一渲染路径接管。 [Ink 调度与控制台处理](https://github.com/vadimdemedes/ink/blob/v7.1.1/src/ink.tsx) |

这些库的差异主要在应用如何调度、以单元格还是行表达变化，以及如何适配后端。同步输出负责尽量把一次提交呈现为完整画面。即使终端支持该模式，频繁提交完整帧也会给终端和复用器增加处理压力。xterm.js 的流控文档说明，写入可以先进入解析队列，因此应用侧的一次写入和终端实际显示是两个观察点。 [Contour 同步输出规范](https://contour-terminal.org/vt-extensions/synchronized-output/) · [xterm.js 流控](https://xtermjs.org/docs/guides/flowcontrol/)

## 输出与帧调度故障

### 历史行携带了终端操作

临时会话中的 Shell 输出含有 `CSI 2 J` 时，旧版 Ni 会把这段字节随历史行写回 PTY。终端擦掉整屏，差量缓存却仍认为未改动的行已经显示。滚回底部后，tmux 中的旧历史和输入栏提示都消失，只剩后续补写的行。重新全量绘制可以暂时恢复，下一次重放该行会再次触发。清屏的终端语义见 [XTerm 控制序列](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)。

Ni 保留按行渲染，由 `fitScreenRow` 把内容整理成可独立绘制的一行。保留 SGR 文字样式和 OSC 8 超链接，补齐行尾复位及链接关闭。把制表符、回车和换行整理成布局可计算的空格。丢弃光标移动、清屏和终端模式指令，终端操作继续由绘制层发出。见 [终端行与 ANSI 处理](../src/ni/terminal_io.nim)。

### 滚轮合并覆盖不了模型流

旧版只合并相邻滚轮报告。流式 Markdown、思考计时和工具状态仍各自触发立即绘制。单个回答到达频率高时，即使滚轮已经合并，其他事件仍可以在很短时间内提交多帧。

Ni 现在让全屏更新先修改状态，再标记待绘制。普通帧使用单调时钟，提交间隔至少 17 ms。空闲输入循环按下一帧截止时间等待，流式回复和 Shell 在轮询时处理待绘制帧。弹窗返回或回复结束时可以立即提交最新状态。全屏的 `Ctrl+L` 使帧缓存失效，再通过同一路径重绘。上一次加入的滚动区域优化继续在重叠行匹配时复用正文。见 [帧调度](../src/ni/tui.nim) 与 [视口差量](../src/ni/viewport.nim)。

## 修复前后复测

| 场景 | 修复前 | 修复后 |
| --- | --- | --- |
| PTY 内首次显示含清屏指令的 Shell 输出 | 发送 1 条整屏擦除指令 | 发送 0 条 |
| 上滚后回到底部，再次显示同一行 | 再发 1 条整屏擦除指令 | 发送 0 条 |
| tmux 中复测同一会话 | 回到底部时历史和输入提示消失 | 历史、最新输出、输入提示同时可见 |
| Herdr 0.9.5，相邻窗格持续刷新 | 回到底部时历史和输入提示消失 | 历史、最新输出、输入提示同时可见 |
| 本地模拟模型发送 120 个 SSE 增量，每个间隔约 2 ms | 单次样本共 137 帧，80,146 字节 | 单次样本共 8 帧，13,522 字节，最终文字完整 |

最后一项使用 100×30 的本地 PTY，统计从提交提示到回复结束的应用输出，包含输入回显帧和状态更新帧。实际帧数随数据分包、终端尺寸、内容和调度而变化。

自动回归覆盖快速下滑、慢速最后一格、滚轮后的普通按键、Shell 清屏指令重放，以及模型暂停发送时上滚再回到底部。单元测试检查宽字符裁剪、样式收尾、链接关闭和控制指令过滤。见 [PTY 回归](../tests/check_tui_scroll.py) 与 [TUI 单元测试](../tests/test_tui_markdown_rpc.nim)。

```sh
nimble test
python3 tests/check_tui_scroll.py "$PWD/ni"
```

## 触控板到达底部后的跳动

### 现象与复现

2026 年 11 月 26 日的录屏来自 Herdr 0.9.5，`TERM=xterm-256color`，窗格 175 列 × 48 行。历史已经滚到底时，继续做同一触控板手势，输入栏保持原位。逐帧比较显示，历史区在最后一页与向前三行的位置之间切换，两张画面都有完整的历史正文。

用多页会话在空闲时滚到底，在独立 PTY 和相同尺寸的 Herdr 窗格里分别注入这两条 SGR 鼠标报告，间隔约 150 ms，重复四轮。`\x1b` 表示 ESC，坐标在历史区内。

| 报告 | 协议含义 | 旧版画面 | 修复后 |
| --- | --- | --- | --- |
| `\x1b[<66;75;12M` | 横向滚动 | 离开底部，显示向前三行的位置 | 保持底部 |
| `\x1b[<65;75;12M` | 向下滚动 | 回到底部 | 保持底部 |

录屏提供了画面顺序，注入实验验证了能产生同样画面的输入序列。修复后，同一组报告在直连 PTY 和 Herdr 窗格中都保持底部。用户随后确认原来的手势已恢复正常。

### 根因与验收

Herdr 会转发横向滚轮报告。旧解码器只检查按钮码的 `64` 位，再用奇偶性决定上下方向，导致 `66` 被解为向上滚动一格，`67` 被解为向下。Ni 一格移动三行，与录屏一致。修复在 `decodeCsiSequence` 里仅屏蔽 Shift、Meta、Ctrl 修饰位，随后只把以 `M` 结尾、按钮号为 `64` 或 `65` 的 SGR 报告转换成纵向滚动。 [Ni 终端输入解码](../src/ni/terminal_io.nim) · [XTerm 滚轮按钮编码](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h3-Wheel-mice) · [Herdr 0.9.5 滚轮转发](https://github.com/herdrdev/herdr/blob/v0.9.5/src/pane/input.rs)

自动回归先用正向用例证明纵向滚动确实可以离开底部并返回，包括 Shift+向上 `68M` 和 Ctrl+向下 `81M`。回到底部后再逐条发送 `65M`、`66M`、`65M`、`67M`、`70M`、`83M`、`64m`，每条分别观察 150 ms，要求 PTY 输出为空。150 ms 跨过当前 12 ms 输入合并窗口和 17 ms 帧间隔，能捕捉旧版先离开再返回的中间帧。最后检查滚轮后紧跟的普通字符能进入编辑区。 [PTY 滚动回归](../tests/check_tui_scroll.py)

## 再遇到闪烁时的排查顺序

1. 记录 `TERM`、终端与复用器版本、窗格列数和行数、运行的二进制以及操作顺序。逐帧确认哪块区域变化，画面是在两个有效位置间切换，还是出现空白、缺行或局部撕裂。
2. 如果历史在两个有效位置间来回切换，按到达顺序比较原始鼠标报告、解码后的事件与视口偏移。组合输入要分开重放，逐条检查触底后的 PTY 输出。某个终端环境独有的问题，在同样的环境和尺寸复测。
3. 如果出现空白或缺行，检查 PTY 输出里的整屏清除、光标定位、滚动区和同步帧边界，尤其是含 Shell 历史的场景。如果异常只在流式输出或高频输入发生，统计操作过程中的帧数并检查最后一次更新。保留中间帧和结束画面的证据，分别验证瞬时跳动与最终视口。 [Pi TUI 调试文档](https://github.com/earendil-works/pi/blob/v1.6.0/packages/coding-agent/docs/tui.md) · [tmux 输出捕获](https://github.com/tmux/tmux/wiki/Advanced-Use)
