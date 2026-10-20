# T3 - Unit tests for UI-independent helpers

Add `tests/UiLogic.Tests.ps1` that loads only the needed functions from src/Shell.ps1 and src/UnifiedTray.ps1 via the PowerShell AST (see tests/CodexCredits.Tests.ps1 for the pattern) and covers:
- Get-UsageBandColor thresholds; New-UsageBrush stop offsets (skip if WPF types are unavailable, but test the offset maths by extracting it into a pure helper if needed).
- Colour picker maths: ConvertTo-CpRgb / ConvertFrom-CpHex round trips, Get-CpCap, Get-CpFinalHex, Get-CpRecent / Add-CpRecent.
- Get-CodexCreditReference, Get-ClaudeCloudCredit (PSCustomObject and hashtable input, missing data, PS7 [datetime] resets_at).
- Format-PanelReset outputs.
Refactor tiny pure helpers out of WPF code only when it is needed for testing and keeps behaviour identical. All tests must pass. Push `cloud/t3-ui-tests`, PR into `dev-0.0.3`, summary in Chinese.
