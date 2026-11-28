<#
.SYNOPSIS
    Forced rtk update check for rust-click-build.

.DESCRIPTION
    Finds rtk git dependencies (https://github.com/ubcool2ic/rtk) in every
    Cargo.toml of a project or workspace, looks up the latest rtk release tag,
    bumps older tag pins (backing up Cargo.toml and Cargo.lock first) and runs
    `cargo update -p rtk`. Branch-pinned and unpinned deps always get
    `cargo update -p rtk`. The build pipeline in build.ps1 calls
    Restore-RtkBackup when a build fails after an update.

    Also holds the shared process-quoting helpers and the pruned Cargo.toml
    directory walk (Get-RcbCargoManifest).

    Works on Windows PowerShell 5.1 and PowerShell 7+. Dot-sourced by build.ps1.
#>


if (-not (Get-Command Invoke-ToolProcess -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'BuildCore.ps1')
}

# Default rtk repository. A dependency counts as rtk when its git URL points
# at github.com/ubcool2ic/rtk (with or without .git, https or ssh). The
# pattern is anchored at both ends so "evil.example/github.com/ubcool2ic/rtk"
# or an option-looking string cannot pass.
$script:RtkDefaultRepoUrl = 'https://github.com/ubcool2ic/rtk'
$script:RtkGitUrlPattern  = '(?i)^(?:(?:https?|ssh|git|git\+ssh)://)?(?:[A-Za-z0-9][^@/\s]*@)?(?:www\.)?github\.com(?::\d+)?[:/]+ubcool2ic/rtk(?:\.git)?/?$'
$script:RtkApiTagsUrl     = 'https://api.github.com/repos/ubcool2ic/rtk/tags?per_page=100'
$script:RtkLatestCache    = @{}

# Regex objects built once (Get-RtkDependency runs per manifest, per line).
$script:RtkReOptions    = [System.Text.RegularExpressions.RegexOptions]::Compiled -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
$script:RtkReGitUrl     = New-Object System.Text.RegularExpressions.Regex($script:RtkGitUrlPattern, $script:RtkReOptions)
$script:RtkReHeader     = New-Object System.Text.RegularExpressions.Regex('^\[\s*([^\[\]]+?)\s*\]$', $script:RtkReOptions)
$script:RtkReDepTable   = New-Object System.Text.RegularExpressions.Regex('^(?:(.*?)\s*\.\s*)?((?:dev-|build-)?dependencies)\s*\.\s*(["'']?)([A-Za-z0-9_\-]+)\3$', $script:RtkReOptions)
$script:RtkReDepSection = New-Object System.Text.RegularExpressions.Regex('(?:^|\.)\s*(?:dev-|build-)?dependencies$', $script:RtkReOptions)
$script:RtkReTableKey   = New-Object System.Text.RegularExpressions.Regex('^(["'']?)([A-Za-z0-9_\-]+)\1\s*=\s*(?:"((?:[^"\\]|\\.)*)"|''([^'']*)'')', $script:RtkReOptions)
$script:RtkReInline     = New-Object System.Text.RegularExpressions.Regex('^(["'']?)([A-Za-z0-9_\-]+)\1\s*=\s*\{(.*)\}$', $script:RtkReOptions)
$script:RtkReDotted     = New-Object System.Text.RegularExpressions.Regex('^(["'']?)([A-Za-z0-9_\-]+)\1\s*\.\s*([A-Za-z0-9_\-]+)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|''([^'']*)'')', $script:RtkReOptions)
$script:RtkReWorkspace  = New-Object System.Text.RegularExpressions.Regex('(?m)^[ \t]*\[\s*workspace\s*[\].]', $script:RtkReOptions)
$script:RtkQuoteChars   = [char[]]@([char]34, [char]39)
$script:RtkOpenChars    = [char[]]@([char]91, [char]123)
$script:RcbGlobChars    = [char[]]@([char]42, [char]63)
$script:RcbReWsArray    = New-Object System.Text.RegularExpressions.Regex('^(["'']?)(members|exclude)\1\s*=\s*\[(.*)\]$', $script:RtkReOptions)
$script:RcbReTomlString = New-Object System.Text.RegularExpressions.Regex('"((?:[^"\\]|\\.)*)"|''([^'']*)''', $script:RtkReOptions)

# Directory names never descended into while looking for Cargo.toml files.
$script:RcbPrunedDirs = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($rcbPruned in @('target', '.git', 'node_modules', '_built')) { [void]$script:RcbPrunedDirs.Add($rcbPruned) }
Remove-Variable -Name rcbPruned -ErrorAction SilentlyContinue

# Characters that force quoting of a Windows command-line argument.
$script:RcbArgSpecialChars = [char[]]@([char]32, [char]9, [char]10, [char]11, [char]13, [char]34)

# -------------------------------------------------------------------------
# Paths and process helpers (shared with build.ps1)
# -------------------------------------------------------------------------

<#
.SYNOPSIS
    Full file-system path for a PowerShell path, relative to the PowerShell
    location (not the process working directory). Does not need to exist.
#>
function Resolve-RcbFullPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    try { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) } catch { return $Path }
}

# Shown whenever a file operation still fails with PathTooLongException.
$script:RcbLongPathHint = 'path is longer than 260 characters; enable Win32 long paths (gpedit: Computer Configuration > Administrative Templates > System > Filesystem > Enable Win32 long paths, or registry HKLM\SYSTEM\CurrentControlSet\Control\FileSystem LongPathsEnabled=1) or move the project to a shorter folder'

<#
.SYNOPSIS
    True on Windows PowerShell 5.1 (.NET Framework), where paths of 260+
    characters (248+ for folders) are rejected unless they carry \\?\.
#>
function Test-RcbLegacyPathRuntime {
    return ($env:OS -eq 'Windows_NT' -and $PSVersionTable.PSVersion.Major -lt 6)
}

<#
.SYNOPSIS
    Adds the \\?\ (or \\?\UNC\) long-path prefix to a full Windows path when
    running under .NET Framework and the path has 248+ characters, or always
    with -Force. Never double-prefixes; relative, device and non-Windows
    paths are returned unchanged.
