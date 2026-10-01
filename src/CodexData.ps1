# CodexData.ps1 - Codex session parsing and usage cost estimation

function Get-CodexSessionDirCandidates {
    param([string[]]$WslHomeRoots = @(Get-WslHomeRoots))

    $candidates = [System.Collections.Generic.List[string]]::new()

    foreach ($root in @($env:CODEX_HOME)) {
        if ($root) {
            try {
                [void]$candidates.Add((Join-Path $root 'sessions'))
            } catch { }
        }
    }

    foreach ($root in @($env:USERPROFILE, $env:HOME)) {
        if ($root) {
            try {
                [void]$candidates.Add((Join-Path (Join-Path $root '.codex') 'sessions'))
            } catch { }
        }
    }

    foreach ($root in @($env:LOCALAPPDATA, $env:APPDATA)) {
        if ($root) {
            try {
                [void]$candidates.Add((Join-Path $root 'OpenAI\Codex\sessions'))
            } catch { }
        }
    }

    foreach ($root in @($WslHomeRoots)) {
        if ($root) {
            try {
                [void]$candidates.Add((Join-Path $root '.codex\sessions'))
            } catch { }
        }
    }

    return @($candidates | Select-Object -Unique)
}

function Resolve-CodexSessionsDir {
    param([string]$PreferredDir = $script:CodexSessionsDir)

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($PreferredDir) { [void]$candidates.Add($PreferredDir) }
    foreach ($dir in Get-CodexSessionDirCandidates) {
        if ($dir) { [void]$candidates.Add($dir) }
    }

    foreach ($dir in @($candidates | Select-Object -Unique)) {
        if ($dir -and (Test-Path -LiteralPath $dir -PathType Container -ErrorAction SilentlyContinue)) { return $dir }
    }

    return @($candidates | Select-Object -First 1)
}

if (-not $script:CodexSessionsDir) {
    $script:CodexSessionsDir = Resolve-CodexSessionsDir
}

$script:CodexStats = $null
$script:CodexStatsFileCache = @{}

# Mirrors Cursor's contract (see Test-ProviderAuthFailed in Config.ps1) so both
# providers report auth trouble the same way instead of failing silently.
$script:CodexAuthState = 'init'
$script:CodexErrMsg    = ''

function Set-CodexAuthState {
    param([string]$State, [string]$Message = '')

    $script:CodexAuthState = $State
    $script:CodexErrMsg    = $Message
}

function Convert-CodexCacheDate {
    param($Value)

    if (-not $Value) { return $null }
    if ($Value -is [datetime]) {
        # Windows PowerShell 5.1 reads a cached date back as UTC, and DateTime
        # compares ticks rather than kind: a 09:03 local record returned as
        # 13:03 and skewed Today, after-hours and the current model. Match
        # Convert-CodexTimestamp, which hands out local time.
        if ($Value.Kind -eq [System.DateTimeKind]::Utc) { return $Value.ToLocalTime() }
        return $Value
    }

    try {
        return [System.DateTimeOffset]::Parse([string]$Value).LocalDateTime
    } catch {
        return $null
    }
}

function Convert-CodexCacheRecords {
    param($Records)

    $converted = [System.Collections.Generic.List[object]]::new()
    if (-not $Records) { return $converted }

    foreach ($r in @($Records)) {
        $date = Convert-CodexCacheDate $r.Date
        if (-not $date) { continue }

        $msgDates = @()
        if ($r.MessageDates) {
            foreach ($d in @($r.MessageDates)) {
                $cd = Convert-CodexCacheDate $d
                if ($cd) { $msgDates += $cd }
            }
        }

        $converted.Add(@{
            Model        = [string]$r.Model
            Date         = $date
            In           = [long]$r.In
            CachedIn     = [long]$r.CachedIn
            Out          = [long]$r.Out
            SessionId    = [string]$r.SessionId
            MessageDates = $msgDates
        })
    }

    return $converted
}

# Session logs are append-only JSONL, and a session that stays open keeps
# growing: one real session passed 535 MB. Re-reading a changed file whole on
# every poll cost its full size each time, blew the 60-second poll ceiling, and
# the reaper killed the job before it could save - so Codex went blank for good.
# The cache now remembers how far into each file it has read, plus the parser
# state at that point, and each poll parses only the bytes appended since.
$script:CodexCacheVersion = 4
# Bytes of each file's head that are fingerprinted, so a file replaced at the
# same path (rather than appended to) is detected and parsed from scratch.
$script:CodexHeadBytes = 4096
# Running total of session-log bytes read; lets tests prove a poll reads only
# what was appended.
$script:CodexBytesRead = 0L
# The only line kinds the stats read. Everything else - the large message and
# tool payloads that make up most of a session - is skipped before the costly
# ConvertFrom-Json. A line that merely mentions one of these is still parsed and
# then ignored by the type checks, so this can only let too much through.
$script:CodexRelevantNeedles = @('session_meta', 'turn_context', 'token_count', 'user_message')
# A cold parse of a huge session (first run after an upgrade, or a replaced
# file) can outlast the 60-second poll ceiling, and a reaped job saves nothing.
# So parse in slices, bank progress in the cache as it goes, and stop once the
# budget is spent; the next poll resumes from the saved offsets.
$script:CodexParseBudgetSeconds = 35
$script:CodexSliceBytes = 67108864

