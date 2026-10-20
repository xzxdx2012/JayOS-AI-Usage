# UiLogic.Tests.ps1 - UI-independent helpers from Shell.ps1 and UnifiedTray.ps1.
# Only the needed functions (and the script variables they read) are loaded
# through the AST, so no WPF window is built.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:count = 0
function Assert($Value, [string]$Name) {
    if (-not $Value) { throw "FAILED: $Name" }
    $script:count++; Write-Output "PASS: $Name"
}

function Import-SourcePart([string]$File, [string[]]$Functions, [string[]]$Variables) {
    $text = [IO.File]::ReadAllText([IO.Path]::Combine($root, 'src', $File))
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
    foreach ($v in $Variables) {
        $a = $ast.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $_.Left.Extent.Text -eq ('$script:' + $v)
        } | Select-Object -First 1
        if (-not $a) { throw "Variable not found: $v" }
        . ([scriptblock]::Create($a.Extent.Text))
    }
    foreach ($f in $Functions) {
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $f }, $true) | Select-Object -First 1
        if (-not $fn) { throw "Function not found: $f" }
        . ([scriptblock]::Create($fn.Extent.Text))
    }
}

. Import-SourcePart 'Shell.ps1' @('Get-UsageBandColor', 'Get-UsageSpectrumStops', 'New-UsageBrush', 'Format-PanelReset',
    'Get-CodexCreditReference', 'Get-ClaudeCloudCredit') @('BandYellowPct', 'BandRedPct', 'UsageSpectrum')
. Import-SourcePart 'UnifiedTray.ps1' @('ConvertTo-CpRgb', 'ConvertFrom-CpHex', 'Get-CpPanelHex', 'Get-CpRecent', 'Add-CpRecent',
    'Get-CpCap', 'Get-CpFinalHex') @('PanelBgPresets')

function Get-Lum([string]$Hex) {
    $r = [Convert]::ToInt32($Hex.Substring(1, 2), 16); $g = [Convert]::ToInt32($Hex.Substring(3, 2), 16); $b = [Convert]::ToInt32($Hex.Substring(5, 2), 16)
    return (0.2126 * $r + 0.7152 * $g + 0.0722 * $b) / 255.0
}
function Get-IsoIn([double]$Seconds) { return [DateTimeOffset]::UtcNow.AddSeconds($Seconds).ToString('o') }

# --- Usage bands ------------------------------------------------------------
Assert ($null -eq (Get-UsageBandColor $null)) 'band: no usage -> no colour'
Assert ((Get-UsageBandColor 0) -eq '#30D158') 'band: 0 % green'
Assert ((Get-UsageBandColor 59.9) -eq '#30D158') 'band: 59.9 % still green'
Assert ((Get-UsageBandColor 60) -eq '#FFD60A') 'band: 60 % yellow'
Assert ((Get-UsageBandColor 84.99) -eq '#FFD60A') 'band: 84.99 % still yellow'
Assert ((Get-UsageBandColor 85) -eq '#FF453A') 'band: 85 % red'
Assert ((Get-UsageBandColor 140) -eq '#FF453A') 'band: over 100 % red'
Assert ((Get-UsageBandColor '72') -eq '#FFD60A') 'band: numeric string accepted'

