# Native Windows build. Only version-controlled application files enter payload.zip.
param(
    [string]$Version = '0.0.3-beta',
    [string]$GoExe = 'go',
    [string]$RsrcExe = 'rsrc',
    [string]$OutputDirectory = $PSScriptRoot
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[void](New-Item -ItemType Directory -Force $OutputDirectory)
$stage = Join-Path (Join-Path $PSScriptRoot '.stage') ([guid]::NewGuid().ToString('N'))
$app = Join-Path $stage 'JayOS-AI-Usage'
[void](New-Item -ItemType Directory -Force $app)
foreach ($file in @('unified-overlay.ps1','Start-Unified.vbs','Setup.ps1','Setup.vbs','Install.bat','Uninstall.bat','sqlite3.exe','LICENSE','README.md')) {
    Copy-Item -LiteralPath (Join-Path $root $file) -Destination $app
}
foreach ($dir in @('src','icons','assets','hooks')) {
    Copy-Item -LiteralPath (Join-Path $root $dir) -Destination $app -Recurse
}
# Require the permission hook: earlier build.sh accidentally omitted hooks/.
if (-not (Test-Path (Join-Path $app 'hooks\ClaudeHook.ps1'))) { throw 'Missing permission hook' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$payload = Join-Path $PSScriptRoot 'payload.zip'
if (Test-Path -LiteralPath $payload) { Remove-Item -LiteralPath $payload }
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $payload, [IO.Compression.CompressionLevel]::Optimal, $false)
$zip = Join-Path $OutputDirectory "JayOS-AI-Usage-$Version.zip"
Copy-Item -LiteralPath $payload -Destination $zip -Force
$exe = Join-Path $OutputDirectory "JayOS-AI-Usage-Setup-$Version.exe"
Push-Location $PSScriptRoot
$oldOs=$env:GOOS; $oldArch=$env:GOARCH; $oldCgo=$env:CGO_ENABLED
try {
    & $RsrcExe -manifest app.manifest -ico ../assets/ai-usage-overlay.ico -arch amd64 -o rsrc_windows_amd64.syso
    if ($LASTEXITCODE -ne 0) { throw 'Resource compilation failed' }
    $env:GOOS='windows'; $env:GOARCH='amd64'; $env:CGO_ENABLED='0'
    & $GoExe test ./...
    if ($LASTEXITCODE -ne 0) { throw 'Installer tests failed' }
    & $GoExe build -trimpath -ldflags '-H windowsgui -s -w' -o $exe .
    if ($LASTEXITCODE -ne 0) { throw 'Installer build failed' }
} finally {
    $env:GOOS=$oldOs; $env:GOARCH=$oldArch; $env:CGO_ENABLED=$oldCgo
    Pop-Location
}
Get-FileHash -Algorithm SHA256 -LiteralPath $exe,$zip | ForEach-Object {
    '{0}  {1}' -f $_.Hash.ToLowerInvariant(), [IO.Path]::GetFileName($_.Path)
} | Set-Content -Encoding Ascii (Join-Path $OutputDirectory 'SHA256SUMS.txt')
Write-Output "Built $exe"
Write-Output "Built $zip"
