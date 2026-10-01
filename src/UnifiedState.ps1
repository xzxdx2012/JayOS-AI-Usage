# UnifiedState.ps1 - settings persistence, window positioning, and clipboard export

$script:UnifiedSectionKeys = @('claude', 'codex', 'cursor', 'grok')

if (-not $script:Cfg) { $script:Cfg = @{} }
$script:UnifiedStateNeedsRepair = $false

$script:UnifiedCfgDefaults = @{
    Left        = $null
    Top         = $null
    Opacity     = 1.0
    StartHidden = $false
    ShowStats   = $true
    Compact     = $false
    Theme       = 'Graphite'
    ShowAlerts  = $true
    ShowGraph   = $false
    AlertState = @{}
    ViewMode = 'Pinned'              # 'Pinned' | 'Quake'
    DropdownHotkey = 'Shift+F11'
    # Global hotkeys steal the combo from every other app, so these start unbound
    # ('' registers nothing) until the user picks one from the tray.
    ToggleOverlayHotkey = ''
    RefreshHotkey = ''
    DropdownMonitor = 'Primary'      # 'Primary' | 'Active' | a Screen DeviceName
    DropdownOpacity = 0.85
    DropdownHideOnFocusLoss = $false
    NotchPinButton = $true           # pin button on the hover notch
    NotchPinned = $false             # notch stays out when the pointer leaves
    Language = 'en'                  # 'en' | 'zh' | 'ja'
    PanelBg = '#17171A'              # panel background colour
}

function ConvertTo-UnifiedSectionsMap($value) {
    # New installs / missing map: Claude off (demo path); others on.
    if (Get-Command Get-DefaultUnifiedSections -ErrorAction SilentlyContinue) {
        $sections = Get-DefaultUnifiedSections
    } else {
        $sections = @{}
        foreach ($key in $script:UnifiedSectionKeys) { $sections[$key] = ($key -ne 'claude') }
    }

    if ($null -eq $value) { return $sections }

    if ($value -is [System.Collections.IDictionary]) {
        foreach ($key in $script:UnifiedSectionKeys) {
            if ($value.Contains($key)) { $sections[$key] = [bool]$value[$key] }
        }
        return $sections
    }

    foreach ($key in $script:UnifiedSectionKeys) {
        $prop = $value.PSObject.Properties[$key]
        if ($prop) { $sections[$key] = [bool]$prop.Value }
    }
    return $sections
}

function Initialize-UnifiedCfg {
    foreach ($key in $script:UnifiedCfgDefaults.Keys) {
        if (-not $script:Cfg.ContainsKey($key)) {
            $script:Cfg[$key] = $script:UnifiedCfgDefaults[$key]
        }
    }
    $script:Cfg['Sections'] = ConvertTo-UnifiedSectionsMap $script:Cfg['Sections']
}

Initialize-UnifiedCfg

function Save-UnifiedState {
    try {
        Initialize-UnifiedCfg
        # Match Test-DropdownMode without requiring Dropdown.ps1 to be loaded
        # (Save-UnifiedState must not clobber pinned Left/Top while Quake is active).
        $mode = [string]$script:Cfg['ViewMode']
        $dropdownActive = ($mode -eq 'Quake' -or $mode -eq 'Dropdown')
        if (Get-Command Test-DropdownMode -ErrorAction SilentlyContinue) {
            $dropdownActive = Test-DropdownMode
        }
        if ($script:window -and -not $dropdownActive) {
            $script:Cfg.Left = $script:window.Left
            $script:Cfg.Top  = $script:window.Top
        }
        # Windows PowerShell 5.1 serializes [datetime] as a DisplayHint blob carrying
        # both 'value' and 'Value' keys, and its own ConvertFrom-Json then refuses the
        # whole file as having duplicate keys. Persist timestamps as strings instead.
        $out = @{}
        foreach ($key in $script:Cfg.Keys) {
            $val = $script:Cfg[$key]
            if ($val -is [datetime]) { $val = $val.ToString('o') }
            $out[$key] = $val
        }
        $out | ConvertTo-Json -Depth 6 | Set-Content -Path $script:StatePath -Encoding UTF8
        $script:UnifiedStateNeedsRepair = $false
    } catch {
        try { Write-Log "Save-UnifiedState failed: $($_.Exception.Message)" } catch { }
    }
}