# --- Usage brush stops --------------------------------------------------------
$stops = @(Get-UsageSpectrumStops 100)
Assert ($stops.Count -eq $script:UsageSpectrum.Count) 'brush: one stop per spectrum point'
Assert ($stops[0].Offset -eq 0 -and $stops[-1].Offset -eq 1 -and $stops[2].Offset -eq 0.6 -and $stops[4].Offset -eq 0.85) 'brush: 100 % maps spectrum onto the track'
Assert ($stops[0].Color -eq '#30D158' -and $stops[-1].Color -eq '#D70015') 'brush: green start, deep red end'
$stops = @(Get-UsageSpectrumStops 50)
Assert ($stops[2].Offset -eq 1.2 -and [math]::Abs($stops[1].Offset - 0.7) -lt 1e-9) 'brush: 50 % bar stretches stops against the fill'
$stops = @(Get-UsageSpectrumStops 0)
Assert ($stops[1].Offset -eq 35) 'brush: 0 % clamps to 1 % (no division by zero)'
$stops = @(Get-UsageSpectrumStops $null)
Assert ($stops[1].Offset -eq 35) 'brush: missing usage treated as 1 %'
$stops = @(Get-UsageSpectrumStops 250)
Assert ($stops[-1].Offset -eq 1) 'brush: over 100 % clamps to 100 %'
$ascending = $true
$stops = @(Get-UsageSpectrumStops 42)
for ($i = 1; $i -lt $stops.Count; $i++) { if ($stops[$i].Offset -le $stops[$i - 1].Offset) { $ascending = $false } }
Assert $ascending 'brush: offsets strictly ascending'
$wpf = $false
try { Add-Type -AssemblyName PresentationCore -ErrorAction Stop; $wpf = $true } catch { }
if ($wpf) {
    $b = New-UsageBrush 50
    Assert ($b.GradientStops.Count -eq 6 -and $b.GradientStops[2].Offset -eq 1.2) 'brush: WPF brush uses the computed stops'
} else {
    Write-Output 'SKIP: New-UsageBrush (WPF not available)'
}

# --- Colour picker maths ------------------------------------------------------
Assert ((ConvertTo-CpRgb 0 1 1) -join ',' -eq '255,0,0') 'hsv: red'
Assert ((ConvertTo-CpRgb 120 1 1) -join ',' -eq '0,255,0') 'hsv: green'
Assert ((ConvertTo-CpRgb 240 1 1) -join ',' -eq '0,0,255') 'hsv: blue'
Assert ((ConvertTo-CpRgb 360 1 1) -join ',' -eq '255,0,0') 'hsv: 360 wraps to red'
Assert ((ConvertTo-CpRgb -120 1 1) -join ',' -eq '0,0,255') 'hsv: negative hue wraps'
Assert ((ConvertTo-CpRgb 77 0 0.5) -join ',' -eq '128,128,128') 'hsv: no saturation is grey'
Assert ((ConvertTo-CpRgb 200 0.8 0) -join ',' -eq '0,0,0') 'hsv: no value is black'
$hsv = ConvertFrom-CpHex '#FF0000'
Assert ($hsv[0] -eq 0 -and $hsv[1] -eq 1 -and $hsv[2] -eq 1) 'hex->hsv: red'
$hsv = ConvertFrom-CpHex '#0000FF'
Assert ($hsv[0] -eq 240 -and $hsv[1] -eq 1 -and $hsv[2] -eq 1) 'hex->hsv: blue'
$hsv = ConvertFrom-CpHex '#FF00FF'
Assert ($hsv[0] -eq 300) 'hex->hsv: magenta hue 300 (negative branch lifted)'
$hsv = ConvertFrom-CpHex '#000000'
Assert ($hsv[0] -eq 0 -and $hsv[1] -eq 0 -and $hsv[2] -eq 0) 'hex->hsv: black'
$ok = $true
foreach ($hex in @('#1A1A1E', '#050505', '#28231E', '#1B2330', '#14281D', '#121F3A', '#261838', '#33151C', '#FFFFFF', '#7F3FBF', '#00FF80', '#123456')) {
    $hsv = ConvertFrom-CpHex $hex
    $rgb = ConvertTo-CpRgb $hsv[0] $hsv[1] $hsv[2]
    if (('#{0:X2}{1:X2}{2:X2}' -f $rgb[0], $rgb[1], $rgb[2]) -ne $hex) { $ok = $false; Write-Output "round trip broke for $hex" }
}
Assert $ok 'hex -> hsv -> rgb round trip'

