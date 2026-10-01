# Config.ps1 - shared constants, pricing table, color themes, and default settings

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$script:PollSeconds    = 180
$script:TickSeconds    = 30
$script:BarTrackWidth  = 250.0
$script:CompactBarWidth = 120.0
$script:WarnPct        = 80
$script:CritPct        = 95
$script:WorkdayStartHour = 8
$script:WorkdayEndHour   = 18
$script:AppVersion     = '0.0.1'

# ---------------------------------------------------------------------------
# Shared provider health vocabulary
#
# Every provider reports auth health with the SAME words, so one predicate
# decides what "broken" means everywhere:
#   init | ok | stale | auth | notoken
#
# 'auth'/'notoken' mean the user must act, so they must reach the UI. Codex
# shipped without any such contract and swallowed a 401 for 13 days: its local
# logs still parsed, so it reported healthy while the live quota was dead. Any
# new provider must set an auth state and message rather than returning $null.
# ---------------------------------------------------------------------------
function Test-ProviderAuthFailed {
    param([string]$AuthState)

    return ($AuthState -eq 'auth' -or $AuthState -eq 'notoken')
}

# WSL can contain the current Codex and Claude state even when the overlay runs
# in Windows. Discovery is cached because every poll process can ask for it more
# than once, and no WSL problem may interrupt the poll.
#
# We do NOT read WSL data directly via the \\wsl.localhost\<distro> UNC path:
# that UNC is unreliable from background processes (Test-Path returns False
# even while the distro is running), so the feature would silently no-op.
# Instead we shell into wsl.exe and have the distro itself copy (cp -u, so
# it is a cheap incremental sync) its .claude/.codex state into a local
# Windows mirror directory under $script:AppDir, then treat that mirror as
# a home root. wsl.exe interop and WSL-side writes to /mnt/c always work.
$script:WslHomeRootsCache = $null

