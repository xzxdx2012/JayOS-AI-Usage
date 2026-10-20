# Notices.Tests.ps1 - "task finished" and "waiting for you" notices.
#
# The hook writes <id>.note.json and returns at once (never blocks the agent);
# the notch filters, queues and shows them. Runs on Windows PowerShell 5.1 and
# PowerShell 7 in a throwaway fixture under tests\; never touches the real
# ~/.claude, ~/.codex or the running notch.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:count = 0
function Assert($Value, [string]$Name) {
    if (-not $Value) { throw "FAILED: $Name" }
    $script:count++; Write-Output "PASS: $Name"
}

$fixture = Join-Path $PSScriptRoot ('notice-fixture-' + [guid]::NewGuid().ToString('N'))
$reqDir = Join-Path $fixture 'requests'
New-Item -ItemType Directory -Path (Join-Path $fixture 'hooks'), $reqDir -Force | Out-Null
$script:AppDir = $fixture
$script:I18nText = @{}; $script:I18nRules = @()
$script:Cfg = @{ AiNotifyDone = $true; AiNotifyAttention = $true }
function Write-Log($Message) { }
. (Join-Path (Join-Path $root 'src') 'Requests.ps1')
$script:ReqDir = $reqDir

Copy-Item -LiteralPath (Join-Path (Join-Path $root 'hooks') 'ClaudeHook.ps1') -Destination (Join-Path (Join-Path $fixture 'hooks') 'ClaudeHook.ps1')
[IO.File]::WriteAllText((Join-Path $fixture 'unified-overlay.pid'), [string]$PID)

function Invoke-Hook([string]$Json, [string]$Agent = 'claude') {
    [IO.File]::WriteAllText((Join-Path $reqDir 'overlay.alive'), 'test')
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Process -Id $PID).Path
    $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path (Join-Path $fixture 'hooks') 'ClaudeHook.ps1') + '" -Agent ' + $Agent
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    # Send actual UTF-8 bytes even on Windows with a legacy console code page.
    # Otherwise the BOM fixture is changed to '?' by the parent before the hook reads it.
    $p = New-Object System.Diagnostics.Process; $p.StartInfo = $info
    try {
        [void]$p.Start()
        $bytes = [Text.Encoding]::UTF8.GetBytes($Json + "`n")
        $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $p.StandardInput.BaseStream.Flush(); $p.StandardInput.Close()
        $done = $p.WaitForExit(8000)
        return @{ Exited = $done; Out = $p.StandardOutput.ReadToEnd() }
    } finally { if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit() }; $p.Dispose() }
}
function Get-Notes { return @(Get-ChildItem -LiteralPath $reqDir -Filter '*.note.json' -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json }) }
function Clear-Notes { Get-ChildItem -LiteralPath $reqDir -Filter '*.note.json' -File | Remove-Item -Force }

