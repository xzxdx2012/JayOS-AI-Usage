# ---------------------------------------------------------------------------
# Island pages "Music" (now playing + synced lyrics) and "Shelf" (files dropped
# on the island + recent clipboard text). The pager in src\IslandPages.ps1
# hosts the pages; this file owns their data and content.
#
# - Now Playing comes from src\media-helper.ps1, a PowerShell 7 process like
#   the overlay (WinRT through lib\winrt, events via src\MediaWatch.cs) that
#   mirrors the system media session into media\media-state.json and takes
#   commands on stdin.
# - Lyrics come from LRCLIB (lrclib.net, community lyrics). Only the artist,
#   title, album and length of the current track are sent. Answers are cached
#   in media\lyrics\. Settings page > 音乐 > 歌词 turns the lookup off.
# - Shelf files are remembered by path in media\shelf.json. Clipboard text is
#   kept in memory only and skips content password managers mark as private.
# ---------------------------------------------------------------------------
$script:MediaProc = $null
$script:MediaRestartAt = [datetime]::MinValue
$script:MediaStateStamp = ''
$script:MediaState = $null
$script:MediaUi = $null
$script:MediaArtShown = ''
$script:MediaActiveShown = $null
$script:LyricsKey = ''
$script:LyricsLines = @()
$script:LyricsJob = $null
$script:LyricIndex = -2
$script:ShelfFiles = New-Object System.Collections.ArrayList
$script:ClipItems = New-Object System.Collections.ArrayList
$script:ClipSeq = [uint32]0
$script:ShelfDragStart = $null
$script:ShelfDraggingOut = $false
$script:MediaTimer = $null
$script:ClipTimer = $null

function Write-MediaLog([string]$Message) {
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log "Media/Shelf: $Message" }
}

function Get-MediaDir {
    $dir = Join-Path $script:AppDir 'media'
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    return $dir
}

function Get-IslandOption([string]$Key, $Default) {
    if ($script:Cfg -and $script:Cfg.ContainsKey($Key) -and $null -ne $script:Cfg[$Key]) { return $script:Cfg[$Key] }
    return $Default
}

function Test-MediaLyricsEnabled { return [bool](Get-IslandOption 'MusicLyrics' $true) }
function Test-ClipHistoryEnabled { return [bool](Get-IslandOption 'ClipHistory' $true) }

function Format-MediaTime($Seconds) {
    if ($null -eq $Seconds -or [double]$Seconds -lt 0) { return '--:--' }
    $s = [int][math]::Floor([double]$Seconds)
    return ('{0}:{1:00}' -f [int][math]::Floor($s / 60), ($s % 60))
}

# ---------------------------------------------------------------------------
# Now Playing bridge
# ---------------------------------------------------------------------------
function Start-MediaHelper {
    if ($script:MediaProc -and -not $script:MediaProc.HasExited) { return }
    if ((Get-Date) -lt $script:MediaRestartAt) { return }
    $script:MediaRestartAt = (Get-Date).AddSeconds(30)
    # The helper runs on the same PowerShell 7 as the overlay (it reads the
    # media sessions through lib\winrt, see src\media-helper.ps1).
    $ps = [Environment]::ProcessPath
    if (-not $ps -or [IO.Path]::GetFileName($ps) -notmatch '^pwsh(\.exe)?$') {
        $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
        $ps = if ($cmd) { $cmd.Source } else { $null }
    }
    $helper = Join-Path $script:AppDir 'src\media-helper.ps1'
    if (-not $ps -or -not (Test-Path -LiteralPath $ps) -or -not (Test-Path -LiteralPath $helper)) { Write-MediaLog 'helper or PowerShell 7 missing'; return }
    $dir = Get-MediaDir
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo($ps)
        $psi.Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -StatePath "{1}" -ArtPath "{2}"' -f
            $helper, (Join-Path $dir 'media-state.json'), (Join-Path $dir 'media-art.img'))
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.CreateNoWindow = $true
        $script:MediaProc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-MediaLog "helper start failed: $($_.Exception.Message)"
        $script:MediaProc = $null
    }
}

function Stop-MediaHelper {
    try { if ($script:MediaProc -and -not $script:MediaProc.HasExited) { $script:MediaProc.StandardInput.Close(); if (-not $script:MediaProc.WaitForExit(1500)) { $script:MediaProc.Kill() } } } catch { }
    $script:MediaProc = $null
}