Assert ((Get-CpCap 240 1) -eq 1.0) 'cap: pure blue is dark enough already'
Assert ([math]::Abs((Get-CpCap 0 0) - 0.28) -lt 1e-9) 'cap: white capped at 0.28'
Assert ([math]::Abs((Get-CpCap 120 1) - 0.28 / 0.7152) -lt 1e-9) 'cap: green capped by its luminance'
Assert ((Get-CpFinalHex 240 1 1) -eq '#0000FF') 'final: pure blue kept'
Assert ((Get-CpFinalHex 0 0 1) -eq '#474747') 'final: white darkened to legible grey'
Assert ((Get-CpFinalHex 0 0 5) -eq (Get-CpFinalHex 0 0 1)) 'final: value above 1 clamped'
Assert ((Get-CpFinalHex 30 0.5 -1) -eq '#000000') 'final: value below 0 clamped'
# Channel rounding can lift the luminance by up to 0.5/255.
$ok = $true
foreach ($h in 0, 45, 90, 135, 180, 225, 270, 315) { foreach ($s in 0, 0.3, 0.7, 1) {
    if ((Get-Lum (Get-CpFinalHex $h $s 1)) -gt 0.283) { $ok = $false; Write-Output "too bright at $h/$s" }
} }
Assert $ok 'final: brightest pick never exceeds the panel luminance cap'
Assert ((Get-CpFinalHex 60 1 1) -eq (Get-CpPanelHex 255 255 0)) 'final: brightest yellow matches Get-CpPanelHex'

$script:Cfg = $null
Assert (@(Get-CpRecent).Count -eq 0) 'recent: no settings -> empty'
Add-CpRecent '#112233'
Assert ($null -eq $script:Cfg) 'recent: add without settings is a no-op'
$script:Cfg = @{ PanelBgRecent = '#112233,bad,#ABCDEF,#12345,#abcdef' }
Assert ((@(Get-CpRecent) -join ',') -eq '#112233,#ABCDEF,#abcdef') 'recent: invalid entries dropped'
$script:Cfg = @{}
Add-CpRecent '#111111'; Add-CpRecent '#222222'; Add-CpRecent '#111111'
Assert ($script:Cfg['PanelBgRecent'] -eq '#111111,#222222') 'recent: newest first, no duplicates'
Add-CpRecent '#1A1A1E'
Assert ($script:Cfg['PanelBgRecent'] -eq '#111111,#222222') 'recent: presets are not remembered'
for ($i = 1; $i -le 10; $i++) { Add-CpRecent ('#0000{0:X2}' -f $i) }
$r = @(Get-CpRecent)
Assert ($r.Count -eq 8 -and $r[0] -eq '#00000A' -and $r[-1] -eq '#000003') 'recent: capped at 8'

# --- Codex credit reference -------------------------------------------------
Assert ((Get-CodexCreditReference 1995.02) -eq 2000) 'credit ref: 1,995.02 -> 2,000'
Assert ((Get-CodexCreditReference 1000) -eq 1000) 'credit ref: round value kept'
Assert ((Get-CodexCreditReference 731.4) -eq 731.4) 'credit ref: odd value kept'
Assert ((Get-CodexCreditReference 497) -eq 500) 'credit ref: 497 -> 500'
Assert ((Get-CodexCreditReference 49.6) -eq 50) 'credit ref: 49.6 -> 50'
Assert ((Get-CodexCreditReference 9.95) -eq 10) 'credit ref: 9.95 -> 10'
Assert ((Get-CodexCreditReference 0) -eq 0) 'credit ref: zero stays zero'

