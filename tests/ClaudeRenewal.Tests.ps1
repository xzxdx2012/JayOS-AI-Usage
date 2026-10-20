$ErrorActionPreference = 'Stop'

$script:AppDir = Join-Path $PSScriptRoot '.claude-renewal-test'
$script:CredPath = Join-Path $script:AppDir '.credentials.json'
$script:ErrLog = Join-Path $script:AppDir 'errors.log'
$script:UA = 'claude-code/test'
New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Data.ps1')

function Get-WslHomeRoots { @() }

try {
    $expired = [System.DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
    @{ claudeAiOauth = @{ accessToken = 'old-access'; refreshToken = 'old-refresh'; expiresAt = $expired } } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:CredPath -Encoding UTF8

    # Expired access token + refresh token: Claude Code is asked to renew it
    # (a hidden one-line `claude -p` run), and the panel keeps "signed in".
    $script:Started = @()
    function Resolve-ClaudeCliExecutable { 'C:\Tools\claude.exe' }
    function Start-Process { param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle) $script:Started += ,@($FilePath, [string]$ArgumentList) }
    $script:State = @{ Data = $null; Status = 'init'; LastFetch = ''; Message = '' }
    Get-Usage -TimeoutSec 1
    if ($script:State.Status -ne 'idle') { throw "Expected 'idle' while renewing, got '$($script:State.Status)'." }
    $launch = ($script:Started | ForEach-Object { $_ -join ' ' }) -join ' | '
    if ($script:Started.Count -ne 1 -or $launch -notmatch 'claude\.exe' -or
        $launch -notmatch '-p "Reply with OK\." --model haiku --max-turns 1 --no-session-persistence') {
        throw 'Claude Code was not started to renew the sign-in.'
    }

    # A second poll right away waits instead of starting Claude Code again.
    Get-Usage -TimeoutSec 1
    if ($script:Started.Count -ne 1 -or $script:State.Status -ne 'idle') { throw 'Renewal was retried too soon.' }

    # After the last allowed try, a real sign-in is asked for.
    @{ Tries = $script:ClaudeCliRenewalMaxTries; Last = (Get-Date).AddHours(-2).ToString('o') } | ConvertTo-Json |
        Set-Content -LiteralPath (Get-ClaudeCliRenewalPath) -Encoding UTF8
    Get-Usage -TimeoutSec 1
    if ($script:State.Status -ne 'auth' -or $script:State.Message -notmatch 'sign in') {
        throw 'Expired Claude credentials did not request reconnection after the renewal tries.'
    }

    # Without Claude Code installed there is nothing to renew with.
    Clear-ClaudeCliRenewal
    function Resolve-ClaudeCliExecutable { $null }
    Get-Usage -TimeoutSec 1
    if ($script:State.Status -ne 'auth') { throw 'Missing Claude Code did not request sign-in.' }
    Remove-Item Function:\Start-Process, Function:\Resolve-ClaudeCliExecutable -ErrorAction SilentlyContinue

    $mainPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'unified-overlay.ps1'
    $tokens = $null; $parseErrors = $null
    $mainAst = [System.Management.Automation.Language.Parser]::ParseFile($mainPath, [ref]$tokens, [ref]$parseErrors)
    foreach ($name in 'Set-ClaudeUsageStateValue', 'Resolve-ClaudeUsageState') {
        $node = $mainAst.Find({ param($ast) $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $ast.Name -eq $name }, $true)
        if (-not $node) { throw "Missing $name in overlay entry point." }
        . ([scriptblock]::Create($node.Extent.Text))
    }
    $recent = @{ Data = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 42.0 } }; DataAsOf = (Get-Date).AddMinutes(-10).ToString('yyyy-MM-dd HH:mm'); LastFetch = '' }
    $missing = @{ Data = $null; Status = 'auth'; LastFetch = ''; Message = '' }
    $merged = Resolve-ClaudeUsageState $recent $missing
    if (-not $merged.Stale -or $merged.Data.five_hour.utilization -ne 42) {
        throw 'Recent Claude usage was not retained after a failed refresh.'
    }
    $recent.DataAsOf = (Get-Date).AddHours(-25).ToString('yyyy-MM-dd HH:mm')
    $merged = Resolve-ClaudeUsageState $recent @{ Data = $null; Status = 'auth'; LastFetch = ''; Message = '' }
    if ($merged.Data -or $merged.Stale) { throw 'Expired Claude usage remained on screen.' }

    'Claude renewal tests passed on PowerShell {0}.' -f $PSVersionTable.PSVersion
} finally {
    foreach ($name in '.credentials.json', 'claude-cli-renewal.json', 'claude-credential-preference.json', 'claude-backoff.json', 'claude-profile.json', 'errors.log') {
        Remove-Item -LiteralPath (Join-Path $script:AppDir $name) -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $script:AppDir -Force -ErrorAction SilentlyContinue
}
