# 代码审查：面板 / 刘海 UI、设置、取色器、i18n、安装与卸载

- 范围：`src/Shell.ps1`、`src/UnifiedTray.ps1`、`src/UnifiedState.ps1`、`Setup.ps1`
- 基线：`dev-0.0.3`（aed2bac）
- 测试：在 Linux 上用 PowerShell 7.4.6 运行 `tests/*.Tests.ps1`。除 `RequestSafety.Tests.ps1` 外全部通过；该文件的清理代码用 Windows 的 `\` 拼路径，在 Linux 上抛出 "Unsafe fixture cleanup path"。这是已知问题，属于 T2，与本次审查的文件无关。
- 只列真实问题，不含代码风格意见。每条都写了复现方法；能在 Linux 上验证的，已用 pwsh 实际跑过。

| # | 严重度 | 简述 |
|---|---|---|
| 1 | high | PS7 下日期被转成 `[string]` 后按当前区域设置解析：fr/de/en-GB 等区域下倒计时为空或日期错误，打开历史曲线时整个刷新中断 |
| 2 | medium | 从下载目录运行 `Uninstall.bat` 会删除下载目录，却不删除真正安装的副本和它注册的 hook |
| 3 | medium | 设置文件不是原子写入：进程在写入中途被结束，会让所有设置恢复默认 |
| 4 | medium | 若干界面文字缺少 zh/ja/fr/ko 翻译，提示（ToolTip）完全不翻译，法语区域下 "of 2 000" 也匹配不到翻译规则 |
| 5 | low | 在刘海上按下鼠标后拖出再松开，刘海会一直停在展开的"NOTCH"状态，不再缩回 |
| 6 | low | 菜单里"不透明度"和"失去焦点时隐藏"的勾选状态在启动时是按默认值算的，之后从不同步 |
| 7 | low | 安装到用户自选的空文件夹后，卸载会递归删除整个文件夹（包括用户后来放进去的文件） |
| 8 | low | 自定义背景色窗口按主显示器的工作区定位，面板在其他显示器上时可能出现在屏幕外 |

---

## 1. [high] PS7 下日期按当前区域设置解析，导致倒计时为空或错误；历史曲线让整个刷新中断

**位置**
- `src/Shell.ps1:1295-1304` `Format-PanelReset([string]$iso)`
- `src/Shell.ps1:1351-1357` `Set-Spark`：`[System.DateTimeOffset]::Parse($valid[0].t)`
- 调用方：`src/Shell.ps1:1289`（`Set-SectionBar` 把 `$resetsAt` 原样传入）、`1810/1816/1826/1834`（Claude 的 `resets_at`）、`2250`（Cursor 的 `BillingCycleEnd`）
- `src/Format.ps1:36` 的 `Format-Reset` 有同样的写法，不在本次范围内，但 `Shell.ps1:1807/2101/2168/2323` 都调用了它

**问题**

在 PowerShell 7 下，`Invoke-RestMethod` / `ConvertFrom-Json` 会把 ISO 时间字符串自动转成 `[datetime]`（DEVELOPMENT.md 的 "Known pitfalls" 里也提到过）。这个值传进 `[string]$iso` 参数时，PowerShell 按不变区域（invariant culture）把它格式化成 `10/23/2026 11:00:00`：时区信息丢了，而且是美式月/日顺序。随后 `[DateTimeOffset]::Parse()` 又按**当前**区域设置解析这个字符串，于是：

- fr-FR、de-DE、en-GB 等区域：解析抛异常，`Format-PanelReset` 返回 `''`，所有"剩 x 小时"的倒计时都是空白。程序本身支持法语界面，法语用户一定会遇到。
- en-GB 下如果日期 ≤ 12（比如 10 月 5 日），不会报错，而是被解析成 5 月 10 日，倒计时完全错误。
- 原字符串以 `Z` 结尾时（`Kind=Utc`），格式化后没有时区，再按本地时间解析，结果偏移一个 UTC 时差（UTC+8 下偏 8 小时）。
- `Set-Spark` 没有 try/catch。从文件读回的历史样本，其 `t` 字段在 PS7 下也是 `[datetime]`，一旦解析失败就会抛异常。`$ErrorActionPreference='Stop'` 时，这会中断 `Update-ClaudeSection`，并通过 `Update-AllSections` 一路向上抛：Codex / Cursor / Grok 面板和刘海读数（`Update-OverlayViews` 里的 `Update-IslandView`）每 30 秒的刷新全部停掉。触发条件是打开了"显示历史曲线"，并且区域设置是上面那几种。

**复现**（pwsh 7，Linux 上即可）
```powershell
$j = '{"s":"2026-10-23T03:00:00.512+00:00","z":"2026-10-20T10:00:00Z"}' | ConvertFrom-Json
[string]$j.s                                   # 10/23/2026 11:00:00（TZ=Asia/Shanghai）
[cultureinfo]::CurrentCulture = 'fr-FR'
[DateTimeOffset]::Parse([string]$j.s)          # 抛异常 -> Format-PanelReset 返回 ''
[cultureinfo]::CurrentCulture = 'en-US'
[DateTimeOffset]::Parse([string]$j.z)          # 2026-10-20T10:00+08:00，实际应为 18:00+08:00
```
历史曲线：把一条 `{"t":"<Get-Date -Format o>","five_hour":10}` 用 `ConvertFrom-Json` 读回，在 fr-FR 下调用 `[DateTimeOffset]::Parse($h[0].t)`，同样抛异常。

**修复建议**
- 加一个纯函数 `ConvertTo-PanelTime($v)`：`[DateTimeOffset]` 原样返回；`[datetime]` 用 `[DateTimeOffset]$v` 转换（保留 Kind，Unspecified 按 UTC 处理）；字符串用 `[DateTimeOffset]::Parse($s, [CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)`。
- `Format-PanelReset`、`Format-Reset` 去掉 `[string]` 参数类型，统一走这个函数；`Set-Spark` 的三处 `Parse` 也改用它，并给每个样本的解析加 try/catch，坏样本直接跳过，不要让整次刷新失败。
- `Update-OverlayViews` 里给每个 `Update-*Section` 单独包一层 try/catch，一个面板出错不要拖累其他面板。

**能发现这个问题的测试**

在 `tests/UiLogic.Tests.ps1` 里加：
- 依次把 `CurrentCulture` 设为 `fr-FR`、`de-DE`、`en-GB`、`zh-CN`，用 `ConvertFrom-Json` 得到的 `[datetime]`（`+00:00` 和 `Z` 两种写法）调用 `Format-PanelReset`，断言输出与 en-US / 字符串输入时一致（例如 `'4h 05m left'`）。
- 用假的 `$script:window`（带 `FindName` 的 PSCustomObject）和从 JSON 读回的 `$script:History` 调用 `Set-Spark`，在 fr-FR 下断言不抛异常，并且点数正确。

---

## 2. [medium] 从下载目录运行卸载：删掉下载目录，真正安装的副本和 hook 都留着

**位置**：`Setup.ps1:528-558`（`Invoke-Uninstall`）、`Setup.ps1:532`（`$script:AppDir = $SourceDir`）、`Setup.ps1:554-557`（删除 `$SourceDir`）、`Uninstall.bat`

**问题**

卸载流程处理的始终是**运行这份 Setup.ps1 的目录**（`$SourceDir`），而不是注册表里记录的安装目录（`InstallLocation`）。安装包里本身就带着 `Uninstall.bat`。用户在解压后的下载目录里双击 `Uninstall.bat`（这很自然）时，会发生下面几件事：

1. `Get-ReqOwnedCommands` 按下载目录拼出 hook 命令，读的也是下载目录里的 `hook-registrations.json`（不存在）。所以 `~/.claude/settings.json` 和 `~/.codex/hooks.json` 里指向**安装目录**的 hook 不会被识别为"自己的"，一条也不删。
2. 注册表卸载项、开始菜单 / 桌面 / 开机启动快捷方式都被删掉。
3. 被递归删除的是**下载目录**。
4. 安装目录 `%LOCALAPPDATA%\JayOS AI Usage` 原封不动地留下，hook 也还注册着，但"已安装的应用"列表里已经找不到它，用户没法再正常卸载。

**复现**（已在 pwsh 中验证）
```powershell
$env:CLAUDE_CONFIG_DIR = "$tmp/claude"; function Write-Log {}
$script:AppDir = "$tmp/inst"; . ./src/Requests.ps1
Set-ClaudeRequestHooks $true                   # 安装目录注册 hook
$script:AppDir = "$tmp/dl"                     # 从下载目录卸载
Set-ClaudeRequestHooks $false
(Get-Content "$tmp/claude/settings.json" -Raw) -match 'inst/hooks/ClaudeHook.ps1'   # True：hook 还在
```

**修复建议**

卸载时先读注册表的 `InstallLocation`（Setup.ps1 第 27 行已经有读取逻辑）。如果该目录存在、里面有 `unified-overlay.ps1`、并且和 `$SourceDir` 不是同一个目录，有两种做法：
- 首选：直接从那个目录重新启动 `Setup.vbs /uninstall` 并退出当前进程；
- 或者把 `$script:AppDir` 和要删除的目录都改成 `InstallLocation`。

注册表里没有记录时，至少要求 `$SourceDir` 下存在本程序的标志文件。另外 `Uninstall.bat` 可以从发布包里去掉，只复制到安装目录。

**能发现这个问题的测试**

把"决定要卸载哪个目录"的逻辑提成纯函数 `Resolve-UninstallDir -SourceDir -RegisteredDir`，测试它在 `SourceDir ≠ RegisteredDir` 时返回 `RegisteredDir`。再加一条集成测试：用上面的复现步骤，确认 hook 用安装目录作为 AppDir 移除后，文件里不再包含它。

---

## 3. [medium] 设置文件不是原子写入，进程中途被结束会让所有设置恢复默认

**位置**：`src/UnifiedState.ps1:97`（`Set-Content -Path $script:StatePath`）、`src/UnifiedState.ps1:108-113`、`unified-overlay.ps1:819`；`Setup.ps1:398`（同样写法）

**问题**

`Set-Content` 会先把文件清空再写入。在下面这些时候，`Save-UnifiedState` 的调用很频繁：每次 Codex 余额变化（`Update-CodexCreditRow`）、每次告警状态变化、每次折叠卡片、每次修改设置。如果进程在清空和写完之间被结束，文件就会是空的或者被截断。`Setup.ps1` 每次更新都会对正在运行的 overlay 执行 `Stop-Process -Force`（第 371-373 行），关机时也一样，所以这并不是罕见情况。

下次启动时：
- 空文件：`Load-UnifiedState` 不报错，直接使用默认值；
- 半截 JSON：进入 catch，设置 `NeedsRepair`，第 819 行马上用默认值把文件覆盖掉。

两种情况下，语言、显示哪些服务商、"刘海里处理 AI 请求"、快捷键、背景色等设置都会丢失。

**复现**（已在 pwsh 中验证）：先写入 `{"Language":"zh","AiRequests":true}`，调用 `Load-UnifiedState`，得到 `Language=zh`。再把文件内容改成空字符串，重新 `Initialize-UnifiedCfg; Load-UnifiedState`，得到 `Language=en AiRequests=False`。

**修复建议**

和 `Add-ReqRegisteredCommand` / `Set-AgentRequestHooks` 的做法一致：先写到同目录的临时文件（`<path>.<guid>.tmp`，UTF-8），再用 `[IO.File]::Replace($tmp, $path, "$path.bak")` 替换（目标文件不存在时用 `File.Move`）。`Load-UnifiedState` 在主文件为空或解析失败时，先尝试读 `.bak`，都不行再用默认值。`Setup.ps1` 的 `Save-LanguageSetting` 也照此修改。

**能发现这个问题的测试**
- 模拟 `Set-Content`（或写临时文件这一步）在写入中途抛异常，断言原来的状态文件内容不变。
- 主文件为空、`.bak` 有效时，断言 `Load-UnifiedState` 从 `.bak` 恢复出 `Language=zh`。
- 保存完成后目录里没有残留的 `*.tmp`。

---

## 4. [medium] 部分界面文字没有翻译；提示从不翻译；法语区域下 "of 2 000" 匹配不到规则

**位置**
- `src/Shell.ps1:1241-1243`：`Format-ClaudeStaleReset` 生成的 `'as of yyyy-MM-dd HH:mm'`。Claude 数据过期时，**所有** Claude 行都显示这句话，表里没有对应规则。
- `src/UnifiedTray.ps1:3742`：`'Monitor with mouse'`、`'Primary'`；`3754`：`'(primary)'`。
- `src/UnifiedTray.ps1:3639`：平台菜单里的链接标签来自 `ProviderLinks.ps1`（`'Install Claude Code'`、`'Dashboard'`、`'Cursor docs'`、`'ChatGPT Codex'`、`'Install Codex CLI'`），都没有翻译。
- `src/UnifiedTray.ps1:3489-3497, 3605, 3613`：用量告警气泡（`'Claude Usage Critical'`、`'Claude Usage Warning'`、`'<label> at N%'`）完全不经过翻译。
- 提示文字：`Invoke-UiTranslate`（`UnifiedTray.ps1:482-500`）只翻译 `TextBlock.Text`，`Invoke-MenuTranslate` 只翻译 `Text` / `ShortcutKeyDisplayString`，所有 `ToolTip` / `ToolTipText` 都保持英文。例如 `Get-AccountState` 的 Tip（`4359-4369`）、`Update-GrokResetDisplay` 的三句提示（`Shell.ps1:2128-2138`）、`'Drag to move'`、自动续期 Claude 登录的说明、`'Click to sign in to …'`。
- `src/Shell.ps1:2037` 的 `'of {0:N0}'` 按当前区域设置格式化：fr-FR 下得到 `of 2 000`（千位分隔符是 U+202F 窄空格），而规则 `^of ([\d,.]+)$`（`UnifiedTray.ps1:421`）匹配不到，于是这一行在法语界面里仍显示英文。

**复现**

用 AST 读出 `$script:I18nText`、`$script:I18nRules` 和 `Requests.ps1` 的 pair 列表，再拿上面这些字符串调用 `Convert-I18nString $t 'zh'`，结果原样返回。法语那一条：`[cultureinfo]::CurrentCulture='fr-FR'; ('of {0:N0}' -f 2000) -match '^of ([\d,.]+)$'` 结果为 `False`。

**修复建议**
- 在 `$script:I18nText` 里补上缺的词条；`as of …` 和 `<label> at N%` 加 `$script:I18nRules` 规则。
- 告警气泡的标题和正文显示前先过一遍 `Convert-I18nString`。
- 新增 `Invoke-I18nToolTip`，翻译方式和正文一致：WPF 元素在 `Invoke-UiTranslate` 遍历时处理字符串类型的 ToolTip，WinForms 菜单项在 `Invoke-MenuTranslate` 里处理 `ToolTipText`。
- 数字按 `[CultureInfo]::InvariantCulture` 格式化（`[string]::Format($inv, 'of {0:N0}', $ref)`），或者把规则改成 `^of ([\d\s\u202F\u00A0,.]+)$`。

**能发现这个问题的测试**

新增 `tests/I18n.Tests.ps1`：
- 用 AST 收集 `New-StripItem` 的字符串常量参数、`Get-AccountState` / `$script:ProviderPillStyles` 里的 `Text` / `Tip`、`Format-ClaudeStaleReset '2026-10-20 10:00'` 和 `Format-PanelReset` 的各种输出，断言每一条在 zh/ja/fr/ko 下都能通过 `Convert-I18nString` 得到不同于英文的结果。
- 在 fr-FR 下断言 `'of {0:N0}'` 生成的文字能被翻译。

---

## 5. [low] 在刘海上按下后把鼠标拖出再松开，刘海卡在展开状态

**位置**：`src/UnifiedTray.ps1:2854-2856`（按下时设置 `NotchPressed`）、`2860-2862`（只在本窗口收到 MouseUp 时清除）、`2702`（`$inNotch -or $script:NotchPressed` 时不计离开时间）

**问题**

窗口没有捕获鼠标。刘海外面是分层窗口的透明区域，不参与命中测试，所以在刘海上按下、把鼠标拖到刘海外再松开时，本窗口收不到 `MouseLeftButtonUp`，`$script:NotchPressed` 一直是 `$true`。在 NOTCH 状态下，`Invoke-NotchHoverPoll` 因此永远不会累计离开时间，刘海一直停在外面，要到下一次点击它才恢复，而下一次点击会直接打开完整面板。

**复现**（Windows）：鼠标移到顶部让刘海出现，在刘海上按住左键，把鼠标向下拖离刘海后松开，刘海不会缩回。

**修复建议**

在 `Invoke-NotchHoverPoll` 开头加一句：`if ($script:NotchPressed -and [System.Windows.Forms.Control]::MouseButtons -eq 'None') { $script:NotchPressed = $false }`。或者在 MouseDown 时 `CaptureMouse()`，并在 `LostMouseCapture` 里清除这个标志。

**能发现这个问题的测试**

把 NOTCH 状态下"要不要累计离开时间"的判断提成纯函数，例如 `Test-NotchHolding -InNotch -Pressed -ButtonsDown -Pinned`，测试 `Pressed=$true, ButtonsDown=$false` 时返回 `$false`。也可以用 AST 加载 `Invoke-NotchHoverPoll`，把 `Get-NotchCursorLocal` 和 `[Control]::MouseButtons` 换成桩，断言在 `HoverLeaveMs` 之后调用了 `Start-NotchEdgeReturn`。

---

## 6. [low] "不透明度"和"失去焦点时隐藏"的勾选状态与实际设置不一致

**位置**：`src/UnifiedTray.ps1:3834`（`$sub.Checked = ([double]$script:Cfg.Opacity -eq [double]$val)`）、`3768`（`$miHideFocus.Checked`）、`4215-4224`（`$script:MenuToggleKeys` 里没有这两项）；加载顺序见 `unified-overlay.ps1:394`（加载 UnifiedTray）和 `805`（`Load-UnifiedState`）

**问题**

菜单是在读取保存的设置**之前**构建的，所以这两项的勾选是按默认值算的（100%、关）。`Sync-MenuToggleStates` 在每次打开菜单时只同步 `MenuToggleKeys` 里列出的开关，不包括这两项。保存的不透明度是 60% 时，重启后菜单仍然勾着 100%，"失去焦点时隐藏"也一直显示为关。

**复现**：选择"不透明度 → 60%"，退出程序再启动，打开设置菜单，100% 仍被勾选。

**修复建议**

在 `Sync-MenuToggleStates` 里加上：`foreach ($kv in $script:opacityItems.GetEnumerator()) { $kv.Value.Checked = ([double]$script:Cfg.Opacity -eq [double]($kv.Key.TrimEnd('%')) / 100) }`，并把 `$miHideFocus.Checked` 也放进去同步（或者把它加进 `MenuToggleKeys`，对应 `DropdownHideOnFocusLoss`）。

**能发现这个问题的测试**

在没有 WPF 的环境下，用 AST 加载 `Sync-MenuToggleStates`，传入假的菜单项对象（只需要 `Checked` 属性）。设置 `$script:Cfg.Opacity = 0.6` 后调用它，断言只有 `'60%'` 被勾选。

---

## 7. [low] 安装到用户自选的空文件夹后，卸载会删除整个文件夹

**位置**：`Setup.ps1:663-667`（只有文件夹非空时才追加 `JayOS AI Usage` 子目录）、`Setup.ps1:554-557`（卸载时 `Remove-Item -Recurse` 整个目录）

**问题**

在"浏览…"里选一个已经存在的空文件夹（比如 `D:\Tools`）时，程序会直接装进这个文件夹。卸载时则递归删除整个目录，包括用户后来放进 `D:\Tools` 的所有文件，而且不经过回收站。

**复现**：新建空文件夹 `D:\Tools`，安装时选它；装好后往里面放一个别的文件，然后卸载，`D:\Tools` 整个消失。

**修复建议**

只要选中的不是已有安装（没有 `unified-overlay.ps1`），并且文件夹名不叫 `JayOS AI Usage`，就一律追加子目录，空文件夹也不例外。另一个办法是卸载时只删除 `src/InstallManifest.ps1` 清单里列出的文件和目录，以及运行时产生的已知文件（`runtime`、`requests`、状态和日志文件），最后目录空了才删除它。

**能发现这个问题的测试**

把目标目录的决定逻辑提成 `Resolve-InstallTarget -Picked`，测试：空的 `D:\Tools` 得到 `D:\Tools\JayOS AI Usage`；已有安装则保持原路径。如果采用按清单删除，再加一条测试：卸载后用户自己的文件仍在。

---

## 8. [low] 自定义背景色窗口按主显示器定位

**位置**：`src/UnifiedTray.ps1:939-948`

**问题**

`$area = [System.Windows.SystemParameters]::WorkArea` 永远是主显示器的工作区。面板被拖到另一块显示器后，`$top` 会被限制在主显示器的纵向范围内。如果副显示器在纵向上与主显示器错开（上下排列、竖屏），或者面板在主显示器左边，取色窗口可能部分或全部落在屏幕外。

**复现**（Windows，两块显示器，副屏在主屏上方）：把面板拖到副屏上，打开"背景颜色 → 自定义…"，取色窗口被夹回主屏的高度范围，与面板分开，或者出现在两块屏幕之间。

**修复建议**

用面板所在的显示器：`[System.Windows.Forms.Screen]::FromHandle($hwnd).WorkingArea`，再像 `Get-WorkArea`（`UnifiedState.ps1:256-272`）那样按 DPI 换算成 DIP。

**能发现这个问题的测试**

把定位计算提成纯函数 `Get-CpPickerPosition -Area -PanelRect -Size`，用不同的显示器矩形（包括负坐标、上下排列）测试，断言结果完全落在给定的工作区内。
