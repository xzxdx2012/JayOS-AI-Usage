# ---------------------------------------------------------------------------
# Settings, Apple style. The footer gear opens a popover laid out like iOS
# Settings: big quick tiles on top, then grouped rows with coloured icons;
# tapping a group pushes its page in from the right, "‹ 设置" goes back.
#
# There is one source of truth: the JayOS settings menu ($script:ctxStrip,
# built in src\UnifiedTray.ps1). This panel reads its groups and items and
# renders them; every tap runs the menu item's own handler (PerformClick),
# so the two can never disagree. The tray icon keeps the classic menu.
# ---------------------------------------------------------------------------
$script:AppleSettingsWin = $null
$script:AppleNav = $null
$script:AppleSettingsPos = $null

$script:AppleGroupColors = @{
    'Account & Data'    = '#0A84FF'
    'Background'        = '#FF9F0A'
    'Panels & Features' = '#30D158'
    'Island'            = '#BF5AF2'
    'System'            = '#8E8E93'
    'Alerts & Status'   = '#FF453A'
}

# Quick tiles: menu item text -> tile label/glyph (Segoe MDL2 Assets).
$script:AppleQuickTiles = @(
    # Filled icons drawn on a 24x24 grid (EvenOdd: inner shapes are cut out),
    # each tile with its own colour, like Control Centre.
    @{ Item = 'Music page';          From = '#FF6482'; To = '#FF2D55'
       Icon = 'M9,3.2 L20.5,1.2 L20.5,15.6 A3.4,3.4 0 1 1 18.6,12.6 L18.6,5.5 L10.9,6.9 L10.9,17.6 A3.4,3.4 0 1 1 9,14.6 Z' }
    @{ Item = 'Shelf page';          From = '#64D2FF'; To = '#0A84FF'
       Icon = 'M3,13 L6.6,4.6 A1.6,1.6 0 0 1 8.1,3.6 L15.9,3.6 A1.6,1.6 0 0 1 17.4,4.6 L21,13 L21,18.6 A2.4,2.4 0 0 1 18.6,21 L5.4,21 A2.4,2.4 0 0 1 3,18.6 Z M5.4,13 L9.2,13 A2.8,2.8 0 0 0 14.8,13 L18.6,13 L15.6,5.8 L8.4,5.8 Z' }
    @{ Item = 'Lyrics on the notch'; From = '#DA8FFF'; To = '#AF52DE'
       Icon = 'M5,3 L19,3 A3,3 0 0 1 22,6 L22,14.5 A3,3 0 0 1 19,17.5 L11,17.5 L6.2,21.2 A0.7,0.7 0 0 1 5.1,20.6 L5.1,17.5 L5,17.5 A3,3 0 0 1 2,14.5 L2,6 A3,3 0 0 1 5,3 Z M6.5,7.6 L17.5,7.6 L17.5,9.4 L6.5,9.4 Z M6.5,11.2 L13.5,11.2 L13.5,13 L6.5,13 Z' }
    @{ Item = 'Fast animations';     From = '#FFD60A'; To = '#FF9F0A'
       Icon = 'M13.6,1.8 L4.4,13.4 A0.6,0.6 0 0 0 4.9,14.4 L11,14.4 L9.9,21.6 A0.4,0.4 0 0 0 10.6,21.9 L19.6,10.4 A0.6,0.6 0 0 0 19.1,9.4 L13,9.4 L14.3,2.1 A0.4,0.4 0 0 0 13.6,1.8 Z' }
)

function Get-AppleText([string]$Text) {
    $t = ($Text -replace '&&', '&')
    try { if (Get-Command Convert-I18nString -ErrorAction SilentlyContinue) { $t = Convert-I18nString $t (Get-UiLanguage) } } catch { }
    return $t
}

# Latin in Segoe UI, Chinese in Microsoft YaHei UI - one family for every
# text in the sheet, so a label never mixes two weights of two fonts.
$script:AppleFont = New-Object System.Windows.Media.FontFamily('Segoe UI, Microsoft YaHei UI')

