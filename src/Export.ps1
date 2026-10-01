# Export.ps1 - clipboard lines and JSON snapshot objects from in-memory payloads.
# No WPF / clipboard I/O. HUD Copy-Stats and -Json both consume these helpers.

function Get-ExportNote {
    param($Obj, [string]$Name)

    if ($null -eq $Obj -or -not $Name) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] }
        foreach ($k in @($Obj.Keys)) {
            if ([string]$k -eq $Name) { return $Obj[$k] }
        }
        return $null
    }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Test-ExportSectionIncluded {
    param($Sections, [string]$Key)

    if ($null -eq $Sections) { return $true }
    $value = Get-ExportNote $Sections $Key
    if ($null -eq $value) { return $true }
    return [bool]$value
}

function Format-ExportUsedPct([string]$Label, $Pct) {
    if ($null -eq $Pct -or $Pct -eq '') { return ('{0}: --' -f $Label) }
    return ('{0}: {1:0}% used' -f $Label, [double]$Pct)
}

function Get-ClaudeQuotaExportWindowSpecs {
    @(
        [PSCustomObject]@{ Field = 'seven_day_fable';      Label = 'Fable' }
        [PSCustomObject]@{ Field = 'seven_day_opus';       Label = 'Opus' }
        [PSCustomObject]@{ Field = 'seven_day_sonnet';     Label = 'Sonnet' }
        [PSCustomObject]@{ Field = 'seven_day_oauth_apps'; Label = 'OAuth apps' }
        [PSCustomObject]@{ Field = 'seven_day_omelette';   Label = 'Omelette' }
        [PSCustomObject]@{ Field = 'seven_day_cowork';     Label = 'Cowork' }
    )
}

function Format-ClaudeQuotaWindowLine {
    param(
        [string]$Label,
        [object]$Window,
        [switch]$IncludeUtilization
    )

    if (-not $Window) { return $null }

    $used = [math]::Round([double](Get-ExportNote $Window 'utilization'))
    $remaining = [math]::Round(100 - [double](Get-ExportNote $Window 'utilization'))
    $suffixParts = @()
    if ($IncludeUtilization) { $suffixParts += "$used% used" }
    $resetAt = Get-ExportNote $Window 'resets_at'
    $reset = if (Get-Command Format-Reset -ErrorAction SilentlyContinue) { Format-Reset $resetAt } else { '' }
    if ($reset) { $suffixParts += $reset }
    $suffix = if ($suffixParts.Count -gt 0) { ' (' + ($suffixParts -join ', ') + ')' } else { '' }

    return ('{0}: {1}% remaining{2}' -f $Label, $remaining, $suffix)
}

function Get-ClaudeQuotaStatLines {
    param(
        [object]$Data,
        [string]$Prefix = 'Claude '
    )

    if (-not $Data) { return @() }

    $lines = @()
    $fiveHour = Get-ExportNote $Data 'five_hour'
    if ($fiveHour) {
        $lines += Format-ClaudeQuotaWindowLine "$($Prefix)5-hour" $fiveHour
    }
    $sevenDay = Get-ExportNote $Data 'seven_day'
    if ($sevenDay) {
        $lines += Format-ClaudeQuotaWindowLine "$($Prefix)weekly" $sevenDay
    }
    foreach ($spec in Get-ClaudeQuotaExportWindowSpecs) {
        $window = Get-ExportNote $Data $spec.Field
        if ($window) {
            $lines += Format-ClaudeQuotaWindowLine "$Prefix$($spec.Label)" $window -IncludeUtilization
        }
    }
    return @($lines | Where-Object { $_ })
}

function Get-ClaudeExportLines {
    param($Identity, $Usage, $Stats)

    $lines = [System.Collections.Generic.List[string]]::new()
    $display = Get-ExportNote $Identity 'Display'
    if ($display) { $lines.Add("Claude account: $display") }
    foreach ($line in @(Get-ClaudeQuotaStatLines $Usage)) {
        $lines.Add([string]$line)
    }
    if ($Stats) {
        $value = Get-ExportNote $Stats 'ValueUSD'
        $inTok = Get-ExportNote $Stats 'InTokens'
        $outTok = Get-ExportNote $Stats 'OutTokens'
        $todayTok = Get-ExportNote $Stats 'TodayTok'
        $todayMsg = Get-ExportNote $Stats 'TodayMsg'
        $afterTok = Get-ExportNote $Stats 'TodayAfterHoursTok'
        $afterMsg = Get-ExportNote $Stats 'TodayAfterHoursMsg'
        $sessions = Get-ExportNote $Stats 'Sessions'
        $messages = Get-ExportNote $Stats 'Messages'
        $lines.Add(('Claude est. API value: ~{0} all-time' -f (Fmt-Money $value)))
        $lines.Add(('Claude tokens: {0} in / {1} out' -f (Fmt-Tok $inTok), (Fmt-Tok $outTok)))
        $lines.Add(('Claude today: {0} tokens / {1} msgs' -f (Fmt-Tok $todayTok), $todayMsg))
        $lines.Add(('Claude today after-hours: {0} tokens / {1} msgs' -f (Fmt-Tok $afterTok), $afterMsg))
        $lines.Add(('Claude lifetime: {0} sessions / {1} msgs' -f $sessions, (Fmt-Tok $messages)))
    }
    return @($lines)
}

