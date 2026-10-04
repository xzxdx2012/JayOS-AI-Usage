# Update.ps1 - "Check for updates": looks for a newer release of JayOS AI Usage
# on GitHub and installs it with the release's own Setup.exe (silent, into the
# folder the app runs from, keeping settings).
#
# Network work runs in a background runspace; a dispatcher timer picks up the
# result so the UI never blocks.

$script:UpdateRepo     = 'xzxdx2012/JayOS-AI-Usage'
$script:UpdateInfo     = $null    # newest release above this version: @{ Key; Version; Url; AssetName; Page }
$script:UpdateJob      = $null    # @{ PS; Handle; Kind = 'check' | 'download'; Manual; Dest }
$script:UpdatePollTimer = $null
$script:UpdateAutoTimer = $null

function Get-UpdateText([string]$Text) {
    try { return (Convert-I18nString $Text (Get-UiLanguage)) } catch { return $Text }
}

# '0.0.2 beta', 'v0.0.2-beta', 'v1.2.0' -> one comparable number.
# Pre-releases sort below the final release: alpha < beta < rc < final.
function ConvertTo-UpdateVersionKey([string]$Text) {
    if ($Text -notmatch '(\d+)\.(\d+)\.(\d+)(?:[\s\-\.]*([A-Za-z]+)\.?(\d*))?') { return $null }
    # Copy the groups first: the switch below runs its own regex matches.
    $maj = [long]$matches[1]; $min = [long]$matches[2]; $pat = [long]$matches[3]
    $label = [string]$matches[4]; $num = [string]$matches[5]
    $stage = switch -regex ($label) {
        '^(?i)a(lpha)?$'  { 1; break }
        '^(?i)b(eta)?$'   { 2; break }
        '^(?i)(rc|pre)$'  { 3; break }
        '^$'              { 4; break }
        default           { 0 }
    }
    $n = if ($num) { [long]$num } else { 0 }
    return ($maj * 1000000000000) + ($min * 100000000) + ($pat * 10000) + ($stage * 100) + $n
}

# 'v0.0.3-beta' -> '0.0.3 beta'
function Format-UpdateVersion([string]$Tag) {
    $v = $Tag -replace '^[vV]', ''
    return ($v -replace '-', ' ')
}

# Results show for a few seconds in the panel header where "Live" normally is
# (no pop-up windows). Seconds = 0 keeps the text until the next notice.
$script:UpdateNoticeUntil = [DateTime]::MinValue
$script:UpdateNoticePrev = $null
$script:UpdateNoticeTimer = $null
function Test-UpdateNoticeActive { return ([DateTime]::UtcNow -lt $script:UpdateNoticeUntil) }

function Show-UpdateNotice([string]$Text, [int]$Seconds = 5) {
    if (-not $script:window) { return }
    $tb = $script:window.FindName('chromeStateText')
    if (-not $tb) { return }
    if (-not (Test-UpdateNoticeActive)) { $script:UpdateNoticePrev = [string]$tb.Text }
    $script:UpdateNoticeUntil = if ($Seconds -gt 0) { [DateTime]::UtcNow.AddSeconds($Seconds) } else { [DateTime]::MaxValue }
    $tb.Text = Get-UpdateText $Text
    if (-not $script:UpdateNoticeTimer) {
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromMilliseconds(500)
        $t.add_Tick({
            param($s, $e)
            if (Test-UpdateNoticeActive) { return }
            $s.Stop()
            $box = $script:window.FindName('chromeStateText')
            if ($box -and $null -ne $script:UpdateNoticePrev) { $box.Text = $script:UpdateNoticePrev }
            try { Invoke-UiTranslate } catch { }
        })
        $script:UpdateNoticeTimer = $t
    }
    if ($Seconds -gt 0) { $script:UpdateNoticeTimer.Start() } else { $script:UpdateNoticeTimer.Stop() }
}

function Sync-UpdateIndicators {
    $info = $script:UpdateInfo
    $busy = ($script:UpdateJob -and $script:UpdateJob.Kind -eq 'download')
    if ($script:window) {
        $dot = $script:window.FindName('chromeUpdateDot')
        if ($dot) { $dot.Visibility = if ($info) { 'Visible' } else { 'Collapsed' } }
        $btn = $script:window.FindName('chromeUpdate')
        if ($btn) {
            $tip = if ($busy) { 'Downloading update…' } elseif ($info) { 'Update to {0}' -f $info.Version } else { 'Check for updates' }
            $btn.ToolTip = Get-UpdateText $tip
        }
        $icon = $script:window.FindName('chromeUpdateIcon')
        if ($icon) {
            if ($busy) {
                $a = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.25, [System.Windows.Duration]([TimeSpan]::FromMilliseconds(600)))
                $a.AutoReverse = $true
                $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
                $icon.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
            } else {
                $icon.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
                $icon.Opacity = 1.0
            }
            $icon.Stroke = NewBrush $(if ($info) { '#30D158' } else { '#C7C7CC' })
        }
    }
    if ($script:miUpdate) {
        $script:miUpdate.Text = if ($info) { 'Update to {0}' -f $info.Version } else { 'Check for updates' }
        try { Invoke-MenuTranslate @($script:miUpdate) } catch { }
    }
}

function Start-UpdatePollTimer {
    if (-not $script:UpdatePollTimer) {
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromMilliseconds(300)
        $t.add_Tick({ try { Invoke-UpdateJobPoll } catch { } })
        $script:UpdatePollTimer = $t
    }
    if (-not $script:UpdatePollTimer.IsEnabled) { $script:UpdatePollTimer.Start() }
}

