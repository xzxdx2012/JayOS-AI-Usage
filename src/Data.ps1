# Data.ps1 - data fetchers: Get-Usage, Get-Stats, and the Write-Log diagnostic helper

function Write-Log {
    param([string]$Message)
    try {
        $line = '[{0}] {1}' -f (Get-Date -Format 's'), $Message
        Add-Content -Path $script:ErrLog -Value $line -Encoding UTF8
        # Every 100 lines (and on the first), keep the file under ~2 MB by
        # dropping everything but its newest 512 KB.
        if (($script:LogWrites++ % 100) -eq 0) { Limit-LogFile $script:ErrLog }
    } catch { }  # never throw from a logger
}

function Limit-LogFile([string]$Path, [long]$MaxBytes = 2MB, [int]$KeepBytes = 512KB) {
    try {
        $fi = New-Object System.IO.FileInfo($Path)
        if (-not $fi.Exists -or $fi.Length -le $MaxBytes) { return }
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            [void]$fs.Seek(-$KeepBytes, 'End')
            $buf = New-Object byte[] $KeepBytes
            $n = $fs.Read($buf, 0, $KeepBytes)
        } finally { $fs.Dispose() }
        $start = [array]::IndexOf($buf, [byte]10) + 1   # begin on a whole line
        $out = New-Object byte[] ($n - $start)
        [array]::Copy($buf, $start, $out, 0, $n - $start)
        [System.IO.File]::WriteAllBytes($Path, $out)
    } catch { }
}

# ---------------------------------------------------------------------------
# Claude quota window normalization
#
# Anthropic may return some weekly windows as top-level seven_day_* fields and
# some in limits[]. Surface both shapes under stable seven_day_* properties so
# export/history code can serialize them without knowing the payload variant.
# ---------------------------------------------------------------------------
function Get-ClaudeQuotaWindowSpecs {
    @(
        [PSCustomObject]@{ Field = 'seven_day_fable';      Label = 'Fable';      Match = @('Fable') }
        [PSCustomObject]@{ Field = 'seven_day_opus';       Label = 'Opus';       Match = @('Opus') }
        [PSCustomObject]@{ Field = 'seven_day_sonnet';     Label = 'Sonnet';     Match = @('Sonnet') }
        [PSCustomObject]@{ Field = 'seven_day_oauth_apps'; Label = 'OAuth apps'; Match = @('OAuth apps', 'OAuth Apps', 'OAuth') }
        [PSCustomObject]@{ Field = 'seven_day_omelette';   Label = 'Omelette';   Match = @('Omelette') }
        [PSCustomObject]@{ Field = 'seven_day_cowork';     Label = 'Cowork';     Match = @('Cowork') }
    )
}

function ConvertTo-ClaudeQuotaMatchKey($value) {
    if (-not $value) { return '' }
    return ([string]$value).ToLowerInvariant() -replace '[^a-z0-9]', ''
}