#>
function ConvertTo-RcbLongPath {
    param([string]$Path, [switch]$Force)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    if ($Path.StartsWith('\\?\', [System.StringComparison]::Ordinal)) { return $Path }
    if (-not $Force) {
        if ($Path.Length -lt 248) { return $Path }
        if (-not (Test-RcbLegacyPathRuntime)) { return $Path }
    }
    if ($Path.StartsWith('\\.\', [System.StringComparison]::Ordinal)) { return $Path }
    if ($Path.StartsWith('\\', [System.StringComparison]::Ordinal)) {
        return ('\\?\UNC\' + $Path.Substring(2).Replace('/', '\'))
    }
    if ($Path.Length -ge 3 -and [char]::IsLetter($Path[0]) -and $Path[1] -eq [char]58 -and ($Path[2] -eq [char]92 -or $Path[2] -eq [char]47)) {
        return ('\\?\' + $Path.Replace('/', '\'))
    }
    return $Path
}

<#
.SYNOPSIS
    Removes the \\?\ or \\?\UNC\ prefix again (for paths shown to the user
    or handed back to callers).
#>
function ConvertFrom-RcbLongPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    if ($Path.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) { return ('\\' + $Path.Substring(8)) }
    if ($Path.StartsWith('\\?\', [System.StringComparison]::Ordinal)) { return $Path.Substring(4) }
    return $Path
}

<#
.SYNOPSIS
    Message text for an exception: the long-path hint when the exception (or
    any inner exception) is a PathTooLongException, else its Message.
#>
function Get-RcbErrorText {
    param($Exception)
    if ($null -eq $Exception) { return '' }
    $e = $Exception
    while ($null -ne $e) {
        if ($e -is [System.IO.PathTooLongException]) { return $script:RcbLongPathHint }
        $e = $e.InnerException
    }
    return [string]$Exception.Message
}

<#
.SYNOPSIS
    Quotes one argument for a Windows command line (CommandLineToArgvW rules):
    backslashes are doubled only before a quote or before the closing quote.
#>
# ConvertTo-RcbWindowsArgument, Join-RcbCommandLine, Set-RcbProcessArgument
# and Stop-RcbProcessTree live in lib/BuildCore.ps1 (shared with build.ps1).

function ConvertTo-RcbSafeFileName {
    param([string]$Name, [int]$MaxLength = 48)
    $s = [regex]::Replace([string]$Name, '[<>:"/\\|?*\x00-\x1F]', '_')
    $s = $s.Trim().TrimEnd([char[]]'. ')
    if ($MaxLength -gt 0 -and $s.Length -gt $MaxLength) {
        $s = $s.Substring(0, $MaxLength)
        if ([char]::IsHighSurrogate($s[$s.Length - 1])) { $s = $s.Substring(0, $s.Length - 1) }
        $s = $s.TrimEnd([char[]]'. ')
    }
    if ($s.Length -eq 0) { $s = 'project' }
    return $s
}

<#
.SYNOPSIS
    Writes bytes to a file through a temp file in the same folder and a
    replace, so a crash cannot leave a truncated file behind.
#>
function Write-RcbFileAtomic {
    param([Parameter(Mandatory = $true)][string]$Path, [byte[]]$Bytes)
    if ($null -eq $Bytes) { $Bytes = New-Object byte[] 0 }
    # The temp name adds 41 characters, so decide on the long-path prefix with that included.
    $forceLong = ((Test-RcbLegacyPathRuntime) -and (($Path.Length + 41) -ge 248))
    $Path = ConvertTo-RcbLongPath $Path -Force:$forceLong
    $tmp = $Path + '.rcb-tmp-' + [guid]::NewGuid().ToString('N')
    try {
        [System.IO.File]::WriteAllBytes($tmp, $Bytes)
        if ([System.IO.File]::Exists($Path)) {
            try {
                [System.IO.File]::Replace($tmp, $Path, [NullString]::Value)
            } catch {
                # File.Replace is not supported on every file system; fall back to an overwrite.
                [System.IO.File]::Copy($tmp, $Path, $true)
            }
        } else {
            [System.IO.File]::Move($tmp, $Path)
        }
    } finally {
        try { if ([System.IO.File]::Exists($tmp)) { [System.IO.File]::Delete($tmp) } } catch { $null = $_ }
    }
}

# -------------------------------------------------------------------------
# Versions
# -------------------------------------------------------------------------

<#
.SYNOPSIS
    Parses an rtk tag like "v1.0.1" or "1.0.1-rc1". Returns $null if not semver.
#>
function ConvertTo-RtkVersion {
    param([string]$Tag)
    if ([string]::IsNullOrEmpty($Tag)) { return $null }
    $m = [regex]::Match($Tag.Trim(), '^[vV]?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.\-]+))?(?:\+[0-9A-Za-z.\-]+)?$')
    if (-not $m.Success) { return $null }
    $major = 0; $minor = 0; $patch = 0
    if (-not [int]::TryParse($m.Groups[1].Value, [ref]$major)) { return $null }
    if (-not [int]::TryParse($m.Groups[2].Value, [ref]$minor)) { return $null }
    if (-not [int]::TryParse($m.Groups[3].Value, [ref]$patch)) { return $null }
    $pre = $null
    if ($m.Groups[4].Success) { $pre = $m.Groups[4].Value }
    return [PSCustomObject]@{
        Tag        = $Tag.Trim()
        Version    = New-Object System.Version($major, $minor, $patch)
        PreRelease = $pre
    }
}

<#
.SYNOPSIS
    Compares two rtk tags. Returns -1, 0 or 1. Non-semver tags throw.
    A pre-release sorts before the matching release (v1.0.0-rc1 < v1.0.0).
#>
function Compare-RtkVersion {
    param([string]$A, [string]$B)
    $va = ConvertTo-RtkVersion $A
    $vb = ConvertTo-RtkVersion $B
    if ($null -eq $va -or $null -eq $vb) { throw "Not a semver tag: '$A' or '$B'" }
    $c = $va.Version.CompareTo($vb.Version)
    if ($c -ne 0) { return [math]::Sign($c) }
    if ($null -eq $va.PreRelease -and $null -eq $vb.PreRelease) { return 0 }
    if ($null -eq $va.PreRelease) { return 1 }
    if ($null -eq $vb.PreRelease) { return -1 }
    return [math]::Sign([string]::CompareOrdinal($va.PreRelease, $vb.PreRelease))
}

<#
.SYNOPSIS
    Picks the highest stable semver tag from a list of tag names.
#>
function Select-RtkLatestTag {
    param([string[]]$Tags)
    $best = $null
    foreach ($t in $Tags) {
        $v = ConvertTo-RtkVersion $t
        if ($null -eq $v -or $null -ne $v.PreRelease) { continue }
        if ($null -eq $best -or (Compare-RtkVersion $t $best) -gt 0) { $best = $t }
    }
    return $best
}

# -------------------------------------------------------------------------
# Cargo.toml scanning
# -------------------------------------------------------------------------

<#
.SYNOPSIS
    Returns $true when a git URL points at the rtk repository.
#>
function Test-RtkGitUrl {
    param([string]$Url)
    if ([string]::IsNullOrEmpty($Url)) { return $false }
    return $script:RtkReGitUrl.IsMatch($Url.Trim())
}

<#
.SYNOPSIS
    Maps any accepted rtk git URL form (scp-like ssh, ssh://, git://, http(s),
    with or without .git, trailing slash or userinfo) to the canonical
    https URL. Returns $null for anything that is not the rtk repository.
#>
function ConvertTo-RtkHttpsUrl {
    param([string]$Url)
    if (-not (Test-RtkGitUrl $Url)) { return $null }
    return 'https://github.com/ubcool2ic/rtk'
}

<#
.SYNOPSIS
    Parses the top-level "key = string" pairs of an inline table body (or a
    single "key = value" line). Strings, arrays and nested tables are skipped
    correctly; only string values are returned. Keys are case-sensitive.
#>
function ConvertFrom-RtkInlineTable {
    param([string]$Body, $Positions = $null)
    $map = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    if ([string]::IsNullOrEmpty($Body)) { return ,$map }
    $n = $Body.Length
    $i = 0
    while ($i -lt $n) {
        while ($i -lt $n -and ($Body[$i] -eq [char]32 -or $Body[$i] -eq [char]9 -or $Body[$i] -eq [char]44)) { $i++ }
        if ($i -ge $n) { break }
        $eq = $Body.IndexOf('=', $i)
        if ($eq -lt 0) { break }
        $key = $Body.Substring($i, $eq - $i).Trim().Trim($script:RtkQuoteChars)
        $i = $eq + 1
        while ($i -lt $n -and ($Body[$i] -eq [char]32 -or $Body[$i] -eq [char]9)) { $i++ }
        if ($i -ge $n) { break }
        $ch = $Body[$i]
        # Optional: offset (inside $Body) where the value of each key starts.
        if ($null -ne $Positions) { $Positions[$key] = $i }
        if ($ch -eq [char]34) {
            # basic string: backslash escapes the next character
            $sb = New-Object System.Text.StringBuilder
            $i++
            while ($i -lt $n -and $Body[$i] -ne [char]34) {
                if ($Body[$i] -eq [char]92 -and ($i + 1) -lt $n) { $i++ }
                [void]$sb.Append($Body[$i])
                $i++
            }
            $i++
            $map[$key] = $sb.ToString()
        } elseif ($ch -eq [char]39) {
            # literal string: no escapes
            $end = $Body.IndexOf([char]39, $i + 1)
            if ($end -lt 0) { break }
            $map[$key] = $Body.Substring($i + 1, $end - $i - 1)
            $i = $end + 1
        } else {
            # number, bool, array or nested table: skip to the next top-level comma
            $depth = 0
            $inQuote = $false
            $quoteChar = [char]34
            while ($i -lt $n) {
                $c = $Body[$i]
                if ($inQuote) {
                    if ($c -eq [char]92 -and $quoteChar -eq [char]34) { $i++ }
                    elseif ($c -eq $quoteChar) { $inQuote = $false }
                } elseif ($c -eq [char]34 -or $c -eq [char]39) { $inQuote = $true; $quoteChar = $c }
                elseif ($c -eq [char]91 -or $c -eq [char]123) { $depth++ }
                elseif ($c -eq [char]93 -or $c -eq [char]125) { $depth-- }
                elseif ($c -eq [char]44 -and $depth -le 0) { break }
                $i++
            }
        }
    }
    return ,$map
}

<#
.SYNOPSIS
    Reads a quoted string value for a key from an inline table body or a
    "key = value" line. Returns $null when the key is absent. The key is
    matched literally (no regex), and text inside other strings is ignored.
#>
function Get-TomlKeyValue {
    param([string]$Text, [string]$Key)
    if ([string]::IsNullOrEmpty($Text) -or [string]::IsNullOrEmpty($Key)) { return $null }
    $t = $Text.Trim()
    if ($t.Length -ge 2 -and $t[0] -eq [char]123 -and $t[$t.Length - 1] -eq [char]125) { $t = $t.Substring(1, $t.Length - 2) }
    $map = ConvertFrom-RtkInlineTable $t
    if ($map.ContainsKey($Key)) { return $map[$Key] }
    return $null
}

<#
.SYNOPSIS
    Strips a trailing TOML comment that is not inside a quoted string
    (handles \" inside basic strings and '...' literal strings).
#>
function Remove-TomlComment {
    param([string]$Line)
    if ([string]::IsNullOrEmpty($Line)) { return $Line }
    $hash = $Line.IndexOf('#')
    if ($hash -lt 0) { return $Line }
    $q = $Line.IndexOfAny($script:RtkQuoteChars)
    if ($q -lt 0 -or $q -gt $hash) { return $Line.Substring(0, $hash) }
    $inDq = $false; $inSq = $false
    for ($i = $q; $i -lt $Line.Length; $i++) {
        $ch = $Line[$i]
        if ($inDq) {
            if ($ch -eq [char]92) { $i++ }
            elseif ($ch -eq [char]34) { $inDq = $false }
        } elseif ($inSq) {
            if ($ch -eq [char]39) { $inSq = $false }
        } elseif ($ch -eq [char]34) { $inDq = $true }
        elseif ($ch -eq [char]39) { $inSq = $true }
        elseif ($ch -eq [char]35) { return $Line.Substring(0, $i) }
    }
    return $Line
}

<#
.SYNOPSIS
    Joins physical TOML lines into logical lines. Internal helper.

.DESCRIPTION
    Physical lines are accumulated while a bracket or brace is open outside a
    string, or while a multi-line string (""" or ''') is open. Comments are
    removed, the content of multi-line strings is dropped (the value becomes
    an empty string) and the pieces are joined with one space. Each result
    is a hashtable: Text (trimmed), Start (0-based physical line of the first
    piece) and Offsets (start offset in Text of every physical line, or
    $null when the logical line is a single physical line).
#>
function Get-RtkLogicalLine {
    param([string[]]$Lines)
    $out = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Lines) { return ,$out }
    $ord = [System.StringComparison]::Ordinal
    $dq3 = '"""'
    $sq3 = "'''"
    $sb = New-Object System.Text.StringBuilder
    $offsets = New-Object System.Collections.Generic.List[int]
    $depth = 0
    $ml = 0          # 0 = none, 1 = inside """, 2 = inside '''
    $start = -1
    $last = $Lines.Length - 1
    for ($li = 0; $li -le $last; $li++) {
        $raw = [string]$Lines[$li]
        if ($raw.Length -gt 0 -and $raw[$raw.Length - 1] -eq [char]13) { $raw = $raw.Substring(0, $raw.Length - 1) }
        if ($start -lt 0) {
            # Fast path: nothing on this line can open a multi-line construct.
            if ($raw.IndexOfAny($script:RtkOpenChars) -lt 0 -and $raw.IndexOf($dq3, $ord) -lt 0 -and $raw.IndexOf($sq3, $ord) -lt 0) {
                $t = $raw
                if ($t.IndexOf('#') -ge 0) { $t = Remove-TomlComment $t }
                $t = $t.Trim()
                if ($t.Length -gt 0) { $out.Add(@{ Text = $t; Start = $li; Offsets = $null }) }
                continue
            }
            $start = $li
            $sb.Length = 0
            $offsets.Clear()
            $depth = 0
            $ml = 0
        } else {
            [void]$sb.Append(' ')
        }
        $offsets.Add($sb.Length)

        $n = $raw.Length
        $i = 0
        while ($i -lt $n) {
            $c = $raw[$i]
            if ($ml -eq 1) {
                if ($c -eq [char]92) { $i += 2; continue }
                if ($c -eq [char]34 -and ($i + 2) -lt $n -and $raw[$i + 1] -eq [char]34 -and $raw[$i + 2] -eq [char]34) {
                    $i += 3
                    $extra = 0
                    while ($extra -lt 2 -and $i -lt $n -and $raw[$i] -eq [char]34) { $i++; $extra++ }
                    $ml = 0
                    continue
                }
                $i++
                continue
            }
            if ($ml -eq 2) {
                $e = $raw.IndexOf($sq3, $i, $ord)
                if ($e -lt 0) { break }
                $i = $e + 3
                $extra = 0
                while ($extra -lt 2 -and $i -lt $n -and $raw[$i] -eq [char]39) { $i++; $extra++ }
                $ml = 0
                continue
            }
            if ($c -eq [char]34) {
                if (($i + 2) -lt $n -and $raw[$i + 1] -eq [char]34 -and $raw[$i + 2] -eq [char]34) {
                    [void]$sb.Append('""')
                    $ml = 1
                    $i += 3
                    continue
                }
                $j = $i + 1
                while ($j -lt $n -and $raw[$j] -ne [char]34) {
                    if ($raw[$j] -eq [char]92) { $j++ }
                    $j++
                }
                if ($j -ge $n) { $j = $n - 1 }
                [void]$sb.Append($raw.Substring($i, $j - $i + 1))
                $i = $j + 1
                continue
            }
            if ($c -eq [char]39) {
                if (($i + 2) -lt $n -and $raw[$i + 1] -eq [char]39 -and $raw[$i + 2] -eq [char]39) {
                    [void]$sb.Append("''")
                    $ml = 2
                    $i += 3
                    continue
                }
                $j = -1
                if (($i + 1) -lt $n) { $j = $raw.IndexOf([char]39, $i + 1) }
                if ($j -lt 0) { $j = $n - 1 }
                [void]$sb.Append($raw.Substring($i, $j - $i + 1))
                $i = $j + 1
                continue
            }
            if ($c -eq [char]35) { break }
            if ($c -eq [char]91 -or $c -eq [char]123) { $depth++ }
            elseif ($c -eq [char]93 -or $c -eq [char]125) { if ($depth -gt 0) { $depth-- } }
            [void]$sb.Append($c)
            $i++
        }

        if (($depth -le 0 -and $ml -eq 0) -or $li -eq $last) {
            $text = $sb.ToString()
            $lead = 0
            while ($lead -lt $text.Length -and [char]::IsWhiteSpace($text[$lead])) { $lead++ }
            $t = $text.Trim()
            if ($t.Length -gt 0) {
                $offs = $null
                if ($offsets.Count -gt 1) {
                    $offs = New-Object int[] $offsets.Count
                    for ($k = 0; $k -lt $offsets.Count; $k++) {
                        $v = $offsets[$k] - $lead
                        if ($v -lt 0) { $v = 0 }
                        $offs[$k] = $v
                    }
                }
                $out.Add(@{ Text = $t; Start = $start; Offsets = $offs })
            }
            $start = -1
            $depth = 0
            $ml = 0
        }
    }
    return ,$out
}

<#
.SYNOPSIS
    0-based physical line that holds the character at $Offset of a logical
    line produced by Get-RtkLogicalLine. Internal helper.
#>
function Get-RtkPhysicalLine {
    param($Logical, [int]$Offset)
    $offs = $Logical.Offsets
    if ($null -eq $offs) { return [int]$Logical.Start }
    $k = 0
    for ($j = 1; $j -lt $offs.Length; $j++) {
        if ($offs[$j] -le $Offset) { $k = $j } else { break }
    }
    return ([int]$Logical.Start + $k)
}

<#
.SYNOPSIS
    Adds a table-form or dotted-key dependency to the result list when its git
    URL is rtk. Internal helper for Get-RtkDependency.
#>
function Add-RtkTableDep {
    param($Dep, $Results, [string]$ManifestPath, [string]$Form = 'table')
    if ($null -eq $Dep -or -not (Test-RtkGitUrl $Dep.Git)) { return }
    $kind = 'none'; $val = $null; $idx = $Dep.HeaderLine
    foreach ($k in @('tag', 'rev', 'branch')) {
        if ($Dep.Pins.ContainsKey($k)) { $kind = $k; $val = $Dep.Pins[$k].Value; $idx = $Dep.Pins[$k].Line; break }
    }
    $Results.Add([PSCustomObject]@{
        ManifestPath = $ManifestPath
        Section      = $Dep.Section
        DepName      = $Dep.Name
        GitUrl       = $Dep.Git
        PinKind      = $kind
        PinValue     = $val
        LineIndex    = $idx
        Form         = $Form
    })
}

<#
.SYNOPSIS
    Finds every rtk git dependency in one Cargo.toml.

.DESCRIPTION
    Handles inline tables (rtk = { git = "...", tag = "v0.8.2" }), renamed deps
    (gui = { package = "rtk", git = "..." }), table form
    ([dependencies.rtk] / [target.'cfg(windows)'.dependencies.rtk] /
    [workspace.dependencies.rtk]) and dotted keys (rtk.git = "..." /
    rtk.tag = "..."). Each result has PinKind tag, rev, branch or none, the
    pin value, and the 0-based line index (lines split on LF, the same way
    Set-RtkTagPin counts them) holding the pin, or the dep line when unpinned.
#>
function Get-RtkDependency {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    $results = New-Object System.Collections.Generic.List[PSCustomObject]
    $full = ConvertTo-RcbLongPath (Resolve-RcbFullPath $ManifestPath)
    if (-not [System.IO.File]::Exists($full)) { return $results.ToArray() }
    $text = [System.IO.File]::ReadAllText($full)
    # Fast path: no "rtk" anywhere means no rtk dependency.
    if ($text.IndexOf('rtk', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { return $results.ToArray() }
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $lines = $text.Split([char]10)
    # Logical lines: multi-line inline tables, arrays and """/''' strings are
    # joined (string content dropped); each keeps its physical line numbers.
    $logical = Get-RtkLogicalLine -Lines $lines

    $section = ''
    $inDeps = $false
    $tableDep = $null   # state while inside [....dependencies.<name>]
    $dotted = $null     # name -> state for dotted keys inside a dependencies section

    foreach ($ll in $logical) {
        $line = [string]$ll.Text
        $i = [int]$ll.Start
        if ($line.Length -eq 0) { continue }

        if ($line[0] -eq [char]91) {
            $isArrayTable = $line.StartsWith('[[', [System.StringComparison]::Ordinal)
            $h = $null
            if (-not $isArrayTable) {
                $h = $script:RtkReHeader.Match($line)
                # Not a table header (e.g. a continuation line of a multi-line array).
                if (-not $h.Success) { continue }
            }
            if ($null -ne $tableDep) { Add-RtkTableDep -Dep $tableDep -Results $results -ManifestPath $ManifestPath -Form 'table'; $tableDep = $null }
            if ($null -ne $dotted) {
                foreach ($dd in $dotted.Values) { Add-RtkTableDep -Dep $dd -Results $results -ManifestPath $ManifestPath -Form 'dotted' }
                $dotted = $null
            }
            if ($isArrayTable) { $section = $line; $inDeps = $false; continue }
            $section = $h.Groups[1].Value
            $dm = $script:RtkReDepTable.Match($section)
            if ($dm.Success) {
                $tableDep = @{ Name = $dm.Groups[4].Value; Section = $section; HeaderLine = $i; Git = $null; Pins = @{} }
                $inDeps = $false
            } else {
                $inDeps = $script:RtkReDepSection.IsMatch($section)
            }
            continue
        }

        if ($null -ne $tableDep) {
            if ($line.IndexOf('=') -lt 0) { continue }
            $kv = $script:RtkReTableKey.Match($line)
            if ($kv.Success) {
                $k = $kv.Groups[2].Value
                $v = if ($kv.Groups[3].Success) { $kv.Groups[3].Value } else { $kv.Groups[4].Value }
                $vi = if ($kv.Groups[3].Success) { $kv.Groups[3].Index } else { $kv.Groups[4].Index }
                if ($k -ceq 'git') { $tableDep.Git = $v }
                elseif ($k -ceq 'tag' -or $k -ceq 'rev' -or $k -ceq 'branch') { $tableDep.Pins[$k] = @{ Value = $v; Line = (Get-RtkPhysicalLine $ll $vi) } }
            }
            continue
        }

        if (-not $inDeps) { continue }

        if ($line.IndexOf('{') -ge 0) {
            if ($line.IndexOf('git', [System.StringComparison]::Ordinal) -lt 0) { continue }
            $im = $script:RtkReInline.Match($line)
            if (-not $im.Success) { continue }
            $posMap = New-Object 'System.Collections.Generic.Dictionary[string,int]'
            $map = ConvertFrom-RtkInlineTable -Body $im.Groups[3].Value -Positions $posMap
            if (-not $map.ContainsKey('git')) { continue }
            $git = $map['git']
            if (-not (Test-RtkGitUrl $git)) { continue }
            $kind = 'none'; $val = $null; $pinLine = $i
            foreach ($k in @('tag', 'rev', 'branch')) {
                if ($map.ContainsKey($k)) {
                    $kind = $k; $val = $map[$k]
                    # Physical line holding the pin value (the table may span lines).
                    if ($posMap.ContainsKey($k)) { $pinLine = Get-RtkPhysicalLine $ll ($im.Groups[3].Index + $posMap[$k]) }
                    break
                }
            }
            $results.Add([PSCustomObject]@{
                ManifestPath = $ManifestPath
                Section      = $section
                DepName      = $im.Groups[2].Value
                GitUrl       = $git
                PinKind      = $kind
                PinValue     = $val
                LineIndex    = $pinLine
                Form         = 'inline'
            })
            continue
        }

        # Dotted keys: rtk.git = "..." / rtk.tag = "..."
        if ($line.IndexOf('.') -lt 0) { continue }
        $dk = $script:RtkReDotted.Match($line)
        if (-not $dk.Success) { continue }
        $name = $dk.Groups[2].Value
        $k = $dk.Groups[3].Value
        $v = if ($dk.Groups[4].Success) { $dk.Groups[4].Value } else { $dk.Groups[5].Value }
        $vi = if ($dk.Groups[4].Success) { $dk.Groups[4].Index } else { $dk.Groups[5].Index }
        if ($null -eq $dotted) { $dotted = New-Object System.Collections.Specialized.OrderedDictionary }
        if (-not $dotted.Contains($name)) {
            $dotted[$name] = @{ Name = $name; Section = $section; HeaderLine = $i; Git = $null; Pins = @{} }
        }
        $state = $dotted[$name]
        if ($k -ceq 'git') { $state.Git = $v }
        elseif ($k -ceq 'tag' -or $k -ceq 'rev' -or $k -ceq 'branch') { $state.Pins[$k] = @{ Value = $v; Line = (Get-RtkPhysicalLine $ll $vi) } }
    }
    if ($null -ne $tableDep) { Add-RtkTableDep -Dep $tableDep -Results $results -ManifestPath $ManifestPath -Form 'table' }
    if ($null -ne $dotted) {
        foreach ($dd in $dotted.Values) { Add-RtkTableDep -Dep $dd -Results $results -ManifestPath $ManifestPath -Form 'dotted' }
    }
    return $results.ToArray()
}

<#
.SYNOPSIS
    True when a Cargo.toml declares a workspace ([workspace] or any
    [workspace.*] table). Unreadable files count as "not a workspace".
#>
function Test-RcbWorkspaceManifest {
    param([string]$ManifestPath)
    $text = $null
    try { $text = [System.IO.File]::ReadAllText((ConvertTo-RcbLongPath (Resolve-RcbFullPath $ManifestPath))) } catch { return $false }
    if ([string]::IsNullOrEmpty($text)) { return $false }
    if ($text.IndexOf('workspace', [System.StringComparison]::Ordinal) -lt 0) { return $false }
    return $script:RtkReWorkspace.IsMatch($text)
}

<#
.SYNOPSIS
    Reads the [workspace] table of a Cargo.toml.

.DESCRIPTION
    Returns a hashtable: IsWorkspace, Members ([string[]] globs), Exclude
    ([string[]]) and HasPackage (the manifest also has [package]). Arrays may
    span lines. Unreadable files give IsWorkspace = $false and empty lists.
#>
function Get-RcbWorkspaceInfo {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)
    $info = @{ IsWorkspace = $false; Members = [string[]]@(); Exclude = [string[]]@(); HasPackage = $false }
    $text = $null
    try { $text = [System.IO.File]::ReadAllText((ConvertTo-RcbLongPath (Resolve-RcbFullPath $ManifestPath))) } catch { return $info }
    if ([string]::IsNullOrEmpty($text)) { return $info }
    if ($text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $members = New-Object System.Collections.Generic.List[string]
    $exclude = New-Object System.Collections.Generic.List[string]
    $section = ''
    foreach ($ll in (Get-RtkLogicalLine -Lines $text.Split([char]10))) {
        $line = [string]$ll.Text
        if ($line.Length -eq 0) { continue }
        if ($line[0] -eq [char]91) {
            if ($line.StartsWith('[[', [System.StringComparison]::Ordinal)) { $section = $line; continue }
            $h = $script:RtkReHeader.Match($line)
            if (-not $h.Success) { continue }
            $section = $h.Groups[1].Value
            if ($section -ceq 'workspace' -or $section -cmatch '^workspace\s*\.') { $info.IsWorkspace = $true }
            elseif ($section -ceq 'package') { $info.HasPackage = $true }
            continue
        }
        if ($section -cne 'workspace') { continue }
        $m = $script:RcbReWsArray.Match($line)
        if (-not $m.Success) { continue }
        $target = $members
        if ($m.Groups[2].Value -ceq 'exclude') { $target = $exclude }
        foreach ($sm in $script:RcbReTomlString.Matches($m.Groups[3].Value)) {
            $s = $null
            if ($sm.Groups[1].Success) { $s = [regex]::Replace($sm.Groups[1].Value, '\\(.)', '$1') } else { $s = $sm.Groups[2].Value }
            if (-not [string]::IsNullOrEmpty($s) -and $s.Trim().Length -gt 0) { $target.Add($s.Trim()) }
        }
    }
    $info.Members = [string[]]$members.ToArray()
    $info.Exclude = [string[]]$exclude.ToArray()
    return $info
}

<#
.SYNOPSIS
    Appends the normalized segments of a path to two parallel lists (segment
    text, and whether it came from a glob pattern). "." is dropped and ".."
    removes the previous segment. Internal helper.
#>
function Add-RcbPathSegment {
    param([string]$Path, $Segments, $Flags, [bool]$IsPattern)
    foreach ($s in ([string]$Path).Replace('\', '/').Split([char]47)) {
        if ($s.Length -eq 0 -or $s -ceq '.') { continue }
        if ($s -ceq '..') {
            if ($Segments.Count -gt 0) { $Segments.RemoveAt($Segments.Count - 1); $Flags.RemoveAt($Flags.Count - 1) }
            continue
        }
        $Segments.Add($s)
        $Flags.Add($IsPattern)
    }
}

<#
.SYNOPSIS
    Compares pattern segments with path segments ('*' and '?' only inside
    pattern segments, never across '/'). Internal helper.
#>
function Test-RcbSegmentMatch {
    param($PatSegs, $PatFlags, $PathSegs, [bool]$PrefixOnly, [bool]$IgnoreCase)
    if ($PrefixOnly) {
        if ($PatSegs.Count -gt $PathSegs.Count) { return $false }
    } elseif ($PatSegs.Count -ne $PathSegs.Count) {
        return $false
    }
    $cmp = [System.StringComparison]::Ordinal
    $opt = [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    if ($IgnoreCase) {
        $cmp = [System.StringComparison]::OrdinalIgnoreCase
        $opt = $opt -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    }
    for ($i = 0; $i -lt $PatSegs.Count; $i++) {
        $pat = [string]$PatSegs[$i]
        $name = [string]$PathSegs[$i]
        if ($PatFlags[$i] -and $pat.IndexOfAny($script:RcbGlobChars) -ge 0) {
            $rx = '^' + [regex]::Escape($pat).Replace('\*', '[^/]*').Replace('\?', '[^/]') + '$'
            if (-not [regex]::IsMatch($name, $rx, $opt)) { return $false }
        } elseif (-not [string]::Equals($pat, $name, $cmp)) {
            return $false
        }
    }
    return $true
}

<#
.SYNOPSIS
    True when a package folder is a member of a workspace.

.DESCRIPTION
    Cargo-like rules: the root folder itself is always a member; a folder at
    or below an exclude path is not; otherwise it must match one member
    pattern exactly. Patterns are relative to the root; '*' and '?' match
    inside one path segment ('**' is not supported and acts like '*').
#>
function Test-RcbWorkspaceMember {
    param(
        [string]$WorkspaceRoot,
        [string]$PackageDir,
        [string[]]$Members = @(),
        [string[]]$Exclude = @()
    )
    if ([string]::IsNullOrEmpty($WorkspaceRoot) -or [string]::IsNullOrEmpty($PackageDir)) { return $false }
    $ci = ($env:OS -eq 'Windows_NT')
    $rootSegs = New-Object System.Collections.Generic.List[string]
    $rootFlags = New-Object System.Collections.Generic.List[bool]
    Add-RcbPathSegment (Resolve-RcbFullPath $WorkspaceRoot) $rootSegs $rootFlags $false
    $pkgSegs = New-Object System.Collections.Generic.List[string]
    $pkgFlags = New-Object System.Collections.Generic.List[bool]
    Add-RcbPathSegment (Resolve-RcbFullPath $PackageDir) $pkgSegs $pkgFlags $false

    if (Test-RcbSegmentMatch $rootSegs $rootFlags $pkgSegs $false $ci) { return $true }

    foreach ($ex in @($Exclude)) {
        if ([string]::IsNullOrEmpty($ex) -or $ex.Trim().Length -eq 0) { continue }
        $segs = New-Object System.Collections.Generic.List[string]
        $flags = New-Object System.Collections.Generic.List[bool]
        $segs.AddRange($rootSegs)
        $flags.AddRange($rootFlags)
        Add-RcbPathSegment $ex $segs $flags $true
        if (Test-RcbSegmentMatch $segs $flags $pkgSegs $true $ci) { return $false }
    }
    foreach ($mb in @($Members)) {
        if ([string]::IsNullOrEmpty($mb) -or $mb.Trim().Length -eq 0) { continue }
        $segs = New-Object System.Collections.Generic.List[string]
        $flags = New-Object System.Collections.Generic.List[bool]
        $segs.AddRange($rootSegs)
        $flags.AddRange($rootFlags)
        Add-RcbPathSegment $mb $segs $flags $true
        if (Test-RcbSegmentMatch $segs $flags $pkgSegs $false $ci) { return $true }
    }
    return $false
}

<#
.SYNOPSIS
    Lists Cargo.toml full paths under a folder without ever descending into
    target, .git, node_modules or _built (case-insensitive).

.DESCRIPTION
    Uses an explicit stack (no recursion). Follows reparse points and symlinks
    with a visited set of resolved paths (OneDrive / linked dirs are found;
    loops cannot hang the walk). Folders that cannot be read are logged and skipped.
    With -ExcludeWorkspaceMembers a workspace root is returned and the walk
    goes on below it, skipping only member package folders (and their
    subtrees), so excluded and non-member packages are found as separate
    projects. A workspace without a members list is not descended into
    (everything below counts as a member). Parents come before their
    children; siblings are in ordinal (case-insensitive) order.
#>
function Get-RcbCargoManifest {
    param(
        [Parameter(Mandatory = $true)][string]$RootDirectory,
        [switch]$ExcludeWorkspaceMembers
    )
    $found = New-Object System.Collections.Generic.List[string]
    $root = Resolve-RcbFullPath $RootDirectory
    if ([string]::IsNullOrEmpty($root) -or -not [System.IO.Directory]::Exists((ConvertTo-RcbLongPath $root))) { return $found.ToArray() }
    # Paths kept in $stack/$found stay un-prefixed; only the I/O calls get \\?\.
    $legacy = Test-RcbLegacyPathRuntime
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($root)
    # Parallel stack: the enclosing workspace (Root/Members/Exclude) or $null.
    $ctxStack = New-Object System.Collections.Generic.Stack[object]
    $ctxStack.Push($null)
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    [void]$visited.Add((Get-RcbRealDirectoryPath $root))
    $subs = New-Object System.Collections.Generic.List[string]
    if ($null -eq $script:RcbDiscoverySkipped) { $script:RcbDiscoverySkipped = New-Object System.Collections.Generic.List[string] }
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $ctx = $ctxStack.Pop()
        $manifest = [System.IO.Path]::Combine($dir, 'Cargo.toml')
        $isFile = $false
        $manifestIo = $manifest
        $dirIo = $dir
        if ($legacy) {
            $manifestIo = ConvertTo-RcbLongPath $manifest
            $dirIo = ConvertTo-RcbLongPath $dir
        }
        try { $isFile = [System.IO.File]::Exists($manifestIo) } catch { $isFile = $false }
        if ($isFile) {
            $found.Add($manifest)
            if ($ExcludeWorkspaceMembers -and (Test-RcbWorkspaceManifest $manifest)) {
                $wsInfo = Get-RcbWorkspaceInfo -ManifestPath $manifest
                if ($wsInfo.IsWorkspace) {
                    # No members list (virtual manifest without members, or a
                    # package with a bare [workspace]): keep the old behaviour
                    # and treat everything below as members.
                    if ($wsInfo.Members.Length -eq 0) { continue }
                    $ctx = @{ Root = $dir; Members = $wsInfo.Members; Exclude = $wsInfo.Exclude }
                }
            }
        }
        $subs.Clear()
        try {
            foreach ($d in (New-Object System.IO.DirectoryInfo($dirIo)).EnumerateDirectories()) {
                if ($script:RcbPrunedDirs.Contains($d.Name)) {
                    # A member crate may be named "target". Never treat .git,
                    # node_modules or _built as a crate, even if they contain a Cargo.toml.
                    $isTargetCrate = $false
                    if ([string]::Equals($d.Name, 'target', [System.StringComparison]::OrdinalIgnoreCase)) {
                        $crateToml = [System.IO.Path]::Combine($d.FullName, 'Cargo.toml')
                        try { $isTargetCrate = [System.IO.File]::Exists($crateToml) } catch { $isTargetCrate = $false }
                    }
                    if (-not $isTargetCrate) { continue }
                }
                $sub = [System.IO.Path]::Combine($dir, $d.Name)
                $real = Get-RcbRealDirectoryPath $sub
                if (-not $visited.Add($real)) {
                    $script:RcbDiscoverySkipped.Add("loop: $sub -> $real")
                    continue
                }
                # Member packages belong to the workspace root: skip them and their subtree.
                if ($null -ne $ctx -and (Test-RcbWorkspaceMember -WorkspaceRoot $ctx.Root -PackageDir $sub -Members $ctx.Members -Exclude $ctx.Exclude)) { continue }
                $subs.Add($sub)
            }
        } catch {
            $script:RcbDiscoverySkipped.Add("${dir}: $($_.Exception.Message)")
        }
        if ($subs.Count -gt 1) { $subs.Sort([System.StringComparer]::OrdinalIgnoreCase) }
        for ($j = $subs.Count - 1; $j -ge 0; $j--) { $stack.Push($subs[$j]); $ctxStack.Push($ctx) }
    }
    return $found.ToArray()
}

<#
.SYNOPSIS
    Lists the Cargo.toml files that belong to one project: just its own
    manifest, or every member manifest under a workspace root.
#>
function Get-ProjectManifestSet {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)
    $full = Resolve-RcbFullPath $ManifestPath
    if (-not [System.IO.File]::Exists((ConvertTo-RcbLongPath $full))) { return @($ManifestPath) }
    if (-not (Test-RcbWorkspaceManifest $full)) { return @($ManifestPath) }
    $wsInfo = Get-RcbWorkspaceInfo -ManifestPath $full
    if (-not $wsInfo.IsWorkspace) { return @($ManifestPath) }
    $root = [System.IO.Path]::GetDirectoryName($full)
    $list = New-Object System.Collections.Generic.List[string]
    $list.Add($ManifestPath)
    # No members list: old behaviour, every manifest below the root counts as a member.
    $filter = ($wsInfo.Members.Length -gt 0)
    foreach ($f in @(Get-RcbCargoManifest -RootDirectory $root)) {
        if ([string]::Equals($f, [System.IO.Path]::Combine($root, 'Cargo.toml'), [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($filter -and -not (Test-RcbWorkspaceMember -WorkspaceRoot $root -PackageDir ([System.IO.Path]::GetDirectoryName($f)) -Members $wsInfo.Members -Exclude $wsInfo.Exclude)) { continue }
        $list.Add($f)
    }
    return $list.ToArray()
}

<#
.SYNOPSIS
    Rewrites the tag of one rtk dependency in place.

.DESCRIPTION
    Keeps everything else byte-for-byte: UTF-8 BOM if present, CRLF/LF (also
    mixed), the quote style and the trailing newline. The file is written
    through a temp file + replace so it cannot be left truncated.
#>
function Set-RtkTagPin {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][int]$LineIndex,
        [Parameter(Mandatory = $true)][string]$OldTag,
        [Parameter(Mandatory = $true)][string]$NewTag
    )
    if ($NewTag -match '["''\\\r\n]') { throw "Refusing to write tag '$NewTag': it contains quote, backslash or newline characters." }
    $full = Resolve-RcbFullPath $ManifestPath
    $bytes = [System.IO.File]::ReadAllBytes((ConvertTo-RcbLongPath $full))
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $offset = 0
    if ($hasBom) { $offset = 3 }
    # Strict UTF-8: invalid bytes throw instead of being silently replaced.
    $enc = New-Object System.Text.UTF8Encoding($false, $true)
    $text = $enc.GetString($bytes, $offset, $bytes.Length - $offset)
    # Split keeping the separators: even slots are lines, odd slots are the line endings.
    $parts = [regex]::Split($text, '(\r?\n)')
    $pos = $LineIndex * 2
    if ($LineIndex -lt 0 -or $pos -ge $parts.Length) { throw "Line $($LineIndex + 1) does not exist in $ManifestPath" }
    $pattern = '(?<![A-Za-z0-9_\-])(tag\s*=\s*)(["''])' + [regex]::Escape($OldTag) + '\2'
    $re = New-Object System.Text.RegularExpressions.Regex($pattern)
    $newLine = $re.Replace($parts[$pos], ('${1}${2}' + $NewTag.Replace('$', '$$') + '${2}'), 1)
    if ($newLine -ceq $parts[$pos]) { throw "Could not find tag '$OldTag' on line $($LineIndex + 1) of $ManifestPath" }
    $parts[$pos] = $newLine
    $body = $enc.GetBytes(($parts -join ''))
    if ($hasBom) {
        $out = New-Object byte[] ($body.Length + 3)
        $out[0] = 0xEF; $out[1] = 0xBB; $out[2] = 0xBF
        [System.Array]::Copy($body, 0, $out, 3, $body.Length)
    } else {
        $out = $body
    }
    Write-RcbFileAtomic -Path $full -Bytes $out
}

# -------------------------------------------------------------------------
# Latest tag lookup (git ls-remote with the user's credentials, then API)
# -------------------------------------------------------------------------

<#
.SYNOPSIS
    Runs a process with a timeout, without prompting. Returns ExitCode,
    StdOut, StdErr and TimedOut. Never throws: a process that cannot be
    started gives ExitCode -1 with the reason in StdErr.
#>
function Invoke-RtkProcess {
    param([string]$FilePath, [string[]]$ArgumentList, [int]$TimeoutSec = 45, [string]$WorkingDirectory = '')
    if ($TimeoutSec -le 0) { $TimeoutSec = 45 }
    # GIT_ALLOW_PROTOCOL applies only to rtk's own git calls, not to cargo build/test.
    $r = Invoke-ToolProcess -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -TimeoutSec $TimeoutSec -ExtraEnvironment @{ GIT_ALLOW_PROTOCOL = 'https:ssh' }
    return [PSCustomObject]@{
        ExitCode  = $r.ExitCode
        StdOut    = $r.StdOut
        StdErr    = $r.StdErr
        TimedOut  = $r.TimedOut
        Cancelled = $r.Cancelled
        Lines     = $r.Lines
    }
}

<#
.SYNOPSIS
    `git ls-remote --tags -- <url>` using the user's own git credential helper.
    Returns the raw ls-remote result object. Mocked in tests.
#>
function Invoke-RtkLsRemote {
    param([string]$RepoUrl, [int]$TimeoutSec = 45)
    if ($TimeoutSec -le 0) { $TimeoutSec = 45 }
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]@{ ExitCode = 127; StdOut = ''; StdErr = 'git is not installed or not on PATH'; TimedOut = $false }
    }
    # "--" so a URL read from a Cargo.toml can never be taken as a git option.
    return Invoke-RtkProcess -FilePath 'git' -ArgumentList @('ls-remote', '--tags', '--', $RepoUrl) -TimeoutSec $TimeoutSec
}

<#
.SYNOPSIS
    Reads one page (100 tags) of rtk tag names from the GitHub API using
    GH_TOKEN. Returns the page as an array of Name/Sha objects. Mocked in tests.
#>
function Invoke-RtkTagApiPage {
    param([string]$Token, [int]$Page = 1)
    if ($Page -lt 1) { $Page = 1 }
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        # Windows PowerShell may default to TLS 1.0; GitHub needs TLS 1.2.
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        } catch { $null = $_ }
    }
    $headers = @{ Authorization = "Bearer $Token"; 'User-Agent' = 'rust-click-build'; Accept = 'application/vnd.github+json' }
    $uri = $script:RtkApiTagsUrl + '&page=' + $Page
    $resp = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 30 -ErrorAction Stop
    return @($resp | ForEach-Object { if ($null -ne $_) { [PSCustomObject]@{ Name = $_.name; Sha = $_.commit.sha } } })
}

<#
.SYNOPSIS
    Lists rtk tag names from the GitHub API using GH_TOKEN, following the
    pages (100 per page) until a short page or 20 pages. An error on a later
    page keeps what was read; an error on the first page is thrown.
    Mocked in tests.
#>
function Invoke-RtkTagApi {
    param([string]$Token)
    $all = New-Object System.Collections.Generic.List[object]
    for ($page = 1; $page -le 20; $page++) {
        $items = @()
        try {
            $items = @(Invoke-RtkTagApiPage -Token $Token -Page $page)
        } catch {
            if ($all.Count -eq 0) { throw }
            break
        }
        foreach ($it in $items) { if ($null -ne $it) { $all.Add($it) } }
        if ($items.Count -lt 100) { break }
    }
    return $all.ToArray()
}

<#
.SYNOPSIS
    Parses `git ls-remote --tags` output into tag name -> commit sha
    (peeled ^{} entries win, so annotated tags map to their commit).
#>
function ConvertFrom-LsRemoteTag {
    param([string]$Text)
    $map = @{}
    foreach ($l in ($Text -split "`r?`n")) {
        $m = [regex]::Match($l, '^([0-9a-fA-F]{7,64})\s+refs/tags/(.+?)(\^\{\})?$')
        if (-not $m.Success) { continue }
        $name = $m.Groups[2].Value
        if ($m.Groups[3].Success -or -not $map.ContainsKey($name)) { $map[$name] = $m.Groups[1].Value.ToLowerInvariant() }
    }
    return $map
}

<#
.SYNOPSIS
    Gets the latest rtk release tag. Tries git ls-remote first, then the
    GitHub API when GH_TOKEN is set. Result: Tag, Sha, Source, TagShas, Error.
    Never throws. Successful lookups are cached per normalized URL for the
    run (ssh and https spellings share one entry). Failures are not cached,
    so a later attempt in the same session can succeed after the network is back.
#>
function Get-RtkLatestRelease {
    param([string]$RepoUrl = $script:RtkDefaultRepoUrl, [string[]]$AlternateUrls = @())
    if ([string]::IsNullOrEmpty($RepoUrl)) { $RepoUrl = $script:RtkDefaultRepoUrl }
    if ($null -eq $script:RtkLatestCache) { $script:RtkLatestCache = @{} }
    # The https form is asked first (fast, uses the credential helper); the
    # cache is keyed on it so every spelling of the rtk URL shares one entry.
    $primary = ConvertTo-RtkHttpsUrl $RepoUrl
    if ($null -eq $primary) { $primary = $RepoUrl }
    if ($script:RtkLatestCache.ContainsKey($primary)) { return $script:RtkLatestCache[$primary] }

    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add($primary)
    foreach ($u in (@($RepoUrl) + @($AlternateUrls))) {
        if ([string]::IsNullOrEmpty($u)) { continue }
        $u = ([string]$u).Trim()
        if ($u.Length -eq 0 -or $candidates.Contains($u)) { continue }
        $candidates.Add($u)
    }

    $errors = New-Object System.Collections.Generic.List[string]
    $result = $null
    $urlIndex = 0
    foreach ($url in $candidates) {
        $urlIndex++
        # The URL itself is not logged (it may carry userinfo).
        $suffix = ''
        if ($urlIndex -gt 1) { $suffix = " (manifest URL #$($urlIndex - 1))" }
        try {
            $ls = Invoke-RtkLsRemote -RepoUrl $url -TimeoutSec 15
            if ($null -ne $ls -and $ls.ExitCode -eq 0) {
                $map = ConvertFrom-LsRemoteTag ([string]$ls.StdOut)
                $latest = Select-RtkLatestTag @($map.Keys)
                if ($null -ne $latest) {
                    $result = [PSCustomObject]@{ Tag = $latest; Sha = $map[$latest]; Source = 'git ls-remote'; TagShas = $map; Error = $null }
                } else { $errors.Add('git ls-remote returned no release tags' + $suffix) }
            } elseif ($null -eq $ls) {
                $errors.Add('git ls-remote returned nothing' + $suffix)
            } else {
                $msg = (([string]$ls.StdErr) -split "`r?`n" | Where-Object { $_ -ne '' } | Select-Object -First 2) -join ' '
                $errors.Add("git ls-remote failed (exit $($ls.ExitCode)): $msg" + $suffix)
            }
        } catch { $errors.Add("git ls-remote error: $($_.Exception.Message)" + $suffix) }
        if ($null -ne $result) { break }
    }

    if ($null -eq $result) {
        $token = $env:GH_TOKEN
        if (-not [string]::IsNullOrEmpty($token)) {
            try {
                $tags = Invoke-RtkTagApi -Token $token
                $map = @{}
                foreach ($t in $tags) {
                    if ($null -eq $t -or [string]::IsNullOrEmpty([string]$t.Name)) { continue }
                    $map[[string]$t.Name] = ([string]$t.Sha).ToLowerInvariant()
                }
                $latest = Select-RtkLatestTag @($map.Keys)
                if ($null -ne $latest) {
                    $result = [PSCustomObject]@{ Tag = $latest; Sha = $map[$latest]; Source = 'GitHub API (GH_TOKEN)'; TagShas = $map; Error = $null }
                } else { $errors.Add('GitHub API returned no release tags') }
            } catch { $errors.Add("GitHub API error: $($_.Exception.Message)") }
        } else {
            $errors.Add('GH_TOKEN is not set, so there is no API fallback')
        }
    }

    if ($null -eq $result) {
        return [PSCustomObject]@{ Tag = $null; Sha = $null; Source = $null; TagShas = @{}; Error = ($errors -join '; ') }
    }
    $script:RtkLatestCache[$primary] = $result
    return $result
}

# -------------------------------------------------------------------------
# Update + backup/restore
# -------------------------------------------------------------------------

<#
.SYNOPSIS
    Creates a new, empty backup folder "rtk-backup-<time>-<project>" under the
    backup root. The project name is made file-name safe, and a counter is
    appended when the folder already exists, so two projects with the same
    name in the same second never share (and overwrite) a backup.
#>
function New-RtkBackupDirectory {
    param([Parameter(Mandatory = $true)][string]$BackupRoot, [string]$ProjectName)
    $rootFull = Resolve-RcbFullPath $BackupRoot
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    $base = [System.IO.Path]::Combine($rootFull, ("rtk-backup-$stamp-" + (ConvertTo-RcbSafeFileName $ProjectName)))
    $dir = $base
    $n = 1
    while ([System.IO.Directory]::Exists((ConvertTo-RcbLongPath $dir)) -or [System.IO.File]::Exists((ConvertTo-RcbLongPath $dir))) {
        $n++
        $dir = "$base-$n"
    }
    [System.IO.Directory]::CreateDirectory((ConvertTo-RcbLongPath $dir)) | Out-Null
    return $dir
}

<#
.SYNOPSIS
    Copies Cargo.toml files (and the project's Cargo.lock) into a backup folder
    and returns a list of @{ Original; Backup; Existed } pairs. A file that
    does not exist yet is recorded with Existed = $false.
#>
function Backup-RtkFile {
    param([string[]]$Files, [string]$BackupDir)
    $pairs = New-Object System.Collections.Generic.List[PSCustomObject]
    $dirFull = Resolve-RcbFullPath $BackupDir
    [System.IO.Directory]::CreateDirectory((ConvertTo-RcbLongPath $dirFull)) | Out-Null
    $n = 0
    foreach ($f in ($Files | Where-Object { -not [string]::IsNullOrEmpty($_) } | Select-Object -Unique)) {
        $n++
        $src = Resolve-RcbFullPath $f
        $dest = [System.IO.Path]::Combine($dirFull, ("{0:D2}_{1}" -f $n, [System.IO.Path]::GetFileName($src)))
        # $dest stays un-prefixed in the returned pair; only the I/O calls get \\?\.
        $srcIo = ConvertTo-RcbLongPath $src
        $existed = [System.IO.File]::Exists($srcIo)
        if ($existed) { [System.IO.File]::Copy($srcIo, (ConvertTo-RcbLongPath $dest), $true) }
        $pairs.Add([PSCustomObject]@{ Original = $f; Backup = $dest; Existed = $existed })
    }
    return ,$pairs.ToArray()
}

<#
.SYNOPSIS
    Puts backed-up files back (and removes a Cargo.lock that did not exist
    before). Every pair is attempted; failures are returned as a list (callers
    should wrap the result with @()). This function does not throw the list.
#>
function Restore-RtkBackup {
    param([PSCustomObject[]]$Pairs)
    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($Pairs)) {
        if ($null -eq $p) { continue }
        foreach ($attempt in 1..3) {
            try {
                $orig = ConvertTo-RcbLongPath (Resolve-RcbFullPath ([string]$p.Original))
                if ($p.Existed) {
                    $backup = ConvertTo-RcbLongPath (Resolve-RcbFullPath ([string]$p.Backup))
                    [System.IO.File]::Copy($backup, $orig, $true)
                } elseif ([System.IO.File]::Exists($orig)) {
                    [System.IO.File]::Delete($orig)
                }
                break
            } catch {
                Start-Sleep -Milliseconds (50 * $attempt)
                if ($attempt -eq 3) {
                    $failures.Add("$($p.Original): $(Get-RcbErrorText $_.Exception)")
                }
            }
        }
    }
    # Emit the list items (or nothing when empty). Callers should wrap with @().
    # Do not use `return ,$array` on an empty array: that becomes a one-element wrapper.
    return $failures
}

<#
.SYNOPSIS
    Runs the forced rtk update check for one project or workspace.

.DESCRIPTION
    Returns an object the build pipeline uses:
      HasRtk, Checked, Changed, Status (short text for the summary table),
      Changes (list of Old/New/Manifest/Kind), Backup (pairs to restore),
      KeptLabel (what to say if the update breaks the build), Warnings.
    $Log is a scriptblock (message, role) for coloured output.
    Once the backup is taken, any failure (pin rewrite, cargo update exit
    code or exception) restores the backup before this function returns.
    Restore failures set Status to ROLLBACK INCOMPLETE and are not leaked
    into the returned object as extra pipeline output.
#>
function Invoke-RtkUpdateCheck {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [scriptblock]$Log = $null
    )
    $say = { param($m, $r) if ($null -ne $Log) { & $Log $m $r } else { Write-Host $m } }
    $ManifestPath = Resolve-RcbFullPath $ManifestPath
    $projDir = [System.IO.Path]::GetDirectoryName($ManifestPath)
    $res = [PSCustomObject]@{
        HasRtk = $false; Checked = $false; Changed = $false; Status = '-'
        Changes = @(); Backup = @(); KeptLabel = $null; Warnings = @(); Latest = $null
    }

    $deps = @()
    foreach ($m in @(Get-ProjectManifestSet -ManifestPath $ManifestPath)) { $deps += @(Get-RtkDependency -ManifestPath $m) }
    if ($deps.Count -eq 0) { $res.Status = 'no rtk dep'; return $res }
    $res.HasRtk = $true

    $depUrls = @($deps | ForEach-Object { [string]$_.GitUrl } | Where-Object { -not [string]::IsNullOrEmpty($_) } | Select-Object -Unique)
    $latest = Get-RtkLatestRelease -RepoUrl $deps[0].GitUrl -AlternateUrls $depUrls
    $res.Latest = $latest.Tag
    if ($null -eq $latest.Tag) {
        & $say '' 'warning'
        & $say '  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!' 'danger'
        & $say '  !!  WARNING: COULD NOT CHECK FOR rtk UPDATES                     !!' 'danger'
        & $say '  !!  (offline, or no git credentials for the private rtk repo)    !!' 'danger'
        & $say '  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!' 'danger'
        & $say "  Reason: $($latest.Error)" 'warning'
        & $say '  Fix: sign in with git (e.g. git ls-remote https://github.com/ubcool2ic/rtk) or set GH_TOKEN.' 'warning'
        & $say '  Continuing the build with the rtk versions already pinned.' 'warning'
        & $say '' 'warning'
        $res.Status = 'NOT CHECKED (offline/no credentials)'
        $res.Warnings = @($latest.Error)
        return $res
    }
    $res.Checked = $true
    & $say "  rtk: latest release is $($latest.Tag) (via $($latest.Source))" 'accent'

    $toBump = @(); $needsUpdate = $false; $kept = @(); $statusParts = @()
    foreach ($d in $deps) {
        $where = "$(Split-Path -Leaf (Split-Path -Parent $d.ManifestPath))/Cargo.toml [$($d.Section)] $($d.DepName)"
        switch ($d.PinKind) {
            'tag' {
                if ($null -eq (ConvertTo-RtkVersion $d.PinValue)) {
                    & $say "  rtk: $where pinned to non-release tag '$($d.PinValue)'; left alone (latest is $($latest.Tag))." 'warning'
                    $statusParts += "tag $($d.PinValue) (non-semver, kept)"
                } elseif ((Compare-RtkVersion $d.PinValue $latest.Tag) -lt 0) {
                    $toBump += $d
                } else {
                    & $say "  rtk: $where tag $($d.PinValue) is up to date." 'success'
                    $statusParts += "$($d.PinValue) (latest)"
                    $kept += $d.PinValue
                }
            }
            'rev' {
                $rev = ([string]$d.PinValue).ToLowerInvariant()
                $matchTag = $null
                if ($rev.Length -ge 7) {
                    foreach ($k in $latest.TagShas.Keys) {
                        if (([string]$latest.TagShas[$k]).StartsWith($rev, [System.StringComparison]::Ordinal)) { $matchTag = $k }
                    }
                }
                if ($null -ne $matchTag -and $matchTag -eq $latest.Tag) {
                    & $say "  rtk: $where rev $($d.PinValue) is the latest release $($latest.Tag)." 'success'
                    $statusParts += "rev = $($latest.Tag) (latest)"
                } else {
                    & $say "  rtk: $where is pinned to rev $($d.PinValue), not the latest release $($latest.Tag). A rev pin is deliberate, so it is NOT bumped; change it to tag = `"$($latest.Tag)`" to update." 'warning'
                    $statusParts += "rev $($d.PinValue) (behind $($latest.Tag), not bumped)"
                }
            }
            default {
                $needsUpdate = $true
                $label = if ($d.PinKind -eq 'branch') { "branch $($d.PinValue)" } else { 'unpinned (default branch)' }
                $statusParts += "${label}: cargo update -p rtk"
                $kept += $label
            }
        }
    }

    if ($toBump.Count -eq 0 -and -not $needsUpdate) {
        $res.Status = ($statusParts | Select-Object -Unique) -join '; '
        return $res
    }

    # Back up every manifest we might touch plus the lockfile, then update.
    # Nothing has been modified yet, so a failed backup just skips the update.
    $backupDir = $null
    try {
        $backupDir = New-RtkBackupDirectory -BackupRoot $BackupRoot -ProjectName (Split-Path -Leaf $projDir)
        $lockPath = Get-CargoLockPath -ManifestPath $ManifestPath
        $files = @($toBump | ForEach-Object { $_.ManifestPath }) + @($lockPath)
        $res.Backup = Backup-RtkFile -Files $files -BackupDir $backupDir
    } catch {
        $why = Get-RcbErrorText $_.Exception
        & $say "  rtk: could not back up Cargo.toml/Cargo.lock: $why. Not updating; building with the current pins." 'warning'
        $res.Backup = @()
        $res.Status = 'update skipped (backup failed); kept old pins'
        $res.Warnings = @($why)
        return $res
    }
    & $say "  rtk: backed up Cargo.toml/Cargo.lock to $backupDir" 'muted'

    function script:Complete-RtkRestore {
        param($Res, $Say, $BackupDir, [string]$FallbackStatus)
        $fails = @(Restore-RtkBackup -Pairs $Res.Backup)
        if ($fails.Count -gt 0) {
            & $Say "  rtk: ROLLBACK INCOMPLETE. Files are in $BackupDir. Failures:" 'danger'
            foreach ($f in $fails) { & $Say "    $f" 'danger' }
            $Res.Status = 'ROLLBACK INCOMPLETE'
            $Res.Warnings = @($fails)
            $Res.Changed = $false
            return $false
        }
        $Res.Status = $FallbackStatus
        return $true
    }

    $changes = @()
    $oldTags = @()
    try {
        foreach ($d in $toBump) {
            Set-RtkTagPin -ManifestPath $d.ManifestPath -LineIndex $d.LineIndex -OldTag $d.PinValue -NewTag $latest.Tag
            $changes += [PSCustomObject]@{ Old = $d.PinValue; New = $latest.Tag; Manifest = $d.ManifestPath; Kind = 'tag' }
            $oldTags += $d.PinValue
            & $say "  rtk: UPDATE $($d.PinValue) -> $($latest.Tag)  ($(Split-Path -Leaf (Split-Path -Parent $d.ManifestPath))/Cargo.toml [$($d.Section)])" 'rtkchange'
        }
    } catch {
        # Some manifests may already be rewritten: put all of them back.
        $why = Get-RcbErrorText $_.Exception
        & $say "  rtk: could not rewrite the pin: $why. Restoring backup." 'danger'
        if (Complete-RtkRestore -Res $res -Say $say -BackupDir $backupDir -FallbackStatus 'update failed (pin rewrite); kept old pin') {
            $res.Warnings = @($why)
        }
        return $res
    }

    $keptAll = @(@($toBump | ForEach-Object { $_.PinValue }) + @($kept) | Select-Object -Unique)
    $upd = $null
    $updError = $null
    try {
        $upd = Invoke-RtkCargoUpdate -ManifestPath $ManifestPath -WorkingDirectory $projDir
    } catch {
        $updError = $_.Exception.Message
    }
    if ($null -ne $updError -or $null -eq $upd -or $upd.ExitCode -ne 0) {
        $first = $updError
        if ($null -eq $first) {
            $allLines = @()
            if ($null -ne $upd) { $allLines = @($upd.Lines) }
            $first = ($allLines | Where-Object { $_ -match 'error' } | Select-Object -First 3) -join ' | '
            if ([string]::IsNullOrEmpty($first)) { $first = ($allLines | Where-Object { -not [string]::IsNullOrEmpty($_) } | Select-Object -Last 3) -join ' | ' }
        }
        & $say "  rtk: 'cargo update -p rtk' failed: $first" 'danger'
        & $say '  rtk: restoring the backup and continuing on the old pins.' 'warning'
        if (Complete-RtkRestore -Res $res -Say $say -BackupDir $backupDir -FallbackStatus "cargo update -p rtk failed; kept $($keptAll -join ', ')") {
            $res.Warnings = @($first)
        }
        return $res
    }
    & $say '  rtk: cargo update -p rtk done.' 'success'

    $res.Changed = $true
    $res.Changes = $changes
    $res.KeptLabel = ($keptAll -join ', ')
    $parts = @()
    foreach ($c in ($changes | Select-Object Old, New -Unique)) { $parts += "$($c.Old) -> $($c.New)" }
    $res.Status = ((@($parts) + @($statusParts)) | Select-Object -Unique) -join '; '
    return $res
}

<#
.SYNOPSIS
    Runs `cargo update -p rtk` for a manifest. Uses the git CLI for fetching so
    Cargo can reach the private repo with the user's credentials. Returns an
    object with ExitCode and Lines.
#>
function Invoke-RtkCargoUpdate {
    param([string]$ManifestPath, [string]$WorkingDirectory)
    $prev = $env:CARGO_NET_GIT_FETCH_WITH_CLI
    if ([string]::IsNullOrEmpty($prev)) { $env:CARGO_NET_GIT_FETCH_WITH_CLI = 'true' }
    try {
        $cargoArgs = @('update', '-p', 'rtk', '--manifest-path', $ManifestPath)
        if ($null -ne (Get-Command Invoke-ToolProcess -CommandType Function -ErrorAction SilentlyContinue)) {
            return Invoke-ToolProcess -FilePath 'cargo' -ArgumentList $cargoArgs -WorkingDirectory $WorkingDirectory
        }
        # Standalone use of this file (build.ps1 not loaded).
        $r = Invoke-RtkProcess -FilePath 'cargo' -ArgumentList $cargoArgs -TimeoutSec 900 -WorkingDirectory $WorkingDirectory
        $lines = @((([string]$r.StdErr) + "`n" + ([string]$r.StdOut)) -split "`r?`n" | Where-Object { $_ -ne '' })
        return [PSCustomObject]@{ ExitCode = $r.ExitCode; Lines = $lines }
    } finally {
        if ([string]::IsNullOrEmpty($prev)) { Remove-Item Env:\CARGO_NET_GIT_FETCH_WITH_CLI -ErrorAction SilentlyContinue }
    }
}
