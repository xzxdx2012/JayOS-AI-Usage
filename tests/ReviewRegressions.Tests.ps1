# ReviewRegressions.Tests.ps1 - the defects found in the 0.0.3 code review
# (R1-R6 and related paths), kept as regression tests. Each check states the
# required behaviour; the original review reproductions are the inverse.
#
# Runs on Windows PowerShell 5.1 and PowerShell 7. Uses a throwaway fixture
# folder under tests\; never touches the real ~/.claude, ~/.codex, the running
# notch or the Claude CLI, and never reads credentials.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:count = 0
function Assert($Value, [string]$Name) {
    if (-not $Value) { throw "FAILED: $Name" }
    $script:count++; Write-Output "PASS: $Name"
}

$fixture = Join-Path $PSScriptRoot ('review-fixture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $fixture 'hooks'), (Join-Path $fixture 'requests') -Force | Out-Null
$script:AppDir = $fixture
$script:I18nText = @{}; $script:I18nRules = @()
function Write-Log($Message) { }
. (Join-Path (Join-Path $root 'src') 'Requests.ps1')
$script:ReqDir = Join-Path $fixture 'requests'

function Start-HookFixture([string]$Json) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Process -Id $PID).Path
    $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path (Join-Path $fixture 'hooks') 'ClaudeHook.ps1') + '" -Agent codex'
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $p = New-Object System.Diagnostics.Process; $p.StartInfo = $info
    [void]$p.Start()
    $p.StandardInput.WriteLine($Json); $p.StandardInput.Close()
    return $p
}
function Wait-RequestFile([int]$Seconds = 10) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $f = Get-ChildItem -LiteralPath $script:ReqDir -Filter '*.req.json' -File | Select-Object -First 1
        if ($f) { return $f }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $until)
    return $null
}
function Set-Heartbeat { [IO.File]::WriteAllText((Join-Path $script:ReqDir 'overlay.alive'), 'test') }