function Get-PropertyValue($object, [string]$name) {
    if (-not $object) { return $null }
    $prop = $object.PSObject.Properties[$name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-ClaudeLimitNames($limit, $spec) {
    $scope = Get-PropertyValue $limit 'scope'
    $model = Get-PropertyValue $scope 'model'
    $application = Get-PropertyValue $scope 'application'

    @(
        (Get-PropertyValue $limit 'display_name')
        (Get-PropertyValue $limit 'name')
        (Get-PropertyValue $limit 'limit_name')
        (Get-PropertyValue $limit 'limit_id')
        (Get-PropertyValue $scope 'display_name')
        (Get-PropertyValue $scope 'name')
        (Get-PropertyValue $scope 'type')
        (Get-PropertyValue $model 'display_name')
        (Get-PropertyValue $model 'name')
        (Get-PropertyValue $application 'display_name')
        (Get-PropertyValue $application 'name')
    ) | Where-Object { $_ }
}

function ConvertTo-ClaudeQuotaWindow($limit) {
    if (-not $limit) { return $null }
    $utilization = $null
    foreach ($name in @('utilization', 'percent', 'used_percent')) {
        $candidate = Get-PropertyValue $limit $name
        if ($null -ne $candidate) { $utilization = [double]$candidate; break }
    }
    if ($null -eq $utilization) { return $null }

    [PSCustomObject]@{
        utilization = $utilization
        resets_at   = Get-PropertyValue $limit 'resets_at'
    }
}

function Get-ScopedLimit([object]$resp, [object]$spec) {
    if (-not $resp.limits) { return $null }
    $matches = @($spec.Match | ForEach-Object { ConvertTo-ClaudeQuotaMatchKey $_ })
    foreach ($lim in $resp.limits) {
        $limitNames = @(Get-ClaudeLimitNames $lim $spec | ForEach-Object { ConvertTo-ClaudeQuotaMatchKey $_ })
        foreach ($name in $limitNames) {
            foreach ($match in $matches) {
                if ($name -eq $match -or ($match -and $name.EndsWith($match))) {
                    return ConvertTo-ClaudeQuotaWindow $lim
                }
            }
        }
    }
    return $null
}

function Normalize-ClaudeQuotaWindows([object]$resp) {
    if (-not $resp) { return $resp }

    foreach ($spec in Get-ClaudeQuotaWindowSpecs) {
        $existing = Get-PropertyValue $resp $spec.Field
        if ($null -eq $existing) {
            $existing = Get-ScopedLimit $resp $spec
        }
        if ($null -ne $existing) {
            $resp | Add-Member -NotePropertyName $spec.Field -NotePropertyValue (ConvertTo-ClaudeQuotaWindow $existing) -Force
        }
    }

    return $resp
}

function ConvertTo-ClaudeIdentity {
    param($Profile)

    if (-not $Profile) { return $null }

    $account = $Profile.account
    $user = $Profile.user
    $org = $Profile.organization
    if (-not $org -and $Profile.organizations) {
        $org = @($Profile.organizations) | Select-Object -First 1
    }

    $email = $null
    foreach ($candidate in @($Profile.email, $account.email, $user.email)) {
        if ($candidate) { $email = [string]$candidate; break }
    }

    $orgName = $null
    foreach ($candidate in @($Profile.organization_name, $org.name, $org.display_name)) {
        if ($candidate) { $orgName = [string]$candidate; break }
    }

    $orgId = $null
    foreach ($candidate in @($Profile.organization_uuid, $Profile.organization_id, $org.uuid, $org.id)) {
        if ($candidate) { $orgId = [string]$candidate; break }
    }

    if (-not $email -and -not $orgName -and -not $orgId) { return $null }

    $parts = @()
    if ($email) { $parts += $email }
    if ($orgName) { $parts += $orgName }
    elseif ($orgId) { $parts += $orgId }

    [PSCustomObject]@{
        Email        = $email
        Organization = $orgName
        OrganizationId = $orgId
        Display      = ($parts -join ' / ')
    }
}

function Get-ClaudeBackoffPath {
    Join-Path $script:AppDir 'claude-backoff.json'
}

# Backoff state carries more than a timestamp: a running FailureCount drives
# exponential escalation, and Status/Message are replayed on the early-return
# path so a cooldown shows its real cause (e.g. 'Auth expired') instead of a
# generic "Rate limited" line.
function Get-ClaudeBackoffState {
    try {
        $path = Get-ClaudeBackoffPath
        if (-not (Test-Path $path)) { return $null }

        $raw = Get-Content $path -Raw -Encoding UTF8 -ErrorAction Stop
        if (-not $raw) { return $null }

        $json = $raw | ConvertFrom-Json -ErrorAction Stop

        $until = $null
        if ($json.BackoffUntil) {
            $until = ([System.DateTimeOffset]::Parse([string]$json.BackoffUntil)).LocalDateTime
        }

        return @{
            Until        = $until
            FailureCount = [int]($json.FailureCount)
            Status       = [string]$json.Status
            Message      = [string]$json.Message
            TokenHash    = [string]$json.TokenHash
        }
    } catch {
        Write-Log "Claude backoff load failed - $($_.Exception.Message)"
        return $null
    }
}

# Claude Code rotates the access token on its own schedule. Once it has, a
# cooldown recorded against the old token is waiting out a problem the user has
# already fixed, so it no longer applies. A backoff with no recorded hash (older
# state files, or a 429 that is deliberately left unkeyed) and a token that
# could not be read both keep the backoff in force.
function Test-ClaudeBackoffActive {
    param(
        $Backoff,
        [string]$CurrentTokenHash,
        [datetime]$Now = (Get-Date)
    )

    if (-not $Backoff) { return $false }
    if (-not $Backoff.Until) { return $false }
    if ([datetime]$Backoff.Until -le $Now) { return $false }

    $failedHash = [string]$Backoff.TokenHash
    if ($failedHash -and $CurrentTokenHash -and $failedHash -ne $CurrentTokenHash) { return $false }

    return $true
}

function Get-ClaudeBackoffUntil {
    $state = Get-ClaudeBackoffState
    if ($state) { return $state.Until }
    return $null
}

function Set-ClaudeBackoffUntil {
    param(
        [datetime]$BackoffUntil,
        [int]$FailureCount = 0,
        [string]$Status = 'stale',
        [string]$Message = '',
        [string]$TokenHash = ''
    )

    try {
        [pscustomobject]@{
            BackoffUntil = ([System.DateTimeOffset]$BackoffUntil).ToString('o')
            FailureCount = $FailureCount
            Status       = $Status
            Message      = $Message
            TokenHash    = $TokenHash
        } | ConvertTo-Json -Depth 3 | Set-Content -Path (Get-ClaudeBackoffPath) -Encoding UTF8
    } catch {
        Write-Log "Claude backoff save failed - $($_.Exception.Message)"
    }
}

# A network outage and an expired token are different problems. Sharing one
# counter let 14 'No such host is known' failures hand the first 401 failure
# #16 and an immediate 30-minute lockout, so the count restarts whenever the
# failure kind changes.
function Get-ClaudeFailureCount {
    param(
        $Previous,
        [string]$Status
    )

    if (-not $Previous) { return 1 }
    $count = [int]$Previous.FailureCount
    if ($count -le 0) { return 1 }
    if ([string]$Previous.Status -ne $Status) { return 1 }
    return $count + 1
}

# Record a failed usage fetch and schedule the next allowed attempt. Every
# failure mode backs off - not just 429 - because repeatedly retrying a bad
# token (401) or a flaky endpoint (503/network) every poll is exactly what
# escalates into a server-side rate limit. Delay is exponential in the running
# failure count (60s, 2m, 4m, ... capped at 30m), floored per reason, and a
# server-supplied Retry-After (when it points meaningfully into the future)
# always wins.
function Register-ClaudeFailure {
    param(
        [string]$Status = 'stale',
        [string]$Message = '',
        $RetryAfter = $null,
        [int]$MinSeconds = 60,
        [string]$TokenHash = ''
    )

    $now = Get-Date

    $count = Get-ClaudeFailureCount -Previous (Get-ClaudeBackoffState) -Status $Status

    if ($RetryAfter -and ([datetime]$RetryAfter) -gt $now.AddMinutes(1)) {
        $until = [datetime]$RetryAfter
    } else {
        $exponent = [math]::Min(6, $count)
        $delay = [math]::Min(1800, 60 * [math]::Pow(2, $exponent - 1))
        $delay = [math]::Max($MinSeconds, $delay)
        $until = $now.AddSeconds($delay)
    }

    Set-ClaudeBackoffUntil -BackoffUntil $until -FailureCount $count -Status $Status -Message $Message -TokenHash $TokenHash
    Write-Log "Claude backoff: $Status (failure #$count) until $($until.ToString('HH:mm:ss')) - $Message"
    return $until
}

function Clear-ClaudeBackoff {
    try {
        $path = Get-ClaudeBackoffPath
        if (Test-Path $path) { Remove-Item $path -Force -ErrorAction Stop }
    } catch {
        Write-Log "Claude backoff clear failed - $($_.Exception.Message)"
    }
}

# The identity behind a token is near-static, but each poll runs in a fresh
# background process, so an in-memory cache would not survive. Persist the
# resolved identity keyed by the token it was fetched with; the profile
# endpoint is then hit at most once per token instead of on every poll. That
# halves the authenticated request volume and, critically, stops a token that
# 401s on /profile from being retried every three minutes.
function Get-ClaudeProfilePath {
    Join-Path $script:AppDir 'claude-profile.json'
}

function Get-CachedClaudeProfile {
    try {
        $path = Get-ClaudeProfilePath
        if (-not (Test-Path $path)) { return $null }

        $raw = Get-Content $path -Raw -Encoding UTF8 -ErrorAction Stop
        if (-not $raw) { return $null }

        $json = $raw | ConvertFrom-Json -ErrorAction Stop
        $tokenHash = [string]$json.TokenHash
        if ($json.Token) {
            $tokenHash = Get-ClaudeTokenHash ([string]$json.Token)
            Save-ClaudeProfile -Token ([string]$json.Token) -Identity $json.Identity
        }
        return @{
            TokenHash = $tokenHash
            Identity = $json.Identity
        }
    } catch {
        Write-Log "Claude profile cache load failed - $($_.Exception.Message)"
        return $null
    }
}

function Get-ClaudeTokenHash([string]$Token) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Token)))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Save-ClaudeProfile {
    param(
        [string]$Token,
        $Identity
    )

    try {
        [pscustomobject]@{
            TokenHash = Get-ClaudeTokenHash $Token
            Identity = $Identity
        } | ConvertTo-Json -Depth 6 | Set-Content -Path (Get-ClaudeProfilePath) -Encoding UTF8
    } catch {
        Write-Log "Claude profile cache save failed - $($_.Exception.Message)"
    }
}