function Test-CodexLineRelevant([string]$Line) {
    if (-not $Line) { return $false }
    foreach ($needle in $script:CodexRelevantNeedles) {
        if ($Line.IndexOf($needle, [System.StringComparison]::Ordinal) -ge 0) { return $true }
    }
    return $false
}

# Reads complete lines from byte $Offset to the last newline in the file. A
# trailing line with no newline yet is left for the next read, since Codex may be
# mid-write. Newlines are found natively and each line is decoded straight from
# the read buffer, so a 500 MB file never has to be held in memory. With
# -MustContain, only lines containing one of the needles are returned.
function Read-CodexNewLines {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [long]$Offset = 0,
        [int]$ChunkBytes = 1048576,
        [string[]]$MustContain = $null,
        # Stop once this many bytes are read (0 = no limit). Only after at least
        # one whole line, so a line longer than the cap cannot stall progress.
        [long]$MaxBytes = 0
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $atEnd = $false
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    $read = 0L
    $consumed = $Offset
    try {
        if ($Offset -gt $stream.Length) { $Offset = $stream.Length; $consumed = $Offset }
        [void]$stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)

        $buffer = New-Object byte[] $ChunkBytes
        # Bytes of a line that straddles two reads.
        $carry = [System.IO.MemoryStream]::new()
        $position = $Offset
        $firstLine = ($Offset -eq 0)

        while ($true) {
            $n = $stream.Read($buffer, 0, $ChunkBytes)
            if ($n -le 0) { $atEnd = $true; break }
            $read += $n
            $start = 0
            while ($start -lt $n) {
                $nl = [Array]::IndexOf($buffer, [byte]10, $start, $n - $start)
                if ($nl -lt 0) {
                    $carry.Write($buffer, $start, $n - $start)
                    break
                }

                if ($carry.Length -gt 0) {
                    $carry.Write($buffer, $start, $nl - $start)
                    $bytes = $carry.ToArray()
                    $carry.SetLength(0)
                    $len = $bytes.Length
                    if ($len -gt 0 -and $bytes[$len - 1] -eq 13) { $len-- }
                    $text = $utf8.GetString($bytes, 0, $len)
                } else {
                    $len = $nl - $start
                    if ($len -gt 0 -and $buffer[$start + $len - 1] -eq 13) { $len-- }
                    $text = $utf8.GetString($buffer, $start, $len)
                }

                if ($firstLine) {
                    # Windows PowerShell 5.1's Set-Content -Encoding UTF8 writes a BOM.
                    $text = $text.TrimStart([char]0xFEFF)
                    $firstLine = $false
                }

                $keep = $true
                if ($MustContain) {
                    $keep = $false
                    foreach ($needle in $MustContain) {
                        if ($text.IndexOf($needle, [System.StringComparison]::Ordinal) -ge 0) { $keep = $true; break }
                    }
                }
                if ($keep) { $lines.Add($text) }

                $consumed = $position + $nl + 1
                $start = $nl + 1
            }
            $position += $n
            if ($MaxBytes -gt 0 -and $read -ge $MaxBytes -and $consumed -gt $Offset) { break }
        }
    } finally {
        $stream.Dispose()
    }

    $script:CodexBytesRead += $read
    return @{ Lines = $lines.ToArray(); NextOffset = [long]$consumed; BytesRead = [long]$read; AtEnd = $atEnd }
}

# SHA-256 of a file's first $Length bytes (fewer if the file is shorter).
function Get-CodexFileHead {
    param([string]$Path, [int]$Length)

    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try {
        $want = [int][Math]::Min([long]$Length, $stream.Length)
        $bytes = New-Object byte[] $want
        $got = 0
        while ($got -lt $want) {
            $n = $stream.Read($bytes, $got, $want - $got)
            if ($n -le 0) { break }
            $got += $n
        }
    } finally {
        $stream.Dispose()
    }

    $script:CodexBytesRead += $got
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes, 0, $got))).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
    return @{ Length = $got; Hash = $hash }
}

