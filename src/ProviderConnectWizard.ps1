# ---------------------------------------------------------------------------
# Connect wizard for the AIs that sign in through their own tools - Claude
# Code, Codex, Grok and Cursor (DeepSeek has its API-key wizard,
# src\DeepSeekKeyWizard.ps1). Same sheet as the DeepSeek wizard, two steps:
#   1. 安装  - is the tool on this PC? If not: the official install guide,
#              then "重新检查".
#   2. 登录  - starts the tool's own sign-in (claude auth login / codex login
#              in a console that opens the browser; the Grok Bot or Cursor
#              app). Passwords never pass through this app.
# While open it re-checks every 1.5 s (Get-AccountState, Resolve-ProviderLoginCli),
# ticks each finished step, and says 已连接 once the sign-in shows up.
# ---------------------------------------------------------------------------
$script:ConnectWizardWin = $null

# A desktop app counts as installed when one of its known exe paths exists
# or Windows has its packaged app.
function Test-ProviderAppInstalled([string]$Key) {
    foreach ($raw in @($script:ProviderMeta[$Key].Exes)) { if ($raw -and (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($raw)))) { return $true } }
    try { if (Get-Command Get-ProviderPackageAppId -ErrorAction SilentlyContinue) { if (Get-ProviderPackageAppId $Key) { return $true } } } catch { }
    return $false
}

# What each AI needs. Install / Login are scriptblocks run on button press.
function Get-ProviderConnectProfile([string]$Key) {
    $name = [string]$script:ProviderMeta[$Key].Name
    switch ($Key) {
        'claude' {
            return @{
                Title = '连接 Claude Code'; Name = 'Claude Code'
                Intro = '灵动岛读取 Claude Code 的登录状态和本机用量。登录在 Claude Code 自己的窗口和浏览器里完成，灵动岛看不到你的密码。'
                InstallTitle = '安装 Claude Code'
                InstallOk = '已安装 Claude Code（claude 命令）'
                InstallMissing = '没找到 claude 命令。按官方说明安装 Claude Code，装好后点「重新检查」。'
                InstallButton = '打开安装说明'
                InstallAction = { Open-ProviderLink -Provider 'claude' -Kind 'Docs' }
                IsInstalled = { [bool](Resolve-ProviderLoginCli 'claude') }
                LoginTitle = '登录 Claude 账号'
                LoginText = '会打开一个命令行窗口并跳到浏览器，在浏览器里确认登录；完成后窗口自己关闭。'
                LoginButton = '登录 Claude'
                LoginAction = { Invoke-ProviderLogin -Provider ([string]$script:ProviderMeta['claude'].Name) -CliName 'claude' }
                Kinds = @('ClaudeUsage', 'ClaudeStats')
            }
        }
        'codex' {
            return @{
                Title = '连接 Codex'; Name = 'Codex'
                Intro = '灵动岛读取 Codex 的额度和本机会话统计。用 ChatGPT 账号登录，在 Codex 自己的窗口和浏览器里完成。'
                InstallTitle = '安装 Codex'
                InstallOk = '已安装 Codex（codex 命令）'
                InstallMissing = '没找到 codex 命令。按官方说明安装 Codex CLI，装好后点「重新检查」。'
                InstallButton = '打开安装说明'
                InstallAction = { Open-ProviderLink -Provider 'codex' -Kind 'Docs' }
                IsInstalled = { [bool](Resolve-ProviderLoginCli 'codex') }
                LoginTitle = '用 ChatGPT 账号登录'
                LoginText = '会打开一个命令行窗口并跳到浏览器，选择你的 ChatGPT 账号并确认；完成后窗口自己关闭。'
                LoginButton = '登录 Codex'
                LoginAction = { Invoke-ProviderLogin -Provider ([string]$script:ProviderMeta['codex'].Name) -CliName 'codex' }
                Kinds = @('CodexStats')
            }
        }
        'grok' {
            return @{
                Title = '连接 Grok'; Name = $name
                Intro = '灵动岛读取 Grok 的用量。登录在 Grok Bot（或 grok 命令行）里完成，灵动岛看不到你的密码。'
                InstallTitle = '安装 Grok Bot'
                InstallOk = '已安装 Grok'
                InstallMissing = '没找到 Grok Bot 或 grok 命令。按官方说明安装，装好后点「重新检查」。'
                InstallButton = '打开安装说明'
                InstallAction = { Open-ProviderLink -Provider 'grok' -Kind 'Docs' }
                IsInstalled = { (Test-ProviderAppInstalled 'grok') -or [bool](Resolve-ProviderLoginCli 'grok') }
                LoginTitle = '登录 Grok 账号'
                LoginText = '打开 Grok Bot 并在里面登录；只装了命令行时，会打开命令行登录。'
                LoginButton = '打开 Grok 登录'
                LoginAction = {
                    $desktop = if (Get-Command Get-GrokBotDesktopStatus -ErrorAction SilentlyContinue) { Get-GrokBotDesktopStatus } else { $null }
                    if ($desktop -and $desktop.Installed) { Open-ProviderApp 'grok' }
                    else { Invoke-ProviderLogin -Provider ([string]$script:ProviderMeta['grok'].Name) -CliName 'grok' }
                }
                Kinds = @('GrokUsage')
            }
        }
        'cursor' {
            return @{
                Title = '连接 Cursor'; Name = 'Cursor'
                Intro = '灵动岛从 Cursor 桌面版读取用量。登录在 Cursor 里完成，灵动岛看不到你的密码。'
                InstallTitle = '安装 Cursor'
                InstallOk = '已安装 Cursor'
                InstallMissing = '没找到 Cursor 桌面版。下载安装后点「重新检查」。'
                InstallButton = '打开 Cursor 官网'
                InstallAction = { Start-Process ([string]$script:ProviderWebsites['cursor']) }
                IsInstalled = { Test-ProviderAppInstalled 'cursor' }
                LoginTitle = '在 Cursor 里登录'
                LoginText = '打开 Cursor，点右上角的头像登录你的账号。登录后回到这里点「重新检查」。'
                LoginButton = '打开 Cursor'
                LoginAction = { Open-ProviderApp 'cursor' }
                Kinds = @('ClaudeUsage')
            }
        }
    }
    return $null
}