try {
    # --- R1: only JayOS's own hook entries are removed ------------------------
    $settings = Join-Path $fixture 'settings.json'
    [IO.File]::WriteAllText($settings, '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"powershell -File C:/Unrelated/ClaudeHook.ps1"}]}]}}')
    [void](Set-AgentRequestHooks $settings 'claude' $true)
    [void](Set-AgentRequestHooks $settings 'claude' $false)
    $after = [IO.File]::ReadAllText($settings)
    Assert ($after.Contains('C:/Unrelated/ClaudeHook.ps1')) 'R1 unrelated hook with the same file name is kept'
    Assert (-not $after.Contains((Get-ClaudeHookCommand 'claude'))) 'R1 our own entry is removed'

    # Migration: the earlier quoted-exe form written by 0.0.3 previews is ours.
    $legacy = Get-ClaudeHookCommand 'claude' -QuotedExe
    [IO.File]::WriteAllText($settings, (@{ hooks = @{ Stop = @(@{ hooks = @(@{ type = 'command'; command = $legacy }) }) } } | ConvertTo-Json -Depth 8))
    [void](Set-AgentRequestHooks $settings 'claude' $false)
    Assert (-not ([IO.File]::ReadAllText($settings)).Contains('ClaudeHook.ps1')) 'R1 legacy quoted entry from this install is migrated away'

    # --- R2: a concurrent edit is merged, not overwritten ----------------------
    [IO.File]::WriteAllText($settings, '{"model":"old","hooks":{}}')
    $script:racePath = $settings; $script:raced = $false
    $realCmd = ${function:Get-ClaudeHookCommand}
    function Get-ClaudeHookCommand {
        param([string]$Agent = 'claude', [string]$AppDir = $script:AppDir, [switch]$QuotedExe)
        if (-not $script:raced) {
            $script:raced = $true
            [IO.File]::WriteAllText($script:racePath, '{"model":"new-user-edit","hooks":{}}')
        }
        return (& $realCmd -Agent $Agent -AppDir $AppDir -QuotedExe:$QuotedExe)
    }
    [void](Set-AgentRequestHooks $settings 'claude' $true)
    Set-Item Function:\Get-ClaudeHookCommand $realCmd
    $j = [IO.File]::ReadAllText($settings) | ConvertFrom-Json
    Assert ($j.model -eq 'new-user-edit' -and @($j.hooks.Stop).Count -eq 1) 'R2 concurrent user edit kept and our hook added'
    # Same race injected after the read (between parse and replace).
    [IO.File]::WriteAllText($settings, '{"model":"old","hooks":{}}')
    $script:raced = $false
    $realOwned = ${function:Get-ReqOwnedCommands}
    function Get-ReqOwnedCommands([string]$Agent) {
        $r = & $realOwned $Agent
        return ,$r
    }
    $realAdd = ${function:Add-ReqRegisteredCommand}
    function Add-ReqRegisteredCommand([string]$Command) {
        if (-not $script:raced) { $script:raced = $true; [IO.File]::WriteAllText($script:racePath, '{"model":"edited-after-read","hooks":{}}') }
        & $realAdd $Command
    }
    [void](Set-AgentRequestHooks $settings 'claude' $true)
    Set-Item Function:\Add-ReqRegisteredCommand $realAdd
    Set-Item Function:\Get-ReqOwnedCommands $realOwned
    $j = [IO.File]::ReadAllText($settings) | ConvertFrom-Json
    Assert ($j.model -eq 'edited-after-read' -and @($j.hooks.Stop).Count -eq 1) 'R2 edit made after our read is merged, not lost'
    Assert (@(Get-ChildItem -LiteralPath $fixture -Filter '*.tmp' -File).Count -eq 0) 'R2 no temp files left behind'

    # --- R4: edits show what changes ----------------------------------------
    $one = [pscustomobject]@{ tool = 'Edit'; input = [pscustomobject]@{ file_path = 'C:\demo\config.json'; old_string = 'safe'; new_string = 'unsafe' } }
    $two = [pscustomobject]@{ tool = 'Edit'; input = [pscustomobject]@{ file_path = 'C:\demo\config.json'; old_string = 'safe'; new_string = 'safe2' } }
    $d1 = (Get-RequestSummary $one).Detail; $d2 = (Get-RequestSummary $two).Detail
    Assert ($d1 -ne $d2 -and $d1.Contains('- safe') -and $d1.Contains('+ unsafe')) 'R4 Edit shows old and new text'
    $w = [pscustomobject]@{ tool = 'Write'; input = [pscustomobject]@{ file_path = 'C:\demo\a.txt'; content = 'hello world' } }
    Assert ((Get-RequestSummary $w).Detail.Contains('hello world')) 'R4 Write shows the content'
    $big = [pscustomobject]@{ tool = 'Write'; input = [pscustomobject]@{ file_path = 'C:\demo\big.txt'; content = ('x' * 30000) } }
    $sb = Get-RequestSummary $big
    Assert ($sb.Truncated -and $sb.Detail.Length -lt 21000) 'R4 oversized content is cut and flagged'

    # Flagged content cannot be allowed from the card.
    $id = [guid]::NewGuid().ToString('N')
    $req = [pscustomobject]@{ id = $id; pid = $PID; event = 'PermissionRequest'; agent = 'claude'; session = 's'; tool = 'Write'
        expires = [DateTime]::UtcNow.AddMinutes(1).ToString('o'); input = $big.input; suggestions = $null }
    [IO.File]::WriteAllText((Join-Path $script:ReqDir "$id.req.json"), ($req | ConvertTo-Json -Depth 6))
    $script:ReqCards[$id] = @{ Req = $req; Truncated = $true }
    function Close-RequestCard($Id) { $script:ReqCards.Remove($Id) }
    Send-RequestAnswer $id @{ action = 'allow' }
    Assert (-not (Test-Path -LiteralPath (Join-Path $script:ReqDir "$id.resp.json"))) 'R4 truncated request cannot be allowed'
    Send-RequestAnswer $id @{ action = 'deny' }
    Assert ((Get-Content -LiteralPath (Join-Path $script:ReqDir "$id.resp.json") -Raw | ConvertFrom-Json).action -eq 'deny') 'R4 truncated request can still be denied'
    Remove-Item -Path (Join-Path $script:ReqDir "$id.*")
    $script:ReqCards.Clear(); $script:ReqAnswered.Clear()

    # --- Times survive a JSON round trip in any time zone ----------------------
    # (PowerShell 7 turns ISO strings into [datetime]; a [string] round trip
    # used to shift them by the local UTC offset.)
    $live = [pscustomobject]@{ id = ([guid]::NewGuid().ToString('N')); pid = $PID; event = 'PermissionRequest'
        expires = [DateTime]::UtcNow.AddSeconds(60).ToString('o')
        processStarted = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o') } | ConvertTo-Json | ConvertFrom-Json
    Assert (Test-RequestLive $live) 'request read back from JSON is live (expires + process start)'
    $old = [pscustomobject]@{ pid = $PID; event = 'PermissionRequest'; expires = [DateTime]::UtcNow.AddSeconds(-5).ToString('o') } | ConvertTo-Json | ConvertFrom-Json
    Assert (-not (Test-RequestLive $old)) 'request read back from JSON past its deadline is not live'

    # --- R6: question detection --------------------------------------------
    $hookPath = Join-Path (Join-Path $root 'hooks') 'ClaudeHook.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($hookPath, [ref]$null, [ref]$null)
    foreach ($n in 'Get-LastParagraph', 'Get-LastSentence', 'Test-EndsWithQuestion', 'Test-IsChoiceQuestion') {
        . ([scriptblock]::Create($ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true).Extent.Text))
    }
    Assert (-not (Test-EndsWithQuestion 'The documentation contains the phrase do you want me to. This task is complete.')) 'R6 quoted phrase is not a question'
    Assert (-not (Test-EndsWithQuestion ("> Shall I deploy?`n`nDeployed."))) 'R6 quoted question is not the last word'
    Assert (Test-EndsWithQuestion ("Done.`n`nShall I also update the docs?")) 'R6 real closing question detected'
    Assert (Test-EndsWithQuestion '改完了，要我继续打包吗？') 'R6 Chinese closing question detected'
    Assert (Test-IsChoiceQuestion 'Should I use Redis or Postgres?') 'R6 either/or question goes to the terminal'

    # --- R3: the hook never waits on a request nobody can answer -------------
    Copy-Item -LiteralPath $hookPath -Destination (Join-Path (Join-Path $fixture 'hooks') 'ClaudeHook.ps1')
    [IO.File]::WriteAllText((Join-Path $fixture 'unified-overlay.pid'), [string]$PID)
    $perm = '{"hook_event_name":"PermissionRequest","session_id":"review","tool_name":"Bash","tool_input":{"command":"echo harmless"}}'

    # Notch not answering (no heartbeat): immediate fallback, no request file.
    Remove-Item -LiteralPath (Join-Path $script:ReqDir 'overlay.alive') -ErrorAction SilentlyContinue
    $p = Start-HookFixture $perm
    try {
        Assert ($p.WaitForExit(8000)) 'R3 no heartbeat: hook exits at once'
        Assert ([string]::IsNullOrEmpty($p.StandardOutput.ReadToEnd())) 'R3 no heartbeat: no decision printed'
        Assert (@(Get-ChildItem -LiteralPath $script:ReqDir -Filter '*.req.json' -File).Count -eq 0) 'R3 no heartbeat: no request written'
    } finally { if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit() }; $p.Dispose() }

    # Request withdrawn: the hook stops waiting within a second or so.
    Set-Heartbeat
    $p = Start-HookFixture $perm
    try {
        $f = Wait-RequestFile
        Assert ($f) 'R3 hook publishes a request while the notch is answering'
        Remove-Item -LiteralPath $f.FullName
        $t0 = [DateTime]::UtcNow
        Assert ($p.WaitForExit(3500)) 'R3 withdrawn request: hook exits quickly'
        Assert ([string]::IsNullOrEmpty($p.StandardOutput.ReadToEnd())) 'R3 withdrawn request: no decision printed'
    } finally { if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit() }; $p.Dispose() }

    # Notch stops answering mid-wait (heartbeat goes stale).
    Set-Heartbeat
    $p = Start-HookFixture $perm
    try {
        $f = Wait-RequestFile
        Assert ($f) 'R3 request published before the heartbeat goes stale'
        [IO.File]::SetLastWriteTimeUtc((Join-Path $script:ReqDir 'overlay.alive'), [DateTime]::UtcNow.AddMinutes(-5))
        Assert ($p.WaitForExit(6000)) 'R3 stale heartbeat: hook gives up within seconds'
        Assert ([string]::IsNullOrEmpty($p.StandardOutput.ReadToEnd())) 'R3 stale heartbeat: no decision printed'
        Assert (@(Get-ChildItem -LiteralPath $script:ReqDir -Filter '*.req.json' -File).Count -eq 0) 'R3 stale heartbeat: request cleaned up'
    } finally { if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit() }; $p.Dispose() }

    # Feature switched off: waiting requests are handed back to the terminal.
    Set-Heartbeat
    $p = Start-HookFixture $perm
    try {
        $f = Wait-RequestFile
        Assert ($f) 'R3 request published before switching off'
        Stop-RequestWatcher
        Assert ($p.WaitForExit(4000)) 'R3 switched off: hook released at once'
        Assert ([string]::IsNullOrEmpty($p.StandardOutput.ReadToEnd())) 'R3 switched off: agent falls back to its own prompt'
        Assert (-not (Test-Path -LiteralPath (Join-Path $script:ReqDir 'overlay.alive'))) 'R3 switched off: heartbeat removed'
    } finally { if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit() }; $p.Dispose() }

    # No answer at all: nothing is ever printed (only a click continues).
    Set-Heartbeat
    $stop = '{"hook_event_name":"Stop","session_id":"review","stop_hook_active":true,"last_assistant_message":"Done. Shall I go on?"}'
    $p = Start-HookFixture $stop
    try {
        $f = Wait-RequestFile
        Assert ($f) 'Stop question published'
        Start-Sleep -Seconds 2
        Assert (-not $p.HasExited) 'Stop without an answer keeps waiting (never continues on its own)'
        Remove-Item -LiteralPath $f.FullName
        Assert ($p.WaitForExit(3500) -and [string]::IsNullOrEmpty($p.StandardOutput.ReadToEnd())) 'Stop withdrawn: no continuation'
    } finally { if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit() }; $p.Dispose() }

    # --- R5: Claude sign-in renewal ------------------------------------------
    . (Join-Path (Join-Path $root 'src') 'Data.ps1')
    function Write-Log($Message) { }
    $script:FixtureCli = Join-Path $fixture 'claude.exe'
    function Resolve-ClaudeCliExecutable { $script:FixtureCli }
    $script:launches = 0
    function Start-Process { param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle, [switch]$PassThru) $script:launches++; return $null }
    Clear-ClaudeCliRenewal

    # State cannot be saved: nothing is started, every time.
    function Save-ClaudeCliRenewalState([hashtable]$State) { throw 'Injected state write failure' }
    $a = Invoke-ClaudeCliRenewal; $b = Invoke-ClaudeCliRenewal
    Assert ($script:launches -eq 0 -and $a -eq 'state_error' -and $b -eq 'state_error') 'R5 unsaved state never starts Claude Code'
    Remove-Item Function:\Save-ClaudeCliRenewalState
    . ([scriptblock]::Create(([System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Join-Path $root 'src') 'Data.ps1'), [ref]$null, [ref]$null).Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Save-ClaudeCliRenewalState' }, $true).Extent.Text)))

    # Started once, then waits (the try was recorded before starting).
    $a = Invoke-ClaudeCliRenewal; $b = Invoke-ClaudeCliRenewal
    Assert ($script:launches -eq 1 -and $a -eq 'started' -and $b -eq 'waiting') 'R5 one start, then waiting'

    # Start fails: reported as such, and still counted (no retry storm).
    Clear-ClaudeCliRenewal
    function Start-Process { param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle, [switch]$PassThru) $script:launches++; throw 'Injected start failure' }
    $script:launches = 0
    $a = Invoke-ClaudeCliRenewal; $b = Invoke-ClaudeCliRenewal
    Assert ($a -eq 'launch_failed' -and $b -eq 'waiting' -and $script:launches -eq 1) 'R5 failed start reported and backed off'
    Assert ((Get-ClaudeCliRenewalState).Tries -eq 1) 'R5 failed start counts as a try'

    # Switched off in Settings.
    Clear-ClaudeCliRenewal
    Set-ClaudeCliRenewalEnabled $false
    $script:launches = 0
    Assert ((Invoke-ClaudeCliRenewal) -eq 'disabled' -and $script:launches -eq 0) 'R5 switched off: nothing started'
    Set-ClaudeCliRenewalEnabled $true
    Assert (Test-ClaudeCliRenewalEnabled) 'R5 switched back on'

    Write-Output "$script:count tests passed on PowerShell $($PSVersionTable.PSVersion)."
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $parent = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