function ConvertFrom-RetryAfter {
    param($Value)

    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    if (-not $text) { return $null }

    $seconds = 0
    if ([int]::TryParse($text, [ref]$seconds)) {
        return (Get-Date).AddSeconds([math]::Max(60, $seconds))
    }

    try {
        return ([System.DateTimeOffset]::Parse($text)).LocalDateTime
    } catch {
        return $null
    }
}

function Get-ResponseRetryAfter {
    param($Response)

    if (-not $Response) { return $null }

    try {
        $header = $Response.Headers['Retry-After']
        if ($header) { return ConvertFrom-RetryAfter $header }
    } catch { }

    try {
        $values = $Response.Headers.GetValues('Retry-After')
        if ($values -and $values.Count -gt 0) { return ConvertFrom-RetryAfter $values[0] }
    } catch { }

    return $null
}

function Get-ClaudeProfile {
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [int]$TimeoutSec = 20
    )

    $profile = Invoke-RestMethod 'https://api.anthropic.com/api/oauth/profile' -TimeoutSec $TimeoutSec -Headers @{
        Authorization = "Bearer $Token"; 'anthropic-beta' = 'oauth-2025-04-20'; 'User-Agent' = $script:UA
    }
    return ConvertTo-ClaudeIdentity $profile
}

