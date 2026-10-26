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

    Works on Windows PowerShell 5.1 and PowerShell 7+. Dot-sourced by build.ps1.
#>


# Default rtk repository. A dependency counts as rtk when its git URL points
# at github.com/ubcool2ic/rtk (with or without .git, https or ssh).
$script:RtkDefaultRepoUrl = 'https://github.com/ubcool2ic/rtk'
$script:RtkGitUrlPattern  = '(?i)github\.com[:/]+ubcool2ic/rtk(\.git)?/?$'
$script:RtkApiTagsUrl     = 'https://api.github.com/repos/ubcool2ic/rtk/tags?per_page=100'
$script:RtkLatestCache    = @{}

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
    $pre = $null
    if ($m.Groups[4].Success) { $pre = $m.Groups[4].Value }
    return [PSCustomObject]@{
        Tag        = $Tag.Trim()
        Version    = New-Object System.Version([int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value)
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
    return ($Url.Trim() -match $script:RtkGitUrlPattern)
}

<#
.SYNOPSIS
    Reads a quoted string value for a key from an inline table body or a
    "key = value" line. Returns $null when the key is absent.
#>
function Get-TomlKeyValue {
    param([string]$Text, [string]$Key)
    $m = [regex]::Match($Text, "(?:^|[\s,{])$Key\s*=\s*(?:`"([^`"]*)`"|'([^']*)')")
    if (-not $m.Success) { return $null }
    if ($m.Groups[1].Success) { return $m.Groups[1].Value }
    return $m.Groups[2].Value
}

<#
.SYNOPSIS
    Strips a trailing TOML comment that is not inside a quoted string.
#>
function Remove-TomlComment {
    param([string]$Line)
    $inDq = $false; $inSq = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $ch = $Line[$i]
        if ($ch -eq '"' -and -not $inSq) { $inDq = -not $inDq }
        elseif ($ch -eq "'" -and -not $inDq) { $inSq = -not $inSq }
        elseif ($ch -eq '#' -and -not $inDq -and -not $inSq) { return $Line.Substring(0, $i) }
    }
    return $Line
}

<#
.SYNOPSIS
    Finds every rtk git dependency in one Cargo.toml.

.DESCRIPTION
    Handles inline tables (rtk = { git = "...", tag = "v0.8.2" }), renamed deps
    (gui = { package = "rtk", git = "..." }), and table form
    ([dependencies.rtk] / [target.'cfg(windows)'.dependencies.rtk] /
    [workspace.dependencies.rtk]). Each result has PinKind tag, rev, branch or
    none, the pin value, and the 0-based line index holding the pin (or the
    dep line when unpinned).
#>
function Get-RtkDependency {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    $results = New-Object System.Collections.Generic.List[PSCustomObject]
    if (-not (Test-Path -LiteralPath $ManifestPath)) { return $results.ToArray() }
    $lines = [System.IO.File]::ReadAllLines($ManifestPath)

    $section = ''
    $tableDep = $null   # state while inside [....dependencies.<name>]

    $flushTable = {
        if ($null -ne $tableDep -and (Test-RtkGitUrl $tableDep.Git)) {
            $kind = 'none'; $val = $null; $idx = $tableDep.HeaderLine
            foreach ($k in @('tag', 'rev', 'branch')) {
                if ($tableDep.Keys.ContainsKey($k)) { $kind = $k; $val = $tableDep.Keys[$k].Value; $idx = $tableDep.Keys[$k].Line; break }
            }
            $results.Add([PSCustomObject]@{
                ManifestPath = $ManifestPath
                Section      = $tableDep.Section
                DepName      = $tableDep.Name
                GitUrl       = $tableDep.Git
                PinKind      = $kind
                PinValue     = $val
                LineIndex    = $idx
                Form         = 'table'
            })
        }
    }

    for ($i = 0; $i -lt $lines.Length; $i++) {
        $raw = $lines[$i]
        $line = (Remove-TomlComment $raw).Trim()
        if ($line -eq '') { continue }

        $h = [regex]::Match($line, '^\[\s*([^\[\]]+?)\s*\]$')
        if ($h.Success) {
            & $flushTable
            $tableDep = $null
            $section = $h.Groups[1].Value
            $dm = [regex]::Match($section, '^(?:(.*)\.)?((?:dev-|build-)?dependencies)\.("?)([A-Za-z0-9_\-]+)\3$')
            if ($dm.Success) {
                $tableDep = @{ Name = $dm.Groups[4].Value; Section = $section; HeaderLine = $i; Git = $null; Keys = @{} }
            }
            continue
        }
        if ($line -match '^\[\[') { & $flushTable; $tableDep = $null; $section = $line; continue }

        if ($null -ne $tableDep) {
            $kv = [regex]::Match($line, '^([A-Za-z0-9_\-]+)\s*=\s*(?:"([^"]*)"|''([^'']*)'')')
            if ($kv.Success) {
                $v = if ($kv.Groups[2].Success) { $kv.Groups[2].Value } else { $kv.Groups[3].Value }
                if ($kv.Groups[1].Value -eq 'git') { $tableDep.Git = $v }
                else { $tableDep.Keys[$kv.Groups[1].Value] = @{ Value = $v; Line = $i } }
            }
            continue
        }

        if ($section -notmatch '(^|\.)((dev-|build-)?dependencies)$') { continue }
        $im = [regex]::Match($line, '^("?)([A-Za-z0-9_\-]+)\1\s*=\s*\{(.*)\}$')
        if (-not $im.Success) { continue }
        $body = $im.Groups[3].Value
        $git = Get-TomlKeyValue $body 'git'
        if (-not (Test-RtkGitUrl $git)) { continue }
        $kind = 'none'; $val = $null
        foreach ($k in @('tag', 'rev', 'branch')) {
            $kvv = Get-TomlKeyValue $body $k
            if ($null -ne $kvv) { $kind = $k; $val = $kvv; break }
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
    }
    & $flushTable
    return $results.ToArray()
}

<#
.SYNOPSIS
    Lists the Cargo.toml files that belong to one project: just its own
    manifest, or every member manifest under a [workspace] root.
#>
function Get-ProjectManifestSet {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)
    $content = [System.IO.File]::ReadAllText($ManifestPath)
    if ($content -notmatch '(?m)^\s*\[workspace\]') { return @($ManifestPath) }
    $root = Split-Path -Parent $ManifestPath
    $list = New-Object System.Collections.Generic.List[string]
    $list.Add($ManifestPath)
    $all = Get-ChildItem -LiteralPath $root -Filter 'Cargo.toml' -Recurse -File -Force -ErrorAction SilentlyContinue
    foreach ($f in $all) {
        if ($f.FullName -eq $ManifestPath) { continue }
        if ($f.FullName -match '[\\/](target|\.git|node_modules|_built)[\\/]') { continue }
        $list.Add($f.FullName)
    }
    return $list.ToArray()
}

<#
.SYNOPSIS
    Rewrites the tag of one rtk dependency in place, keeping line endings and
    writing UTF-8 without a BOM (Cargo rejects nothing, but diffs stay clean).
#>
function Set-RtkTagPin {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][int]$LineIndex,
        [Parameter(Mandatory = $true)][string]$OldTag,
        [Parameter(Mandatory = $true)][string]$NewTag
    )
    $text = [System.IO.File]::ReadAllText($ManifestPath)
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [regex]::Split($text, "\r?\n")
    $pattern = '(tag\s*=\s*)(["''])' + [regex]::Escape($OldTag) + '\2'
    $newLine = [regex]::Replace($lines[$LineIndex], $pattern, ('${1}${2}' + $NewTag + '${2}'), 1)
    if ($newLine -eq $lines[$LineIndex]) { throw "Could not find tag '$OldTag' on line $($LineIndex + 1) of $ManifestPath" }
    $lines[$LineIndex] = $newLine
    [System.IO.File]::WriteAllText($ManifestPath, ($lines -join $nl), (New-Object System.Text.UTF8Encoding($false)))
}

