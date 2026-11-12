// Now-playing watcher for the media helper (src\media-helper.ps1), compiled
// by PowerShell 7 against the WinRT projection in lib\winrt.
//
// It listens to Windows' media sessions (the same source as the volume
// flyout): every track change, play/pause and seek raises an event, which
// bumps Version so the helper writes the new state at once instead of on
// its next poll. Commands go to the session the overlay is showing.
using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Windows.Foundation;
using Windows.Media.Control;
using Windows.Storage.Streams;

namespace AIUsage {
    public sealed class MediaInfo {
        public string App = "", Title = "", Artist = "", Album = "", Status = "", Key = "", ArtFile = "";
        public double Position, Duration;
        public long Updated;
        public bool HasTimeline, IsNetEase;
    }

    public static class MediaWatch {
        static GlobalSystemMediaTransportControlsSessionManager mgr;
        static readonly object gate = new object();
        static readonly List<GlobalSystemMediaTransportControlsSession> hooked = new List<GlobalSystemMediaTransportControlsSession>();
        static GlobalSystemMediaTransportControlsSession shown;
        static string artKey = null, artFile = "";
        static int version;
        public static int Version { get { return Volatile.Read(ref version); } }
        public static string LastError = "";

        static void Bump() { Interlocked.Increment(ref version); }

        static T Wait<T>(IAsyncOperation<T> op, int ms) {
            var t = op.AsTask();
            if (!t.Wait(ms)) throw new TimeoutException("WinRT call timed out");
            return t.Result;
        }

        public static bool Start() {
            try {
                mgr = Wait(GlobalSystemMediaTransportControlsSessionManager.RequestAsync(), 6000);
                mgr.SessionsChanged += (s, e) => { Rehook(); Bump(); };
                mgr.CurrentSessionChanged += (s, e) => Bump();
                Rehook();
                return true;
            } catch (Exception ex) { LastError = ex.Message; return false; }
        }

        static void OnProps(GlobalSystemMediaTransportControlsSession s, MediaPropertiesChangedEventArgs e) { Bump(); }
        static void OnPlayback(GlobalSystemMediaTransportControlsSession s, PlaybackInfoChangedEventArgs e) { Bump(); }
        static void OnTimeline(GlobalSystemMediaTransportControlsSession s, TimelinePropertiesChangedEventArgs e) { Bump(); }

        // Sessions come and go (a browser tab, a player starting): drop the old
        // handlers and hook every current session.
        static void Rehook() {
            lock (gate) {
                foreach (var s in hooked) {
                    try { s.MediaPropertiesChanged -= OnProps; s.PlaybackInfoChanged -= OnPlayback; s.TimelinePropertiesChanged -= OnTimeline; } catch { }
                }
                hooked.Clear();
                try {
                    foreach (var s in mgr.GetSessions()) {
                        try { s.MediaPropertiesChanged += OnProps; s.PlaybackInfoChanged += OnPlayback; s.TimelinePropertiesChanged += OnTimeline; hooked.Add(s); } catch { }
                    }
                } catch { }
            }
        }

        static bool IsNe(GlobalSystemMediaTransportControlsSession s) {
            try { return s.SourceAppUserModelId.IndexOf("cloudmusic", StringComparison.OrdinalIgnoreCase) >= 0; } catch { return false; }
        }
        static bool IsPlaying(GlobalSystemMediaTransportControlsSession s) {
            try { return s.GetPlaybackInfo().PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing; } catch { return false; }
        }

        // Which session to show: one that is playing (NetEase first), else the
        // one already on screen if it still exists (a pause must not make the
        // card jump to another app), else NetEase, else the system's current.
        static GlobalSystemMediaTransportControlsSession Pick() {
            if (mgr == null) return null;
            IReadOnlyList<GlobalSystemMediaTransportControlsSession> all;
            try { all = mgr.GetSessions(); } catch { return null; }
            GlobalSystemMediaTransportControlsSession playingNe = null, playing = null, ne = null, same = null;
            string shownId = null;
            try { if (shown != null) shownId = shown.SourceAppUserModelId; } catch { shownId = null; }
            foreach (var s in all) {
                bool p = IsPlaying(s), n = IsNe(s);
                if (p && n && playingNe == null) playingNe = s;
                if (p && playing == null) playing = s;
                if (n && ne == null) ne = s;
                try { if (shownId != null && same == null && s.SourceAppUserModelId == shownId) same = s; } catch { }
            }
            var pick = playingNe ?? playing ?? same ?? ne;
            if (pick == null) { try { pick = mgr.GetCurrentSession(); } catch { pick = null; } }
            return pick;
        }