function Get-ClaudeCredentialPreferencePath {
    Join-Path $script:AppDir 'claude-credential-preference.json'
}

function Get-PreferredClaudeCredentialPath {
    try {
        $path = Get-ClaudeCredentialPreferencePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
        return [string]((Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json).CredentialPath)
    } catch {
        return $null
    }
}

function Save-PreferredClaudeCredentialPath([string]$CredentialPath) {
    if (-not $CredentialPath) { return }
    try {
        @{ CredentialPath = $CredentialPath } |
            ConvertTo-Json |
            Set-Content -LiteralPath (Get-ClaudeCredentialPreferencePath) -Encoding UTF8
    } catch {
        Write-Log "Save-PreferredClaudeCredentialPath failed - $($_.Exception.Message)"
    }
}

function Get-ClaudeCredentialPathsInPreferenceOrder([string[]]$Paths) {
    $ordered = [System.Collections.Generic.List[string]]::new()
    $preferred = Get-PreferredClaudeCredentialPath
    if ($preferred -and $Paths -contains $preferred -and (Test-Path -LiteralPath $preferred -PathType Leaf)) {
        [void]$ordered.Add($preferred)
    }
    foreach ($path in @($Paths | Select-Object -Unique)) {
        if ($path -and -not $ordered.Contains($path)) { [void]$ordered.Add($path) }
    }
    return $ordered.ToArray()
}

function Select-ClaudeCredential {
    param([string[]]$Paths)

    $nowMs = [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $bestValid = $null
    $bestValidExpiresAt = 0L
    $bestFallback = $null
    $bestFallbackMtime = [datetime]::MinValue

    foreach ($path in @($Paths | Select-Object -Unique)) {
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue)) { continue }

        try {
            $credentialFile = Get-Item -LiteralPath $path -ErrorAction Stop
            $credentials = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $oauth = $credentials.claudeAiOauth
            $token = if ($oauth) { [string]$oauth.accessToken } else { $null }
            if (-not $token) { continue }

            if ($credentialFile.LastWriteTimeUtc -gt $bestFallbackMtime) {
                $bestFallback = $token
                $bestFallbackMtime = $credentialFile.LastWriteTimeUtc
            }

            $expiresAt = 0L
            if ($oauth.expiresAt -and [long]::TryParse([string]$oauth.expiresAt, [ref]$expiresAt) -and
                $expiresAt -gt $nowMs -and $expiresAt -gt $bestValidExpiresAt) {
                $bestValid = $token
                $bestValidExpiresAt = $expiresAt
            }
        } catch { }
    }

    if ($bestValid) { return $bestValid }
    return $bestFallback
}

# What the recovery checks need from each credential file: a SHA-256 of the
# token and its expiresAt (unix ms, 0 when absent). The raw token never leaves
# this function, so nothing downstream can log or persist it. The overlay only
# ever READS these files - refreshing would rotate the refresh token out from
# under Claude Code and log the user out.
function Get-ClaudeCredentialFingerprints {
    param([string[]]$Paths)

    $fingerprints = [System.Collections.Generic.List[object]]::new()
    foreach ($path in @($Paths)) {
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue)) { continue }

        try {
            $oauth = (Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop |
                ConvertFrom-Json -ErrorAction Stop).claudeAiOauth
        } catch {
            # Type only: Windows PowerShell's JSON errors echo the input, which
            # for a half-written credentials file is the raw token.
            Write-Log "Claude credential fingerprint skipped $path - $($_.Exception.GetType().Name)"
            continue
        }
        if (-not $oauth) { continue }
        $token = [string]$oauth.accessToken
        if (-not $token) { continue }

        $expiresAt = 0L
        if (-not [long]::TryParse([string]$oauth.expiresAt, [ref]$expiresAt)) { $expiresAt = 0L }

        [void]$fingerprints.Add(@{
            Path      = $path
            TokenHash = Get-ClaudeTokenHash $token
            ExpiresAt = $expiresAt
        })
    }
    return $fingerprints.ToArray()
}

# One key for every credential Get-Usage will try. The fetch loop falls through
# all of them, so a rotation in ANY one is worth a retry - keying to the first
# alone held a backoff for up to 30 minutes after a Windows re-auth whenever a
# stale WSL token happened to be preferred. Sorted and de-duplicated so a
# preference-order flip, or the same token at two paths, is not a rotation.
# Built from token hashes, so a sync that rewrites an unchanged token matches.
function Get-ClaudeCredentialSetHash {
    param([string[]]$TokenHashes)

    $members = @($TokenHashes | Where-Object { $_ } | Sort-Object -Unique)
    if ($members.Count -eq 0) { return '' }
    return Get-ClaudeTokenHash ($members -join '|')
}

