<#
    Unified AI Usage Overlay
    A single always-on-top HUD showing Claude Code, Codex, Cursor, and Grok usage.
    Right-click the panel for all options.

    Usage:
      powershell -STA -File unified-overlay.ps1           # run
      powershell -File unified-overlay.ps1 -Json          # print one snapshot and exit
      powershell -STA -File unified-overlay.ps1 -Install  # add login auto-start + run
      powershell -STA -File unified-overlay.ps1 -Uninstall
#>
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Hidden,
    [switch]$Json,
    [switch]$Snapshot,
    [switch]$NoHud,
    [ValidateSet('Claude', 'Codex', 'Cursor', 'Grok')]
    [string[]]$Provider = @('Claude', 'Codex', 'Cursor', 'Grok'),
    [switch]$ClaudeOnly,
    [switch]$CodexOnly,
    [switch]$CursorOnly,
    [switch]$GrokOnly,
    [int]$TimeoutSec = 20,
    [int]$ClaudeTimeoutSec = 0,
    [int]$CursorTimeoutSec = 0,
    [int]$GrokTimeoutSec = 0,
    [switch]$Background   # set on self-relaunch to break infinite-loop
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw 'Windows PowerShell 5.1 or PowerShell 7+ is required.'
}

$script:AppDir    = $PSScriptRoot
$script:StatePath = Join-Path $script:AppDir 'unified-overlay-state.json'
$script:VbsPath   = Join-Path $script:AppDir 'Start-Unified.vbs'
$script:ErrLog    = Join-Path $script:AppDir 'unified-overlay-error.log'
$script:PidPath   = Join-Path $script:AppDir 'unified-overlay.pid'
$script:LnkPath   = Join-Path ([Environment]::GetFolderPath('Startup')) 'AIUsageOverlay.lnk'
$script:CredPath  = Join-Path $env:USERPROFILE '.claude\.credentials.json'

function Quote-NativeArg([string]$Value) {
    '"' + ($Value -replace '"', '\"') + '"'
}

function Start-HiddenBackground {
    $exe = (Get-Process -Id $PID).Path
    $args = @(
        '-STA',
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-NonInteractive',
        '-File',
        (Quote-NativeArg $PSCommandPath),
        '-Background'
    )

    if ([System.IO.Path]::GetFileName($exe) -ieq 'pwsh.exe') {
        # conhost --headless is required: pwsh -WindowStyle Hidden is ignored by Windows Terminal.
        Start-Process 'conhost.exe' -ArgumentList (@('--headless', (Quote-NativeArg $exe)) + $args)
    } else {
        Start-Process $exe -WindowStyle Hidden -ArgumentList $args
    }
}

function Stop-ExistingInstance {
    $scriptPath = [System.IO.Path]::GetFullPath($PSCommandPath)

    if (Test-Path $script:PidPath) {
        try {
            $oldPid = [int](Get-Content $script:PidPath -Raw)
            if ($oldPid -ne $PID) {
                $old = Get-CimInstance Win32_Process -Filter "ProcessId=$oldPid" -ErrorAction SilentlyContinue
                if ($old -and $old.CommandLine -like "*$scriptPath*") {
                    Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Milliseconds 500
                }
            }
        } catch { }
        Remove-Item $script:PidPath -Force -ErrorAction SilentlyContinue
    }

    Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $PID -and
            $_.CommandLine -like "*$scriptPath*" -and
            $_.CommandLine -like '*-Background*'
        } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

function Install-Autostart {
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($script:LnkPath)
    $sc.TargetPath       = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $sc.Arguments        = '"' + $script:VbsPath + '"'
    $sc.WorkingDirectory = $script:AppDir
    $sc.Description      = 'AI Usage Overlay'
    $sc.Save()
}
function Uninstall-Autostart { if (Test-Path $script:LnkPath) { Remove-Item $script:LnkPath -Force } }
function Test-Autostart      { Test-Path $script:LnkPath }

function Invoke-SafeSnapshotStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    try {
        & $ScriptBlock
        return $null
    } catch {
        Write-Log "Snapshot: $Name failed - $($_.Exception.Message)"
        return $_.Exception.Message
    }
}

function Limit-SnapshotTimeoutSec {
    param(
        [int]$Value,
        [int]$Default = 20
    )

    if ($Value -le 0) { $Value = $Default }
    return [math]::Min(120, [math]::Max(1, $Value))
}

function Resolve-SnapshotProviders {
    param(
        [string[]]$Provider,
        [switch]$ClaudeOnly,
        [switch]$CodexOnly,
        [switch]$CursorOnly,
        [switch]$GrokOnly
    )

    $selected = [ordered]@{
        claude = $false
        codex  = $false
        cursor = $false
        grok   = $false
    }

    if ($ClaudeOnly -or $CodexOnly -or $CursorOnly -or $GrokOnly) {
        if ($ClaudeOnly) { $selected.claude = $true }
        if ($CodexOnly)  { $selected.codex  = $true }
        if ($CursorOnly) { $selected.cursor = $true }
        if ($GrokOnly)   { $selected.grok   = $true }
        return $selected
    }

    foreach ($name in @($Provider)) {
        switch -Regex ($name) {
            '^Claude$' { $selected.claude = $true; break }
            '^Codex$'  { $selected.codex  = $true; break }
            '^Cursor$' { $selected.cursor = $true; break }
            '^Grok$'   { $selected.grok   = $true; break }
        }
    }

    return $selected
}

