$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:count = 0
function Assert($Value, [string]$Name) {
    if (-not $Value) { throw "FAILED: $Name" }
    $script:count++; Write-Output "PASS: $Name"
}

$fixture = Join-Path $PSScriptRoot ('.release-providers-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $fixture)
try {
    $script:Cfg = @{}
    $script:window = $null
    $script:StatePath = Join-Path $fixture 'state.json'
    function Write-Log { }
    . (Join-Path $root 'src/UnifiedState.ps1')

    Assert (Test-DeveloperFeaturesEnabled) 'legacy developer gate is permanently enabled for compatibility'
    Assert (((Get-AvailableProviderKeys) -join ',') -eq 'deepseek,claude,codex,cursor') 'Grok Bot is retired from the supported provider list'
    $script:Cfg.DeveloperFeatures = $false
    Initialize-UnifiedCfg
    Assert ($script:Cfg.DeveloperFeatures -and (Test-ProviderAvailable 'cursor') -and -not (Test-ProviderAvailable 'grok')) 'old profiles keep Cursor while Grok Bot stays retired'

    $tray = [IO.File]::ReadAllText((Join-Path $root 'src/UnifiedTray.ps1'))
    $shell = [IO.File]::ReadAllText((Join-Path $root 'src/Shell.ps1'))
    Assert (-not $tray.Contains("New-StripItem 'Developer features (Cursor / Grok Bot beta)'")) 'developer preview switch is removed from settings'
    Assert ($tray.Contains('function Test-CardRailMode') -and $tray -match 'function Test-CardRailMode[\s\S]*?return \$true') 'hero and right-side small-card rail is always enabled'
    Assert (-not ($tray -match 'Count\s+-ge\s+4')) 'provider-count threshold is removed'
    Assert (-not $tray.Contains('function Invoke-QueuedWheelStep') -and -not $tray.Contains('$script:CardWheelPending') -and $tray.Contains('if ($script:CardRailAnimating) { return }')) 'wheel bursts are consumed during animation and never drain after scrolling stops'
    # Card switches run 420 ms on the island spring (see Switch-AccordionCardAnimated);
    # 260 ms read as an instant swap. Earlier this matched the collapse duration by accident.
    # 2026-11-09: card switches keep the original grow/shrink FLIP motion
    # (user's choice), 380 ms on the island spring, bitmap-cached.
    Assert ($tray -match 'function Switch-AccordionCardAnimated[\s\S]*?\$duration = 380' -and $tray -match 'function Switch-AccordionCardAnimated[\s\S]*?Start-CardFlipAnimation' -and $tray.Contains('Get-IslandSpringEase') -and $tray.Contains('CubicEase') -and $tray.Contains('EaseInOut') -and $tray.Contains('BitmapCache') -and $tray.Contains('SetDesiredFrameRate')) 'card switches use the original cached grow/shrink spring motion'
    Assert ($tray.Contains('[System.Windows.Controls.Grid]::SetRow($section, 0)') -and $tray.Contains('$railTop = [double]$SideRow * 44.0')) 'small AI cards stay grouped without overlapping in one top-anchored rail'
    Assert ($tray.Contains("return ([string]`$Key -ne 'grok')") -or ([IO.File]::ReadAllText((Join-Path $root 'src/UnifiedState.ps1')).Contains("return ([string]`$Key -ne 'grok')"))) 'Grok Bot is unavailable to the live UI'
    Assert ($tray.Contains('CornerRadius="18"') -and $tray.Contains('[AIUsageDwm]::RoundClean($helper.Handle)') -and -not $tray.Contains('CreateRoundRectRgn') -and $tray.Contains('0xFFFFFFFE') -and $tray.Contains('ncDisabled = 1') -and $tray.Contains('$s.DragMove()')) 'custom background picker keeps clean dark corners without a light native region fringe'
    Assert (-not $tray.Contains('[void]$script:ctxStrip.Items.Add($miHotkeys)') -and -not $tray.Contains('[void]$script:ctxStrip.Items.Add($miSnap)') -and -not $tray.Contains('[void]$miView.DropDownItems.Add($miHotkey)')) 'shortcut and corner-snap settings are removed'
    Assert ($tray.IndexOf("@('Copy stats to clipboard', 'IcoCopy')") -lt $tray.IndexOf("@('Test alert', 'IcoBell')") -and $tray.Contains("@('Notify when a task finishes', 'IcoCheck', `$true)") -and $tray.Contains("@('Notify when the AI needs you', 'IcoAttention', `$true)")) 'copy stats sits below Notch and notification rows use distinct icons'
    Assert ($tray.Contains('foreach ($key in (Get-AvailableProviderKeys))') -and $tray.Contains("`$deepSeekLogin = New-StripItem 'DeepSeek Harness'") -and $tray.Contains("Open-ProviderApp 'deepseek'") -and -not $tray.Contains("`$grokLogin = New-StripItem 'Grok Bot'")) 'AI services and login expose DeepSeek Harness but not retired Grok Bot'
    Assert ($tray.Contains('$script:NotchPanelSeen = $true') -and $tray.Contains('Start-NotchCollapse')) 'expanded panel records entry so first pointer exit folds it back'
    Assert ($tray.Contains('TextOptions.TextRenderingMode="ClearType"') -and $tray.Contains('AllowsTransparency="False"')) 'custom background picker uses sharp opaque ClearType rendering'
    $backgroundAt = $tray.IndexOf("Title = 'Background'"); $panelsAfterBackground = $tray.IndexOf("Title = 'Panels & Features'", $backgroundAt)
    $backgroundGroup = $tray.Substring($backgroundAt, $panelsAfterBackground - $backgroundAt)
    $systemAfterPanels = $tray.IndexOf("Title = 'System'", $panelsAfterBackground); $panelLayoutGroup = $tray.Substring($panelsAfterBackground, $systemAfterPanels - $panelsAfterBackground)
    Assert ($backgroundGroup.Contains("Direct = 'Background'") -and -not $tray.Contains("Title = 'Appearance & Layout'") -and $panelLayoutGroup.Contains("@('Follow active monitor', 'IcoWindow')") -and $panelLayoutGroup.Contains("@('Language', 'IcoGlobe')")) 'background replaces Appearance while layout and language merge into Panels & Features'
    Assert ($shell.Contains('Text="DeepSeek Harness"') -and $tray.Contains("deepseek = @{ Name = 'DeepSeek Harness'") -and $tray.Contains('DeepSeek Harness.lnk')) 'DeepSeek Harness uses the exact desktop shortcut name and real icon'
    Assert ($tray.Contains("ShortcutKeyDisplayString = '      '")) 'toggle submenus reserve a compact switch gutter'
    Assert ($tray.Contains("@('Notify when a task finishes', 'IcoCheck', `$true)") -and $tray.Contains("@('Notify when the AI needs you', 'IcoAttention', `$true)")) 'notification rows render as switches without the blue checked-item frame'
    Assert ($tray.Contains('[void]$w.ShowDialog()') -and $tray.Contains("New-StripItem 'Custom…' { Invoke-CustomPanelBackgroundDeferred }") -and -not $tray.Contains('New-Object System.Windows.Forms.ColorDialog')) 'custom background uses the modal JayOS-styled picker'
    Assert (-not $tray.Contains("New-StripItem 'Renew Claude sign-in automatically'")) 'built-in Claude renewal switch is hidden'
    Assert ($tray.Contains("`$script:DisplayVersion = '0.0.4 Beta'")) 'plugin keeps its 0.0.4 Beta label'
    Assert ($tray.IndexOf("Title = 'Alerts & Status'") -gt $tray.IndexOf("Title = 'System'")) 'notifications group is at the bottom'
    $panelsAt = $tray.IndexOf("Title = 'Panels & Features'"); $systemAt = $tray.IndexOf("Title = 'System'"); $alertsAt = $tray.IndexOf("Title = 'Alerts & Status'"); $usedAt = $tray.IndexOf('$used =', $alertsAt)
    $panelGroup = $tray.Substring($panelsAt, $systemAt - $panelsAt); $alertGroup = $tray.Substring($alertsAt, $usedAt - $alertsAt)
    Assert (-not $panelGroup.Contains("@('Threshold alerts'") -and $alertGroup.Contains("@('Threshold alerts'") -and $alertGroup.Contains("@('Notify when a task finishes'") -and $alertGroup.Contains("@('Notify when the AI needs you'") -and $alertGroup.Contains("@('Remind again if unanswered'")) 'all four reminder controls live under Alerts & Status'

    $entry = [IO.File]::ReadAllText((Join-Path $root 'unified-overlay.ps1'))
    Assert ($entry -match 'if \(\$IncludeCursor\)\s*\{\s*Get-CursorUsage') 'Cursor collection remains explicitly routed in the worker'

    Write-Output "$script:count tests passed"
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if (-not $resolved.StartsWith(([IO.Path]::GetFullPath($PSScriptRoot) + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
