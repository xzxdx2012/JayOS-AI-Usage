# ---------------------------------------------------------------------------
# Island pager. The open island shows one page at a time:
#   AI 用量 (the provider cards)  |  音乐  |  Shelf   (+ 设置 behind the gear)
# Pages slide sideways on a spring and cross-fade; the silhouette then glides
# to the new page's height and lands with a small jelly squash. Switch pages
# with the dots in the footer, a horizontal (touchpad) scroll anywhere on the
# island, the wheel over the dots, or the wheel on any page but AI (where the
# wheel keeps switching provider cards).
# ---------------------------------------------------------------------------
$script:IslandPage = 'ai'
$script:IslandLastContentPage = 'ai'
$script:IslandPagesUi = $null
$script:IslandRelayoutQueued = $false
$script:IslandPageSliding = $false
$script:IslandWheelAt = [datetime]::MinValue
$script:IslandHWheelAcc = 0
$script:IslandPageMeta = [ordered]@{
    ai       = @{ Title = 'AI 用量'; Dot = '用量' }
    music    = @{ Title = '音乐';    Dot = '音乐' }
    shelf    = @{ Title = 'Shelf';   Dot = 'Shelf' }
    settings = @{ Title = '设置';    Dot = '设置' }
}

# ---------------------------------------------------------------------------
# Spring easing for WPF animations (same feel as the notch: zeta 0.8)
# ---------------------------------------------------------------------------
function Initialize-IslandNative {
    if (([System.Management.Automation.PSTypeName]'AIUsageFrameProbe').Type) { return }
    $refs = @([System.Windows.Media.Animation.EasingFunctionBase].Assembly.Location, [System.Windows.Freezable].Assembly.Location,
              [System.Windows.Interop.HwndSource].Assembly.Location,
              [System.Collections.Generic.List[double]].Assembly.Location, [System.Diagnostics.Stopwatch].Assembly.Location,
              [System.Globalization.CultureInfo].Assembly.Location) | Where-Object { $_ } | Select-Object -Unique
    Add-Type -ReferencedAssemblies $refs -TypeDefinition @'
using System;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Animation;
public class AIUsageSpringEase : EasingFunctionBase {
    const double Z = 0.80, W = 7.5;
    static double F(double p) {
        double wd = W * Math.Sqrt(1.0 - Z * Z);
        return 1.0 - Math.Exp(-Z * W * p) * (Math.Cos(wd * p) + (Z * W / wd) * Math.Sin(wd * p));
    }
    static readonly double End = F(1.0);
    protected override double EaseInCore(double t) { return F(t) / End; }
    protected override Freezable CreateInstanceCore() { return new AIUsageSpringEase(); }
}
// Horizontal wheel (touchpad two-finger swipe) reaches the island as
// WM_MOUSEHWHEEL; WPF has no event for it. Only that message calls back.
public static class AIUsageHWheel {
    public static Action<int> OnWheel;
    static IntPtr Hook(IntPtr hwnd, int msg, IntPtr w, IntPtr l, ref bool handled) {
        if (msg == 0x020E && OnWheel != null) {
            int d = (short)((w.ToInt64() >> 16) & 0xFFFF);
            OnWheel(d);
            handled = true;
        }
        return IntPtr.Zero;
    }
    public static void Attach(HwndSource s) { s.AddHook(Hook); }
}
// Frame-time probe: records when each Rendering callback actually runs on
// the UI thread (wall clock), so a stalled UI thread shows up as a long gap.
public static class AIUsageFrameProbe {
    static System.Diagnostics.Stopwatch sw;
    static double[] t = new double[2048];
    static int n;
    static bool on;
    static TimeSpan last;
    public static void Start() {
        n = 0;
        if (on) { sw.Restart(); return; }
        sw = System.Diagnostics.Stopwatch.StartNew(); on = true;
        System.Windows.Media.CompositionTarget.Rendering += Tick;
    }
    static void Tick(object s, EventArgs e) {
        var r = e as System.Windows.Media.RenderingEventArgs;
        if (r != null) { if (r.RenderingTime == last) return; last = r.RenderingTime; }
        if (n < t.Length) t[n++] = sw.Elapsed.TotalMilliseconds;
    }
    public static string Stop() {
        if (!on) return "";
        System.Windows.Media.CompositionTarget.Rendering -= Tick;
        on = false;
        if (n < 2) return "frames=" + n;
        double max = 0, sum = 0; int slow = 0;
        var where = new System.Text.StringBuilder();
        for (int i = 1; i < n; i++) {
            double d = t[i] - t[i - 1]; sum += d; if (d > max) max = d;
            if (d > 25) { slow++; where.Append(where.Length > 0 ? "," : "").Append(i).Append(':').Append(((int)d).ToString()); }
        }
        double avg = sum / (n - 1);
        return string.Format(System.Globalization.CultureInfo.InvariantCulture,
            "frames={0} span={1:0}ms avg={2:0.0}ms (~{3:0}fps) maxGap={4:0}ms slow(>25ms)={5} [{7}] firstFrameAt={6:0}ms",
            n, t[n - 1] - t[0], avg, 1000.0 / avg, max, slow, t[0], where.ToString());
    }
}
'@
}

function Get-IslandSpringEase {
    Initialize-IslandNative
    $e = New-Object AIUsageSpringEase
    $e.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseIn
    return $e
}

function New-IslandAnimation([double]$From, [double]$To, [int]$Ms, [string]$Kind = 'spring') {
    $a = if ([double]::IsNaN($From)) { New-Object System.Windows.Media.Animation.DoubleAnimation($To, [System.Windows.Duration]([TimeSpan]::FromMilliseconds($Ms))) }
         else { New-Object System.Windows.Media.Animation.DoubleAnimation($From, $To, [System.Windows.Duration]([TimeSpan]::FromMilliseconds($Ms))) }
    if ($Kind -eq 'spring') { $a.EasingFunction = Get-IslandSpringEase }
    else {
        $ease = New-Object System.Windows.Media.Animation.CubicEase
        $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
        $a.EasingFunction = $ease
    }
    return $a
}

