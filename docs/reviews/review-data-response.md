# 对 review-data.md 的处理说明

分支 `fix/data`（基于 `dev-0.0.3`）。每一条都是先写失败的测试（`tests/DataReview.Tests.ps1`），再修代码。修复后，在 `TZ=Asia/Shanghai`、`UTC`、`America/New_York` 三个时区下这 48 项测试全部通过。

| # | 结论 | 修改 |
|---|---|---|
| 1 | 同意，已修复 | `Data.ps1`：退避时间和用量缓存的日期改用现有的 `ConvertTo-RenewalUtc`，不再经过 `[string]` |
| 2 | 同意，已修复 | `GrokData.ps1`：`Test-GrokAuthEntryExpired` 和 `Convert-GrokPeriodEnd` 改用新的 `ConvertTo-DateTimeOffset` |
| 3 | 同意，已修复 | `Format.ps1`：`Format-Reset` 不再限定 `[string]` 参数类型，改用 `ConvertTo-DateTimeOffset` |
| 4 | 同意，已修复 | `CodexData.ps1`、`unified-overlay.ps1`、`Shell.ps1`：补解析期间仍请求实时配额，结果标记为 `CatchingUp`，并保留上一次的完整本地统计 |
| 5 | 同意，已修复 | `Data.ps1`：`Convert-StatsCacheDate` 遇到 `Kind=Utc` 时转成本地时间（与 `Convert-CodexCacheDate` 一致） |
| 6 | 部分同意 | 已修：按 job 类型计算超时上限，Cursor 请求也改用 `UsageTimeoutSec`。暂不做：把 Cursor 拆成独立 job（原因见下） |

## 各条说明

**1–3（日期在 PS7 下被转成 `[string]`）**

在 `Config.ps1` 新增 `ConvertTo-DateTimeOffset`。选 `Config.ps1` 是因为主进程和每个后台 job 都会先加载它，`Format.ps1` 和 `GrokData.ps1` 都能直接使用。它的规则：
- `[DateTimeOffset]` 原样返回；
- `[datetime]` 用 `DateTimeOffset(DateTime)` 构造，保留 Kind（Utc 得到 +00:00，Local / Unspecified 按本地时间）；
- 字符串按 InvariantCulture 解析，没有时区时按本地时间处理，这与以前 `DateTimeOffset.Parse` 的语义一致。

`Data.ps1` 在测试里是单独加载的，所以它继续使用自己文件里已有的 `ConvertTo-RenewalUtc`，没有新增对 `Config.ps1` 的依赖。

测试在 en-GB、de-DE、fr-FR、en-US 下覆盖了以下几种输入：
- 退避时间（2 月 3 日，会被日月对调的情况）的读写往返；
- 用量缓存的恢复；
- 已过期和未过期的 Grok token（含 `Z`、UTC `[datetime]`）；
- 传给 `Format-Reset` 的五种输入：`+00:00` 和 `Z` 两种 JSON 日期、`DateTimeOffset`、Local 和 Utc 两种 `[datetime]`。

修复前 en-US 下 UTC `[datetime]` 的倒计时少了 8 小时（东八区），其他区域则是空白。

另外，UI 审查（`docs/reviews/review-ui.md` 第 1 条）里的 `Format-PanelReset` / `Set-Spark`（`Shell.ps1`）是同一类问题，不属于 data 范围，这次没有改。修那一条时可以直接用 `ConvertTo-DateTimeOffset`。

**4（Codex 补解析期间面板变成 "--"）**
- `Get-CodexStats` 在解析预算用完时仍保存进度，但不再提前返回。它照常请求实时配额，返回一个只有实时字段的结果，并带上 `CatchingUp = $true` 和 `LiveOk`。
- 新增 `Merge-CodexStatsResult`：收到 `CatchingUp` 结果、且之前已有完整结果时，保留之前的本地统计（token、费用、会话数等），只用实时接口的值覆盖周用量、5 小时用量、重置次数、套餐和 credits。实时接口这一轮也失败时，原样保留之前的结果。
- 完全没有之前结果时（例如升级后第一次运行），`Update-CodexSection` 会把本地统计几行显示成 "--"，不显示部分统计的数字。这样仍然满足原代码"部分统计不能当真实数字显示"的要求，同时周用量和 5 小时用量照常显示。
- 测试会模拟预算为 0，确认实时接口被调用、结果带实时数字和 `CatchingUp`、合并规则正确，并确认下一轮预算恢复后能发布完整统计。

**5（5.1 下 Claude 统计缓存的日期是 UTC）**

按建议修复。测试断言：输入 `Kind=Utc` 的日期，输出为同一时刻、非 UTC 的本地时间。

**6（cursor.com 慢时 Claude job 被反复回收）**
- 已修：新增 `Get-RefreshJobCeilingSeconds`。`ClaudeUsage` job 串行最多发 5 个请求（usage、profile、Cursor 的 usage / summary / analytics），上限改为 `5 × UsageTimeoutSec + 20` = 120 秒；其他 job 仍是原来的 `2 × UsageTimeoutSec + 20`。同时 job 里的 `Get-CursorUsage`、`Get-CursorLocalStats` 也使用 `UsageTimeoutSec`，让上限和实际超时对得上。这样 cursor.com 很慢时，job 能跑完（下一轮 tick 只会跳过，不会杀掉重启），Claude 数据最多晚一轮更新，而不是一直不更新。测试：运行了 61 秒的 `ClaudeUsage` job 不会被回收，运行了 200 秒的仍会被回收。
- 暂不做（拆成独立的 `CursorUsage` job）：这会改动刷新结果的处理分支、`Update-AllSections` 里"Syncing"状态对应 job 的方式（cursor 目前对应 `ClaudeUsage`）、`Get-ProviderLoginRefreshKinds`、手动刷新列表和历史采样的时机，范围明显大于这个 bug 本身。超时上限修正后已经不会再出现"反复回收"的循环。拆分 job 适合作为单独的任务做，最好能在 Windows 上验证。

**"未列入的观察"两条**

同意审查者的判断，不是 bug，这次不处理。