$script:ConnectWizardXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        Topmost="True" ShowInTaskbar="False" Width="380" SizeToContent="Height"
        UseLayoutRounding="True" SnapsToDevicePixels="True" FontFamily="Segoe UI, Microsoft YaHei UI"
        WindowStartupLocation="CenterScreen">
  <Border x:Name="sheet" CornerRadius="16" Background="#FF141416" BorderBrush="#FF3A3A3E" BorderThickness="1" Margin="2" Padding="20,16,20,18" Opacity="0">
    <StackPanel>
      <Grid Background="#01000000" Margin="0,0,0,12">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Border x:Name="iconTile" Width="26" Height="26" CornerRadius="7" Margin="0,0,10,0" ClipToBounds="True">
            <Grid>
              <TextBlock x:Name="iconMono" Foreground="White" FontSize="11" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              <Image x:Name="iconImage" Stretch="UniformToFill"/>
            </Grid>
          </Border>
          <TextBlock x:Name="titleText" Foreground="#F5F5F7" FontSize="15" FontWeight="SemiBold" VerticalAlignment="Center"/>
        </StackPanel>
        <Border x:Name="closeButton" Width="22" Height="22" CornerRadius="11" Background="#2C2C2E" HorizontalAlignment="Right" Cursor="Hand">
          <TextBlock Text="&#xE711;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="8" Foreground="#AEAEB2" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
      </Grid>
      <TextBlock x:Name="introText" Foreground="#8E8E93" FontSize="11.5" TextWrapping="Wrap" Margin="0,0,0,14"/>

      <Border CornerRadius="10" Background="#FF1C1C1E" Padding="12,10,12,12" Margin="0,0,0,10">
        <StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
            <Border x:Name="step1Dot" Width="18" Height="18" CornerRadius="9" Background="#FF0A84FF" Margin="0,0,8,0">
              <TextBlock x:Name="step1Num" Text="1" Foreground="White" FontSize="11" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <TextBlock x:Name="step1Title" Foreground="#F5F5F7" FontSize="13" FontWeight="SemiBold" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock x:Name="step1Text" Foreground="#AEAEB2" FontSize="11.5" TextWrapping="Wrap" Margin="26,0,0,0"/>
          <Border x:Name="step1Button" Margin="26,8,0,0" HorizontalAlignment="Left" CornerRadius="8" Background="#FF2C2C2E" Padding="12,6,12,6" Cursor="Hand">
            <StackPanel Orientation="Horizontal">
              <TextBlock x:Name="step1ButtonText" Foreground="#0A84FF" FontSize="12" FontWeight="SemiBold"/>
              <TextBlock Text="&#xE8A7;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="10" Foreground="#0A84FF" Margin="6,2,0,0"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </Border>

      <Border x:Name="step2Block" CornerRadius="10" Background="#FF1C1C1E" Padding="12,10,12,12" Margin="0,0,0,12">
        <StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
            <Border x:Name="step2Dot" Width="18" Height="18" CornerRadius="9" Background="#FF0A84FF" Margin="0,0,8,0">
              <TextBlock x:Name="step2Num" Text="2" Foreground="White" FontSize="11" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <TextBlock x:Name="step2Title" Foreground="#F5F5F7" FontSize="13" FontWeight="SemiBold" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock x:Name="step2Text" Foreground="#AEAEB2" FontSize="11.5" TextWrapping="Wrap" Margin="26,0,0,0"/>
          <Border x:Name="step2Button" Margin="26,8,0,0" HorizontalAlignment="Left" CornerRadius="8" Background="#FF0A84FF" Padding="12,6,12,6" Cursor="Hand">
            <TextBlock x:Name="step2ButtonText" Foreground="White" FontSize="12" FontWeight="SemiBold"/>
          </Border>
          <TextBlock x:Name="statusText" Margin="26,8,0,0" FontSize="11.5" TextWrapping="Wrap" Foreground="#8E8E93"/>
        </StackPanel>
      </Border>

      <Grid>
        <TextBlock x:Name="recheckLink" Text="重新检查" Foreground="#0A84FF" FontSize="12" Cursor="Hand" VerticalAlignment="Center"/>
        <Border x:Name="doneButton" HorizontalAlignment="Right" CornerRadius="9" Padding="14,7,14,7" Cursor="Hand" Background="#FF2C2C2E">
          <TextBlock x:Name="doneText" Text="关闭" Foreground="#F5F5F7" FontSize="12.5"/>
        </Border>
      </Grid>
    </StackPanel>
  </Border>