# Settings > 动画 hooks used by the notch engine in UnifiedTray.ps1.
function Get-NotchSpeedFactor { if ([string](Get-IslandOption 'AnimSpeed' 'normal') -eq 'fast') { return 1.35 } return 1.0 }
function Get-NotchJellyScale {
    switch ([string](Get-IslandOption 'JellyAmount' 'normal')) { 'off' { return 0.0 } 'soft' { return 0.5 } default { return 1.0 } }
}

function Get-IslandNavKeys {
    $keys = @('ai')
    if ([bool](Get-IslandOption 'PageMusic' $true)) { $keys += 'music' }
    if ([bool](Get-IslandOption 'PageShelf' $true)) { $keys += 'shelf' }
    # Plain return: callers wrap it in @(); a unary comma here would nest it.
    return $keys
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
function Initialize-IslandPages {
    if (-not $script:window) { return }
    if ($script:IslandPagesUi -and $script:IslandPagesUi.Window -eq $script:window) { return }
    $w = $script:window
    $content = $w.FindName('panelContent')
    $scroll = $w.FindName('sectionScroll')
    $footerRow = $w.FindName('footerRow')
    $header = $w.FindName('islandCollapseHeader')
    if (-not $content -or -not $scroll -or -not $footerRow -or -not $header) { Write-MediaLog 'pager: panel parts not found'; return }
    Initialize-IslandNative
    $script:MediaUi = $null

    $hostGrid = New-Object System.Windows.Controls.Grid
    $hostGrid.ClipToBounds = $true
    $idx = $content.Children.IndexOf($scroll)
    $content.Children.RemoveAt($idx)
    $content.Children.Insert($idx, $hostGrid)

    $pages = [ordered]@{}
    $ai = New-Object System.Windows.Controls.Grid
    [void]$ai.Children.Add($scroll)
    $pages['ai'] = $ai
    $pages['music'] = New-MusicPage
    $pages['shelf'] = New-ShelfPage
    foreach ($k in @($pages.Keys)) {
        $p = $pages[$k]
        $p.RenderTransform = New-Object System.Windows.Media.TranslateTransform(0, 0)
        $p.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
        $p.Visibility = $script:VisCollapsed
        [void]$hostGrid.Children.Add($p)
    }

    # Header: the AI title and its controls stay for the AI page; other pages
    # show their own title in the same place.
    $aiTitle = $null
    foreach ($c in @($header.Children)) {
        if ($c -is [System.Windows.Controls.TextBlock] -and [System.Windows.Controls.Grid]::GetColumn($c) -eq 1) { $aiTitle = $c }
    }
    $pageTitle = New-Object System.Windows.Controls.TextBlock
    $pageTitle.Foreground = NewBrush '#F5F5F7'
    $pageTitle.FontSize = 18
    $pageTitle.FontWeight = [System.Windows.FontWeights]::Bold
    $pageTitle.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
    $pageTitle.VerticalAlignment = 'Center'
    $pageTitle.Margin = New-Object System.Windows.Thickness(10, 0, 12, 1)
    $pageTitle.Visibility = $script:VisCollapsed
    $pageTitle.RenderTransform = New-Object System.Windows.Media.TranslateTransform(0, 0)
    [System.Windows.Controls.Grid]::SetColumn($pageTitle, 1)
    [void]$header.Children.Add($pageTitle)
    $aiOnly = @()
    foreach ($c in @($header.Children)) {
        $col = [System.Windows.Controls.Grid]::GetColumn($c)
        if ($col -ge 2) { $aiOnly += $c }
    }

    # Footer pager, centred: ‹  • ━ •  ›
    $nav = New-Object System.Windows.Controls.StackPanel
    $nav.Orientation = 'Horizontal'
    $nav.HorizontalAlignment = 'Center'
    $nav.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumnSpan($nav, 4)
    $prev = New-IslandNavButton -1
    $dots = New-Object System.Windows.Controls.StackPanel
    $dots.Orientation = 'Horizontal'
    $dots.VerticalAlignment = 'Center'
    $dots.Background = NewBrush '#00FFFFFF'
    $dots.Margin = New-Object System.Windows.Thickness(4, 0, 4, 0)
    $next = New-IslandNavButton 1
    # The visible dots are ONE drawn image (Set-IslandDotWidths) on top of the
    # invisible click slots, so the moving pill never re-runs layout.
    $dotsHost = New-Object System.Windows.Controls.Grid
    $dotsHost.VerticalAlignment = 'Center'
    $dotsHost.Margin = New-Object System.Windows.Thickness(4, 0, 4, 0)
    $dots.Margin = New-Object System.Windows.Thickness(0)
    $dotImg = New-Object System.Windows.Controls.Image
    $dotImg.Stretch = [System.Windows.Media.Stretch]::None
    $dotImg.HorizontalAlignment = 'Left'; $dotImg.VerticalAlignment = 'Center'
    $dotImg.IsHitTestVisible = $false
    $dotImg.SnapsToDevicePixels = $false
    [void]$dotsHost.Children.Add($dots); [void]$dotsHost.Children.Add($dotImg)
    [void]$nav.Children.Add($prev); [void]$nav.Children.Add($dotsHost); [void]$nav.Children.Add($next)
    [void]$footerRow.Children.Add($nav)
    $nav.Add_MouseWheel({ param($s, $e) $e.Handled = $true; Step-IslandPage $(if ($e.Delta -lt 0) { 1 } else { -1 }) })

    $script:IslandPagesUi = @{
        Window = $w; Host = $hostGrid; Pages = $pages; Dots = $dots; DotsHost = $dotsHost; DotImage = $dotImg; Nav = $nav; Prev = $prev; Next = $next
        AiTitle = $aiTitle; PageTitle = $pageTitle; AiOnly = $aiOnly
        Gear = $w.FindName('footerSettingsButton')
    }
    if ($script:NotchParts) { $script:NotchParts['Pages'] = $hostGrid }

    Initialize-MediaShelfRuntime
    Register-IslandHWheel
    $start = $script:IslandPage
    if (-not $pages.Contains($start) -or ($start -ne 'settings' -and (Get-IslandNavKeys) -notcontains $start)) { $start = 'ai' }
    Show-IslandPageImmediate $start
    Update-MediaView -Force
}

function Register-IslandHWheel {
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper $script:window).Handle
        if ($h -eq [IntPtr]::Zero) {
            $script:window.Add_SourceInitialized({ Register-IslandHWheel })
            return
        }
        if ($script:IslandHWheelHwnd -eq $h) { return }
        $script:IslandHWheelHwnd = $h
        [AIUsageHWheel]::OnWheel = [Action[int]]{ param($d) try { Invoke-IslandHWheel $d } catch { } }
        [AIUsageHWheel]::Attach([System.Windows.Interop.HwndSource]::FromHwnd($h))
    } catch { Write-MediaLog "hwheel hook: $($_.Exception.Message)" }
}

