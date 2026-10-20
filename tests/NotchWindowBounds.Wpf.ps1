param([string]$Root = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'src\UnifiedTray.ps1'),[ref]$null,[ref]$null)
# No tray, user configuration, or credentials are loaded.
foreach($s in $ast.EndBlock.Statements) {
 if($s -is [Management.Automation.Language.FunctionDefinitionAst]){break}
 if($s -is [Management.Automation.Language.AssignmentStatementAst]) { . ([scriptblock]::Create($s.Extent.Text)) }
}
foreach($name in @('Initialize-NotchNative','Initialize-NotchFastPath','Get-NotchGeometry','Get-NotchEase','Get-NotchPreset','Invoke-NotchApply','Start-NotchMotion','Start-NotchRendering','Stop-NotchRendering','Invoke-NotchFrame','Sync-NotchWindowHeight','Set-NotchRest')) {
 $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 . ([scriptblock]::Create($fn.Extent.Text))
}
function Test-NotchShell {$true}
function Sync-NotchCursor {}
function Sync-IslandMenuItem {}
function Test-NotchPinned {$false}
function Write-NotchLog($s) {throw $s}
Initialize-NotchNative
Initialize-NotchFastPath
$script:window=[Windows.Markup.XamlReader]::Parse(@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="JayOS bounds regression fixture" WindowStyle="None" AllowsTransparency="True" Background="Transparent" ShowInTaskbar="False" ResizeMode="NoResize" Width="560" Height="352" Left="100" Top="100"><Grid><Border Background="Black"/></Grid></Window>
'@)
$script:NotchContentRoot=$script:window.Content
$script:NotchBackdrop=$script:NotchContentRoot.Children[0]
$script:IslandRoot=New-Object Windows.Controls.Grid
$script:NotchContentRoot.Children.Add($script:IslandRoot) | Out-Null
$script:NotchStage.CX=280; $script:NotchStage.PanelH=340
$script:NotchParts=@{}
function Pump([int]$ms) {
 $frame=New-Object Windows.Threading.DispatcherFrame
 $timer=New-Object Windows.Threading.DispatcherTimer
 $timer.Interval=[TimeSpan]::FromMilliseconds($ms)
 $timer.Tag=$frame
 $timer.add_Tick({param($s,$e) $s.Stop(); $s.Tag.Continue=$false})
 $timer.Start(); [Windows.Threading.Dispatcher]::PushFrame($frame)
}
function Check-Height([double]$expected,[string]$label) {
 $hwnd=[Windows.Interop.WindowInteropHelper]::new($script:window).Handle
 $r=[AIUsageNotchNative]::CursorAndWindow($hwnd)
 $dpi=[Windows.PresentationSource]::FromVisual($script:window).CompositionTarget.TransformToDevice.M22
 if([math]::Abs($script:window.ActualHeight-$expected) -gt (1.0/$dpi) -or [math]::Abs($r[5]-$expected*$dpi) -gt 1) {throw "$label mismatch: WPF=$($script:window.ActualHeight) native=$($r[5]) expected=$expected DPI=$dpi"}
 Write-Output "$label WPF=$($script:window.ActualHeight) native=$($r[5]) dpi=$dpi"
}
try {
 $script:window.Show(); Set-NotchRest; Pump 100; Check-Height 5 'EDGE startup'
 for($i=0;$i -lt 6;$i++) {
  $script:NotchState='NOTCH'
  Start-NotchMotion -DurationMs 100 -Tracks @{h=@(32);w=@(280)}
  Pump 15
  Check-Height 352 'motion reserved'
  Pump 200; Check-Height 32 'NOTCH settled'
  $script:NotchState='EXPANDING'
  Start-NotchMotion -DurationMs 100 -Tracks @{h=@(340);w=@(520)} -OnComplete {$script:NotchState='EXPANDED'}
  Pump 200; Check-Height 340 'PANEL settled'
  $script:NotchState='EDGE_RETURN'
  Start-NotchMotion -DurationMs 100 -Tracks @{h=@(5);w=@(132)} -OnComplete {$script:NotchState='EDGE'}
  Pump 200; Check-Height 5 'EDGE settled'
 }
 Write-Output 'PASS native HWND bounds and 18 composed transitions'
} finally {Stop-NotchRendering; $script:window.Close()}
