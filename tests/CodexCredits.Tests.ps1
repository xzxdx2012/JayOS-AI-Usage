# CodexCredits.Tests.ps1 - credits bought after the Codex plan limit.
# Pure parsing tests: no network, no WPF, no real ~/.codex.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:count = 0
function Assert($Value, [string]$Name) {
    if (-not $Value) { throw "FAILED: $Name" }
    $script:count++; Write-Output "PASS: $Name"
}

$script:AppDir = $root
$script:ErrLog = Join-Path ([IO.Path]::GetTempPath()) ('codex-credits-' + [guid]::NewGuid().ToString('N') + '.log')
function Get-WslHomeRoots { return @() }
. (Join-Path (Join-Path $root 'src') 'CodexData.ps1')

# The overlay helper lives in Shell.ps1 next to WPF code; load just it.
$shell = [IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'Shell.ps1'))
$ast = [System.Management.Automation.Language.Parser]::ParseInput($shell, [ref]$null, [ref]$null)
$fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-CodexCreditReference' }, $true) | Select-Object -First 1
. ([scriptblock]::Create($fn.Extent.Text))

try {
    $c = ConvertFrom-CodexCredits ([pscustomobject]@{ has_credits = $true; unlimited = $false; balance = '1995.0229500000' })
    Assert ($c.Has -and -not $c.Unlimited -and [math]::Abs($c.Balance - 1995.02295) -lt 1e-6) 'balance string parsed (invariant culture)'
    $c = ConvertFrom-CodexCredits ([pscustomobject]@{ has_credits = $false; unlimited = $false; balance = '0' })
    Assert (-not $c.Has -and $c.Balance -eq 0) 'no credits: balance 0'
    Assert ($null -eq (ConvertFrom-CodexCredits $null)) 'missing credits object -> null'

    $resp = [pscustomobject]@{
        plan_type  = 'plus'
        rate_limit = [pscustomobject]@{ secondary_window = [pscustomobject]@{ used_percent = 100; limit_window_seconds = 604800; reset_at = 1792876191 } }
        credits    = [pscustomobject]@{ has_credits = $true; unlimited = $false; balance = '1500.5' }
    }
    $live = ConvertFrom-CodexUsageResponse $resp
    Assert ($live.WeekPct -eq 100 -and $live.Credits.Balance -eq 1500.5) 'live usage response carries credits'

    $rl = [pscustomobject]@{
        primary   = [pscustomobject]@{ used_percent = 9; window_minutes = 300; resets_at = 1792476063 }
        secondary = [pscustomobject]@{ used_percent = 100; window_minutes = 10080; resets_at = 1792876191 }
        credits   = [pscustomobject]@{ has_credits = $true; unlimited = $false; balance = '1995.02' }
    }
    $stats = Measure-CodexStats @() (Get-Date) $rl
    Assert ($stats.Credits.Has -and $stats.Credits.Balance -eq 1995.02) 'session-log rate limits carry credits'
    $stats = Measure-CodexStats @() (Get-Date) $null
    Assert ($null -eq $stats.Credits) 'no rate limits: no credits'

    Assert ((Get-CodexCreditReference 1995.02) -eq 2000) 'top-up 1,995.02 reads as 2,000'
    Assert ((Get-CodexCreditReference 1000) -eq 1000) 'round top-up kept'
    Assert ((Get-CodexCreditReference 731.4) -eq 731.4) 'odd balance kept as is'

    $d = Get-Date
    $samples = @(
        @{ Date = $d.AddHours(-30); Has = $true;  Balance = 500 },
        @{ Date = $d.AddHours(-20); Has = $false; Balance = 0 },
        @{ Date = $d.AddHours(-3);  Has = $true;  Balance = 1995.02 },
        @{ Date = $d.AddHours(-1);  Has = $true;  Balance = 1847.48 }
    )
    Assert ((Get-CodexCreditPeak $samples) -eq 1995.02) 'top-up size found in the logs after the balance ran out'
    $samples += @{ Date = $d; Has = $true; Balance = 2847.48 }
    Assert ((Get-CodexCreditPeak $samples) -eq 2847.48) 'a balance that goes up is a new top-up'
    Assert ($null -eq (Get-CodexCreditPeak @(@{ Date = $d; Has = $false; Balance = 0 }))) 'no credits: no peak'

    # Turning points are kept while parsing a session log.
    $st = New-CodexParseState
    $mk = { param($t, $has, $bal) '{"timestamp":"' + $t + '","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1}},"rate_limits":{"credits":{"has_credits":' + $has + ',"unlimited":false,"balance":"' + $bal + '"}}}}' }
    $lines = @(
        (& $mk '2026-10-19T20:00:00Z' 'false' '0'),
        (& $mk '2026-10-19T22:54:00Z' 'true' '1995.02'),
        (& $mk '2026-10-19T23:30:00Z' 'true' '1950.10'),
        (& $mk '2026-10-20T01:00:00Z' 'true' '1866.00')
    )
    Update-CodexParseState -State $st -Lines $lines -FallbackSessionId 'x'
    Assert ($st.CreditPoints.Count -eq 2 -and $st.CreditPoints[1].Balance -eq 1995.02) 'parser keeps the top-up point, not every step down'
    Assert ((Get-CodexCreditPeak @($st.CreditPoints + @(@{ Date = (Get-Date); Has = $true; Balance = 1866.0 }))) -eq 1995.02) 'peak survives later spending in the same session'
    $round = ConvertFrom-CodexCachedState ([pscustomobject]@{ CreditPoints = @([pscustomobject]@{ Date = '2026-10-19T22:54:00Z'; Has = $true; Balance = 1995.02 }) })
    Assert ($round.CreditPoints.Count -eq 1 -and $round.CreditPoints[0].Balance -eq 1995.02) 'credit points survive the file cache'

    Write-Output "$script:count tests passed on PowerShell $($PSVersionTable.PSVersion)."
} finally {
    Remove-Item -LiteralPath $script:ErrLog -Force -ErrorAction SilentlyContinue
}
