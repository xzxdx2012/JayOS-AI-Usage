# InstallManifest.ps1 - files the installer copies into the per-user install dir.

function Get-OverlayInstallRequiredRelativePaths {
    @(
        'unified-overlay.ps1'
        'Start-Unified.vbs'
        'sqlite3.exe'
        'README.md'
        'src\*.ps1'
    )
}

function Get-OverlayInstallCopyItems {
    @(
        [pscustomobject]@{ Relative = 'unified-overlay.ps1'; Optional = $false; Recurse = $false; Contents = $false }
        [pscustomobject]@{ Relative = 'Start-Unified.vbs';   Optional = $false; Recurse = $false; Contents = $false }
        [pscustomobject]@{ Relative = 'Install.bat';         Optional = $true;  Recurse = $false; Contents = $false }
        [pscustomobject]@{ Relative = 'Uninstall.bat';       Optional = $true;  Recurse = $false; Contents = $false }
        [pscustomobject]@{ Relative = 'Setup.ps1';           Optional = $true;  Recurse = $false; Contents = $false }
        [pscustomobject]@{ Relative = 'Setup.vbs';           Optional = $true;  Recurse = $false; Contents = $false }
        [pscustomobject]@{ Relative = 'sqlite3.exe';         Optional = $false; Recurse = $false; Contents = $false }
        [pscustomobject]@{ Relative = 'LICENSE';             Optional = $true;  Recurse = $false; Contents = $false }
        [pscustomobject]@{ Relative = 'README.md';           Optional = $false; Recurse = $false; Contents = $false }
        [pscustomobject]@{ Relative = 'src';                 Optional = $false; Recurse = $true;  Contents = $true  }
        [pscustomobject]@{ Relative = 'assets';              Optional = $true;  Recurse = $true;  Contents = $false }
        [pscustomobject]@{ Relative = 'icons';               Optional = $true;  Recurse = $true;  Contents = $false }
        [pscustomobject]@{ Relative = 'docs';                Optional = $true;  Recurse = $true;  Contents = $false }
    )
}

function Copy-OverlayInstallFiles {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DestRoot
    )

    if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
        throw "Install source is missing: $SourceRoot"
    }

    [void](New-Item -ItemType Directory -Force -Path $DestRoot)

    foreach ($item in Get-OverlayInstallCopyItems) {
        $from = Join-Path $SourceRoot $item.Relative
        if (-not (Test-Path -LiteralPath $from)) {
            if ([bool]$item.Optional) { continue }
            throw "Missing required install file: $($item.Relative)"
        }

        $to = Join-Path $DestRoot $item.Relative
        if ([bool]$item.Contents) {
            [void](New-Item -ItemType Directory -Force -Path $to)
            Copy-Item -Path (Join-Path $from '*') -Destination $to -Recurse -Force
        } else {
            $parent = Split-Path -Parent $to
            if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
                [void](New-Item -ItemType Directory -Force -Path $parent)
            }
            Copy-Item -LiteralPath $from -Destination $to -Recurse:([bool]$item.Recurse) -Force
        }
    }
}
