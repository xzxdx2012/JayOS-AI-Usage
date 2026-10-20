# JayOS AI Usage - notes for Claude

A Windows "notch" overlay (PowerShell 7 / Windows PowerShell 5.1 + WPF) that shows Claude, Codex,
Cursor and Grok usage and answers Claude Code / Codex permission requests from the notch.
Read docs/DEVELOPMENT.md before changing anything.

## Rules
- The owner reads Chinese: write every summary, PR description and question to the owner in **Simplified Chinese**. Code, comments and commit messages stay in English.
- Keep Windows PowerShell 5.1 compatibility (no `??`, no ternary, no `-AsHashtable`, no `&&` in .ps1).
- WPF cannot run in this Linux VM. Test logic with `pwsh` (PowerShell 7 is preinstalled or installable); do not try to start the UI.
- Never read or print credential files (Claude `.credentials.json`, Codex `auth.json`) - tests use fixtures only.
- Every user-visible English string needs zh/ja/fr/ko entries in the i18n tables (src/UnifiedTray.ps1 `$script:I18nText`, src/Requests.ps1 pair list).
- Run all tests before you push: `for t in tests/*.Tests.ps1; do pwsh -NoProfile -File "$t" || exit 1; done`
- Work only on your task file in docs/cloud-tasks/. Push your own branch; never push to main or dev-0.0.3 directly unless the task says so.