function Invoke-OverlaySnapshot {
    param(
        [string[]]$Provider = @('Claude', 'Codex', 'Cursor', 'Grok'),
        [switch]$ClaudeOnly,
        [switch]$CodexOnly,
        [switch]$CursorOnly,
        [switch]$GrokOnly,
        [int]$TimeoutSec = 20,
        [int]$ClaudeTimeoutSec = 0,
        [int]$CursorTimeoutSec = 0,
        [int]$GrokTimeoutSec = 0
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    . (Join-Path $script:AppDir 'src\Config.ps1')
    . (Join-Path $script:AppDir 'src\Format.ps1')
    . (Join-Path $script:AppDir 'src\Pricing.ps1')
    . (Join-Path $script:AppDir 'src\History.ps1')
    . (Join-Path $script:AppDir 'src\Data.ps1')
    . (Join-Path $script:AppDir 'src\State.ps1')
    . (Join-Path $script:AppDir 'src\CodexData.ps1')
    . (Join-Path $script:AppDir 'src\CursorData.ps1')
    . (Join-Path $script:AppDir 'src\GrokData.ps1')
    . (Join-Path $script:AppDir 'src\ProviderLinks.ps1')
    . (Join-Path $script:AppDir 'src\Export.ps1')

    $script:State = @{ Data = $null; Status = 'init'; LastFetch = ''; Message = '' }
    $script:Stats = $null
    $script:CodexStats = $null
    $script:CodexAuthState = 'init'
    $script:CodexErrMsg = ''
    $script:LiveData = $null
    $script:SummaryData = $null
    $script:LocalData = $null
    $script:AuthState = 'init'
    $script:CursorErrMsg = ''
    $script:CursorLastFetch = ''
    $script:GrokAuthState = 'init'
    $script:GrokErrMsg = ''
    $script:GrokUsage = $null

    $selectedProviders = Resolve-SnapshotProviders -Provider $Provider -ClaudeOnly:$ClaudeOnly -CodexOnly:$CodexOnly -CursorOnly:$CursorOnly -GrokOnly:$GrokOnly
    $defaultTimeout = Limit-SnapshotTimeoutSec -Value $TimeoutSec
    $claudeTimeout = Limit-SnapshotTimeoutSec -Value $ClaudeTimeoutSec -Default $defaultTimeout
    $cursorTimeout = Limit-SnapshotTimeoutSec -Value $CursorTimeoutSec -Default $defaultTimeout
    $grokTimeout = Limit-SnapshotTimeoutSec -Value $GrokTimeoutSec -Default $defaultTimeout

    Load-History
    $claudeError = $null
    $claudeStatsError = $null
    $codexError = $null
    $cursorUsageError = $null
    $cursorStatsError = $null
    $grokError = $null

    if ($selectedProviders['claude']) {
        $claudeError = Invoke-SafeSnapshotStep 'Claude usage' { Get-Usage -TimeoutSec $claudeTimeout -Force }
        $claudeStatsError = Invoke-SafeSnapshotStep 'Claude stats' { Get-Stats }
    }
    if ($selectedProviders['codex']) {
        $codexError = Invoke-SafeSnapshotStep 'Codex stats' { Get-CodexStats }
    }
    if ($selectedProviders['cursor']) {
        $cursorUsageError = Invoke-SafeSnapshotStep 'Cursor usage' { Get-CursorUsage -TimeoutSec $cursorTimeout }
        $cursorStatsError = Invoke-SafeSnapshotStep 'Cursor stats' { Get-CursorLocalStats -TimeoutSec $cursorTimeout }
    }
    if ($selectedProviders['grok']) {
        $grokError = Invoke-SafeSnapshotStep 'Grok usage' { [void](Get-GrokLiveUsage -TimeoutSec $grokTimeout) }
    }

    if (Get-Command Complete-UnifiedHistoryPoll -ErrorAction SilentlyContinue) {
        Complete-UnifiedHistoryPoll
    }

    $providers = [ordered]@{
        claude = New-SkippedProviderSnapshot
        codex  = New-SkippedProviderSnapshot
        cursor = New-SkippedProviderSnapshot
        grok   = New-SkippedProviderSnapshot
    }

    if ($selectedProviders['claude']) {
        $claudeStatus = $script:State.Status
        if (($claudeStatus -eq 'error' -and $script:State.Message -eq 'No credentials file') -or
            ($claudeStatus -eq 'auth' -and $script:State.Message -eq 'Not logged in')) {
            $claudeStatus = 'unavailable'
        }

        $providers.claude = New-ClaudeProviderSnapshot `
            -Status $claudeStatus `
            -Message $script:State.Message `
            -LastFetch $script:State.LastFetch `
            -Identity $script:ClaudeIdentity `
            -Usage $script:State.Data `
            -Stats $script:Stats `
            -FetchError $claudeError `
            -StatsError $claudeStatsError
    }
    if ($selectedProviders['codex']) {
        # Aligned with cursor below: an auth failure outranks successfully parsed
        # local stats. Codex used to report 'ok' while its live quota 401'd for
        # 13 days, because the session logs still parsed fine.
        $codexStatus =
            if ($script:CodexAuthState -eq 'notoken') { 'unavailable' }
            elseif (Test-ProviderAuthFailed $script:CodexAuthState) { $script:CodexAuthState }
            elseif ($script:CodexAuthState -eq 'stale') { 'stale' }
            elseif ($script:CodexStats) { 'ok' }
            elseif ($codexError) { 'error' }
            else { 'unavailable' }

        $providers.codex = New-CodexProviderSnapshot `
            -Status $codexStatus `
            -Message $script:CodexErrMsg `
            -Stats $script:CodexStats `
            -FetchError $codexError
    }
    if ($selectedProviders['cursor']) {
        $cursorError = if ($cursorUsageError) { $cursorUsageError } else { $cursorStatsError }
        $cursorStatus = if ($script:AuthState -eq 'notoken') { 'unavailable' } else { $script:AuthState }
        $providers.cursor = New-CursorProviderSnapshot `
            -Status $cursorStatus `
            -Message $script:CursorErrMsg `
            -LastFetch $script:CursorLastFetch `
            -Usage $script:LiveData `
            -Summary $script:SummaryData `
            -Local $script:LocalData `
            -FetchError $cursorError
    }
    if ($selectedProviders['grok']) {
        $grokStatus =
            if ($script:GrokAuthState -eq 'notoken') { 'unavailable' }
            elseif (Test-ProviderAuthFailed $script:GrokAuthState) { $script:GrokAuthState }
            elseif ($script:GrokAuthState -eq 'stale') { 'stale' }
            elseif ($script:GrokUsage) { 'ok' }
            elseif ($grokError) { 'error' }
            else { $script:GrokAuthState }

        $providers.grok = New-GrokProviderSnapshot `
            -Status $grokStatus `
            -Message $script:GrokErrMsg `
            -Usage $script:GrokUsage `
            -FetchError $grokError
    }

    $snapshot = New-UnifiedSnapshotDocument `
        -AppVersion $script:AppVersion `
        -SelectedProviders $selectedProviders `
        -Timeouts ([ordered]@{ claude = $claudeTimeout; cursor = $cursorTimeout; grok = $grokTimeout }) `
        -Providers $providers

    $snapshot | ConvertTo-Json -Depth 12
}

if ($Uninstall) { Uninstall-Autostart; Write-Host 'Removed login auto-start.'; return }
if ($Install) {
    Install-Autostart
    Stop-ExistingInstance
    Start-HiddenBackground
    Write-Host 'Installed. Unified overlay is running.'
    return
}

if ($Json -or $Snapshot -or $NoHud) {
    Invoke-OverlaySnapshot -Provider $Provider -ClaudeOnly:$ClaudeOnly -CodexOnly:$CodexOnly -CursorOnly:$CursorOnly -GrokOnly:$GrokOnly -TimeoutSec $TimeoutSec -ClaudeTimeoutSec $ClaudeTimeoutSec -CursorTimeoutSec $CursorTimeoutSec -GrokTimeoutSec $GrokTimeoutSec
    return
}

# Self-relaunch when run from a console. The spawned copy is hidden and uses
# -Background to skip this block, so there is no infinite loop.
if (-not $Background) {
    Add-Type -Name '_UnifiedK32' -Namespace '' -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();'
    if ([_UnifiedK32]::GetConsoleWindow() -ne [IntPtr]::Zero) {
        Start-HiddenBackground
        exit
    }
}

# A fresh GUI start replaces any overlay already running from this folder
# (previously only -Install did this, so relaunching stacked copies).
Stop-ExistingInstance

try {

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase,
                       System.Windows.Forms, System.Drawing, System.Xaml

# WPF enables process DPI awareness lazily. Do this before WinForms creates
# tray/menu handles, or Windows scales their screen coordinates a second time.
[void][System.Windows.SystemParameters]::PrimaryScreenWidth

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Load modules (dot-sourced into this scope)
# ---------------------------------------------------------------------------
. (Join-Path $script:AppDir 'src\Config.ps1')
. (Join-Path $script:AppDir 'src\Format.ps1')
. (Join-Path $script:AppDir 'src\Pricing.ps1')
. (Join-Path $script:AppDir 'src\History.ps1')
. (Join-Path $script:AppDir 'src\Data.ps1')
Remove-StaleOverlayArtifacts
. (Join-Path $script:AppDir 'src\State.ps1')
. (Join-Path $script:AppDir 'src\CodexData.ps1')
. (Join-Path $script:AppDir 'src\CursorData.ps1')
. (Join-Path $script:AppDir 'src\GrokData.ps1')
. (Join-Path $script:AppDir 'src\ProviderLogin.ps1')
. (Join-Path $script:AppDir 'src\ProviderVersions.ps1')
. (Join-Path $script:AppDir 'src\ProviderLinks.ps1')
. (Join-Path $script:AppDir 'src\Export.ps1')
. (Join-Path $script:AppDir 'src\InstallManifest.ps1')
. (Join-Path $script:AppDir 'src\Layout.ps1')
. (Join-Path $script:AppDir 'src\Status.ps1')
. (Join-Path $script:AppDir 'src\Shell.ps1')
. (Join-Path $script:AppDir 'src\UnifiedState.ps1')
. (Join-Path $script:AppDir 'src\ProviderPicker.ps1')
. (Join-Path $script:AppDir 'src\QuakeView.ps1')
. (Join-Path $script:AppDir 'src\Dropdown.ps1')
. (Join-Path $script:AppDir 'src\Update.ps1')
. (Join-Path $script:AppDir 'src\UnifiedTray.ps1')

# ---------------------------------------------------------------------------
# Runtime state (declared after modules so $xaml from Shell.ps1 is available)
# ---------------------------------------------------------------------------
$script:State      = @{ Data = $null; Status = 'init'; LastFetch = ''; Message = '' }
$script:Stats      = $null
$script:ReallyQuit = $false
$script:Positioned = $false

$script:window = [System.Windows.Markup.XamlReader]::Parse($xaml)

function Update-OverlayViews {
    Update-AllSections
    if (Get-Command Update-IslandView -ErrorAction SilentlyContinue) { Update-IslandView }
}

function Restore-UnifiedSections {
    foreach ($key in $script:UnifiedSectionKeys) {
        if ($script:Cfg.Sections.ContainsKey($key)) {
            Set-Section $key ([bool]$script:Cfg.Sections[$key])
        }
    }
}

# ---------------------------------------------------------------------------
# Async data gathering (off the WPF dispatcher thread)
#
# The poll fans out to network (cursor.com, api.anthropic.com - up to 20s each)
# and to 5 sqlite3.exe spawns. Doing that synchronously on the UI thread froze
# the window for up to ~40s every 3 minutes. Instead we start self-contained
# background refreshes (ThreadJob on PowerShell 7, process Job on Windows
# PowerShell 5.1), and a fast completion-poll timer marshals each RETURNED data
# packet back onto the UI thread and renders there.
# ---------------------------------------------------------------------------

# Runs in background runspaces. Each job dot-sources the modules it needs and
# RETURNS plain data only; WPF objects are touched only on the dispatcher thread.
$script:ClaudeUsageScript = {
    param([string]$AppDir, [string]$CredPath, [string]$ErrLog, [int]$UsageTimeoutSec = 20, [bool]$ForceRefresh = $false)

    $script:AppDir   = $AppDir
    $script:CredPath = $CredPath
    $script:ErrLog   = $ErrLog
    # NEVER mutate $env:PATH here. This scriptblock re-runs in-process (ThreadJob)
    # on every poll, so prepending grew PATH past the Win32 32,767-char env-var
    # limit after ~875 polls (a few days to ~a week, depending on the adaptive
    # poll interval). Past that, EVERY child-process spawn fails process-wide and
    # the Cursor section reports "Cannot read Cursor token from state.vscdb"
    # forever, with no error logged anywhere.
    # Invoke-Sqlite locates the bundled sqlite3.exe itself via Resolve-Sqlite3Path.

    . (Join-Path $AppDir 'src\Config.ps1')
    . (Join-Path $AppDir 'src\History.ps1')
    . (Join-Path $AppDir 'src\Data.ps1')
    . (Join-Path $AppDir 'src\CursorData.ps1')

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # State hashtable mirrors the shape unified-overlay.ps1 declares.
    $script:State = @{ Data = $null; Status = 'init'; LastFetch = ''; Message = '' }

    Load-History
    Get-Usage -TimeoutSec $UsageTimeoutSec -Force:$ForceRefresh
    Get-CursorUsage
    Get-CursorLocalStats

    @{
        Kind            = 'ClaudeUsage'
        State           = $script:State
        ClaudeIdentity  = $script:ClaudeIdentity
        LiveData        = $script:LiveData
        SummaryData     = $script:SummaryData
        LocalData       = $script:LocalData
        AuthState       = $script:AuthState
        CursorErrMsg    = $script:CursorErrMsg
        CursorLastFetch = $script:CursorLastFetch
        History         = @($script:History)
    }
}

$script:ClaudeStatsScript = {
    param([string]$AppDir, [string]$ErrLog)

    $script:AppDir = $AppDir
    $script:ErrLog = $ErrLog

    . (Join-Path $AppDir 'src\Config.ps1')
    . (Join-Path $AppDir 'src\Pricing.ps1')
    . (Join-Path $AppDir 'src\Data.ps1')

    Get-Stats

    @{
        Kind  = 'ClaudeStats'
        Stats = $script:Stats
    }
}

$script:CodexStatsScript = {
    param([string]$AppDir, [string]$ErrLog)

    $script:AppDir = $AppDir
    $script:ErrLog = $ErrLog

    . (Join-Path $AppDir 'src\Config.ps1')
    . (Join-Path $AppDir 'src\Pricing.ps1')
    . (Join-Path $AppDir 'src\Data.ps1')
    . (Join-Path $AppDir 'src\CodexData.ps1')

    Get-CodexStats

    @{
        Kind           = 'CodexStats'
        CodexStats     = $script:CodexStats
        CodexAuthState = $script:CodexAuthState
        CodexErrMsg    = $script:CodexErrMsg
    }
}


$script:GrokUsageScript = {
    param([string]$AppDir, [string]$ErrLog, [int]$UsageTimeoutSec = 20)

    $script:AppDir = $AppDir
    $script:ErrLog = $ErrLog

    . (Join-Path $AppDir 'src\Config.ps1')
    . (Join-Path $AppDir 'src\GrokData.ps1')

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Get-GrokLiveUsage -TimeoutSec $UsageTimeoutSec

    @{
        Kind          = 'GrokUsage'
        GrokUsage     = $script:GrokUsage
        GrokAuthState = $script:GrokAuthState
        GrokErrMsg    = $script:GrokErrMsg
    }
}

$script:pollJobs = @{}
$script:pollJobStartedAt = @{}
$script:LastClaudeUsageSignature = $null
$script:ClaudeUnchangedPolls = 0

function Get-ClaudeUsageSignature {
    param($Data)

    if (-not $Data) { return '' }
    $parts = @()
    foreach ($key in @('five_hour','seven_day','seven_day_fable','seven_day_opus')) {
        $prop = $Data.PSObject.Properties[$key]
        if (-not $prop -or -not $prop.Value) { continue }
        $node = $prop.Value
        $parts += ('{0}:{1}:{2}' -f $key, $node.utilization, $node.resets_at)
    }
    return ($parts -join '|')
}

function Get-ClaudeAdaptivePollSeconds {
    param($State)

    $defaultSeconds = if ($script:PollSeconds) { [int]$script:PollSeconds } else { 180 }

    $backoffUntil = Get-ClaudeBackoffUntil
    if ($backoffUntil -and $backoffUntil -gt (Get-Date)) {
        return [math]::Min(3600, [math]::Max(60, [int][math]::Ceiling(($backoffUntil - (Get-Date)).TotalSeconds)))
    }

    if (-not $State -or -not $State.Data) { return $defaultSeconds }

    $fiveHour = $State.Data.five_hour
    if ($fiveHour -and $null -ne $fiveHour.utilization -and [double]$fiveHour.utilization -ge [double]$script:WarnPct) {
        $script:ClaudeUnchangedPolls = 0
        $script:LastClaudeUsageSignature = Get-ClaudeUsageSignature $State.Data
        return 60
    }

    $signature = Get-ClaudeUsageSignature $State.Data
    if ($signature -and $signature -eq $script:LastClaudeUsageSignature) {
        $script:ClaudeUnchangedPolls++
    } else {
        $script:ClaudeUnchangedPolls = 0
        $script:LastClaudeUsageSignature = $signature
    }

    if ($script:ClaudeUnchangedPolls -ge 2) { return 900 }
    if ($script:ClaudeUnchangedPolls -eq 1) { return 300 }
    return $defaultSeconds
}

function Sync-ClaudePollTimerInterval {
    param($State)

    if (-not $script:pollTimer) { return }
    $seconds = Get-ClaudeAdaptivePollSeconds $State
    # This timer refreshes every provider. Claude enforces its own retry
    # deadline in Get-Usage; its backoff must not stall Codex/Cursor/Grok.
    $baseline = if ($script:PollSeconds) { [int]$script:PollSeconds } else { 180 }
    $seconds = [math]::Min($baseline, $seconds)
    $script:pollTimer.Interval = [TimeSpan]::FromSeconds($seconds)
}

function Start-OverlayBackgroundJob {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )

    if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
        return Start-ThreadJob -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    }

    return Start-Job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
}

function Start-AllRefreshJobs {
    param(
        [int]$UsageTimeoutSec = 20,
        [switch]$Force,
        [string[]]$Kind
    )

    $jobs = @(
        @{
            Kind       = 'ClaudeUsage'
            Script     = $script:ClaudeUsageScript
            Arguments  = @($script:AppDir, $script:CredPath, $script:ErrLog, $UsageTimeoutSec, [bool]$Force)
        }
        @{
            Kind       = 'ClaudeStats'
            Script     = $script:ClaudeStatsScript
            Arguments  = @($script:AppDir, $script:ErrLog)
        }
        @{
            Kind       = 'CodexStats'
            Script     = $script:CodexStatsScript
            Arguments  = @($script:AppDir, $script:ErrLog)
        }
        @{
            Kind       = 'GrokUsage'
            Script     = $script:GrokUsageScript
            Arguments  = @($script:AppDir, $script:ErrLog, $UsageTimeoutSec)
        }
    )

    if ($Kind -and $Kind.Count -gt 0) {
        $allow = @($Kind)
        $jobs = @($jobs | Where-Object { $allow -contains $_.Kind })
    }

    foreach ($jobSpec in $jobs) {
        $jobKind = $jobSpec.Kind

        if ($script:pollJobs.ContainsKey($jobKind)) {
            $existing = $script:pollJobs[$jobKind]
            if ($existing.State -eq 'Running' -or $existing.State -eq 'NotStarted') {
                $ceilingSeconds = (2 * $UsageTimeoutSec + 20)
                if (-not $script:pollJobStartedAt.ContainsKey($jobKind)) {
                    $script:pollJobStartedAt[$jobKind] = Get-Date
                    Write-Log "Start-AllRefreshJobs: previous $jobKind refresh still running; skipping this source."
                    continue
                }

                $elapsedSeconds = ((Get-Date) - $script:pollJobStartedAt[$jobKind]).TotalSeconds
                if ($elapsedSeconds -gt $ceilingSeconds) {
                    Write-Log "Start-AllRefreshJobs: previous $jobKind refresh hung > $ceilingSeconds seconds; reaping and restarting."
                    # Bind by Id so real jobs and lightweight test doubles both work
                    # (positional Stop-Job $obj tries -Id Int32[] and blows up on PSCustomObject).
                    Stop-Job -Id $existing.Id -ErrorAction SilentlyContinue
                    Remove-Job -Id $existing.Id -Force -ErrorAction SilentlyContinue
                    $script:pollJobs.Remove($jobKind)
                    $script:pollJobStartedAt.Remove($jobKind)
                } else {
                    Write-Log "Start-AllRefreshJobs: previous $jobKind refresh still running; skipping this source."
                    continue
                }
            }

            if ($script:pollJobs.ContainsKey($jobKind)) {
                Remove-Job -Id $existing.Id -Force -ErrorAction SilentlyContinue
                $script:pollJobs.Remove($jobKind)
            }
        }

        $script:pollJobs[$jobKind] = Start-OverlayBackgroundJob -ScriptBlock $jobSpec.Script -ArgumentList $jobSpec.Arguments
        $script:pollJobStartedAt[$jobKind] = Get-Date
    }
}

# Merge a freshly-returned Claude usage State onto the previous one, preserving
# last-known-good Data when the new result carries none (backoff/auth/stale/error
# paths return no Data) so the HUD shows stale values, not blank bars.
# Carried-forward Data is flagged Stale with DataAsOf set to the fetch it came
# from, so the HUD can say how old the numbers are rather than present them as
# live next to a reset countdown that may already have passed.
function Resolve-ClaudeUsageState {
    param($Previous, $Incoming)

    if (-not $Incoming) { return $Previous }
    if ($null -eq $Incoming.Data -and $Previous -and $null -ne $Previous.Data) {
        $asOf = [string]$Previous.DataAsOf
        if (-not $asOf) { $asOf = [string]$Previous.LastFetch }
        $readAt = [datetime]::MinValue
        if ([datetime]::TryParse($asOf, [ref]$readAt) -and $readAt -ge (Get-Date).AddHours(-24)) {
            Set-ClaudeUsageStateValue $Incoming 'Data' $Previous.Data
            Set-ClaudeUsageStateValue $Incoming 'Stale' $true
            Set-ClaudeUsageStateValue $Incoming 'DataAsOf' $asOf
        } else {
            Set-ClaudeUsageStateValue $Incoming 'Stale' $false
            Set-ClaudeUsageStateValue $Incoming 'DataAsOf' ''
        }
    } else {
        Set-ClaudeUsageStateValue $Incoming 'Stale' $false
        if (-not $Incoming.DataAsOf) {
            Set-ClaudeUsageStateValue $Incoming 'DataAsOf' (Get-Date -Format 'yyyy-MM-dd HH:mm')
        }
    }
    return $Incoming
}

# The job's State is a hashtable, but a process job (Windows PowerShell 5.1) can
# hand back a deserialized object instead; set keys without assuming a shape.
function Set-ClaudeUsageStateValue {
    param($State, [string]$Name, $Value)

    if ($null -eq $State) { return }
    if ($State -is [System.Collections.IDictionary]) { $State[$Name] = $Value; return }
    $State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Complete-RefreshJobs {
    if (-not $script:pollJobs -or $script:pollJobs.Count -eq 0) { return $false }

    $completedAny = $false

    foreach ($kind in @($script:pollJobs.Keys)) {
        $job = $script:pollJobs[$kind]
        if ($job.State -eq 'Running' -or $job.State -eq 'NotStarted') { continue }

        try {
            $results = @(Receive-Job $job -ErrorAction SilentlyContinue)
            $r = $results | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('Kind') } | Select-Object -Last 1

            if ($r) {
                $resultKind = [string]$r['Kind']
                $applied = $true
                switch ($resultKind) {
                    'ClaudeUsage' {
                        $script:State           = Resolve-ClaudeUsageState $script:State $r['State']
                        if ($r['ClaudeIdentity']) { $script:ClaudeIdentity = $r['ClaudeIdentity'] }
                        $script:LiveData        = $r['LiveData']
                        $script:SummaryData     = $r['SummaryData']
                        $script:LocalData       = $r['LocalData']
                        $script:AuthState       = $r['AuthState']
                        $script:CursorErrMsg    = $r['CursorErrMsg']
                        $script:CursorLastFetch = $r['CursorLastFetch']
                        Sync-ClaudePollTimerInterval $script:State
                    }
                    'ClaudeStats' {
                        $script:Stats = $r['Stats']
                    }
                    'CodexStats' {
                        $script:CodexStats = $r['CodexStats']
                        $script:CodexAuthState = $r['CodexAuthState']
                        $script:CodexErrMsg = $r['CodexErrMsg']
                    }
                    'GrokUsage' {
                        $script:GrokUsage = $r['GrokUsage']
                        $script:GrokAuthState = $r['GrokAuthState']
                        $script:GrokErrMsg = $r['GrokErrMsg']
                    }
                    default {
                        Write-Log "Complete-RefreshJobs: unknown result kind '$resultKind'."
                        $applied = $false
                    }
                }

                if ($applied) {
                    Update-OverlayViews
                    Resize-ToContent
                }
            }

            $completedAny = $true
        } catch {
            Write-Log "Complete-RefreshJobs: $kind failed: $($_.Exception.Message)"
        } finally {
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            $script:pollJobs.Remove($kind)
            $script:pollJobStartedAt.Remove($kind)
        }
    }

    if ($completedAny -and (-not $script:pollJobs -or $script:pollJobs.Count -eq 0)) {
        if (Get-Command Complete-UnifiedHistoryPoll -ErrorAction SilentlyContinue) {
            Complete-UnifiedHistoryPoll
        }
        Update-OverlayViews
        Resize-ToContent
    }

    return $completedAny
}

# ---------------------------------------------------------------------------
# Startup sequence - window shows immediately in a "loading" state; the first
# data load runs async and each section fills in as its refresh job returns.
# ---------------------------------------------------------------------------
Load-UnifiedState
$script:Cfg['ViewMode'] = 'Pinned'
$script:Cfg['StartHidden'] = $false
Initialize-IslandView
Load-History
$cachedClaudeUsage = Get-CachedClaudeUsage
if (-not $cachedClaudeUsage) { $cachedClaudeUsage = Get-RecentClaudeUsageFromHistory }
if ($cachedClaudeUsage) {
    $script:State.Data = $cachedClaudeUsage.Data
    $script:State.Status = 'stale'
    $script:State.Stale = $true
    $script:State.DataAsOf = $cachedClaudeUsage.AsOf
    $script:State.Message = 'Showing last available usage'
}
if ($script:UnifiedStateNeedsRepair) { Save-UnifiedState }
if (Get-Command Invoke-FirstRunProviderPickerIfNeeded -ErrorAction SilentlyContinue) {
    Invoke-FirstRunProviderPickerIfNeeded
}
if (Test-DropdownMode) { Initialize-DropdownPinnedPosition }
Sync-ViewModeMenuItems   # menu was built from defaults before state was read
if (-not $cachedClaudeUsage) {
    $script:State.Status  = 'init'
    $script:State.Message = 'loading...'
}
Update-OverlayViews
Apply-UnifiedSettings
Restore-UnifiedSections
Resize-ToContent
# Poll timer: every 180s kick off fresh async refreshes (skips sources still running).
$script:pollTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:pollTimer.Interval = [TimeSpan]::FromSeconds(180)
$script:pollTimer.add_Tick({ Start-AllRefreshJobs })

# Completion timer: cheaply checks whether refresh jobs have finished and, if
# so, marshals their data onto the UI thread and renders immediately.
$script:jobTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:jobTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:jobTimer.add_Tick({ [void](Complete-RefreshJobs); Complete-ProviderLoginWatchers })

function Get-ClaudeCredentialStamp {
    if (-not $script:CredPath) { return '' }
    try {
        $file = Get-Item -LiteralPath $script:CredPath -ErrorAction Stop
        return ('{0}:{1}' -f $file.LastWriteTimeUtc.Ticks, $file.Length)
    } catch { return '' }
}

$script:ClaudeCredentialStamp = Get-ClaudeCredentialStamp
$script:credentialTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:credentialTimer.Interval = [TimeSpan]::FromSeconds(10)
$script:credentialTimer.add_Tick({
    $stamp = Get-ClaudeCredentialStamp
    if ($stamp -eq $script:ClaudeCredentialStamp) { return }
    if ($script:pollJobs.ContainsKey('ClaudeUsage') -and
        $script:pollJobs['ClaudeUsage'].State -in @('Running', 'NotStarted')) { return }
    $script:ClaudeCredentialStamp = $stamp
    Start-AllRefreshJobs -Force -Kind @('ClaudeUsage')
})

# Tick timer: refreshes reset countdowns/clock every 30s (render only, no I/O,
# no layout Measure - Resize-ToContent is intentionally NOT in this path).
$script:tickTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:tickTimer.Interval = [TimeSpan]::FromSeconds(30)
$script:tickTimer.add_Tick({ Update-OverlayViews })


function Show-UnifiedWindowWhenRendered {
    Resize-ToContent
    $script:window.Opacity = 0
    $script:window.add_ContentRendered({
        $opacity = 1.0
        if ($script:Cfg -and $script:Cfg.ContainsKey('Opacity') -and $null -ne $script:Cfg.Opacity) {
            $opacity = [double]$script:Cfg.Opacity
        }
        $script:window.Opacity = $opacity
    })
    $script:window.Show()
    Resize-ToContent
    if (Test-IslandMode) {
        Position-IslandWindow
    } elseif (-not $script:Positioned) {
        Position-Window
    } else {
        Clamp-Position
    }
}

# Build-And-Show: retry window Show() until the DWM compositor is ready.
# At login the Startup-folder shortcut can fire before the desktop is fully
# initialised, causing WPF's SetRootVisual to fail with "VisualTarget cannot
# have a parent". The error is transient; recreating the window and retrying
# is the correct fix. Backoff: 250 ms, 500 ms, 1 s, 2 s, 4 s x3 (~16 s total).
function Build-And-Show {
    $maxAttempts = 8
    for ($i = 1; $i -le $maxAttempts; $i++) {
        if ($i -gt 1) {
            # Discard the bad window state and create a fresh one.
            $script:Positioned = $false
            $script:window = [System.Windows.Markup.XamlReader]::Parse($xaml)
            Initialize-IslandView
            Update-OverlayViews
            Apply-UnifiedSettings
            Restore-UnifiedSections
            Resize-ToContent
        }
        Wire-UnifiedWindowEvents
        try {
            # Dropdown mode starts parked off-screen: the hotkey brings it in, so
            # there is no window to show at startup.
            if (Test-DropdownMode) {
                Apply-DropdownChrome
                Register-DropdownHotkey | Out-Null
            } elseif (-not $Hidden -and -not [bool]$script:Cfg.StartHidden) {
                Show-UnifiedWindowWhenRendered
            }
            return $true
        } catch {
            if ($_.Exception.Message -notmatch 'VisualTarget') { throw }
            $delay = [math]::Min(4000, [int](250 * [math]::Pow(2, $i - 1)))
            Write-Log "Show() attempt $i/$maxAttempts failed (compositor not ready); retrying in ${delay}ms..."
            Start-Sleep -Milliseconds $delay
        }
    }
    return $false
}

if (-not (Build-And-Show)) {
    Write-Log 'Unified overlay failed to start after all attempts; compositor never became ready.'
    return
}

$script:pollTimer.Start()
$script:jobTimer.Start()
$script:tickTimer.Start()
$script:credentialTimer.Start()

# Let WPF paint the notch before starting process jobs and network work.
[void]$script:window.Dispatcher.BeginInvoke(
    [System.Windows.Threading.DispatcherPriority]::Background,
    [Action]{ Start-AllRefreshJobs -UsageTimeoutSec 8 })

# Write PID file so Uninstall.bat can terminate the process.
try { [System.IO.File]::WriteAllText($script:PidPath, "$PID") } catch { }

# An exception thrown inside a timer tick or event handler surfaces as an opaque
# 'Exception calling "Run"' with only this line in the stack. Log the real
# exception and its stack before it unwinds, so UI-thread faults are diagnosable.
try {
    $script:window.Dispatcher.Add_UnhandledException({
        param($s, $e)
        try {
            Write-Log ("Dispatcher exception: {0}`n{1}" -f $e.Exception.Message, $e.Exception.StackTrace)
        } catch { }
    })
} catch { }

[System.Windows.Threading.Dispatcher]::Run()

try { Remove-Item $script:PidPath -ErrorAction SilentlyContinue } catch { }

}
catch {
    $msg = "[{0}] {1}`n{2}" -f (Get-Date -Format 's'), $_.Exception.Message, $_.ScriptStackTrace
    try { Add-Content -Path $script:ErrLog -Value $msg -Encoding UTF8 } catch { }
    throw
}
