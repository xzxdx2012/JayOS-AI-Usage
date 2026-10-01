# ProviderLogin.ps1 - tray-spawned CLI login (claude / codex / grok)
#
# Resolve via Get-Command (grok also checks ~/.grok/bin/grok.exe). Never mutate PATH. Never write auth.json or tokens.
# Spawn a visible console; OAuth finishes in the CLI's browser/device prompt.

function Resolve-ProviderLoginCli {
    param([Parameter(Mandatory = $true)][string]$CliName)

    $cmd = Get-Command -Name $CliName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd -and $CliName -match '^(?i)grok$') {
        $wellKnown = Join-Path $HOME '.grok\bin\grok.exe'
        if (Test-Path -LiteralPath $wellKnown) {
            return [pscustomobject]@{ Name = 'grok'; Path = $wellKnown; CommandType = 'Application' }
        }
    }
    if (-not $cmd) { return $null }

    if ([string]$cmd.CommandType -eq 'Alias' -and $cmd.ResolvedCommand) {
        $cmd = $cmd.ResolvedCommand
    }

    $path = $null
    if ($cmd.PSObject.Properties['Source'] -and $cmd.Source) {
        $path = [string]$cmd.Source
    } elseif ($cmd.PSObject.Properties['Path'] -and $cmd.Path) {
        $path = [string]$cmd.Path
    }

    if (-not $path) { return $null }

    [pscustomobject]@{
        Name        = $CliName
        Path        = $path
        CommandType = [string]$cmd.CommandType
    }
}

function Get-ProviderLoginMenuCaption {
    param(
        [Parameter(Mandatory = $true)][string]$CliName,
        $Resolved
    )

    if ($Resolved) { return "Log in $CliName" }
    return "$CliName not installed"
}

function Get-ProviderLoginRefreshKinds {
    param([Parameter(Mandatory = $true)][string]$Provider)

    switch -Regex ($Provider) {
        '^(?i)claude$' { @('ClaudeUsage', 'ClaudeStats') }
        '^(?i)codex$'  { @('CodexStats') }
        '^(?i)grok$'   { @('GrokUsage') }
        default        { @() }
    }
}

function Get-ProviderLoginArguments([string]$CliName) {
    # Claude Code 2.x signs in with `claude auth login` (opens the browser);
    # a bare `claude login` would start a chat with "login" as the prompt.
    switch -Regex ($CliName) {
        '^(?i)claude$' { return @('auth', 'login') }
        default        { return @('login') }
    }
}

# npm installs a claude.ps1 / claude.cmd shim next to the real claude.exe.
# Prefer the native exe; a .ps1 must run through PowerShell, since opening it
# directly hands it to the .ps1 file association (Notepad).
function Resolve-ProviderLoginExecutable($Resolved) {
    $path = [string]$Resolved.Path
    if ($path -match '(?i)\.ps1$') {
        $dir = Split-Path -Parent $path
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($path)
        foreach ($candidate in @(
                (Join-Path $dir ('node_modules\@anthropic-ai\claude-code\bin\' + $stem + '.exe')),
                (Join-Path $dir ($stem + '.exe')),
                (Join-Path $dir ($stem + '.cmd')))) {
            if ($stem -ne 'claude' -and $candidate -match 'claude-code') { continue }
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }
    return $path
}

function Start-ProviderLoginProcess {
    param($Resolved)

    if (-not $Resolved -or -not $Resolved.Path) { return $null }

    $loginArgs = @(Get-ProviderLoginArguments ([string]$Resolved.Name))
    $exe = Resolve-ProviderLoginExecutable $Resolved
    $quoted = ($loginArgs | ForEach-Object { $_ }) -join ' '
    $title = "Sign in - $($Resolved.Name)"

    # Visible console so the CLI can show its prompt; the CLI opens the sign-in
    # page in the browser. The click thread must not wait.
    $shell = (Get-Process -Id $PID).Path
    if (-not $shell -or -not (Test-Path -LiteralPath $shell)) { $shell = 'powershell.exe' }
    $cmd = "`$Host.UI.RawUI.WindowTitle = '$title'; & '$($exe -replace "'", "''")' $quoted; " +
        "if (`$LASTEXITCODE -ne 0) { Write-Host ''; Read-Host 'Sign-in did not finish. Press Enter to close' }"
    # -EncodedCommand: no quoting surprises from Start-Process's argument join.
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
    Start-Process -FilePath $shell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -PassThru
}
