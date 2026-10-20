# UnifiedTray.ps1 - unified system tray icon and dark context menu

# ---------------------------------------------------------------------------
# Notch shell
#
# A presentation-only layer over the existing panel. Polling, auth and cache
# behaviour are untouched; this file only decides what the window looks like.
#
# The whole pinned view is ONE black silhouette that keeps changing shape:
#
#   EDGE         a few-pixel sliver hanging from the top edge of the screen
#   NOTCH        (hover) the sliver grows into a MacBook-style notch and shows
#                the four quota numbers
#   EXPANDING    (left click) the notch grows into the full panel
#   EXPANDED     the full panel; drag it anywhere by its empty space
#   COLLAPSING   ("-" button) the panel shrinks - and travels home if it was
#                dragged away - back into the notch
#   HOLD         a short beat as a notch
#   EDGE_RETURN  the notch shrinks back into the sliver
#
# How it stays smooth: the window never changes size during a morph. It is a
# fixed transparent stage during motion, trimmed vertically when idle. A black backdrop fills the
# stage and the stage's root Grid is clipped to a geometry rebuilt every frame
# from (width, height, bottom radius, shoulder, dock). The clip also masks the
# notch text and the panel content, so content is revealed by the silhouette
# instead of being squeezed. Pixels outside the clip are fully transparent and
# therefore click-through.
#
# One frame loop (CompositionTarget.Rendering) drives every property through
# per-field tracks. A new motion starts each field from its current on-screen
# value, so reversing half-way through (hover in, hover out) never jumps.
# ---------------------------------------------------------------------------
$script:NotchSpec = @{
    EdgeW = 132.0; EdgeH = 5.0; EdgeRb = 2.5; EdgeSh = 2.5
    NotchH = 32.0; NotchRb = 12.0; NotchSh = 7.0; NotchPadX = 12.0; NotchMinW = 150.0
    PanelMinW = 520.0; PanelGutter = 14.0; PanelRb = 22.0; PanelSh = 10.0; FloatRadius = 22.0
    StagePadX = 20.0; StagePadBottom = 12.0
    EdgeZoneExtraX = 56.0; EdgeZoneY = 9.0
    HoverDwellMs = 60.0; HoverLeaveMs = 220.0; PanelLeaveMs = 100.0; PollMs = 35
}
$script:NotchStage = @{ NotchW = 280.0; PanelW = 312.0; PanelH = 320.0; StageW = 352.0; CX = 176.0 }
$script:NotchState = 'EDGE'
$script:NotchWindow = $null
$script:NotchBackdrop = $null
$script:NotchContentRoot = $null
$script:NotchParts = @{}
$script:IslandRoot = $null
$script:IslandElements = @{}
$script:NV = @{
    w = 132.0; h = 5.0; rb = 2.5; sh = 2.5; dock = 1.0
    notchA = 0.0; notchDy = -3.0; headA = 0.0; bodyA = 0.0; bodyDy = -10.0
    winL = 0.0; winT = 0.0
}
$script:NTracks = @{}
$script:NotchTransition = $null
$script:NotchClock = [System.Diagnostics.Stopwatch]::StartNew()
$script:NotchRendering = $false
$script:NotchRenderHandler = $null
$script:NotchFast = $null
$script:NotchLastFrame = [TimeSpan]::Zero
$script:NotchHoverTimer = $null
$script:NotchHoldTimer = $null
$script:NotchArmed = $true
$script:NotchDwellMs = 0.0
$script:NotchLeaveMs = 0.0
$script:NotchPressed = $false
$script:NotchDragging = $false
$script:NotchPanelSeen = $false
$script:NotchPinElement = $null
$script:NotchPanelLeaveMs = 0.0
$script:NotchMenuGraceMs = 0.0
$script:NotchWideElements = $null
$script:NotchHwnd = [IntPtr]::Zero
$script:NotchHwndWindow = $null
$script:NotchInv = [System.Globalization.CultureInfo]::InvariantCulture
$script:NotchSpringK = 7.5
$script:NotchSpringNorm = 1.0 - (1.0 + 7.5) * [math]::Exp(-7.5)
$script:VisVisible = [System.Windows.Visibility]::Visible
$script:VisHidden = [System.Windows.Visibility]::Hidden
$script:VisCollapsed = [System.Windows.Visibility]::Collapsed

function Write-NotchLog([string]$Message) {
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        try { Write-Log "Notch: $Message" } catch { }
    }
}

function Test-NotchShell {
    if ((Get-Command Test-DropdownMode -ErrorAction SilentlyContinue) -and (Test-DropdownMode)) { return $false }
    return $true
}

# Legacy name kept for callers elsewhere: true while the pinned view is NOT the
# full panel (edge / notch / on its way back to the edge).
function Test-IslandMode {
    if (-not (Test-NotchShell)) { return $false }
    return -not ($script:NotchState -eq 'EXPANDED' -or $script:NotchState -eq 'EXPANDING')
}

function Get-IslandMember {
    param($Object, [string]$Name)
    if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Name)) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        foreach ($key in @($Object.Keys)) {
            if ([string]$key -ieq $Name) { return $Object[$key] }
        }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

# ---------------------------------------------------------------------------
# Provider icons
#
# Each provider shows the icon of its own app when that app is installed on
# this PC, read at runtime (Store/MSIX package logo, or the .exe icon). A PNG
# or ICO dropped into <app>\icons\<provider>.png|.ico wins over both. With no
# icon found the tile falls back to a coloured monogram.
# ---------------------------------------------------------------------------
$script:ProviderMeta = [ordered]@{
    claude = @{ Name = 'Claude'; Mono = 'Cl'; Grad = @('#F59E0B', '#EA580C')
                Packages = '^(Claude|AnthropicPBC|Anthropic)[._]'
                Exes = @('%LOCALAPPDATA%\AnthropicClaude\claude.exe', '%LOCALAPPDATA%\Programs\Claude\Claude.exe', '%ProgramFiles%\Claude\Claude.exe', '%LOCALAPPDATA%\Claude\Claude.exe') }
    codex  = @{ Name = 'Codex'; Mono = 'Cx'; Grad = @('#6366F1', '#8B5CF6')
                Packages = '^OpenAI\.Codex[._]'
                Exes = @('%LOCALAPPDATA%\Programs\Codex\Codex.exe', '%ProgramFiles%\Codex\Codex.exe') }
    cursor = @{ Name = 'Cursor'; Mono = 'Cu'; Grad = @('#334155', '#0F172A')
                Packages = '^(Anysphere|Cursor)[._]'
                Exes = @('%LOCALAPPDATA%\Programs\cursor\Cursor.exe', '%ProgramFiles%\Cursor\Cursor.exe') }
    grok   = @{ Name = 'Grok'; Mono = 'Gk'; Grad = @('#52525B', '#18181B')
                Packages = '^(XAI|xAI|Grok)[._]'
                Exes = @('%LOCALAPPDATA%\Programs\Grok\Grok.exe', '%ProgramFiles%\Grok\Grok.exe') }
}
$script:ProviderIconCache = @{}

function Initialize-ProviderIconNative {
    if (([System.Management.Automation.PSTypeName]'AIUsageIconNative').Type) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AIUsageIconNative {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern uint PrivateExtractIcons(string file, int index, int cx, int cy, IntPtr[] icons, uint[] ids, uint count, uint flags);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
    public static IntPtr Extract(string file, int size) {
        var h = new IntPtr[1]; var id = new uint[1];
        uint n = PrivateExtractIcons(file, 0, size, size, h, id, 1, 0);
        if (n == 0 || n == 0xFFFFFFFF) return IntPtr.Zero;
        return h[0];
    }
}
'@
}

function Get-PackageLogoPath([string]$Root) {
    $manifest = Join-Path $Root 'AppxManifest.xml'
    if (-not (Test-Path -LiteralPath $manifest)) { return $null }
    $text = [System.IO.File]::ReadAllText($manifest)
    $logo = $null
    foreach ($attr in @('Square44x44Logo', 'Square150x150Logo', 'Logo')) {
        $m = [regex]::Match($text, $attr + '="([^"]+)"')
        if ($m.Success) { $logo = $m.Groups[1].Value; break }
    }
    if (-not $logo) { return $null }
    $full = Join-Path $Root $logo
    $dir = Split-Path $full -Parent
    $base = [System.IO.Path]::GetFileNameWithoutExtension($full)
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $best = $null; $bestScore = -1
    foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter ($base + '*.png') -File -ErrorAction SilentlyContinue)) {
        $n = $f.Name.ToLowerInvariant()
        $score = 10
        if ($n -match 'targetsize-(\d+)') {
            $size = [int]$Matches[1]
            $score = 40 - [math]::Abs($size - 64) / 8
            if ($n -match 'unplated') { $score += 40 }
            if ($n -match 'lightunplated|contrast') { $score -= 30 }
        } elseif ($n -match 'scale-(\d+)') {
            $score = 20 + [int]$Matches[1] / 50
        }
        if ($score -gt $bestScore) { $best = $f.FullName; $bestScore = $score }
    }
    if ($best) { return $best }
    if (Test-Path -LiteralPath $full) { return $full }
    return $null
}

function Get-ProviderIcon([string]$Key) {
    if ($script:ProviderIconCache.ContainsKey($Key)) { return $script:ProviderIconCache[$Key] }
    $meta = $script:ProviderMeta[$Key]
    $source = $null
    try {
        # 1. user-supplied override
        foreach ($ext in @('png', 'ico')) {
            $p = Join-Path $script:AppDir ("icons\{0}.{1}" -f $Key, $ext)
            if (Test-Path -LiteralPath $p) {
                $bi = New-Object System.Windows.Media.Imaging.BitmapImage
                $bi.BeginInit(); $bi.UriSource = [Uri]$p; $bi.CacheOption = 'OnLoad'; $bi.DecodePixelWidth = 64; $bi.EndInit(); $bi.Freeze()
                $source = $bi; break
            }
        }
        # 2. installed Store/MSIX package
        if (-not $source -and $meta) {
            $reg = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages'
            if (Test-Path $reg) {
                $pkg = Get-ChildItem $reg -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match $meta.Packages } | Select-Object -First 1
                if ($pkg) {
                    $root = (Get-ItemProperty -LiteralPath $pkg.PSPath -ErrorAction SilentlyContinue).PackageRootFolder
                    if ($root) {
                        $logo = Get-PackageLogoPath $root
                        if ($logo) {
                            $bi = New-Object System.Windows.Media.Imaging.BitmapImage
                            $bi.BeginInit(); $bi.UriSource = [Uri]$logo; $bi.CacheOption = 'OnLoad'; $bi.DecodePixelWidth = 64; $bi.EndInit(); $bi.Freeze()
                            $source = $bi
                        }
                    }
                }
            }
        }
        # 3. classic .exe install
        if (-not $source -and $meta) {
            Initialize-ProviderIconNative
            foreach ($raw in $meta.Exes) {
                $exe = [Environment]::ExpandEnvironmentVariables($raw)
                if (-not (Test-Path -LiteralPath $exe)) { continue }
                $h = [AIUsageIconNative]::Extract($exe, 64)
                if ($h -eq [IntPtr]::Zero) { continue }
                try {
                    $bs = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($h, [System.Windows.Int32Rect]::Empty,
                        [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
                    $bs.Freeze()
                    $source = $bs
                } finally { [void][AIUsageIconNative]::DestroyIcon($h) }
                if ($source) { break }
            }
        }
    } catch {
        Write-NotchLog "icon $Key : $($_.Exception.Message)"
    }
    $script:ProviderIconCache[$Key] = $source
    return $source
}

# Fill an icon tile: the app icon when there is one, else gradient + monogram.
function Set-ProviderTile($Tile, $Image, $Mono, [string]$Key) {
    if (-not $Tile) { return }
    $icon = Get-ProviderIcon $Key
    $meta = $script:ProviderMeta[$Key]
    if ($icon) {
        if ($Image) { $Image.Source = $icon; $Image.Visibility = $script:VisVisible }
        if ($Mono) { $Mono.Visibility = $script:VisCollapsed }
        $Tile.Background = [System.Windows.Media.Brushes]::Transparent
    } else {
        if ($Image) { $Image.Visibility = $script:VisCollapsed }
        if ($Mono) { $Mono.Visibility = $script:VisVisible; if ($meta) { $Mono.Text = $meta.Mono } }
        if ($meta) {
            $b = New-Object System.Windows.Media.LinearGradientBrush
            $b.StartPoint = [System.Windows.Point]::new(0, 0); $b.EndPoint = [System.Windows.Point]::new(1, 1)
            [void]$b.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.ColorConverter]::ConvertFromString($meta.Grad[0]), 0)))
            [void]$b.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.ColorConverter]::ConvertFromString($meta.Grad[1]), 1)))
            $Tile.Background = $b
        }
    }
}

function Sync-ProviderCardIcons {
    if (-not $script:window) { return }
    foreach ($key in @($script:ProviderMeta.Keys)) {
        Set-ProviderTile ($script:window.FindName($key + 'IconTile')) ($script:window.FindName($key + 'IconImage')) ($script:window.FindName($key + 'Monogram')) $key
    }
}

# ---------------------------------------------------------------------------
# Language: English / 中文 / Français / 日本語 / 한국어. Text is written in English everywhere and
# translated in one pass after each refresh (panel) and on every menu open, so
# the rest of the code never has to know about languages.
# ---------------------------------------------------------------------------
$script:I18nLangs = [ordered]@{ en = 'English'; zh = '中文'; fr = 'Français'; ja = '日本語'; ko = '한국어' }
# Translations per language. Keys are the English text the code writes.
$script:I18nText = @{
    'AI Usage' = @{ zh = 'AI 用量'; ja = 'AI 使用量'; fr = 'Usage IA'; ko = 'AI 사용량' }
    'Live' = @{ zh = '实时'; ja = 'ライブ'; fr = 'En direct'; ko = '실시간' }
    'Accounts' = @{ zh = '账户'; ja = 'アカウント'; fr = 'Comptes'; ko = '계정' }
    'Account' = @{ zh = '账号'; ja = 'アカウント'; fr = 'Compte'; ko = '계정' }
    '5-Hour Session' = @{ zh = '5 小时会话'; ja = '5時間セッション'; fr = 'Session 5 h'; ko = '5시간 세션' }
    'Weekly Limit' = @{ zh = '每周额度'; ja = '週間上限'; fr = 'Limite hebdo'; ko = '주간 한도' }
    'Fable Weekly' = @{ zh = 'Fable 每周'; ja = 'Fable 週間'; fr = 'Fable hebdo'; ko = 'Fable 주간' }
    'Opus Weekly' = @{ zh = 'Opus 每周'; ja = 'Opus 週間'; fr = 'Opus hebdo'; ko = 'Opus 주간' }
    '5-HOUR' = @{ zh = '5 小时'; ja = '5時間'; fr = '5 H'; ko = '5시간' }
    'WEEKLY' = @{ zh = '每周'; ja = '週間'; fr = 'HEBDO'; ko = '주간' }
    'Models' = @{ zh = '模型'; ja = 'モデル'; fr = 'Modèles'; ko = '모델' }
    'Model' = @{ zh = '模型'; ja = 'モデル'; fr = 'Modèle'; ko = '모델' }
    'OTHER' = @{ zh = '其他'; ja = 'その他'; fr = 'AUTRES'; ko = '기타' }
    'Other models' = @{ zh = '其他模型'; ja = 'その他のモデル'; fr = 'Autres modèles'; ko = '기타 모델' }
    'On-demand' = @{ zh = '按需'; ja = 'オンデマンド'; fr = 'À la demande'; ko = '온디맨드' }
    'Overage' = @{ zh = '超额'; ja = '超過分'; fr = 'Dépassement'; ko = '초과분' }
    'Prepaid' = @{ zh = '预付'; ja = 'プリペイド'; fr = 'Prépayé'; ko = '선불' }
    'Usage' = @{ zh = '用量'; ja = '使用量'; fr = 'Utilisation'; ko = '사용량' }
    'Edits' = @{ zh = '编辑'; ja = '編集'; fr = 'Modifs'; ko = '편집' }
    'Lines' = @{ zh = '行数'; ja = '行数'; fr = 'Lignes'; ko = '줄 수' }
    'over' = @{ zh = '超出'; ja = '超過'; fr = 'dépassé'; ko = '초과' }
    'used' = @{ zh = '已用'; ja = '使用済み'; fr = 'utilisé'; ko = '사용됨' }
    'left' = @{ zh = '剩余'; ja = '残り'; fr = 'restant'; ko = '남음' }
    'high' = @{ zh = '偏高'; ja = '高め'; fr = 'élevé'; ko = '높음' }
    'critical!' = @{ zh = '即将用完！'; ja = '残りわずか！'; fr = 'critique !'; ko = '위험!' }
    'Est. Cost' = @{ zh = '预估费用'; ja = '推定コスト'; fr = 'Coût estimé'; ko = '예상 비용' }
    'Tokens' = @{ zh = 'Token'; ja = 'トークン'; fr = 'Jetons'; ko = '토큰' }
    'Today' = @{ zh = '今天'; ja = '今日'; fr = 'Aujourd''hui'; ko = '오늘' }
    'After Hrs' = @{ zh = '下班后'; ja = '時間外'; fr = 'Hors heures'; ko = '업무 외' }
    'Lifetime' = @{ zh = '累计'; ja = '累計'; fr = 'Total'; ko = '누적' }
    'Resets' = @{ zh = '重置'; ja = 'リセット'; fr = 'Réinit.'; ko = '초기화' }
    'Used up · limit reached' = @{ zh = '已用完 · 达到上限'; ja = '使い切りました · 上限到達'; fr = 'Épuisé · limite atteinte'; ko = '모두 사용 · 한도 도달' }
    'Unavailable' = @{ zh = '不可用'; ja = '利用不可'; fr = 'Indisponible'; ko = '사용 불가' }
    'Loading' = @{ zh = '加载中'; ja = '読み込み中'; fr = 'Chargement'; ko = '불러오는 중' }
    'Active' = @{ zh = '正常'; ja = '稼働中'; fr = 'Actif'; ko = '정상' }
    'Signed in' = @{ zh = '已登录'; ja = 'サインイン済み'; fr = 'Connecté'; ko = '로그인됨' }
    'Not set up' = @{ zh = '未设置'; ja = '未設定'; fr = 'Non configuré'; ko = '설정 안 됨' }
    'Sign in' = @{ zh = '需要登录'; ja = 'サインインが必要'; fr = 'Se connecter'; ko = '로그인 필요' }
    'Showing last available usage' = @{ zh = '显示最近一次的用量'; ja = '最後に取得した使用量を表示中'; fr = 'Dernières données disponibles'; ko = '마지막 사용량 표시 중' }
    'Claude access expired - sign in again to restore live usage' = @{ zh = 'Claude 登录已过期，重新登录后恢复实时用量'; ja = 'Claude のアクセスが期限切れです。再度サインインするとライブ使用量が戻ります'; fr = 'Accès Claude expiré : reconnectez-vous pour retrouver l''usage en direct'; ko = 'Claude 접근이 만료되었습니다. 다시 로그인하면 실시간 사용량이 복원됩니다' }
    'Stale' = @{ zh = '数据过期'; ja = 'データが古い'; fr = 'Périmé'; ko = '오래된 데이터' }
    'Error' = @{ zh = '错误'; ja = 'エラー'; fr = 'Erreur'; ko = '오류' }
    'Syncing' = @{ zh = '同步中'; ja = '同期中'; fr = 'Synchro'; ko = '동기화 중' }
    'Not signed in' = @{ zh = '未登录'; ja = '未サインイン'; fr = 'Non connecté'; ko = '로그인 안 됨' }
    'Checking' = @{ zh = '检查中'; ja = '確認中'; fr = 'Vérification'; ko = '확인 중' }
    'Signed in · idle' = @{ zh = '已登录 · 空闲'; ja = 'サインイン済み · 待機中'; fr = 'Connecté · inactif'; ko = '로그인됨 · 대기' }
    'resetting now' = @{ zh = '即将重置'; ja = 'まもなくリセット'; fr = 'réinitialisation'; ko = '곧 초기화' }
    'JayOS  Settings' = @{ zh = 'JayOS 设置'; ja = 'JayOS 設定'; fr = 'Réglages JayOS'; ko = 'JayOS 설정' }
    'Alerts & Status' = @{ zh = '提醒与状态'; ja = '通知とステータス'; fr = 'Alertes et état'; ko = '알림 및 상태' }
    'Account & Data' = @{ zh = '账户与数据'; ja = 'アカウントとデータ'; fr = 'Compte et données'; ko = '계정 및 데이터' }
    'Appearance & Layout' = @{ zh = '外观与布局'; ja = '外観とレイアウト'; fr = 'Apparence et disposition'; ko = '모양 및 레이아웃' }
    'Panels & Features' = @{ zh = '面板与功能'; ja = 'パネルと機能'; fr = 'Panneaux et fonctions'; ko = '패널 및 기능' }
    'System' = @{ zh = '系统'; ja = 'システム'; fr = 'Système'; ko = '시스템' }
    'Quit' = @{ zh = '退出'; ja = '終了'; fr = 'Quitter'; ko = '종료' }
    'Notch (hover to peek)' = @{ zh = '刘海（悬停预览）'; ja = 'ノッチ（ホバーで表示）'; fr = 'Encoche (survol pour voir)'; ko = '노치 (마우스를 올려 보기)' }
    'Open full panel' = @{ zh = '打开完整面板'; ja = 'パネルを開く'; fr = 'Ouvrir le panneau'; ko = '전체 패널 열기' }
    'Fold back to notch' = @{ zh = '收回到刘海'; ja = 'ノッチに戻す'; fr = 'Replier dans l''encoche'; ko = '노치로 접기' }
    'Refresh now' = @{ zh = '立即刷新'; ja = '今すぐ更新'; fr = 'Actualiser'; ko = '지금 새로 고침' }
    'Test alert' = @{ zh = '测试提醒'; ja = 'テスト通知'; fr = 'Tester une alerte'; ko = '알림 테스트' }
    'Dismiss current alert' = @{ zh = '关闭当前提醒'; ja = '現在の通知を閉じる'; fr = 'Ignorer l''alerte'; ko = '현재 알림 닫기' }
    'Copy stats to clipboard' = @{ zh = '复制统计数据'; ja = '統計をコピー'; fr = 'Copier les statistiques'; ko = '통계 복사' }
    'Platforms' = @{ zh = '平台'; ja = 'プラットフォーム'; fr = 'Plateformes'; ko = '플랫폼' }
    'Brand' = @{ zh = '品牌标识'; ja = 'ブランド'; fr = 'Marque'; ko = '브랜드' }
    'Providers' = @{ zh = 'AI 服务'; ja = 'プロバイダー'; fr = 'Services IA'; ko = 'AI 서비스' }
    'Log in' = @{ zh = '登录'; ja = 'サインイン'; fr = 'Connexion'; ko = '로그인' }
    'View' = @{ zh = '视图'; ja = '表示'; fr = 'Affichage'; ko = '보기' }
    'Hotkeys' = @{ zh = '快捷键'; ja = 'ホットキー'; fr = 'Raccourcis'; ko = '단축키' }
    'Snap to corner' = @{ zh = '贴靠到角落'; ja = '隅に配置'; fr = 'Aligner dans un coin'; ko = '모서리에 맞추기' }
    'Opacity' = @{ zh = '不透明度'; ja = '不透明度'; fr = 'Opacité'; ko = '불투명도' }
    'Theme' = @{ zh = '主题'; ja = 'テーマ'; fr = 'Thème'; ko = '테마' }
    'Language' = @{ zh = '语言'; ja = '言語'; fr = 'Langue'; ko = '언어' }
    'Background' = @{ zh = '背景颜色'; ja = '背景色'; fr = 'Arrière-plan'; ko = '배경색' }
    'Custom…' = @{ zh = '自定义…'; ja = 'カスタム…'; fr = 'Personnaliser…'; ko = '사용자 지정…' }
    'Show stats panel' = @{ zh = '显示统计面板'; ja = '統計パネルを表示'; fr = 'Afficher les statistiques'; ko = '통계 패널 표시' }
    'Compact mode' = @{ zh = '紧凑模式'; ja = 'コンパクトモード'; fr = 'Mode compact'; ko = '간단히 보기' }
    'Threshold alerts' = @{ zh = '用量提醒'; ja = 'しきい値通知'; fr = 'Alertes de seuil'; ko = '사용량 알림' }
    'Show history graph' = @{ zh = '显示历史曲线'; ja = '履歴グラフを表示'; fr = 'Afficher l''historique'; ko = '기록 그래프 표시' }
    'Show remaining (not used)' = @{ zh = '显示剩余（而非已用）'; ja = '残量を表示（使用量ではなく）'; fr = 'Afficher le restant (pas l''utilisé)'; ko = '남은 양 표시 (사용량 대신)' }
    'Pin button on notch' = @{ zh = '刘海图钉按钮'; ja = 'ノッチのピンボタン'; fr = 'Épingle sur l''encoche'; ko = '노치 고정 버튼' }
    'Open at login' = @{ zh = '开机启动'; ja = 'ログイン時に起動'; fr = 'Lancer au démarrage'; ko = '로그인 시 실행' }
    'Start hidden to tray' = @{ zh = '启动时隐藏到托盘'; ja = 'トレイに隠して起動'; fr = 'Démarrer réduit'; ko = '트레이로 숨겨서 시작' }
    'Minimize to tray' = @{ zh = '最小化到托盘'; ja = 'トレイに最小化'; fr = 'Réduire dans la barre'; ko = '트레이로 최소화' }
    'Pinned panel' = @{ zh = '固定面板'; ja = '固定パネル'; fr = 'Panneau fixe'; ko = '고정 패널' }
    'Quake terminal (hotkey)' = @{ zh = '下拉面板（快捷键）'; ja = 'ドロップダウン（ホットキー）'; fr = 'Panneau déroulant (raccourci)'; ko = '드롭다운 패널 (단축키)' }
    'Drop-down hotkey' = @{ zh = '下拉快捷键'; ja = 'ドロップダウンのホットキー'; fr = 'Raccourci du panneau'; ko = '드롭다운 단축키' }
    'Drop-down monitor' = @{ zh = '下拉所在显示器'; ja = 'ドロップダウンのモニター'; fr = 'Écran du panneau'; ko = '드롭다운 모니터' }
    'Hide when it loses focus' = @{ zh = '失去焦点时隐藏'; ja = 'フォーカスを失ったら隠す'; fr = 'Masquer si inactif'; ko = '포커스를 잃으면 숨기기' }
    'Show/hide overlay' = @{ zh = '显示/隐藏悬浮窗'; ja = 'オーバーレイの表示/非表示'; fr = 'Afficher/masquer'; ko = '오버레이 표시/숨기기' }
    'None (unbound)' = @{ zh = '无（未绑定）'; ja = 'なし（未割り当て）'; fr = 'Aucun'; ko = '없음' }
    'Top right' = @{ zh = '右上'; ja = '右上'; fr = 'En haut à droite'; ko = '오른쪽 위' }
    'Top left' = @{ zh = '左上'; ja = '左上'; fr = 'En haut à gauche'; ko = '왼쪽 위' }
    'Bottom right' = @{ zh = '右下'; ja = '右下'; fr = 'En bas à droite'; ko = '오른쪽 아래' }
    'Bottom left' = @{ zh = '左下'; ja = '左下'; fr = 'En bas à gauche'; ko = '왼쪽 아래' }
    'Choose providers…' = @{ zh = '选择 AI 服务…'; ja = 'プロバイダーを選択…'; fr = 'Choisir les services…'; ko = 'AI 서비스 선택…' }
    'Set footer brand…' = @{ zh = '设置底部标识…'; ja = 'フッターのロゴを設定…'; fr = 'Logo de pied de page…'; ko = '하단 로고 설정…' }
    'Reset JayOS mark' = @{ zh = '重置 JayOS 标识'; ja = 'JayOS マークをリセット'; fr = 'Rétablir le logo JayOS'; ko = 'JayOS 로고 복원' }
    'Graphite' = @{ zh = '石墨'; ja = 'グラファイト'; fr = 'Graphite'; ko = '그래파이트' }
    'Pure black' = @{ zh = '纯黑'; ja = 'ピュアブラック'; fr = 'Noir pur'; ko = '순수 검정' }
    'Warm gray' = @{ zh = '暖灰'; ja = 'ウォームグレー'; fr = 'Gris chaud'; ko = '따뜻한 회색' }
    'Slate' = @{ zh = '岩灰'; ja = 'スレート'; fr = 'Ardoise'; ko = '슬레이트' }
    'Forest' = @{ zh = '墨绿'; ja = 'フォレスト'; fr = 'Forêt'; ko = '포레스트' }
    'Navy' = @{ zh = '深蓝'; ja = 'ネイビー'; fr = 'Marine'; ko = '네이비' }
    'Plum' = @{ zh = '暗紫'; ja = 'プラム'; fr = 'Prune'; ko = '플럼' }
    'Wine' = @{ zh = '酒红'; ja = 'ワイン'; fr = 'Bordeaux'; ko = '와인' }
    'Check for updates' = @{ zh = '检查更新'; ja = '更新を確認'; fr = 'Rechercher des mises à jour'; ko = '업데이트 확인' }
    'Downloading update…' = @{ zh = '正在下载更新…'; ja = '更新をダウンロード中…'; fr = 'Téléchargement de la mise à jour…'; ko = '업데이트 다운로드 중…' }
    'Checking for updates…' = @{ zh = '正在检查更新…'; ja = '更新を確認中…'; fr = 'Recherche de mises à jour…'; ko = '업데이트 확인 중…' }
    'Update check failed' = @{ zh = '检查更新失败'; ja = '更新を確認できませんでした'; fr = 'Échec de la vérification'; ko = '업데이트 확인 실패' }
    'Update download failed' = @{ zh = '更新下载失败'; ja = '更新のダウンロードに失敗'; fr = 'Échec du téléchargement'; ko = '업데이트 다운로드 실패' }
    'Installing update…' = @{ zh = '正在安装更新…'; ja = '更新をインストール中…'; fr = 'Installation de la mise à jour…'; ko = '업데이트 설치 중…' }
    'Custom background colour' = @{ zh = '自定义背景颜色'; ja = '背景色をカスタマイズ'; fr = 'Couleur de fond personnalisée'; ko = '배경색 사용자 지정' }
    'Cloud credit' = @{ zh = '云端剩余额度'; ja = 'クラウド残高'; fr = 'Crédit cloud restant'; ko = '클라우드 잔여 크레딧' }
    'Credits' = @{ zh = '加购额度'; ja = '追加クレジット'; fr = 'Crédits'; ko = '추가 크레딧' }
    'Unlimited' = @{ zh = '不限量'; ja = '無制限'; fr = 'Illimité'; ko = '무제한' }
    'Hue' = @{ zh = '色相'; ja = '色相'; fr = 'Teinte'; ko = '색상' }
    'Brightness' = @{ zh = '亮度'; ja = '明るさ'; fr = 'Luminosité'; ko = '밝기' }
    'Presets' = @{ zh = '预设'; ja = 'プリセット'; fr = 'Préréglages'; ko = '프리셋' }
    'Recent' = @{ zh = '最近使用'; ja = '最近使った色'; fr = 'Récentes'; ko = '최근 사용' }
    'Cancel' = @{ zh = '取消'; ja = 'キャンセル'; fr = 'Annuler'; ko = '취소' }
    'Apply' = @{ zh = '应用'; ja = '適用'; fr = 'Appliquer'; ko = '적용' }
    'Earliest expires {0}.' = @{ zh = ' 最早于 {0} 到期。'; ja = ' 最も早い有効期限：{0}。'; fr = ' Première expiration : {0}.'; ko = ' 가장 빠른 만료일: {0}.' }
    'Monitor with mouse' = @{ zh = '鼠标所在显示器'; ja = 'マウスのあるモニター'; fr = 'Écran de la souris'; ko = '마우스가 있는 모니터' }
    'Primary' = @{ zh = '主显示器'; ja = 'メインモニター'; fr = 'Écran principal'; ko = '주 모니터' }
    'Install Claude Code' = @{ zh = '安装 Claude Code'; ja = 'Claude Code をインストール'; fr = 'Installer Claude Code'; ko = 'Claude Code 설치' }
    'Dashboard' = @{ zh = '控制台'; ja = 'ダッシュボード'; fr = 'Tableau de bord'; ko = '대시보드' }
    'Cursor docs' = @{ zh = 'Cursor 文档'; ja = 'Cursor ドキュメント'; fr = 'Documentation Cursor'; ko = 'Cursor 문서' }
    'ChatGPT Codex' = @{ zh = 'ChatGPT Codex 网页版'; ja = 'ChatGPT Codex を開く'; fr = 'Ouvrir ChatGPT Codex'; ko = 'ChatGPT Codex 열기' }
    'Install Codex CLI' = @{ zh = '安装 Codex 命令行工具'; ja = 'Codex CLI をインストール'; fr = 'Installer Codex CLI'; ko = 'Codex CLI 설치' }
    'Install Grok CLI' = @{ zh = '安装 Grok 命令行工具'; ja = 'Grok CLI をインストール'; fr = 'Installer Grok CLI'; ko = 'Grok CLI 설치' }
    'Console / billing' = @{ zh = '控制台 / 账单'; ja = 'コンソール / 請求'; fr = 'Console / facturation'; ko = '콘솔 / 결제' }
    'Claude Usage Critical' = @{ zh = 'Claude 用量即将耗尽'; ja = 'Claude の使用量が上限間近'; fr = 'Utilisation Claude : seuil critique'; ko = 'Claude 사용량 한도 임박' }
    'Claude Usage Warning' = @{ zh = 'Claude 用量预警'; ja = 'Claude の使用量の警告'; fr = 'Alerte d''utilisation Claude'; ko = 'Claude 사용량 경고' }
    '{0} at {1}%' = @{ zh = '{0}已使用 {1}%'; ja = '{0}の使用量：{1}%'; fr = '{0} à {1} %'; ko = '{0} 사용량 {1}%' }
    '(~{0} min to limit)' = @{ zh = '（预计约 {0} 分钟后达到上限）'; ja = '（上限まで約{0}分）'; fr = ' (limite dans environ {0} min)'; ko = ' (한도까지 약 {0}분)' }
    'AI Usage Overlay Test' = @{ zh = 'AI 用量悬浮窗测试'; ja = 'AI 使用量オーバーレイのテスト'; fr = 'Test de l''affichage d''utilisation IA'; ko = 'AI 사용량 오버레이 테스트' }
    'Threshold alerts are working.' = @{ zh = '用量阈值提醒正常。'; ja = '使用量のしきい値通知は正常です。'; fr = 'Les alertes de seuil fonctionnent.'; ko = '사용량 임계값 알림이 정상 작동합니다.' }
    'Drag to move' = @{ zh = '拖动以移动'; ja = 'ドラッグして移動'; fr = 'Glisser pour déplacer'; ko = '드래그하여 이동' }
    'Not installed - opens the install page' = @{ zh = '尚未安装，点击打开安装页面'; ja = '未インストール：クリックでインストールページを開く'; fr = 'Non installé : ouvrir la page d''installation'; ko = '설치되지 않음 - 클릭하여 설치 페이지 열기' }
    'Click to sign in again' = @{ zh = '点击重新登录'; ja = 'クリックして再ログイン'; fr = 'Cliquer pour se reconnecter'; ko = '클릭하여 다시 로그인' }
    'Signed in - last refresh failed' = @{ zh = '已登录，但上次刷新失败'; ja = 'ログイン済み：前回の更新に失敗'; fr = 'Connecté, mais la dernière actualisation a échoué'; ko = '로그인됨 - 마지막 새로 고침 실패' }
    'Signed in (token idle) - click to sign in again' = @{ zh = '已登录（令牌暂未使用），点击重新登录'; ja = 'ログイン済み（トークン待機中）：クリックして再ログイン'; fr = 'Connecté (jeton inactif) : cliquer pour se reconnecter'; ko = '로그인됨 (토큰 유휴 상태) - 클릭하여 다시 로그인' }
    'Live access expired - click to sign in' = @{ zh = '实时访问授权已过期，点击登录'; ja = 'リアルタイムアクセスの期限切れ：クリックしてログイン'; fr = 'Accès en temps réel expiré : cliquer pour se connecter'; ko = '실시간 접근 만료 - 클릭하여 로그인' }
    'Click to sign in' = @{ zh = '点击登录'; ja = 'クリックしてログイン'; fr = 'Cliquer pour se connecter'; ko = '클릭하여 로그인' }
    'Waiting for the first refresh' = @{ zh = '等待首次刷新'; ja = '初回の更新を待機中'; fr = 'En attente de la première actualisation'; ko = '첫 새로 고침 대기 중' }
    'Signed in. Live usage returns when Claude Code renews its token.' = @{ zh = '已登录。Claude Code 续期令牌后将恢复实时用量。'; ja = 'ログイン済み。Claude Code がトークンを更新するとリアルタイム使用量が再表示されます。'; fr = 'Connecté. L''utilisation en temps réel reviendra après le renouvellement du jeton par Claude Code.'; ko = '로그인됨. Claude Code가 토큰을 갱신하면 실시간 사용량이 다시 표시됩니다.' }
    'Runs Claude Code in the background with a one-line Haiku prompt when the sign-in has expired (at most every 30 minutes).' = @{ zh = '登录过期时，在后台向 Claude Code 发送一条简短的 Haiku 提示以续期（最多每 30 分钟一次）。'; ja = 'ログイン期限切れ時に、バックグラウンドで Claude Code に短い Haiku プロンプトを送信して更新します（最大30分に1回）。'; fr = 'Après expiration de la connexion, lance Claude Code en arrière-plan avec une courte requête Haiku (au plus une fois toutes les 30 minutes).'; ko = '로그인이 만료되면 백그라운드에서 Claude Code에 짧은 Haiku 프롬프트를 보내 갱신합니다 (최대 30분에 한 번).' }
    'One-time usage reset availability could not be verified.' = @{ zh = '暂时无法确认可用的用量重置次数。'; ja = '利用可能な使用量リセット回数を確認できませんでした。'; fr = 'Impossible de vérifier le nombre de réinitialisations disponibles.'; ko = '사용량 초기화 가능 횟수를 확인할 수 없습니다.' }
    'One-time usage resets. Redeem on the Grok Usage page.' = @{ zh = '可用的单次用量重置次数，请前往 Grok 用量页面使用。'; ja = '使用量の単発リセット。Grok の使用量ページで利用できます。'; fr = 'Réinitialisations ponctuelles à utiliser sur la page d''utilisation Grok.'; ko = '일회성 사용량 초기화. Grok 사용량 페이지에서 사용할 수 있습니다.' }
    'Reset availability needs refreshing after expiry.' = @{ zh = '重置次数已过期，请刷新后查看。'; ja = '有効期限が切れたため、リセット回数を再取得してください。'; fr = 'Actualisez les réinitialisations disponibles après expiration.'; ko = '유효 기간이 만료되어 초기화 가능 횟수를 새로 고쳐야 합니다.' }
    'One-time usage resets you can redeem on the Codex usage page.' = @{ zh = '可在 Codex 用量页面使用的单次用量重置次数。'; ja = 'Codex の使用量ページで利用できる単発リセット。'; fr = 'Réinitialisations ponctuelles à utiliser sur la page d''utilisation Codex.'; ko = 'Codex 사용량 페이지에서 사용할 수 있는 일회성 초기화.' }
    'Sign in to your AIs' = @{ zh = '登录 AI 账号'; ja = 'AI アカウントにログイン'; fr = 'Se connecter aux comptes IA'; ko = 'AI 계정 로그인' }
    'Every colour here keeps the text readable.' = @{ zh = '这里的每种颜色都能看清文字。'; ja = 'ここの色はどれも文字が読みやすい明るさです。'; fr = 'Chaque couleur ici garde le texte lisible.'; ko = '여기 있는 색은 모두 글자가 잘 보입니다.' }
}
# Single words inside the two-tone stat values ("456 in / 98.9k out").
$script:I18nWords = @{
    'all-time' = @{ zh = '累计'; ja = '累計'; fr = 'au total'; ko = '누적' }
    'in' = @{ zh = '入'; ja = '入'; fr = 'entrée'; ko = '입력' }
    'out' = @{ zh = '出'; ja = '出'; fr = 'sortie'; ko = '출력' }
    'msgs' = @{ zh = '条消息'; ja = '件'; fr = 'msg'; ko = '개 메시지' }
    'sessions' = @{ zh = '个会话'; ja = 'セッション'; fr = 'sessions'; ko = '세션' }
    'available' = @{ zh = '次可用'; ja = '回利用可'; fr = 'disponible'; ko = '회 사용 가능' }
}
$script:I18nRules = @(
    @{ rx = '^Claude Code cloud sessions: \$(.+) of \$(.+) left\. Expires (.*)\.$'; zh = 'Claude Code 云端会话额度：剩余 $$$1 / $$$2，到期时间：$3。'; ja = 'Claude Code クラウドセッション：残り $$$1 / $$$2。有効期限：$3。'; fr = 'Sessions cloud Claude Code : $$$1 restants sur $$$2. Expiration : $3.'; ko = 'Claude Code 클라우드 세션: $$$2 중 $$$1 남음. 만료: $3.' },
    @{ rx = '^(.+) credits left of a (.+) top-up \((.+)% left\)\.$'; zh = '加购额度共 $2，剩余 $1（$3%）。'; ja = '追加クレジット $2 のうち残り $1（$3%）。'; fr = 'Il reste $1 crédits sur une recharge de $2 ($3 % restants).'; ko = '추가 크레딧 $2 중 $1 남음 ($3%).' },
    @{ rx = '^as of (.+)$'; zh = '截至 $1'; ja = '$1 時点'; fr = 'au $1'; ko = '$1 기준' },
    @{ rx = '^Claude as of (.+)$'; zh = 'Claude 数据截至 $1'; ja = 'Claude：$1 時点'; fr = 'Claude : au $1'; ko = 'Claude: $1 기준' },
    @{ rx = '^(.*)\(primary\)$'; zh = '$1（主显示器）'; ja = '$1（メイン）'; fr = '$1(principal)'; ko = '$1(주 모니터)' },
    @{ rx = '^Click to sign in to (.+)$'; zh = '点击登录 $1'; ja = '$1 にログインするにはクリック'; fr = 'Cliquer pour se connecter à $1'; ko = '$1에 로그인하려면 클릭' },
    @{ rx = '^Open (.+)$'; zh = '打开 $1'; ja = '$1 を開く'; fr = 'Ouvrir $1'; ko = '$1 열기' },
    @{ rx = '^Update to (.+)$'; zh = '更新到 $1'; ja = '$1 に更新'; fr = 'Mettre à jour vers $1'; ko = '$1(으)로 업데이트' },
    @{ rx = '^Up to date \((.+)\)$'; zh = '已是最新版（$1）'; ja = '最新版です（$1）'; fr = 'À jour ($1)'; ko = '최신 버전 ($1)' },
    @{ rx = '^Live · (.+)$'; zh = '实时 · $1'; ja = 'ライブ · $1'; fr = 'En direct · $1'; ko = '실시간 · $1' },
    @{ rx = '^(\d+)d (\d+)h left$'; zh = '剩 $1 天 $2 小时'; ja = '残り $1日$2時間'; fr = 'reste $1 j $2 h'; ko = '$1일 $2시간 남음' },
    @{ rx = '^(\d+)h (\d+)m left$'; zh = '剩 $1 小时 $2 分'; ja = '残り $1時間$2分'; fr = 'reste $1 h $2 min'; ko = '$1시간 $2분 남음' },
    @{ rx = '^(\d+)m left$'; zh = '剩 $1 分钟'; ja = '残り $1分'; fr = 'reste $1 min'; ko = '$1분 남음' },
    @{ rx = '^(\d+) available$'; zh = '$1 次可用'; ja = '$1 回利用可'; fr = '$1 disponible(s)'; ko = '$1회 사용 가능' },
    @{ rx = '^of ([\d\s\u202F\u00A0,.]+)$'; zh = '共 $1'; ja = '/ $1'; fr = 'sur $1'; ko = '/ $1' },
    @{ rx = '^Version (.+)$'; zh = '版本 $1'; ja = 'バージョン $1'; fr = 'Version $1'; ko = '버전 $1' },
    @{ rx = '^Log in (\S+)$'; zh = '登录 $1'; ja = '$1 にサインイン'; fr = 'Connexion à $1'; ko = '$1 로그인' },
    @{ rx = '^(\S+) not installed$'; zh = '$1 未安装'; ja = '$1 未インストール'; fr = '$1 non installé'; ko = '$1 설치 안 됨' },
    @{ rx = '^(.+?)\s+\(hidden\)$'; zh = '$1（已隐藏）'; ja = '$1（非表示）'; fr = '$1 (masqué)'; ko = '$1 (숨김)' }
)

