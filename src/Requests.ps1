# Requests.ps1 - "AI requests in the notch".
#
# When Claude Code needs you - a permission ("run this command?"), a choice
# (AskUserQuestion), a plan to approve, or a turn that ends with a question -
# a card pops up next to the notch and you answer it there.
#
# How it connects: hooks\ClaudeHook.ps1 is registered as a Claude Code hook
# (PermissionRequest and Stop) in ~/.claude/settings.json while the setting is
# on. The hook drops <id>.req.json into <app>\requests and waits; the card
# writes <id>.resp.json. Cards whose hook has gone away (answered in the
# terminal, Claude stopped, timed out) disappear on their own.

$script:ReqDir = [System.IO.Path]::Combine([string]$script:AppDir, 'requests')
$script:ReqCards = [ordered]@{}        # id -> @{ Window; Req; Picks; Height }
$script:ReqTimer = $null
$script:ReqAnswered = New-Object 'System.Collections.Generic.HashSet[string]'
$script:ReqClosing = New-Object System.Collections.Generic.List[object]   # cards on their way back into the notch
$script:ReqClock = [System.Diagnostics.Stopwatch]::StartNew()
$script:ReqRenderHandler = $null
$script:ReqRendering = $false
$script:ReqHookMarker = 'ClaudeHook.ps1'
$script:ReqDetailMax = 20000     # characters of a command / edit shown on a card
$script:ReqJsonDepthMax = 100    # nesting a tool's raw input is shown to (ConvertTo-Json -Depth)

