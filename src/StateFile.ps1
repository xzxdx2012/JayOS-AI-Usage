# StateFile.ps1 - crash-safe UTF-8 JSON persistence (PowerShell 5.1+).
function Read-StateJson([string]$Path) {
    foreach ($candidate in @($Path, ($Path + '.bak'))) {
        if (-not [IO.File]::Exists($candidate)) { continue }
        try {
            $text = [IO.File]::ReadAllText($candidate)
            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            $value = $text | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $value -and $value -is [pscustomobject]) { return $value }
        } catch { }
    }
    throw "No valid settings file: $Path"
}

function Write-StateJsonAtomic([string]$Path, $Value) {
    $tmp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $json = $Value | ConvertTo-Json -Depth 6 -ErrorAction Stop
        Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8 -ErrorAction Stop
        if ([IO.File]::Exists($Path)) {
            # Do not replace a good backup with an empty/truncated primary.
            $backup = $tmp + '.old'
            try {
                $old = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop
                if ($old -is [pscustomobject]) { $backup = $Path + '.bak' }
            } catch { }
            [IO.File]::Replace($tmp, $Path, $backup)
        } else { [IO.File]::Move($tmp, $Path) }
    } finally {
        if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) }
        if ([IO.File]::Exists($tmp + '.old')) { [IO.File]::Delete($tmp + '.old') }
    }
}
