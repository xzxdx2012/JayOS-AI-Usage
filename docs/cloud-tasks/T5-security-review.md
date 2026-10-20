# T5 - Review hooks/ClaudeHook.ps1 and src/Requests.ps1

Find ways the hook could (a) block Claude Code / Codex past their timeout, (b) answer a request the user did not answer, (c) remove or corrupt hook entries the user owns in ~/.claude/settings.json or ~/.codex/hooks.json, (d) leak request content to logs. For each real issue: a failing test first, then the fix. Write docs/reviews/0.0.3-hooks-review.md (Chinese) listing findings with severity, including ones you decided not to fix and why. Push `cloud/t5-review`, PR into `dev-0.0.3`.