</Window>
'@

function Close-ProviderConnectWizard {
    $w = $script:ConnectWizardWin
    $script:ConnectWizardWin = $null
    if ($w) { try { if ($w.Tag.Timer) { $w.Tag.Timer.Stop() } } catch { }; try { $w.Close() } catch { } }
}

function Set-ConnectStepDone($Dot, $Num, [bool]$Done) {
    $Dot.Background = NewBrush $(if ($Done) { '#FF30D158' } else { '#FF0A84FF' })
    if ($Done) { $Num.Text = [string][char]0x2713 } elseif ($Num.Tag) { $Num.Text = [string]$Num.Tag }
}

# Re-read install + sign-in state and redraw the two steps.
function Update-ProviderConnectWizard {
    $w = $script:ConnectWizardWin
    if (-not $w) { return }
    $t = $w.Tag; $u = $t.Ui; $p = $t.Profile
    $installed = $false
    try { $installed = [bool](& $p.IsInstalled) } catch { $installed = $false }
    Set-ConnectStepDone $u.step1Dot $u.step1Num $installed
    $u.step1Text.Text = if ($installed) { $p.InstallOk } else { $p.InstallMissing }
    $u.step1Button.Visibility = if ($installed) { 'Collapsed' } else { 'Visible' }
    $u.step2Block.Opacity = if ($installed) { 1.0 } else { 0.45 }
    $u.step2Button.IsHitTestVisible = $installed
    $state = $null
    try { $state = Get-AccountState $t.Key } catch { $state = $null }
    $tag = if ($state) { [string]$state.Tag } else { '' }
    $ok = ($installed -and $tag -eq 'acct:ok')
    Set-ConnectStepDone $u.step2Dot $u.step2Num $ok
    if (-not $installed) {
        $u.statusText.Text = '先完成第 1 步。'; $u.statusText.Foreground = NewBrush '#8E8E93'
    } elseif ($ok) {
        $u.statusText.Text = if ($t.LoginStarted) { ('已连接 ' + $p.Name + '，卡片会马上更新。') } else { '已登录。要换账号可以再点一次登录。' }
        $u.statusText.Foreground = NewBrush '#30D158'
        $u.doneText.Text = '完成'; $u.doneButton.Background = NewBrush '#FF0A84FF'
    } elseif ($tag -eq 'acct:stale') {
        $u.statusText.Text = '已登录，但上次刷新失败。点「重新检查」再试，或重新登录。'; $u.statusText.Foreground = NewBrush '#FF9F0A'
    } elseif ($t.LoginStarted) {
        $u.statusText.Text = '等你在打开的窗口或浏览器里完成登录…'; $u.statusText.Foreground = NewBrush '#8E8E93'
    } elseif ($tag -eq 'acct:auth') {
        $u.statusText.Text = '登录已过期，需要重新登录。'; $u.statusText.Foreground = NewBrush '#FF9F0A'
    } else {
        $u.statusText.Text = '还没有登录信息。'; $u.statusText.Foreground = NewBrush '#8E8E93'
    }
    if ($ok -and $t.LoginStarted -and -not $t.Celebrated) {
        $t.Celebrated = $true
        $u.statusText.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-IslandAnimation 0.0 1.0 220 'out'))
    }
}