$script:I18nOrig = @{}
$script:I18nLast = @{}
$script:I18nBlocks = $null

function Get-UiLanguage {
    $l = if ($script:Cfg) { [string]$script:Cfg['Language'] } else { '' }
    if ($script:I18nLangs.Contains($l)) { return $l }
    return 'en'
}

function Convert-I18nString([string]$Text, [string]$Lang) {
    if ($Lang -eq 'en' -or [string]::IsNullOrWhiteSpace($Text)) { return $Text }
    $key = $Text.Trim()
    if ($script:I18nText.ContainsKey($key)) {
        $t = [string]$script:I18nText[$key][$Lang]
        if ($t) { return $t }
        return $Text
    }
    if ($key -match '^(.+) Earliest expires (.+)\.$') {
        $base = $matches[1]; $expiry = $matches[2]
        return (Convert-I18nString $base $Lang) + ((Convert-I18nString ' Earliest expires {0}.' $Lang) -f $expiry)
    }
    if ($key -match '^(.+) at (\d+)%(?: \(~(.+) min to limit\))?$') {
        $label = $matches[1]; $pct = $matches[2]; $mins = $matches[3]
        $body = (Convert-I18nString '{0} at {1}%' $Lang) -f (Convert-I18nString $label $Lang), $pct
        if ($mins) { $body += ((Convert-I18nString ' (~{0} min to limit)' $Lang) -f $mins) }
        return $body
    }
    foreach ($r in $script:I18nRules) {
        if ($key -match $r.rx) { return [regex]::Replace($key, $r.rx, [string]$r[$Lang]) }
    }
    return $Text
}

# Remembers the English source of each translated element, so switching back
# (or the code writing fresh English) always starts from the original.
function Get-I18nSource($Key, [string]$Current) {
    if ($script:I18nLast.ContainsKey($Key) -and [string]$script:I18nLast[$Key] -ceq $Current) { return [string]$script:I18nOrig[$Key] }
    return $Current
}

function Set-I18nMemo($Key, [string]$Source, [string]$Shown) {
    if ($Shown -cne $Source) { $script:I18nOrig[$Key] = $Source; $script:I18nLast[$Key] = $Shown }
    elseif ($script:I18nLast.ContainsKey($Key)) { [void]$script:I18nLast.Remove($Key); [void]$script:I18nOrig.Remove($Key) }
}

function Invoke-I18nTextBlock($Tb, [string]$Lang) {
    $inl = $Tb.Inlines
    if ($inl.Count -gt 1) {
        if ($Lang -eq 'en') { return }
        foreach ($run in @($inl)) {
            if ($run -isnot [System.Windows.Documents.Run]) { continue }
            $w = [string]$run.Text
            if ($script:I18nWords.ContainsKey($w)) { $run.Text = [string]$script:I18nWords[$w][$Lang] }
        }
        return
    }
    $cur = [string]$Tb.Text
    $src = Get-I18nSource $Tb $cur
    $new = Convert-I18nString $src $Lang
    if ($new -cne $cur) { $Tb.Text = $new }
    Set-I18nMemo $Tb $src $new
}

# Keep tooltip memo keys separate from the text on the same control. Store
# keys on the control rather than in a global table retaining dynamic menus.
function Invoke-I18nToolTip($Element, [string]$Lang, [string]$Property = 'ToolTip') {
    if (-not $Element.PSObject.Properties[$Property]) { return }
    if ($Element.$Property -isnot [string]) { return }
    $cur = [string]$Element.$Property
    $memoName = 'JayOSI18n' + $Property
    $memo = $Element.PSObject.Properties[$memoName]
    $src = $cur
    if ($memo -and $memo.Value.Shown -ceq $cur) { $src = $memo.Value.Source }
    $new = Convert-I18nString $src $Lang
    $Element.$Property = $new
    $Element | Add-Member -NotePropertyName $memoName -NotePropertyValue @{ Source = $src; Shown = $new } -Force
}

function Invoke-UiTranslate {
    if (-not $script:window -or -not $script:window.Content) { return }
    $lang = Get-UiLanguage
    if (-not $script:I18nBlocks -or $script:I18nBlocksWindow -ne $script:window) {
        $list = [System.Collections.Generic.List[object]]::new()
        $stack = New-Object System.Collections.Stack
        $stack.Push($script:window.Content)
        while ($stack.Count -gt 0) {
            $n = $stack.Pop()
            [void]$list.Add($n)
            if ($n -isnot [System.Windows.DependencyObject]) { continue }
            foreach ($c in [System.Windows.LogicalTreeHelper]::GetChildren($n)) { if ($c -is [System.Windows.DependencyObject]) { $stack.Push($c) } }
        }
        $script:I18nBlocks = $list
        $script:I18nBlocksWindow = $script:window
    }
    foreach ($tb in $script:I18nBlocks) {
        try { Invoke-I18nToolTip $tb $lang } catch { }
        if ($tb -is [System.Windows.Controls.TextBlock]) { try { Invoke-I18nTextBlock $tb $lang } catch { } }
    }
}

function Invoke-MenuTranslate($Items) {
    $lang = Get-UiLanguage
    foreach ($it in @($Items)) {
        if ($it -isnot [System.Windows.Forms.ToolStripItem] -or $it -is [System.Windows.Forms.ToolStripSeparator]) { continue }
        Invoke-I18nToolTip $it $lang 'ToolTipText'
        $cur = [string]$it.Text
        $src = Get-I18nSource $it $cur
        $plain = $src -replace '&&', '&'
        $tr = Convert-I18nString $plain $lang
        $new = if ($tr -ceq $plain) { $src } else { $tr -replace '&', '&&' }
        if ($new -cne $cur) { $it.Text = $new }
        Set-I18nMemo $it $src $new
        if ($it -is [System.Windows.Forms.ToolStripMenuItem]) {
            $sk = [string]$it.ShortcutKeyDisplayString
            if ($sk.Trim()) { $it.ShortcutKeyDisplayString = Convert-I18nString $sk $lang }
            if ($it.DropDownItems.Count -gt 0) { Invoke-MenuTranslate $it.DropDownItems }
        }
    }
}

function Set-UiLanguage([string]$Lang) {
    if (-not $script:I18nLangs.Contains($Lang)) { $Lang = 'en' }
    if ($script:Cfg) { $script:Cfg['Language'] = $Lang }
    try { Save-UnifiedState } catch { }
    Sync-UiLanguageTag
    Invoke-UiTranslate
    if ($script:ctxStrip) { Invoke-MenuTranslate $script:ctxStrip.Items }
    Sync-AppearanceMenus
    try { Update-NotchStageLayout } catch { }
}

# CJK glyphs come from font fallback; the xml:lang tag picks the right forms
# (Japanese vs Simplified Chinese).
function Sync-UiLanguageTag {
    if (-not $script:window) { return }
    $tag = switch (Get-UiLanguage) { 'zh' { 'zh-CN' } 'ja' { 'ja-JP' } 'fr' { 'fr-FR' } 'ko' { 'ko-KR' } default { 'en-US' } }
    try { $script:window.Language = [System.Windows.Markup.XmlLanguage]::GetLanguage($tag) } catch { }
}

# ---------------------------------------------------------------------------
# Panel background: a few quiet presets plus any custom colour. The top stays
# pure black so the notch still melts into the bezel.
# ---------------------------------------------------------------------------
# Dark enough for white text, but each with a clear tint so they read apart.
$script:PanelBgPresets = [ordered]@{
    'Graphite' = '#1A1A1E'; 'Pure black' = '#050505'; 'Warm gray' = '#28231E'; 'Slate' = '#1B2330'
    'Forest' = '#14281D'; 'Navy' = '#121F3A'; 'Plum' = '#261838'; 'Wine' = '#33151C'
}
# Earlier, near-identical versions of the same presets map to the new ones.
$script:PanelBgLegacy = @{ '#17171A' = '#1A1A1E'; '#060606' = '#050505'; '#1D1B19' = '#28231E'; '#171A1F' = '#1B2330'; '#111814' = '#14281D' }

function Get-PanelBgHex {
    $h = if ($script:Cfg) { [string]$script:Cfg['PanelBg'] } else { '' }
    if ($h -match '^#[0-9A-Fa-f]{6}$') {
        $h = $h.ToUpperInvariant()
        if ($script:PanelBgLegacy.ContainsKey($h)) { return $script:PanelBgLegacy[$h] }
        return $h
    }
    return '#1A1A1E'
}

function Set-NotchBackdropColor([string]$Hex) {
    if (-not $script:NotchBackdrop) { return }
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
    $black = [System.Windows.Media.Color]::FromRgb(0, 0, 0)
    $b = New-Object System.Windows.Media.LinearGradientBrush
    $b.MappingMode = [System.Windows.Media.BrushMappingMode]::Absolute
    $b.StartPoint = [System.Windows.Point]::new(0, 0)
    $b.EndPoint = [System.Windows.Point]::new(0, 420)
    [void]$b.GradientStops.Add((New-Object System.Windows.Media.GradientStop($black, 0.0)))
    [void]$b.GradientStops.Add((New-Object System.Windows.Media.GradientStop($black, 0.07)))
    [void]$b.GradientStops.Add((New-Object System.Windows.Media.GradientStop($c, 0.24)))
    [void]$b.GradientStops.Add((New-Object System.Windows.Media.GradientStop($c, 1.0)))
    $b.Freeze()
    $script:NotchBackdrop.Background = $b
}

function Set-PanelBackground([string]$Hex) {
    if ($script:Cfg) { $script:Cfg['PanelBg'] = $Hex }
    try { Save-UnifiedState } catch { }
    Set-NotchBackdropColor $Hex
    Sync-AppearanceMenus
}

# Custom background colour: a dark picker in the panel's own style. Drag in
# the square (saturation / brightness) and along the hue strip, type a hex
# code, or pick a preset or a recent colour. The panel previews every change;
# Apply keeps it, Cancel / Esc puts the saved colour back. Light picks are
# darkened so the white text stays readable - the tile shows the real result.
$script:ColorPicker = $null
$script:CpH = 0.0; $script:CpS = 0.0; $script:CpV = 0.0
$script:CpSyncing = $false

function ConvertTo-CpRgb([double]$H, [double]$S, [double]$V) {
    $h = (($H % 360) + 360) % 360 / 60.0
    $i = [math]::Floor($h); $f = $h - $i
    $p = $V * (1 - $S); $q = $V * (1 - $S * $f); $t = $V * (1 - $S * (1 - $f))
    $rgb = switch ([int]$i) { 0 { $V, $t, $p } 1 { $q, $V, $p } 2 { $p, $V, $t } 3 { $p, $q, $V } 4 { $t, $p, $V } default { $V, $p, $q } }
    return @([int][math]::Round($rgb[0] * 255), [int][math]::Round($rgb[1] * 255), [int][math]::Round($rgb[2] * 255))
}

function ConvertFrom-CpHex([string]$Hex) {
    $c = [System.Drawing.ColorTranslator]::FromHtml($Hex)
    $r = $c.R / 255.0; $g = $c.G / 255.0; $b = $c.B / 255.0
    $max = [math]::Max($r, [math]::Max($g, $b)); $min = [math]::Min($r, [math]::Min($g, $b)); $d = $max - $min
    $h = 0.0
    if ($d -gt 0) {
        if ($max -eq $r) { $h = 60 * ((($g - $b) / $d) % 6) }
        elseif ($max -eq $g) { $h = 60 * ((($b - $r) / $d) + 2) }
        else { $h = 60 * ((($r - $g) / $d) + 4) }
    }
    if ($h -lt 0) { $h += 360 }
    $s = if ($max -gt 0) { $d / $max } else { 0 }
    return @($h, $s, $max)
}

# Same rule as before: cap the luminance so white text stays legible.
function Get-CpPanelHex([int]$R, [int]$G, [int]$B) {
    $r = [double]$R; $g = [double]$G; $bl = [double]$B
    $lum = (0.2126 * $r + 0.7152 * $g + 0.0722 * $bl) / 255.0
    if ($lum -gt 0.28) { $k = 0.28 / $lum; $r *= $k; $g *= $k; $bl *= $k }
    return ('#{0:X2}{1:X2}{2:X2}' -f [int]$r, [int]$g, [int]$bl)
}

function Get-CpRecent {
    $raw = if ($script:Cfg) { [string]$script:Cfg['PanelBgRecent'] } else { '' }
    return @($raw -split ',' | Where-Object { $_ -match '^#[0-9A-Fa-f]{6}$' } | Select-Object -First 8)
}

function Add-CpRecent([string]$Hex) {
    if (-not $script:Cfg) { return }
    if (@($script:PanelBgPresets.Values) -contains $Hex) { return }
    $list = @($Hex) + @(Get-CpRecent | Where-Object { $_ -ne $Hex })
    $script:Cfg['PanelBgRecent'] = (@($list | Select-Object -First 8) -join ',')
}

# Brightness runs from black to the brightest version of the colour the panel
# allows (Get-CpPanelHex), so the whole slider changes the result - there is no
# stretch at the top that gets darkened back to the same colour.
function Get-CpCap([double]$H, [double]$S) {
    $top = ConvertTo-CpRgb $H $S 1
    $lum = (0.2126 * $top[0] + 0.7152 * $top[1] + 0.0722 * $top[2]) / 255.0
    if ($lum -gt 0.28) { return (0.28 / $lum) }
    return 1.0
}
function Get-CpFinalHex([double]$H, [double]$S, [double]$V) {
    $rgb = ConvertTo-CpRgb $H $S ([math]::Max(0.0, [math]::Min(1.0, $V)) * (Get-CpCap $H $S))
    return ('#{0:X2}{1:X2}{2:X2}' -f $rgb[0], $rgb[1], $rgb[2])
}

# The square shows the colours the panel will really use at each saturation
# (left to right) and brightness (bottom to top) for the chosen hue.
$script:CpFieldHue = -1.0
$script:CpFieldBitmap = $null
function Update-CpField($w) {
    if (-not ('JayOSColorField' -as [type])) {
        Add-Type -TypeDefinition @'
public static class JayOSColorField {
    static void Hsv(double h, double s, double v, out double r, out double g, out double b) {
        h = ((h % 360) + 360) % 360 / 60.0;
        int i = (int)System.Math.Floor(h); double f = h - i;
        double p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f));
        switch (i) { case 0: r = v; g = t; b = p; break; case 1: r = q; g = v; b = p; break;
                     case 2: r = p; g = v; b = t; break; case 3: r = p; g = q; b = v; break;
                     case 4: r = t; g = p; b = v; break; default: r = v; g = p; b = q; break; }
    }
    public static byte[] Render(double hue, int w, int h, double maxLum) {
        byte[] px = new byte[w * h * 4];
        for (int x = 0; x < w; x++) {
            double s = (double)x / (w - 1), r1, g1, b1;
            Hsv(hue, s, 1, out r1, out g1, out b1);
            double lum = 0.2126 * r1 + 0.7152 * g1 + 0.0722 * b1;
            double cap = lum > maxLum ? maxLum / lum : 1.0;
            for (int y = 0; y < h; y++) {
                double k = (1.0 - (double)y / (h - 1)) * cap;
                int o = (y * w + x) * 4;
                px[o] = (byte)System.Math.Round(b1 * k * 255); px[o + 1] = (byte)System.Math.Round(g1 * k * 255);
                px[o + 2] = (byte)System.Math.Round(r1 * k * 255); px[o + 3] = 255;
            }
        }
        return px;
    }
}
'@
    }
    $fw = 274; $fh = 160
    if (-not $script:CpFieldBitmap) {
        $script:CpFieldBitmap = New-Object System.Windows.Media.Imaging.WriteableBitmap($fw, $fh, 96, 96, [System.Windows.Media.PixelFormats]::Bgra32, $null)
    }
    $px = [JayOSColorField]::Render($script:CpH, $fw, $fh, 0.28)
    $script:CpFieldBitmap.WritePixels((New-Object System.Windows.Int32Rect(0, 0, $fw, $fh)), $px, $fw * 4, 0)
    $w.FindName('cpSvImage').Source = $script:CpFieldBitmap
}

function Update-ColorPicker([switch]$FromHex) {
    $w = $script:ColorPicker
    if (-not $w) { return }
    $rgb = ConvertTo-CpRgb $script:CpH $script:CpS $script:CpV
    $pick = '#{0:X2}{1:X2}{2:X2}' -f $rgb[0], $rgb[1], $rgb[2]
    $final = Get-CpFinalHex $script:CpH $script:CpS $script:CpV
    $brightest = Get-CpFinalHex $script:CpH $script:CpS 1
    $w.FindName('cpBriTrack').Background = New-GradientBrush '#000000' $brightest
    $bt = $w.FindName('cpBri')
    $bth = $w.FindName('cpBriThumb')
    [System.Windows.Controls.Canvas]::SetLeft($bth, $script:CpV * $bt.Width - 8)
    $bth.Fill = NewBrush $final
    $w.FindName('cpBriValue').Text = ('{0:0}%' -f ($script:CpV * 100))
    $hue = ConvertTo-CpRgb $script:CpH 1 1
    if ($script:CpFieldHue -ne $script:CpH) { Update-CpField $w; $script:CpFieldHue = $script:CpH }
    $sv = $w.FindName('cpSv'); $ht = $w.FindName('cpHue')
    $th = $w.FindName('cpSvThumb'); $hth = $w.FindName('cpHueThumb')
    [System.Windows.Controls.Canvas]::SetLeft($th, $script:CpS * $sv.Width - 8)
    [System.Windows.Controls.Canvas]::SetTop($th, (1 - $script:CpV) * $sv.Height - 8)
    $th.Fill = NewBrush $final
    [System.Windows.Controls.Canvas]::SetLeft($hth, $script:CpH / 360.0 * $ht.Width - 8)
    $hth.Fill = NewBrush ('#{0:X2}{1:X2}{2:X2}' -f $hue[0], $hue[1], $hue[2])
    # The tile shows the panel as it will look: black at the top, then the colour.
    $tile = New-Object System.Windows.Media.LinearGradientBrush
    $tile.StartPoint = [System.Windows.Point]::new(0, 0); $tile.EndPoint = [System.Windows.Point]::new(0, 1)
    $fc = [System.Windows.Media.ColorConverter]::ConvertFromString($final)
    [void]$tile.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Colors]::Black, 0.0)))
    [void]$tile.GradientStops.Add((New-Object System.Windows.Media.GradientStop($fc, 0.45)))
    [void]$tile.GradientStops.Add((New-Object System.Windows.Media.GradientStop($fc, 1.0)))
    $w.FindName('cpTile').Background = $tile
    if (-not $FromHex) {
        $script:CpSyncing = $true
        $box = $w.FindName('cpHex'); $box.Text = $final; $box.CaretIndex = $box.Text.Length
        $script:CpSyncing = $false
    }
    $script:CpFinal = $final
    try { Set-NotchBackdropColor $final } catch { }
}

function Set-CpFromHex([string]$Hex, [switch]$FromHex) {
    if ($Hex -notmatch '^#?[0-9A-Fa-f]{6}$') { return }
    if (-not $Hex.StartsWith('#')) { $Hex = '#' + $Hex }
    $hsv = ConvertFrom-CpHex $Hex
    $script:CpH = $hsv[0]; $script:CpS = $hsv[1]
    # Where this colour sits on the brightness slider (too bright: the top).
    $script:CpV = [math]::Min(1.0, $hsv[2] / (Get-CpCap $hsv[0] $hsv[1]))
    Update-ColorPicker -FromHex:$FromHex
}

function Close-ColorPicker([switch]$Apply) {
    $w = $script:ColorPicker
    if (-not $w) { return }
    $script:ColorPicker = $null
    if ($Apply -and $script:CpFinal) {
        Add-CpRecent $script:CpFinal
        Set-PanelBackground $script:CpFinal
    } else {
        try { Set-NotchBackdropColor (Get-PanelBgHex) } catch { }
    }
    try { $w.Close() } catch { }
}

