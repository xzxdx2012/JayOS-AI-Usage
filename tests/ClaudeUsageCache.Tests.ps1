$ErrorActionPreference = 'Stop'

$script:AppDir = Join-Path $PSScriptRoot '.claude-cache-test'
$script:ErrLog = Join-Path $script:AppDir 'errors.log'
New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Data.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\History.ps1')

try {
    $data = [pscustomobject]@{
        five_hour = [pscustomobject]@{ utilization = 42.0; resets_at = '2026-10-04T00:00:00Z' }
        seven_day = [pscustomobject]@{ utilization = 63.0; resets_at = '2026-10-05T00:00:00Z' }
    }
    Save-ClaudeUsageCache $data
    $loaded = Get-CachedClaudeUsage
    if (-not $loaded -or $loaded.Data.five_hour.utilization -ne 42 -or -not $loaded.AsOf) {
        throw 'Recent Claude usage was not restored.'
    }

    $jobs = 1..4 | ForEach-Object {
        Start-Job -ScriptBlock {
            param($root, $source)
            $script:AppDir = $root
            $script:ErrLog = Join-Path $root 'errors.log'
            . $source
            Save-ClaudeUsageCache ([pscustomobject]@{
                five_hour = [pscustomobject]@{ utilization = 42.0 }
                seven_day = [pscustomobject]@{ utilization = 63.0 }
            })
        } -ArgumentList $script:AppDir, (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Data.ps1')
    }
    try {
        $jobs | Wait-Job | Out-Null
        $jobs | Receive-Job -ErrorAction Stop | Out-Null
        $loaded = Get-CachedClaudeUsage
        if (-not $loaded -or $loaded.Data.five_hour.utilization -ne 42) {
            throw 'Concurrent Claude usage saves did not leave a valid cache.'
        }
        if ((Test-Path -LiteralPath $script:ErrLog) -and
            (Select-String -LiteralPath $script:ErrLog -Pattern 'Claude usage cache save failed' -Quiet)) {
            throw "Concurrent Claude usage saves logged an error: $(Get-Content -LiteralPath $script:ErrLog -Raw)"
        }
    } finally {
        $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
    }

    $cachePath = Get-ClaudeUsageCachePath
    $saved = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
    $saved.FetchedAt = [System.DateTimeOffset]::Now.AddHours(-25).ToString('o')
    $saved | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $cachePath -Encoding UTF8
    if (Get-CachedClaudeUsage) { throw 'Expired Claude usage was restored.' }

    Set-Content -LiteralPath $cachePath -Value '{broken' -Encoding UTF8
    if (Get-CachedClaudeUsage) { throw 'Malformed Claude usage was restored.' }

    $script:History.Add([pscustomobject]@{
        t = [System.DateTimeOffset]::Now.AddHours(-2).ToString('o')
        five_hour = 0.0
        seven_day = 63.0
    })
    $fromHistory = Get-RecentClaudeUsageFromHistory
    if (-not $fromHistory -or $fromHistory.Data.five_hour.utilization -ne 0 -or
        $fromHistory.Data.seven_day.utilization -ne 63) {
        throw 'Recent history did not provide last known Claude usage.'
    }
    $script:History.Clear()
    $script:History.Add([pscustomobject]@{
        t = [System.DateTimeOffset]::Now.AddHours(-25).ToString('o')
        five_hour = 42.0
        seven_day = 63.0
    })
    if (Get-RecentClaudeUsageFromHistory) { throw 'Expired history was restored.' }

    'Claude usage cache tests passed on PowerShell {0}.' -f $PSVersionTable.PSVersion
} finally {
    foreach ($name in 'claude-usage-cache.json', 'errors.log') {
        Remove-Item -LiteralPath (Join-Path $script:AppDir $name) -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem -LiteralPath $script:AppDir -Filter 'claude-usage-cache.*.tmp' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:AppDir -Force -ErrorAction SilentlyContinue
}