function Get-AppleRootTitle {
    switch (Get-UiLanguage) { 'zh' { '设置' } 'ja' { '設定' } 'ko' { '설정' } 'fr' { 'Réglages' } default { 'Settings' } }
}

function Get-AppleItemKey($Item) {
    # The English source text (before translation) identifies an item.
    try { if (Get-Command Get-I18nSource -ErrorAction SilentlyContinue) { $src = Get-I18nSource $Item ([string]$Item.Text); if ($src) { return ($src -replace '&&', '&') } } } catch { }
    return ([string]$Item.Text -replace '&&', '&')
}

function Convert-AppleImage($Image) {
    if (-not $Image) { return $null }
    try {
        $bmp = New-Object System.Drawing.Bitmap($Image)
        $h = $bmp.GetHbitmap([System.Drawing.Color]::FromArgb(0, 0, 0, 0))
        try {
            $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHBitmap($h, [IntPtr]::Zero, [System.Windows.Int32Rect]::Empty,
                [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
            $src.Freeze()
            return $src
        } finally {
            if (-not ([System.Management.Automation.PSTypeName]'AIUsage.AppleGdi').Type) {
                Add-Type -Namespace AIUsage -Name AppleGdi -MemberDefinition '[DllImport("gdi32.dll")] public static extern bool DeleteObject(System.IntPtr h);' -ErrorAction SilentlyContinue
            }
            try { [void][AIUsage.AppleGdi]::DeleteObject($h) } catch { }
            $bmp.Dispose()
        }
    } catch { return $null }
}

# Make sure every switch/check mark reflects the current settings.
function Sync-AppleSource {
    foreach ($fn in @('Sync-MenuToggleStates', 'Sync-AppearanceMenus', 'Sync-ProviderLoginMenuItems', 'Sync-SectionMenuItems', 'Sync-IslandMenuToggles')) {
        if (Get-Command $fn -ErrorAction SilentlyContinue) { try { & $fn } catch { } }
    }
    try { Invoke-MenuTranslate $script:ctxStrip.Items } catch { }
}

# ---------------------------------------------------------------------------
# Controls
# ---------------------------------------------------------------------------
function New-AppleSwitch([bool]$On) {
    $track = New-Object System.Windows.Controls.Border
    $track.Width = 38; $track.Height = 23
    $track.CornerRadius = New-Object System.Windows.CornerRadius(11.5)
    $track.Background = NewBrush $(if ($On) { '#30D158' } else { '#39393D' })
    $knob = New-Object System.Windows.Shapes.Ellipse
    $knob.Width = 19; $knob.Height = 19
    $knob.Fill = NewBrush '#FFFFFF'
    $knob.HorizontalAlignment = 'Left'; $knob.VerticalAlignment = 'Center'
    $knob.RenderTransform = New-Object System.Windows.Media.TranslateTransform($(if ($On) { 17 } else { 2 }), 0)
    $track.Child = $knob
    $track.Tag = $On
    return $track
}

function Set-AppleSwitch($Track, [bool]$On) {
    $Track.Tag = $On
    $Track.Background = NewBrush $(if ($On) { '#30D158' } else { '#39393D' })
    $tt = $Track.Child.RenderTransform
    $a = New-IslandAnimation ([double]$tt.X) $(if ($On) { 17.0 } else { 2.0 }) 380 'spring'
    $tt.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $a)
}

function New-AppleIconTile([string]$Color, $Image, [string]$Glyph) {
    $tile = New-Object System.Windows.Controls.Border
    $tile.Width = 22; $tile.Height = 22
    $tile.CornerRadius = New-Object System.Windows.CornerRadius(5.5)
    $tile.Background = NewBrush $Color
    $tile.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)
    $tile.VerticalAlignment = 'Center'
    if ($Image) {
        $img = New-Object System.Windows.Controls.Image
        $img.Source = $Image; $img.Width = 13; $img.Height = 13
        [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, 'HighQuality')
        $tile.Child = $img
    } elseif ($Glyph) {
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = $Glyph; $t.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe Fluent Icons, Segoe MDL2 Assets')
        $t.FontSize = 11; $t.Foreground = NewBrush '#FFFFFF'
        $t.HorizontalAlignment = 'Center'; $t.VerticalAlignment = 'Center'
        $tile.Child = $t
    }
    return $tile
}

