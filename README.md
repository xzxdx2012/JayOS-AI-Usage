# JayOS · AI Usage

A notch for Windows that shows how much of your AI limits you have used. It sits at the top of the screen like the notch on a Mac and covers **Claude**, **Codex**, **Cursor** and **Grok**.

## Install

1. Download **`JayOS-AI-Usage-Setup-0.0.2-beta.exe`** from [Releases](../../releases).
2. Double-click it and follow the wizard. You can pick the language (English, 中文, Français, 日本語, 한국어), the install folder, start with Windows and a desktop shortcut.

No admin rights are needed. Everything installs for the current user.

- **Silent install:** `JayOS-AI-Usage-Setup-0.0.2-beta.exe /S` installs with the default options and starts the app.
- **"Windows protected your PC":** the exe is not code-signed yet. Click **More info → Run anyway**.
- **PowerShell 7:** the app runs on PowerShell. If PowerShell 7 is not installed, setup downloads a portable copy into the install folder. Without internet it falls back to Windows PowerShell 5.1.

Prefer a zip? Download `JayOS-AI-Usage-0.0.2-beta.zip`, unzip it and double-click `Setup.vbs`. To run without installing, double-click `Start-Unified.vbs`.

**Uninstall:** Windows **Settings → Apps → Installed apps → JayOS AI Usage → Uninstall**.

## Use

- **Move the mouse to the top centre of the screen.** The notch drops down with the percentage used for each AI.
- **Click the notch** to open the full panel. The first AI is expanded and the mouse wheel switches to the others.
- **Move the mouse away** and the panel folds back. If you drag the panel somewhere else, use **−** in its top-left corner to send it back.
- **Pin** (right side of the notch) keeps the notch out.
- **Click an AI's icon** in the panel to open that app.
- **Refresh** at the top of the panel updates right away. **Accounts** shows who is signed in and lets you sign in.
- **Update** (the arrow next to Refresh) checks GitHub for a new version. A green dot means one is ready; click it to install. Your settings stay.
- **Settings** (bottom right): change the theme, background colour and language. Hover a theme or colour to preview it; the menu stays open while you pick, and closes when you click outside it. The menu can be dragged by its title.

Bar colours: green below 60 %, yellow from 60 %, red from 85 %. At 100 % the panel says the limit is used up.

## Requirements

- Windows 10 or 11
- PowerShell 7 (installed automatically if missing) or Windows PowerShell 5.1
- The AI tools you want to track, signed in on this computer (Claude Code, Codex CLI, Cursor, Grok)

## Project layout

| Path | What it is |
| --- | --- |
| `unified-overlay.ps1` | Entry point |
| `src/` | The app (WPF UI, data readers for each AI, settings) |
| `icons/` | Icons for the four AIs |
| `assets/` | App and tray icon |
| `Setup.ps1`, `Setup.vbs` | Setup wizard and uninstaller |
| `Start-Unified.vbs` | Starts the app without a console window |
| `installer/` | Source of the single-file `Setup.exe` (Go) |
| `sqlite3.exe` | Used to read Cursor's local usage database |

Settings are saved in `unified-overlay-state.json` next to the app. Errors go to `unified-overlay-error.log`, which is kept under 2 MB.

## Build the installer

```sh
go install github.com/akavel/rsrc@latest
./installer/build.sh
```

This creates `installer/JayOS-AI-Usage-Setup-<version>.exe`.

## License

[MIT](LICENSE)
