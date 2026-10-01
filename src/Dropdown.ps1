# Dropdown.ps1 - Quake-style drop-down view: a translucent panel that slides in
# from the top edge of a chosen monitor on a global hotkey, and slides back out.
#
# This is an alternate presentation of the same window, not a second window. The
# pinned view keeps its saved Left/Top; entering dropdown mode parks the window
# off the top edge of the target monitor and drives Window.Top with the same
# DoubleAnimation/CubicEase pattern the panel already uses for its height.
#
# The hotkey needs a real message pump: a WPF HwndSourceHook cannot be built from
# a PowerShell scriptblock because its signature takes a by-ref bool. A tiny
# NativeWindow subclass owns the hotkey registration and raises a plain event
# instead. Its handle is created on the WPF UI thread, so the event fires there
# and can touch the window directly.

function Get-DropdownReferencedAssemblies {
    $refs = [System.Collections.Generic.List[string]]::new()

    foreach ($type in @([System.Drawing.Color], [System.Windows.Forms.Form],
                        # .NET 9 type-forwarded System.Windows.Forms.Message into
                        # System.Windows.Forms.Primitives. WndProc(ref Message m)
                        # then fails to compile with CS1069 unless the assembly that
                        # actually holds Message is referenced too. Resolve it from
                        # the type so this keeps working wherever it gets forwarded.
                        [System.Windows.Forms.Message])) {
        $location = $null
        try { $location = $type.Assembly.Location } catch { }
        if ($location -and -not $refs.Contains($location)) { [void]$refs.Add($location) }
    }

    return @($refs)
}

if (-not ('AIUsageGlobalHotkey' -as [type])) {
    Add-Type -ReferencedAssemblies (Get-DropdownReferencedAssemblies) -TypeDefinition @'
using System;
using System.Collections;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class AIUsageHotkeyEventArgs : EventArgs
{
    private readonly int _id;
    public AIUsageHotkeyEventArgs(int id) { _id = id; }
    public int Id { get { return _id; } }
}

public class AIUsageGlobalHotkey : NativeWindow, IDisposable
{
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private const int WM_HOTKEY = 0x0312;
    // Ids currently held by this window. Several bindings share one window, and
    // WM_HOTKEY's wParam says which of them fired. ArrayList, not List<int>:
    // pwsh's Add-Type does not reference System.Collections, where List<T> lives.
    private readonly ArrayList _registered = new ArrayList();

    public event EventHandler<AIUsageHotkeyEventArgs> Pressed;

    public AIUsageGlobalHotkey() { CreateHandle(new CreateParams()); }

    public bool Register(int id, uint modifiers, uint vk)
    {
        Unregister(id);
        bool ok = RegisterHotKey(this.Handle, id, modifiers, vk);
        if (ok) { _registered.Add(id); }
        return ok;
    }

    public void Unregister(int id)
    {
        if (!_registered.Contains(id)) { return; }
        UnregisterHotKey(this.Handle, id);
        _registered.Remove(id);
    }

    public void UnregisterAll()
    {
        foreach (object id in _registered.ToArray()) { UnregisterHotKey(this.Handle, (int)id); }
        _registered.Clear();
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY)
        {
            int id = (int)m.WParam;
            if (_registered.Contains(id))
            {
                EventHandler<AIUsageHotkeyEventArgs> h = Pressed;
                if (h != null) h(this, new AIUsageHotkeyEventArgs(id));
            }
        }
        base.WndProc(ref m);
    }

    public void Dispose()
    {
        UnregisterAll();
        if (this.Handle != IntPtr.Zero) { this.DestroyHandle(); }
    }
}
'@ -ErrorAction Stop
}

$script:HotkeyOwner     = $null    # AIUsageGlobalHotkey instance, shared by every binding
$script:DropdownShown   = $false
$script:DropdownAnimating = $false
$script:DropdownAnimTarget = 0.0   # slide target/mode for the Completed handler,
$script:DropdownAnimHide   = $false # kept in script scope (see Move-DropdownTo)
$script:PinnedLeft      = $null    # saved so switching back restores the pinned spot
$script:PinnedTop       = $null