# One grouped-list section: rounded #1C1C1E block, rows separated by inset hairlines.
function New-AppleSection([string]$Header) {
    $wrap = New-Object System.Windows.Controls.StackPanel
    $wrap.Margin = New-Object System.Windows.Thickness(0, 0, 0, 14)
    if ($Header) {
        $h = New-Object System.Windows.Controls.TextBlock
        $h.Text = $Header.ToUpperInvariant(); $h.Foreground = NewBrush '#8E8E93'; $h.FontSize = 10.5
        $h.Margin = New-Object System.Windows.Thickness(12, 0, 0, 5)
        [void]$wrap.Children.Add($h)
    }
    $block = New-Object System.Windows.Controls.Border
    $block.CornerRadius = New-Object System.Windows.CornerRadius(10)
    $block.Background = NewBrush '#1C1C1E'
    $block.ClipToBounds = $true
    $rows = New-Object System.Windows.Controls.StackPanel
    $block.Child = $rows
    [void]$wrap.Children.Add($block)
    return @{ Element = $wrap; Rows = $rows }
}

function Add-AppleRow($Section, $Row) {
    if ($Section.Rows.Children.Count -gt 0) {
        $sep = New-Object System.Windows.Controls.Border
        $sep.Height = 0.6; $sep.Background = NewBrush '#38383A'
        $sep.Margin = New-Object System.Windows.Thickness(44, 0, 0, 0)
        [void]$Section.Rows.Children.Add($sep)
    }
    [void]$Section.Rows.Children.Add($Row)
}

# A row: [icon] label ............ accessory.  Press highlights like iOS.
function New-AppleRow([string]$Label, $Icon, $Accessory, [scriptblock]$OnTap, [string]$LabelColor = '#F5F5F7', [string]$Value = '') {
    $row = New-Object System.Windows.Controls.Border
    $row.Background = NewBrush '#001C1C1E'
    $row.Padding = New-Object System.Windows.Thickness(12, 5, 11, 5)
    $row.MinHeight = 34
    $g = New-Object System.Windows.Controls.Grid
    foreach ($w in @('Auto', '*', 'Auto')) {
        $c = New-Object System.Windows.Controls.ColumnDefinition
        $c.Width = if ($w -eq '*') { New-Object System.Windows.GridLength(1, 'Star') } else { [System.Windows.GridLength]::Auto }
        $g.ColumnDefinitions.Add($c)
    }
    if ($Icon) { [void]$g.Children.Add($Icon) }
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Label; $t.Foreground = NewBrush $LabelColor; $t.FontSize = 12.5
    $t.FontFamily = $script:AppleFont
    $t.VerticalAlignment = 'Center'; $t.TextTrimming = 'CharacterEllipsis'
    [System.Windows.Controls.Grid]::SetColumn($t, 1)
    [void]$g.Children.Add($t)
    $right = New-Object System.Windows.Controls.StackPanel
    $right.Orientation = 'Horizontal'; $right.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($right, 2)
    if ($Value) {
        $v = New-Object System.Windows.Controls.TextBlock
        $v.Text = $Value; $v.Foreground = NewBrush '#8E8E93'; $v.FontSize = 12.5
        $v.VerticalAlignment = 'Center'; $v.Margin = New-Object System.Windows.Thickness(8, 0, 6, 0)
        [void]$right.Children.Add($v)
    }
    if ($Accessory) { [void]$right.Children.Add($Accessory) }
    [void]$g.Children.Add($right)
    $row.Child = $g
    if ($OnTap) {
        $row.Cursor = [System.Windows.Input.Cursors]::Hand
        $row.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; $s.Background = NewBrush '#2C2C2E' })
        $row.Add_MouseLeave({ param($s, $e) $s.Background = NewBrush '#001C1C1E' })
        $row.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; $s.Background = NewBrush '#001C1C1E'; try { & $s.Tag.Tap $s } catch { } })
    }
    # Per-row state lives in Tag: Tap (handler), Item (menu item), Sw (switch).
    $row.Tag = @{ Tap = $OnTap; Item = $null; Sw = $null }
    return $row
}

