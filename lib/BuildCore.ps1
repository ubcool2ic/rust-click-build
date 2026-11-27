# Shared process, path and discovery helpers for rust-click-build.
# Works on Windows PowerShell 5.1 and PowerShell 7+. Dot-sourced by build.ps1
# and by lib/RtkUpdate.ps1 when loaded on its own.

$script:BuildCancelRequested = $false
$script:ResolvedCargoPath = $null

<#
.SYNOPSIS
    Quotes one argument for the MSVC / CommandLineToArgvW command line rules.
    Empty arguments become "". Backslashes before a quote or the closing quote
    are doubled.
#>
function ConvertTo-CommandLineArgument {
    param([AllowNull()][string]$Argument)
    if ($null -eq $Argument) { $Argument = '' }
    $needsQuotes = ($Argument.Length -eq 0) -or ($Argument -match '[\s"]')
    if (-not $needsQuotes) { return $Argument }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $Argument.ToCharArray()) {
        if ($ch -eq [char]'\') { $backslashes++; continue }
        if ($ch -eq [char]'"') {
            if ($backslashes -gt 0) { [void]$sb.Append('\', $backslashes * 2) }
            [void]$sb.Append('\"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) { [void]$sb.Append('\', $backslashes); $backslashes = 0 }
        [void]$sb.Append($ch)
    }
    if ($backslashes -gt 0) { [void]$sb.Append('\', $backslashes * 2) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

<#
.SYNOPSIS
    Joins arguments into one command line that Start-Process -ArgumentList (string) can use.
#>
function Join-RcbCommandLine {
    param([string[]]$ArgumentList)
    if ($null -eq $ArgumentList -or $ArgumentList.Count -eq 0) { return '' }
    return (($ArgumentList | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' ')
}

<#
.SYNOPSIS
    Kills a process and its children. Uses Kill($true) on .NET Core and
    taskkill /T /F on Windows PowerShell 5.1.
#>
function Stop-ProcessTree {
    param([System.Diagnostics.Process]$Process)
    if ($null -eq $Process) { return }
    try { if ($Process.HasExited) { return } } catch { return }
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        try { $Process.Kill($true) } catch {
            try { $Process.Kill() } catch { $null = $_ }
        }
        return
    }
    $isWin = ($env:OS -eq 'Windows_NT')
    if ($isWin) {
        try {
            $procId = $Process.Id
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'taskkill.exe'
            $psi.Arguments = "/T /F /PID $procId"
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $tk = [System.Diagnostics.Process]::Start($psi)
            if ($null -ne $tk) {
                $null = $tk.WaitForExit(5000)
                $tk.Dispose()
            }
        } catch {
            try { $Process.Kill() } catch { $null = $_ }
        }
    } else {
        try { $Process.Kill() } catch { $null = $_ }
    }
}

<#
.SYNOPSIS
    Resolves a command name to a full path via Get-Command, falling back to the name.
#>
function Resolve-CommandPath {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ([System.IO.Path]::IsPathRooted($Name)) { return $Name }
    $cmd = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $cmd) { return $Name }
    if (-not [string]::IsNullOrEmpty($cmd.Source)) { return [string]$cmd.Source }
    if (-not [string]::IsNullOrEmpty($cmd.Path)) { return [string]$cmd.Path }
    return $Name
}

<#
.SYNOPSIS
    Prepends ~/.cargo/bin to PATH when cargo is not yet visible. Returns $true
    if cargo can be resolved afterwards.
#>
function Add-CargoBinToPath {
    $userHome = $env:USERPROFILE
    if ([string]::IsNullOrEmpty($userHome)) { $userHome = $env:HOME }
    if (-not [string]::IsNullOrEmpty($userHome)) {
        $cargoBin = Join-Path $userHome (Join-Path '.cargo' 'bin')
        if ((Test-Path -LiteralPath $cargoBin) -and ($null -eq (Get-Command cargo -ErrorAction SilentlyContinue))) {
            $pathParts = $env:PATH -split [System.IO.Path]::PathSeparator
            if (-not ($pathParts -contains $cargoBin)) {
                $env:PATH = $cargoBin + [System.IO.Path]::PathSeparator + $env:PATH
            }
        }
    }
    return [bool](Get-Command cargo -ErrorAction SilentlyContinue)
}

<#
.SYNOPSIS
    Runs a process, streaming both stdout and stderr, with stdin closed,
    UTF-8 decoding, optional timeout, and a cancel flag. Returns ExitCode,
    Lines (stderr then stdout), StdOut, StdErr, TimedOut and Cancelled.
#>
function Invoke-ToolProcess {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$WorkingDirectory = '',
        [scriptblock]$OnOutputLine = $null,
        [scriptblock]$OnTick = $null,
        [int]$TimeoutSec = 0
    )

    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        return [PSCustomObject]@{ ExitCode = -1; Lines = @(); StdOut = ''; StdErr = 'missing executable path'; TimedOut = $false; Cancelled = $false }
    }

    $resolved = Resolve-CommandPath -Name $FilePath
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $resolved
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    if (-not [string]::IsNullOrEmpty($WorkingDirectory)) { $psi.WorkingDirectory = $WorkingDirectory }

    $useArgList = $false
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        try { $null = $psi.ArgumentList; $useArgList = $true } catch { $useArgList = $false }
    }
    if ($useArgList) {
        foreach ($a in @($ArgumentList)) { [void]$psi.ArgumentList.Add([string]$a) }
    } else {
        $psi.Arguments = Join-RcbCommandLine -ArgumentList @($ArgumentList)
    }

    try {
        $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
        $psi.EnvironmentVariables['GCM_INTERACTIVE'] = 'never'
        $psi.EnvironmentVariables['GIT_ALLOW_PROTOCOL'] = 'https:ssh:git'
    } catch { $null = $_ }

    $process = $null
    $stdoutLines = New-Object System.Collections.Generic.List[string]
    $stderrLines = New-Object System.Collections.Generic.List[string]
    $timedOut = $false
    $cancelled = $false
    try {
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        try {
            $null = $process.Start()
        } catch {
            return [PSCustomObject]@{
                ExitCode = -1; Lines = @(); StdOut = ''; StdErr = $_.Exception.Message
                TimedOut = $false; Cancelled = $false
            }
        }
        try { $process.StandardInput.Close() } catch { $null = $_ }

        $outTask = $process.StandardOutput.ReadLineAsync()
        $errTask = $process.StandardError.ReadLineAsync()
        $deadline = $null
        if ($TimeoutSec -gt 0) { $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec) }

        while ($true) {
            if ($script:BuildCancelRequested) {
                $cancelled = $true
                Stop-ProcessTree -Process $process
                break
            }
            if ($null -ne $deadline -and [datetime]::UtcNow -gt $deadline) {
                $timedOut = $true
                Stop-ProcessTree -Process $process
                break
            }
            $wait = New-Object System.Collections.Generic.List[System.Threading.Tasks.Task]
            if ($null -ne $outTask) { $wait.Add($outTask) }
            if ($null -ne $errTask) { $wait.Add($errTask) }
            if ($wait.Count -eq 0) { break }
            $idx = [System.Threading.Tasks.Task]::WaitAny($wait.ToArray(), 100)
            if ($idx -lt 0) {
                if ($null -ne $OnTick) { try { & $OnTick } catch { $null = $_ } }
                continue
            }
            $done = $wait[$idx]
            if ($done -eq $outTask) {
                if ($outTask.IsFaulted) { $outTask = $null; continue }
                $line = $outTask.Result
                if ($null -eq $line) { $outTask = $null }
                else {
                    $stdoutLines.Add($line)
                    if ($null -ne $OnOutputLine) { try { & $OnOutputLine $line } catch { $null = $_ } }
                    $outTask = $process.StandardOutput.ReadLineAsync()
                }
            } elseif ($done -eq $errTask) {
                if ($errTask.IsFaulted) { $errTask = $null; continue }
                $line = $errTask.Result
                if ($null -eq $line) { $errTask = $null }
                else {
                    $stderrLines.Add($line)
                    if ($null -ne $OnOutputLine) { try { & $OnOutputLine $line } catch { $null = $_ } }
                    $errTask = $process.StandardError.ReadLineAsync()
                }
            }
        }

        if (-not $process.HasExited) { $null = $process.WaitForExit(2000) }
        if (-not $process.HasExited) { Stop-ProcessTree -Process $process; $null = $process.WaitForExit(2000) }
        $exit = -1
        try { if ($process.HasExited) { $exit = $process.ExitCode } } catch { $exit = -1 }
        if ($timedOut -or $cancelled) { $exit = -1 }
        $all = New-Object System.Collections.Generic.List[string]
        foreach ($l in $stderrLines) { $all.Add($l) }
        foreach ($l in $stdoutLines) { $all.Add($l) }
        return [PSCustomObject]@{
            ExitCode  = $exit
            Lines     = $all.ToArray()
            StdOut    = ($stdoutLines -join "`n")
            StdErr    = ($stderrLines -join "`n")
            TimedOut  = $timedOut
            Cancelled = $cancelled
        }
    } finally {
        if ($null -ne $process) { try { $process.Dispose() } catch { $null = $_ } }
    }
}

<#
.SYNOPSIS
    Iterative Cargo.toml discovery. Prunes target, .git, node_modules and
    _built by directory name before descending, and skips reparse points
    (junctions/symlinks) so a self-referencing link cannot loop.
#>
function Get-CargoTomlFiles {
    param(
        [Parameter(Mandatory = $true)][string]$RootDirectory,
        [string[]]$SkipNames = @('target', '.git', 'node_modules', '_built')
    )
    $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    if ([string]::IsNullOrWhiteSpace($RootDirectory) -or -not (Test-Path -LiteralPath $RootDirectory -PathType Container)) {
        return $files.ToArray()
    }
    $skip = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $SkipNames) { [void]$skip.Add($n) }
    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $stack.Push((New-Object System.IO.DirectoryInfo ($RootDirectory)))
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            foreach ($f in $dir.EnumerateFiles('Cargo.toml')) { $files.Add($f) }
            foreach ($sub in $dir.EnumerateDirectories()) {
                if ($skip.Contains($sub.Name)) { continue }
                if (($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $stack.Push($sub)
            }
        } catch { $null = $_ }
    }
    return $files.ToArray()
}

<#
.SYNOPSIS
    Destination folder name under _built, based on the path relative to the
    scan root so two projects with the same leaf name do not collide.
#>
function Get-RelativeBuiltName {
    param([string]$Root, [string]$ProjectDir)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $projFull = [System.IO.Path]::GetFullPath($ProjectDir)
    $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    if ($projFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return (Split-Path -Leaf $projFull)
    }
    if ($projFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $projFull.Substring($rootFull.Length).TrimStart('\', '/')
        if ([string]::IsNullOrEmpty($rel)) { return (Split-Path -Leaf $projFull) }
        return ($rel -replace '[\\/]', '_')
    }
    return (Split-Path -Leaf $ProjectDir)
}

<#
.SYNOPSIS
    Cargo.lock path for a manifest: the file next to a [workspace] root, or
    the nearest workspace ancestor, otherwise the package directory.
#>
function Get-CargoLockPath {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)
    $dir = Split-Path -Parent $ManifestPath
    if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) {
        $content = [System.IO.File]::ReadAllText($ManifestPath)
        if ($content -match '(?m)^\s*\[workspace\]') {
            return (Join-Path $dir 'Cargo.lock')
        }
    }
    $cur = $dir
    while ($true) {
        $parent = Split-Path -Parent $cur
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $cur) { break }
        $parentToml = Join-Path $parent 'Cargo.toml'
        if (Test-Path -LiteralPath $parentToml -PathType Leaf) {
            $pc = [System.IO.File]::ReadAllText($parentToml)
            if ($pc -match '(?m)^\s*\[workspace\]') {
                return (Join-Path $parent 'Cargo.lock')
            }
        }
        $cur = $parent
    }
    return (Join-Path $dir 'Cargo.lock')
}

<#
.SYNOPSIS
    Opts into TLS 1.2 on Windows PowerShell 5.1 (older defaults can negotiate TLS 1.0).
#>
function Initialize-RcbTls12 {
    try {
        $tls12 = [Net.SecurityProtocolType]::Tls12
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor $tls12
    } catch { $null = $_ }
}

<#
.SYNOPSIS
    True when the current thread is STA.
#>
function Test-RcbStaThread {
    return ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA)
}