# A token past its expiresAt cannot succeed, and spending a 401 on it only
# escalates the backoff. Only an all-expired set counts: one unknown expiry or
# one live token means the fetch loop still has something worth trying.
function Test-ClaudeCredentialsExpired {
    param(
        [long[]]$ExpiresAtUnixMs,
        [long]$NowUnixMs
    )

    if (-not $ExpiresAtUnixMs -or $ExpiresAtUnixMs.Count -eq 0) { return $false }
    foreach ($expiresAt in $ExpiresAtUnixMs) {
        if ($expiresAt -le 0) { return $false }
        if ($expiresAt -gt $NowUnixMs) { return $false }
    }
    return $true
}

function Get-ClaudeProjectsDirCandidates {
    param([string[]]$WslHomeRoots = @(Get-WslHomeRoots))

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($env:USERPROFILE) {
        try { [void]$candidates.Add((Join-Path $env:USERPROFILE '.claude\projects')) } catch { }
    }

    foreach ($root in @($WslHomeRoots)) {
        if ($root) {
            try { [void]$candidates.Add((Join-Path $root '.claude\projects')) } catch { }
        }
    }

    return @($candidates | Select-Object -Unique)
}

# True when any credential file carries a refresh token, i.e. Claude Code can
# renew the access token on its own and the user does not need to log in again.
function Test-ClaudeRefreshTokenPresent([string[]]$Paths) {
    foreach ($path in @($Paths)) {
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue)) { continue }
        try {
            $oauth = (Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop |
                ConvertFrom-Json -ErrorAction Stop).claudeAiOauth
            if ($oauth -and [string]$oauth.refreshToken) { return $true }
        } catch { }
    }
    return $false
}