function Get-WslHomeRoots {
    if ($null -ne $script:WslHomeRootsCache) {
        return @($script:WslHomeRootsCache)
    }

    if (-not $script:AppDir) {
        $script:WslHomeRootsCache = @()
        return @()
    }

    $mirrorBase = Join-Path $script:AppDir 'wsl-mirror'
    $marker = Join-Path $mirrorBase '.last-sync'
    $roots = [System.Collections.Generic.List[string]]::new()

    try {
        # Stampede guard: multiple background poll jobs can call this
        # concurrently. Only pay for the WSL sync once per 60 seconds;
        # everyone else just reads whatever is already in the mirror.
        $needsSync = $true
        try {
            if (Test-Path -LiteralPath $marker -PathType Leaf -ErrorAction SilentlyContinue) {
                $markerItem = Get-Item -LiteralPath $marker -ErrorAction Stop
                $ageSeconds = ((Get-Date).ToUniversalTime() - $markerItem.LastWriteTimeUtc).TotalSeconds
                if ($ageSeconds -lt 60) {
                    $needsSync = $false
                }
            }
        } catch { }

        if ($needsSync) {
            $process = $null
            try {
                $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
                if ($wsl) {
                    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
                    $startInfo.FileName = $wsl.Source
                    $startInfo.Arguments = '--list --quiet'
                    $startInfo.UseShellExecute = $false
                    $startInfo.CreateNoWindow = $true
                    $startInfo.RedirectStandardOutput = $true
                    $startInfo.RedirectStandardError = $true
                    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::Unicode

                    $process = [System.Diagnostics.Process]::new()
                    $process.StartInfo = $startInfo
                    $distros = @()
                    if ($process.Start() -and $process.WaitForExit(1500)) {
                        $distroOutput = $process.StandardOutput.ReadToEnd()
                        $distros = @($distroOutput -split "`n") | ForEach-Object {
                            ([string]$_).Replace([string][char]0, '').Trim()
                        } | Where-Object { $_ -and $_ -notmatch '^docker' }
                    } else {
                        if ($process -and -not $process.HasExited) {
                            try { $process.Kill() } catch { }
                        }
                    }
                    if ($process) { $process.Dispose() }
                    $process = $null

                    if ($distros.Count -gt 0) {
                        try { [void](New-Item -ItemType Directory -Force -Path $mirrorBase -ErrorAction Stop) } catch { }

                        $mirrorEscaped = $mirrorBase.Replace("'", "'\''")
                        $syncScriptTemplate = 'MB=$(wslpath -u ''{0}''); for h in /home/*; do u=$(basename \"$h\"); if [ -d \"$h/.claude\" ] || [ -d \"$h/.codex\" ]; then d=\"$MB/{1}/$u\"; mkdir -p \"$d/.claude\" \"$d/.codex\"; cp -u --preserve=timestamps \"$h/.claude/.credentials.json\" \"$d/.claude/\" 2>/dev/null; cp -u -r --preserve=timestamps \"$h/.claude/projects\" \"$d/.claude/\" 2>/dev/null; cp -u -r --preserve=timestamps \"$h/.codex/sessions\" \"$d/.codex/\" 2>/dev/null; fi; done'

                        foreach ($distro in $distros) {
                            $syncScript = $syncScriptTemplate -f $mirrorEscaped, $distro
                            $syncProcess = $null
                            try {
                                $syncStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
                                $syncStartInfo.FileName = $wsl.Source
                                $syncStartInfo.Arguments = '-d ' + $distro + ' -e /bin/sh -c "' + $syncScript + '"'
                                $syncStartInfo.UseShellExecute = $false
                                $syncStartInfo.CreateNoWindow = $true
                                $syncStartInfo.RedirectStandardOutput = $true
                                $syncStartInfo.RedirectStandardError = $true

                                $syncProcess = [System.Diagnostics.Process]::new()
                                $syncProcess.StartInfo = $syncStartInfo
                                if (-not $syncProcess.Start() -or -not $syncProcess.WaitForExit(45000)) {
                                    if ($syncProcess -and -not $syncProcess.HasExited) {
                                        try { $syncProcess.Kill() } catch { }
                                    }
                                    # Partial mirror is fine; cp -u resumes next poll.
                                }
                            } catch {
                            } finally {
                                if ($syncProcess) { $syncProcess.Dispose() }
                            }
                        }

                        try {
                            [void](New-Item -ItemType Directory -Force -Path $mirrorBase -ErrorAction Stop)
                            Set-Content -LiteralPath $marker -Value ((Get-Date).ToUniversalTime().ToString('o')) -ErrorAction Stop
                        } catch { }
                    }
                }
            } catch {
            } finally {
                if ($process) { $process.Dispose() }
            }
        }

        # Build the result from whatever is in the mirror, regardless of
        # whether this call's own sync (if any) succeeded.
        try {
            if (Test-Path -LiteralPath $mirrorBase -PathType Container -ErrorAction SilentlyContinue) {
                foreach ($distroDir in @(Get-ChildItem -LiteralPath $mirrorBase -Directory -ErrorAction SilentlyContinue)) {
                    foreach ($userDir in @(Get-ChildItem -LiteralPath $distroDir.FullName -Directory -ErrorAction SilentlyContinue)) {
                        $hasClaude = Test-Path -LiteralPath (Join-Path $userDir.FullName '.claude') -PathType Container -ErrorAction SilentlyContinue
                        $hasCodex = Test-Path -LiteralPath (Join-Path $userDir.FullName '.codex') -PathType Container -ErrorAction SilentlyContinue
                        if ($hasClaude -or $hasCodex) {
                            [void]$roots.Add($userDir.FullName)
                        }
                    }
                }
            }
        } catch { }

        $script:WslHomeRootsCache = @($roots | Select-Object -Unique)
        return @($script:WslHomeRootsCache)
    } catch {
        $script:WslHomeRootsCache = @()
        return @()
    }
}


