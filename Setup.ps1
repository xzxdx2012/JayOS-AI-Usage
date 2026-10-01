<#
    JayOS AI Usage - setup wizard (install / uninstall).

      Setup.vbs              install (wizard)
      Setup.vbs /uninstall   remove from this computer
      Setup.ps1 -Silent      install with the default options, no window
                             (used by the app's "Check for updates"; add
                             -InstallDir to update a given folder in place)
#>
param(
    [switch]$Uninstall,
    [switch]$Silent,
    [string]$InstallDir
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$AppName      = 'JayOS AI Usage'
$AppVersion   = '0.0.2 beta'
$Publisher    = 'JayOS'
$RegKey       = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\JayOS.AIUsage'
$SourceDir    = $PSScriptRoot
$DefaultDir   = Join-Path $env:LOCALAPPDATA 'JayOS AI Usage'
# Updating: reuse the folder of an existing install so its settings carry over.
try {
    $prev = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\JayOS.AIUsage' -ErrorAction Stop).InstallLocation
    if ($prev -and (Test-Path -LiteralPath (Join-Path $prev 'unified-overlay.ps1'))) { $DefaultDir = $prev }
} catch {
    $legacy = Join-Path $env:LOCALAPPDATA 'AIUsageOverlay'
    if (Test-Path -LiteralPath (Join-Path $legacy 'unified-overlay.ps1')) { $DefaultDir = $legacy }
}
# Only one wizard at a time: close any earlier one that is still open.
try {
    Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*Setup.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch { }
$StartupLnk   = Join-Path ([Environment]::GetFolderPath('Startup')) 'AIUsageOverlay.lnk'
$StartMenuLnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'JayOS AI Usage.lnk'
$DesktopLnk   = Join-Path ([Environment]::GetFolderPath('Desktop')) 'JayOS AI Usage.lnk'

# ---------------------------------------------------------------------------
# Text
# ---------------------------------------------------------------------------
$Languages = [ordered]@{ en = 'English'; zh = '中文'; fr = 'Français'; ja = '日本語'; ko = '한국어' }
$T = @{
    en = @{
        WelcomeTitle = 'Welcome'
        WelcomeBody  = 'This will install JayOS AI Usage — a notch at the top of your screen that shows how much of your Claude, Codex, Cursor and Grok limits you have used.'
        Language     = 'Language'
        OptionsTitle = 'Install options'
        Location     = 'Install location'
        Browse       = 'Browse…'
        Autostart    = 'Start when Windows starts'
        Desktop      = 'Create a desktop shortcut'
        Installing   = 'Installing…'
        StepStop     = 'Closing the running copy…'
        StepCopy     = 'Copying files…'
        StepShort    = 'Creating shortcuts…'
        StepRuntime  = 'Downloading PowerShell 7… {0}'
        StepSettings = 'Saving settings…'
        DoneTitle    = 'All set'
        DoneBody     = 'JayOS AI Usage is installed. Move the mouse to the top centre of the screen to see the notch; click it for the full panel.'
        LaunchNow    = 'Open JayOS AI Usage now'
        Back = 'Back'; Next = 'Next'; Install = 'Install'; Finish = 'Finish'; Cancel = 'Cancel'; Close = 'Close'
        FailTitle    = 'Installation failed'
        UninstTitle  = 'Remove JayOS AI Usage'
        UninstBody   = 'This removes JayOS AI Usage, its shortcuts and its settings from this computer.'
        Remove       = 'Remove'
        RemovedBody  = 'JayOS AI Usage has been removed.'
        PickFolder   = 'Choose where to install JayOS AI Usage'
    }
    zh = @{
        WelcomeTitle = '欢迎'
        WelcomeBody  = '将安装 JayOS AI Usage —— 屏幕顶部的一个“刘海”，显示你的 Claude、Codex、Cursor 和 Grok 额度已经用了多少。'
        Language     = '语言'
        OptionsTitle = '安装选项'
        Location     = '安装位置'
        Browse       = '浏览…'
        Autostart    = '开机时自动启动'
        Desktop      = '创建桌面快捷方式'
        Installing   = '正在安装…'
        StepStop     = '正在关闭正在运行的程序…'
        StepCopy     = '正在复制文件…'
        StepShort    = '正在创建快捷方式…'
        StepRuntime  = '正在下载 PowerShell 7… {0}'
        StepSettings = '正在保存设置…'
        DoneTitle    = '安装完成'
        DoneBody     = 'JayOS AI Usage 已安装。把鼠标移到屏幕顶部中间就会出现刘海，点击可以展开完整面板。'
        LaunchNow    = '现在打开 JayOS AI Usage'
        Back = '上一步'; Next = '下一步'; Install = '安装'; Finish = '完成'; Cancel = '取消'; Close = '关闭'
        FailTitle    = '安装失败'
        UninstTitle  = '卸载 JayOS AI Usage'
        UninstBody   = '这会从这台电脑上删除 JayOS AI Usage、它的快捷方式和设置。'
        Remove       = '卸载'
        RemovedBody  = 'JayOS AI Usage 已卸载。'
        PickFolder   = '选择 JayOS AI Usage 的安装位置'
    }
    fr = @{
        WelcomeTitle = 'Bienvenue'
        WelcomeBody  = "Vous allez installer JayOS AI Usage : une encoche en haut de l'écran qui indique la part de vos limites Claude, Codex, Cursor et Grok déjà utilisée."
        Language     = 'Langue'
        OptionsTitle = "Options d'installation"
        Location     = "Dossier d'installation"
        Browse       = 'Parcourir…'
        Autostart    = 'Lancer au démarrage de Windows'
        Desktop      = 'Créer un raccourci sur le bureau'
        Installing   = 'Installation…'
        StepStop     = "Fermeture de l'instance en cours…"
        StepCopy     = 'Copie des fichiers…'
        StepShort    = 'Création des raccourcis…'
        StepRuntime  = 'Téléchargement de PowerShell 7… {0}'
        StepSettings = 'Enregistrement des réglages…'
        DoneTitle    = 'Terminé'
        DoneBody     = "JayOS AI Usage est installé. Placez la souris en haut au centre de l'écran pour voir l'encoche ; cliquez dessus pour ouvrir le panneau."
        LaunchNow    = 'Ouvrir JayOS AI Usage maintenant'
        Back = 'Retour'; Next = 'Suivant'; Install = 'Installer'; Finish = 'Terminer'; Cancel = 'Annuler'; Close = 'Fermer'
        FailTitle    = "Échec de l'installation"
        UninstTitle  = 'Désinstaller JayOS AI Usage'
        UninstBody   = 'JayOS AI Usage, ses raccourcis et ses réglages seront supprimés de cet ordinateur.'
        Remove       = 'Désinstaller'
        RemovedBody  = 'JayOS AI Usage a été désinstallé.'
        PickFolder   = "Choisissez le dossier d'installation de JayOS AI Usage"
    }
    ja = @{
        WelcomeTitle = 'ようこそ'
        WelcomeBody  = 'JayOS AI Usage をインストールします。画面上部のノッチに、Claude・Codex・Cursor・Grok の使用量が表示されます。'
        Language     = '言語'
        OptionsTitle = 'インストールオプション'
        Location     = 'インストール先'
        Browse       = '参照…'
        Autostart    = 'Windows の起動時に開始'
        Desktop      = 'デスクトップにショートカットを作成'
        Installing   = 'インストール中…'
        StepStop     = '実行中のアプリを終了しています…'
        StepCopy     = 'ファイルをコピーしています…'
        StepShort    = 'ショートカットを作成しています…'
        StepRuntime  = 'PowerShell 7 をダウンロードしています… {0}'
        StepSettings = '設定を保存しています…'
        DoneTitle    = '完了'
        DoneBody     = 'JayOS AI Usage をインストールしました。マウスを画面上部の中央に移動するとノッチが表示され、クリックするとパネルが開きます。'
        LaunchNow    = '今すぐ JayOS AI Usage を開く'
        Back = '戻る'; Next = '次へ'; Install = 'インストール'; Finish = '完了'; Cancel = 'キャンセル'; Close = '閉じる'
        FailTitle    = 'インストールに失敗しました'
        UninstTitle  = 'JayOS AI Usage のアンインストール'
        UninstBody   = 'JayOS AI Usage とショートカット、設定をこのコンピューターから削除します。'
        Remove       = 'アンインストール'
        RemovedBody  = 'JayOS AI Usage を削除しました。'
        PickFolder   = 'JayOS AI Usage のインストール先を選択'
    }
    ko = @{
        WelcomeTitle = '환영합니다'
        WelcomeBody  = 'JayOS AI Usage를 설치합니다. 화면 상단의 노치에 Claude, Codex, Cursor, Grok 한도를 얼마나 사용했는지 표시됩니다.'
        Language     = '언어'
        OptionsTitle = '설치 옵션'
        Location     = '설치 위치'
        Browse       = '찾아보기…'
        Autostart    = 'Windows 시작 시 실행'
        Desktop      = '바탕 화면 바로 가기 만들기'
        Installing   = '설치 중…'
        StepStop     = '실행 중인 앱을 닫는 중…'
        StepCopy     = '파일을 복사하는 중…'
        StepShort    = '바로 가기를 만드는 중…'
        StepRuntime  = 'PowerShell 7 다운로드 중… {0}'
        StepSettings = '설정을 저장하는 중…'
        DoneTitle    = '설치 완료'
        DoneBody     = 'JayOS AI Usage가 설치되었습니다. 마우스를 화면 상단 가운데로 옮기면 노치가 나타나고, 클릭하면 전체 패널이 열립니다.'
        LaunchNow    = '지금 JayOS AI Usage 열기'
        Back = '뒤로'; Next = '다음'; Install = '설치'; Finish = '마침'; Cancel = '취소'; Close = '닫기'
        FailTitle    = '설치하지 못했습니다'
        UninstTitle  = 'JayOS AI Usage 제거'
        UninstBody   = '이 컴퓨터에서 JayOS AI Usage와 바로 가기, 설정을 삭제합니다.'
        Remove       = '제거'
        RemovedBody  = 'JayOS AI Usage가 제거되었습니다.'
        PickFolder   = 'JayOS AI Usage 설치 위치 선택'
    }
}

$script:Lang = 'en'
function S([string]$Key) { return [string]$T[$script:Lang][$Key] }

# ---------------------------------------------------------------------------
# Window
# ---------------------------------------------------------------------------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="JayOS AI Usage Setup" Width="600" Height="440" WindowStartupLocation="CenterScreen"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        FontFamily="Segoe UI" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#F5F5F7"/>
      <Setter Property="Background" Value="#1FFFFFFF"/>
      <Setter Property="BorderBrush" Value="#26FFFFFF"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="18,7"/>
      <Setter Property="Margin" Value="8,0,0,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" CornerRadius="9" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#F5F5F7"/>
      <Setter Property="BorderBrush" Value="#F5F5F7"/>
      <Setter Property="Foreground" Value="#111113"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E5E5EA"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <ContentPresenter VerticalAlignment="Center"/>
              <Border x:Name="track" Grid.Column="1" Width="38" Height="22" CornerRadius="11" Background="#48484C">
                <Ellipse x:Name="knob" Width="18" Height="18" Fill="White" HorizontalAlignment="Left" Margin="2,0,0,0"/>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="#30D158"/>
                <Setter TargetName="knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="knob" Property="Margin" Value="0,0,2,0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border CornerRadius="16" BorderBrush="#2C2C2E" BorderThickness="1">
    <Border.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
        <GradientStop Color="#FF0B0B0C" Offset="0"/><GradientStop Color="#FF17171A" Offset="1"/>
      </LinearGradientBrush>
    </Border.Background>
    <Grid Margin="28,22,28,22">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- Header: app mark, name, close -->
      <Grid x:Name="header" Background="Transparent">
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <Border Width="40" Height="40" CornerRadius="10" Background="#161618" BorderBrush="#46464A" BorderThickness="1">
          <Canvas Width="40" Height="40">
            <Rectangle Canvas.Left="10" Canvas.Top="20" Width="5" Height="10" RadiusX="2.5" RadiusY="2.5" Fill="#F2F2F7"/>
            <Rectangle Canvas.Left="17.5" Canvas.Top="15" Width="5" Height="15" RadiusX="2.5" RadiusY="2.5" Fill="#F2F2F7"/>
            <Rectangle Canvas.Left="25" Canvas.Top="10" Width="5" Height="20" RadiusX="2.5" RadiusY="2.5" Fill="#30D158"/>
          </Canvas>
        </Border>
        <StackPanel Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center">
          <TextBlock Text="JayOS AI Usage" Foreground="#F5F5F7" FontSize="17" FontWeight="SemiBold"/>
          <TextBlock x:Name="versionText" Foreground="#8E8E93" FontSize="11.5"/>
        </StackPanel>
        <Button x:Name="closeButton" Grid.Column="2" Style="{StaticResource Btn}" Padding="10,4" Background="Transparent" BorderBrush="Transparent"
                Content="✕" Foreground="#8E8E93" VerticalAlignment="Top"/>
      </Grid>

      <!-- Pages -->
      <Grid Grid.Row="1" Margin="0,26,0,0">
        <StackPanel x:Name="pageWelcome">
          <TextBlock x:Name="welcomeTitle" Foreground="#F5F5F7" FontSize="24" FontWeight="SemiBold"/>
          <TextBlock x:Name="welcomeBody" Foreground="#A1A1A6" FontSize="13.5" TextWrapping="Wrap" LineHeight="20" Margin="0,10,0,0"/>
          <TextBlock x:Name="languageLabel" Foreground="#8E8E93" FontSize="12" Margin="0,26,0,8"/>
          <WrapPanel x:Name="languageRow"/>
        </StackPanel>

        <StackPanel x:Name="pageOptions" Visibility="Collapsed">
          <TextBlock x:Name="optionsTitle" Foreground="#F5F5F7" FontSize="24" FontWeight="SemiBold"/>
          <TextBlock x:Name="locationLabel" Foreground="#8E8E93" FontSize="12" Margin="0,18,0,8"/>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Border CornerRadius="9" Background="#14FFFFFF" BorderBrush="#26FFFFFF" BorderThickness="1" Padding="12,8">
              <TextBlock x:Name="locationText" Foreground="#E5E5EA" FontSize="13" TextTrimming="CharacterEllipsis"/>
            </Border>
            <Button x:Name="browseButton" Grid.Column="1" Style="{StaticResource Btn}"/>
          </Grid>
          <StackPanel Margin="0,24,0,0">
            <CheckBox x:Name="autostartBox" Style="{StaticResource Switch}" IsChecked="True"/>
            <CheckBox x:Name="desktopBox" Style="{StaticResource Switch}" IsChecked="True"/>
          </StackPanel>
        </StackPanel>

        <StackPanel x:Name="pageProgress" Visibility="Collapsed" VerticalAlignment="Center">
          <TextBlock x:Name="progressTitle" Foreground="#F5F5F7" FontSize="22" FontWeight="SemiBold"/>
          <Border Height="6" CornerRadius="3" Background="#26FFFFFF" Margin="0,20,0,0">
            <Border x:Name="progressFill" Height="6" CornerRadius="3" Background="#30D158" HorizontalAlignment="Left" Width="0"/>
          </Border>
          <TextBlock x:Name="progressStep" Foreground="#8E8E93" FontSize="12.5" Margin="0,10,0,0"/>
        </StackPanel>

        <StackPanel x:Name="pageDone" Visibility="Collapsed">
          <Grid Width="52" Height="52" HorizontalAlignment="Left">
            <Ellipse Fill="#30D158"/>
            <Path Data="M15,27 L23,35 L38,18" Stroke="#0B0B0C" StrokeThickness="4" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
          </Grid>
          <TextBlock x:Name="doneTitle" Foreground="#F5F5F7" FontSize="24" FontWeight="SemiBold" Margin="0,16,0,0"/>
          <TextBlock x:Name="doneBody" Foreground="#A1A1A6" FontSize="13.5" TextWrapping="Wrap" LineHeight="20" Margin="0,10,0,0"/>
          <CheckBox x:Name="launchBox" Style="{StaticResource Switch}" IsChecked="True" Margin="0,22,0,0"/>
        </StackPanel>
      </Grid>

      <!-- Footer: step dots + buttons -->
      <Grid Grid.Row="2">
        <StackPanel x:Name="dots" Orientation="Horizontal" VerticalAlignment="Center"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="backButton" Style="{StaticResource Btn}"/>
          <Button x:Name="nextButton" Style="{StaticResource Primary}"/>
        </StackPanel>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$win = [System.Windows.Markup.XamlReader]::Parse($xaml)
$ui = @{}
foreach ($n in 'header','versionText','closeButton','pageWelcome','welcomeTitle','welcomeBody','languageLabel','languageRow',
               'pageOptions','optionsTitle','locationLabel','locationText','browseButton','autostartBox','desktopBox',
               'pageProgress','progressTitle','progressFill','progressStep','pageDone','doneTitle','doneBody','launchBox',
               'dots','backButton','nextButton') {
    $ui[$n] = $win.FindName($n)
}
$ui.versionText.Text = $AppVersion
$win.Add_ContentRendered({ try { [void]$win.Activate(); $win.Topmost = $true; $win.Topmost = $false } catch { } })
$ui.header.Add_MouseLeftButtonDown({ try { $win.DragMove() } catch { } })

function Brush([string]$Hex) { return [System.Windows.Media.BrushConverter]::new().ConvertFromString($Hex) }

function Pump {
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [Action]({ $frame.Continue = $false }.GetNewClosure()))
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

# ---------------------------------------------------------------------------
# Install / uninstall work
# ---------------------------------------------------------------------------
function Stop-RunningOverlay {
    Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*unified-overlay.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function New-Shortcut([string]$Path, [string]$TargetDir) {
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($Path)
    $sc.TargetPath       = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $sc.Arguments        = '"' + (Join-Path $TargetDir 'Start-Unified.vbs') + '"'
    $sc.WorkingDirectory = $TargetDir
    $sc.IconLocation     = (Join-Path $TargetDir 'assets\ai-usage-overlay.ico') + ',0'
    $sc.Description      = $AppName
    $sc.Save()
}

function Save-LanguageSetting([string]$TargetDir) {
    $path = Join-Path $TargetDir 'unified-overlay-state.json'
    $state = [ordered]@{}
    if (Test-Path -LiteralPath $path) {
        try {
            $old = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $old.PSObject.Properties) { $state[$p.Name] = $p.Value }
        } catch { }
    }
    # A silent update keeps the language the app already uses.
    if (-not ($Silent -and $state.Contains('Language'))) { $state['Language'] = $script:Lang }
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
}

# ---------------------------------------------------------------------------
# PowerShell 7 runtime. The app runs best on PowerShell 7; a new computer
# usually only has Windows PowerShell 5.1, so a portable copy is downloaded
# into <install>\runtime\pwsh (no admin rights needed). If the download fails
# the app still starts on Windows PowerShell 5.1.
# ---------------------------------------------------------------------------
function Find-SystemPwsh {
    foreach ($p in @(
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'PowerShell\7\pwsh.exe' }),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'))) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Install-PwshRuntime([string]$TargetDir, [scriptblock]$OnProgress) {
    $runtimeDir = Join-Path $TargetDir 'runtime\pwsh'
    if (Test-Path -LiteralPath (Join-Path $runtimeDir 'pwsh.exe')) { return $true }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'ARM64' { 'arm64' } 'x86' { 'x86' } default { 'x64' } }
        $url = $null
        try {
            $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -Headers @{ 'User-Agent' = 'JayOS-AI-Usage-Setup' } -TimeoutSec 20 -UseBasicParsing
            $asset = $rel.assets | Where-Object { $_.name -like "PowerShell-*-win-$arch.zip" } | Select-Object -First 1
            if ($asset) { $url = $asset.browser_download_url }
        } catch { }
        if (-not $url) { $url = "https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/PowerShell-7.4.6-win-$arch.zip" }

        $zip = Join-Path ([IO.Path]::GetTempPath()) ('jayos-pwsh-{0}.zip' -f [guid]::NewGuid().ToString('N'))
        $req = [Net.HttpWebRequest]::Create($url)
        $req.UserAgent = 'JayOS-AI-Usage-Setup'
        $req.Timeout = 30000
        $resp = $req.GetResponse()
        $total = [double]$resp.ContentLength
        $in = $resp.GetResponseStream()
        $out = [IO.File]::Create($zip)
        try {
            $buf = New-Object byte[] 262144
            $done = 0.0; $last = [DateTime]::MinValue
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $out.Write($buf, 0, $n); $done += $n
                if (([DateTime]::UtcNow - $last).TotalMilliseconds -gt 120) {
                    $last = [DateTime]::UtcNow
                    if ($OnProgress) { & $OnProgress $(if ($total -gt 0) { $done / $total } else { -1 }) }
                }
            }
        } finally { $out.Dispose(); $in.Dispose(); $resp.Dispose() }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $tmpDir = $runtimeDir + '.tmp'
        if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force }
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmpDir)
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath (Join-Path $tmpDir 'pwsh.exe'))) { throw 'pwsh.exe missing from download' }
        if (Test-Path -LiteralPath $runtimeDir) { Remove-Item -LiteralPath $runtimeDir -Recurse -Force }
        Move-Item -LiteralPath $tmpDir -Destination $runtimeDir
        return $true
    } catch {
        return $false
    }
}

