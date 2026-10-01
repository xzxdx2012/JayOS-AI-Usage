# Status.ps1 - which single provider status the chrome header shows.
#
# The header dot and text used to follow Claude alone, so a Codex 401 left the
# dot green and a Claude hiccup wiped the only timestamp in the window. This
# picks the worst status across the providers the user has enabled. Deliberately
# free of WPF types and file I/O so it stays Pester-testable; callers pass in the
# status words they already hold. Needs Test-ProviderAuthFailed (Config.ps1).

# Section order on screen; also breaks ties so the header names the topmost one.
$script:StatusProviderOrder = @('claude', 'codex', 'cursor', 'grok')

# Only these replace the last-fetch time in the header. Everything else
# (init, refreshing, unavailable) says nothing the user can act on.
$script:StatusAlertStates = @('auth', 'error', 'stale')

function ConvertTo-ChromeStatus([string]$Status) {
    if ([string]::IsNullOrWhiteSpace($Status)) { return 'init' }
    $s = $Status.Trim().ToLowerInvariant()
    # Same mapping as the snapshot in unified-overlay.ps1: never logged in is a
    # setup gap shown as 'unavailable', not an expired login.
    if ($s -eq 'notoken') { return 'unavailable' }
    return $s
}

# Higher is worse. Matches the snapshot precedence: an auth failure outranks
# everything, including successfully parsed local stats - Codex once reported
# 'ok' for 13 days while its live quota 401'd. 'ok' outranks the states that
# carry no information, so one provider still initialising cannot grey out a
# header whose other providers have all reported healthy.
function Get-ProviderStatusSeverity([string]$Status) {
    $s = ConvertTo-ChromeStatus $Status
    if (Test-ProviderAuthFailed $s) { return 4 }
    switch ($s) {
        'error' { return 3 }
        'stale' { return 2 }
        'ok'    { return 1 }
        'idle'  { return 0 }
    }
    return 0
}

# Reads a key from a hashtable or from a settings object that round-tripped
# through JSON (Cfg.Sections is a PSCustomObject then).
function Get-StatusMapValue($Map, [string]$Key) {
    if ($null -eq $Map) { return $null }
    if ($Map -is [System.Collections.IDictionary]) {
        if ($Map.Contains($Key)) { return $Map[$Key] }
        return $null
    }
    $prop = $Map.PSObject.Properties[$Key]
    if ($prop) { return $prop.Value }
    return $null
}

# Missing map or missing key means enabled, as Test-ClaudeSectionVisible does.
function Test-ProviderStatusEnabled($Enabled, [string]$Key) {
    $v = Get-StatusMapValue $Enabled $Key
    if ($null -eq $v) { return $true }
    return [bool]$v
}

# Returns @{ Status; Provider }. Disabled providers never count, which is what
# keeps a hidden Claude's auth/stale/error out of the chrome. With nothing
# enabled the result is a neutral 'init' with no provider.
function Get-WorstProviderStatus {
    param(
        $Status,
        $Enabled,
        [string[]]$Order = $script:StatusProviderOrder
    )

    $worst = @{ Status = 'init'; Provider = $null }
    $worstRank = -1
    foreach ($key in $Order) {
        if (-not (Test-ProviderStatusEnabled $Enabled $key)) { continue }
        $raw = Get-StatusMapValue $Status $key
        $rank = Get-ProviderStatusSeverity $raw
        if ($rank -gt $worstRank) {
            $worstRank = $rank
            $worst = @{ Status = (ConvertTo-ChromeStatus $raw); Provider = $key }
        }
    }
    return $worst
}

# Header right-hand slot: the last-fetch time while nothing enabled needs
# attention, otherwise the culprit ('CODEX auth') instead of Claude's message.
# Busy is the manual-refresh text; it wins while set so the click visibly lands.
function Get-ChromeStatusText {
    param(
        [string]$Status,
        [string]$Provider,
        [string]$LastFetch,
        [string]$Busy
    )

    if (-not [string]::IsNullOrWhiteSpace($Busy)) { return $Busy }
    if ($Status -notin $script:StatusAlertStates) { return [string]$LastFetch }
    if ([string]::IsNullOrWhiteSpace($Provider)) { return $Status }
    return ('{0} {1}' -f $Provider.ToUpperInvariant(), $Status)
}

# Fill for a status dot, chrome or section. The palette the chrome dot has
# always used; anything without information reads as neutral slate.
function Get-StatusDotColor([string]$Status) {
    switch (ConvertTo-ChromeStatus $Status) {
        'ok'    { return '#30D158' }
        'stale' { return '#FF9F0A' }
        'idle'  { return '#AEAEB2' }
        'auth'  { return '#FF453A' }
        'error' { return '#FF453A' }
    }
    return '#636366'
}

# Hover text for a section dot: the state word, plus what the provider said or,
# when healthy, when it last fetched.
function Get-SectionStatusTip {
    param(
        [string]$Status,
        [string]$Message,
        [string]$LastFetch
    )

    $s = ConvertTo-ChromeStatus $Status
    if (-not [string]::IsNullOrWhiteSpace($Message)) { return ('{0} - {1}' -f $s, $Message.Trim()) }
    if ($s -eq 'ok' -and -not [string]::IsNullOrWhiteSpace($LastFetch)) { return ('ok {0}' -f $LastFetch.Trim()) }
    return $s
}
