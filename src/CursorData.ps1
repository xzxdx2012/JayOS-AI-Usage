$script:StateVscdb = Join-Path $env:APPDATA 'Cursor\User\globalStorage\state.vscdb'
$script:TrackingDb = Join-Path $env:USERPROFILE '.cursor\ai-tracking\ai-code-tracking.db'

$script:LiveData        = $null
$script:LocalData       = $null
$script:SummaryData     = $null
$script:AuthState       = 'init'
$script:CursorLastFetch = ''
$script:CursorErrMsg    = ''

function Fmt-Num($n) {
    if ($null -eq $n) { return '--' }
    if ($n -ge 1e6) { return ('{0:0.0}M' -f ($n / 1e6)) }
    if ($n -ge 1e3) { return ('{0:0}k'   -f ($n / 1e3)) }
    return ('{0:0}' -f $n)
}


function ConvertTo-CursorSummaryMetric($value) {
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

function Get-CursorDisplayMessagePercent([string]$Message) {
    if ([string]::IsNullOrWhiteSpace($Message)) { return $null }
    # Only recognize an explicit usage sentence, never an unrelated/remaining %.
    $m = [regex]::Match($Message, '(?i)\bused\s+(\d+(?:\.\d+)?)\s*%')
    if (-not $m.Success) { return $null }
    return ConvertTo-CursorSummaryMetric $m.Groups[1].Value
}

function Get-CursorPlanUsageFromSummary($Summary = $script:SummaryData) {
    # Plan & Usage pools from usage-summary (Settings: Cursor Models / Other Models).
    # Never invent 0 from missing fields. Settings display-message % wins when present
    # (matches what Cursor Settings shows); fall back to plan.autoPercentUsed / apiPercentUsed.
    $used = $null; $limit = $null; $autoPct = $null; $apiPct = $null
    $odEnabled = $null; $odUsedCents = $null

    if ($Summary) {
        $plan = $null
        if ($Summary.individualUsage) { $plan = $Summary.individualUsage.plan }
        if ($plan) {
            $used = ConvertTo-CursorSummaryMetric $plan.used
            $limit = ConvertTo-CursorSummaryMetric $plan.limit
        }
        $msgAuto = Get-CursorDisplayMessagePercent ([string]$Summary.autoModelSelectedDisplayMessage)
        $msgApi  = Get-CursorDisplayMessagePercent ([string]$Summary.namedModelSelectedDisplayMessage)
        if ($null -ne $msgAuto) {
            $autoPct = $msgAuto
        } elseif ($plan) {
            $autoPct = ConvertTo-CursorSummaryMetric $plan.autoPercentUsed
        }
        if ($null -ne $msgApi) {
            $apiPct = $msgApi
        } elseif ($plan) {
            $apiPct = ConvertTo-CursorSummaryMetric $plan.apiPercentUsed
        }
        if ($Summary.individualUsage -and $Summary.individualUsage.onDemand) {
            $od = $Summary.individualUsage.onDemand
            if ($null -ne $od.enabled) { $odEnabled = [bool]$od.enabled }
            $odUsedCents = ConvertTo-CursorSummaryMetric $od.used
        }
    }

    $barPct = $null
    if ($null -ne $autoPct) {
        $barPct = [math]::Min(100.0, [double]$autoPct)
    } elseif (($null -ne $limit) -and ([double]$limit -gt 0) -and ($null -ne $used)) {
        $barPct = [math]::Min(100.0, ([double]$used / [double]$limit) * 100.0)
    }

    [pscustomobject]@{
        Used            = $used
        Limit           = $limit
        AutoPercent     = $autoPct
        ApiPercent      = $apiPct
        BarPercent      = $barPct
        OnDemandEnabled = $odEnabled
        OnDemandUsedCents = $odUsedCents
        MembershipType  = if ($Summary) { $Summary.membershipType } else { $null }
        BillingCycleEnd = if ($Summary) { $Summary.billingCycleEnd } else { $null }
    }
}


function Format-CursorPlanCountText {
    # Settings-faithful plan label for the Models bar.
    # Lead with Settings-faithful BarPercent. Show used/limit only when that
    # ratio agrees with the bar % (within 2 pts); otherwise % wins so a
    # mismatched 2000/2000 never fights a ~10% Settings bar.
    param($Plan)

    if ($null -eq $Plan) { return '--' }

    $hasBar = ($null -ne $Plan.BarPercent)
    $pct = $null
    if ($hasBar) {
        $pct = [int][math]::Min(100, [math]::Round([double]$Plan.BarPercent))
    }

    $hasUL = ($null -ne $Plan.Used) -and ($null -ne $Plan.Limit) -and ([double]$Plan.Limit -gt 0)
    if ($hasUL -and $hasBar) {
        $fromUL = [int][math]::Min(100, [math]::Round(([double]$Plan.Used / [double]$Plan.Limit) * 100.0))
        if ([math]::Abs($fromUL - $pct) -le 2) {
            return ('{0} / {1}' -f [int][math]::Round([double]$Plan.Used), [int][math]::Round([double]$Plan.Limit))
        }
        return ('{0}%' -f $pct)
    }
    if ($hasBar) { return ('{0}%' -f $pct) }
    if ($hasUL) {
        return ('{0} / {1}' -f [int][math]::Round([double]$Plan.Used), [int][math]::Round([double]$Plan.Limit))
    }
    return '--'
}



# ---------------------------------------------------------------------------
# SQLite helper - reads Cursor's SQLite databases via bundled sqlite3.exe
# ---------------------------------------------------------------------------
# The bundled sqlite3.exe ships in the app ROOT ({app}\sqlite3.exe) while these
# modules install to {app}\src, so resolution must walk one level up. Relying on
# PATH instead is what used to break the Cursor section outright - see the
# PATH-hygiene note in unified-overlay.ps1.
function Resolve-Sqlite3Path {
    param([string]$BaseDir)

    if ($BaseDir) {
        $candidates = @((Join-Path $BaseDir 'sqlite3.exe'))
        $parent = Split-Path $BaseDir -Parent
        if ($parent) { $candidates += (Join-Path $parent 'sqlite3.exe') }
        foreach ($candidate in $candidates) {
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }

    $cmd = Get-Command sqlite3.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-Sqlite {
    param([string]$DbPath, [string]$Query)
    $exe = Resolve-Sqlite3Path $PSScriptRoot
    if (-not $exe) { return $null }
    try {
        # sqlite3 -json may return output as a string array (one line per line);
        # join into a single string so ConvertFrom-Json can parse the full JSON.
        $lines = & $exe -readonly -json $DbPath $Query 2>$null
        if ($lines) { $lines -join '' } else { $null }
    } catch { $null }
}

# Windows PowerShell 5.1 silently drops a 'Cookie' entry passed through -Headers
# (its own CookieContainer wins), so every cursor.com call 401s. Carry the session
# cookie in a WebRequestSession instead - that path works on both 5.1 and 7+.
function New-CursorWebSession {
    param([string]$UserId, [string]$Token)
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $value   = [Uri]::EscapeDataString($UserId + '::' + $Token)
    $session.Cookies.Add((New-Object System.Net.Cookie('WorkosCursorSessionToken', $value, '/', 'cursor.com')))
    return $session
}

function Get-CursorToken {
    # Read accessToken and email from state.vscdb
    $raw = Invoke-Sqlite $script:StateVscdb "SELECT key, value FROM ItemTable WHERE key IN ('cursorAuth/accessToken','cursorAuth/cachedEmail')"
    if (-not $raw) { return $null, $null, $null }
    $rows = $null
    try { $rows = $raw | ConvertFrom-Json } catch { return $null, $null, $null }
    if (-not $rows) { return $null, $null, $null }

    $tok    = $null
    $email  = $null
    $userId = $null

    foreach ($row in $rows) {
        if ($row.key -eq 'cursorAuth/accessToken') { $tok   = $row.value -replace '^"|"$','' }
        if ($row.key -eq 'cursorAuth/cachedEmail')  { $email = $row.value -replace '^"|"$','' }
    }

    # Decode JWT payload to extract userId (sub field)
    if ($tok) {
        try {
            $parts = $tok -split '\.'
            if ($parts.Count -ge 2) {
                $b64 = $parts[1].Replace('-', '+').Replace('_', '/')
                $pad = $b64.Length % 4
                if ($pad -ne 0) { $b64 += '=' * (4 - $pad) }
                $payload = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64)) | ConvertFrom-Json
                if ($payload.sub) { $userId = $payload.sub }
            }
        } catch { }
    }

    return $tok, $userId, $email
}

# ---------------------------------------------------------------------------
# Live data from Cursor API
# ---------------------------------------------------------------------------
function Get-CursorUsage {
    param([int]$TimeoutSec = 20)

    $script:LiveData = $null
    $script:SummaryData = $null
    $tok, $userId, $email = Get-CursorToken
    if (-not $tok -or -not $userId) {
        $script:AuthState = 'notoken'; $script:CursorErrMsg = 'Cannot read Cursor token from state.vscdb'
        return
    }

    $session = New-CursorWebSession -UserId $userId -Token $tok

    try {
        $r = Invoke-RestMethod "https://cursor.com/api/usage?user=$([Uri]::EscapeDataString($userId))" `
            -WebSession $session -TimeoutSec $TimeoutSec
        $script:LiveData        = $r
        $script:AuthState       = 'ok'
        $script:CursorErrMsg    = ''
        $script:CursorLastFetch = (Get-Date -Format 'HH:mm')
    } catch {
        $code = $null
        if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
        if ($code -eq 401) { $script:AuthState = 'auth';  $script:CursorErrMsg = 'Auth expired - reopen Cursor' }
        else                { $script:AuthState = 'stale'; $script:CursorErrMsg = $_.Exception.Message }
    }

    # The displayed quota comes from summary, so its result owns refresh status.
    try {
        $summary = Invoke-RestMethod 'https://cursor.com/api/usage-summary' `
            -WebSession $session -Headers @{ Authorization = "Bearer $tok" } -TimeoutSec $TimeoutSec
        if (-not $summary -or -not $summary.individualUsage) { throw 'Unrecognized Cursor usage-summary response' }
        $script:SummaryData = $summary
        $script:AuthState = 'ok'
        $script:CursorErrMsg = ''
        $script:CursorLastFetch = (Get-Date -Format 'HH:mm')
    } catch {
        $code = $null
        if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
        $script:AuthState = if ($code -in @(401, 403)) { 'auth' } else { 'stale' }
        $script:CursorErrMsg = 'Cursor usage summary unavailable'
    }
}

# ---------------------------------------------------------------------------
# Edit/model stats from the Cursor dashboard analytics API.
# Cursor stopped writing the local ai-code-tracking.db (ai_code_hashes) around
# 2026-05-27 and serves these live from cursor.com instead. The endpoint is
# user-scoped and returns a fixed ~30-day rolling window of per-day metrics.
# (No web or live-local source exposes a conversation/session count anymore.)
# ---------------------------------------------------------------------------
function Get-CursorLocalStats {
    param([int]$TimeoutSec = 20)

    $script:LocalData = $null
    $tok, $userId, $email = Get-CursorToken
    if (-not $tok -or -not $userId) { return }
    $session = New-CursorWebSession -UserId $userId -Token $tok

    try {
        $a = Invoke-RestMethod 'https://cursor.com/api/dashboard/get-user-analytics' `
            -WebSession $session -TimeoutSec $TimeoutSec
    } catch { return }
    if (-not $a -or -not $a.dailyMetrics) { return }

    # date is UTC-midnight ms; match the bucket whose day == today (UTC).
    $todayMs = [System.DateTimeOffset]::new([datetime]::UtcNow.Date, [TimeSpan]::Zero).ToUnixTimeMilliseconds()

    $edits30d = 0L; $editsToday = $null; $linesAcc = 0L
    $hasEdits = $true; $hasLines = $true
    $models = @{}
    foreach ($day in $a.dailyMetrics) {
        if ($null -eq $day.totalApplies) { $hasEdits = $false }
        else { $edits30d += [long]$day.totalApplies }
        if ($null -eq $day.acceptedLinesAdded) { $hasLines = $false }
        else { $linesAcc += [long]$day.acceptedLinesAdded }
        if ([long]$day.date -eq $todayMs -and $null -ne $day.totalApplies) { $editsToday = [long]$day.totalApplies }
        foreach ($m in $day.modelUsage) {
            if ($m.name) { $models[$m.name] = [int]$models[$m.name] + [int]$m.count }
        }
    }

    $topModel = $null; $topCount = 0; $totalModel = 0
    foreach ($kv in $models.GetEnumerator()) {
        $totalModel += $kv.Value
        if ($kv.Value -gt $topCount) { $topCount = $kv.Value; $topModel = $kv.Key }
    }
    $topPct = if ($totalModel -gt 0) { [int][Math]::Round($topCount * 100.0 / $totalModel) } else { 0 }

    $script:LocalData = [PSCustomObject]@{
        edits30d      = if ($hasEdits) { $edits30d } else { $null }
        editsToday    = $editsToday
        topModel      = $topModel
        topPct        = $topPct
        linesAccepted = if ($hasLines) { $linesAcc } else { $null }
    }
}
