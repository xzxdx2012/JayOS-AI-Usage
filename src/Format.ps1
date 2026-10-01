# Format.ps1 - formatting helpers

$script:ResetGlyph = [string][char]0x21BA
# NOTE: NewBrush and New-GradientBrush require PresentationCore (loaded by overlay.ps1 before dot-sourcing).
# Format-Reset, Fmt-Tok, Fmt-Money, Remaining-Color are assembly-free and fully Pester-testable.

function NewBrush([string]$hex) {
    New-Object System.Windows.Media.SolidColorBrush (
        [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($hex))
}

function New-GradientBrush([string]$c1, [string]$c2) {
    $b = New-Object System.Windows.Media.LinearGradientBrush
    $b.StartPoint = [System.Windows.Point]::new(0,0)
    $b.EndPoint   = [System.Windows.Point]::new(1,0)
    $s1 = New-Object System.Windows.Media.GradientStop
    $s1.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($c1); $s1.Offset = 0
    $s2 = New-Object System.Windows.Media.GradientStop
    $s2.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($c2); $s2.Offset = 1
    [void]$b.GradientStops.Add($s1); [void]$b.GradientStops.Add($s2)
    return $b
}

function New-GradientBrush2([string]$c1, [string]$c2) {
    $b = New-Object System.Windows.Media.LinearGradientBrush
    $b.StartPoint = [System.Windows.Point]::new(0,0)
    $b.EndPoint   = [System.Windows.Point]::new(0.7,1)
    $s1 = New-Object System.Windows.Media.GradientStop
    $s1.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($c1); $s1.Offset = 0
    $s2 = New-Object System.Windows.Media.GradientStop
    $s2.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($c2); $s2.Offset = 1
    [void]$b.GradientStops.Add($s1); [void]$b.GradientStops.Add($s2)
    return $b
}

function Format-Reset([string]$iso) {
    if (-not $iso) { return '' }
    try {
        $span = [System.DateTimeOffset]::Parse($iso) - [System.DateTimeOffset]::Now
        if ($span.TotalSeconds -le 0) { return 'now' }
        # [math]::Floor - [int] rounds (banker's), which would tick the hours/days up a unit
        if ($span.TotalDays  -ge 1)   { return ('{0} {1}d {2}h'   -f $script:ResetGlyph, [int][math]::Floor($span.TotalDays), $span.Hours) }
        if ($span.TotalHours -ge 1)   { return ('{0} {1}h{2:00}m' -f $script:ResetGlyph, [int][math]::Floor($span.TotalHours), $span.Minutes) }
        return ('{0} {1}m' -f $script:ResetGlyph, [int][math]::Floor($span.TotalMinutes))
    } catch { return '' }
}

# Color for the remaining-% number: green -> amber -> red as capacity runs out
function Remaining-Color([double]$rem) {
    if ($rem -le 5)  { return '#F87171' }  # red   - almost out
    if ($rem -le 20) { return '#FBBF24' }  # amber - getting low
    return '#F1F5F9'                        # white - plenty left
}

function Fmt-Tok([double]$n) {
    if ($n -ge 1e6) { return ('{0:0.0}M' -f ($n / 1e6)) }
    if ($n -ge 1e3) { return ('{0:0.0}k' -f ($n / 1e3)) }
    return ('{0:0}' -f $n)
}

function Fmt-Money([double]$n) { return ('${0:N0}' -f $n) }
