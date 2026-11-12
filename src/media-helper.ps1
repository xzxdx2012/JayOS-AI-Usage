# Now-playing bridge for the overlay, on PowerShell 7 like the rest of the app.
# Windows' media sessions are read through the WinRT projection in lib\winrt
# (Microsoft.Windows.SDK.NET + WinRT.Runtime); src\MediaWatch.cs listens to
# their events, so a new track, play/pause or seek is written within ~0.1 s
# instead of on the next poll. NetEase Cloud Music without a session is still
# read from its window title, local queue and audio level (below).
# Output: the current track as JSON in -StatePath, cover art next to it.
# Input: one-word commands on stdin - toggle | play | pause | next | prev.
# It exits when stdin closes, i.e. when the overlay process goes away.
param(
    [Parameter(Mandatory = $true)][string]$StatePath,
    [Parameter(Mandatory = $true)][string]$ArtPath
)
$ErrorActionPreference = 'Stop'
# Set AIUSAGE_MEDIA_TRACE=1 to print stage timings on stderr (diagnostics only).
$script:TraceSw = [Diagnostics.Stopwatch]::StartNew()
function Trace-Helper([string]$What) { if ($env:AIUSAGE_MEDIA_TRACE) { [Console]::Error.WriteLine(('{0,6} ms  {1}' -f $script:TraceSw.ElapsedMilliseconds, $What)) } }
$AppDir = Split-Path -Parent $PSScriptRoot
$ArtDir = [IO.Path]::GetDirectoryName($ArtPath)

# --- WinRT media sessions ---------------------------------------------------
# The watcher is compiled once into lib\cache and reused while its source is
# unchanged (compiling takes ~1.5 s; loading the cached copy is instant).
$script:WatchOk = $false
try {
    $lib = Join-Path $AppDir 'lib\winrt'
    Add-Type -Path (Join-Path $lib 'WinRT.Runtime.dll')
    Add-Type -Path (Join-Path $lib 'Microsoft.Windows.SDK.NET.dll')
    $cs = Join-Path $PSScriptRoot 'MediaWatch.cs'
    $cacheDir = Join-Path $AppDir 'lib\cache'
    if (-not (Test-Path -LiteralPath $cacheDir)) { [void](New-Item -ItemType Directory -Path $cacheDir -Force) }
    $hash = (Get-FileHash -LiteralPath $cs -Algorithm SHA256).Hash.Substring(0, 16)
    $dll = Join-Path $cacheDir ("MediaWatch-$hash.dll")
    if (Test-Path -LiteralPath $dll) {
        Add-Type -Path $dll
    } else {
        Get-ChildItem -LiteralPath $cacheDir -Filter 'MediaWatch-*.dll' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        $refs = @((Join-Path $lib 'WinRT.Runtime.dll'), (Join-Path $lib 'Microsoft.Windows.SDK.NET.dll'),
            'System.Runtime', 'System.Collections', 'System.Threading', 'System.Threading.Tasks', 'System.Linq',
            'System.Runtime.InteropServices', 'System.ObjectModel', 'System.IO')
        try {
            Add-Type -Path $cs -ReferencedAssemblies $refs -OutputAssembly $dll -IgnoreWarnings -WarningAction SilentlyContinue
            Add-Type -Path $dll
        } catch {
            # Cache folder not writable: compile in memory instead.
            Add-Type -Path $cs -ReferencedAssemblies $refs -IgnoreWarnings -WarningAction SilentlyContinue
        }
    }
    Trace-Helper 'watcher loaded'
    $script:WatchOk = [AIUsage.MediaWatch]::Start()
    Trace-Helper "watcher started: $($script:WatchOk)"
} catch { $script:WatchOk = $false; $script:WatchError = $_.Exception.Message }

function Write-State($Obj) {
    $json = $Obj | ConvertTo-Json -Compress
    if ($json -eq $script:LastJson) { return }
    $script:LastJson = $json
    $tmp = $StatePath + '.tmp'
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $StatePath -Force
}

$script:LastJson = ''
# [Console]::In is a synchronized reader whose ReadLineAsync blocks; a plain
# StreamReader over the raw handle reads truly asynchronously.
$stdin = New-Object IO.StreamReader([Console]::OpenStandardInput())
$pending = $stdin.ReadLineAsync()
# ---------------------------------------------------------------------------
# NetEase Cloud Music (网易云音乐) support.
# Its desktop client does not always publish a system media session. When it
# does not, read the track from its main window title ("歌名 - 歌手") and fill
# in length and cover from its local queue (webdata\file\playingList). The
# position is then estimated from when the title changed (Estimated = true),
# and play/pause/next/previous go out as system media keys, which the client
# obeys by default.
# ---------------------------------------------------------------------------
Add-Type -Namespace AIUsage -Name MediaKeys -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
'@
$script:NeQueuePath = Join-Path $env:LOCALAPPDATA 'NetEase\CloudMusic\webdata\file\playingList'
$script:NeQueueStamp = ''
$script:NeQueue = @()
$script:NeTitle = ''
$script:NeElapsed = 0.0
$script:NePlayingSince = $null
$script:NeArtKey = ''
$script:NeArtFile = ''