function New-CpSwatch([string]$Hex, [string]$Tip) {
    $b = New-Object System.Windows.Controls.Border
    $b.Width = 26; $b.Height = 26; $b.CornerRadius = 7; $b.Margin = '0,0,8,8'
    $b.Cursor = [System.Windows.Input.Cursors]::Hand
    $c = [System.Drawing.ColorTranslator]::FromHtml($Hex)
    $lift = '#{0:X2}{1:X2}{2:X2}' -f [math]::Min(255, [int]($c.R * 1.6 + 6)), [math]::Min(255, [int]($c.G * 1.6 + 6)), [math]::Min(255, [int]($c.B * 1.6 + 6))
    $g = New-Object System.Windows.Media.LinearGradientBrush
    $g.StartPoint = [System.Windows.Point]::new(0, 0); $g.EndPoint = [System.Windows.Point]::new(0, 1)
    [void]$g.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.ColorConverter]::ConvertFromString($Hex), 0.0)))
    [void]$g.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.ColorConverter]::ConvertFromString($lift), 1.0)))
    $b.Background = $g
    $b.BorderBrush = NewBrush '#55FFFFFF'; $b.BorderThickness = 1
    $b.ToolTip = $Tip
    $b.Tag = $Hex
    $b.add_MouseLeftButtonUp({ param($s, $e) Set-CpFromHex ([string]$s.Tag) })
    $b.add_MouseEnter({ param($s, $e) $s.BorderBrush = NewBrush '#F5F5F7' })
    $b.add_MouseLeave({ param($s, $e) $s.BorderBrush = NewBrush '#55FFFFFF' })
    return $b
}

function Invoke-CpPick($Sender, $E, [string]$Kind) {
    $p = $E.GetPosition($Sender)
    if ($Kind -eq 'sv') {
        $script:CpS = [math]::Max(0.0, [math]::Min(1.0, $p.X / $Sender.Width))
        $script:CpV = [math]::Max(0.0, [math]::Min(1.0, 1 - $p.Y / $Sender.Height))
    } elseif ($Kind -eq 'bri') {
        $script:CpV = [math]::Max(0.0, [math]::Min(1.0, $p.X / $Sender.Width))
    } else {
        $script:CpH = [math]::Max(0.0, [math]::Min(359.9, $p.X / $Sender.Width * 360.0))
    }
    Update-ColorPicker
}

function Get-CpText([string]$Text) {
    try { return (Convert-I18nString $Text (Get-UiLanguage)) } catch { return $Text }
}

# Coordinates are DIPs in the panel monitor's work area (Get-WorkArea).
function Get-CpPickerPosition($Area, $PanelRect, $Size) {
    $width = [math]::Min([double]$Size.Width, $Area.Right - $Area.Left)
    $height = [math]::Min([double]$Size.Height, $Area.Bottom - $Area.Top)
    $left = $Area.Left + ($Area.Right - $Area.Left - $width) / 2
    $right = $PanelRect.Left + $PanelRect.Width + 4
    if ($right + $width -le $Area.Right) { $left = $right }
    elseif ($PanelRect.Left - $width - 4 -ge $Area.Left) { $left = $PanelRect.Left - $width - 4 }
    return @{
        Left = [math]::Max($Area.Left, [math]::Min($left, $Area.Right - $width))
        Top = [math]::Max($Area.Top, [math]::Min($PanelRect.Top, $Area.Bottom - $height))
        Width = $width; Height = $height
    }
}

function Invoke-CustomPanelBackground {
    if ($script:ColorPicker) { try { $script:ColorPicker.Activate() } catch { }; return }
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        SizeToContent="WidthAndHeight" Topmost="True" ShowInTaskbar="False" FontFamily="Segoe UI">
  <Border Margin="14" Padding="18,14,18,16" CornerRadius="16" Background="#F21C1C1F" BorderBrush="#3A3A3D" BorderThickness="1">
    <Border.Effect><DropShadowEffect BlurRadius="24" ShadowDepth="4" Opacity="0.55" Color="#000000"/></Border.Effect>
    <StackPanel Width="276">
      <DockPanel x:Name="cpTitleRow" Background="Transparent" Margin="0,0,0,12">
        <Border x:Name="cpClose" DockPanel.Dock="Right" Width="22" Height="22" CornerRadius="11" Background="#2C2C2E" Cursor="Hand">
          <TextBlock Text="&#x2715;" FontSize="10" Foreground="#A1A1A6" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <TextBlock x:Name="cpTitle" FontSize="14" FontWeight="SemiBold" Foreground="#F5F5F7" VerticalAlignment="Center"/>
      </DockPanel>
      <Border CornerRadius="10" ClipToBounds="True" BorderBrush="#33FFFFFF" BorderThickness="1">
        <Grid x:Name="cpSvHost" Width="274" Height="160" Cursor="Cross" Background="Transparent">
          <Grid.Clip><RectangleGeometry Rect="0,0,274,160" RadiusX="9" RadiusY="9"/></Grid.Clip>
          <Image x:Name="cpSvImage" Stretch="Fill"/>
          <Canvas x:Name="cpSv" Width="274" Height="160" Background="Transparent">
            <Ellipse x:Name="cpSvThumb" Width="16" Height="16" Stroke="#FFFFFF" StrokeThickness="2.5" IsHitTestVisible="False">
              <Ellipse.Effect><DropShadowEffect BlurRadius="4" ShadowDepth="0" Opacity="0.8"/></Ellipse.Effect>
            </Ellipse>
          </Canvas>
        </Grid>
      </Border>
      <TextBlock x:Name="cpHueLabel" Margin="0,14,0,6" FontSize="11" FontWeight="SemiBold" Foreground="#8E8E93"/>
      <Grid Height="16" Cursor="Hand">
        <Border CornerRadius="6" Height="12" VerticalAlignment="Center">
          <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
            <GradientStop Color="#FF0000" Offset="0"/><GradientStop Color="#FFFF00" Offset="0.1667"/><GradientStop Color="#00FF00" Offset="0.3333"/>
            <GradientStop Color="#00FFFF" Offset="0.5"/><GradientStop Color="#0000FF" Offset="0.6667"/><GradientStop Color="#FF00FF" Offset="0.8333"/><GradientStop Color="#FF0000" Offset="1"/>
          </LinearGradientBrush></Border.Background>
        </Border>
        <Canvas x:Name="cpHue" Width="274" Height="16" Background="Transparent">
          <Ellipse x:Name="cpHueThumb" Width="16" Height="16" Stroke="#FFFFFF" StrokeThickness="2.5" IsHitTestVisible="False">
            <Ellipse.Effect><DropShadowEffect BlurRadius="4" ShadowDepth="0" Opacity="0.8"/></Ellipse.Effect>
          </Ellipse>
        </Canvas>
      </Grid>
      <DockPanel Margin="0,12,0,6">
        <TextBlock x:Name="cpBriValue" DockPanel.Dock="Right" FontSize="11" FontWeight="SemiBold" Foreground="#C7C7CC"/>
        <TextBlock x:Name="cpBriLabel" FontSize="11" FontWeight="SemiBold" Foreground="#8E8E93"/>
      </DockPanel>
      <Grid Height="16" Cursor="Hand">
        <Border x:Name="cpBriTrack" CornerRadius="6" Height="12" VerticalAlignment="Center" BorderBrush="#33FFFFFF" BorderThickness="1"/>
        <Canvas x:Name="cpBri" Width="274" Height="16" Background="Transparent">
          <Ellipse x:Name="cpBriThumb" Width="16" Height="16" Stroke="#FFFFFF" StrokeThickness="2.5" IsHitTestVisible="False">
            <Ellipse.Effect><DropShadowEffect BlurRadius="4" ShadowDepth="0" Opacity="0.8"/></Ellipse.Effect>
          </Ellipse>
        </Canvas>
      </Grid>
      <Grid Margin="0,16,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Border x:Name="cpTile" Width="54" Height="54" CornerRadius="12" BorderBrush="#44FFFFFF" BorderThickness="1"/>
        <StackPanel Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center">
          <Border CornerRadius="8" Background="#2C2C2E" BorderBrush="#3A3A3D" BorderThickness="1" Padding="8,3">
            <DockPanel>
              <TextBox x:Name="cpHex" Background="Transparent" BorderThickness="0" Foreground="#F5F5F7" CaretBrush="#F5F5F7"
                       FontFamily="Consolas" FontSize="13" MaxLength="7" VerticalContentAlignment="Center"/>
            </DockPanel>
          </Border>
          <TextBlock x:Name="cpHint" Margin="2,6,0,0" FontSize="11" Foreground="#8E8E93" TextWrapping="Wrap"/>
        </StackPanel>
      </Grid>
      <TextBlock x:Name="cpPresetsLabel" Margin="0,16,0,8" FontSize="11" FontWeight="SemiBold" Foreground="#8E8E93"/>
      <WrapPanel x:Name="cpPresets"/>
      <TextBlock x:Name="cpRecentLabel" Margin="0,6,0,8" FontSize="11" FontWeight="SemiBold" Foreground="#8E8E93"/>
      <WrapPanel x:Name="cpRecent"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
        <Border x:Name="cpCancel" CornerRadius="9" Background="#2C2C2E" Padding="16,7" Margin="0,0,8,0" Cursor="Hand">
          <TextBlock x:Name="cpCancelText" FontSize="12.5" Foreground="#F5F5F7" FontWeight="SemiBold"/>
        </Border>
        <Border x:Name="cpApply" CornerRadius="9" Background="#0A84FF" Padding="18,7" Cursor="Hand">
          <TextBlock x:Name="cpApplyText" FontSize="12.5" Foreground="#FFFFFF" FontWeight="SemiBold"/>
        </Border>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
"@
    $w = [System.Windows.Markup.XamlReader]::Parse($xaml)
    $script:ColorPicker = $w
    $script:CpFieldHue = -1.0; $script:CpFieldBitmap = $null
    $w.FindName('cpTitle').Text = Get-CpText 'Custom background colour'
    $w.FindName('cpPresetsLabel').Text = Get-CpText 'Presets'
    $w.FindName('cpHueLabel').Text = Get-CpText 'Hue'
    $w.FindName('cpBriLabel').Text = Get-CpText 'Brightness'
    $w.FindName('cpRecentLabel').Text = Get-CpText 'Recent'
    $w.FindName('cpCancelText').Text = Get-CpText 'Cancel'
    $w.FindName('cpApplyText').Text = Get-CpText 'Apply'
    $w.FindName('cpHint').Text = Get-CpText 'Every colour here keeps the text readable.'

    foreach ($pair in $script:PanelBgPresets.GetEnumerator()) {
        [void]$w.FindName('cpPresets').Children.Add((New-CpSwatch ([string]$pair.Value) (Get-CpText ([string]$pair.Key))))
    }
    $recent = @(Get-CpRecent)
    foreach ($hex in $recent) { [void]$w.FindName('cpRecent').Children.Add((New-CpSwatch $hex $hex)) }
    if ($recent.Count -eq 0) {
        $w.FindName('cpRecentLabel').Visibility = 'Collapsed'; $w.FindName('cpRecent').Visibility = 'Collapsed'
    }

    # Dragging in the square and along the hue strip.
    $sv = $w.FindName('cpSv'); $hue = $w.FindName('cpHue')
    $sv.add_MouseLeftButtonDown({ param($s, $e) [void]$s.CaptureMouse(); Invoke-CpPick $s $e 'sv' })
    $sv.add_MouseMove({ param($s, $e) if ($s.IsMouseCaptured) { Invoke-CpPick $s $e 'sv' } })
    $sv.add_MouseLeftButtonUp({ param($s, $e) $s.ReleaseMouseCapture() })
    $hue.add_MouseLeftButtonDown({ param($s, $e) [void]$s.CaptureMouse(); Invoke-CpPick $s $e 'hue' })
    $hue.add_MouseMove({ param($s, $e) if ($s.IsMouseCaptured) { Invoke-CpPick $s $e 'hue' } })
    $hue.add_MouseLeftButtonUp({ param($s, $e) $s.ReleaseMouseCapture() })
    $bri = $w.FindName('cpBri')
    $bri.add_MouseLeftButtonDown({ param($s, $e) [void]$s.CaptureMouse(); Invoke-CpPick $s $e 'bri' })
    $bri.add_MouseMove({ param($s, $e) if ($s.IsMouseCaptured) { Invoke-CpPick $s $e 'bri' } })
    $bri.add_MouseLeftButtonUp({ param($s, $e) $s.ReleaseMouseCapture() })
    # The mouse wheel nudges brightness anywhere on the picker's colour area.
    $w.add_MouseWheel({
        param($s, $e)
        $script:CpV = [math]::Max(0.0, [math]::Min(1.0, $script:CpV + [math]::Sign($e.Delta) * 0.02))
        Update-ColorPicker
    })
    $w.FindName('cpHex').add_TextChanged({
        if ($script:CpSyncing) { return }
        $t = [string]$script:ColorPicker.FindName('cpHex').Text
        if ($t -match '^#?[0-9A-Fa-f]{6}$') { Set-CpFromHex $t -FromHex }
    })
    $w.FindName('cpTitleRow').add_MouseLeftButtonDown({ try { $script:ColorPicker.DragMove() } catch { } })
    # Down, not up: the title row would start a drag first.
    $w.FindName('cpClose').add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; Close-ColorPicker })
    $w.FindName('cpCancel').add_MouseLeftButtonUp({ Close-ColorPicker })
    $w.FindName('cpApply').add_MouseLeftButtonUp({ Close-ColorPicker -Apply })
    foreach ($n in 'cpCancel', 'cpApply', 'cpClose') {
        $btn = $w.FindName($n)
        $btn.add_MouseEnter({ param($s, $e) $s.Opacity = 0.85 })
        $btn.add_MouseLeave({ param($s, $e) $s.Opacity = 1.0 })
    }
    $w.add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'Escape') { Close-ColorPicker; $e.Handled = $true }
        elseif ($e.Key -eq 'Return') { Close-ColorPicker -Apply; $e.Handled = $true }
    })
    $w.add_Closed({ if ($script:ColorPicker) { $script:ColorPicker = $null; try { Set-NotchBackdropColor (Get-PanelBgHex) } catch { } } })

    # Beside the panel when there is room, otherwise centred on its screen.
    $w.WindowStartupLocation = 'Manual'
    $area = Get-WorkArea
    $mw = $script:window
    $w.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
    $pos = Get-CpPickerPosition $area @{ Left = $mw.Left; Top = $mw.Top; Width = $mw.ActualWidth } $w.DesiredSize
    $w.SizeToContent = 'Manual'
    $w.Left = $pos.Left; $w.Top = $pos.Top
    # On a small/high-DPI monitor keep the dialog inside the work area too.
    $w.Width = $pos.Width; $w.Height = $pos.Height

    Set-CpFromHex (Get-PanelBgHex)
    $w.Show()
    [void]$w.Activate()
    [void]$w.FindName('cpHex').Focus()
}

function New-RoundRectPath([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $R * 2
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $p.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
    $p.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

# Background colour row: a little tile in that colour (black at the top like the
# real panel), outlined so even the near-black ones read apart.
function New-SwatchBitmap([string]$Hex) {
    $px = if ($script:MenuIconPx) { [int]$script:MenuIconPx } else { 18 }
    $bmp = New-Object System.Drawing.Bitmap($px, $px)
    $gr = [System.Drawing.Graphics]::FromImage($bmp)
    $gr.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $c = [System.Drawing.ColorTranslator]::FromHtml($Hex)
    $path = New-RoundRectPath 0.5 0.5 ($px - 1.5) ($px - 1.5) ([single]($px / 4.5))
    $rect = New-Object System.Drawing.RectangleF(0, 0, $px, $px)
    # Show the colour a touch brighter than it renders so tints are visible.
    $lift = [System.Drawing.Color]::FromArgb([math]::Min(255, [int]($c.R * 1.6 + 6)), [math]::Min(255, [int]($c.G * 1.6 + 6)), [math]::Min(255, [int]($c.B * 1.6 + 6)))
    $fill = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $c, $lift, 90.0)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(150, 255, 255, 255), 1.0)
    $gr.FillPath($fill, $path)
    $gr.DrawPath($pen, $path)
    $fill.Dispose(); $pen.Dispose(); $path.Dispose(); $gr.Dispose()
    return $bmp
}

# Theme row: a miniature panel - the theme's background with its three meter
# colours - so you can see the palette before picking it.
function New-ThemeSwatchBitmap([string]$Name) {
    $t = $script:Themes[$Name]
    $px = if ($script:MenuIconPx) { [int]$script:MenuIconPx } else { 18 }
    $bmp = New-Object System.Drawing.Bitmap($px, $px)
    if (-not $t) { return $bmp }
    $gr = [System.Drawing.Graphics]::FromImage($bmp)
    $gr.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $path = New-RoundRectPath 0.5 0.5 ($px - 1.5) ($px - 1.5) ([single]($px / 4.5))
    $bg = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml([string]$t.BgC1))
    $gr.FillPath($bg, $path)
    $cols = @()
    foreach ($k in 'FivehColors', 'WeekColors', 'FabColors') {
        $v = @($t[$k])
        $cols += $(if ($v.Count -gt 1) { [string]$v[1] } elseif ($v.Count -eq 1) { [string]$v[0] } else { '#C7C7CC' })
    }
    $barH = [single][math]::Max(2.0, $px / 7.0)
    $gap = [single](($px - 3 * $barH) / 4.0)
    $lens = @(0.72, 0.5, 0.86)
    for ($i = 0; $i -lt 3; $i++) {
        $b = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml($cols[$i]))
        $y = $gap + $i * ($barH + $gap)
        $w = ($px - 6) * $lens[$i]
        $bar = New-RoundRectPath 3 $y $w $barH ([single]($barH / 2.0))
        $gr.FillPath($b, $bar)
        $b.Dispose(); $bar.Dispose()
    }
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(150, 255, 255, 255), 1.0)
    $gr.DrawPath($pen, $path)
    $bg.Dispose(); $pen.Dispose(); $path.Dispose(); $gr.Dispose()
    return $bmp
}

# Hovering a theme previews it on the open panel; leaving the list (or closing
# the menu) goes back to the saved one. Applied on a short delay so sweeping
# across the list stays smooth.
$script:ThemePreviewShown = $null
$script:ThemePreviewWanted = $null
$script:ThemePreviewTimer = $null
function Invoke-ThemePreview([string]$Name) {
    if (-not $Name) { $Name = [string]$script:Cfg.Theme }
    $script:ThemePreviewWanted = $Name
    if (-not $script:ThemePreviewTimer) {
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromMilliseconds(70)
        $t.add_Tick({
            param($s, $e)
            $s.Stop()
            $want = [string]$script:ThemePreviewWanted
            if (-not $want -or $want -eq [string]$script:ThemePreviewShown) { return }
            try { Apply-UnifiedTheme $want; $script:ThemePreviewShown = $want; Update-AllSections } catch { }
        })
        $script:ThemePreviewTimer = $t
    }
    $script:ThemePreviewTimer.Stop()
    $script:ThemePreviewTimer.Start()
}

function Sync-AppearanceMenus {
    $hex = Get-PanelBgHex
    $isPreset = $false
    if ($script:bgItems) {
        foreach ($k in @($script:bgItems.Keys)) {
            $it = $script:bgItems[$k]
            if (-not $it.Image) { try { $it.Image = New-SwatchBitmap $k } catch { } }
            $it.Tag = 'swatch'
            $it.Checked = ($k -eq $hex)
            if ($it.Checked) { $isPreset = $true }
        }
    }
    if ($script:bgCustomItem) {
        $script:bgCustomItem.Checked = -not $isPreset
        $script:bgCustomItem.Tag = 'swatch-action'
        try { $script:bgCustomItem.Image = New-SwatchBitmap $hex } catch { }
    }
    if ($script:themeItems) {
        foreach ($k in @($script:themeItems.Keys)) {
            $it = $script:themeItems[$k]
            if (-not $it.Image -or [string]$it.Tag -ne 'swatch') { try { $it.Image = New-ThemeSwatchBitmap $k } catch { } }
            $it.Tag = 'swatch'
            $it.Checked = ($k -eq [string]$script:Cfg.Theme)
        }
    }
    if ($script:langItems) {
        $lang = Get-UiLanguage
        foreach ($k in @($script:langItems.Keys)) { $script:langItems[$k].Checked = ($k -eq $lang) }
    }
}

# Bright status colours on the stat icons (the labels and values stay neutral).
$script:StatIconColors = @{
    'Account' = '#30D158'; 'Est. Cost' = '#FFD60A'; 'Tokens' = '#64D2FF'; 'Today' = '#30D158'
    'After Hrs' = '#FF9F0A'; 'Lifetime' = '#FF6961'; 'Overage' = '#FF9F0A'; 'Usage' = '#64D2FF'
    'Edits' = '#FFD60A'; 'Lines' = '#64D2FF'; 'Prepaid' = '#30D158'; 'Plan' = '#FFD60A'
}
function Set-StatIconColors {
    if (-not $script:window -or -not $script:window.Content) { return }
    $statStyle = $script:window.TryFindResource('StatIcon')
    if (-not $statStyle) { return }
    $stack = New-Object System.Collections.Stack
    $stack.Push($script:window.Content)
    while ($stack.Count -gt 0) {
        $n = $stack.Pop()
        if ($n -is [System.Windows.Shapes.Path] -and $n.Style -eq $statStyle) {
            $parent = [System.Windows.LogicalTreeHelper]::GetParent($n)
            if ($parent) {
                foreach ($c in [System.Windows.LogicalTreeHelper]::GetChildren($parent)) {
                    if ($c -is [System.Windows.Controls.TextBlock]) {
                        $label = Get-I18nSource $c ([string]$c.Text)
                        if ($script:StatIconColors.ContainsKey($label)) { $n.Stroke = NewBrush $script:StatIconColors[$label] }
                        break
                    }
                }
            }
            continue
        }
        if ($n -isnot [System.Windows.DependencyObject]) { continue }
        foreach ($c in [System.Windows.LogicalTreeHelper]::GetChildren($n)) { if ($c -is [System.Windows.DependencyObject]) { $stack.Push($c) } }
    }
}

function Start-RefreshSpin {
    if (-not $script:window) { return }
    $rt = $script:window.FindName('chromeRefreshSpin')
    if (-not $rt) { return }
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, 360.0, [System.Windows.Duration]([TimeSpan]::FromMilliseconds(750)))
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseInOut
    $a.EasingFunction = $ease
    $rt.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $a)
}

# ---------------------------------------------------------------------------
# Open a provider's own app from its card icon: the installed Store/MSIX app,
# else the desktop .exe, else its CLI in a terminal, else its website.
# ---------------------------------------------------------------------------
$script:ProviderWebsites = @{
    claude = 'https://claude.ai/'
    codex  = 'https://chatgpt.com/codex'
    cursor = 'https://cursor.com/'
    grok   = 'https://grok.com/'
}

function Get-ProviderPackageAppId([string]$Key) {
    $meta = $script:ProviderMeta[$Key]
    if (-not $meta) { return $null }
    $reg = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages'
    if (-not (Test-Path $reg)) { return $null }
    $pkg = Get-ChildItem $reg -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match $meta.Packages } | Select-Object -First 1
    if (-not $pkg) { return $null }
    # PackageFullName = Name_Version_Arch_ResourceId_PublisherId; the family
    # name used by shell:AppsFolder is Name_PublisherId.
    $parts = ([string]$pkg.PSChildName).Split('_')
    if ($parts.Count -lt 2) { return $null }
    $family = $parts[0] + '_' + $parts[$parts.Count - 1]
    $appId = 'App'
    $root = (Get-ItemProperty -LiteralPath $pkg.PSPath -ErrorAction SilentlyContinue).PackageRootFolder
    if ($root) {
        $manifest = Join-Path $root 'AppxManifest.xml'
        if (Test-Path -LiteralPath $manifest) {
            $m = [regex]::Match([System.IO.File]::ReadAllText($manifest), '<Application\b[^>]*\sId="([^"]+)"')
            if ($m.Success) { $appId = $m.Groups[1].Value }
        }
    }
    return ($family + '!' + $appId)
}

