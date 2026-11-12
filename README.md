# JayOS · AI Usage

A Windows notch-style overlay for AI usage and permission requests. It lives at the top of the screen, shows account limits, and lets you respond to supported terminal requests without switching windows.

**Version: 0.0.4 Beta** · Maintained by **xzxdx2012**.

## Install

1. Download **JayOS-AI-Usage-Setup-0.0.4-beta.exe** from [Releases](../../releases).
2. Run the installer, choose a language and installation folder, and select **Install**.
3. The app starts with Windows; no desktop shortcut is created. (The wizard no longer has an options page.)

The installer runs per user and does not require administrator privileges. It prefers PowerShell 7, offers a portable runtime if needed, and falls back to Windows PowerShell 5.1 when unavailable. The Music page needs PowerShell 7.

- **Silent install:** `JayOS-AI-Usage-Setup-0.0.4-beta.exe /S`. A fresh install enables autostart without creating a desktop shortcut. An update preserves your existing shortcut choices.
- **Portable ZIP:** extract `JayOS-AI-Usage-0.0.4-beta.zip`, then run `Start-Unified.vbs`. Use `Setup.vbs` if you want to install it.
- **Uninstall:** Windows **Settings → Apps → Installed apps → JayOS AI Usage → Uninstall**.
- **Checksums:** compare the downloaded files with `SHA256SUMS.txt`.

The installer is not code-signed. Release archives never contain local credentials, usage caches, settings, history, logs, or pending request files.

## Use the notch

- Hover at the top center of the screen to show usage. Click to open the full panel.
- Move away to fold it. Pin the notch to keep it open, or drag the expanded panel to another position.
- Use the mouse wheel or provider headers to change the expanded card. The panel reopens on the card you picked last, also after a restart.
- With only one AI provider switched on, its card fills the full width and the mouse wheel turns pages instead.
- **‹ ›**, the page dots or a sideways touchpad swipe switch between the **AI**, **Music** and **Shelf** pages.
- **Accounts** shows sign-in status. Choosing an AI - or a card's status pill while it is not signed in - opens a **connect wizard**: step 1 checks the tool is installed (with a link to the official install guide), step 2 starts the tool's own sign-in (`claude auth login`, `codex login` or the Cursor app). It re-checks every 1.5 seconds and confirms when the sign-in arrives. Passwords never pass through this app.
- **Refresh** updates usage. The update button checks for published releases.
- The gear at the bottom right opens **Settings**: quick tiles on top, grouped options below, a page per group. Drag it by its background; it reopens under the gear. The tray icon keeps the classic menu.

The native window height contracts to the visible notch when idle, rather than leaving a full-height transparent panel underneath. Horizontal stage coordinates remain unchanged so dragging and permission-card positioning stay compatible.

## Music and Shelf pages

- **Music** shows what is playing - NetEase Cloud Music, Apple Music, Spotify, browsers and any app that publishes a Windows media session - with cover, progress, synced lyrics and play/pause/next/previous. Track changes and pauses appear within about a tenth of a second.
- NetEase Cloud Music is also recognised when it publishes no media session: from its window title, its local play queue and its audio level (for pause).
- Lyrics come from NetEase's lyric service for NetEase tracks, otherwise from [LRCLIB](https://lrclib.net). Only the title, artist, album and length are sent. Turn lookups off under **Settings → Island → Synced lyrics**.
- The notch can show the current track and lyric line (**Now playing on the notch**, **Lyrics on the notch**). On the other pages the footer shows the track; click it to open Music.
- **Shelf** keeps files dropped on the island and recent clipboard text (clipboard history can be turned off; it is kept in memory only).

The music helper reads Windows media sessions through the Microsoft WinRT projection in `lib/winrt` (`Microsoft.Windows.SDK.NET.dll`, `WinRT.Runtime.dll`, Microsoft-signed).

## DeepSeek balance

The DeepSeek card leads with the **remaining balance**, read from DeepSeek's official API - never estimated:

1. **Your API key** (recommended): choose DeepSeek under **Accounts** (or click the card's hint) to open the **API key wizard**. It links to [platform.deepseek.com/api_keys](https://platform.deepseek.com/api_keys), checks the pasted key's format, asks DeepSeek once whether it works, and only then saves it - encrypted for your Windows account (DPAPI) in `deepseek-api-key.dat`. The key is sent only to `api.deepseek.com`. `DEEPSEEK_API_KEY` and `deepseek-api-key.txt` still work as alternatives.
2. **DeepSeek Harness**, while it runs: the balance is read from its local server on `127.0.0.1`; Harness asks DeepSeek with its own key. If Harness has an access password, put it on the first line of `deepseek-harness-token.txt` in the app folder.

The last real balance is remembered with the time it was read, so the card still shows it - marked as a **last read** value - when no source answers. Local token, request and session counts come from DeepSeek Harness's own session files.

## Stable and experimental providers

Claude Code and Codex are available in ordinary mode. Their display preferences can be changed in the provider chooser.

**Cursor is experimental** and needs a valid local sign-in. **Grok Bot is not supported**: its desktop app does not publish usage data, so JayOS neither shows nor polls it.

Experimental readers require compatible local installations and valid sign-ins. Enabling the switch alone does not sign you in or guarantee that a provider API is available.

## Display preferences

Under **Settings → Panels & Features**, **Show remaining (not used)** changes the meter presentation. Meter colors still reflect the proportion used: green below 60%, yellow from 60%, and red from 85%.

Other options include compact layout, statistics, usage history, alerts, notch pinning, notifications, and request reminders. Appearance options include background color and language. Supported interface languages are English, Chinese, French, Japanese, and Korean; English is the default.

Purchased Codex credits appear as a separate row. The app uses observed balances to estimate the most recent top-up reference because the service does not expose an original purchase amount.

Automatic Claude sign-in renewal can be disabled under **Panels & Features**. When enabled, it may run a short background CLI prompt after an expired sign-in, subject to retry and timeout limits.

## Answer permission requests

Enable **Settings → Panels & Features → AI requests in the notch**. Supported Claude Code and Codex requests appear as cards with Allow, Deny, or In terminal actions. Supported questions, completion notices, and attention notices can also appear there.

Requests are queued. Answering in the terminal, closing the overlay, or a timeout returns control to the terminal's normal flow. The feature never approves a request on its own.

The integration registers only its own hooks in the providers' settings files. Existing unrelated hooks and settings are retained. Turning the feature off or uninstalling removes its own entries. Some providers require you to trust newly registered hooks in their terminal interface.

## Restore default settings

Open **Settings → System → Restore default settings** and confirm. The confirmation defaults to **No**.

The reset restores appearance, language, view mode, hotkeys, provider preferences, notifications, request handling, and experimental-feature preferences. Request handling and developer features return to their default off state. Waiting permission requests return to the terminal rather than being approved.

- Existing settings are backed up as `unified-overlay-state.json.before-defaults-<id>.bak`.
- Custom footer artwork and the renewal opt-out marker are backed up before their defaults are restored.
- Accounts, credentials, usage history, caches, and credit-reference observations are preserved.
- Windows startup and desktop-shortcut choices are not changed by the app reset.

## Project layout

| Path | Purpose |
| --- | --- |
| `unified-overlay.ps1` | Entry point and refresh workers |
| `src/` | UI, data readers, settings, and request handling |
| `hooks/` | Permission and notification hook |
| `assets/`, `icons/` | Artwork and notification sounds |
| `Setup.ps1`, `Setup.vbs` | Installer and uninstaller |
| `Start-Unified.vbs` | Console-free launcher |
| `installer/` | Go single-file installer source and build scripts |
| `lib/winrt/` | Microsoft WinRT projection used by the music helper |
| `tests/` | Fixture-based regression tests |
| `sqlite3.exe` | Local database reader used by the experimental Cursor integration |

Settings are stored next to the installed application in `unified-overlay-state.json`. Errors are written to `unified-overlay-error.log` with size-limited rotation.

## Build and test

Requires Windows, Go 1.24 or later, PowerShell, and `rsrc`:

```powershell
go install github.com/akavel/rsrc@v0.10.2
./installer/build.ps1 -OutputDirectory C:\build\jayos
```

The build packages an explicit application-file allowlist, tests payload extraction and content, and writes EXE, ZIP, and SHA-256 checksum files.

Run each `tests/*.Tests.ps1` with PowerShell 7 (and Windows PowerShell 5.1 for the 5.1-compatible parts). Native WPF bounds coverage can be run separately with:

```powershell
pwsh -STA -NoProfile -File tests/NotchWindowBounds.Wpf.ps1
```

## License

[MIT](LICENSE)
