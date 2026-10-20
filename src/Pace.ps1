<#
    Pace.ps1 — burn-rate governor for the Claude 5-hour window.

    Dot-source alongside Data.ps1. It answers one question: given where the
    5-hour utilization is now and how long until it resets, am I on track to
    finish the window close to the ceiling without blowing past it?

        . "$PSScriptRoot\Pace.ps1"
        $p = Get-PaceVerdict
        "$($p.Verdict) — $($p.Advice)"
        Format-PaceLine $p          # one-line tray/overlay string

    Under-using the window wastes paid capacity; over-running it stalls work.
    The ceiling is 95 by design, NOT 100 — leave headroom to finish and
    checkpoint cleanly rather than dying mid-edit.
#>

$script:PaceCeiling   = 95   # target utilization at reset
$script:PaceBand      = 6    # +/- tolerance on the projection, in points
$script:PaceWindowMin = 45   # trailing window used to measure the actual rate
$script:PaceMinSpan   = 6    # minimum history (minutes) before trusting a rate
$script:PaceUsageLog  = 'C:\Users\agodavarthy\Claude\overnight\usage.jsonl'

function Get-PaceSamples {
    <# Reads the overnight sampler's JSONL telemetry. Tolerates partial lines. #>
    param([string]$Path = $script:PaceUsageLog)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $o = $line | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $o.fiveHour -and $o.ts) { [void]$rows.Add($o) }
        } catch { }
    }
    return $rows
}

function Measure-PaceRate {
    <# Actual %/min over the trailing window. Resets the segment when the
       5-hour window rolls over (utilization drops sharply). #>
    param([object[]]$Samples, [datetime]$Now = (Get-Date))
    $cut = $Now.ToUniversalTime().AddMinutes(-$script:PaceWindowMin)
    $win = @($Samples | Where-Object { ([datetime]$_.ts).ToUniversalTime() -ge $cut })
    if ($win.Count -lt 2) { return $null }

    $start = 0
    for ($i = 1; $i -lt $win.Count; $i++) {
        if ($win[$i].fiveHour -lt ($win[$i - 1].fiveHour - 2)) { $start = $i }
    }
    $seg = $win[$start..($win.Count - 1)]
    if ($seg.Count -lt 2) { return $null }

    $a = $seg[0]; $b = $seg[-1]
    $span = (([datetime]$b.ts) - ([datetime]$a.ts)).TotalMinutes
    if ($span -lt $script:PaceMinSpan) { return $null }

    [pscustomobject]@{
        RatePctPerMin = [math]::Round((($b.fiveHour - $a.fiveHour) / $span), 4)
        SpanMinutes   = [math]::Round($span, 0)
        SampleCount   = $seg.Count
    }
}

