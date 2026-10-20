# 代码审查：用量数据层（area: data）

- 范围：`src/Data.ps1`、`src/CodexData.ps1`、`src/CursorData.ps1`、`src/GrokData.ps1`、`unified-overlay.ps1`
- 基线：`dev-0.0.3`（aed2bac）
- 测试：Linux 上 PowerShell 7.4.6 运行 `tests/*.Tests.ps1`：7 个通过；`RequestSafety.Tests.ps1` 因 Linux 路径问题失败（清理检查只认 `\`），已由 PR #3（`cloud/t2-tests`）修复，与本审查范围无关。现有测试全部在 en-US 区域、UTC 时区下运行，所以没有覆盖下面第 1–3 条。
- 复现脚本都只用测试夹具（假 token、临时目录），没有读取任何真实凭据文件。

严重程度：blocker（不能发布）> high（主要功能对部分用户失效）> medium（显示错误或特定条件下失效）> low。

本次没有发现 blocker。

---

## 1. [high] PowerShell 7 下 Claude 退避时间和用量缓存的日期读取依赖系统区域，在 dd/MM 区域会读错或读不出

**位置**
- `src/Data.ps1:207`：`[System.DateTimeOffset]::Parse([string]$json.BackoffUntil)`
- `src/Data.ps1:376`：`[System.DateTimeOffset]::Parse([string]$saved.FetchedAt)`

**问题**
PowerShell 7 的 `ConvertFrom-Json` 会把 ISO 日期字符串自动转成 `[datetime]`（docs/DEVELOPMENT.md“Known pitfalls”里已经提到）。`[string]` 转换用的是不变区域格式 `MM/dd/yyyy HH:mm:ss`，而 `DateTimeOffset.Parse` 用的是当前区域。区域是 en-GB、de-DE、fr-FR 等 dd/MM 格式时：

- 日 ≤ 12：日和月对调。例如写入 2 月 3 日的退避，读回来变成 3 月 2 日。
- 日 > 12：解析失败，被 `catch` 吞掉后返回 `$null`。

**后果**
- 429 限流的退避故意不绑定 token（`Data.ps1:976-979`）。读错时，可能“退避”一个月，Claude 面板长期显示 “Rate limited”，只有凭据文件变化触发 `-Force` 刷新才会恢复。解析失败时退避被忽略，每次轮询都会再打 API。这正是退避机制要防止的，会让服务端限流越来越重。
- `Get-CachedClaudeUsage` 在这些区域总是返回 `$null`，启动时无法显示上次的用量（0.0.2 的“用量缓存”功能失效）。没有日志，因为日期读错时是安静地被年龄检查丢弃的。

**复现**（`pwsh`，PowerShell 7）
```powershell
[Threading.Thread]::CurrentThread.CurrentCulture = 'en-GB'
$script:AppDir = <临时目录>; $script:ErrLog = <临时目录>\e.log
. src/Data.ps1
Set-ClaudeBackoffUntil -BackoffUntil ([datetime]'2027-02-03T10:00:00') -Status stale
(Get-ClaudeBackoffState).Until      # 得到 2027-03-02 10:00，应为 2027-02-03 10:00
Save-ClaudeUsageCache ([pscustomobject]@{ five_hour = @{ utilization = 1 } })
Get-CachedClaudeUsage               # 得到 $null，应返回刚保存的数据
```
实测：en-US、zh-CN 正常；en-GB、de-DE 都会出错。

**建议修复**
读取时先做规范化，不要经过 `[string]`。可以复用现有的 `ConvertTo-RenewalUtc`（它已经处理了 `[DateTimeOffset]`、`[DateTime]` 和字符串三种情况，并用 InvariantCulture 解析）：
```powershell
$until = (ConvertTo-RenewalUtc $json.BackoffUntil).ToLocalTime()
$asOf  = [DateTimeOffset](ConvertTo-RenewalUtc $saved.FetchedAt)
```
或者写一个通用的 `ConvertTo-UtcDateTime` 放到 Format.ps1，所有读 JSON 日期的地方都用它。

**能发现问题的测试**
`tests/ClaudeUsageCache.Tests.ps1` 新增：把 `CurrentCulture` 依次设为 `en-GB`、`de-DE`，分别用 2 月 3 日（日 ≤ 12）和 10 月 20 日（日 > 12）往返 `Set-ClaudeBackoffUntil`/`Get-ClaudeBackoffState` 和 `Save-ClaudeUsageCache`/`Get-CachedClaudeUsage`，断言读回的时间相同、缓存不为空。测试结束后恢复区域。

---

## 2. [high] Grok：有效的登录 token 会被当成已过期，提示“run grok login”（PowerShell 7，东八区和 dd/MM 区域都会出现）

**位置**
`src/GrokData.ps1:66`：`$exp = [datetimeoffset]::Parse([string]$raw)`

**问题**
与第 1 条同一类问题，但这里多了一层时区错误。`expires_at` 通常是 `...Z`（UTC）。PowerShell 7 读成 `Kind=Utc` 的 `[datetime]`，`[string]` 之后丢掉了 `Z`，再按**本地时间**解析。

- 东八区（UTC+8）：每个 token 最后 8 小时被当成已过期。实测一个还有 3 小时有效期的 token 被判为过期。
- en-GB、de-DE：实测 16 天后才过期的 token 直接被判为过期（日月对调）。

判为过期后 `Get-GrokAccessToken` 返回 `$null`，`Get-GrokLiveUsage` 设为 `notoken`，面板显示 “run grok login”，实际上用户是登录状态。

**复现**
```powershell
# TZ=Asia/Shanghai pwsh ...
. src/GrokData.ps1
$exp  = [datetime]::UtcNow.AddHours(3).ToString('yyyy-MM-ddTHH:mm:ssZ')
$auth = ('{"https://auth.x.ai::client":{"key":"fixture-token","expires_at":"' + $exp + '"}}') | ConvertFrom-Json
Get-GrokAccessToken $auth   # 得到 $null，应返回 'fixture-token'
```
TZ=UTC 和 America/New_York 下正常，Asia/Shanghai 下出错；en-GB、de-DE 区域下即使 16 天后过期也出错。

**建议修复**
```powershell
if ($raw -is [DateTimeOffset]) { $exp = $raw }
elseif ($raw -is [datetime]) {
    $u = if ($raw.Kind -eq 'Local') { $raw.ToUniversalTime() } else { [datetime]::SpecifyKind($raw, 'Utc') }
    $exp = [DateTimeOffset]$u
} else {
    $exp = [DateTimeOffset]::Parse([string]$raw, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
}
```
（和第 1 条共用同一个规范化函数最好。）同一个文件的 `Convert-GrokPeriodEnd`（`GrokData.ps1:127`）对 `Kind=Utc` 的 `[datetime]` 也是原样返回，没有转本地时间，修第 2 条时一起统一。

**能发现问题的测试**
新增 `tests/GrokData.Tests.ps1`：用夹具 auth 对象（假 token），`expires_at` 分别为“现在 + 3 小时（Z）”和“现在 − 1 分钟（Z）”，在 `CurrentCulture = en-GB` 下断言前者能拿到 token、后者拿不到。时区问题在 Linux CI 上可以用 `TZ=Asia/Shanghai pwsh -File ...` 跑同一个测试，或者测试内直接比较 `UtcDateTime`。

---

## 3. [medium] dd/MM 区域下重置倒计时为空或错误（Claude 在 PowerShell 7 下、Codex、Grok）

**位置**
- 数据层交出 `[datetime]`：`src/CodexData.ps1:534`（`Convert-CodexEpochSeconds` 返回 `LocalDateTime`）、`src/GrokData.ps1:127-130`；PowerShell 7 下 `Invoke-RestMethod` 把 Claude 的 `resets_at` 也变成了 `[datetime]`（`Data.ps1:945` 的结果原样进入 `State.Data`）。
- 显示层用 `[string]` 接收：`src/Format.ps1:36` `function Format-Reset([string]$iso)`，内部用当前区域 `DateTimeOffset::Parse`。这一行不在本次审查的文件里，但问题来自数据层的类型约定。

**问题**
`[datetime]` 传进 `[string]$iso` 时变成 `MM/dd/yyyy HH:mm:ss`，与第 1 条一样，在 dd/MM 区域里要么解析失败（倒计时显示空白），要么日月对调（倒计时差几个月）。

**复现**
```powershell
[Threading.Thread]::CurrentThread.CurrentCulture = 'en-GB'
. src/Format.ps1; . src/CodexData.ps1
$epoch = [DateTimeOffset]::UtcNow.AddDays(3).AddHours(5).ToUnixTimeSeconds()
$p = ConvertFrom-CodexUsageResponse ([pscustomobject]@{ rate_limit = [pscustomobject]@{ primary_window = [pscustomobject]@{ limit_window_seconds = 604800; used_percent = 10; reset_at = $epoch } } })
Format-Reset $p.WeekResetsAt     # en-GB: ''；en-US: '↺ 3d 4h'
```
Claude（PowerShell 7）：`'{"five_hour":{"resets_at":"<30 小时后>+00:00"}}' | ConvertFrom-Json` 后 `Format-Reset $d.five_hour.resets_at`，en-GB 下为空，en-US 和 zh-CN 下为 `↺ 1d 5h`。

**建议修复**
在 `Format-Reset` 里去掉 `[string]` 约束，接收任意类型，并用第 1 条的规范化函数转成 `DateTimeOffset`（字符串用 InvariantCulture 解析）。数据层继续交 `[datetime]` 或 ISO 字符串都可以，但要在 docs/DEVELOPMENT.md 里写明约定。

**能发现问题的测试**
`Format-Reset` 单元测试：在 `en-GB`、`de-DE` 区域下，分别传入 `[datetime]`（Local 和 Utc 两种 Kind）、`[DateTimeOffset]` 和 ISO 字符串（含 `Z` 和 `+00:00`），时间都是“现在 + 30 小时”，断言结果都是 `↺ 1d 5h`（或 6h，取决于秒数）。

---

## 4. [medium] Codex 会话日志补解析期间，Codex 整个面板变成 “--”，实时配额也不会刷新

**位置**
- `src/CodexData.ps1:986-996`：`$stopped` 时直接 `return`，`$script:CodexStats` 保持 `$null`，并跳过了 `Get-CodexLiveUsage`（`:1013`）
- `unified-overlay.ps1:759`：`$script:CodexStats = $r['CodexStats']` 无条件覆盖

**问题**
大量会话日志第一次解析时，会超过 35 秒预算（`CodexParseBudgetSeconds`），这一轮会提前返回。每个后台 job 都是新的运行空间，`CodexStats` 一开始就是 `$null`，所以这一轮返回 `CodexStats = $null`，`CodexAuthState = 'init'`。主线程把它直接覆盖到界面上，`Update-CodexSection`（`Shell.ps1:2051`）就把所有行显示成 “--”。

同时实时接口（周用量、5 小时用量、重置次数、credits）这一轮也不请求了。代码注释（`CodexData.ps1:859`、`:1010`）明确说实时配额不依赖本地日志，现在却被本地解析进度卡住。

这个版本把 `CodexCacheVersion` 提到了 5（`:136`），升级后所有用户的缓存都会失效、重新完整解析。会话日志大的用户（注释提到单个会话 535 MB），升级后会有好几轮轮询（每轮 3 分钟）Codex 面板是空的。

**复现**
```powershell
# 夹具：CODEX_HOME 下两个很小的 .jsonl 会话；$script:CodexParseBudgetSeconds = 0 模拟预算耗尽
function Get-CodexLiveUsage { $script:liveCalled = $true; @{ WeekPct = 42.0 } }
Get-CodexStats
# 实测：CodexStats -eq $null 为 True，liveCalled 为 False
```

**建议修复**
1. `Get-CodexStats` 中，`$stopped` 时仍然调用 `Get-CodexLiveUsage`，用 `Measure-CodexStats @() (Get-Date)` 做一个只有实时字段的结果，并加一个标记（例如 `CatchingUp = $true`），让界面显示“正在读取会话日志”，而不是 “--”。
2. `Complete-RefreshJobs` 的 `'CodexStats'` 分支：结果标记了 `CatchingUp`，或者 `CodexStats` 为空但上一次有值时，保留上一次的本地统计（和 Claude 的 `Resolve-ClaudeUsageState` 一样，保留旧值并标为过时）。

**能发现问题的测试**
在 `tests/CodexCredits.Tests.ps1`（或新建 `CodexStats.Tests.ps1`）里用上面的夹具，设 `CodexParseBudgetSeconds = 0`，mock `Get-CodexLiveUsage`，断言：(a) mock 被调用；(b) `$script:CodexStats.WeekPct -eq 42`；(c) 下一轮预算恢复后，本地统计与一次性完整解析的结果一致。

---

## 5. [medium] Windows PowerShell 5.1 下 Claude 统计缓存的日期是 UTC，“今天”和“工作时间外”统计错位

**位置**
`src/Data.ps1:1092`：`Convert-StatsCacheDate` 遇到 `[datetime]` 就原样返回

**问题**
Windows PowerShell 5.1 的 `ConvertTo-Json` 把日期写成 `\/Date(ms)\/`，`ConvertFrom-Json` 读回时是 `Kind=Utc` 的 `[datetime]`。`CodexData.ps1:83-88` 的注释记录了同一个现象，并且只在 Codex 一侧修了（`ToLocalTime()`）。Claude 统计缓存（`stats-cache.json`）走的 `Convert-StatsCacheDate` 没有这一步。

第一次解析时是本地时间，但从第二轮起，文件没变化的记录都从缓存读，时间都变成了 UTC。`Measure-Stats` 用 `$r.Date.Date -eq $today.Date` 和 `$Date.Hour` 判断“今天”和“工作时间外”，东八区的用户：

- 本地 00:00–08:00 的消息被算到昨天。
- 本地 09:30 的消息变成 01:30，被算成“工作时间外”。

**复现**（等价模拟：把 5.1 读回的 UTC 值直接交给转换函数）
```powershell
# TZ=Asia/Shanghai
$asRead51 = [datetime]::Today.AddHours(9.5).ToUniversalTime()
$r = @(Convert-StatsCacheRecords @([pscustomobject]@{ Model='m'; Date=$asRead51; In=1; Out=1; CacheW=0; CacheR=0; SessionId='s'; Key='k' }))[0]
$r.Date.ToString('HH:mm')        # 01:30；Convert-CodexCacheDate 同样的输入得到 09:30
Test-UsageAfterHours $r.Date     # True，应为 False
```
在 Windows PowerShell 5.1 上可以直接复现：同一组 transcript 跑两次 `Get-Stats`，第二次的 `TodayAfterHoursMsg` 和 `TodayMsg` 与第一次不同。

**建议修复**
`Convert-StatsCacheDate` 改成和 `Convert-CodexCacheDate` 一样：`Kind -eq Utc` 时返回 `.ToLocalTime()`。

**能发现问题的测试**
新建 `tests/ClaudeStats.Tests.ps1`：
1. 给 `Convert-StatsCacheRecords` 传入 `Kind=Utc` 的日期，断言输出与输入是同一时刻、`Kind=Local`。
2. 集成：夹具 transcript 目录跑两次 `Get-Stats`，断言两次的 `TodayMsg`、`TodayAfterHoursMsg` 相同。在 Windows CI（5.1）上这一步能直接抓到这个 bug。

---

## 6. [medium]（需要慢网络才会触发）用量接近上限时，cursor.com 慢会让 Claude 刷新 job 被反复杀掉

**位置**
- `unified-overlay.ps1:653`：超时上限 `2 * $UsageTimeoutSec + 20` = 60 秒（定时器调用时 `UsageTimeoutSec` 是默认的 20）
- `unified-overlay.ps1:458-460`：同一个 `ClaudeUsage` job 里还串行跑了 `Get-CursorUsage`（2 个请求）和 `Get-CursorLocalStats`（1 个请求），它们不受 `UsageTimeoutSec` 约束，各自用默认 20 秒超时
- `unified-overlay.ps1:571`、`:596`：5 小时用量 ≥ `WarnPct`（80%）时轮询间隔变成 60 秒

**问题**
这个 job 最坏耗时约为 Claude usage 20 秒 + profile 20 秒（换 token 时）+ Cursor 3 × 20 秒，最多 100 秒。轮询间隔是 60 秒，下一次 tick 时 job 已经跑了 60 秒，超过上限就被杀掉，然后马上启动一个新的，周而复始。

结果是在 Claude 用量最高、最需要看到实时数字的时候，Claude 的数据一直不更新，同时日志里每分钟一条 “hung > 60 seconds; reaping”。只有 cursor.com 连接挂起（连接不报错、要等到超时，例如被防火墙丢包、代理很慢）时才会触发。我没有在真实网络上复现，以上是根据代码推算的。

**建议修复**
1. 把 Cursor 拆成独立的 job（例如 `CursorUsage`），这样 Claude 不受 Cursor 网络影响。
2. 超时上限按每种 job 实际的最大耗时分别计算，不要用一个公式套所有 job。

**能发现问题的测试**
对 `Start-AllRefreshJobs` 用 test double（代码注释里已经支持“lightweight test doubles”）：放入一个 `State='Running'` 的假 `ClaudeUsage` job，把 `pollJobStartedAt` 设为 61 秒前，断言它不会被回收（或者断言上限 ≥ 该 job 各请求超时之和）。拆分 job 后，再断言 `ClaudeUsageScript` 里不再调用 `Get-Cursor*`。

---

## 未列入的观察（不是问题，或者证据不足）
- `Sync-ClaudePollTimerInterval` 取 `min(baseline, adaptive)`，所以 300 秒和 900 秒的自适应放慢实际上不会生效。注释说明这是有意的（不能拖慢其它服务商），不算 bug，但 `Get-ClaudeAdaptivePollSeconds` 里相应的分支是无效代码。
- `codex-cache.json` 为每个 token_count 增量都保存一条记录，会一直增长；每轮都要完整 `ConvertFrom-Json`。长期可能拖慢 Codex job，但没有测量数据，暂不列为问题。
