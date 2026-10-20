$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:count = 0
function Assert($Value, [string]$Name) {
    if (-not $Value) { throw "FAILED: $Name" }
    $script:count++; Write-Output "PASS: $Name"
}
function Import-TestFunction([string]$File, [string]$Name) {
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $File), [ref]$null, [ref]$null)
    $fn = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name}, $true)
    if (-not $fn) { throw "Missing function: $Name" }
    . ([scriptblock]::Create(($fn.Extent.Text -replace ('^function\s+' + [regex]::Escape($Name) + '\b'), ('function script:' + $Name))))
}
$fixture = Join-Path $PSScriptRoot ('.developer-features-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $fixture)
try {
    $script:Cfg = @{}
    $script:window = $null
    $script:StatePath = Join-Path $fixture 'state.json'
    function Write-Log { }
    . (Join-Path $root 'src/UnifiedState.ps1')
    Assert (-not (Test-DeveloperFeaturesEnabled)) 'new installation defaults developer features off'
    Assert (((Get-AvailableProviderKeys) -join ',') -eq 'claude,codex') 'ordinary accounts expose only Claude and Codex'
    $script:Cfg.DeveloperFeatures = 'false'
    Assert (-not (Test-DeveloperFeaturesEnabled)) 'malformed string cannot accidentally enable beta providers'
    $script:Cfg.DeveloperFeatures = $true
    Assert (((Get-AvailableProviderKeys) -join ',') -eq 'claude,codex,cursor,grok') 'opt-in enables both beta accounts'
    Save-UnifiedState
    $script:Cfg.DeveloperFeatures = $false
    Load-UnifiedState
    Assert (Test-DeveloperFeaturesEnabled) 'developer preference survives save and reload'
    $script:Cfg.DeveloperFeatures = $false
    Save-UnifiedState
    $script:Cfg = @{}
    Load-UnifiedState
    Assert (-not (Test-DeveloperFeaturesEnabled)) 'disabled preference survives save and reload'

    foreach ($n in @('Get-SectionVisible','Get-EnabledProviderKeys','Sync-SectionMenuItems')) { Import-TestFunction 'src/UnifiedTray.ps1' $n }
    $script:Cfg.Sections = @{claude=$true;codex=$true;cursor=$true;grok=$true}
    $script:ProviderMeta = [ordered]@{claude=@{};codex=@{};cursor=@{};grok=@{}}
    $script:sectionItems = @{}
    foreach ($key in $script:ProviderMeta.Keys) { $script:sectionItems[$key] = [pscustomobject]@{Checked=$false;Visible=$true} }
    Sync-SectionMenuItems
    Assert (-not $script:sectionItems.cursor.Visible -and -not $script:sectionItems.grok.Visible) 'provider menu hides experimental entries while off'
    Assert (((Get-EnabledProviderKeys) -join ',') -eq 'claude,codex') 'notch and accordion exclude beta providers despite saved on flags'
    Assert ($script:Cfg.Sections.cursor -and $script:Cfg.Sections.grok) 'turning feature off preserves per-provider preferences'
    $script:Cfg.DeveloperFeatures = $true
    Sync-SectionMenuItems
    Assert ($script:sectionItems.cursor.Visible -and $script:sectionItems.grok.Visible) 'provider menu immediately restores entries on opt-in'
    Assert (((Get-EnabledProviderKeys) -join ',') -eq 'claude,codex,cursor,grok') 'opt-in providers are usable by the notch'
    $script:Cfg.Sections.cursor = $false
    Assert (-not (Get-SectionVisible 'cursor') -and (Test-ProviderAvailable 'cursor')) 'provider visibility remains independent of availability'

    Import-TestFunction 'unified-overlay.ps1' 'Start-AllRefreshJobs'
    function Start-OverlayBackgroundJob { param($ScriptBlock,$ArgumentList) $script:started += ,$ArgumentList; return [pscustomobject]@{State='Completed';Id=123} }
    $script:ClaudeUsageScript={}; $script:ClaudeStatsScript={}; $script:CodexStatsScript={}; $script:GrokUsageScript={}
    $script:AppDir=$fixture; $script:CredPath='fixture-only'; $script:ErrLog='fixture-only'
    $script:Cfg.DeveloperFeatures=$false
    $script:pollJobs=@{}; $script:pollJobStartedAt=@{}; $script:started=@()
    Start-AllRefreshJobs
    Assert (-not $script:pollJobs.ContainsKey('GrokUsage')) 'ordinary mode starts no Grok network job'
    Assert (-not [bool]$script:started[0][5]) 'ordinary mode passes IncludeCursor=false to shared worker'
    $script:Cfg.DeveloperFeatures=$true
    $script:pollJobs=@{}; $script:pollJobStartedAt=@{}; $script:started=@()
    Start-AllRefreshJobs
    Assert ($script:pollJobs.ContainsKey('GrokUsage')) 'developer mode starts Grok usage job'
    Assert ([bool]$script:started[0][5]) 'developer mode enables Cursor usage in shared worker'

    $tray = [IO.File]::ReadAllText((Join-Path $root 'src/UnifiedTray.ps1'))
    $ast = [Management.Automation.Language.Parser]::ParseInput($tray, [ref]$null, [ref]$null)
    $group = $ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$groups'}, $true)
    . ([scriptblock]::Create($group.Extent.Text))
    $panel = $groups | Where-Object { $_.Title -eq 'Panels & Features' }
    $labels = @($panel.Items | ForEach-Object { $_[0] })
    Assert ($labels -contains 'Show remaining (not used)') 'remaining toggle belongs to Panels and Features, not root fallback'
    Assert ($labels -contains 'Developer features (Cursor / Grok beta)') 'developer toggle belongs to Panels and Features'
    $accounts = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-AccountsMenu'}, $true).Extent.Text
    Assert ($accounts.Contains('Get-AvailableProviderKeys')) 'account menu uses the same availability gate'
    $picker = [IO.File]::ReadAllText((Join-Path $root 'src/ProviderPicker.ps1'))
    Assert ($picker.Contains('Test-ProviderAvailable $key')) 'first-run provider chooser does not expose beta entries'
    Assert ($picker.Contains("`$out['codex'] = `$true")) 'empty ordinary selection falls back to stable Codex, not hidden Cursor'
    $entry = [IO.File]::ReadAllText((Join-Path $root 'unified-overlay.ps1'))
    Assert ($entry -match 'if \(\$IncludeCursor\)\s*\{\s*Get-CursorUsage') 'Cursor collection is guarded inside the worker'
    $script:Cfg.DeveloperFeatures=$false
    $script:sectionVisibility=@{}
    function Set-SectionVisible($Key,$Visible) { $script:sectionVisibility[$Key]=$Visible }
    function Apply-UnifiedTheme { }
    Apply-UnifiedSettings
    Assert (-not $script:sectionVisibility.cursor -and -not $script:sectionVisibility.grok) 'applying default settings collapses experimental panel wrappers'
    Assert ($script:sectionVisibility.claude -and $script:sectionVisibility.codex) 'stable panel wrappers remain available'
    Import-TestFunction 'src/UnifiedTray.ps1' 'Sync-ProviderLoginMenuItems'
    $script:loginItems=@{}
    foreach($key in @('claude','codex','grok')) { $script:loginItems[$key]=[pscustomobject]@{Visible=$true;Text='';Enabled=$true} }
    $script:resolved=@()
    function Resolve-ProviderLoginCli($Key) { $script:resolved+=$Key; return $null }
    function Get-ProviderLoginMenuCaption { param($CliName,$Resolved) return $CliName }
    Sync-ProviderLoginMenuItems
    Assert (-not $script:loginItems.grok.Visible -and $script:resolved -notcontains 'grok') 'ordinary login menu neither exposes nor resolves Grok CLI'
    Import-TestFunction 'src/UnifiedTray.ps1' 'Set-DeveloperFeatures'
    $script:saved=0; $script:applied=0; $script:refreshed=0
    function Save-UnifiedState { $script:saved++ }
    function Apply-UnifiedSettings { $script:applied++ }
    function Sync-ProviderLoginMenuItems { }
    function Sync-MenuToggleStates { }
    function Update-AllSections { }
    function Resize-ToContent { }
    function Start-AllRefreshJobs { param($Kind,[switch]$Force) $script:refreshed++ }
    Set-DeveloperFeatures $false
    Assert (-not (Test-DeveloperFeaturesEnabled) -and $script:saved -eq 1 -and $script:applied -eq 1) 'real toggle-off action persists and reapplies settings'
    Assert ($script:refreshed -eq 0) 'toggle-off action does not start experimental refresh'
    Set-DeveloperFeatures $true
    Assert ((Test-DeveloperFeaturesEnabled) -and $script:saved -eq 2 -and $script:applied -eq 2) 'real toggle-on action persists and reapplies settings'
    Assert ($script:refreshed -eq 1) 'toggle-on action immediately refreshes beta data'
    Write-Output "$script:count tests passed"
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if (-not $resolved.StartsWith(([IO.Path]::GetFullPath($PSScriptRoot) + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
