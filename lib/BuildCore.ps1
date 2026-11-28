# Shared process, path and discovery helpers for rust-click-build.
# Works on Windows PowerShell 5.1 and PowerShell 7+. Dot-sourced by build.ps1
# and by lib/RtkUpdate.ps1 when loaded on its own.

$script:BuildCancelRequested = $false
$script:ResolvedCargoPath = $null
$script:RcbOnTick = $null
$script:RcbCancelBox = $null
$script:RcbDiscoverySkipped = New-Object System.Collections.Generic.List[string]
$script:RcbToolTimeoutSec = 7200
if ($env:RCB_TOOL_TIMEOUT_SEC -match '^-?\d+$') {
    $script:RcbToolTimeoutSec = [int]$env:RCB_TOOL_TIMEOUT_SEC
}
if ($null -eq $script:IsWindowsOS) {
    $script:IsWindowsOS = ($env:OS -eq 'Windows_NT')
    if ($PSVersionTable.PSVersion.Major -ge 6 -and $PSVersionTable.Platform -eq 'Unix') {
        $script:IsWindowsOS = $false
    }
}

function Test-RcbCancelRequested {
    if ($script:BuildCancelRequested) { return $true }
    if ($null -ne $script:RcbCancelBox -and [bool]$script:RcbCancelBox['Value']) {
        $script:BuildCancelRequested = $true
        return $true
    }
    return $false
}

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

# Name used by the PR #2 tests and helpers.
function ConvertTo-RcbWindowsArgument {
    param([AllowNull()][string]$Argument)
    return (ConvertTo-CommandLineArgument $Argument)
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

function Set-RcbProcessArgument {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.ProcessStartInfo]$StartInfo,
        [string[]]$ArgumentList
    )
    if ($null -ne $StartInfo.PSObject.Properties['ArgumentList']) {
        foreach ($a in @($ArgumentList)) { $StartInfo.ArgumentList.Add([string]$a) }
    } else {
        $StartInfo.Arguments = Join-RcbCommandLine $ArgumentList
    }
}

<#
.SYNOPSIS
    Kills a process and its children. Uses Kill($true) on .NET Core and
    taskkill /T /F on Windows PowerShell 5.1. Still tries to kill descendants
    after the parent has exited.
#>
function Get-RcbDirectChildIds {
    param([int]$ParentId)
    $ids = New-Object System.Collections.Generic.List[int]
    if ($ParentId -le 0) { return @() }
    if ($env:OS -eq 'Windows_NT') {
        try {
            $procs = Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$ParentId" -ErrorAction Stop
            foreach ($pr in @($procs)) { [void]$ids.Add([int]$pr.ProcessId) }
        } catch {
            try {
                $procs = Get-WmiObject Win32_Process -Filter "ParentProcessId=$ParentId" -ErrorAction SilentlyContinue
                foreach ($pr in @($procs)) { [void]$ids.Add([int]$pr.ProcessId) }
            } catch { $null = $_ }
        }
        return $ids.ToArray()
    }
    try {
        $taskRoot = "/proc/$ParentId/task"
        if ([System.IO.Directory]::Exists($taskRoot)) {
            foreach ($taskDir in [System.IO.Directory]::GetDirectories($taskRoot)) {
                $cf = [System.IO.Path]::Combine($taskDir, 'children')
                if ([System.IO.File]::Exists($cf)) {
                    $txt = [System.IO.File]::ReadAllText($cf)
                    foreach ($tok in ($txt -split '\s+')) {
                        $n = 0
                        if ([int]::TryParse($tok, [ref]$n) -and $n -gt 0) { [void]$ids.Add($n) }
                    }
                }
            }
        }
    } catch { $null = $_ }
    return $ids.ToArray()
}