# Everything the per-line parse carries forward, so a poll can resume where the
# last one stopped instead of re-reading the file.
function New-CodexParseState {
    return @{
        HasUsage       = $false
        PreviousUsage  = @{ input_tokens = 0L; cached_input_tokens = 0L; output_tokens = 0L }
        LastModel      = $null
        SessionId      = $null
        SessionDate    = $null
        MessageDates   = [System.Collections.Generic.List[datetime]]::new()
        LastTokenDate  = $null
        LastRateLimits = $null
        TokenRecords   = [System.Collections.Generic.List[object]]::new()
    }
}

# Folds session-log lines into $State, one at a time and in order.
function Update-CodexParseState {
    param($State, [string[]]$Lines, [string]$FallbackSessionId)

    foreach ($line in $Lines) {
        if (-not $line) { continue }

        try {
            $o = ConvertFrom-Json -InputObject $line -ErrorAction Stop
        } catch {
            continue
        }

        if ($o.type -eq 'session_meta') {
            if ($o.payload.session_id) {
                $State.SessionId = [string]$o.payload.session_id
            } elseif ($o.payload.id) {
                $State.SessionId = [string]$o.payload.id
            }
            $metaDate = Convert-CodexTimestamp $o.payload.timestamp
            if (-not $metaDate) {
                $metaDate = Convert-CodexTimestamp $o.timestamp
            }
            if ($metaDate) {
                $State.SessionDate = $metaDate
            }
        } elseif ($o.type -eq 'turn_context') {
            if ($o.payload.model) {
                $State.LastModel = [string]$o.payload.model
            }
        } elseif (($o.type -eq 'token_count') -or
                  (($o.type -eq 'event_msg') -and ($o.payload.type -eq 'token_count'))) {
            $usage = $o.payload.info.total_token_usage
            $limits = $o.payload.rate_limits
            if (-not $limits) {
                $limits = $o.rate_limits
            }
            if ($usage) {
                $State.HasUsage = $true
                $State.LastRateLimits = $limits
                $tokenDate = Convert-CodexTimestamp $o.timestamp
                if ($tokenDate) {
                    $State.LastTokenDate = $tokenDate
                    # Cumulative counters are snapshots. Attribute only their
                    # increments to the observation's date and active model.
                    $previous = $State.PreviousUsage
                    $deltaIn = [long]$usage.input_tokens - [long]$previous.input_tokens
                    $deltaCached = [long]$usage.cached_input_tokens - [long]$previous.cached_input_tokens
                    $deltaOut = [long]$usage.output_tokens - [long]$previous.output_tokens
                    if ($deltaIn -ge 0 -and $deltaCached -ge 0 -and $deltaOut -ge 0) {
                        if ($deltaIn -gt 0 -or $deltaOut -gt 0) {
                            $model = $State.LastModel
                            if (-not $model) { $model = 'default' }
                            $sessionName = $State.SessionId
                            if (-not $sessionName) { $sessionName = $FallbackSessionId }
                            $State.TokenRecords.Add(@{
                                Model = $model
                                Date = $tokenDate; In = $deltaIn; CachedIn = $deltaCached; Out = $deltaOut
                                SessionId = $sessionName
                                MessageDates = @()
                            })
                        }
                    } else {
                        Write-CodexLog 'Codex cumulative counters decreased; exact attribution is unavailable for this boundary'
                    }
                    $State.PreviousUsage = @{
                        input_tokens        = [long]$usage.input_tokens
                        cached_input_tokens = [long]$usage.cached_input_tokens
                        output_tokens       = [long]$usage.output_tokens
                    }
                }
            }
        } elseif (($o.type -eq 'event_msg') -and ($o.payload.type -eq 'user_message')) {
            $msgDate = Convert-CodexTimestamp $o.timestamp
            if ($msgDate) { [void]$State.MessageDates.Add($msgDate) }
        }
    }
}

# The file's records as Measure-CodexStats expects them: every token increment,
# then one message/session summary record built from the state.
function Complete-CodexFileRecords {
    param($State, [string]$FallbackSessionId, [datetime]$FallbackDate)

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $State.TokenRecords) { $records.Add($r) }

    if ($State.HasUsage -or $State.SessionId -or $State.MessageDates.Count -gt 0) {
        $recordDate = $State.SessionDate
        if (-not $recordDate) { $recordDate = $State.LastTokenDate }
        if (-not $recordDate) { $recordDate = $FallbackDate }

        $modelName = $State.LastModel
        if (-not $modelName) { $modelName = 'default' }

        $sessionName = $State.SessionId
        if (-not $sessionName) { $sessionName = $FallbackSessionId }

        # Message/session metadata is separate from token increments.
        $records.Add(@{
            Model        = $modelName
            Date         = $recordDate
            In           = 0L
            CachedIn     = 0L
            Out          = 0L
            SessionId    = [string]$sessionName
            MessageDates = $State.MessageDates.ToArray()
        })
    }

    $fileTokenDate = $State.LastTokenDate
    if ($State.HasUsage) {
        if (-not $fileTokenDate) { $fileTokenDate = $State.SessionDate }
        if (-not $fileTokenDate) { $fileTokenDate = $FallbackDate }
    }

    return @{ Records = $records; FileTokenDate = $fileTokenDate }
}