# MOD_* from winuser.h; NOREPEAT stops auto-repeat while the key is held.
$script:HotkeyModifiers = @{ ALT = 1; CONTROL = 2; CTRL = 2; SHIFT = 4; WIN = 8 }
$script:HotkeyNoRepeat  = 0x4000

# Virtual-key codes for the combos we let the menu offer.
$script:HotkeyVirtualKeys = @{
    'F1'=0x70; 'F2'=0x71; 'F3'=0x72; 'F4'=0x73; 'F5'=0x74; 'F6'=0x75
    'F7'=0x76; 'F8'=0x77; 'F9'=0x78; 'F10'=0x79; 'F11'=0x7A; 'F12'=0x7B
    '`'=0xC0; 'TILDE'=0xC0; 'BACKTICK'=0xC0; 'SPACE'=0x20
    'A'=0x41; 'U'=0x55; 'Q'=0x51
}

# 'Shift+F11' -> @{ Mods = 4; Vk = 0x7A }
function ConvertTo-HotkeySpec([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $mods = 0
    $vk   = 0
    foreach ($part in ($Text -split '\+')) {
        $p = $part.Trim().ToUpperInvariant()
        if ($p.Length -eq 0) { continue }
        if ($script:HotkeyModifiers.ContainsKey($p)) {
            $mods = $mods -bor $script:HotkeyModifiers[$p]
        } elseif ($script:HotkeyVirtualKeys.ContainsKey($p)) {
            $vk = $script:HotkeyVirtualKeys[$p]
        } else {
            return $null
        }
    }
    if ($vk -eq 0) { return $null }
    return @{ Mods = ($mods -bor $script:HotkeyNoRepeat); Vk = $vk }
}

# Bindable actions. Each owns a WM_HOTKEY id (arbitrary, but stable and unique
# within the owner window), the config key holding its combo, and what it runs.
# 0x4149 ('AI') is the id the drop-down has always used. Label and Fallback make
# up the log lines when a combo cannot be registered.
$script:HotkeyActions = [ordered]@{
    Dropdown = @{
        Id               = 0x4149
        ConfigKey        = 'DropdownHotkey'
        Label            = 'Dropdown'
        Fallback         = 'dropdown will only open from the tray'
        DropdownModeOnly = $true
        Action           = { Toggle-Dropdown }
    }
    Toggle = @{
        Id               = 0x414A
        ConfigKey        = 'ToggleOverlayHotkey'
        Label            = 'Show/hide overlay'
        Fallback         = 'the overlay will only show/hide from the tray'
        DropdownModeOnly = $false
        Action           = { Toggle-Window }
    }
    Refresh = @{
        Id               = 0x414B
        ConfigKey        = 'RefreshHotkey'
        Label            = 'Refresh now'
        Fallback         = 'refresh will only run from the tray'
        DropdownModeOnly = $false
        Action           = { Invoke-ManualRefresh }
    }
}

function Get-HotkeyActionNames {
    return @($script:HotkeyActions.Keys)
}

function Get-HotkeyAction([string]$Name) {
    if ([string]::IsNullOrEmpty($Name) -or -not $script:HotkeyActions.Contains($Name)) { return $null }
    return $script:HotkeyActions[$Name]
}

# Runs from a WndProc on the UI thread; an escaping exception takes the whole
# dispatcher down, so a failing action is logged instead.
function Invoke-OverlayHotkey([int]$Id) {
    foreach ($name in @($script:HotkeyActions.Keys)) {
        $entry = $script:HotkeyActions[$name]
        if ([int]$entry.Id -ne $Id) { continue }
        try {
            & $entry.Action
        } catch {
            Write-Log ("{0} hotkey failed: {1}`n{2}" -f $entry.Label, $_.Exception.Message, $_.ScriptStackTrace)
        }
        return
    }
}

function Get-OverlayHotkeyOwner {
    if (-not $script:HotkeyOwner) {
        $script:HotkeyOwner = New-Object AIUsageGlobalHotkey
        $script:HotkeyOwner.add_Pressed({ param($s, $e) Invoke-OverlayHotkey ([int]$e.Id) })
    }
    return $script:HotkeyOwner
}

function Register-OverlayHotkey([string]$Name) {
    $entry = Get-HotkeyAction $Name
    if (-not $entry) { return $false }
    $combo = [string]$script:Cfg[$entry.ConfigKey]
    try {
        $owner = Get-OverlayHotkeyOwner
        # Drop the previous claim first so re-binding, or clearing back to
        # unbound, hands the old combo back to Windows.
        $owner.Unregister([int]$entry.Id)
        if ([string]::IsNullOrWhiteSpace($combo)) { return $false }
        $spec = ConvertTo-HotkeySpec $combo
        if (-not $spec) {
            Write-Log "$($entry.Label) hotkey '$combo' is not a combo I recognise; $($entry.Fallback)."
            return $false
        }
        $ok = $owner.Register([int]$entry.Id, [uint32]$spec.Mods, [uint32]$spec.Vk)
        if (-not $ok) {
            # Another process already owns this combo - Windows gives no detail beyond the failure.
            Write-Log "$($entry.Label) hotkey '$combo' is already taken by another app; pick a different one."
        }
        return $ok
    } catch {
        Write-Log "Register-OverlayHotkey '$Name' failed: $($_.Exception.Message)"
        return $false
    }
}

# Every binding that applies to the current view. The drop-down combo only
# means something in quake mode; the others work in either view.
function Register-OverlayHotkeys {
    foreach ($name in @($script:HotkeyActions.Keys)) {
        if ($script:HotkeyActions[$name].DropdownModeOnly -and -not (Test-DropdownMode)) { continue }
        [void](Register-OverlayHotkey $name)
    }
}

function Unregister-OverlayHotkey([string]$Name) {
    $entry = Get-HotkeyAction $Name
    if (-not $entry -or -not $script:HotkeyOwner) { return }
    try { $script:HotkeyOwner.Unregister([int]$entry.Id) } catch { }
}

function Set-OverlayHotkey([string]$Name, [string]$Combo) {
    $entry = Get-HotkeyAction $Name
    if (-not $entry) { return }
    $script:Cfg[$entry.ConfigKey] = $Combo
    if ($entry.DropdownModeOnly -and -not (Test-DropdownMode)) {
        Unregister-OverlayHotkey $Name
        return
    }
    [void](Register-OverlayHotkey $Name)
}

function Register-DropdownHotkey {
    return Register-OverlayHotkey 'Dropdown'
}

function Unregister-DropdownHotkey {
    Unregister-OverlayHotkey 'Dropdown'
}

function Dispose-DropdownHotkey {
    if ($script:HotkeyOwner) {
        try { $script:HotkeyOwner.Dispose() } catch { }
        $script:HotkeyOwner = $null
    }
}

# ---------------------------------------------------------------------------
# Monitor choice. Stored as a DeviceName so it survives restarts, with 'Active'
# meaning "whichever monitor the mouse is on right now". A remembered monitor
# that has since been unplugged falls back to primary rather than throwing.
# ---------------------------------------------------------------------------
function Get-DropdownScreens {
    return @([System.Windows.Forms.Screen]::AllScreens)
}

function Resolve-DropdownScreen {
    $want = [string]$script:Cfg['DropdownMonitor']
    if ([string]::IsNullOrWhiteSpace($want) -or $want -eq 'Active') {
        return [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Control]::MousePosition)
    }
    if ($want -eq 'Primary') { return [System.Windows.Forms.Screen]::PrimaryScreen }
    $match = Get-DropdownScreens | Where-Object { $_.DeviceName -eq $want } | Select-Object -First 1
    if ($match) { return $match }
    return [System.Windows.Forms.Screen]::PrimaryScreen
}