function Invoke-IslandHWheel([int]$Delta) {
    if ($script:NotchState -ne 'EXPANDED') { return }
    $script:IslandHWheelAcc += $Delta
    if ([math]::Abs($script:IslandHWheelAcc) -lt 120) { return }
    $dir = if ($script:IslandHWheelAcc -gt 0) { 1 } else { -1 }
    $script:IslandHWheelAcc = 0
    Step-IslandPage $dir
}

# The vertical wheel: with several AIs it steps through the provider cards on
# the AI page and is swallowed on the other pages (the arrows, the dots and a
# sideways swipe turn pages). With only one AI there are no cards to step,
# so the wheel turns the pages instead - down = next, up = previous - on
# every page. Touchpads send small steps; they add up to one notch (120).
# The footer pager handles its own wheel. Returns $true when consumed here.
$script:IslandVWheelAcc = 0
function Invoke-IslandPageWheel($EventArgs) {
    if (-not $script:IslandPagesUi) { return $false }
    $single = (Get-Command Test-SingleProviderCard -ErrorAction SilentlyContinue) -and (Test-SingleProviderCard)
    if ($single) {
        $EventArgs.Handled = $true
        $script:IslandVWheelAcc += [int]$EventArgs.Delta
        if ([math]::Abs($script:IslandVWheelAcc) -lt 120) { return $true }
        $dir = if ($script:IslandVWheelAcc -lt 0) { 1 } else { -1 }
        $script:IslandVWheelAcc = 0
        Step-IslandPage $dir
        return $true
    }
    if ($script:IslandPage -eq 'ai') { return $false }
    $EventArgs.Handled = $true
    return $true
}

function Step-IslandPage([int]$Direction) {
    if (((Get-Date) - $script:IslandWheelAt).TotalMilliseconds -lt 320) { return }
    $keys = @(Get-IslandNavKeys)
    $cur = if ($script:IslandPage -eq 'settings') { $script:IslandLastContentPage } else { $script:IslandPage }
    $i = [array]::IndexOf($keys, $cur)
    $j = [math]::Max(0, [math]::Min($keys.Count - 1, $i + $Direction))
    if ($script:IslandPage -ne 'settings' -and $j -eq $i) { return }
    $script:IslandWheelAt = Get-Date
    Switch-IslandPage $keys[$j]
}

function Get-IslandPagePosition([string]$Key) {
    $order = @(Get-IslandNavKeys) + @('settings')
    return [array]::IndexOf($order, $Key)
}

function Show-IslandPageImmediate([string]$Key) {
    $ui = $script:IslandPagesUi
    if (-not $ui -or -not $ui.Pages.Contains($Key)) { $script:IslandPage = $Key; return }
    foreach ($k in @($ui.Pages.Keys)) {
        $p = $ui.Pages[$k]
        $p.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $p.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null)
        $p.Opacity = 1.0
        $p.RenderTransform.X = 0.0
        $p.Visibility = if ($k -eq $Key) { $script:VisVisible } else { $script:VisCollapsed }
    }
    $script:IslandPage = $Key
    if ($Key -ne 'settings') { $script:IslandLastContentPage = $Key }
    Update-IslandChrome -NoAnimate
    Request-IslandRelayout
}

function Switch-IslandPage([string]$Key) {
    $ui = $script:IslandPagesUi
    if (-not $ui -or -not $ui.Pages.Contains($Key) -or $Key -eq $script:IslandPage) { return }
    if (([System.Management.Automation.PSTypeName]'AIUsageFrameProbe').Type) { [AIUsageFrameProbe]::Start(); $script:FrameProbeLabel = "page $($script:IslandPage)->$Key" }
    if ($Key -eq 'settings') { Update-SettingsPage }
    # Fill the music page before it moves, not during its first frames.
    if ($Key -eq 'music') { Update-MediaView -Force }
    $fromKey = $script:IslandPage
    $dir = if ((Get-IslandPagePosition $Key) -ge (Get-IslandPagePosition $fromKey)) { 1.0 } else { -1.0 }
    $old = $ui.Pages[$fromKey]
    $new = $ui.Pages[$Key]
    $script:IslandPage = $Key
    if ($Key -ne 'settings') { $script:IslandLastContentPage = $Key }
    $speed = if (Get-Command Get-NotchSpeedFactor -ErrorAction SilentlyContinue) { Get-NotchSpeedFactor } else { 1.0 }

    # Both pages ride ONE spring, in lockstep: the old one slides out as the
    # new one slides in by the same distance, and their opacities cross over
    # on the same curve. No layout work and no silhouette squash while it
    # runs (Nusa keeps squash for size changes); pages are bitmap-cached for
    # the slide so each frame only moves pixels.
    foreach ($k in @($ui.Pages.Keys)) { if ($k -ne $fromKey -and $k -ne $Key) { $ui.Pages[$k].Visibility = $script:VisCollapsed } }
    $new.Visibility = $script:VisVisible
    $ms = [int](440 / $speed)
    $dist = 64.0
    foreach ($p in @($old, $new)) { $p.CacheMode = New-Object System.Windows.Media.BitmapCache }
    $outX = New-IslandAnimation 0.0 (-$dist * $dir) $ms 'spring'
    $outA = New-IslandAnimation 1.0 0.0 ([int]($ms * 0.55)) 'out'
    $inX = New-IslandAnimation ($dist * $dir) 0.0 $ms 'spring'
    $inA = New-IslandAnimation 0.0 1.0 ([int]($ms * 0.55)) 'out'
    $inX.add_Completed({ try { Complete-IslandPageSwitch } catch { } })
    $old.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $outX)
    $old.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $outA)
    $new.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $inX)
    $new.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $inA)
    $script:IslandPageSliding = $true
    # Safety net in case Completed never fires (window hidden mid-slide).
    $script:IslandSlideUntil = (Get-Date).AddMilliseconds($ms + 250)
    Update-IslandChrome
}

