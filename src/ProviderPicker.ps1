# ProviderPicker.ps1 - first-run / tray provider chooser (MS-PRODUCTIZE-OVERLAY)
# Calm WinForms checklist. Persists via Cfg.Sections + Save-UnifiedState.

function Get-DefaultUnifiedSections {
    # Demo / stranger path: Claude off until chosen. Codex/Cursor/Grok on.
    @{
        claude = $false
        codex  = $true
        cursor = $true
        grok   = $true
    }
}

function Test-UnifiedFirstRun {
    if (-not $script:StatePath) { return $false }
    return -not (Test-Path -LiteralPath $script:StatePath)
}

function Apply-ProviderSections {
    param($Sections)

    if (-not $script:Cfg) { $script:Cfg = @{} }
    if (Get-Command Initialize-UnifiedCfg -ErrorAction SilentlyContinue) {
        Initialize-UnifiedCfg
    }
    if (Get-Command ConvertTo-UnifiedSectionsMap -ErrorAction SilentlyContinue) {
        $script:Cfg['Sections'] = ConvertTo-UnifiedSectionsMap $Sections
    } else {
        $script:Cfg['Sections'] = $Sections
    }

    if (Get-Command Save-UnifiedState -ErrorAction SilentlyContinue) {
        Save-UnifiedState
    }
    if (Get-Command Apply-UnifiedSettings -ErrorAction SilentlyContinue) {
        Apply-UnifiedSettings
    }
    if (Get-Command Sync-SectionMenuItems -ErrorAction SilentlyContinue) {
        Sync-SectionMenuItems
    }
    if (Get-Command Update-AllSections -ErrorAction SilentlyContinue) {
        Update-AllSections
    }
    if (Get-Command Resize-ToContent -ErrorAction SilentlyContinue) {
        Resize-ToContent
    }
}

function Show-ProviderPickerDialog {
    param($Initial = $null)

    $map = if (Get-Command ConvertTo-UnifiedSectionsMap -ErrorAction SilentlyContinue) {
        ConvertTo-UnifiedSectionsMap $(if ($null -ne $Initial) { $Initial } else { Get-DefaultUnifiedSections })
    } else {
        Get-DefaultUnifiedSections
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'AI Usage Overlay'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $true
    $form.ClientSize = New-Object System.Drawing.Size(340, 280)
    $form.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
    $form.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Which providers do you use?'
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(20, 16)
    $title.ForeColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
    $title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Hidden tiles stay quiet. Change anytime from the tray > Providers.'
    $hint.AutoSize = $false
    $hint.Size = New-Object System.Drawing.Size(300, 36)
    $hint.Location = New-Object System.Drawing.Point(20, 44)
    $hint.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)

    $checks = @{}
    $y = 92
    foreach ($pair in @(
        @('codex', 'Codex'),
        @('cursor', 'Cursor'),
        @('grok', 'Grok'),
        @('claude', 'Claude')
    )) {
        $key = $pair[0]
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = $pair[1]
        $cb.Checked = [bool]$map[$key]
        $cb.AutoSize = $true
        $cb.Location = New-Object System.Drawing.Point(28, $y)
        $cb.ForeColor = $form.ForeColor
        $cb.BackColor = $form.BackColor
        $checks[$key] = $cb
        [void]$form.Controls.Add($cb)
        $y += 28
    }

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Continue'
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Location = New-Object System.Drawing.Point(110, 220)
    $ok.Size = New-Object System.Drawing.Size(120, 30)
    $ok.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $ok.BackColor = [System.Drawing.Color]::FromArgb(30, 58, 95)
    $ok.ForeColor = $form.ForeColor

    [void]$form.Controls.Add($title)
    [void]$form.Controls.Add($hint)
    [void]$form.Controls.Add($ok)
    $form.AcceptButton = $ok

    $result = $form.ShowDialog()
    $form.Dispose()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

    $out = @{}
    foreach ($key in @('claude', 'codex', 'cursor', 'grok')) {
        $out[$key] = [bool]$checks[$key].Checked
    }
    # Keep at least one tile so the HUD isn't an empty shell.
    $any = $false
    foreach ($v in $out.Values) { if ($v) { $any = $true; break } }
    if (-not $any) { $out['cursor'] = $true }
    return $out
}

function Invoke-ProviderPickerFromTray {
    $initial = if ($script:Cfg -and $script:Cfg.Sections) { $script:Cfg.Sections } else { Get-DefaultUnifiedSections }
    $choice = Show-ProviderPickerDialog -Initial $initial
    if ($null -eq $choice) { return }
    Apply-ProviderSections $choice
}

function Invoke-FirstRunProviderPickerIfNeeded {
    if (-not (Test-UnifiedFirstRun)) { return }
    $choice = Show-ProviderPickerDialog -Initial (Get-DefaultUnifiedSections)
    if ($null -eq $choice) {
        $choice = Get-DefaultUnifiedSections
    }
    Apply-ProviderSections $choice
}
