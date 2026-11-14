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

<#
.SYNOPSIS
    Quotes one argument for a Windows command line (CommandLineToArgvW rules):
    backslashes are doubled only before a quote or before the closing quote.
#>
function ConvertTo-RcbWindowsArgument {
    param([string]$Argument)
    if ([string]::IsNullOrEmpty($Argument)) { return '""' }
    if ($Argument.IndexOfAny($script:RcbArgSpecialChars) -lt 0) { return $Argument }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $Argument.ToCharArray()) {
        if ($ch -eq [char]92) { $bs++; continue }
        if ($ch -eq [char]34) {
            [void]$sb.Append('\' * ($bs * 2 + 1))
            [void]$sb.Append('"')
            $bs = 0
            continue
        }
        if ($bs -gt 0) { [void]$sb.Append('\' * $bs); $bs = 0 }
        [void]$sb.Append($ch)
    }
    if ($bs -gt 0) { [void]$sb.Append('\' * ($bs * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

<#
.SYNOPSIS
    Joins arguments into one correctly quoted Windows command line.
#>
function Join-RcbCommandLine {
    param([string[]]$ArgumentList)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($a in $ArgumentList) { $parts.Add((ConvertTo-RcbWindowsArgument ([string]$a))) }
    return ($parts.ToArray() -join ' ')
}

<#
.SYNOPSIS
    Puts arguments on a ProcessStartInfo: ArgumentList when the runtime has it
    (PowerShell 7 / .NET Core), otherwise a quoted Arguments string (5.1).
#>
function Set-RcbProcessArgument {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.ProcessStartInfo]$StartInfo,
        [string[]]$ArgumentList
    )
    if ($null -ne $StartInfo.PSObject.Properties['ArgumentList']) {
        foreach ($a in $ArgumentList) { $StartInfo.ArgumentList.Add([string]$a) }
    } else {
        $StartInfo.Arguments = Join-RcbCommandLine $ArgumentList
    }
}

<#
.SYNOPSIS
    Kills a process (and its children where the runtime or taskkill allows).
    Never throws.
#>
function Stop-RcbProcessTree {
    param($Process)
    if ($null -eq $Process) { return }
    try {
        if ($Process.HasExited) { return }
        if ($null -ne $Process.GetType().GetMethod('Kill', [type[]]@([bool]))) {
            $Process.Kill($true)
            return
        }
    } catch { $null = $_ }
    if ($env:OS -eq 'Windows_NT') {
        try { $null = & taskkill.exe /T /F /PID $Process.Id 2>$null } catch { $null = $_ }
    }
    try { if (-not $Process.HasExited) { $Process.Kill() } } catch { $null = $_ }
}

<#
.SYNOPSIS
    Makes a string safe to use as one file or folder name on Windows and
    Linux (unicode letters are kept; reserved characters become "_").
#>
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
    Parses the top-level "key = string" pairs of an inline table body (or a
    single "key = value" line). Strings, arrays and nested tables are skipped
    correctly; only string values are returned. Keys are case-sensitive.
#>
function ConvertFrom-RtkInlineTable {
    param([string]$Body)
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
    $full = Resolve-RcbFullPath $ManifestPath
    if (-not [System.IO.File]::Exists($full)) { return $results.ToArray() }
    $text = [System.IO.File]::ReadAllText($full)
    # Fast path: no "rtk" anywhere means no rtk dependency.
    if ($text.IndexOf('rtk', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { return $results.ToArray() }
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $lines = $text.Split([char]10)

    $section = ''
    $inDeps = $false
    $tableDep = $null   # state while inside [....dependencies.<name>]
    $dotted = $null     # name -> state for dotted keys inside a dependencies section

    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        if ($line.IndexOf('#') -ge 0) { $line = Remove-TomlComment $line }
        $line = $line.Trim()
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
                if ($k -ceq 'git') { $tableDep.Git = $v }
                elseif ($k -ceq 'tag' -or $k -ceq 'rev' -or $k -ceq 'branch') { $tableDep.Pins[$k] = @{ Value = $v; Line = $i } }
            }
            continue
        }

        if (-not $inDeps) { continue }

        if ($line.IndexOf('{') -ge 0) {
            if ($line.IndexOf('git', [System.StringComparison]::Ordinal) -lt 0) { continue }
            $im = $script:RtkReInline.Match($line)
            if (-not $im.Success) { continue }
            $map = ConvertFrom-RtkInlineTable $im.Groups[3].Value
            if (-not $map.ContainsKey('git')) { continue }
            $git = $map['git']
            if (-not (Test-RtkGitUrl $git)) { continue }
            $kind = 'none'; $val = $null
            foreach ($k in @('tag', 'rev', 'branch')) {
                if ($map.ContainsKey($k)) { $kind = $k; $val = $map[$k]; break }
            }
            $results.Add([PSCustomObject]@{
                ManifestPath = $ManifestPath
                Section      = $section
                DepName      = $im.Groups[2].Value
                GitUrl       = $git
                PinKind      = $kind
                PinValue     = $val
                LineIndex    = $i
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
        if ($null -eq $dotted) { $dotted = New-Object System.Collections.Specialized.OrderedDictionary }
        if (-not $dotted.Contains($name)) {
            $dotted[$name] = @{ Name = $name; Section = $section; HeaderLine = $i; Git = $null; Pins = @{} }
        }
        $state = $dotted[$name]
        if ($k -ceq 'git') { $state.Git = $v }
        elseif ($k -ceq 'tag' -or $k -ceq 'rev' -or $k -ceq 'branch') { $state.Pins[$k] = @{ Value = $v; Line = $i } }
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
    try { $text = [System.IO.File]::ReadAllText((Resolve-RcbFullPath $ManifestPath)) } catch { return $false }
    if ([string]::IsNullOrEmpty($text)) { return $false }
    if ($text.IndexOf('workspace', [System.StringComparison]::Ordinal) -lt 0) { return $false }
    return $script:RtkReWorkspace.IsMatch($text)
}

<#
.SYNOPSIS
    Lists Cargo.toml full paths under a folder without ever descending into
    target, .git, node_modules or _built (case-insensitive).

.DESCRIPTION
    Uses an explicit stack (no recursion), skips reparse points (junctions and
    symlinks, so loops cannot hang the walk) and folders that cannot be read.
    With -ExcludeWorkspaceMembers a folder whose Cargo.toml declares a
    workspace is returned but not descended into. Parents come before their
    children; siblings are in ordinal (case-insensitive) order.
#>
function Get-RcbCargoManifest {
    param(
        [Parameter(Mandatory = $true)][string]$RootDirectory,
        [switch]$ExcludeWorkspaceMembers
    )
    $found = New-Object System.Collections.Generic.List[string]
    $root = Resolve-RcbFullPath $RootDirectory
    if ([string]::IsNullOrEmpty($root) -or -not [System.IO.Directory]::Exists($root)) { return $found.ToArray() }
    $reparse = [System.IO.FileAttributes]::ReparsePoint
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($root)
    $subs = New-Object System.Collections.Generic.List[string]
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $manifest = [System.IO.Path]::Combine($dir, 'Cargo.toml')
        $isFile = $false
        try { $isFile = [System.IO.File]::Exists($manifest) } catch { $isFile = $false }
        if ($isFile) {
            $found.Add($manifest)
            if ($ExcludeWorkspaceMembers -and (Test-RcbWorkspaceManifest $manifest)) { continue }
        }
        $subs.Clear()
        try {
            foreach ($d in (New-Object System.IO.DirectoryInfo($dir)).EnumerateDirectories()) {
                if ($script:RcbPrunedDirs.Contains($d.Name)) { continue }
                if (($d.Attributes -band $reparse) -ne 0) { continue }
                $subs.Add($d.FullName)
            }
        } catch {
            # Access denied, path too long or folder removed while walking: skip it.
            $null = $_
        }
        if ($subs.Count -gt 1) { $subs.Sort([System.StringComparer]::OrdinalIgnoreCase) }
        for ($j = $subs.Count - 1; $j -ge 0; $j--) { $stack.Push($subs[$j]) }
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
    if (-not [System.IO.File]::Exists($full)) { return @($ManifestPath) }
    if (-not (Test-RcbWorkspaceManifest $full)) { return @($ManifestPath) }
    $root = [System.IO.Path]::GetDirectoryName($full)
    $list = New-Object System.Collections.Generic.List[string]
    $list.Add($ManifestPath)
    foreach ($f in @(Get-RcbCargoManifest -RootDirectory $root)) {
        if ([string]::Equals([System.IO.Path]::GetDirectoryName($f), $root, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
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
    $bytes = [System.IO.File]::ReadAllBytes($full)
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
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    Set-RcbProcessArgument -StartInfo $psi -ArgumentList $ArgumentList
    if (-not [string]::IsNullOrEmpty($WorkingDirectory)) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    # Never block on a username/password prompt: no credentials = warn and go on.
    $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $psi.EnvironmentVariables['GCM_INTERACTIVE'] = 'never'
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try {
        try {
            [void]$p.Start()
        } catch {
            return [PSCustomObject]@{ ExitCode = -1; StdOut = ''; StdErr = "could not start '$FilePath': $($_.Exception.Message)"; TimedOut = $false }
        }
        # Closed stdin: anything that tries to read a prompt gets EOF at once.
        try { $p.StandardInput.Close() } catch { $null = $_ }
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        $tasks = [System.Threading.Tasks.Task[]]@($outTask, $errTask)
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            Stop-RcbProcessTree $p
            try { [void][System.Threading.Tasks.Task]::WaitAll($tasks, 2000) } catch { $null = $_ }
            return [PSCustomObject]@{ ExitCode = -1; StdOut = ''; StdErr = "timed out after ${TimeoutSec}s"; TimedOut = $true }
        }
        # The process is gone; give the readers a bounded time in case a child kept the pipes open.
        try { [void][System.Threading.Tasks.Task]::WaitAll($tasks, 5000) } catch { $null = $_ }
        $out = ''; $err = ''
        try { if ($outTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) { $out = [string]$outTask.Result } } catch { $null = $_ }
        try { if ($errTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) { $err = [string]$errTask.Result } } catch { $null = $_ }
        return [PSCustomObject]@{ ExitCode = $p.ExitCode; StdOut = $out; StdErr = $err; TimedOut = $false }
    } finally {
        $p.Dispose()
    }
}

<#
.SYNOPSIS
    `git ls-remote --tags -- <url>` using the user's own git credential helper.
    Returns the raw ls-remote result object. Mocked in tests.
#>
function Invoke-RtkLsRemote {
    param([string]$RepoUrl)
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]@{ ExitCode = 127; StdOut = ''; StdErr = 'git is not installed or not on PATH'; TimedOut = $false }
    }
    # "--" so a URL read from a Cargo.toml can never be taken as a git option.
    return Invoke-RtkProcess -FilePath 'git' -ArgumentList @('ls-remote', '--tags', '--', $RepoUrl)
}

<#
.SYNOPSIS
    Lists rtk tag names from the GitHub API using GH_TOKEN. Mocked in tests.
#>
function Invoke-RtkTagApi {
    param([string]$Token)
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        # Windows PowerShell may default to TLS 1.0; GitHub needs TLS 1.2.
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        } catch { $null = $_ }
    }
    $headers = @{ Authorization = "Bearer $Token"; 'User-Agent' = 'rust-click-build'; Accept = 'application/vnd.github+json' }
    $resp = Invoke-RestMethod -Uri $script:RtkApiTagsUrl -Headers $headers -TimeoutSec 30 -ErrorAction Stop
    return @($resp | ForEach-Object { [PSCustomObject]@{ Name = $_.name; Sha = $_.commit.sha } })
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
    Never throws. Cached per URL for the run, failures included, so a dead
    network is asked once and not once per project.
#>
function Get-RtkLatestRelease {
    param([string]$RepoUrl = $script:RtkDefaultRepoUrl)
    if ([string]::IsNullOrEmpty($RepoUrl)) { $RepoUrl = $script:RtkDefaultRepoUrl }
    if ($null -eq $script:RtkLatestCache) { $script:RtkLatestCache = @{} }
    if ($script:RtkLatestCache.ContainsKey($RepoUrl)) { return $script:RtkLatestCache[$RepoUrl] }

    $errors = New-Object System.Collections.Generic.List[string]
    $result = $null
    try {
        $ls = Invoke-RtkLsRemote -RepoUrl $RepoUrl
        if ($null -ne $ls -and $ls.ExitCode -eq 0) {
            $map = ConvertFrom-LsRemoteTag ([string]$ls.StdOut)
            $latest = Select-RtkLatestTag @($map.Keys)
            if ($null -ne $latest) {
                $result = [PSCustomObject]@{ Tag = $latest; Sha = $map[$latest]; Source = 'git ls-remote'; TagShas = $map; Error = $null }
            } else { $errors.Add('git ls-remote returned no release tags') }
        } elseif ($null -eq $ls) {
            $errors.Add('git ls-remote returned nothing')
        } else {
            $msg = (([string]$ls.StdErr) -split "`r?`n" | Where-Object { $_ -ne '' } | Select-Object -First 2) -join ' '
            $errors.Add("git ls-remote failed (exit $($ls.ExitCode)): $msg")
        }
    } catch { $errors.Add("git ls-remote error: $($_.Exception.Message)") }

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
        $result = [PSCustomObject]@{ Tag = $null; Sha = $null; Source = $null; TagShas = @{}; Error = ($errors -join '; ') }
    }
    $script:RtkLatestCache[$RepoUrl] = $result
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
    while ([System.IO.Directory]::Exists($dir) -or [System.IO.File]::Exists($dir)) {
        $n++
        $dir = "$base-$n"
    }
    [System.IO.Directory]::CreateDirectory($dir) | Out-Null
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
    [System.IO.Directory]::CreateDirectory($dirFull) | Out-Null
    $n = 0
    foreach ($f in ($Files | Where-Object { -not [string]::IsNullOrEmpty($_) } | Select-Object -Unique)) {
        $n++
        $src = Resolve-RcbFullPath $f
        $dest = [System.IO.Path]::Combine($dirFull, ("{0:D2}_{1}" -f $n, [System.IO.Path]::GetFileName($src)))
        $existed = [System.IO.File]::Exists($src)
        if ($existed) { [System.IO.File]::Copy($src, $dest, $true) }
        $pairs.Add([PSCustomObject]@{ Original = $f; Backup = $dest; Existed = $existed })
    }
    return ,$pairs.ToArray()
}

<#
.SYNOPSIS
    Puts backed-up files back (and removes a Cargo.lock that did not exist
    before). Every pair is attempted; failures are collected and thrown
    together at the end.
#>
function Restore-RtkBackup {
    param([PSCustomObject[]]$Pairs)
    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($p in $Pairs) {
        if ($null -eq $p) { continue }
        try {
            $orig = Resolve-RcbFullPath ([string]$p.Original)
            if ($p.Existed) {
                [System.IO.File]::Copy([string]$p.Backup, $orig, $true)
            } elseif ([System.IO.File]::Exists($orig)) {
                [System.IO.File]::Delete($orig)
            }
        } catch {
            $failures.Add("$($p.Original): $($_.Exception.Message)")
        }
    }
    if ($failures.Count -gt 0) { throw ("Could not restore: " + ($failures.ToArray() -join '; ')) }
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

    $latest = Get-RtkLatestRelease -RepoUrl $deps[0].GitUrl
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
        $files = @($toBump | ForEach-Object { $_.ManifestPath }) + @([System.IO.Path]::Combine($projDir, 'Cargo.lock'))
        $res.Backup = Backup-RtkFile -Files $files -BackupDir $backupDir
    } catch {
        & $say "  rtk: could not back up Cargo.toml/Cargo.lock: $($_.Exception.Message). Not updating; building with the current pins." 'warning'
        $res.Backup = @()
        $res.Status = 'update skipped (backup failed); kept old pins'
        $res.Warnings = @($_.Exception.Message)
        return $res
    }
    & $say "  rtk: backed up Cargo.toml/Cargo.lock to $backupDir" 'muted'

    $rollback = {
        try {
            Restore-RtkBackup -Pairs $res.Backup
        } catch {
            & $say "  rtk: RESTORE FAILED: $($_.Exception.Message). The original files are in $backupDir" 'danger'
        }
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
        & $say "  rtk: could not rewrite the pin: $($_.Exception.Message). Restoring backup." 'danger'
        & $rollback
        $res.Status = 'update failed (pin rewrite); kept old pin'
        $res.Warnings = @($_.Exception.Message)
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
        & $rollback
        $res.Status = "cargo update -p rtk failed; kept $($keptAll -join ', ')"
        $res.Warnings = @($first)
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