        public static bool AnyPlaying() {
            if (mgr == null) return false;
            try { foreach (var s in mgr.GetSessions()) if (IsPlaying(s)) return true; } catch { }
            return false;
        }

        public static MediaInfo Read(string artDir) {
            var s = Pick();
            shown = s;
            if (s == null) return null;
            var info = new MediaInfo();
            try { info.App = s.SourceAppUserModelId ?? ""; } catch { }
            info.IsNetEase = IsNe(s);
            GlobalSystemMediaTransportControlsSessionMediaProperties p = null;
            try { p = Wait(s.TryGetMediaPropertiesAsync(), 4000); } catch (Exception ex) { LastError = ex.Message; }
            if (p != null) {
                info.Title = p.Title ?? ""; info.Artist = p.Artist ?? ""; info.Album = p.AlbumTitle ?? "";
            }
            try { info.Status = s.GetPlaybackInfo().PlaybackStatus.ToString(); } catch { info.Status = ""; }
            try {
                var tl = s.GetTimelineProperties();
                double dur = (tl.EndTime - tl.StartTime).TotalSeconds;
                info.Duration = Math.Round(Math.Max(0, dur), 2);
                info.Position = Math.Round(Math.Max(0, tl.Position.TotalSeconds), 2);
                info.Updated = tl.LastUpdatedTime.ToUnixTimeMilliseconds();
                info.HasTimeline = dur > 0 || tl.Position.TotalSeconds > 0;
            } catch { }
            info.Key = info.Artist + "|" + info.Title + "|" + info.Album;
            info.ArtFile = SaveArt(p, info.Key, artDir);
            return info;
        }

        // A fresh file name per track, so the overlay never reads a half-written image.
        static string SaveArt(GlobalSystemMediaTransportControlsSessionMediaProperties p, string key, string dir) {
            if (key == artKey && (artFile.Length == 0 || File.Exists(artFile))) return artFile;
            artKey = key; artFile = "";
            if (p == null || p.Thumbnail == null || string.IsNullOrEmpty(dir)) return "";
            try {
                string name = Path.Combine(dir, "media-art-" + ((uint)key.GetHashCode()).ToString() + ".img");
                foreach (var old in Directory.GetFiles(dir, "media-art-*.img")) {
                    if (!string.Equals(old, name, StringComparison.OrdinalIgnoreCase) && Path.GetFileName(old).IndexOf("-ne-", StringComparison.Ordinal) < 0) { try { File.Delete(old); } catch { } }
                }
                using (var ras = Wait(p.Thumbnail.OpenReadAsync(), 4000))
                using (var src = ras.AsStreamForRead())
                using (var dst = File.Create(name)) { src.CopyTo(dst); }
                artFile = name;
            } catch (Exception ex) { LastError = ex.Message; artFile = ""; }
            return artFile;
        }

        // Play/pause/next/previous on the session on screen. False when there is
        // none or it refused, so the caller can fall back to media keys.
        public static bool Command(string cmd) {
            var s = shown ?? Pick();
            if (s == null) return false;
            try {
                IAsyncOperation<bool> op;
                switch (cmd) {
                    case "toggle": op = s.TryTogglePlayPauseAsync(); break;
                    case "play": op = s.TryPlayAsync(); break;
                    case "pause": op = s.TryPauseAsync(); break;
                    case "next": op = s.TrySkipNextAsync(); break;
                    case "prev": op = s.TrySkipPreviousAsync(); break;
                    default: return false;
                }
                bool ok = Wait(op, 3000);
                Bump();
                return ok;
            } catch (Exception ex) { LastError = ex.Message; return false; }
        }
    }
}
