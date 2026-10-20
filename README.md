# JayOS · AI Usage

A Windows notch-style overlay for AI usage and permission requests. It lives at the top of the screen, shows account limits, and lets you respond to supported terminal requests without switching windows.

**Version: 0.0.3 Beta** · Maintained by **xzxdx2012**.

## Install

1. Download **JayOS-AI-Usage-Setup-0.0.3-beta.exe** from [Releases](../../releases).
2. Run the installer and choose a language and installation folder.
3. **Start when Windows starts** is on by default. **Create a desktop shortcut** is off by default; enable it if wanted.

The installer runs per user and does not require administrator privileges. It prefers PowerShell 7, offers a portable runtime if needed, and falls back to Windows PowerShell 5.1 when unavailable.

- **Silent install:** `JayOS-AI-Usage-Setup-0.0.3-beta.exe /S`. A fresh install enables autostart without creating a desktop shortcut. An update preserves your existing shortcut choices.
- **Portable ZIP:** extract `JayOS-AI-Usage-0.0.3-beta.zip`, then run `Start-Unified.vbs`. Use `Setup.vbs` if you want to install it.
- **Uninstall:** Windows **Settings → Apps → Installed apps → JayOS AI Usage → Uninstall**.
- **Checksums:** compare the downloaded files with `SHA256SUMS.txt`.

The installer is not code-signed. Release archives never contain local credentials, usage caches, settings, history, logs, or pending request files.

## Use the notch

- Hover at the top center of the screen to show usage. Click to open the full panel.
- Move away to fold it. Pin the notch to keep it open, or drag the expanded panel to another position.
- Use the mouse wheel or provider headers to change the expanded card.
- **Accounts** shows sign-in status and opens the appropriate sign-in or provider page.
- **Refresh** updates usage. The update button checks for published releases.
- The settings menu can be moved by dragging its title.

The native window height contracts to the visible notch when idle, rather than leaving a full-height transparent panel underneath. Horizontal stage coordinates remain unchanged so dragging and permission-card positioning stay compatible.

## Stable and experimental providers

Claude Code and Codex are available in ordinary mode. Their display preferences can be changed in the provider chooser.

**Cursor and Grok are experimental.** Enable **Settings → Panels & Features → Developer features (Cursor / Grok beta)** to reveal their account, provider, and platform entries and start their usage readers. The switch is **off by default**. Turning it off hides those entries and prevents subsequent experimental usage refreshes without deleting account data or saved provider choices. An already-running refresh may finish.

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

Run each `tests/*.Tests.ps1` with both PowerShell 7 and Windows PowerShell 5.1. Native WPF bounds coverage can be run separately with:

```powershell
pwsh -STA -NoProfile -File tests/NotchWindowBounds.Wpf.ps1
```

## License

[MIT](LICENSE)