function ConvertFrom-CodexCachedState {
    param($Saved)

    $state = New-CodexParseState
    if (-not $Saved) { return $state }

    $state.HasUsage = [bool]$Saved.HasUsage
    if ($Saved.PreviousUsage) {
        $state.PreviousUsage = @{
            input_tokens        = [long]$Saved.PreviousUsage.input_tokens
            cached_input_tokens = [long]$Saved.PreviousUsage.cached_input_tokens
            output_tokens       = [long]$Saved.PreviousUsage.output_tokens
        }
    }
    if ($Saved.LastModel) { $state.LastModel = [string]$Saved.LastModel }
    if ($Saved.SessionId) { $state.SessionId = [string]$Saved.SessionId }
    $state.SessionDate = Convert-CodexCacheDate $Saved.SessionDate
    foreach ($d in @($Saved.MessageDates)) {
        $cd = Convert-CodexCacheDate $d
        if ($cd) { [void]$state.MessageDates.Add($cd) }
    }
    $state.LastTokenDate = Convert-CodexCacheDate $Saved.LastTokenDate
    $state.LastRateLimits = $Saved.LastRateLimits
    foreach ($r in (Convert-CodexCacheRecords $Saved.TokenRecords)) { $state.TokenRecords.Add($r) }
    return $state
}

function Import-CodexStatsFileCache {
    param([string]$CachePath)

    if (-not $CachePath -or -not (Test-Path $CachePath)) { return }

    try {
        $raw = Get-Content $CachePath -Raw -Encoding UTF8 -ErrorAction Stop
        if (-not $raw) { return }

        $json = $raw | ConvertFrom-Json -ErrorAction Stop
        $loaded = @{}

        foreach ($prop in $json.PSObject.Properties) {
            $entry = $prop.Value
            if (-not $entry -or -not $entry.Stamp -or $entry.CacheVersion -ne $script:CodexCacheVersion) { continue }

            $loaded[$prop.Name] = @{
                CacheVersion = $script:CodexCacheVersion
                Stamp        = [string]$entry.Stamp
                Offset       = [long]$entry.Offset
                HeadLength   = [int]$entry.HeadLength
                HeadHash     = [string]$entry.HeadHash
                State        = ConvertFrom-CodexCachedState $entry.State
            }
        }

        $script:CodexStatsFileCache = $loaded
    } catch {
        Write-CodexLog "Get-CodexStats: failed to load cache $CachePath - $($_.Exception.Message)"
    }
}

function Export-CodexStatsFileCache {
    param([string]$CachePath)

    if (-not $CachePath) { return }

    try {
        $script:CodexStatsFileCache |
            ConvertTo-Json -Depth 12 |
            Set-Content -Path $CachePath -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-CodexLog "Get-CodexStats: failed to save cache $CachePath - $($_.Exception.Message)"
    }
}

function Write-CodexLog {
    param([string]$Message)
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log $Message
    }
}

function Convert-CodexTimestamp {
    param($Value)

    if (-not $Value) { return $null }

    try {
        if ($Value -is [string]) {
            return [System.DateTimeOffset]::Parse($Value).LocalDateTime
        }
        return ([datetime]$Value).ToLocalTime()
    } catch {
        return $null
    }
}

function Convert-CodexEpochSeconds {
    param($Value)

    if ($null -eq $Value) { return $null }

    try {
        return [System.DateTimeOffset]::FromUnixTimeSeconds([long][double]$Value).LocalDateTime
    } catch {
        return $null
    }
}

function Test-CodexUsageAfterHours([datetime]$Date) {
    $startHour = if ($null -ne $script:WorkdayStartHour) { [int]$script:WorkdayStartHour } else { 8 }
    $endHour = if ($null -ne $script:WorkdayEndHour) { [int]$script:WorkdayEndHour } else { 18 }
    if ($Date.DayOfWeek -in @([System.DayOfWeek]::Saturday, [System.DayOfWeek]::Sunday)) { return $true }
    return ($Date.Hour -lt $startHour -or $Date.Hour -ge $endHour)
}