function New-AppleChevron {
    $c = New-Object System.Windows.Controls.TextBlock
    $c.Text = [string][char]0xE76C
    $c.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe Fluent Icons, Segoe MDL2 Assets')
    $c.FontSize = 9; $c.Foreground = NewBrush '#5A5A5F'; $c.VerticalAlignment = 'Center'
    return $c
}

function New-AppleCheck([bool]$On) {
    $c = New-Object System.Windows.Controls.TextBlock
    $c.Text = [string][char]0xE73E
    $c.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe Fluent Icons, Segoe MDL2 Assets')
    $c.FontSize = 11.5; $c.Foreground = NewBrush '#0A84FF'; $c.VerticalAlignment = 'Center'
    $c.Visibility = if ($On) { 'Visible' } else { 'Hidden' }
    return $c
}

# ---------------------------------------------------------------------------
# Pages
# ---------------------------------------------------------------------------
function New-AppleTile($Item, $Spec) {
    $on = [bool]$Item.Checked
    $tile = New-Object System.Windows.Controls.Border
    # Compact Control Centre pill: round glyph on the left, label beside it.
    $tile.CornerRadius = New-Object System.Windows.CornerRadius(12)
    $tile.Height = 40
    $tile.Margin = New-Object System.Windows.Thickness(3)
    $tile.Padding = New-Object System.Windows.Thickness(7, 0, 8, 0)
    $tile.Cursor = [System.Windows.Input.Cursors]::Hand
    $sp = New-Object System.Windows.Controls.DockPanel
    $sp.VerticalAlignment = 'Center'
    $circle = New-Object System.Windows.Controls.Border
    $circle.Width = 24; $circle.Height = 24; $circle.CornerRadius = New-Object System.Windows.CornerRadius(12)
    $circle.Margin = New-Object System.Windows.Thickness(0, 0, 7, 0)
    $g = New-Object System.Windows.Shapes.Path
    $geo = [System.Windows.Media.Geometry]::Parse('F0 ' + [string]$Spec.Icon); $geo.Freeze()
    $g.Data = $geo; $g.Stretch = 'Uniform'; $g.Width = 13; $g.Height = 13
    $g.HorizontalAlignment = 'Center'; $g.VerticalAlignment = 'Center'
    $circle.Child = $g
    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Text = Get-AppleText ([string]$Item.Text); $lbl.FontSize = 12; $lbl.FontFamily = $script:AppleFont
    $lbl.VerticalAlignment = 'Center'; $lbl.TextTrimming = 'CharacterEllipsis'
    [void]$sp.Children.Add($circle); [void]$sp.Children.Add($lbl)
    $tile.Child = $sp
    $tile.Tag = @{ Item = $Item; Circle = $circle; Glyph = $g; Label = $lbl; Spec = $Spec }
    $tile.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
    $tile.RenderTransform = New-Object System.Windows.Media.ScaleTransform(1, 1)
    Set-AppleTileState $tile $on
    $tile.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; Invoke-PressPop $s 0.94 })
    $tile.Add_MouseLeftButtonUp({
        param($s, $e)
        $e.Handled = $true; Invoke-PressPop $s 1.0
        try { $s.Tag.Item.PerformClick() } catch { }
        Sync-AppleSource
        Set-AppleTileState $s ([bool]$s.Tag.Item.Checked)
    })
    return $tile
}

function Set-AppleTileState($Tile, [bool]$On) {
    $t = $Tile.Tag
    # Quiet dark tiles: "on" is told by the coloured circle, not a white slab.
    $Tile.Background = NewBrush $(if ($On) { '#2C2C2E' } else { '#1C1C1E' })
    if ($On) {
        $gb = New-Object System.Windows.Media.LinearGradientBrush(([System.Windows.Media.ColorConverter]::ConvertFromString([string]$t.Spec.From)), ([System.Windows.Media.ColorConverter]::ConvertFromString([string]$t.Spec.To)), 90.0)
        $gb.Freeze()
        $t.Circle.Background = $gb
    } else { $t.Circle.Background = NewBrush '#3A3A3C' }
    $t.Glyph.Fill = NewBrush $(if ($On) { '#FFFFFF' } else { '#8E8E93' })
    $t.Label.Foreground = NewBrush $(if ($On) { '#F5F5F7' } else { '#8E8E93' })
}