function Get-PaceVerdict {
    <# Current = live utilization if supplied, else the newest sample.
       ResetsAt = the 5-hour reset timestamp. Both optional; falls back to
       the sampler log so this works even when the usage API is rate-limited. #>
    param(
        [Nullable[double]]$Current,
        [Nullable[datetime]]$ResetsAt
    )

    $samples = Get-PaceSamples
    $last = if ($samples.Count) { $samples[-1] } else { $null }

    if ($null -eq $Current -and $last) { $Current = [double]$last.fiveHour }
    if ($null -eq $ResetsAt -and $last -and $last.resetsAt) { $ResetsAt = [datetime]$last.resetsAt }

    if ($null -eq $Current -or $null -eq $ResetsAt) {
        return [pscustomobject]@{
            Ok = $false; Verdict = 'UNKNOWN'
            Advice = 'No usage data (API rate-limited and no sampler history).'
        }
    }

    $remaining = [math]::Max(0, ($ResetsAt.ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalMinutes)
    $headroom  = $script:PaceCeiling - $Current
    $required  = if ($remaining -gt 0) { $headroom / $remaining } else { 0 }
    $measured  = Measure-PaceRate -Samples $samples
    $actual    = if ($measured) { $measured.RatePctPerMin } else { $null }
    $projected = if ($null -ne $actual) { $Current + ($actual * $remaining) } else { $null }

    $verdict = 'ON_TRACK'; $advice = ''
    if ($headroom -le 0) {
        $verdict = 'THROTTLE'
        $advice  = "At or past the $($script:PaceCeiling)% ceiling. Stop starting work; finish and checkpoint."
    } elseif ($null -eq $projected) {
        $advice = "Insufficient history. Budget allows $([math]::Round($required,3)) %/min."
    } elseif ($projected -gt $script:PaceCeiling) {
        $verdict = 'THROTTLE'
        $advice  = "Burning $([math]::Round($actual,3)) %/min vs $([math]::Round($required,3)) allowed; projected $([math]::Round($projected))% at reset. Do not start new agents."
    } elseif ($projected -lt ($script:PaceCeiling - $script:PaceBand)) {
        $verdict = 'ACCELERATE'
        $advice  = "Only projected to reach $([math]::Round($projected))% of a $($script:PaceCeiling)% budget. Spare capacity: start more work."
    } else {
        $advice = "Projected $([math]::Round($projected))% at reset, inside the band. Hold concurrency."
    }

    [pscustomobject]@{
        Ok                 = $true
        Verdict            = $verdict
        Advice             = $advice
        Current            = [math]::Round($Current, 1)
        Ceiling            = $script:PaceCeiling
        RemainingMinutes   = [math]::Round($remaining, 0)
        HeadroomPoints     = [math]::Round($headroom, 1)
        RequiredPctPerMin  = [math]::Round($required, 4)
        MinutesPerPoint    = if ($required -gt 0) { [math]::Round((1 / $required), 1) } else { $null }
        ActualPctPerMin    = $actual
        ProjectedAtReset   = if ($null -ne $projected) { [math]::Round($projected, 1) } else { $null }
        MeasuredOverMin    = if ($measured) { $measured.SpanMinutes } else { 0 }
        SampleCount        = if ($measured) { $measured.SampleCount } else { 0 }
    }
}

function Format-PaceLine {
    <# Compact single line for the tray tooltip or overlay footer. #>
    param([Parameter(Mandatory)][object]$Pace)
    if (-not $Pace.Ok) { return 'pace n/a' }
    $glyph = switch ($Pace.Verdict) {
        'THROTTLE'   { [char]0x25BC }  # down triangle: slow down
        'ACCELERATE' { [char]0x25B2 }  # up triangle: room to run
        default      { [char]0x25CF }  # dot: on track
    }
    $proj = if ($null -ne $Pace.ProjectedAtReset) { "$($Pace.ProjectedAtReset)%" } else { '--' }
    "$glyph $($Pace.Current)% -> $proj / $($Pace.Ceiling)%  ($($Pace.RemainingMinutes)m left, $($Pace.MinutesPerPoint)m per pt)"
}

# Standalone: pwsh -File src\Pace.ps1
if ($MyInvocation.InvocationName -ne '.') {
    $p = Get-PaceVerdict
    if ($p.Ok) {
        Write-Host ""
        Write-Host ("  5-hour {0}%  ceiling {1}%  resets in {2}m" -f $p.Current, $p.Ceiling, $p.RemainingMinutes)
        Write-Host ("  allowed {0} %/min (1 pt every {1}m)" -f $p.RequiredPctPerMin, $p.MinutesPerPoint)
        Write-Host ("  actual  {0} %/min over {1}m ({2} samples)" -f $p.ActualPctPerMin, $p.MeasuredOverMin, $p.SampleCount)
        Write-Host ("  projected at reset: {0}%" -f $p.ProjectedAtReset)
        Write-Host ""
        Write-Host ("  {0}: {1}" -f $p.Verdict, $p.Advice)
        Write-Host ""
        Write-Host ("  tray: {0}" -f (Format-PaceLine $p))
    } else {
        Write-Host "  $($p.Advice)"
    }
    if ($p.Verdict -eq 'THROTTLE') { exit 3 } else { exit 0 }
}