function Open-ProviderApp([string]$Key) {
    try {
        $aumid = Get-ProviderPackageAppId $Key
        if ($aumid) {
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('shell:AppsFolder\' + $aumid)
            return
        }
        $meta = $script:ProviderMeta[$Key]
        if ($meta) {
            foreach ($raw in $meta.Exes) {
                $exe = [Environment]::ExpandEnvironmentVariables($raw)
                if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe; return }
            }
        }
        # A CLI-only tool: open it in a terminal.
        if ($Key -ne 'cursor' -and (Get-Command Resolve-ProviderLoginCli -ErrorAction SilentlyContinue)) {
            $cli = Resolve-ProviderLoginCli $Key
            if ($cli -and $cli.Path) {
                $shell = (Get-Process -Id $PID).Path
                if (-not $shell) { $shell = 'powershell.exe' }
                $cmd = "`$Host.UI.RawUI.WindowTitle = '$($meta.Name)'; & '$(([string]$cli.Path) -replace "'", "''")'"
                $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
                Start-Process -FilePath $shell -ArgumentList @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
                return
            }
        }
        $url = $script:ProviderWebsites[$Key]
        if ($url) { Start-Process $url }
    } catch {
        Write-NotchLog "open app $Key : $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Card accordion (notch panel): one provider's details open at a time. The
# panel opens on the first card; the mouse wheel steps through the others,
# and clicking a card's header opens (or closes) that one.
# ---------------------------------------------------------------------------
$script:AccordionKey = $null
$script:AccordionWheelClock = [System.Diagnostics.Stopwatch]::StartNew()
$script:AccordionWheelAt = -1000.0

function Set-AccordionCard([string]$Key, [switch]$NoLayout) {
    if (-not $script:window) { return }
    # Get-EnabledProviderKeys returns its array unrolled-proof (,$keys): take
    # it as is - wrapping it in @() would nest it.
    $all = Get-EnabledProviderKeys
    foreach ($k in $all) {
        $open = ([string]$k -eq [string]$Key)
        $body = $script:window.FindName($k + 'Body')
        $wasOpen = ($body -and $body.Visibility -eq [System.Windows.Visibility]::Visible)
        Set-Section $k $open
        if ($open -and -not $wasOpen -and $body -and -not $NoLayout) {
            # Fade the newly opened details in while the silhouette resizes.
            $a = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, [double]$body.Opacity, [System.Windows.Duration]([TimeSpan]::FromMilliseconds(200)))
            $a.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
            $body.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
        }
    }
    $script:AccordionKey = $Key
    if (-not $NoLayout) { Resize-ToContent }
}

function Step-AccordionCard([int]$Direction) {
    $keys = [string[]](Get-EnabledProviderKeys)
    if ($keys.Count -eq 0) { return }
    $i = [array]::IndexOf($keys, [string]$script:AccordionKey)
    if ($i -lt 0) { $next = if ($Direction -gt 0) { 0 } else { $keys.Count - 1 } }
    else { $next = [math]::Max(0, [math]::Min($keys.Count - 1, $i + $Direction)) }
    if ($next -eq $i) { return }
    Set-AccordionCard $keys[$next]
}

function Invoke-CardHeaderClick([string]$Key) {
    if (Test-NotchShell) {
        if ($script:AccordionKey -eq $Key) { Set-AccordionCard $null } else { Set-AccordionCard $Key }
        return
    }
    Toggle-Section $Key
    Sync-SectionMenuItems
}

function Invoke-PanelWheel($EventArgs) {
    if (-not (Test-NotchShell) -or $script:NotchState -ne 'EXPANDED') { return }
    $EventArgs.Handled = $true
    # Wheels and touchpads send bursts; one card per gesture step.
    $now = $script:AccordionWheelClock.Elapsed.TotalMilliseconds
    if ($now - $script:AccordionWheelAt -lt 230) { return }
    $script:AccordionWheelAt = $now
    if ($EventArgs.Delta -lt 0) { Step-AccordionCard 1 } else { Step-AccordionCard -1 }
}

# ---------------------------------------------------------------------------
# Notch readout: one small tag per enabled provider showing how much has been
# USED (5h / weekly, or the plan meter for Cursor). 1, 2 or 4 providers - the
# notch grows to fit and the stage re-centres.
# ---------------------------------------------------------------------------
function Get-EnabledProviderKeys {
    $keys = @()
    foreach ($key in @($script:ProviderMeta.Keys)) {
        $on = $true
        if (Get-Command Get-SectionVisible -ErrorAction SilentlyContinue) { $on = [bool](Get-SectionVisible $key) }
        if ($on) { $keys += $key }
    }
    return ,$keys
}

function Get-ProviderUsedMetrics([string]$Key) {
    switch ($Key) {
        'claude' {
            $d = if ($script:State) { Get-IslandMember $script:State 'Data' } else { $null }
            return @(
                @{ Label = '5h'; Value = (Get-IslandMember (Get-IslandMember $d 'five_hour') 'utilization') },
                @{ Label = 'W';  Value = (Get-IslandMember (Get-IslandMember $d 'seven_day') 'utilization') })
        }
        'codex' {
            return @(
                @{ Label = '5h'; Value = (Get-IslandMember $script:CodexStats 'FiveHourPct') },
                @{ Label = 'W';  Value = (Get-IslandMember $script:CodexStats 'WeekPct') })
        }
        'cursor' {
            $pct = $null
            if (Get-Command Get-CursorPlanUsageFromSummary -ErrorAction SilentlyContinue) {
                try { $pct = (Get-CursorPlanUsageFromSummary $script:SummaryData).BarPercent } catch { }
            }
            return @(@{ Label = 'Mo'; Value = $pct })
        }
        'grok' {
            return @(@{ Label = 'W'; Value = (Get-IslandMember $script:GrokUsage 'WeekPct') })
        }
    }
    return @()
}

function New-NotchTag([string]$Key) {
    $meta = $script:ProviderMeta[$Key]
    $metrics = @(Get-ProviderUsedMetrics $Key)
    $xaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        CornerRadius="10" Background="#17FFFFFF" Padding="3,2,9,2" Margin="3,0" VerticalAlignment="Center">
  <StackPanel x:Name="row" Orientation="Horizontal">
    <Border x:Name="tile" Width="17" Height="17" CornerRadius="5" Margin="0,0,6,0" VerticalAlignment="Center" ClipToBounds="True">
      <Grid>
        <TextBlock x:Name="mono" Foreground="#FFFFFF" FontSize="7.5" FontWeight="Bold" FontFamily="Segoe UI" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        <Image x:Name="img" Visibility="Collapsed" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
      </Grid>
    </Border>
  </StackPanel>
</Border>
'@
    $tag = [System.Windows.Markup.XamlReader]::Parse($xaml)
    $row = $tag.FindName('row')
    Set-ProviderTile $tag.FindName('tile') $tag.FindName('img') $tag.FindName('mono') $Key
    $values = @()
    for ($i = 0; $i -lt $metrics.Count; $i++) {
        if ($i -gt 0) {
            $sep = New-Object System.Windows.Controls.Border
            $sep.Width = 1; $sep.Height = 10; $sep.Margin = New-Object System.Windows.Thickness(7, 0, 7, 0)
            $sep.Background = NewBrush '#2EFFFFFF'; $sep.VerticalAlignment = 'Center'
            [void]$row.Children.Add($sep)
        }
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = $metrics[$i].Label; $lbl.FontSize = 9.5; $lbl.FontFamily = 'Segoe UI'
        $lbl.Foreground = NewBrush '#8E8E93'; $lbl.VerticalAlignment = 'Center'
        $lbl.Margin = New-Object System.Windows.Thickness(0, 1, 4, 0)
        [void]$row.Children.Add($lbl)
        $val = New-Object System.Windows.Controls.TextBlock
        $val.Text = '100%'; $val.FontSize = 12; $val.FontFamily = 'Segoe UI Semibold'
        $val.VerticalAlignment = 'Center'
        [void]$row.Children.Add($val)
        $values += $val
    }
    return @{ Element = $tag; Values = $values }
}

# ---------------------------------------------------------------------------
# Pin: keeps the notch out (instead of folding back to the sliver) when the
# pointer leaves. The button is optional (settings: "Pin button on notch").
# ---------------------------------------------------------------------------
function Test-NotchPinButtonEnabled {
    if (-not $script:Cfg) { return $true }
    $v = $script:Cfg['NotchPinButton']
    if ($null -eq $v) { return $true }
    return [bool]$v
}

function Test-NotchPinned {
    if (-not (Test-NotchPinButtonEnabled)) { return $false }
    return [bool]$script:Cfg['NotchPinned']
}

function New-NotchPinElement {
    $xaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="22" Height="22" CornerRadius="11" Margin="5,0,0,0" VerticalAlignment="Center"
        Background="#00FFFFFF">
  <TextBlock x:Name="glyph" FontFamily="Segoe MDL2 Assets" FontSize="11"
             HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,1,0,0"/>
</Border>
'@
    return [System.Windows.Markup.XamlReader]::Parse($xaml)
}

function Sync-NotchPinGlyph {
    $el = $script:NotchPinElement
    if (-not $el) { return }
    $glyph = $el.FindName('glyph')
    $pinned = Test-NotchPinned
    if ($glyph) {
        $glyph.Text = if ($pinned) { [string][char]0xE840 } else { [string][char]0xE718 }
        $glyph.Foreground = NewBrush $(if ($pinned) { '#0A84FF' } else { '#8E8E93' })
    }
    $el.Background = NewBrush $(if ($pinned) { '#260A84FF' } else { '#00FFFFFF' })
}

# True when a click at this mouse event landed on the pin (a little slack
# around it - it is small).
function Test-NotchPinHit($EventArgs) {
    $el = $script:NotchPinElement
    if (-not $el -or -not $script:IslandRoot -or $script:IslandRoot.Visibility -ne $script:VisVisible) { return $false }
    try {
        $p = $EventArgs.GetPosition($el)
        return ($p.X -ge -5 -and $p.Y -ge -6 -and $p.X -le ([double]$el.ActualWidth + 5) -and $p.Y -le ([double]$el.ActualHeight + 6))
    } catch { return $false }
}

function Set-NotchPinned([bool]$Pinned) {
    if (-not $script:Cfg) { return }
    $script:Cfg['NotchPinned'] = $Pinned
    Sync-NotchPinGlyph
    try { Assert-NotchTopmost -Force } catch { }
    try { Save-UnifiedState } catch { }
    if ($Pinned -and ($script:NotchState -eq 'EDGE' -or $script:NotchState -eq 'EDGE_RETURN' -or $script:NotchState -eq 'HOLD')) {
        Start-NotchHover
    }
    $script:NotchLeaveMs = 0.0
}

function Set-NotchPinButton([bool]$Enabled) {
    if (-not $script:Cfg) { return }
    $script:Cfg['NotchPinButton'] = $Enabled
    if (-not $Enabled) { $script:Cfg['NotchPinned'] = $false }
    try { Save-UnifiedState } catch { }
    Update-IslandView
}

function Set-NotchUsedText($Element, $Used) {
    if (-not $Element) { return }
    if ($null -eq $Used -or [string]$Used -eq '') {
        $Element.Text = '--'
        $Element.Foreground = NewBrush '#636366'
        return
    }
    $u = 0.0
    try { $u = [math]::Max(0.0, [double]$Used) } catch { $Element.Text = '--'; return }
    $Element.Text = ('{0:0}%' -f $u)
    # Used share: calm white, then Apple orange / red as the limit nears.
    $colour = if (Get-Command Get-UsageBandColor -ErrorAction SilentlyContinue) { Get-UsageBandColor $u }
              elseif ($u -ge 90) { '#FF453A' } elseif ($u -ge 75) { '#FF9F0A' } else { '#F2F2F7' }
    $Element.Foreground = NewBrush $colour
}

# Builds (when the provider set changed) and measures the tag row; returns the
# notch width it needs. Value slots are measured at "100%" so numbers ticking
# never change the width.
function Update-NotchInfoLayout {
    $row = $script:IslandElements['Row']
    if (-not $row) { return [double]$script:NotchStage.NotchW }
    $keys = Get-EnabledProviderKeys
    $pinOn = Test-NotchPinButtonEnabled
    $sig = ($keys -join ',') + '|pin=' + $pinOn
    if ($script:NotchTagSignature -ne $sig -or -not $script:NotchTags) {
        $row.Children.Clear()
        $script:NotchTags = [ordered]@{}
        foreach ($key in $keys) {
            $tag = New-NotchTag $key
            [void]$row.Children.Add($tag.Element)
            $script:NotchTags[$key] = $tag
        }
        if ($keys.Count -eq 0) {
            $t = New-Object System.Windows.Controls.TextBlock
            $t.Text = 'AI Usage'; $t.FontSize = 12; $t.FontFamily = 'Segoe UI Semibold'; $t.Foreground = NewBrush '#F2F2F7'
            [void]$row.Children.Add($t)
        }
        $script:NotchPinElement = $null
        if ($pinOn) {
            $script:NotchPinElement = New-NotchPinElement
            [void]$row.Children.Add($script:NotchPinElement)
            Sync-NotchPinGlyph
        }
        # Width from the widest possible readout.
        foreach ($tag in @($script:NotchTags.Values)) { foreach ($v in $tag.Values) { $v.Text = '100%' } }
        $row.Measure((New-Object System.Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
        foreach ($tag in @($script:NotchTags.Values)) {
            foreach ($v in $tag.Values) {
                $v.Measure((New-Object System.Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
                $v.MinWidth = [math]::Ceiling($v.DesiredSize.Width)
            }
        }
        $sp = $script:NotchSpec
        $w = [double]$row.DesiredSize.Width
        $script:NotchStage.NotchW = [math]::Max($sp.NotchMinW, [math]::Ceiling($w + 2.0 * $sp.NotchPadX))
        $script:NotchTagSignature = $sig
        Update-IslandValues
    }
    return [double]$script:NotchStage.NotchW
}

function Update-IslandValues {
    if (-not $script:NotchTags) { return }
    if ($script:NotchBackdrop) {
        $script:NotchBackdrop.ToolTip = if ($script:State -and [bool]$script:State.Stale) {
            'Claude ' + (Format-ClaudeStaleReset ([string]$script:State.DataAsOf))
        } else { $null }
    }
    if ($script:NotchBackdrop) { Invoke-I18nToolTip $script:NotchBackdrop (Get-UiLanguage) }
    foreach ($key in @($script:NotchTags.Keys)) {
        $tag = $script:NotchTags[$key]
        if ($key -eq 'claude') {
            $stale = $script:State -and [bool]$script:State.Stale
            $tag.Element.Opacity = if ($stale) { 0.65 } else { 1.0 }
        }
        $metrics = @(Get-ProviderUsedMetrics $key)
        for ($i = 0; $i -lt $tag.Values.Count -and $i -lt $metrics.Count; $i++) {
            Set-NotchUsedText $tag.Values[$i] $metrics[$i].Value
        }
    }
}

# Called on every data refresh and on the 30 s tick.
function Update-IslandView {
    if (-not $script:IslandRoot -or -not $script:IslandElements) { return }
    $before = [double]$script:NotchStage.NotchW
    [void](Update-NotchInfoLayout)
    Update-IslandValues
    if ([math]::Abs([double]$script:NotchStage.NotchW - $before) -gt 0.5 -and (Get-Command Update-NotchStageLayout -ErrorAction SilentlyContinue)) {
        Update-NotchStageLayout
    }
}

function Initialize-IslandView {
    if (-not $script:window -or -not $script:window.Content) { return }
    if ($script:NotchWindow -eq $script:window -and $script:IslandRoot) { return }

    $grid = $script:window.Content
    Initialize-NotchNative
    Initialize-NotchFastPath

    # The silhouette. It fills the stage; the root clip gives it its shape.
    # Pure black where the notch lives, easing into a deep navy lower down so
    # the open panel reads like tinted glass while the notch still melts into
    # the bezel.
    $backdropXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
  <Border.Background>
    <LinearGradientBrush StartPoint="0,0" EndPoint="0,420" MappingMode="Absolute">
      <GradientStop Color="#FF000000" Offset="0"/>
      <GradientStop Color="#FF09090A" Offset="0.12"/>
      <GradientStop Color="#FF111113" Offset="0.6"/>
      <GradientStop Color="#FF161618" Offset="1"/>
    </LinearGradientBrush>
  </Border.Background>
</Border>
'@
    $backdrop = [System.Windows.Markup.XamlReader]::Parse($backdropXaml)
    [void]$grid.Children.Add($backdrop)
    [System.Windows.Controls.Panel]::SetZIndex($backdrop, 1)

    $infoXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
      Height="32" HorizontalAlignment="Left" VerticalAlignment="Top"
      IsHitTestVisible="False" Opacity="0" Visibility="Hidden"
      TextOptions.TextFormattingMode="Display">
  <Grid.RenderTransform>
    <TranslateTransform x:Name="notchInfoTranslate" Y="-3"/>
  </Grid.RenderTransform>
  <StackPanel x:Name="notchInfoRow" Orientation="Horizontal"
              HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,0,0,1"/>
</Grid>
'@
    $info = [System.Windows.Markup.XamlReader]::Parse($infoXaml)
    [void]$grid.Children.Add($info)
    [System.Windows.Controls.Panel]::SetZIndex($info, 20)

    $script:NotchBackdrop = $backdrop
    $script:NotchContentRoot = $grid
    $script:IslandRoot = $info
    $script:IslandElements = @{ Row = $info.FindName('notchInfoRow') }
    $script:NotchTags = $null
    $script:NotchTagSignature = $null

    $w = $script:window
    $script:NotchParts = @{
        Pinned           = $w.FindName('pinnedRoot')
        Main             = $w.FindName('mainBorder')
        Content          = $w.FindName('panelContent')
        ContentTranslate = $w.FindName('panelContentTranslate')
        Header           = $w.FindName('islandCollapseHeader')
        Scroll           = $w.FindName('sectionScroll')
        Divider          = $w.FindName('footerDivider')
        Footer           = $w.FindName('footerRow')
        CollapseButton   = $w.FindName('panelCollapseButton')
        LogoTile         = $w.FindName('panelLogoTile')
        InfoTranslate    = $info.FindName('notchInfoTranslate')
    }

    $button = $script:NotchParts.CollapseButton
    if ($button) {
        # Mark mouse-down handled so the window-level drag never starts here.
        $button.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
        $button.Add_MouseLeftButtonUp({
            param($s, $e)
            $e.Handled = $true
            if ($script:NotchState -eq 'EXPANDED' -or $script:NotchState -eq 'EXPANDING') { Start-NotchCollapse }
        })
    }
    # Footer gear: settings menu. Header pill: accounts (sign in / who is signed in).
    $gear = $w.FindName('footerSettingsButton')
    if ($gear) {
        $gear.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
        $gear.Add_MouseLeftButtonUp({ param($s, $e) Show-ContextMenuAtWpfPointer $e })
    }
    $refreshButton = $w.FindName('chromeRefresh')
    if ($refreshButton) {
        $refreshButton.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
        $refreshButton.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Start-RefreshSpin; Invoke-ManualRefresh })
    }
    $updateButton = $w.FindName('chromeUpdate')
    if ($updateButton) {
        $updateButton.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
        $updateButton.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; try { Invoke-UpdateButton } catch { } })
        try { Sync-UpdateIndicators; Start-UpdateAutoCheck } catch { }
    }
    try { Set-NotchBackdropColor (Get-PanelBgHex) } catch { }
    try { Set-StatIconColors } catch { }
    try { Sync-UiLanguageTag } catch { }
    $acct = $w.FindName('chromePill')
    if ($acct) {
        $acct.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
        $acct.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Show-AccountsMenu })
    }
    # A card's red "Sign in" pill starts that provider's sign-in directly.
    foreach ($key in @('claude', 'codex', 'cursor', 'grok')) {
        $pill = $w.FindName($key + 'StatusPill')
        if (-not $pill) { continue }
        $pill.Add_MouseLeftButtonDown({ param($s, $e) if ([string]$s.Tag -eq 'auth') { $e.Handled = $true } })
        $pill.Add_MouseLeftButtonUp({
            param($s, $e)
            if ([string]$s.Tag -ne 'auth') { return }
            $e.Handled = $true
            Invoke-AccountAction (([string]$s.Name) -replace 'StatusPill$', '')
        })
    }

    $sp = $script:NotchSpec
    $st = $script:NotchStage
    [void](Update-NotchInfoLayout)
    $st.PanelW = $sp.PanelMinW
    $st.StageW = [math]::Ceiling([math]::Max($st.PanelW, $st.NotchW) + 2.0 * $sp.StagePadX)
    $st.CX = $st.StageW / 2.0
    $info.Width = $st.NotchW

    $script:NotchWindow = $script:window
    $script:NotchWideElements = $null
    if ($script:NotchState -ne 'EXPANDED') { $script:NotchState = 'EDGE' }
    Enable-NotchShell
    Set-NotchRest
    Sync-ProviderCardIcons
    Update-IslandView
}

# ---------------------------------------------------------------------------
# Panel chrome refresh (called at the end of Update-AllSections)
# ---------------------------------------------------------------------------
$script:ProviderPillStyles = @{
    ok          = @{ Text = 'Active';     Fg = '#30D158'; Bg = '#1A30D158'; Bd = '#3830D158' }
    stale       = @{ Text = 'Stale';      Fg = '#FF9F0A'; Bg = '#1AFF9F0A'; Bd = '#38FF9F0A' }
    auth        = @{ Text = 'Sign in';    Fg = '#FF453A'; Bg = '#1AFF453A'; Bd = '#38FF453A' }
    error       = @{ Text = 'Error';      Fg = '#FF453A'; Bg = '#1AFF453A'; Bd = '#38FF453A' }
    unavailable = @{ Text = 'Not set up'; Fg = '#A1A1A6'; Bg = '#10FFFFFF'; Bd = '#22FFFFFF' }
    refreshing  = @{ Text = 'Syncing';    Fg = '#E5E5EA'; Bg = '#14FFFFFF'; Bd = '#26FFFFFF' }
    idle        = @{ Text = 'Signed in';  Fg = '#E5E5EA'; Bg = '#14FFFFFF'; Bd = '#26FFFFFF' }
    init        = @{ Text = 'Loading';    Fg = '#A1A1A6'; Bg = '#10FFFFFF'; Bd = '#22FFFFFF' }
}

function Get-PanelStatusKey([string]$Status) {
    $s = if (Get-Command ConvertTo-ChromeStatus -ErrorAction SilentlyContinue) { ConvertTo-ChromeStatus $Status } else { [string]$Status }
    if ((Get-Command Test-ProviderAuthFailed -ErrorAction SilentlyContinue) -and (Test-ProviderAuthFailed $s)) { return 'auth' }
    if ($script:ProviderPillStyles.ContainsKey($s)) { return $s }
    return 'init'
}

# "~$32 all-time" -> bright "~$32", muted "all-time" (numbers stand out).
function Format-StatInlines($Tb) {
    if (-not $Tb) { return }
    $text = [regex]::Replace([string]$Tb.Text, '\s{2,}', ' ')
    if ([string]::IsNullOrEmpty($text) -or $text -eq '--') { return }
    $Tb.Inlines.Clear()
    foreach ($part in [regex]::Split($text, '(\s+)')) {
        if ($part -eq '') { continue }
        $run = New-Object System.Windows.Documents.Run($part)
        if ($part -match '^[~$]*[\d][\d.,]*[kKMBG%]?$' -or $part -match '^~?\$[\d.,]+[kKMB]?$') {
            $run.Foreground = NewBrush '#F5F5F7'
            $run.FontWeight = [System.Windows.FontWeights]::SemiBold
        } elseif ($part -notmatch '^\s+$') {
            $run.Foreground = NewBrush '#8E8E93'
        }
        [void]$Tb.Inlines.Add($run)
    }
}

function Update-PanelChrome {
    param($Statuses, [string]$ChromeStatus)
    $w = $script:window
    if (-not $w) { return }

    $script:LastProviderStatuses = $Statuses

    # Header state: "Live · 20:31" while healthy, otherwise what needs attention.
    $chromeKey = Get-PanelStatusKey $ChromeStatus
    $stateText = $w.FindName('chromeStateText')
    $time = $w.FindName('timeText')
    if ($stateText) {
        $words = @{ ok = 'Live'; stale = 'Stale'; auth = 'Sign in'; error = 'Error'; unavailable = 'Not set up'; refreshing = 'Syncing'; idle = 'Signed in ' + [char]0x00B7 + ' idle'; init = 'Loading' }
        $word = $words[$chromeKey]
        $clock = if ($time) { [string]$time.Text } else { '' }
        if ($chromeKey -eq 'ok' -and $clock -match '^\d{1,2}:\d{2}') { $word = 'Live ' + [char]0x00B7 + ' ' + $clock }
        # An update message (Update.ps1) holds the spot for a few seconds.
        $notice = $false
        try { $notice = Test-UpdateNoticeActive } catch { }
        if ($notice) { $script:UpdateNoticePrev = $word } else { $stateText.Text = $word }
    }

    # Accounts pill: "Sign in" + red dot while an enabled provider needs it.
    $needsSignIn = $false
    foreach ($key in @('claude', 'codex', 'cursor', 'grok')) {
        if (-not (Get-SectionVisible $key)) { continue }
        $raw = $null
        if ($Statuses -is [System.Collections.IDictionary] -and $Statuses.Contains($key)) { $raw = $Statuses[$key] }
        if ((Get-PanelStatusKey $raw) -eq 'auth') { $needsSignIn = $true }
    }
    $pill = $w.FindName('chromePill')
    $pillText = $w.FindName('chromePillText')
    $pillAlert = $w.FindName('chromePillAlert')
    if ($pill) { $pill.BorderBrush = NewBrush $(if ($needsSignIn) { '#55FF453A' } else { '#22FFFFFF' }) }
    if ($pillText) { $pillText.Text = if ($needsSignIn) { 'Sign in' } else { 'Accounts' } }
    if ($pillAlert) { $pillAlert.Visibility = if ($needsSignIn) { $script:VisVisible } else { $script:VisCollapsed } }

    # Card status pills.
    foreach ($key in @('claude', 'codex', 'cursor', 'grok')) {
        $raw = $null
        if ($Statuses -is [System.Collections.IDictionary] -and $Statuses.Contains($key)) { $raw = $Statuses[$key] }
        $style = $script:ProviderPillStyles[(Get-PanelStatusKey $raw)]
        $p = $w.FindName($key + 'StatusPill')
        $t = $w.FindName($key + 'StatusText')
        $d = $w.FindName($key + 'StatusDot')
        if ($p) {
            $p.Background = NewBrush $style.Bg; $p.BorderBrush = NewBrush $style.Bd
            $isAuth = ((Get-PanelStatusKey $raw) -eq 'auth')
            $p.Tag = if ($isAuth) { 'auth' } else { $null }
            $p.Cursor = if ($isAuth) { [System.Windows.Input.Cursors]::Hand } else { $null }
            $p.ToolTip = if ($isAuth) { 'Click to sign in to ' + $script:ProviderMeta[$key].Name }
                         elseif ((Get-PanelStatusKey $raw) -eq 'idle') { 'Signed in. Live usage returns when Claude Code renews its token.' }
                         else { $null }
        }
        if ($t) { $t.Text = $style.Text; $t.Foreground = NewBrush $style.Fg }
        if ($d) { $d.Fill = NewBrush $style.Fg }
    }

    # "Limit reached" badges.
    foreach ($pair in @(@('fivehPct','fivehLimit'), @('weekPct','weekLimit'), @('codexFivehPct','codexFivehLimit'),
                        @('codexWeekPct','codexWeekLimit'), @('grokWeekPct','grokWeekLimit'))) {
        $pct = $w.FindName($pair[0]); $badge = $w.FindName($pair[1])
        if (-not $pct -or -not $badge) { continue }
        $full = ([string]$pct.Text -match '^(\d+)%$') -and ([int]$Matches[1] -ge 100)
        $want = if ($full) { $script:VisVisible } else { $script:VisCollapsed }
        if ($badge.Visibility -ne $want) { $badge.Visibility = $want }
        # The badge says it; the small "critical!" line under the bar would repeat it.
        $sub = $w.FindName(($pair[0] -replace 'Pct$', 'Sub'))
        if ($full -and $sub) { $sub.Visibility = $script:VisCollapsed }
    }

    # A limit Claude does not report reads "Unavailable", not blank.
    $hasClaudeData = $script:State -and $script:State.Data
    foreach ($pair in @(@('fabPct','fabReset'), @('opusPct','opusReset'))) {
        $pct = $w.FindName($pair[0]); $reset = $w.FindName($pair[1])
        if ($pct -and $reset -and $hasClaudeData -and [string]$pct.Text -eq '--') { $reset.Text = 'Unavailable' }
    }

    foreach ($name in @('valText','tokText','todayText','afterHoursText','lifeText','extraVal',
                        'codexValText','codexTokText','codexTodayText','codexAfterHoursText','codexSessText',
                        'editsText','cursorTodayText','cursorSessText','grokPrepaidText')) {
        Format-StatInlines ($w.FindName($name))
    }
    Invoke-UiTranslate
}

# Theme colours land on the row icons; the row labels stay neutral as in the
# card design.
function Sync-PanelAccentIcons {
    if (-not $script:window) { return }
    foreach ($label in @('fivehLabel','weekLabel','fabLabel','opusLabel','codexFivehLabel','codexWeekLabel','reqLabel','grokWeekLabel')) {
        $lb = $script:window.FindName($label)
        $ic = $script:window.FindName(($label -replace 'Label$', 'Icon'))
        if (-not $lb -or -not $ic) { continue }
        # Row icon colour follows the usage band (Set-BarStateBrush); the label
        # reads in near-white.
        $lb.Foreground = NewBrush '#EDEDF0'
    }
}

function Apply-IslandWindowBehavior {
    if (-not $script:window) { return }

    $script:window.Topmost = $true
    $script:window.ShowActivated = $false
    $script:window.Focusable = $false

    if (-not ([System.Management.Automation.PSTypeName]'AIUsageIslandNative').Type) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AIUsageIslandNative {
    [DllImport("user32.dll", SetLastError=true)] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", SetLastError=true)] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint flags);
}
'@
    }

    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $script:window).Handle
    if ($hwnd -eq [IntPtr]::Zero) { return }
    $gwlExStyle = -20
    $wsExNoActivate = 0x08000000
    $wsExToolWindow = 0x00000080
    $style = [AIUsageIslandNative]::GetWindowLong($hwnd, $gwlExStyle)
    [void][AIUsageIslandNative]::SetWindowLong($hwnd, $gwlExStyle, ($style -bor $wsExNoActivate -bor $wsExToolWindow))
    [void][AIUsageIslandNative]::SetWindowPos($hwnd, [IntPtr](-1), 0, 0, 0, 0, 0x0013)
}

# Keep the notch above other apps. Windows can drop a window's always-on-top
# flag (seen after signing in with the notch pinned: any app then covered it
# until it was unpinned and pinned again). Checked every ~1.5 s from the hover
# poll, and the window is put back on top a few times after start, when
# Explorer and other startup apps are still opening their windows.
$script:TopmostCheckAt = [DateTime]::MinValue
$script:TopmostKickUntil = [DateTime]::UtcNow.AddSeconds(90)
function Assert-NotchTopmost([switch]$Force) {
    if (-not $script:window -or -not $script:window.IsVisible) { return }
    $now = [DateTime]::UtcNow
    if (-not $Force -and $now -lt $script:TopmostCheckAt) { return }
    $script:TopmostCheckAt = $now.AddMilliseconds(1500)
    if (-not ([System.Management.Automation.PSTypeName]'AIUsageIslandNative').Type) { return }
    # Never push the overlay over its own open menus.
    if (Test-NotchMenuOpen) { return }
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $script:window).Handle
    if ($hwnd -eq [IntPtr]::Zero) { return }
    $ex = [AIUsageIslandNative]::GetWindowLong($hwnd, -20)
    $lost = (($ex -band 0x8) -eq 0)
    if ($lost -or $Force -or $now -lt $script:TopmostKickUntil) {
        if ($lost) {
            $script:window.Topmost = $false
            $script:window.Topmost = $true
            try { Write-NotchLog 'always-on-top was lost; restored' } catch { }
        }
        # HWND_TOPMOST, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE
        [void][AIUsageIslandNative]::SetWindowPos($hwnd, [IntPtr](-1), 0, 0, 0, 0, 0x0013)
        # An AI request card grows out of the notch and must stay above it.
        if (($script:ReqCards -and $script:ReqCards.Count -gt 0) -or ($script:ReqClosing -and $script:ReqClosing.Count -gt 0)) { try { Set-RequestCardsOnTop } catch { } }
    }
}

# ---------------------------------------------------------------------------
# Shape
# ---------------------------------------------------------------------------
function Get-NotchPreset([string]$Name) {
    $sp = $script:NotchSpec
    $st = $script:NotchStage
    switch ($Name) {
        'EDGE'  { return @{ w = $sp.EdgeW;  h = $sp.EdgeH;   rb = $sp.EdgeRb;  sh = $sp.EdgeSh } }
        'NOTCH' { return @{ w = $st.NotchW; h = $sp.NotchH;  rb = $sp.NotchRb; sh = $sp.NotchSh } }
        'PANEL' { return @{ w = $st.PanelW; h = $st.PanelH;  rb = $sp.PanelRb; sh = $sp.PanelSh } }
    }
    return $null
}

# The silhouette as path data in stage coordinates. The top edge always sits on
# y=0. Docked, the top corners are square and flare outwards through concave
# "shoulders" so the shape reads as growing out of the bezel; floating (dragged
# away from the top), the shoulders are gone and the top corners are rounded.
# The per-frame maths (easing + silhouette) compiled once: a .NET call costs a
# fraction of a PowerShell function call, which is most of a frame's budget.
function Initialize-NotchFastPath {
    if ($null -ne $script:NotchFast) { return }
    $script:NotchFast = $false
    try {
        if (-not ([System.Management.Automation.PSTypeName]'AIUsageNotchMath').Type) {
            $refs = @([System.Windows.Media.Geometry].Assembly.Location, [System.Windows.Point].Assembly.Location,
                      [System.Windows.Freezable].Assembly.Location) | Where-Object { $_ } | Select-Object -Unique
            Add-Type -ReferencedAssemblies $refs -TypeDefinition @'
using System;
using System.Windows;
using System.Windows.Media;
public static class AIUsageNotchMath {
    const double K = 7.5;
    static readonly double Norm = 1.0 - (1.0 + K) * Math.Exp(-K);
    public static double Ease(string kind, double p) {
        switch (kind) {
            case "spring": return (1.0 - (1.0 + K * p) * Math.Exp(-K * p)) / Norm;
            case "out": { double q = 1.0 - p; return 1.0 - q * q * q; }
            case "fade": return p * p * (3.0 - 2.0 * p);
            case "inout":
                if (p < 0.5) return 4.0 * p * p * p;
                { double q = -2.0 * p + 2.0; return 1.0 - (q * q * q) / 2.0; }
        }
        return p;
    }
    public static Geometry Silhouette(double cx, double w, double h, double rb, double s, double rt) {
        if (w < 1.0) w = 1.0;
        if (h < 1.0) h = 1.0;
        double x = cx - w / 2.0, r = x + w;
        rb = Math.Max(0.0, Math.Min(rb, Math.Min(w / 2.0, h)));
        if (s > 0.05) s = Math.Min(s, Math.Max(0.0, h - rb));
        var g = new StreamGeometry();
        using (StreamGeometryContext c = g.Open()) {
            if (s > 0.05) {
                c.BeginFigure(new Point(x - s, 0), true, true);
                c.ArcTo(new Point(x, s), new Size(s, s), 0, false, SweepDirection.Clockwise, true, false);
                c.LineTo(new Point(x, h - rb), true, false);
                c.ArcTo(new Point(x + rb, h), new Size(rb, rb), 0, false, SweepDirection.Counterclockwise, true, false);
                c.LineTo(new Point(r - rb, h), true, false);
                c.ArcTo(new Point(r, h - rb), new Size(rb, rb), 0, false, SweepDirection.Counterclockwise, true, false);
                c.LineTo(new Point(r, s), true, false);
                c.ArcTo(new Point(r + s, 0), new Size(s, s), 0, false, SweepDirection.Clockwise, true, false);
            } else {
                rt = Math.Max(0.0, Math.Min(rt, Math.Min(w / 2.0, Math.Max(0.0, h - rb))));
                if (rt > 0.05) {
                    c.BeginFigure(new Point(x, rt), true, true);
                    c.LineTo(new Point(x, h - rb), true, false);
                    c.ArcTo(new Point(x + rb, h), new Size(rb, rb), 0, false, SweepDirection.Counterclockwise, true, false);
                    c.LineTo(new Point(r - rb, h), true, false);
                    c.ArcTo(new Point(r, h - rb), new Size(rb, rb), 0, false, SweepDirection.Counterclockwise, true, false);
                    c.LineTo(new Point(r, rt), true, false);
                    c.ArcTo(new Point(r - rt, 0), new Size(rt, rt), 0, false, SweepDirection.Counterclockwise, true, false);
                    c.LineTo(new Point(x + rt, 0), true, false);
                    c.ArcTo(new Point(x, rt), new Size(rt, rt), 0, false, SweepDirection.Counterclockwise, true, false);
                } else {
                    c.BeginFigure(new Point(x, 0), true, true);
                    c.LineTo(new Point(x, h - rb), true, false);
                    c.ArcTo(new Point(x + rb, h), new Size(rb, rb), 0, false, SweepDirection.Counterclockwise, true, false);
                    c.LineTo(new Point(r - rb, h), true, false);
                    c.ArcTo(new Point(r, h - rb), new Size(rb, rb), 0, false, SweepDirection.Counterclockwise, true, false);
                    c.LineTo(new Point(r, 0), true, false);
                }
            }
        }
        g.Freeze();
        return g;
    }
}
'@
        }
        # Smoke test before trusting it with every frame.
        [void][AIUsageNotchMath]::Silhouette(100.0, 50.0, 20.0, 5.0, 3.0, 0.0)
        [void][AIUsageNotchMath]::Ease('spring', 0.5)
        $script:NotchFast = $true
    } catch {
        Write-NotchLog "fast path unavailable: $($_.Exception.Message)"
        $script:NotchFast = $false
    }
}

function Get-NotchGeometry([double]$w, [double]$h, [double]$rb, [double]$s, [double]$rt) {
    if ($script:NotchFast) {
        return [AIUsageNotchMath]::Silhouette([double]$script:NotchStage.CX, $w, $h, $rb, $s, $rt)
    }
    $cx = [double]$script:NotchStage.CX
    if ($w -lt 1.0) { $w = 1.0 }
    if ($h -lt 1.0) { $h = 1.0 }
    $x = $cx - $w / 2.0
    $r = $x + $w
    $rb = [math]::Max(0.0, [math]::Min($rb, [math]::Min($w / 2.0, $h)))

    if ($s -gt 0.05) {
        $s = [math]::Min($s, [math]::Max(0.0, $h - $rb))
    }
    if ($s -gt 0.05) {
        $fmt = 'M{0:0.##},0 A{1:0.##},{1:0.##} 0 0 1 {2:0.##},{1:0.##} L{2:0.##},{3:0.##} A{4:0.##},{4:0.##} 0 0 0 {5:0.##},{6:0.##} L{7:0.##},{6:0.##} A{4:0.##},{4:0.##} 0 0 0 {8:0.##},{3:0.##} L{8:0.##},{1:0.##} A{1:0.##},{1:0.##} 0 0 1 {9:0.##},0 Z'
        $data = [string]::Format($script:NotchInv, $fmt, [object[]]@(($x - $s), $s, $x, ($h - $rb), $rb, ($x + $rb), $h, ($r - $rb), $r, ($r + $s)))
    } else {
        $rt = [math]::Max(0.0, [math]::Min($rt, [math]::Min($w / 2.0, [math]::Max(0.0, $h - $rb))))
        if ($rt -gt 0.05) {
            $fmt = 'M{0:0.##},{1:0.##} L{0:0.##},{2:0.##} A{3:0.##},{3:0.##} 0 0 0 {4:0.##},{5:0.##} L{6:0.##},{5:0.##} A{3:0.##},{3:0.##} 0 0 0 {7:0.##},{2:0.##} L{7:0.##},{1:0.##} A{1:0.##},{1:0.##} 0 0 0 {8:0.##},0 L{9:0.##},0 A{1:0.##},{1:0.##} 0 0 0 {0:0.##},{1:0.##} Z'
            $data = [string]::Format($script:NotchInv, $fmt, [object[]]@($x, $rt, ($h - $rb), $rb, ($x + $rb), $h, ($r - $rb), $r, ($r - $rt), ($x + $rt)))
        } else {
            $fmt = 'M{0:0.##},0 L{0:0.##},{1:0.##} A{2:0.##},{2:0.##} 0 0 0 {3:0.##},{4:0.##} L{5:0.##},{4:0.##} A{2:0.##},{2:0.##} 0 0 0 {6:0.##},{1:0.##} L{6:0.##},0 Z'
            $data = [string]::Format($script:NotchInv, $fmt, [object[]]@($x, ($h - $rb), $rb, ($x + $rb), $h, ($r - $rb), $r))
        }
    }
    $geometry = [System.Windows.Media.Geometry]::Parse($data)
    $geometry.Freeze()
    return $geometry
}