function Load-UnifiedState {
    $script:UnifiedStateNeedsRepair = $false
    try {
        Initialize-UnifiedCfg
        if (-not (Test-Path $script:StatePath)) { return }

        $s = Get-Content $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($key in @('Left', 'Top', 'Opacity', 'StartHidden', 'ShowStats', 'Compact', 'Theme', 'ShowAlerts', 'ShowGraph', 'ViewMode', 'DropdownHotkey', 'ToggleOverlayHotkey', 'RefreshHotkey', 'DropdownMonitor', 'DropdownOpacity', 'DropdownHideOnFocusLoss', 'NotchPinButton', 'NotchPinned', 'Language', 'PanelBg')) {
            $prop = $s.PSObject.Properties[$key]
            if ($prop -and $null -ne $prop.Value) { $script:Cfg[$key] = $prop.Value }
        }
        if ($script:Themes -and -not $script:Themes.Contains([string]$script:Cfg['Theme'])) { $script:Cfg['Theme'] = 'Graphite' }
        # One-time move from the old default to the neutral Graphite palette;
        # picking any theme from the menu afterwards is respected.
        $pv = $s.PSObject.Properties['PaletteVersion']
        if (-not $pv -or [int]$pv.Value -lt 2) {
            if ([string]$script:Cfg['Theme'] -eq 'Deep Space') { $script:Cfg['Theme'] = 'Graphite' }
        }
        $script:Cfg['PaletteVersion'] = 2


        $sectionsProp = $s.PSObject.Properties['Sections']
        if ($sectionsProp) {
            $script:Cfg['Sections'] = ConvertTo-UnifiedSectionsMap $sectionsProp.Value
        }
        $alertStateProp = $s.PSObject.Properties['AlertState']
        if ($alertStateProp) {
            $script:Cfg['AlertState'] = $alertStateProp.Value
            if (Get-Command Import-AlertStateFromConfig -ErrorAction SilentlyContinue) {
                Import-AlertStateFromConfig
            }
        }

        Initialize-UnifiedCfg
    } catch {
        $script:UnifiedStateNeedsRepair = $true
        try { Write-Log "Load-UnifiedState failed: $($_.Exception.Message)" } catch { }
    }
}

function Sync-CompactModeBodies {
    # Full vs Compact must be exclusive Collapsed/Visible so large % labels
    # cannot ghost under the other mode (Hidden still participates in hit-test/layout).
    if (-not $script:window -or -not $script:Cfg) { return }
    $compact = [bool]$script:Cfg.Compact
    $vFull = if ($compact) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }
    $vComp = if ($compact) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    foreach ($sec in $script:UnifiedSectionKeys) {
        $full = $script:window.FindName($sec + 'Full')
        if ($full) { $full.Visibility = $vFull }
        $comp = $script:window.FindName($sec + 'Compact')
        if ($comp) { $comp.Visibility = $vComp }
        $hd = $script:window.FindName($sec + 'HeaderDetail')
        if ($hd) { $hd.Visibility = $vComp }
    }
}
function Apply-UnifiedSettings {
    Initialize-UnifiedCfg

    if ($script:window) {
        $script:window.Opacity = [double]$script:Cfg.Opacity

        $statsPanel = $script:window.FindName('statsPanel')
        if ($statsPanel) {
            $statsPanel.Visibility = if ($script:Cfg.ShowStats) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
        }

        if (-not $script:SparkRowNames) {
            $script:SparkRowNames = @(
                'fivehSparkRow','weekSparkRow','fivehSparkRowC','weekSparkRowC',
                'codexFivehSparkRow','codexWeekSparkRow','codexFivehSparkRowC','codexWeekSparkRowC',
                'grokWeekSparkRow','grokWeekSparkRowC',
                'cursorReqSparkRow','cursorReqSparkRowC'
            )
        }
        $sparkVis = if ($script:Cfg.ShowGraph) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
        foreach ($name in $script:SparkRowNames) {
            $row = $script:window.FindName($name)
            if ($row -and -not $script:Cfg.ShowGraph) { $row.Visibility = $sparkVis }
        }

        # Compact mode: swap each section's Full body for its single-line Compact body.
        Sync-CompactModeBodies
    }

    foreach ($key in $script:UnifiedSectionKeys) {
        Set-SectionVisible $key ([bool]$script:Cfg.Sections[$key])
    }

    Apply-UnifiedTheme $script:Cfg.Theme
}