# Device pixels -> WPF device-independent units. Uses this window's compositor
# scale, which is correct for uniform DPI; a mixed-DPI setup would need the
# target monitor's own scale, which WPF does not expose per-screen here.
function Get-DropdownScaleFactor {
    try {
        $src = [System.Windows.Interop.HwndSource]::FromVisual($script:window)
        if ($src -and $src.CompositionTarget) {
            $m = $src.CompositionTarget.TransformFromDevice
            return @{ X = [double]$m.M11; Y = [double]$m.M22 }
        }
    } catch { }
    return @{ X = 1.0; Y = 1.0 }
}

function Get-DropdownGeometry {
    $screen = Resolve-DropdownScreen
    $scale  = Get-DropdownScaleFactor
    $wa     = $screen.WorkingArea

    $w = [double]$script:window.Width
    $h = [double]$script:window.Height
    if ([double]::IsNaN($w) -or $w -le 0) { $w = [double]$script:window.ActualWidth }
    if ([double]::IsNaN($h) -or $h -le 0) { $h = [double]$script:window.ActualHeight }

    $waLeft   = [double]$wa.Left  * $scale.X
    $waTop    = [double]$wa.Top   * $scale.Y
    $waWidth  = [double]$wa.Width * $scale.X

    # The quake strip spans the monitor like a real drop-down console; only the
    # legacy narrow panel gets centred.
    $left = if ($w -ge ($waWidth - 2)) { $waLeft } else { $waLeft + [math]::Max(0, ($waWidth - $w) / 2.0) }

    return @{
        Left      = $left
        Width     = $waWidth
        ShownTop  = $waTop
        HiddenTop = $waTop - $h - 8      # a few px extra so the shadow clears too
        Height    = $h
    }
}

