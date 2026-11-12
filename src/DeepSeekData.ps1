# DeepSeek Harness usage: local session statistics (token counts from the
# Harness transcripts), plus the real account balance from DeepSeek's official
# API (https://api.deepseek.com/user/balance). No estimated money figures.
#
# Where the balance comes from, first that answers wins:
#   1. Your own API key - environment variable DEEPSEEK_API_KEY (process, user
#      or machine), else the first line of deepseek-api-key.txt in the app
#      folder (never written anywhere by this app).
#   2. DeepSeek Harness itself, while it runs: its local phone/pet server
#      (GET /m/api/account-usage on 127.0.0.1) asks DeepSeek with the key
#      Harness keeps, and returns only the amount - the key never reaches
#      this app. If Harness has an access password (its phone-pairing
#      口令), put it on the first line of deepseek-harness-token.txt in the
#      app folder yourself; it is sent only to 127.0.0.1 as X-Mobile-Token.
# The last real balance is remembered with its time (deepseek-budget.json),
# so with Harness closed the card still shows it, labelled with when it was read.
$script:DeepSeekStats = $null

function Get-DeepSeekApiKey {
    foreach ($scope in 'Process', 'User', 'Machine') {
        $v = [Environment]::GetEnvironmentVariable('DEEPSEEK_API_KEY', $scope)
        if ($v -and $v.Trim()) { return $v.Trim() }
    }
    $f = Join-Path $script:AppDir 'deepseek-api-key.txt'
    if (Test-Path -LiteralPath $f) {
        try { $v = (Get-Content -LiteralPath $f -TotalCount 1).Trim(); if ($v) { return $v } } catch { }
    }
    return ''
}
$script:DeepSeekPython = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'
if (-not (Test-Path -LiteralPath $script:DeepSeekPython)) {
    $found = Get-Command python.exe, py.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $script:DeepSeekPython = $found.Source }
}
$script:DeepSeekUsageScript = {
    param([string]$AppDir, [string]$Python, [string]$ApiKey)
    try {
        $raw = & $Python (Join-Path $AppDir 'src\deepseek-usage.py') 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Local usage reader failed' }
        $stats = ($raw -join "`n") | ConvertFrom-Json
    } catch {
        $stats = [pscustomobject]@{ Status = 'error'; Message = 'Local usage unavailable' }
    }
    $harnessNote = ''
    if (-not $ApiKey) {
        # DeepSeek Harness's own local server: port 3080 by default, else any
        # port its processes listen on. Loopback only, short timeouts.
        $ports = New-Object System.Collections.Generic.List[int]
        $ports.Add(3080)
        try {
            $ids = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { [string]$_.ExecutablePath -match 'DeepSeek Harness|\\\.dsh\\' -or [string]$_.CommandLine -match '\\\.dsh\\profiles' } | ForEach-Object { [int]$_.ProcessId })
            if ($ids.Count) {
                foreach ($c in @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $ids -contains $_.OwningProcess -and $_.LocalAddress -in @('127.0.0.1', '0.0.0.0', '::', '::1') })) {
                    if (-not $ports.Contains([int]$c.LocalPort)) { $ports.Add([int]$c.LocalPort) }
                }
            } else { $harnessNote = 'harness-closed' }
        } catch { }
        foreach ($port in $ports) {
            $hdr = @{}
            $tokFile = Join-Path $AppDir 'deepseek-harness-token.txt'
            if (Test-Path -LiteralPath $tokFile) { try { $tk = (Get-Content -LiteralPath $tokFile -TotalCount 1).Trim(); if ($tk) { $hdr['X-Mobile-Token'] = $tk } } catch { } }
            try {
                $resp = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/m/api/account-usage" -f $port) -Headers $hdr -TimeoutSec 8 -SkipHttpErrorCheck -ErrorAction Stop
            } catch { continue }
            if ([int]$resp.StatusCode -eq 401) { $harnessNote = $(if ($hdr.Count) { 'harness-password-wrong' } else { 'harness-password' }); break }
            if ([int]$resp.StatusCode -ne 200) { continue }
            try {
                $j = $resp.Content | ConvertFrom-Json
                $src = @($j.sources) | Where-Object { [string]$_.id -eq 'deepseek' -and $null -ne $_.amount } | Select-Object -First 1
                if ($src) {
                    $stats | Add-Member -NotePropertyName Balance -Force -NotePropertyValue ([pscustomobject]@{
                        Total     = [double]::Parse([string]$src.amount, [Globalization.CultureInfo]::InvariantCulture)
                        Granted   = $null
                        ToppedUp  = $null
                        Currency  = $(if ($src.currency) { [string]$src.currency } else { 'CNY' })
                        Available = ($src.available -ne $false)
                        AsOf      = (Get-Date).ToString('o')
                        Source    = 'harness'
                    })
                    $harnessNote = ''
                    break
                } else { $harnessNote = 'harness-no-deepseek' }
            } catch { }
        }
        if (-not $stats.Balance -and -not $harnessNote) { $harnessNote = 'harness-no-server' }
        if ($harnessNote) { $stats | Add-Member -NotePropertyName HarnessNote -NotePropertyValue $harnessNote -Force }
    }
    if ($ApiKey) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $r = Invoke-RestMethod -Uri 'https://api.deepseek.com/user/balance' -TimeoutSec 15 `
                -Headers @{ Authorization = 'Bearer ' + $ApiKey; Accept = 'application/json'; 'User-Agent' = 'JayOS-AI-Usage' }
            $infos = @($r.balance_infos)
            $info = $infos | Where-Object { $_.currency -eq 'CNY' } | Select-Object -First 1
            if (-not $info) { $info = $infos | Select-Object -First 1 }
            if ($info) {
                $stats | Add-Member -NotePropertyName Balance -Force -NotePropertyValue ([pscustomobject]@{
                    Total     = [double]$info.total_balance
                    Granted   = [double]$info.granted_balance
                    ToppedUp  = [double]$info.topped_up_balance
                    Currency  = [string]$info.currency
                    Available = [bool]$r.is_available
                    AsOf      = (Get-Date).ToString('o')
                    Source    = 'api'
                })
            }
        } catch {
            $code = $null; if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
            $msg = if ($code -eq 401) { 'API key 无效或已失效' } elseif ($code) { "余额接口返回 HTTP $code" } else { '网络不可用，稍后重试' }
            $stats | Add-Member -NotePropertyName BalanceError -NotePropertyValue $msg -Force
        }
    }
    @{ Kind = 'DeepSeekUsage'; DeepSeekStats = $stats }
}
function Format-DeepSeekTokens($Value) {
    if ($null -eq $Value) { return '--' }
    $n = [double]$Value
    if ($n -ge 1000000) { return ('{0:0.00}M' -f ($n / 1000000)) }
    if ($n -ge 1000) { return ('{0:0.0}K' -f ($n / 1000)) }
    return ('{0:0}' -f $n)
}
# Real balance only (from the official API); $null without one - nothing is
# estimated. "Used" is measured against the current top-up: the highest
# balance seen since the last top-up (a jump of more than ¥0.50 starts a new
# one), remembered in deepseek-budget.json as BalancePeakCny.
function Get-DeepSeekBudget {
    $st = $script:DeepSeekStats
    $cfgPath = Join-Path $script:AppDir 'deepseek-budget.json'
    $cfg = $null
    try { $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json } catch { }
    if (-not $st -or -not $st.Balance) {
        # No live answer: the last real balance, marked stale with its time.
        if ($cfg -and $null -ne $cfg.BalanceLastCny -and $cfg.BalanceLastAt) {
            $bal = [double]$cfg.BalanceLastCny
            $peak = [math]::Max([double]$cfg.BalancePeakCny, [math]::Max($bal, 0.01))
            $used = [math]::Max(0.0, $peak - $bal)
            return @{ Total = $peak; Used = $used; Remaining = $bal
                UsedPct = 100 * $used / $peak; RemainingPct = 100 * $bal / $peak
                Granted = $null; ToppedUp = $null; AsOf = [string]$cfg.BalanceLastAt
                Source = [string]$cfg.BalanceLastSource; Stale = $true; LocalOk = ($st -and $st.Status -eq 'ok') }
        }
        return $null
    }
    $bal = [double]$st.Balance.Total
    $peak = 0.0
    if ($cfg -and $cfg.BalancePeakCny) { $peak = [double]$cfg.BalancePeakCny }
    $last = if ($cfg -and $null -ne $cfg.BalanceLastCny) { [double]$cfg.BalanceLastCny } else { $null }
    $newPeak = $peak
    if ($peak -le 0 -or $bal -gt $peak -or ($null -ne $last -and $bal -gt $last + 0.5)) { $newPeak = $bal }
    # Rewritten on every live read, so BalanceLastAt is the time of the last real answer.
    if ($true) {
        try {
            $o = [ordered]@{}
            if ($cfg) { foreach ($p in $cfg.PSObject.Properties) { $o[$p.Name] = $p.Value } }
            $o['BalancePeakCny'] = $newPeak; $o['BalanceLastCny'] = $bal
            $o['BalanceLastAt'] = [string]$st.Balance.AsOf; $o['BalanceLastSource'] = [string]$st.Balance.Source
            [IO.File]::WriteAllText($cfgPath, ($o | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        } catch { }
    }
    $peak = [math]::Max($newPeak, 0.01)
    $used = [math]::Max(0.0, $peak - $bal)
    return @{ Total = $peak; Used = $used; Remaining = $bal
        UsedPct = 100 * $used / $peak; RemainingPct = 100 * $bal / $peak
        Granted = $st.Balance.Granted; ToppedUp = $st.Balance.ToppedUp
        AsOf = [string]$st.Balance.AsOf; Source = [string]$st.Balance.Source; Stale = $false; LocalOk = ($st.Status -eq 'ok') }
}
function Update-DeepSeekPanel {
    if (-not $script:window) { return }
    $header = $script:window.FindName('deepseekHeader')
    if (-not $header) { return }
    $compact = [bool]$script:Cfg.Compact
    $script:window.FindName('deepseekFull').Visibility = if ($compact) { 'Collapsed' } else { 'Visible' }
    $script:window.FindName('deepseekCompact').Visibility = if ($compact) { 'Visible' } else { 'Collapsed' }
    $script:window.FindName('deepseekStatsPanel').Visibility = if ($script:Cfg.ShowStats) { 'Visible' } else { 'Collapsed' }
    $showRemaining = Test-ShowRemaining
    $budget = Get-DeepSeekBudget
    $s = $script:DeepSeekStats
    $localOk = ($s -and $s.Status -in @('ok', 'partial'))
    $pct = if ($budget) { $budget.UsedPct } else { $null }
    Set-SectionBar 'deepseekBudgetBar' 'deepseekBudgetPct' '' '' $pct $null
    Set-SectionBar 'deepseekBudgetBarC' 'deepseekCompactPct' '' '' $pct $null
    $find = { param($n) $script:window.FindName($n) }
    $statusText = & $find 'deepseekStatusText'
    $note = & $find 'deepseekNote'
    if ($budget) {
        # Real account balance from DeepSeek.
        # The money left leads; how much of the current top-up is used is
        # the smaller line.
        (& $find 'deepseekBudgetLabel').Text = '剩余余额'
        (& $find 'deepseekBudgetPct').Text = ('¥{0:0.00}' -f $budget.Remaining)
        (& $find 'deepseekTotal').Text = ('本次充值已用 {0:0}%（¥{1:0.00}）' -f $budget.UsedPct, $budget.Used)
        (& $find 'deepseekBalance').Text = if ($localOk) { ('今日  {0} tokens · {1} 次请求' -f (Format-DeepSeekTokens $s.TodayTokens), [int]$s.TodayRequests) } else { '今日 --' }
        (& $find 'deepseekRemaining').Text = if ($null -ne $budget.ToppedUp -and $null -ne $budget.Granted) { ('充值 ¥{0:0.00} · 赠送 ¥{1:0.00}' -f [double]$budget.ToppedUp, [double]$budget.Granted) }
            elseif ($localOk) { ('累计 {0} tokens' -f (Format-DeepSeekTokens $s.TotalTokens)) } else { '' }
        (& $find 'deepseekRemaining').Foreground = NewBrush '#8E8E93'
        (& $find 'deepseekStatCost').Text = if ($budget.Used -gt 0.004) { ('¥{0:0.00}' -f $budget.Used) } else { '--' }
        (& $find 'deepseekStatusDot').Fill = NewBrush (Get-UsageBandColor $pct)
        (& $find 'deepseekBudgetPct').Foreground = NewBrush (Get-UsageBandColor $pct)
        $when = ''; try { $at = [datetime]$budget.AsOf; $when = if ($at.Date -eq (Get-Date).Date) { $at.ToString('HH:mm') } else { $at.ToString('M月d日 HH:mm') } } catch { }
        $via = switch ([string]$budget.Source) { 'harness' { '经 Harness' } 'screenshot' { '来自截图' } default { 'API' } }
        if ($budget.Stale) {
            # A remembered reading: amber dot, and when it was read.
            if ($statusText) { $statusText.Text = '上次' }
            (& $find 'deepseekStatusDot').Fill = NewBrush '#FF9F0A'
            if ($note) { $note.Text = ('官方余额 · {0} 读取 · {1}' -f $when, $via) }
        } else {
            if ($statusText) { $statusText.Text = '实时' }
            if ($note) { $note.Text = ('官方余额 · {0} 更新 · {1}' -f $when, $via) }
        }
    } else {
        # No key (or the balance call failed): local, real token statistics
        # only - no money figure.
        # The balance leads even when it is unknown; the local token counts
        # (real) are the smaller lines.
        (& $find 'deepseekBudgetLabel').Text = '剩余余额'
        (& $find 'deepseekBudgetPct').Text = '¥ --'
        (& $find 'deepseekBudgetPct').Foreground = NewBrush '#8E8E93'
        (& $find 'deepseekTotal').Text = if ($localOk) { ('今日  {0} tokens · {1} 次请求' -f (Format-DeepSeekTokens $s.TodayTokens), [int]$s.TodayRequests) } else { '今日 --' }
        (& $find 'deepseekBalance').Text = if ($localOk) { ('累计  {0} tokens' -f (Format-DeepSeekTokens $s.TotalTokens)) } else { '累计 --' }
        $why = if ($s -and $s.BalanceError) { '余额读取失败：' + [string]$s.BalanceError }
            elseif ($s -and $s.HarnessNote -eq 'harness-password') { 'DeepSeek Harness 设了访问口令，读不到余额' }
            elseif ($s -and $s.HarnessNote -eq 'harness-password-wrong') { 'DeepSeek Harness 访问口令不对' }
            elseif ($s -and $s.HarnessNote -eq 'harness-closed') { '打开 DeepSeek Harness 后显示余额' }
            else { 'DeepSeek Harness 没有返回余额' }
        (& $find 'deepseekRemaining').Text = $why
        (& $find 'deepseekRemaining').ToolTip = '余额来源：打开 DeepSeek Harness（由它向 DeepSeek 查询，本程序拿不到密钥），或自己设置环境变量 DEEPSEEK_API_KEY。'
        (& $find 'deepseekRemaining').Foreground = NewBrush '#8E8E93'
        (& $find 'deepseekStatCost').Text = '--'
        # Not connected to a balance source: grey, whatever the local stats say.
        (& $find 'deepseekStatusDot').Fill = NewBrush '#8E8E93'
        if ($statusText) { $statusText.Text = '未连接' }
        if ($note) { $note.Text = 'DeepSeek Harness 本地会话统计' }
    }
    (& $find 'deepseekSection').ToolTip = $null
    foreach ($pair in @(@('Tokens','TotalTokens'),@('Requests','Requests'),@('Sessions','Sessions'))) {
        $value = '--'
        if ($s -and $s.Status -in @('ok','partial')) {
            $value = if ($pair[0] -eq 'Tokens') { Format-DeepSeekTokens $s.TotalTokens } else { [string]$s.($pair[1]) }
            if ($s.Status -eq 'partial') { $value = '~' + $value }
        }
        $script:window.FindName('deepseekStat' + $pair[0]).Text = $value
    }
    if ($budget) {
        $script:window.FindName('deepseekCompactText').Text = ('余额 ¥{0:0.00}' -f $budget.Remaining)
        $script:window.FindName('deepseekCompactPct').Text = ('{0:0}%' -f (Get-ShownPct $pct))
        $script:window.FindName('deepseekCompactPct').Foreground = NewBrush (Get-UsageBandColor $pct)
    } else {
        $script:window.FindName('deepseekCompactText').Text = '余额 ¥--'
        $script:window.FindName('deepseekCompactPct').Text = ''
    }
    Update-DeepSeekHistory $budget
    if (Get-Command Update-IslandValues -ErrorAction SilentlyContinue) { Update-IslandValues }
    $model = $script:window.FindName('deepseekStatModel')
    $model.Text = 'deepseek-flash'
    $model.ToolTip = $null
    Update-DeepSeekNotices $s
}

function Update-DeepSeekNotices($Stats) {
    if (-not $Stats -or -not (Get-Command Test-AiRequestsEnabled -ErrorAction SilentlyContinue) -or -not (Test-AiRequestsEnabled) -or -not $script:ReqDir) { return }
    $cursorPath = Join-Path $script:AppDir 'deepseek-notice-cursor.json'
    $cursor = @{ Done = ''; Attention = '' }
    try {
        if (Test-Path -LiteralPath $cursorPath) {
            $old = Get-Content -LiteralPath $cursorPath -Raw | ConvertFrom-Json
            $cursor.Done = [string]$old.Done; $cursor.Attention = [string]$old.Attention
        }
    } catch { }
    $first = (-not $cursor.Done -and -not $cursor.Attention)
    $events = @(
        @{ Field='LatestCompletedKey'; Cursor='Done'; Kind='done'; Time='LatestCompletedAt'; Session='LatestCompletedSession'; Message='LatestCompletedMessage' },
        @{ Field='LatestAttentionKey'; Cursor='Attention'; Kind='ask'; Time='LatestAttentionAt'; Session='LatestAttentionSession'; Message='LatestAttentionMessage' }
    )
    foreach ($e in $events) {
        $key = [string]$Stats.($e.Field)
        if (-not $key -or $key -eq [string]$cursor[$e.Cursor]) { continue }
        if (-not $first) {
            $md5 = [System.Security.Cryptography.MD5]::Create()
            try { $id = ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes('deepseek|' + $key)))).Replace('-','').ToLowerInvariant() } finally { $md5.Dispose() }
            $note = [ordered]@{
                id=$id; kind=$e.Kind; agent='deepseek'; session=[string]$Stats.($e.Session)
                message=[string]$Stats.($e.Message); chain=@(); cwd=''
                expires=[DateTime]::UtcNow.AddMinutes(10).ToString('o')
            }
            $tmp = Join-Path $script:ReqDir ($id + '.note.json.tmp')
            $dst = Join-Path $script:ReqDir ($id + '.note.json')
            try {
                [IO.File]::WriteAllText($tmp, ($note | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
                Move-Item -LiteralPath $tmp -Destination $dst -Force
            } catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
        $cursor[$e.Cursor] = $key
    }
    try {
        $tmp = $cursorPath + '.tmp'
        [IO.File]::WriteAllText($tmp, ($cursor | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $cursorPath -Force
    } catch { }
}

function Update-DeepSeekHistory($Budget) {
    $row = $script:window.FindName('deepseekHistoryRow')
    $line = $script:window.FindName('deepseekHistoryLine')
    $canvas = $script:window.FindName('deepseekHistoryCanvas')
    $label = $script:window.FindName('deepseekHistoryLabel')
    if (-not $row -or -not $line) { return }
    $path = Join-Path $script:AppDir 'deepseek-history.json'
    if ($null -eq $script:DeepSeekHistory) {
        $script:DeepSeekHistory = @()
        try {
            if (Test-Path -LiteralPath $path) {
                $script:DeepSeekHistory = @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json | Where-Object {
                    $n=0.0; $d=[datetimeoffset]::MinValue
                    [datetimeoffset]::TryParse([string]$_.t,[ref]$d) -and [double]::TryParse([string]$_.used,[ref]$n) -and -not [double]::IsNaN($n) -and -not [double]::IsInfinity($n)
                })
            }
        } catch { $script:DeepSeekHistory = @() }
    }
    # Only new successful data refreshes add samples. UI ticks/settings do not.
    # A remembered (stale) balance is not a new reading, so it adds no sample.
    if ($Budget -and -not $Budget.Stale -and $Budget.LocalOk -and $script:DeepSeekStats.AsOf) {
        $stamp = ([datetimeoffset]$script:DeepSeekStats.AsOf).ToString('o')
        if ($script:DeepSeekHistoryStamp -ne $stamp) {
            if (-not (@($script:DeepSeekHistory | Where-Object t -eq $stamp).Count)) {
                $script:DeepSeekHistory += [pscustomobject]@{ t=$stamp; used=[double]$Budget.UsedPct }
                $script:DeepSeekHistory = @($script:DeepSeekHistory | Sort-Object { [datetimeoffset]$_.t } | Select-Object -Last 480)
                try {
                    $json = ConvertTo-Json -InputObject @($script:DeepSeekHistory) -Depth 3
                    [IO.File]::WriteAllText(($path+'.tmp'),$json,[Text.UTF8Encoding]::new($false))
                    Move-Item -LiteralPath ($path+'.tmp') -Destination $path -Force
                } catch { if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log 'DeepSeek history could not be saved' } }
            }
            $script:DeepSeekHistoryStamp = $stamp
        }
    }
    $line.Points.Clear()
    $row.Visibility = if ($script:Cfg.ShowGraph) { 'Visible' } else { 'Collapsed' }
    if (-not $script:Cfg.ShowGraph) { return }
    $cutoff = [datetimeoffset]::Now.AddHours(-24)
    $samples = @($script:DeepSeekHistory | Where-Object { [datetimeoffset]$_.t -ge $cutoff } | Sort-Object { [datetimeoffset]$_.t })
    if ($samples.Count -lt 2) {
        $label.Text = '历史 · 等待下一次采样（约3分钟）'
        return
    }
    $values = @($samples | ForEach-Object { Get-ShownPct ([double]$_.used) })
    $low = [double]($values | Measure-Object -Minimum).Minimum
    $high = [double]($values | Measure-Object -Maximum).Maximum
    $span = [math]::Max(0.1, $high-$low)
    $min = $low - $span*0.15
    $max = $high + $span*0.15
    $range = [math]::Max(0.1, $max-$min)
    $start = [datetimeoffset]$samples[0].t
    $duration = (([datetimeoffset]$samples[-1].t)-$start).TotalSeconds
    if ($duration -le 0) { $label.Text = '历史 · 等待不同时间的采样'; return }
    for ($i=0; $i -lt $samples.Count; $i++) {
        $x = ((([datetimeoffset]$samples[$i].t)-$start).TotalSeconds/$duration)*$canvas.Width
        $y = $canvas.Height-2-($values[$i]-$min)/$range*($canvas.Height-4)
        [void]$line.Points.Add([System.Windows.Point]::new($x,$y))
    }
    $word = if (Test-ShowRemaining) { '剩余' } else { '已用' }
    $label.Text = ('{0} {1:0.00}–{2:0.00}% · {3}次采样' -f $word,$low,$high,$samples.Count)
    $line.Stroke = NewBrush (Get-UsageBandColor ([double]$samples[-1].used))
    $canvas.ToolTip = '最近24小时的 DeepSeek 官方余额采样，纵轴自动缩放。'
}
