# 对 review-requests.md 的回复（修复方）

- 审查：`review/requests` 分支上的 `docs/reviews/review-requests.md`
- 修复分支：`fix/requests`（基于 `dev-0.0.3`）
- 做法：每个同意的问题先写一个会失败的测试（新文件 `tests/RequestReview.Tests.ps1`），再修代码。保持 Windows PowerShell 5.1 兼容。

| # | 结论 | 说明 |
|---|---|---|
| 1 | 同意，已修复 | 卡片和 hook 两边都处理了 |
| 2 | 部分同意 | 已修复“卡片上看不到授予了什么”；不接受“每条 suggestion 单独一个按钮” |
| 3 | 同意，已修复 | 命令放在第一行，说明文字单独显示 |
| 4 | 同意，但本分支不重复修改 | 已在 PR #1（`cloud/t1-ci`）修复 |

## 1. 嵌套过深的 MCP 输入 — 同意，已修复
- 卡片（`src/Requests.ps1` 的 `Get-RequestSummary` default 分支）：改为 `-Depth 100`。新增 `Get-ReqJsonDepth`（不用递归计算嵌套深度），深度超过 100 时设 `Truncated = $true`，卡片上只保留“拒绝 / 去终端”。
- hook（`hooks/ClaudeHook.ps1`）：`tool_input` 或 `permission_suggestions` 的嵌套深度超过 24 时，hook 不接管：不写请求文件、不输出，退出码 0，交回终端。请求文件和回答都用 `-Depth 30` 序列化，回答里输入还要再往下包 3 层，所以 24 留有余量。
- 我先在 pwsh 上实测了 `ConvertTo-Json -Depth N` 的规则：对象和数组都算一层，第 N+1 层开始被转成字符串。审查里的例子用数组做叶子，正好能看到内容被替换成 `System.Object[]`，所以测试也用数组做叶子。叶子是普通字符串时，被转成 `@{k=...}` 的字符串里仍然包含原文，测试会误判为通过。
- 测试：`1 deep MCP input is shown in full or can only be denied`、`1 MCP input deeper than the card can show can only be denied`、`1 hook hands too-deep input back to the terminal`。另外加了两条保护测试，确认正常输入仍然可以允许。

## 2. “总是允许”授予的内容不可见 — 部分同意

**同意并已修复的部分**：卡片确实完全没有说明“总是允许”会写入什么，这是真实的问题。新增 `Format-ReqGrants`，把每条 `permission_suggestions` 写成一行，显示在按钮上方（“总是允许”还会授予：…）：
- 规则类：`addRules`、`replaceRules`、`removeRules`，显示 behavior、`Tool(ruleContent)` 和 destination；
- `setMode`：显示切换到的模式（例如 acceptEdits）和范围；
- `addDirectories`、`removeDirectories`：显示文件夹和范围；
- 不认识的类型：原样显示 JSON，不会隐藏。

新增的界面文字都补了 zh/ja/fr/ko 翻译。

**不接受的部分**：把每条 suggestion 拆成单独的按钮，回答时只带一条（按索引）。理由如下：
1. 据我对 Claude Code 的了解，`permission_suggestions` 对应的是终端权限对话框里的那**一个**“是，并且不再询问…”选项。终端选这个选项时，会把这一组更新一起应用（例如命令跨目录时，规则和 `addDirectories` 是一起加的；文件修改对话框里的“本会话允许所有修改”就是 `setMode acceptEdits`）。按条拆开，会产生终端里从来没有的组合（例如只加规则、不加目录），之后的请求可能还会再问，或者行为与终端不一致。
2. 安全上要解决的是“用户不知道授予了什么”，这一点现在卡片上已经逐条写明了，而且和终端授予的范围完全一样。审查里说的“比终端里任何一个单独选项授予的权限都大”，只有在这些 suggestions 在终端里也是分开的选项时才成立；按第 1 点，它们是同一个选项。
3. 我没有办法在这个环境里运行真实的 Claude Code 去验证第 1 点。如果维护者确认终端里这些 suggestions 是分开的选项，再改成按条选择：hook 端按索引从自己的 `$in.permission_suggestions` 里取，不信任响应里的内容。可以另开任务。

同理，也不在“总是允许”里排除 `setMode` 和 `addDirectories`：终端的同一个选项也会应用它们，而且现在卡片上会明确显示，例如“权限模式：acceptEdits · session”。

- 测试：`2 card lists the rule Always allow saves, and where`、`2 card lists a permission mode change`、`2 card lists added folders`，以及保护测试 `2 no grants shown where Always allow is not offered (Codex)`。

## 3. 说明文字把命令挤出可视区域 — 同意，已修复
- Bash 和 shell 类分支：`Detail` 只包含命令本身，所以命令一定在第一行。`justification` 和 `description` 移到新的 `Note` 字段，在命令框**下方**用灰色普通字体显示，放在一个最多 60px 高的独立滚动区里，不占用命令框的 150px。说明文字只用于显示，过长时截断，不影响“允许”按钮。
- 测试：`3 command is the first line on the card`、`3 description is shown apart from the command`、`3 Codex justification is shown apart from the command`。

## 4. stdin 开头的 BOM — 同意，本分支不重复修改
PR #1（`cloud/t1-ci`）已经在 `hooks/ClaudeHook.ps1` 读入输入后加了 `TrimStart([char]0xFEFF)`，并且有对应的测试。在这里再改一次会和 PR #1 冲突，所以以 PR #1 为准。

## 测试结果
- `fix/requests` 单独运行（Linux，pwsh 7.4.6）：9 个测试文件中 8 个通过。`RequestSafety.Tests.ps1` 失败在清理阶段：`dev-0.0.3` 上写死了 `\` 路径分隔符，这是 T2 的问题，由 PR #3 修复，与本分支的改动无关。
- 把 PR #3（`cloud/t2-tests`）临时合并到本分支后，在临时工作区里 9 个文件全部通过（其中 RequestSafety 27 条、RequestReview 12 条、ReviewRegressions 41 条）。
- 没有 Windows PowerShell 5.1 环境，没有在 5.1 上实际运行。新代码只用了 5.1 也支持的写法：没有 `??`、三元运算符或 `-AsHashtable`，改动的 .ps1 文件保留了 BOM。
