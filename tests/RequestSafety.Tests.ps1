$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:count = 0
function Assert($Value, [string]$Name) {
    if (-not $Value) { throw "FAILED: $Name" }
    $script:count++; Write-Output "PASS: $Name"
}
$script:AppDir = $root
$script:I18nText = @{}; $script:I18nRules = @()
. (Join-Path $root 'src\Requests.ps1')
function Close-RequestCard($Id) { $script:closed = $Id }
function Write-Log($Message) { }
$fixture = Join-Path $PSScriptRoot ('fixture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$fixture\hooks", "$fixture\requests" -Force | Out-Null
try {
    $script:ReqDir = Join-Path $fixture 'requests'
    $id = [guid]::NewGuid().ToString('N')
    $req = [pscustomobject]@{
        id=$id; pid=$PID; event='PermissionRequest'; agent='codex'; session='test'
        expires=[DateTime]::UtcNow.AddMinutes(1).ToString('o')
        processStarted=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
        suggestions=@('anything'); tool='exec_command'; input=@{cmd=('x' * 1200)}
    }
    Assert (Test-RequestIdentity $req $id) 'valid request identity'
    Assert (-not (Test-RequestIdentity $req "../bad';throw 'injection")) 'reject callback and path injection'
    Assert (-not (Test-RequestIdentity $req ([guid]::NewGuid().ToString('N')))) 'reject filename id mismatch'
    Assert (Test-RequestLive $req) 'live process and deadline'
    $req.expires=[DateTime]::UtcNow.AddSeconds(-1).ToString('o')
    Assert (-not (Test-RequestLive $req)) 'expired request rejected'
    $req.expires='invalid'
    Assert (-not (Test-RequestLive $req)) 'invalid deadline rejected'
    $req.expires=[DateTime]::UtcNow.AddMinutes(1).ToString('o')
    $saved=$req.processStarted; $req.processStarted=[DateTime]::UtcNow.AddDays(-1).ToString('o')
    Assert (-not (Test-RequestLive $req)) 'reused pid rejected'
    $req.processStarted=$saved
    Assert (-not (Test-RequestAlwaysAllowed $req)) 'Codex never offers always allow'
    $req.agent='claude'
    Assert (Test-RequestAlwaysAllowed $req) 'Claude suggestions retained'
    $req.agent='codex'
    Assert ((Get-RequestSummary $req).Detail.Length -eq 1200) 'full command retained'
    $path=Join-Path $script:ReqDir "$id.req.json"
    [IO.File]::WriteAllText($path, ($req | ConvertTo-Json -Depth 10))
    $script:ReqCards[$id]=@{Req=$req}
    Send-RequestAnswer $id @{action='always'}
    Assert (-not (Test-Path "$script:ReqDir\$id.resp.json")) 'Codex always rejected in answer handler'
    Send-RequestAnswer $id @{action='allow'}
    $resp=Get-Content -LiteralPath "$script:ReqDir\$id.resp.json" -Raw | ConvertFrom-Json
    Assert ($resp.id -ceq $id -and $resp.session -eq 'test' -and $resp.action -eq 'allow') 'answer bound to request and session'
    Send-RequestAnswer $id @{action='deny'}
    $resp=Get-Content -LiteralPath "$script:ReqDir\$id.resp.json" -Raw | ConvertFrom-Json
    Assert ($resp.action -eq 'allow') 'duplicate answer cannot overwrite'
    [void]$script:ReqAnswered.Remove($id)
    Send-RequestAnswer $id @{action='deny'}
    $resp=Get-Content -LiteralPath "$script:ReqDir\$id.resp.json" -Raw | ConvertFrom-Json
    Assert ($resp.action -eq 'allow') 'existing response wins even without memory marker'
    Remove-Item -LiteralPath "$script:ReqDir\$id.resp.json"
    $req.expires=[DateTime]::UtcNow.AddSeconds(-1).ToString('o')
    Send-RequestAnswer $id @{action='allow'}
    Assert (-not (Test-Path "$script:ReqDir\$id.resp.json")) 'late click produces no approval'
    Remove-Item -LiteralPath $path

    # Run the real hook against a fixture, never the installed overlay.
    Copy-Item -LiteralPath "$root\hooks\ClaudeHook.ps1" -Destination "$fixture\hooks\ClaudeHook.ps1"
    [IO.File]::WriteAllText("$fixture\unified-overlay.pid", [string]$PID)
    function Invoke-HookFixture([string]$Event, [string]$Action, [bool]$Mismatch=$false, [bool]$Active=$false) {
        # The notch's heartbeat: the hook only hands requests to a notch that is answering.
        [IO.File]::WriteAllText("$fixture\requests\overlay.alive", 'test')
        $info=New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName=(Get-Process -Id $PID).Path
        $info.Arguments='-NoProfile -ExecutionPolicy Bypass -File "' + "$fixture\hooks\ClaudeHook.ps1" + '" -Agent codex'
        $info.UseShellExecute=$false; $info.CreateNoWindow=$true
        $info.RedirectStandardInput=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
        $p=New-Object System.Diagnostics.Process; $p.StartInfo=$info
        try {
            [void]$p.Start()
            $inputObject=@{hook_event_name=$Event; session_id='integration'; cwd=$fixture; tool_name='exec_command'; tool_input=@{cmd='echo fixture'}; last_assistant_message='Continue?'; stop_hook_active=$Active}
            $p.StandardInput.WriteLine(($inputObject | ConvertTo-Json -Compress)); $p.StandardInput.Close()
            if ($true) {
                $until=[DateTime]::UtcNow.AddSeconds(10); $file=$null
                do {
                    $file=Get-ChildItem -LiteralPath "$fixture\requests" -Filter '*.req.json' | Select-Object -First 1
                    if ($file -or $p.HasExited) { break }; Start-Sleep -Milliseconds 50
                } while ([DateTime]::UtcNow -lt $until)
                if (-not $file) { throw 'Hook fixture did not publish a request' }
                $r=Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
                $answer=@{id=$r.id; session=$r.session; action=$Action}
                if ($Mismatch) { $answer.session='wrong-session' }
                $response=Join-Path "$fixture\requests" ($r.id + '.resp.json')
                [IO.File]::WriteAllText(($response+'.tmp'), ($answer | ConvertTo-Json -Compress))
                [IO.File]::Move(($response+'.tmp'), $response)
            }
            if (-not $p.WaitForExit(5000)) { throw 'Hook fixture timed out' }
            $out=$p.StandardOutput.ReadToEnd(); $err=$p.StandardError.ReadToEnd()
            if ($p.ExitCode -ne 0 -or $err) { throw "Hook error: $err" }
            Assert (@(Get-ChildItem -LiteralPath "$fixture\requests" -File | Where-Object { $_.Name -like '*.json*' }).Count -eq 0) 'hook cleans request and response'
            return $out
        } finally { if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit() }; $p.Dispose() }
    }
    # Capture only the final JSON; Assert messages also travel through the pipeline.
    $result=@(Invoke-HookFixture 'PermissionRequest' 'allow')[-1] | ConvertFrom-Json
    Assert ($result.hookSpecificOutput.decision.behavior -eq 'allow') 'real hook allow protocol'
    $result=@(Invoke-HookFixture 'PermissionRequest' 'deny')[-1] | ConvertFrom-Json
    Assert ($result.hookSpecificOutput.decision.behavior -eq 'deny') 'real hook deny protocol'
    $result=@(Invoke-HookFixture 'PermissionRequest' 'allow' $true)[-1]
    Assert ([string]::IsNullOrEmpty($result)) 'mismatched response produces no approval'
    $result=@(Invoke-HookFixture 'Stop' 'continue')[-1] | ConvertFrom-Json
    Assert ($result.decision -eq 'block') 'real hook continuation protocol'
    # A continuation that asks again still waits for a click; it never
    # continues by itself (no answer -> no output, see the mismatch case).
    $result=@(Invoke-HookFixture 'Stop' 'continue' $false $true)[-1] | ConvertFrom-Json
    Assert ($result.decision -eq 'block') 'repeat question after Continue still offered'
    $result=@(Invoke-HookFixture 'Stop' 'ignore' $false $true)[-1]
    Assert ([string]::IsNullOrEmpty($result)) 'repeat question answered "reply myself" gives no continuation'
    Write-Output "$script:count tests passed on PowerShell $($PSVersionTable.PSVersion)."
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture)
    $parent=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\'
    if (-not $resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
