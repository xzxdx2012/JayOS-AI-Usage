$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:count = 0
function Assert($Value, [string]$Name) {
    if (-not $Value) { throw "FAILED: $Name" }
    $script:count++; Write-Output "PASS: $Name"
}
function Import-TestFunction([string]$File, [string]$Name) {
    $t = $null; $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $File), [ref]$t, [ref]$e)
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    if (-not $fn) { throw "Missing function: $Name" }
    . ([scriptblock]::Create(($fn.Extent.Text -replace ('^function\s+' + [regex]::Escape($Name) + '\b'), ('function script:' + $Name))))
}
foreach ($n in 'New-CodexParseState','ConvertFrom-CodexCredits','Add-CodexCreditPoint','Get-CodexCreditPeak','ConvertFrom-CodexCachedState','Convert-CodexCacheDate','Convert-CodexCacheRecords') {
    Import-TestFunction 'src\CodexData.ps1' $n
}
$d = [datetime]'2026-10-20T12:00:00Z'
function Push-Credit($State, [double]$Balance, [int]$Minute) {
    Add-CodexCreditPoint $State ([pscustomobject]@{ has_credits = ($Balance -gt 0); unlimited = $false; balance = [string]$Balance }) ($d.AddMinutes($Minute))
}
$s = New-CodexParseState
Push-Credit $s 2000 0; Push-Credit $s 1000 1; Push-Credit $s 1500 2; Push-Credit $s 1400 3
Assert ((Get-CodexCreditPeak $s.CreditPoints) -eq 1500) 'parser detects a top-up below the historical maximum'
Assert ($s.CreditPoints.Count -eq 3) 'compression preserves the valley and top-up, not every spend'
$info = Get-CodexCreditPeak $s.CreditPoints -WithDate
Assert ($info.Balance -eq 1500 -and $info.Date -eq $d.AddMinutes(2)) 'peak carries the observation time'
$s = New-CodexParseState; Push-Credit $s 2000 0; Push-Credit $s 1000 1
$restored = ConvertFrom-CodexCachedState ($s | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
Push-Credit $restored 1500 2
Assert ((Get-CodexCreditPeak $restored.CreditPoints) -eq 1500) 'top-up detection survives a cache round trip'
Push-Credit $restored 0 3; Push-Credit $restored 500 4
Assert ((Get-CodexCreditPeak $restored.CreditPoints) -eq 500) 'running out starts a new reference'
Assert ($null -eq (Get-CodexCreditPeak @() -WithDate)) 'empty history has no reference'

Add-Type -AssemblyName PresentationFramework
foreach ($n in 'Get-CodexCreditReference','Test-ShowRemaining','Update-CodexCreditRow') { Import-TestFunction 'src\Shell.ps1' $n }
$script:controls = @{}
foreach ($n in 'codexCreditRow','codexCreditPct','codexCreditSub','codexCreditBar','codexCreditIcon') {
    $script:controls[$n] = [pscustomobject]@{ Visibility='Visible'; Text=''; Foreground=$null; Background=$null; Stroke=$null; ToolTip=''; Width=0 }
}
$script:window = New-Object PSObject
$script:window | Add-Member ScriptMethod FindName { param($n) $script:controls[$n] }
function NewBrush($c) { return $c }
function New-GradientBrush($a, $b) { return "$a/$b" }
function Get-UsageBandColor($v) { return '#FFFFFF' }
function Set-BarWidth($bar, $w) { $bar.Width=$w }
function Save-UnifiedState { }
$script:BarTrackWidth=250; $script:BandRedPct=85; $script:BandYellowPct=60
$script:Cfg=@{ CodexCreditPeak=2000.0; CodexCreditLast=1000.0; ShowRemaining=$true }
Update-CodexCreditRow @{ Unlimited=$false; Balance=1500.0 } 2000.0 ($d.AddMinutes(-1))
Assert ($script:Cfg.CodexCreditPeak -eq 1500) 'live top-up wins over an old larger log peak'
Update-CodexCreditRow @{ Unlimited=$false; Balance=1400.0 } 2000.0 ($d.AddMinutes(-1))
Assert ($script:Cfg.CodexCreditPeak -eq 1500) 'old log stays ignored on the next refresh'
Assert ($script:controls.codexCreditBar.Width -eq 233) 'bar uses the new reference'
$round = $script:Cfg | ConvertTo-Json | ConvertFrom-Json
$script:Cfg=@{}; foreach($p in $round.PSObject.Properties){$script:Cfg[$p.Name]=$p.Value}
Update-CodexCreditRow @{ Unlimited=$false; Balance=1300.0 } 2000.0 ($d.AddMinutes(-1))
Assert ($script:Cfg.CodexCreditPeak -eq 1500) 'stale log stays ignored after a settings round trip'
$script:Cfg=@{ CodexCreditPeak=2000.0; CodexCreditLast=1400.0 }
Update-CodexCreditRow @{ Unlimited=$false; Balance=1400.0 } 1500.0 ($d.AddMinutes(2))
Assert ($script:Cfg.CodexCreditPeak -eq 1500) 'migration repairs an old overestimated reference'
Update-CodexCreditRow @{ Unlimited=$false; Balance=0.0 } 1500.0 ($d.AddMinutes(2))
Assert (-not $script:Cfg.ContainsKey('CodexCreditEpoch')) 'zero balance clears the reference epoch'
$script:Cfg=@{ Unrelated=$true }
Update-CodexCreditRow @{ Unlimited=$false; Balance=1847.0 } 1995.0 $d
Assert ($script:Cfg.CodexCreditPeak -eq 1995) 'first sighting recovers a higher historical purchase'
$script:Cfg=@{ CodexCreditPeak=1500.0; CodexCreditLast=1400.0; CodexCreditEpoch=$d.ToString('o') }
Update-CodexCreditRow @{ Unlimited=$false; Balance=1400.0 } 1600.0 ($d.AddMinutes(2))
Assert ($script:Cfg.CodexCreditPeak -eq 1600) 'newer log evidence can refine the reference'

# This installed fixture also contained expectations for Set-CpValidation and
# a derived DisplayVersion from an uninstalled branch. Those functions are not
# part of the installed baseline; UI coverage lives in UiLogic/UiReview.Tests.
$unified=[IO.File]::ReadAllText((Join-Path $root 'src\UnifiedState.ps1'))
Assert ($unified -match "'CodexCreditEpoch'") 'credit epoch is included in settings loading'
Write-Output ("$script:count review-fix checks passed on PowerShell $($PSVersionTable.PSVersion).")
