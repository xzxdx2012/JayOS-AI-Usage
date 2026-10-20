# ClaudeHook.ps1 - Claude Code and Codex hook for JayOS AI Usage.
#
# Claude Code and Codex run this when they need you. The "AI requests in the
# notch" setting registers it in ~/.claude/settings.json and in
# ~/.codex/hooks.json (there with -Agent codex):
#
#   PermissionRequest  a tool needs approval, Claude asks a multiple-choice
#                      question (AskUserQuestion) or wants a plan approved
#   Stop               Claude finished its turn; when its last message is a
#                      question ("Shall I go on?") the notch offers "Continue",
#                      otherwise it shows a "done" notice
#   Notification       (Claude Code) it is waiting for you in its own prompt:
#                      permission dialog, input, a form - shown as a notice
#
# The request is shown as a card next to the notch. The answer comes back
# through two files in <app>\requests (<id>.req.json -> <id>.resp.json).
#
# Whenever anything is off - the overlay is not running, no answer in time,
# "Answer in terminal", an error - this prints nothing and exits 0, which
# leaves Claude Code to ask in the terminal exactly as it normally would.

param([string]$Agent = 'claude')

$ErrorActionPreference = 'Stop'
$Agent = $Agent.ToLowerInvariant()
if ($Agent -ne 'codex') { $Agent = 'claude' }
$utf8 = New-Object System.Text.UTF8Encoding($false)
try { [Console]::InputEncoding = $utf8; [Console]::OutputEncoding = $utf8 } catch { }

$appDir = Split-Path -Parent $PSScriptRoot
$reqDir = Join-Path $appDir 'requests'
$aliveFile = Join-Path $reqDir 'overlay.alive'     # touched by the notch about once a second
$hookLog = Join-Path $reqDir 'hook.log'
$reqPath = $null; $respPath = $null; $tmp = $null; $stage = 'start'

# Stage and error type only - never request content, commands or tokens.
function Write-HookLog([string]$Text) {
    try {
        if ((Test-Path -LiteralPath $hookLog) -and (Get-Item -LiteralPath $hookLog).Length -gt 262144) {
            Move-Item -LiteralPath $hookLog -Destination ($hookLog + '.old') -Force
        }
        [System.IO.File]::AppendAllText($hookLog, ('{0} [{1}] {2}{3}' -f (Get-Date).ToString('s'), $Agent, $Text, [Environment]::NewLine))
    } catch { }
}

function Test-OverlayRunning {
    try {
        $pidText = [System.IO.File]::ReadAllText((Join-Path $appDir 'unified-overlay.pid')).Trim()
        $p = Get-Process -Id ([int]$pidText) -ErrorAction Stop
        return ($p.ProcessName -match '^(pwsh|powershell)$')
    } catch { return $false }
}

# The notch's request watcher is running and its UI thread is responsive:
# it refreshes overlay.alive about once a second. A live PID alone is not
# enough (the feature can be off, or the UI thread stuck).
function Test-OverlayReady([double]$MaxAgeSeconds = 6) {
    try {
        if (-not (Test-Path -LiteralPath $aliveFile)) { return $false }
        $age = ([DateTime]::UtcNow - [System.IO.File]::GetLastWriteTimeUtc($aliveFile)).TotalSeconds
        return ($age -le $MaxAgeSeconds -and $age -ge -60)
    } catch { return $false }
}

# The last paragraph, with code blocks and quoted lines taken out.
function Get-LastParagraph([string]$Text) {
    if (-not $Text) { return '' }
    $t = [regex]::Replace($Text, '(?s)```.*?```', ' ')
    $paras = @([regex]::Split($t.Trim(), '\r?\n\s*\r?\n') | ForEach-Object {
        (@($_ -split '\r?\n' | Where-Object { $_.Trim() -and $_.TrimStart() -notmatch '^>' }) -join ' ').Trim()
    } | Where-Object { $_ })
    if ($paras.Count -eq 0) { return '' }
    return [string]$paras[-1]
}

function Get-LastSentence([string]$Paragraph) {
    $p = $Paragraph.Trim().TrimEnd('*', '_', '`', ')', '）', ' ', '"', '”', "'")
    $parts = @([regex]::Split($p, '(?<=[\.!\?。！？])\s*') | Where-Object { $_.Trim() })
    if ($parts.Count -eq 0) { return '' }
    return ([string]$parts[-1]).Trim()
}

# A turn that ends by asking the user something ("Shall I continue?"): the
# last sentence of the last paragraph is a question. Mentions of question
# phrases elsewhere (quotes, docs, code) do not count.
function Test-EndsWithQuestion([string]$Text) {
    $s = Get-LastSentence (Get-LastParagraph $Text)
    if (-not $s) { return $false }
    if ($s -match '[\?？]$') { return $true }
    return ($s -match '(吗|呢|吧)$')
}

