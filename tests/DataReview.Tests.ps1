# DataReview.Tests.ps1 - regression tests for docs/reviews/review-data.md
# (dates read back under other cultures, Codex catch-up polls, the Claude job
# ceiling). Fixtures only: fake tokens, temp folders; never reads real
# credentials or the real ~/.codex.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:count = 0
function Assert($Value, [string]$Name) {
    if (-not $Value) { throw "FAILED: $Name" }
    $script:count++; Write-Output "PASS: $Name"
}

# Runs a block under another culture and always puts the old one back.
function Invoke-InCulture([string]$Name, [scriptblock]$Body) {
    $thread = [System.Threading.Thread]::CurrentThread
    $old = $thread.CurrentCulture
    try {
        $thread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($Name)
        return (& $Body)
    } finally {
        $thread.CurrentCulture = $old
    }
}

function Import-SourceFunctions([string]$Path, [string[]]$Names) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    foreach ($n in $Names) {
        $fn = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true)
        if ($fn) { . ([scriptblock]::Create($fn.Extent.Text)) }
    }
}

$fixture = [IO.Path]::Combine($PSScriptRoot, 'jayos-data-review-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$script:AppDir = $fixture
$script:ErrLog = [IO.Path]::Combine($fixture, 'errors.log')
$src = [IO.Path]::Combine($root, 'src')
function claude { 'claude-code/test' }
. ([IO.Path]::Combine($src, 'Config.ps1'))
function Get-WslHomeRoots { return @() }
. ([IO.Path]::Combine($src, 'Format.ps1'))
. ([IO.Path]::Combine($src, 'Data.ps1'))
. ([IO.Path]::Combine($src, 'CodexData.ps1'))
. ([IO.Path]::Combine($src, 'GrokData.ps1'))
. Import-SourceFunctions ([IO.Path]::Combine($root, 'unified-overlay.ps1')) @('Start-AllRefreshJobs', 'Get-RefreshJobCeilingSeconds')

$savedEnv = @{}
foreach ($v in 'CODEX_HOME', 'USERPROFILE', 'HOME', 'LOCALAPPDATA', 'APPDATA') { $savedEnv[$v] = [Environment]::GetEnvironmentVariable($v) }

try {
    # --- 1. Claude backoff and usage cache dates (review-data #1) ----------
    $until = [datetime]::new(2027, 2, 3, 10, 0, 0, [DateTimeKind]::Local)
    Set-ClaudeBackoffUntil -BackoffUntil $until -Status stale
    foreach ($c in 'en-GB', 'de-DE', 'en-US') {
        $got = Invoke-InCulture $c { (Get-ClaudeBackoffState).Until }
        Assert ($got -is [datetime] -and $got -eq $until) "backoff deadline reads back unchanged under $c"
    }
    Save-ClaudeUsageCache ([pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 12.0 } })
    foreach ($c in 'en-GB', 'de-DE', 'en-US') {
        $cached = Invoke-InCulture $c { Get-CachedClaudeUsage }
        Assert ($cached -and $cached.Data.five_hour.utilization -eq 12) "usage cache is restored under $c"
    }

    # --- 2. Grok token expiry (review-data #2) ------------------------------
    $past = ('{"https://auth.x.ai::client":{"key":"fixture-old","expires_at":"2000-12-25T10:00:00Z"}}') | ConvertFrom-Json
    $future = ('{"https://auth.x.ai::client":{"key":"fixture-new","expires_at":"2099-10-20T10:00:00Z"}}') | ConvertFrom-Json
    foreach ($c in 'en-GB', 'de-DE', 'en-US') {
        Assert ($null -eq (Invoke-InCulture $c { Get-GrokAccessToken $past })) "expired Grok token is not used under $c"
        Assert ((Invoke-InCulture $c { Get-GrokAccessToken $future }) -eq 'fixture-new') "valid Grok token is used under $c"
    }
    $soon = [datetime]::UtcNow.AddHours(3)
    Assert (-not (Test-GrokAuthEntryExpired ([pscustomobject]@{ expires_at = $soon }))) 'UTC [datetime] expiry three hours ahead is not expired'
    Assert (Test-GrokAuthEntryExpired ([pscustomobject]@{ expires_at = [datetime]::UtcNow.AddMinutes(-1) })) 'UTC [datetime] expiry a minute ago is expired'
    $end = Convert-GrokPeriodEnd ([datetime]::new(2099, 10, 20, 10, 0, 0, [DateTimeKind]::Utc))
    Assert ($end.Kind -eq [DateTimeKind]::Local -and $end.ToUniversalTime() -eq [datetime]::new(2099, 10, 20, 10, 0, 0, [DateTimeKind]::Utc)) 'Grok period end from a UTC [datetime] is handed out as local time'

    # --- 3. Format-Reset with [datetime] input (review-data #3) ------------
    $at = [DateTimeOffset]::Now.AddHours(30).AddMinutes(1)
    $expect = Invoke-InCulture 'en-US' { Format-Reset $at.ToString('o') }
    $jsonDate = ('{"r":"' + $at.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fff') + '+00:00","z":"' + $at.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss') + 'Z"}') | ConvertFrom-Json
    $inputs = @($jsonDate.r, $jsonDate.z, $at, $at.LocalDateTime, $at.UtcDateTime)
    foreach ($c in 'de-DE', 'en-GB', 'fr-FR', 'en-US') {
        foreach ($in in $inputs) {
            $got = Invoke-InCulture $c { Format-Reset $in }
            Assert ($got -eq $expect) "Format-Reset of a $($in.GetType().Name) under $c reads '$expect' (got '$got')"
        }
    }
    Assert ((Format-Reset $null) -eq '') 'Format-Reset of nothing is empty'
    Assert ((Format-Reset 'not a date') -eq '') 'Format-Reset of garbage is empty'

    # --- 5. Claude stats cache dates (review-data #5) -----------------------
    $local = [datetime]::Today.AddHours(9.5)
    $rec = @(Convert-StatsCacheRecords @([pscustomobject]@{ Model = 'm'; Date = $local.ToUniversalTime(); In = 1; Out = 1; CacheW = 0; CacheR = 0; SessionId = 's'; Key = 'k' }))[0]
    Assert ($rec.Date.Kind -ne [DateTimeKind]::Utc -and $rec.Date -eq $local) 'a cached UTC date (Windows PowerShell 5.1) comes back as local time'

    # --- 4. Codex catch-up poll (review-data #4) ----------------------------
    $codexHome = [IO.Path]::Combine($fixture, 'codex')
    $sessions = [IO.Path]::Combine($codexHome, 'sessions')
    New-Item -ItemType Directory -Path $sessions -Force | Out-Null
    foreach ($v in 'USERPROFILE', 'HOME', 'LOCALAPPDATA', 'APPDATA') { [Environment]::SetEnvironmentVariable($v, $fixture) }
    $env:CODEX_HOME = $codexHome
    $script:CodexSessionsDir = $sessions
    $line = '{"timestamp":"2026-10-19T20:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5,"cached_input_tokens":0,"output_tokens":7}}}}'
    foreach ($n in 'a', 'b') { [IO.File]::WriteAllText([IO.Path]::Combine($sessions, "rollout-$n.jsonl"), $line + "`n") }
    $script:liveCalls = 0
    function Get-CodexLiveUsage { $script:liveCalls++; return @{ WeekPct = 42.0; WeekResetsAt = $null; FiveHourPct = 7.0; FiveHourResetsAt = $null; ResetsAvailable = 1; PlanType = 'plus'; Credits = $null } }
    $script:CodexStatsFileCache = @{}
    $script:CodexStats = $null
    $script:CodexParseBudgetSeconds = 0
    Get-CodexStats
    Assert ($script:liveCalls -eq 1) 'live Codex usage is still fetched while session logs are catching up'
    Assert ($script:CodexStats -and $script:CodexStats.WeekPct -eq 42 -and $script:CodexStats.FiveHourPct -eq 7) 'catch-up poll carries the live weekly and 5-hour numbers'
    Assert ($script:CodexStats.CatchingUp) 'catch-up poll is marked as catching up'
    $partial = $script:CodexStats

    $previous = @{ InTokens = 900L; OutTokens = 100L; Sessions = 3; WeekPct = 10.0; FiveHourPct = 1.0; PlanType = 'plus' }
    $merged = Merge-CodexStatsResult $previous $partial
    Assert ($merged.InTokens -eq 900 -and $merged.Sessions -eq 3) 'a catch-up result keeps the last complete local totals'
    Assert ($merged.WeekPct -eq 42 -and $merged.FiveHourPct -eq 7 -and -not $merged.CatchingUp) 'a catch-up result still updates the live numbers'
    Assert ((Merge-CodexStatsResult $null $partial).CatchingUp) 'with nothing earlier the catch-up result is shown as catching up'
    $full = @{ InTokens = 1L; WeekPct = 5.0 }
    Assert ((Merge-CodexStatsResult $previous $full).InTokens -eq 1) 'a complete result replaces the earlier one'

    $script:CodexParseBudgetSeconds = 35
    $script:liveCalls = 0
    Get-CodexStats
    Assert ($script:CodexStats -and -not $script:CodexStats.CatchingUp -and $script:CodexStats.InTokens -eq 10 -and $script:CodexStats.WeekPct -eq 42) 'the next poll finishes both logs and publishes the full totals'

    # --- 6. Claude usage job ceiling (review-data #6) -----------------------
    function Write-Log($Message) { }
    $script:started = 0
    function Start-OverlayBackgroundJob { $script:started++; return [pscustomobject]@{ Id = -1; State = 'Running' } }
    $running = [pscustomobject]@{ Id = -2; State = 'Running' }
    $script:pollJobs = @{ ClaudeUsage = $running }
    $script:pollJobStartedAt = @{ ClaudeUsage = (Get-Date).AddSeconds(-61) }
    Start-AllRefreshJobs -Kind @('ClaudeUsage')
    Assert ([object]::ReferenceEquals($script:pollJobs['ClaudeUsage'], $running) -and $script:started -eq 0) 'a Claude usage job (which also fetches Cursor) is not reaped after 61 s'
    $script:pollJobStartedAt = @{ ClaudeUsage = (Get-Date).AddSeconds(-200) }
    Start-AllRefreshJobs -Kind @('ClaudeUsage')
    Assert ($script:started -eq 1) 'a Claude usage job that really hangs is still reaped'

    Write-Output "$script:count tests passed on PowerShell $($PSVersionTable.PSVersion)."
} finally {
    foreach ($v in @($savedEnv.Keys)) { [Environment]::SetEnvironmentVariable($v, $savedEnv[$v]) }
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ($resolved.StartsWith([IO.Path]::GetFullPath($PSScriptRoot), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