function Send-MediaCommand([string]$Command) {
    # Play/pause flips on screen at once; the helper's real state follows
    # within ~0.2 s and replaces this guess.
    if ($Command -eq 'toggle' -and (Test-MediaActive)) {
        try {
            $s = $script:MediaState
            $pos = Get-MediaPosition $s
            $playing = ([string]$s.Status -eq 'Playing')
            $s.Status = if ($playing) { 'Paused' } else { 'Playing' }
            $s.Position = [double]$pos
            $s.Updated = if ($playing) { 0 } else { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
            Update-MediaView -Force
        } catch { }
    }
    try {
        Start-MediaHelper
        if ($script:MediaProc -and -not $script:MediaProc.HasExited) {
            $script:MediaProc.StandardInput.WriteLine($Command)
            $script:MediaProc.StandardInput.Flush()
        }
    } catch { Write-MediaLog "command '$Command' failed: $($_.Exception.Message)" }
}

function Read-MediaState {
    $path = Join-Path (Get-MediaDir) 'media-state.json'
    try {
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        $stamp = '{0}:{1}' -f $item.LastWriteTimeUtc.Ticks, $item.Length
        if ($stamp -eq $script:MediaStateStamp) { return $false }
        $script:MediaStateStamp = $stamp
        $script:MediaState = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
        return $true
    } catch { return $false }
}

function Test-MediaActive {
    $s = $script:MediaState
    return [bool]($s -and $s.Active -and ([string]$s.Title -or [string]$s.Artist))
}

# Seconds into the track right now: the session reports a position and when
# it took it; while playing, time has moved on since.
function Get-MediaPosition($State) {
    if (-not $State) { return $null }
    $pos = [double]$State.Position
    if ([string]$State.Status -eq 'Playing' -and $State.Updated) {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $pos += [math]::Max(0.0, ($now - [double]$State.Updated) / 1000.0)
    }
    if ([double]$State.Duration -gt 0) { $pos = [math]::Min($pos, [double]$State.Duration) }
    return $pos
}

# ---------------------------------------------------------------------------
# Lyrics (LRCLIB)
# ---------------------------------------------------------------------------
function ConvertFrom-Lrc([string]$Text) {
    $lines = New-Object System.Collections.ArrayList
    foreach ($raw in ($Text -split "`r?`n")) {
        $tags = [regex]::Matches($raw, '\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]')
        if ($tags.Count -eq 0) { continue }
        $lyric = ($raw -replace '\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\]', '').Trim()
        foreach ($t in $tags) {
            $sec = [double]$t.Groups[1].Value * 60.0 + [double]::Parse(($t.Groups[2].Value -replace ':', '.'), [Globalization.CultureInfo]::InvariantCulture)
            [void]$lines.Add([pscustomobject]@{ T = $sec; L = $lyric })
        }
    }
    return @($lines | Sort-Object T)
}

# Lyrics sources, in order:
#   1. NetEase Cloud Music's own lyric API, when the track came from NetEase
#      (NeId from the helper) - covers Chinese/Japanese songs LRCLIB lacks.
#   2. LRCLIB exact match (artist + title + album + length), then a search by
#      title + first artist.
# Hits are cached for good; misses only for 6 hours, so one network hiccup
# never leaves a song without lyrics forever.
$script:LyricsFetchScript = {
    param([string]$Artist, [string]$Title, [string]$Album, [double]$Duration, [string]$CacheFile, [string]$NeId)
    if (Test-Path -LiteralPath $CacheFile) {
        try {
            $old = Get-Content -LiteralPath $CacheFile -Raw
            $o = $old | ConvertFrom-Json
            $fresh = ((Get-Date) - (Get-Item -LiteralPath $CacheFile).LastWriteTime).TotalHours -lt 6
            if ($o.found -or $o.synced -or $fresh) { return $old }
        } catch { }
    }
    $synced = ''; $plain = ''; $instrumental = $false; $source = ''
    if ($NeId) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $r = Invoke-RestMethod -Uri ("https://music.163.com/api/song/lyric?id={0}&lv=1&kv=1&tv=-1" -f $NeId) `
                -Headers @{ 'User-Agent' = 'Mozilla/5.0'; 'Referer' = 'https://music.163.com/' } -TimeoutSec 8
            $lrc = [string]$r.lrc.lyric
            if ($lrc -match '\[\d{1,3}:\d{1,2}') { $synced = $lrc; $source = 'netease' }
            elseif ($r.nolyric) { $instrumental = $true; $source = 'netease' }
        } catch { }
    }
    if (-not $synced) {
        $headers = @{ 'User-Agent' = 'JayOS-AI-Usage overlay (local desktop app)' }
        $enc = { param($s) [uri]::EscapeDataString([string]$s) }
        $firstArtist = ([string]$Artist -split '[/,、&]')[0].Trim()
        $q = 'artist_name=' + (& $enc $Artist) + '&track_name=' + (& $enc $Title)
        if ($Album) { $q += '&album_name=' + (& $enc $Album) }
        if ($Duration -gt 0) { $q += '&duration=' + [int][math]::Round($Duration) }
        $hit = $null
        try { $hit = Invoke-RestMethod -Uri ('https://lrclib.net/api/get?' + $q) -Headers $headers -TimeoutSec 8 } catch { }
        if (-not $hit -or (-not $hit.syncedLyrics -and -not $hit.plainLyrics)) {
            try {
                $found = @(Invoke-RestMethod -Uri ('https://lrclib.net/api/search?track_name=' + (& $enc $Title) + '&artist_name=' + (& $enc $firstArtist)) -Headers $headers -TimeoutSec 8)
                $hit = $found | Where-Object { $_.syncedLyrics } | Select-Object -First 1
                if (-not $hit) { $hit = $found | Select-Object -First 1 }
            } catch { }
        }
        if ($hit) { $synced = [string]$hit.syncedLyrics; $plain = [string]$hit.plainLyrics; $instrumental = [bool]$hit.instrumental; $source = 'lrclib' }
    }
    $json = [ordered]@{
        synced = $synced
        plain = $plain
        instrumental = $instrumental
        found = [bool]($synced -or $plain -or $instrumental)
        source = $source
    } | ConvertTo-Json -Compress
    try { [IO.File]::WriteAllText($CacheFile, $json, (New-Object Text.UTF8Encoding($false))) } catch { }
    return $json
}

function Start-LyricsLookup($State) {
    # The NetEase id is part of the key: if it shows up a tick after the
    # title, the lookup runs again with the better source.
    $key = [string]$State.Key + '#' + [string]$State.NeId
    if ($key -eq $script:LyricsKey) { return }
    $script:LyricsKey = $key
    $script:LyricsLines = @()
    $script:LyricIndex = -2
    if ($script:LyricsJob) { try { Remove-Job -Id $script:LyricsJob.Id -Force -ErrorAction SilentlyContinue } catch { }; $script:LyricsJob = $null }
    if (-not (Test-MediaLyricsEnabled) -or -not $State.Title) { return }
    $dir = Join-Path (Get-MediaDir) 'lyrics'
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try { $hash = ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($key)))).Replace('-', '').ToLowerInvariant() } finally { $md5.Dispose() }
    $cache = Join-Path $dir ($hash + '.json')
    $script:LyricsJob = Start-OverlayBackgroundJob -ScriptBlock $script:LyricsFetchScript -ArgumentList @(
        [string]$State.Artist, [string]$State.Title, [string]$State.Album, [double]$State.Duration, $cache, [string]$State.NeId)
    $script:LyricsJob | Add-Member -NotePropertyName LyricsKey -NotePropertyValue $key -Force
}

function Complete-LyricsLookup {
    $job = $script:LyricsJob
    if (-not $job -or $job.State -eq 'Running' -or $job.State -eq 'NotStarted') { return }
    $script:LyricsJob = $null
    try {
        $raw = (@(Receive-Job -Id $job.Id -ErrorAction SilentlyContinue) -join '')
        if ([string]$job.LyricsKey -ne $script:LyricsKey -or -not $raw) { return }
        $r = $raw | ConvertFrom-Json
        if ($r.synced) { $script:LyricsLines = @(ConvertFrom-Lrc ([string]$r.synced)) }
        elseif ($r.instrumental) { $script:LyricsLines = @([pscustomobject]@{ T = 0.0; L = '♪ 纯音乐' }) }
        else { $script:LyricsLines = @() }
        $script:LyricIndex = -2
    } catch { } finally { Remove-Job -Id $job.Id -Force -ErrorAction SilentlyContinue }
}

function Get-LyricIndex([double]$Position) {
    $lines = $script:LyricsLines
    if (-not $lines -or $lines.Count -eq 0) { return -1 }
    # Show a line a touch early, the way karaoke lyrics read.
    $p = $Position + 0.25
    $lo = 0; $hi = $lines.Count - 1; $best = -1
    while ($lo -le $hi) {
        $mid = [int](($lo + $hi) / 2)
        if ([double]$lines[$mid].T -le $p) { $best = $mid; $lo = $mid + 1 } else { $hi = $mid - 1 }
    }
    return $best
}

# ---------------------------------------------------------------------------
# Music page
# ---------------------------------------------------------------------------
$script:MusicPageXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <StackPanel x:Name="musicEmpty" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,26,0,30">
    <Border Width="54" Height="54" CornerRadius="16" Background="#14FFFFFF" HorizontalAlignment="Center">
      <Path Data="M9,19.5 A3,3 0 1 1 9,19.45 M12,19.5 V5 L21,3.4 V7.3 L12,8.9" Stroke="#8E8E93" StrokeThickness="1.8"
            StrokeLineJoin="Round" Width="26" Height="24" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <TextBlock Text="没有正在播放的音乐" Foreground="#E5E5EA" FontSize="14" FontFamily="Segoe UI Semibold" HorizontalAlignment="Center" Margin="0,12,0,0"/>
    <TextBlock Text="在网易云音乐、Apple Music 或浏览器里播放，就会出现在这里" Foreground="#8E8E93" FontSize="11.5" FontFamily="Segoe UI" HorizontalAlignment="Center" Margin="0,4,0,0"/>
  </StackPanel>
  <Grid x:Name="musicNow" Visibility="Collapsed" Margin="4,2,4,4" VerticalAlignment="Center">
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
    </Grid.ColumnDefinitions>
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <Border x:Name="musicArtBox" Width="88" Height="88" CornerRadius="18" Background="#1FFFFFFF" VerticalAlignment="Center">
      <Grid>
        <Path x:Name="musicArtNote" Data="M9,19.5 A3,3 0 1 1 9,19.45 M12,19.5 V5 L21,3.4 V7.3 L12,8.9" Stroke="#8E8E93" StrokeThickness="1.8"
              StrokeLineJoin="Round" Width="26" Height="24" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        <Border CornerRadius="18">
          <Border.Background><ImageBrush x:Name="musicArtBrush" Stretch="UniformToFill"/></Border.Background>
        </Border>
      </Grid>
    </Border>
    <StackPanel Grid.Column="1" Margin="16,0,16,0" VerticalAlignment="Center">
      <TextBlock x:Name="musicTitle" Foreground="#F5F5F7" FontSize="18" FontFamily="Segoe UI Semibold" TextTrimming="CharacterEllipsis"/>
      <TextBlock x:Name="musicArtist" Foreground="#A1A1A6" FontSize="12.5" FontFamily="Segoe UI" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
      <Grid Margin="0,12,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBlock x:Name="musicPosText" Text="0:00" Foreground="#8E8E93" FontSize="11" FontFamily="Segoe UI" VerticalAlignment="Center" Width="40"/>
        <Grid Grid.Column="1" Height="4" Margin="6,0" VerticalAlignment="Center">
          <Border Background="#26FFFFFF" CornerRadius="2"/>
          <Border Background="#F5F5F7" CornerRadius="2" RenderTransformOrigin="0,0.5">
            <Border.RenderTransform><ScaleTransform x:Name="musicProgressScale" ScaleX="0"/></Border.RenderTransform>
          </Border>
        </Grid>
        <TextBlock x:Name="musicDurText" Grid.Column="2" Text="0:00" Foreground="#8E8E93" FontSize="11" FontFamily="Segoe UI" VerticalAlignment="Center" Width="34" TextAlignment="Right"/>
      </Grid>
    </StackPanel>
    <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
      <Border x:Name="musicPrev" Width="38" Height="38" CornerRadius="19" Background="#00FFFFFF" Cursor="Hand" ToolTip="上一首">
        <Path Data="M3.5,3 H5.5 V13 H3.5 Z M13,3 L6.5,8 L13,13 Z" Fill="#E5E5EA" Width="16" Height="16" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <Border x:Name="musicPlay" Width="46" Height="46" CornerRadius="23" Background="#F5F5F7" Cursor="Hand" Margin="6,0" ToolTip="播放/暂停">
        <Path x:Name="musicPlayIcon" Data="M4.5,2.5 L13.5,8 L4.5,13.5 Z" Fill="#111113" Width="16" Height="16" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <Border x:Name="musicNext" Width="38" Height="38" CornerRadius="19" Background="#00FFFFFF" Cursor="Hand" ToolTip="下一首">
        <Path Data="M10.5,3 H12.5 V13 H10.5 Z M3,3 L9.5,8 L3,13 Z" Fill="#E5E5EA" Width="16" Height="16" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
    </StackPanel>
    <Grid x:Name="musicLyricBox" Grid.Row="1" Grid.ColumnSpan="3" Margin="0,16,0,0" Height="72" ClipToBounds="True" Visibility="Collapsed">
      <StackPanel x:Name="musicLyricStack" VerticalAlignment="Center">
        <StackPanel.RenderTransform><TranslateTransform x:Name="musicLyricShift" Y="0"/></StackPanel.RenderTransform>
        <TextBlock x:Name="musicLyricPrev" Foreground="#5E5E63" FontSize="12.5" FontFamily="Segoe UI" TextTrimming="CharacterEllipsis" HorizontalAlignment="Center"/>
        <TextBlock x:Name="musicLyric" Foreground="#F5F5F7" FontSize="17" FontFamily="Segoe UI Semibold" TextTrimming="CharacterEllipsis" HorizontalAlignment="Center" Margin="0,5,0,5"/>
        <TextBlock x:Name="musicLyricNext" Foreground="#8E8E93" FontSize="12.5" FontFamily="Segoe UI" TextTrimming="CharacterEllipsis" HorizontalAlignment="Center"/>
      </StackPanel>
    </Grid>
  </Grid>
</Grid>
'@

function New-MusicPage {
    $page = [System.Windows.Markup.XamlReader]::Parse($script:MusicPageXaml)
    $ui = if ($script:MediaUi) { $script:MediaUi } else { @{} }
    foreach ($n in @('musicEmpty','musicNow','musicArtBrush','musicArtNote','musicTitle','musicArtist','musicPosText','musicDurText','musicProgressScale',
                     'musicPrev','musicPlay','musicPlayIcon','musicNext','musicLyricBox','musicLyricStack','musicLyricShift','musicLyricPrev','musicLyric','musicLyricNext')) {
        $ui[$n] = $page.FindName($n)
    }
    $ui.MusicPage = $page
    foreach ($pair in @(@('musicPrev','prev','#00FFFFFF','#1FFFFFFF'), @('musicPlay','toggle','#F5F5F7','#FFFFFFFF'), @('musicNext','next','#00FFFFFF','#1FFFFFFF'))) {
        $b = $ui[$pair[0]]
        $b.Tag = @{ Cmd = $pair[1]; Off = $pair[2]; On = $pair[3] }
        $b.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
        $b.RenderTransform = New-Object System.Windows.Media.ScaleTransform(1, 1)
        $b.Add_MouseEnter({ param($s, $e) $s.Background = NewBrush $s.Tag.On })
        $b.Add_MouseLeave({ param($s, $e) $s.Background = NewBrush $s.Tag.Off })
        $b.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; Invoke-PressPop $s 0.9 })
        $b.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Invoke-PressPop $s 1.0; Send-MediaCommand ([string]$s.Tag.Cmd) })
    }
    $script:MediaUi = $ui
    $script:MediaArtShown = ''
    $script:MediaActiveShown = $null
    $script:LyricIndex = -2
    return $page
}

# Buttons shrink a touch while pressed and spring back, like the notch does.
function Invoke-PressPop($Element, [double]$To) {
    $st = $Element.RenderTransform
    if ($st -isnot [System.Windows.Media.ScaleTransform]) { return }
    $dur = [System.Windows.Duration]([TimeSpan]::FromMilliseconds($(if ($To -lt 1) { 90 } else { 320 })))
    foreach ($p in @([System.Windows.Media.ScaleTransform]::ScaleXProperty, [System.Windows.Media.ScaleTransform]::ScaleYProperty)) {
        $a = New-Object System.Windows.Media.Animation.DoubleAnimation($To, $dur)
        $a.EasingFunction = Get-IslandSpringEase
        $st.BeginAnimation($p, $a)
    }
}

function Update-MediaView([switch]$Force) {
    $ui = $script:MediaUi
    if (-not $ui -or -not $ui.MusicPage) { return }
    $s = $script:MediaState
    $active = Test-MediaActive
    if ($active -ne $script:MediaActiveShown) {
        $script:MediaActiveShown = $active
        $ui.musicNow.Visibility = if ($active) { $script:VisVisible } else { $script:VisCollapsed }
        $ui.musicEmpty.Visibility = if ($active) { $script:VisCollapsed } else { $script:VisVisible }
        $Force = $true
        Request-IslandPageLayout 'music'
        if (Get-Command Update-NotchMediaBadge -ErrorAction SilentlyContinue) { Update-NotchMediaBadge }
    }
    if (-not $active) { return }

    if ($Force) {
        $ui.musicTitle.Text = [string]$s.Title
        $ui.musicArtist.Text = (@([string]$s.Artist, [string]$s.Album) | Where-Object { $_ }) -join ' · '
        $playing = ([string]$s.Status -eq 'Playing')
        $ui.musicPlayIcon.Data = [System.Windows.Media.Geometry]::Parse($(if ($playing) { 'M4,3 H7 V13 H4 Z M9,3 H12 V13 H9 Z' } else { 'M4.5,2.5 L13.5,8 L4.5,13.5 Z' }))
        $art = [string]$s.Art
        if ($art -ne $script:MediaArtShown) {
            $script:MediaArtShown = $art
            $img = $null
            if ($art -and (Test-Path -LiteralPath $art)) {
                try {
                    $bi = New-Object System.Windows.Media.Imaging.BitmapImage
                    $bi.BeginInit()
                    $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                    $bi.DecodePixelWidth = 180
                    $bi.UriSource = New-Object System.Uri($art)
                    $bi.EndInit(); $bi.Freeze()
                    $img = $bi
                } catch { $img = $null }
            }
            $ui.musicArtBrush.ImageSource = $img
            $ui.musicArtNote.Visibility = if ($img) { $script:VisHidden } else { $script:VisVisible }
        }
        Start-LyricsLookup $s
        if (Get-Command Update-NotchMediaBadge -ErrorAction SilentlyContinue) { Update-NotchMediaBadge }
    }

    $pos = Get-MediaPosition $s
    $dur = [double]$s.Duration
    $ui.musicProgressScale.ScaleX = if ($dur -gt 0 -and $null -ne $pos) { [math]::Max(0.0, [math]::Min(1.0, $pos / $dur)) } else { 0.0 }
    # "≈" when the player gives no position and it is timed here instead.
    $ui.musicPosText.Text = $(if ($s.Estimated) { '≈' } else { '' }) + (Format-MediaTime $pos)
    $ui.musicPosText.ToolTip = if ($s.Estimated) { '这个播放器不报告播放进度，进度和歌词按切歌时间估算' } else { $null }
    $ui.musicDurText.Text = if ($dur -gt 0) { Format-MediaTime $dur } else { '--:--' }

    $hasLyrics = ($script:LyricsLines.Count -gt 0)
    $boxVis = if ($hasLyrics) { $script:VisVisible } else { $script:VisCollapsed }
    if ($ui.musicLyricBox.Visibility -ne $boxVis) { $ui.musicLyricBox.Visibility = $boxVis; Request-IslandPageLayout 'music' }
    if (-not $hasLyrics) { return }
    $idx = Get-LyricIndex ([double]$pos)
    if ($idx -eq $script:LyricIndex) { return }
    $forward = ($idx -gt $script:LyricIndex)
    $script:LyricIndex = $idx
    $lines = $script:LyricsLines
    $cur = if ($idx -ge 0) { [string]$lines[$idx].L } else { '' }
    $ui.musicLyricPrev.Text = if ($idx -ge 1) { [string]$lines[$idx - 1].L } else { '' }
    $ui.musicLyric.Text = if ($cur) { $cur } else { '♪' }
    $ui.musicLyricNext.Text = if ($idx + 1 -lt $lines.Count) { [string]$lines[$idx + 1].L } else { '' }
    # The block glides up one line and the new line fades in.
    $from = if ($forward) { 22.0 } else { -22.0 }
    $slide = New-Object System.Windows.Media.Animation.DoubleAnimation($from, 0.0, [System.Windows.Duration]([TimeSpan]::FromMilliseconds(420)))
    $slide.EasingFunction = Get-IslandSpringEase
    $ui.musicLyricShift.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $slide)
    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation(0.25, 1.0, [System.Windows.Duration]([TimeSpan]::FromMilliseconds(300)))
    $ui.musicLyric.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
}

# ---------------------------------------------------------------------------
# Shelf page: files (left) + clipboard history (right)
# ---------------------------------------------------------------------------
$script:ShelfPageXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition x:Name="clipGap" Width="10"/><ColumnDefinition x:Name="clipColumn" Width="*"/></Grid.ColumnDefinitions>
  <Border x:Name="shelfFilesCard" Padding="12,10,12,12">
    <StackPanel>
      <Grid Margin="0,0,0,8">
        <TextBlock Text="文件" Foreground="#F5F5F7" FontSize="14" FontFamily="Segoe UI Semibold" VerticalAlignment="Center"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <TextBlock x:Name="shelfCount" Foreground="#8E8E93" FontSize="11.5" FontFamily="Segoe UI" VerticalAlignment="Center"/>
          <Border x:Name="shelfClear" CornerRadius="7" Padding="8,3" Margin="8,0,0,0" Cursor="Hand" Background="#14FFFFFF" Visibility="Collapsed" ToolTip="清空 Shelf（不会删除文件）">
            <TextBlock Text="清空" Foreground="#C7C7CC" FontSize="11.5" FontFamily="Segoe UI"/>
          </Border>
        </StackPanel>
      </Grid>
      <Grid x:Name="shelfFilesArea" MinHeight="96">
        <Rectangle x:Name="shelfDropRect" RadiusX="12" RadiusY="12" Stroke="#38FFFFFF" StrokeThickness="1" StrokeDashArray="4 3" Fill="#08FFFFFF"/>
        <StackPanel x:Name="shelfEmpty" HorizontalAlignment="Center" VerticalAlignment="Center">
          <Path Data="M12,3 V15 M7,10 L12,15 L17,10 M4,17 V20 H20 V17" Stroke="#8E8E93" StrokeThickness="1.7" StrokeLineJoin="Round"
                StrokeStartLineCap="Round" StrokeEndLineCap="Round" Width="24" Height="24" HorizontalAlignment="Center"/>
          <TextBlock x:Name="shelfEmptyText" Text="把文件拖到岛上，随时再拖出去" Foreground="#8E8E93" FontSize="12" FontFamily="Segoe UI" Margin="0,6,0,0" HorizontalAlignment="Center"/>
        </StackPanel>
        <WrapPanel x:Name="shelfFiles" Margin="6"/>
      </Grid>
    </StackPanel>
  </Border>
  <Border x:Name="shelfClipCard" Grid.Column="2" Padding="12,10,12,12">
    <StackPanel>
      <Grid Margin="0,0,0,8">
        <TextBlock Text="剪贴板" Foreground="#F5F5F7" FontSize="14" FontFamily="Segoe UI Semibold" VerticalAlignment="Center"/>
        <TextBlock Text="仅内存 · 单击复制" Foreground="#6E6E73" FontSize="11" FontFamily="Segoe UI" HorizontalAlignment="Right" VerticalAlignment="Center"/>
      </Grid>
      <StackPanel x:Name="clipList"/>
    </StackPanel>
  </Border>
</Grid>
'@

function New-ShelfPage {
    $page = [System.Windows.Markup.XamlReader]::Parse($script:ShelfPageXaml)
    $ui = if ($script:MediaUi) { $script:MediaUi } else { @{} }
    foreach ($n in @('clipColumn','clipGap','shelfFilesCard','shelfClipCard','shelfCount','shelfClear','shelfFilesArea','shelfDropRect','shelfEmpty','shelfEmptyText','shelfFiles','clipList')) { $ui[$n] = $page.FindName($n) }
    $ui.ShelfPage = $page
    try { $card = $script:window.FindResource('Card'); $ui.shelfFilesCard.Style = $card; $ui.shelfClipCard.Style = $card } catch { }
    foreach ($c in @($ui.shelfFilesCard, $ui.shelfClipCard)) { $c.Margin = New-Object System.Windows.Thickness(0); $c.Padding = New-Object System.Windows.Thickness(12, 10, 12, 12) }
    $ui.shelfClear.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
    $ui.shelfClear.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; $script:ShelfFiles.Clear(); Save-ShelfFiles; Update-ShelfView })
    $script:MediaUi = $ui
    Import-ShelfFiles
    Update-ShelfView
    return $page
}

function Get-ShelfPath { Join-Path (Get-MediaDir) 'shelf.json' }

function Import-ShelfFiles {
    $script:ShelfFiles.Clear()
    try {
        $p = Get-ShelfPath
        if (Test-Path -LiteralPath $p) {
            foreach ($f in @(Get-Content -LiteralPath $p -Raw | ConvertFrom-Json)) {
                if ($f -and (Test-Path -LiteralPath ([string]$f))) { [void]$script:ShelfFiles.Add([string]$f) }
            }
        }
    } catch { }
}

function Save-ShelfFiles {
    try {
        $p = Get-ShelfPath
        $json = ConvertTo-Json -InputObject @($script:ShelfFiles) -Compress
        [IO.File]::WriteAllText($p + '.tmp', $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath ($p + '.tmp') -Destination $p -Force
    } catch { Write-MediaLog "shelf save failed: $($_.Exception.Message)" }
}

function Add-ShelfFiles([string[]]$Paths) {
    $added = $false
    foreach ($p in $Paths) {
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        $full = [IO.Path]::GetFullPath($p)
        if (@($script:ShelfFiles | Where-Object { $_ -ieq $full }).Count) { continue }
        [void]$script:ShelfFiles.Insert(0, $full)
        $added = $true
    }
    while ($script:ShelfFiles.Count -gt 24) { $script:ShelfFiles.RemoveAt($script:ShelfFiles.Count - 1) }
    if ($added) { Save-ShelfFiles }
    Update-ShelfView
}

function Remove-ShelfFile([string]$Path) {
    foreach ($h in @($script:ShelfFiles | Where-Object { $_ -ieq $Path })) { $script:ShelfFiles.Remove($h) }
    Save-ShelfFiles
    Update-ShelfView
}

function Get-ShelfFileIcon([string]$Path) {
    try {
        $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($Path)
        if (-not $icon) { return $null }
        try {
            $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($icon.Handle, [System.Windows.Int32Rect]::Empty,
                [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
            $src.Freeze()
            return $src
        } finally { $icon.Dispose() }
    } catch { return $null }
}

function New-ShelfChip([string]$Path) {
    $chip = New-Object System.Windows.Controls.Border
    $chip.CornerRadius = New-Object System.Windows.CornerRadius(10)
    $chip.Background = NewBrush '#16FFFFFF'
    $chip.Padding = New-Object System.Windows.Thickness(8, 6, 6, 6)
    $chip.Margin = New-Object System.Windows.Thickness(3)
    $chip.Cursor = [System.Windows.Input.Cursors]::Hand
    $chip.Tag = $Path
    $chip.ToolTip = $Path + "`n单击打开 · 拖出去使用"
    $chip.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
    $chip.RenderTransform = New-Object System.Windows.Media.ScaleTransform(1, 1)
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $icon = Get-ShelfFileIcon $Path
    if ($icon) {
        $img = New-Object System.Windows.Controls.Image
        $img.Source = $icon; $img.Width = 20; $img.Height = 20
        $img.Margin = New-Object System.Windows.Thickness(0, 0, 7, 0)
        [void]$row.Children.Add($img)
    }
    $name = New-Object System.Windows.Controls.TextBlock
    $name.Text = [IO.Path]::GetFileName($Path.TrimEnd('\'))
    if (-not $name.Text) { $name.Text = $Path }
    $name.MaxWidth = 150
    $name.TextTrimming = 'CharacterEllipsis'
    $name.Foreground = NewBrush '#E5E5EA'
    $name.FontSize = 12
    $name.VerticalAlignment = 'Center'
    [void]$row.Children.Add($name)
    $x = New-Object System.Windows.Controls.TextBlock
    $x.Text = '×'
    $x.Foreground = NewBrush '#8E8E93'
    $x.FontSize = 14
    $x.Margin = New-Object System.Windows.Thickness(8, -2, 2, 0)
    $x.VerticalAlignment = 'Center'
    $x.Tag = $Path
    $x.ToolTip = '从 Shelf 移除'
    $x.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
    $x.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Remove-ShelfFile ([string]$s.Tag) })
    [void]$row.Children.Add($x)
    $chip.Child = $row

    $chip.Add_MouseEnter({ param($s, $e) $s.Background = NewBrush '#26FFFFFF' })
    $chip.Add_MouseLeave({ param($s, $e) $s.Background = NewBrush '#16FFFFFF' })
    $chip.Add_MouseLeftButtonDown({
        param($s, $e)
        $e.Handled = $true
        $script:ShelfDragStart = $e.GetPosition($script:window)
        Invoke-PressPop $s 0.95
    })
    $chip.Add_MouseMove({
        param($s, $e)
        if ($null -eq $script:ShelfDragStart -or $e.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { return }
        $p = $e.GetPosition($script:window)
        if ([math]::Abs($p.X - $script:ShelfDragStart.X) -lt 5 -and [math]::Abs($p.Y - $script:ShelfDragStart.Y) -lt 5) { return }
        $script:ShelfDragStart = $null
        Invoke-PressPop $s 1.0
        $path = [string]$s.Tag
        if (-not (Test-Path -LiteralPath $path)) { Remove-ShelfFile $path; return }
        $data = New-Object System.Windows.DataObject
        $files = New-Object System.Collections.Specialized.StringCollection
        [void]$files.Add($path)
        $data.SetFileDropList($files)
        $script:ShelfDraggingOut = $true
        try {
            [void][System.Windows.DragDrop]::DoDragDrop($s, $data, ([System.Windows.DragDropEffects]::Copy -bor [System.Windows.DragDropEffects]::Link))
        } catch { Write-MediaLog "drag out failed: $($_.Exception.Message)" } finally { $script:ShelfDraggingOut = $false }
    })
    $chip.Add_MouseLeftButtonUp({
        param($s, $e)
        Invoke-PressPop $s 1.0
        if ($null -eq $script:ShelfDragStart) { return }
        $script:ShelfDragStart = $null
        $e.Handled = $true
        $path = [string]$s.Tag
        if (Test-Path -LiteralPath $path) { try { Start-Process -FilePath $path } catch { } } else { Remove-ShelfFile $path }
    })
    return $chip
}

function Update-ShelfView {
    $ui = $script:MediaUi
    if (-not $ui -or -not $ui.ShelfPage) { return }
    $ui.shelfFiles.Children.Clear()
    foreach ($f in @($script:ShelfFiles)) { [void]$ui.shelfFiles.Children.Add((New-ShelfChip $f)) }
    $n = $script:ShelfFiles.Count
    $ui.shelfEmpty.Visibility = if ($n) { $script:VisCollapsed } else { $script:VisVisible }
    $ui.shelfCount.Text = if ($n) { ('{0} 个文件' -f $n) } else { '' }
    $ui.shelfClear.Visibility = if ($n) { $script:VisVisible } else { $script:VisCollapsed }
    $clipOn = Test-ClipHistoryEnabled
    $ui.shelfClipCard.Visibility = if ($clipOn) { $script:VisVisible } else { $script:VisCollapsed }
    # Two equal cards side by side; with clipboard history off, files take the row.
    $ui.clipColumn.Width = if ($clipOn) { New-Object System.Windows.GridLength(1, 'Star') } else { New-Object System.Windows.GridLength(0) }
    $ui.clipGap.Width = New-Object System.Windows.GridLength($(if ($clipOn) { 10.0 } else { 0.0 }))
    Update-ClipList
    Request-IslandPageLayout 'shelf'
}

function Set-ShelfDropHighlight([bool]$On) {
    $ui = $script:MediaUi
    if (-not $ui -or -not $ui.ShelfPage) { return }
    $ui.shelfDropRect.Stroke = NewBrush $(if ($On) { '#CC0A84FF' } else { '#38FFFFFF' })
    $ui.shelfDropRect.Fill = NewBrush $(if ($On) { '#220A84FF' } else { '#08FFFFFF' })
    $ui.shelfEmptyText.Text = if ($On) { '松手放进 Shelf' } else { '把文件拖到岛上，随时再拖出去' }
}

function Invoke-ShelfDragOver($e, [switch]$Enter) {
    if ($script:ShelfDraggingOut -or -not $e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        $e.Effects = [System.Windows.DragDropEffects]::None; $e.Handled = $true; return
    }
    $e.Effects = [System.Windows.DragDropEffects]::Copy
    $e.Handled = $true
    if ($Enter) {
        if ((Get-Command Test-NotchShell -ErrorAction SilentlyContinue) -and (Test-NotchShell) -and
            $script:NotchState -ne 'EXPANDED' -and $script:NotchState -ne 'EXPANDING') {
            if (Get-Command Show-IslandPageImmediate -ErrorAction SilentlyContinue) { Show-IslandPageImmediate 'shelf' }
            Start-NotchExpand
        } elseif (Get-Command Switch-IslandPage -ErrorAction SilentlyContinue) {
            Switch-IslandPage 'shelf'
        }
        Set-ShelfDropHighlight $true
    }
}

function Invoke-ShelfDrop($e) {
    Set-ShelfDropHighlight $false
    if ($script:ShelfDraggingOut) { return }
    try {
        if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
            Add-ShelfFiles ([string[]]$e.Data.GetData([System.Windows.DataFormats]::FileDrop))
            $e.Handled = $true
        }
    } catch { Write-MediaLog "drop failed: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
# Clipboard history (memory only)
# ---------------------------------------------------------------------------
function Initialize-ClipboardNative {
    if (([System.Management.Automation.PSTypeName]'AIUsageClipboardSeq').Type) { return }
    try {
        Add-TypeCached -TypeDefinition @'
using System.Runtime.InteropServices;
public static class AIUsageClipboardSeq {
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
}
'@
    } catch { }
}

function Invoke-ClipboardTick {
    if (-not (Test-ClipHistoryEnabled)) { return }
    if ((Get-Command Test-IslandAnimating -ErrorAction SilentlyContinue) -and (Test-IslandAnimating)) { return }
    if (-not ([System.Management.Automation.PSTypeName]'AIUsageClipboardSeq').Type) { return }
    $seq = [AIUsageClipboardSeq]::GetClipboardSequenceNumber()
    if ($seq -eq $script:ClipSeq) { return }
    $first = ($script:ClipSeq -eq 0)
    $script:ClipSeq = $seq
    $text = $null
    try {
        # Password managers flag secrets so clipboard tools leave them alone.
        if ([System.Windows.Clipboard]::ContainsData('ExcludeClipboardContentFromMonitorProcessing')) { return }
        if ([System.Windows.Clipboard]::ContainsData('CanIncludeInClipboardHistory')) {
            $flag = [System.Windows.Clipboard]::GetData('CanIncludeInClipboardHistory')
            if ($flag -is [System.IO.MemoryStream] -and $flag.Length -ge 4 -and [BitConverter]::ToInt32($flag.ToArray(), 0) -eq 0) { return }
        }
        if ([System.Windows.Clipboard]::ContainsText()) { $text = [System.Windows.Clipboard]::GetText() }
    } catch { return }
    if ($first -or [string]::IsNullOrWhiteSpace($text)) { return }
    if ($text.Length -gt 20000) { $text = $text.Substring(0, 20000) }
    foreach ($d in @($script:ClipItems | Where-Object { $_.Text -ceq $text })) { $script:ClipItems.Remove($d) }
    [void]$script:ClipItems.Insert(0, [pscustomobject]@{ Text = $text; At = Get-Date })
    while ($script:ClipItems.Count -gt 20) { $script:ClipItems.RemoveAt($script:ClipItems.Count - 1) }
    Update-ClipList
    Request-IslandPageLayout 'shelf'
}

function Update-ClipList {
    $ui = $script:MediaUi
    if (-not $ui -or -not $ui.clipList) { return }
    $list = $ui.clipList
    $list.Children.Clear()
    if ($script:ClipItems.Count -eq 0) {
        $empty = New-Object System.Windows.Controls.TextBlock
        $empty.Text = '复制的文字会出现在这里'
        $empty.Foreground = NewBrush '#8E8E93'
        $empty.FontSize = 12
        $empty.Margin = New-Object System.Windows.Thickness(2, 30, 2, 30)
        $empty.HorizontalAlignment = 'Center'
        [void]$list.Children.Add($empty)
        return
    }
    foreach ($item in @($script:ClipItems | Select-Object -First 5)) {
        $row = New-Object System.Windows.Controls.Border
        $row.CornerRadius = New-Object System.Windows.CornerRadius(9)
        $row.Background = NewBrush '#10FFFFFF'
        $row.Padding = New-Object System.Windows.Thickness(10, 6, 10, 6)
        $row.Margin = New-Object System.Windows.Thickness(0, 0, 0, 4)
        $row.Cursor = [System.Windows.Input.Cursors]::Hand
        $row.Tag = $item.Text
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = ($item.Text -replace '\s+', ' ').Trim()
        $tb.TextTrimming = 'CharacterEllipsis'
        $tb.Foreground = NewBrush '#E5E5EA'
        $tb.FontSize = 12
        $row.Child = $tb
        $row.ToolTip = if ($item.Text.Length -gt 400) { $item.Text.Substring(0, 400) + '…' } else { $item.Text }
        $row.Add_MouseEnter({ param($s, $e) $s.Background = NewBrush '#22FFFFFF' })
        $row.Add_MouseLeave({ param($s, $e) $s.Background = NewBrush '#10FFFFFF' })
        $row.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
        $row.Add_MouseLeftButtonUp({
            param($s, $e)
            $e.Handled = $true
            try {
                [System.Windows.Clipboard]::SetText([string]$s.Tag)
                $s.Child.Text = '已复制 ✓'
                $s.Child.Foreground = NewBrush '#30D158'
            } catch { }
        })
        [void]$list.Children.Add($row)
    }
}

# ---------------------------------------------------------------------------
# Timers and drag/drop wiring (called once per window by the pager)
# ---------------------------------------------------------------------------
function Initialize-MediaShelfRuntime {
    $script:window.AllowDrop = $true
    $script:window.Add_DragEnter({ param($s, $e) Invoke-ShelfDragOver $e -Enter })
    $script:window.Add_DragOver({ param($s, $e) Invoke-ShelfDragOver $e })
    $script:window.Add_DragLeave({ param($s, $e) Set-ShelfDropHighlight $false })
    $script:window.Add_Drop({ param($s, $e) Invoke-ShelfDrop $e })
    Initialize-ClipboardNative
    if (-not $script:MediaTimer) {
        $script:MediaTimer = New-Object System.Windows.Threading.DispatcherTimer
        # 200 ms: the helper writes changes within ~0.1 s, so a track change or pause shows almost at once.
        $script:MediaTimer.Interval = [TimeSpan]::FromMilliseconds(200)
        $script:MediaTimer.add_Tick({ try { Invoke-MediaTick } catch { } })
        $script:MediaTimer.Start()
    }
    if (-not $script:ClipTimer) {
        $script:ClipTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:ClipTimer.Interval = [TimeSpan]::FromMilliseconds(600)
        $script:ClipTimer.add_Tick({ try { Invoke-ClipboardTick } catch { } })
        $script:ClipTimer.Start()
    }
    Start-MediaHelper
}

function Invoke-MediaTick {
    # Never compete with an animation for the UI thread.
    if ((Get-Command Test-IslandAnimating -ErrorAction SilentlyContinue) -and (Test-IslandAnimating)) { return }
    if (-not $script:MediaProc -or $script:MediaProc.HasExited) { Start-MediaHelper }
    $changed = Read-MediaState
    Complete-LyricsLookup
    # The progress bar and lyrics only need ticking while the music page is
    # on screen; otherwise just react to a real change of track/state.
    $onMusic = ($script:IslandPage -eq 'music' -and $script:NotchState -eq 'EXPANDED')
    if ($onMusic -or $changed) { Update-MediaView -Force:$changed }
    # Folded notch: keep its lyric line in step with the song.
    if ((Test-MediaActive) -and (Get-Command Update-NotchLyric -ErrorAction SilentlyContinue)) { Update-NotchLyric }
}