# -------------------------------------------------------------------------
# Latest tag lookup (git ls-remote with the user's credentials, then API)
# -------------------------------------------------------------------------

<#
.SYNOPSIS
    Runs a process with a timeout, without prompting. Returns ExitCode,
    StdOut, StdErr and TimedOut.
#>
function Invoke-RtkProcess {
    param([string]$FilePath, [string[]]$ArgumentList, [int]$TimeoutSec = 45)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($ArgumentList | ForEach-Object { if ($_ -match '\s|"') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    # Never block on a username/password prompt: no credentials = warn and go on.
    $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $psi.EnvironmentVariables['GCM_INTERACTIVE'] = 'never'
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $p.Start() | Out-Null
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { $null = $_ }
        return [PSCustomObject]@{ ExitCode = -1; StdOut = ''; StdErr = "timed out after ${TimeoutSec}s"; TimedOut = $true }
    }
    return [PSCustomObject]@{ ExitCode = $p.ExitCode; StdOut = $outTask.Result; StdErr = $errTask.Result; TimedOut = $false }
}

<#
.SYNOPSIS
    `git ls-remote --tags <url>` using the user's own git credential helper.
    Returns the raw ls-remote result object. Mocked in tests.
#>
function Invoke-RtkLsRemote {
    param([string]$RepoUrl)
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]@{ ExitCode = 127; StdOut = ''; StdErr = 'git is not installed or not on PATH'; TimedOut = $false }
    }
    return Invoke-RtkProcess -FilePath 'git' -ArgumentList @('ls-remote', '--tags', $RepoUrl)
}