try {
    # --- hook side --------------------------------------------------------
    $r = Invoke-Hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"C:/p/demo","last_assistant_message":"All tests pass.\n\nThe build is green."}'
    $n = @(Get-Notes)
    Assert ($r.Exited -and [string]::IsNullOrEmpty($r.Out)) 'finished turn: hook returns at once, prints nothing'
    Assert ($n.Count -eq 1 -and $n[0].kind -eq 'done' -and $n[0].agent -eq 'claude' -and $n[0].session -eq 's1') 'finished turn: a "done" notice is written'
    Assert ($null -ne $n[0].PSObject.Properties['chain']) 'notice records the process chain (to find the terminal window)'
    Assert (@(Get-ChildItem -LiteralPath $reqDir -Filter '*.req.json' -File).Count -eq 0) 'finished turn: no request to answer'
    Clear-Notes

    # A parent whose console is UTF-8 can put a byte order mark before the JSON;
    # Windows PowerShell 5.1's ConvertFrom-Json rejects it.
    $r = Invoke-Hook ([string][char]0xFEFF + '{"hook_event_name":"Stop","session_id":"s1","last_assistant_message":"Done."}')
    Assert (@(Get-Notes).Count -eq 1) 'input with a byte order mark is still read'
    Clear-Notes

    $r = Invoke-Hook '{"hook_event_name":"Stop","session_id":"s1","last_assistant_message":"Should I use Redis or Postgres?"}' 'codex'
    $n = @(Get-Notes)
    Assert ($r.Exited -and [string]::IsNullOrEmpty($r.Out) -and $n.Count -eq 1 -and $n[0].kind -eq 'ask' -and $n[0].agent -eq 'codex') 'either/or question: "answer in the terminal" notice'
    Clear-Notes

    $r = Invoke-Hook '{"hook_event_name":"Notification","session_id":"s2","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}'
    $n = @(Get-Notes)
    Assert ($r.Exited -and $n.Count -eq 1 -and $n[0].kind -eq 'permission' -and $n[0].message -like '*permission*') 'Notification permission_prompt -> permission notice'
    Clear-Notes
    $r = Invoke-Hook '{"hook_event_name":"Notification","session_id":"s2","notification_type":"idle_prompt","message":"Claude is waiting for your input"}'
    Assert (@(Get-Notes)[0].kind -eq 'idle') 'Notification idle_prompt -> idle notice'
    Clear-Notes
    $r = Invoke-Hook '{"hook_event_name":"Notification","session_id":"s2","notification_type":"elicitation_dialog","message":"Fill in the form"}'
    Assert (@(Get-Notes)[0].kind -eq 'input') 'Notification elicitation_dialog -> input notice'
    Clear-Notes
    $r = Invoke-Hook '{"hook_event_name":"Notification","session_id":"s2","notification_type":"auth_success","message":"Signed in"}'
    Assert (@(Get-Notes).Count -eq 0) 'Notification auth_success -> no notice'
    $r = Invoke-Hook '{"hook_event_name":"Notification","session_id":"s2","message":"Claude needs your permission to use Write"}'
    Assert (@(Get-Notes)[0].kind -eq 'permission') 'Notification without a type: permission recognised from the text'
    Clear-Notes

    Remove-Item -LiteralPath (Join-Path $reqDir 'overlay.alive')
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $r = $null
    # No heartbeat: nothing is written at all.
    $p = [System.Diagnostics.Process]::Start((New-Object System.Diagnostics.ProcessStartInfo -Property @{
        FileName = (Get-Process -Id $PID).Path
        Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path (Join-Path $fixture 'hooks') 'ClaudeHook.ps1') + '"'
        UseShellExecute = $false; CreateNoWindow = $true; RedirectStandardInput = $true; RedirectStandardOutput = $true }))
    $p.StandardInput.WriteLine('{"hook_event_name":"Stop","session_id":"s3","last_assistant_message":"Done."}'); $p.StandardInput.Close()
    [void]$p.WaitForExit(8000); $p.Dispose()
    Assert (@(Get-Notes).Count -eq 0) 'notch not answering: no notice written'

    # --- notch side ---------------------------------------------------------
    function New-Note([string]$Kind, [string]$Session = 's', [int]$Secs = 60, [string]$Agent = 'claude') {
        $id = [guid]::NewGuid().ToString('N')
        $o = [ordered]@{ id = $id; agent = $Agent; kind = $Kind; created = (Get-Date).ToString('o'); expires = [DateTime]::UtcNow.AddSeconds($Secs).ToString('o'); cwd = 'C:/p'; session = $Session; message = 'm' }
        [IO.File]::WriteAllText((Join-Path $reqDir "$id.note.json"), ($o | ConvertTo-Json))
        Start-Sleep -Milliseconds 20
        return $id
    }
    $none = New-Object System.Collections.Generic.List[object]
    $a = New-Note 'done'; $b = New-Note 'idle'
    $w = Get-ReqWaitingNotices $none
    Assert ($w.Count -eq 2 -and $w[0].id -eq $a) 'notices queue oldest first'
    Clear-Notes; $script:ReqParseCache = @{}

    $x = New-Note 'done' 's' -5
    $w = Get-ReqWaitingNotices $none
    Assert ($w.Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $reqDir "$x.note.json"))) 'expired notice is dropped and deleted'

    $script:Cfg['AiNotifyDone'] = $false
    $x = New-Note 'done'; $y = New-Note 'permission' 'other'
    $w = Get-ReqWaitingNotices $none
    Assert ($w.Count -eq 1 -and $w[0].kind -eq 'permission') '"task finished" switched off: only the other notice stays'
    $script:Cfg['AiNotifyDone'] = $true
    $script:Cfg['AiNotifyAttention'] = $false
    $w = Get-ReqWaitingNotices $none
    Assert ($w.Count -eq 0) '"needs you" switched off: permission notice dropped'
    $script:Cfg['AiNotifyAttention'] = $true
    Clear-Notes; $script:ReqParseCache = @{}

    # A permission notice repeating a card for the same session is dropped.
    $y = New-Note 'permission' 'busy'
    $pending = New-Object System.Collections.Generic.List[object]
    $pending.Add([pscustomobject]@{ agent = 'claude'; session = 'busy' })
    Assert ((Get-ReqWaitingNotices $pending).Count -eq 0) 'permission notice dropped while a card for that session waits'
    $y = New-Note 'permission' 'term'
    $script:ReqRecentTerminal['claude|term'] = [DateTime]::UtcNow
    Assert ((Get-ReqWaitingNotices $none).Count -eq 0) 'permission notice dropped right after "In terminal"'
    $y = New-Note 'permission' 'fresh'
    Assert ((Get-ReqWaitingNotices $none).Count -eq 1) 'permission notice for another session is kept'
    Clear-Notes; $script:ReqParseCache = @{}

    # Bad ids and kinds never show.
    [IO.File]::WriteAllText((Join-Path $reqDir 'bad.note.json'), '{"id":"bad","kind":"done","expires":"2999-01-01T00:00:00Z"}')
    $id = [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText((Join-Path $reqDir "$id.note.json"), ('{"id":"' + $id + '","kind":"rm -rf","expires":"2999-01-01T00:00:00Z"}'))
    Assert ((Get-ReqWaitingNotices $none).Count -eq 0) 'invalid id or kind is dropped'

    # A Cowork approval card stays until Cowork withdraws or expires it.
    $script:ReqClosed = @()
    function Close-NoticeCard([string]$Id) { $script:ReqClosed += "n:$Id"; $script:ReqCards.Remove($Id) }
    function Close-RequestCard([string]$Id) { $script:ReqClosed += "r:$Id"; $script:ReqCards.Remove($Id) }
    function Show-NoticeCard($Note) { }
    $s = New-Note 'permission' 'cw' 600 'cowork'
    $sn = Get-Content -LiteralPath (Join-Path $reqDir "$s.note.json") -Raw | ConvertFrom-Json
    $script:ReqCards[$s] = @{ Req = $sn; IsNotice = $true; Sticky = $true; Window = [pscustomobject]@{ IsMouseOver = $false }; Shown = [DateTime]::UtcNow; AutoCloseAt = [DateTime]::UtcNow.AddSeconds(-5) }
    Invoke-RequestPoll
    Assert ($script:ReqCards.Contains($s) -and $script:ReqClosed.Count -eq 0) 'Cowork approval card ignores the auto-close time'
    $sn.message = 'still waiting'; $script:ReqCards[$s].Req = $sn
    $sn.expires = [DateTime]::UtcNow.AddSeconds(-1).ToString('o')
    Start-Sleep -Milliseconds 30
    [IO.File]::WriteAllText((Join-Path $reqDir "$s.note.json"), ($sn | ConvertTo-Json))
    Invoke-RequestPoll
    Assert (-not $script:ReqCards.Contains($s) -and $script:ReqClosed -contains "n:$s") 'Cowork approval card closes once withdrawn (expired)'
    $script:ReqCards.Clear(); Clear-Notes; $script:ReqParseCache = @{}

    # Nothing to jump to: no window found, no error.
    Assert ((Find-ReqAgentWindow @(999999, 999998)) -eq [IntPtr]::Zero) 'no window for unknown processes'
    Assert ((Get-ReqNoticeExcerpt ("Intro.`n`n``````code``````" + "`n`nThe build is green.")) -eq 'The build is green.') 'done card shows the last paragraph, not code'

    # --- hook registration ----------------------------------------------------
    $settings = Join-Path $fixture 'settings.json'
    [IO.File]::WriteAllText($settings, '{}')
    [void](Set-AgentRequestHooks $settings 'claude' $true)
    $j = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
    Assert (@($j.hooks.Notification).Count -eq 1 -and [int]@($j.hooks.Notification)[0].hooks[0].timeout -eq 10) 'Claude: Notification hook registered (10 s)'
    [void](Set-AgentRequestHooks $settings 'claude' $false)
    $j = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
    Assert ($null -eq $j.hooks.Notification) 'Claude: Notification hook removed when off'
    $codex = Join-Path $fixture 'hooks.json'
    [void](Set-AgentRequestHooks $codex 'codex' $true)
    $j = Get-Content -LiteralPath $codex -Raw | ConvertFrom-Json
    Assert ($null -eq $j.hooks.Notification -and @($j.hooks.Stop).Count -eq 1) 'Codex: no Notification hook (Codex has no such event)'

    Write-Output "$script:count tests passed on PowerShell $($PSVersionTable.PSVersion)."
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $parent = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