function Get-NotchEase([string]$Kind, [double]$p) {
    switch ($Kind) {
        'spring' {
            # Critically damped spring, normalised to land exactly on 1: starts
            # from rest, moves decisively, settles with no bounce.
            $k = $script:NotchSpringK
            return (1.0 - (1.0 + $k * $p) * [math]::Exp(-$k * $p)) / $script:NotchSpringNorm
        }
        'out'   { $q = 1.0 - $p; return 1.0 - $q * $q * $q }
        'fade'  { return $p * $p * (3.0 - 2.0 * $p) }
        'inout' {
            if ($p -lt 0.5) { return 4.0 * $p * $p * $p }
            $q = -2.0 * $p + 2.0
            return 1.0 - ($q * $q * $q) / 2.0
        }
    }
    return $p
}

function Invoke-NotchApply {
    param([switch]$MoveWindow)
    $grid = $script:NotchContentRoot
    if (-not $grid) { return }
    $v = $script:NV
    $sp = $script:NotchSpec

    $d = [double]$v.dock
    $shoulder = [double]$v.sh * [math]::Max(0.0, [math]::Min(1.0, ($d - 0.5) * 2.0))
    $top = $sp.FloatRadius * [math]::Max(0.0, [math]::Min(1.0, (0.5 - $d) * 2.0))
    $grid.Clip = Get-NotchGeometry ([double]$v.w) ([double]$v.h) ([double]$v.rb) $shoulder $top
    # A layered window only re-presents dirty regions; a shrinking clip alone
    # was not always counted, leaving old panel pixels on screen. Repainting
    # the full-stage backdrop marks the whole surface dirty.
    if ($script:NotchBackdrop) { $script:NotchBackdrop.InvalidateVisual() }

    $info = $script:IslandRoot
    $na = [double]$v.notchA
    if ($na -le 0.004) {
        if ($info.Visibility -ne $script:VisHidden) { $info.Visibility = $script:VisHidden }
    } else {
        if ($info.Visibility -ne $script:VisVisible) { $info.Visibility = $script:VisVisible }
        $info.Opacity = $na
        if ($script:NotchParts.InfoTranslate) { $script:NotchParts.InfoTranslate.Y = [double]$v.notchDy }
    }

    $parts = $script:NotchParts
    $pinned = $parts.Pinned
    if ($pinned) {
        $ha = [double]$v.headA
        $ba = [double]$v.bodyA
        if ($ha -le 0.004 -and $ba -le 0.004) {
            if ($pinned.Visibility -ne $script:VisHidden) { $pinned.Visibility = $script:VisHidden }
        } else {
            if ($pinned.Visibility -ne $script:VisVisible) { $pinned.Visibility = $script:VisVisible }
            if ($parts.Header)  { $parts.Header.Opacity = $ha }
            if ($parts.Scroll)  { $parts.Scroll.Opacity = $ba }
            if ($parts.Divider) { $parts.Divider.Opacity = $ba }
            if ($parts.Footer)  { $parts.Footer.Opacity = $ba }
            if ($parts.ContentTranslate) { $parts.ContentTranslate.Y = [double]$v.bodyDy }
        }
    }

    if ($MoveWindow) {
        $script:window.Left = [double]$v.winL
        $script:window.Top = [double]$v.winT
    }
}

# ---------------------------------------------------------------------------
# Motion engine
# ---------------------------------------------------------------------------
# Tracks: @{ field = @(to, startFraction, endFraction, ease) }. Every field
# starts from its current on-screen value. -Additive adds tracks without
# replacing the pending state-change callback of the running transition.
function Start-NotchMotion {
    param(
        [hashtable]$Tracks,
        [int]$DurationMs,
        [scriptblock]$OnComplete = $null,
        [switch]$Additive
    )
    $now = $script:NotchClock.Elapsed.TotalMilliseconds
    foreach ($name in @($Tracks.Keys)) {
        $spec = @($Tracks[$name])
        $to = [double]$spec[0]
        $t0 = if ($spec.Count -gt 1) { [double]$spec[1] } else { 0.0 }
        $t1 = if ($spec.Count -gt 2) { [double]$spec[2] } else { 1.0 }
        $ease = if ($spec.Count -gt 3) { [string]$spec[3] } else { 'spring' }
        $from = [double]$script:NV[$name]
        if ([math]::Abs($to - $from) -lt 0.0005) {
            [void]$script:NTracks.Remove($name)
            $script:NV[$name] = $to
            continue
        }
        $script:NTracks[$name] = @{
            From  = $from
            To    = $to
            Start = $now + $t0 * $DurationMs
            Dur   = [math]::Max(1.0, ($t1 - $t0) * $DurationMs)
            Ease  = $ease
        }
    }
    if (-not $Additive) {
        $script:NotchTransition = @{ End = $now + $DurationMs; Done = $OnComplete }
    }
    Start-NotchRendering
}

function Start-NotchRendering {
    if ($script:NotchRendering) { return }
    # Reserve the animation surface BEFORE the first frame. At rest the HWND
    # is only as tall as the visible silhouette (including the 5-DIP edge).
    Sync-NotchWindowHeight -ForMotion
    if (-not $script:NotchRenderHandler) {
        $script:NotchRenderHandler = [System.EventHandler]{ param($s, $e) Invoke-NotchFrame $e }
    }
    [System.Windows.Media.CompositionTarget]::add_Rendering($script:NotchRenderHandler)
    $script:NotchRendering = $true
}

function Stop-NotchRendering {
    if (-not $script:NotchRendering) { return }
    try { [System.Windows.Media.CompositionTarget]::remove_Rendering($script:NotchRenderHandler) } catch { }
    $script:NotchRendering = $false
    # Never resize the layered window from inside the Rendering callback: WPF
    # can then keep presenting the old surface. Settle the stage afterwards.
    if ($script:window -and $script:window.Dispatcher) {
        [void]$script:window.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [Action]{ try { Sync-NotchWindowHeight } catch { } })
    }
}

function Invoke-NotchFrame {
    param($e)
    try {
        if ($e -is [System.Windows.Media.RenderingEventArgs]) {
            # Rendering can fire more than once per composed frame.
            if ($e.RenderingTime -eq $script:NotchLastFrame) { return }
            $script:NotchLastFrame = $e.RenderingTime
        }
        $now = $script:NotchClock.Elapsed.TotalMilliseconds
        $moveWindow = $false
        foreach ($name in @($script:NTracks.Keys)) {
            $tr = $script:NTracks[$name]
            $p = ($now - [double]$tr.Start) / [double]$tr.Dur
            if ($name -eq 'winL' -or $name -eq 'winT') { $moveWindow = $true }
            if ($p -le 0.0) { continue }
            if ($p -ge 1.0) {
                $script:NV[$name] = [double]$tr.To
                [void]$script:NTracks.Remove($name)
            } else {
                $eased = if ($script:NotchFast) { [AIUsageNotchMath]::Ease([string]$tr.Ease, $p) } else { Get-NotchEase $tr.Ease $p }
                $value = [double]$tr.From + ([double]$tr.To - [double]$tr.From) * $eased
                if (($name -eq 'winT' -or $name -eq 'winL') -and [math]::Abs($value - [double]$tr.To) -lt 1.5) {
                    # The spring's tail creeps the last pixel for several
                    # frames; that sliver showed as a gap under the bezel.
                    $value = [double]$tr.To
                    [void]$script:NTracks.Remove($name)
                }
                $script:NV[$name] = $value
            }
        }
        Invoke-NotchApply -MoveWindow:$moveWindow

        $tx = $script:NotchTransition
        if ($tx -and $now -ge [double]$tx.End) {
            $script:NotchTransition = $null
            if ($tx.Done) { & $tx.Done }
        }
        if ($script:NTracks.Count -eq 0 -and -not $script:NotchTransition) { Stop-NotchRendering }
    } catch {
        Write-NotchLog "frame error: $($_.Exception.Message)"
        $script:NTracks.Clear()
        $script:NotchTransition = $null
        Stop-NotchRendering
    }
}

# Snap to the resting sliver with no motion (startup, re-show, mode switch).
function Set-NotchRest {
    $script:NTracks.Clear()
    $script:NotchTransition = $null
    $edge = Get-NotchPreset 'EDGE'
    $script:NV['w'] = $edge.w
    $script:NV['h'] = $edge.h
    $script:NV['rb'] = $edge.rb
    $script:NV['sh'] = $edge.sh
    $script:NV['dock'] = 1.0
    $script:NV['notchA'] = 0.0
    $script:NV['notchDy'] = -3.0
    $script:NV['headA'] = 0.0
    $script:NV['bodyA'] = 0.0
    $script:NV['bodyDy'] = -10.0
    $script:NotchState = 'EDGE'
    $script:NotchArmed = $true
    $script:NotchDwellMs = 0.0
    $script:NotchLeaveMs = 0.0
    Sync-NotchCursor
    Invoke-NotchApply
    Sync-NotchWindowHeight
    Sync-IslandMenuItem
    if ((Test-NotchPinned) -and $script:window) {
        [void]$script:window.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [Action]{ try { if ($script:NotchState -eq 'EDGE' -and (Test-NotchPinned)) { Start-NotchHover } } catch { } })
    }
}

function Sync-NotchCursor {
    if (-not $script:NotchBackdrop) { return }
    if ($script:NotchState -eq 'EXPANDED' -or $script:NotchState -eq 'EXPANDING') {
        $script:NotchBackdrop.Cursor = $null
    } else {
        $script:NotchBackdrop.Cursor = [System.Windows.Input.Cursors]::Hand
    }
}

# ---------------------------------------------------------------------------
# Stage layout
# ---------------------------------------------------------------------------
function Enable-NotchShell {
    $parts = $script:NotchParts
    if (-not $parts -or -not $parts.Pinned) { return }
    if ($script:NotchBackdrop -and $script:NotchBackdrop.Visibility -ne $script:VisVisible) {
        $script:NotchBackdrop.Visibility = $script:VisVisible
    }
    $pinned = $parts.Pinned
    $pinned.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
    $pinned.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
    if ($parts.Content) {
        $want = New-Object System.Windows.Thickness(0, 13, 0, 12)
        if ($parts.Content.Margin -ne $want) { $parts.Content.Margin = $want }
    }
    Set-NotchContentWidth ([double]$script:NotchStage.PanelW - 2.0 * $script:NotchSpec.PanelGutter)
    Sync-NotchPanelChrome
    if ($script:NotchState -eq 'SUSPENDED') {
        $script:NotchState = 'EDGE'
        Set-NotchRest
    }
    Ensure-NotchTimers
}

# Only panelContent carries horizontal space (a 14 DIP gutter each side of the
# silhouette); its parents carry none. Every progress track and sparkline
# canvas is tagged "track" in the XAML and spans the card's inner width less
# the 26 DIP icon column: card padding 13 + border 1 on each side.
function Set-NotchContentWidth([double]$Width) {
    $parts = $script:NotchParts
    $content = $parts.Content
    if (-not $content -or $Width -lt 120) { return }
    $Width = [math]::Floor($Width)
    if (-not $script:NotchWideElements) {
        $found = New-Object System.Collections.ArrayList
        $stack = New-Object System.Collections.Stack
        $stack.Push($content)
        while ($stack.Count -gt 0) {
            $node = $stack.Pop()
            foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($node)) {
                if ($child -isnot [System.Windows.DependencyObject]) { continue }
                if ($child -is [System.Windows.FrameworkElement] -and [string]$child.Tag -eq 'track') { [void]$found.Add($child) }
                $stack.Push($child)
            }
        }
        $script:NotchWideElements = $found.ToArray()
    }
    # content - card (12 padding + 1 border) x2 - meters' right margin 14
    # - stats column 196 - icon column 24
    $track = [math]::Floor($Width - 26.0 - 14.0 - 196.0 - 24.0)
    $changed = ([math]::Abs([double]$content.Width - $Width) -gt 0.5) -or ([math]::Abs([double]$script:BarTrackWidth - $track) -gt 0.5)
    $content.Width = $Width
    foreach ($el in $script:NotchWideElements) { $el.Width = $track }
    $script:BarTrackWidth = $track
    if ($changed -and (Get-Command Update-AllSections -ErrorAction SilentlyContinue)) {
        try { Update-AllSections } catch { Write-NotchLog "resize sections: $($_.Exception.Message)" }
    }
}

# The silhouette is the panel's background now; the themed card border would
# fight it (and cannot do square top corners), so it goes transparent.
function Sync-NotchPanelChrome {
    if (-not $script:window) { return }
    $mb = $script:window.FindName('mainBorder')
    if (-not $mb) { return }
    if (Test-NotchShell) {
        $mb.Background = [System.Windows.Media.Brushes]::Transparent
        $mb.BorderBrush = [System.Windows.Media.Brushes]::Transparent
        $mb.BorderThickness = New-Object System.Windows.Thickness(0)
        $mb.CornerRadius = New-Object System.Windows.CornerRadius(0)
        Sync-PanelAccentIcons
    } else {
        $mb.BorderThickness = New-Object System.Windows.Thickness(1)
        $mb.CornerRadius = New-Object System.Windows.CornerRadius(20)
    }
}

# Leaving the pinned view for the Quake terminal: hand the window back in the
# state that mode expects.
function Suspend-NotchShell {
    Stop-NotchRendering
    $script:NTracks.Clear()
    $script:NotchTransition = $null
    if ($script:NotchHoldTimer) { $script:NotchHoldTimer.Stop() }
    $script:NotchState = 'SUSPENDED'
    if ($script:NotchContentRoot) { $script:NotchContentRoot.Clip = $null }
    if ($script:NotchBackdrop) { $script:NotchBackdrop.Visibility = $script:VisCollapsed }
    if ($script:IslandRoot) { $script:IslandRoot.Visibility = $script:VisCollapsed }
    $parts = $script:NotchParts
    if ($parts.Pinned) {
        $parts.Pinned.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
        $parts.Pinned.Margin = New-Object System.Windows.Thickness(12)
        $parts.Pinned.Width = 280.0
    }
    foreach ($k in @('Header','Scroll','Divider','Footer')) {
        if ($parts[$k]) { $parts[$k].Opacity = 1.0 }
    }
    if ($parts.ContentTranslate) { $parts.ContentTranslate.Y = 0.0 }
    if ($parts.Content) { $parts.Content.Margin = New-Object System.Windows.Thickness(14, 8, 14, 9) }
    Set-NotchContentWidth 250.0
    if ($parts.Scroll) { $parts.Scroll.MaxHeight = [double]::PositiveInfinity }
    if ($script:Cfg -and (Get-Command Apply-UnifiedTheme -ErrorAction SilentlyContinue)) { Apply-UnifiedTheme $script:Cfg.Theme }
}

function Get-NotchHomePosition {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $stageW = [double]$script:NotchStage.StageW
    return @{ Left = [math]::Round($wa.Left + (($wa.Width - $stageW) / 2.0)); Top = $wa.Top }
}

function Sync-NotchWindowHeight {
    param([switch]$ForMotion)
    if (-not $script:window -or -not (Test-NotchShell)) { return }
    if ($script:NotchState -eq 'SUSPENDED') { return }
    # Keep the animation stage full-sized, but do not leave a panel-sized
    # transparent HWND at rest: Snipping Tool selects the native window rect.
    # Never shrink in CompositionTarget.Rendering. Stop-NotchRendering queues
    # this operation after the final clipped frame has been presented.
    $moving = $ForMotion -or $script:NotchRendering -or $script:NTracks.Count -gt 0 -or $null -ne $script:NotchTransition
    $target = if ($moving) {
        [math]::Ceiling([math]::Max([double]$script:NV.h, [double]$script:NotchStage.PanelH) + $script:NotchSpec.StagePadBottom)
    } else {
        [math]::Max(1.0, [math]::Ceiling([double]$script:NV.h))
    }
    $current = [double]$script:window.Height
    if ([double]::IsNaN($current) -or $target -gt $current + 0.5) {
        $script:window.Height = $target
    } elseif ($target -lt $current - 0.5 -and -not $moving) {
        # The clip already hides the outgoing pixels. Invalidate the backdrop
        # again after resizing so the smaller layered surface is repainted.
        $script:window.Height = $target
        if ($script:NotchBackdrop) { $script:NotchBackdrop.InvalidateVisual() }
    }
}

# Measures the panel and sizes the stage. Height changes only touch the
# transparent bottom of the stage, so nothing visible moves; the stage grows
# at once and only shrinks again while resting at the edge.
function Update-NotchStageLayout {
    if (-not $script:window -or -not (Test-NotchShell)) { return }
    Initialize-IslandView
    $parts = $script:NotchParts
    $pinned = $parts.Pinned
    if (-not $pinned) { return }
    Enable-NotchShell

    $sp = $script:NotchSpec
    $st = $script:NotchStage
    # Provider set may have changed (tray Show/Hide): rebuild the notch tags.
    [void](Update-NotchInfoLayout)
    if ([math]::Abs([double]$pinned.Width - $st.PanelW) -gt 0.1) { $pinned.Width = $st.PanelW }

    $inf = New-Object System.Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)
    $sv = $parts.Scroll
    # Flush pending invalidations first (a section just collapsed/expanded):
    # a direct Measure on a clean ancestor would return the stale size.
    try { $script:window.UpdateLayout() } catch { }
    if ($sv) { $sv.MaxHeight = [double]::PositiveInfinity; $sv.InvalidateMeasure() }
    $pinned.InvalidateMeasure()
    $pinned.Measure($inf)
    $natural = [double]$pinned.DesiredSize.Height
    $wa = [System.Windows.SystemParameters]::WorkArea
    $budget = [math]::Max(240.0, [double]$wa.Height - 24.0)
    if ($sv -and (Get-Command Get-SectionScrollMaxHeight -ErrorAction SilentlyContinue)) {
        $max = Get-SectionScrollMaxHeight -DesiredTotal $natural -ScrollNatural ([double]$sv.DesiredSize.Height) -Budget $budget
        if ($null -ne $max) {
            $sv.MaxHeight = $max
            $pinned.InvalidateMeasure()
            $pinned.Measure($inf)
            $natural = [double]$pinned.DesiredSize.Height
        }
    }
    if ($natural -le 0) { $natural = [double]$st.PanelH }
    $panelH = [math]::Ceiling($natural)
    $st.PanelH = $panelH

    $stageW = [math]::Ceiling([math]::Max([double]$st.PanelW, [double]$st.NotchW) + 2.0 * $sp.StagePadX)
    $st.StageW = $stageW
    $st.CX = $stageW / 2.0
    $pinnedMargin = New-Object System.Windows.Thickness(($st.CX - $st.PanelW / 2.0), 0, 0, 0)
    if ($pinned.Margin -ne $pinnedMargin) { $pinned.Margin = $pinnedMargin }
    if ($script:IslandRoot) {
        $infoMargin = New-Object System.Windows.Thickness(($st.CX - $st.NotchW / 2.0), 0, 0, 0)
        if ($script:IslandRoot.Margin -ne $infoMargin) { $script:IslandRoot.Margin = $infoMargin }
        $script:IslandRoot.Width = $st.NotchW
    }

    $win = $script:window
    $oldW = [double]$win.Width
    if ([double]::IsNaN($oldW) -or [math]::Abs($oldW - $stageW) -gt 0.5) {
        $win.Width = $stageW
        if (-not [double]::IsNaN($oldW) -and -not [double]::IsNaN([double]$win.Left)) {
            $win.Left = [double]$win.Left + ($oldW - $stageW) / 2.0
        }
    }
    Sync-NotchWindowHeight

    if ($script:NotchState -eq 'EXPANDED') {
        $heading = if ($script:NTracks.ContainsKey('h')) { [double]$script:NTracks['h'].To } else { [double]$script:NV.h }
        if ([math]::Abs($heading - $panelH) -gt 0.5) {
            Start-NotchMotion -Additive -DurationMs 240 -Tracks @{ h = @($panelH, 0.0, 1.0, 'spring') }
        }
    } elseif ($script:NotchState -eq 'EXPANDING') {
        if ($script:NTracks.ContainsKey('h')) { $script:NTracks['h'].To = [double]$panelH }
    } elseif ($script:NotchState -eq 'NOTCH' -and [math]::Abs([double]$script:NV.w - [double]$st.NotchW) -gt 0.5) {
        Start-NotchMotion -Additive -DurationMs 260 -Tracks @{ w = @([double]$st.NotchW, 0.0, 1.0, 'spring') }
    }
    Invoke-NotchApply
}

function Position-IslandWindow {
    param([switch]$Reveal)
    if (-not $script:window -or -not (Test-NotchShell)) { return }
    Initialize-IslandView
    Update-NotchStageLayout
    if ($script:NotchState -ne 'EXPANDED' -and $script:NotchState -ne 'EXPANDING') {
        $homePos = Get-NotchHomePosition
        $script:window.Left = $homePos.Left
        $script:window.Top = $homePos.Top
        Set-NotchRest
    }
    $script:Positioned = $true
    Apply-IslandWindowBehavior
}

function Sync-IslandMenuItem {
    $folded = Test-IslandMode
    if ($script:miNotchOpen) { $script:miNotchOpen.Enabled = $folded }
    if ($script:miNotchFold) { $script:miNotchFold.Enabled = -not $folded }
}

# ---------------------------------------------------------------------------
# Transitions
# ---------------------------------------------------------------------------
function Start-NotchHover {
    if (-not (Test-NotchShell)) { return }
    $script:NotchState = 'NOTCH'
    $script:NotchLeaveMs = 0.0
    Sync-NotchCursor
    $n = Get-NotchPreset 'NOTCH'
    # Height leads, the sides follow, corners form on the way; the readout
    # only fades in once the notch has mostly formed.
    Start-NotchMotion -DurationMs 270 -Tracks @{
        h       = @($n.h,  0.0,  0.82, 'spring')
        w       = @($n.w,  0.12, 1.0,  'spring')
        rb      = @($n.rb, 0.05, 0.9,  'spring')
        sh      = @($n.sh, 0.0,  0.8,  'spring')
        dock    = @(1.0,   0.0,  1.0,  'out')
        notchA  = @(1.0,   0.52, 1.0,  'fade')
        notchDy = @(0.0,   0.48, 1.0,  'out')
        headA   = @(0.0,   0.0,  0.3,  'fade')
        bodyA   = @(0.0,   0.0,  0.3,  'fade')
    }
}

function Start-NotchEdgeReturn {
    param([switch]$Disarm)
    if (-not (Test-NotchShell)) { return }
    $script:NotchState = 'EDGE_RETURN'
    if ($Disarm) { $script:NotchArmed = $false }
    Sync-NotchCursor
    $e = Get-NotchPreset 'EDGE'
    # Readout out first, then height, then width; the lower corners dissolve
    # into the sliver last.
    Start-NotchMotion -DurationMs 280 -Tracks @{
        notchA  = @(0.0,   0.0,  0.36, 'fade')
        notchDy = @(-3.0,  0.0,  0.4,  'out')
        h       = @($e.h,  0.1,  0.86, 'spring')
        w       = @($e.w,  0.2,  1.0,  'spring')
        rb      = @($e.rb, 0.15, 1.0,  'spring')
        sh      = @($e.sh, 0.3,  1.0,  'spring')
        dock    = @(1.0,   0.0,  1.0,  'out')
        headA   = @(0.0,   0.0,  0.2,  'fade')
        bodyA   = @(0.0,   0.0,  0.2,  'fade')
    } -OnComplete {
        $script:NotchState = 'EDGE'
        $script:NotchDwellMs = 0.0
        Sync-NotchCursor
        Sync-IslandMenuItem
    }
}

function Start-NotchExpand {
    if (-not $script:window -or -not (Test-NotchShell)) { return }
    if ($script:NotchState -eq 'EXPANDING' -or $script:NotchState -eq 'EXPANDED') { return }
    if ($script:NotchHoldTimer) { $script:NotchHoldTimer.Stop() }
    # Open on the first provider's details; the others start folded.
    try {
        $cards = [string[]](Get-EnabledProviderKeys)
        $firstCard = if ($cards.Count -gt 0) { $cards[0] } else { '' }
        Set-AccordionCard $firstCard -NoLayout
    } catch { Write-NotchLog "accordion: $($_.Exception.Message)" }
    Update-NotchStageLayout
    $script:NotchState = 'EXPANDING'
    $script:NotchPanelSeen = $false
    $script:NotchPanelLeaveMs = 0.0
    $script:NotchMenuGraceMs = 0.0
    Sync-NotchCursor
    Sync-IslandMenuItem
    Sync-NotchCollapseButton
    $pn = Get-NotchPreset 'PANEL'
    # The outline leads. Header joins once the outline is ~2/3 of the way,
    # the body last, settling with a soft ease-out.
    Start-NotchMotion -DurationMs 440 -Tracks @{
        h       = @($pn.h,  0.0,  1.0,  'spring')
        w       = @($pn.w,  0.0,  0.82, 'spring')
        rb      = @($pn.rb, 0.0,  0.85, 'spring')
        sh      = @($pn.sh, 0.0,  0.85, 'spring')
        dock    = @(1.0,    0.0,  0.5,  'out')
        notchA  = @(0.0,    0.0,  0.3,  'fade')
        notchDy = @(3.0,    0.0,  0.3,  'out')
        headA   = @(1.0,    0.26, 0.58, 'fade')
        bodyA   = @(1.0,    0.4,  0.86, 'fade')
        bodyDy  = @(0.0,    0.3,  1.0,  'out')
    } -OnComplete {
        $script:NotchState = 'EXPANDED'
        $script:NV['notchDy'] = -3.0
        Sync-NotchCursor
        Sync-IslandMenuItem
        Sync-NotchDock
    }
}

function Start-NotchCollapse {
    if (-not $script:window -or -not (Test-NotchShell)) { return }
    if ($script:NotchState -ne 'EXPANDED' -and $script:NotchState -ne 'EXPANDING') { return }
    $script:NotchState = 'COLLAPSING'
    Sync-NotchCursor
    Sync-IslandMenuItem

    $n = Get-NotchPreset 'NOTCH'
    $homePos = Get-NotchHomePosition
    $win = $script:window
    $left = [double]$win.Left
    $topNow = [double]$win.Top
    $needsMove = ([math]::Abs($left - $homePos.Left) -gt 0.5 -or [math]::Abs($topNow - $homePos.Top) -gt 0.5)
    $script:NV['winL'] = $left
    $script:NV['winT'] = $topNow

    $tracks = @{
        bodyA   = @(0.0,   0.0,  0.22, 'fade')
        headA   = @(0.0,   0.04, 0.28, 'fade')
        bodyDy  = @(-8.0,  0.0,  0.32, 'out')
        h       = @($n.h,  0.06, 1.0,  'spring')
        w       = @($n.w,  0.14, 1.0,  'spring')
        rb      = @($n.rb, 0.1,  0.9,  'spring')
        sh      = @($n.sh, 0.1,  0.9,  'spring')
        notchA  = @(1.0,   0.7,  1.0,  'fade')
        notchDy = @(0.0,   0.66, 1.0,  'out')
    }
    $duration = 400
    if ($needsMove) {
        # Travel home while morphing; the top corners square off and the
        # shoulders grow back only as it arrives at the bezel.
        $duration = 500
        $tracks['winL'] = @([double]$homePos.Left, 0.0, 0.9,  'spring')
        $tracks['winT'] = @([double]$homePos.Top,  0.0, 0.78, 'spring')
        $tracks['dock'] = @(1.0, 0.5, 0.95, 'inout')
    } else {
        $tracks['dock'] = @(1.0, 0.0, 0.5, 'out')
    }
    Start-NotchMotion -DurationMs $duration -Tracks $tracks -OnComplete {
        if (Test-NotchPinned) {
            # Pinned: rest as the notch instead of folding on to the sliver.
            $script:NotchState = 'NOTCH'
            $script:NotchLeaveMs = 0.0
            Sync-NotchCursor
            Sync-IslandMenuItem
            return
        }
        $script:NotchState = 'HOLD'
        Ensure-NotchTimers
        $script:NotchHoldTimer.Stop()
        $script:NotchHoldTimer.Start()
    }
}

# Kept for the tray menu and older callers: $true = go to the edge, $false =
# open the full panel.
function Set-IslandMode {
    param([bool]$Enabled)
    if (-not $script:window) { return }
    Initialize-IslandView
    if ($Enabled) { Start-NotchCollapse } else { Start-NotchExpand }
}

# Detach / re-dock while the panel is dragged: shoulders melt away and the top
# corners round as soon as it leaves the bezel, and come back if it is dropped
# against the top again.
function Test-NotchDockedAtTop {
    $wa = [System.Windows.SystemParameters]::WorkArea
    return ([double]$script:window.Top -le $wa.Top + 0.5)
}

# Docked at the top: the panel folds back by clicking its top strip, so the
# "-" button is not shown. Moved away from the top: "-" appears and takes it
# home. Hidden (not Collapsed) keeps the header text from shifting.
function Sync-NotchCollapseButton {
    $parts = $script:NotchParts
    if (-not $script:window -or -not $parts) { return }
    $docked = Test-NotchDockedAtTop
    # The "-" takes the logo tile's slot while the panel is away from the top.
    $button = $parts.CollapseButton
    if ($button) {
        $want = if ($docked) { $script:VisCollapsed } else { $script:VisVisible }
        if ($button.Visibility -ne $want) { $button.Visibility = $want }
    }
    if ($parts.LogoTile) {
        $want = if ($docked) { $script:VisVisible } else { $script:VisCollapsed }
        if ($parts.LogoTile.Visibility -ne $want) { $parts.LogoTile.Visibility = $want }
    }
    if ($parts.Header) {
        $parts.Header.Cursor = if ($docked) { [System.Windows.Input.Cursors]::Hand } else { $null }
    }
}

function Sync-NotchDock {
    if ($script:NotchState -ne 'EXPANDED' -or -not $script:window) { return }
    if ($script:NTracks.ContainsKey('winL')) { return }
    Sync-NotchCollapseButton
    $target = if (Test-NotchDockedAtTop) { 1.0 } else { 0.0 }
    $current = if ($script:NTracks.ContainsKey('dock')) { [double]$script:NTracks['dock'].To } else { [double]$script:NV.dock }
    if ([math]::Abs($current - $target) -lt 0.01) { return }
    Start-NotchMotion -Additive -DurationMs 220 -Tracks @{ dock = @($target, 0.0, 1.0, 'inout') }
}

function Complete-NotchDrag {
    if (-not $script:window) { return }
    $wa = [System.Windows.SystemParameters]::WorkArea
    # Dropped above the top edge: settle flush against it (and dock).
    if ([double]$script:window.Top -lt $wa.Top) { $script:window.Top = $wa.Top }
    Sync-NotchDock
}

# ---------------------------------------------------------------------------
# Pointer handling
# ---------------------------------------------------------------------------
function Ensure-NotchTimers {
    if (-not $script:NotchHoverTimer) {
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromMilliseconds($script:NotchSpec.PollMs)
        $t.add_Tick({ Invoke-NotchHoverPoll })
        $script:NotchHoverTimer = $t
    }
    if (-not $script:NotchHoverTimer.IsEnabled) { $script:NotchHoverTimer.Start() }
    if (-not $script:NotchHoldTimer) {
        $h = New-Object System.Windows.Threading.DispatcherTimer
        $h.Interval = [TimeSpan]::FromMilliseconds(140)
        $h.add_Tick({
            $script:NotchHoldTimer.Stop()
            if ($script:NotchState -eq 'HOLD') {
                if (Test-NotchPinned) { $script:NotchState = 'NOTCH' } else { Start-NotchEdgeReturn -Disarm }
            }
        })
        $script:NotchHoldTimer = $h
    }
}

function Initialize-NotchNative {
    if (([System.Management.Automation.PSTypeName]'AIUsageNotchNative').Type) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AIUsageNotchNative {
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    public static double[] CursorAndWindow(IntPtr hwnd) {
        POINT p; RECT r;
        if (!GetCursorPos(out p) || !GetWindowRect(hwnd, out r)) return null;
        return new double[] { p.X, p.Y, r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top };
    }
}
'@
}