# ---------------------------------------------------------------------------
# Text (English source, translated like the rest of the UI)
# ---------------------------------------------------------------------------
foreach ($pair in @(
    @('Allow',                     '允许',               '許可',                 'Autoriser',                '허용'),
    @('Always allow',              '总是允许',           '常に許可',             'Toujours autoriser',       '항상 허용'),
    @('Deny',                      '拒绝',               '拒否',                 'Refuser',                  '거부'),
    @('In terminal',               '去终端',             'ターミナルで',         'Dans le terminal',         '터미널에서'),
    @('Submit',                    '提交',               '送信',                 'Envoyer',                  '제출'),
    @('Continue',                  '继续',               '続けて',               'Continuer',                '계속'),
    @('I''ll reply myself',        '我自己回复',         '自分で返信',           'Je réponds moi-même',      '직접 답할게요'),
    @('Run a command',             '运行命令',           'コマンドを実行',       'Exécuter une commande',    '명령 실행'),
    @('Edit a file',               '修改文件',           'ファイルを編集',       'Modifier un fichier',      '파일 수정'),
    @('Create a file',             '创建文件',           'ファイルを作成',       'Créer un fichier',         '파일 만들기'),
    @('Read a file',               '读取文件',           'ファイルを読む',       'Lire un fichier',          '파일 읽기'),
    @('Open a web page',           '打开网页',           'Web ページを開く',     'Ouvrir une page web',      '웹 페이지 열기'),
    @('Search the web',            '搜索网页',           'Web 検索',             'Rechercher sur le web',    '웹 검색'),
    @('Approve the plan',          '批准计划',           'プランを承認',         'Approuver le plan',        '계획 승인'),
    @('Claude has a question',     'Claude 有个问题',    'Claude からの質問',    'Claude a une question',    'Claude의 질문'),
    @('Claude is asking',          'Claude 在问你',      'Claude が聞いています', 'Claude vous demande',     'Claude가 묻고 있어요'),
    @('Codex is asking',           'Codex 在问你',       'Codex が聞いています', 'Codex vous demande',      'Codex가 묻고 있어요'),
    @('Edit files',                '修改文件',           'ファイルを編集',       'Modifier des fichiers',    '파일 수정'),
    @('Write a file',              '写入文件',           'ファイルに書き込む',   'Écrire un fichier',        '파일 쓰기'),
    @('every occurrence',          '全部替换',           'すべて置換',           'toutes les occurrences',   '모두 바꾸기'),
    @('change',                    '修改',               '変更',                 'modification',             '변경'),
    @('Not shown: {0} more characters', '还有 {0} 个字符未显示', 'さらに {0} 文字は非表示', '{0} caractères non affichés', '{0}자 더 있음(표시 안 됨)'),
    @('Too long to review here. Read it in the terminal to allow it.', '内容太长，这里看不全。要允许请去终端查看。', '長すぎてここでは確認できません。許可するにはターミナルで確認してください。', 'Trop long pour être relu ici. Lisez-le dans le terminal pour l''autoriser.', '여기서 다 볼 수 없습니다. 허용하려면 터미널에서 확인하세요.'),
    @('Asked again: {0} times',    '已经第 {0} 次问了',  '{0} 回目の質問です',   'Demandé {0} fois',         '{0}번째 질문'),
    @('{0} finished',              '{0} 完成了',         '{0} が完了しました',   '{0} a terminé',            '{0} 완료'),
    @('{0} is asking you something', '{0} 在问你一个问题', '{0} から質問があります', '{0} vous pose une question', '{0}가 질문하고 있어요'),
    @('{0} needs your permission', '{0} 需要你的授权',   '{0} が許可を求めています', '{0} demande votre autorisation', '{0}가 권한을 요청합니다'),
    @('{0} is waiting for you',    '{0} 在等你',         '{0} があなたを待っています', '{0} vous attend',      '{0}가 기다리고 있어요'),
    @('{0} needs your input',      '{0} 需要你输入',     '{0} が入力を求めています', '{0} attend une réponse', '{0}가 입력을 기다립니다'),
    @('Answer it in the terminal.', '请到终端里回答。',   'ターミナルで回答してください。', 'Répondez dans le terminal.', '터미널에서 답해 주세요.'),
    @('OK',                        '知道了',             'OK',                   'OK',                       '확인'),
    @('Show me',                   '去看看',             '表示する',             'Voir',                     '보기'),
    @('Open Claude',               '打开 Claude',        'Claude を開く',        'Ouvrir Claude',            'Claude 열기'),
    @('Approve in Claude',         '去 Claude 里批准',   'Claude で承認',        'Approuver dans Claude',    'Claude에서 승인'),
    @('Click below to jump to it, then press Allow there.', '点下面的按钮跳过去，在那里点「允许」。', '下のボタンで移動し、そこで「許可」を押してください。', 'Cliquez ci-dessous pour y aller, puis sur Autoriser.', '아래 버튼으로 이동한 뒤 거기서 허용을 누르세요.'),
    @('Approve it in the Claude app.', '请到 Claude 应用里批准。', 'Claude アプリで承認してください。', 'Approuvez dans l''app Claude.', 'Claude 앱에서 승인해 주세요.'),
    @('Copy',                      '复制',               'コピー',               'Copier',                   '복사'),
    @('Copied',                    '已复制',             'コピーしました',       'Copié',                    '복사됨'),
    @('Notify when a task finishes', '任务完成时通知',    'タスク完了時に通知',   'Notifier quand une tâche se termine', '작업 완료 시 알림'),
    @('Notify when the AI needs you', 'AI 需要你时提醒',  'AI が呼んだら通知',     'Notifier quand l''IA a besoin de vous', 'AI가 필요로 할 때 알림'),
    @('Pick one',                  '选一个',             '1 つ選択',             'Choisissez',               '하나 선택'),
    @('Pick any',                  '可多选',             '複数選択可',           'Plusieurs choix',          '여러 개 선택'),
    @('Yes, go ahead.',            '可以，继续。',       'はい、続けてください。', 'Oui, continuez.',        '네, 계속하세요.'),
    @('AI requests in the notch',  '刘海里处理 AI 请求', 'ノッチで AI の確認に応答', 'Demandes IA dans l''encoche', '노치에서 AI 요청 처리'),
    @('Remind again if unanswered', '未处理时再次提醒', '未応答なら再通知',     'Rappeler sans réponse',    '응답 없으면 다시 알림'),
    @('Off',                       '关闭',               'オフ',                 'Désactivé',                '끄기'),
    @('Renew Claude sign-in automatically', '自动续期 Claude 登录', 'Claude のサインインを自動更新', 'Renouveler la connexion Claude', 'Claude 로그인 자동 갱신'),
    @('Always allow also grants:',  '“总是允许”还会授予：', '「常に許可」で次も許可されます:', '« Toujours autoriser » accorde aussi :', '''항상 허용''은 다음 권한도 부여합니다:'),
    @('Rule ({0}): {1}',           '规则（{0}）：{1}',   'ルール（{0}）: {1}',   'Règle ({0}) : {1}',        '규칙({0}): {1}'),
    @('Replace rules ({0}): {1}',  '替换规则（{0}）：{1}', 'ルールを置換（{0}）: {1}', 'Remplacer les règles ({0}) : {1}', '규칙 교체({0}): {1}'),
    @('Remove rule ({0}): {1}',    '删除规则（{0}）：{1}', 'ルールを削除（{0}）: {1}', 'Supprimer la règle ({0}) : {1}', '규칙 삭제({0}): {1}'),
    @('Permission mode: {0}',      '权限模式：{0}',      '権限モード: {0}',      'Mode d''autorisation : {0}', '권한 모드: {0}'),
    @('Folder access: {0}',        '允许访问文件夹：{0}', 'フォルダーへのアクセス: {0}', 'Accès au dossier : {0}', '폴더 접근: {0}'),
    @('Remove folder access: {0}', '取消文件夹访问：{0}', 'フォルダーのアクセスを削除: {0}', 'Retirer l''accès au dossier : {0}', '폴더 접근 해제: {0}')
)) {
    if ($script:I18nText -and -not $script:I18nText.ContainsKey($pair[0])) {
        $script:I18nText[$pair[0]] = @{ zh = $pair[1]; ja = $pair[2]; fr = $pair[3]; ko = $pair[4] }
    }
}
if ($script:I18nRules) {
    $script:I18nRules = @(
        @{ rx = '^Use (.+)$'; zh = '使用 $1'; ja = '$1 を使用'; fr = 'Utiliser $1'; ko = '$1 사용' },
        @{ rx = '^(\d+) s$'; zh = '$1 秒后'; ja = '$1 秒後'; fr = 'après $1 s'; ko = '$1초 후' }
    ) + @($script:I18nRules)
}

function Get-ReqText([string]$Text) {
    try { return (Convert-I18nString $Text (Get-UiLanguage)) } catch { return $Text }
}

# ---------------------------------------------------------------------------
# Hook registration
#   Claude Code: ~/.claude/settings.json        (PermissionRequest + Stop)
#   Codex:       ~/.codex/hooks.json            (PermissionRequest + Stop)
# Both use the same hook script; -Agent tells it which one is calling.
# ---------------------------------------------------------------------------
function Get-ClaudeUserSettingsPath {
    $dir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
    return (Join-Path $dir 'settings.json')
}

function Get-CodexHomeDir {
    if ($env:CODEX_HOME) { return $env:CODEX_HOME }
    return (Join-Path $env:USERPROFILE '.codex')
}

function Get-CodexHooksPath { return (Join-Path (Get-CodexHomeDir) 'hooks.json') }

function Get-ClaudeHookCommand([string]$Agent = 'claude', [string]$AppDir = $script:AppDir, [switch]$QuotedExe) {
    # Forward slashes and an unquoted powershell.exe (System32 has no spaces):
    # the same line runs from cmd, PowerShell and Git Bash alike.
    $root = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
    $ps = ($root.TrimEnd('\') + '\System32\WindowsPowerShell\v1.0\powershell.exe') -replace '\\', '/'
    if ($QuotedExe -or $ps -match ' ') { $ps = '"' + $ps + '"' }
    $hook = ($AppDir.TrimEnd('\', '/') + '\hooks\' + $script:ReqHookMarker) -replace '\\', '/'
    $line = '{0} -NoLogo -NoProfile -ExecutionPolicy Bypass -File "{1}"' -f $ps, $hook
    if ($Agent -and $Agent -ne 'claude') { $line += ' -Agent ' + $Agent }
    return $line
}

# Which hook entries are ours. Only exact commands JayOS wrote count - never
# "any command mentioning ClaudeHook.ps1", which could be someone else's.
# The record lives in JayOS's own folder (hook-registrations.json), not as an
# extra field in the agents' settings files.
function Get-ReqRegistryPath { return [System.IO.Path]::Combine([string]$script:AppDir, 'hook-registrations.json') }

function Get-ReqRegisteredCommands {
    $list = @()
    try {
        $path = Get-ReqRegistryPath
        if (Test-Path -LiteralPath $path) {
            $j = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
            $list = @($j.commands | ForEach-Object { [string]$_ } | Where-Object { $_ })
        }
    } catch { }
    return ,$list
}

function Add-ReqRegisteredCommand([string]$Command) {
    $all = New-Object System.Collections.Generic.List[string]
    foreach ($c in (Get-ReqRegisteredCommands)) { if (-not $all.Contains($c)) { $all.Add($c) } }
    if (-not $all.Contains($Command)) { $all.Add($Command) }
    $path = Get-ReqRegistryPath
    $tmp = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [System.IO.File]::WriteAllText($tmp, (@{ commands = @($all) } | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

# Every command this install may have written: the current form, the earlier
# quoted-exe form (0.0.3 previews) for this folder, and anything recorded.
function Get-ReqOwnedCommands([string]$Agent) {
    $own = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    [void]$own.Add((Get-ClaudeHookCommand $Agent))
    [void]$own.Add((Get-ClaudeHookCommand $Agent -QuotedExe))
    foreach ($c in (Get-ReqRegisteredCommands)) { [void]$own.Add($c) }
    return ,$own
}

# One writer at a time inside JayOS (the notch and Setup share this lock).
function Invoke-WithReqHookLock([scriptblock]$Body) {
    $m = New-Object System.Threading.Mutex($false, 'Local\JayOS-AIUsage-AgentHooks')
    $held = $false
    try {
        try { $held = $m.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'Another JayOS process is updating the hook settings.' }
        return (& $Body)
    } finally {
        if ($held) { try { $m.ReleaseMutex() } catch { } }
        $m.Dispose()
    }
}

# Adds (On) or removes our PermissionRequest and Stop hooks in one agent's
# hooks file, keeping everything else in it. A file it cannot parse is left
# untouched (the error goes to the caller). If the file changes while we
# merge (the user or the agent saving it), the merge starts over from the new
# content instead of overwriting it. Returns $true when done.
function Set-AgentRequestHooks([string]$Path, [string]$Agent, [bool]$On) {
    return (Invoke-WithReqHookLock {
        $dir = Split-Path -Parent $Path
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            $cmd = Get-ClaudeHookCommand $Agent
            $owned = Get-ReqOwnedCommands $Agent
            $exists = Test-Path -LiteralPath $Path
            $before = $null
            if (-not $exists) {
                if (-not $On) { return $true }
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
                $doc = New-Object PSObject
            } else {
                $before = [System.IO.File]::ReadAllBytes($Path)
                $raw = [System.IO.File]::ReadAllText($Path)
                $doc = if ($raw.Trim()) { $raw | ConvertFrom-Json -ErrorAction Stop } else { New-Object PSObject }
            }

            $hooks = $doc.PSObject.Properties['hooks']
            $hooksObj = if ($hooks -and $hooks.Value) { $hooks.Value } else { New-Object PSObject }
            $changed = $false
            # Claude Code also tells us when it waits in its own prompt
            # (Notification); Codex has no such event.
            $mine = if ($Agent -eq 'codex') { @('PermissionRequest', 'Stop') } else { @('PermissionRequest', 'Stop', 'Notification') }
            foreach ($evt in @('PermissionRequest', 'Stop', 'Notification')) {
                $kept = @()
                $prop = $hooksObj.PSObject.Properties[$evt]
                foreach ($group in @($(if ($prop) { $prop.Value }))) {
                    if (-not $group) { continue }
                    $all = @(@($group.hooks) | Where-Object { $_ })
                    $inner = @($all | Where-Object { -not $owned.Contains([string]$_.command) })
                    if ($inner.Count -ne $all.Count) { $changed = $true }
                    if ($inner.Count -eq 0) { continue }
                    $group.hooks = $inner
                    $kept += $group
                }
                if ($On -and $mine -contains $evt) {
                    $timeout = switch ($evt) { 'Stop' { 120 } 'Notification' { 10 } default { 600 } }
                    $handler = [ordered]@{ type = 'command'; command = $cmd; timeout = $timeout }
                    $entry = [ordered]@{}
                    if ($Agent -eq 'codex') {
                        # Codex: no matcher means every tool; Windows-only
                        # override and a status line while it waits.
                        $handler['commandWindows'] = $cmd
                        $handler['statusMessage'] = 'Waiting for your answer in the JayOS notch'
                    } elseif ($evt -eq 'PermissionRequest') {
                        $entry['matcher'] = '*'
                    }
                    $entry['hooks'] = @([pscustomobject]$handler)
                    $kept += [pscustomobject]$entry
                    $changed = $true
                }
                if ($prop) { $hooksObj.PSObject.Properties.Remove($evt) }
                if ($kept.Count -gt 0) { $hooksObj | Add-Member -NotePropertyName $evt -NotePropertyValue @($kept) -Force }
            }
            if (-not $changed -and $exists) { return $true }      # nothing of ours there: leave the file alone
            if ($doc.PSObject.Properties['hooks']) { $doc.PSObject.Properties.Remove('hooks') }
            if (@($hooksObj.PSObject.Properties).Count -gt 0 -or $Agent -eq 'codex') {
                $doc | Add-Member -NotePropertyName 'hooks' -NotePropertyValue $hooksObj -Force
            }
            $json = $doc | ConvertTo-Json -Depth 64

            # The record only widens what counts as ours later; failing to
            # write it must not block registering the hook itself.
            if ($On) { try { Add-ReqRegisteredCommand $cmd } catch { try { Write-Log "AI requests: hook record not saved - $($_.Exception.Message)" } catch { } } }
            $tmp = $Path + '.jayos-' + [guid]::NewGuid().ToString('N') + '.tmp'
            try {
                [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
                if ($exists) {
                    # Changed since we read it? Merge again from the new content.
                    $now = [System.IO.File]::ReadAllBytes($Path)
                    if ([Convert]::ToBase64String($now) -ne [Convert]::ToBase64String($before)) { continue }
                    $backup = $Path + '.jayos-backup'
                    if (-not (Test-Path -LiteralPath $backup)) { [System.IO.File]::WriteAllBytes($backup, $before) }
                    [System.IO.File]::Replace($tmp, $Path, [NullString]::Value)
                } else {
                    if (Test-Path -LiteralPath $Path) { continue }       # created meanwhile: merge into it
                    [System.IO.File]::Move($tmp, $Path)
                }
                return $true
            } finally {
                if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            }
        }
        throw ('{0} kept changing while JayOS was updating it; try again.' -f $Path)
    })
}

function Set-ClaudeRequestHooks([bool]$On) {
    return (Set-AgentRequestHooks (Get-ClaudeUserSettingsPath) 'claude' $On)
}

# Only when Codex is installed (its home folder exists); otherwise nothing to do.
function Set-CodexRequestHooks([bool]$On) {
    if (-not (Test-Path -LiteralPath (Get-CodexHomeDir))) { return $false }
    return (Set-AgentRequestHooks (Get-CodexHooksPath) 'codex' $On)
}

function Test-AiRequestsEnabled { return [bool]$script:Cfg['AiRequests'] }

# Registers (or removes) the hooks for every agent; one failing does not stop
# the other. Returns the agents that could not be updated, with the reason.
function Update-AllRequestHooks([bool]$On) {
    $failed = @()
    foreach ($a in @(
        @{ Name = 'Claude Code'; Set = { param($v) Set-ClaudeRequestHooks $v }; Path = { Get-ClaudeUserSettingsPath } },
        @{ Name = 'Codex';       Set = { param($v) Set-CodexRequestHooks $v };  Path = { Get-CodexHooksPath } })) {
        try { [void](& $a.Set $On) }
        catch {
            $failed += ("{0}: {1}`n{2}" -f $a.Name, (& $a.Path), $_.Exception.Message)
            try { Write-Log "AI requests: $($a.Name) hooks not updated - $($_.Exception.Message)" } catch { }
        }
    }
    return ,$failed
}

function Set-AiRequestsEnabled([bool]$On) {
    $failed = Update-AllRequestHooks $On
    $script:Cfg['AiRequests'] = $On
    try { Save-UnifiedState } catch { }
    if ($On) { Start-RequestWatcher } else { Stop-RequestWatcher }
    if ($failed.Count -gt 0) {
        try {
            [void][System.Windows.Forms.MessageBox]::Show(
                "These settings files could not be updated:`n`n" + ($failed -join "`n`n"),
                'JayOS AI Usage', 'OK', 'Warning')
        } catch { }
    }
}

# Re-registers on start, so a moved install folder, a newly installed Codex or
# a settings file that was replaced keeps working.
function Initialize-AiRequests {
    if (-not (Test-AiRequestsEnabled)) { return }
    [void](Update-AllRequestHooks $true)
    Start-RequestWatcher
}

# ---------------------------------------------------------------------------
# Watching for requests
# ---------------------------------------------------------------------------
function Get-ReqAlivePath { return [System.IO.Path]::Combine($script:ReqDir, 'overlay.alive') }

# The hook only hands a request over while this file is fresh, so a notch
# that is closed, switched off or stuck never leaves an agent waiting.
$script:ReqAliveAt = [DateTime]::MinValue
function Update-ReqHeartbeat {
    $now = [DateTime]::UtcNow
    if (($now - $script:ReqAliveAt).TotalMilliseconds -lt 900) { return }
    $script:ReqAliveAt = $now
    try {
        $f = Get-ReqAlivePath
        if (Test-Path -LiteralPath $f) { [System.IO.File]::SetLastWriteTimeUtc($f, $now) }
        else { [System.IO.File]::WriteAllText($f, 'JayOS AI Usage is answering requests.') }
    } catch { }
}

function Start-RequestWatcher {
    if (-not (Test-Path -LiteralPath $script:ReqDir)) { New-Item -ItemType Directory -Force -Path $script:ReqDir | Out-Null }
    # Leftovers from a crash or a restart.
    Get-ChildItem -LiteralPath $script:ReqDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-15) -and $_.Name -notlike 'hook.log*' } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    if (-not $script:ReqTimer) {
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromMilliseconds(300)
        $t.add_Tick({ try { Invoke-RequestPoll } catch { try { Write-Log "AI requests: poll error - $($_.Exception.Message)" } catch { } } })
        $script:ReqTimer = $t
    }
    $script:ReqAliveAt = [DateTime]::MinValue
    Update-ReqHeartbeat
    $script:ReqTimer.Start()
    try { Initialize-ReqWindowNative } catch { try { Write-Log "AI requests: window helper unavailable - $($_.Exception.Message)" } catch { } }
}

# Switched off (or quitting): hand every waiting request back to the agent's
# own prompt right away instead of leaving the hooks to time out.
function Stop-RequestWatcher {
    if ($script:ReqTimer) { $script:ReqTimer.Stop() }
    try { Remove-Item -LiteralPath (Get-ReqAlivePath) -Force -ErrorAction SilentlyContinue } catch { }
    foreach ($f in @(Get-ChildItem -LiteralPath $script:ReqDir -Filter '*.req.json' -File -ErrorAction SilentlyContinue)) {
        $id = $f.Name.Substring(0, $f.Name.Length - '.req.json'.Length)
        $req = Get-ReqParsed $f
        if ($req -and (Test-RequestIdentity $req $id)) { [void](Write-ReqAnswerFile $id ([string]$req.session) @{ action = 'terminal' }) }
    }
    # Notices waiting to be shown are dropped (nothing depends on them).
    Get-ChildItem -LiteralPath $script:ReqDir -Filter '*.note.json' -File -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    foreach ($id in @($script:ReqCards.Keys)) { Close-RequestCard $id -Instant }
    foreach ($c in $script:ReqClosing.ToArray()) { try { $c.Window.Close() } catch { } }
    $script:ReqClosing.Clear()
    $script:ReqParseCache = @{}
}

# Writes <id>.resp.json bound to the request (id + session). Never replaces an
# answer that is already there. Returns $true when this call wrote it.
function Write-ReqAnswerFile([string]$Id, [string]$Session, [hashtable]$Answer) {
    if ($Id -cnotmatch '^[a-f0-9]{32}$') { return $false }
    $resp = Join-Path $script:ReqDir ($Id + '.resp.json')
    if (Test-Path -LiteralPath $resp) { return $false }
    $bound = @{} + $Answer
    $bound.id = $Id
    $bound.session = $Session
    $tmp = $resp + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [System.IO.File]::WriteAllText($tmp, ($bound | ConvertTo-Json -Depth 10 -Compress), (New-Object System.Text.UTF8Encoding($false)))
        # File.Move does not overwrite an answer that won the race.
        [IO.File]::Move($tmp, $resp)
        return $true
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

# Request files are parsed once per version (size + time), not every poll.
# Oversized or unreadable files are remembered as bad and skipped.
$script:ReqParseCache = @{}
function Get-ReqParsed($File) {
    $stamp = '{0}|{1}' -f $File.Length, $File.LastWriteTimeUtc.Ticks
    $hit = $script:ReqParseCache[$File.FullName]
    if ($hit -and $hit.Stamp -eq $stamp) { return $hit.Req }
    $req = $null
    try {
        if ($File.Length -le 1048576) {
            $req = [System.IO.File]::ReadAllText($File.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        }
    } catch { $req = $null }
    if (-not $req) { try { Write-Log "AI requests: skipped unreadable request $($File.Name)" } catch { } }
    $script:ReqParseCache[$File.FullName] = @{ Stamp = $stamp; Req = $req }
    return $req
}

# One card at a time, oldest request first; the rest wait their turn (the
# card shows how many are waiting).

# A time from a request/notice file as UTC. PowerShell 7's ConvertFrom-Json
# turns ISO strings into [datetime] already; turning that back into a string
# drops the time zone, so never round-trip through [string].
function ConvertTo-ReqUtc($Value) {
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    if ($Value -is [DateTime]) {
        if ($Value.Kind -eq [DateTimeKind]::Local) { return $Value.ToUniversalTime() }
        return [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc)
    }
    $text = [string]$Value
    if (-not $text) { throw 'No time given.' }
    return [DateTimeOffset]::Parse($text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
}

# Request ids become filenames and callback arguments: reject all metacharacters.
function Test-RequestIdentity($Req, [string]$ExpectedId) {
    return ($ExpectedId -cmatch '^[a-f0-9]{32}$' -and [string]$Req.id -ceq $ExpectedId -and
        [string]$Req.event -cin @('PermissionRequest', 'Stop'))
}

function Test-RequestLive($Req) {
    try {
        if ([string]$Req.expires) {
            if ((ConvertTo-ReqUtc $Req.expires) -le [DateTime]::UtcNow) { return $false }
        } else {
            # Compatibility with an in-flight pre-upgrade hook, bounded by age.
            $created = (ConvertTo-ReqUtc $Req.created)
            $limit = if ($Req.event -eq 'Stop') { 110 } else { 590 }
            if ($created -gt [DateTime]::UtcNow.AddSeconds(5) -or $created.AddSeconds($limit) -le [DateTime]::UtcNow) { return $false }
        }
        $process = Get-Process -Id ([int]$Req.pid) -ErrorAction Stop
        if ([string]$Req.processStarted) {
            $started = (ConvertTo-ReqUtc $Req.processStarted)
            if ($process.StartTime.ToUniversalTime().Ticks -ne $started.Ticks) { return $false }
        }
        return $true
    } catch { return $false }
}

function Test-RequestAlwaysAllowed($Req) {
    return ([string]$Req.agent -ne 'codex' -and @($Req.suggestions | Where-Object { $_ }).Count -gt 0)
}

function Invoke-RequestPoll {
    if (-not (Test-Path -LiteralPath $script:ReqDir)) { return }
    Update-ReqHeartbeat
    $files = @(Get-ChildItem -LiteralPath $script:ReqDir -Filter '*.req.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc)
    $live = @{}
    $seen = @{}
    $waiting = New-Object System.Collections.Generic.List[object]
    foreach ($f in $files) {
        $seen[$f.FullName] = $true
        $id = $f.Name.Substring(0, $f.Name.Length - '.req.json'.Length)
        $live[$id] = $true
        if ($script:ReqCards.Contains($id)) { continue }
        # Already answered: the hook is about to pick up the answer and remove
        # the request; showing it again would make the card flash back.
        if ($script:ReqAnswered.Contains($id)) { continue }
        if (Test-Path -LiteralPath (Join-Path $script:ReqDir ($id + '.resp.json'))) { continue }
        $candidate = Get-ReqParsed $f
        if (-not $candidate) { continue }
        if (-not (Test-RequestIdentity $candidate $id) -or -not (Test-RequestLive $candidate)) { continue }
        $waiting.Add($candidate)
    }
    foreach ($k in @($script:ReqParseCache.Keys)) {
        if (-not $seen.ContainsKey($k) -and -not (Test-Path -LiteralPath $k)) { $script:ReqParseCache.Remove($k) }
    }
    foreach ($id in @($script:ReqAnswered)) { if (-not $live.ContainsKey($id)) { [void]$script:ReqAnswered.Remove($id) } }

    # Gone from disk (answered in the terminal, timed out) or the hook died.
    foreach ($id in @($script:ReqCards.Keys)) {
        $card = $script:ReqCards[$id]
        if ($card.IsNotice) { continue }
        $alive = Test-RequestLive $card.Req
        if (-not $live.ContainsKey($id) -or -not $alive) { Close-RequestCard $id }
    }

    # A card whose fold-back animation did not finish is closed for good, so
    # it can never hold up the queue.
    foreach ($c in $script:ReqClosing.ToArray()) {
        if ($c.ClosingSince -and ([DateTime]::UtcNow - $c.ClosingSince).TotalSeconds -gt 3) {
            try { $c.Window.Close() } catch { }
            [void]$script:ReqClosing.Remove($c)
        }
    }

    # Notices give way to anything that needs an answer; otherwise they close
    # on their own (not while the pointer is on them).
    $notes = Get-ReqWaitingNotices $waiting
    foreach ($id in @($script:ReqCards.Keys)) {
        $card = $script:ReqCards[$id]
        if (-not $card.IsNotice) { continue }
        $hover = $false
        try { $hover = [bool]$card.Window.IsMouseOver } catch { }
        if ($card.Sticky) {
            # Stays until Cowork withdraws the note (the request was answered)
            # or it expires. Steps aside for a request and comes back after.
            $nf = Join-Path $script:ReqDir ($id + '.note.json')
            $still = $false
            try {
                $fi = Get-Item -LiteralPath $nf -ErrorAction Stop
                $now = Get-ReqParsed $fi      # re-read: Cowork withdraws it by setting a past expiry
                $still = $now -and (Test-NoticeValid $now $id)
            } catch { }
            if (-not $still) { Close-NoticeCard $id }
            elseif ($waiting.Count -gt 0) { Close-RequestCard $id }
            continue
        }
        if ($hover) { $card.AutoCloseAt = [DateTime]::UtcNow.AddSeconds(2) }
        if ($waiting.Count -gt 0 -or ([DateTime]::UtcNow -ge $card.AutoCloseAt)) { Close-NoticeCard $id }
    }

    # Next card once the previous one has gone back into the notch.
    if ($script:ReqCards.Count -eq 0 -and $script:ReqClosing.Count -eq 0 -and $waiting.Count -eq 0 -and $notes.Count -gt 0) {
        $note = $notes[0]
        $notes.RemoveAt(0)
        try { Show-NoticeCard $note } catch {
            try { Write-Log "AI requests: notice could not be shown - $($_.Exception.Message)" } catch { }
            Close-NoticeCard ([string]$note.id)
        }
    }
    if ($script:ReqCards.Count -eq 0 -and $script:ReqClosing.Count -eq 0 -and $waiting.Count -gt 0) {
        $req = $waiting[0]
        $waiting.RemoveAt(0)
        try { Show-RequestCard $req } catch {
            try { Write-Log "AI requests: card could not be shown - $($_.Exception.Message)" } catch { }
            # Hand it back to the agent's own prompt rather than retrying forever.
            [void]$script:ReqAnswered.Add([string]$req.id)
            try { [void](Write-ReqAnswerFile ([string]$req.id) ([string]$req.session) @{ action = 'terminal' }) } catch { }
            if ($script:ReqCards.Contains([string]$req.id)) { Close-RequestCard ([string]$req.id) -Instant }
        }
    }
    $remind = 25
    try { if ($null -ne $script:Cfg['AiRequestRemind']) { $remind = [int]$script:Cfg['AiRequestRemind'] } } catch { }
    $more = $waiting.Count + $notes.Count
    foreach ($c in @($script:ReqCards.Values)) {
        if ($c.Badge) { $c.Badge.Text = if ($more -gt 0) { '+' + $more } else { '' } }
        if ($c.IsNotice -and -not $c.Sticky) { continue }
        if ($c.Sticky -and $c.Reminded -and $remind -gt 0 -and ([DateTime]::UtcNow - $c.Shown).TotalSeconds -ge $remind) {
            # A waiting approval keeps chiming at the reminder interval.
            $c.Shown = [DateTime]::UtcNow; $c.Reminded = $false
        }
        if (-not $c.Reminded -and $c.Shown -and $remind -gt 0 -and ([DateTime]::UtcNow - $c.Shown).TotalSeconds -ge $remind) {
            $c.Reminded = $true
            Invoke-RequestSound
        }
    }
}

function Send-RequestAnswer([string]$Id, [hashtable]$Answer) {
    $tmp = $null
    if ($Id -cnotmatch '^[a-f0-9]{32}$' -or $script:ReqAnswered.Contains($Id)) { return }
    $card = $script:ReqCards[$Id]
    if (-not $card) { return }
    try {
        $reqPath = Join-Path $script:ReqDir ($Id + '.req.json')
        if (-not (Test-Path -LiteralPath $reqPath) -or -not (Test-RequestLive $card.Req)) {
            Close-RequestCard $Id
            return
        }
        $disk = [IO.File]::ReadAllText($reqPath) | ConvertFrom-Json
        if (-not (Test-RequestIdentity $disk $Id) -or
            [string]$disk.session -cne [string]$card.Req.session) { return }
        $action = [string]$Answer.action
        if ($card.Req.event -eq 'Stop') {
            if ($action -cnotin @('continue', 'ignore', 'terminal')) { return }
        } else {
            if ($action -cnotin @('allow', 'deny', 'always', 'answers', 'terminal')) { return }
            if ($action -eq 'always' -and -not (Test-RequestAlwaysAllowed $card.Req)) { return }
            if ($action -eq 'answers' -and ($card.Req.agent -eq 'codex' -or $card.Req.tool -ne 'AskUserQuestion')) { return }
            # Content too long to show in full: it can only be denied here.
            if ($card.Truncated -and $action -cin @('allow', 'always')) { return }
        }
        $resp = Join-Path $script:ReqDir ($Id + '.resp.json')
        if (Test-Path -LiteralPath $resp) { Close-RequestCard $Id; return }
        if (Write-ReqAnswerFile $Id ([string]$card.Req.session) $Answer) {
            if ($action -eq 'terminal') { $script:ReqRecentTerminal[[string]$card.Req.agent + '|' + [string]$card.Req.session] = [DateTime]::UtcNow }
            [void]$script:ReqAnswered.Add($Id)
            Close-RequestCard $Id
        }
    } catch {
        # Keep the card available for retry if writing fails.
        try { Write-Log "AI requests: answer not written - $($_.Exception.Message)" } catch { }
    } finally {
        if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------------------
# Cards
# ---------------------------------------------------------------------------
function Get-RequestSummary($Req) {
    $tool = [string]$Req.tool
    $in = $Req.input
    $title = ''; $detail = ''; $note = ''; $mono = $false; $tooDeep = $false
    switch -regex ($tool) {
        '^(Bash|PowerShell|shell|local_shell|exec_command|unified_exec)$' {
            # Codex can hand the command over as an argument list.
            $c = $in.command
            if ($c -is [System.Array]) { $c = (@($c) | ForEach-Object { [string]$_ }) -join ' ' }
            if (-not $c -and $in.cmd) { $c = $in.cmd }
            # The command comes first and alone: the description is the model's
            # own words and must never push what actually runs out of view.
            $title = 'Run a command'; $detail = [string]$c; $mono = $true
            $note = (@([string]$in.justification, [string]$in.description) | Where-Object { $_ }) -join "`n"
        }
        '^apply_patch$' {
            $c = $in.command
            if (-not $c) { $c = $in.input }
            if ($c -is [System.Array]) { $c = (@($c) | ForEach-Object { [string]$_ }) -join "`n" }
            $title = 'Edit files'; $detail = [string]$c; $mono = $true
        }
        '^Edit$' {
            # What actually changes, not just where.
            $title = 'Edit a file'; $mono = $true
            $detail = [string]$in.file_path + $(if ($in.replace_all) { '   (' + (Get-ReqText 'every occurrence') + ')' } else { '' }) + "`n`n" +
                (Format-ReqDiff ([string]$in.old_string) ([string]$in.new_string))
        }
        '^MultiEdit$' {
            $title = 'Edit a file'; $mono = $true
            $parts = @([string]$in.file_path)
            $n = 0
            foreach ($e in @($in.edits)) {
                $n++
                $parts += ('@@ {0} {1}' -f (Get-ReqText 'change'), $n) + $(if ($e.replace_all) { '   (' + (Get-ReqText 'every occurrence') + ')' } else { '' })
                $parts += (Format-ReqDiff ([string]$e.old_string) ([string]$e.new_string))
            }
            $detail = $parts -join "`n`n"
        }
        '^NotebookEdit$' {
            $title = 'Edit a file'; $mono = $true
            $detail = ('{0}   cell {1}   {2}' -f [string]$in.notebook_path, [string]$in.cell_id, [string]$in.edit_mode).TrimEnd() + "`n`n" +
                (Format-ReqDiff '' ([string]$in.new_source))
        }
        '^Write$' {
            # The whole new file content.
            $title = 'Write a file'; $mono = $true
            $detail = [string]$in.file_path + "`n`n" + [string]$in.content
        }
        '^Read$' { $title = 'Read a file'; $detail = [string]$in.file_path }
        '^WebFetch$' { $title = 'Open a web page'; $detail = [string]$in.url }
        '^WebSearch$' { $title = 'Search the web'; $detail = [string]$in.query }
        '^ExitPlanMode$' { $title = 'Approve the plan'; $detail = [string]$in.plan }
        default {
            $name = $tool -replace '^mcp__', '' -replace '__', ' · '
            $title = 'Use ' + $name
            try { $detail = ($in | ConvertTo-Json -Depth $script:ReqJsonDepthMax -Compress -WarningAction SilentlyContinue) } catch { $detail = '' }
            # Deeper than that, ConvertTo-Json writes "@{x=}" in place of the
            # content: what would be allowed is not what the card shows.
            if ((Get-ReqJsonDepth $in ($script:ReqJsonDepthMax + 1)) -gt $script:ReqJsonDepthMax) { $tooDeep = $true }
            $mono = $true
        }
    }
    # The full operation goes in the scrollable detail area. Beyond a size a
    # card can sensibly show, it is cut, marked, and can only be denied here
    # (Allow needs the terminal, where all of it can be read).
    $truncated = $tooDeep
    if ($note.Length -gt $script:ReqDetailMax) { $note = $note.Substring(0, $script:ReqDetailMax) + ' […]' }
    if ($detail.Length -gt $script:ReqDetailMax) {
        $more = $detail.Length - $script:ReqDetailMax
        $detail = $detail.Substring(0, $script:ReqDetailMax) + "`n`n[… " + ((Get-ReqText 'Not shown: {0} more characters') -f $more) + ']'
        $truncated = $true
    }
    $grants = if (Test-RequestAlwaysAllowed $Req) { Format-ReqGrants $Req.suggestions } else { '' }
    return @{ Title = (Get-ReqText $title); Detail = $detail; Note = $note; Mono = $mono; Truncated = $truncated; Grants = $grants }
}

# How deeply objects and arrays nest in $Value (a plain value is 0). Counted
# without recursion, and only up to $Stop, so a hostile input stays cheap.
function Get-ReqJsonDepth($Value, [int]$Stop = 1000) {
    $max = 0
    $values = New-Object 'System.Collections.Generic.Stack[object]'
    $levels = New-Object 'System.Collections.Generic.Stack[int]'
    $values.Push($Value); $levels.Push(1)
    while ($values.Count -gt 0) {
        $v = $values.Pop(); $level = $levels.Pop()
        if ($null -eq $v -or $v -is [string] -or $v -is [ValueType]) { continue }
        if ($level -gt $max) { $max = $level; if ($max -gt $Stop) { break } }
        if ($v -is [System.Collections.IDictionary]) {
            foreach ($k in @($v.Keys)) { $values.Push($v[$k]); $levels.Push($level + 1) }
        } elseif ($v -is [System.Collections.IEnumerable]) {
            foreach ($c in $v) { $values.Push($c); $levels.Push($level + 1) }
        } else {
            foreach ($p in $v.PSObject.Properties) { $values.Push($p.Value); $levels.Push($level + 1) }
        }
    }
    return $max
}

# What "Always allow" hands back to Claude Code (its permission_suggestions),
# one line each, so the card says what is granted and where it is saved.
function Format-ReqGrants($Suggestions) {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($s in @($Suggestions | Where-Object { $_ })) {
        $where = if ([string]$s.destination) { '  · ' + [string]$s.destination } else { '' }
        switch -regex ([string]$s.type) {
            '^(addRules|replaceRules|removeRules)$' {
                $rules = (@($s.rules | Where-Object { $_ } | ForEach-Object {
                    if ([string]$_.ruleContent) { '{0}({1})' -f [string]$_.toolName, [string]$_.ruleContent } else { [string]$_.toolName }
                })) -join ', '
                $fmt = switch ([string]$s.type) { 'addRules' { 'Rule ({0}): {1}' } 'replaceRules' { 'Replace rules ({0}): {1}' } default { 'Remove rule ({0}): {1}' } }
                $lines.Add(((Get-ReqText $fmt) -f [string]$s.behavior, $rules) + $where)
                break
            }
            '^setMode$' { $lines.Add(((Get-ReqText 'Permission mode: {0}') -f [string]$s.mode) + $where); break }
            '^addDirectories$' { $lines.Add(((Get-ReqText 'Folder access: {0}') -f ((@($s.directories) | ForEach-Object { [string]$_ }) -join ', ')) + $where); break }
            '^removeDirectories$' { $lines.Add(((Get-ReqText 'Remove folder access: {0}') -f ((@($s.directories) | ForEach-Object { [string]$_ }) -join ', ')) + $where); break }
            default { try { $lines.Add(($s | ConvertTo-Json -Depth 6 -Compress -WarningAction SilentlyContinue)) } catch { } }
        }
    }
    return ($lines -join "`n")
}

# old -> new as '- ' / '+ ' lines.
function Format-ReqDiff([string]$Old, [string]$New) {
    $out = New-Object System.Collections.Generic.List[string]
    if ($Old) { foreach ($l in ($Old -split '\r?\n')) { $out.Add('- ' + $l) } }
    if ($New) { foreach ($l in ($New -split '\r?\n')) { $out.Add('+ ' + $l) } }
    return ($out -join "`n")
}

function New-ReqButton([string]$Text, [string]$Kind, [scriptblock]$OnClick, $Tag = $null) {
    $b = New-Object System.Windows.Controls.Border
    $b.CornerRadius = 8
    $b.Padding = '12,6'
    $b.Margin = '0,0,6,6'
    $b.Cursor = 'Hand'
    $b.BorderThickness = 1
    $fg = '#F5F5F7'
    switch ($Kind) {
        'primary' { $b.Background = NewBrush '#F5F5F7'; $b.BorderBrush = NewBrush '#F5F5F7'; $fg = '#111113' }
        'danger'  { $b.Background = NewBrush '#26FF453A'; $b.BorderBrush = NewBrush '#55FF453A'; $fg = '#FF6961' }
        'option'  { $b.Background = NewBrush '#14FFFFFF'; $b.BorderBrush = NewBrush '#26FFFFFF'; $b.HorizontalAlignment = 'Stretch'; $b.Margin = '0,0,0,6' }
        default   { $b.Background = NewBrush '#14FFFFFF'; $b.BorderBrush = NewBrush '#26FFFFFF' }
    }
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.FontSize = 12.5
    $tb.FontWeight = $(if ($Kind -eq 'primary') { 'SemiBold' } else { 'Normal' })
    $tb.Foreground = NewBrush $fg
    $tb.TextWrapping = 'Wrap'
    $b.Child = $tb
    $b.Tag = @{ Action = $OnClick; Data = $Tag }
    $b.Add_MouseEnter({ param($s, $e) $s.Opacity = 0.85 })
    $b.Add_MouseLeave({ param($s, $e) $s.Opacity = 1.0 })
    $b.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; try { & $s.Tag.Action $s } catch { try { Write-Log "AI requests: click failed - $($_.Exception.Message)" } catch { } } })
    return $b
}

# Card scrolling: a thin, rounded, see-through bar like the panel's, with no
# arrows. It overlays a small right gutter, brightens and widens on hover and
# is brightest while dragged. The wheel scrolls it without taking focus.
$script:ReqScrollTemplate = $null
function Get-ReqScrollTemplate {
    if ($script:ReqScrollTemplate) { return $script:ReqScrollTemplate }
    $xaml = @'
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                 xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
                 TargetType="ScrollViewer">
  <Grid>
    <ScrollContentPresenter x:Name="PART_ScrollContentPresenter" Margin="0,0,12,0"/>
    <ScrollBar x:Name="PART_VerticalScrollBar" Orientation="Vertical"
               HorizontalAlignment="Right" Width="8" Margin="0,1,0,1"
               Value="{TemplateBinding VerticalOffset}"
               Maximum="{TemplateBinding ScrollableHeight}"
               ViewportSize="{TemplateBinding ViewportHeight}"
               Visibility="{TemplateBinding ComputedVerticalScrollBarVisibility}">
      <ScrollBar.Template>
        <ControlTemplate TargetType="ScrollBar">
          <Border x:Name="Rail" Background="Transparent" CornerRadius="4">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.DecreaseRepeatButton>
                <RepeatButton Command="ScrollBar.PageUpCommand" Focusable="False">
                  <RepeatButton.Template>
                    <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
                  </RepeatButton.Template>
                </RepeatButton>
              </Track.DecreaseRepeatButton>
              <Track.Thumb>
                <Thumb MinHeight="22">
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb">
                      <Border Background="Transparent">
                        <Border x:Name="Bar" Width="4" CornerRadius="2" HorizontalAlignment="Center"
                                Background="#38FFFFFF"/>
                      </Border>
                      <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                          <Setter TargetName="Bar" Property="Width" Value="6"/>
                          <Setter TargetName="Bar" Property="CornerRadius" Value="3"/>
                          <Setter TargetName="Bar" Property="Background" Value="#70FFFFFF"/>
                        </Trigger>
                        <Trigger Property="IsDragging" Value="True">
                          <Setter TargetName="Bar" Property="Width" Value="6"/>
                          <Setter TargetName="Bar" Property="CornerRadius" Value="3"/>
                          <Setter TargetName="Bar" Property="Background" Value="#A8FFFFFF"/>
                        </Trigger>
                      </ControlTemplate.Triggers>
                    </ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
              <Track.IncreaseRepeatButton>
                <RepeatButton Command="ScrollBar.PageDownCommand" Focusable="False">
                  <RepeatButton.Template>
                    <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
                  </RepeatButton.Template>
                </RepeatButton>
              </Track.IncreaseRepeatButton>
            </Track>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="Rail" Property="Background" Value="#12FFFFFF"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </ScrollBar.Template>
    </ScrollBar>
  </Grid>
</ControlTemplate>
'@
    $script:ReqScrollTemplate = [System.Windows.Markup.XamlReader]::Parse($xaml)
    return $script:ReqScrollTemplate
}

function New-ReqScroll($Content, [double]$MaxHeight) {
    $sv = New-Object System.Windows.Controls.ScrollViewer
    $sv.MaxHeight = $MaxHeight
    $sv.VerticalScrollBarVisibility = 'Auto'
    $sv.HorizontalScrollBarVisibility = 'Disabled'
    $sv.Focusable = $false
    try { $sv.Template = Get-ReqScrollTemplate } catch {
        try { Write-Log "AI requests: scrollbar style not applied - $($_.Exception.Message)" } catch { }
    }
    $sv.Content = $Content
    return $sv
}

function New-ReqText([string]$Text, [double]$Size, [string]$Color, [string]$Weight = 'Normal', [bool]$Mono = $false) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.FontSize = $Size
    $tb.Foreground = NewBrush $Color
    $tb.FontWeight = $Weight
    $tb.TextWrapping = 'Wrap'
    if ($Mono) { $tb.FontFamily = New-Object System.Windows.Media.FontFamily('Cascadia Mono, Consolas') }
    return $tb
}

# ---------------------------------------------------------------------------
# The card grows out of the notch
# ---------------------------------------------------------------------------
# A card starts as the notch's own silhouette (the thin bar, or the pinned
# notch), springs open into the card with a little overshoot, then the
# content fades in. Answered, it folds back into the notch.
$script:ReqCardW   = 384.0     # card width
$script:ReqPadX    = 18.0      # content inset left/right
$script:ReqPadTop  = 14.0
$script:ReqPadBot  = 12.0
$script:ReqShadow  = 26.0      # room for the shadow around the card
$script:ReqWinH    = 720.0     # the window is fixed; only the shape moves
$script:ReqOpenMs  = 560.0
$script:ReqCloseMs = 380.0

# Where the notch is now and what it looks like (screen DIPs).
function Get-ReqNotchAnchor {
    $sp = $script:NotchSpec
    $screenW = [System.Windows.SystemParameters]::PrimaryScreenWidth
    $a = @{ CX = $screenW / 2.0; Top = 0.0; Docked = $true
             W = [double]$sp.EdgeW; H = [double]$sp.EdgeH; Rb = [double]$sp.EdgeRb; Sh = [double]$sp.EdgeSh }
    try {
        if ((Test-NotchShell) -and $script:window -and $script:window.IsVisible) {
            $v = $script:NV
            $a.CX = [double]$script:window.Left + [double]$script:NotchStage.CX
            $a.Top = [double]$script:window.Top
            $a.Docked = ([double]$v.dock -ge 0.5)
            if ($script:NotchState -eq 'EXPANDED' -or $script:NotchState -eq 'EXPANDING' -or $script:NotchState -eq 'COLLAPSING') {
                $n = Get-NotchPreset 'NOTCH'
                $a.W = [double]$n.w; $a.H = [double]$n.h; $a.Rb = [double]$n.rb; $a.Sh = [double]$n.sh
            } else {
                $a.W = [double]$v.w; $a.H = [double]$v.h; $a.Rb = [double]$v.rb; $a.Sh = [double]$v.sh
            }
        }
    } catch { }
    if ($a.W -lt 40.0) { $a.W = 40.0 }
    if ($a.H -lt 2.0) { $a.H = 2.0 }
    return $a
}

# The notch's silhouette code, centred on the card window instead.
function Get-ReqShape([double]$cx, [double]$w, [double]$h, [double]$rb, [double]$s, [double]$rt) {
    $old = $script:NotchStage.CX
    try {
        $script:NotchStage.CX = $cx
        return (Get-NotchGeometry $w $h $rb $s $rt)
    } finally {
        $script:NotchStage.CX = $old
    }
}

function Get-ReqEase([string]$Kind, [double]$p) {
    if ($p -le 0.0) { return 0.0 }
    if ($p -ge 1.0) { return 1.0 }
    switch ($Kind) {
        'pop' {
            # Ease-out with a small overshoot: the card "pops" out of the notch.
            $c1 = 1.35; $c3 = $c1 + 1.0; $q = $p - 1.0
            return 1.0 + $c3 * $q * $q * $q + $c1 * $q * $q
        }
        'out'   { $q = 1.0 - $p; return 1.0 - $q * $q * $q }
        'in'    { return $p * $p * $p }
        'inout' {
            if ($p -lt 0.5) { return 4.0 * $p * $p * $p }
            $q = -2.0 * $p + 2.0
            return 1.0 - ($q * $q * $q) / 2.0
        }
    }
    return $p
}

function Start-ReqRendering {
    if ($script:ReqRendering) { return }
    if (-not $script:ReqRenderHandler) {
        $script:ReqRenderHandler = [System.EventHandler]{ param($s, $e) Invoke-ReqFrame }
    }
    [System.Windows.Media.CompositionTarget]::add_Rendering($script:ReqRenderHandler)
    $script:ReqRendering = $true
}

function Stop-ReqRendering {
    if (-not $script:ReqRendering) { return }
    try { [System.Windows.Media.CompositionTarget]::remove_Rendering($script:ReqRenderHandler) } catch { }
    $script:ReqRendering = $false
}

# Same fill as the notch: black where it meets the bezel, fading into the
# chosen background colour, so card and notch read as one shape.
function New-ReqBackdropBrush {
    $hex = '#1A1A1E'
    try { $hex = Get-PanelBgHex } catch { }
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
    $black = [System.Windows.Media.Color]::FromRgb(0, 0, 0)
    $b = New-Object System.Windows.Media.LinearGradientBrush
    $b.MappingMode = [System.Windows.Media.BrushMappingMode]::Absolute
    $b.StartPoint = New-Object System.Windows.Point(0, 0)
    $b.EndPoint = New-Object System.Windows.Point(0, 420)
    [void]$b.GradientStops.Add((New-Object System.Windows.Media.GradientStop($black, 0.0)))
    [void]$b.GradientStops.Add((New-Object System.Windows.Media.GradientStop($black, 0.07)))
    [void]$b.GradientStops.Add((New-Object System.Windows.Media.GradientStop($c, 0.24)))
    [void]$b.GradientStops.Add((New-Object System.Windows.Media.GradientStop($c, 1.0)))
    $b.Freeze()
    return $b
}

# Open cards and cards on their way back into the notch.
function Get-ReqAllCards {
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($c in $script:ReqCards.Values) { $all.Add($c) }
    foreach ($c in $script:ReqClosing) { $all.Add($c) }
    return ,$all.ToArray()
}

function Set-ReqCardShape($Card, [double]$w, [double]$h, [double]$rb, [double]$s, [double]$rt) {
    $Card.Shell.Clip = Get-ReqShape $Card.CX $w $h $rb $s $rt
    $Card.Cur = @{ W = $w; H = $h; Rb = $rb; S = $s; Rt = $rt }
}

function Invoke-ReqFrame {
    try {
        $now = $script:ReqClock.Elapsed.TotalMilliseconds
        $busy = $false
        foreach ($c in (Get-ReqAllCards)) {
            $an = $c.Anim
            if (-not $an) { continue }
            $p = [math]::Min(1.0, [math]::Max(0.0, ($now - [double]$an.T0) / [double]$an.Dur))
            $f = $an.From; $t = $an.To
            if ($an.Kind -eq 'open') {
                # Height leads, the sides follow; the content comes in last.
                $ph = Get-ReqEase 'pop' ([math]::Min(1.0, $p / 0.78))
                $pw = Get-ReqEase 'pop' ([math]::Max(0.0, ($p - 0.06) / 0.86))
                $pr = Get-ReqEase 'out' ([math]::Min(1.0, $p / 0.7))
                $pc = Get-ReqEase 'out' ([math]::Max(0.0, ($p - 0.42) / 0.58))
                $c.Content.Opacity = $pc
                $c.ContentMove.Y = -10.0 * (1.0 - $pc)
                $c.ContentScale.ScaleX = 0.96 + 0.04 * $pc
                $c.ContentScale.ScaleY = 0.96 + 0.04 * $pc
            } else {
                # Content out first, then the shape folds back into the notch.
                $pc = Get-ReqEase 'out' ([math]::Min(1.0, $p / 0.32))
                $c.Content.Opacity = 1.0 - $pc
                $c.ContentMove.Y = -8.0 * $pc
                $q = [math]::Max(0.0, ($p - 0.14) / 0.86)
                $ph = Get-ReqEase 'inout' $q
                $pw = Get-ReqEase 'inout' ([math]::Max(0.0, ($q - 0.05) / 0.95))
                $pr = $ph
            }
            $w  = [double]$f.W  + ([double]$t.W  - [double]$f.W)  * $pw
            $h  = [double]$f.H  + ([double]$t.H  - [double]$f.H)  * $ph
            $rb = [double]$f.Rb + ([double]$t.Rb - [double]$f.Rb) * $pr
            $sh = [double]$f.S  + ([double]$t.S  - [double]$f.S)  * $pr
            $rt = [double]$f.Rt + ([double]$t.Rt - [double]$f.Rt) * $pr
            Set-ReqCardShape $c ([math]::Max(1.0, $w)) ([math]::Max(1.0, $h)) ([math]::Max(0.0, $rb)) ([math]::Max(0.0, $sh)) ([math]::Max(0.0, $rt))
            if ($p -ge 1.0) {
                $c.Anim = $null
                if ($an.Done) { try { & $an.Done $c } catch { } }
            } else { $busy = $true }
        }
        if (-not $busy) { Stop-ReqRendering }
    } catch {
        try { Write-Log "AI requests: animation error - $($_.Exception.Message)" } catch { }
        Stop-ReqRendering
        # Without the animation: open cards jump to their final shape, cards
        # on their way out close at once, so nothing is left half-drawn and
        # the queue keeps moving.
        foreach ($c in @($script:ReqCards.Values)) {
            try {
                if ($c.Anim -and $c.Anim.Kind -eq 'open') {
                    $t = $c.Anim.To
                    $c.Anim = $null
                    $c.Content.Opacity = 1.0; $c.ContentMove.Y = 0.0
                    $c.ContentScale.ScaleX = 1.0; $c.ContentScale.ScaleY = 1.0
                    Set-ReqCardShape $c ([double]$t.W) ([double]$t.H) ([double]$t.Rb) ([double]$t.S) ([double]$t.Rt)
                }
            } catch { }
        }
        foreach ($c in $script:ReqClosing.ToArray()) { try { $c.Window.Close() } catch { } }
        $script:ReqClosing.Clear()
    }
}

# Above the notch, which re-asserts its own always-on-top now and then.
function Set-RequestCardsOnTop {
    if (-not ([System.Management.Automation.PSTypeName]'AIUsageIslandNative').Type) { return }
    foreach ($c in (Get-ReqAllCards)) {
        try {
            $h = (New-Object System.Windows.Interop.WindowInteropHelper $c.Window).Handle
            if ($h -ne [IntPtr]::Zero) { [void][AIUsageIslandNative]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x0013) }
        } catch { }
    }
}

# A clear, bright three-note chime (assets\request.wav), loud enough to hear
# over music; played when a card comes out, and once more if it is still
# waiting after the time set in Settings (Remind again if unanswered).
$script:ReqSoundPlayer = $null
function Invoke-RequestSound {
    try {
        if (-not $script:ReqSoundPlayer) {
            $wav = Join-Path $script:AppDir 'assets\request.wav'
            if (Test-Path -LiteralPath $wav) {
                $script:ReqSoundPlayer = New-Object System.Media.SoundPlayer($wav)
                $script:ReqSoundPlayer.Load()
            }
        }
        if ($script:ReqSoundPlayer) { $script:ReqSoundPlayer.Play() }
        else { [System.Media.SystemSounds]::Exclamation.Play() }
    } catch {
        try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
    }
}

# How many times in a row this session has asked the same closing question.
$script:ReqStopRepeat = @{}
function Get-ReqStopRepeat($Req) {
    $key = [string]$Req.agent + '|' + [string]$Req.session
    $text = ([string]$Req.message).Trim()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = [Convert]::ToBase64String($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))) } finally { $sha.Dispose() }
    $prev = $script:ReqStopRepeat[$key]
    $n = if ($prev -and $prev.Hash -eq $hash) { [int]$prev.Count + 1 } else { 1 }
    $script:ReqStopRepeat[$key] = @{ Hash = $hash; Count = $n }
    return $n
}

# Notices (finished) use a softer two-note chime, assets\done.wav.
$script:ReqNoticePlayer = $null
function Invoke-NoticeSound {
    try {
        if (-not $script:ReqNoticePlayer) {
            $wav = Join-Path $script:AppDir 'assets\done.wav'
            if (Test-Path -LiteralPath $wav) {
                $script:ReqNoticePlayer = New-Object System.Media.SoundPlayer($wav)
                $script:ReqNoticePlayer.Load()
            }
        }
        if ($script:ReqNoticePlayer) { $script:ReqNoticePlayer.Play() }
        else { [System.Media.SystemSounds]::Asterisk.Play() }
    } catch { }
}

function Test-RequestCardShowing { return ($script:ReqCards.Count -gt 0 -or $script:ReqClosing.Count -gt 0) }

# The card window, its notch-shaped shell and the header row; registered
# under $Id but not shown yet (Open-ReqCard does that).
function New-ReqCardShell($Req, [string]$Id) {
    $anchor = Get-ReqNotchAnchor
    $sp = $script:NotchSpec
    $cardW = $script:ReqCardW
    $winW = $cardW + 2.0 * ([double]$sp.NotchSh + $script:ReqShadow)
    $cx = $winW / 2.0

    $win = New-Object System.Windows.Window
    $win.WindowStyle = 'None'
    $win.AllowsTransparency = $true
    $win.Background = [System.Windows.Media.Brushes]::Transparent
    $win.Topmost = $true
    $win.ShowInTaskbar = $false
    $win.ShowActivated = $false
    $win.ResizeMode = 'NoResize'
    $win.Width = $winW
    $win.Height = $script:ReqWinH
    $win.Left = $anchor.CX - $cx
    $win.Top = $anchor.Top

    # Shadow host (no background: clicks outside the shape go through) ->
    # shell (the card colour, clipped to the animated silhouette) -> content.
    $holder = New-Object System.Windows.Controls.Grid
    $shadow = New-Object System.Windows.Media.Effects.DropShadowEffect
    $shadow.BlurRadius = 22; $shadow.ShadowDepth = 3; $shadow.Opacity = 0.5; $shadow.Direction = 270
    $shadow.Color = [System.Windows.Media.Colors]::Black
    $holder.Effect = $shadow
    $shell = New-Object System.Windows.Controls.Grid
    $shell.Background = New-ReqBackdropBrush
    [void]$holder.Children.Add($shell)
    $win.Content = $holder

    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.Width = $cardW - 2.0 * $script:ReqPadX
    $stack.HorizontalAlignment = 'Center'
    $stack.VerticalAlignment = 'Top'
    $stack.Margin = New-Object System.Windows.Thickness(0, $script:ReqPadTop, 0, 0)
    $stack.MaxHeight = $script:ReqWinH - $script:ReqShadow - $script:ReqPadTop - $script:ReqPadBot - 20
    $stack.Opacity = 0.0
    $tg = New-Object System.Windows.Media.TransformGroup
    $scale = New-Object System.Windows.Media.ScaleTransform(0.96, 0.96)
    $move = New-Object System.Windows.Media.TranslateTransform(0, -10)
    $tg.Children.Add($scale); $tg.Children.Add($move)
    $stack.RenderTransform = $tg
    $stack.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.0)
    [void]$shell.Children.Add($stack)

    # Header: agent icon, "Claude Code · folder" / "Codex · folder", and "+2"
    # when more wait.
    $isCodex = ([string]$Req.agent -eq 'codex')
    $isCowork = ([string]$Req.agent -eq 'cowork')
    $agentName = if ($isCodex) { 'Codex' } elseif ($isCowork) { 'Claude Cowork' } else { 'Claude Code' }
    $agentIcon = if ($isCodex) { 'codex.png' } else { 'claude.png' }
    $head = New-Object System.Windows.Controls.DockPanel
    $head.Margin = '0,0,0,8'
    $badge = New-ReqText '' 11 '#8E8E93' 'SemiBold'
    [System.Windows.Controls.DockPanel]::SetDock($badge, 'Right')
    $badge.VerticalAlignment = 'Center'
    [void]$head.Children.Add($badge)
    try {
        $img = New-Object System.Windows.Controls.Image
        $img.Source = New-Object System.Windows.Media.Imaging.BitmapImage((New-Object System.Uri((Join-Path $script:AppDir ('icons\' + $agentIcon)))))
        $img.Width = 18; $img.Height = 18; $img.Margin = '0,0,8,0'
        [System.Windows.Controls.DockPanel]::SetDock($img, 'Left')
        [void]$head.Children.Add($img)
    } catch { }
    $folder = ''
    try { if ($Req.cwd) { $folder = ' · ' + (Split-Path -Leaf ([string]$Req.cwd)) } } catch { }
    $title = New-ReqText ($agentName + $folder) 12 '#A1A1A6' 'SemiBold'
    $title.VerticalAlignment = 'Center'
    $title.TextTrimming = 'CharacterEllipsis'
    $title.TextWrapping = 'NoWrap'
    [void]$head.Children.Add($title)
    [void]$stack.Children.Add($head)

    $card = @{
        Window = $win; Req = $Req; Picks = @{}; Shell = $shell; Content = $stack
        ContentMove = $move; ContentScale = $scale; Badge = $badge; CX = $cx
        Docked = $anchor.Docked; Anim = $null; Cur = $null
    }
    $card['Anchor'] = $anchor
    $card['IsCodex'] = $isCodex
    $card['CardW'] = $cardW
    $script:ReqCards[$Id] = $card
    return $card
}

# Shows a card built by New-ReqCardShell: first frame exactly the notch, then
# it springs open. $Sound: 'request' (needs an answer) or 'notice'.
function Open-ReqCard($card, [string]$Sound = 'request') {
    $win = $card.Window
    $stack = $card.Content
    $anchor = $card.Anchor
    $cardW = $card.CardW
    $sp = $script:NotchSpec
    # Never steal focus from the app you are typing in.
    $win.Add_SourceInitialized({
        param($s, $e)
        try {
            $h = (New-Object System.Windows.Interop.WindowInteropHelper $s).Handle
            if (([System.Management.Automation.PSTypeName]'AIUsageIslandNative').Type) {
                $ex = [AIUsageIslandNative]::GetWindowLong($h, -20)
                [void][AIUsageIslandNative]::SetWindowLong($h, -20, ($ex -bor 0x08000000 -bor 0x00000080))
            }
        } catch { }
    })

    # First frame: exactly the notch.
    $rt0 = if ($anchor.Docked) { 0.0 } else { [double]$sp.FloatRadius }
    $s0 = if ($anchor.Docked) { $anchor.Sh } else { 0.0 }
    Set-ReqCardShape $card $anchor.W $anchor.H $anchor.Rb $s0 $rt0
    $win.Show()
    Set-RequestCardsOnTop

    # Card size from the laid-out content, then open.
    $stack.UpdateLayout()
    $cardH = [math]::Ceiling($stack.ActualHeight + $script:ReqPadTop + $script:ReqPadBot)
    $card.Anim = @{
        Kind = 'open'; T0 = $script:ReqClock.Elapsed.TotalMilliseconds; Dur = $script:ReqOpenMs
        From = $card.Cur
        To = @{ W = $cardW; H = $cardH; Rb = 24.0; S = $(if ($anchor.Docked) { 10.0 } else { 0.0 }); Rt = $(if ($anchor.Docked) { 0.0 } else { 18.0 }) }
        Done = $null
    }
    Start-ReqRendering
    $card.Shown = [DateTime]::UtcNow
    if ($Sound -eq 'notice') { Invoke-NoticeSound } else { Invoke-RequestSound }
}

function Show-RequestCard($Req) {
    $id = [string]$Req.id
    if (-not (Test-RequestIdentity $Req $id) -or -not (Test-RequestLive $Req)) { return }
    $card = New-ReqCardShell $Req $id
    $stack = $card.Content
    $isCodex = $card.IsCodex
    $idCopy = $id

    if ($Req.event -eq 'Stop') {
        [void]$stack.Children.Add((New-ReqText (Get-ReqText $(if ($isCodex) { 'Codex is asking' } else { 'Claude is asking' })) 15 '#F5F5F7' 'SemiBold'))
        # Same question again in this session after a Continue: say so, so a
        # loop of "shall I go on?" is visible rather than answered by habit.
        $times = Get-ReqStopRepeat $Req
        if ($times -ge 2) {
            $rep = New-ReqText ((Get-ReqText 'Asked again: {0} times') -f $times) 11.5 '#FF9F0A' 'SemiBold'
            $rep.Margin = '0,4,0,0'
            [void]$stack.Children.Add($rep)
        }
        $msg = New-ReqText ([string]$Req.message) 12.5 '#D1D1D6'
        $msgScroll = New-ReqScroll $msg 160
        $msgScroll.Margin = '0,6,0,10'
        [void]$stack.Children.Add($msgScroll)
        $row = New-Object System.Windows.Controls.WrapPanel
        [void]$row.Children.Add((New-ReqButton (Get-ReqText 'Continue') 'primary' ([scriptblock]::Create("Send-RequestAnswer '$idCopy' @{ action = 'continue'; message = (Get-ReqText 'Yes, go ahead.') }"))))
        [void]$row.Children.Add((New-ReqButton (Get-ReqText 'I''ll reply myself') 'neutral' ([scriptblock]::Create("Invoke-ReqTerminal '$idCopy' 'ignore'"))))
        [void]$stack.Children.Add($row)
    } elseif (-not $isCodex -and $Req.tool -eq 'AskUserQuestion') {
        $questions = @($Req.input.questions)
        $qi = 0
        # Questions and options scroll; Submit / In terminal stay below them.
        $qPanel = New-Object System.Windows.Controls.StackPanel
        foreach ($q in $questions) {
            $qText = [string]$q.question
            $multi = [bool]$q.multiSelect
            $label = if ($q.header) { [string]$q.header + ' · ' } else { '' }
            [void]$qPanel.Children.Add((New-ReqText ($label + (Get-ReqText $(if ($multi) { 'Pick any' } else { 'Pick one' }))) 11 '#8E8E93'))
            $qt = New-ReqText $qText 14 '#F5F5F7' 'SemiBold'
            $qt.Margin = '0,2,0,8'
            [void]$qPanel.Children.Add($qt)
            foreach ($opt in @($q.options)) {
                $optLabel = [string]$opt.label
                $btn = New-ReqButton $optLabel 'option' {
                    param($s)
                    $d = $s.Tag.Data
                    $c = $script:ReqCards[$d.Id]
                    if (-not $c) { return }
                    $picked = @($c.Picks[$d.Question])
                    if ($d.Multi) {
                        if ($picked -contains $d.Label) { $picked = @($picked | Where-Object { $_ -ne $d.Label }) } else { $picked += $d.Label }
                    } else { $picked = @($d.Label) }
                    $c.Picks[$d.Question] = $picked
                    foreach ($sib in $s.Parent.Children) {
                        if ($sib.Tag -and $sib.Tag.Data -and $sib.Tag.Data.Question -eq $d.Question) {
                            $on = ($picked -contains $sib.Tag.Data.Label)
                            $sib.BorderBrush = NewBrush $(if ($on) { '#0A84FF' } else { '#26FFFFFF' })
                            $sib.Background = NewBrush $(if ($on) { '#260A84FF' } else { '#14FFFFFF' })
                        }
                    }
                    # A single single-choice question answers on the first click.
                    if (-not $d.Multi -and $d.Count -eq 1) { Submit-RequestAnswers $d.Id }
                } @{ Id = $idCopy; Question = $qText; Label = $optLabel; Multi = $multi; Count = $questions.Count }
                if ($opt.description) {
                    $optPanel = New-Object System.Windows.Controls.StackPanel
                    $t1 = $btn.Child
                    $btn.Child = $optPanel
                    [void]$optPanel.Children.Add($t1)
                    $t2 = New-ReqText ([string]$opt.description) 11 '#8E8E93'
                    $t2.Margin = '0,2,0,0'
                    [void]$optPanel.Children.Add($t2)
                }
                [void]$qPanel.Children.Add($btn)
            }
            $qi++
        }
        [void]$stack.Children.Add((New-ReqScroll $qPanel 380))
        $row = New-Object System.Windows.Controls.WrapPanel
        $row.Margin = '0,4,0,0'
        $needSubmit = ($questions.Count -gt 1) -or (@($questions | Where-Object { $_.multiSelect }).Count -gt 0)
        if ($needSubmit) {
            [void]$row.Children.Add((New-ReqButton (Get-ReqText 'Submit') 'primary' ([scriptblock]::Create("Submit-RequestAnswers '$idCopy'"))))
        }
        [void]$row.Children.Add((New-ReqButton (Get-ReqText 'In terminal') 'neutral' ([scriptblock]::Create("Invoke-ReqTerminal '$idCopy' 'terminal'"))))
        [void]$stack.Children.Add($row)
    } else {
        $sum = Get-RequestSummary $Req
        [void]$stack.Children.Add((New-ReqText $sum.Title 15 '#F5F5F7' 'SemiBold'))
        if ($sum.Detail) {
            $box = New-Object System.Windows.Controls.Border
            $box.CornerRadius = 8
            $box.Background = NewBrush '#0DFFFFFF'
            $box.Padding = '10,8'
            $box.Margin = '0,8,0,10'
            $dt = New-ReqText $sum.Detail 12 '#E5E5EA' 'Normal' $sum.Mono
            $box.Padding = '10,8,4,8'          # the scrollbar sits in the right inset
            $box.Child = New-ReqScroll $dt 150
            [void]$stack.Children.Add($box)
        }
        if ($sum.Note) {
            # The agent's own explanation, below the command and apart from it.
            $nt = New-ReqText $sum.Note 11.5 '#8E8E93'
            $ns = New-ReqScroll $nt 60
            $ns.Margin = '0,0,0,8'
            [void]$stack.Children.Add($ns)
        }
        $card.Truncated = [bool]$sum.Truncated
        if ($card.Truncated) {
            $warn = New-ReqText (Get-ReqText 'Too long to review here. Read it in the terminal to allow it.') 11.5 '#FF9F0A' 'SemiBold'
            $warn.Margin = '0,0,0,8'
            [void]$stack.Children.Add($warn)
        }
        if (-not $card.Truncated -and $sum.Grants) {
            # Exactly what "Always allow" saves (rules, mode, folders) and where.
            $gp = New-Object System.Windows.Controls.StackPanel
            [void]$gp.Children.Add((New-ReqText (Get-ReqText 'Always allow also grants:') 11 '#8E8E93'))
            [void]$gp.Children.Add((New-ReqText $sum.Grants 11.5 '#D1D1D6' 'Normal' $true))
            $gs = New-ReqScroll $gp 90
            $gs.Margin = '0,0,0,8'
            [void]$stack.Children.Add($gs)
        }
        $row = New-Object System.Windows.Controls.WrapPanel
        if (-not $card.Truncated) {
            [void]$row.Children.Add((New-ReqButton (Get-ReqText 'Allow') 'primary' ([scriptblock]::Create("Send-RequestAnswer '$idCopy' @{ action = 'allow' }"))))
        }
        if (-not $card.Truncated -and (Test-RequestAlwaysAllowed $Req)) {
            [void]$row.Children.Add((New-ReqButton (Get-ReqText 'Always allow') 'neutral' ([scriptblock]::Create("Send-RequestAnswer '$idCopy' @{ action = 'always' }"))))
        }
        [void]$row.Children.Add((New-ReqButton (Get-ReqText 'Deny') 'danger' ([scriptblock]::Create("Send-RequestAnswer '$idCopy' @{ action = 'deny' }"))))
        [void]$row.Children.Add((New-ReqButton (Get-ReqText 'In terminal') 'neutral' ([scriptblock]::Create("Invoke-ReqTerminal '$idCopy' 'terminal'"))))
        [void]$stack.Children.Add($row)
    }

    Open-ReqCard $card 'request'
}

# ---------------------------------------------------------------------------
# "Go to terminal": bring the agent's window (Windows Terminal, a console,
# VS Code, the Codex or Claude app) to the front.
# ---------------------------------------------------------------------------
function Initialize-ReqWindowNative {
    if (([System.Management.Automation.PSTypeName]'JayOSReqWindow').Type) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class JayOSReqWindow {
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    public static bool Usable(IntPtr h) { return h != IntPtr.Zero && IsWindowVisible(h); }
    public static bool Focus(IntPtr h) {
        if (h == IntPtr.Zero) return false;
        if (IsIconic(h)) ShowWindow(h, 9);          // SW_RESTORE
        // A tap of Alt lets a background app hand over the foreground.
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x12, 0, 2, UIntPtr.Zero);
        BringWindowToTop(h);
        return SetForegroundWindow(h);
    }
}
'@
}

# Processes above $StartPid, nearest first (only while it still runs).
function Get-ReqAncestorPids([int]$StartPid) {
    $chain = @()
    try {
        $parent = @{}
        foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId -ErrorAction Stop)) {
            $parent[[int]$p.ProcessId] = [int]$p.ParentProcessId
        }
        $cur = $StartPid
        for ($i = 0; $i -lt 12; $i++) {
            if (-not $parent.ContainsKey($cur)) { break }
            $cur = $parent[$cur]
            if ($cur -le 4 -or $chain -contains $cur) { break }
            $chain += $cur
        }
    } catch { }
    return ,$chain
}

# The first process in the chain that owns a visible window. When the chain
# has none (the agent runs in an app, or the request came from somewhere
# without a terminal), fall back to that agent's own app window, so every
# card offers the same "Show me" / "In terminal" button.
$script:ReqAgentApps = @{
    claude = @('Claude')
    cowork = @('Claude')
    codex  = @('Codex', 'ChatGPT')
}
function Find-ReqAgentWindow($Chain, [string]$Agent = '') {
    try { Initialize-ReqWindowNative } catch { return [IntPtr]::Zero }
    foreach ($id in @($Chain)) {
        if ([int]$id -eq $PID) { continue }
        try {
            $h = (Get-Process -Id ([int]$id) -ErrorAction Stop).MainWindowHandle
            if ([JayOSReqWindow]::Usable($h)) { return $h }
        } catch { }
    }
    $names = @($script:ReqAgentApps[$Agent.ToLowerInvariant()])
    $pathHint = if ($Agent -eq 'codex') { '*OpenAI.Codex*' } elseif ($Agent -eq 'claude' -or $Agent -eq 'cowork') { '*AnthropicClaude*' } else { $null }
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })) {
        $match = $names -contains $p.ProcessName
        if (-not $match -and $pathHint) { try { $match = ([string]$p.Path -like $pathHint) } catch { } }
        if ($match) { try { if ([JayOSReqWindow]::Usable($p.MainWindowHandle)) { return $p.MainWindowHandle } } catch { } }
    }
    return [IntPtr]::Zero
}

# No window to bring forward (the app is closed or sits in the tray): open
# the agent's app from the Start menu instead.
function Start-ReqAgentApp([string]$Agent) {
    $want = switch ($Agent) { 'codex' { '^(Codex|ChatGPT Codex)$' } { $_ -eq 'claude' -or $_ -eq 'cowork' } { '^Claude$' } default { $null } }
    if (-not $want) { return $false }
    try {
        $app = @(Get-StartApps -ErrorAction Stop | Where-Object { $_.Name -match $want }) | Select-Object -First 1
        if ($app) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('shell:AppsFolder\' + $app.AppID); return $true }
    } catch { try { Write-Log "AI requests: could not open the $Agent app - $($_.Exception.Message)" } catch { } }
    return $false
}

function Show-ReqAgentWindow([IntPtr]$Handle) {
    if ($Handle -eq [IntPtr]::Zero) { return $false }
    try { return [JayOSReqWindow]::Focus($Handle) } catch { return $false }
}

# "In terminal" / "I'll reply myself" on a request card: hand it back to the
# agent's own prompt and jump there. The window is looked up before
# answering, while the hook (and so the process chain) still exists.
function Invoke-ReqTerminal([string]$Id, [string]$Action = 'terminal') {
    $c = $script:ReqCards[$Id]
    $h = [IntPtr]::Zero
    if ($c) { $h = Find-ReqAgentWindow (Get-ReqAncestorPids ([int]$c.Req.pid)) ([string]$c.Req.agent) }
    Send-RequestAnswer $Id @{ action = $Action }
    [void](Show-ReqAgentWindow $h)
}

function Copy-ReqText([string]$Text, $Button) {
    try {
        [System.Windows.Clipboard]::SetText($Text)
        if ($Button -and $Button.Child -is [System.Windows.Controls.TextBlock]) { $Button.Child.Text = Get-ReqText 'Copied' }
    } catch { }
}

# ---------------------------------------------------------------------------
# Notices: nothing to answer - "finished", "waiting for you in the terminal".
# The hook writes <id>.note.json and returns at once; the card closes by itself.
# ---------------------------------------------------------------------------
$script:ReqNoticeKinds = @('done', 'ask', 'permission', 'idle', 'input')
$script:ReqRecentTerminal = @{}     # agent|session -> when "In terminal" was picked

function Test-ReqNoticeEnabled([string]$Kind) {
    $key = if ($Kind -eq 'done') { 'AiNotifyDone' } else { 'AiNotifyAttention' }
    try { if ($null -ne $script:Cfg[$key]) { return [bool]$script:Cfg[$key] } } catch { }
    return $true
}

function Test-NoticeValid($Note, [string]$ExpectedId) {
    if ($ExpectedId -cnotmatch '^[a-f0-9]{32}$' -or [string]$Note.id -cne $ExpectedId) { return $false }
    if ($script:ReqNoticeKinds -notcontains [string]$Note.kind) { return $false }
    try { return ((ConvertTo-ReqUtc $Note.expires) -gt [DateTime]::UtcNow) } catch { return $false }
}

# The last paragraph of a reply (code blocks left out), for the "done" card.
function Get-ReqNoticeExcerpt([string]$Text, [int]$Max = 700) {
    if (-not $Text) { return '' }
    $t = [regex]::Replace($Text, '(?s)```.*?```', ' ')
    $paras = @([regex]::Split($t.Trim(), '\r?\n\s*\r?\n') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $last = if ($paras.Count) { [string]$paras[-1] } else { $Text.Trim() }
    if ($last.Length -gt $Max) { $last = '…' + $last.Substring($last.Length - $Max) }
    return $last
}

function Show-NoticeCard($Note) {
    $id = [string]$Note.id
    $card = New-ReqCardShell $Note $id
    $card.IsNotice = $true
    $stack = $card.Content
    $who = if ($card.IsCodex) { 'Codex' } else { 'Claude' }
    $kind = [string]$Note.kind
    $spec = switch ($kind) {
        'done'       { @{ Title = '{0} finished';                Color = '#30D158'; Mark = '✓'; Hint = '';                         Secs = 8 } }
        'ask'        { @{ Title = '{0} is asking you something'; Color = '#FF9F0A'; Mark = '?'; Hint = 'Answer it in the terminal.'; Secs = 20 } }
        'permission' { @{ Title = '{0} needs your permission';   Color = '#FF9F0A'; Mark = '!'; Hint = 'Answer it in the terminal.'; Secs = 20 } }
        'idle'       { @{ Title = '{0} is waiting for you';      Color = '#0A84FF'; Mark = '…'; Hint = '';                         Secs = 12 } }
        default      { @{ Title = '{0} needs your input';        Color = '#FF9F0A'; Mark = '!'; Hint = 'Answer it in the terminal.'; Secs = 20 } }
    }
    # Claude in Cowork (the desktop app) asks in the app, not in a terminal;
    # its card stays out longer because the app waits for the answer.
    $inApp = ([string]$Note.agent -eq 'cowork')
    if ($inApp -and $spec.Hint) { $spec.Hint = 'Approve it in the Claude app.'; $spec.Secs = 60 }
    # A Cowork approval stays on screen until it has been answered.
    $card.Sticky = ($inApp -and $kind -eq 'permission' -and [bool]$Note.sticky)
    # Title row: a coloured mark, then the line.
    $row = New-Object System.Windows.Controls.DockPanel
    $dot = New-Object System.Windows.Controls.Border
    $dot.Width = 20; $dot.Height = 20; $dot.CornerRadius = 10; $dot.Margin = '0,0,8,0'
    $dot.Background = NewBrush $spec.Color
    $mk = New-ReqText $spec.Mark 12 '#FFFFFF' 'Bold'
    $mk.HorizontalAlignment = 'Center'; $mk.VerticalAlignment = 'Center'
    $dot.Child = $mk
    [System.Windows.Controls.DockPanel]::SetDock($dot, 'Left')
    [void]$row.Children.Add($dot)
    $tt = New-ReqText ((Get-ReqText $spec.Title) -f $who) 15 '#F5F5F7' 'SemiBold'
    $tt.VerticalAlignment = 'Center'
    [void]$row.Children.Add($tt)
    [void]$stack.Children.Add($row)

    $text = if ($kind -eq 'done' -or $kind -eq 'ask') { Get-ReqNoticeExcerpt ([string]$Note.message) } else { [string]$Note.message }
    if ($text) {
        $msg = New-ReqText $text 12.5 '#D1D1D6'
        $sc = New-ReqScroll $msg 140
        $sc.Margin = '0,8,0,4'
        [void]$stack.Children.Add($sc)
    }
    if ($card.Sticky) { $spec.Hint = 'Click below to jump to it, then press Allow there.' }
    if ($spec.Hint) {
        $h = New-ReqText (Get-ReqText $spec.Hint) 11.5 $spec.Color 'SemiBold'
        $h.Margin = '0,4,0,0'
        [void]$stack.Children.Add($h)
    }
    $btns = New-Object System.Windows.Controls.WrapPanel
    $btns.Margin = '0,8,0,0'
    # Jump to the agent's window (or open its app). Always offered, so every
    # card of a kind has the same buttons whichever agent it is from.
    $card.AgentWindow = Find-ReqAgentWindow @($Note.chain) ([string]$Note.agent)
    $go = if ($kind -eq 'done') { 'Show me' } elseif ($card.Sticky) { 'Approve in Claude' } elseif ($inApp) { 'Open Claude' } else { 'In terminal' }
    [void]$btns.Children.Add((New-ReqButton (Get-ReqText $go) 'primary' ([scriptblock]::Create("Open-NoticeTarget '$id'"))))
    if ($kind -eq 'done' -and [string]$Note.message) {
        [void]$btns.Children.Add((New-ReqButton (Get-ReqText 'Copy') 'neutral' {
            param($b)
            $c = $script:ReqCards[[string]$b.Tag.Data]
            if ($c) { Copy-ReqText ([string]$c.Req.message) $b; $c.AutoCloseAt = [DateTime]::UtcNow.AddSeconds(4) }
        } $id))
    }
    if (-not $card.Sticky) {
        [void]$btns.Children.Add((New-ReqButton (Get-ReqText 'OK') 'neutral' ([scriptblock]::Create("Close-NoticeCard '$id'"))))
    }
    [void]$stack.Children.Add($btns)

    $card.AutoCloseAt = [DateTime]::UtcNow.AddSeconds([int]$spec.Secs)
    Open-ReqCard $card $(if ($kind -eq 'done' -or $kind -eq 'idle') { 'notice' } else { 'request' })
}

function Open-NoticeTarget([string]$Id) {
    $c = $script:ReqCards[$Id]
    $h = [IntPtr]::Zero
    $agent = ''
    if ($c) {
        $agent = [string]$c.Req.agent
        $h = $c.AgentWindow
        # The window may have opened since the card came out.
        if ($h -eq [IntPtr]::Zero) { $h = Find-ReqAgentWindow @($c.Req.chain) $agent }
    }
    # Clicking the button is the answer to the card: it goes back into the
    # notch (a Cowork approval card too - the person has gone to the app).
    Close-NoticeCard $Id
    if (-not (Show-ReqAgentWindow $h)) { [void](Start-ReqAgentApp $agent) }
}

function Close-NoticeCard([string]$Id) {
    if ($Id -cnotmatch '^[a-f0-9]{32}$') { return }
    try { Remove-Item -LiteralPath (Join-Path $script:ReqDir ($Id + '.note.json')) -Force -ErrorAction SilentlyContinue } catch { }
    Close-RequestCard $Id
}

# Notices waiting to be shown (oldest first). Expired, switched-off or
# redundant ones are deleted here.
function Get-ReqWaitingNotices([System.Collections.Generic.List[object]]$Requests) {
    $out = New-Object System.Collections.Generic.List[object]
    $files = @(Get-ChildItem -LiteralPath $script:ReqDir -Filter '*.note.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc)
    foreach ($f in $files) {
        $id = $f.Name.Substring(0, $f.Name.Length - '.note.json'.Length)
        if ($script:ReqCards.Contains($id)) { continue }
        $note = Get-ReqParsed $f
        $drop = (-not $note) -or (-not (Test-NoticeValid $note $id)) -or (-not (Test-ReqNoticeEnabled ([string]$note.kind)))
        if (-not $drop -and [string]$note.kind -eq 'permission') {
            # A card for this session is up or waiting, or "In terminal" was
            # just picked there: the notice would only repeat it.
            $key = [string]$note.agent + '|' + [string]$note.session
            foreach ($c in @($script:ReqCards.Values)) { if (-not $c.IsNotice -and ([string]$c.Req.agent + '|' + [string]$c.Req.session) -eq $key) { $drop = $true } }
            foreach ($r in $Requests) { if (([string]$r.agent + '|' + [string]$r.session) -eq $key) { $drop = $true } }
            $at = $script:ReqRecentTerminal[$key]
            if ($at -and ([DateTime]::UtcNow - $at).TotalSeconds -lt 20) { $drop = $true }
        }
        if ($drop) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue; continue }
        $out.Add($note)
    }
    return ,$out
}

function Submit-RequestAnswers([string]$Id) {
    $c = $script:ReqCards[$Id]
    if (-not $c) { return }
    $answers = @{}
    foreach ($q in @($c.Req.input.questions)) {
        $picked = @($c.Picks[[string]$q.question] | Where-Object { $_ })
        if ($picked.Count -eq 0) { return }      # every question needs an answer first
        $answers[[string]$q.question] = ($picked -join ', ')
    }
    Send-RequestAnswer $Id @{ action = 'answers'; answers = $answers }
}

# Folds the card back into the notch, then closes it.
function Close-RequestCard([string]$Id, [switch]$Instant) {
    $c = $script:ReqCards[$Id]
    if (-not $c) { return }
    $script:ReqCards.Remove($Id)
    if ($Instant -or -not $c.Cur) {
        try { $c.Window.Close() } catch { }
        return
    }
    $c.Content.IsHitTestVisible = $false
    $anchor = Get-ReqNotchAnchor
    $c.Anim = @{
        Kind = 'close'; T0 = $script:ReqClock.Elapsed.TotalMilliseconds; Dur = $script:ReqCloseMs
        From = $c.Cur
        To = @{ W = $anchor.W; H = $anchor.H; Rb = $anchor.Rb
                S = $(if ($c.Docked) { $anchor.Sh } else { 0.0 }); Rt = $(if ($c.Docked) { 0.0 } else { [double]$script:NotchSpec.FloatRadius }) }
        Done = {
            param($card)
            try { $card.Window.Close() } catch { }
            [void]$script:ReqClosing.Remove($card)
        }
    }
    $c.ClosingSince = [DateTime]::UtcNow
    $script:ReqClosing.Add($c)
    Start-ReqRendering
}
