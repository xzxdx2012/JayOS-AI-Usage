# JayOS · AI Usage

A notch for Windows that shows how much of your AI limits you have used. It sits at the top of the screen like the notch on a Mac and covers **Claude**, **Codex**, **Cursor** and **Grok**.

## Install

1. Download **`JayOS-AI-Usage-Setup-0.0.3-beta.exe`** from [Releases](../../releases).
2. Double-click it and follow the wizard. You can pick the language (English, 中文, Français, 日本語, 한국어), the install folder, start with Windows and a desktop shortcut.

No admin rights are needed. Everything installs for the current user.

- **Silent install:** `JayOS-AI-Usage-Setup-0.0.3-beta.exe /S` installs with the default options and starts the app.
- **"Windows protected your PC":** the exe is not code-signed yet. Click **More info → Run anyway**.
- **PowerShell 7:** the app runs on PowerShell. If PowerShell 7 is not installed, setup downloads a portable copy into the install folder. Without internet it falls back to Windows PowerShell 5.1.

Prefer a zip? Download `JayOS-AI-Usage-0.0.3-beta.zip`, unzip it and double-click `Setup.vbs`. To run without installing, double-click `Start-Unified.vbs`.

**Uninstall:** Windows **Settings → Apps → Installed apps → JayOS AI Usage → Uninstall**.

## Use

- **Move the mouse to the top centre of the screen.** The notch drops down with the percentage used for each AI.
- **Click the notch** to open the full panel. The first AI is expanded and the mouse wheel switches to the others.
- **Move the mouse away** and the panel folds back. If you drag the panel somewhere else, use **−** in its top-left corner to send it back.
- **Pin** (right side of the notch) keeps the notch out.
- **Click an AI's icon** in the panel to open that app.
- **Refresh** at the top of the panel updates right away. **Accounts** shows who is signed in and lets you sign in.
- **Update** (the arrow next to Refresh) checks GitHub for a new version. A green dot means one is ready; click it to install. Your settings stay.
- **Settings** (bottom right): change the background colour and language. Hover a colour to preview it, or open **Custom…** for a colour picker (drag the square and hue strip or type a hex code; the panel previews as you go and keeps your recent colours); the menu stays open while you pick, and closes when you click outside it. The menu can be dragged by its title.

**Codex credits:** once you have bought extra Codex credits (after the plan limit is used up), the Codex card adds a **Credits** row with what is left and a bar against your last top-up. Codex only reports the balance, so the top-up size is the highest balance seen since the last purchase.

Bar colours follow usage, in the notch and in the panel: green while there is plenty left, through yellow from 60 % to red from 85 %. At 100 % the panel says the limit is used up.

**Claude sign-in renewal:** Claude Code's access token expires after a few hours. When it has, the app asks Claude Code to renew it by running it hidden with a one-line Haiku prompt (at most every 30 minutes, at most 3 times; a run that hangs is stopped after 3 minutes). Turn this off under **Settings → Panels & Features → Renew Claude sign-in automatically**; then an expired sign-in simply asks you to sign in again.

## Answer Claude Code and Codex from the notch

Turn on **Settings → Panels & Features → AI requests in the notch**. When Claude Code or Codex needs you, a card grows out of the notch with a chime, and you answer it there instead of switching to the terminal:

- **Permission requests** (run a command, edit files, open a web page, …): **Allow**, **Deny** or **In terminal**. Claude Code also offers **Always allow**.
- **Questions with options** (Claude Code): click an option. A single question is answered on the first click.
- **"Shall I continue?"** at the end of a turn: **Continue** lets the agent carry on; **I'll reply myself** hands it back to the terminal.

Notices come out of the notch the same way and close on their own (hover to keep one open):

- **Task finished**: when a turn ends without a question, with its last paragraph and a soft chime (Claude Code and Codex).
- **Needs you in the terminal** (Claude Code): its own permission dialog, waiting for your input, a form to fill in; also an either/or question that "Continue" cannot answer.

Turn them on or off under **Settings → Panels & Features → Notify when a task finishes / Notify when the AI needs you**. Anything that needs an answer comes first; a notice gives way to it.

Several requests queue up and come out one at a time. If a card is not answered, the chime plays once more after 25 seconds; change or turn this off under **Settings → Panels & Features → Remind again if unanswered**. Whatever you do in the terminal still works: answering there, a timeout or a closed notch all fall back to the agent's normal prompt.

How it connects:

- **Claude Code:** `PermissionRequest`, `Stop` and `Notification` hooks in `~/.claude/settings.json`.
- **Codex:** the same two hooks in `~/.codex/hooks.json` (only if Codex is installed). Codex asks you to trust new hooks once: run `/hooks` in Codex and trust the JayOS entries. Codex does not let hooks add permanent rules or answer option questions, so its cards offer Allow / Deny / In terminal.

Your other settings and hooks are kept, and a backup of each file is saved next to it (`*.jayos-backup`). Turning the option off or uninstalling removes the entries again.

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
| `assets/` | App and tray icon, request chime |
| `hooks/` | Claude Code hook for "AI requests in the notch" |
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