function Estimate-CodexCost([string]$model, $v) {
    if (-not $script:CodexPrices) { throw 'Estimate-CodexCost: $script:CodexPrices not loaded - dot-source Config.ps1 first.' }

    if ($model -eq 'default') {
        $tier = 'default'
    } elseif ($model -match '^gpt-5') {
        if ($script:CodexPrices.ContainsKey($model)) {
            $tier = $model
        } else {
            $tier = 'gpt-5.5'
        }
    } else {
        $tier = 'default'
        # Logged once per model: this runs for every usage record, and logging
        # each one grew the error log to tens of megabytes.
        if (-not $script:CodexUnknownModels) { $script:CodexUnknownModels = @{} }
        if ($model -and -not $script:CodexUnknownModels.ContainsKey($model)) {
            $script:CodexUnknownModels[$model] = $true
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log "Unknown Codex model '$model' - falling back to default pricing (verify prices)"
            }
        }
    }

    if (-not $script:CodexPrices.ContainsKey($tier)) {
        $tier = 'default'
    }

    $p = $script:CodexPrices[$tier]
    $inputTokens = [decimal]$v.inputTokens
    $cachedInputTokens = [decimal]$v.cachedInputTokens
    $outputTokens = [decimal]$v.outputTokens
    $uncachedInputTokens = [Math]::Max([decimal]0, $inputTokens - $cachedInputTokens)

    return ($uncachedInputTokens / 1000000 * [decimal]$p.in) +
           ($cachedInputTokens   / 1000000 * [decimal]$p.cachedIn) +
           ($outputTokens        / 1000000 * [decimal]$p.out)
}

function Measure-CodexStats([object[]]$records, [datetime]$today, $rateLimits = $null) {
    $val = [decimal]0; $tin = 0L; $tout = 0L
    $sessions = [System.Collections.Generic.HashSet[string]]::new()
    $msgCount = 0; $tMsg = 0; $tTok = 0L; $afterHoursMsg = 0; $afterHoursTok = 0L
    $fiveHourPct = $null
    $fiveHourResetsAt = $null
    $weekPct = $null
    $weekResetsAt = $null
    $currentModel = $null
    $latestModelDate = $null

    foreach ($r in $records) {
        $v = @{
            inputTokens       = [long]$r.In
            cachedInputTokens = [long]$r.CachedIn
            outputTokens      = [long]$r.Out
        }
        $val  += Estimate-CodexCost $r.Model $v
        $tin  += [long]$r.In
        $tout += [long]$r.Out
        [void]$sessions.Add([string]$r.SessionId)

        $messageDates = if ($null -eq $r.MessageDates) { @() } else { @($r.MessageDates) }
        if ($null -eq $r.MessageDates) {
            $messageDates = @($r.Date)
        }
        $msgCount += $messageDates.Count
        foreach ($messageDate in $messageDates) {
            if ($messageDate.Date -eq $today.Date) {
                $tMsg++
                if (Test-CodexUsageAfterHours $messageDate) { $afterHoursMsg++ }
            }
        }

        if ($r.Date.Date -eq $today.Date) {
            $tTok += [long]$r.In + [long]$r.Out
            if (Test-CodexUsageAfterHours $r.Date) { $afterHoursTok += [long]$r.In + [long]$r.Out }
        }

        # Current model = the model of the most recent session that named one
        # ('default' is the fallback for sessions with no turn_context).
        if ($r.Model -and $r.Model -ne 'default' -and ((-not $latestModelDate) -or ($r.Date -gt $latestModelDate))) {
            $latestModelDate = $r.Date
            $currentModel = $r.Model
        }
    }

    if ($rateLimits) {
        # Codex reports one or two rate-limit windows. Historically the short
        # (5-hour) window was 'primary' and the weekly window was 'secondary',
        # but newer Codex plans surface only the weekly limit and carry it in
        # the 'primary' slot. Match the actual 300/10080-minute durations and
        # fall back to the legacy slot convention only when
        # Codex omits the window metadata.
        $fiveHour = $null
        $weekly   = $null

        $candidates = @()
        if ($rateLimits.primary)   { $candidates += $rateLimits.primary }
        if ($rateLimits.secondary) { $candidates += $rateLimits.secondary }

        $withWindows = @($candidates | Where-Object {
            ($null -ne $_.window_minutes) -and ($null -ne $_.used_percent)
        })

        if ($withWindows.Count -gt 0) {
            $fiveHour = $withWindows | Where-Object { $_.window_minutes -eq 300 } | Select-Object -First 1
            $weekly = $withWindows | Where-Object { $_.window_minutes -eq 10080 } | Select-Object -First 1
        } else {
            $fiveHour = $rateLimits.primary
            $weekly   = $rateLimits.secondary
        }

        if ($fiveHour) {
            if ($null -ne $fiveHour.used_percent) { $fiveHourPct = [double]$fiveHour.used_percent }
            if ($null -ne $fiveHour.resets_at)    { $fiveHourResetsAt = Convert-CodexEpochSeconds $fiveHour.resets_at }
        }
        if ($weekly) {
            if ($null -ne $weekly.used_percent) { $weekPct = [double]$weekly.used_percent }
            if ($null -ne $weekly.resets_at)    { $weekResetsAt = Convert-CodexEpochSeconds $weekly.resets_at }
        }
    }

    return @{
        ValueUSD         = $val
        InTokens         = $tin
        OutTokens        = $tout
        Sessions         = $sessions.Count
        Messages         = $msgCount
        TodayMsg         = $tMsg
        TodayTok         = $tTok
        TodayAfterHoursMsg = $afterHoursMsg
        TodayAfterHoursTok = $afterHoursTok
        FiveHourPct      = $fiveHourPct
        FiveHourResetsAt = $fiveHourResetsAt
        WeekPct          = $weekPct
        WeekResetsAt     = $weekResetsAt
        ResetsAvailable  = $null
        PlanType         = $null
        Model            = $currentModel
        LastComputed     = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    }
}