# ---------------------------------------------------------------------------
# Slide. Window.Top is animated (not a content transform) so the window never
# covers screen area it is not visibly filling - a transparent WPF background
# still swallows clicks.
# ---------------------------------------------------------------------------
function Move-DropdownTo([double]$Target, [bool]$HideWhenDone) {
    $topProp = [System.Windows.Window]::TopProperty
    $script:window.BeginAnimation($topProp, $null)

    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.From     = [double]$script:window.Top
    $anim.To       = $Target
    $anim.Duration = [System.Windows.Duration][TimeSpan]::FromMilliseconds(190)
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = if ($HideWhenDone) {
        [System.Windows.Media.Animation.EasingMode]::EaseIn
    } else {
        [System.Windows.Media.Animation.EasingMode]::EaseOut
    }
    $anim.EasingFunction = $ease

    # Deliberately NOT .GetNewClosure(): inside a closure, $script: resolves to the
    # closure's own scope, so $script:window reads as $null (killing the dispatcher)
    # and writes to $script:DropdownAnimating would never reach the real variable,
    # wedging the toggle after one use. A plain scriptblock keeps the defining
    # session state, so the per-animation values are parked in script scope instead.
    $script:DropdownAnimTarget = $Target
    $script:DropdownAnimHide   = $HideWhenDone
    $script:DropdownAnimating  = $true
    $anim.Add_Completed({
        try {
            # Clear the animation hold before assigning Top, or the value sticks.
            $script:window.BeginAnimation([System.Windows.Window]::TopProperty, $null)
            $script:window.Top = $script:DropdownAnimTarget
            if ($script:DropdownAnimHide) { $script:window.Hide() }
        } catch {
            Write-Log "Dropdown slide completion failed: $($_.Exception.Message)"
        } finally {
            $script:DropdownAnimating = $false
        }
    })

    $script:window.BeginAnimation($topProp, $anim)
}

function Show-Dropdown {
    if (-not (Test-DropdownMode)) { return }

    # Terminal layout first, then size to the monitor width, so the parked
    # position is computed from the real strip height.
    Set-QuakeLayout $true
    Resize-QuakeToContent
    $script:window.UpdateLayout()
    Resize-QuakeToContent      # second pass: height settles once Runs are laid out
    $geo = Get-DropdownGeometry

    $script:window.BeginAnimation([System.Windows.Window]::TopProperty, $null)
    $script:DropdownAnimating = $false
    $script:window.Left = $geo.Left
    $script:window.Top  = $geo.HiddenTop
    $script:window.Show()
    # Re-assert after Show: first-show layout can re-run positioning logic, and the
    # measured size may differ once the window actually has a compositor.
    Resize-QuakeToContent
    $geo = Get-DropdownGeometry
    $script:window.Left = $geo.Left
    $script:window.Top  = $geo.HiddenTop
    $script:window.Topmost = $true
    $script:window.Activate()      # so Esc and click-away dismissal work

    $script:DropdownShown = $true
    Move-DropdownTo $geo.ShownTop $false
}

function Hide-Dropdown {
    if (-not $script:DropdownShown) { return }
    $script:DropdownShown = $false
    if (-not $script:window.IsVisible) { return }
    $geo = Get-DropdownGeometry
    Move-DropdownTo $geo.HiddenTop $true
}