function Get-AppleGroups {
    $groups = @()
    foreach ($it in @($script:ctxStrip.Items)) {
        if ($it -isnot [System.Windows.Forms.ToolStripMenuItem]) { continue }
        if ([string]$it.Tag -eq 'grip') { continue }
        $groups += $it
    }
    return $groups
}

function Find-AppleMenuItem([string]$Key, $Items = $script:ctxStrip.Items) {
    foreach ($it in @($Items)) {
        if ($it -isnot [System.Windows.Forms.ToolStripMenuItem]) { continue }
        if ((Get-AppleItemKey $it) -eq $Key) { return $it }
        if ($it.HasDropDownItems) { $f = Find-AppleMenuItem $Key $it.DropDownItems; if ($f) { return $f } }
    }
    return $null
}

function New-AppleRootPage {
    $page = New-Object System.Windows.Controls.StackPanel
    # Quick tiles (2 x 2).
    $grid = New-Object System.Windows.Controls.Primitives.UniformGrid
    $grid.Columns = 2
    $grid.Margin = New-Object System.Windows.Thickness(-3, 0, -3, 12)
    foreach ($q in $script:AppleQuickTiles) {
        $item = Find-AppleMenuItem $q.Item
        if ($item) { [void]$grid.Children.Add((New-AppleTile $item $q)) }
    }
    if ($grid.Children.Count) { [void]$page.Children.Add($grid) }

    $sec = New-AppleSection ''
    $quit = $null
    foreach ($g in Get-AppleGroups) {
        $key = Get-AppleItemKey $g
        if ($key -eq 'Quit') { $quit = $g; continue }
        $color = if ($script:AppleGroupColors.ContainsKey($key)) { $script:AppleGroupColors[$key] } else { '#636366' }
        $icon = New-AppleIconTile $color (Convert-AppleImage $g.Image) ''
        if ($g.HasDropDownItems) {
            $row = New-AppleRow (Get-AppleText ([string]$g.Text)) $icon (New-AppleChevron) { param($s) Push-ApplePage $s.Tag.Item }
        } else {
            $row = New-AppleRow (Get-AppleText ([string]$g.Text)) $icon $null { param($s) try { $s.Tag.Item.PerformClick() } catch { }; Sync-AppleSource }
        }
        $row.Tag.Item = $g
        Add-AppleRow $sec $row
    }
    [void]$page.Children.Add($sec.Element)
    if ($quit) {
        $qs = New-AppleSection ''
        $row = New-AppleRow (Get-AppleText ([string]$quit.Text)) $null $null { param($s) $i = $s.Tag.Item; Close-AppleSettings; try { $i.PerformClick() } catch { } } '#FF453A'
        $row.Tag.Item = $quit
        Add-AppleRow $qs $row
        [void]$page.Children.Add($qs.Element)
    }
    return $page
}

