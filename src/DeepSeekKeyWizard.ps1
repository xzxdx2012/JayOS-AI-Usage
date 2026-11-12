# ---------------------------------------------------------------------------
# DeepSeek sign-in wizard: connect the DeepSeek card to the official balance
# with an API key the user creates and pastes in. Two steps in one small
# sheet (same look as the settings sheet):
#   1. open platform.deepseek.com/api_keys, create a key, copy it;
#   2. paste it here -> "验证并保存" asks DeepSeek once (GET /user/balance),
#      and only a key DeepSeek accepts is saved.
# The key is stored encrypted for this Windows account (DPAPI, the same
# protection as ConvertFrom-SecureString) in deepseek-api-key.dat next to
# the app, and is only ever sent to api.deepseek.com. Get-DeepSeekApiKey
# (src\DeepSeekData.ps1) reads it first.
# ---------------------------------------------------------------------------
$script:DeepSeekWizardWin = $null

function Get-DeepSeekKeyFile { Join-Path $script:AppDir 'deepseek-api-key.dat' }

function Save-DeepSeekApiKey([string]$Key) {
    $sec = ConvertTo-SecureString -String $Key -AsPlainText -Force
    $enc = ConvertFrom-SecureString -SecureString $sec
    $path = Get-DeepSeekKeyFile
    [IO.File]::WriteAllText($path + '.tmp', $enc, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath ($path + '.tmp') -Destination $path -Force
}

function Read-DeepSeekSavedKey {
    $path = Get-DeepSeekKeyFile
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    try {
        $sec = ConvertTo-SecureString -String ([IO.File]::ReadAllText($path).Trim())
        return [Net.NetworkCredential]::new('', $sec).Password
    } catch { return '' }
}

function Remove-DeepSeekSavedKey {
    $path = Get-DeepSeekKeyFile
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}

# Format check before anything is sent: DeepSeek keys are "sk-" + 32 hex.
function Test-DeepSeekKeyShape([string]$Key) {
    $k = $Key.Trim()
    if (-not $k) { return '先把 API key 粘贴到上面的框里' }
    if ($k -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return '这是一串 ID，不是 API key。API key 以 sk- 开头，只在创建时的弹窗里显示一次' }
    if (-not $k.StartsWith('sk-')) { return 'API key 应该以 sk- 开头，请重新复制' }
    if ($k -match '\s') { return 'key 里有空格，请重新复制' }
    if ($k.Length -lt 20 -or $k.Length -gt 200) { return 'key 的长度不对，请重新复制完整的一串' }
    return ''
}

function Close-DeepSeekKeyWizard {
    $w = $script:DeepSeekWizardWin
    $script:DeepSeekWizardWin = $null
    if ($w) { try { $w.Close() } catch { } }
}

$script:DeepSeekWizardXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        Topmost="True" ShowInTaskbar="False" Width="380" SizeToContent="Height"
        UseLayoutRounding="True" SnapsToDevicePixels="True" FontFamily="Segoe UI, Microsoft YaHei UI"
        WindowStartupLocation="CenterScreen">
  <Border x:Name="sheet" CornerRadius="16" Background="#FF141416" BorderBrush="#FF3A3A3E" BorderThickness="1" Margin="2" Padding="20,16,20,18" Opacity="0">
    <StackPanel>
      <Grid x:Name="titleBar" Background="#01000000" Margin="0,0,0,12">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Border Width="26" Height="26" CornerRadius="7" Background="#FF4D6BFE" Margin="0,0,10,0">
            <TextBlock Text="&#xE192;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="13" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock Text="连接 DeepSeek 余额" Foreground="#F5F5F7" FontSize="15" FontWeight="SemiBold" VerticalAlignment="Center"/>
        </StackPanel>
        <Border x:Name="closeButton" Width="22" Height="22" CornerRadius="11" Background="#2C2C2E" HorizontalAlignment="Right" Cursor="Hand">
          <TextBlock Text="&#xE711;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="8" Foreground="#AEAEB2" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
      </Grid>
      <TextBlock Text="灵动岛用你的 API key 向 DeepSeek 官方查询余额。key 只保存在这台电脑上（按你的 Windows 账户加密），只会发给 api.deepseek.com。"
                 Foreground="#8E8E93" FontSize="11.5" TextWrapping="Wrap" Margin="0,0,0,14"/>

      <!-- Step 1 -->
      <Border CornerRadius="10" Background="#FF1C1C1E" Padding="12,10,12,12" Margin="0,0,0,10">
        <StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
            <Border Width="18" Height="18" CornerRadius="9" Background="#FF0A84FF" Margin="0,0,8,0">
              <TextBlock Text="1" Foreground="White" FontSize="11" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <TextBlock Text="创建 API key" Foreground="#F5F5F7" FontSize="13" FontWeight="SemiBold" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock Foreground="#AEAEB2" FontSize="11.5" TextWrapping="Wrap" Margin="26,0,0,8"
                     Text="在开放平台登录，点「创建 API key」，在弹窗里点复制。那串 sk- 开头的字只显示一次。"/>
          <Border x:Name="openButton" Margin="26,0,0,0" HorizontalAlignment="Left" CornerRadius="8" Background="#FF2C2C2E" Padding="12,6,12,6" Cursor="Hand">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="打开 DeepSeek 开放平台" Foreground="#0A84FF" FontSize="12" FontWeight="SemiBold"/>
              <TextBlock Text="&#xE8A7;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="10" Foreground="#0A84FF" Margin="6,2,0,0"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </Border>

      <!-- Step 2 -->
      <Border CornerRadius="10" Background="#FF1C1C1E" Padding="12,10,12,12" Margin="0,0,0,12">
        <StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
            <Border Width="18" Height="18" CornerRadius="9" Background="#FF0A84FF" Margin="0,0,8,0">
              <TextBlock Text="2" Foreground="White" FontSize="11" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <TextBlock Text="粘贴到这里" Foreground="#F5F5F7" FontSize="13" FontWeight="SemiBold" VerticalAlignment="Center"/>
          </StackPanel>
          <Grid Margin="26,0,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Border CornerRadius="8" Background="#FF2C2C2E" BorderBrush="#FF3A3A3E" BorderThickness="1" Padding="8,5,8,5">
              <PasswordBox x:Name="keyBox" Background="Transparent" BorderThickness="0" Foreground="#F5F5F7" CaretBrush="#F5F5F7" FontSize="12.5" PasswordChar="●"/>
            </Border>
            <Border x:Name="pasteButton" Grid.Column="1" Margin="8,0,0,0" CornerRadius="8" Background="#FF2C2C2E" Padding="10,0,10,0" Cursor="Hand">
              <TextBlock Text="粘贴" Foreground="#F5F5F7" FontSize="12" VerticalAlignment="Center"/>
            </Border>
          </Grid>
          <TextBlock x:Name="statusText" Margin="26,8,0,0" FontSize="11.5" TextWrapping="Wrap" Foreground="#8E8E93" Text=""/>
        </StackPanel>
      </Border>

      <Grid>
        <TextBlock x:Name="altLink" Text="改用 DeepSeek Harness" Foreground="#636366" FontSize="11" Cursor="Hand" VerticalAlignment="Center" ToolTip="不填 key：打开 DeepSeek Harness，由它读取余额（它设了访问口令时，需要把口令填到 deepseek-harness-token.txt）"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Border x:Name="removeButton" CornerRadius="9" Padding="12,7,12,7" Cursor="Hand" Margin="0,0,8,0" Visibility="Collapsed" Background="#FF2C2C2E">
            <TextBlock Text="移除已保存的 key" Foreground="#FF453A" FontSize="12"/>
          </Border>
          <Border x:Name="cancelButton" CornerRadius="9" Padding="14,7,14,7" Cursor="Hand" Margin="0,0,8,0" Background="#FF2C2C2E">
            <TextBlock Text="取消" Foreground="#F5F5F7" FontSize="12.5"/>
          </Border>
          <Border x:Name="saveButton" CornerRadius="9" Padding="14,7,14,7" Cursor="Hand" Background="#FF0A84FF">
            <TextBlock x:Name="saveText" Text="验证并保存" Foreground="White" FontSize="12.5" FontWeight="SemiBold"/>
          </Border>
        </StackPanel>
      </Grid>
    </StackPanel>
  </Border>
</Window>
'@

function Set-DeepSeekWizardStatus($Ui, [string]$Text, [string]$Color = '#8E8E93') {
    $Ui.statusText.Text = $Text
    $Ui.statusText.Foreground = NewBrush $Color
}

function Show-DeepSeekKeyWizard {
    if ($script:DeepSeekWizardWin) { try { $script:DeepSeekWizardWin.Activate() } catch { }; return }
    $win = [System.Windows.Markup.XamlReader]::Parse($script:DeepSeekWizardXaml)
    $ui = @{}
    foreach ($n in @('sheet', 'titleBar', 'closeButton', 'openButton', 'keyBox', 'pasteButton', 'statusText', 'altLink', 'removeButton', 'cancelButton', 'saveButton', 'saveText')) { $ui[$n] = $win.FindName($n) }
    $win.Tag = @{ Ui = $ui; Busy = $false; Task = $null; Client = $null; Timer = $null; Key = '' }
    $script:DeepSeekWizardWin = $win

    if (Read-DeepSeekSavedKey) {
        $ui.removeButton.Visibility = 'Visible'
        Set-DeepSeekWizardStatus $ui '已保存过一个 key。粘贴新的 key 可替换它。'
    }
    # Buttons press like the rest of the island; actions run on release.
    foreach ($b in @($ui.openButton, $ui.pasteButton, $ui.removeButton, $ui.cancelButton, $ui.saveButton, $ui.closeButton)) {
        $b.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
        $b.RenderTransform = New-Object System.Windows.Media.ScaleTransform(1, 1)
        $b.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; if (Get-Command Invoke-PressPop -ErrorAction SilentlyContinue) { Invoke-PressPop $s 0.94 } })
    }
    $up = {
        param($Element, [scriptblock]$Action)
        $Element.Tag = $Action
        $Element.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; if (Get-Command Invoke-PressPop -ErrorAction SilentlyContinue) { Invoke-PressPop $s 1.0 }; try { & $s.Tag } catch { } })
    }
    & $up $ui.closeButton { Close-DeepSeekKeyWizard }
    & $up $ui.cancelButton { Close-DeepSeekKeyWizard }
    & $up $ui.openButton { try { Start-Process 'https://platform.deepseek.com/api_keys' } catch { } }
    & $up $ui.pasteButton {
        $w = $script:DeepSeekWizardWin; if (-not $w) { return }
        $u = $w.Tag.Ui
        try { $clip = [System.Windows.Clipboard]::GetText() } catch { $clip = '' }
        $clip = ([string]$clip).Trim()
        if ($clip) { $u.keyBox.Password = $clip; $why = Test-DeepSeekKeyShape $clip; if ($why) { Set-DeepSeekWizardStatus $u $why '#FF9F0A' } else { Set-DeepSeekWizardStatus $u '格式没问题，点「验证并保存」。' '#30D158' } }
        else { Set-DeepSeekWizardStatus $u '剪贴板里没有文字，先在开放平台复制 key。' '#FF9F0A' }
    }
    & $up $ui.removeButton {
        Remove-DeepSeekSavedKey
        $w = $script:DeepSeekWizardWin; if ($w) { $w.Tag.Ui.removeButton.Visibility = 'Collapsed'; Set-DeepSeekWizardStatus $w.Tag.Ui '已移除保存的 key。' }
        Request-DeepSeekRefresh
    }
    & $up $ui.saveButton { Start-DeepSeekKeyCheck }
    $ui.altLink.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Close-DeepSeekKeyWizard; try { Open-ProviderApp 'deepseek' } catch { } })
    $ui.keyBox.Add_PasswordChanged({
        $w = $script:DeepSeekWizardWin; if (-not $w -or $w.Tag.Busy) { return }
        $u = $w.Tag.Ui; $k = [string]$u.keyBox.Password
        if (-not $k) { Set-DeepSeekWizardStatus $u ''; return }
        $why = Test-DeepSeekKeyShape $k
        if ($why) { Set-DeepSeekWizardStatus $u $why '#FF9F0A' } else { Set-DeepSeekWizardStatus $u '格式没问题，点「验证并保存」。' '#30D158' }
    })
    $win.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { Close-DeepSeekKeyWizard } elseif ($e.Key -eq 'Return') { Start-DeepSeekKeyCheck } })
    $win.Add_MouseLeftButtonDown({ param($s, $e) try { $s.DragMove() } catch { } })
    $win.Add_Closed({
        param($s, $e)
        try { if ($s.Tag.Timer) { $s.Tag.Timer.Stop() }; if ($s.Tag.Client) { $s.Tag.Client.Dispose() } } catch { }
        if ($script:DeepSeekWizardWin -eq $s) { $script:DeepSeekWizardWin = $null }
    })
    $win.Add_ContentRendered({
        param($s, $e)
        $sh = $s.FindName('sheet')
        $sh.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-IslandAnimation 0.0 1.0 180 'out'))
        try { [void]$s.FindName('keyBox').Focus() } catch { }
    })
    $win.Show()
    try { $win.Activate() } catch { }
}