# Slide finished: drop the old page from layout, release the bitmap caches,
# then do the (deferred) relayout. No squash here - that was the "shake".
function Complete-IslandPageSwitch {
    $ui = $script:IslandPagesUi
    if (-not $ui) { return }
    $script:IslandPageSliding = $false
    if (([System.Management.Automation.PSTypeName]'AIUsageFrameProbe').Type) { $fp = [AIUsageFrameProbe]::Stop(); if ($fp) { Write-MediaLog ("frames {0}: {1}" -f $script:FrameProbeLabel, $fp) } }
    foreach ($k in @($ui.Pages.Keys)) {
        $p = $ui.Pages[$k]
        $p.CacheMode = $null
        if ($k -eq $script:IslandPage) { continue }
        $p.Visibility = $script:VisCollapsed
        $p.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $p.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null)
        $p.Opacity = 1.0
        $p.RenderTransform.X = 0.0
    }
    Request-IslandRelayout
}

function Request-IslandPageLayout([string]$Key) {
    if (-not $Key -or $Key -eq $script:IslandPage) { Request-IslandRelayout }
}

# AI, 音乐 and Shelf share one content height: the tallest of the three,
# measured at the host's width. Each page is briefly made visible to be
# measured (a collapsed element measures as 0) and put back in the same
# synchronous pass, so nothing flickers. Settings keeps its own height.
$script:IslandPageHeight = 0.0
function Sync-IslandPageHeights {
    $ui = $script:IslandPagesUi
    if (-not $ui) { return }
    $hostGrid = $ui.Host
    $width = [double]$hostGrid.ActualWidth
    if ($width -le 0) { return }
    $max = 0.0
    $seen = @()
    foreach ($k in @(Get-IslandNavKeys)) {
        $p = $ui.Pages[$k]
        if (-not $p) { continue }
        $vis = $p.Visibility
        $savedMin = $p.MinHeight
        try {
            $p.MinHeight = 0
            if ($vis -ne $script:VisVisible) { $p.Visibility = $script:VisVisible }
            $p.Measure((New-Object System.Windows.Size($width, [double]::PositiveInfinity)))
            $h = [double]$p.DesiredSize.Height
            $seen += ('{0}={1:0.#}' -f $k, $h)
            if ($h -gt $max) { $max = $h }
        } finally {
            if ($vis -ne $script:VisVisible) { $p.Visibility = $vis }
            $p.MinHeight = $savedMin
        }
    }
    if ($max -le 0) { return }
    $max = [math]::Ceiling($max)
    foreach ($k in @(Get-IslandNavKeys)) {
        $p = $ui.Pages[$k]
        if ($p -and [math]::Abs([double]$p.MinHeight - $max) -gt 0.5) { $p.MinHeight = $max }
    }
    if ($ui.Pages['settings'] -and $ui.Pages['settings'].MinHeight -ne 0) { $ui.Pages['settings'].MinHeight = 0 }
    if ($max -ne $script:IslandPageHeight) {
        $script:IslandPageHeight = $max
        Write-MediaLog ("page height {0} (natural: {1}; width {2:0})" -f $max, ($seen -join ', '), $width)
    }
}

function Request-IslandRelayout {
    # Mid-slide relayouts were part of the jank; the slide's end requests one.
    if ($script:IslandPageSliding -and (Get-Date) -lt $script:IslandSlideUntil) { return }
    $script:IslandPageSliding = $false
    if ($script:IslandRelayoutQueued -or -not $script:window) { return }
    $script:IslandRelayoutQueued = $true
    [void]$script:window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{
        $script:IslandRelayoutQueued = $false
        try { Sync-IslandPageHeights } catch { }
        try {
            if ((Get-Command Test-NotchShell -ErrorAction SilentlyContinue) -and (Test-NotchShell)) { Update-NotchStageLayout }
            elseif (Get-Command Resize-ToContent -ErrorAction SilentlyContinue) { Resize-ToContent }
        } catch { }
    })
}

# Title, AI-only header controls, dots and the gear follow the page.
function Update-IslandChrome([switch]$NoAnimate) {
    $ui = $script:IslandPagesUi
    if (-not $ui) { return }
    $key = $script:IslandPage
    $isAi = ($key -eq 'ai')
    if ($ui.AiTitle) { $ui.AiTitle.Visibility = if ($isAi) { $script:VisVisible } else { $script:VisCollapsed } }
    $ui.PageTitle.Visibility = if ($isAi) { $script:VisCollapsed } else { $script:VisVisible }
    $ui.PageTitle.Text = [string]$script:IslandPageMeta[$key].Title
    foreach ($el in $ui.AiOnly) { $el.Visibility = if ($isAi) { $script:VisVisible } else { $script:VisHidden } }
    if (-not $NoAnimate -and -not $isAi) {
        $ui.PageTitle.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, (New-IslandAnimation 6.0 0.0 360 'spring'))
        $ui.PageTitle.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-IslandAnimation 0.0 1.0 220 'out'))
    }
    Update-IslandDots -NoAnimate:$NoAnimate
    Update-FooterNowPlaying
}

