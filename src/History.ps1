# History.ps1 - usage history ring buffer and burn-rate / ETA projection

$script:HistoryPath   = Join-Path $script:AppDir 'overlay-history.json'
$script:History       = [System.Collections.Generic.List[object]]::new()
$script:HistoryMaxLen = 480   # ~24h at 3-min polling intervals

function Get-ClaudeHistoryQuotaFields {
    @(
        'five_hour'
        'seven_day'
        'seven_day_fable'
        'seven_day_opus'
        'seven_day_sonnet'
        'seven_day_oauth_apps'
        'seven_day_omelette'
        'seven_day_cowork'
    )
}

function Get-HistoryProviderMetricKeys {
    @(
        'codex_five_hour'
        'codex_seven_day'
        'grok_seven_day'
        'cursor_requests'
    )
}

function ConvertTo-HistoryMetric($value) {
    if ($null -eq $value) { return $null }
    if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) { return $null }
    try {
        $d = [double]$value
        if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return $null }
        return $d
    } catch {
        return $null
    }
}

function Get-HistoryCursorRequestPct {
    # Plan utilization from usage-summary (Cursor Models). Never invent 0 from missing gpt-4.
    if (Get-Command Get-CursorPlanUsageFromSummary -ErrorAction SilentlyContinue) {
        $plan = Get-CursorPlanUsageFromSummary $script:SummaryData
        if ($null -ne $plan.BarPercent) { return [double]$plan.BarPercent }
        if (($null -ne $plan.Limit) -and ([double]$plan.Limit -gt 0) -and ($null -ne $plan.Used)) {
            return [math]::Min(100.0, ([double]$plan.Used / [double]$plan.Limit) * 100.0)
        }
        return $null
    }
    return $null
}

function Load-History {
    try {
        if (-not (Test-Path $script:HistoryPath)) { return }
        $raw = Get-Content $script:HistoryPath -Raw | ConvertFrom-Json
        if ($null -ne $raw) {
            $script:History = [System.Collections.Generic.List[object]](@($raw))
        }
    } catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "Load-History failed: $($_.Exception.Message)"
        }
    }
}

function Add-HistorySample([object]$data, $FreshProviders = $null) {
    # $data is the API response object from Get-Usage ($script:State.Data)
    $sampleData = [ordered]@{
        t = (Get-Date -Format 'o')  # ISO 8601
    }
    foreach ($field in Get-ClaudeHistoryQuotaFields) {
        $window = if ($data) { $data.PSObject.Properties[$field].Value } else { $null }
        $sampleData[$field] = if ($window) { ConvertTo-HistoryMetric $window.utilization } else { $null }
    }
    $codex = $script:CodexStats
    $sampleData['codex_five_hour'] = if ($codex) { ConvertTo-HistoryMetric $codex.FiveHourPct } else { $null }
    $sampleData['codex_seven_day'] = if ($codex) { ConvertTo-HistoryMetric $codex.WeekPct } else { $null }
    $sampleData['grok_seven_day'] = if ($script:GrokUsage) { ConvertTo-HistoryMetric $script:GrokUsage.WeekPct } else { $null }
    $sampleData['cursor_requests'] = Get-HistoryCursorRequestPct
    if ($null -ne $FreshProviders) {
        if (-not $FreshProviders.claude) {
            foreach ($field in Get-ClaudeHistoryQuotaFields) { $sampleData[$field] = $null }
        }
        if (-not $FreshProviders.codex) { $sampleData['codex_five_hour'] = $null; $sampleData['codex_seven_day'] = $null }
        if (-not $FreshProviders.grok) { $sampleData['grok_seven_day'] = $null }
        if (-not $FreshProviders.cursor) { $sampleData['cursor_requests'] = $null }
    }
    $sample = [PSCustomObject]$sampleData
    $script:History.Add($sample)
    while ($script:History.Count -gt $script:HistoryMaxLen) {
        $script:History.RemoveAt(0)
    }
}

function Complete-UnifiedHistoryPoll {
    $data = $null
    if ($script:State -and $script:State.Data) { $data = $script:State.Data }
    Add-HistorySample $data @{
        claude = ($script:State.Status -eq 'ok')
        codex = ($script:CodexAuthState -eq 'ok')
        grok = ($script:GrokAuthState -eq 'ok')
        cursor = ($script:AuthState -eq 'ok')
    }
    Save-History
}

function Save-History {
    try {
        $script:History | ConvertTo-Json -Depth 3 | Set-Content -Path $script:HistoryPath -Encoding UTF8
    } catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "Save-History failed: $($_.Exception.Message)"
        }
    }
}

function Get-Eta {
    param(
        [object[]]$Samples,
        [string]$MetricKey
    )
    # Need at least 3 samples to fit a line
    if ($null -eq $Samples -or $Samples.Count -lt 3) { return $null }

    # Filter to samples with a non-null value for this metric, within last 60 minutes
    $cutoff = (Get-Date).AddMinutes(-60)
    $recent = @($Samples | Where-Object {
        $null -ne $_.$MetricKey -and
        [System.DateTimeOffset]::Parse($_.t).LocalDateTime -ge $cutoff
    })
    if ($recent.Count -lt 3) { return $null }

    # Convert timestamps to minutes-since-first for linear regression
    $t0 = [System.DateTimeOffset]::Parse($recent[0].t)
    $xs = @($recent | ForEach-Object { ([System.DateTimeOffset]::Parse($_.t) - $t0).TotalMinutes })
    $ys = @($recent | ForEach-Object { [double]($_.$MetricKey) })

    # Simple linear regression: y = a + b*x
    $n    = $xs.Count
    $sumX = ($xs | Measure-Object -Sum).Sum
    $sumY = ($ys | Measure-Object -Sum).Sum
    $sumXY = 0; for ($i = 0; $i -lt $n; $i++) { $sumXY += $xs[$i] * $ys[$i] }
    $sumX2 = 0; for ($i = 0; $i -lt $n; $i++) { $sumX2 += $xs[$i] * $xs[$i] }
    $denom = $n * $sumX2 - $sumX * $sumX
    if ([math]::Abs($denom) -lt 1e-10) { return $null }  # perfectly flat / single point

    $b = ($n * $sumXY - $sumX * $sumY) / $denom  # slope (util % per minute)
    if ($b -le 0) { return $null }  # not increasing - no ETA

    # Current util = last sample's value
    $currentUtil = $ys[-1]
    if ($currentUtil -ge 100) { return 0 }  # already at limit

    # Minutes to reach 100%
    $etaMinutes = (100.0 - $currentUtil) / $b
    if ($etaMinutes -gt 1440) { return $null }  # more than 24h away - not useful
    return [int][math]::Ceiling($etaMinutes)
}