function Request-ProviderConnectRefresh {
    $w = $script:ConnectWizardWin
    if (-not $w) { return }
    try { if (Get-Command Start-AllRefreshJobs -ErrorAction SilentlyContinue) { Start-AllRefreshJobs -Force -Kind @($w.Tag.Profile.Kinds) } } catch { }
}

function Show-ProviderConnectWizard([string]$Key, [switch]$NoShow) {
    $prof = Get-ProviderConnectProfile $Key
    if (-not $prof) { return $false }
    if ($script:ConnectWizardWin) {
        if ($script:ConnectWizardWin.Tag.Key -eq $Key) { try { $script:ConnectWizardWin.Activate() } catch { }; return $true }
        Close-ProviderConnectWizard
    }
    $win = [System.Windows.Markup.XamlReader]::Parse($script:ConnectWizardXaml)
    $ui = @{}
    foreach ($n in @('sheet', 'iconTile', 'iconMono', 'iconImage', 'titleText', 'closeButton', 'introText', 'step1Dot', 'step1Num', 'step1Title', 'step1Text', 'step1Button', 'step1ButtonText',
                     'step2Block', 'step2Dot', 'step2Num', 'step2Title', 'step2Text', 'step2Button', 'step2ButtonText', 'statusText', 'recheckLink', 'doneButton', 'doneText')) { $ui[$n] = $win.FindName($n) }
    $win.Tag = @{ Key = $Key; Profile = $prof; Ui = $ui; Timer = $null; LoginStarted = $false; Celebrated = $false }
    $script:ConnectWizardWin = $win

    # Header: the AI's own icon (icons\<key>.png), else its monogram on its colours.
    $meta = $script:ProviderMeta[$Key]
    try {
        $g = @($meta.Grad)
        $ui.iconTile.Background = New-Object System.Windows.Media.LinearGradientBrush(([System.Windows.Media.ColorConverter]::ConvertFromString([string]$g[0])), ([System.Windows.Media.ColorConverter]::ConvertFromString([string]$g[-1])), 45.0)
    } catch { $ui.iconTile.Background = NewBrush '#FF3A3A3C' }
    $ui.iconMono.Text = [string]$meta.Mono
    $png = Join-Path $script:AppDir ('icons\' + $Key + '.png')
    if (Test-Path -LiteralPath $png) {
        try {
            $bi = New-Object System.Windows.Media.Imaging.BitmapImage
            $bi.BeginInit(); $bi.CacheOption = 'OnLoad'; $bi.DecodePixelWidth = 64; $bi.UriSource = New-Object System.Uri($png); $bi.EndInit(); $bi.Freeze()
            $ui.iconImage.Source = $bi
        } catch { }
    }
    $ui.titleText.Text = $prof.Title
    $ui.introText.Text = $prof.Intro
    $ui.step1Title.Text = $prof.InstallTitle
    $ui.step1ButtonText.Text = $prof.InstallButton
    $ui.step2Title.Text = $prof.LoginTitle
    $ui.step2Text.Text = $prof.LoginText
    $ui.step2ButtonText.Text = $prof.LoginButton
    $ui.step1Num.Tag = '1'; $ui.step2Num.Tag = '2'

    foreach ($b in @($ui.closeButton, $ui.step1Button, $ui.step2Button, $ui.doneButton)) {
        $b.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
        $b.RenderTransform = New-Object System.Windows.Media.ScaleTransform(1, 1)
        $b.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; if (Get-Command Invoke-PressPop -ErrorAction SilentlyContinue) { Invoke-PressPop $s 0.94 } })
    }
    $ui.closeButton.Tag = { Close-ProviderConnectWizard }
    $ui.doneButton.Tag = { Close-ProviderConnectWizard }
    $ui.step1Button.Tag = { $w = $script:ConnectWizardWin; if ($w) { try { & $w.Tag.Profile.InstallAction } catch { } } }
    $ui.step2Button.Tag = {
        $w = $script:ConnectWizardWin; if (-not $w) { return }
        $w.Tag.LoginStarted = $true; $w.Tag.Celebrated = $false
        try { & $w.Tag.Profile.LoginAction } catch { try { Write-Log ('connect wizard login: ' + $_.Exception.Message) } catch { } }
        Update-ProviderConnectWizard
    }
    foreach ($b in @($ui.closeButton, $ui.step1Button, $ui.step2Button, $ui.doneButton)) {
        $b.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; if (Get-Command Invoke-PressPop -ErrorAction SilentlyContinue) { Invoke-PressPop $s 1.0 }; try { & $s.Tag } catch { } })
    }
    $ui.recheckLink.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Request-ProviderConnectRefresh; Update-ProviderConnectWizard })
    $win.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { Close-ProviderConnectWizard } })
    $win.Add_MouseLeftButtonDown({ param($s, $e) try { $s.DragMove() } catch { } })
    $win.Add_Closed({ param($s, $e) try { if ($s.Tag.Timer) { $s.Tag.Timer.Stop() } } catch { }; if ($script:ConnectWizardWin -eq $s) { $script:ConnectWizardWin = $null } })
    $win.Add_ContentRendered({ param($s, $e) $s.FindName('sheet').BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-IslandAnimation 0.0 1.0 180 'out')) })

    # Live re-check while open; a finished sign-in shows up within ~1.5 s
    # of the provider's refresh (the login watcher refreshes on exit).
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(1500)
    $timer.Add_Tick({ try { Update-ProviderConnectWizard } catch { } })
    $win.Tag.Timer = $timer
    Update-ProviderConnectWizard
    if ($NoShow) { return $true }   # tests: built and filled, never shown
    $win.Show()
    try { $win.Activate() } catch { }
    $timer.Start()
    return $true
}