# Round ‹ / › button that steps one page; pressed it dips and springs back.
function New-IslandNavButton([int]$Direction) {
    $b = New-Object System.Windows.Controls.Border
    $b.Width = 26; $b.Height = 26
    $b.CornerRadius = New-Object System.Windows.CornerRadius(13)
    $b.Background = NewBrush '#14FFFFFF'
    $b.Cursor = [System.Windows.Input.Cursors]::Hand
    $b.VerticalAlignment = 'Center'
    $b.Tag = $Direction
    $b.ToolTip = if ($Direction -lt 0) { '上一页' } else { '下一页' }
    $b.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
    $b.RenderTransform = New-Object System.Windows.Media.ScaleTransform(1, 1)
    $p = New-Object System.Windows.Shapes.Path
    $p.Data = [System.Windows.Media.Geometry]::Parse($(if ($Direction -lt 0) { 'M9.5,3.5 L5,8 L9.5,12.5' } else { 'M6.5,3.5 L11,8 L6.5,12.5' }))
    $p.Stroke = NewBrush '#E5E5EA'
    $p.StrokeThickness = 1.8
    $p.StrokeStartLineCap = 'Round'; $p.StrokeEndLineCap = 'Round'; $p.StrokeLineJoin = 'Round'
    $p.Width = 16; $p.Height = 16
    $p.HorizontalAlignment = 'Center'; $p.VerticalAlignment = 'Center'
    $b.Child = $p
    $b.Add_MouseEnter({ param($s, $e) if ($s.Opacity -gt 0.5) { $s.Background = NewBrush '#2AFFFFFF' } })
    $b.Add_MouseLeave({ param($s, $e) $s.Background = NewBrush '#14FFFFFF' })
    # Page turns on press (no wait for release); the button pops back on release.
    $b.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; Invoke-PressPop $s 0.86; $script:IslandWheelAt = [datetime]::MinValue; Step-IslandPage ([int]$s.Tag) })
    $b.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Invoke-PressPop $s 1.0 })
    return $b
}

# Page dots: one position value P (fractional page index) drives every dot.
# Dot i is 7 + 15 * max(0, 1 - |i - P|) wide, so while the pill travels from
# one page to the next the two dots trade exactly what one gains and the
# other loses - the row's total width never changes. (Before, each dot had
# its own spring and its own pixel rounding; the sum wobbled by a pixel or
# two each frame and the centred pager visibly shook, worst on fast wheel
# steps that restarted the springs mid-way.) P moves on the island spring,
# one frame callback, and a new target simply continues from where P is.
$script:IslandDotPos = -1.0
$script:IslandDotAnim = $null
$script:IslandDotRender = $null
# "No page active" (the old settings page) is the explicit -1 target only.
# The spring overshoots its target a little, so on the way to the FIRST page
# P dips just below 0 for a few frames; treating that as "none" made the pill
# vanish and come back - the flicker when going from page 2 to page 1. The
# overshoot is clamped to the first/last dot instead.
function Set-IslandDotWidths([double]$Pos) {
    $ui = $script:IslandPagesUi
    if (-not $ui -or -not $ui.DotImage) { return }
    $count = @($ui.Dots.Children).Count
    if ($count -lt 1) { $ui.DotImage.Source = $null; return }
    $none = ($Pos -le -0.5)
    if (-not $none) { $Pos = [math]::Max(0.0, [math]::Min([double]($count - 1), $Pos)) }
    # Exact (sub-pixel) positions, drawn - nothing is laid out or rounded per
    # frame, so no dot can shiver by a pixel. Dot i: 7 + 15*near wide, with a
    # 10 DIP gap; the row always spans the same 36 + 10*count DIP.
    $rowW = [double]($count - 1) * 17.0 + 32.0
    $grp = New-Object System.Windows.Media.DrawingGroup
    # A transparent full-size rectangle pins the image bounds to the row.
    $grp.Children.Add((New-Object System.Windows.Media.GeometryDrawing([System.Windows.Media.Brushes]::Transparent, $null,
        (New-Object System.Windows.Media.RectangleGeometry((New-Object System.Windows.Rect(0, 0, $rowW, 7)))))))
    $x = 5.0
    for ($i = 0; $i -lt $count; $i++) {
        $near = if ($none) { 0.0 } else { [math]::Max(0.0, 1.0 - [math]::Abs($i - $Pos)) }
        $w = 7.0 + 15.0 * $near
        # Colour follows the same curve: dim dot (white 30%) -> bright pill.
        $alpha = if ($none) { 0x33 } else { [byte][math]::Round(0x4D + (0xFF - 0x4D) * $near) }
        $lum = [byte][math]::Round(0xFF - (0xFF - 0xF5) * $near)
        $brush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb($alpha, $lum, $lum, [byte][math]::Round(0xFF - (0xFF - 0xF7) * $near)))
        $brush.Freeze()
        $geo = New-Object System.Windows.Media.RectangleGeometry((New-Object System.Windows.Rect($x, 0, $w, 7)), 3.5, 3.5)
        $grp.Children.Add((New-Object System.Windows.Media.GeometryDrawing($brush, $null, $geo)))
        $x += $w + 10.0
    }
    $grp.Freeze()
    $img = New-Object System.Windows.Media.DrawingImage($grp)
    $img.Freeze()
    $ui.DotImage.Source = $img
}function Start-IslandDotMotion([double]$Target, [switch]$NoAnimate) {
    $ui = $script:IslandPagesUi
    if (-not $ui) { return }
    if ($NoAnimate -or $script:IslandDotPos -le -0.5 -or $Target -le -0.5) {
        $script:IslandDotAnim = $null
        $script:IslandDotPos = $Target
        Set-IslandDotWidths $Target
        return
    }
    if ([math]::Abs($Target - $script:IslandDotPos) -lt 0.001 -and -not $script:IslandDotAnim) { Set-IslandDotWidths $Target; return }
    $speed = if (Get-Command Get-NotchSpeedFactor -ErrorAction SilentlyContinue) { Get-NotchSpeedFactor } else { 1.0 }
    $script:IslandDotAnim = @{ From = [double]$script:IslandDotPos; To = $Target; Ms = (420.0 / $speed)
        Clock = [System.Diagnostics.Stopwatch]::StartNew(); Ease = (Get-IslandSpringEase) }
    if (-not $script:IslandDotRender) {
        $script:IslandDotRender = [EventHandler]{
            param($s, $e)
            try {
                $a = $script:IslandDotAnim
                if (-not $a) { Stop-IslandDotRender; return }
                $tt = [math]::Min(1.0, $a.Clock.Elapsed.TotalMilliseconds / [double]$a.Ms)
                $pos = if ($tt -ge 1.0) { $a.To } else { $a.From + ($a.To - $a.From) * $a.Ease.Ease($tt) }
                $script:IslandDotPos = $pos
                Set-IslandDotWidths $pos
                if ($tt -ge 1.0) { $script:IslandDotAnim = $null; Stop-IslandDotRender }
            } catch { $script:IslandDotAnim = $null; Stop-IslandDotRender }
        }
        [System.Windows.Media.CompositionTarget]::add_Rendering($script:IslandDotRender)
    }
}
function Stop-IslandDotRender {
    if ($script:IslandDotRender) {
        try { [System.Windows.Media.CompositionTarget]::remove_Rendering($script:IslandDotRender) } catch { }
        $script:IslandDotRender = $null
    }
}