# --- Claude cloud credit ------------------------------------------------------
Assert ($null -eq (Get-ClaudeCloudCredit $null)) 'cloud: no data'
Assert ($null -eq (Get-ClaudeCloudCredit ([pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 10 } }))) 'cloud: no credit-shaped entry'
$obj = [pscustomobject]@{
    five_hour        = [pscustomobject]@{ utilization = 12; resets_at = '2026-10-20T10:00:00Z' }
    seven_day_opus   = [pscustomobject]@{ limit_dollars = 5; remaining_dollars = 1; resets_at = 'x' }
    extra_usage      = [pscustomobject]@{ limit_dollars = 7; remaining_dollars = 2 }
    tags             = @([pscustomobject]@{ limit_dollars = 9; remaining_dollars = 9 })
    note             = 'hello'
    zeroed           = [pscustomobject]@{ limit_dollars = 0; remaining_dollars = 0 }
    juniper_pantheon = [pscustomobject]@{ limit_dollars = 100; remaining_dollars = 63.5; resets_at = '2026-11-30T08:00:00Z' }
}
$c = Get-ClaudeCloudCredit $obj
Assert ($c -and $c.Limit -eq 100 -and $c.Left -eq 63.5 -and $c.ExpiresAt -eq '2026-11-30T08:00:00Z') 'cloud: found by shape in a PSCustomObject, skipping known/array/zero entries'
$c = Get-ClaudeCloudCredit @{ five_hour = @{ utilization = 1 }; cedar = @{ limit_dollars = '50'; remaining_dollars = '12.25'; resets_at = '2026-12-01T00:00:00Z' } }
Assert ($c -and $c.Limit -eq 50 -and $c.Left -eq 12.25) 'cloud: hashtable input'
Assert ($null -eq (Get-ClaudeCloudCredit @{ cedar = @{ limit_dollars = 50 } })) 'cloud: missing remaining_dollars'
$c = Get-ClaudeCloudCredit @{ cedar = @{ limit_dollars = 20; remaining_dollars = 0 } }
Assert ($c -and $c.Left -eq 0 -and $c.ExpiresAt -eq '') 'cloud: spent credit and no expiry still reported'
$json = '{"five_hour":{"utilization":3,"resets_at":"2026-10-20T10:00:00Z"},"maple":{"limit_dollars":100,"remaining_dollars":99,"resets_at":"2026-11-30T08:00:00Z"}}' | ConvertFrom-Json
$c = Get-ClaudeCloudCredit $json
Assert ($c -and $c.ExpiresAt -is [string]) 'cloud: JSON input gives a string expiry'
Assert ([DateTimeOffset]::Parse($c.ExpiresAt).UtcDateTime -eq [datetime]::new(2026, 11, 30, 8, 0, 0, [DateTimeKind]::Utc)) 'cloud: expiry survives the PS7 [datetime] conversion'
$c = Get-ClaudeCloudCredit @{ maple = @{ limit_dollars = 1; remaining_dollars = 1; resets_at = [DateTimeOffset]::new(2026, 11, 30, 8, 0, 0, [TimeSpan]::Zero) } }
Assert ([DateTimeOffset]::Parse($c.ExpiresAt).UtcDateTime.Hour -eq 8) 'cloud: DateTimeOffset expiry handed on as ISO'

# --- Panel reset wording ----------------------------------------------------
Assert ((Format-PanelReset '') -eq '') 'reset: empty'
Assert ((Format-PanelReset 'not a date') -eq '') 'reset: garbage'
Assert ((Format-PanelReset (Get-IsoIn -60)) -eq 'resetting now') 'reset: past'
Assert ((Format-PanelReset (Get-IsoIn 20)) -eq '1m left') 'reset: under a minute shows 1m'
Assert ((Format-PanelReset (Get-IsoIn (10 * 60 + 30))) -eq '10m left') 'reset: minutes'
Assert ((Format-PanelReset (Get-IsoIn (4 * 3600 + 5 * 60 + 30))) -eq '4h 05m left') 'reset: hours pad minutes'
Assert ((Format-PanelReset (Get-IsoIn (3 * 86400 + 20 * 3600 + 30))) -eq '3d 20h left') 'reset: days'
Assert ((Format-PanelReset (Get-IsoIn (86400 + 30))) -eq '1d 0h left') 'reset: exactly a day'

Write-Output "$script:count tests passed on PowerShell $($PSVersionTable.PSVersion)."