# Cursor in stage DIPs. Cursor and window rect come from the same Win32 space,
# so the scale is simply window pixels / window DIPs whatever the DPI mode.
function Get-NotchCursorLocal {
    $win = $script:window
    if ($script:NotchHwndWindow -ne $win -or $script:NotchHwnd -eq [IntPtr]::Zero) {
        $script:NotchHwnd = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
        $script:NotchHwndWindow = $win
    }
    if ($script:NotchHwnd -eq [IntPtr]::Zero) { return $null }
    $m = [AIUsageNotchNative]::CursorAndWindow($script:NotchHwnd)
    if (-not $m) { return $null }
    $dipW = [double]$win.ActualWidth
    if ($dipW -le 0 -or $m[4] -le 0) { return $null }
    $scale = $m[4] / $dipW
    return @{ X = ($m[0] - $m[2]) / $scale; Y = ($m[1] - $m[3]) / $scale }
}

# Hover is read from the cursor position rather than WPF MouseEnter/Leave: the
# silhouette changes under a still pointer, and a layered window only hears
# about the mouse over its painted pixels.
# A stale MouseDown flag is not evidence that a button is still held.
function Test-NotchHolding([bool]$InNotch, [bool]$Pressed, [bool]$ButtonsDown, [bool]$Pinned) {
    return ($InNotch -or ($Pressed -and $ButtonsDown) -or $Pinned)
}

function Invoke-NotchHoverPoll {
    $buttonsDown = ([System.Windows.Forms.Control]::MouseButtons -ne [System.Windows.Forms.MouseButtons]::None)
    if ($script:NotchPressed -and -not $buttonsDown) { $script:NotchPressed = $false }
    try {
        if (-not $script:window -or -not $script:window.IsVisible) { return }
        if (-not (Test-NotchShell)) { return }
        Assert-NotchTopmost
        if (Test-NotchMenuOpen) { Close-NotchMenusOnOutsideClick }
        $state = $script:NotchState
        if ($state -eq 'EXPANDED') { Invoke-NotchPanelLeavePoll; return }
        # While an AI request card is out of the notch, the notch stays put.
        if (($script:ReqCards -and $script:ReqCards.Count -gt 0) -or ($script:ReqClosing -and $script:ReqClosing.Count -gt 0)) { return }
        if ($state -ne 'EDGE' -and $state -ne 'NOTCH' -and $state -ne 'EDGE_RETURN') { return }

        $pt = Get-NotchCursorLocal
        if (-not $pt) { return }
        $sp = $script:NotchSpec
        $st = $script:NotchStage
        $dx = [math]::Abs($pt.X - [double]$st.CX)
        $tick = [double]$sp.PollMs
        $inEdge = ($pt.Y -ge -6.0) -and ($pt.Y -le $sp.EdgeZoneY) -and ($dx -le ($sp.EdgeW / 2.0 + $sp.EdgeZoneExtraX))
        $inNotch = ($pt.Y -ge -6.0) -and ($pt.Y -le ($sp.NotchH + 12.0)) -and ($dx -le ([double]$st.NotchW / 2.0 + 14.0))

        if ($state -eq 'EDGE') {
            if (-not $script:NotchArmed) {
                if (-not $inEdge) { $script:NotchArmed = $true }
                $script:NotchDwellMs = 0.0
                return
            }
            if ($inEdge) {
                $script:NotchDwellMs += $tick
                if ($script:NotchDwellMs -ge $sp.HoverDwellMs) {
                    $script:NotchDwellMs = 0.0
                    Start-NotchHover
                }
            } else {
                $script:NotchDwellMs = 0.0
            }
        } elseif ($state -eq 'NOTCH') {
            if ((Test-NotchHolding $inNotch $script:NotchPressed $buttonsDown $false) -or (Test-NotchPinned)) {
                $script:NotchLeaveMs = 0.0
            } else {
                $script:NotchLeaveMs += $tick
                if ($script:NotchLeaveMs -ge $sp.HoverLeaveMs) {
                    $script:NotchLeaveMs = 0.0
                    Start-NotchEdgeReturn
                }
            }
        } elseif ($state -eq 'EDGE_RETURN') {
            if ($script:NotchArmed) {
                $overShape = $inNotch -and ($pt.Y -le ([double]$script:NV.h + 4.0))
                if ($inEdge -or $overShape) { Start-NotchHover }
            } elseif (-not $inEdge -and -not $inNotch) {
                $script:NotchArmed = $true
            }
        }
    } catch { }
}

# A popup menu (settings, accounts, or one of their submenus) is open. The
# pointer is over the menu then, not the panel, which is not a "leave".
function Test-NotchMenuOpen {
    foreach ($strip in @($script:ctxStrip, $script:accountsStrip)) {
        if (-not $strip) { continue }
        if ($strip.Visible) { return $true }
    }
    return $false
}

# True when the screen point lies on this dropdown or any open submenu of it.
function Test-PointOnMenu($Strip, [System.Drawing.Point]$Point) {
    if (-not $Strip -or -not $Strip.Visible) { return $false }
    if ($Strip.Bounds.Contains($Point)) { return $true }
    foreach ($it in @($Strip.Items)) {
        if ($it -is [System.Windows.Forms.ToolStripDropDownItem] -and $it.HasDropDownItems -and $it.DropDown.Visible) {
            if (Test-PointOnMenu $it.DropDown $Point) { return $true }
        }
    }
    return $false
}

# The overlay never takes focus (it must not steal it from the app you are
# working in), so WinForms never learns about a click elsewhere and the menu
# would stay up. Close it ourselves on any press outside the open menus.
function Close-NotchMenusOnOutsideClick {
    if (-not [AIUsageMenuDrag]::AnyButtonPressed()) { return }
    if ([AIUsageMenuDrag]::Active) { return }
    $pt = [System.Windows.Forms.Control]::MousePosition
    foreach ($strip in @($script:ctxStrip, $script:accountsStrip)) {
        if (-not $strip -or -not $strip.Visible) { continue }
        if (-not (Test-PointOnMenu $strip $pt)) {
            try { $strip.Close([System.Windows.Forms.ToolStripDropDownCloseReason]::AppClicked) } catch { }
        }
    }
}

# Docked at the top, the open panel behaves like a dropdown from the notch:
# once the pointer has been over it, moving off it folds it back. Dragged away
# from the top it is a free window and stays until its "-" button.
function Invoke-NotchPanelLeavePoll {
    $sp = $script:NotchSpec
    $tick = [double]$sp.PollMs
    if ($script:NotchDragging -or $script:NotchPressed -or $script:NTracks.ContainsKey('winL')) { $script:NotchPanelLeaveMs = 0.0; return }
    if (-not (Test-NotchDockedAtTop)) { $script:NotchPanelLeaveMs = 0.0; return }
    if (Test-NotchMenuOpen) {
        Close-NotchMenusOnOutsideClick
        $script:NotchPanelLeaveMs = 0.0; $script:NotchMenuGraceMs = 700.0; return
    }
    # The colour picker previews on the panel: keep it open meanwhile.
    if ($script:ColorPicker) { $script:NotchPanelLeaveMs = 0.0; $script:NotchMenuGraceMs = 700.0; return }
    if ([System.Windows.Forms.Control]::MouseButtons -ne [System.Windows.Forms.MouseButtons]::None) { $script:NotchPanelLeaveMs = 0.0; return }

    $pt = Get-NotchCursorLocal
    if (-not $pt) { return }
    $st = $script:NotchStage
    $half = [double]$script:NV.w / 2.0 + 10.0
    $inside = ($pt.Y -ge -8.0) -and ($pt.Y -le ([double]$script:NV.h + 12.0)) -and ([math]::Abs($pt.X - [double]$st.CX) -le $half)
    if ($inside) {
        $script:NotchPanelSeen = $true
        $script:NotchPanelLeaveMs = 0.0
        return
    }
    if (-not $script:NotchPanelSeen) { return }
    # Just closed a menu that was hanging outside the panel: give the pointer
    # a moment to come back before folding.
    if ($script:NotchMenuGraceMs -gt 0) { $script:NotchMenuGraceMs -= $tick; return }
    $script:NotchPanelLeaveMs += $tick
    if ($script:NotchPanelLeaveMs -ge $sp.PanelLeaveMs) {
        $script:NotchPanelLeaveMs = 0.0
        $script:NotchPanelSeen = $false
        Start-NotchCollapse
    }
}

function Test-NotchInteractiveSource($Source) {
    $node = $Source
    $guard = 0
    while ($node -and $guard -lt 80) {
        $guard++
        if ($node -is [System.Windows.Controls.Primitives.ScrollBar] -or
            $node -is [System.Windows.Controls.Primitives.Thumb] -or
            $node -is [System.Windows.Controls.Primitives.ButtonBase] -or
            $node -is [System.Windows.Controls.Primitives.TextBoxBase] -or
            $node -is [System.Windows.Controls.PasswordBox] -or
            $node -is [System.Windows.Controls.Primitives.Selector] -or
            $node -is [System.Windows.Documents.Hyperlink]) { return $true }
        if ($script:NotchParts.CollapseButton -and $node -eq $script:NotchParts.CollapseButton) { return $true }
        if ($node -eq $script:window) { break }
        if ($node -is [System.Windows.Media.Visual]) {
            $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
        } elseif ($node -is [System.Windows.FrameworkContentElement]) {
            $node = $node.Parent
        } else {
            break
        }
    }
    return $false
}

function Invoke-NotchMouseDown($EventArgs) {
    if (-not (Test-NotchShell)) { return }
    $state = $script:NotchState
    if ($state -eq 'EXPANDED') {
        if (Test-NotchInteractiveSource $EventArgs.OriginalSource) { return }
        $EventArgs.Handled = $true
        # A press on the top strip of a docked panel is a "fold back" click
        # unless it turns into a drag.
        $onTopStrip = $false
        $header = $script:NotchParts.Header
        if ($header -and (Test-NotchDockedAtTop)) {
            $hp = $EventArgs.GetPosition($header)
            $onTopStrip = ($hp.Y -le [double]$header.ActualHeight + 4.0)
        }
        $startLeft = [double]$script:window.Left
        $startTop = [double]$script:window.Top
        $script:NotchDragging = $true
        try {
            $script:window.DragMove()
        } catch {
            Write-NotchLog "DragMove error: $($_.Exception.Message)"
        } finally {
            $script:NotchDragging = $false
        }
        $moved = ([math]::Abs([double]$script:window.Left - $startLeft) -gt 1.0 -or [math]::Abs([double]$script:window.Top - $startTop) -gt 1.0)
        if ($onTopStrip -and -not $moved) {
            Start-NotchCollapse
            return
        }
        Complete-NotchDrag
        return
    }
    if ($state -eq 'NOTCH' -or $state -eq 'EDGE_RETURN' -or $state -eq 'EDGE') {
        $script:NotchPressed = $true
    }
    $EventArgs.Handled = $true
}

function Invoke-NotchMouseUp($EventArgs) {
    if (-not $script:NotchPressed) { return }
    $script:NotchPressed = $false
    $EventArgs.Handled = $true
    $state = $script:NotchState
    if (($state -eq 'NOTCH' -or $state -eq 'EDGE_RETURN') -and (Test-NotchPinHit $EventArgs)) {
        Set-NotchPinned (-not (Test-NotchPinned))
        return
    }
    if ($state -eq 'NOTCH' -or $state -eq 'EDGE_RETURN' -or $state -eq 'EDGE') { Start-NotchExpand }
}

# ---------------------------------------------------------------------------
# Window events - wired per window instance (called by Build-And-Show on each build)
# ---------------------------------------------------------------------------
function Wire-UnifiedWindowEvents {
    Initialize-IslandView
    $script:window.ShowActivated = $false
    $script:window.Focusable = $false
    $script:window.Add_SourceInitialized({ Apply-IslandWindowBehavior })

    $script:window.Add_MouseLeftButtonDown({
        param($s, $e)
        # In dropdown mode the panel is anchored to a monitor edge; dragging it
        # would both fight the slide animation and overwrite the pinned position.
        if ((Get-Command Test-DropdownMode -ErrorAction SilentlyContinue) -and (Test-DropdownMode)) { return }
        Invoke-NotchMouseDown $e
    })
    $script:window.Add_MouseLeftButtonUp({
        param($s, $e)
        Invoke-NotchMouseUp $e
    })
    $script:window.Add_LocationChanged({
        if ($script:NotchDragging) { Sync-NotchDock }
    })

    # Quake-style dismissal: Esc, or focus moving to another app. The context
    # menu is a WinForms strip, so showing it deactivates this window - without
    # that guard, right-clicking the panel would slide it away.
    $script:window.Add_PreviewKeyDown({
        param($s, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Escape -and (Test-DropdownMode)) {
            Hide-Dropdown
            $e.Handled = $true
        }
    })
    # Off by default: a real quake console stays up until you dismiss it, and a
    # usage readout you want to glance at while working in another window is
    # exactly the case where hiding on focus loss is wrong.
    $script:window.Add_Deactivated({
        if (-not (Test-DropdownMode)) { return }
        if (-not [bool]$script:Cfg['DropdownHideOnFocusLoss']) { return }
        if ($script:ctxStrip -and $script:ctxStrip.Visible) { return }
        Hide-Dropdown
    })
    $script:window.Add_Loaded({
        Resize-ToContent
        if (Test-IslandMode) { Position-IslandWindow } elseif (Test-NotchShell) { Update-NotchStageLayout } else { Position-Window }
        Apply-IslandWindowBehavior
    })
    $script:window.Add_Closing({ param($s, $e) if (-not $script:ReallyQuit) { $e.Cancel = $true; $script:window.Hide() } })
    # Right-click no longer opens the settings menu on the overlay; the footer
    # gear (and the tray icon) do.

    foreach ($pair in @(@('claudeHeader','claude'), @('codexHeader','codex'), @('cursorHeader','cursor'), @('grokHeader','grok'))) {
        $headerName = $pair[0]
        $sectionKey = $pair[1]
        $header = $script:window.FindName($headerName)
        if ($header) {
            # Mark mouse-down handled so the window-level DragMove handler does not
            # start a drag (which would otherwise swallow the header's mouse-up).
            $header.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
            $header.Add_MouseLeftButtonUp([scriptblock]::Create("Invoke-CardHeaderClick '$sectionKey'"))
        }
        # The provider's icon opens its app.
        $tile = $script:window.FindName($sectionKey + 'IconTile')
        if ($tile) {
            $tile.Cursor = [System.Windows.Input.Cursors]::Hand
            $tile.ToolTip = Convert-I18nString ('Open ' + $script:ProviderMeta[$sectionKey].Name) (Get-UiLanguage)
            $tile.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
            $tile.Add_MouseLeftButtonUp([scriptblock]::Create("param(`$s, `$e) `$e.Handled = `$true; Open-ProviderApp '$sectionKey'"))
        }
    }
    $script:window.Add_PreviewMouseWheel({ param($s, $e) Invoke-PanelWheel $e })

    # Global hotkeys go here rather than at file scope: this file is loaded before
    # the saved config is, while this runs after it. Re-registering is idempotent.
    if (Get-Command Register-OverlayHotkeys -ErrorAction SilentlyContinue) { Register-OverlayHotkeys }
}


function Toggle-PinnedWindow {
    if ($script:window.IsVisible) { $script:window.Hide() }
    else {
        $script:window.Show()
        $script:window.Topmost = $true
        Apply-IslandWindowBehavior
        if (Test-IslandMode) { Position-IslandWindow }
    }
}

# Tray-click entry point. Kept separate from Toggle-PinnedWindow so the dropdown
# path and the pinned path cannot call back into each other.
function Toggle-Window {
    if ((Get-Command Test-DropdownMode -ErrorAction SilentlyContinue) -and (Test-DropdownMode)) {
        Toggle-Dropdown
        return
    }
    Toggle-PinnedWindow
}

function Get-ContextMenuScreenPoint {
    # ContextMenuStrip.Show and Control.MousePosition share WinForms screen
    # coordinates. WPF PointToScreen can use a different DPI coordinate space.
    return [System.Windows.Forms.Control]::MousePosition
}

# Submenus open to the right. Near the right edge of the screen Windows flips
# the deeper levels to the left, over their parent; start the menu far enough
# left that the settings menu, a group and its deepest submenu all fit.
function Get-SettingsMenuOrigin([System.Drawing.Point]$Point) {
    try {
        Sync-AppearanceMenus
        Invoke-MenuTranslate $script:ctxStrip.Items
        $empty = [System.Drawing.Size]::Empty
        $w2 = $script:ctxStrip.GetPreferredSize($empty).Width
        $w3 = 0; $w4 = 0
        foreach ($it in @($script:ctxStrip.Items)) {
            if ($it -isnot [System.Windows.Forms.ToolStripMenuItem] -or -not $it.HasDropDownItems) { continue }
            $w3 = [math]::Max($w3, $it.DropDown.GetPreferredSize($empty).Width)
            foreach ($sub in @($it.DropDownItems)) {
                if ($sub -is [System.Windows.Forms.ToolStripMenuItem] -and $sub.HasDropDownItems) {
                    $w4 = [math]::Max($w4, $sub.DropDown.GetPreferredSize($empty).Width)
                }
            }
        }
        $area = [System.Windows.Forms.Screen]::FromPoint($Point).WorkingArea
        $need = $w2 + $w3 + $w4 + 8
        $x = $Point.X
        if ($x + $need -gt $area.Right) { $x = [math]::Max($area.Left, $area.Right - $need) }
        return (New-Object System.Drawing.Point($x, $Point.Y))
    } catch {
        return $Point
    }
}

function Show-ContextMenuAtWpfPointer {
    param($EventArgs)

    $pt = Get-ContextMenuScreenPoint
    $EventArgs.Handled = $true
    [void][AIUsageMenuDrag]::AnyButtonPressed()   # clear the press that opened it
    $pt = Get-SettingsMenuOrigin $pt
    $script:ctxStrip.Show($pt)
    [AIUsageMenuDrag]::Activate($script:ctxStrip)
}

function Quit-App {
    $script:ReallyQuit = $true
    if ($script:pollTimer) { $script:pollTimer.Stop() }
    if ($script:tickTimer) { $script:tickTimer.Stop() }
    if ($script:jobTimer)  { $script:jobTimer.Stop() }
    if ($script:NotchHoverTimer) { $script:NotchHoverTimer.Stop() }
    if ($script:NotchHoldTimer) { $script:NotchHoldTimer.Stop() }
    if (Get-Command Stop-NotchRendering -ErrorAction SilentlyContinue) { Stop-NotchRendering }
    if ($script:pollJobs) {
        foreach ($job in @($script:pollJobs.Values)) {
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
        $script:pollJobs.Clear()
    }
    if ($script:loginWatchJobs) {
        foreach ($job in @($script:loginWatchJobs.Values)) {
            if ($job -is [System.Management.Automation.Job]) {
                Remove-Job $job -Force -ErrorAction SilentlyContinue
            }
        }
        $script:loginWatchJobs.Clear()
    }
    if (Get-Command Dispose-DropdownHotkey -ErrorAction SilentlyContinue) { Dispose-DropdownHotkey }
    if ($script:notify)    { $script:notify.Visible = $false; $script:notify.Dispose() }
    $script:window.Close()
    $script:window.Dispatcher.InvokeShutdown()
}


function Invoke-ProviderLogin {
    param(
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][string]$CliName
    )

    $resolved = Resolve-ProviderLoginCli $CliName
    if (-not $resolved) { return }

    $proc = Start-ProviderLoginProcess $resolved
    if (-not $proc) { return }

    if (-not $script:loginWatchJobs) { $script:loginWatchJobs = @{} }

    $script:loginWatchJobs[$Provider] = Start-OverlayBackgroundJob -ScriptBlock {
        param($ProcessId, $ProviderName)
        try {
            $p = Get-Process -Id $ProcessId -ErrorAction Stop
            $p.WaitForExit()
        } catch { }
        @{ Kind = 'ProviderLoginDone'; Provider = $ProviderName }
    } -ArgumentList @($proc.Id, $Provider)

    if ($script:jobTimer -and -not $script:jobTimer.IsEnabled) {
        $script:jobTimer.Start()
    }
}

function Complete-ProviderLoginWatchers {
    if (-not $script:loginWatchJobs -or $script:loginWatchJobs.Count -eq 0) { return }

    foreach ($provider in @($script:loginWatchJobs.Keys)) {
        $job = $script:loginWatchJobs[$provider]
        if ($job.State -eq 'Running' -or $job.State -eq 'NotStarted') { continue }

        try {
            $results = @(Receive-Job $job -ErrorAction SilentlyContinue)
            $r = $results | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('Provider') } | Select-Object -Last 1
            $name = if ($r) { [string]$r['Provider'] } else { $provider }
            $kinds = @(Get-ProviderLoginRefreshKinds $name)
            if ($kinds.Count -gt 0) {
                Start-AllRefreshJobs -Force -Kind $kinds
            }
        } catch {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log "Provider login watcher failed: $($_.Exception.Message)"
            }
        } finally {
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            $script:loginWatchJobs.Remove($provider)
        }
    }
}

function Sync-ProviderLoginMenuItems {
    if (-not $script:loginItems) { return }
    foreach ($cli in @($script:loginItems.Keys)) {
        $item = $script:loginItems[$cli]
        $resolved = Resolve-ProviderLoginCli $cli
        $item.Text = Get-ProviderLoginMenuCaption -CliName $cli -Resolved $resolved
        $item.Enabled = [bool]$resolved
    }
}

function Invoke-ManualRefresh {
    if ($script:State) {
        $script:State.Status = 'refreshing'
        $script:State.Message = 'refreshing...'
    }
    # Every card reads "Syncing" until its own data is back, not only Claude's.
    $script:ManualSyncKinds = @('ClaudeUsage', 'CodexStats', 'GrokUsage')

    if (Get-Command Clear-ProviderVersionCache -ErrorAction SilentlyContinue) { Clear-ProviderVersionCache }
    Start-AllRefreshJobs -Force

    if ($script:jobTimer -and -not $script:jobTimer.IsEnabled) {
        $script:jobTimer.Start()
    }

    if (Get-Command Update-OverlayViews -ErrorAction SilentlyContinue) { Update-OverlayViews } else { Update-AllSections; Update-IslandView }
    # Hand-drop brand.png paints on Refresh without Set / theme / restart.
    if (Get-Command Apply-FooterBrandMark -ErrorAction SilentlyContinue) {
        Apply-FooterBrandMark
    }
}

# ---------------------------------------------------------------------------
# Right-click context menu - dark-themed WinForms ContextMenuStrip shown
# from the WPF panel's MouseRightButtonUp event.
# ---------------------------------------------------------------------------
$script:themeItems   = @{}
$script:opacityItems = @{}
$script:sectionItems = @{}
$script:loginItems  = @{}
$script:loginWatchJobs = @{}

# Dark colour table for the strip renderer
# Resolve already-loaded assembly paths so Add-Type can find them under .NET 6+
$_sdPath  = [System.Drawing.Color].Assembly.Location
$_swfPath = [System.Windows.Forms.Form].Assembly.Location
$_gfxPath = [System.Drawing.Graphics].Assembly.Location   # Graphics/SolidBrush/Pen live in a separate assembly from Color
# ToolStripItem derives from Component, which lives in its own assembly on .NET 6+.
$_cmPath  = [System.ComponentModel.Component].Assembly.Location
$_menuRefs = @($_sdPath, $_swfPath, $_gfxPath, $_cmPath) | Where-Object { $_ } | Select-Object -Unique
Add-Type -ReferencedAssemblies $_menuRefs -TypeDefinition @'
using System.Drawing;
using System.Windows.Forms;
public class DarkColorTable : ProfessionalColorTable {
    static Color Bg  { get { return Color.FromArgb(28, 28, 30); } }
    static Color Sel { get { return Color.FromArgb(46, 46, 49); } }
    public override Color MenuItemSelected              { get { return Sel; } }
    public override Color MenuItemBorder                { get { return Sel; } }
    public override Color MenuBorder                    { get { return Color.FromArgb(58, 58, 61); } }
    public override Color ToolStripDropDownBackground   { get { return Bg; } }
    public override Color ImageMarginGradientBegin      { get { return Bg; } }
    public override Color ImageMarginGradientMiddle     { get { return Bg; } }
    public override Color ImageMarginGradientEnd        { get { return Bg; } }
    public override Color CheckBackground               { get { return Sel; } }
    public override Color CheckSelectedBackground       { get { return Sel; } }
    public override Color SeparatorDark                 { get { return Color.FromArgb(46, 46, 49); } }
    public override Color SeparatorLight                { get { return Bg; } }
    public override Color MenuItemSelectedGradientBegin { get { return Sel; } }
    public override Color MenuItemSelectedGradientEnd   { get { return Sel; } }
    public override Color MenuItemPressedGradientBegin  { get { return Sel; } }
    public override Color MenuItemPressedGradientEnd    { get { return Sel; } }
    public override Color MenuStripGradientBegin        { get { return Bg; } }
    public override Color MenuStripGradientEnd          { get { return Bg; } }
}
public class DarkMenuRenderer : ToolStripProfessionalRenderer {
    public DarkMenuRenderer() : base(new DarkColorTable()) { RoundedEdges = false; }
    static bool IsTag(ToolStripItem item, string tag) { return !object.ReferenceEquals(item, null) && (item.Tag as string) == tag; }
    static System.Drawing.Drawing2D.GraphicsPath Round(RectangleF r, float rad) {
        var p = new System.Drawing.Drawing2D.GraphicsPath();
        float d = rad * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
    // Rounded highlight inset from the edges; toggle rows also draw their switch.
    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e) {
        Graphics g = e.Graphics;
        var bounds = new Rectangle(Point.Empty, e.Item.Size);
        using (var b = new SolidBrush(Color.FromArgb(28, 28, 30))) g.FillRectangle(b, bounds);
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        if (IsTag(e.Item, "grip")) {
            // Drag handle: no hover highlight; a 2x3 dot grip on the right.
            using (var b = new SolidBrush(Color.FromArgb(110, 110, 115))) {
                float gx = bounds.Width - 26f, gy = bounds.Height / 2f - 6f;
                for (int row = 0; row < 3; row++)
                    for (int col = 0; col < 2; col++)
                        g.FillEllipse(b, gx + col * 5f, gy + row * 5f, 2.6f, 2.6f);
            }
            return;
        }
        if ((e.Item.Selected || e.Item.Pressed) && e.Item.Enabled && !IsTag(e.Item, "header")) {
            var r = new RectangleF(4, 1, bounds.Width - 8, bounds.Height - 2);
            using (var path = Round(r, 6f))
            using (var b = new SolidBrush(Color.FromArgb(46, 46, 49)))
            using (var p = new Pen(Color.FromArgb(70, 70, 74))) { g.FillPath(b, path); g.DrawPath(p, path); }
        }
        var mi = e.Item as ToolStripMenuItem;
        if (!object.ReferenceEquals(mi, null) && IsTag(mi, "toggle")) {
            float h = 16f, w = 30f;
            float x = bounds.Width - w - 12f, y = (bounds.Height - h) / 2f;
            var track = new RectangleF(x, y, w, h);
            using (var path = Round(track, h / 2f))
            using (var b = new SolidBrush(mi.Checked ? Color.FromArgb(48, 209, 88) : Color.FromArgb(72, 72, 76)))
                g.FillPath(b, path);
            float k = h - 4f;
            float kx = mi.Checked ? x + w - k - 2f : x + 2f;
            using (var b = new SolidBrush(mi.Checked ? Color.White : Color.FromArgb(229, 229, 234)))
                g.FillEllipse(b, kx, y + 2f, k, k);
        }
    }
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
        string tag = e.Item.Tag as string;
        var ami = e.Item as ToolStripMenuItem;
        if (tag != null && tag.StartsWith("acct:") && !object.ReferenceEquals(ami, null) && e.Text == ami.ShortcutKeyDisplayString) {
            if (tag == "acct:ok") e.TextColor = Color.FromArgb(48, 209, 88);
            else if (tag == "acct:auth") e.TextColor = Color.FromArgb(255, 69, 58);
            else if (tag == "acct:stale") e.TextColor = Color.FromArgb(255, 159, 10);
            else e.TextColor = Color.FromArgb(142, 142, 147);
            base.OnRenderItemText(e);
            return;
        }
        if (IsTag(e.Item, "grip")) {
            e.TextColor = Color.FromArgb(245, 245, 247);
        } else if (IsTag(e.Item, "header")) {
            e.TextColor = Color.FromArgb(142, 142, 147);
        } else if (e.Item.Enabled) {
            e.TextColor = Color.FromArgb(242, 242, 247);
        }
        base.OnRenderItemText(e);
    }
    protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e) {
        e.ArrowColor = Color.FromArgb(152, 152, 157);
        base.OnRenderArrow(e);
    }
    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e) {
        var r = new Rectangle(Point.Empty, e.Item.Size);
        using (var b = new SolidBrush(Color.FromArgb(28, 28, 30))) e.Graphics.FillRectangle(b, r);
        using (var p = new Pen(Color.FromArgb(46, 46, 49))) e.Graphics.DrawLine(p, 12, r.Height / 2, r.Width - 12, r.Height / 2);
    }
    protected override void OnRenderImageMargin(ToolStripRenderEventArgs e) {
        using (var b = new SolidBrush(Color.FromArgb(28, 28, 30))) e.Graphics.FillRectangle(b, e.AffectedBounds);
    }
    // Toggle rows are shown by their switch; their icon draws plainly, without
    // the checked-state box WinForms would put behind it.
    static bool IsSwatch(ToolStripItem item) {
        string t = object.ReferenceEquals(item, null) ? null : item.Tag as string;
        return t != null && t.StartsWith("swatch");
    }
    protected override void OnRenderItemImage(ToolStripItemImageRenderEventArgs e) {
        if (IsTag(e.Item, "toggle")) {
            if (e.Image != null) e.Graphics.DrawImage(e.Image, e.ImageRectangle);
            return;
        }
        if (IsSwatch(e.Item)) {
            // Colour rows: the swatch itself, with a blue ring around the one in use.
            if (e.Image != null) e.Graphics.DrawImage(e.Image, e.ImageRectangle);
            var mi = e.Item as ToolStripMenuItem;
            if (!object.ReferenceEquals(mi, null) && mi.Checked) {
                var g = e.Graphics;
                var prev = g.SmoothingMode;
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                var r = new RectangleF(e.ImageRectangle.X - 2.5f, e.ImageRectangle.Y - 2.5f, e.ImageRectangle.Width + 4f, e.ImageRectangle.Height + 4f);
                using (var path = Round(r, 6f))
                using (var p = new Pen(Color.FromArgb(10, 132, 255), 2f)) g.DrawPath(p, path);
                g.SmoothingMode = prev;
            }
            return;
        }
        base.OnRenderItemImage(e);
    }
    protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e) {
        if (IsTag(e.Item, "toggle") || IsSwatch(e.Item)) return;
        Graphics g = e.Graphics;
        Rectangle r = e.ImageRectangle;
        if (r.IsEmpty) return;
        var prevMode = g.SmoothingMode;
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        using (var pen = new Pen(Color.FromArgb(10, 132, 255), 1.8f)) {
            float x1 = r.Left + 3, y1 = r.Top + r.Height / 2f;
            float x2 = r.Left + r.Width / 2f - 1, y2 = r.Bottom - 4;
            float x3 = r.Right - 3, y3 = r.Top + 4;
            g.DrawLine(pen, x1, y1, x2, y2);
            g.DrawLine(pen, x2, y2, x3, y3);
        }
        g.SmoothingMode = prevMode;
    }
}
'@