function Update-IslandDots([switch]$NoAnimate) {
    $ui = $script:IslandPagesUi
    if (-not $ui) { return }
    $keys = @(Get-IslandNavKeys)
    $dots = $ui.Dots
    $sig = ($keys -join ',')
    if ([string]$dots.Tag -ne $sig) {
        $dots.Tag = $sig
        $dots.Children.Clear()
        foreach ($k in $keys) {
            # A roomy transparent hit area around each small dot.
            # An invisible, fixed-size click slot; the dot itself is drawn.
            $hit = New-Object System.Windows.Controls.Border
            $hit.Background = NewBrush '#00FFFFFF'
            $hit.Height = 25
            $hit.Width = 66.0 / [math]::Max(1, $keys.Count)
            $hit.Cursor = [System.Windows.Input.Cursors]::Hand
            $hit.Tag = $k
            $hit.ToolTip = [string]$script:IslandPageMeta[$k].Dot
            $hit.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; Switch-IslandPage ([string]$s.Tag) })
            $hit.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true })
            [void]$dots.Children.Add($hit)
        }
    }
    # The row has a fixed width - every slot is the dot plus 10 DIP of hit area,
    # one dot is the 22 DIP pill - so the centred pager (arrows included) can
    # never shift while the pill moves.
    $rowW = [double]($keys.Count - 1) * 17.0 + 32.0
    $dots.Width = $rowW
    if ($ui.DotsHost) { $ui.DotsHost.Width = $rowW }
    foreach ($hit in @($dots.Children)) { $hit.Width = $rowW / [math]::Max(1, $keys.Count) }
    $active = if ($script:IslandPage -eq 'settings') { '' } else { $script:IslandPage }
    $target = if ($active) { [double][array]::IndexOf($keys, $active) } else { -1.0 }
    Start-IslandDotMotion $target -NoAnimate:$NoAnimate
    # Arrows dim at the ends (from settings both lead back into the pages).
    $cur = if ($script:IslandPage -eq 'settings') { '' } else { $script:IslandPage }
    $i = if ($cur) { [array]::IndexOf($keys, $cur) } else { -1 }
    foreach ($pair in @(@($ui.Prev, ($cur -eq '' -or $i -gt 0)), @($ui.Next, ($cur -eq '' -or $i -lt $keys.Count - 1)))) {
        if (-not $pair[0]) { continue }
        # Stay hit-testable even when dimmed, so a click there never turns
        # into a window drag; Step-IslandPage simply does nothing at the end.
        $pair[0].Opacity = if ($pair[1]) { 1.0 } else { 0.3 }
        $pair[0].Cursor = if ($pair[1]) { [System.Windows.Input.Cursors]::Hand } else { $null }
    }
    if ($ui.Nav) { $ui.Nav.Visibility = if ($keys.Count -gt 1) { $script:VisVisible } else { $script:VisHidden } }
}

# Footer, left: while music plays and another page is showing, the brand
# text becomes "♪ title – artist"; a click on it opens the music page.
function Update-FooterNowPlaying {
    if (-not $script:window) { return }
    $label = $script:window.FindName('brandLabel')
    if (-not $label) { return }
    if (-not $script:FooterNowPlayingWired) {
        $script:FooterNowPlayingWired = $true
        $label.Add_MouseLeftButtonDown({
            param($s, $e)
            if ($s.Tag -is [hashtable] -and $s.Tag.Music) { $e.Handled = $true; Switch-IslandPage 'music' }
        })
    }
    if ($label.Tag -isnot [hashtable]) { $label.Tag = @{ Music = $false; Brand = [string]$label.Text } }
    # Left-aligned always: a Stretch element under a MaxWidth centres itself
    # in its column, which pushed "JayOS" towards the middle of the footer.
    if ($label.HorizontalAlignment -ne [System.Windows.HorizontalAlignment]::Left) { $label.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left }
    $show = $script:IslandPagesUi -and $script:IslandPage -ne 'music' -and
            ((Get-IslandNavKeys) -contains 'music') -and (Test-MediaActive)
    if ($show) {
        if (-not $label.Tag.Music) { $label.Tag.Brand = [string]$label.Text }
        $s = $script:MediaState
        $label.Tag.Music = $true
        $label.Text = '♪  ' + ((@([string]$s.Title, [string]$s.Artist) | Where-Object { $_ }) -join ' – ')
        $label.TextTrimming = 'CharacterEllipsis'
        $label.MaxWidth = 210
        $label.Foreground = NewBrush $(if ([string]$s.Status -eq 'Playing') { '#E5E5EA' } else { '#8E8E93' })
        $label.Cursor = [System.Windows.Input.Cursors]::Hand
        $label.ToolTip = '打开音乐页'
    } elseif ($label.Tag.Music) {
        $label.Tag.Music = $false
        $label.Text = [string]$label.Tag.Brand
        $label.MaxWidth = [double]::PositiveInfinity
        $label.Foreground = NewBrush '#A1A1A6'
        $label.Cursor = $null
        $label.ToolTip = $null
    }
}

