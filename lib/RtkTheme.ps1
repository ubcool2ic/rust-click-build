<#
.SYNOPSIS
    rtk design tokens for rust-click-build (GUI + console colours).

.DESCRIPTION
    Values copied from rtk v1.0.1 (github.com/ubcool2ic/rtk):
      src/style.rs  Tokens::modern_light / modern_dark / high_contrast
                    (palette, spacing [4,8,12,16,24], radius, type scale),
                    TButton / Accent.TButton / Card styles (padding 6x14,
                    Card padding 16 radius 12, hover = blend(surface, fg, 6%),
                    pressed = 12%, accent hover = blend(accent, white, 8%)).
      src/theme.rs  SemanticTokens::from_tokens (success/warning/info per
                    light/dark/high-contrast, text_disabled = blend 45%).
      fonts/        Noto Sans Regular/Bold (400/700 only), bundled in
                    assets/fonts under the SIL OFL.
    Body text is 14 px, titles 18 px, headings 22 px, captions 12 px.
#>

<#
.SYNOPSIS
    Converts an "r,g,b" triple to a #RRGGBB string.
#>
function ConvertTo-RtkHex {
    param([int[]]$Rgb)
    return ('#{0:X2}{1:X2}{2:X2}' -f $Rgb[0], $Rgb[1], $Rgb[2])
}

<#
.SYNOPSIS
    rtk's blend(a, b, t): a + (b - a) * t per channel, rounded.
#>
function Get-RtkBlend {
    param([int[]]$A, [int[]]$B, [double]$T)
    return @(
        [int][math]::Round($A[0] + ($B[0] - $A[0]) * $T),
        [int][math]::Round($A[1] + ($B[1] - $A[1]) * $T),
        [int][math]::Round($A[2] + ($B[2] - $A[2]) * $T)
    )
}

<#
.SYNOPSIS
    Builds the token set for one rtk theme: ModernLight, ModernDark or HighContrast.
#>
function Get-RtkTheme {
    param([ValidateSet('ModernLight', 'ModernDark', 'HighContrast')][string]$Name = 'ModernDark')
    switch ($Name) {
        'ModernLight' {
            $p = @{ bg = @(245, 247, 251); surface = @(255, 255, 255); surface2 = @(235, 239, 248); fg = @(27, 31, 42)
                    muted = @(90, 100, 118); accent = @(37, 99, 235); accent_fg = @(255, 255, 255); border = @(226, 230, 239)
                    focus = @(37, 99, 235); danger = @(185, 28, 28); field = @(255, 255, 255)
                    success = @(21, 128, 61); warning = @(180, 83, 9); info = @(3, 105, 161) }
            $radius = @{ sm = 6; md = 10; lg = 14 }; $isDark = $false; $hc = $false
        }
        'ModernDark' {
            $p = @{ bg = @(15, 17, 21); surface = @(23, 26, 33); surface2 = @(31, 36, 48); fg = @(230, 232, 238)
                    muted = @(154, 163, 178); accent = @(79, 140, 255); accent_fg = @(15, 17, 21); border = @(42, 48, 64)
                    focus = @(79, 140, 255); danger = @(248, 113, 113); field = @(23, 26, 33)
                    success = @(74, 222, 128); warning = @(251, 191, 36); info = @(56, 189, 248) }
            $radius = @{ sm = 6; md = 10; lg = 14 }; $isDark = $true; $hc = $false
        }
        'HighContrast' {
            $p = @{ bg = @(0, 0, 0); surface = @(0, 0, 0); surface2 = @(20, 20, 20); fg = @(255, 255, 255)
                    muted = @(200, 200, 200); accent = @(26, 235, 255); accent_fg = @(0, 0, 0); border = @(255, 255, 255)
                    focus = @(255, 255, 0); danger = @(255, 50, 50); field = @(0, 0, 0)
                    success = @(0, 255, 0); warning = @(255, 255, 0); info = @(0, 255, 255) }
            $radius = @{ sm = 0; md = 0; lg = 0 }; $isDark = $true; $hc = $true
        }
    }
    $hover   = Get-RtkBlend -A $p.surface -B $p.fg -T 0.06
    $pressed = Get-RtkBlend -A $p.surface -B $p.fg -T 0.12
    $accHov  = Get-RtkBlend -A $p.accent -B @(255, 255, 255) -T 0.08
    $accPrs  = Get-RtkBlend -A $p.accent -B @(0, 0, 0) -T 0.08
    $disabled = Get-RtkBlend -A $p.fg -B $p.bg -T 0.45
    $colors = @{}
    foreach ($k in $p.Keys) { $colors[$k] = $p[$k] }
    $colors['hover'] = $hover; $colors['pressed'] = $pressed
    $colors['accent_hover'] = $accHov; $colors['accent_pressed'] = $accPrs
    $colors['text_disabled'] = $disabled
    return [PSCustomObject]@{
        Name         = $Name
        IsDark       = $isDark
        HighContrast = $hc
        Colors       = $colors
        Spacing      = @{ xs = 4; sm = 8; md = 12; lg = 16; xl = 24 }
        Radius       = $radius
        CardRadius   = $(if ($hc) { 0 } else { 12 })
        BorderWidth  = $(if ($hc) { 2 } else { 1 })
        FontFamily   = 'Noto Sans'
        FontPx       = @{ caption = 12; body = 14; title = 18; heading = 22 }
        ButtonPad    = @{ v = 6; h = 14 }
    }
}