function Add-RcbDescendantIds {
    param([int]$RootId, [System.Collections.Generic.HashSet[int]]$Into, [int]$Depth = 0)
    if ($null -eq $Into -or $RootId -le 0 -or $Depth -gt 32) { return }
    foreach ($cid in @(Get-RcbDirectChildIds -ParentId $RootId)) {
        if ($Into.Add($cid)) {
            Add-RcbDescendantIds -RootId $cid -Into $Into -Depth ($Depth + 1)
        }
    }
}

function Initialize-RcbLibc {
    if ($env:OS -eq 'Windows_NT') { return }
    if ('RcbLibc' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class RcbLibc {
    public const int PR_SET_CHILD_SUBREAPER = 36;
    public const int WNOHANG = 1;
    [DllImport("libc", SetLastError = true)]
    public static extern int prctl(int option, ulong arg2, ulong arg3, ulong arg4, ulong arg5);
    [DllImport("libc", SetLastError = true)]
    public static extern int waitpid(int pid, out int status, int options);
}
"@
}

function Initialize-RcbChildSubreaper {
    if ($env:OS -eq 'Windows_NT') { return }
    if ($script:RcbSubreaperReady -eq $true) { return }
    try {
        Initialize-RcbLibc
        $rc = [RcbLibc]::prctl(36, [uint64]1, [uint64]0, [uint64]0, [uint64]0)
        $script:RcbSubreaperReady = ($rc -eq 0)
    } catch {
        $script:RcbSubreaperReady = $false
    }
}

function Test-RcbPidZombie {
    param([int]$Id)
    if ($Id -le 0 -or $env:OS -eq 'Windows_NT') { return $false }
    $statPath = "/proc/$Id/stat"
    if (-not [System.IO.File]::Exists($statPath)) { return $false }
    try {
        $txt = [System.IO.File]::ReadAllText($statPath)
        return ($txt -match '\)\s+Z\s')
    } catch { return $false }
}

function Wait-RcbPid {
    param([int]$Id)
    if ($Id -le 0) { return }
    if ($env:OS -eq 'Windows_NT') {
        try {
            $pr = [System.Diagnostics.Process]::GetProcessById($Id)
            $null = $pr.WaitForExit(500)
        } catch { $null = $_ }
        return
    }
    try {
        Initialize-RcbLibc
        $status = 0
        if (Test-RcbPidZombie -Id $Id) {
            [void][RcbLibc]::waitpid($Id, [ref]$status, 0)
        } else {
            [void][RcbLibc]::waitpid($Id, [ref]$status, [RcbLibc]::WNOHANG)
        }
    } catch { $null = $_ }
}

function Add-RcbReparentedStragglers {
    param(
        [int]$SelfId,
        [System.Collections.Generic.HashSet[int]]$Before,
        [int]$StartedId,
        [System.Collections.Generic.HashSet[int]]$Into
    )
    if ($null -eq $Into -or $SelfId -le 0) { return }
    foreach ($cid in @(Get-RcbDirectChildIds -ParentId $SelfId)) {
        if ($cid -le 0 -or $cid -eq $StartedId) { continue }
        if ($null -ne $Before -and $Before.Contains($cid)) { continue }
        if ($Into.Add($cid)) { Add-RcbDescendantIds -RootId $cid -Into $Into }
    }
}

function Test-RcbPidAlive {
    param([int]$Id)
    if ($Id -le 0) { return $false }
    if ($env:OS -eq 'Windows_NT') {
        try {
            $pr = [System.Diagnostics.Process]::GetProcessById($Id)
            return -not $pr.HasExited
        } catch { return $false }
    }
    if (-not [System.IO.Directory]::Exists("/proc/$Id")) { return $false }
    # A reparented child we killed can sit as our zombie until waitpid.
    if (Test-RcbPidZombie -Id $Id) { return $false }
    return $true
}

function Sync-RcbKnownDescendants {
    param([System.Diagnostics.Process]$Process, [System.Collections.Generic.HashSet[int]]$Into)
    if ($null -eq $Into) { return }
    $id = 0
    try { if ($null -ne $Process) { $id = $Process.Id } } catch { $id = 0 }
    if ($id -gt 0) { Add-RcbDescendantIds -RootId $id -Into $Into }
}

function Stop-RcbProcessIds {
    param([int[]]$Ids)
    foreach ($id in @($Ids)) {
        if ($id -le 0) { continue }
        try {
            $pr = [System.Diagnostics.Process]::GetProcessById($id)
        } catch { $pr = $null }
        if ($null -ne $pr) {
            try {
                if (-not $pr.HasExited) {
                    if ($PSVersionTable.PSVersion.Major -ge 6) {
                        try { $pr.Kill($true) } catch { try { $pr.Kill() } catch { $null = $_ } }
                    } else {
                        try { $pr.Kill() } catch { $null = $_ }
                    }
                }
            } catch { $null = $_ }
            try { $pr.Dispose() } catch { $null = $_ }
        }
        # Reap so a subreaper-owned zombie does not linger in /proc.
        Wait-RcbPid -Id $id
    }
}

function Stop-ProcessTree {
    param(
        [System.Diagnostics.Process]$Process,
        [int[]]$KnownIds = @()
    )
    if ($null -eq $Process -and (@($KnownIds).Count -eq 0)) { return }
    $procId = 0
    $alreadyExited = $true
    if ($null -ne $Process) {
        try { $procId = $Process.Id } catch { $procId = 0 }
        try { $alreadyExited = $Process.HasExited } catch { $alreadyExited = $true }
    }
    $desc = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($k in @($KnownIds)) { if ($k -gt 0) { [void]$desc.Add($k) } }
    if ($procId -gt 0) { Add-RcbDescendantIds -RootId $procId -Into $desc }
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        if ($null -ne $Process -and -not $alreadyExited) {
            try { $Process.Kill($true) } catch {
                try { $Process.Kill() } catch { $null = $_ }
            }
        }
        # Kill leftover descendants even when the parent has already exited
        # (on Unix they are reparented and Kill($true) on a dead parent is a no-op).
        Stop-RcbProcessIds -Ids @($desc)
        return
    }
    $isWin = ($env:OS -eq 'Windows_NT')
    if ($isWin -and $procId -gt 0) {
        try {
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
            if (-not $alreadyExited) {
                try { $Process.Kill() } catch { $null = $_ }
            }
        }
    } elseif (-not $alreadyExited) {
        try { $Process.Kill() } catch { $null = $_ }
    }
    Stop-RcbProcessIds -Ids @($desc)
}