# Footer gear (bottom right): the original JayOS settings menu. The island's
# own options live there too, in its "灵动岛" group - no separate page.
function Invoke-FooterGear($EventArgs) {
    # Apple-style settings sheet (src\AppleSettings.ps1), built from the same
    # menu items; the classic menu stays as the fallback and on the tray icon.
    if (Get-Command Show-AppleSettings -ErrorAction SilentlyContinue) {
        try { Show-AppleSettings $EventArgs; return } catch { try { Write-Log ("apple settings: " + $_.Exception.Message) } catch { } }
    }
    Show-ContextMenuAtWpfPointer $EventArgs
}

# ---------------------------------------------------------------------------
# Settings page
# ---------------------------------------------------------------------------
function Set-IslandOption([string]$Key, $Value) {
    $script:Cfg[$Key] = $Value
    try { Save-UnifiedState } catch { }
    switch ($Key) {
        { $_ -in @('PageMusic', 'PageShelf') } {
            # A page that was switched off cannot stay on screen.
            if ((Get-IslandNavKeys) -notcontains $script:IslandPage) { Show-IslandPageImmediate 'ai' } else { Update-IslandDots }
        }
        { $_ -in @('NotchMusic', 'NotchLyrics') } { if (Get-Command Update-NotchMediaBadge -ErrorAction SilentlyContinue) { Update-NotchMediaBadge -Force } }
        'ClipHistory' { if (-not $Value) { $script:ClipItems.Clear() }; Update-ShelfView }
        'MusicLyrics' { $script:LyricsKey = ''; $script:LyricsLines = @(); $script:LyricIndex = -2; $script:MediaActiveShown = $null; Update-MediaView -Force }
    }
    Update-SettingsPage
}

function New-SettingsCard([string]$Title) {
    $card = New-Object System.Windows.Controls.Border
    try { $card.Style = $script:window.FindResource('Card') } catch { }
    $card.Margin = New-Object System.Windows.Thickness(0, 0, 0, 0)
    $card.Padding = New-Object System.Windows.Thickness(14, 11, 14, 8)
    $stack = New-Object System.Windows.Controls.StackPanel
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Title
    $t.Foreground = NewBrush '#8E8E93'
    $t.FontSize = 11.5
    $t.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI Semibold')
    $t.Margin = New-Object System.Windows.Thickness(0, 0, 0, 6)
    [void]$stack.Children.Add($t)
    $card.Child = $stack
    return @{ Card = $card; Stack = $stack }
}

function New-SettingsLabel([string]$Title, [string]$Desc) {
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.VerticalAlignment = 'Center'
    $a = New-Object System.Windows.Controls.TextBlock
    $a.Text = $Title; $a.Foreground = NewBrush '#F5F5F7'; $a.FontSize = 13
    $a.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
    [void]$sp.Children.Add($a)
    if ($Desc) {
        $b = New-Object System.Windows.Controls.TextBlock
        $b.Text = $Desc; $b.Foreground = NewBrush '#8E8E93'; $b.FontSize = 11; $b.TextWrapping = 'Wrap'
        $b.Margin = New-Object System.Windows.Thickness(0, 1, 12, 0)
        [void]$sp.Children.Add($b)
    }
    return $sp
}

function New-SettingsRow($Left, $Right) {
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = New-Object System.Windows.Thickness(0, 5, 0, 5)
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = New-Object System.Windows.GridLength(1, 'Star')
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::Auto
    $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)
    [void]$g.Children.Add($Left)
    [System.Windows.Controls.Grid]::SetColumn($Right, 1)
    $Right.VerticalAlignment = 'Center'
    [void]$g.Children.Add($Right)
    return $g
}

# An iOS-style switch whose knob travels on the island spring.
function New-SettingsToggle([string]$Key, [bool]$Default) {
    $track = New-Object System.Windows.Controls.Border
    $track.Width = 40; $track.Height = 24
    $track.CornerRadius = New-Object System.Windows.CornerRadius(12)
    $track.Cursor = [System.Windows.Input.Cursors]::Hand
    $track.Tag = @{ Key = $Key; Default = $Default; Kind = 'toggle' }
    $knob = New-Object System.Windows.Shapes.Ellipse
    $knob.Width = 20; $knob.Height = 20
    $knob.Fill = NewBrush '#FFFFFF'
    $knob.HorizontalAlignment = 'Left'
    $knob.VerticalAlignment = 'Center'
    $knob.RenderTransform = New-Object System.Windows.Media.TranslateTransform(2, 0)
    $track.Child = $knob
    $track.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
    $track.Add_MouseLeftButtonUp({
        param($s, $e)
        $e.Handled = $true
        $k = [string]$s.Tag.Key
        Set-IslandOption $k (-not [bool](Get-IslandOption $k $s.Tag.Default))
    })
    return $track
}

function Sync-SettingsToggle($Track, [switch]$Animate) {
    $on = [bool](Get-IslandOption ([string]$Track.Tag.Key) $Track.Tag.Default)
    $Track.Background = NewBrush $(if ($on) { '#30D158' } else { '#3A3A3C' })
    $x = if ($on) { 18.0 } else { 2.0 }
    $tt = $Track.Child.RenderTransform
    if ($Animate) { $tt.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, (New-IslandAnimation ([double]$tt.X) $x 380 'spring')) }
    else { $tt.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null); $tt.X = $x }
}

function New-SettingsSegment([string]$Key, [string]$Default, [object[]]$Options) {
    $outer = New-Object System.Windows.Controls.Border
    $outer.Background = NewBrush '#1C1C1E'
    $outer.CornerRadius = New-Object System.Windows.CornerRadius(9)
    $outer.Padding = New-Object System.Windows.Thickness(2)
    $outer.Tag = @{ Key = $Key; Default = $Default; Kind = 'segment' }
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    foreach ($o in $Options) {
        $b = New-Object System.Windows.Controls.Border
        $b.CornerRadius = New-Object System.Windows.CornerRadius(7)
        $b.Padding = New-Object System.Windows.Thickness(11, 4, 11, 4)
        $b.Cursor = [System.Windows.Input.Cursors]::Hand
        $b.Tag = @{ Key = $Key; Value = [string]$o[0] }
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = [string]$o[1]; $t.FontSize = 12
        $b.Child = $t
        $b.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
        $b.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Set-IslandOption ([string]$s.Tag.Key) ([string]$s.Tag.Value) })
        [void]$row.Children.Add($b)
    }
    $outer.Child = $row
    return $outer
}

