# GrokData.ps1 - SuperGrok / grok CLI billing adapter
#
# Same auth contract as Codex: init | ok | stale | auth | notoken + message.
# Never log or snapshot the bearer token.

$script:GrokAuthState = 'init'
$script:GrokErrMsg    = ''
$script:GrokUsage     = $null

function Set-GrokAuthState {
    param([string]$State, [string]$Message = '')

    $script:GrokAuthState = $State
    $script:GrokErrMsg    = $Message
}

function Write-GrokLog {
    param([string]$Message)
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log $Message
    }
}

function Resolve-GrokAuthPath {
    param([string]$AuthPath)

    if ($AuthPath) { return $AuthPath }

    if ($env:GROK_HOME) {
        try { return (Join-Path $env:GROK_HOME 'auth.json') } catch { }
    }

    foreach ($root in @($env:USERPROFILE, $env:HOME)) {
        if ($root) {
            try { return (Join-Path (Join-Path $root '.grok') 'auth.json') } catch { }
        }
    }

    return (Join-Path $env:USERPROFILE '.grok\auth.json')
}

function Get-GrokNoteValue {
    param($Obj, [string]$Name)

    if (-not $Obj -or -not $Name) { return $null }

    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] }
        return $null
    }

    if ($Obj.PSObject -and $Obj.PSObject.Properties[$Name]) {
        return $Obj.PSObject.Properties[$Name].Value
    }

    return $null
}

function Test-GrokAuthEntryExpired {
    param($Entry)

    $raw = Get-GrokNoteValue $Entry 'expires_at'
    if (-not $raw) { return $false }

    try {
        $exp = [datetimeoffset]::Parse([string]$raw)
        return ($exp -le [datetimeoffset]::Now)
    } catch {
        return $false
    }
}

function Get-GrokTokenFromEntry {
    param($Entry)

    if (-not $Entry) { return $null }
    if (Test-GrokAuthEntryExpired $Entry) { return $null }

    foreach ($name in @('key', 'access_token')) {
        $val = Get-GrokNoteValue $Entry $name
        if ($val -is [string] -and $val) { return $val }
    }

    $tokens = Get-GrokNoteValue $Entry 'tokens'
    $nested = Get-GrokNoteValue $tokens 'access_token'
    if ($nested -is [string] -and $nested) { return $nested }

    return $null
}

function Get-GrokAccessToken {
    param($Auth)

    if (-not $Auth) { return $null }

    $preferred = [System.Collections.Generic.List[object]]::new()
    $fallback  = [System.Collections.Generic.List[object]]::new()

    if ($Auth.PSObject) {
        foreach ($prop in $Auth.PSObject.Properties) {
            $val = $prop.Value
            if ($null -eq $val -or $val -is [string] -or $val -is [ValueType]) { continue }
            if ($prop.Name -like 'https://auth.x.ai::*') {
                [void]$preferred.Add($val)
            } else {
                [void]$fallback.Add($val)
            }
        }
    }

    foreach ($entry in $preferred) {
        $token = Get-GrokTokenFromEntry $entry
        if ($token) { return $token }
    }
    foreach ($entry in $fallback) {
        $token = Get-GrokTokenFromEntry $entry
        if ($token) { return $token }
    }

    return Get-GrokTokenFromEntry $Auth
}

function Convert-GrokPeriodEnd {
    param($Value)

    if (-not $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }

    try {
        return [System.DateTimeOffset]::Parse([string]$Value).LocalDateTime
    } catch {
        return $null
    }
}

function Convert-GrokPrepaidText {
    param($Value)

    if ($null -eq $Value) { return $null }

    if ($Value -is [ValueType]) {
        try { return ('{0:N2}' -f [double]$Value) } catch { return [string]$Value }
    }

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($name in @('val', 'amount', 'balance', 'credits', 'remaining', 'value')) {
            if ($Value.Contains($name) -and $null -ne $Value[$name]) {
                try { return ('{0:N2}' -f [double]$Value[$name]) } catch { return [string]$Value[$name] }
            }
        }
        return $null
    }

    $amount = $null
    foreach ($name in @('val', 'amount', 'balance', 'credits', 'remaining', 'value')) {
        $prop = $Value.PSObject.Properties[$name]
        if ($prop -and $null -ne $prop.Value) {
            $amount = $prop.Value
            break
        }
    }
    if ($null -eq $amount) { return $null }
    try { return ('{0:N2}' -f [double]$amount) } catch { return [string]$amount }
}

