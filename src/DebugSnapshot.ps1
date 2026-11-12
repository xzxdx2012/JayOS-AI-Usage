# ---------------------------------------------------------------------------
# Background self-check: drop a file named "snapshot.request" in the app
# folder (one card key per line - claude, codex, cursor, deepseek - or empty
# for the current view) and the overlay renders its own window to PNGs in
# "debug-snapshots\". Nothing on screen is clicked; only this app is drawn.
# A line "settings" also renders the settings sheet.
# ---------------------------------------------------------------------------
$script:SnapQueue = $null
$script:SnapWaitUntil = [DateTime]::MinValue

function Save-SnapshotPng($Element, [string]$Name) {
    if (-not $Element) { return }
    $w = [math]::Ceiling([double]$Element.ActualWidth); $h = [math]::Ceiling([double]$Element.ActualHeight)
    if ($w -lt 2 -or $h -lt 2) {
        # Not laid out (collapsed island): measure at its natural size.
        $Element.Measure((New-Object System.Windows.Size(720, 2000)))
        $Element.Arrange((New-Object System.Windows.Rect(0, 0, $Element.DesiredSize.Width, $Element.DesiredSize.Height)))
        $w = [math]::Ceiling($Element.DesiredSize.Width); $h = [math]::Ceiling($Element.DesiredSize.Height)
    }
    if ($w -lt 2 -or $h -lt 2) { return }
    $dpi = 96.0 * 1.5
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]($w * 1.5), [int]($h * 1.5), $dpi, $dpi, [System.Windows.Media.PixelFormats]::Pbgra32)
    # Dark backing so translucent panels read the way they do on screen.
    $dv = New-Object System.Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $dc.DrawRectangle((NewBrush '#FF1A1A1E'), $null, (New-Object System.Windows.Rect(0, 0, $w, $h)))
    $dc.DrawRectangle((New-Object System.Windows.Media.VisualBrush($Element)), $null, (New-Object System.Windows.Rect(0, 0, $w, $h)))
    $dc.Close()
    $rtb.Render($dv)
    $dir = Join-Path $script:AppDir 'debug-snapshots'
    if (-not (Test-Path $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [System.IO.File]::Create((Join-Path $dir ($Name + '.png')))
    try { $enc.Save($fs) } finally { $fs.Dispose() }
    try { $Element.InvalidateMeasure() } catch { }
}

function Invoke-SnapshotTick {
    $req = Join-Path $script:AppDir 'snapshot.request'
    if ($null -eq $script:SnapQueue) {
        if (-not (Test-Path $req)) { return }
        $lines = @(Get-Content $req -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        Remove-Item $req -Force -ErrorAction SilentlyContinue
        if (-not $lines.Count) { $lines = @('current') }
        $script:SnapQueue = New-Object System.Collections.Queue
        # Put the user's card (and saved LastCard) back when done.
        $script:SnapRestoreCard = [string]$script:AccordionKey; $script:SnapSuppressSave = $true
        foreach ($l in $lines) { $script:SnapQueue.Enqueue(@{ Key = $l; Switched = $false }) }
    }
    if ([DateTime]::UtcNow -lt $script:SnapWaitUntil) { return }
    if ($script:SnapQueue.Count -eq 0) {
        $script:SnapQueue = $null
        try {
            if ($script:SnapRestoreCard -and [string]$script:AccordionKey -ne $script:SnapRestoreCard) { Set-AccordionCard $script:SnapRestoreCard }
        } catch { }
        $script:SnapSuppressSave = $false
        return
    }
    $job = $script:SnapQueue.Peek()
    try {
        $k = [string]$job.Key
        if ($k -eq 'settings') {
            if (-not $job.Switched) {
                $job.Switched = $true
                if (-not $script:AppleSettingsWin) { Show-AppleSettings $null }
                $script:SnapWaitUntil = [DateTime]::UtcNow.AddMilliseconds(900); return
            }
            if ($script:AppleSettingsWin) { $aw = $script:AppleSettingsWin; $sh = $aw.FindName('sheet'); $wa = [System.Windows.SystemParameters]::WorkArea; Write-Log ("snapshot settings: win {0:0.#}x{1:0.#} at {2:0.#},{3:0.#} actual {4:0.#}x{5:0.#}; sheet {6:0.#}x{7:0.#}; child {8:0.#}; workarea {9}; opacity {10:0.##} scale {11:0.###}" -f $aw.Width, $aw.Height, $aw.Left, $aw.Top, $aw.ActualWidth, $aw.ActualHeight, $sh.ActualWidth, $sh.ActualHeight, $sh.Child.ActualHeight, $wa, $sh.Opacity, $aw.FindName('sheetScale').ScaleX) }
            if ($script:AppleSettingsWin) { Save-SnapshotPng $script:AppleSettingsWin.Content 'settings'; Close-AppleSettings }
            [void]$script:SnapQueue.Dequeue(); return
        }
        if ($k -eq 'frames-ai') {
            # Record the panel every rendered frame during music -> ai.
            if (-not $job.Switched) {
                $job.Switched = $true; $job.Step = 0
                $script:IslandWheelAt = [datetime]::MinValue
                if ($script:IslandPage -ne 'music') { Switch-IslandPage 'music' }
                $script:SnapWaitUntil = [DateTime]::UtcNow.AddMilliseconds(1200); return
            }
            if ($job.Step -eq 0) {
                $job.Step = 1
                $dir = Join-Path $script:AppDir 'debug-snapshots\frames'
                if (-not (Test-Path $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
                Get-ChildItem $dir -Filter 'f*.png' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                $script:FrameRec = @{ Dir = $dir; N = 0; Clock = [System.Diagnostics.Stopwatch]::StartNew(); Times = New-Object System.Collections.ArrayList }
                $script:FrameRecHandler = [EventHandler]{
                    param($s, $e)
                    $r = $script:FrameRec
                    if (-not $r -or $r.N -ge 70) { try { [System.Windows.Media.CompositionTarget]::remove_Rendering($script:FrameRecHandler) } catch { }; return }
                    try {
                        $el = $script:NotchParts.Content; if (-not $el -or $el.ActualHeight -lt 50) { $el = $script:NotchParts.Pinned }
                        $w = [int][math]::Ceiling($el.ActualWidth); $h = [int][math]::Ceiling($el.ActualHeight)
                        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
                        $dv = New-Object System.Windows.Media.DrawingVisual; $dc = $dv.RenderOpen()
                        $dc.DrawRectangle((NewBrush '#FF1A1A1E'), $null, (New-Object System.Windows.Rect(0, 0, $w, $h)))
                        $dc.DrawRectangle((New-Object System.Windows.Media.VisualBrush($el)), $null, (New-Object System.Windows.Rect(0, 0, $w, $h))); $dc.Close()
                        $rtb.Render($dv)
                        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
                        $fs = [IO.File]::Create((Join-Path $r.Dir ('f{0:000}.png' -f $r.N))); try { $enc.Save($fs) } finally { $fs.Dispose() }
                        [void]$r.Times.Add(('{0:000} {1:0} ms' -f $r.N, $r.Clock.Elapsed.TotalMilliseconds))
                        $r.N++
                    } catch { $r.N = 999 }
                }
                [System.Windows.Media.CompositionTarget]::add_Rendering($script:FrameRecHandler)
                Switch-IslandPage 'ai'
                $script:SnapWaitUntil = [DateTime]::UtcNow.AddMilliseconds(3500); return
            }
            try { [System.Windows.Media.CompositionTarget]::remove_Rendering($script:FrameRecHandler) } catch { }
            if ($script:FrameRec) { [IO.File]::WriteAllLines((Join-Path $script:FrameRec.Dir 'times.txt'), [string[]]$script:FrameRec.Times) }
            $script:FrameRec = $null
            [void]$script:SnapQueue.Dequeue(); return
        }
        if ($k -eq 'trace-ai') {
            # Page 2 -> page 1 with a log line (ms) for every layout function
            # that runs; the functions are put back exactly afterwards.
            $names = @('Request-CardRailFill', 'Sync-CardRailFill', 'Measure-HeroCardHeights', 'Update-NotchStageLayout', 'Sync-NotchWindowHeight',
                'Update-AllSections', 'Set-AccordionCard', 'Sync-ProviderCardLayout', 'Resize-ToContent', 'Sync-IslandPageHeights', 'Set-NotchContentWidth',
                'Start-NotchMotion', 'Update-IslandChrome', 'Update-IslandDots', 'Set-BarWidth', 'Update-FooterNowPlaying', 'Request-IslandRelayout',
                'Complete-IslandPageSwitch', 'Update-CardRailSummaries', 'Update-IslandValues', 'Sync-CardRailHeaderLabel', 'Set-CardRailChrome', 'Set-Section')
            if (-not $job.Switched) {
                $job.Switched = $true; $job.Step = 0
                $script:TraceOrig = @{}; $script:TraceClock = [System.Diagnostics.Stopwatch]::StartNew()
                foreach ($n in $names) {
                    $cmd = Get-Command $n -CommandType Function -ErrorAction SilentlyContinue
                    if (-not $cmd) { continue }
                    $script:TraceOrig[$n] = $cmd.ScriptBlock
                    $ast = $cmd.ScriptBlock.Ast
                    $params = if ($ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $ast.Parameters) { ($ast.Parameters | ForEach-Object { $_.Extent.Text }) -join ', ' } else { '' }
                    $bodyAst = if ($ast -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $ast.Body } else { $ast }
                    $body = $bodyAst.Extent.Text
                    if ($bodyAst.ParamBlock) { $params = ''; }
                    $src = "param($params)`nif (`$script:TraceClock) { Write-Log ('trace {0,5} ms  $n' -f `$script:TraceClock.ElapsedMilliseconds) }`n. $body"
                    if ($bodyAst.ParamBlock) { $src = $body.Substring(1, $body.Length - 2) -replace [regex]::Escape($bodyAst.ParamBlock.Extent.Text), ($bodyAst.ParamBlock.Extent.Text + "`nif (`$script:TraceClock) { Write-Log ('trace {0,5} ms  $n' -f `$script:TraceClock.ElapsedMilliseconds) }") }
                    Set-Item -Path ("function:script:" + $n) -Value ([scriptblock]::Create($src))
                }
                Write-Log ('trace start: page={0} state={1}' -f $script:IslandPage, $script:NotchState)
                $script:IslandWheelAt = [datetime]::MinValue
                if ($script:IslandPage -eq 'ai') { Switch-IslandPage 'music' }
                $script:SnapWaitUntil = [DateTime]::UtcNow.AddMilliseconds(1200); return
            }
            if ($job.Step -eq 0) {
                $job.Step = 1
                $script:TraceClock.Restart()
                Write-Log ('trace at music: ' + ('panelH={0:0.##} NVh={1:0.##} winH={2:0.##} pages: {3}' -f [double]$script:NotchStage.PanelH, [double]$script:NV.h, [double]$script:window.Height, ((@($script:IslandPagesUi.Pages.Keys) | ForEach-Object { '{0}={1:0.##}/{2:0.##}' -f $_, $script:IslandPagesUi.Pages[$_].ActualHeight, $script:IslandPagesUi.Pages[$_].MinHeight }) -join ' ')))
                Write-Log 'trace ---- music -> ai ----'
                Switch-IslandPage 'ai'
                $script:SnapWaitUntil = [DateTime]::UtcNow.AddMilliseconds(1800); return
            }
            foreach ($n in @($script:TraceOrig.Keys)) { Set-Item -Path ("function:script:" + $n) -Value $script:TraceOrig[$n] }
            $script:TraceClock = $null
            Write-Log ('trace at ai: ' + ('panelH={0:0.##} NVh={1:0.##} winH={2:0.##} pages: {3}' -f [double]$script:NotchStage.PanelH, [double]$script:NV.h, [double]$script:window.Height, ((@($script:IslandPagesUi.Pages.Keys) | ForEach-Object { '{0}={1:0.##}/{2:0.##}' -f $_, $script:IslandPagesUi.Pages[$_].ActualHeight, $script:IslandPagesUi.Pages[$_].MinHeight }) -join ' ')))
            Write-Log 'trace end (functions restored)'
            [void]$script:SnapQueue.Dequeue(); return
        }
        if ($k -eq 'dots-rec') {
            # Record the drawn indicator every frame of music -> ai into one sheet.
            if (-not $job.Switched) {
                $job.Switched = $true; $job.Step = 0
                $script:IslandWheelAt = [datetime]::MinValue
                if ($script:IslandPage -ne 'music') { Switch-IslandPage 'music' }
                $script:SnapWaitUntil = [DateTime]::UtcNow.AddMilliseconds(1200); return
            }
            if ($job.Step -eq 0) {
                $job.Step = 1
                $script:DotRec = New-Object System.Collections.ArrayList
                $script:DotRecHandler = [EventHandler]{ param($s, $e)
                    if ($script:DotRec.Count -ge 40) { try { [System.Windows.Media.CompositionTarget]::remove_Rendering($script:DotRecHandler) } catch { }; return }
                    [void]$script:DotRec.Add(@{ Img = $script:IslandPagesUi.DotImage.Source; Pos = [double]$script:IslandDotPos }) }
                [System.Windows.Media.CompositionTarget]::add_Rendering($script:DotRecHandler)
                Switch-IslandPage 'ai'
                $script:SnapWaitUntil = [DateTime]::UtcNow.AddMilliseconds(1500); return
            }
            try { [System.Windows.Media.CompositionTarget]::remove_Rendering($script:DotRecHandler) } catch { }
            $frames = @($script:DotRec); $sc = 6.0; $rowW = 66.0; $rowH = 7.0 + 6.0
            $W = [int]($rowW * $sc + 120); $H = [int]($frames.Count * $rowH * $sc / 2 + 20)
            $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($W, $H, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
            $dv = New-Object System.Windows.Media.DrawingVisual; $dc = $dv.RenderOpen()
            $dc.DrawRectangle((NewBrush '#FF1C1C1E'), $null, (New-Object System.Windows.Rect(0, 0, $W, $H)))
            $typeface = New-Object System.Windows.Media.Typeface('Consolas')
            for ($i = 0; $i -lt $frames.Count; $i++) {
                $y = 10 + $i * $rowH * $sc / 2
                $ft = New-Object System.Windows.Media.FormattedText(('{0:00} P={1:0.000}' -f $i, $frames[$i].Pos), [Globalization.CultureInfo]::InvariantCulture, 'LeftToRight', $typeface, 11, (NewBrush '#FF8E8E93'), 1.0)
                $dc.DrawText($ft, (New-Object System.Windows.Point(4, $y)))
                if ($frames[$i].Img) { $dc.DrawImage($frames[$i].Img, [System.Windows.Rect]::new(110.0, [double]$y, [double]($rowW * $sc / 2), [double](7 * $sc / 2))) }
            }
            $dc.Close(); $rtb.Render($dv)
            $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
            $fs = [IO.File]::Create((Join-Path $script:AppDir 'debug-snapshots\dots-frames.png')); try { $enc.Save($fs) } finally { $fs.Dispose() }
            Write-Log ('snapshot dots-rec: {0} frames, P from {1:0.000} to {2:0.000}, lowest {3:0.000}' -f $frames.Count, $frames[0].Pos, $frames[-1].Pos, (($frames | ForEach-Object { $_.Pos } | Measure-Object -Minimum).Minimum))
            $script:DotRec = $null
            [void]$script:SnapQueue.Dequeue(); return
        }
        if ($k -eq 'pills') {
            Write-Log ('snapshot pills: ' + ((@('claude','codex','cursor','grok') | ForEach-Object { $pp = $script:window.FindName($_ + 'StatusPill'); '{0}={1}/{2}' -f $_, $(if ($script:ConnectPillWired -and $script:ConnectPillWired.ContainsKey($_) -and [object]::ReferenceEquals($script:ConnectPillWired[$_], $pp)) { 'wired' } else { 'NOT-wired' }), [string](Get-AccountState $_).Tag }) -join ' '))
            [void]$script:SnapQueue.Dequeue(); return
        }
        if ($k -eq 'dots') {
            $ui = $script:IslandPagesUi
            $ws = 'drawn ' + $(if ($ui.DotImage.Source) { '{0:0.#}x{1:0.#}' -f $ui.DotImage.Source.Width, $ui.DotImage.Source.Height } else { 'none' })
            Write-Log ('snapshot dots: page={0} pos={1:0.###} widths={2} row={3:0.#} frameHook={4}' -f $script:IslandPage, $script:IslandDotPos, $ws, $ui.Dots.Width, [bool]$script:IslandDotRender)
            [void]$script:SnapQueue.Dequeue(); return
        }
        if ($k -eq 'wheel') {
            # One wheel notch down then up through the real handler; logs the pages.
            $fake = [pscustomobject]@{ Delta = -120; Handled = $false }
            $p0 = [string]$script:IslandPage
            $script:IslandWheelAt = [datetime]::MinValue
            [void](Invoke-IslandPageWheel $fake)
            $p1 = [string]$script:IslandPage
            $fake2 = [pscustomobject]@{ Delta = 120; Handled = $false }
            $script:IslandWheelAt = [datetime]::MinValue
            [void](Invoke-IslandPageWheel $fake2)
            $p2 = [string]$script:IslandPage
            Write-Log ('snapshot wheel: single={0} pages {1} -down-> {2} -up-> {3} handled={4}/{5}' -f (Test-SingleProviderCard), $p0, $p1, $p2, $fake.Handled, $fake2.Handled)
            try { if ($p0 -and $script:IslandPage -ne $p0) { Show-IslandPageImmediate $p0 } } catch { }
            [void]$script:SnapQueue.Dequeue(); return
        }
        if ($k -eq 'single') {
            # Draw the AI page as if only the current card's AI were on, then
            # put every section back exactly as it was.
            if (-not $job.Switched) {
                $job.Switched = $true
                $job.Keep = [string]$script:AccordionKey
                $job.Saved = @{}
                foreach ($pk in @($script:ProviderMeta.Keys)) { $job.Saved[$pk] = [bool](Get-SectionVisible $pk) }
                if (-not $script:Cfg.Sections -or $script:Cfg.Sections -isnot [System.Collections.IDictionary]) {
                    $h = @{}; if ($script:Cfg.Sections) { foreach ($pp in $script:Cfg.Sections.PSObject.Properties) { $h[$pp.Name] = $pp.Value } }
                    $job.OrigSections = $script:Cfg.Sections; $script:Cfg.Sections = $h
                }
                foreach ($pk in @($job.Saved.Keys)) { if ($pk -ne $job.Keep -and $job.Saved[$pk]) { $script:Cfg.Sections[$pk] = $false; Set-SectionVisible $pk $false } }
                $script:SnapWaitUntil = [DateTime]::UtcNow.AddMilliseconds(1200); return
            }
            try {
                $hg = $script:window.FindName('sectionStack'); $hero = $script:window.FindName($job.Keep + 'Section')
                Write-Log ('snapshot single: rail column {0:0}, hero width {1:0}, hero margin right {2:0}, bar track {3:0}, panel {4:0}' -f $hg.ColumnDefinitions[1].Width.Value, $hero.ActualWidth, $hero.Margin.Right, $script:BarTrackWidth, [double]$script:NotchParts.Content.Width)
                Save-SnapshotPng $hero ('card-single-' + $job.Keep)
            } finally {
                foreach ($pk in @($job.Saved.Keys)) { if ($pk -ne $job.Keep -and $job.Saved[$pk]) { $script:Cfg.Sections[$pk] = $true; Set-SectionVisible $pk $true } }
                if ($job.Contains('OrigSections')) { $script:Cfg.Sections = $job.OrigSections }
                try { Save-UnifiedState } catch { }
            }
            [void]$script:SnapQueue.Dequeue(); return
        }
        if ($k -eq 'music') {
            if (-not $job.Switched) {
                $job.Switched = $true
                $job.Back = [string]$script:IslandPage
                Show-IslandPageImmediate 'music'
                $script:SnapWaitUntil = [DateTime]::UtcNow.AddMilliseconds(900); return
            }
            $ms = $script:MediaState
            $info = if ($ms) { ($ms.Keys | Sort-Object | ForEach-Object { '{0}={1}' -f $_, ([string]$ms[$_]).Substring(0, [math]::Min(60, ([string]$ms[$_]).Length)) }) -join '; ' } else { '(no state)' }
            Write-Log ('snapshot music: active={0} lyrics={1} idx={2} key={3} | {4}' -f (Test-MediaActive), @($script:LyricsLines).Count, $script:LyricIndex, $script:LyricsKey, $info)
            if ($script:MediaUi -and $script:MediaUi.MusicPage) { Save-SnapshotPng $script:MediaUi.MusicPage 'page-music' }
            try { if ($job.Back) { Show-IslandPageImmediate $job.Back } } catch { }
            [void]$script:SnapQueue.Dequeue(); return
        }
        if ($k -ne 'current' -and -not $job.Switched) {
            $job.Switched = $true
            try { Switch-AccordionCardAnimated $k 'Click' } catch { }
            $script:SnapWaitUntil = [DateTime]::UtcNow.AddMilliseconds(1200); return
        }
        if ($k -eq 'current') { Save-SnapshotPng $script:window.Content 'window' } else { Save-SnapshotPng $script:window.FindName($k + 'Section') ('card-' + $k) }
    } catch {
        try { Write-Log ('snapshot: ' + $_.Exception.Message + ' (line ' + $_.InvocationInfo.ScriptLineNumber + ': ' + $_.InvocationInfo.Line.Trim() + ')') } catch { }
    }
    [void]$script:SnapQueue.Dequeue()
}

$script:SnapTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:SnapTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:SnapTimer.add_Tick({ try { Invoke-SnapshotTick } catch { } })
$script:SnapTimer.Start()
