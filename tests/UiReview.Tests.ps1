param([int]$Finding = 0)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:count = 0
$script:failures = @()
function Assert($Value, $Name) { if (-not $Value) { throw "FAILED: $Name" }; $script:count++ }
function Import-Part($File, $Names) {
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $File), [ref]$null, [ref]$null)
    foreach ($name in $Names) {
        $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        if (-not $fn) { throw "Missing function: $name" }
        . ([scriptblock]::Create($fn.Extent.Text))
    }
}
function Check($Number, [scriptblock]$Body) {
    if ($Finding -and $Finding -ne $Number) { return }
    try { & $Body; Write-Output "PASS finding $Number" } catch { $script:failures += "Finding ${Number}: $_ $($_.ScriptStackTrace)"; Write-Output $script:failures[-1] }
}
$fixture = Join-Path $PSScriptRoot ('ui-review-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $fixture)
function Write-Log { }
try {
Check 1 {
    . Import-Part 'src/Config.ps1' @('ConvertTo-DateTimeOffset')
    . Import-Part 'src/Shell.ps1' @('Format-PanelReset','Set-Spark','Update-AllSections')
    $culture = [cultureinfo]::CurrentCulture
    try {
        foreach ($lang in 'fr-FR','de-DE','en-GB','zh-CN') {
            [cultureinfo]::CurrentCulture = $lang
            foreach ($suffix in 'Z','+00:00') {
                $iso = [datetime]::UtcNow.AddHours(4).AddMinutes(5).ToString('yyyy-MM-ddTHH:mm:ss') + $suffix
                $j = ('{"t":"' + $iso + '"}') | ConvertFrom-Json
                Assert ((Format-PanelReset $j.t) -eq (Format-PanelReset $iso)) "typed dates $lang $suffix"
                Assert ((Format-PanelReset $j.t) -match '^4h 0[45]m left$') 'countdown is not empty'
            }
        }
        # Stub only WPF's point/visibility types; no UI is created.
        if (-not ('System.Windows.Point' -as [type])) { Add-Type 'namespace System.Windows { public struct Point { public double X,Y; public Point(double x,double y){X=x;Y=y;} } public enum Visibility { Visible, Collapsed } }' }
        $script:spark = [pscustomobject]@{ Points = [Collections.Generic.List[object]]::new() }
        $script:canvas = [pscustomobject]@{ Width = 100; Height = 30 }
        $script:row = [pscustomobject]@{ Visibility = 'Visible' }
        $script:window = [pscustomobject]@{}
        $script:window | Add-Member ScriptMethod FindName { param($n) switch ($n) { 'spark' { $script:spark }; 'canvas' { $script:canvas }; 'row' { $script:row } } }
        $script:Cfg = @{ ShowGraph = $true }
        $script:History = '[{"t":"bad","v":10},{"t":"2026-10-20T10:00:00Z","v":20},{"t":"2026-10-20T11:00:00Z","v":40},{"t":"bad","v":90}]' | ConvertFrom-Json
        Set-Spark 'spark' 'canvas' 'v' 'row'
        Assert ($script:spark.Points.Count -eq 2) 'bad samples skipped; typed dates rendered'
        Assert ($script:spark.Points[1].X -eq 100) 'sparkline time range'
        $source = (Get-Command Update-AllSections).Definition
        Assert ($source -match 'try\s*\{\s*Update-ClaudeSection' -and $source -match 'try\s*\{\s*Update-CodexSection') 'section errors isolated'
        function Get-WorstProviderStatus { @{ Status = 'ok' } }
        function Set-SectionStatusDots { }
        $script:updated = @(); $script:notify = $null
        function Update-ClaudeSection { $script:updated += 'claude'; throw 'bad Claude sample' }
        function Update-CodexSection { $script:updated += 'codex'; throw 'bad Codex sample' }
        function Update-CursorSection { $script:updated += 'cursor' }
        function Update-GrokSection { $script:updated += 'grok' }
        Update-AllSections
        Assert (($script:updated -join ',') -eq 'claude,codex,cursor,grok') 'actual refresh continues after provider failures'
    } finally { [cultureinfo]::CurrentCulture = $culture }
}
Check 2 {
    . Import-Part 'Setup.ps1' @('Resolve-UninstallDir','Invoke-Uninstall')
    $dl = Join-Path $fixture 'download'; $inst = Join-Path $fixture 'installed'
    foreach ($p in $dl,$inst) { [void](New-Item -ItemType Directory $p); [IO.File]::WriteAllText((Join-Path $p 'unified-overlay.ps1'), '# fixture') }
    Assert ((Resolve-UninstallDir $dl $inst) -eq $inst) 'registered installation wins'
    Assert ((Resolve-UninstallDir $dl '') -eq $dl) 'standalone marker fallback'
    $thrown = $false; try { Resolve-UninstallDir $fixture '' } catch { $thrown = $true }
    Assert $thrown 'refuse unmarked directory'
    $script:AppDir = $inst
    . (Join-Path $root 'src/Requests.ps1')
    $settings = Join-Path $fixture 'agent-settings.json'
    [IO.File]::WriteAllText($settings, '{}')
    [void](Set-AgentRequestHooks $settings 'claude' $true)
    $script:AppDir = Resolve-UninstallDir $dl $inst
    [void](Set-AgentRequestHooks $settings 'claude' $false)
    Assert (-not ([IO.File]::ReadAllText($settings).Contains('ClaudeHook.ps1'))) 'installed hook removed from fixture'
    Assert ((Get-Command Invoke-Uninstall).Definition -match 'Resolve-UninstallDir') 'uninstaller uses resolver'
}
Check 3 {
    . (Join-Path $root 'src/UnifiedState.ps1')
    $script:window = $null; $script:Themes = $null; $script:StatePath = Join-Path $fixture 'state.json'
    [IO.File]::WriteAllText($script:StatePath, '{"Language":"en"}')
    [IO.File]::WriteAllText(($script:StatePath + '.bak'), '{"Language":"zh"}')
    [IO.File]::WriteAllText($script:StatePath, '')
    $script:Cfg = @{}; Load-UnifiedState
    Assert ($script:Cfg.Language -eq 'zh') 'empty primary recovers backup'
    [IO.File]::WriteAllText($script:StatePath, '{bad')
    $script:Cfg = @{}; Load-UnifiedState
    Assert ($script:Cfg.Language -eq 'zh') 'truncated primary recovers backup'
    $script:Cfg.Language = 'ja'; Save-UnifiedState
    Assert (([IO.File]::ReadAllText($script:StatePath) | ConvertFrom-Json).Language -eq 'ja') 'atomic save writes state'
    Assert (@(Get-ChildItem $fixture -Filter '*.tmp').Count -eq 0) 'no temporary files remain'
    Assert (([IO.File]::ReadAllText(($script:StatePath + '.bak')) | ConvertFrom-Json).Language -eq 'zh') 'recovery save preserves last good backup'
    $script:Cfg.Language = 'fr'; Save-UnifiedState
    Assert (([IO.File]::ReadAllText(($script:StatePath + '.bak')) | ConvertFrom-Json).Language -eq 'ja') 'normal save backs up previous primary'
    $old = [IO.File]::ReadAllText($script:StatePath)
    function Set-Content { param($LiteralPath,$Value,$Encoding,$ErrorAction) [IO.File]::WriteAllText($LiteralPath, '{partial'); throw 'simulated interrupted write' }
    try { $script:Cfg.Language = 'ko'; Save-UnifiedState } finally { Remove-Item Function:\Set-Content }
    Assert ([IO.File]::ReadAllText($script:StatePath) -eq $old) 'failed temporary write preserves primary'
    Assert (@(Get-ChildItem $fixture -Filter '*.tmp').Count -eq 0) 'failed save cleans temporary file'
    . Import-Part 'Setup.ps1' @('Save-LanguageSetting')
    $script:Lang = 'fr'; $Silent = $false
    Save-LanguageSetting $fixture
    Assert (([IO.File]::ReadAllText((Join-Path $fixture 'unified-overlay-state.json')) | ConvertFrom-Json).Language -eq 'fr') 'setup saves language atomically'
    $script:Lang = 'ko'
    function Set-Content { param($LiteralPath,$Value,$Encoding,$ErrorAction) [IO.File]::WriteAllText($LiteralPath, '{partial'); throw 'simulated setup write failure' }
    $thrown = $false
    try { Save-LanguageSetting $fixture } catch { $thrown = $true } finally { Remove-Item Function:\Set-Content }
    Assert $thrown 'setup reports failed save'
    Assert (([IO.File]::ReadAllText((Join-Path $fixture 'unified-overlay-state.json')) | ConvertFrom-Json).Language -eq 'fr') 'setup failure preserves language'
    Assert (@(Get-ChildItem $fixture -Filter '*.tmp').Count -eq 0) 'setup failure leaves no temporary files'
}
Check 5 {
    . Import-Part 'src/UnifiedTray.ps1' @('Test-NotchHolding','Invoke-NotchHoverPoll')
    Assert (-not (Test-NotchHolding $false $true $false $false)) 'release outside does not hold notch'
    Assert (Test-NotchHolding $false $true $true $false) 'actual pressed button holds'
    Assert (Test-NotchHolding $true $false $false $false) 'hover holds'
    Assert (Test-NotchHolding $false $false $false $true) 'pin holds'
    Assert ((Get-Command Invoke-NotchHoverPoll).Definition -match 'Test-NotchHolding') 'hover poll uses physical button state'
}
Check 6 {
    . Import-Part 'src/UnifiedTray.ps1' @('Sync-MenuToggleStates')
    function Sync-SectionMenuItems {}; function Sync-IslandMenuItem {}
    $script:Cfg = @{ Opacity = 0.6; DropdownHideOnFocusLoss = $true }
    $script:MenuToggleItems = @{}; $script:MenuToggleKeys = @{}
    $script:miHideFocus = [pscustomobject]@{ Checked = $false }
    $script:opacityItems = @{}
    foreach ($k in '60%','80%','100%') { $script:opacityItems[$k] = [pscustomobject]@{ Checked = $false } }
    Sync-MenuToggleStates
    Assert ($script:opacityItems['60%'].Checked -and -not $script:opacityItems['100%'].Checked -and -not $script:opacityItems['80%'].Checked) 'saved opacity synchronized'
    Assert $script:miHideFocus.Checked 'saved focus-loss setting synchronized'
    $script:Cfg.Opacity = 1; $script:Cfg.DropdownHideOnFocusLoss = $false; Sync-MenuToggleStates
    Assert ($script:opacityItems['100%'].Checked -and -not $script:opacityItems['60%'].Checked -and -not $script:miHideFocus.Checked) 'later changes synchronized'
}
Check 7 {
    . Import-Part 'Setup.ps1' @('Resolve-InstallTarget')
    $tools = Join-Path $fixture 'Tools'; [void](New-Item -ItemType Directory $tools)
    Assert ((Resolve-InstallTarget $tools) -eq (Join-Path $tools 'JayOS AI Usage')) 'empty user folder gets app subfolder'
    [IO.File]::WriteAllText((Join-Path $tools 'unified-overlay.ps1'), '# fixture')
    Assert ((Resolve-InstallTarget $tools) -eq $tools) 'existing install stays in place'
    $named = Join-Path $fixture 'JayOS AI Usage'
    Assert ((Resolve-InstallTarget $named) -eq $named) 'dedicated app directory not nested'
}
Check 8 {
    . Import-Part 'src/UnifiedTray.ps1' @('Get-CpPickerPosition')
    foreach ($area in @(@{Left=-1920;Top=0;Right=0;Bottom=1080}, @{Left=0;Top=-1200;Right=1920;Bottom=0}, @{Left=1800;Top=400;Right=3000;Bottom=1400})) {
        $pos = Get-CpPickerPosition $area @{Left=$area.Left+20;Top=$area.Top+950;Width=400} @{Width=332;Height=560}
        Assert ($pos.Left -ge $area.Left -and $pos.Left+332 -le $area.Right -and $pos.Top -ge $area.Top -and $pos.Top+560 -le $area.Bottom) 'picker clamped to panel monitor'
    }
    $small = Get-CpPickerPosition @{Left=-800;Top=-400;Right=-500;Bottom=0} @{Left=-800;Top=-200;Width=100} @{Width=332;Height=560}
    Assert ($small.Width -eq 300 -and $small.Height -eq 400 -and $small.Left -eq -800 -and $small.Top -eq -400) 'small work area constrains dialog size'
    $text = [IO.File]::ReadAllText((Join-Path $root 'src/UnifiedTray.ps1'))
    Assert ($text -match '\$area = Get-WorkArea') 'picker uses DPI-aware panel monitor'
}
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if (-not $resolved.StartsWith(([IO.Path]::GetFullPath($PSScriptRoot) + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
if ($script:failures.Count) { $script:failures | Write-Output; exit 1 }
Write-Output "$script:count tests passed"
