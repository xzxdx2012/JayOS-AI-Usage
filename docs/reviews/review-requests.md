# 代码审查：AI 请求与通知卡片（hooks/ClaudeHook.ps1、src/Requests.ps1）

- 基线：`dev-0.0.3`（`aed2bac`）
- 范围：`hooks/ClaudeHook.ps1`、`src/Requests.ps1`，包括请求/通知卡片、hook 注册、`<app>/requests/` 文件协议和安全性
- 测试：在 Linux 的 PowerShell 7.4.6 上运行全部 8 个测试脚本，7 个通过；`RequestSafety.Tests.ps1` 在清理阶段失败，原因是写死了 `\` 路径分隔符（属 T2，与本审查无关）。另外，T1 的 CI（PR #1）在 Windows PowerShell 5.1 上发现了问题 4。
- 只列出确认存在的问题，不含代码风格建议。除了问题 4 在 PR #1 中已修复，其余问题都尚未修改代码。

| # | 严重程度 | 标题 |
|---|---|---|
| 1 | 高 | MCP/未知工具的参数嵌套超过 4 层时，卡片上看不到，但“允许”按钮仍然可用 |
| 2 | 高 | “总是允许”会把 Claude Code 给出的所有 `permission_suggestions` 一次性全部应用，而卡片上完全不显示具体授予了什么 |
| 3 | 中 | 命令卡片把 AI 写的 `description` 放在命令前面，命令可能被挤出可视区域 |
| 4 | 中 | stdin 开头带 BOM 时，hook 在 Windows PowerShell 5.1 上直接失败，卡片和通知都不会出现（已在 PR #1 修复） |

---

## 1.【高】MCP/未知工具的参数嵌套超过 4 层时，卡片上看不到，但“允许”按钮仍然可用

**位置**：`src/Requests.ps1:656-661`（`Get-RequestSummary` 的 `default` 分支），另见 `hooks/ClaudeHook.ps1:223`

**问题**：未知工具（MCP 工具等）的参数用 `ConvertTo-Json -Depth 4` 显示。第 5 层及更深的对象会被 PowerShell 转成 `"@{x=}"` 这样的字符串，内容丢失：PS 7 只打印一个警告，5.1 连警告都没有。`$truncated` 只看字符数，因此卡片不会提示内容被截断，“允许”和“总是允许”按钮照常显示。用户批准的是完整的原始调用，但在卡片上根本看不到关键参数。hook 把请求写入 `.req.json` 时用的是 `-Depth 30`，同类问题在更深的层级也存在。

**复现**（已在 pwsh 7.4.6 上验证）：
```powershell
$req = '{"tool":"mcp__db__run","input":{"query":{"where":{"and":{"or":{"not":{"x":{"cmds":["DROP TABLE users"]}}}}}}}}' | ConvertFrom-Json
(Get-RequestSummary $req).Detail      # {"query":{"where":{"and":{"or":{"not":"@{x=}"}}}}}
(Get-RequestSummary $req).Truncated   # False  -> 卡片显示“允许”
```

**修复建议**：
- `default` 分支改用足够大的深度（例如 `-Depth 100`），并检测是否超出深度：先用 `-Depth 100` 序列化，再与原始 JSON 的嵌套深度比较；或者在 PS 7 下检查是否出现 `WarningVariable`。一旦超出，就设 `Truncated = $true`，只允许拒绝或去终端处理。
- hook 端同理：`ConvertTo-Json -Depth 30` 如果截断了 `tool_input`，应该放弃接管（不输出，退出码 0，交回终端）。

**能发现该问题的测试**（`RequestSafety.Tests.ps1`）：
```powershell
$deep = '{"id":"..","tool":"mcp__x__y","input":{"a":{"b":{"c":{"d":{"e":{"f":"SECRET-ARG"}}}}}}}' | ConvertFrom-Json
$s = Get-RequestSummary $deep
Assert (($s.Detail -like '*SECRET-ARG*') -or $s.Truncated) 'deep MCP input is shown in full or can only be denied'
```

---

## 2.【高】“总是允许”会一次性应用所有 `permission_suggestions`，而卡片上完全不显示具体授予了什么

**位置**：`hooks/ClaudeHook.ps1:267-273`，`src/Requests.ps1:452-454`、`1292-1294`

**问题**：Claude Code 的 `permission_suggestions` 是一个列表，每一项对应终端里一个带说明的选项，例如“Yes, and don't ask again for `npm test:*` in this project”，也可能是 `addDirectories`、`setMode: acceptEdits` 等。卡片上只有一个没有任何说明的“总是允许”按钮。点击后，hook 把**全部** suggestions 原样放进 `updatedPermissions`。结果是：
- 用户不知道写入了什么规则，写到哪个设置文件（`destination`），作用范围多大；
- 一次点击可能同时添加多条规则，或者顺带切换权限模式，例如整个会话进入 acceptEdits，之后的文件修改不再询问。这比终端里任何一个单独选项授予的权限都大。

**复现**：构造一个 PermissionRequest，让 `permission_suggestions` 同时包含
`{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm:*"}],"behavior":"allow","destination":"localSettings"}` 和 `{"type":"setMode","mode":"acceptEdits","destination":"session"}`。
卡片只显示“总是允许”；点击后，hook 输出的 `decision.updatedPermissions` 同时包含这两项。用 `RequestSafety.Tests.ps1` 里现有的 `Invoke-HookFixture` 就能看到。

**修复建议**：
- 卡片上把每条 suggestion 显示成单独的按钮，写明规则内容、类型和范围，例如“总是允许 `Bash(npm:*)`（本项目）”。回答时只带上用户选中的那**一条**（用索引或内容哈希，hook 端按索引从自己的 `$in.permission_suggestions` 里取，不信任响应里的内容）。
- 至少应该把 `setMode` 和 `addDirectories` 这类改变整个会话权限的项排除在“总是允许”之外，或者单独标出来。

**能发现该问题的测试**：
- `RequestSafety.Tests.ps1`：hook fixture 带两条 suggestions，响应为 `{action:'always', suggestion:0}`，断言 `updatedPermissions` 只有第 0 条；响应为 `{action:'always'}`（不带索引）时，不得输出包含 `setMode` 的项。
- 单元测试：`Get-RequestSummary`（或新的按钮生成函数）的输出里包含 `npm:*` 这样的规则文本。

---

## 3.【中】命令卡片把 AI 写的 `description` 放在命令前面，命令可能被挤出可视区域

**位置**：`src/Requests.ps1:610-618`（Bash/shell 分支），显示区域见 `1277-1279`（`New-ReqScroll $dt 150`）

**问题**：卡片的详情内容是 `justification + "\n" + description + "\n" + command`，显示在一个高 150px 的可滚动框里（12pt 等宽字体大约 9 行）。`description` 和 `justification` 由模型生成，可能受到提示注入的影响。描述稍长时，真正要执行的命令就在可视区域之外，用户只看到“Run the unit tests…”就点了“允许”。终端里 Claude Code 是先显示命令、再显示描述的。

**复现**（已在 pwsh 7.4.6 上验证）：`description` 为 15 行“Run the unit tests (step n)”，`command='rm -rf ~/projects'`，则 `Get-RequestSummary` 输出的第 1 行是描述，命令在第 16 行（共 16 行）。

**修复建议**：命令永远放在第一行，并且单独放在等宽字体的框里。`description`/`justification` 放在命令下方，用普通字体、较暗的颜色，而且不计入命令框的高度。也可以给说明文字限制行数（比如最多 3 行，可展开）。

**能发现该问题的测试**：
```powershell
$s = Get-RequestSummary ([pscustomobject]@{ tool='Bash'; input=[pscustomobject]@{ command='rm -rf ~/x'; description=((1..15|%{"line $_"}) -join "`n") } })
Assert (($s.Detail -split "`n")[0] -eq 'rm -rf ~/x') 'command is the first line on the card'
```

---

## 4.【中】stdin 开头带 BOM 时，hook 在 Windows PowerShell 5.1 上直接失败（已在 PR #1 修复）

**位置**：`hooks/ClaudeHook.ps1:147-149`

**问题**：如果父进程的控制台编码是 UTF-8（例如 `chcp 65001`，或者父进程是用 .NET Framework 写 stdin 的程序），stdin 开头会多一个 U+FEFF。5.1 的 `ConvertFrom-Json` 会报 `Invalid JSON primitive`，hook 只记一行 `error at read input` 就退出，所以所有请求和通知都会悄悄退回终端。PS 7 能容忍 BOM，所以本地测不出来。hook 在生产环境中正是用 5.1 运行的（`Get-ClaudeHookCommand` 固定用 `powershell.exe`）。

**复现**：在 GitHub Actions `windows-latest` 的 `powershell` 下运行 `Notices.Tests.ps1` 和 `RequestSafety.Tests.ps1`，hook 的诊断日志是 `codes: 65279,123,...`，接着是 `error at read input: Invalid JSON primitive`。

**修复**：读取输入后执行 `$raw = $raw.TrimStart([char]0xFEFF)`。PR #1（`cloud/t1-ci`）已经这样修改。

**测试**：`Notices.Tests.ps1` 中的 “input with a byte order mark is still read”（已在 PR #1 加入，修复前在 PS 7 上也会失败）。