function Get-CodexExportLines {
    param($Stats)

    if (-not $Stats) { return @() }

    $lines = [System.Collections.Generic.List[string]]::new()
    $weekPct = Get-ExportNote $Stats 'WeekPct'
    $fiveHourPct = Get-ExportNote $Stats 'FiveHourPct'
    $resets = Get-ExportNote $Stats 'ResetsAvailable'
    $lines.Add((Format-ExportUsedPct 'Codex weekly' $weekPct))
    if ($null -ne $fiveHourPct -and $fiveHourPct -ne '') {
        $lines.Add((Format-ExportUsedPct 'Codex 5-hour' $fiveHourPct))
    }
    if ($null -ne $resets -and $resets -ne '') {
        $lines.Add(('Codex reset credits: {0} available' -f [int]$resets))
    } else {
        $lines.Add('Codex reset credits: --')
    }
    $value = Get-ExportNote $Stats 'ValueUSD'
    $inTok = Get-ExportNote $Stats 'InTokens'
    $outTok = Get-ExportNote $Stats 'OutTokens'
    $todayTok = Get-ExportNote $Stats 'TodayTok'
    $todayMsg = Get-ExportNote $Stats 'TodayMsg'
    $afterTok = Get-ExportNote $Stats 'TodayAfterHoursTok'
    $afterMsg = Get-ExportNote $Stats 'TodayAfterHoursMsg'
    $sessions = Get-ExportNote $Stats 'Sessions'
    $messages = Get-ExportNote $Stats 'Messages'
    $lines.Add(('Codex est. API value: ~{0} all-time' -f (Fmt-Money $value)))
    $lines.Add(('Codex tokens: {0} in / {1} out' -f (Fmt-Tok $inTok), (Fmt-Tok $outTok)))
    $lines.Add(('Codex today: {0} tokens / {1} msgs' -f (Fmt-Tok $todayTok), $todayMsg))
    $lines.Add(('Codex today after-hours: {0} tokens / {1} msgs' -f (Fmt-Tok $afterTok), $afterMsg))
    $lines.Add(('Codex lifetime: {0} sessions / {1} msgs' -f $sessions, (Fmt-Tok $messages)))
    return @($lines)
}

function Get-CursorExportLines {
    param($Summary, $Local)

    if (-not $Summary -and -not $Local) { return @() }

    $lines = [System.Collections.Generic.List[string]]::new()
    $plan = $null
    if ($Summary -and (Get-Command Get-CursorPlanUsageFromSummary -ErrorAction SilentlyContinue)) {
        $plan = Get-CursorPlanUsageFromSummary $Summary
    }

    if ($plan) {
        $bar = Get-ExportNote $plan 'BarPercent'
        $other = Get-ExportNote $plan 'ApiPercent'
        $odEnabled = Get-ExportNote $plan 'OnDemandEnabled'
        $odCents = Get-ExportNote $plan 'OnDemandUsedCents'
        $lines.Add((Format-ExportUsedPct 'Cursor Models' $bar))
        if ($null -ne $other -and $other -ne '') {
            $lines.Add(('Cursor Other Models: {0:0}%' -f [double]$other))
        } else {
            $lines.Add('Cursor Other Models: --')
        }
        if (($null -ne $odEnabled) -and (-not [bool]$odEnabled)) {
            $lines.Add('Cursor on-demand: Off')
        } elseif ($null -ne $odCents -and $odCents -ne '') {
            $lines.Add(('Cursor on-demand: ${0:N2}' -f ([double]$odCents / 100.0)))
        } else {
            $lines.Add('Cursor on-demand: --')
        }
    } elseif ($Summary) {
        $lines.Add('Cursor Models: --')
        $lines.Add('Cursor Other Models: --')
        $lines.Add('Cursor on-demand: --')
    }

    if ($Local) {
        $edits30 = Get-ExportNote $Local 'edits30d'
        $editsToday = Get-ExportNote $Local 'editsToday'
        $topModel = Get-ExportNote $Local 'topModel'
        $topPct = Get-ExportNote $Local 'topPct'
        $linesAccepted = Get-ExportNote $Local 'linesAccepted'
        $lines.Add(('Cursor edits: {0} (30d) / {1} today' -f $edits30, $editsToday))
        if ($topModel) {
            $lines.Add(('Cursor top model: {0} {1}%' -f $topModel, $topPct))
        }
        if ($null -ne $linesAccepted -and $linesAccepted -ne '') {
            $lines.Add(('Cursor AI lines accepted (30d): {0}' -f $linesAccepted))
        }
    }

    return @($lines)
}