function Test-FiniteNumber($value) {
    if ($null -eq $value) { return $false }
    try {
        $d = [double]$value
        return -not [double]::IsNaN($d) -and -not [double]::IsInfinity($d)
    } catch {
        return $false
    }
}

function Get-WindowDimension([string]$name) {
    $actualName = "Actual$name"
    $candidates = @(
        $script:window.$actualName,
        $script:window.$name,
        $script:window.RenderSize.$name,
        $script:window.DesiredSize.$name
    )

    foreach ($candidate in $candidates) {
        if ((Test-FiniteNumber $candidate) -and [double]$candidate -gt 0) {
            return [double]$candidate
        }
    }

    return 0.0
}

function ConvertFrom-ScreenWorkArea {
    param(
        $WorkingArea,
        $TransformFromDevice,
        $ScreenOrigin
    )

    $scaleX = [double]$TransformFromDevice.M11
    $scaleY = [double]$TransformFromDevice.M22

    if ($ScreenOrigin -and (Test-FiniteNumber $script:window.Left) -and (Test-FiniteNumber $script:window.Top)) {
        $left = [double]$script:window.Left + (([double]$WorkingArea.Left - [double]$ScreenOrigin.X) * $scaleX)
        $top  = [double]$script:window.Top  + (([double]$WorkingArea.Top  - [double]$ScreenOrigin.Y) * $scaleY)
        return @{
            Left   = $left
            Top    = $top
            Right  = $left + ([double]$WorkingArea.Width  * $scaleX)
            Bottom = $top  + ([double]$WorkingArea.Height * $scaleY)
        }
    }

    return @{
        Left   = [double]$WorkingArea.Left   * $scaleX
        Top    = [double]$WorkingArea.Top    * $scaleY
        Right  = [double]$WorkingArea.Right  * $scaleX
        Bottom = [double]$WorkingArea.Bottom * $scaleY
    }
}

# Work area (in WPF device-independent units) of the monitor the window is
# currently on. SystemParameters.WorkArea is always primary, so resolve the
# window monitor by HWND and convert the screen pixel rect through DPI.
function Get-WorkArea {
    $src = [System.Windows.PresentationSource]::FromVisual($script:window)
    if ($null -eq $src) {
        $wa = [System.Windows.SystemParameters]::WorkArea
        return @{ Left = $wa.Left; Top = $wa.Top; Right = $wa.Right; Bottom = $wa.Bottom }
    }
    $fromDev = $src.CompositionTarget.TransformFromDevice
    $hwnd    = (New-Object System.Windows.Interop.WindowInteropHelper $script:window).Handle
    $wa      = ([System.Windows.Forms.Screen]::FromHandle($hwnd)).WorkingArea
    $origin  = $null
    try {
        $origin = $script:window.PointToScreen((New-Object System.Windows.Point 0, 0))
    } catch {
        $origin = $null
    }
    return ConvertFrom-ScreenWorkArea $wa $fromDev $origin
}

function Clamp-Position {
    $wa = Get-WorkArea
    $w  = Get-WindowDimension 'Width'
    $h  = Get-WindowDimension 'Height'
    $script:window.Left = [math]::Max($wa.Left, [math]::Min($script:window.Left, $wa.Right  - $w))
    $script:window.Top  = [math]::Max($wa.Top,  [math]::Min($script:window.Top,  $wa.Bottom - $h))
}

# Working areas (physical pixels) of every currently connected monitor.
function Get-ScreenWorkAreas {
    [System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
        $w = $_.WorkingArea
        @{ Left = [double]$w.Left; Top = [double]$w.Top; Right = [double]$w.Right; Bottom = [double]$w.Bottom }
    }
}

# Device (DPI) scale of the monitor the window is currently on. WPF Left/Top are
# device-independent units; monitor rects are physical pixels, so the saved
# position must be scaled before it can be compared against them.
function Get-DeviceScale {
    $src = [System.Windows.PresentationSource]::FromVisual($script:window)
    if ($src) {
        $t = $src.CompositionTarget.TransformToDevice
        return @{ X = [double]$t.M11; Y = [double]$t.M22 }
    }
    return @{ X = 1.0; Y = 1.0 }
}