function Stop-RcbProcessTree {
    param([System.Diagnostics.Process]$Process, [int[]]$KnownIds = @())
    Stop-ProcessTree -Process $Process -KnownIds $KnownIds
}

function Test-RcbRustupSignerSubject {
    param([string]$Subject)
    # Exact CN or O of the Rust Foundation, not a substring match on "Rust".
    $allowed = @('Rust Foundation', 'The Rust Foundation')
    foreach ($part in @(([string]$Subject) -split ',')) {
        $p = $part.Trim()
        if ($p -match '^(CN|O)\s*=\s*(.+)$') {
            $name = $Matches[2].Trim().Trim('"')
            if ($allowed -contains $name) { return $true }
        }
    }
    return $false
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
    Prepends $CARGO_HOME/bin (or ~/.cargo/bin) to PATH when cargo is not yet
    visible. Uses [IO.Path]::Combine so a missing drive does not throw.
    Returns $true if cargo can be resolved afterwards.
#>
function Add-CargoBinToPath {
    $sep = [string][System.IO.Path]::PathSeparator
    $trimChars = [char[]]@('\', '/')
    $dirs = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrEmpty($env:CARGO_HOME)) {
        try { $dirs.Add([System.IO.Path]::Combine($env:CARGO_HOME, 'bin')) } catch { $null = $_ }
    }
    $userHome = $null
    if ($script:IsWindowsOS) { $userHome = $env:USERPROFILE } else { $userHome = $env:HOME }
    if ([string]::IsNullOrEmpty($userHome)) { $userHome = $HOME }
    if (-not [string]::IsNullOrEmpty($userHome)) {
        try { $dirs.Add([System.IO.Path]::Combine($userHome, '.cargo', 'bin')) } catch { $null = $_ }
    }

    foreach ($dir in $dirs) {
        if ($null -ne (Get-Command cargo -ErrorAction SilentlyContinue)) { break }
        $exists = $false
        try { $exists = [bool](Test-Path -LiteralPath $dir -PathType Container) } catch { $exists = $false }
        if (-not $exists) { continue }
        $want = $dir.TrimEnd($trimChars)
        $comparison = [System.StringComparison]::Ordinal
        if ($script:IsWindowsOS) { $comparison = [System.StringComparison]::OrdinalIgnoreCase }
        $present = $false
        foreach ($p in ([string]$env:PATH).Split([char[]]@([System.IO.Path]::PathSeparator))) {
            if ([string]::IsNullOrEmpty($p)) { continue }
            $have = $p.Trim().TrimEnd($trimChars)
            if ([string]::Equals($have, $want, $comparison)) { $present = $true; break }
        }
        if (-not $present) {
            if ([string]::IsNullOrEmpty($env:PATH)) {
                $env:PATH = $dir
            } else {
                $env:PATH = $dir + $sep + $env:PATH
            }
        }
    }
    return ($null -ne (Get-Command cargo -ErrorAction SilentlyContinue))
}

<#
.SYNOPSIS
    Runs a process, streaming both stdout and stderr, with stdin closed,
    UTF-8 decoding, optional timeout, and a cancel flag. Returns ExitCode,
    Lines (in arrival order), StdOut, StdErr, TimedOut and Cancelled.
    GIT_ALLOW_PROTOCOL is not set here; rtk git calls add it themselves.
#>
function Invoke-ToolProcess {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$WorkingDirectory = '',
        [scriptblock]$OnOutputLine = $null,
        [scriptblock]$OnTick = $null,
        [int]$TimeoutSec = 0,
        [hashtable]$ExtraEnvironment = $null,
        [string[]]$RemoveEnvironment = @()
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
        if ($null -ne $ExtraEnvironment) {
            foreach ($k in @($ExtraEnvironment.Keys)) {
                $psi.EnvironmentVariables[$k] = [string]$ExtraEnvironment[$k]
            }
        }
        foreach ($k in @($RemoveEnvironment)) {
            if (-not [string]::IsNullOrWhiteSpace($k)) {
                try { $null = $psi.EnvironmentVariables.Remove($k) } catch { $null = $_ }
            }
        }
    } catch { $null = $_ }

    $process = $null
    $lines = New-Object System.Collections.Generic.List[string]
    $stdoutLines = New-Object System.Collections.Generic.List[string]
    $stderrLines = New-Object System.Collections.Generic.List[string]
    $timedOut = $false
    $cancelled = $false
    $callbackError = $null
    try {
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        Initialize-RcbChildSubreaper
        $selfPid = [int]$PID
        $childrenBefore = New-Object 'System.Collections.Generic.HashSet[int]'
        try {
            foreach ($cid in @(Get-RcbDirectChildIds -ParentId $selfPid)) {
                if ($cid -gt 0) { [void]$childrenBefore.Add($cid) }
            }
        } catch { $null = $_ }
        try {
            $null = $process.Start()
        } catch {
            $msg = "could not start '${FilePath}': $($_.Exception.Message)"
            return [PSCustomObject]@{
                ExitCode = -1; Lines = @(); StdOut = ''; StdErr = $msg
                TimedOut = $false; Cancelled = $false
            }
        }
        $knownDescendants = New-Object 'System.Collections.Generic.HashSet[int]'
        # Snapshot immediately, before anything that might reap the child, and
        # tight-spin briefly so a parent that forks and exits at once is still
        # observed while /proc/<pid>/children is populated.
        try {
            $spinEnd = [datetime]::UtcNow.AddMilliseconds(50)
            do {
                Sync-RcbKnownDescendants -Process $process -Into $knownDescendants
                Add-RcbReparentedStragglers -SelfId $selfPid -Before $childrenBefore -StartedId $process.Id -Into $knownDescendants
                if (-not (Test-RcbPidAlive -Id $process.Id)) { break }
            } while ([datetime]::UtcNow -lt $spinEnd)
        } catch { $null = $_ }

        try { $process.StandardInput.Close() } catch { $null = $_ }

        $outTask = $process.StandardOutput.ReadLineAsync()
        $errTask = $process.StandardError.ReadLineAsync()
        $deadline = $null
        if ($TimeoutSec -gt 0) { $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec) }
        $exitedAt = $null

        while ($true) {
            if (Test-RcbCancelRequested) {
                $cancelled = $true
                Stop-ProcessTree -Process $process -KnownIds @($knownDescendants)
                break
            }
            # Snapshot before HasExited: HasExited may reap, after which
            # Linux has already reparented children to init.
            try { Sync-RcbKnownDescendants -Process $process -Into $knownDescendants } catch { $null = $_ }
            $hasExited = $false
            try { $hasExited = $process.HasExited } catch { $hasExited = $true }
            if ($hasExited -and $null -eq $exitedAt) {
                # Re-snapshot after the parent exits and collect reparented stragglers.
                try { Sync-RcbKnownDescendants -Process $process -Into $knownDescendants } catch { $null = $_ }
                try { Add-RcbReparentedStragglers -SelfId $selfPid -Before $childrenBefore -StartedId $process.Id -Into $knownDescendants } catch { $null = $_ }
                $exitedAt = [datetime]::UtcNow
            }
            # A successful (or already-finished) exit must not be reported as TimedOut,
            # even if a grandchild is still holding the pipes when the deadline hits.
            if ($null -ne $deadline -and [datetime]::UtcNow -gt $deadline -and -not $hasExited) {
                $timedOut = $true
                Stop-ProcessTree -Process $process -KnownIds @($knownDescendants)
                break
            }
            if ($hasExited -and (([datetime]::UtcNow - $exitedAt).TotalMilliseconds -ge 400)) {
                # Parent is gone: drain briefly, then stop waiting for EOF.
                break
            }
            $wait = New-Object System.Collections.Generic.List[System.Threading.Tasks.Task]
            if ($null -ne $outTask) { $wait.Add($outTask) }
            if ($null -ne $errTask) { $wait.Add($errTask) }
            if ($wait.Count -eq 0) { break }
            $idx = [System.Threading.Tasks.Task]::WaitAny($wait.ToArray(), 100)
            if ($idx -lt 0) {
                $tick = $OnTick
                if ($null -eq $tick) { $tick = $script:RcbOnTick }
                if ($null -ne $tick) { try { & $tick } catch { $null = $_ } }
                continue
            }
            $done = $wait[$idx]
            if ($done -eq $outTask) {
                if ($outTask.IsFaulted) { $outTask = $null; continue }
                $line = $outTask.Result
                if ($null -eq $line) { $outTask = $null }
                else {
                    $stdoutLines.Add($line)
                    $lines.Add($line)
                    if ($null -ne $OnOutputLine) {
                        try { & $OnOutputLine $line } catch {
                            $callbackError = $_
                            $cancelled = $true
                            Stop-ProcessTree -Process $process -KnownIds @($knownDescendants)
                            break
                        }
                    }
                    $outTask = $process.StandardOutput.ReadLineAsync()
                }
            } elseif ($done -eq $errTask) {
                if ($errTask.IsFaulted) { $errTask = $null; continue }
                $line = $errTask.Result
                if ($null -eq $line) { $errTask = $null }
                else {
                    $stderrLines.Add($line)
                    $lines.Add($line)
                    if ($null -ne $OnOutputLine) {
                        try { & $OnOutputLine $line } catch {
                            $callbackError = $_
                            $cancelled = $true
                            Stop-ProcessTree -Process $process -KnownIds @($knownDescendants)
                            break
                        }
                    }
                    $errTask = $process.StandardError.ReadLineAsync()
                }
            }
        }

        # Re-snapshot after the parent exits and kill reparented stragglers.
        try { Sync-RcbKnownDescendants -Process $process -Into $knownDescendants } catch { $null = $_ }
        try { Add-RcbReparentedStragglers -SelfId $selfPid -Before $childrenBefore -StartedId $process.Id -Into $knownDescendants } catch { $null = $_ }
        if (-not $process.HasExited) { $null = $process.WaitForExit(2000) }
        try { Sync-RcbKnownDescendants -Process $process -Into $knownDescendants } catch { $null = $_ }
        if (-not $process.HasExited) { Stop-ProcessTree -Process $process -KnownIds @($knownDescendants); $null = $process.WaitForExit(2000) }
        try { Sync-RcbKnownDescendants -Process $process -Into $knownDescendants } catch { $null = $_ }
        try { Stop-ProcessTree -Process $process -KnownIds @($knownDescendants) } catch { $null = $_ }
        $exit = -1
        try { if ($process.HasExited) { $exit = $process.ExitCode } } catch { $exit = -1 }
        if ($timedOut -or $cancelled) { $exit = -1 }
        if ($null -ne $callbackError) { throw $callbackError }
        return [PSCustomObject]@{
            ExitCode  = $exit
            Lines     = $lines.ToArray()
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
    The real path of a directory, following symlinks when the runtime can.
    Used as a visited-set key so discovery can follow OneDrive / linked
    folders without looping.
#>
function Get-RcbRealDirectoryPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    try {
        $info = New-Object System.IO.DirectoryInfo $Path
        if ($info.Exists) {
            try {
                if ($null -ne $info.PSObject.Methods['ResolveLinkTarget']) {
                    $resolved = $info.ResolveLinkTarget($true)
                    if ($null -ne $resolved -and -not [string]::IsNullOrEmpty($resolved.FullName)) {
                        return $resolved.FullName
                    }
                }
            } catch { $null = $_ }
            try {
                if (-not [string]::IsNullOrEmpty($info.LinkTarget)) {
                    $t = [string]$info.LinkTarget
                    if (-not [System.IO.Path]::IsPathRooted($t)) {
                        $parent = $info.Parent
                        $baseDir = if ($null -ne $parent) { $parent.FullName } else { [System.IO.Path]::GetDirectoryName($info.FullName) }
                        $t = [System.IO.Path]::GetFullPath((Join-Path $baseDir $t))
                    }
                    return $t
                }
            } catch { $null = $_ }
            return $info.FullName
        }
    } catch { $null = $_ }
    try { return [System.IO.Path]::GetFullPath($Path) } catch { return $Path }
}

<#
.SYNOPSIS
    Iterative Cargo.toml discovery. Prunes target, .git, node_modules and
    _built by directory name before descending, unless that folder itself
    contains a Cargo.toml (a member crate named "target"). Follows reparse
    points and symlinks with a visited set of resolved paths so OneDrive
    and linked project dirs are found, and loops cannot hang the walk.
#>
function Get-CargoTomlFiles {
    param(
        [Parameter(Mandatory = $true)][string]$RootDirectory,
        [string[]]$SkipNames = @('target', '.git', 'node_modules', '_built')
    )
    $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $script:RcbDiscoverySkipped = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($RootDirectory) -or -not (Test-Path -LiteralPath $RootDirectory -PathType Container)) {
        return $files.ToArray()
    }
    $skip = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $SkipNames) { [void]$skip.Add($n) }
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $rootInfo = New-Object System.IO.DirectoryInfo ($RootDirectory)
    $stack.Push($rootInfo)
    [void]$visited.Add((Get-RcbRealDirectoryPath $rootInfo.FullName))
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            foreach ($f in $dir.EnumerateFiles('Cargo.toml')) { $files.Add($f) }
            foreach ($sub in $dir.EnumerateDirectories()) {
                if ($skip.Contains($sub.Name)) {
                    $isTargetCrate = $false
                    if ([string]::Equals($sub.Name, 'target', [System.StringComparison]::OrdinalIgnoreCase)) {
                        $crateToml = [System.IO.Path]::Combine($sub.FullName, 'Cargo.toml')
                        try { $isTargetCrate = [System.IO.File]::Exists($crateToml) } catch { $isTargetCrate = $false }
                    }
                    if (-not $isTargetCrate) { continue }
                }
                $real = Get-RcbRealDirectoryPath $sub.FullName
                if (-not $visited.Add($real)) {
                    $script:RcbDiscoverySkipped.Add("loop: $($sub.FullName) -> $real")
                    continue
                }
                $stack.Push($sub)
            }
        } catch {
            $script:RcbDiscoverySkipped.Add("$($dir.FullName): $($_.Exception.Message)")
        }
    }
    return $files.ToArray()
}

