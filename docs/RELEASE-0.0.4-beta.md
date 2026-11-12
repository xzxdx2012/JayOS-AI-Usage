# JayOS AI Usage 0.0.4 Beta

The island grows two new pages - **Music** and **Shelf** - gains a **DeepSeek Harness** card with the real account balance, and gets a redesigned **Settings** sheet, sharper rendering and smoother motion.

## New

- **Island pages.** Switch between **AI**, **Music** and **Shelf** with **‹ ›**, the page dots or a sideways touchpad swipe. Pages slide on one spring; all three share the same height.
- **Music page.** Now playing from any app that publishes a Windows media session (NetEase Cloud Music, Apple Music, Spotify, browsers ...), with cover, progress, synced lyrics and play/pause/next/previous.
  - The music helper now runs on PowerShell 7 like the rest of the app and listens to Windows media events: track changes, pauses and seeks show within about 0.1 s, play/pause flips on screen at once, and commands go to the session on screen (media keys as a fallback).
  - **NetEase Cloud Music** is also recognised without a media session - from its window title, local play queue and audio level (pause detection) - with cover and length from its queue or public search.
  - Lyrics come from NetEase's lyric service for NetEase tracks, otherwise from LRCLIB. Misses are retried after 6 hours.
  - Optional **Now playing on the notch** and **Lyrics on the notch**; on other pages the footer shows the current track.
- **Shelf page.** Files dropped on the island and recent clipboard text (in memory only; can be turned off).
- **DeepSeek Harness card.** Leads with the **remaining balance** from DeepSeek's official API - no estimates:
  - via your own `DEEPSEEK_API_KEY` (sent only to `api.deepseek.com`), or
  - via DeepSeek Harness's local server while it runs (optional access password in `deepseek-harness-token.txt`).
  - The last real balance is remembered with its time when no source answers. Local token, request and session counts come from Harness's own session files.
- **Connect wizards.** Signing in is now guided for every AI:
  - **Claude Code, Codex and Cursor:** step 1 checks the tool is installed (with a link to the official install guide), step 2 starts the tool's own sign-in (`claude auth login`, `codex login` or the Cursor app). The wizard re-checks every 1.5 s, ticks each finished step and confirms when the sign-in arrives. It opens from **Accounts**, the **Log in** menu and a card's status pill while that AI is not signed in. Passwords never pass through this app.
  - **DeepSeek:** an API-key wizard links to the DeepSeek platform, checks the pasted key's format (an ID pasted by mistake is caught), asks DeepSeek once whether the key works and shows the balance, then saves it encrypted for your Windows account (DPAPI) in `deepseek-api-key.dat`.
- **Settings sheet.**  The footer gear opens a compact, iOS-style sheet: quick tiles on top, grouped rows with switches and drill-down pages, built from the same items as the classic menu (still on the tray icon). It can be dragged and reopens under the gear. A new **Island** group holds the page, music, lyrics, clipboard and animation options.

## Improved

- **Cards.** All hero cards share one height; the original grow/shrink switch animation is smoother (no re-measuring, hit-testing or timers during the move). The panel reopens on the card you picked last, also after a restart.
- **One provider.** With a single AI switched on, its card fills the full width and the vertical wheel turns pages instead.
- **Statistics column** (cost, tokens, today, after hours, lifetime) appears on every card, and the **Show stats panel** switch now applies to all of them.
- **Meters** are sized to the hero card, so bars are no longer cut off when the statistics column is shown.
- **Codex** shows the 5-hour limit only when the plan has one (verified against Plus and Pro Lite responses), and refreshes stale plan data after an upgrade.
- **Sharper rendering.** The island window and its animation offsets snap to the monitor's pixel grid (crisp text at 125 % and other scalings); the settings sheet is opaque with no shadow effect, which removes the double image.
- **Page indicator** is drawn as a single image with sub-pixel motion: no shiver while the pill moves, and no flicker on the way back to the first page.
- **Setup wizard** no longer has an options page: the app starts with Windows and no desktop shortcut is created.

## Fixed

- The version string is now **0.0.4 Beta**; the previous "0.04 Beta" could not be read by the update checker.
- DeepSeek usage no longer re-reads all sessions on every refresh.
- Removed a hard-coded user path from the DeepSeek reader.

## Downloads

- **JayOS-AI-Usage-Setup-0.0.4-beta.exe** — Windows x64 single-file installer.
- **JayOS-AI-Usage-0.0.4-beta.zip** — application archive for portable use or scripted installation.
- **SHA256SUMS.txt** — SHA-256 checksums for both packages.

The installer is not code-signed. Packages do not include local credentials, API keys (plain or encrypted), settings, usage caches, history, logs, request files, music state or lyric caches. They now include `lib/winrt` (Microsoft-signed WinRT projection used by the music helper), which makes them larger than 0.0.3.

The Music page needs PowerShell 7. Existing account data and settings are retained during an update. Cursor remains experimental and requires a valid local sign-in. Grok Bot is not supported, because its desktop app does not publish usage data.
