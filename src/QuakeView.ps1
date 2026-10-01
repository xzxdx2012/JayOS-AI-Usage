# QuakeView.ps1 - renders the quake strip as monospace terminal output.
#
# This is a separate renderer from Update-*Section, not a reflow of the panel.
# The panel binds to ~60 named XAML elements laid out vertically at a fixed
# 250px; a full-width horizontal strip has different content entirely. Both read
# the same script-scope data, so there is no second data path:
#   Claude usage  $script:State.Data      Claude local  $script:Stats
#   Codex         $script:CodexStats      Cursor        $script:LiveData /
#                                                       $script:SummaryData
#
# Colour comes from per-Run Foreground, so each line mixes dim labels, bright
# values and threshold-coloured gauges the way top/htop does.

$script:QuakeCol = @{
    Dim    = '#5A7590'
    Label  = '#7B9EC4'
    Value  = '#D8E3F0'
    Bright = '#FFFFFF'
    Head   = '#38BDF8'
    Track  = '#26374A'
    Good   = '#4ADE80'
    Warn   = '#FBBF24'
    Crit   = '#F87171'
    Accent = '#C084FC'
}

function Get-QuakeBrush([string]$Hex) {
    if (-not $script:QuakeBrushCache) { $script:QuakeBrushCache = @{} }
    if (-not $script:QuakeBrushCache.ContainsKey($Hex)) {
        $script:QuakeBrushCache[$Hex] = New-Object System.Windows.Media.SolidColorBrush(
            [System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
    }
    return $script:QuakeBrushCache[$Hex]
}

function Add-QuakeRun($TextBlock, [string]$Text, [string]$Hex, [bool]$Bold = $false) {
    $run = New-Object System.Windows.Documents.Run($Text)
    $run.Foreground = Get-QuakeBrush $Hex
    if ($Bold) { $run.FontWeight = [System.Windows.FontWeights]::Bold }
    [void]$TextBlock.Inlines.Add($run)
}

function Add-QuakeBreak($TextBlock) {
    [void]$TextBlock.Inlines.Add((New-Object System.Windows.Documents.LineBreak))
}

function Get-QuakeThresholdHex([double]$Pct) {
    if ($Pct -ge 85) { return $script:QuakeCol.Crit }
    if ($Pct -ge 60) { return $script:QuakeCol.Warn }
    return $script:QuakeCol.Good
}

# htop-style gauge: filled blocks up to the value, light shade for the remainder.
# Over 100% the whole bar is filled and the caller marks it OVER.
function Get-QuakeGauge([double]$Pct, [int]$Width = 18) {
    $clamped = [math]::Max(0, [math]::Min(100, $Pct))
    $filled  = [int][math]::Round($Width * $clamped / 100.0)
    if ($filled -gt $Width) { $filled = $Width }
    return @{
        Filled = ([string][char]0x2588) * $filled
        Empty  = ([string][char]0x2591) * ($Width - $filled)
    }
}

# One gauge line: "  5-HOUR  [########------]  52%  1h33m"
# LabelWidth is 9 so the longest labels ('INCLUDED', 'lifetime', 'est cost')
# still get a separating space; PadRight(8) ran them straight into the value.
function Get-QuakeGaugeWidth {
    $w = 1920.0
    if ($script:window -and $script:window.Width -gt 0) { $w = [double]$script:window.Width }
    if ($w -lt 1500) { return 14 }
    return 18
}

function Add-QuakeGaugeLine($TextBlock, [string]$Label, $Pct, $ResetsAt, [int]$LabelWidth = 9, [int]$GaugeWidth = 18) {
    Add-QuakeRun $TextBlock ('  ' + $Label.PadRight($LabelWidth)) $script:QuakeCol.Label
    if ($null -eq $Pct) {
        Add-QuakeRun $TextBlock ('[' + ([string][char]0x2591) * $GaugeWidth + ']') $script:QuakeCol.Track
        Add-QuakeRun $TextBlock '    --' $script:QuakeCol.Dim
        Add-QuakeBreak $TextBlock
        return
    }
    $p = [double]$Pct
    $g = Get-QuakeGauge $p $GaugeWidth
    $hex = Get-QuakeThresholdHex $p
    Add-QuakeRun $TextBlock '[' $script:QuakeCol.Track
    Add-QuakeRun $TextBlock $g.Filled $hex
    Add-QuakeRun $TextBlock $g.Empty $script:QuakeCol.Track
    Add-QuakeRun $TextBlock ']' $script:QuakeCol.Track
    Add-QuakeRun $TextBlock (' {0,4}%' -f [int][math]::Round($p)) $hex $true
    if ($p -gt 100) { Add-QuakeRun $TextBlock ' OVER' $script:QuakeCol.Crit $true }
    if ($ResetsAt) {
        $r = ''
        try { $r = Format-Reset $ResetsAt } catch { }
        if ($r) { Add-QuakeRun $TextBlock ('  ' + $r) $script:QuakeCol.Dim }
    }
    Add-QuakeBreak $TextBlock
}

# "  label  value" stat line
function Add-QuakeStatLine($TextBlock, [string]$Label, [string]$Value, [int]$LabelWidth = 9, [string]$ValueHex = $null) {
    if (-not $ValueHex) { $ValueHex = $script:QuakeCol.Value }
    Add-QuakeRun $TextBlock ('  ' + $Label.PadRight($LabelWidth)) $script:QuakeCol.Label
    Add-QuakeRun $TextBlock $Value $ValueHex
    Add-QuakeBreak $TextBlock
}

function Add-QuakeSectionTitle($TextBlock, [string]$Title, [string]$Suffix = '') {
    Add-QuakeRun $TextBlock $Title $script:QuakeCol.Head $true
    if ($Suffix) { Add-QuakeRun $TextBlock ('  ' + $Suffix) $script:QuakeCol.Dim }
    Add-QuakeBreak $TextBlock
}

function Format-QuakeNum([double]$n) {
    if ($n -ge 1e9) { return ('{0:0.0}B' -f ($n / 1e9)) }
    if ($n -ge 1e6) { return ('{0:0.0}M' -f ($n / 1e6)) }
    if ($n -ge 1e3) { return ('{0:0.0}k' -f ($n / 1e3)) }
    return ('{0:0}' -f $n)
}

function ConvertTo-QuakeExtraUsage($extra) {
    if (-not $extra -or -not $extra.is_enabled -or -not $extra.monthly_limit) { return $null }

    return [pscustomobject]@{
        Used   = [double]$extra.used_credits / 100.0
        Limit  = [double]$extra.monthly_limit / 100.0
        Symbol = if ($extra.currency -eq 'USD') { '$' } else { "$($extra.currency) " }
    }
}

# ---------------------------------------------------------------------------
# Columns
# ---------------------------------------------------------------------------
function Render-QuakeClaude($tb) {
    $tb.Inlines.Clear()
    $ident = if ($script:ClaudeIdentity -and $script:ClaudeIdentity.Email) { [string]$script:ClaudeIdentity.Email } else { '' }
    Add-QuakeSectionTitle $tb 'CLAUDE' $ident

    $d = if ($script:State) { $script:State.Data } else { $null }
    if (-not $d) {
        $msg = if ($script:State -and $script:State.Message) { $script:State.Message } else { 'no data' }
        Add-QuakeRun $tb ('  ' + $msg) $script:QuakeCol.Dim
        Add-QuakeBreak $tb
    } else {
        Add-QuakeGaugeLine $tb '5-HOUR' $d.five_hour.utilization $d.five_hour.resets_at
        Add-QuakeGaugeLine $tb 'WEEKLY' $d.seven_day.utilization $d.seven_day.resets_at
        # Extra weekly windows only exist on some plans; show the ones we got.
        foreach ($spec in (Get-ClaudeQuotaExportWindowSpecs)) {
            $w = $d.($spec.Field)
            if ($w -and $null -ne $w.utilization) {
                Add-QuakeGaugeLine $tb $spec.Label.ToUpperInvariant() $w.utilization $w.resets_at
            }
        }
    }

    $s = $script:Stats
    if ($s) {
        Add-QuakeStatLine $tb 'tokens' ('{0} in / {1} out' -f (Format-QuakeNum ([double]$s.InTokens)), (Format-QuakeNum ([double]$s.OutTokens)))
        Add-QuakeStatLine $tb 'today' ('{0} tok  {1} msgs' -f (Format-QuakeNum ([double]$s.TodayTok)), [int]$s.TodayMsg)
        Add-QuakeStatLine $tb 'lifetime' ('{0} sessions  {1} msgs' -f [int]$s.Sessions, (Format-QuakeNum ([double]$s.Messages)))
        Add-QuakeStatLine $tb 'est cost' ('~${0:N0} all-time' -f [double]$s.ValueUSD)
    }
    $extra = if ($d) { ConvertTo-QuakeExtraUsage $d.extra_usage } else { $null }
    if ($extra) {
        $hex = if ($extra.Limit -gt 0 -and ($extra.Used / $extra.Limit) -ge 0.85) { $script:QuakeCol.Crit } else { $script:QuakeCol.Value }
        Add-QuakeStatLine $tb 'overage' ('{0}{1:N2} / {0}{2:N0}' -f $extra.Symbol, $extra.Used, $extra.Limit) 9 $hex
    }
}

function Render-QuakeCodex($tb) {
    $tb.Inlines.Clear()
    $s = $script:CodexStats
    Add-QuakeSectionTitle $tb 'CODEX' $(if ($s) { '' } else { 'no sessions found' })
    if (-not $s) {
        Add-QuakeRun $tb '  nothing under ~\.codex\sessions' $script:QuakeCol.Dim
        Add-QuakeBreak $tb
        return
    }
    Add-QuakeGaugeLine $tb '5-HOUR' $s.FiveHourPct $s.FiveHourResetsAt
    Add-QuakeGaugeLine $tb 'WEEKLY' $s.WeekPct $s.WeekResetsAt
    Add-QuakeStatLine $tb 'tokens' ('{0} in / {1} out' -f (Format-QuakeNum ([double]$s.InTokens)), (Format-QuakeNum ([double]$s.OutTokens)))
    Add-QuakeStatLine $tb 'today' ('{0} tok  {1} msgs' -f (Format-QuakeNum ([double]$s.TodayTok)), [int]$s.TodayMsg)
    Add-QuakeStatLine $tb 'lifetime' ('{0} sessions  {1} msgs' -f [int]$s.Sessions, (Format-QuakeNum ([double]$s.Messages)))
    Add-QuakeStatLine $tb 'est cost' ('~${0:N0} all-time' -f [double]$s.ValueUSD)
}

function Render-QuakeGrok($tb) {
    $tb.Inlines.Clear()
    $s = $script:GrokUsage
    $suffix = if ($s -and $s.PlanType) { [string]$s.PlanType } else { '' }
    Add-QuakeSectionTitle $tb 'GROK' $suffix
    $gw = Get-QuakeGaugeWidth

    if ($script:GrokAuthState -eq 'auth' -or $script:GrokAuthState -eq 'notoken') {
        Add-QuakeRun $tb ('  ' + [string]$script:GrokErrMsg) $script:QuakeCol.Crit
        Add-QuakeBreak $tb
        return
    }

    if (-not $s) {
        $msg = if ($script:GrokErrMsg) { [string]$script:GrokErrMsg } else { 'no data' }
        Add-QuakeRun $tb ('  ' + $msg) $script:QuakeCol.Dim
        Add-QuakeBreak $tb
        return
    }

    Add-QuakeGaugeLine $tb 'WEEKLY' $s.WeekPct $s.WeekResetsAt 9 $gw
    if ($s.PrepaidBalance) { Add-QuakeStatLine $tb 'prepaid' [string]$s.PrepaidBalance }
}

function Render-QuakeCursor($tb) {
    $tb.Inlines.Clear()
    $sum = $script:SummaryData
    $suffix = if ($sum -and $sum.membershipType) { '{0} / {1}' -f $sum.membershipType, $sum.limitType } else { '' }
    Add-QuakeSectionTitle $tb 'CURSOR' $suffix

    if ($script:AuthState -eq 'auth' -or $script:AuthState -eq 'notoken') {
        Add-QuakeRun $tb ('  ' + [string]$script:CursorErrMsg) $script:QuakeCol.Crit
        Add-QuakeBreak $tb
        return
    }

    $plan = $null
    if (Get-Command Get-CursorPlanUsageFromSummary -ErrorAction SilentlyContinue) {
        $plan = Get-CursorPlanUsageFromSummary $sum
    }
    if ($plan -and ($null -ne $plan.BarPercent)) {
        Add-QuakeGaugeLine $tb 'CURSOR' $plan.BarPercent $null
        Add-QuakeStatLine $tb 'models' (Format-CursorPlanCountText $plan)
    } else {
        Add-QuakeGaugeLine $tb 'CURSOR' $null $null
    }
    if ($plan -and ($null -ne $plan.ApiPercent)) {
        Add-QuakeStatLine $tb 'other' ('{0:0}%' -f [double]$plan.ApiPercent)
    }

    if ($sum) {
        if ($plan -and ($null -ne $plan.OnDemandEnabled) -and (-not $plan.OnDemandEnabled)) {
            Add-QuakeStatLine $tb 'on-dmd' 'off' 9 $script:QuakeCol.Dim
        } elseif ($sum.individualUsage -and $sum.individualUsage.onDemand) {
            Add-QuakeStatLine $tb 'on-dmd' ('${0:N2}' -f ([double]$sum.individualUsage.onDemand.used / 100.0)) 9 $script:QuakeCol.Bright
        }
        if ($sum.teamUsage -and $sum.teamUsage.onDemand) {
            $tu = [double]$sum.teamUsage.onDemand.used / 100.0
            $tl = [double]$sum.teamUsage.onDemand.limit / 100.0
            Add-QuakeStatLine $tb 'team' ('${0:N0} / ${1:N0}' -f $tu, $tl)
        }
        if ($sum.billingCycleEnd) {
            $r = ''
            try { $r = Format-Reset $sum.billingCycleEnd } catch { }
            Add-QuakeStatLine $tb 'cycle' ('renews {0}' -f $r)
        }
    }
    $l = $script:LocalData
    if ($l) {
        Add-QuakeStatLine $tb 'edits' ('{0} in 30d  {1} today' -f [int]$l.edits30d, [int]$l.editsToday)
        if ($l.topModel) { Add-QuakeStatLine $tb 'top' ('{0} {1}%' -f $l.topModel, [int]$l.topPct) }
    } else {
        Add-QuakeStatLine $tb 'edits' 'analytics unavailable (403)' 9 $script:QuakeCol.Dim
    }
}

function Render-QuakeHeader($tb) {
    $tb.Inlines.Clear()
    $status = if ($script:State) { [string]$script:State.Status } else { 'init' }
    $hex = switch ($status) {
        'ok'    { $script:QuakeCol.Good }
        'stale' { $script:QuakeCol.Warn }
        default { $script:QuakeCol.Crit }
    }
    Add-QuakeRun $tb 'AI USAGE' $script:QuakeCol.Head $true
    Add-QuakeRun $tb '  ' $script:QuakeCol.Dim
    Add-QuakeRun $tb ([string][char]0x25CF) $hex
    Add-QuakeRun $tb (' ' + $status) $script:QuakeCol.Dim
    $fetched = if ($script:State -and $script:State.LastFetch) { [string]$script:State.LastFetch } else { '' }
    if ($fetched) { Add-QuakeRun $tb ('   updated ' + $fetched) $script:QuakeCol.Dim }
}

function Render-QuakeFooter($tb) {
    $tb.Inlines.Clear()
    $key = [string]$script:Cfg['DropdownHotkey']
    Add-QuakeRun $tb ("$key toggle" + '   esc close   right-click menu') $script:QuakeCol.Dim
}

# ---------------------------------------------------------------------------
# Entry point - called from Update-AllSections while the quake view is active.
# ---------------------------------------------------------------------------
function Update-QuakeView {
    if (-not $script:window) { return }
    $root = $script:window.FindName('quakeRoot')
    if (-not $root -or $root.Visibility -ne [System.Windows.Visibility]::Visible) { return }
    try {
        Render-QuakeHeader ($script:window.FindName('qHeader'))
        Render-QuakeClaude ($script:window.FindName('qClaude'))
        Render-QuakeCodex  ($script:window.FindName('qCodex'))
        Render-QuakeCursor ($script:window.FindName('qCursor'))
        Render-QuakeGrok   ($script:window.FindName('qGrok'))
        Render-QuakeFooter ($script:window.FindName('qFooter'))
    } catch {
        Write-Log ("Update-QuakeView failed: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
    }
}

# Swap which root is live. The panel keeps updating while hidden (its bar writes
# short-circuit on invisible elements), so switching back is instant.
function Set-QuakeLayout([bool]$Enabled) {
    if (-not $script:window) { return }
    $q = $script:window.FindName('quakeRoot')
    $p = $script:window.FindName('pinnedRoot')
    if ($q) { $q.Visibility = if ($Enabled) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
    if ($p) { $p.Visibility = if ($Enabled) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible } }
    if ($Enabled) { Update-QuakeView }
}

# Quake sizing is the opposite of the panel's: width is dictated by the monitor,
# height by whatever the three columns need.
function Resize-QuakeToContent {
    $screen = Resolve-DropdownScreen
    $scale  = Get-DropdownScaleFactor
    $wa     = $screen.WorkingArea
    $w      = [double]$wa.Width * $scale.X

    $script:window.Width = $w
    $root = $script:window.FindName('quakeRoot')
    if (-not $root) { return }
    $root.Measure((New-Object System.Windows.Size($w, [double]::PositiveInfinity)))
    $h = [double]$root.DesiredSize.Height
    if ($h -gt 0) { $script:window.Height = $h }
}