# Drag a popup menu by its title row. A timer follows the pointer while the
# left button is held, so fast moves never outrun the item's mouse events.
if (-not ([System.Management.Automation.PSTypeName]'AIUsageMenuDrag').Type) {
Add-Type -ReferencedAssemblies $_menuRefs -TypeDefinition @'
using System;
using System.Drawing;
using System.Windows.Forms;
public static class AIUsageMenuDrag {
    static ToolStripDropDown target;
    static Point offset;
    static System.Windows.Forms.Timer timer;
    public static bool Active { get { return !object.ReferenceEquals(target, null); } }
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    // The overlay never activates, so a menu shown from it would never hear
    // about clicks in other apps. Activating the menu lets it close normally.
    public static void Activate(ToolStripDropDown dd) {
        try { if (dd.IsHandleCreated) SetForegroundWindow(dd.Handle); } catch { }
    }
    // Any mouse button down now, or pressed since the last call.
    public static bool AnyButtonPressed() {
        bool hit = false;
        foreach (int vk in new int[] { 1, 2, 4 }) { if ((GetAsyncKeyState(vk) & 0x8001) != 0) hit = true; }
        return hit;
    }
    public static void Attach(ToolStripDropDown dd, ToolStripItem handle) {
        handle.MouseDown += delegate(object s, MouseEventArgs e) {
            if (e.Button != MouseButtons.Left) return;
            foreach (ToolStripItem it in dd.Items) {
                ToolStripDropDownItem di = it as ToolStripDropDownItem;
                if (!object.ReferenceEquals(di, null) && di.DropDown.Visible) di.HideDropDown();
            }
            target = dd;
            Point p = Control.MousePosition;
            offset = new Point(p.X - dd.Left, p.Y - dd.Top);
            if (object.ReferenceEquals(timer, null)) {
                timer = new System.Windows.Forms.Timer();
                timer.Interval = 10;
                timer.Tick += Tick;
            }
            timer.Start();
        };
    }
    static void Tick(object s, EventArgs e) {
        if (object.ReferenceEquals(target, null) || !target.Visible || (Control.MouseButtons & MouseButtons.Left) == 0) {
            timer.Stop();
            target = null;
            return;
        }
        Point p = Control.MousePosition;
        Point np = new Point(p.X - offset.X, p.Y - offset.Y);
        if (np != target.Location) target.Location = np;
    }
}
'@
}

$darkFg   = [System.Drawing.Color]::FromArgb(242, 242, 247)
$darkBg   = [System.Drawing.Color]::FromArgb(28, 28, 30)
$menuFont = New-Object System.Drawing.Font('Segoe UI', 10)

function New-StripItem([string]$text, [scriptblock]$onClick) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($text)
    $mi.ForeColor = $darkFg
    $mi.BackColor = $darkBg
    $mi.Font      = $menuFont
    if ($onClick) { $mi.add_Click($onClick) }
    return $mi
}

function Get-SectionVisible([string]$key) {
    if (-not $script:Cfg -or -not $script:Cfg.Sections) { return $true }

    $sections = $script:Cfg.Sections
    if ($sections -is [System.Collections.IDictionary] -and $sections.Contains($key)) {
        return [bool]$sections[$key]
    }
    if ($sections.PSObject.Properties.Name -contains $key) {
        return [bool]$sections.$key
    }
    return $true
}

function Get-SectionExpanded([string]$key) {
    return Get-SectionVisible $key
}

function Sync-SectionMenuItems {
    foreach ($key in $script:UnifiedSectionKeys) {
        if ($script:sectionItems.ContainsKey($key)) {
            $script:sectionItems[$key].Checked = Get-SectionVisible $key
        }
    }
}

$script:ctxStrip = New-Object System.Windows.Forms.ContextMenuStrip
$script:darkRenderer = New-Object DarkMenuRenderer
$script:ctxStrip.Renderer  = $script:darkRenderer
# Submenu dropdowns render via the global manager renderer, not the strip's own,
# so set it too - otherwise nested menu items keep the unreadable light highlight.
[System.Windows.Forms.ToolStripManager]::Renderer = $script:darkRenderer
$script:ctxStrip.BackColor = $darkBg
$script:ctxStrip.ForeColor = $darkFg
$script:ctxStrip.Font      = $menuFont
$script:ctxStrip.ShowImageMargin = $true

function Add-Separator {
    $sep = New-Object System.Windows.Forms.ToolStripSeparator
    $sep.BackColor = $darkBg; $sep.ForeColor = $darkFg
    [void]$script:ctxStrip.Items.Add($sep)
}

$script:miIsland = New-StripItem 'Notch (hover to peek)' $null
$script:miNotchOpen = New-StripItem 'Open full panel' { Start-NotchExpand }
$script:miNotchFold = New-StripItem 'Fold back to notch' { Start-NotchCollapse }
[void]$script:miIsland.DropDownItems.Add($script:miNotchOpen)
[void]$script:miIsland.DropDownItems.Add($script:miNotchFold)
[void]$script:ctxStrip.Items.Add($script:miIsland)
Add-Separator

# ---------------------------------------------------------------------------
# Threshold alert system
# ---------------------------------------------------------------------------
$script:AlertKeys = @('five_hour', 'seven_day', 'seven_day_fable', 'seven_day_opus')
$script:Notified = @{}
foreach ($alertKey in $script:AlertKeys) {
    $script:Notified[$alertKey] = @{ Level = 0; Reset = $null }
}

function ConvertTo-AlertStateMap($value) {
    $map = @{}
    foreach ($alertKey in $script:AlertKeys) {
        $map[$alertKey] = @{ Level = 0; Reset = $null }
    }

    if ($null -eq $value) { return $map }

    foreach ($alertKey in $script:AlertKeys) {
        $entry = $null
        if ($value -is [System.Collections.IDictionary]) {
            if (-not $value.Contains($alertKey)) { continue }
            $entry = $value[$alertKey]
        } else {
            $prop = $value.PSObject.Properties[$alertKey]
            if (-not $prop) { continue }
            $entry = $prop.Value
        }

        if ($null -eq $entry) { continue }

        if ($entry -is [System.Collections.IDictionary]) {
            $map[$alertKey] = @{
                Level = if ($entry.Contains('Level') -and $null -ne $entry['Level']) { [int]$entry['Level'] } else { 0 }
                Reset = if ($entry.Contains('Reset')) { $entry['Reset'] } else { $null }
            }
            continue
        }

        $levelProp = $entry.PSObject.Properties['Level']
        $resetProp = $entry.PSObject.Properties['Reset']
        if ($levelProp -or $resetProp) {
            $map[$alertKey] = @{
                Level = if ($levelProp -and $null -ne $levelProp.Value) { [int]$levelProp.Value } else { 0 }
                Reset = if ($resetProp) { $resetProp.Value } else { $null }
            }
            continue
        }

        $map[$alertKey] = @{ Level = [int]$entry; Reset = $null }
    }

    return $map
}

function Export-AlertStateToConfig {
    if (-not $script:Cfg) { return }
    $script:Cfg['AlertState'] = ConvertTo-AlertStateMap $script:Notified
}

function Import-AlertStateFromConfig {
    if (-not $script:Cfg) { return }
    $script:Notified = ConvertTo-AlertStateMap $script:Cfg.AlertState
    Export-AlertStateToConfig
}

Import-AlertStateFromConfig

function Get-AlertLabel([string]$key) {
    switch ($key) {
        'five_hour'        { '5-hour session' }
        'seven_day'        { 'Weekly limit' }
        'seven_day_fable'  { 'Fable weekly' }
        'seven_day_opus'   { 'Opus weekly' }
        default            { $key }
    }
}

function Get-AlertResetWindow([string]$key, $resetAt = $null) {
    if ($null -eq $resetAt -and $script:State -and $script:State.Data) {
        $quota = $script:State.Data.PSObject.Properties[$key]
        if ($quota -and $quota.Value) {
            $resetProp = $quota.Value.PSObject.Properties['resets_at']
            if ($resetProp) { $resetAt = $resetProp.Value }
        }
    }

    if ($null -eq $resetAt) { return $null }
    return [string]$resetAt
}

function Get-AlertState([string]$key, $resetWindow = $null) {
    if (-not $script:Notified) { $script:Notified = @{} }
    if (-not $script:Notified.ContainsKey($key)) {
        $script:Notified[$key] = @{ Level = 0; Reset = $resetWindow }
    }

    $state = $script:Notified[$key]
    if ($state -isnot [System.Collections.IDictionary]) {
        $state = @{ Level = [int]$state; Reset = $resetWindow }
        $script:Notified[$key] = $state
    } elseif ($resetWindow -and $state['Reset'] -and $state['Reset'] -ne $resetWindow) {
        $state['Level'] = 0
        $state['Reset'] = $resetWindow
    } elseif ($resetWindow -and -not $state['Reset']) {
        $state['Reset'] = $resetWindow
    }

    return $state
}

function Set-AlertState([string]$key, [int]$level, $resetWindow = $null) {
    $state = Get-AlertState $key $resetWindow
    $oldLevel = [int]$state['Level']
    $oldReset = $state['Reset']
    $state['Level'] = $level
    $state['Reset'] = $resetWindow
    Export-AlertStateToConfig
    if (($oldLevel -ne $level -or $oldReset -ne $resetWindow) -and (Get-Command Save-UnifiedState -ErrorAction SilentlyContinue)) {
        Save-UnifiedState
    }
}

function Get-AlertLevel($util) {
    if ($null -eq $util) { return 0 }
    $u = [double]$util
    if ($u -ge $script:CritPct) { return [int]$script:CritPct }
    if ($u -ge $script:WarnPct) { return [int]$script:WarnPct }
    return 0
}

function Invoke-TestAlert {
    if (-not $script:notify) { return }
    $script:notify.ShowBalloonTip(
        4000,
        (Convert-I18nString 'AI Usage Overlay Test' (Get-UiLanguage)),
        (Convert-I18nString 'Threshold alerts are working.' (Get-UiLanguage)),
        [System.Windows.Forms.ToolTipIcon]::Info
    )
}

function Dismiss-CurrentAlerts {
    if (-not $script:State -or -not $script:State.Data) { return }

    foreach ($key in $script:AlertKeys) {
        $quota = $script:State.Data.PSObject.Properties[$key]
        if (-not $quota -or -not $quota.Value) { continue }

        $utilProp = $quota.Value.PSObject.Properties['utilization']
        if (-not $utilProp) { continue }

        $level = Get-AlertLevel $utilProp.Value
        if ($level -le 0) { continue }

        $resetProp = $quota.Value.PSObject.Properties['resets_at']
        $resetWindow = if ($resetProp) { Get-AlertResetWindow $key $resetProp.Value } else { Get-AlertResetWindow $key }
        Set-AlertState $key $level $resetWindow
    }
}

function Check-Alert([string]$key, $util, $resetAt = $null) {
    if (-not [bool]$script:Cfg.ShowAlerts) { return }
    if (-not $script:notify) { return }
    if ($null -eq $util) { return }

    $u = [double]$util
    $resetWindow = Get-AlertResetWindow $key $resetAt
    $state = Get-AlertState $key $resetWindow
    $last = [int]$state['Level']

    # Reset when usage drops back below warn threshold
    if ($u -lt $script:WarnPct) {
        Set-AlertState $key 0 $resetWindow
        return
    }

    # Fire CRITICAL alert (crosses into CritPct band)
    if ($u -ge $script:CritPct -and $last -lt $script:CritPct) {
        $label = Get-AlertLabel $key
        $eta = ''
        if ($script:History -and $script:History.Count -gt 2) {
            $mins = Get-Eta $script:History $key
            if ($null -ne $mins) { $eta = " (~$mins min to limit)" }
        }
        $script:notify.ShowBalloonTip(5000, (Convert-I18nString 'Claude Usage Critical' (Get-UiLanguage)), (Convert-I18nString "$label at $([int]$u)%$eta" (Get-UiLanguage)), [System.Windows.Forms.ToolTipIcon]::Warning)
        Set-AlertState $key ([int]$script:CritPct) $resetWindow
        return
    }

    # Fire WARN alert (crosses into WarnPct band)
    if ($u -ge $script:WarnPct -and $last -lt $script:WarnPct) {
        $label = Get-AlertLabel $key
        $script:notify.ShowBalloonTip(4000, (Convert-I18nString 'Claude Usage Warning' (Get-UiLanguage)), (Convert-I18nString "$label at $([int]$u)%" (Get-UiLanguage)), [System.Windows.Forms.ToolTipIcon]::Info)
        Set-AlertState $key ([int]$script:WarnPct) $resetWindow
        return
    }
}

# ---------------------------------------------------------------------------
# Context menu items
# ---------------------------------------------------------------------------

# Actions
[void]$script:ctxStrip.Items.Add((New-StripItem 'Test alert' { Invoke-TestAlert }))
[void]$script:ctxStrip.Items.Add((New-StripItem 'Dismiss current alert' { Dismiss-CurrentAlerts }))
Add-Separator
[void]$script:ctxStrip.Items.Add((New-StripItem 'Copy stats to clipboard' { Copy-Stats }))

# Official vendor pages — one shared shape (provider → Usage + Docs). Hidden
# HUD tiles still keep their links. Labels/URLs vary per vendor on purpose.
$miPlatforms = New-StripItem 'Platforms' $null
$linkGroups = Get-ProviderLinkMenuShape | Group-Object ProviderId
foreach ($group in $linkGroups) {
    $first = @($group.Group)[0]
    $sub = New-StripItem $first.ProviderLabel $null
    foreach ($link in @($group.Group)) {
        $providerId = $link.ProviderId
        $kind = $link.Kind
        [void]$sub.DropDownItems.Add((New-StripItem $link.Label ([scriptblock]::Create("Open-ProviderLink -Provider '$providerId' -Kind '$kind'"))))
    }
    [void]$miPlatforms.DropDownItems.Add($sub)
}
[void]$script:ctxStrip.Items.Add($miPlatforms)
Add-Separator

# Brand (footer mark) - submenu keeps the strip short
$miBrand = New-StripItem 'Brand' $null
[void]$miBrand.DropDownItems.Add((New-StripItem 'Set footer brand…' { Invoke-SetFooterBrand }))
[void]$miBrand.DropDownItems.Add((New-StripItem 'Reset JayOS mark' { Invoke-ResetFooterBrand }))
[void]$script:ctxStrip.Items.Add($miBrand)

# Version (shown under System)
$script:DisplayVersion = '0.0.3 beta'
$script:miUpdate = New-StripItem 'Check for updates' { Invoke-UpdateButton }
[void]$script:ctxStrip.Items.Add($script:miUpdate)
$miVersion = New-StripItem ("Version {0}" -f $script:DisplayVersion) $null
$miVersion.Enabled = $false
[void]$script:ctxStrip.Items.Add($miVersion)
Add-Separator

# Providers — first-run dialog + quick Show/Hide toggles
$miProviders = New-StripItem 'Providers' $null
$miChooseProviders = New-StripItem 'Choose providers…' {
    if (Get-Command Invoke-ProviderPickerFromTray -ErrorAction SilentlyContinue) {
        # Defer ShowDialog until after tray menu closes (QA D2).
        if ($script:ctxStrip -and $script:ctxStrip.IsHandleCreated) {
            [void]$script:ctxStrip.BeginInvoke([Action]{ Invoke-ProviderPickerFromTray })
        } else {
            Invoke-ProviderPickerFromTray
        }
    }
}
[void]$miProviders.DropDownItems.Add($miChooseProviders)
[void]$miProviders.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
foreach ($pair in @(@('Claude','claude'), @('Codex','codex'), @('Cursor','cursor'), @('Grok','grok'))) {
    $label = $pair[0]
    $key = $pair[1]
    $item = New-StripItem $label ([scriptblock]::Create("`$visible = -not (Get-SectionVisible '$key'); Set-SectionVisible '$key' `$visible; `$script:Cfg.Sections['$key'] = `$visible; Save-UnifiedState; Sync-SectionMenuItems"))
    $item.CheckOnClick = $false
    $item.Checked = Get-SectionVisible $key
    $script:sectionItems[$key] = $item
    [void]$miProviders.DropDownItems.Add($item)
}
[void]$script:ctxStrip.Items.Add($miProviders)

# Log in: spawn a visible CLI (`claude login` / `codex login` / `grok login`).
Add-Separator
$miLogin = New-StripItem 'Log in' $null
foreach ($pair in @(@('Claude','claude'), @('Codex','codex'), @('Grok','grok'))) {
    $provider = $pair[0]
    $cli = $pair[1]
    $sub = New-StripItem (Get-ProviderLoginMenuCaption -CliName $cli -Resolved $null) ([scriptblock]::Create("Invoke-ProviderLogin -Provider '$provider' -CliName '$cli'"))
    $script:loginItems[$cli] = $sub
    [void]$miLogin.DropDownItems.Add($sub)
}
[void]$script:ctxStrip.Items.Add($miLogin)
Sync-ProviderLoginMenuItems
$script:ctxStrip.add_Opening({ Sync-ProviderLoginMenuItems })

# View mode: pinned panel vs Quake-style drop-down on a global hotkey
$script:viewModeItems = @{}
function Sync-ViewModeMenuItems {
    $mode = if (Test-DropdownMode) { 'Quake' } else { 'Pinned' }
    foreach ($k in @($script:viewModeItems.Keys)) { $script:viewModeItems[$k].Checked = ($k -eq $mode) }
    if ($script:dropdownHotkeyItems) {
        $cur = [string]$script:Cfg['DropdownHotkey']
        foreach ($k in @($script:dropdownHotkeyItems.Keys)) { $script:dropdownHotkeyItems[$k].Checked = ($k -eq $cur) }
    }
    if ($script:dropdownMonitorItems) {
        $cur = [string]$script:Cfg['DropdownMonitor']
        foreach ($k in @($script:dropdownMonitorItems.Keys)) { $script:dropdownMonitorItems[$k].Checked = ($k -eq $cur) }
    }
}

$miView = New-StripItem 'View' $null
foreach ($pair in @(@('Pinned panel', 'Pinned'), @('Quake terminal (hotkey)', 'Quake'))) {
    $lbl = $pair[0]; $mode = $pair[1]
    $sub = New-StripItem $lbl ([scriptblock]::Create(
        "if ('$mode' -eq 'Quake') { Enter-DropdownMode } else { Exit-DropdownMode }; Save-UnifiedState; Sync-ViewModeMenuItems"))
    $sub.CheckOnClick = $false
    $script:viewModeItems[$mode] = $sub
    [void]$miView.DropDownItems.Add($sub)
}
[void]$miView.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# Hotkey presets. Any combo the parser understands can be set in the state file;
# these are the ones unlikely to collide with editors or browsers.
$script:dropdownHotkeyItems = @{}
$miHotkey = New-StripItem 'Drop-down hotkey' $null
foreach ($combo in @('Shift+F11', 'Shift+F12', 'Ctrl+Alt+`', 'Ctrl+Alt+U', 'Win+`')) {
    $c = $combo
    $sub = New-StripItem $c ([scriptblock]::Create("Set-DropdownHotkey '$c'; Save-UnifiedState; Sync-ViewModeMenuItems"))
    $sub.CheckOnClick = $false
    $script:dropdownHotkeyItems[$c] = $sub
    [void]$miHotkey.DropDownItems.Add($sub)
}
[void]$miView.DropDownItems.Add($miHotkey)

# Monitor picker, built from the live screen list so labels show real resolutions.
$script:dropdownMonitorItems = @{}
$miMonitor = New-StripItem 'Drop-down monitor' $null
foreach ($pair in @(@('Primary', 'Primary'), @('Monitor with mouse', 'Active'))) {
    $lbl = $pair[0]; $val = $pair[1]
    $sub = New-StripItem $lbl ([scriptblock]::Create("Set-DropdownMonitor '$val'; Save-UnifiedState; Sync-ViewModeMenuItems"))
    $sub.CheckOnClick = $false
    $script:dropdownMonitorItems[$val] = $sub
    [void]$miMonitor.DropDownItems.Add($sub)
}
[void]$miMonitor.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$screenIndex = 0
foreach ($scr in (Get-DropdownScreens)) {
    $screenIndex++
    $dev = $scr.DeviceName
    $lbl = '{0}: {1}x{2}{3}' -f $screenIndex, $scr.Bounds.Width, $scr.Bounds.Height, $(if ($scr.Primary) { ' (primary)' } else { '' })
    $sub = New-StripItem $lbl ([scriptblock]::Create("Set-DropdownMonitor '$dev'; Save-UnifiedState; Sync-ViewModeMenuItems"))
    $sub.CheckOnClick = $false
    $script:dropdownMonitorItems[$dev] = $sub
    [void]$miMonitor.DropDownItems.Add($sub)
}
[void]$miView.DropDownItems.Add($miMonitor)

$script:miHideFocus = New-StripItem 'Hide when it loses focus' {
    $script:Cfg['DropdownHideOnFocusLoss'] = -not [bool]$script:Cfg['DropdownHideOnFocusLoss']
    $miHideFocus.Checked = [bool]$script:Cfg['DropdownHideOnFocusLoss']
    Save-UnifiedState
}
$miHideFocus.CheckOnClick = $false
$miHideFocus.Checked = [bool]$script:Cfg['DropdownHideOnFocusLoss']
[void]$miView.DropDownItems.Add($miHideFocus)
[void]$script:ctxStrip.Items.Add($miView)
Sync-ViewModeMenuItems

# Global hotkeys for the everyday actions. Both ship unbound, so each submenu
# leads with an explicit way back to that state.
$script:hotkeyMenuItems = @{}
function Sync-OverlayHotkeyMenuItems {
    if (-not (Get-Command Get-HotkeyAction -ErrorAction SilentlyContinue)) { return }
    foreach ($action in @($script:hotkeyMenuItems.Keys)) {
        $entry = Get-HotkeyAction $action
        if (-not $entry) { continue }
        $cur = [string]$script:Cfg[$entry.ConfigKey]
        $items = $script:hotkeyMenuItems[$action]
        foreach ($k in @($items.Keys)) { $items[$k].Checked = ($k -eq $cur) }
    }
}

# Presets are Ctrl+Alt(+Shift)+F-key only: apps rarely bind them, and an F-key
# never types a character, so AltGr (sent as Ctrl+Alt) cannot collide. Skipped:
# Ctrl+Alt+F7/F8 (JetBrains), Ctrl+Alt+F12 (Intel graphics panel), and
# Ctrl+Alt+Shift+F9/F10, which tests/HotkeyProbe.ps1 claims while it runs.
$miHotkeys = New-StripItem 'Hotkeys' $null
foreach ($spec in @(
    @{ Action = 'Toggle';  Label = 'Show/hide overlay'; Combos = @('Ctrl+Alt+F6', 'Ctrl+Alt+F11', 'Ctrl+Alt+Shift+F6', 'Ctrl+Alt+Shift+F11') },
    @{ Action = 'Refresh'; Label = 'Refresh now';       Combos = @('Ctrl+Alt+F5', 'Ctrl+Alt+F10', 'Ctrl+Alt+Shift+F5', 'Ctrl+Alt+Shift+F12') })) {
    $action = $spec.Action
    $items = @{}
    $miAction = New-StripItem $spec.Label $null
    $none = New-StripItem 'None (unbound)' ([scriptblock]::Create("Set-OverlayHotkey '$action' ''; Save-UnifiedState; Sync-OverlayHotkeyMenuItems"))
    $none.CheckOnClick = $false
    $items[''] = $none
    [void]$miAction.DropDownItems.Add($none)
    [void]$miAction.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    foreach ($combo in $spec.Combos) {
        $c = $combo
        $sub = New-StripItem $c ([scriptblock]::Create("Set-OverlayHotkey '$action' '$c'; Save-UnifiedState; Sync-OverlayHotkeyMenuItems"))
        $sub.CheckOnClick = $false
        $items[$c] = $sub
        [void]$miAction.DropDownItems.Add($sub)
    }
    $script:hotkeyMenuItems[$action] = $items
    [void]$miHotkeys.DropDownItems.Add($miAction)
}
[void]$script:ctxStrip.Items.Add($miHotkeys)
Sync-OverlayHotkeyMenuItems
# The saved config loads after this file, so re-sync the checks on every open.
$script:ctxStrip.add_Opening({ Sync-OverlayHotkeyMenuItems })
Add-Separator

# Snap to corner
$miSnap = New-StripItem 'Snap to corner' $null
foreach ($pair in @(@('Top right','TR'), @('Top left','TL'), @('Bottom right','BR'), @('Bottom left','BL'))) {
    $lbl = $pair[0]; $key = $pair[1]
    $sub = New-StripItem $lbl ([scriptblock]::Create("Snap-ToCorner '$key'"))
    [void]$miSnap.DropDownItems.Add($sub)
}
[void]$script:ctxStrip.Items.Add($miSnap)

# Opacity
$miOp = New-StripItem 'Opacity' $null
foreach ($pair in @(@('100%',1.0), @('80%',0.8), @('60%',0.6), @('40%',0.4))) {
    $lbl = $pair[0]; $val = $pair[1]
    $sub = New-StripItem $lbl ([scriptblock]::Create("`$script:Cfg.Opacity=$val; Apply-UnifiedSettings; Save-UnifiedState; foreach(`$x in `$script:opacityItems.Values){`$x.Checked=`$false}; `$script:opacityItems['$lbl'].Checked=`$true"))
    $sub.CheckOnClick = $false
    $sub.Checked = ([double]$script:Cfg.Opacity -eq [double]$val)
    $script:opacityItems[$lbl] = $sub
    [void]$miOp.DropDownItems.Add($sub)
}
[void]$script:ctxStrip.Items.Add($miOp)

# Themes are no longer offered in Settings (meters follow usage on every
# theme); the saved theme still sets the panel colours.

# Panel background
$script:bgItems = [ordered]@{}
$miBg = New-StripItem 'Background' $null
foreach ($pair in $script:PanelBgPresets.GetEnumerator()) {
    $bgHex = [string]$pair.Value
    $sub = New-StripItem ([string]$pair.Key) ([scriptblock]::Create("Set-PanelBackground '$bgHex'"))
    $sub.CheckOnClick = $false
    $script:bgItems[$bgHex] = $sub
    [void]$miBg.DropDownItems.Add($sub)
}
[void]$miBg.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$script:bgCustomItem = New-StripItem 'Custom…' { Invoke-CustomPanelBackground }
$script:bgCustomItem.CheckOnClick = $false
[void]$miBg.DropDownItems.Add($script:bgCustomItem)
[void]$script:ctxStrip.Items.Add($miBg)

# Language
$script:langItems = [ordered]@{}
$miLang = New-StripItem 'Language' $null
foreach ($pair in $script:I18nLangs.GetEnumerator()) {
    $code = [string]$pair.Key
    $sub = New-StripItem ([string]$pair.Value) ([scriptblock]::Create("Set-UiLanguage '$code'"))
    $sub.CheckOnClick = $false
    $script:langItems[$code] = $sub
    [void]$miLang.DropDownItems.Add($sub)
}
[void]$script:ctxStrip.Items.Add($miLang)
Add-Separator

# Toggles
$miStats = New-StripItem 'Show stats panel' {
    $script:Cfg.ShowStats = -not [bool]$script:Cfg.ShowStats
    $miStats.Checked = [bool]$script:Cfg.ShowStats
    Apply-UnifiedSettings; Save-UnifiedState
}
$miStats.Checked = [bool]$script:Cfg.ShowStats
[void]$script:ctxStrip.Items.Add($miStats)

$miCompact = New-StripItem 'Compact mode' {
    $script:Cfg.Compact = -not [bool]$script:Cfg.Compact
    $miCompact.Checked = [bool]$script:Cfg.Compact
    Apply-UnifiedSettings
    Update-AllSections
    Resize-ToContent
    Save-UnifiedState
}
$miCompact.Checked = [bool]$script:Cfg.Compact
[void]$script:ctxStrip.Items.Add($miCompact)

$miAlerts = New-StripItem 'Threshold alerts' {
    $script:Cfg.ShowAlerts = -not [bool]$script:Cfg.ShowAlerts
    $miAlerts.Checked = [bool]$script:Cfg.ShowAlerts
    Save-UnifiedState
}
$miAlerts.Checked = [bool]$script:Cfg.ShowAlerts
[void]$script:ctxStrip.Items.Add($miAlerts)

$miGraph = New-StripItem 'Show history graph' {
    $script:Cfg.ShowGraph = -not [bool]$script:Cfg.ShowGraph
    $miGraph.Checked = [bool]$script:Cfg.ShowGraph
    Apply-UnifiedSettings; Save-UnifiedState
    Update-AllSections
}
$miGraph.Checked = [bool]$script:Cfg.ShowGraph
[void]$script:ctxStrip.Items.Add($miGraph)

$script:miRemaining = New-StripItem 'Show remaining (not used)' {
    $script:Cfg.ShowRemaining = -not [bool]$script:Cfg.ShowRemaining
    $script:miRemaining.Checked = [bool]$script:Cfg.ShowRemaining
    Save-UnifiedState
    Update-AllSections
}
$script:miRemaining.Checked = [bool]$script:Cfg.ShowRemaining
[void]$script:ctxStrip.Items.Add($script:miRemaining)

$script:miNotchPin = New-StripItem 'Pin button on notch' {
    Set-NotchPinButton (-not (Test-NotchPinButtonEnabled))
    $script:miNotchPin.Checked = (Test-NotchPinButtonEnabled)
}
$script:miNotchPin.Checked = $true
[void]$script:ctxStrip.Items.Add($script:miNotchPin)

$script:miAiRequests = New-StripItem 'AI requests in the notch' {
    Set-AiRequestsEnabled (-not (Test-AiRequestsEnabled))
    $script:miAiRequests.Checked = (Test-AiRequestsEnabled)
}
$script:miAiRequests.Checked = $false
[void]$script:ctxStrip.Items.Add($script:miAiRequests)

# Notices from the notch: a task finished; the agent waits for you in its own
# terminal prompt (permission dialog, input).
$script:miAiNotifyDone = New-StripItem 'Notify when a task finishes' {
    $script:Cfg['AiNotifyDone'] = -not [bool]$script:Cfg['AiNotifyDone']
    Save-UnifiedState
    $script:miAiNotifyDone.Checked = [bool]$script:Cfg['AiNotifyDone']
}
$script:miAiNotifyDone.Checked = $true
[void]$script:ctxStrip.Items.Add($script:miAiNotifyDone)
$script:miAiNotifyAttention = New-StripItem 'Notify when the AI needs you' {
    $script:Cfg['AiNotifyAttention'] = -not [bool]$script:Cfg['AiNotifyAttention']
    Save-UnifiedState
    $script:miAiNotifyAttention.Checked = [bool]$script:Cfg['AiNotifyAttention']
}
$script:miAiNotifyAttention.Checked = $true
[void]$script:ctxStrip.Items.Add($script:miAiNotifyAttention)

# Renew an expired Claude sign-in by running Claude Code hidden (one tiny
# Haiku reply, at most every 30 minutes). Off: an expired sign-in just asks
# you to sign in again. The setting is a marker file (Data.ps1).
$script:miClaudeRenew = New-StripItem 'Renew Claude sign-in automatically' {
    try { Set-ClaudeCliRenewalEnabled (-not (Test-ClaudeCliRenewalEnabled)) } catch { }
    try { $script:miClaudeRenew.Checked = (Test-ClaudeCliRenewalEnabled) } catch { }
}
$script:miClaudeRenew.Checked = $true
$script:miClaudeRenew.ToolTipText = 'Runs Claude Code in the background with a one-line Haiku prompt when the sign-in has expired (at most every 30 minutes).'
[void]$script:ctxStrip.Items.Add($script:miClaudeRenew)

# How long an unanswered AI request card waits before it chimes again.
$script:aiRemindItems = [ordered]@{}
function Sync-AiRemindItems {
    $cur = 25
    try { if ($null -ne $script:Cfg['AiRequestRemind']) { $cur = [int]$script:Cfg['AiRequestRemind'] } } catch { }
    foreach ($k in @($script:aiRemindItems.Keys)) { $script:aiRemindItems[$k].Checked = ([int]$k -eq $cur) }
}
$script:miAiRemind = New-StripItem 'Remind again if unanswered' $null
foreach ($pair in @(@('Off', 0), @('10 s', 10), @('25 s', 25), @('45 s', 45), @('60 s', 60))) {
    $val = [int]$pair[1]
    $sub = New-StripItem $pair[0] ([scriptblock]::Create("`$script:Cfg['AiRequestRemind'] = $val; Save-UnifiedState; Sync-AiRemindItems"))
    $sub.CheckOnClick = $false
    $script:aiRemindItems[[string]$val] = $sub
    [void]$script:miAiRemind.DropDownItems.Add($sub)
}
Sync-AiRemindItems
[void]$script:ctxStrip.Items.Add($script:miAiRemind)
Add-Separator

# Login
$script:miLogin = New-StripItem 'Open at login' {
    if (Test-Autostart) { Uninstall-Autostart } else { Install-Autostart }
    $script:miLogin.Checked = (Test-Autostart)
}
$script:miLogin.Checked = (Test-Autostart)
[void]$script:ctxStrip.Items.Add($script:miLogin)

$miSH = New-StripItem 'Start hidden to tray' {
    $script:Cfg.StartHidden = -not [bool]$script:Cfg.StartHidden
    $miSH.Checked = [bool]$script:Cfg.StartHidden
    Save-UnifiedState
}
$miSH.Checked = [bool]$script:Cfg.StartHidden
[void]$script:ctxStrip.Items.Add($miSH)
Add-Separator