<#
.SYNOPSIS
    Lists rtk tag names from the GitHub API using GH_TOKEN. Mocked in tests.
#>
function Invoke-RtkTagApi {
    param([string]$Token)
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
    Cached per URL for the run.
#>
function Get-RtkLatestRelease {
    param([string]$RepoUrl = $script:RtkDefaultRepoUrl)
    if ($script:RtkLatestCache.ContainsKey($RepoUrl)) { return $script:RtkLatestCache[$RepoUrl] }

    $errors = New-Object System.Collections.Generic.List[string]
    $result = $null
    try {
        $ls = Invoke-RtkLsRemote -RepoUrl $RepoUrl
        if ($ls.ExitCode -eq 0) {
            $map = ConvertFrom-LsRemoteTag $ls.StdOut
            $latest = Select-RtkLatestTag @($map.Keys)
            if ($null -ne $latest) {
                $result = [PSCustomObject]@{ Tag = $latest; Sha = $map[$latest]; Source = 'git ls-remote'; TagShas = $map; Error = $null }
            } else { $errors.Add('git ls-remote returned no release tags') }
        } else {
            $msg = ($ls.StdErr -split "`r?`n" | Where-Object { $_ -ne '' } | Select-Object -First 2) -join ' '
            $errors.Add("git ls-remote failed (exit $($ls.ExitCode)): $msg")
        }
    } catch { $errors.Add("git ls-remote error: $($_.Exception.Message)") }

    if ($null -eq $result) {
        $token = $env:GH_TOKEN
        if (-not [string]::IsNullOrEmpty($token)) {
            try {
                $tags = Invoke-RtkTagApi -Token $token
                $map = @{}
                foreach ($t in $tags) { $map[$t.Name] = ([string]$t.Sha).ToLowerInvariant() }
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
    Copies Cargo.toml files (and the project's Cargo.lock) into a backup folder
    and returns a list of @{ Original; Backup } pairs.
#>
function Backup-RtkFile {
    param([string[]]$Files, [string]$BackupDir)
    $pairs = New-Object System.Collections.Generic.List[PSCustomObject]
    [System.IO.Directory]::CreateDirectory($BackupDir) | Out-Null
    $n = 0
    foreach ($f in ($Files | Select-Object -Unique)) {
        $n++
        $dest = Join-Path $BackupDir ("{0:D2}_{1}" -f $n, (Split-Path -Leaf $f))
        $existed = Test-Path -LiteralPath $f
        if ($existed) { Copy-Item -LiteralPath $f -Destination $dest -Force }
        $pairs.Add([PSCustomObject]@{ Original = $f; Backup = $dest; Existed = $existed })
    }
    return ,$pairs.ToArray()
}

<#
.SYNOPSIS
    Puts backed-up files back (and removes a Cargo.lock that did not exist before).
#>
function Restore-RtkBackup {
    param([PSCustomObject[]]$Pairs)
    foreach ($p in $Pairs) {
        if ($p.Existed) { Copy-Item -LiteralPath $p.Backup -Destination $p.Original -Force }
        elseif (Test-Path -LiteralPath $p.Original) { Remove-Item -LiteralPath $p.Original -Force }
    }
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
#>
function Invoke-RtkUpdateCheck {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [scriptblock]$Log = $null
    )
    $say = { param($m, $r) if ($null -ne $Log) { & $Log $m $r } else { Write-Host $m } }
    $projDir = Split-Path -Parent $ManifestPath
    $res = [PSCustomObject]@{
        HasRtk = $false; Checked = $false; Changed = $false; Status = '-'
        Changes = @(); Backup = @(); KeptLabel = $null; Warnings = @(); Latest = $null
    }

    $deps = @()
    foreach ($m in (Get-ProjectManifestSet -ManifestPath $ManifestPath)) { $deps += @(Get-RtkDependency -ManifestPath $m) }
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
                foreach ($k in $latest.TagShas.Keys) { if ($latest.TagShas[$k].StartsWith($rev) -and $rev.Length -ge 7) { $matchTag = $k } }
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
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $backupDir = Join-Path $BackupRoot ("rtk-backup-$stamp-" + (Split-Path -Leaf $projDir))
    $files = @($toBump | ForEach-Object { $_.ManifestPath }) + @(Join-Path $projDir 'Cargo.lock')
    $res.Backup = Backup-RtkFile -Files $files -BackupDir $backupDir
    & $say "  rtk: backed up Cargo.toml/Cargo.lock to $backupDir" 'muted'

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
        & $say "  rtk: could not rewrite the pin: $($_.Exception.Message). Restoring backup." 'danger'
        Restore-RtkBackup -Pairs $res.Backup
        $res.Status = 'update failed (pin rewrite); kept old pin'
        return $res
    }

    $upd = Invoke-RtkCargoUpdate -ManifestPath $ManifestPath -WorkingDirectory $projDir
    if ($upd.ExitCode -ne 0) {
        $first = ($upd.Lines | Where-Object { $_ -match 'error' } | Select-Object -First 3) -join ' | '
        & $say "  rtk: 'cargo update -p rtk' failed: $first" 'danger'
        & $say '  rtk: restoring the backup and continuing on the old pins.' 'warning'
        Restore-RtkBackup -Pairs $res.Backup
        $res.Status = "cargo update -p rtk failed; kept $((@($oldTags) + @($kept) | Select-Object -Unique) -join ', ')"
        $res.Warnings = @($first)
        return $res
    }
    & $say '  rtk: cargo update -p rtk done.' 'success'

    $res.Changed = $true
    $res.Changes = $changes
    $keptAll = @($oldTags) + @($kept) | Select-Object -Unique
    $res.KeptLabel = ($keptAll -join ', ')
    $parts = @()
    foreach ($c in ($changes | Select-Object Old, New -Unique)) { $parts += "$($c.Old) -> $($c.New)" }
    $res.Status = ((@($parts) + @($statusParts)) | Select-Object -Unique) -join '; '
    return $res
}

<#
.SYNOPSIS
    Runs `cargo update -p rtk` for a manifest. Uses the git CLI for fetching so
    Cargo can reach the private repo with the user's credentials.
#>
function Invoke-RtkCargoUpdate {
    param([string]$ManifestPath, [string]$WorkingDirectory)
    $prev = $env:CARGO_NET_GIT_FETCH_WITH_CLI
    if ([string]::IsNullOrEmpty($prev)) { $env:CARGO_NET_GIT_FETCH_WITH_CLI = 'true' }
    try {
        return Invoke-ToolProcess -FilePath 'cargo' -ArgumentList @('update', '-p', 'rtk', '--manifest-path', $ManifestPath) -WorkingDirectory $WorkingDirectory
    } finally {
        if ([string]::IsNullOrEmpty($prev)) { Remove-Item Env:\CARGO_NET_GIT_FETCH_WITH_CLI -ErrorAction SilentlyContinue }
    }
}