<#
.SYNOPSIS
    Picks ModernDark / ModernLight / HighContrast from the Windows settings
    (AppsUseLightTheme and the high-contrast flag). Defaults to ModernDark.
#>
function Get-RtkSystemThemeName {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        if ([System.Windows.Forms.SystemInformation]::HighContrast) { return 'HighContrast' }
    } catch { $null = $_ }
    try {
        $v = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop
        if ($v -eq 1) { return 'ModernLight' }
        return 'ModernDark'
    } catch { return 'ModernDark' }
}

# -------------------------------------------------------------------------
# Console colours: same palette (modern dark, since consoles are dark).
# 24-bit ANSI when the host supports VT, otherwise the nearest ConsoleColor.
# -------------------------------------------------------------------------
$script:RtkConsoleTheme = Get-RtkTheme -Name 'ModernDark'
$script:RtkRoleConsoleFallback = @{
    text = 'Gray'; muted = 'DarkGray'; accent = 'Cyan'; info = 'Cyan'
    success = 'Green'; warning = 'Yellow'; danger = 'Red'; heading = 'White'
}
$script:RtkFromConsoleColor = @{
    'Cyan' = 'accent'; 'DarkCyan' = 'accent'; 'Green' = 'success'; 'DarkGreen' = 'success'
    'Yellow' = 'warning'; 'DarkYellow' = 'warning'; 'Red' = 'danger'; 'DarkRed' = 'danger'
    'Gray' = 'text'; 'DarkGray' = 'muted'; 'White' = 'heading'; 'Blue' = 'info'; 'Magenta' = 'accent'
}

<#
.SYNOPSIS
    Maps a legacy ConsoleColor name to an rtk role (Cyan -> accent, ...).
#>
function ConvertTo-RtkRole {
    param([string]$ConsoleColor)
    if ($script:RtkFromConsoleColor.ContainsKey($ConsoleColor)) { return $script:RtkFromConsoleColor[$ConsoleColor] }
    return 'text'
}

<#
.SYNOPSIS
    True when the console understands 24-bit ANSI colour (VT) and output is
    not redirected. Can be forced off with RCB_NO_TRUECOLOR=1.
#>
function Test-RtkTrueColor {
    if ($env:RCB_NO_TRUECOLOR -eq '1' -or -not [string]::IsNullOrEmpty($env:NO_COLOR)) { return $false }
    try {
        if ([Console]::IsOutputRedirected) { return $false }
        return [bool]$Host.UI.SupportsVirtualTerminal
    } catch { return $false }
}
$script:RtkTrueColor = Test-RtkTrueColor

<#
.SYNOPSIS
    Returns the RGB triple for a role in the console theme.
#>
function Get-RtkRoleRgb {
    param([string]$Role, $Theme = $script:RtkConsoleTheme)
    $c = $Theme.Colors
    switch ($Role) {
        'heading' { return $c.fg }
        'text'    { return $c.fg }
        'muted'   { return $c.muted }
        'accent'  { return $c.accent }
        'info'    { return $c.info }
        'success' { return $c.success }
        'warning' { return $c.warning }
        'danger'  { return $c.danger }
        default   { return $c.fg }
    }
}

<#
.SYNOPSIS
    Writes one coloured segment (no newline) to the console using a role.
#>
function Write-RtkSegment {
    param([string]$Text, [string]$Role = 'text', [switch]$Bold, [switch]$NewLine)
    if ($script:RtkTrueColor) {
        $rgb = Get-RtkRoleRgb $Role
        $esc = [char]27
        $b = if ($Bold) { "$esc[1m" } else { '' }
        $s = "$esc[38;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m$b$Text$esc[0m"
        if ($NewLine) { Write-Host $s } else { Write-Host $s -NoNewline }
    } else {
        $cc = $script:RtkRoleConsoleFallback[$Role]
        if ($null -eq $cc) { $cc = 'Gray' }
        if ($NewLine) { Write-Host $Text -ForegroundColor $cc } else { Write-Host $Text -ForegroundColor $cc -NoNewline }
    }
}

<#
.SYNOPSIS
    Writes a full console line in a role colour. Lines with role "rtkchange"
    containing "old -> new" print the old version in warning, the arrow muted
    and the new version in success.
#>
function Write-RtkConsoleLine {
    param([string]$Message, [string]$Role = 'text')
    if ($Role -eq 'rtkchange') {
        $m = [regex]::Match($Message, '^(.*?)(\S+)( -> )(\S+)(.*)$')
        if ($m.Success) {
            Write-RtkSegment $m.Groups[1].Value 'accent' -Bold
            Write-RtkSegment $m.Groups[2].Value 'warning' -Bold
            Write-RtkSegment $m.Groups[3].Value 'muted'
            Write-RtkSegment $m.Groups[4].Value 'success' -Bold
            Write-RtkSegment $m.Groups[5].Value 'muted' -NewLine
            return
        }
        $Role = 'accent'
    }
    if ($Role -eq 'text' -and -not $script:RtkTrueColor) { Write-Host $Message; return }
    Write-RtkSegment $Message $Role -Bold:($Role -eq 'heading') -NewLine
}