# A group's (or submenu's) page: its rows become switches, check marks,
# drill-downs or plain actions, depending on what the menu item is.
function New-AppleItemPage($Parent) {
    $page = New-Object System.Windows.Controls.StackPanel
    $sec = $null
    $header = ''
    $items = @($Parent.DropDownItems)
    # A list where items carry check marks is a pick-one list.
    $isChoice = (@($items | Where-Object { $_ -is [System.Windows.Forms.ToolStripMenuItem] -and [string]$_.Tag -ne 'toggle' -and [string]$_.Tag -ne 'header' -and $_.Checked }).Count -gt 0)
    foreach ($it in $items) {
        if ($it -is [System.Windows.Forms.ToolStripSeparator]) {
            if ($sec -and $sec.Rows.Children.Count) { [void]$page.Children.Add($sec.Element); $sec = $null }
            continue
        }
        if ($it -isnot [System.Windows.Forms.ToolStripMenuItem]) { continue }
        if ([string]$it.Tag -eq 'header') { continue }
        if (-not $it.Available) { continue }
        if (-not $sec) { $sec = New-AppleSection $header }
        $label = Get-AppleText ([string]$it.Text)
        $img = Convert-AppleImage $it.Image
        $icon = if ($img) { New-AppleIconTile '#3A3A3C' $img '' } else { $null }
        if ([string]$it.Tag -eq 'toggle') {
            $sw = New-AppleSwitch ([bool]$it.Checked)
            $row = New-AppleRow $label $icon $sw { param($s) $i = $s.Tag.Item; try { $i.PerformClick() } catch { }; Sync-AppleSource; Set-AppleSwitch $s.Tag.Sw ([bool]$i.Checked) }
            $row.Tag.Sw = $sw
        } elseif ($it.HasDropDownItems) {
            $cur = @($it.DropDownItems | Where-Object { $_ -is [System.Windows.Forms.ToolStripMenuItem] -and $_.Checked } | Select-Object -First 1)
            $val = if ($cur.Count) { Get-AppleText ([string]$cur[0].Text) } else { '' }
            $row = New-AppleRow $label $icon (New-AppleChevron) { param($s) Push-ApplePage $s.Tag.Item } '#F5F5F7' $val
        } elseif ($isChoice) {
            $row = New-AppleRow $label $icon (New-AppleCheck ([bool]$it.Checked)) { param($s) try { $s.Tag.Item.PerformClick() } catch { }; Sync-AppleSource; Update-AppleCurrentPage }
        } elseif (-not $it.Enabled) {
            $row = New-AppleRow $label $icon $null $null '#8E8E93'
        } else {
            $row = New-AppleRow $label $icon $null { param($s) try { $s.Tag.Item.PerformClick() } catch { }; Sync-AppleSource; Update-AppleCurrentPage }
        }
        $row.Tag.Item = $it
        Add-AppleRow $sec $row
    }
    if ($sec -and $sec.Rows.Children.Count) { [void]$page.Children.Add($sec.Element) }
    return $page
}

# ---------------------------------------------------------------------------
# Window + navigation
# ---------------------------------------------------------------------------
$script:AppleSettingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        Topmost="True" ShowInTaskbar="False" Width="298" Height="468" SizeToContent="Manual"
        UseLayoutRounding="True" SnapsToDevicePixels="True" FontFamily="Segoe UI, Microsoft YaHei UI">
  <Border x:Name="sheet" CornerRadius="16" Background="#FF141416" BorderBrush="#FF3A3A3E" BorderThickness="1" Margin="2" Opacity="0"
          RenderTransformOrigin="1,0">
    <Border.RenderTransform><ScaleTransform x:Name="sheetScale" ScaleX="0.96" ScaleY="0.96"/></Border.RenderTransform>
    <Grid>
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
      <Grid x:Name="titleBar" Margin="14,10,10,4" Background="#01000000">
        <TextBlock x:Name="backButton" Text="" Foreground="#0A84FF" FontSize="12.5" Cursor="Hand"
                   VerticalAlignment="Center" HorizontalAlignment="Left" Visibility="Collapsed"/>
        <TextBlock x:Name="navTitle" Foreground="#F5F5F7" FontSize="12.5" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        <Border x:Name="closeButton" Width="22" Height="22" CornerRadius="11" Background="#2C2C2E" HorizontalAlignment="Right" Cursor="Hand">
          <TextBlock Text="&#xE711;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="8" Foreground="#AEAEB2" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
      </Grid>
      <Grid x:Name="pageHost" Grid.Row="1" ClipToBounds="True"/>
    </Grid>
  </Border>
</Window>
'@

function Close-AppleSettings {
    $w = $script:AppleSettingsWin
    $script:AppleSettingsWin = $null
    if ($w) { try { $w.Close() } catch { } }
}

