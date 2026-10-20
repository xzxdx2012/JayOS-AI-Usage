# No credentials, live overlay, or WPF required. Exercise the actual source functions.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$file = Join-Path (Join-Path $root 'src') 'UnifiedTray.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
foreach ($name in @('Sync-NotchWindowHeight', 'Start-NotchRendering')) {
    $fn = $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]}, $true) |
        Where-Object { $_.Name -eq $name } | Select-Object -First 1
    . ([scriptblock]::Create($fn.Extent.Text))
}
$script:count = 0
function Assert($Value, [string]$Name) {
    if (-not $Value) { throw "FAILED: $Name" }
    $script:count++; Write-Output "PASS: $Name"
}
$script:shell = $true
function Test-NotchShell { return $script:shell }
$script:NotchSpec = @{ StagePadBottom = 12.0 }
$script:NotchStage = @{ PanelH = 340.0 }
$script:window = [pscustomobject]@{ Height = 352.0 }
$script:NotchBackdrop = [pscustomobject]@{ Repaints = 0 }
$script:NotchBackdrop | Add-Member ScriptMethod InvalidateVisual { $this.Repaints++ }
$script:NV = @{ h = 5.0 }
$script:NTracks = @{}
$script:NotchTransition = $null
$script:NotchRendering = $false
$script:NotchState = 'EDGE'
Sync-NotchWindowHeight
Assert ($script:window.Height -eq 5.0) 'idle EDGE HWND is 5 DIPs, not panel height'
Assert ($script:NotchBackdrop.Repaints -eq 1) 'shrinking invalidates layered backdrop'
Sync-NotchWindowHeight
Assert ($script:NotchBackdrop.Repaints -eq 1) 'idle sync is idempotent'
$script:NotchStage.PanelH = 600.0
Sync-NotchWindowHeight
Assert ($script:window.Height -eq 5.0) 'background content refresh does not reopen transparent bottom'
Sync-NotchWindowHeight -ForMotion
Assert ($script:window.Height -eq 612.0) 'animation surface is restored before motion'
$script:NotchRendering = $true
$script:NV.h = 32.0
Sync-NotchWindowHeight
Assert ($script:window.Height -eq 612.0) 'rendering never shrinks the native surface'
$script:NotchRendering = $false
$script:NTracks.h = @{ To = 600.0 }
Sync-NotchWindowHeight
Assert ($script:window.Height -eq 612.0) 'pending track prevents premature shrink'
$script:NTracks.Clear()
$script:NotchTransition = @{ End = 100 }
Sync-NotchWindowHeight
Assert ($script:window.Height -eq 612.0) 'pending completion prevents premature shrink'
$script:NotchTransition = $null
foreach ($state in @('NOTCH', 'HOLD')) {
    $script:NotchState = $state
    Sync-NotchWindowHeight
    Assert ($script:window.Height -eq 32.0) "$state settles to visible notch height"
}
$script:NotchState = 'EXPANDED'; $script:NV.h = 600.0
Sync-NotchWindowHeight
Assert ($script:window.Height -eq 600.0) 'expanded panel is not clipped'
$script:NV.h = 700.2; $script:NotchRendering = $true
Sync-NotchWindowHeight
Assert ($script:window.Height -eq 713.0) 'reversing a taller morph keeps current pixels inside surface'
$script:NotchRendering = $false
$script:NV.h = 31.2
Sync-NotchWindowHeight
Assert ($script:window.Height -eq 32.0) 'fractional DIP height rounds upward'
$script:shell = $false; $script:window.Height = 800.0
Sync-NotchWindowHeight
Assert ($script:window.Height -eq 800.0) 'Quake mode owns its own geometry'
$script:shell = $true; $script:NotchState = 'SUSPENDED'
Sync-NotchWindowHeight
Assert ($script:window.Height -eq 800.0) 'queued settle cannot resize suspended shell'
# Call-order regression: reserve before registering CompositionTarget.Rendering.
$start = $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-NotchRendering'}, $true)[0].Extent.Text
Assert ($start.IndexOf('Sync-NotchWindowHeight -ForMotion') -lt $start.IndexOf('::add_Rendering')) 'surface grows before first Rendering callback'
$stop = $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Stop-NotchRendering'}, $true)[0].Extent.Text
Assert ($stop.Contains('BeginInvoke') -and $stop.Contains('Sync-NotchWindowHeight')) 'settle stays deferred outside Rendering callback'
$rest = $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-NotchRest'}, $true)[0].Extent.Text
Assert ($rest.Contains('Sync-NotchWindowHeight')) 'startup and mode switch trim idle HWND too'
Write-Output "$script:count tests passed"