function Format-GrokProductChip {
    param(
        [string]$Name,
        $Qty,
        [switch]$AsPercent
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    if ($null -eq $Qty) { return $Name }
    try {
        $n = [double]$Qty
        if ($AsPercent) { return ('{0} {1:0}%' -f $Name, $n) }
        return ('{0} {1}' -f $Name, $Qty)
    } catch {
        return ('{0} {1}' -f $Name, $Qty)
    }
}

function Format-GrokProductUsage {
    # Stacked chips "GrokChat 20%\nGrokBuild 5%" (not a wrapping one-liner).
    # usagePercent is a qty on a named product — never emit "usagePercent 20".
    param($Usage)

    if ($null -eq $Usage) { return $null }

    $sep = [Environment]::NewLine
    $parts = [System.Collections.Generic.List[string]]::new()
    $items = if ($Usage -is [System.Collections.IEnumerable] -and $Usage -isnot [string]) { @($Usage) } else { @($Usage) }
    foreach ($item in $items) {
        if ($null -eq $item) { continue }
        if ($item -is [System.Collections.IDictionary]) {
            foreach ($k in @($item.Keys)) {
                if ($null -eq $item[$k]) { continue }
                $chip = Format-GrokProductChip -Name ([string]$k) -Qty $item[$k] -AsPercent
                if ($chip) { [void]$parts.Add($chip) }
            }
            continue
        }
        if ($item.PSObject) {
            $named = $null
            $qty = $null
            $asPct = $false
            foreach ($prop in $item.PSObject.Properties) {
                if ($prop.Name -in @('product', 'name')) {
                    $named = [string]$prop.Value
                    continue
                }
                if ($prop.Name -in @('usagePercent', 'percent', 'creditUsagePercent') -and $null -ne $prop.Value) {
                    $qty = $prop.Value
                    $asPct = $true
                    continue
                }
                if ($prop.Name -in @('count', 'usage', 'credits', 'val', 'value', 'amount') -and $null -ne $prop.Value) {
                    $qty = $prop.Value
                    continue
                }
            }
            if ($named) {
                $chip = Format-GrokProductChip -Name $named -Qty $qty -AsPercent:$asPct
                if ($chip) { [void]$parts.Add($chip) }
                continue
            }
            # Shorthand notes: { GrokChat = 20 } with no product/name field.
            foreach ($prop in $item.PSObject.Properties) {
                if ($prop.Name -in @('product', 'name', 'usagePercent', 'percent', 'creditUsagePercent', 'count', 'usage', 'credits', 'val', 'value', 'amount')) {
                    continue
                }
                if ($null -eq $prop.Value) { continue }
                if (-not ($prop.Value -is [ValueType] -or $prop.Value -is [string])) { continue }
                $chip = Format-GrokProductChip -Name ([string]$prop.Name) -Qty $prop.Value -AsPercent
                if ($chip) { [void]$parts.Add($chip) }
            }
        }
    }
    if ($parts.Count -eq 0) { return $null }
    return ($parts -join $sep)
}
function Convert-GrokPlanType {
    param($Obj)

    if (-not $Obj) { return $null }

    foreach ($candidate in @(
        $Obj.product,
        $(if ($Obj.config) { $Obj.config.product }),
        $(if ($Obj.config) { $Obj.config.plan }),
        $Obj.plan,
        $Obj.planType
    )) {
        if ($candidate) { return [string]$candidate }
    }

    $usage = $Obj.productUsage
    if (-not $usage -and $Obj.config) { $usage = $Obj.config.productUsage }
    if ($usage) {
        if ($usage -is [System.Collections.IEnumerable] -and $usage -isnot [string]) {
            foreach ($item in @($usage)) {
                if ($item -and $item.product) { return [string]$item.product }
                if ($item -and $item.name) { return [string]$item.name }
            }
        } elseif ($usage.product) {
            return [string]$usage.product
        }
    }

    return $null
}

# Pure parser so tests do not need a network call. All fields optional.
function ConvertFrom-GrokBillingResponse($obj) {
    if (-not $obj) { return $null }

    $cfg = $obj.config
    $weekPct = $null
    $weekResetsAt = $null

    if ($cfg) {
        if ($null -ne $cfg.creditUsagePercent) {
            try { $weekPct = [double]$cfg.creditUsagePercent } catch { }
        }
        if ($cfg.currentPeriod) {
            $weekResetsAt = Convert-GrokPeriodEnd $cfg.currentPeriod.end
        }
    }

    $prepaidRaw = $null
    $productRaw = $null
    if ($cfg) {
        $prepaidRaw = Get-GrokNoteValue $cfg 'prepaidBalance'
        $productRaw = Get-GrokNoteValue $cfg 'productUsage'
    }
    if ($null -eq $prepaidRaw) { $prepaidRaw = Get-GrokNoteValue $obj 'prepaidBalance' }
    if ($null -eq $productRaw) { $productRaw = Get-GrokNoteValue $obj 'productUsage' }

    $productText = Format-GrokProductUsage $productRaw

    return @{
        WeekPct           = $weekPct
        WeekResetsAt      = $weekResetsAt
        PrepaidBalance    = Convert-GrokPrepaidText $prepaidRaw
        ProductUsage      = $productRaw
        ProductUsageText  = $productText
        PlanType          = Convert-GrokPlanType $obj
    }
}

# Minimal protobuf reader for the observed GetRemainingResets wire schema.
# Token IDs are used only for deduplication and never returned or persisted.
function Read-GrokVarint([byte[]]$Bytes, [ref]$Position) {
    [long]$value = 0
    for ($shift = 0; $shift -le 56; $shift += 7) {
        if ($Position.Value -ge $Bytes.Length) { throw 'Truncated reset varint' }
        $b = $Bytes[$Position.Value]; $Position.Value++
        $value = $value -bor ([long]($b -band 127) -shl $shift)
        if (($b -band 128) -eq 0) { return $value }
    }
    throw 'Invalid reset varint'
}

function Read-GrokWireFields([byte[]]$Bytes) {
    $p = 0
    while ($p -lt $Bytes.Length) {
        $tag = Read-GrokVarint $Bytes ([ref]$p)
        $number = $tag -shr 3; $wire = $tag -band 7
        if ($number -le 0) { throw 'Invalid reset field' }
        if ($wire -eq 0) {
            $value = Read-GrokVarint $Bytes ([ref]$p)
        } else {
            $length = switch ($wire) { 1 { 8 } 2 { Read-GrokVarint $Bytes ([ref]$p) } 5 { 4 } default { throw 'Unsupported reset wire type' } }
            if ($length -gt ($Bytes.Length - $p)) { throw 'Truncated reset field' }
            $value = New-Object byte[] ([int]$length)
            [Array]::Copy($Bytes, $p, $value, 0, [int]$length)
            $p += [int]$length
        }
        [pscustomobject]@{ Number=$number; Wire=$wire; Value=$value }
    }
}

function ConvertFrom-GrokResetsResponse {
    param([byte[]]$Bytes, [datetimeoffset]$Now = [datetimeoffset]::UtcNow)
    $p = 0; $payload = $null; $statusOk = $false
    while ($p -lt $Bytes.Length) {
        if ($Bytes.Length - $p -lt 5) { throw 'Truncated reset frame' }
        $flag = $Bytes[$p]
        [long]$length = ([long]$Bytes[$p+1]*16777216)+([long]$Bytes[$p+2]*65536)+([long]$Bytes[$p+3]*256)+$Bytes[$p+4]
        $p += 5
        if ($length -gt ($Bytes.Length - $p)) { throw 'Truncated reset payload' }
        $body = New-Object byte[] ([int]$length)
        [Array]::Copy($Bytes, $p, $body, 0, [int]$length); $p += [int]$length
        if ($flag -eq 128) {
            $trailers = [Text.Encoding]::ASCII.GetString($body)
            if ($trailers -notmatch '(?m)^grpc-status:\s*0\s*\r?$') { throw 'Reset lookup returned a gRPC error' }
            $statusOk = $true
        } elseif ($flag -eq 0 -and $null -eq $payload -and -not $statusOk) {
            $payload = $body
        } else { throw 'Unexpected reset frame' }
    }
    if (-not $statusOk -or $null -eq $payload) { throw 'Incomplete reset response' }
    $ids = [Collections.Generic.HashSet[string]]::new()
    $expires = $null
    foreach ($entry in @(Read-GrokWireFields $payload)) {
        if ($entry.Number -ne 10) { throw 'Unrecognized reset response schema' }
        if ($entry.Wire -ne 2) { throw 'Invalid reset record' }
        $id = $null; $start = $null; $end = $null
        foreach ($field in @(Read-GrokWireFields $entry.Value)) {
            if ($field.Number -eq 10 -and $field.Wire -eq 2) {
                $id = [Text.Encoding]::UTF8.GetString($field.Value)
            } elseif ($field.Number -in @(20,30) -and $field.Wire -eq 2) {
                $seconds = @(Read-GrokWireFields $field.Value | Where-Object { $_.Number -eq 1 -and $_.Wire -eq 0 })
                if ($seconds.Count -ne 1) { throw 'Invalid reset timestamp' }
                $date = [datetimeoffset]::FromUnixTimeSeconds($seconds[0].Value)
                if ($field.Number -eq 20) { $start = $date } else { $end = $date }
            }
        }
        if ([string]::IsNullOrWhiteSpace($id) -or $null -eq $start -or $null -eq $end -or $end -le $start) { throw 'Incomplete reset token' }
        if ($start -le $Now -and $end -gt $Now) {
            [void]$ids.Add($id)
            if ($null -eq $expires -or $end -lt $expires) { $expires = $end }
        }
    }
    $expiryText = if ($null -ne $expires) { $expires.ToString('o') } else { $null }
    return @{ ResetsAvailable=$ids.Count; ResetExpiresAt=$expiryText; ResetStatus='ok'; ResetsObservedAt=$Now.ToString('o') }
}

function Get-GrokRemainingResets {
    param([string]$Token, [int]$TimeoutSec = 8)
    try {
        $response = Invoke-WebRequest -Uri 'https://grok.com/prod_mc_billing.ConsumerUiSvc/GetRemainingResets' `
            -Method Post -Headers @{ Authorization="Bearer $Token"; 'x-grok-client-mode'='cli'; Accept='application/grpc-web+proto'; 'connect-protocol-version'='1' } `
            -ContentType 'application/grpc-web+proto' -Body ([byte[]]@(0,0,0,0,0)) `
            -UseBasicParsing -TimeoutSec ([math]::Min(8,[math]::Max(1,$TimeoutSec))) -ErrorAction Stop
        $stream = New-Object IO.MemoryStream
        try {
            $response.RawContentStream.Position = 0
            $response.RawContentStream.CopyTo($stream)
            return ConvertFrom-GrokResetsResponse $stream.ToArray()
        } finally { $stream.Dispose() }
    } catch {
        # Reset lookup failure must not discard successfully fetched usage.
        return @{ ResetsAvailable=$null; ResetExpiresAt=$null; ResetStatus='unavailable'; ResetsObservedAt=$null }
    }
}

function Get-GrokLiveUsage {
    param(
        [int]$TimeoutSec = 15,
        [string]$AuthPath
    )

    if ($TimeoutSec -le 0) { $TimeoutSec = 15 }
    $TimeoutSec = [math]::Min(120, [math]::Max(1, $TimeoutSec))

    $path = Resolve-GrokAuthPath -AuthPath $AuthPath
    if (-not (Test-Path -LiteralPath $path)) {
        Set-GrokAuthState 'notoken' 'run grok login'
        return $null
    }

    try {
        $auth = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    } catch {
        Write-GrokLog 'Get-GrokLiveUsage: cannot read auth.json'
        Set-GrokAuthState 'notoken' 'run grok login'
        return $null
    }

    $token = Get-GrokAccessToken $auth
    if (-not $token) {
        Set-GrokAuthState 'notoken' 'run grok login'
        return $null
    }

    $headers = @{
        'Authorization'     = "Bearer $token"
        'x-xai-token-auth'  = 'xai-grok-cli'
        'Accept'            = 'application/json'
        'User-Agent'        = 'grok-cli (ai-usage-overlay)'
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $resp = Invoke-RestMethod -Uri 'https://cli-chat-proxy.grok.com/v1/billing?format=credits' `
            -Headers $headers -Method GET -TimeoutSec $TimeoutSec
        if (-not $resp -or -not $resp.config) { throw 'Unrecognized Grok billing response' }
        Set-GrokAuthState 'ok' ''
        $parsed = ConvertFrom-GrokBillingResponse $resp
        $resetInfo = Get-GrokRemainingResets -Token $token -TimeoutSec $TimeoutSec
        foreach ($key in $resetInfo.Keys) { $parsed[$key] = $resetInfo[$key] }
        $script:GrokUsage = $parsed
        return $parsed
    } catch {
        $message = $_.Exception.Message
        $code = $null
        if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
        Write-GrokLog "Get-GrokLiveUsage: request failed (HTTP $code)"
        if ($code -eq 401 -or $message -match '\b401\b') {
            Set-GrokAuthState 'auth' 'Grok login expired - run grok login'
        } else {
            Set-GrokAuthState 'stale' 'Grok usage unavailable; retry later'
        }
        return $null
    }
}