function New-ApplePageHost($Content, [string]$Title, [bool]$LargeTitle) {
    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Hidden'
    $scroll.HorizontalScrollBarVisibility = 'Disabled'
    # Opaque, so a page sliding in covers the one leaving instead of the two
    # showing through each other (that read as a double image).
    $scroll.Background = NewBrush '#FF141416'
    $inner = New-Object System.Windows.Controls.StackPanel
    $inner.Margin = New-Object System.Windows.Thickness(12, 0, 12, 12)
    if ($LargeTitle) {
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = $Title; $t.Foreground = NewBrush '#F5F5F7'; $t.FontSize = 21
        $t.FontFamily = $script:AppleFont; $t.FontWeight = [System.Windows.FontWeights]::Bold
        $t.Margin = New-Object System.Windows.Thickness(3, 0, 0, 10)
        [void]$inner.Children.Add($t)
    }
    [void]$inner.Children.Add($Content)
    $scroll.Content = $inner
    $scroll.RenderTransform = New-Object System.Windows.Media.TranslateTransform(0, 0)
    $scroll.Add_PreviewMouseWheel({ param($s, $e) $s.ScrollToVerticalOffset($s.VerticalOffset - $e.Delta / 2.0); $e.Handled = $true })
    return $scroll
}

function Show-ApplePage([int]$Direction) {
    $nav = $script:AppleNav
    if (-not $nav) { return }
    $top = $nav.Stack[$nav.Stack.Count - 1]
    if ($top.Source) { $content = New-AppleItemPage $top.Source; $title = Get-AppleText ([string]$top.Source.Text); $large = $false }
    else { $content = New-AppleRootPage; $title = Get-AppleRootTitle; $large = $true }
    $hostPage = New-ApplePageHost $content $title $large
    $ui = $nav.Ui
    $ui.navTitle.Text = if ($large) { '' } else { $title }
    if ($nav.Stack.Count -gt 1) {
        $prev = $nav.Stack[$nav.Stack.Count - 2]
        $prevTitle = if ($prev.Source) { Get-AppleText ([string]$prev.Source.Text) } else { Get-AppleRootTitle }
        $ui.backButton.Text = [string][char]0x2039 + ' ' + $prevTitle
        $ui.backButton.Visibility = 'Visible'
    } else { $ui.backButton.Visibility = 'Collapsed' }
    $old = $nav.Current
    [void]$ui.pageHost.Children.Add($hostPage)
    $nav.Current = $hostPage
    $w = 300.0
    if ($old -and $Direction -ne 0) {
        # iOS push/pop: the new page slides fully across, the old one moves a third.
        $hostPage.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, (New-IslandAnimation ($w * $Direction) 0.0 420 'spring'))
        $oldA = New-IslandAnimation 0.0 (-$w * 0.3 * $Direction) 420 'spring'
        $oldA.add_Completed({ try { $n = $script:AppleNav; if ($n) { foreach ($c in @($n.Ui.pageHost.Children)) { if ($c -ne $n.Current) { $n.Ui.pageHost.Children.Remove($c) } } } } catch { } })
        $old.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $oldA)
        $old.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-IslandAnimation 1.0 0.0 180 'out'))
    } elseif ($old) {
        $ui.pageHost.Children.Remove($old)
    }
}

function Push-ApplePage($Source) {
    if (-not $script:AppleNav) { return }
    Sync-AppleSource
    [void]$script:AppleNav.Stack.Add(@{ Source = $Source })
    Show-ApplePage 1
}

function Pop-ApplePage {
    $nav = $script:AppleNav
    if (-not $nav -or $nav.Stack.Count -le 1) { return }
    $nav.Stack.RemoveAt($nav.Stack.Count - 1)
    Show-ApplePage -1
}

# Rebuild the visible page in place (after a pick-one choice or action).
function Update-AppleCurrentPage {
    if (-not $script:AppleNav) { return }
    Show-ApplePage 0
}

