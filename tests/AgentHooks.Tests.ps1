# AgentHooks.Tests.ps1 - "AI requests in the notch" hook registration.
#
# Checks that the Claude Code (settings.json) and Codex (hooks.json) hook
# entries are added, kept idempotent, removed again, and that hooks the user
# already had are left alone. Works on Windows PowerShell 5.1 and PowerShell 7;
# uses a throwaway home folder, never the real ~/.claude or ~/.codex.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path $PSScriptRoot ('jayos-hooks-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $tmp '.codex') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $tmp '.claude') -Force | Out-Null

$savedProfile = $env:USERPROFILE; $savedCodex = $env:CODEX_HOME; $savedClaude = $env:CLAUDE_CONFIG_DIR
$failures = 0
function Assert([bool]$Cond, [string]$What) {
    if ($Cond) { Write-Host "  ok   $What" } else { Write-Host "  FAIL $What" -ForegroundColor Red; $script:failures++ }
}

try {
    $env:USERPROFILE = $tmp
    Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
    Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
    $script:AppDir = 'C:\Program Files\Jay OS\AIUsageOverlay'
    $script:I18nText = @{}; $script:I18nRules = @()
    function Write-Log($m) { }
    . (Join-Path $root 'src\Requests.ps1')

    $codexPath = Join-Path $tmp '.codex\hooks.json'
    $claudePath = Join-Path $tmp '.claude\settings.json'
    [IO.File]::WriteAllText($codexPath, '{"hooks":{"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"python3 log.py"}]}],"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}')
    [IO.File]::WriteAllText($claudePath, '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo bye"}]}]}}')

    Write-Host 'Codex hooks.json'
    [void](Set-CodexRequestHooks $true); [void](Set-CodexRequestHooks $true)
    $j = Get-Content -LiteralPath $codexPath -Raw | ConvertFrom-Json
    $pr = @($j.hooks.PermissionRequest)
    Assert ($pr.Count -eq 1) 'one PermissionRequest group after enabling twice'
    Assert ($null -eq $pr[0].matcher) 'no matcher (Codex: every tool)'
    $h = @($pr[0].hooks)[0]
    Assert ([string]$h.command -like '*ClaudeHook.ps1" -Agent codex') 'command calls the hook with -Agent codex'
    Assert ([string]$h.commandWindows -eq [string]$h.command) 'commandWindows set'
    Assert ([int]$h.timeout -eq 600) 'PermissionRequest timeout 600 s'
    Assert ([string]$h.command -notmatch '^"') 'powershell.exe not quoted (works from cmd and PowerShell)'
    Assert ([string]$h.command -match '-File "C:/Program Files/Jay OS/AIUsageOverlay/hooks/ClaudeHook.ps1"') 'script path quoted (spaces)'
    Assert (@($j.hooks.Stop).Count -eq 2) 'Stop: user hook kept + ours'
    Assert (@($j.hooks.PostToolUse).Count -eq 1) 'PostToolUse user hook kept'
    Assert (Test-Path -LiteralPath ($codexPath + '.jayos-backup')) 'backup written'
    [void](Set-CodexRequestHooks $false)
    $j = Get-Content -LiteralPath $codexPath -Raw | ConvertFrom-Json
    Assert ($null -eq $j.hooks.PermissionRequest) 'PermissionRequest removed when off'
    Assert (@($j.hooks.Stop).Count -eq 1 -and [string]@($j.hooks.Stop)[0].hooks[0].command -eq 'say done') 'only the user Stop hook left'

    Write-Host 'Claude settings.json'
    [void](Set-ClaudeRequestHooks $true); [void](Set-ClaudeRequestHooks $true)
    $c = Get-Content -LiteralPath $claudePath -Raw | ConvertFrom-Json
    Assert ([string]$c.model -eq 'opus') 'other settings kept'
    Assert (@($c.hooks.PermissionRequest).Count -eq 1 -and [string]@($c.hooks.PermissionRequest)[0].matcher -eq '*') 'PermissionRequest matcher *'
    Assert ([string]@($c.hooks.PermissionRequest)[0].hooks[0].command -notlike '*-Agent*') 'Claude command has no -Agent'
    Assert (@($c.hooks.Stop).Count -eq 2) 'Stop: user hook kept + ours'
    [void](Set-ClaudeRequestHooks $false)
    $c = Get-Content -LiteralPath $claudePath -Raw | ConvertFrom-Json
    Assert ($null -eq $c.hooks.PermissionRequest -and @($c.hooks.Stop).Count -eq 1) 'Claude hooks removed when off'

    Write-Host 'Codex not installed'
    Remove-Item -LiteralPath (Join-Path $tmp '.codex') -Recurse -Force
    Assert (-not (Set-CodexRequestHooks $true)) 'returns false'
    Assert (-not (Test-Path -LiteralPath (Join-Path $tmp '.codex'))) 'does not create ~/.codex'
} finally {
    $env:USERPROFILE = $savedProfile
    if ($savedCodex) { $env:CODEX_HOME = $savedCodex }
    if ($savedClaude) { $env:CLAUDE_CONFIG_DIR = $savedClaude }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host ("Agent hook tests passed on PowerShell {0}." -f $PSVersionTable.PSVersion)
