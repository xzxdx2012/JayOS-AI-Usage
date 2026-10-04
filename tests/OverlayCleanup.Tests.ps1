$ErrorActionPreference = 'Stop'

$script:AppDir = Join-Path $PSScriptRoot '.overlay-cleanup-test'
if (Test-Path -LiteralPath $script:AppDir) { throw 'Cleanup test directory already exists.' }
New-Item -ItemType Directory -Path $script:AppDir | Out-Null
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Data.ps1')

try {
    $oldNames = @(
        'claude-usage-cache.json.tmp',
        'claude-usage-cache.json.0123456789abcdef0123456789abcdef.bak',
        'unified-overlay-error.log.1'
    )
    $keepNames = @(
        'claude-usage-cache.json',
        'claude-usage-cache.json.abcdef0123456789abcdef0123456789.tmp',
        'unified-overlay-error.log',
        'unrelated.bak'
    )
    foreach ($name in $oldNames + $keepNames) {
        $path = Join-Path $script:AppDir $name
        [System.IO.File]::WriteAllText($path, 'test')
        if ($oldNames -contains $name -or $name -eq 'unrelated.bak') {
            [System.IO.File]::SetLastWriteTimeUtc($path, [DateTime]::UtcNow.AddDays(-2))
        }
    }

    Remove-StaleOverlayArtifacts
    foreach ($name in $oldNames) {
        if (Test-Path -LiteralPath (Join-Path $script:AppDir $name)) { throw "Old artifact survived: $name" }
    }
    foreach ($name in $keepNames) {
        if (-not (Test-Path -LiteralPath (Join-Path $script:AppDir $name))) { throw "Important file removed: $name" }
    }
    'Overlay cleanup tests passed on PowerShell {0}.' -f $PSVersionTable.PSVersion
} finally {
    Get-ChildItem -LiteralPath $script:AppDir -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:AppDir -Force -ErrorAction SilentlyContinue
}