# Ask DeepSeek once whether the key works; asynchronous, so the window keeps
# responding. Only an accepted key is saved.
function Start-DeepSeekKeyCheck {
    $w = $script:DeepSeekWizardWin
    if (-not $w -or $w.Tag.Busy) { return }
    $u = $w.Tag.Ui
    $key = ([string]$u.keyBox.Password).Trim()
    $why = Test-DeepSeekKeyShape $key
    if ($why) { Set-DeepSeekWizardStatus $u $why '#FF9F0A'; return }
    $w.Tag.Busy = $true; $w.Tag.Key = $key
    $u.saveText.Text = '正在验证…'
    Set-DeepSeekWizardStatus $u '正在向 DeepSeek 确认这个 key…'
    try {
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(15)
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, 'https://api.deepseek.com/user/balance')
        $req.Headers.TryAddWithoutValidation('Authorization', 'Bearer ' + $key) | Out-Null
        $req.Headers.TryAddWithoutValidation('Accept', 'application/json') | Out-Null
        $req.Headers.TryAddWithoutValidation('User-Agent', 'JayOS-AI-Usage') | Out-Null
        $w.Tag.Client = $client
        $w.Tag.Task = $client.SendAsync($req)
    } catch {
        $w.Tag.Busy = $false; $u.saveText.Text = '验证并保存'
        Set-DeepSeekWizardStatus $u ('连接失败：' + $_.Exception.Message) '#FF453A'; return
    }
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(120)
    $t.Add_Tick({ param($s, $e) try { Complete-DeepSeekKeyCheck $s } catch { $s.Stop() } })
    $w.Tag.Timer = $t
    $t.Start()
}

