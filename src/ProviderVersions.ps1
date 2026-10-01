# ProviderVersions.ps1 - cached CLI / Cursor app versions for HUD badges.
# Prefer real resolved binaries (Get-Command / known paths / FileVersionInfo).
# Never spawn on every paint — TTL cache. Show '--' when unknown.

$script:ProviderVersionCache = @{}
$script:ProviderVersionCacheAt = @{}
if (-not $script:ProviderVersionTtlSec) { $script:ProviderVersionTtlSec = 600 }
$script:ProviderVersionMutedFg = '#5C7A96'

function Format-ProviderVersionLabel {
    param([string]$Raw)

    if ([string]::IsNullOrWhiteSpace($Raw)) { return '--' }
    $line = (($Raw -split '\r?\n') | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1)
    if (-not $line) { return '--' }
    $s = $line.Trim()
    if ($s -match '(\d+\.\d+\.\d+(?:\.\d+)?)') { return $Matches[1] }
    if ($s.Length -gt 28) { return $s.Substring(0, 28) }
    return $s
}

function Get-CachedProviderVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][scriptblock]$Resolver
    )

    $now = [datetime]::UtcNow
    if ($script:ProviderVersionCache.ContainsKey($Key) -and $script:ProviderVersionCacheAt.ContainsKey($Key)) {
        $age = ($now - [datetime]$script:ProviderVersionCacheAt[$Key]).TotalSeconds
        if ($age -ge 0 -and $age -lt [double]$script:ProviderVersionTtlSec) {
            return [string]$script:ProviderVersionCache[$Key]
        }
    }

    $val = '--'
    try {
        $resolved = & $Resolver
        $val = Format-ProviderVersionLabel ([string]$resolved)
    } catch {
        $val = '--'
    }
    if ([string]::IsNullOrWhiteSpace($val)) { $val = '--' }
    $script:ProviderVersionCache[$Key] = $val
    $script:ProviderVersionCacheAt[$Key] = $now
    return $val
}

function Clear-ProviderVersionCache {
    $script:ProviderVersionCache = @{}
    $script:ProviderVersionCacheAt = @{}
}

function Invoke-ProviderCliVersion {
    param([Parameter(Mandatory = $true)][string]$ExePath)

    if (-not $ExePath -or -not (Test-Path -LiteralPath $ExePath)) { return $null }
    try {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = & $ExePath --version 2>&1 | Out-String
        $ErrorActionPreference = $prev
        return $out
    } catch {
        return $null
    }
}

function Get-ProviderCliVersionCached {
    param([Parameter(Mandatory = $true)][string]$CliName)

    Get-CachedProviderVersion -Key ("cli:" + $CliName.ToLowerInvariant()) -Resolver {
        if (-not (Get-Command Resolve-ProviderLoginCli -ErrorAction SilentlyContinue)) { return $null }
        $resolved = Resolve-ProviderLoginCli $CliName
        if (-not $resolved -or -not $resolved.Path) { return $null }
        Invoke-ProviderCliVersion $resolved.Path
    }
}