function Get-GrokExportLines {
    param($Usage)

    if (-not $Usage) { return @() }

    $lines = [System.Collections.Generic.List[string]]::new()
    $weekPct = Get-ExportNote $Usage 'WeekPct'
    $resetAt = Get-ExportNote $Usage 'WeekResetsAt'
    $plan = Get-ExportNote $Usage 'PlanType'
    $prepaid = Get-ExportNote $Usage 'PrepaidBalance'
    $lines.Add((Format-ExportUsedPct 'Grok weekly' $weekPct))
    if ($resetAt) {
        $reset = if (Get-Command Format-Reset -ErrorAction SilentlyContinue) { Format-Reset $resetAt } else { [string]$resetAt }
        if ($reset) { $lines.Add("Grok weekly reset: $reset") }
    }
    if ($plan) { $lines.Add("Grok plan: $plan") }
    $resets = Get-ExportNote $Usage 'ResetsAvailable'
    if ((Get-ExportNote $Usage 'ResetStatus') -eq 'ok' -and $null -ne $resets) {
        $lines.Add("Grok one-time resets: $resets available")
    } else { $lines.Add('Grok one-time resets: --') }
    if ($null -ne $prepaid -and [string]$prepaid -ne '') { $lines.Add("Grok prepaid: $prepaid") }
    return @($lines)
}

function Get-UnifiedExportLines {
    param(
        [datetime]$GeneratedAt = (Get-Date),
        [string]$AppVersion = $script:AppVersion,
        $ClaudeIdentity,
        $ClaudeUsage,
        $ClaudeStats,
        $CodexStats,
        $CursorSummary,
        $CursorLocal,
        $GrokUsage,
        $Sections
    )

    $header = 'AI Usage Overlay'
    if ($AppVersion) { $header = "$header $AppVersion" }
    $header = "$header - $($GeneratedAt.ToString('yyyy-MM-dd HH:mm'))"

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($header)

    if (Test-ExportSectionIncluded $Sections 'claude') {
        foreach ($line in @(Get-ClaudeExportLines -Identity $ClaudeIdentity -Usage $ClaudeUsage -Stats $ClaudeStats)) {
            $lines.Add($line)
        }
    }
    if (Test-ExportSectionIncluded $Sections 'codex') {
        foreach ($line in @(Get-CodexExportLines -Stats $CodexStats)) {
            $lines.Add($line)
        }
    }
    if (Test-ExportSectionIncluded $Sections 'cursor') {
        foreach ($line in @(Get-CursorExportLines -Summary $CursorSummary -Local $CursorLocal)) {
            $lines.Add($line)
        }
    }
    if (Test-ExportSectionIncluded $Sections 'grok') {
        foreach ($line in @(Get-GrokExportLines -Usage $GrokUsage)) {
            $lines.Add($line)
        }
    }

    return @($lines)
}

function New-SkippedProviderSnapshot {
    param([string]$Reason = 'Provider was not selected.')

    [ordered]@{
        selected = $false
        status   = 'skipped'
        message  = $Reason
        error    = $null
    }
}

function New-ClaudeProviderSnapshot {
    param(
        $Status,
        $Message,
        $LastFetch,
        $Identity,
        $Usage,
        $Stats,
        $FetchError,
        $StatsError
    )

    [ordered]@{
        selected   = $true
        status     = $Status
        message    = $Message
        lastFetch  = $LastFetch
        identity   = $Identity
        usage      = $Usage
        stats      = $Stats
        error      = $FetchError
        statsError = $StatsError
    }
}

function New-CodexProviderSnapshot {
    param(
        $Status,
        $Message,
        $Stats,
        $FetchError
    )

    [ordered]@{
        selected = $true
        status   = $Status
        message  = $Message
        stats    = $Stats
        error    = $FetchError
    }
}

function New-CursorProviderSnapshot {
    param(
        $Status,
        $Message,
        $LastFetch,
        $Usage,
        $Summary,
        $Local,
        $FetchError
    )

    [ordered]@{
        selected  = $true
        status    = $Status
        message   = $Message
        lastFetch = $LastFetch
        usage     = $Usage
        summary   = $Summary
        local     = $Local
        error     = $FetchError
    }
}

function New-GrokProviderSnapshot {
    param(
        $Status,
        $Message,
        $Usage,
        $FetchError
    )

    [ordered]@{
        selected = $true
        status   = $Status
        message  = $Message
        usage    = $Usage
        error    = $FetchError
    }
}

function New-UnifiedSnapshotDocument {
    param(
        [string]$AppVersion,
        $GeneratedAt = (Get-Date),
        $SelectedProviders,
        $Timeouts,
        $Providers
    )

    $requested = @()
    if ($SelectedProviders) {
        $requested = @($SelectedProviders.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { $_.Key })
    }

    $generated = if ($GeneratedAt -is [datetime]) { $GeneratedAt.ToString('o') } else { [string]$GeneratedAt }

    [ordered]@{
        schema      = 'ai-usage.snapshot.v1'
        generatedAt = $generated
        appVersion  = $AppVersion
        request     = [ordered]@{
            providers  = @($requested)
            timeoutSec = [ordered]@{
                claude = Get-ExportNote $Timeouts 'claude'
                cursor = Get-ExportNote $Timeouts 'cursor'
                grok   = Get-ExportNote $Timeouts 'grok'
            }
        }
        providers   = $Providers
    }
}