function Complete-DeepSeekKeyCheck($Timer) {
    $w = $script:DeepSeekWizardWin
    if (-not $w) { $Timer.Stop(); return }
    $task = $w.Tag.Task
    if (-not $task -or -not $task.IsCompleted) { return }
    $Timer.Stop()
    $u = $w.Tag.Ui
    $w.Tag.Busy = $false
    $u.saveText.Text = '验证并保存'
    if ($task.IsFaulted -or $task.IsCanceled) {
        $msg = if ($task.IsCanceled) { '超时了' } else { [string]$task.Exception.InnerException.Message }
        Set-DeepSeekWizardStatus $u ('连不上 DeepSeek（' + $msg + '），检查网络后再试。') '#FF453A'
        return
    }
    $resp = $task.Result
    $code = [int]$resp.StatusCode
    if ($code -eq 401) { Set-DeepSeekWizardStatus $u 'DeepSeek 说这个 key 无效。确认复制的是完整的 sk- 开头那串，或新建一个。' '#FF453A'; return }
    if ($code -ne 200) { Set-DeepSeekWizardStatus $u ('DeepSeek 返回了 HTTP ' + $code + '，稍后再试。') '#FF453A'; return }
    $body = ''
    try { $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult() } catch { }
    $amount = $null; $cur = 'CNY'
    try {
        $j = $body | ConvertFrom-Json
        $info = @($j.balance_infos) | Where-Object { $_.currency -eq 'CNY' } | Select-Object -First 1
        if (-not $info) { $info = @($j.balance_infos) | Select-Object -First 1 }
        if ($info) { $amount = [double]$info.total_balance; $cur = [string]$info.currency }
    } catch { }
    try { Save-DeepSeekApiKey $w.Tag.Key } catch { Set-DeepSeekWizardStatus $u ('key 有效，但保存失败：' + $_.Exception.Message) '#FF453A'; return }
    $u.keyBox.Password = ''
    $sym = if ($cur -eq 'USD') { '$' } else { '¥' }
    $shown = if ($null -ne $amount) { ('已连接，当前余额 {0}{1:0.00}。卡片马上更新。' -f $sym, $amount) } else { '已连接。卡片马上更新。' }
    Set-DeepSeekWizardStatus $u $shown '#30D158'
    $u.saveText.Text = '完成'
    $u.saveButton.Tag = { Close-DeepSeekKeyWizard }
    Request-DeepSeekRefresh
    # Close on its own after a moment.
    $close = New-Object System.Windows.Threading.DispatcherTimer
    $close.Interval = [TimeSpan]::FromMilliseconds(1600)
    $close.Add_Tick({ param($s, $e) $s.Stop(); Close-DeepSeekKeyWizard })
    $close.Start()
}

# Refresh the DeepSeek card now (new or removed key).
function Request-DeepSeekRefresh {
    try { if (Get-Command Start-AllRefreshJobs -ErrorAction SilentlyContinue) { Start-AllRefreshJobs -Kind 'DeepSeekUsage' -Force } } catch { }
}

# "Sign in" for DeepSeek: the wizard (Open-ProviderApp 'deepseek' stays the
# fallback and the wizard's "改用 DeepSeek Harness" link).
function Show-DeepSeekSignIn {
    if (Get-Command Show-DeepSeekKeyWizard -ErrorAction SilentlyContinue) {
        try { Show-DeepSeekKeyWizard; return } catch { try { Write-Log ('deepseek wizard: ' + $_.Exception.Message) } catch { } }
    }
    Open-ProviderApp 'deepseek'
}