# "A or B?" / "Which one?": "Continue" would not answer it - leave it to the
# terminal instead of offering a meaningless button.
function Test-IsChoiceQuestion([string]$Text) {
    $s = Get-LastSentence (Get-LastParagraph $Text)
    return ($s -match '(?i)(还是|或者|哪个|哪一|哪种|哪些|\bor\b|\bwhich\b|\beither\b)')
}

# The processes that started this hook (agent, shell, terminal / editor /
# app), nearest first. This hook is gone by the time a notice is clicked, so
# the notch uses this list to find the window to bring forward.
function Get-AncestorPids {
    $chain = @()
    try {
        $parent = @{}
        foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId -ErrorAction Stop)) {
            $parent[[int]$p.ProcessId] = [int]$p.ParentProcessId
        }
        $cur = $PID
        for ($i = 0; $i -lt 12; $i++) {
            if (-not $parent.ContainsKey($cur)) { break }
            $cur = $parent[$cur]
            if ($cur -le 4 -or $chain -contains $cur) { break }
            $chain += $cur
        }
    } catch { }
    return $chain
}

# A notice (nothing to answer): <id>.note.json, written and left for the notch.
# The agent is never kept waiting for it.
function Write-Notice([string]$Kind, [string]$Text) {
    $script:stage = 'write notice'
    if (-not (Test-Path -LiteralPath $reqDir)) { New-Item -ItemType Directory -Force -Path $reqDir | Out-Null }
    if ($Text.Length -gt 4000) { $Text = '[…] ' + $Text.Substring($Text.Length - 4000) }
    $nid = [guid]::NewGuid().ToString('N')
    $note = [ordered]@{
        id      = $nid
        agent   = $Agent
        chain   = @(Get-AncestorPids)
        kind    = $Kind
        created = (Get-Date).ToString('o')
        expires = [DateTime]::UtcNow.AddSeconds(90).ToString('o')
        cwd     = [string]$in.cwd
        session = [string]$in.session_id
        message = $Text
    }
    $path = Join-Path $reqDir ($nid + '.note.json')
    $t = $path + '.tmp'
    [System.IO.File]::WriteAllText($t, ($note | ConvertTo-Json -Depth 5 -Compress), $utf8)
    Move-Item -LiteralPath $t -Destination $path -Force
}