# ---------------------------------------------------------------------------
# Pricing table
# ---------------------------------------------------------------------------
$script:PricesAsOf = '2026-06-01'
$script:Prices = @{
    fable  = @{ in = 10.0; out = 50.0; cw = 12.50; cr = 1.00 }
    opus   = @{ in = 15.0; out = 75.0; cw = 18.75; cr = 1.50 }
    sonnet = @{ in = 3.0;  out = 15.0; cw = 3.75;  cr = 0.30 }
    haiku  = @{ in = 1.0;  out = 5.0;  cw = 1.25;  cr = 0.10 }
}

$script:CodexPricesAsOf = '2026-06-26'
$script:CodexPrices = @{
    'gpt-5.5' = @{ in = 5.00; cachedIn = 0.50; out = 30.00 }
    default   = @{ in = 5.00; cachedIn = 0.50; out = 30.00 }
}

# ---------------------------------------------------------------------------
# User-Agent detection
# ---------------------------------------------------------------------------
$script:UA = 'claude-code/2.1.0'
try { $v = (& claude --version) 2>$null; if ($v -match '(\d+\.\d+\.\d+)') { $script:UA = "claude-code/$($matches[1])" } } catch { }

# ---------------------------------------------------------------------------
# Color themes
# ---------------------------------------------------------------------------
$script:Themes = [ordered]@{
    # Default: neutral graphite, Apple-style. Meters read in near-white and only
    # turn orange / red as a limit nears (see Set-SectionBar).
    'Graphite' = @{
        BgC1 = '#161618'; BgC2 = '#0E0E10'; BorderC1 = '#2C2C2E'; BrandLabelFg = '#8E8E93'
        FivehColors = '#C7C7CC','#F2F2F7'
        WeekColors  = '#C7C7CC','#F2F2F7'
        FabColors   = '#AEAEB2','#E5E5EA'
        OpusColors  = '#AEAEB2','#E5E5EA'
        FivehFg     = '#F5F5F7'
        WeekFg      = '#F5F5F7'
        FabFg       = '#F5F5F7'
        OpusFg      = '#F5F5F7'
        Stripe      = '#F2F2F7','#C7C7CC','#8E8E93','#636366'
        StateBars   = $true
    }
    'Deep Space' = @{
        BgC1 = '#0F172A'; BgC2 = '#080C18'; BorderC1 = '#1E3A5F'; BrandLabelFg = '#5C8AAA'
        FivehColors = '#0369A1','#38BDF8'
        WeekColors  = '#C2410C','#FB923C'
        FabColors   = '#6D28D9','#C084FC'
        OpusColors  = '#92400E','#FDE047'
        FivehFg     = '#38BDF8'
        WeekFg      = '#FB923C'
        FabFg       = '#C084FC'
        OpusFg      = '#FDE047'
        Stripe      = '#38BDF8','#818CF8','#E879F9','#FB923C'
    }
    'Ocean' = @{
        BgC1 = '#0F1F2E'; BgC2 = '#091420'; BorderC1 = '#1A4060'; BrandLabelFg = '#5C8AAA'
        FivehColors = '#0F766E','#2DD4BF'
        WeekColors  = '#9D174D','#FB7185'
        FabColors   = '#1E40AF','#93C5FD'
        OpusColors  = '#92400E','#FCD34D'
        FivehFg     = '#2DD4BF'
        WeekFg      = '#FB7185'
        FabFg       = '#93C5FD'
        OpusFg      = '#FCD34D'
        Stripe      = '#2DD4BF','#93C5FD','#FB7185','#FCD34D'
    }
    'Mono' = @{
        BgC1 = '#111111'; BgC2 = '#080808'; BorderC1 = '#2A2A2A'; BrandLabelFg = '#909090'
        FivehColors = '#1E3A5F','#94A3B8'
        WeekColors  = '#1E3A5F','#94A3B8'
        FabColors   = '#1E3A5F','#94A3B8'
        OpusColors  = '#1E3A5F','#94A3B8'
        FivehFg     = '#94A3B8'
        WeekFg      = '#94A3B8'
        FabFg       = '#94A3B8'
        OpusFg      = '#94A3B8'
        Stripe      = '#334155','#64748B','#94A3B8','#64748B'
    }
    'Black & White' = @{
        BgC1 = '#0A0A0A'; BgC2 = '#000000'; BorderC1 = '#2A2A2A'; BrandLabelFg = '#B0B0B0'
        FivehColors = '#3A3A3A','#E8E8E8'
        WeekColors  = '#3A3A3A','#E8E8E8'
        FabColors   = '#3A3A3A','#E8E8E8'
        OpusColors  = '#3A3A3A','#9A9A9A'
        FivehFg     = '#E8E8E8'
        WeekFg      = '#E8E8E8'
        FabFg       = '#E8E8E8'
        OpusFg      = '#E8E8E8'
        Stripe      = '#E8E8E8','#B0B0B0','#7A7A7A','#4A4A4A'
    }
    'Catppuccin' = @{
        BgC1 = '#1E1E2E'; BgC2 = '#11111B'; BorderC1 = '#313244'; BrandLabelFg = '#9399B2'
        FivehColors = '#313E5F','#89B4FA'
        WeekColors  = '#6E4A2E','#FAB387'
        FabColors   = '#4B3A6B','#CBA6F7'
        OpusColors  = '#6E5E2E','#F9E2AF'
        FivehFg     = '#89B4FA'
        WeekFg      = '#FAB387'
        FabFg       = '#CBA6F7'
        OpusFg      = '#F9E2AF'
        Stripe      = '#89B4FA','#CBA6F7','#F5C2E7','#FAB387'
    }
    'Synthwave' = @{
        BgC1 = '#241B2F'; BgC2 = '#0D0221'; BorderC1 = '#472066'; BrandLabelFg = '#B383E0'
        FivehColors = '#0E4F5C','#05D9E8'
        WeekColors  = '#7A0F52','#FF6AC1'
        FabColors   = '#4B1F8C','#B388FF'
        OpusColors  = '#8A106B','#FE53BB'
        FivehFg     = '#05D9E8'
        WeekFg      = '#FF6AC1'
        FabFg       = '#B388FF'
        OpusFg      = '#FE53BB'
        Stripe      = '#05D9E8','#B388FF','#FF6AC1','#FE53BB'
    }
    'Nord' = @{
        BgC1 = '#2E3440'; BgC2 = '#242933'; BorderC1 = '#434C5E'; BrandLabelFg = '#7B88A1'
        FivehColors = '#3B4A5A','#88C0D0'
        WeekColors  = '#6E4636','#D08770'
        FabColors   = '#4C4257','#B48EAD'
        OpusColors  = '#6E6142','#EBCB8B'
        FivehFg     = '#88C0D0'
        WeekFg      = '#D08770'
        FabFg       = '#B48EAD'
        OpusFg      = '#EBCB8B'
        Stripe      = '#8FBCBB','#88C0D0','#81A1C1','#5E81AC'
    }
    'Dracula' = @{
        BgC1 = '#282A36'; BgC2 = '#1A1B23'; BorderC1 = '#44475A'; BrandLabelFg = '#6272A4'
        FivehColors = '#1F5560','#8BE9FD'
        WeekColors  = '#7A2F5C','#FF79C6'
        FabColors   = '#4B3B7A','#BD93F9'
        OpusColors  = '#5A6E2E','#F1FA8C'
        FivehFg     = '#8BE9FD'
        WeekFg      = '#FF79C6'
        FabFg       = '#BD93F9'
        OpusFg      = '#F1FA8C'
        Stripe      = '#8BE9FD','#BD93F9','#FF79C6','#50FA7B'
    }
    'Rose Sunset' = @{
        BgC1 = '#2A2436'; BgC2 = '#1C1622'; BorderC1 = '#504357'; BrandLabelFg = '#C08497'
        FivehColors = '#7A3A32','#FF9E80'
        WeekColors  = '#7A5A1E','#F6C177'
        FabColors   = '#7A2F52','#EB6F92'
        OpusColors  = '#6E5A2E','#F2D5A0'
        FivehFg     = '#FF9E80'
        WeekFg      = '#F6C177'
        FabFg       = '#EB6F92'
        OpusFg      = '#F2D5A0'
        Stripe      = '#FF9E80','#EB6F92','#C4A7E7','#F6C177'
    }
}