# True when the given rectangle overlaps any monitor work area by at least
# $MinVisible pixels on both axes. All rects share one (pixel) coordinate space.
# This is how we detect a window stranded on a now-disconnected monitor: its
# saved rectangle intersects none of the monitors that are actually present.
function Test-RectOnAnyScreen {
    param(
        [double]$Left,
        [double]$Top,
        [double]$Width,
        [double]$Height,
        [object[]]$Screens,
        [double]$MinVisible = 48.0
    )

    $right  = $Left + $Width
    $bottom = $Top  + $Height
    foreach ($s in $Screens) {
        $overlapX = [math]::Min($right,  [double]$s.Right)  - [math]::Max($Left, [double]$s.Left)
        $overlapY = [math]::Min($bottom, [double]$s.Bottom) - [math]::Max($Top,  [double]$s.Top)
        if ($overlapX -ge $MinVisible -and $overlapY -ge $MinVisible) { return $true }
    }
    return $false
}

# True when the saved config position lands enough of the window on a connected
# monitor to be reachable. Guards against restoring onto a monitor that has since
# been unplugged (the classic "overlay vanished" report).
function Test-SavedPositionVisible {
    if ($null -eq $script:Cfg.Left -or $null -eq $script:Cfg.Top) { return $false }
    if (-not (Test-FiniteNumber $script:Cfg.Left) -or -not (Test-FiniteNumber $script:Cfg.Top)) { return $false }

    $scale = Get-DeviceScale
    $w = (Get-WindowDimension 'Width')  * $scale.X
    $h = (Get-WindowDimension 'Height') * $scale.Y
    $left = [double]$script:Cfg.Left * $scale.X
    $top  = [double]$script:Cfg.Top  * $scale.Y

    return Test-RectOnAnyScreen -Left $left -Top $top -Width $w -Height $h -Screens (Get-ScreenWorkAreas)
}

function Snap-ToCorner([string]$corner) {
    $wa = Get-WorkArea
    $w  = Get-WindowDimension 'Width'
    $h  = Get-WindowDimension 'Height'
    switch ($corner) {
        'TR' { $script:window.Left = $wa.Right - $w - 16; $script:window.Top = $wa.Top    + 16 }
        'TL' { $script:window.Left = $wa.Left  + 16;      $script:window.Top = $wa.Top    + 16 }
        'BR' { $script:window.Left = $wa.Right - $w - 16; $script:window.Top = $wa.Bottom - $h - 16 }
        'BL' { $script:window.Left = $wa.Left  + 16;      $script:window.Top = $wa.Bottom - $h - 16 }
    }
    Save-UnifiedState
}

function Position-Window {
    if ($script:Positioned) { return }
    $script:Positioned = $true
    Resize-ToContent
    if (($null -ne $script:Cfg.Left) -and (Test-SavedPositionVisible)) {
        $script:window.Left = [double]$script:Cfg.Left
        $script:window.Top  = [double]$script:Cfg.Top
        Clamp-Position
    } else {
        Snap-ToCorner 'TR'
    }
}

function Get-OverlayPersistedSettingKeys {
    @(
        'Theme'
        'Opacity'
        'Compact'
        'ShowStats'
        'ShowGraph'
        'ShowAlerts'
        'ViewMode'
        'StartHidden'
        'Sections'
        'DropdownHotkey'
        'ToggleOverlayHotkey'
        'RefreshHotkey'
        'DropdownMonitor'
        'DropdownHideOnFocusLoss'
        'Left'
        'Top'
    )
}

function Copy-Stats {
    $sections = $null
    if ($script:Cfg -is [System.Collections.IDictionary] -and $script:Cfg.Contains('Sections')) {
        $sections = $script:Cfg['Sections']
    }

    $usage = $null
    if ($script:State -is [System.Collections.IDictionary] -and $script:State.Contains('Data')) {
        $usage = $script:State['Data']
    } elseif ($script:State) {
        $usage = $script:State.Data
    }

    $lines = Get-UnifiedExportLines `
        -ClaudeIdentity $script:ClaudeIdentity `
        -ClaudeUsage $usage `
        -ClaudeStats $script:Stats `
        -CodexStats $script:CodexStats `
        -CursorSummary $script:SummaryData `
        -CursorLocal $script:LocalData `
        -GrokUsage $script:GrokUsage `
        -Sections $sections

    [System.Windows.Clipboard]::SetText(($lines -join "`n"))
}