function Send-MediaKey([byte]$Vk) {
    [AIUsage.MediaKeys]::keybd_event($Vk, 0, 0, [UIntPtr]::Zero)
    [AIUsage.MediaKeys]::keybd_event($Vk, 0, 2, [UIntPtr]::Zero)
}

function Get-NeQueue {
    try {
        $item = Get-Item -LiteralPath $script:NeQueuePath -ErrorAction Stop
        $stamp = '{0}:{1}' -f $item.LastWriteTimeUtc.Ticks, $item.Length
        if ($stamp -ne $script:NeQueueStamp) {
            $script:NeQueueStamp = $stamp
            $script:NeQueue = @((Get-Content -LiteralPath $script:NeQueuePath -Raw -Encoding UTF8 | ConvertFrom-Json).list | ForEach-Object { $_.track } | Where-Object { $_ })
        }
    } catch { }
    return $script:NeQueue
}

# Best match in the local queue for a title/artist pair.
function Find-NeTrack([string]$Title, [string]$Artist) {
    $q = @(Get-NeQueue)
    if (-not $Title -or $q.Count -eq 0) { return $null }
    $hits = @($q | Where-Object { [string]$_.name -eq $Title })
    if ($hits.Count -gt 1 -and $Artist) {
        $byArtist = @($hits | Where-Object { ((@($_.artists | ForEach-Object { [string]$_.name })) -join '/') -like ('*' + ($Artist -split '[/,、]')[0].Trim() + '*') })
        if ($byArtist.Count) { $hits = $byArtist }
    }
    return ($hits | Select-Object -First 1)
}