# Parse the Codex live usage endpoint (chatgpt.com/backend-api/wham/usage)
# response into overlay fields. Match explicit five-hour/seven-day durations; the reset
# credit count backs the "N resets available" line. Pure so it can be tested
# without a network call.
function ConvertFrom-CodexUsageResponse($obj) {
    if (-not $obj) { return $null }

    $weekPct = $null; $weekResetsAt = $null
    $fiveHourPct = $null; $fiveHourResetsAt = $null

    $rl = $obj.rate_limit
    if ($rl) {
        $windows = @()
        if ($rl.primary_window)   { $windows += $rl.primary_window }
        if ($rl.secondary_window) { $windows += $rl.secondary_window }

        $withSecs = @($windows | Where-Object {
            ($null -ne $_.limit_window_seconds) -and ($null -ne $_.used_percent)
        })

        $weekly = $null; $fiveHour = $null
        $fiveHour = $withSecs | Where-Object { $_.limit_window_seconds -eq 18000 } | Select-Object -First 1
        $weekly = $withSecs | Where-Object { $_.limit_window_seconds -eq 604800 } | Select-Object -First 1

        if ($weekly) {
            if ($null -ne $weekly.used_percent) { $weekPct = [double]$weekly.used_percent }
            if ($null -ne $weekly.reset_at)     { $weekResetsAt = Convert-CodexEpochSeconds $weekly.reset_at }
        }
        if ($fiveHour) {
            if ($null -ne $fiveHour.used_percent) { $fiveHourPct = [double]$fiveHour.used_percent }
            if ($null -ne $fiveHour.reset_at)     { $fiveHourResetsAt = Convert-CodexEpochSeconds $fiveHour.reset_at }
        }
    }

    $resetsAvailable = $null
    if ($obj.rate_limit_reset_credits -and ($null -ne $obj.rate_limit_reset_credits.available_count)) {
        $resetsAvailable = [int]$obj.rate_limit_reset_credits.available_count
    }

    return @{
        WeekPct          = $weekPct
        WeekResetsAt     = $weekResetsAt
        FiveHourPct      = $fiveHourPct
        FiveHourResetsAt = $fiveHourResetsAt
        ResetsAvailable  = $resetsAvailable
        PlanType         = $obj.plan_type
    }
}