function Sync-SettingsSegment($Outer) {
    $cur = [string](Get-IslandOption ([string]$Outer.Tag.Key) $Outer.Tag.Default)
    foreach ($b in @($Outer.Child.Children)) {
        $on = ([string]$b.Tag.Value -eq $cur)
        $b.Background = NewBrush $(if ($on) { '#3A3A3C' } else { '#00FFFFFF' })
        $b.Child.Foreground = NewBrush $(if ($on) { '#F5F5F7' } else { '#8E8E93' })
    }
}

function New-SettingsPage {
    # 2 x 2 uniform grid: every cell takes the size of the largest card, so
    # all four cards line up with identical width and height. Cards carry a
    # 5-DIP margin each (10-DIP gutters); the grid pulls back 5 at the edges.
    $grid = New-Object System.Windows.Controls.Primitives.UniformGrid
    $grid.Rows = 2
    $grid.Columns = 2
    $grid.Margin = New-Object System.Windows.Thickness(-5, -5, -5, -5)
    $controls = New-Object System.Collections.ArrayList
    $cards = @{}

    $g = New-SettingsCard '页面'
    $t = New-SettingsToggle 'PageMusic' $true; [void]$controls.Add($t)
    [void]$g.Stack.Children.Add((New-SettingsRow (New-SettingsLabel '音乐' '正在播放的歌曲、控制和歌词') $t))
    $t = New-SettingsToggle 'PageShelf' $true; [void]$controls.Add($t)
    [void]$g.Stack.Children.Add((New-SettingsRow (New-SettingsLabel 'Shelf' '暂存拖进来的文件和最近复制的文字') $t))
    $cards.Pages = $g.Card

    $g = New-SettingsCard '动画'
    $s = New-SettingsSegment 'AnimSpeed' 'normal' @(@('normal', '标准'), @('fast', '快速')); [void]$controls.Add($s)
    [void]$g.Stack.Children.Add((New-SettingsRow (New-SettingsLabel '速度' '展开、收起和翻页') $s))
    $s = New-SettingsSegment 'JellyAmount' 'normal' @(@('off', '关'), @('soft', '柔和'), @('normal', '标准')); [void]$controls.Add($s)
    [void]$g.Stack.Children.Add((New-SettingsRow (New-SettingsLabel '果冻回弹' '落定时轻轻鼓一下再停住') $s))
    $cards.Anim = $g.Card

    $g = New-SettingsCard '音乐与 Shelf'
    $t = New-SettingsToggle 'MusicLyrics' $true; [void]$controls.Add($t)
    [void]$g.Stack.Children.Add((New-SettingsRow (New-SettingsLabel '同步歌词' '来自 LRCLIB，会发送歌名、歌手和时长') $t))
    $t = New-SettingsToggle 'ClipHistory' $true; [void]$controls.Add($t)
    [void]$g.Stack.Children.Add((New-SettingsRow (New-SettingsLabel '剪贴板历史' '最近 20 段文字，只存在内存里') $t))
    $cards.Media = $g.Card

    $g = New-SettingsCard '更多'
    $more = New-Object System.Windows.Controls.Border
    $more.CornerRadius = New-Object System.Windows.CornerRadius(9)
    $more.Background = NewBrush '#1C1C1E'
    $more.Padding = New-Object System.Windows.Thickness(12, 5, 12, 5)
    $more.Cursor = [System.Windows.Input.Cursors]::Hand
    $mt = New-Object System.Windows.Controls.TextBlock
    $mt.Text = '全部设置 ›'; $mt.Foreground = NewBrush '#F5F5F7'; $mt.FontSize = 12
    $more.Child = $mt
    $more.Add_MouseEnter({ param($s, $e) $s.Background = NewBrush '#2C2C2E' })
    $more.Add_MouseLeave({ param($s, $e) $s.Background = NewBrush '#1C1C1E' })
    $more.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
    $more.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Show-ContextMenuAtWpfPointer $e })
    [void]$g.Stack.Children.Add((New-SettingsRow (New-SettingsLabel '外观、语言、账户和提醒' '主题、显示哪些 AI、快捷键等') $more))
    # Second row so this card carries the same two rows as the others.
    $ver = New-Object System.Windows.Controls.TextBlock
    $vl = $script:window.FindName('versionLabel')
    $ver.Text = if ($vl -and $vl.Text) { [string]$vl.Text } else { '' }
    $ver.Foreground = NewBrush '#8E8E93'; $ver.FontSize = 12
    [void]$g.Stack.Children.Add((New-SettingsRow (New-SettingsLabel '关于' 'JayOS AI 用量灵动岛') $ver))
    $cards.More = $g.Card

    # Row-major: 页面 | 音乐与 Shelf  /  动画 | 更多
    foreach ($c in @($cards.Pages, $cards.Media, $cards.Anim, $cards.More)) {
        $c.Margin = New-Object System.Windows.Thickness(5)
        $c.VerticalAlignment = [System.Windows.VerticalAlignment]::Stretch
        $c.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
        [void]$grid.Children.Add($c)
    }

    $script:SettingsControls = $controls
    Update-SettingsPage -NoAnimate
    return $grid
}

function Update-SettingsPage([switch]$NoAnimate) {
    if (-not $script:SettingsControls) { return }
    foreach ($c in @($script:SettingsControls)) {
        if ($c.Tag.Kind -eq 'toggle') { Sync-SettingsToggle $c -Animate:(-not $NoAnimate) } else { Sync-SettingsSegment $c }
    }
}