function Resolve-CursorAppExePath {
    $candidates = [System.Collections.Generic.List[string]]::new()
    $cmd = Get-Command -Name cursor -ErrorAction SilentlyContinue | Select-Object -First 1
    $cmdPath = $null
    if ($cmd) {
        if ($cmd.PSObject.Properties['Source'] -and $cmd.Source) { $cmdPath = [string]$cmd.Source }
        elseif ($cmd.PSObject.Properties['Path'] -and $cmd.Path) { $cmdPath = [string]$cmd.Path }
    }
    if ($cmdPath) {
        [void]$candidates.Add($cmdPath)
        # cursor.cmd lives under resources\app\bin — walk up to install root Cursor.exe
        try {
            $dir = Split-Path -Parent $cmdPath
            for ($i = 0; $i -lt 5 -and $dir; $i++) {
                $exe = Join-Path $dir 'Cursor.exe'
                [void]$candidates.Add($exe)
                $dir = Split-Path -Parent $dir
            }
        } catch { }
    }
    $pf = ${env:ProgramFiles}
    $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    foreach ($p in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\cursor\Cursor.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Cursor\Cursor.exe'),
        $(if ($pf) { Join-Path $pf 'cursor\Cursor.exe' }),
        $(if ($pf) { Join-Path $pf 'Cursor\Cursor.exe' }),
        $(if ($pf86) { Join-Path $pf86 'cursor\Cursor.exe' }),
        $(if ($pf86) { Join-Path $pf86 'Cursor\Cursor.exe' })
    )) {
        if ($p) { [void]$candidates.Add($p) }
    }
    foreach ($p in $candidates) {
        if ($p -and ([IO.Path]::GetFileName($p) -ieq 'Cursor.exe') -and (Test-Path -LiteralPath $p)) { return $p }
    }
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Get-CursorPackageJsonVersion {
    param([string]$ExeOrCmdPath)
    if (-not $ExeOrCmdPath) { return $null }
    try {
        $dir = Split-Path -Parent $ExeOrCmdPath
        for ($i = 0; $i -lt 6 -and $dir; $i++) {
            $pkg = Join-Path $dir 'resources\app\package.json'
            if (Test-Path -LiteralPath $pkg) {
                $raw = Get-Content -LiteralPath $pkg -Raw -ErrorAction Stop
                if ($raw -match '"version"\s*:\s*"([^"]+)"') { return $Matches[1] }
            }
            $pkg2 = Join-Path $dir 'package.json'
            if ((Split-Path -Leaf $dir) -eq 'app' -and (Test-Path -LiteralPath $pkg2)) {
                $raw = Get-Content -LiteralPath $pkg2 -Raw -ErrorAction Stop
                if ($raw -match '"version"\s*:\s*"([^"]+)"') { return $Matches[1] }
            }
            $dir = Split-Path -Parent $dir
        }
    } catch { }
    return $null
}

function Get-CursorAppVersionCached {
    Get-CachedProviderVersion -Key 'app:cursor' -Resolver {
        $exe = Resolve-CursorAppExePath
        if ($exe -and ([IO.Path]::GetFileName($exe) -ieq 'Cursor.exe')) {
            try {
                $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
                foreach ($cand in @($info.ProductVersion, $info.FileVersion)) {
                    if ($cand) {
                        $label = Format-ProviderVersionLabel ([string]$cand)
                        if ($label -ne '--') { return $label }
                    }
                }
            } catch { }
            $fromPkg = Get-CursorPackageJsonVersion $exe
            if ($fromPkg) { return $fromPkg }
        }
        $cmd = Get-Command -Name cursor -ErrorAction SilentlyContinue | Select-Object -First 1
        $cmdPath = $null
        if ($cmd) {
            if ($cmd.Source) { $cmdPath = [string]$cmd.Source } elseif ($cmd.Path) { $cmdPath = [string]$cmd.Path }
        }
        $fromPkg = Get-CursorPackageJsonVersion $cmdPath
        if ($fromPkg) { return $fromPkg }
        return $null
    }
}


function Format-ProviderPlanLabel {
    param($Raw)
    if ($null -eq $Raw) { return $null }
    $s = ([string]$Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($s) -or $s -eq '--' -or $s -eq 'null') { return $null }
    # membershipType / plan_type often snake or lower: pro, pro_plus, plus
    if ($s -match '^[A-Za-z0-9]+(?:[_-][A-Za-z0-9]+)*$') {
        $parts = $s -split '[_-]'
        $nice = foreach ($part in $parts) {
            if (-not $part) { continue }
            $part.Substring(0, 1).ToUpper() + $part.Substring(1).ToLower()
        }
        return ($nice -join ' ')
    }
    return $s
}

function Format-ProviderVersionPlanBadge {
    param(
        [string]$Version,
        [string]$Plan
    )
    $ver = if ([string]::IsNullOrWhiteSpace($Version)) { '--' } else { $Version.Trim() }
    $plan = Format-ProviderPlanLabel $Plan
    if (-not $plan) { return $ver }
    return ('{0} · {1}' -f $ver, $plan)
}


