# RequestReview.Tests.ps1 - regressions from docs/reviews/review-requests.md.
#
# Plain script (no Pester); works on Windows PowerShell 5.1 and PowerShell 7,
# on Windows and Linux. Runs the real hook against a throwaway fixture folder.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:count = 0
function Assert($Value, [string]$Name) {
    if (-not $Value) { throw "FAILED: $Name" }
    $script:count++; Write-Output "PASS: $Name"
}

$script:AppDir = $root
$script:I18nText = @{}; $script:I18nRules = @()
function Write-Log($Message) { }
. (Join-Path (Join-Path $root 'src') 'Requests.ps1')

# Nested objects { k = { k = ... { k = $Leaf } } }, $Levels deep.
function New-NestedInput([int]$Levels, $Leaf) {
    $v = $Leaf
    for ($i = 0; $i -lt $Levels; $i++) { $v = [pscustomobject]@{ k = $v } }
    return $v
}

$fixture = Join-Path $PSScriptRoot ('review-req-fixture-' + [guid]::NewGuid().ToString('N'))
$reqDir = Join-Path $fixture 'requests'
$hookDir = Join-Path $fixture 'hooks'
$fixtureHook = Join-Path $hookDir 'ClaudeHook.ps1'
New-Item -ItemType Directory -Path $reqDir, $hookDir -Force | Out-Null
try {
    # --- 1: deeply nested MCP input -----------------------------------------
    # An array leaf: past the serializer's depth it becomes "System.Object[]".
    $deep = [pscustomobject]@{ tool = 'mcp__db__run'; input = (New-NestedInput 6 @('SECRET-ARG')) }
    $s = Get-RequestSummary $deep
    Assert ($s.Detail -like '*SECRET-ARG*' -or $s.Truncated) '1 deep MCP input is shown in full or can only be denied'
    $s = Get-RequestSummary ([pscustomobject]@{ tool = 'mcp__db__run'; input = (New-NestedInput 120 'SECRET-ARG') })
    Assert ($s.Truncated) '1 MCP input deeper than the card can show can only be denied'
    $s = Get-RequestSummary ([pscustomobject]@{ tool = 'mcp__db__run'; input = [pscustomobject]@{ query = 'select 1' } })
    Assert ((-not $s.Truncated) -and $s.Detail -like '*select 1*') '1 ordinary MCP input still allowed'

    # The real hook: input too deep for its own request file / answer must go
    # back to the terminal, never be handed over cut.
    Copy-Item -LiteralPath (Join-Path (Join-Path $root 'hooks') 'ClaudeHook.ps1') -Destination $fixtureHook
    [IO.File]::WriteAllText((Join-Path $fixture 'unified-overlay.pid'), [string]$PID)
    function Invoke-Hook([string]$Json) {
        [IO.File]::WriteAllText((Join-Path $reqDir 'overlay.alive'), 'test')
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = (Get-Process -Id $PID).Path
        $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $fixtureHook + '"'
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        $p = New-Object System.Diagnostics.Process; $p.StartInfo = $info
        try {
            [void]$p.Start()
            $p.StandardInput.Write($Json); $p.StandardInput.Close()
            $published = $false
            $until = [DateTime]::UtcNow.AddSeconds(8)
            while ([DateTime]::UtcNow -lt $until -and -not $p.HasExited) {
                $f = Get-ChildItem -LiteralPath $reqDir -Filter '*.req.json' | Select-Object -First 1
                if ($f) {
                    # It was handed over: answer so the hook ends, and report it.
                    $published = $true
                    $r = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
                    $resp = Join-Path $reqDir ($r.id + '.resp.json')
                    [IO.File]::WriteAllText(($resp + '.tmp'), (@{ id = $r.id; session = $r.session; action = 'allow' } | ConvertTo-Json -Compress))
                    [IO.File]::Move(($resp + '.tmp'), $resp)
                    break
                }
                Start-Sleep -Milliseconds 50
            }
            if (-not $p.WaitForExit(8000)) { throw 'Hook fixture timed out' }
            return @{ Published = $published; Out = $p.StandardOutput.ReadToEnd(); Exit = $p.ExitCode }
        } finally { if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit() }; $p.Dispose() }
    }
    $base = @{ hook_event_name = 'PermissionRequest'; session_id = 'deep'; cwd = $fixture; tool_name = 'mcp__db__run' }
    $base.tool_input = New-NestedInput 40 'SECRET-ARG'
    $r = Invoke-Hook ($base | ConvertTo-Json -Depth 100 -Compress)
    Assert ((-not $r.Published) -and [string]::IsNullOrEmpty($r.Out) -and $r.Exit -eq 0) '1 hook hands too-deep input back to the terminal'
    $base.tool_input = New-NestedInput 3 'ok'
    $r = Invoke-Hook ($base | ConvertTo-Json -Depth 100 -Compress)
    Assert ($r.Published -and ($r.Out | ConvertFrom-Json).hookSpecificOutput.decision.behavior -eq 'allow') '1 hook still hands over ordinary input'

    # --- 2: "Always allow" says what it grants ------------------------------
    $sugg = @(
        [pscustomobject]@{ type = 'addRules'; rules = @([pscustomobject]@{ toolName = 'Bash'; ruleContent = 'npm:*' }); behavior = 'allow'; destination = 'localSettings' },
        [pscustomobject]@{ type = 'setMode'; mode = 'acceptEdits'; destination = 'session' },
        [pscustomobject]@{ type = 'addDirectories'; directories = @('C:/work/other'); destination = 'session' })
    $s = Get-RequestSummary ([pscustomobject]@{ tool = 'Bash'; agent = 'claude'; suggestions = $sugg; input = [pscustomobject]@{ command = 'npm test' } })
    $g = [string]$s.Grants
    Assert ($g -like '*Bash(npm:*)*' -and $g -like '*localSettings*') '2 card lists the rule Always allow saves, and where'
    Assert ($g -like '*acceptEdits*') '2 card lists a permission mode change'
    Assert ($g -like '*C:/work/other*') '2 card lists added folders'
    $s = Get-RequestSummary ([pscustomobject]@{ tool = 'Bash'; agent = 'codex'; suggestions = $sugg; input = [pscustomobject]@{ command = 'npm test' } })
    Assert (-not $s.Grants) '2 no grants shown where Always allow is not offered (Codex)'

    # --- 3: the command comes first -----------------------------------------
    $desc = (1..15 | ForEach-Object { "Run the unit tests (step $_)" }) -join "`n"
    $s = Get-RequestSummary ([pscustomobject]@{ tool = 'Bash'; input = [pscustomobject]@{ command = 'rm -rf ~/projects'; description = $desc } })
    Assert (($s.Detail -split "`n")[0] -eq 'rm -rf ~/projects') '3 command is the first line on the card'
    Assert ($s.Detail -notlike '*Run the unit tests*' -and $s.Note -like '*step 15*') '3 description is shown apart from the command'
    $s = Get-RequestSummary ([pscustomobject]@{ tool = 'exec_command'; input = [pscustomobject]@{ cmd = 'git push'; justification = 'Publish the branch' } })
    Assert (($s.Detail -split "`n")[0] -eq 'git push' -and $s.Note -like '*Publish the branch*') '3 Codex justification is shown apart from the command'

    Write-Output "$script:count tests passed on PowerShell $($PSVersionTable.PSVersion)."
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $parent = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
