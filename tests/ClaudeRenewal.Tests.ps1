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

    function Invoke-RestMethod {
        param($Method, $Uri, $ContentType, $Body, $TimeoutSec, [switch]$UseBasicParsing, $UserAgent)
        if ($Method -ne 'Post' -or $Uri -ne $script:ClaudeOAuthTokenUrl -or
            $ContentType -ne 'application/x-www-form-urlencoded' -or
            $Body.grant_type -ne 'refresh_token' -or $Body.refresh_token -ne 'old-refresh' -or
            $Body.client_id -ne $script:ClaudeOAuthClientId -or $Body.ContainsKey('scope')) {
            throw 'OAuth refresh did not use the expected form fields.'
        }
        return [pscustomobject]@{ access_token = 'new-access'; refresh_token = 'new-refresh'; expires_in = 3600 }
    }

    if (-not (Invoke-ClaudeTokenRefresh @($script:CredPath))) { throw 'OAuth refresh did not report success.' }
    $updated = (Get-Content -LiteralPath $script:CredPath -Raw | ConvertFrom-Json).claudeAiOauth
    if ($updated.accessToken -ne 'new-access' -or $updated.refreshToken -ne 'new-refresh' -or
        [long]$updated.expiresAt -le [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) {
        throw 'OAuth refresh did not save the rotated credentials.'
    }

    $updated.expiresAt = $expired
    @{ claudeAiOauth = $updated } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:CredPath -Encoding UTF8
    function Invoke-ClaudeTokenRefresh { return $false }
    $script:State = @{ Data = $null; Status = 'init'; LastFetch = ''; Message = '' }
    Get-Usage -TimeoutSec 1
    if ($script:State.Status -ne 'auth' -or $script:State.Message -notmatch 'sign in') {
        throw 'Expired Claude credentials did not request reconnection.'
    }

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
    foreach ($name in '.credentials.json', '.credentials.json.jayos-tmp', 'claude-token-refresh.txt', 'claude-credential-preference.json', 'errors.log') {
        Remove-Item -LiteralPath (Join-Path $script:AppDir $name) -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $script:AppDir -Force -ErrorAction SilentlyContinue
}
