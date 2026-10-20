$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:count = 0
function Assert($Value, [string]$Name) {
    if (-not $Value) { throw "FAILED: $Name" }
    $script:count++; Write-Output "PASS: $Name"
}
$fixture = Join-Path $PSScriptRoot ('.default-settings-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $fixture)
try {
    $script:window = $null
    $script:StatePath = Join-Path $fixture 'state.json'
    $script:Cfg = @{}
    . (Join-Path $root 'src/ProviderPicker.ps1')
    . (Join-Path $root 'src/UnifiedState.ps1')
    $script:Cfg.Theme='Gold'; $script:Cfg.Language='zh'; $script:Cfg.DeveloperFeatures=$true
    $script:Cfg.ShowRemaining=$false; $script:Cfg.Opacity=0.6; $script:Cfg.ViewMode='Quake'
    $script:Cfg.ToggleOverlayHotkey='Ctrl+Alt+Y'
    $script:Cfg.Sections=@{claude=$true;codex=$false;cursor=$true;grok=$true}
    $script:Cfg.CodexCreditPeak=1500.0; $script:Cfg.CodexCreditLast=1200.0; $script:Cfg.CodexCreditEpoch='2026-10-20T12:00:00Z'
    $script:Cfg.AiRequests=$true
    Write-StateJsonAtomic $script:StatePath $script:Cfg
    $before=[IO.File]::ReadAllText($script:StatePath)
    foreach($name in @('fixture-auth.json','usage-cache.json','overlay-history.json','startup.lnk','desktop.lnk')) {
        [IO.File]::WriteAllText((Join-Path $fixture $name), 'fixture-only-do-not-modify')
    }
    $script:hookCalls=@();$script:watcherStopped=0
    function Update-AllRequestHooks([bool]$On) { $script:hookCalls+= $On; return ,@() }
    function Stop-RequestWatcher { $script:watcherStopped++ }
    $backup=Reset-UnifiedPreferences
    Assert ((Test-Path -LiteralPath $backup) -and [IO.File]::ReadAllText($backup) -eq $before) 'reset backs up the complete previous settings first'
    Assert ($script:Cfg.Theme -eq 'Graphite' -and $script:Cfg.PanelBg -eq '#1A1A1E') 'appearance returns to factory defaults'
    Assert ($script:Cfg.Language -eq 'en' -and $script:Cfg.Opacity -eq 1.0) 'default language and opacity restored'
    Assert (-not (Test-DeveloperFeaturesEnabled)) 'experimental providers are opt-in again after reset'
    Assert ($script:Cfg.ShowRemaining) 'remaining display returns to default'
    Assert ($script:Cfg.ViewMode -eq 'Pinned' -and $null -eq $script:Cfg.Left -and $null -eq $script:Cfg.Top) 'view and saved position reset'
    Assert ($script:Cfg.ToggleOverlayHotkey -eq '' -and $script:Cfg.RefreshHotkey -eq '') 'custom global hotkeys return to unbound'
    Assert ($script:Cfg.Sections.codex -and -not $script:Cfg.Sections.claude) 'provider preferences return to documented defaults'
    Assert ($script:Cfg.CodexCreditPeak -eq 1500 -and $script:Cfg.CodexCreditLast -eq 1200) 'credit observations are preserved as data, not reset as preferences'
    Assert ($script:Cfg.CodexCreditEpoch -eq '2026-10-20T12:00:00Z') 'credit epoch is preserved'
    Assert (-not $script:Cfg.AiRequests -and $script:hookCalls.Count -eq 1 -and -not $script:hookCalls[0]) 'reset removes enabled app request hooks without granting permission'
    Assert ($script:watcherStopped -eq 1) 'request watcher is stopped after successful reset'
    foreach($name in @('fixture-auth.json','usage-cache.json','overlay-history.json','startup.lnk','desktop.lnk')) {
        Assert ([IO.File]::ReadAllText((Join-Path $fixture $name)) -eq 'fixture-only-do-not-modify') "reset preserves $name"
    }
    $saved=Read-StateJson $script:StatePath
    Assert ($saved.Theme -eq 'Graphite' -and -not $saved.DeveloperFeatures) 'defaults are persisted atomically'
    $script:Cfg.AlertState['changed']=$true
    Assert ($script:UnifiedCfgDefaults.AlertState.Count -eq 0) 'reset does not share mutable default maps'

    # A failed write must leave both the in-memory settings and file intact.
    $script:Cfg.Theme='Custom';$script:Cfg.AiRequests=$true
    Write-StateJsonAtomic $script:StatePath $script:Cfg
    $before=[IO.File]::ReadAllText($script:StatePath);$oldCfg=$script:Cfg
    $script:hookCalls=@()
    function Write-StateJsonAtomic { throw 'simulated write failure' }
    $thrown=$false
    try { Reset-UnifiedPreferences | Out-Null } catch { $thrown=$true }
    Assert $thrown 'write failure is reported to confirmation UI'
    Assert ([object]::ReferenceEquals($oldCfg,$script:Cfg) -and [IO.File]::ReadAllText($script:StatePath) -eq $before) 'write failure retains previous live and saved preferences'
    Assert ($script:hookCalls.Count -eq 2 -and -not $script:hookCalls[0] -and $script:hookCalls[1]) 'failed reset restores previously enabled request hooks'
    . (Join-Path $root 'src/StateFile.ps1')
    function Update-AllRequestHooks([bool]$On) { $script:hookCalls+=$On; if(-not $On){return ,@('fixture hook failure')};return ,@() }
    $thrown=$false
    try { Reset-UnifiedPreferences | Out-Null } catch {$thrown=$true}
    Assert ($thrown -and [object]::ReferenceEquals($oldCfg,$script:Cfg)) 'partial hook removal aborts reset instead of persisting misleading defaults'

    $setup=[IO.File]::ReadAllText((Join-Path $root 'Setup.ps1'))
    Assert ($setup -match 'x:Name="desktopBox"[^\r\n]*IsChecked="False"') 'wizard desktop shortcut is off by default'
    Assert ($setup -match 'x:Name="autostartBox"[^\r\n]*IsChecked="True"') 'wizard Windows autostart remains on by default'
    Assert ($setup -match '\$desktop = if \(\$existing\) \{ Test-Path -LiteralPath \$DesktopLnk \} else \{ \$false \}') 'silent fresh install also defaults desktop shortcut off and preserves upgrade choices'
    $tray=[IO.File]::ReadAllText((Join-Path $root 'src/UnifiedTray.ps1'))
    Assert ($tray -match 'MessageBoxDefaultButton\]::Button2') 'restore confirmation defaults to No'
    Assert ($tray.Contains("@('Restore default settings', 'IcoGear')")) 'restore command is placed in the System settings group'
    Write-Output "$script:count tests passed"
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture)
    if(-not $resolved.StartsWith(([IO.Path]::GetFullPath($PSScriptRoot)+[IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup path'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