function Invoke-Install([string]$TargetDir, [bool]$Autostart, [bool]$Desktop) {
    $steps = 5.0
    $report = {
        param([double]$n, [string]$key, [string]$extra = '')
        $ui.progressStep.Text = (S $key) -f $extra
        $ui.progressFill.Width = [math]::Max(6, ($ui.progressFill.Parent.ActualWidth) * ($n / $steps))
        Pump
    }

    & $report 1 'StepStop'
    Stop-RunningOverlay
    Start-Sleep -Milliseconds 300

    & $report 2 'StepCopy'
    $src = (Resolve-Path -LiteralPath $SourceDir).Path.TrimEnd('\')
    New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
    $dst = (Resolve-Path -LiteralPath $TargetDir).Path.TrimEnd('\')
    if ($src -ne $dst) {
        foreach ($name in 'unified-overlay.ps1','Start-Unified.vbs','Setup.ps1','Setup.vbs','Install.bat','Uninstall.bat',
                          'sqlite3.exe','README.md','LICENSE') {
            $from = Join-Path $src $name
            if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination $dst -Force }
        }
        foreach ($dir in 'src','icons','assets') {
            $from = Join-Path $src $dir
            if (-not (Test-Path -LiteralPath $from)) { continue }
            $to = Join-Path $dst $dir
            New-Item -ItemType Directory -Force -Path $to | Out-Null
            Copy-Item -Path (Join-Path $from '*') -Destination $to -Recurse -Force
        }
    }

    if (-not (Find-SystemPwsh)) {
        & $report 2.05 'StepRuntime'
        [void](Install-PwshRuntime $dst {
            param($f)
            & $report (2 + [math]::Max(0, $f) * 0.95) 'StepRuntime' $(if ($f -ge 0) { '{0:P0}' -f $f } else { '' })
        })
    }

    & $report 3 'StepShort'
    New-Shortcut $StartMenuLnk $dst
    if ($Desktop) { New-Shortcut $DesktopLnk $dst } elseif (Test-Path -LiteralPath $DesktopLnk) { Remove-Item -LiteralPath $DesktopLnk -Force }
    if ($Autostart) { New-Shortcut $StartupLnk $dst } elseif (Test-Path -LiteralPath $StartupLnk) { Remove-Item -LiteralPath $StartupLnk -Force }

    & $report 4.5 'StepSettings'
    Save-LanguageSetting $dst
    $sizeKb = [int]((Get-ChildItem -LiteralPath $dst -Recurse -File | Measure-Object Length -Sum).Sum / 1KB)
    New-Item -Path $RegKey -Force | Out-Null
    $values = @{
        DisplayName = $AppName; DisplayVersion = $AppVersion; Publisher = $Publisher
        DisplayIcon = (Join-Path $dst 'assets\ai-usage-overlay.ico'); InstallLocation = $dst
        UninstallString = ('"{0}" "{1}" /uninstall' -f (Join-Path $env:SystemRoot 'System32\wscript.exe'), (Join-Path $dst 'Setup.vbs'))
    }
    foreach ($k in $values.Keys) { New-ItemProperty -Path $RegKey -Name $k -Value $values[$k] -PropertyType String -Force | Out-Null }
    New-ItemProperty -Path $RegKey -Name 'NoModify' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $RegKey -Name 'NoRepair' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $RegKey -Name 'EstimatedSize' -Value $sizeKb -PropertyType DWord -Force | Out-Null
    return $dst
}

function Invoke-Uninstall {
    Stop-RunningOverlay
    foreach ($lnk in $StartMenuLnk, $DesktopLnk, $StartupLnk) {
        if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item -Path $RegKey -Recurse -Force -ErrorAction SilentlyContinue
    # This script (and possibly the PowerShell running it) lives in the folder
    # being removed: a helper outside it waits for this process to exit first.
    $dir = (Resolve-Path -LiteralPath $SourceDir).Path
    $cmd = "Wait-Process -Id $PID -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500; Remove-Item -LiteralPath '{0}' -Recurse -Force -ErrorAction SilentlyContinue" -f $dir.Replace("'", "''")
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + $enc)
}

# ---------------------------------------------------------------------------
# Wizard flow
# ---------------------------------------------------------------------------
$script:Page = 0
$script:TargetDir = $DefaultDir
$script:Installed = $null
$pages = @($ui.pageWelcome, $ui.pageOptions, $ui.pageProgress, $ui.pageDone)

function Update-Text {
    $ui.welcomeTitle.Text  = S 'WelcomeTitle'
    $ui.welcomeBody.Text   = S 'WelcomeBody'
    $ui.languageLabel.Text = S 'Language'
    $ui.optionsTitle.Text  = S 'OptionsTitle'
    $ui.locationLabel.Text = S 'Location'
    $ui.browseButton.Content = S 'Browse'
    $ui.autostartBox.Content = S 'Autostart'
    $ui.desktopBox.Content = S 'Desktop'
    $ui.progressTitle.Text = S 'Installing'
    $ui.doneTitle.Text     = S 'DoneTitle'
    $ui.doneBody.Text      = S 'DoneBody'
    $ui.launchBox.Content  = S 'LaunchNow'
    $ui.backButton.Content = S 'Back'
    $ui.locationText.Text  = $script:TargetDir
    $tag = switch ($script:Lang) { 'zh' { 'zh-CN' } 'ja' { 'ja-JP' } 'fr' { 'fr-FR' } 'ko' { 'ko-KR' } default { 'en-US' } }
    $win.Language = [System.Windows.Markup.XmlLanguage]::GetLanguage($tag)
    foreach ($chip in $ui.languageRow.Children) {
        $on = ([string]$chip.Tag -eq $script:Lang)
        $chip.Background = Brush $(if ($on) { '#F5F5F7' } else { '#14FFFFFF' })
        $chip.Child.Foreground = Brush $(if ($on) { '#111113' } else { '#E5E5EA' })
    }
    Show-Page $script:Page
}

function Show-Page([int]$Index) {
    $script:Page = $Index
    for ($i = 0; $i -lt $pages.Count; $i++) {
        $pages[$i].Visibility = if ($i -eq $Index) { 'Visible' } else { 'Collapsed' }
    }
    $ui.backButton.Visibility = if ($Index -eq 1) { 'Visible' } else { 'Collapsed' }
    $ui.nextButton.Content = switch ($Index) { 0 { S 'Next' } 1 { S 'Install' } 3 { S 'Finish' } default { S 'Next' } }
    $ui.nextButton.IsEnabled = ($Index -ne 2)
    $ui.closeButton.IsEnabled = ($Index -ne 2)
    $ui.dots.Children.Clear()
    for ($i = 0; $i -lt $pages.Count; $i++) {
        $d = New-Object System.Windows.Shapes.Ellipse
        $d.Width = 7; $d.Height = 7; $d.Margin = '0,0,7,0'
        $d.Fill = Brush $(if ($i -eq $Index) { '#F5F5F7' } else { '#48484C' })
        [void]$ui.dots.Children.Add($d)
    }
}

foreach ($code in $Languages.Keys) {
    $chip = New-Object System.Windows.Controls.Border
    $chip.CornerRadius = 9; $chip.Padding = '14,7'; $chip.Margin = '0,0,8,8'; $chip.Cursor = 'Hand'
    $chip.BorderBrush = Brush '#26FFFFFF'; $chip.BorderThickness = 1; $chip.Tag = $code
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Languages[$code]; $tb.FontSize = 13
    $chip.Child = $tb
    $chip.Add_MouseLeftButtonUp({ param($s, $e) $script:Lang = [string]$s.Tag; Update-Text })
    [void]$ui.languageRow.Children.Add($chip)
}

# Buttons and switches react on mouse-up directly instead of relying on WPF's
# mouse capture, which fails when the window was opened without focus (e.g. from
# a hidden console) and left every button dead.
function Register-Tap($Element, [scriptblock]$Action) {
    $Element.Tag = $Action
    $Element.Add_PreviewMouseLeftButtonUp({
        param($s, $e)
        $p = $e.GetPosition($s)
        $inside = ($p.X -ge 0 -and $p.Y -ge 0 -and $p.X -le $s.ActualWidth -and $p.Y -le $s.ActualHeight)
        $e.Handled = $true
        if ($s.IsMouseCaptured) { $s.ReleaseMouseCapture() }
        if ($inside -and $s.IsEnabled) { & $s.Tag }
    })
    if ($Element -is [System.Windows.Controls.Button]) {
        # Keyboard (Space / Enter on a focused button) still goes through Click.
        $Element.Add_Click({ param($s, $e) & $s.Tag })
    }
}
foreach ($box in $ui.autostartBox, $ui.desktopBox, $ui.launchBox) {
    $box.Add_PreviewMouseLeftButtonUp({
        param($s, $e)
        $e.Handled = $true
        if ($s.IsMouseCaptured) { $s.ReleaseMouseCapture() }
        $p = $e.GetPosition($s)
        if ($p.X -ge 0 -and $p.Y -ge 0 -and $p.X -le $s.ActualWidth -and $p.Y -le $s.ActualHeight) { $s.IsChecked = -not [bool]$s.IsChecked }
    })
}

$script:Mode = if ($Uninstall) { 'uninstall' } else { 'install' }
$script:Removed = $false
Register-Tap $ui.closeButton { $win.Close() }
Register-Tap $ui.backButton { if ($script:Mode -eq 'uninstall') { $win.Close() } else { Show-Page 0 } }
Register-Tap $ui.browseButton {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = S 'PickFolder'
    try { $dlg.UseDescriptionForTitle = $true } catch { }   # .NET 5+ only
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $picked = $dlg.SelectedPath
        # An existing install is updated in place; any other non-empty folder
        # gets its own "JayOS AI Usage" subfolder.
        $isInstall = Test-Path -LiteralPath (Join-Path $picked 'unified-overlay.ps1')
        if (-not $isInstall -and (Split-Path -Leaf $picked) -ne 'JayOS AI Usage' -and (Get-ChildItem -LiteralPath $picked -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            $picked = Join-Path $picked 'JayOS AI Usage'
        }
        $script:TargetDir = $picked
        $ui.locationText.Text = $picked
    }
}
Register-Tap $ui.nextButton {
  try {
    if ($script:Mode -eq 'uninstall') {
        if ($script:Removed) { $win.Close(); return }
        try { Invoke-Uninstall } catch { }
        $script:Removed = $true
        $ui.welcomeBody.Text = S 'RemovedBody'
        $ui.backButton.Visibility = 'Collapsed'
        $ui.nextButton.Content = S 'Close'
        $ui.nextButton.Background = Brush '#F5F5F7'; $ui.nextButton.BorderBrush = Brush '#F5F5F7'; $ui.nextButton.Foreground = Brush '#111113'
        return
    }
    switch ($script:Page) {
        0 { Show-Page 1 }
        1 {
            Show-Page 2
            try {
                $script:Installed = Invoke-Install $script:TargetDir ([bool]$ui.autostartBox.IsChecked) ([bool]$ui.desktopBox.IsChecked)
                Show-Page 3
            } catch {
                [void][System.Windows.MessageBox]::Show($_.Exception.Message, (S 'FailTitle'), 'OK', 'Error')
                Show-Page 1
            }
        }
        3 {
            if ($ui.launchBox.IsChecked -and $script:Installed) {
                Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"' + (Join-Path $script:Installed 'Start-Unified.vbs') + '"')
            }
            $win.Close()
        }
    }
  } catch {
    $msg = ($_ | Out-String)
    [void][System.Windows.MessageBox]::Show($msg, 'Setup')
  }
}

# ---------------------------------------------------------------------------
# Uninstall mode: one confirmation screen in the language the app uses.
# ---------------------------------------------------------------------------
if ($Uninstall) {
    try {
        $state = Get-Content -LiteralPath (Join-Path $SourceDir 'unified-overlay-state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($T.ContainsKey([string]$state.Language)) { $script:Lang = [string]$state.Language }
    } catch { }
    Update-Text
    $ui.welcomeTitle.Text = S 'UninstTitle'
    $ui.welcomeBody.Text = S 'UninstBody'
    $ui.languageLabel.Visibility = 'Collapsed'
    $ui.languageRow.Visibility = 'Collapsed'
    $ui.dots.Visibility = 'Collapsed'
    $ui.backButton.Visibility = 'Visible'
    $ui.backButton.Content = S 'Cancel'
    $ui.nextButton.Content = S 'Remove'
    $ui.nextButton.Background = Brush '#FF453A'; $ui.nextButton.BorderBrush = Brush '#FF453A'; $ui.nextButton.Foreground = Brush '#FFFFFF'
    [void]$win.ShowDialog()
    return
}

if ($Silent) {
    try {
        if ($InstallDir) { $script:TargetDir = $InstallDir.TrimEnd('\') }
        # An update keeps the choices made at install time; a first install
        # turns both on.
        $existing = Test-Path -LiteralPath (Join-Path $script:TargetDir 'unified-overlay.ps1')
        $autostart = if ($existing) { Test-Path -LiteralPath $StartupLnk } else { $true }
        $desktop = if ($existing) { Test-Path -LiteralPath $DesktopLnk } else { $true }
        $installed = Invoke-Install $script:TargetDir $autostart $desktop
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"' + (Join-Path $installed 'Start-Unified.vbs') + '"')
        exit 0
    } catch {
        # Whatever went wrong, do not leave the user without the app.
        $vbs = Join-Path $script:TargetDir 'Start-Unified.vbs'
        if (Test-Path -LiteralPath $vbs) { Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"' + $vbs + '"') }
        exit 1
    }
}

Update-Text
[void]$win.ShowDialog()