function Toggle-Dropdown {
    # This runs from a WndProc on the UI thread; an escaping exception takes the
    # whole dispatcher down, so the handler swallows and logs instead.
    try {
        if (-not (Test-DropdownMode)) {
            # Hotkey pressed while pinned: just toggle the pinned panel.
            Toggle-PinnedWindow
            return
        }
        if ($script:DropdownAnimating) { return }
        if ($script:DropdownShown) { Hide-Dropdown } else { Show-Dropdown }
    } catch {
        Write-Log ("Toggle-Dropdown failed: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
        $script:DropdownAnimating = $false
    }
}

function Test-DropdownMode {
    # 'Dropdown' is the pre-terminal name for this mode; still honoured so an
    # existing state file keeps working.
    $m = [string]$script:Cfg['ViewMode']
    return ($m -eq 'Quake' -or $m -eq 'Dropdown')
}

function Initialize-DropdownPinnedPosition {
    if ($null -ne $script:Cfg['Left'] -and $null -ne $script:Cfg['Top']) {
        $script:PinnedLeft = [double]$script:Cfg['Left']
        $script:PinnedTop  = [double]$script:Cfg['Top']
    }
}

# ---------------------------------------------------------------------------
# Mode switching
# ---------------------------------------------------------------------------
function Enter-DropdownMode {
    if ($null -ne $script:Cfg['Left']) {
        $script:PinnedLeft = [double]$script:Cfg['Left']
        $script:PinnedTop  = [double]$script:Cfg['Top']
    }
    $script:Cfg['ViewMode'] = 'Quake'
    if (Get-Command Suspend-NotchShell -ErrorAction SilentlyContinue) { Suspend-NotchShell }
    Apply-DropdownChrome
    Set-QuakeLayout $true
    $script:window.Hide()
    $script:DropdownShown = $false
    Register-DropdownHotkey | Out-Null
}

function Exit-DropdownMode {
    $script:Cfg['ViewMode'] = 'Pinned'
    Unregister-DropdownHotkey
    $script:DropdownShown = $false
    Set-QuakeLayout $false
    Apply-DropdownChrome
    Resize-ToContent          # back to content-sized, not monitor-wide
    $script:window.BeginAnimation([System.Windows.Window]::TopProperty, $null)
    $script:DropdownAnimating = $false
    if ($null -ne $script:PinnedLeft) {
        $script:Cfg['Left'] = $script:PinnedLeft
        $script:Cfg['Top']  = $script:PinnedTop
        $script:window.Left = $script:PinnedLeft
        $script:window.Top  = $script:PinnedTop
    }
    Clamp-Position
    $script:window.Show()
    $script:window.Topmost = $true
    # Back to the pinned view: rebuild the notch stage and rest at the edge.
    if (Get-Command Position-IslandWindow -ErrorAction SilentlyContinue) { Position-IslandWindow }
}

# Element-level opacity for the translucent look, kept separate from the
# user's window Opacity setting so the two do not fight.
function Apply-DropdownChrome {
    $panel = $script:window.FindName('mainBorder')
    $quake = $script:window.FindName('quakeRoot')
    if (Test-DropdownMode) {
        $o = [double]$script:Cfg['DropdownOpacity']
        if ($o -le 0 -or $o -gt 1) { $o = 0.85 }
        if ($quake) { $quake.Opacity = $o }
        if ($panel) { $panel.Opacity = 1.0 }
    } else {
        if ($quake) { $quake.Opacity = 1.0 }
        if ($panel) { $panel.Opacity = 1.0 }
    }
}

function Set-DropdownMonitor([string]$DeviceName) {
    $script:Cfg['DropdownMonitor'] = $DeviceName
    if (Test-DropdownMode -and $script:DropdownShown) {
        Resize-QuakeToContent
        $script:window.UpdateLayout()
        $geo = Get-DropdownGeometry
        $script:window.BeginAnimation([System.Windows.Window]::TopProperty, $null)
        $script:DropdownAnimating = $false
        $script:window.Left = $geo.Left
        $script:window.Top  = $geo.ShownTop
    }
}

function Set-DropdownHotkey([string]$Combo) {
    Set-OverlayHotkey 'Dropdown' $Combo
}
