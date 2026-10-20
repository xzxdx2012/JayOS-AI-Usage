$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:count = 0
function Assert($v,$name) { if (-not $v) { throw "FAILED: $name" }; $script:count++ }
$path = Join-Path $root 'src/UnifiedTray.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$null)
foreach ($v in 'I18nText','I18nRules','I18nOrig','I18nLast','I18nLangs','ProviderPillStyles') {
    $a = $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq ('$script:'+$v) } | Select-Object -First 1
    . ([scriptblock]::Create($a.Extent.Text))
}
foreach ($name in 'Convert-I18nString','Get-I18nSource','Set-I18nMemo','Get-UiLanguage','Invoke-I18nToolTip','Invoke-MenuTranslate') {
    $fn = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    if ($fn) { . ([scriptblock]::Create($fn.Extent.Text)) }
}
$reqAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src/Requests.ps1'),[ref]$null,[ref]$null)
$pairs = $reqAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.ForEachStatementAst] -and $_.Variable.VariablePath.UserPath -eq 'pair' } | Select-Object -First 1
. ([scriptblock]::Create($pairs.Extent.Text))
$texts = @('Monitor with mouse','Primary','Display 2 (primary)','Install Claude Code','Dashboard','Cursor docs','ChatGPT Codex','Install Codex CLI','Install Grok CLI','Console / billing',
    'as of 2026-10-20 10:00','Claude Usage Critical','Claude Usage Warning','5-hour session at 95%','5-hour session at 95% (~15 min to limit)',
    'AI Usage Overlay Test','Threshold alerts are working.','Click to sign in to Claude','Open Codex','Drag to move',
    'Not installed - opens the install page','Click to sign in again','Signed in - last refresh failed','Signed in (token idle) - click to sign in again',
    'Live access expired - click to sign in','Click to sign in','Waiting for the first refresh',
    'Signed in. Live usage returns when Claude Code renews its token.',
    'Runs Claude Code in the background with a one-line Haiku prompt when the sign-in has expired (at most every 30 minutes).',
    'One-time usage reset availability could not be verified.','One-time usage resets. Redeem on the Grok Usage page.','Reset availability needs refreshing after expiry.',
    'One-time usage resets you can redeem on the Codex usage page.','Sign in to your AIs',
    '4h 05m left','2d 3h left','4m left','resetting now',
    'Claude Code cloud sessions: $12.50 of $20 left. Expires 2026-10-21 10:00.',
    '12.50 credits left of a 20 top-up (63% left).',
    'One-time usage resets. Redeem on the Grok Usage page. Earliest expires 2026-10-21 10:00.')
# Collect literal menu labels and account Text/Tip fields from the real AST.
foreach ($cmd in $ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'New-StripItem'},$true)) {
    if ($cmd.CommandElements.Count -gt 1 -and $cmd.CommandElements[1] -is [Management.Automation.Language.StringConstantExpressionAst]) { $texts += $cmd.CommandElements[1].Value }
}
$account = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-AccountState'},$true)
foreach ($h in $account.FindAll({param($n) $n -is [Management.Automation.Language.HashtableAst]},$true)) {
    foreach ($kv in $h.KeyValuePairs) { if ($kv.Item1.Value -in @('Text','Tip')) { $texts += $kv.Item2.PipelineElements[0].Expression.Value } }
}
foreach ($style in $script:ProviderPillStyles.Values) { $texts += $style.Text }
$culture = [cultureinfo]::CurrentCulture
try {
    [cultureinfo]::CurrentCulture = 'fr-FR'; $texts += ('of {0:N0}' -f 2000)
    foreach ($lang in 'zh','ja','fr','ko') {
        foreach ($t in @($texts | Select-Object -Unique)) { Assert ((Convert-I18nString $t $lang) -cne $t) "$lang translation: $t" }
        Assert ((Convert-I18nString '5-hour session at 95% (~15 min to limit)' $lang) -notmatch 'min to limit|5-hour session| at ') 'entire alert body translated'
        Assert ((Convert-I18nString 'One-time usage resets. Redeem on the Grok Usage page. Earliest expires 2026-10-21 10:00.' $lang) -notmatch 'Earliest expires|Redeem on') 'entire expiry tooltip translated'
        $el = [pscustomobject]@{ ToolTip = 'Drag to move' }
        Invoke-I18nToolTip $el $lang
        Assert ($el.ToolTip -cne 'Drag to move') 'WPF tooltip translated without WPF'
        Invoke-I18nToolTip $el 'en'; Assert ($el.ToolTip -ceq 'Drag to move') 'tooltip source restored'
        $el.ToolTip = 'Click to sign in'; Invoke-I18nToolTip $el $lang
        Assert ($el.ToolTip -ceq (Convert-I18nString 'Click to sign in' $lang)) 'updated tooltip source respected'
    }
    # UI wiring is checked without creating any WinForms or WPF object.
    $ui = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-UiTranslate'},$true).Extent.Text
    Assert ($ui -match 'Invoke-I18nToolTip') 'logical tree includes tooltip translation'
    Assert ((Get-Command Invoke-MenuTranslate).Definition -match 'Invoke-I18nToolTip.+ToolTipText') 'menu tooltip translation wired'
    foreach ($name in 'Check-Alert','Invoke-TestAlert') {
        $fn = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        Assert ($fn.Extent.Text -match 'Convert-I18nString') 'balloons localized before display'
    }
} finally { [cultureinfo]::CurrentCulture = $culture }
Write-Output "$script:count tests passed"