function Get-ProviderStatNote {
    # Hashtable + PSCustomObject reader (CodexStats is a Hashtable from Measure-CodexStats).
    # Prefer this over $obj.PSObject.Properties['X'], which misses Hashtable keys.
    param($Obj, [string]$Name)
    if ($null -eq $Obj -or -not $Name) { return $null }
    if (Get-Command Get-OverlayStatNote -ErrorAction SilentlyContinue) {
        return Get-OverlayStatNote $Obj $Name
    }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] }
        foreach ($k in @($Obj.Keys)) {
            if ([string]$k -eq $Name) { return $Obj[$k] }
        }
        return $null
    }
    if ($Obj.PSObject -and $Obj.PSObject.Properties[$Name]) {
        return $Obj.PSObject.Properties[$Name].Value
    }
    return $null
}

function Get-ProviderPlanLabel {
    param([Parameter(Mandatory = $true)][string]$Provider)

    switch -Regex ($Provider) {
        '^(?i)cursor$' {
            $sum = $script:SummaryData
            if ($sum -and $sum.membershipType) {
                return Format-ProviderPlanLabel $sum.membershipType
            }
            if (Get-Command Get-CursorPlanUsageFromSummary -ErrorAction SilentlyContinue) {
                $plan = Get-CursorPlanUsageFromSummary $sum
                if ($plan -and $plan.MembershipType) {
                    return Format-ProviderPlanLabel $plan.MembershipType
                }
            }
            return $null
        }
        '^(?i)grok$' {
            $s = $script:GrokUsage
            if (-not $s) { return $null }
            return Format-ProviderPlanLabel (Get-ProviderStatNote $s 'PlanType')
        }
        '^(?i)codex$' {
            $s = $script:CodexStats
            if (-not $s) { return $null }
            return Format-ProviderPlanLabel (Get-ProviderStatNote $s 'PlanType')
        }
        '^(?i)claude$' {
            # No stable plan tier on ClaudeIdentity today — omit rather than invent.
            $id = $script:ClaudeIdentity
            if (-not $id) { return $null }
            foreach ($name in @('Plan', 'PlanType', 'Subscription', 'Tier')) {
                if ($id.PSObject.Properties[$name] -and $id.$name) {
                    return Format-ProviderPlanLabel $id.$name
                }
            }
            return $null
        }
        default { return $null }
    }
}

function Update-ProviderVersionLabels {
    if (-not $script:window) { return }
    $muted = if ($script:ProviderVersionMutedFg) { $script:ProviderVersionMutedFg } else { '#5C7A96' }

    $claudeShown = $true
    if (Get-Command Test-ClaudeSectionVisible -ErrorAction SilentlyContinue) {
        $claudeShown = [bool](Test-ClaudeSectionVisible)
    }

    $specs = @(
        @{ El = 'claudeVersionText'; Provider = 'claude'; Show = $claudeShown; Get = { Get-ProviderCliVersionCached 'claude' } }
        @{ El = 'codexVersionText';  Provider = 'codex';  Show = $true;       Get = { Get-ProviderCliVersionCached 'codex' } }
        @{ El = 'cursorVersionText'; Provider = 'cursor'; Show = $true;       Get = { Get-CursorAppVersionCached } }
        @{ El = 'grokVersionText';   Provider = 'grok';   Show = $true;       Get = { Get-ProviderCliVersionCached 'grok' } }
    )

    foreach ($spec in $specs) {
        $el = $script:window.FindName($spec.El)
        if (-not $el) { continue }
        if (-not $spec.Show) {
            $el.Text = ''
            $el.Visibility = [System.Windows.Visibility]::Collapsed
            continue
        }
        $ver = & $spec.Get
        if ([string]::IsNullOrWhiteSpace($ver)) { $ver = '--' }
        $plan = Get-ProviderPlanLabel $spec.Provider
        $el.Text = Format-ProviderVersionPlanBadge -Version $ver -Plan $plan
        if ($el.PSObject.Properties['Foreground']) {
            try { $el.Foreground = (NewBrush $muted) } catch { }
        }
        $el.Visibility = [System.Windows.Visibility]::Visible
    }
}