# Cursor bar color per theme. Cursor's bar is painted at refresh time (not via the
# shared bar loop), so without this it stayed green in every theme. Kept distinct
# from that theme's Claude/Codex hues for variety.
$script:CursorPalette = [ordered]@{
    'Graphite'      = @('#C7C7CC','#F2F2F7')
    'Deep Space'    = @('#4338CA','#818CF8')
    'Ocean'         = @('#0E7490','#22D3EE')
    'Mono'          = @('#475569','#94A3B8')
    'Black & White' = @('#6B7280','#E5E7EB')
    'Catppuccin'    = @('#40A02B','#A6E3A1')
    'Synthwave'     = @('#0A8F5A','#3DF5A0')
    'Nord'          = @('#5E7A4E','#A3BE8C')
    'Dracula'       = @('#1F8A4C','#50FA7B')
    'Rose Sunset'   = @('#4D7C0F','#BEF264')
}
foreach ($k in $script:CursorPalette.Keys) {
    if ($script:Themes.Contains($k)) {
        $script:Themes[$k].CursorColors = $script:CursorPalette[$k]
        $script:Themes[$k].CursorFg     = $script:CursorPalette[$k][1]
    }
}
$script:CursorColorsCur = @('#065F46','#34D399')
$script:AccentCursor = '#34D399'
$script:AccentFiveh  = '#38BDF8'
$script:AccentWeek   = '#FB923C'
$script:AccentFab    = '#C084FC'
$script:AccentOpus   = '#FDE047'
$script:AccentGrok   = '#FDE68A'