function Show-AppleSettings($EventArgs) {
    if ($script:AppleSettingsWin) { Close-AppleSettings; return }
    if (-not $script:ctxStrip) { return }
    Sync-AppleSource
    $win = [System.Windows.Markup.XamlReader]::Parse($script:AppleSettingsXaml)
    $ui = @{}
    foreach ($n in @('sheet', 'sheetScale', 'backButton', 'navTitle', 'closeButton', 'pageHost')) { $ui[$n] = $win.FindName($n) }
    $script:AppleSettingsWin = $win
    $script:AppleNav = @{ Ui = $ui; Stack = (New-Object System.Collections.ArrayList); Current = $null }
    [void]$script:AppleNav.Stack.Add(@{ Source = $null })
    $ui.closeButton.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Close-AppleSettings })
    $ui.backButton.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Pop-ApplePage })
    $win.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { if ($script:AppleNav.Stack.Count -gt 1) { Pop-ApplePage } else { Close-AppleSettings } } })
    # Tapping outside closes it - unless a dialog it opened (colour picker,
    # folder picker, ...) took the focus.
    $win.Add_Deactivated({
        param($s, $e)
        [void]$s.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{
            try {
                $w = $script:AppleSettingsWin
                if (-not $w -or $w.IsActive) { return }
                if ($script:ColorPicker) { return }
                $fg = [System.Windows.Application]::Current
                Close-AppleSettings
            } catch { }
        })
    })
    $win.Add_Closed({ $script:AppleSettingsWin = $null; $script:AppleNav = $null })
    # The pages have opaque backgrounds; clip them to the sheet's rounded
    # inner edge so the bottom corners stay round (radius 16 minus the 1 px border).
    $ui.sheet.Child.Add_SizeChanged({
        param($s, $e)
        $g = New-Object System.Windows.Media.RectangleGeometry((New-Object System.Windows.Rect(0, 0, $s.ActualWidth, $s.ActualHeight)), 15, 15)
        $g.Freeze(); $s.Clip = $g
    })
    # Drag it anywhere by its background or title bar (rows, tiles and
    # buttons keep their own clicks). Each time it opens it is back under the gear.
    $win.Add_MouseLeftButtonDown({
        param($s, $e)
        $o = $e.OriginalSource
        foreach ($n in @('closeButton', 'backButton')) {
            $b = $s.FindName($n)
            if ($b -and $o -is [System.Windows.DependencyObject] -and ($o -eq $b -or $b.IsAncestorOf($o))) { return }
        }
        try { $s.DragMove() } catch { }
    })


    # Place it under the island, right edge near the gear.
    try {
        $iw = $script:window
        $gear = $iw.FindName('footerSettingsButton')
        $pt = $gear.TranslatePoint((New-Object System.Windows.Point([double]$gear.ActualWidth, [double]$gear.ActualHeight)), $iw)
        $left = [double]$iw.Left + $pt.X - [double]$win.Width + 24
        $top = [double]$iw.Top + $pt.Y + 4
        $wa = [System.Windows.SystemParameters]::WorkArea
        $left = [math]::Max($wa.Left + 4, [math]::Min($left, $wa.Right - [double]$win.Width - 4))
        $top = [math]::Max($wa.Top + 4, [math]::Min($top, $wa.Bottom - [double]$win.Height - 4))

        $win.Left = Get-NotchSnap $left; $win.Top = Get-NotchSnap $top
    } catch { $win.WindowStartupLocation = 'CenterScreen' }

    Show-ApplePage 0
    # The sheet starts invisible (XAML Opacity 0, scale 0.96). One smooth
    # fade + grow starts only after the window has painted once, so there is
    # no full-brightness first frame and no spring overshoot - either of
    # those read as the sheet flashing twice.
    $win.Add_ContentRendered({
        param($s, $e)
        $sh = $s.FindName('sheet'); $sc = $s.FindName('sheetScale')
        foreach ($p in @([System.Windows.Media.ScaleTransform]::ScaleXProperty, [System.Windows.Media.ScaleTransform]::ScaleYProperty)) {
            $sc.BeginAnimation($p, (New-IslandAnimation 0.96 1.0 220 'out'))
        }
        $sh.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-IslandAnimation 0.0 1.0 180 'out'))
    })
    $win.Show()
    try { $win.Activate() } catch { }
}