function Start-UpdateCheck([switch]$Manual) {
    if ($script:UpdateJob) { return }
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript({
        param($Repo)
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $headers = @{ 'Accept' = 'application/vnd.github+json' }
        $rels = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=20" -Headers $headers -UserAgent 'JayOS-AI-Usage' -TimeoutSec 20 -UseBasicParsing
        foreach ($rel in @($rels)) {
            if ($rel.draft) { continue }
            $asset = @($rel.assets) | Where-Object { $_.name -like '*Setup*.exe' } | Select-Object -First 1
            if (-not $asset) { continue }
            [pscustomobject]@{
                Tag = [string]$rel.tag_name; Url = [string]$asset.browser_download_url
                AssetName = [string]$asset.name; Size = [long]$asset.size; Page = [string]$rel.html_url
            }
        }
    }).AddArgument($script:UpdateRepo)
    $script:UpdateJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Kind = 'check'; Manual = [bool]$Manual }
    Start-UpdatePollTimer
}

function Start-UpdateDownload {
    $info = $script:UpdateInfo
    if (-not $info -or $script:UpdateJob) { return }
    $dest = Join-Path ([IO.Path]::GetTempPath()) $info.AssetName
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript({
        param($Url, $Dest)
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force }
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UserAgent 'JayOS-AI-Usage' -TimeoutSec 120 -UseBasicParsing
        (Get-Item -LiteralPath $Dest).Length
    }).AddArgument($info.Url).AddArgument($dest)
    $script:UpdateJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Kind = 'download'; Manual = $true; Dest = $dest; Size = $info.Size }
    Sync-UpdateIndicators
    Start-UpdatePollTimer
}

function Invoke-UpdateJobPoll {
    $job = $script:UpdateJob
    if (-not $job) { if ($script:UpdatePollTimer) { $script:UpdatePollTimer.Stop() }; return }
    if (-not $job.Handle.IsCompleted) { return }
    $script:UpdateJob = $null
    if ($script:UpdatePollTimer) { $script:UpdatePollTimer.Stop() }

    $result = $null; $failed = $false
    try {
        $result = $job.PS.EndInvoke($job.Handle)
        if ($job.PS.HadErrors -and (-not $result -or $result.Count -eq 0)) { $failed = $true }
    } catch {
        $failed = $true
        try { Write-Log "Update $($job.Kind) failed - $($_.Exception.Message)" } catch { }
    } finally {
        try { $job.PS.Dispose() } catch { }
    }

    if ($job.Kind -eq 'check') {
        $current = ConvertTo-UpdateVersionKey $script:DisplayVersion
        $best = $null
        foreach ($r in @($result)) {
            if (-not $r) { continue }
            $k = ConvertTo-UpdateVersionKey ([string]$r.Tag)
            if ($null -eq $k -or $null -eq $current -or $k -le $current) { continue }
            if (-not $best -or $k -gt $best.Key) {
                $best = @{ Key = $k; Version = (Format-UpdateVersion $r.Tag); Url = $r.Url; AssetName = $r.AssetName; Size = $r.Size; Page = $r.Page }
            }
        }
        if (-not $failed) { $script:UpdateInfo = $best }
        Sync-UpdateIndicators
        if ($job.Manual) {
            if ($script:UpdateInfo) { Show-UpdateNotice ('Update to {0}' -f $script:UpdateInfo.Version) 6 }
            elseif ($failed) { Show-UpdateNotice 'Update check failed' 6 }
            else { Show-UpdateNotice ('Up to date ({0})' -f $script:DisplayVersion) 5 }
        }
        return
    }

    # Download finished: hand over to the new Setup.exe. It closes this app,
    # installs over this folder (settings stay) and starts the new version.
    Sync-UpdateIndicators
    $len = 0L
    try { $len = [long](@($result)[-1]) } catch { }
    $ok = (-not $failed) -and (Test-Path -LiteralPath $job.Dest) -and $len -gt 500000 -and (-not $job.Size -or $len -eq [long]$job.Size)
    if (-not $ok) {
        Show-UpdateNotice 'Update download failed' 6
        return
    }
    try {
        Show-UpdateNotice 'Installing update…' 0
        $dir = [string]$script:AppDir
        Start-Process -FilePath $job.Dest -ArgumentList @('/S', ('"/D={0}"' -f $dir.TrimEnd('\')))
    } catch {
        try { Write-Log "Update start failed - $($_.Exception.Message)" } catch { }
        Show-UpdateNotice 'Update download failed' 6
    }
}

# Header button / menu item: with a newer version already found (green dot),
# download and install it; otherwise check now and say what was found.
function Invoke-UpdateButton {
    if ($script:UpdateJob) { return }
    if ($script:UpdateInfo) {
        Show-UpdateNotice 'Downloading update…' 0
        Start-UpdateDownload
    } else {
        Show-UpdateNotice 'Checking for updates…' 0
        Start-UpdateCheck -Manual
    }
}

# Quiet check shortly after start, then every 6 hours; only lights the dot.
function Start-UpdateAutoCheck {
    if ($script:UpdateAutoTimer) { return }
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromSeconds(20)
    $t.add_Tick({
        param($s, $e)
        $s.Interval = [TimeSpan]::FromHours(6)
        try { if (-not $script:UpdateInfo) { Start-UpdateCheck } } catch { }
    })
    $script:UpdateAutoTimer = $t
    $t.Start()
}