# A card's status pill opens the wizard while that AI is not signed in
# (state other than "Signed in"); otherwise the click is left to the card.
function Register-ConnectStatusPills {
    # Done only when every pill exists and is wired: the first ticks can run
    # before the cards are built, and stopping then left them unwired.
    if (-not $script:window) { return $false }
    $all = $true
    foreach ($k in @('claude', 'codex', 'cursor', 'grok')) {
        $pill = $script:window.FindName($k + 'StatusPill')
        if (-not $pill) { $all = $false; continue }
        # Remember wired pills here, not in pill.Tag: the card's status code
        # uses Tag for its own styling and overwrote the marker.
        if (-not $script:ConnectPillWired) { $script:ConnectPillWired = @{} }
        if ($script:ConnectPillWired.ContainsKey($k) -and [object]::ReferenceEquals($script:ConnectPillWired[$k], $pill)) { continue }
        $script:ConnectPillWired[$k] = $pill
        $pill.Add_MouseEnter([scriptblock]::Create(@"
param(`$s, `$e)
try { `$st = Get-AccountState '$k'; if (`$st -and [string]`$st.Tag -ne 'acct:ok') { `$s.Cursor = [System.Windows.Input.Cursors]::Hand; `$s.ToolTip = '连接 ' + [string]`$script:ProviderMeta['$k'].Name } else { `$s.Cursor = `$null; `$s.ToolTip = `$null } } catch { }
"@))
        $pill.Add_MouseLeftButtonUp([scriptblock]::Create(@"
param(`$s, `$e)
try { `$st = Get-AccountState '$k'; if (`$st -and [string]`$st.Tag -ne 'acct:ok' -and (Test-ProviderAvailable '$k')) { `$e.Handled = `$true; [void](Show-ProviderConnectWizard '$k') } } catch { }
"@))
    }
    return $all
}
$script:ConnectPillTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ConnectPillTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:ConnectPillTries = 0
$script:ConnectPillTimer.Add_Tick({
    param($s, $e)
    $script:ConnectPillTries++
    try { if (Register-ConnectStatusPills) { $s.Stop() } } catch { try { Write-Log ('connect pills: ' + $_.Exception.Message) } catch { } }
    if ($script:ConnectPillTries -ge 60) { $s.Stop() }
})
$script:ConnectPillTimer.Start()