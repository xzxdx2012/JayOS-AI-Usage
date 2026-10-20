# Development notes (0.0.3 beta)

## Layout
| Path | What |
|---|---|
| unified-overlay.ps1 | Entry point, background refresh jobs (ClaudeUsage, ClaudeStats, CodexStats, GrokUsage) |
| src/UnifiedTray.ps1 | Notch, settings menu, i18n tables, colour picker, refresh, hover logic (~3,700 lines) |
| src/Shell.ps1 | Main panel XAML and per-provider section updaters (Update-ClaudeSection, Update-CodexSection, ...) |
| src/Requests.ps1 | "AI requests in the notch": hook registration, request/notice cards, animation, sounds |
| hooks/ClaudeHook.ps1 | Hook that Claude Code / Codex run (Windows PowerShell 5.1); `-Agent codex` for Codex |
| src/Data.ps1 | Claude usage + Claude sign-in renewal |
| src/CodexData.ps1 | Codex usage (session logs + chatgpt.com/backend-api/wham/usage) and bought credits |
| src/UnifiedState.ps1 | Settings (unified-overlay-state.json); only keys listed in Load-UnifiedState are restored |
| Setup.ps1 / installer/ | Setup wizard + uninstaller; Go single-file installer (installer/build.sh) |
| tests/*.Tests.ps1 | Plain PowerShell test scripts (no Pester); each prints "N tests passed" |

## Notch <-> hook file protocol (<app>/requests/)
- `<32 hex>.req.json` request written by the hook; `<id>.resp.json` answer written by the notch (bound to id + session, written via temp file + File.Move, never overwritten).
- `<id>.note.json` notices: id, agent (claude|codex|cowork), kind (done|ask|permission|idle|input), expires (ISO UTC), message, chain (ancestor pids), session, cwd, optional `sticky` (cowork approval cards stay until withdrawn = expires set to the past).
- `overlay.alive` heartbeat touched about once a second; hook needs it <= 6 s old at start, <= 10 s while waiting, else prints nothing and exits 0.
- `hook-registrations.json` lists the exact hook commands JayOS wrote; only those are ever removed. Writes are serialised with mutex `Local\JayOS-AIUsage-AgentHooks`.

## Colours
Usage bands: green < 60 %, yellow >= 60 %, red >= 85 % (Get-UsageBandColor). Panel bars use New-UsageBrush (a green->yellow->orange->red spectrum placed against the full track). "Remaining" bars (Codex credits, Claude cloud credit) colour by the used share.

## Known pitfalls
- PowerShell 7 ConvertFrom-Json turns ISO strings into [datetime]; normalise before parsing (ConvertTo-ReqUtc, ConvertTo-RenewalUtc).
- `@($emptyList)` on a generic List can throw; use `.ToArray()`.
- `$host` is reserved. Use `[IO.Path]::Combine` instead of Join-Path with drive letters in tests.
- Don't use `.GetNewClosure()` in WPF event handlers (script functions become invisible); call plain functions.
- Don't rely on `x:Name` on Freezables (brushes) in XAML; build brushes in code.
- Tests build paths from relative parts (Join-Path / [IO.Path]::Combine) and use fixture paths for executables and install folders, so they run unchanged on Windows and Linux.

## Data sources
- Claude: OAuth usage endpoint. Fields five_hour, seven_day, seven_day_opus, seven_day_fable (often absent), a promotional cloud-session credit under a changing code name (found by shape: limit_dollars / remaining_dollars / resets_at). No reset-credit count is exposed.
- Codex: `credits {has_credits, unlimited, balance}` in wham/usage and in session-log rate_limits; `rate_limit_reset_credits.available_count` = resets available.