try {
    $stage = 'read input'
    $raw = [Console]::In.ReadToEnd()
    # A UTF-8 console in the parent can prefix a byte order mark; 5.1's ConvertFrom-Json rejects it.
    if ($raw) { $raw = $raw.TrimStart([char]0xFEFF) }
    if (-not $raw) { exit 0 }
    $in = $raw | ConvertFrom-Json
    $event = [string]$in.hook_event_name
    # One line per call (event and outcome only) - enough to see whether the
    # agent calls this hook at all and where a call stops.
    Write-HookLog ('called: {0} {1}' -f $event, [string]$in.tool_name)
    if ($event -notin @('PermissionRequest', 'Stop', 'Notification')) { exit 0 }
    if (-not (Test-OverlayRunning)) { Write-HookLog 'skipped: notch not running'; exit 0 }
    if (-not (Test-OverlayReady)) { Write-HookLog 'skipped: notch not answering requests (feature off or busy)'; exit 0 }

    $message = ''
    if ($event -eq 'Notification') {
        # Claude Code needs you somewhere this hook cannot answer (its own
        # permission dialog, waiting for input, an MCP form): a notice only.
        $type = [string]$in.notification_type
        $text = [string]$in.message
        if (-not $type) {
            if ($text -match '(?i)permission') { $type = 'permission_prompt' }
            elseif ($text -match '(?i)waiting for your input|idle') { $type = 'idle_prompt' }
        }
        $kind = switch -regex ($type) {
            '^permission_prompt$' { 'permission'; break }
            '^idle_prompt$' { 'idle'; break }
            '^(elicitation_dialog|elicitation_url_dialog|agent_needs_input)$' { 'input'; break }
            default { '' }
        }
        if ($kind) { Write-Notice $kind $text; Write-HookLog ('notice: ' + $kind) } else { Write-HookLog ('ignored notification: ' + $type) }
        exit 0
    }
    if ($event -eq 'Stop') {
        # stop_hook_active is NOT a reason to skip: every continuation here
        # needs a person to click "Continue" (no click, no output), and
        # skipping would hide the next "shall I go on?" after a Continue. The
        # notch counts repeats of the same question instead.
        $message = [string]$in.last_assistant_message
        if (-not (Test-EndsWithQuestion $message)) {
            # Finished: tell the notch, and let the agent stop right away.
            Write-Notice 'done' $message
            Write-HookLog 'notice: done'
            exit 0
        }
        if (Test-IsChoiceQuestion $message) {
            # "A or B?" cannot be answered with "Continue": point to the terminal.
            Write-Notice 'ask' $message
            exit 0
        }
        # The card scrolls; only very long turns are cut, and marked as cut.
        if ($message.Length -gt 6000) { $message = '[…] ' + $message.Substring($message.Length - 6000) }
    }

    $stage = 'write request'
    if (-not (Test-Path -LiteralPath $reqDir)) { New-Item -ItemType Directory -Force -Path $reqDir | Out-Null }
    $id = [guid]::NewGuid().ToString('N')
    $limit = if ($event -eq 'Stop') { 110 } else { 590 }
    $expires = [DateTime]::UtcNow.AddSeconds($limit)
    $req = [ordered]@{
        id          = $id
        agent       = $Agent
        pid         = $PID
        processStarted = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
        expires     = $expires.ToString('o')
        event       = $event
        created     = (Get-Date).ToString('o')
        cwd         = [string]$in.cwd
        session     = [string]$in.session_id
        turn        = [string]$in.turn_id
        repeat      = [bool]$in.stop_hook_active
        tool        = [string]$in.tool_name
        input       = $in.tool_input
        suggestions = $in.permission_suggestions
        message     = $message
    }
    $reqPath = Join-Path $reqDir ($id + '.req.json')
    $respPath = Join-Path $reqDir ($id + '.resp.json')
    $tmp = $reqPath + '.tmp'
    [System.IO.File]::WriteAllText($tmp, ($req | ConvertTo-Json -Depth 30 -Compress), $utf8)
    Move-Item -LiteralPath $tmp -Destination $reqPath -Force

    # Wait for the answer. Give up (no output -> the agent asks in its own
    # terminal prompt) when the request is withdrawn, the notch stops
    # answering, or the deadline passes. The agent's own timeout is longer.
    $stage = 'wait'
    $deadline = $expires
    $resp = $null
    $tick = 0
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $respPath) {
            Start-Sleep -Milliseconds 50
            $stage = 'read answer'
            $resp = [System.IO.File]::ReadAllText($respPath, $utf8) | ConvertFrom-Json
            break
        }
        if (-not (Test-Path -LiteralPath $reqPath)) { Write-HookLog 'request withdrawn'; exit 0 }
        Start-Sleep -Milliseconds 150
        $tick++
        if ($tick % 10 -eq 0) {
            if (-not (Test-OverlayReady 10)) { Write-HookLog 'notch stopped answering'; exit 0 }
            if (-not (Test-OverlayRunning)) { Write-HookLog 'notch closed'; exit 0 }
        }
    }
    if (-not $resp -or [DateTime]::UtcNow -ge $deadline) { exit 0 }
    # Responses must belong to this request; no legacy unbound approvals.
    if ([string]$resp.id -cne $id -or [string]$resp.session -cne [string]$in.session_id) { Write-HookLog 'answer did not match'; exit 0 }

    $stage = 'answer'
    $action = [string]$resp.action
    $out = $null
    Write-HookLog ('answered: ' + $action)
    if ($event -eq 'Stop') {
        if ($action -eq 'continue') {
            $reason = [string]$resp.message
            if (-not $reason) { $reason = 'Yes, go ahead.' }
            $out = [ordered]@{ decision = 'block'; reason = $reason }
        }
    } else {
        switch ($action) {
            'allow' {
                $out = @{ hookSpecificOutput = @{ hookEventName = 'PermissionRequest'; decision = @{ behavior = 'allow' } } }
            }
            'always' {
                # Codex rejects updatedPermissions (fails closed): plain allow there.
                $decision = [ordered]@{ behavior = 'allow' }
                $sugg = @($in.permission_suggestions | Where-Object { $_ })
                if ($Agent -eq 'claude' -and $sugg.Count -gt 0) { $decision['updatedPermissions'] = $sugg }
                $out = @{ hookSpecificOutput = @{ hookEventName = 'PermissionRequest'; decision = $decision } }
            }
            'answers' {
                # AskUserQuestion (Claude Code only; Codex rejects updatedInput).
                if ($Agent -ne 'claude') { break }
                $updated = [ordered]@{}
                foreach ($p in $in.tool_input.PSObject.Properties) { $updated[$p.Name] = $p.Value }
                $answers = [ordered]@{}
                foreach ($p in $resp.answers.PSObject.Properties) { $answers[$p.Name] = [string]$p.Value }
                $updated['answers'] = $answers
                $out = @{ hookSpecificOutput = @{ hookEventName = 'PermissionRequest'; decision = @{ behavior = 'allow'; updatedInput = $updated } } }
            }
            'deny' {
                $msg = [string]$resp.message
                if (-not $msg) { $msg = 'The user declined this in JayOS AI Usage.' }
                $out = @{ hookSpecificOutput = @{ hookEventName = 'PermissionRequest'; decision = @{ behavior = 'deny'; message = $msg } } }
            }
        }
    }
    if ($out) { [Console]::Out.Write(($out | ConvertTo-Json -Depth 30 -Compress)) }
} catch {
    # Never get in the agent's way: on any problem it asks in the terminal.
    Write-HookLog ('error at {0}: {1}' -f $stage, $_.Exception.GetType().Name)
} finally {
    foreach ($p in @($reqPath, $respPath, $tmp)) {
        if ($p) { try { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } catch { } }
    }
}
exit 0