<#
.SYNOPSIS
    Destination folder name under _built, based on the path relative to the
    scan root so two projects with the same leaf name do not collide.
    Path separators become "--" so a_b and a/b stay distinct.
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
        return ($rel -replace '[\\/]', '--')
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
    target_directory from captured "cargo metadata" output lines. Cargo warnings
    (stderr) may precede the JSON, so the last line starting with "{" is tried
    first, then the whole text. Returns $null when not found.
#>
function Get-RcbMetadataTargetDir {
    param([string[]]$Lines)
    $obj = Get-RcbMetadataObject -Lines $Lines
    if ($null -eq $obj) { return $null }
    $prop = $null
    try { $prop = $obj.PSObject.Properties['target_directory'] } catch { $prop = $null }
    if ($null -ne $prop -and -not [string]::IsNullOrEmpty([string]$prop.Value)) {
        return [string]$prop.Value
    }
    return $null
}

function Get-RcbMetadataObject {
    param([string]$Text = '', [string[]]$Lines = @())
    $all = @($Lines | Where-Object { $null -ne $_ })
    if ($all.Count -eq 0 -and -not [string]::IsNullOrEmpty($Text)) {
        $all = @($Text -split "`r?`n")
    }
    $candidates = New-Object System.Collections.Generic.List[string]
    $jsonLine = $null
    foreach ($l in $all) {
        if ($l -match '^\s*\{') { $jsonLine = $l }
    }
    if ($null -ne $jsonLine) { $candidates.Add($jsonLine) }
    if ($all.Count -gt 0) { $candidates.Add(($all -join "`n")) }
    if (-not [string]::IsNullOrEmpty($Text) -and $Text -ne ($all -join "`n")) { $candidates.Add($Text) }
    foreach ($chunk in $candidates) {
        $obj = $null
        try { $obj = $chunk | ConvertFrom-Json } catch { $obj = $null }
        if ($null -eq $obj) {
            $start = $chunk.IndexOf('{')
            $end = $chunk.LastIndexOf('}')
            if ($start -ge 0 -and $end -gt $start) {
                try { $obj = $chunk.Substring($start, $end - $start + 1) | ConvertFrom-Json } catch { $obj = $null }
            }
        }
        if ($null -ne $obj) { return $obj }
    }
    return $null
}

<#
.SYNOPSIS
    Binary target names (kind "bin") from a cargo metadata object.
#>
function Get-RcbMetadataBinNames {
    param($Metadata)
    $names = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Metadata) { return @() }
    try {
        foreach ($pkg in @($Metadata.packages)) {
            foreach ($t in @($pkg.targets)) {
                $kinds = @($t.kind)
                if ($kinds -contains 'bin') {
                    $n = [string]$t.name
                    if (-not [string]::IsNullOrEmpty($n) -and -not $names.Contains($n)) { $names.Add($n) }
                }
            }
        }
    } catch { $null = $_ }
    return $names.ToArray()
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