# Tracks that are not in the local queue (radio, recommendations, ...) are
# looked up once on NetEase's own public search by title + first artist.
# Results, misses included, are remembered for the life of the helper.
$script:NeOnline = @{}
function Find-NeTrackOnline([string]$Title, [string]$Artist) {
    if (-not $Title) { return $null }
    $k = $Title + '|' + $Artist
    if ($script:NeOnline.ContainsKey($k)) { return $script:NeOnline[$k] }
    $script:NeOnline[$k] = $null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $first = ($Artist -split '[/,、]')[0].Trim()
        $q = [uri]::EscapeDataString(($Title + ' ' + $first).Trim())
        $r = Invoke-RestMethod -Uri ('https://music.163.com/api/cloudsearch/pc?s=' + $q + '&type=1&limit=5') `
            -Headers @{ 'User-Agent' = 'Mozilla/5.0'; 'Referer' = 'https://music.163.com/' } -TimeoutSec 6
        $songs = @($r.result.songs)
        $hit = $songs | Where-Object { [string]$_.name -eq $Title } | Select-Object -First 1
        if (-not $hit) { $hit = $songs | Select-Object -First 1 }
        if ($hit) {
            # Same shape as a queue entry, so the callers need no branches.
            $script:NeOnline[$k] = [pscustomobject]@{
                id       = $hit.id
                name     = [string]$hit.name
                duration = $hit.dt
                album    = [pscustomobject]@{ name = [string]$hit.al.name; picUrl = [string]$hit.al.picUrl }
            }
        }
    } catch { }
    return $script:NeOnline[$k]
}

function Save-NeArt($Track) {
    $url = [string]$Track.album.picUrl
    if (-not $url) { return '' }
    if ($url -eq $script:NeArtKey -and $script:NeArtFile -and (Test-Path -LiteralPath $script:NeArtFile)) { return $script:NeArtFile }
    $script:NeArtKey = $url
    $script:NeArtFile = ''
    try {
        $dir = [IO.Path]::GetDirectoryName($ArtPath)
        $name = Join-Path $dir ('media-art-ne-{0}.img' -f ([Math]::Abs($url.GetHashCode())))
        Get-ChildItem -LiteralPath $dir -Filter 'media-art-ne-*.img' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $name } | Remove-Item -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $name)) {
            $wc = New-Object Net.WebClient
            try { $wc.DownloadFile(($url -replace '^http:', 'https:') + '?param=300y300', $name) } finally { $wc.Dispose() }
        }
        $script:NeArtFile = $name
    } catch { $script:NeArtFile = '' }
    return $script:NeArtFile
}

# The client's track title ("song - artist") while a track is loaded, else ''.
# Process.MainWindowTitle is unreliable for NetEase (several top-level
# windows; it often comes back empty), so read the windows by class: the
# main window (OrpheusBrowserHost), else the tray icon's window ("icon"),
# which keeps the title even when the client is minimised to the tray.
Add-Type -Namespace AIUsage -Name NeWindows -MemberDefinition @'
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, System.IntPtr l);
[DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(System.IntPtr h, out int pid);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(System.IntPtr h, System.Text.StringBuilder s, int n);
public static string Title(int[] pids) {
    var set = new System.Collections.Generic.HashSet<int>(pids);
    string main = "", icon = "";
    EnumWindows((h, l) => {
        int pid; GetWindowThreadProcessId(h, out pid);
        if (!set.Contains(pid)) return true;
        var c = new System.Text.StringBuilder(128); GetClassName(h, c, 128);
        string cls = c.ToString();
        if (cls != "OrpheusBrowserHost" && cls != "icon") return true;
        var t = new System.Text.StringBuilder(512); GetWindowText(h, t, 512);
        if (cls == "OrpheusBrowserHost" && main.Length == 0) main = t.ToString();
        if (cls == "icon" && icon.Length == 0) icon = t.ToString();
        return true;
    }, System.IntPtr.Zero);
    return main.Contains(" - ") ? main : icon;
}
'@
# NetEase does not report pause either. Its audio does: Windows exposes a
# peak meter per audio session, and a paused client outputs silence. The
# helper samples the client's sessions every loop (250 ms) and calls it
# playing while it made sound in the last 1.5 s.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace AIUsage {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCo { }
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int mask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    }
    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
    }
    [Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionManager2 {
        [PreserveSig] int GetAudioSessionControl(IntPtr guid, int flags, out IntPtr ctl);
        [PreserveSig] int GetSimpleAudioVolume(IntPtr guid, int flags, out IntPtr vol);
        [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator e);
    }
    [Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionEnumerator {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetSession(int index, out IAudioSessionControl2 session);
    }
    // Only GetProcessId is called; the slots before it keep the vtable order.
    [Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionControl2 {
        [PreserveSig] int GetState(out int state);
        [PreserveSig] int GetDisplayName(out IntPtr name);
        [PreserveSig] int SetDisplayName(IntPtr name, IntPtr ctx);
        [PreserveSig] int GetIconPath(out IntPtr path);
        [PreserveSig] int SetIconPath(IntPtr path, IntPtr ctx);
        [PreserveSig] int GetGroupingParam(out Guid g);
        [PreserveSig] int SetGroupingParam(IntPtr g, IntPtr ctx);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr n);
        [PreserveSig] int UnregisterAudioSessionNotification(IntPtr n);
        [PreserveSig] int GetSessionIdentifier(out IntPtr id);
        [PreserveSig] int GetSessionInstanceIdentifier(out IntPtr id);
        [PreserveSig] int GetProcessId(out uint pid);
    }
    [Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioMeterInformation {
        [PreserveSig] int GetPeakValue(out float peak);
    }
    public static class AudioPeak {
        // Loudest current peak (0..1) across the default output's sessions
        // owned by these processes; -1 when none of them has a session.
        public static float ForPids(int[] pids) {
            float best = -1f;
            try {
                var en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCo();
                IMMDevice dev;
                if (en.GetDefaultAudioEndpoint(0, 1, out dev) != 0 || dev == null) return best;
                Guid iid = typeof(IAudioSessionManager2).GUID;
                object o;
                if (dev.Activate(ref iid, 23, IntPtr.Zero, out o) != 0) return best;
                var mgr = (IAudioSessionManager2)o;
                IAudioSessionEnumerator se;
                if (mgr.GetSessionEnumerator(out se) != 0) return best;
                int n; se.GetCount(out n);
                for (int i = 0; i < n; i++) {
                    IAudioSessionControl2 s;
                    if (se.GetSession(i, out s) != 0 || s == null) continue;
                    uint pid; s.GetProcessId(out pid);
                    if (Array.IndexOf(pids, (int)pid) < 0) continue;
                    var meter = s as IAudioMeterInformation;
                    if (meter == null) continue;
                    float p; if (meter.GetPeakValue(out p) == 0 && p > best) best = p;
                }
            } catch { }
            return best;
        }
    }
}
'@
$script:NeLastSoundAt = [DateTimeOffset]::MinValue
$script:NeHasAudioSession = $false
function Update-NeAudio {
    $pids = @(Get-Process -Name cloudmusic -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    if ($pids.Count -eq 0) { $script:NeHasAudioSession = $false; return }
    $peak = [AIUsage.AudioPeak]::ForPids([int[]]$pids)
    $script:NeHasAudioSession = ($peak -ge 0)
    if ($peak -ge 0) { $script:NeSeenAudioSession = $true }
    if ($peak -gt 0.0005) { $script:NeLastSoundAt = [DateTimeOffset]::UtcNow }
}
# Playing = made sound in the last 1.5 s. A client that has never had an
# audio session since we started cannot be judged: assume playing. One that
# had one and dropped it has stopped playing.
$script:NeSeenAudioSession = $false
function Test-NeAudible {
    if (-not $script:NeHasAudioSession -and -not $script:NeSeenAudioSession) { return $true }
    return (([DateTimeOffset]::UtcNow - $script:NeLastSoundAt).TotalSeconds -lt 1.5)
}

function Get-NeWindowTitle {
    $pids = @(Get-Process -Name cloudmusic -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    if ($pids.Count -eq 0) { return '' }
    $t = [string][AIUsage.NeWindows]::Title([int[]]$pids)
    if ($t -eq '网易云音乐' -or $t -notmatch ' - ') { return '' }
    return $t
}

$script:UsingNeFallback = $false
$script:SessKey = ''
$script:SessElapsed = 0.0
$script:SessPlayingSince = $null

function Update-State {
    $info = $null
    if ($script:WatchOk) { try { $info = [AIUsage.MediaWatch]::Read($ArtDir) } catch { $info = $null } }
    $sessionPlaying = ($info -and $info.Status -eq 'Playing')
    $winTitle = Get-NeWindowTitle
    $sessionIsNe = ($info -and $info.IsNetEase)
    if ($winTitle -and -not $sessionIsNe -and -not $sessionPlaying) {
        # NetEase without a media session: window title + local queue, and
        # the audio level for play/pause.
        $script:UsingNeFallback = $true
        $nowUtc = [DateTimeOffset]::UtcNow
        $audible = Test-NeAudible
        if ($winTitle -ne $script:NeTitle) {
            $script:NeTitle = $winTitle
            $script:NeElapsed = 0.0
            $script:NePlayingSince = if ($audible) { $nowUtc } else { $null }
        }
        # Played time only: start the clock when sound starts, stop it
        # (back-dated to the last sound) when the client goes quiet.
        if ($audible) {
            if (-not $script:NePlayingSince) { $script:NePlayingSince = $nowUtc }
        } elseif ($script:NePlayingSince) {
            $stopAt = if ($script:NeLastSoundAt -gt $script:NePlayingSince) { $script:NeLastSoundAt } else { $script:NePlayingSince }
            $script:NeElapsed += ($stopAt - $script:NePlayingSince).TotalSeconds
            $script:NePlayingSince = $null
        }
        $cut = $winTitle.LastIndexOf(' - ')
        $title = $winTitle.Substring(0, $cut).Trim()
        $artist = $winTitle.Substring($cut + 3).Trim()
        $track = Find-NeTrack $title $artist
        if (-not $track) { $track = Find-NeTrackOnline $title $artist }
        $dur = if ($track -and $track.duration) { [math]::Round([double]$track.duration / 1000.0, 2) } else { 0 }
        $art = if ($track) { Save-NeArt $track } else { '' }
        $album = if ($track) { [string]$track.album.name } else { '' }
        $paused = -not [bool]$script:NePlayingSince
        Write-State ([ordered]@{
            Active    = $true
            App       = 'cloudmusic.exe'
            Title     = $title
            Artist    = $artist
            Album     = $album
            Status    = $(if ($paused) { 'Paused' } else { 'Playing' })
            Position  = [math]::Round([double]$script:NeElapsed, 2)
            Duration  = $dur
            Updated   = $(if ($paused) { 0 } else { $script:NePlayingSince.ToUnixTimeMilliseconds() })
            Art       = $art
            Key       = '{0}|{1}|{2}' -f $artist, $title, $album
            Estimated = $true
            Src       = 'window-title'
            NeId      = $(if ($track -and $track.id) { [string]$track.id } else { '' })
        })
        return
    }
    $script:UsingNeFallback = $false
    if (-not $info -or (-not $info.Title -and -not $info.Artist)) {
        Write-State ([ordered]@{ Active = $false; Watch = [bool]$script:WatchOk })
        return
    }
    $title = [string]$info.Title; $artist = [string]$info.Artist; $album = [string]$info.Album
    $art = [string]$info.ArtFile
    $dur = [double]$info.Duration
    # NetEase's session can come without a timeline or cover: fill those
    # from its local queue (or its public search).
    $track = $null
    if ($sessionIsNe) {
        $track = Find-NeTrack $title $artist
        if (-not $track) { $track = Find-NeTrackOnline $title $artist }
        if ($track) {
            if ($dur -le 0 -and $track.duration) { $dur = [math]::Round([double]$track.duration / 1000.0, 2) }
            if (-not $art) { $art = Save-NeArt $track }
            if (-not $album) { $album = [string]$track.album.name }
        }
    }
    $key = '{0}|{1}|{2}' -f $artist, $title, [string]$info.Album
    $status = [string]$info.Status
    $nowUtc = [DateTimeOffset]::UtcNow
    if ($key -ne $script:SessKey) {
        $script:SessKey = $key
        $script:SessElapsed = 0.0
        $script:SessPlayingSince = $null
    }
    # Sessions without a timeline (NetEase often) are timed here, counting
    # only time spent Playing.
    if ($status -eq 'Playing') {
        if (-not $script:SessPlayingSince) { $script:SessPlayingSince = $nowUtc }
    } elseif ($script:SessPlayingSince) {
        $script:SessElapsed += ($nowUtc - $script:SessPlayingSince).TotalSeconds
        $script:SessPlayingSince = $null
    }
    $noTimeline = -not $info.HasTimeline
    $position = [double]$info.Position
    $updated = [long]$info.Updated
    if ($noTimeline) {
        $position = [math]::Round([double]$script:SessElapsed, 2)
        $updated = if ($script:SessPlayingSince) { $script:SessPlayingSince.ToUnixTimeMilliseconds() } else { 0 }
    }
    Write-State ([ordered]@{
        Active    = $true
        App       = [string]$info.App
        Title     = $title
        Artist    = $artist
        Album     = $album
        Status    = $status
        Position  = $position
        Duration  = $dur
        Updated   = $updated
        Art       = $art
        Key       = $key
        Estimated = $noTimeline
        Src       = 'session'
        NeId      = $(if ($track -and $track.id) { [string]$track.id } else { '' })
    })
}

# Commands go to the session on screen; NetEase without one gets media keys.
function Invoke-HelperCommand([string]$Cmd) {
    $sent = $false
    if (-not $script:UsingNeFallback -and $script:WatchOk) {
        try { $sent = [bool][AIUsage.MediaWatch]::Command($Cmd) } catch { $sent = $false }
    }
    if (-not $sent) {
        switch ($Cmd) {
            { $_ -in @('toggle', 'play', 'pause') } { Send-MediaKey 0xB3 }
            'next' { Send-MediaKey 0xB0 }
            'prev' { Send-MediaKey 0xB1 }
        }
    }
}

# Main loop, 100 ms: commands at once; state when a session event arrived,
# shortly after a command (players take a moment to switch), and at least
# once a second; the NetEase audio meter every 250 ms.
Trace-Helper 'NetEase helpers compiled'
$lastVer = -1
$nextPoll = [DateTime]::MinValue
$nextAudio = [DateTime]::MinValue
$rechecks = New-Object System.Collections.Generic.Queue[DateTime]
while ($true) {
    $now = [DateTime]::UtcNow
    if ($pending.IsCompleted) {
        $cmd = $pending.Result
        if ($null -eq $cmd) { break }
        try { Invoke-HelperCommand $cmd.Trim() } catch { }
        foreach ($ms in @(120, 400, 1000)) { $rechecks.Enqueue($now.AddMilliseconds($ms)) }
        $pending = $stdin.ReadLineAsync()
    }
    if ($now -ge $nextAudio) { $nextAudio = $now.AddMilliseconds(250); try { Update-NeAudio } catch { } }
    $ver = if ($script:WatchOk) { [AIUsage.MediaWatch]::Version } else { 0 }
    $due = ($ver -ne $lastVer) -or ($now -ge $nextPoll)
    while ($rechecks.Count -and $rechecks.Peek() -le $now) { [void]$rechecks.Dequeue(); $due = $true }
    if ($due) {
        $lastVer = $ver
        $nextPoll = $now.AddMilliseconds(1000)
        try { Update-State } catch { Write-State @{ Active = $false; Error = $_.Exception.Message } }
        Trace-Helper "state written: $($script:LastJson.Substring(0, [math]::Min(80, $script:LastJson.Length)))"
    }
    Start-Sleep -Milliseconds 100
}