# Fetch live Codex usage from the ChatGPT backend using the local Codex OAuth
# token. The new Codex no longer records rate limits in session logs, so this
# authenticated call is the only source for the weekly bar and reset credits.
# Returns $null on any failure (missing/expired token, network error) so the
# overlay falls back to whatever it already has instead of breaking.
function Get-CodexLiveUsage {
    param(
        [int]$TimeoutSec = 15,
        [string]$AuthPath
    )

    $authPath = if ($AuthPath) { $AuthPath } elseif ($env:CODEX_HOME) { Join-Path $env:CODEX_HOME 'auth.json' } else { Join-Path $env:USERPROFILE '.codex\auth.json' }
    if (-not (Test-Path -LiteralPath $authPath)) {
        Set-CodexAuthState 'notoken' 'No Codex login found - run codex login'
        return $null
    }

    try {
        $auth = Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json
    } catch {
        Write-CodexLog 'Get-CodexLiveUsage: cannot read auth.json'
        Set-CodexAuthState 'notoken' 'Cannot read Codex auth.json - run codex login'
        return $null
    }

    $token = $null
    if ($auth.tokens -and $auth.tokens.access_token) { $token = $auth.tokens.access_token }
    elseif ($auth.access_token) { $token = $auth.access_token }
    if (-not $token) {
        Set-CodexAuthState 'notoken' 'No Codex access token - run codex login'
        return $null
    }

    $acct = $auth.account_id
    if (-not $acct -and $auth.tokens) { $acct = $auth.tokens.account_id }

    $headers = @{
        'Authorization' = "Bearer $token"
        'originator'    = 'codex_cli_rs'
        'User-Agent'    = 'codex_cli_rs/0.144.2 (ai-usage-overlay)'
        'Accept'        = 'application/json'
    }
    if ($acct) { $headers['chatgpt-account-id'] = "$acct" }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $resp = Invoke-RestMethod -Uri 'https://chatgpt.com/backend-api/wham/usage' `
            -Headers $headers -Method GET -TimeoutSec $TimeoutSec
        if (-not $resp -or -not $resp.rate_limit) { throw 'Unrecognized Codex usage response' }
        Set-CodexAuthState 'ok' ''
        return ConvertFrom-CodexUsageResponse $resp
    } catch {
        $message = $_.Exception.Message

        # Both the access token AND the refresh token expire, and once the
        # refresh token is gone no code path can recover it - only an interactive
        # `codex login`. Name that remedy instead of echoing a bare 401.
        $code = $null
        if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
        Write-CodexLog "Get-CodexLiveUsage: request failed (HTTP $code)"
        if ($code -eq 401 -or $message -match '\b401\b') {
            Set-CodexAuthState 'auth' 'Codex login expired - run codex login'
        } else {
            Set-CodexAuthState 'stale' 'Codex usage unavailable; retry later'
        }
        return $null
    }
}

function Get-CodexStats {
    $cachePath = Join-Path $script:AppDir 'codex-cache.json'
    Import-CodexStatsFileCache $cachePath
    $sessionsDir = Resolve-CodexSessionsDir
    if ($sessionsDir) {
        $script:CodexSessionsDir = $sessionsDir
    }

    $candidateDirs = [System.Collections.Generic.List[string]]::new()
    if ($script:CodexSessionsDir) { [void]$candidateDirs.Add($script:CodexSessionsDir) }
    foreach ($dir in Get-CodexSessionDirCandidates) {
        if ($dir) { [void]$candidateDirs.Add($dir) }
    }

    $sessionDirs = [System.Collections.Generic.List[string]]::new()
    foreach ($dir in @($candidateDirs | Select-Object -Unique)) {
        try {
            if (Test-Path -LiteralPath $dir -PathType Container -ErrorAction SilentlyContinue) {
                [void]$sessionDirs.Add($dir)
            }
        } catch { }
    }

    if ($sessionDirs.Count -eq 0) {
        $candidateText = (@($candidateDirs | Select-Object -Unique)) -join '; '
        Write-CodexLog "Get-CodexStats: Codex sessions directory not found - checked: $candidateText"
        # Live account limits do not depend on local transcript availability.
    }

    $files = [System.Collections.Generic.List[object]]::new()
    foreach ($dir in $sessionDirs) {
        try {
            foreach ($file in @(Get-ChildItem -LiteralPath $dir -Recurse -Filter '*.jsonl' -File -ErrorAction Stop)) {
                [void]$files.Add($file)
            }
        } catch {
            Write-CodexLog "Get-CodexStats: failed to enumerate sessions in $dir - $($_.Exception.Message)"
        }
    }

    $allRecords = [System.Collections.Generic.List[object]]::new()
    $latestRateLimits = $null
    $latestTokenDate = $null
    $activeCache = @{}

    $budget = [System.Diagnostics.Stopwatch]::StartNew()
    $stopped = $false
    $parsedAny = $false

    foreach ($file in $files) {
        $stamp = "$($file.LastWriteTimeUtc.Ticks):$($file.Length)"
        $cached = $script:CodexStatsFileCache[$file.FullName]

        if ($cached -and $cached.Stamp -eq $stamp) {
            $entry = $cached
        } else {
            # Out of budget: leave this file for the next poll, but always make
            # at least one slice of progress per poll.
            if ($parsedAny -and $budget.Elapsed.TotalSeconds -ge $script:CodexParseBudgetSeconds) {
                $stopped = $true
                break
            }

            # Resume from where the last poll stopped when the file has only
            # grown and its head is unchanged; otherwise it was replaced or
            # truncated, so parse it from the start.
            $state = $null
            $offset = 0L
            if ($cached -and $cached.State -and $cached.HeadLength -gt 0 -and $file.Length -ge $cached.Offset) {
                try {
                    $head = Get-CodexFileHead -Path $file.FullName -Length $cached.HeadLength
                    if ($head.Length -eq $cached.HeadLength -and $head.Hash -eq $cached.HeadHash) {
                        $state = $cached.State
                        $offset = [long]$cached.Offset
                    }
                } catch { }
            }
            if (-not $state) { $state = New-CodexParseState }
            $startOffset = $offset

            $unreadable = $false
            $atEnd = $false
            while (-not $atEnd) {
                try {
                    $read = Read-CodexNewLines -Path $file.FullName -Offset $offset -MustContain $script:CodexRelevantNeedles -MaxBytes $script:CodexSliceBytes
                } catch {
                    Write-CodexLog "Get-CodexStats: skipping unreadable file $($file.FullName) - $($_.Exception.Message)"
                    $unreadable = $true
                    break
                }
                Update-CodexParseState -State $state -Lines $read.Lines -FallbackSessionId $file.BaseName
                $offset = [long]$read.NextOffset
                $atEnd = [bool]$read.AtEnd
                $parsedAny = $true
                if (-not $atEnd -and $budget.Elapsed.TotalSeconds -ge $script:CodexParseBudgetSeconds) {
                    $stopped = $true
                    break
                }
            }
            if ($unreadable) { continue }

            # The head only needs re-hashing while it is still shorter than the
            # fingerprint window; once full, appends cannot change it.
            $headLength = 0
            $headHash = ''
            if ($startOffset -gt 0 -and $cached.HeadLength -ge $script:CodexHeadBytes) {
                $headLength = $cached.HeadLength
                $headHash = $cached.HeadHash
            } else {
                try {
                    $head = Get-CodexFileHead -Path $file.FullName -Length $script:CodexHeadBytes
                    $headLength = $head.Length
                    $headHash = $head.Hash
                } catch { }
            }

            # A file left part-way gets a stamp that can never match a real one
            # ("ticks:length"), so the next poll resumes it. Not empty: the
            # cache loader drops entries without a stamp, which would throw the
            # saved progress away and restart the parse on every poll.
            $entryStamp = $stamp
            if ($stopped) { $entryStamp = 'partial' }

            $entry = @{
                CacheVersion = $script:CodexCacheVersion
                Stamp        = $entryStamp
                Offset       = $offset
                HeadLength   = $headLength
                HeadHash     = $headHash
                State        = $state
            }
        }

        $activeCache[$file.FullName] = $entry
        if ($stopped) { break }

        $done = Complete-CodexFileRecords -State $entry.State -FallbackSessionId $file.BaseName -FallbackDate $file.LastWriteTime
        foreach ($r in $done.Records) {
            $allRecords.Add($r)
        }
        $fileTokenDate = $done.FileTokenDate
        if ($fileTokenDate -and ((-not $latestTokenDate) -or ($fileTokenDate -gt $latestTokenDate))) {
            $latestTokenDate = $fileTokenDate
            $latestRateLimits = $entry.State.LastRateLimits
        }
    }

    if ($stopped) {
        # Bank the progress and keep every file this poll did not reach, then
        # publish nothing: partial totals would read as real numbers.
        foreach ($key in @($script:CodexStatsFileCache.Keys)) {
            if (-not $activeCache.ContainsKey($key)) { $activeCache[$key] = $script:CodexStatsFileCache[$key] }
        }
        $script:CodexStatsFileCache = $activeCache
        Export-CodexStatsFileCache $cachePath
        Write-CodexLog 'Get-CodexStats: still catching up on session logs; progress saved for the next poll'
        return
    }

    $script:CodexStatsFileCache = $activeCache
    Export-CodexStatsFileCache $cachePath

    try {
        if ($sessionDirs.Count -gt 0) {
            $script:CodexStats = Measure-CodexStats $allRecords.ToArray() (Get-Date) $latestRateLimits
        }
    } catch {
        Write-CodexLog "Get-CodexStats: Measure-CodexStats failed - $($_.Exception.Message)"
    }

    # The current Codex no longer persists rate limits to session logs, so the
    # weekly bar and reset-credit count come from the live usage endpoint. Prefer
    # live values when available; otherwise keep whatever the logs provided.
    try {
        $live = Get-CodexLiveUsage
        if ($live) {
            if (-not $script:CodexStats) {
                $script:CodexStats = Measure-CodexStats @() (Get-Date)
            }
            $script:CodexStats.WeekPct = $live.WeekPct
            $script:CodexStats.WeekResetsAt = $live.WeekResetsAt
            $script:CodexStats.FiveHourPct = $live.FiveHourPct
            $script:CodexStats.FiveHourResetsAt = $live.FiveHourResetsAt
            $script:CodexStats.ResetsAvailable = $live.ResetsAvailable
            if ($live.PlanType) { $script:CodexStats.PlanType = $live.PlanType }
        }
    } catch {
        Write-CodexLog "Get-CodexStats: live usage merge failed - $($_.Exception.Message)"
    }
}