# Grok bar color per theme. Distinct from Claude/Codex/Cursor hues.
$script:GrokPalette = [ordered]@{
    'Graphite'      = @('#C7C7CC','#F2F2F7')
    'Deep Space'    = @('#A16207','#FDE68A')
    'Ocean'         = @('#B45309','#FCD34D')
    'Mono'          = @('#57534E','#D6D3D1')
    'Black & White' = @('#737373','#F5F5F5')
    'Catppuccin'    = @('#DF8E1D','#F9E2AF')
    'Synthwave'     = @('#F59E0B','#FDE047')
    'Nord'          = @('#EBCB8B','#ECEFF4')
    'Dracula'       = @('#F1FA8C','#F8F8F2')
    'Rose Sunset'   = @('#F6C177','#FEF3C7')
}
foreach ($k in $script:GrokPalette.Keys) {
    if ($script:Themes.Contains($k)) {
        $script:Themes[$k].GrokColors = $script:GrokPalette[$k]
        $script:Themes[$k].GrokFg     = $script:GrokPalette[$k][1]
    }
}
$script:GrokColorsCur = @('#A16207','#FDE68A')


# ---------------------------------------------------------------------------
# Default config
# ---------------------------------------------------------------------------
$script:Cfg = @{
    Left        = $null
    Top         = $null
    Opacity     = 1.0
    StartHidden = $false
    ShowStats   = $true
    Theme       = 'Graphite'
    ShowAlerts  = $true    # threshold balloon alerts
    ShowGraph   = $false   # history sparkline (off by default to keep the panel compact)
    AlertState = @{}
}