# Window
[void]$script:ctxStrip.Items.Add((New-StripItem 'Minimize to tray' { $script:window.Hide() }))
[void]$script:ctxStrip.Items.Add((New-StripItem 'Quit' { Quit-App }))

# ---------------------------------------------------------------------------
# Menu layout: grouped sections with captions, line icons, and switches for
# on/off settings. The items above keep their handlers; this only reorders
# and decorates them.
# ---------------------------------------------------------------------------
. {
    $iconData = @{
    IcoClock = 'M8,1.75 A6.25,6.25 0 1 1 7.99,1.75 Z M8,4.6 V8 L10.4,9.4'
    IcoCalendar = 'M3,3.5 H13 A1,1 0 0 1 14,4.5 V13 A1,1 0 0 1 13,14 H3 A1,1 0 0 1 2,13 V4.5 A1,1 0 0 1 3,3.5 Z M2,7 H14 M5.2,2 V4.8 M10.8,2 V4.8'
    IcoDatabase = 'M2.5,4 A5.5,2 0 1 0 13.5,4 A5.5,2 0 1 0 2.5,4 Z M2.5,4 V12 A5.5,2 0 0 0 13.5,12 V4 M2.5,8 A5.5,2 0 0 0 13.5,8'
    IcoPerson = 'M10.7,5 A2.7,2.7 0 1 1 5.3,5 A2.7,2.7 0 1 1 10.7,5 Z M2.8,14 C3.3,11 5.4,9.6 8,9.6 C10.6,9.6 12.7,11 13.2,14'
    IcoDollar = 'M8,1.75 A6.25,6.25 0 1 1 7.99,1.75 Z M10,5.9 C9.6,5.2 8.9,4.9 8,4.9 C6.9,4.9 6.1,5.5 6.1,6.35 C6.1,8.4 9.9,7.5 9.9,9.65 C9.9,10.55 9.1,11.1 8,11.1 C7,11.1 6.3,10.8 5.9,10.1 M8,3.7 V4.9 M8,11.1 V12.3'
    IcoBars = 'M3,13.5 V9.5 M6.5,13.5 V5.5 M10,13.5 V8 M13.5,13.5 V3'
    IcoMoon = 'M13.2,9.9 A5.6,5.6 0 1 1 6.1,2.8 A4.5,4.5 0 0 0 13.2,9.9 Z'
    IcoChat = 'M3,3 H13 A1,1 0 0 1 14,4 V10.5 A1,1 0 0 1 13,11.5 H7.2 L4.3,13.8 V11.5 H3 A1,1 0 0 1 2,10.5 V4 A1,1 0 0 1 3,3 Z'
    IcoRefresh = 'M13.3,6.2 A5.4,5.4 0 0 0 3.4,5 M3,2.2 V5.4 H6.2 M2.7,9.8 A5.4,5.4 0 0 0 12.6,11 M13,13.8 V10.6 H9.8'
    IcoInfo = 'M8,1.75 A6.25,6.25 0 1 1 7.99,1.75 Z M8,7.3 V11.3 M8,4.7 V4.9'
    IcoSliders = 'M2.5,4.5 H8.1 M11.9,4.5 H13.5 M11.9,4.5 A1.9,1.9 0 1 1 8.1,4.5 A1.9,1.9 0 1 1 11.9,4.5 Z M2.5,11.5 H4.1 M7.9,11.5 H13.5 M7.9,11.5 A1.9,1.9 0 1 1 4.1,11.5 A1.9,1.9 0 1 1 7.9,11.5 Z'
    IcoChevDown = 'M4.5,6.3 L8,9.8 L11.5,6.3'
    IcoLayers = 'M8,2 L14,5 L8,8 L2,5 Z M2,8 L8,11 L14,8 M2,11 L8,14 L14,11'
    IcoEye = 'M1.5,8 C3.2,4.8 5.5,3.5 8,3.5 C10.5,3.5 12.8,4.8 14.5,8 C12.8,11.2 10.5,12.5 8,12.5 C5.5,12.5 3.2,11.2 1.5,8 Z M10.2,8 A2.2,2.2 0 1 1 5.8,8 A2.2,2.2 0 1 1 10.2,8 Z'
    IcoEyeOff = 'M1.5,8 C3.2,4.8 5.5,3.5 8,3.5 C10.5,3.5 12.8,4.8 14.5,8 C12.8,11.2 10.5,12.5 8,12.5 C5.5,12.5 3.2,11.2 1.5,8 Z M2.5,2.5 L13.5,13.5'
    IcoBell = 'M4,11 V7.2 A4,4 0 0 1 12,7.2 V11 L13.2,12.3 H2.8 Z M6.6,13.8 A1.5,1.5 0 0 0 9.4,13.8'
    IcoBellOff = 'M4,11 V7.2 A4,4 0 0 1 12,7.2 V11 L13.2,12.3 H2.8 Z M6.6,13.8 A1.5,1.5 0 0 0 9.4,13.8 M2,2 L14,14'
    IcoCopy = 'M5.5,5.5 H12.5 A1,1 0 0 1 13.5,6.5 V13 A1,1 0 0 1 12.5,14 H6.5 A1,1 0 0 1 5.5,13 Z M3.5,10.5 H3 A1,1 0 0 1 2,9.5 V3 A1,1 0 0 1 3,2 H9.5 A1,1 0 0 1 10.5,3 V3.5'
    IcoTag = 'M2,2.5 H7.8 L14,8.7 L8.7,14 L2.5,7.8 V2.5 Z M6.2,5.4 A0.8,0.8 0 1 1 4.6,5.4 A0.8,0.8 0 1 1 6.2,5.4 Z'
    IcoDownload = 'M8,2 V10 M4.8,6.8 L8,10 L11.2,6.8 M2.5,11.5 V13.5 H13.5 V11.5'
    IcoWindow = 'M3,3 H13 A1,1 0 0 1 14,4 V12 A1,1 0 0 1 13,13 H3 A1,1 0 0 1 2,12 V4 A1,1 0 0 1 3,3 Z'
    IcoKeyboard = 'M2.5,4 H13.5 A1,1 0 0 1 14.5,5 V11 A1,1 0 0 1 13.5,12 H2.5 A1,1 0 0 1 1.5,11 V5 A1,1 0 0 1 2.5,4 Z M4,6.6 H4.3 M6.5,6.6 H6.8 M9.2,6.6 H9.5 M11.7,6.6 H12 M4,8.6 H4.3 M11.7,8.6 H12 M5.8,10 H10.2'
    IcoCorner = 'M2.5,6 V3.5 A1,1 0 0 1 3.5,2.5 H6 M10,2.5 H12.5 A1,1 0 0 1 13.5,3.5 V6 M13.5,10 V12.5 A1,1 0 0 1 12.5,13.5 H10 M6,13.5 H3.5 A1,1 0 0 1 2.5,12.5 V10'
    IcoDrop = 'M8,2 C8,2 3.5,7 3.5,10 A4.5,4.5 0 0 0 12.5,10 C12.5,7 8,2 8,2 Z'
    IcoPalette = 'M8,2 A6,6 0 1 0 8,14 C9,14 9.4,13.3 9,12.6 C8.5,11.8 9,10.8 10,10.8 H11.5 A2.5,2.5 0 0 0 14,8.3 C14,4.8 11.3,2 8,2 Z M5,7.3 H5.3 M7.2,4.9 H7.5 M10.3,5.3 H10.6'
    IcoList = 'M3,3 H13 A1,1 0 0 1 14,4 V12 A1,1 0 0 1 13,13 H3 A1,1 0 0 1 2,12 V4 A1,1 0 0 1 3,3 Z M4.8,6 H11.2 M4.8,8.3 H11.2 M4.8,10.6 H9'
    IcoTrend = 'M2,11.5 L6,7.5 L8.6,10.1 L14,4.6 M10.6,4.6 H14 V8'
    IcoPower = 'M8,2 V7.5 M5,3.7 A5.3,5.3 0 1 0 11,3.7'
    IcoMinus = 'M4,8 H12'
    IcoExit = 'M9.5,2.5 H3.5 A1,1 0 0 0 2.5,3.5 V12.5 A1,1 0 0 0 3.5,13.5 H9.5 M7,8 H14 M11.5,5.5 L14,8 L11.5,10.5'
    IcoBolt = 'M9,1.8 L3.5,9 H7.6 L7,14.2 L12.5,7 H8.4 Z'
    IcoGlobe = 'M8,1.75 A6.25,6.25 0 1 1 7.99,1.75 Z M1.9,8 H14.1 M8,1.75 C5.7,4 5.7,12 8,14.25 M8,1.75 C10.3,4 10.3,12 8,14.25'
    IcoSwatch = 'M3,3 H13 A1,1 0 0 1 14,4 V12 A1,1 0 0 1 13,13 H3 A1,1 0 0 1 2,12 V4 A1,1 0 0 1 3,3 Z M8,3 V13 M8,8 H14'
    IcoPin = 'M9.6,2 L14,6.4 M11.8,4.2 L8.9,7.1 L10.1,10.6 L5.4,5.9 L8.9,7.1 M7.75,8.25 L2.6,13.4'
    IcoGear = 'M10.2,8 A2.2,2.2 0 1 1 5.8,8 A2.2,2.2 0 1 1 10.2,8 Z M8,1.6 V3.3 M8,12.7 V14.4 M1.6,8 H3.3 M12.7,8 H14.4 M3.5,3.5 L4.7,4.7 M11.3,11.3 L12.5,12.5 M3.5,12.5 L4.7,11.3 M11.3,4.7 L12.5,3.5'
    }
    $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $script:MenuDpi = [math]::Max(1.0, $g.DpiX / 96.0)
    $g.Dispose()
    $script:MenuIconPx = [int][math]::Round(18 * $script:MenuDpi)
    $script:ctxStrip.ImageScalingSize = New-Object System.Drawing.Size($script:MenuIconPx, $script:MenuIconPx)

    function ConvertTo-DrawingBitmap($Source) {
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($Source))
        $ms = New-Object System.IO.MemoryStream
        $enc.Save($ms); $ms.Position = 0
        $img = [System.Drawing.Image]::FromStream($ms)
        $bmp = New-Object System.Drawing.Bitmap($img)
        $img.Dispose(); $ms.Dispose()
        return $bmp
    }

    # A provider's icon at menu size. Drawn through a DrawingVisual so every
    # source kind (PNG, package logo, exe icon) converts the same way; with no
    # icon at all it draws the provider's monogram tile instead.
    function Get-ProviderMenuBitmap([string]$Key) {
        if (-not $script:ProviderMenuBitmaps) { $script:ProviderMenuBitmaps = @{} }
        if ($script:ProviderMenuBitmaps.ContainsKey($Key)) { return $script:ProviderMenuBitmaps[$Key] }
        $px = $script:MenuIconPx
        $dv = New-Object System.Windows.Media.DrawingVisual
        $dc = $dv.RenderOpen()
        $rect = New-Object System.Windows.Rect(0, 0, $px, $px)
        $src = $null
        try { $src = Get-ProviderIcon $Key } catch { }
        if ($src) {
            $dc.DrawImage($src, $rect)
        } else {
            $meta = $script:ProviderMeta[$Key]
            $bg = NewBrush $(if ($meta) { $meta.Grad[1] } else { '#3A3A3C' })
            $dc.DrawRoundedRectangle($bg, $null, $rect, $px * 0.24, $px * 0.24)
            $text = if ($meta) { [string]$meta.Mono } else { '?' }
            $ft = New-Object System.Windows.Media.FormattedText($text, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Windows.FlowDirection]::LeftToRight, (New-Object System.Windows.Media.Typeface('Segoe UI Semibold')),
                ($px * 0.42), [System.Windows.Media.Brushes]::White, 1.0)
            $dc.DrawText($ft, (New-Object System.Windows.Point((($px - $ft.Width) / 2.0), (($px - $ft.Height) / 2.0))))
        }
        $dc.Close()
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($px, $px, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($dv)
        $bmp = ConvertTo-DrawingBitmap $rtb
        $script:ProviderMenuBitmaps[$Key] = $bmp
        return $bmp
    }

    function New-MenuIcon([string]$Data, [string]$Hex = '#C7C7CC') {
        $px = $script:MenuIconPx
        $geo = [System.Windows.Media.Geometry]::Parse($Data)
        $pen = New-Object System.Windows.Media.Pen((NewBrush $Hex), 1.5)
        $pen.StartLineCap = 'Round'; $pen.EndLineCap = 'Round'; $pen.LineJoin = 'Round'
        $dv = New-Object System.Windows.Media.DrawingVisual
        $dc = $dv.RenderOpen()
        $dc.PushTransform((New-Object System.Windows.Media.ScaleTransform(($px / 16.0), ($px / 16.0))))
        $dc.DrawGeometry($null, $pen, $geo)
        $dc.Pop(); $dc.Close()
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($px, $px, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($dv)
        return ConvertTo-DrawingBitmap $rtb
    }

    function New-MenuHeader([string]$Text) {
        # '&&' shows a literal ampersand (a single '&' marks a mnemonic).
        $h = New-Object System.Windows.Forms.ToolStripMenuItem(($Text.ToUpperInvariant() -replace '&', '&&'))
        $h.Enabled = $false
        $h.Tag = 'header'
        $h.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 7.75)
        $h.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
        $h.BackColor = $darkBg
        return $h
    }

    $byText = @{}
    foreach ($it in @($script:ctxStrip.Items)) {
        if ($it -is [System.Windows.Forms.ToolStripMenuItem]) { $byText[$it.Text] = $it }
    }
    $groups = @(
        @{ Title = 'Alerts & Status'; Icon = 'IcoBell'; Items = @(
            @('Notch (hover to peek)', 'IcoEye'), @('Test alert', 'IcoBell'),
            @('Dismiss current alert', 'IcoBellOff'), @('Copy stats to clipboard', 'IcoCopy')) },
        @{ Title = 'Account & Data'; Icon = 'IcoPerson'; Items = @(
            @('Platforms', 'IcoLayers'), @('Brand', 'IcoTag'),
            @('Providers', 'IcoDatabase'), @('Log in', 'IcoPerson')) },
        @{ Title = 'Appearance & Layout'; Icon = 'IcoPalette'; Items = @(
            @('View', 'IcoWindow'), @('Hotkeys', 'IcoKeyboard'), @('Snap to corner', 'IcoCorner'),
            @('Opacity', 'IcoDrop'), @('Background', 'IcoSwatch'),
            @('Language', 'IcoGlobe')) },
        @{ Title = 'Panels & Features'; Icon = 'IcoSliders'; Toggle = $true; Items = @(
            @('Show stats panel', 'IcoBars'), @('Compact mode', 'IcoList'),
            @('Threshold alerts', 'IcoBell'), @('Show history graph', 'IcoTrend'),
            @('Pin button on notch', 'IcoPin'), @('AI requests in the notch', 'IcoChat'),
            @('Notify when a task finishes', 'IcoBell'), @('Notify when the AI needs you', 'IcoBell'),
            @('Remind again if unanswered', 'IcoBell'), @('Renew Claude sign-in automatically', 'IcoPower')) },
        @{ Title = 'System'; Icon = 'IcoPower'; Items = @(
            @('Open at login', 'IcoPower', $true), @('Start hidden to tray', 'IcoEyeOff', $true),
            @('Minimize to tray', 'IcoMinus'), @('Check for updates', 'IcoDownload'),
            @(("Version {0}" -f $script:DisplayVersion), 'IcoInfo')) }
    )
    $used = @{}
    $script:ctxStrip.Items.Clear()
    $script:MenuDropDowns = [System.Collections.Generic.List[object]]::new()
    [void]$script:MenuDropDowns.Add($script:ctxStrip)

    # Title row doubles as the drag handle for the whole menu.
    $grip = New-Object System.Windows.Forms.ToolStripMenuItem('JayOS  Settings')
    $grip.Tag = 'grip'
    $grip.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
    $grip.Padding = New-Object System.Windows.Forms.Padding(0, 5, 0, 5)
    $grip.BackColor = $darkBg
    $grip.ToolTipText = 'Drag to move'
    try { $grip.Image = New-MenuIcon $iconData['IcoGear'] '#F1F5F9' } catch { }
    [void]$script:ctxStrip.Items.Add($grip)
    [AIUsageMenuDrag]::Attach($script:ctxStrip, $grip)
    Add-Separator

    # Level 2: one row per group; level 3: the group's settings.
    foreach ($grp in $groups) {
        # '&&' shows a literal ampersand (a single '&' marks a mnemonic).
        $gi = New-StripItem ($grp.Title -replace '&', '&&') $null
        $gi.Tag = 'group'
        $gi.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
        try { $gi.Image = New-MenuIcon $iconData[$grp.Icon] } catch { }
        $gi.DropDown.BackColor = $darkBg
        $gi.DropDown.ImageScalingSize = $script:ctxStrip.ImageScalingSize
        $gi.DropDownDirection = [System.Windows.Forms.ToolStripDropDownDirection]::Right
        $sub = New-MenuHeader $grp.Title
        [void]$gi.DropDownItems.Add($sub)
        foreach ($spec in $grp.Items) {
            $item = $byText[$spec[0]]
            if (-not $item) { continue }
            try { $item.Image = New-MenuIcon $iconData[$spec[1]] } catch { }
            $item.Padding = New-Object System.Windows.Forms.Padding(0, 3, 0, 3)
            # A row with its own submenu (a list of choices) is never a switch.
            if (($grp.Toggle -and -not $item.HasDropDownItems) -or ($spec.Count -gt 2 -and $spec[2])) {
                $item.Tag = 'toggle'
                $item.CheckOnClick = $false
                # Reserve room on the right for the switch.
                $item.ShortcutKeyDisplayString = '            '
            }
            [void]$gi.DropDownItems.Add($item)
            $used[$spec[0]] = $true
        }
        [void]$script:MenuDropDowns.Add($gi.DropDown)
        [void]$script:ctxStrip.Items.Add($gi)
    }
    # Anything not placed above (future items) stays reachable.
    foreach ($k in @($byText.Keys)) {
        if ($k -eq 'Quit' -or $used.ContainsKey($k)) { continue }
        [void]$script:ctxStrip.Items.Add($byText[$k])
    }
    Add-Separator
    $quit = $byText['Quit']
    if ($quit) {
        try { $quit.Image = New-MenuIcon $iconData['IcoExit'] '#F87171' } catch { }
        $quit.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
        [void]$script:ctxStrip.Items.Add($quit)
    }

    # Provider rows (Providers / Log in submenus) get the providers' own icons;
    # the Show/Hide rows in Providers become switches so the state stays visible.
    foreach ($parent in @($byText['Providers'], $byText['Log in'])) {
        if (-not $parent) { continue }
        foreach ($sub in @($parent.DropDownItems)) {
            if ($sub -isnot [System.Windows.Forms.ToolStripMenuItem]) { continue }
            foreach ($key in @('claude', 'codex', 'cursor', 'grok')) {
                if ($sub.Text -match ('^' + [regex]::Escape($script:ProviderMeta[$key].Name) + '\b')) {
                    try { $sub.Image = Get-ProviderMenuBitmap $key } catch { }
                    if ($parent -eq $byText['Providers']) {
                        $sub.Tag = 'toggle'
                        $sub.ShortcutKeyDisplayString = '            '
                    }
                }
            }
        }
    }

    # The items were built before the saved settings loaded; re-read every
    # switch from the live settings each time the menu opens.
    $script:MenuToggleKeys = @{
        'Show stats panel' = 'ShowStats'; 'Compact mode' = 'Compact'; 'Threshold alerts' = 'ShowAlerts'
        'Show history graph' = 'ShowGraph'; 'Start hidden to tray' = 'StartHidden'
        'Show remaining (not used)' = 'ShowRemaining'
        'Pin button on notch' = 'NotchPinButton'; 'AI requests in the notch' = 'AiRequests'
        'Notify when a task finishes' = 'AiNotifyDone'; 'Notify when the AI needs you' = 'AiNotifyAttention'
    }
    $script:MenuToggleItems = @{}
    foreach ($k in @($script:MenuToggleKeys.Keys) + @('Open at login', 'Renew Claude sign-in automatically')) {
        if ($byText.ContainsKey($k)) { $script:MenuToggleItems[$k] = $byText[$k] }
    }

    # Pick-one rows keep the menu open (see Register-MenuKeepOpen). The view
    # switch (pinned / drop-down) and dialogs still close it.
    $skip = @($script:bgCustomItem) + @($script:viewModeItems.Values)
    function Set-MenuOptionTags($Items) {
        foreach ($it in @($Items)) {
            if ($it -isnot [System.Windows.Forms.ToolStripMenuItem]) { continue }
            if ($it.DropDownItems.Count -gt 0) { Set-MenuOptionTags $it.DropDownItems; continue }
            if ($null -ne $it.Tag) { continue }
            $isSkip = $false
            foreach ($x in $skip) { if ([object]::ReferenceEquals($x, $it)) { $isSkip = $true } }
            if (-not $isSkip) { $it.Tag = 'option' }
        }
    }
    foreach ($name in @('View', 'Hotkeys', 'Snap to corner', 'Opacity', 'Theme', 'Background', 'Language', 'Remind again if unanswered')) {
        if ($byText[$name]) { Set-MenuOptionTags $byText[$name].DropDownItems }
    }

    # Live preview while hovering a colour or theme; leaving the list restores
    # what is saved (a click saves it).
    if ($byText['Background']) {
        foreach ($k in @($script:bgItems.Keys)) {
            $script:bgItems[$k].add_MouseEnter([scriptblock]::Create("try { Set-NotchBackdropColor '$k' } catch { }"))
        }
        $restoreBg = { try { Set-NotchBackdropColor (Get-PanelBgHex) } catch { } }
        if ($script:bgCustomItem) { $script:bgCustomItem.add_MouseEnter($restoreBg) }
        $byText['Background'].DropDown.add_MouseLeave($restoreBg)
        $byText['Background'].DropDown.add_Closed($restoreBg)
    }
    if ($byText['Theme']) {
        foreach ($k in @($script:themeItems.Keys)) {
            $script:themeItems[$k].add_MouseEnter([scriptblock]::Create("Invoke-ThemePreview '$($k -replace "'", "''")'"))
        }
        $byText['Theme'].DropDown.add_MouseLeave({ Invoke-ThemePreview $null })
        $byText['Theme'].DropDown.add_Closed({ Invoke-ThemePreview $null })
    }
    Sync-AppearanceMenus
    Sync-IslandMenuItem
}

function Sync-MenuToggleStates {
    if (-not $script:Cfg) { return }
    foreach ($k in @($script:MenuToggleItems.Keys)) {
        $item = $script:MenuToggleItems[$k]
        if ($k -eq 'Renew Claude sign-in automatically') {
            try { $item.Checked = [bool](Test-ClaudeCliRenewalEnabled) } catch { }
        } elseif ($k -eq 'Open at login') {
            if (Get-Command Test-Autostart -ErrorAction SilentlyContinue) { $item.Checked = [bool](Test-Autostart) }
        } else {
            $item.Checked = [bool]$script:Cfg[$script:MenuToggleKeys[$k]]
        }
    }
    if ($script:opacityItems) {
        foreach ($kv in $script:opacityItems.GetEnumerator()) {
            $kv.Value.Checked = ([math]::Abs([double]$script:Cfg.Opacity - [double]::Parse($kv.Key.TrimEnd('%'), [cultureinfo]::InvariantCulture) / 100.0) -lt 0.00001)
        }
    }
    if ($script:miHideFocus) { $script:miHideFocus.Checked = [bool]$script:Cfg.DropdownHideOnFocusLoss }
    Sync-SectionMenuItems
    Sync-IslandMenuItem
    try { Sync-AiRemindItems } catch { }
}
$script:ctxStrip.add_Opening({ try { Sync-MenuToggleStates } catch { } })
$script:ctxStrip.add_Opening({ try { Sync-AppearanceMenus; Invoke-MenuTranslate $script:ctxStrip.Items } catch { } })

# Rounded popup corners on Windows 11 (ignored elsewhere).
if (-not ([System.Management.Automation.PSTypeName]'AIUsageDwm').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AIUsageDwm {
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int value, int size);
    public static void Round(IntPtr h) { int v = 2; try { DwmSetWindowAttribute(h, 33, ref v, 4); } catch { } }
}
'@
}
function Set-MenuRoundCorners($Strip) {
    if (-not $Strip) { return }
    $Strip.add_Opened({ param($s, $e) try { [AIUsageDwm]::Round($s.Handle) } catch { } })
    foreach ($it in @($Strip.Items)) {
        if ($it -is [System.Windows.Forms.ToolStripMenuItem] -and $it.DropDownItems.Count -gt 0) {
            $it.DropDown.BackColor = $darkBg
            Set-MenuRoundCorners $it.DropDown
        }
    }
}
Set-MenuRoundCorners $script:ctxStrip

# Flipping a switch, picking an option (theme, colour, language, opacity...) or
# clicking the title/drag row keeps the menu open so several settings can be
# changed in one go; click outside the menu to close it. Actions close it.
$script:MenuKeepOpenUntil = [DateTime]::MinValue
function Register-MenuKeepOpen($Strip) {
    if (-not $Strip) { return }
    $Strip.add_ItemClicked({
        param($s, $e)
        $t = [string]$e.ClickedItem.Tag
        if ($t -eq 'toggle' -or $t -eq 'grip' -or $t -eq 'option' -or $t -eq 'swatch') { $script:MenuKeepOpenUntil = [DateTime]::UtcNow.AddMilliseconds(400) }
    })
    $Strip.add_Closing({
        param($s, $e)
        if ($e.CloseReason -eq [System.Windows.Forms.ToolStripDropDownCloseReason]::ItemClicked -and
            [DateTime]::UtcNow -lt $script:MenuKeepOpenUntil) { $e.Cancel = $true }
    })
    foreach ($it in @($Strip.Items)) {
        if ($it -is [System.Windows.Forms.ToolStripMenuItem] -and $it.DropDownItems.Count -gt 0) {
            Register-MenuKeepOpen $it.DropDown
        }
    }
}
Register-MenuKeepOpen $script:ctxStrip

# ---------------------------------------------------------------------------
# Accounts popup (header pill): every AI with its sign-in state; click one to
# sign in (CLI login), or to install / open its page when there is no CLI.
# ---------------------------------------------------------------------------
function Invoke-AccountAction([string]$Key) {
    try {
        $name = $script:ProviderMeta[$Key].Name
        if ($Key -eq 'cursor') {
            if (Get-Command Open-ProviderLink -ErrorAction SilentlyContinue) { Open-ProviderLink -Provider 'cursor' -Kind 'Usage' }
            return
        }
        $resolved = Resolve-ProviderLoginCli $Key
        if ($resolved) {
            Invoke-ProviderLogin -Provider $name -CliName $Key
        } elseif (Get-Command Open-ProviderLink -ErrorAction SilentlyContinue) {
            Open-ProviderLink -Provider $Key -Kind 'Docs'
        }
    } catch {
        Write-NotchLog "account action $Key : $($_.Exception.Message)"
    }
}

function Get-AccountState([string]$Key) {
    $raw = $null
    $st = $script:LastProviderStatuses
    if ($st -is [System.Collections.IDictionary] -and $st.Contains($Key)) { $raw = $st[$Key] }
    $k = Get-PanelStatusKey $raw
    if ($Key -ne 'cursor' -and -not (Resolve-ProviderLoginCli $Key)) {
        return @{ Tag = 'acct:missing'; Text = 'Not set up'; Tip = 'Not installed - opens the install page' }
    }
    switch ($k) {
        'ok'          { return @{ Tag = 'acct:ok';    Text = 'Signed in';  Tip = 'Click to sign in again' } }
        'stale'       { return @{ Tag = 'acct:stale'; Text = 'Signed in';  Tip = 'Signed in - last refresh failed' } }
        'idle'        { return @{ Tag = 'acct:ok';    Text = 'Signed in';  Tip = 'Signed in (token idle) - click to sign in again' } }
        'auth'        { return @{ Tag = 'acct:auth';  Text = 'Sign in'; Tip = 'Live access expired - click to sign in' } }
        'error'       { return @{ Tag = 'acct:stale'; Text = 'Error';      Tip = 'Click to sign in again' } }
        'unavailable' { return @{ Tag = 'acct:missing'; Text = 'Not set up'; Tip = 'Click to sign in' } }
    }
    return @{ Tag = 'acct:missing'; Text = 'Checking'; Tip = 'Waiting for the first refresh' }
}

function Show-AccountsMenu {
    if (-not $script:accountsStrip) {
        $m = New-Object System.Windows.Forms.ContextMenuStrip
        $m.Renderer = $script:darkRenderer
        $m.BackColor = $darkBg
        $m.ForeColor = $darkFg
        $m.Font = $menuFont
        $m.ShowImageMargin = $true
        $m.ImageScalingSize = $script:ctxStrip.ImageScalingSize
        $m.add_Opened({ param($s, $e) try { [AIUsageDwm]::Round($s.Handle) } catch { } })
        $script:accountsStrip = $m
    }
    $m = $script:accountsStrip
    $m.Items.Clear()
    $hdr = New-Object System.Windows.Forms.ToolStripMenuItem('ACCOUNTS')
    $hdr.Enabled = $false; $hdr.Tag = 'header'
    $hdr.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 7.75)
    $hdr.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
    [void]$m.Items.Add($hdr)
    foreach ($key in @('claude', 'codex', 'cursor', 'grok')) {
        $state = Get-AccountState $key
        $label = $script:ProviderMeta[$key].Name
        if (-not (Get-SectionVisible $key)) { $label += '  (hidden)' }
        $item = New-Object System.Windows.Forms.ToolStripMenuItem($label)
        $item.ForeColor = $darkFg; $item.BackColor = $darkBg; $item.Font = $menuFont
        $item.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
        $item.Tag = $state.Tag
        $item.ShortcutKeyDisplayString = $state.Text
        $item.ShowShortcutKeys = $true
        $tip = $state.Tip
        if ($key -eq 'claude' -and $script:ClaudeIdentity -and $script:ClaudeIdentity.Display) { $tip = [string]$script:ClaudeIdentity.Display + ' - ' + $tip }
        $item.ToolTipText = $tip
        try { $item.Image = Get-ProviderMenuBitmap $key } catch { }
        $item.add_Click([scriptblock]::Create("Invoke-AccountAction '$key'"))
        [void]$m.Items.Add($item)
    }
    $sep = New-Object System.Windows.Forms.ToolStripSeparator
    [void]$m.Items.Add($sep)
    $refresh = New-Object System.Windows.Forms.ToolStripMenuItem('Refresh now')
    $refresh.ForeColor = $darkFg; $refresh.BackColor = $darkBg; $refresh.Font = $menuFont
    $refresh.Padding = New-Object System.Windows.Forms.Padding(0, 3, 0, 3)
    try { $refresh.Image = New-MenuIcon $iconData['IcoRefresh'] } catch { }
    $refresh.add_Click({ Invoke-ManualRefresh })
    [void]$m.Items.Add($refresh)
    try { Invoke-MenuTranslate $m.Items } catch { }
    [void][AIUsageMenuDrag]::AnyButtonPressed()   # clear the press that opened it
    $m.Show([System.Windows.Forms.Control]::MousePosition)
    [AIUsageMenuDrag]::Activate($m)
}

# ---------------------------------------------------------------------------
# Tray icon - left-click toggles the unified window
# ---------------------------------------------------------------------------
function New-TrayIcon {
    $icoPath = Join-Path $script:AppDir 'assets\ai-usage-overlay.ico'
    if (Test-Path -LiteralPath $icoPath) {
        try { return New-Object System.Drawing.Icon($icoPath) } catch { }
    }
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $grd = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.Point 1,1),(New-Object System.Drawing.Point 31,31),
        [System.Drawing.Color]::FromArgb(255,30,58,138),[System.Drawing.Color]::FromArgb(255,109,40,217))
    $g.FillEllipse($grd,1,1,30,30)
    $fnt = New-Object System.Drawing.Font('Bahnschrift',11,[System.Drawing.FontStyle]::Bold)
    $sf  = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $g.DrawString('AI',$fnt,[System.Drawing.Brushes]::White,(New-Object System.Drawing.RectangleF(0,0,32,32)),$sf)
    $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$script:notify = New-Object System.Windows.Forms.NotifyIcon
$script:notify.Icon = New-TrayIcon
$script:notify.Text = 'AI Usage  (left-click to show)'
$script:notify.ContextMenuStrip = $script:ctxStrip
$script:notify.Visible = $true
$script:notify.add_MouseClick({ param($s,$e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Toggle-Window }
})
