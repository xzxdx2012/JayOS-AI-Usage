# Layout.ps1 - vertical-fit math for the pinned overlay.
#
# With every provider expanded the accordion wants ~912 DIP, which overflows a
# 1536x864 work area (816 DIP). Shell.ps1 measures, this decides how much the
# scrollable section region has to give up. Deliberately free of WPF types so it
# stays Pester-testable; callers pass in measured doubles.

# Matches the 16px inset Snap-ToCorner uses, so a clamped window still lands
# flush with a corner instead of butting against the taskbar.
$script:LayoutCornerInset = 16.0
# Work area we assume when the real one is unreadable (window not yet sourced):
# the shortest display we care about supporting.
$script:LayoutFallbackWorkAreaHeight = 720.0
# Below this the scroll region stops giving ground - a sliver of content that
# cannot show a single metric row is worse than a window that overhangs.
$script:LayoutMinScrollHeight = 120.0

function Test-LayoutFinite($value) {
    if ($null -eq $value) { return $false }
    try {
        $d = [double]$value
        return -not [double]::IsNaN($d) -and -not [double]::IsInfinity($d)
    } catch {
        return $false
    }
}

# Tallest the window may be on this monitor: work area less the corner inset at
# top and bottom.
function Get-FitBudget {
    param(
        [double]$WorkAreaHeight,
        [double]$Inset = $script:LayoutCornerInset
    )
    if (-not (Test-LayoutFinite $WorkAreaHeight) -or $WorkAreaHeight -le 0) {
        $WorkAreaHeight = $script:LayoutFallbackWorkAreaHeight
    }
    return [math]::Max(0.0, $WorkAreaHeight - (2.0 * $Inset))
}

# MaxHeight for the section ScrollViewer, or $null when the content fits and no
# clamp should be applied. The chrome (header, footer, stripe, margins) is fixed,
# so the entire overflow comes out of the scroll region.
function Get-SectionScrollMaxHeight {
    param(
        [double]$DesiredTotal,
        [double]$ScrollNatural,
        [double]$Budget,
        [double]$MinScroll = $script:LayoutMinScrollHeight
    )
    if (-not (Test-LayoutFinite $DesiredTotal))  { return $null }
    if (-not (Test-LayoutFinite $ScrollNatural)) { return $null }
    if (-not (Test-LayoutFinite $Budget) -or $Budget -le 0) { return $null }

    $overflow = $DesiredTotal - $Budget
    if ($overflow -le 0) { return $null }

    return [math]::Max($MinScroll, $ScrollNatural - $overflow)
}

# Final window height once the scroll region has absorbed what it can.
function Get-ClampedWindowHeight {
    param(
        [double]$DesiredTotal,
        [double]$Budget
    )
    if (-not (Test-LayoutFinite $DesiredTotal)) { return $DesiredTotal }
    if (-not (Test-LayoutFinite $Budget) -or $Budget -le 0) { return $DesiredTotal }
    return [math]::Min($DesiredTotal, $Budget)
}

# The sub-label under each bar earns its ~12 DIP only when it says something the
# bar does not. Set-SectionBar writes 'used' in the ordinary case and swaps in
# 'high'/'critical!' past the thresholds; Cursor writes a request count there.
# Anything that is not the plain 'used' filler stays on screen.
function Test-BarSubVisible([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return ($Text.Trim().ToLowerInvariant() -ne 'used')
}