# The runnable Claude CLI: the native claude.exe behind npm's claude.ps1/.cmd
# shims when there is one (Start-Process on a .ps1 opens it in Notepad).
function Resolve-ClaudeCliExecutable {
    $cands = @(Get-Command -Name claude -All -ErrorAction SilentlyContinue)
    foreach ($c in $cands) {
        $p = [string]$c.Source
        if ($p -and $p -match '(?i)\.exe$' -and (Test-Path -LiteralPath $p)) { return $p }
    }
    foreach ($c in $cands) {
        $p = [string]$c.Source
        if (-not $p) { continue }
        $dir = Split-Path -Parent $p
        $native = Join-Path $dir 'node_modules\@anthropic-ai\claude-code\bin\claude.exe'
        if (Test-Path -LiteralPath $native) { return $native }
    }
    foreach ($c in $cands) {
        $p = [string]$c.Source
        if ($p -and $p -match '(?i)\.(cmd|bat)$') { return $p }
    }
    $wellKnown = @(
        (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
        (Join-Path $env:APPDATA 'npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe'))
    foreach ($p in $wellKnown) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
    return $null
}

# Run `claude auth status` hidden, at most every 20 minutes: the CLI checks its
# own sign-in and renews an expired access token, writing the credentials file
# itself. The next poll sees the new token (a new credential hash clears the
# backoff) and live usage comes back.
function Invoke-ClaudeTokenNudge {
    try {
        $marker = Join-Path $script:AppDir 'claude-token-nudge.txt'
        if (Test-Path -LiteralPath $marker) {
            $age = (Get-Date) - (Get-Item -LiteralPath $marker).LastWriteTime
            if ($age.TotalMinutes -lt 20) { return }
        }
        $exe = Resolve-ClaudeCliExecutable
        if (-not $exe) { return }
        Set-Content -LiteralPath $marker -Value (Get-Date -Format o) -Encoding UTF8
        Start-Process -FilePath $exe -ArgumentList @('auth', 'status') -WindowStyle Hidden | Out-Null
    } catch {
        try { Write-Log "Claude token nudge failed - $($_.Exception.GetType().Name)" } catch { }
    }
}

function Get-Usage {
    param(
        [int]$TimeoutSec = 20,
        [switch]$Force
    )

    $credentialPaths = [System.Collections.Generic.List[string]]::new()
    $preferredPath = Get-PreferredClaudeCredentialPath
    if ($preferredPath) { [void]$credentialPaths.Add($preferredPath) }
    if ($script:CredPath) { [void]$credentialPaths.Add($script:CredPath) }
    foreach ($root in Get-WslHomeRoots) {
        if ($root) {
            try { [void]$credentialPaths.Add((Join-Path $root '.claude\.credentials.json')) } catch { }
        }
    }
    $candidatePaths = @($credentialPaths | Select-Object -Unique)
    $candidatePaths = @(Get-ClaudeCredentialPathsInPreferenceOrder $candidatePaths)

    # The backoff and expiry decisions both turn on which tokens are on disk
    # right now - all of them, since the fetch loop tries every candidate.
    $fingerprints = @(Get-ClaudeCredentialFingerprints $candidatePaths)
    $credentialSetHash = Get-ClaudeCredentialSetHash @($fingerprints | ForEach-Object { [string]$_.TokenHash })

    # Checked before the backoff: a cooldown recorded while the token was
    # merely idle must not keep replaying "sign in" at the user.
    $nowMsIdle = [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $expiriesIdle = @($fingerprints | ForEach-Object { [long]$_.ExpiresAt })
    if ((Test-ClaudeCredentialsExpired -ExpiresAtUnixMs $expiriesIdle -NowUnixMs $nowMsIdle) -and
        (Test-ClaudeRefreshTokenPresent $candidatePaths)) {
        # Only the short-lived access token has run out. With a refresh token on
        # disk the account is still signed in - Claude Code renews the pair the
        # next time it runs - so say so instead of asking for a new login, and
        # nudge the CLI to renew it (it owns the file; the overlay never writes it).
        if (Test-ClaudeRefreshTokenPresent $candidatePaths) {
            Invoke-ClaudeTokenNudge
            try {
                $cachedProfile = Get-CachedClaudeProfile
                if ($cachedProfile -and $cachedProfile.Identity) { $script:ClaudeIdentity = $cachedProfile.Identity }
            } catch { }
            $idleMessage = 'Signed in - usage resumes when Claude Code renews its token'
            $script:State.Status = 'idle'; $script:State.Message = $idleMessage
            return
        }
    }

    if (-not $Force) {
        $backoff = Get-ClaudeBackoffState
        if (Test-ClaudeBackoffActive -Backoff $backoff -CurrentTokenHash $credentialSetHash) {
            # Replay the failure's own status/message so the cooldown reflects
            # its real cause (auth, network, ...) rather than always reading as
            # a rate limit.
            if ($backoff.Status)  { $script:State.Status  = $backoff.Status }  else { $script:State.Status = 'stale' }
            if ($backoff.Message) { $script:State.Message = $backoff.Message } else { $script:State.Message = "Rate limited until $($backoff.Until.ToString('HH:mm'))" }
            return
        }
    }

    if ($candidatePaths.Count -eq 0) {
        $script:State.Status = 'error'; $script:State.Message = 'No credentials file'; return
    }

    # Every token on disk is already past its expiresAt, so a request can only
    # 401. Say what fixes it instead, and key the cooldown to these tokens so
    # the poll after Claude Code rotates any of them goes straight through.
    $nowMs = [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $expiries = @($fingerprints | ForEach-Object { [long]$_.ExpiresAt })
    if (Test-ClaudeCredentialsExpired -ExpiresAtUnixMs $expiries -NowUnixMs $nowMs) {
        $expiredMessage = 'Token expired - open Claude Code to refresh'
        [void](Register-ClaudeFailure -Status 'auth' -Message $expiredMessage -MinSeconds 60 -TokenHash $credentialSetHash)
        $script:State.Status = 'auth'; $script:State.Message = $expiredMessage
        return
    }

    $resp = $null
    $tok = $null
    $selectedPath = $null
    $lastAuthException = $null
    try {
        foreach ($credentialPath in $candidatePaths) {
            try { $candidateToken = (Get-Content $credentialPath -Raw -Encoding UTF8 | ConvertFrom-Json).claudeAiOauth.accessToken } catch { continue }
            if (-not $candidateToken) { continue }

            try {
                $resp = Invoke-RestMethod 'https://api.anthropic.com/api/oauth/usage' -TimeoutSec $TimeoutSec -Headers @{
                    Authorization = "Bearer $candidateToken"; 'anthropic-beta' = 'oauth-2025-04-20'; 'User-Agent' = $script:UA
                }
                $tok = [string]$candidateToken
                $selectedPath = $credentialPath
                break
            } catch {
                $code = $null
                if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
                if ($code -eq 401) { $lastAuthException = $_.Exception; continue }
                throw
            }
        }

        if (-not $resp) {
            if ($lastAuthException) { throw $lastAuthException }
            $script:State.Status = 'auth'; $script:State.Message = 'Not logged in'; return
        }

        Save-PreferredClaudeCredentialPath $selectedPath
        $resp = Normalize-ClaudeQuotaWindows $resp
        $script:State.Data = $resp; $script:State.Status = 'ok'
        $script:State.Message = ''; $script:State.LastFetch = (Get-Date -Format 'HH:mm')
        Clear-ClaudeBackoff
    } catch {
        $code = $null
        if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
        if ($code -eq 429) {
            # Deliberately not keyed to the token: a rate limit is the server
            # telling us to stop, and a rotation must not walk over it.
            $retryUntil = Get-ResponseRetryAfter $_.Exception.Response
            $until = Register-ClaudeFailure -Status 'stale' -Message '' -RetryAfter $retryUntil -MinSeconds 900
            $script:State.Status = 'stale'
            $script:State.Message = "Rate limited until $($until.ToString('HH:mm'))"
        }
        elseif ($code -eq 401) {
            [void](Register-ClaudeFailure -Status 'auth' -Message 'Auth expired' -MinSeconds 60 -TokenHash $credentialSetHash)
            $script:State.Status = 'auth'; $script:State.Message = 'Auth expired'
        }
        else {
            $msg = $_.Exception.Message
            [void](Register-ClaudeFailure -Status 'stale' -Message $msg -MinSeconds 60 -TokenHash $credentialSetHash)
            $script:State.Status = 'stale'; $script:State.Message = $msg
        }
        # A failed usage call means the token/endpoint is already unhappy; do
        # not follow it with a second authenticated request to /profile.
        return
    }

    # Resolve identity at most once per token. The value is cached to disk so it
    # survives the fresh process each poll runs in; on a token rotation the cache
    # misses and we fetch again. A token that has already been tried (success or
    # failure) is never re-hit, which is what stopped the every-poll /profile
    # 401s from escalating into a rate limit.
    $cached = Get-CachedClaudeProfile
    if ($cached -and $cached.TokenHash -eq (Get-ClaudeTokenHash $tok)) {
        $script:ClaudeIdentity = $cached.Identity
    } else {
        try {
            $script:ClaudeIdentity = Get-ClaudeProfile -Token $tok -TimeoutSec $TimeoutSec
        } catch {
            $script:ClaudeIdentity = $null
            Write-Log "Get-Usage: Claude profile fetch failed - $($_.Exception.Message)"
        }
        Save-ClaudeProfile -Token $tok -Identity $script:ClaudeIdentity
    }
}

# ---------------------------------------------------------------------------
# Measure-Stats - pure aggregator, takes pre-parsed records and a reference
# date; returns the same hashtable shape consumed by Update-UI.
#
# Each record must have:
#   Model     - model name string (e.g. 'claude-opus-4-8')
#   Date      - [datetime] (local date of the message)
#   In        - [long] input tokens
#   Out       - [long] output tokens
#   CacheW    - [long] cache-creation tokens
#   CacheR    - [long] cache-read tokens
#   SessionId - session GUID string
#   Key       - dedup key (already applied upstream by Get-Stats)
# ---------------------------------------------------------------------------
function Measure-Stats([object[]]$records, [datetime]$today) {
    $val = 0.0; $tin = 0L; $tout = 0L
    $sessions = [System.Collections.Generic.HashSet[string]]::new()
    $tMsg = 0; $tTok = 0L
    $afterHoursMsg = 0; $afterHoursTok = 0L

    foreach ($r in $records) {
        $v = @{
            inputTokens              = $r.In
            outputTokens             = $r.Out
            cacheCreationInputTokens = $r.CacheW
            cacheReadInputTokens     = $r.CacheR
        }
        $val  += Estimate-Cost $r.Model $v
        $tin  += [long]$r.In
        $tout += [long]$r.Out
        [void]$sessions.Add([string]$r.SessionId)

        if ($r.Date.Date -eq $today.Date) {
            $tMsg++
            $tTok += [long]$r.In + [long]$r.Out
            if (Test-UsageAfterHours $r.Date) {
                $afterHoursMsg++
                $afterHoursTok += [long]$r.In + [long]$r.Out
            }
        }
    }

    return @{
        ValueUSD     = $val
        InTokens     = $tin
        OutTokens    = $tout
        Sessions     = $sessions.Count
        Messages     = $records.Count
        TodayMsg     = $tMsg
        TodayTok     = $tTok
        TodayAfterHoursMsg = $afterHoursMsg
        TodayAfterHoursTok = $afterHoursTok
        LastComputed = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    }
}

function Test-UsageAfterHours([datetime]$Date) {
    $startHour = if ($null -ne $script:WorkdayStartHour) { [int]$script:WorkdayStartHour } else { 8 }
    $endHour = if ($null -ne $script:WorkdayEndHour) { [int]$script:WorkdayEndHour } else { 18 }

    if ($Date.DayOfWeek -eq [System.DayOfWeek]::Saturday -or
        $Date.DayOfWeek -eq [System.DayOfWeek]::Sunday) {
        return $true
    }

    return ($Date.Hour -lt $startHour -or $Date.Hour -ge $endHour)
}

# Per-file parse cache: path -> @{ Stamp; Records }
# Stamp = "$($file.LastWriteTimeUtc.Ticks):$($file.Length)"
$script:StatsFileCache = @{}

function Convert-StatsCacheDate {
    param($Value)

    if (-not $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }

    try {
        return [System.DateTimeOffset]::Parse([string]$Value).LocalDateTime
    } catch {
        return $null
    }
}

function Convert-StatsCacheRecords {
    param($Records)

    $converted = [System.Collections.Generic.List[object]]::new()
    if (-not $Records) { return $converted }

    foreach ($r in @($Records)) {
        $date = Convert-StatsCacheDate $r.Date
        if (-not $date) { continue }

        $converted.Add(@{
            Model     = [string]$r.Model
            Date      = $date
            In        = [long]$r.In
            Out       = [long]$r.Out
            CacheW    = [long]$r.CacheW
            CacheR    = [long]$r.CacheR
            SessionId = [string]$r.SessionId
            Key       = [string]$r.Key
        })
    }

    return $converted
}

function Import-StatsFileCache {
    param([string]$CachePath)

    if (-not $CachePath -or -not (Test-Path $CachePath)) { return }

    try {
        $raw = Get-Content $CachePath -Raw -Encoding UTF8 -ErrorAction Stop
        if (-not $raw) { return }

        $json = $raw | ConvertFrom-Json -ErrorAction Stop
        $loaded = @{}

        foreach ($prop in $json.PSObject.Properties) {
            $entry = $prop.Value
            if (-not $entry -or -not $entry.Stamp) { continue }

            $loaded[$prop.Name] = @{
                Stamp   = [string]$entry.Stamp
                Records = Convert-StatsCacheRecords $entry.Records
            }
        }

        $script:StatsFileCache = $loaded
    } catch {
        Write-Log "Get-Stats: failed to load cache $CachePath - $($_.Exception.Message)"
    }
}

function Export-StatsFileCache {
    param([string]$CachePath)

    if (-not $CachePath) { return }

    try {
        $script:StatsFileCache |
            ConvertTo-Json -Depth 8 |
            Set-Content -Path $CachePath -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Log "Get-Stats: failed to save cache $CachePath - $($_.Exception.Message)"
    }
}

function Get-Stats {
    $cachePath = Join-Path $script:AppDir 'stats-cache.json'
    Import-StatsFileCache $cachePath

    $projectDirs = [System.Collections.Generic.List[string]]::new()
    foreach ($dir in Get-ClaudeProjectsDirCandidates) {
        try {
            if (Test-Path -LiteralPath $dir -PathType Container -ErrorAction SilentlyContinue) {
                [void]$projectDirs.Add($dir)
            }
        } catch { }
    }

    if ($projectDirs.Count -eq 0) {
        Write-Log 'Get-Stats: ~/.claude/projects not found - no transcript data'
        return
    }

    $files = [System.Collections.Generic.List[object]]::new()
    foreach ($dir in $projectDirs) {
        try {
            foreach ($file in @(Get-ChildItem -LiteralPath $dir -Recurse -Filter '*.jsonl' -File -ErrorAction Stop)) {
                [void]$files.Add($file)
            }
        } catch {
            Write-Log "Get-Stats: failed to enumerate transcripts in $dir - $($_.Exception.Message)"
        }
    }

    # Deduplicate across all files using msgId:requestId key
    $seen  = [System.Collections.Generic.HashSet[string]]::new()
    $allRecords = [System.Collections.Generic.List[object]]::new()
    $activeCache = @{}

    foreach ($file in $files) {
        $stamp = "$($file.LastWriteTimeUtc.Ticks):$($file.Length)"
        $cached = $script:StatsFileCache[$file.FullName]

        if ($cached -and $cached.Stamp -eq $stamp) {
            $activeCache[$file.FullName] = $cached
            # Reuse cached parse - only add records whose keys haven't been seen yet
            foreach ($r in $cached.Records) {
                if ($seen.Add($r.Key)) { $allRecords.Add($r) }
            }
            continue
        }

        # Parse this file fresh
        $fileRecords = [System.Collections.Generic.List[object]]::new()
        try {
            $lines = Get-Content $file.FullName -Encoding UTF8 -ErrorAction Stop
        } catch {
            Write-Log "Get-Stats: skipping unreadable file $($file.FullName) - $($_.Exception.Message)"
            continue
        }

        foreach ($line in $lines) {
            if (-not $line) { continue }
            try {
                $o = $line | ConvertFrom-Json -ErrorAction Stop
            } catch { continue }

            # Only assistant messages with usage data
            if ($o.type -ne 'assistant') { continue }
            $u = $o.message.usage
            if (-not $u) { continue }

            $key = "$($o.message.id):$($o.requestId)"
            $ts  = $o.timestamp
            if (-not $ts) { continue }
            # PS7 ConvertFrom-Json auto-converts ISO timestamps to [datetime]; PS5 leaves them as strings.
            # [System.DateTimeOffset]::Parse handles the string case; the else handles PS7's [datetime].
            $localDate = if ($ts -is [string]) { [System.DateTimeOffset]::Parse($ts).LocalDateTime } else { ([datetime]$ts).ToLocalTime() }

            $r = @{
                Model     = [string]$o.message.model
                Date      = $localDate
                In        = [long]$u.input_tokens
                Out       = [long]$u.output_tokens
                CacheW    = [long]$u.cache_creation_input_tokens
                CacheR    = [long]$u.cache_read_input_tokens
                SessionId = [string]$o.sessionId
                Key       = $key
            }
            $fileRecords.Add($r)
        }

        $activeCache[$file.FullName] = @{ Stamp = $stamp; Records = $fileRecords }

        foreach ($r in $fileRecords) {
            if ($seen.Add($r.Key)) { $allRecords.Add($r) }
        }
    }

    $script:StatsFileCache = $activeCache
    Export-StatsFileCache $cachePath

    try {
        $script:Stats = Measure-Stats $allRecords.ToArray() (Get-Date)
    } catch {
        Write-Log "Get-Stats: Measure-Stats failed - $($_.Exception.Message)"
    }
}
