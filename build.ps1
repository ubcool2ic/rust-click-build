<#
.SYNOPSIS
    Automated Rust project builder wrapping Cargo for Windows PowerShell 5.1 and pwsh 7+.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Path,

    [Parameter()]
    [ValidateSet('release', 'debug')]
    [string]$BuildProfile = 'release',

    [Parameter()]
    [switch]$Test,

    [Parameter()]
    [switch]$Gui,

    [Parameter()]
    [switch]$NoPause,

    [Parameter()]
    [switch]$NoInstall,

    [Parameter()]
    [switch]$NoOpen,

    # Skip the forced rtk update check (it is on by default).
    [Parameter()]
    [switch]$NoRtkUpdate,

    # GUI theme. System follows the Windows light/dark/high-contrast setting.
    [Parameter()]
    [ValidateSet('System', 'Light', 'Dark', 'HighContrast')]
    [string]$Theme = 'System',

    # Machine-readable progress on stdout ("@@RCB {json}" lines). Implies -NoPause.
    [Parameter()]
    [switch]$JsonProgress,

    # Open the legacy WinForms window instead of the rtk GUI.
    [Parameter()]
    [switch]$ClassicGui
)

$ErrorActionPreference = 'Stop'

# Bound script parameters, kept for the STA relaunch (see Invoke-InSTA).
$script:RcbBoundParameters = @{}
foreach ($rcbKey in @($PSBoundParameters.Keys)) { $script:RcbBoundParameters[$rcbKey] = $PSBoundParameters[$rcbKey] }

# rtk design tokens (console + GUI colours) and the forced rtk update check.
. (Join-Path $PSScriptRoot (Join-Path 'lib' 'RtkTheme.ps1'))
. (Join-Path $PSScriptRoot (Join-Path 'lib' 'RtkUpdate.ps1'))
. (Join-Path $PSScriptRoot (Join-Path 'lib' 'RcbProgress.ps1'))
if ($JsonProgress) {
    $script:RcbJsonProgress = $true
    $script:RtkPlainConsole = $true
    $NoPause = $true
}

# Determine Windows platform reliably across PS 5.1 and pwsh Core
$script:IsWindowsOS = ($env:OS -eq 'Windows_NT')
if ($PSVersionTable.PSVersion.Major -ge 6) {
    if ($PSVersionTable.Platform -eq 'Unix') {
        $script:IsWindowsOS = $false
    }
}

# Old function names kept working for scripts and tests that call them.
Set-Alias -Name Refresh-SystemPath -Value Update-SessionPath
Set-Alias -Name Test-And-InstallPrereqs -Value Test-BuildPrerequisite
Set-Alias -Name Find-CargoProjects -Value Find-CargoProject

# -------------------------------------------------------------------------
# Helper: STA Thread Runner (required for WinForms dialogs on pwsh Core)
# -------------------------------------------------------------------------
function Test-RcbStaThread {
    return ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA)
}

<#
.SYNOPSIS
    Path of the PowerShell host running this script (powershell.exe or pwsh).
#>
function Get-RcbHostExecutable {
    $exe = $null
    try { $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { $exe = $null }
    if (-not [string]::IsNullOrEmpty($exe)) {
        $leaf = [System.IO.Path]::GetFileNameWithoutExtension($exe)
        if ($leaf -match '^(powershell|pwsh)$') { return $exe }
    }
    if ($PSVersionTable.PSVersion.Major -le 5) { return 'powershell.exe' }
    if ($script:IsWindowsOS) { return 'pwsh.exe' }
    return 'pwsh'
}

<#
.SYNOPSIS
    Pure builder for the host argument list that re-runs this script with the
    same bound parameters. Present switches become -Name, absent ones are
    dropped, other values become "-Name", "value" (one argument each).
    -STA is added when the host is a Windows executable (*.exe).
#>
function ConvertTo-RcbRelaunchArgument {
    param(
        [hashtable]$BoundParameters,
        [string]$ScriptPath,
        [string[]]$Extra = @(),
        [string]$HostPath = 'powershell.exe'
    )
    $list = New-Object System.Collections.Generic.List[string]
    $list.Add('-NoProfile')
    if ($HostPath -match '\.exe$') { $list.Add('-STA') }
    $list.Add('-File')
    $list.Add($ScriptPath)
    if ($null -ne $BoundParameters) {
        foreach ($name in @($BoundParameters.Keys | Sort-Object)) {
            $value = $BoundParameters[$name]
            if ($null -eq $value) { continue }
            if ($value -is [System.Management.Automation.SwitchParameter]) {
                if ($value.IsPresent) { $list.Add('-' + [string]$name) }
                continue
            }
            if ($value -is [bool]) {
                if ($value) { $list.Add('-' + [string]$name) }
                continue
            }
            $text = [string]$value
            if ($text -eq '') { continue }
            $list.Add('-' + [string]$name)
            $list.Add($text)
        }
    }
    foreach ($e in @($Extra)) {
        if (-not [string]::IsNullOrEmpty($e)) { $list.Add($e) }
    }
    return $list.ToArray()
}

<#
.SYNOPSIS
    Re-runs this script in a child PowerShell process started with -STA,
    waits for it and returns its exit code.
#>
function Invoke-RcbStaRelaunch {
    param(
        [hashtable]$BoundParameters = $script:RcbBoundParameters,
        [string]$ScriptPath = $PSCommandPath,
        [string[]]$Extra = @()
    )
    if ($env:RCB_STA_CHILD -eq '1') {
        throw "An STA thread is required for the window, and the relaunched process is still not STA."
    }
    if ([string]::IsNullOrEmpty($ScriptPath)) {
        throw "An STA thread is required for the window, and the script path for a relaunch is unknown."
    }
    $hostExe = Get-RcbHostExecutable
    $argList = @(ConvertTo-RcbRelaunchArgument -BoundParameters $BoundParameters -ScriptPath $ScriptPath -Extra $Extra -HostPath $hostExe)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $hostExe
    $null = Set-RcbProcessArgument -StartInfo $psi -ArgumentList $argList
    $psi.UseShellExecute = $false
    $psi.EnvironmentVariables['RCB_STA_CHILD'] = '1'
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        $proc.WaitForExit()
        return [int]$proc.ExitCode
    } finally {
        try { $proc.Dispose() } catch { $null = $_ }
    }
}

# Already STA: runs the scriptblock inline and returns its output.
# Otherwise: re-runs this script in a -STA child process and returns its exit code
# (a raw .NET thread has no runspace, so script cannot run on it).
function Invoke-InSTA {
    param([scriptblock]$ScriptBlock, [string[]]$Extra = @())
    if (Test-RcbStaThread) {
        return (& $ScriptBlock)
    }

    # Not STA: relaunch the whole script in an STA child process.

    return (Invoke-RcbStaRelaunch -Extra $Extra)
}

# -------------------------------------------------------------------------
# Diagnostic Hints
# -------------------------------------------------------------------------
function Get-FriendlyHint {
    param([string]$Text)

    if ($Text -match 'no default is configured' -or $Text -match 'no default toolchain') {
        return "Rust is installed but no default toolchain is set. Open a terminal and run: rustup default stable"
    }
    if ($Text -match 'could not find `Cargo.toml`') {
        return "No Cargo.toml found at that location. Pick the folder that contains your Rust project."
    }
    if ($Text -match 'link\.exe' -or $Text -match 'linker `link\.exe` not found') {
        return "MSVC C++ Build Tools linker (link.exe) not found. Install MSVC Build Tools workload (Desktop development with C++)."
    }
    if ($Text -match 'failed to download' -or $Text -match "Couldn't resolve host" -or $Text -match 'spurious network error' -or $Text -match 'network') {
        return "Network or crates.io download failure. Check internet/proxy settings, or run with 'cargo build --offline' if dependencies are cached."
    }
    if ($Text -match 'Blocking waiting for file lock' -or $Text -match 'Access is denied' -or $Text -match 'being used by another process' -or $Text -match 'os error 32' -or $Text -match 'os error 5\b') {
        return "File lock or permission issue (os error 32/5). A running executable or process is locking target files. Close running instances."
    }
    if ($Text -match 'No space left' -or $Text -match 'There is not enough space' -or $Text -match 'os error 112') {
        return "Disk is full (os error 112). Free up disk space on target drive and try again."
    }
    if ($Text -match 'path too long' -or $Text -match 'os error 206') {
        return "Path length exceeds system limits (os error 206). Move project to a shorter path (e.g., C:\src) or enable Win32 LongPathsEnabled in registry."
    }
    return $null
}

# -------------------------------------------------------------------------
# Logging & Output Helpers
# -------------------------------------------------------------------------
$script:LogFilePath = $null

function Write-BuildLog {
    param(
        [string]$Message,
        [System.ConsoleColor]$ForegroundColor = [System.ConsoleColor]::Gray,
        [scriptblock]$UiCallback = $null,
        # rtk colour role: text, muted, heading, accent, info, success, warning,
        # danger or rtkchange. Defaults to the role matching -ForegroundColor.
        [string]$Role = ''
    )

    if ([string]::IsNullOrEmpty($Role)) { $Role = ConvertTo-RtkRole ([string]$ForegroundColor) }
    if ($script:RcbJsonProgress) {
        Write-RcbEvent 'log' ([ordered]@{ text = $Message; role = $Role })
    } else {
        Write-RtkConsoleLine -Message $Message -Role $Role
    }

    Write-RcbLogLine $Message

    if ($null -ne $UiCallback) {
        try {
            & $UiCallback $Message $Role
        } catch {
            # Suppress UI write failures
            $null = $_
        }
    }
}

# -------------------------------------------------------------------------
# Environment & PATH Refresh
# -------------------------------------------------------------------------
function Update-SessionPath {
    if ($script:IsWindowsOS) {
        try {
            $machinePath = [System.Environment]::GetEnvironmentVariable('Path', [System.EnvironmentVariableTarget]::Machine)
            $userPath    = [System.Environment]::GetEnvironmentVariable('Path', [System.EnvironmentVariableTarget]::User)
            $parts = @()
            if (-not [string]::IsNullOrEmpty($machinePath)) { $parts += $machinePath }
            if (-not [string]::IsNullOrEmpty($userPath)) { $parts += $userPath }
            $env:PATH = ($parts -join [System.IO.Path]::PathSeparator)
        } catch {
            # Ignore registry access limits
            $null = $_
        }
    }
}

# -------------------------------------------------------------------------
# Cargo bin directory on PATH (rustup installs are often not on PATH yet)
# -------------------------------------------------------------------------
<#
.SYNOPSIS
    When cargo is not resolvable, puts CARGO_HOME\bin and <home>\.cargo\bin
    (USERPROFILE on Windows, HOME elsewhere) at the front of PATH if the
    directory exists and is not already listed. Returns $true when cargo is
    resolvable afterwards.
#>
function Add-CargoBinToPath {
    $sep = [string][System.IO.Path]::PathSeparator
    $trimChars = [char[]]@('\', '/')
    $dirs = New-Object System.Collections.Generic.List[string]
    # Path.Combine, not Join-Path: Join-Path throws when the drive does not exist.
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
        # An already resolvable cargo is never shadowed.
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

# -------------------------------------------------------------------------
# Process Runner with Live Output Interception
# -------------------------------------------------------------------------
function Invoke-ToolProcess {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$WorkingDirectory = '',
        [scriptblock]$OnOutputLine = $null
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $null = Set-RcbProcessArgument -StartInfo $psi -ArgumentList $ArgumentList
    if (-not [string]::IsNullOrEmpty($WorkingDirectory)) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $capturedLines = New-Object System.Collections.Generic.List[string]

    try {
        $process.Start() | Out-Null
    } catch {
        $msg = $_.Exception.Message
        if ($null -ne $_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
        try { $process.Dispose() } catch { $null = $_ }
        $failLine = "failed to start ${FilePath}: $msg"
        if ($null -ne $OnOutputLine) { & $OnOutputLine $failLine }
        return [PSCustomObject]@{ ExitCode = -1; Lines = @($failLine) }
    }
    try {
    # stdout is drained by a .NET task (no PowerShell script on background threads);
    # cargo writes its progress and errors to stderr, which we stream line by line here.
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    while ($null -ne ($line = $process.StandardError.ReadLine())) {
        $capturedLines.Add($line)
        if ($null -ne $OnOutputLine) { & $OnOutputLine $line }
    }
    $process.WaitForExit()
    $outText = $stdoutTask.Result
    if (-not [string]::IsNullOrEmpty($outText)) {
        foreach ($l in ($outText -split "`r?`n")) {
            if ($l -ne '') {
                $capturedLines.Add($l)
                if ($null -ne $OnOutputLine) { & $OnOutputLine $l }
            }
        }
    }
    return [PSCustomObject]@{
        ExitCode = $process.ExitCode
        Lines    = $capturedLines.ToArray()
    }
    } finally {
        # An exception (callback failure, stop request) must not leave the child running.
        try {
            if (-not $process.HasExited) {
                $process.Kill()
                [void]$process.WaitForExit(5000)
            }
        } catch { $null = $_ }
        try { $process.Dispose() } catch { $null = $_ }
    }
}

# -------------------------------------------------------------------------
# Prerequisite Verification & Installation
# -------------------------------------------------------------------------
function Test-BuildPrerequisite {
    param(
        [bool]$NoInstallFlag,
        [scriptblock]$UiLog = $null,
        [scriptblock]$PromptUser = $null
    )

    # 1. Cargo check & cargo/bin PATH check
    $null = Add-CargoBinToPath

    $cargoCmd = Get-Command cargo -ErrorAction SilentlyContinue

    # 2. MSVC Build Tools Check (Windows only)
    $msvcFound = $true
    if ($script:IsWindowsOS) {
        $progFilesX86 = ${env:ProgramFiles(x86)}
        if ([string]::IsNullOrEmpty($progFilesX86)) {
            $progFilesX86 = 'C:\Program Files (x86)'
        }
        $vswherePath = Join-Path $progFilesX86 (Join-Path "Microsoft Visual Studio" (Join-Path "Installer" "vswhere.exe"))
        $msvcFound = $false
        if (Test-Path -LiteralPath $vswherePath) {
            $vsCheck = $null
            try {
                $vsCheck = & $vswherePath -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
            } catch {
                $vsCheck = $null
            }
            if (-not [string]::IsNullOrEmpty($vsCheck)) {
                $msvcFound = $true
            }
        }
    }

    $needsCargo = ($null -eq $cargoCmd)
    $needsMsvc = ($script:IsWindowsOS -and (-not $msvcFound))

    if (-not $needsCargo -and -not $needsMsvc) {
        return $true
    }

    if ($NoInstallFlag) {
        Write-BuildLog "Missing prerequisites detected, but -NoInstall was specified." -ForegroundColor Yellow -UiCallback $UiLog
        if ($needsCargo) { Write-BuildLog "  - Cargo/Rust is not in PATH." -ForegroundColor Red -UiCallback $UiLog }
        if ($needsMsvc)  { Write-BuildLog "  - MSVC C++ Build Tools are missing." -ForegroundColor Red -UiCallback $UiLog }
        return $false
    }

    # Prompt user
    $installQuestion = "The following prerequisites are missing:`n"
    if ($needsCargo) { $installQuestion += "  - Rust toolchain (rustup/cargo)`n" }
    if ($needsMsvc)  { $installQuestion += "  - Visual Studio C++ Build Tools (MSVC)`n" }
    $installQuestion += "`nWould you like to automatically install them now?"

    $consent = Request-RcbConfirm -Id 'install-prereqs' -Question $installQuestion -PromptUser $PromptUser

    if (-not $consent) {
        Write-BuildLog "Installation declined by user. Required prerequisites missing." -ForegroundColor Red -UiCallback $UiLog
        return $false
    }

    $hasWinget = $false
    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($null -ne $wingetCmd) {
        $hasWinget = $true
    }

    try {
    # Install Rust
    if ($needsCargo) {
        Write-BuildLog "Installing Rust toolchain..." -ForegroundColor Cyan -UiCallback $UiLog
        if ($hasWinget) {
            & winget install --id Rustlang.Rustup -e --accept-source-agreements --accept-package-agreements | ForEach-Object { Write-BuildLog "  $_" -Role muted -UiCallback $UiLog }
        } else {
            if ($script:IsWindowsOS) {
                $tempInit = Join-Path $env:TEMP "rustup-init.exe"
                Write-BuildLog "Downloading rustup-init from https://win.rustup.rs/x86_64..." -ForegroundColor Cyan -UiCallback $UiLog
                # Windows PowerShell 5.1: TLS 1.2 is not always on by default, and the IE engine may be missing.
                try {
                    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
                } catch { $null = $_ }
                Invoke-WebRequest -Uri "https://win.rustup.rs/x86_64" -OutFile $tempInit -UseBasicParsing
                & $tempInit -y | ForEach-Object { Write-BuildLog "  $_" -Role muted -UiCallback $UiLog }
            } else {
                Write-BuildLog "Please install rustup manually: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh" -ForegroundColor Red -UiCallback $UiLog
            }
        }
    }

    # Install MSVC Build Tools
    if ($needsMsvc) {
        Write-BuildLog "Installing Visual Studio C++ Build Tools..." -ForegroundColor Cyan -UiCallback $UiLog
        if ($hasWinget) {
            & winget install --id Microsoft.VisualStudio.2022.BuildTools -e --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended" | ForEach-Object { Write-BuildLog "  $_" -Role muted -UiCallback $UiLog }
        } else {
            Write-BuildLog "winget not found. Opening Visual Studio Build Tools download page..." -ForegroundColor Yellow -UiCallback $UiLog
            $url = "https://visualstudio.microsoft.com/visual-cpp-build-tools/"
            Write-BuildLog "Download URL: $url" -ForegroundColor Cyan -UiCallback $UiLog
            if ($script:IsWindowsOS) {
                Start-Process $url
            }
        }
    }

    Update-SessionPath

    } catch {
        Write-BuildLog "Automatic installation failed: $($_.Exception.Message)" -ForegroundColor Red -UiCallback $UiLog
        Update-SessionPath
    }

    # Update-SessionPath rebuilt PATH from the registry; put cargo's bin dir back.
    $null = Add-CargoBinToPath

    $recheckCargo = Get-Command cargo -ErrorAction SilentlyContinue
    if ($null -eq $recheckCargo) {
        Write-BuildLog "Cargo is still not detected in PATH. A system restart or new console session may be required." -ForegroundColor Red -UiCallback $UiLog
        return $false
    }

    return $true
}

# -------------------------------------------------------------------------
# Manifest & Project Discovery
# -------------------------------------------------------------------------
function Find-CargoProject {
    param([string]$RootDirectory)

    # Shared scanner from lib/RtkUpdate.ps1 (one directory walk, workspace members dropped).
    $items = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($p in @(Get-RcbCargoManifest -RootDirectory $RootDirectory -ExcludeWorkspaceMembers)) {
        if ($p -is [System.IO.FileInfo]) {
            $items.Add($p)
        } elseif (-not [string]::IsNullOrEmpty([string]$p)) {
            $items.Add((New-Object System.IO.FileInfo([string]$p)))
        }
    }
    $sorted = @($items | Sort-Object { ($_.DirectoryName -split '[\\/]').Count }, FullName)
    return ,([System.IO.FileInfo[]]$sorted)
}

<#
.SYNOPSIS
    target_directory from captured "cargo metadata" output lines. Cargo warnings
    (stderr) are captured together with the JSON, so the last line starting
    with "{" is tried first, then the whole text. Returns $null when not found.
#>
function Get-RcbMetadataTargetDir {
    param([string[]]$Lines)
    $all = @($Lines | Where-Object { $null -ne $_ })
    $candidates = New-Object System.Collections.Generic.List[string]
    $jsonLine = $null
    foreach ($l in $all) {
        if ($l -match '^\s*\{') { $jsonLine = $l }
    }
    if ($null -ne $jsonLine) { $candidates.Add($jsonLine) }
    if ($all.Count -gt 0) { $candidates.Add(($all -join "`n")) }
    foreach ($text in $candidates) {
        $obj = $null
        try { $obj = $text | ConvertFrom-Json } catch { $obj = $null }
        if ($null -eq $obj) { continue }
        $prop = $null
        try { $prop = $obj.PSObject.Properties['target_directory'] } catch { $prop = $null }
        if ($null -ne $prop -and -not [string]::IsNullOrEmpty([string]$prop.Value)) {
            return [string]$prop.Value
        }
    }
    return $null
}

# -------------------------------------------------------------------------
# One cargo build, with first-error and hint extraction
# -------------------------------------------------------------------------
function Invoke-CargoBuildStep {
    param(
        [string]$ManifestPath,
        [string]$ProjectDir,
        [string]$ActiveProfile,
        [scriptblock]$UiLog = $null
    )
    $passed = $false
    $firstErrors = New-Object System.Collections.Generic.List[string]
    $firstHints  = New-Object System.Collections.Generic.List[string]
    try {
        $buildArgs = @("build", "--manifest-path", $ManifestPath)
        if ($ActiveProfile -eq 'release') {
            $buildArgs += "--release"
        }

        $procResult = Invoke-ToolProcess -FilePath "cargo" -ArgumentList $buildArgs -WorkingDirectory $ProjectDir -OnOutputLine {
            param($line)
            Write-BuildLog "  $line" -Role muted -UiCallback $UiLog
        }

        if ($procResult.ExitCode -eq 0) {
            $passed = $true
        } else {
            # Parse errors from build output
            $recordingError = $false
            $errBlock = New-Object System.Text.StringBuilder
            foreach ($line in $procResult.Lines) {
                if ($line -match '^error(\[E\d+\])?:') {
                    if ($errBlock.Length -gt 0 -and $firstErrors.Count -lt 3) {
                        $firstErrors.Add($errBlock.ToString())
                    }
                    $errBlock.Length = 0
                    [void]$errBlock.Append($line)
                    $recordingError = $true
                } elseif ($recordingError -and $line -match '^\s*-->\s+') {
                    [void]$errBlock.Append("`n  ").Append($line)
                    $recordingError = $false
                    continue
                }
                if ($firstHints.Count -lt 3) {
                    $hint = Get-FriendlyHint -Text $line
                    if (-not [string]::IsNullOrEmpty($hint) -and -not ($firstHints -contains $hint)) {
                        $firstHints.Add($hint)
                    }
                }
            }
            if ($errBlock.Length -gt 0 -and $firstErrors.Count -lt 3) {
                $firstErrors.Add($errBlock.ToString())
            }
        }
    } catch {
        $passed = $false
        Write-BuildLog "Build execution exception: $($_.Exception.Message)" -ForegroundColor Red -UiCallback $UiLog
    }
    return [PSCustomObject]@{
        Passed      = $passed
        FirstErrors = $firstErrors.ToArray()
        FirstHints  = $firstHints.ToArray()
    }
}

# -------------------------------------------------------------------------
# Summary table (coloured per row, rtk column included)
# -------------------------------------------------------------------------
function Write-SummaryTable {
    param(
        [object[]]$Results,
        [scriptblock]$UiLog = $null
    )
    $rows = @($Results)
    $tableText = ($rows | Format-Table -Property Project, BuildStatus, TestStatus, Artifacts, Seconds, Rtk -AutoSize -Wrap | Out-String -Width 220)
    $lines = @($tableText -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    $rowIndex = -1
    foreach ($l in $lines) {
        $role = 'heading'
        if ($l -match '^-{3,}') { $role = 'muted' }
        else {
            # Map each printed line to its row by the project name at the start.
            foreach ($r in $rows) {
                if ($l.StartsWith([string]$r.Project + ' ')) { $rowIndex = [array]::IndexOf($rows, $r) }
            }
            if ($rowIndex -ge 0 -and $l -notmatch '^Project\s') {
                $r = $rows[$rowIndex]
                if ($r.BuildStatus -ne 'PASS' -or $r.TestStatus -eq 'FAIL') { $role = 'danger' }
                elseif ([string]$r.Rtk -match 'broke|NOT CHECKED|failed|error|behind') { $role = 'warning' }
                elseif ([string]$r.Rtk -match ' -> ') { $role = 'rtkchange' }
                else { $role = 'success' }
            }
        }
        if ($role -eq 'rtkchange') {
            $m = [regex]::Match($l, '^(.*?)(\S+)( -> )(\S+)(.*)$')
            if ($m.Success) {
                if ($script:RcbJsonProgress) {
                    Write-RcbEvent 'log' ([ordered]@{ text = $l; role = 'rtkchange' })
                } else {
                    Write-RtkSegment $m.Groups[1].Value 'success'
                    Write-RtkSegment $m.Groups[2].Value 'warning' -Bold
                    Write-RtkSegment $m.Groups[3].Value 'muted'
                    Write-RtkSegment $m.Groups[4].Value 'success' -Bold
                    Write-RtkSegment $m.Groups[5].Value 'success' -NewLine
                }
                Write-RcbLogLine $l
                if ($null -ne $UiLog) { try { & $UiLog $l 'rtkchange' } catch { $null = $_ } }
                continue
            }
            $role = 'success'
        }
        Write-BuildLog $l -Role $role -UiCallback $UiLog
    }
    foreach ($r in $rows) {
        if (@($r.RtkErrors).Count -gt 0) {
            Write-BuildLog "  $($r.Project): $($r.Rtk). First errors with the new rtk:" -Role danger -UiCallback $UiLog
            foreach ($e in $r.RtkErrors) { Write-BuildLog "    $e" -Role danger -UiCallback $UiLog }
        }
    }
}

# -------------------------------------------------------------------------
# Core Build Engine
# -------------------------------------------------------------------------
function Start-BuildPipelineCore {
    param(
        [string]$TargetFolder,
        [string]$ActiveProfile,
        [bool]$RunTests,
        [bool]$NoInstallFlag,
        [bool]$NoOpenFlag,
        [scriptblock]$UiLog = $null,
        [scriptblock]$PromptUser = $null,
        [bool]$NoRtkUpdateFlag = $false
    )

    $summaryResults = New-Object System.Collections.Generic.List[PSCustomObject]
    $overallSuccess = $true

    try {
        # Check folder validity
        if ([string]::IsNullOrEmpty($TargetFolder) -or -not (Test-Path -LiteralPath $TargetFolder -PathType Container)) {
            Write-BuildLog "Error: Invalid or non-existent folder specified: '$TargetFolder'" -ForegroundColor Red -UiCallback $UiLog
            return [PSCustomObject]@{ Success = $false; Cancelled = $true; Results = $summaryResults }
        }

        $resolvedPath = (Resolve-Path -LiteralPath $TargetFolder).ProviderPath

        # Warnings for long paths or spaces
        if ($resolvedPath.Length -gt 200) {
            Write-BuildLog "Warning: Path length is $($resolvedPath.Length) chars (> 200). Long paths may trigger build errors." -ForegroundColor Yellow -UiCallback $UiLog
        }
        if ($resolvedPath -match '\s') {
            Write-BuildLog "Warning: Path contains whitespace characters. Some Cargo tools or build scripts may misbehave." -ForegroundColor Yellow -UiCallback $UiLog
        }

        # Setup _built and log file
        $builtDir = Join-Path $resolvedPath "_built"
        if (-not (Test-Path -LiteralPath $builtDir)) {
            [System.IO.Directory]::CreateDirectory($builtDir) | Out-Null
        }
        $timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
        $script:LogFilePath = Join-Path $builtDir "build-$timestamp.log"
        [System.IO.File]::WriteAllText($script:LogFilePath, "Build started: $(Get-Date)`r`nPath: $resolvedPath`r`nProfile: $ActiveProfile`r`n`r`n")
        Open-RcbLogWriter $script:LogFilePath
        $script:RcbBuiltDir = $builtDir
        Write-RcbEvent 'start' ([ordered]@{ version = 1; path = $resolvedPath; profile = $ActiveProfile; test = $RunTests; rtk_update = (-not $NoRtkUpdateFlag); log_file = $script:LogFilePath })

        Write-BuildLog "==========================================================" -ForegroundColor Cyan -UiCallback $UiLog
        Write-BuildLog " Rust Project Builder: $resolvedPath" -ForegroundColor Cyan -UiCallback $UiLog
        Write-BuildLog " Log File: $script:LogFilePath" -ForegroundColor Cyan -UiCallback $UiLog
        Write-BuildLog "==========================================================" -ForegroundColor Cyan -UiCallback $UiLog

        # Check prereqs
        $prereqsOk = Test-BuildPrerequisite -NoInstallFlag $NoInstallFlag -UiLog $UiLog -PromptUser $PromptUser
        if (-not $prereqsOk) {
            Write-BuildLog "Terminating: Prerequisites are unmet." -ForegroundColor Red -UiCallback $UiLog
            return [PSCustomObject]@{ Success = $false; Cancelled = $false; Results = $summaryResults }
        }

        # Cargo's built-in git client cannot use Git Credential Manager; the git
        # CLI can, so private git deps like rtk resolve with the user's login.
        if ([string]::IsNullOrEmpty($env:CARGO_NET_GIT_FETCH_WITH_CLI) -and $null -ne (Get-Command git -ErrorAction SilentlyContinue)) {
            $env:CARGO_NET_GIT_FETCH_WITH_CLI = 'true'
        }
        if ($NoRtkUpdateFlag) {
            Write-BuildLog "rtk update check is OFF (-NoRtkUpdate)." -Role warning -UiCallback $UiLog
        }

        # Project discovery
        Write-BuildLog "Scanning for Cargo projects..." -ForegroundColor Gray -UiCallback $UiLog
        $projects = Find-CargoProject -RootDirectory $resolvedPath

        if ($projects.Count -eq 0) {
            Write-BuildLog "No Cargo.toml manifests found in '$resolvedPath'. Pick the folder that contains your Rust project (the one with Cargo.toml)." -ForegroundColor Yellow -UiCallback $UiLog
            return [PSCustomObject]@{ Success = $false; Cancelled = $true; Results = $summaryResults }
        }

        Write-BuildLog "Discovered $($projects.Count) project(s)/workspace(s).`n" -ForegroundColor Green -UiCallback $UiLog
        Write-RcbEvent 'discovered' ([ordered]@{ count = $projects.Count; projects = [string[]]@($projects | ForEach-Object { $_.Directory.Name }) })

        $projIndex = 0
        foreach ($manifest in $projects) {
            $projIndex++
            $projName = $manifest.Directory.Name
            $projDir = $manifest.DirectoryName
            $projManifestPath = $manifest.FullName

            $projTimer = [System.Diagnostics.Stopwatch]::StartNew()
            Write-RcbEvent 'project_start' ([ordered]@{ index = $projIndex; total = $projects.Count; name = $projName; dir = $projDir })
            Write-BuildLog "[$projIndex/$($projects.Count)] Building project '$projName'..." -ForegroundColor Cyan -UiCallback $UiLog

            $buildPassed = $false
            $testPassed = $null
            $exeCount = 0
            $firstErrors = New-Object System.Collections.Generic.List[string]
            $firstHints  = New-Object System.Collections.Generic.List[string]

            # Determine target directory via cargo metadata
            $targetDir = $null
            try {
                $metaArgs = @("metadata", "--format-version", "1", "--no-deps", "--manifest-path", $projManifestPath)
                $metaProc = Invoke-ToolProcess -FilePath "cargo" -ArgumentList $metaArgs -WorkingDirectory $projDir
                if ($metaProc.ExitCode -eq 0) {
                    $targetDir = Get-RcbMetadataTargetDir -Lines $metaProc.Lines
                }
            } catch {
                # Fallback on target directory error
                $null = $_
            $null = $_
            }

            if ([string]::IsNullOrEmpty($targetDir)) {
                $targetDir = Join-Path $projDir "target"
            }

            $profileSubdir = if ($ActiveProfile -eq 'release') { 'release' } else { 'debug' }
            $outputDir = Join-Path $targetDir $profileSubdir

            # Forced rtk update check (before every cargo build)
            Write-RcbEvent 'phase' ([ordered]@{ index = $projIndex; name = $projName; phase = 'rtk' })
            $rtkRes = $null
            if ($NoRtkUpdateFlag) {
                $rtkStatus = 'skipped (-NoRtkUpdate)'
            } else {
                try {
                    $rtkRes = Invoke-RtkUpdateCheck -ManifestPath $projManifestPath -BackupRoot $builtDir -Log {
                        param($m, $r)
                        Write-BuildLog $m -Role $r -UiCallback $UiLog
                    }
                    $rtkStatus = $rtkRes.Status
                } catch {
                    $rtkStatus = 'check error'
                    Write-BuildLog "  rtk: update check error: $($_.Exception.Message). Building with the current pins." -Role warning -UiCallback $UiLog
                }
            }

            Write-RcbEvent 'rtk' ([ordered]@{ index = $projIndex; name = $projName; status = [string]$rtkStatus; changed = [bool]($null -ne $rtkRes -and $rtkRes.Changed) })
            Write-RcbEvent 'phase' ([ordered]@{ index = $projIndex; name = $projName; phase = 'build' })
            # Build Step
            $build = Invoke-CargoBuildStep -ManifestPath $projManifestPath -ProjectDir $projDir -ActiveProfile $ActiveProfile -UiLog $UiLog
            $buildPassed = $build.Passed
            foreach ($e in $build.FirstErrors) { $firstErrors.Add($e) }
            foreach ($h in $build.FirstHints) { $firstHints.Add($h) }

            # rtk update broke the build: restore the backup and rebuild on the old pin.
            $rtkErrors = @()
            if (-not $buildPassed -and $null -ne $rtkRes -and $rtkRes.Changed) {
                $rtkErrors = @($build.FirstErrors)
                Write-BuildLog "  rtk: the build FAILED after the rtk update. Restoring the backup and rebuilding on $($rtkRes.KeptLabel)..." -Role danger -UiCallback $UiLog
                # Captured so restore output cannot leak into the pipeline result.
                $restoreOut = @(Restore-RtkBackup -Pairs $rtkRes.Backup)
                foreach ($rf in $restoreOut) {
                    if ($rf -is [string] -and $rf -ne '') { Write-BuildLog "  rtk: restore problem: $rf" -Role danger -UiCallback $UiLog }
                }
                $firstErrors.Clear(); $firstHints.Clear()
                $build = Invoke-CargoBuildStep -ManifestPath $projManifestPath -ProjectDir $projDir -ActiveProfile $ActiveProfile -UiLog $UiLog
                $buildPassed = $build.Passed
                foreach ($e in $build.FirstErrors) { $firstErrors.Add($e) }
                foreach ($h in $build.FirstHints) { $firstHints.Add($h) }
                $rtkStatus = "rtk update broke the build, kept $($rtkRes.KeptLabel)"
                Write-BuildLog "  rtk: $rtkStatus. First errors with the new rtk:" -Role danger -UiCallback $UiLog
                foreach ($e in $rtkErrors) { Write-BuildLog "    $e" -Role danger -UiCallback $UiLog }
            }
            if (-not $buildPassed) { $overallSuccess = $false }

            # Test Step (optional)
            if ($buildPassed -and $RunTests) {
                Write-RcbEvent 'phase' ([ordered]@{ index = $projIndex; name = $projName; phase = 'test' })
                Write-BuildLog "  Running tests for '$projName'..." -ForegroundColor Cyan -UiCallback $UiLog
                try {
                    $testArgs = @("test", "--manifest-path", $projManifestPath)
                    if ($ActiveProfile -eq 'release') {
                        $testArgs += "--release"
                    }
                    $testProc = Invoke-ToolProcess -FilePath "cargo" -ArgumentList $testArgs -WorkingDirectory $projDir -OnOutputLine {
                        param($line)
                        Write-BuildLog "  [test] $line" -ForegroundColor Gray -UiCallback $UiLog
                    }
                    if ($testProc.ExitCode -eq 0) {
                        $testPassed = $true
                    } else {
                        $testPassed = $false
                        $overallSuccess = $false
                    }
                } catch {
                    $testPassed = $false
                    $overallSuccess = $false
                    Write-BuildLog "Test execution exception: $($_.Exception.Message)" -ForegroundColor Red -UiCallback $UiLog
                }
            }

            # Copy Outputs Step
            Write-RcbEvent 'phase' ([ordered]@{ index = $projIndex; name = $projName; phase = 'collect' })
            if ($buildPassed -and (Test-Path -LiteralPath $outputDir)) {
                try {
                    $destProjBuilt = Join-Path $builtDir $projName
                    if (-not (Test-Path -LiteralPath $destProjBuilt)) {
                        [System.IO.Directory]::CreateDirectory($destProjBuilt) | Out-Null
                    }

                    if ($script:IsWindowsOS) {
                        $exeFiles = Get-ChildItem -LiteralPath $outputDir -Filter "*.exe" -File -Force -ErrorAction SilentlyContinue
                        foreach ($exe in $exeFiles) {
                            $targetPath = Join-Path $destProjBuilt $exe.Name
                            try {
                                Copy-Item -LiteralPath $exe.FullName -Destination $targetPath -Force -ErrorAction Stop
                                $exeCount++
                            } catch {
                                Write-BuildLog "Warning: could not copy '$($exe.Name)' (is it running or locked?): $($_.Exception.Message)" -ForegroundColor Yellow -UiCallback $UiLog
                            }
                        }
                    } else {
                        # Non-Windows executable copy: regular files without extensions having executable permissions
                        $allCandidates = Get-ChildItem -LiteralPath $outputDir -File -Force -ErrorAction SilentlyContinue
                        foreach ($cand in $allCandidates) {
                            if ([string]::IsNullOrEmpty($cand.Extension) -and $cand.Name -notmatch '\.') {
                                $targetPath = Join-Path $destProjBuilt $cand.Name
                                try {
                                    Copy-Item -LiteralPath $cand.FullName -Destination $targetPath -Force -ErrorAction Stop
                                    $exeCount++
                                } catch {
                                    Write-BuildLog "Warning: could not copy '$($cand.Name)' (is it running or locked?): $($_.Exception.Message)" -ForegroundColor Yellow -UiCallback $UiLog
                                }
                            }
                        }
                    }
                } catch {
                    Write-BuildLog "Warning: Error copying binaries: $($_.Exception.Message)" -ForegroundColor Yellow -UiCallback $UiLog
                }
            }

            $projTimer.Stop()
            $elapsedSec = [math]::Round($projTimer.Elapsed.TotalSeconds, 2)

            # Project summary feedback
            if ($buildPassed) {
                Write-BuildLog "[$projIndex/$($projects.Count)] PASS: '$projName' built in ${elapsedSec}s ($exeCount binary artifacts copied)." -ForegroundColor Green -UiCallback $UiLog
            } else {
                Write-BuildLog "[$projIndex/$($projects.Count)] FAIL: '$projName' failed after ${elapsedSec}s." -ForegroundColor Red -UiCallback $UiLog
                if ($firstErrors.Count -gt 0) {
                    Write-BuildLog "  Top error(s):" -ForegroundColor Red -UiCallback $UiLog
                    foreach ($err in $firstErrors) {
                        Write-BuildLog "    $err" -ForegroundColor Red -UiCallback $UiLog
                    }
                }
                if ($firstHints.Count -gt 0) {
                    Write-BuildLog "  Friendly diagnostic hint(s):" -ForegroundColor Yellow -UiCallback $UiLog
                    foreach ($hint in $firstHints) {
                        Write-BuildLog "    -> $hint" -ForegroundColor Yellow -UiCallback $UiLog
                    }
                }
            }

            $testDisplay = "N/A"
            if ($RunTests) {
                if ($testPassed -eq $true) {
                    $testDisplay = "PASS"
                } elseif ($testPassed -eq $false) {
                    $testDisplay = "FAIL"
                } else {
                    $testDisplay = "SKIPPED"
                }
            }

            $summaryResults.Add([PSCustomObject]@{
                Project     = $projName
                BuildStatus = if ($buildPassed) { "PASS" } else { "FAIL" }
                TestStatus  = $testDisplay
                Artifacts   = $exeCount
                Seconds     = $elapsedSec
                Rtk         = $rtkStatus
                RtkErrors   = $rtkErrors
            })

            $testEvt = 'N/A'
            if ($testPassed -eq $true) { $testEvt = 'PASS' } elseif ($testPassed -eq $false) { $testEvt = 'FAIL' }
            $buildEvt = 'FAIL'
            if ($buildPassed) { $buildEvt = 'PASS' }
            Write-RcbEvent 'project_end' ([ordered]@{ index = $projIndex; name = $projName; build = $buildEvt; test = $testEvt; artifacts = $exeCount; seconds = $elapsedSec; rtk = [string]$rtkStatus; errors = [string[]]$firstErrors.ToArray(); hints = [string[]]$firstHints.ToArray() })

            Write-BuildLog "" -UiCallback $UiLog
            if ($null -ne $script:LogWriter) { try { $script:LogWriter.Flush() } catch { $null = $_ } }
        }

        # Summary Display
        Write-BuildLog "============================= SUMMARY =============================" -ForegroundColor Cyan -UiCallback $UiLog
        Write-SummaryTable -Results $summaryResults -UiLog $UiLog
        Write-BuildLog "===================================================================" -ForegroundColor Cyan -UiCallback $UiLog

        if (-not $NoOpenFlag -and $script:IsWindowsOS -and (Test-Path -LiteralPath $builtDir)) {
            try {
                Start-Process "explorer.exe" -ArgumentList "`"$builtDir`""
            } catch {
                # Ignore explorer launch failures
                $null = $_
            $null = $_
            }
        }

        return [PSCustomObject]@{
            Success   = $overallSuccess
            Cancelled = $false
            Results   = $summaryResults
        }
    } catch {
        Write-BuildLog "Unexpected pipeline error: $($_.Exception.Message)" -ForegroundColor Red -UiCallback $UiLog
        return [PSCustomObject]@{ Success = $false; Cancelled = $false; Results = $summaryResults }
    }
}

# -------------------------------------------------------------------------
# Pipeline wrapper: closes the log writer, restores the environment and
# emits the single JSON "summary" event (also on early returns).
# -------------------------------------------------------------------------
function Start-BuildPipeline {
    param(
        [string]$TargetFolder,
        [string]$ActiveProfile,
        [bool]$RunTests,
        [bool]$NoInstallFlag,
        [bool]$NoOpenFlag,
        [scriptblock]$UiLog = $null,
        [scriptblock]$PromptUser = $null,
        [bool]$NoRtkUpdateFlag = $false
    )
    $prevGitCli = $env:CARGO_NET_GIT_FETCH_WITH_CLI
    # Never start a run with a writer left over from an earlier one.
    Close-RcbLogWriter
    $script:RcbBuiltDir = $null
    $script:LogFilePath = $null
    $result = $null
    try {
        $out = @(Start-BuildPipelineCore @PSBoundParameters)
        $result = $out | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['Success'] } | Select-Object -Last 1
    } finally {
        Close-RcbLogWriter
        $env:CARGO_NET_GIT_FETCH_WITH_CLI = $prevGitCli
    }

    $exitCode = 1; $success = $false; $cancelled = $false; $passed = 0; $failed = 0
    if ($null -ne $result) {
        $success = [bool]$result.Success
        $cancelled = [bool]$result.Cancelled
        if ($cancelled) { $exitCode = 2 } elseif ($success) { $exitCode = 0 }
        foreach ($r in @($result.Results)) {
            if ($r.BuildStatus -eq 'PASS') { $passed++ } else { $failed++ }
        }
    }
    Write-RcbEvent 'summary' ([ordered]@{ success = $success; cancelled = $cancelled; exit_code = $exitCode; built_dir = $script:RcbBuiltDir; log_file = $script:LogFilePath; passed = $passed; failed = $failed })
    return $result
}

# -------------------------------------------------------------------------
# WinForms GUI Interface (rtk look: tokens from lib/RtkTheme.ps1)
# -------------------------------------------------------------------------
$script:RtkFontCollection = $null
$script:RtkFontFamily = $null

<#
.SYNOPSIS
    Loads the bundled Noto Sans (400/700) for GDI+ and GDI. Falls back to
    Segoe UI when the files are missing or loading fails.
#>
function Initialize-RtkFont {
    if ($null -ne $script:RtkFontFamily) { return }
    $dir = Join-Path $PSScriptRoot (Join-Path 'assets' 'fonts')
    $files = @('NotoSans-Regular.ttf', 'NotoSans-Bold.ttf') | ForEach-Object { Join-Path $dir $_ }
    try {
        foreach ($f in $files) { if (-not (Test-Path -LiteralPath $f)) { throw "missing $f" } }
        # GDI (native TextBox/ComboBox and TextRenderer) only sees fonts registered with AddFontResourceEx.
        if (-not ('RcbFontNative' -as [type])) {
            Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class RcbFontNative {
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    public static extern int AddFontResourceEx(string name, uint fl, System.IntPtr res);
}
'@
        }
        foreach ($f in $files) { [void][RcbFontNative]::AddFontResourceEx($f, 0x10, [System.IntPtr]::Zero) }  # FR_PRIVATE
        $pfc = New-Object System.Drawing.Text.PrivateFontCollection
        foreach ($f in $files) { $pfc.AddFontFile($f) }
        $script:RtkFontCollection = $pfc
        $script:RtkFontFamily = $pfc.Families | Where-Object { $_.Name -eq 'Noto Sans' } | Select-Object -First 1
        if ($null -eq $script:RtkFontFamily) { $script:RtkFontFamily = $pfc.Families[0] }
    } catch {
        $script:RtkFontFamily = New-Object System.Drawing.FontFamily('Segoe UI')
    }
}

<#
.SYNOPSIS
    A Noto Sans font at an rtk pixel size (14 body, 18 title, 12 caption).
#>
function New-RtkFont {
    param([double]$Px = 14, [switch]$Bold)
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    return New-Object System.Drawing.Font($script:RtkFontFamily, [single]$Px, $style, [System.Drawing.GraphicsUnit]::Pixel)
}

<#
.SYNOPSIS
    System.Drawing.Color from an rtk RGB triple.
#>
function ConvertTo-DrawingColor {
    param([int[]]$Rgb)
    return [System.Drawing.Color]::FromArgb(255, $Rgb[0], $Rgb[1], $Rgb[2])
}

<#
.SYNOPSIS
    Rounded-rectangle GraphicsPath (radius 0 = plain rectangle).
#>
function New-RtkRoundedPath {
    param([System.Drawing.RectangleF]$Rect, [single]$Radius)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($Radius -le 0) { $path.AddRectangle($Rect); return ,$path }
    $d = [single]([math]::Min($Radius * 2, [math]::Min($Rect.Width, $Rect.Height)))
    $path.AddArc($Rect.X, $Rect.Y, $d, $d, 180, 90)
    $path.AddArc($Rect.Right - $d, $Rect.Y, $d, $d, 270, 90)
    $path.AddArc($Rect.Right - $d, $Rect.Bottom - $d, $d, $d, 0, 90)
    $path.AddArc($Rect.X, $Rect.Bottom - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    return ,$path
}

<#
.SYNOPSIS
    Paints an rtk Card / entry frame: rounded fill + 1px (2px in high contrast) border.
#>
function Invoke-RtkFramePaint {
    param($Control, $PaintArgs)
    $t = $script:GuiTheme
    $kind = $Control.Tag.Role
    $g = $PaintArgs.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear($Control.Parent.BackColor)
    $bw = [single]$t.BorderWidth
    $rect = New-Object System.Drawing.RectangleF(($bw / 2), ($bw / 2), ($Control.Width - $bw - 1), ($Control.Height - $bw - 1))
    $radius = if ($kind -eq 'card') { $t.CardRadius } else { $t.Radius.sm }
    $fill = if ($kind -eq 'card') { $t.Colors.surface } else { $t.Colors.field }
    $border = $t.Colors.border
    if ($kind -eq 'entry' -and $Control.Tag.Focused) { $border = $t.Colors.focus }
    $path = New-RtkRoundedPath $rect $radius
    $brush = New-Object System.Drawing.SolidBrush (ConvertTo-DrawingColor $fill)
    $pen = New-Object System.Drawing.Pen((ConvertTo-DrawingColor $border), $bw)
    if ($kind -eq 'entry' -and $Control.Tag.Focused) { $pen.Width = [single]($bw + 1) }
    $g.FillPath($brush, $path)
    $g.DrawPath($pen, $path)
    $brush.Dispose(); $pen.Dispose(); $path.Dispose()
}

<#
.SYNOPSIS
    Paints an rtk TButton (surface) or Accent.TButton (accent, bold) with
    hover/pressed/disabled states and radius md.
#>
function Invoke-RtkButtonPaint {
    param($Button, $PaintArgs)
    $t = $script:GuiTheme
    $c = $t.Colors
    $accent = ($Button.Tag.Role -eq 'accent')
    $g = $PaintArgs.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear($Button.Parent.BackColor)
    if ($accent) {
        $bg = $c.accent; $fg = $c.accent_fg; $bd = $c.accent
        if ($Button.Tag.Pressed) { $bg = $c.accent_pressed } elseif ($Button.Tag.Hover) { $bg = $c.accent_hover }
    } else {
        $bg = $c.surface; $fg = $c.fg; $bd = $c.border
        if ($Button.Tag.Pressed) { $bg = $c.pressed } elseif ($Button.Tag.Hover) { $bg = $c.hover }
    }
    if (-not $Button.Enabled) { $fg = $c.text_disabled; if ($accent) { $bg = Get-RtkBlend $c.accent $c.surface 0.55; $bd = $bg } }
    $bw = [single]$t.BorderWidth
    $rect = New-Object System.Drawing.RectangleF(($bw / 2), ($bw / 2), ($Button.Width - $bw - 1), ($Button.Height - $bw - 1))
    $path = New-RtkRoundedPath $rect $t.Radius.md
    $brush = New-Object System.Drawing.SolidBrush (ConvertTo-DrawingColor $bg)
    $pen = New-Object System.Drawing.Pen((ConvertTo-DrawingColor $bd), $bw)
    $g.FillPath($brush, $path); $g.DrawPath($pen, $path)
    if ($Button.Focused -and $Button.Tag.ShowFocus) {
        $ring = New-Object System.Drawing.Pen((ConvertTo-DrawingColor $c.focus), [single]2)
        $g.DrawPath($ring, $path); $ring.Dispose()
    }
    $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::SingleLine
    [System.Windows.Forms.TextRenderer]::DrawText($g, $Button.Text, $Button.Font, $Button.ClientRectangle, (ConvertTo-DrawingColor $fg), $flags)
    $brush.Dispose(); $pen.Dispose(); $path.Dispose()
}

<#
.SYNOPSIS
    Creates an owner-drawn rtk button. Role "button" (TButton) or "accent".
#>
function New-RtkButton {
    param([string]$Text, [string]$Role = 'button', [int]$Width = 110, [int]$Height = 36)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Size = New-Object System.Drawing.Size($Width, $Height)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 0
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Font = New-RtkFont -Px 14 -Bold:($Role -eq 'accent')
    $b.Tag = @{ Role = $Role; Hover = $false; Pressed = $false; ShowFocus = $false }
    $b.add_MouseEnter({ $this.Tag.Hover = $true; $this.Invalidate() })
    $b.add_MouseLeave({ $this.Tag.Hover = $false; $this.Tag.Pressed = $false; $this.Invalidate() })
    $b.add_MouseDown({ $this.Tag.Pressed = $true; $this.Invalidate() })
    $b.add_MouseUp({ $this.Tag.Pressed = $false; $this.Invalidate() })
    $b.add_KeyUp({ $this.Tag.ShowFocus = $true; $this.Invalidate() })
    $b.add_EnabledChanged({ $this.Invalidate() })
    $b.add_Paint({ Invoke-RtkButtonPaint -Button $this -PaintArgs $_ })
    return $b
}

<#
.SYNOPSIS
    Creates an rtk Card panel (surface, radius 12, padding 16).
#>
function New-RtkCard {
    $p = New-Object System.Windows.Forms.Panel
    $p.Tag = @{ Role = 'card' }
    $p.Padding = New-Object System.Windows.Forms.Padding(16)
    $p.add_Paint({ Invoke-RtkFramePaint -Control $this -PaintArgs $_ })
    $p.add_Resize({ $this.Invalidate() })
    return $p
}

<#
.SYNOPSIS
    Creates a label with an rtk text role: text, muted, title, caption.
#>
function New-RtkLabel {
    param([string]$Text, [string]$Role = 'text', [double]$Px = 14, [switch]$Bold)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.AutoSize = $true
    $l.Font = New-RtkFont -Px $Px -Bold:$Bold
    $l.Tag = @{ Role = $Role }
    return $l
}

<#
.SYNOPSIS
    Applies the current $script:GuiTheme colours to a control tree.
#>
function Set-RtkControlTheme {
    param($Control)
    $c = $script:GuiTheme.Colors
    $role = $null
    if ($Control.Tag -is [hashtable]) { $role = $Control.Tag.Role }
    switch ($role) {
        'header'  { $Control.BackColor = ConvertTo-DrawingColor $c.surface }
        'status'  { $Control.BackColor = ConvertTo-DrawingColor $c.surface }
        'card'    { $Control.BackColor = ConvertTo-DrawingColor $c.surface }
        'entry'   { $Control.BackColor = ConvertTo-DrawingColor $c.field }
        'rule'    { $Control.BackColor = ConvertTo-DrawingColor $c.border }
        'text'    { $Control.ForeColor = ConvertTo-DrawingColor $c.fg; $Control.BackColor = [System.Drawing.Color]::Transparent }
        'muted'   { $Control.ForeColor = ConvertTo-DrawingColor $c.muted; $Control.BackColor = [System.Drawing.Color]::Transparent }
        'textbox' { $Control.BackColor = ConvertTo-DrawingColor $c.field; $Control.ForeColor = ConvertTo-DrawingColor $c.fg }
        'log'     { $Control.BackColor = ConvertTo-DrawingColor $c.bg; $Control.ForeColor = ConvertTo-DrawingColor $c.fg }
        'combo'   { $Control.BackColor = ConvertTo-DrawingColor $c.field; $Control.ForeColor = ConvertTo-DrawingColor $c.fg }
        'check'   {
            $Control.ForeColor = ConvertTo-DrawingColor $c.fg
            $Control.BackColor = ConvertTo-DrawingColor $c.surface
            $Control.FlatAppearance.BorderColor = ConvertTo-DrawingColor $c.border
            $Control.FlatAppearance.CheckedBackColor = ConvertTo-DrawingColor $c.accent
            $Control.FlatAppearance.MouseOverBackColor = ConvertTo-DrawingColor $c.hover
        }
        default   { }
    }
    $Control.Invalidate()
    foreach ($child in $Control.Controls) { Set-RtkControlTheme $child }
}

function Show-BuildGui {
    param(
        [string]$InitialPath,
        [string]$InitialProfile,
        [bool]$InitialTest,
        [bool]$InitialRtkUpdate = $true,
        [string]$InitialTheme = 'System',
        [bool]$NoInstall = $false,
        [bool]$NoOpen = $false
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { $null = $_ }
    Initialize-RtkFont

    $themeNameFor = {
        param($choice)
        switch ($choice) {
            'Light'        { 'ModernLight' }
            'Dark'         { 'ModernDark' }
            'HighContrast' { 'HighContrast' }
            default        { Get-RtkSystemThemeName }
        }
    }
    $script:GuiTheme = Get-RtkTheme -Name (& $themeNameFor $InitialTheme)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Rust Click Build"
    $form.ClientSize = New-Object System.Drawing.Size(860, 720)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
    $form.MinimumSize = New-Object System.Drawing.Size(720, 560)
    $form.Font = New-RtkFont -Px 14
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

    # Header bar: title, subtitle, theme picker
    $header = New-Object System.Windows.Forms.Panel
    $header.Tag = @{ Role = 'header' }
    $header.Dock = [System.Windows.Forms.DockStyle]::Top
    $header.Height = 68
    $lblTitle = New-RtkLabel -Text 'Rust Click Build' -Px 18 -Bold
    $lblTitle.Location = New-Object System.Drawing.Point(24, 12)
    $header.Controls.Add($lblTitle)
    $lblSub = New-RtkLabel -Text 'Click-and-go cargo builder  |  rtk style' -Role 'muted' -Px 12
    $lblSub.Location = New-Object System.Drawing.Point(25, 40)
    $header.Controls.Add($lblSub)
    $lblTheme = New-RtkLabel -Text 'Theme' -Role 'muted' -Px 12
    $lblTheme.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $lblTheme.Location = New-Object System.Drawing.Point(632, 25)
    $header.Controls.Add($lblTheme)
    $cmbTheme = New-Object System.Windows.Forms.ComboBox
    $cmbTheme.Tag = @{ Role = 'combo' }
    $cmbTheme.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cmbTheme.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    [void]$cmbTheme.Items.AddRange(@('System', 'Light', 'Dark', 'HighContrast'))
    $cmbTheme.SelectedItem = $InitialTheme
    $cmbTheme.Size = New-Object System.Drawing.Size(160, 28)
    $cmbTheme.Location = New-Object System.Drawing.Point(678, 20)
    $cmbTheme.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $header.Controls.Add($cmbTheme)
    $rule = New-Object System.Windows.Forms.Panel
    $rule.Tag = @{ Role = 'rule' }
    $rule.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $rule.Height = 1
    $header.Controls.Add($rule)

    # Status bar
    $status = New-Object System.Windows.Forms.Panel
    $status.Tag = @{ Role = 'status' }
    $status.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $status.Height = 34
    $lblStatus = New-RtkLabel -Text 'Ready. Pick a folder and press Start Build.' -Role 'muted' -Px 12
    $lblStatus.Location = New-Object System.Drawing.Point(24, 9)
    $status.Controls.Add($lblStatus)
    $rule2 = New-Object System.Windows.Forms.Panel
    $rule2.Tag = @{ Role = 'rule' }
    $rule2.Dock = [System.Windows.Forms.DockStyle]::Top
    $rule2.Height = 1
    $status.Controls.Add($rule2)

    # Body
    $body = New-Object System.Windows.Forms.Panel
    $body.Dock = [System.Windows.Forms.DockStyle]::Fill
    $anchorTLR = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $anchorAll = $anchorTLR -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $anchorTR  = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $W = 860; $pad = 16; $gap = 12

    # Card 1: project folder
    $cardPath = New-RtkCard
    $cardPath.Location = New-Object System.Drawing.Point($pad, $pad)
    $cardPath.Size = New-Object System.Drawing.Size(($W - 2 * $pad), 96)
    $cardPath.Anchor = $anchorTLR
    $lblPath = New-RtkLabel -Text 'PROJECT FOLDER' -Role 'muted' -Px 12 -Bold
    $lblPath.Location = New-Object System.Drawing.Point(16, 14)
    $cardPath.Controls.Add($lblPath)
    $entry = New-Object System.Windows.Forms.Panel
    $entry.Tag = @{ Role = 'entry'; Focused = $false }
    $entry.Location = New-Object System.Drawing.Point(16, 40)
    $entry.Size = New-Object System.Drawing.Size(($cardPath.Width - 32 - 110 - 8), 38)
    $entry.Anchor = $anchorTLR
    $entry.add_Paint({ Invoke-RtkFramePaint -Control $this -PaintArgs $_ })
    $entry.add_Resize({ $this.Invalidate() })
    $txtPath = New-Object System.Windows.Forms.TextBox
    $txtPath.Tag = @{ Role = 'textbox' }
    $txtPath.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $txtPath.Font = New-RtkFont -Px 14
    $txtPath.Location = New-Object System.Drawing.Point(12, 10)
    $txtPath.Width = $entry.Width - 24
    $txtPath.Anchor = $anchorTLR
    if (-not [string]::IsNullOrEmpty($InitialPath)) { $txtPath.Text = $InitialPath } else { $txtPath.Text = (Get-Location).Path }
    $txtPath.add_GotFocus({ $entry.Tag.Focused = $true; $entry.Invalidate() })
    $txtPath.add_LostFocus({ $entry.Tag.Focused = $false; $entry.Invalidate() })
    $entry.Controls.Add($txtPath)
    $cardPath.Controls.Add($entry)
    $btnBrowse = New-RtkButton -Text 'Browse...' -Width 110 -Height 38
    $btnBrowse.Location = New-Object System.Drawing.Point(($cardPath.Width - 16 - 110), 40)
    $btnBrowse.Anchor = $anchorTR
    $btnBrowse.add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        if (-not [string]::IsNullOrEmpty($txtPath.Text) -and (Test-Path -LiteralPath $txtPath.Text)) {
            $dlg.SelectedPath = $txtPath.Text
        }
        $dlg.Description = "Select Rust Workspace or Project Root Folder"
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtPath.Text = $dlg.SelectedPath
        }
    })
    $cardPath.Controls.Add($btnBrowse)
    $body.Controls.Add($cardPath)

    # Card 2: build options
    $cardOpt = New-RtkCard
    $cardOpt.Location = New-Object System.Drawing.Point($pad, ($pad + 96 + $gap))
    $cardOpt.Size = New-Object System.Drawing.Size(($W - 2 * $pad), 118)
    $cardOpt.Anchor = $anchorTLR
    $lblOpt = New-RtkLabel -Text 'BUILD OPTIONS' -Role 'muted' -Px 12 -Bold
    $lblOpt.Location = New-Object System.Drawing.Point(16, 14)
    $cardOpt.Controls.Add($lblOpt)
    $newCheck = {
        param($kind, $text, $x, $y, $w)
        $cb = if ($kind -eq 'radio') { New-Object System.Windows.Forms.RadioButton } else { New-Object System.Windows.Forms.CheckBox }
        $cb.Text = $text
        $cb.Tag = @{ Role = 'check' }
        $cb.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $cb.Font = New-RtkFont -Px 14
        $cb.Location = New-Object System.Drawing.Point($x, $y)
        $cb.Size = New-Object System.Drawing.Size($w, 26)
        $cb.Cursor = [System.Windows.Forms.Cursors]::Hand
        return $cb
    }
    $rbRelease = & $newCheck 'radio' 'Release' 16 42 100
    $rbRelease.Checked = ($InitialProfile -eq 'release')
    $cardOpt.Controls.Add($rbRelease)
    $rbDebug = & $newCheck 'radio' 'Debug' 124 42 90
    $rbDebug.Checked = ($InitialProfile -eq 'debug')
    $cardOpt.Controls.Add($rbDebug)
    $chkTest = & $newCheck 'check' 'Run tests (cargo test)' 236 42 220
    $chkTest.Checked = $InitialTest
    $cardOpt.Controls.Add($chkTest)
    $chkRtk = & $newCheck 'check' 'Check for rtk updates before building (recommended)' 16 74 420
    $chkRtk.Checked = $InitialRtkUpdate
    $cardOpt.Controls.Add($chkRtk)
    $btnBuild = New-RtkButton -Text 'Start Build' -Role 'accent' -Width 150 -Height 42
    # Build options travel with the button, so the click handler does not depend on scope lookup.
    $btnBuild.Tag['State'] = @{ NoInstall = [bool]$NoInstall; NoOpen = [bool]$NoOpen }
    $btnBuild.Location = New-Object System.Drawing.Point(($cardOpt.Width - 16 - 150), 52)
    $btnBuild.Anchor = $anchorTR
    $cardOpt.Controls.Add($btnBuild)
    $body.Controls.Add($cardOpt)

    # Card 3: log
    $logTop = $pad + 96 + $gap + 118 + $gap
    $cardLog = New-RtkCard
    $cardLog.Location = New-Object System.Drawing.Point($pad, $logTop)
    $cardLog.Size = New-Object System.Drawing.Size(($W - 2 * $pad), (720 - 68 - 34 - $logTop - $pad))
    $cardLog.Anchor = $anchorAll
    $lblLog = New-RtkLabel -Text 'BUILD LOG' -Role 'muted' -Px 12 -Bold
    $lblLog.Location = New-Object System.Drawing.Point(16, 14)
    $cardLog.Controls.Add($lblLog)
    $txtLog = New-Object System.Windows.Forms.RichTextBox
    $txtLog.Tag = @{ Role = 'log' }
    $txtLog.ReadOnly = $true
    $txtLog.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $txtLog.WordWrap = $false
    $txtLog.DetectUrls = $false
    $monoName = 'Consolas'
    try { if ((New-Object System.Drawing.FontFamily('Cascadia Mono')).Name -eq 'Cascadia Mono') { $monoName = 'Cascadia Mono' } } catch { $null = $_ }
    $txtLog.Font = New-Object System.Drawing.Font($monoName, [single]13, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $txtLog.Location = New-Object System.Drawing.Point(16, 40)
    $txtLog.Size = New-Object System.Drawing.Size(($cardLog.Width - 32), ($cardLog.Height - 56))
    $txtLog.Anchor = $anchorAll
    $cardLog.Controls.Add($txtLog)
    $body.Controls.Add($cardLog)

    $form.Controls.Add($body)
    $form.Controls.Add($status)
    $form.Controls.Add($header)

    $applyTheme = {
        $form.BackColor = ConvertTo-DrawingColor $script:GuiTheme.Colors.bg
        $body.BackColor = $form.BackColor
        $form.ForeColor = ConvertTo-DrawingColor $script:GuiTheme.Colors.fg
        Set-RtkControlTheme $form
    }
    & $applyTheme
    $cmbTheme.add_SelectedIndexChanged({
        $script:GuiTheme = Get-RtkTheme -Name (& $themeNameFor ([string]$cmbTheme.SelectedItem))
        & $applyTheme
    })

    # Log lines coloured by rtk role (same roles as the console).
    $uiLogger = {
        param($line, $role)
        if ([string]::IsNullOrEmpty($role)) { $role = 'text' }
        $txtLog.SelectionStart = $txtLog.TextLength
        $txtLog.SelectionLength = 0
        if ($role -eq 'rtkchange') {
            $m = [regex]::Match($line, '^(.*?)(\S+)( -> )(\S+)(.*)$')
            if ($m.Success) {
                $segs = @(@($m.Groups[1].Value, 'accent'), @($m.Groups[2].Value, 'warning'), @($m.Groups[3].Value, 'muted'), @($m.Groups[4].Value, 'success'), @(($m.Groups[5].Value + "`r`n"), 'muted'))
                foreach ($s in $segs) {
                    $txtLog.SelectionColor = ConvertTo-DrawingColor (Get-RtkRoleRgb $s[1] $script:GuiTheme)
                    $txtLog.AppendText($s[0])
                }
                $txtLog.ScrollToCaret()
                [System.Windows.Forms.Application]::DoEvents()
                return
            }
            $role = 'accent'
        }
        $txtLog.SelectionColor = ConvertTo-DrawingColor (Get-RtkRoleRgb $role $script:GuiTheme)
        $txtLog.AppendText($line + "`r`n")
        $txtLog.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }

    $guiPrompt = {
        param($promptMsg)
        $choice = [System.Windows.Forms.MessageBox]::Show(
            $promptMsg,
            "Rust Prerequisites Required",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        return ($choice -eq [System.Windows.Forms.DialogResult]::Yes)
    }

    $btnBuild.add_Click({
        $optNoInstall = $false
        $optNoOpen = $false
        $clickState = $null
        if ($null -ne $this -and $this.Tag -is [hashtable]) { $clickState = $this.Tag['State'] }
        if ($clickState -is [hashtable]) {
            $optNoInstall = [bool]$clickState['NoInstall']
            $optNoOpen = [bool]$clickState['NoOpen']
        }
        try {
        $btnBuild.Enabled = $false
        $btnBrowse.Enabled = $false
        $txtPath.Enabled = $false
        $cardOpt.Enabled = $false
        $txtLog.Clear()
        $lblStatus.Text = 'Building...'
        $lblStatus.ForeColor = ConvertTo-DrawingColor $script:GuiTheme.Colors.accent

        $chosenProfile = if ($rbRelease.Checked) { 'release' } else { 'debug' }
        $chosenTest = $chkTest.Checked
        $folder = $txtPath.Text.Trim()

            $pipeResult = Start-BuildPipeline `
                -TargetFolder $folder `
                -ActiveProfile $chosenProfile `
                -RunTests $chosenTest `
                -NoInstallFlag $optNoInstall `
                -NoOpenFlag $optNoOpen `
                -UiLog $uiLogger `
                -PromptUser $guiPrompt `
                -NoRtkUpdateFlag (-not $chkRtk.Checked)
            if ($null -ne $pipeResult) {
                $res = @($pipeResult.Results)
                $ok = @($res | Where-Object { $_.BuildStatus -eq 'PASS' }).Count
                $bad = $res.Count - $ok
                $rtkNote = @($res | Where-Object { [string]$_.Rtk -match ' -> |broke|NOT CHECKED' } | ForEach-Object { "$($_.Project): $($_.Rtk)" }) -join '; '
                $lblStatus.Text = "Done: $ok built, $bad failed." + $(if ($rtkNote) { "  rtk: $rtkNote" } else { '' })
                $roleName = if ($bad -gt 0) { 'danger' } elseif ($rtkNote -match 'broke|NOT CHECKED') { 'warning' } else { 'success' }
                $lblStatus.ForeColor = ConvertTo-DrawingColor (Get-RtkRoleRgb $roleName $script:GuiTheme)
            }
        } catch {
            # Show the error in the log box instead of crashing the form.
            $clickError = "Build stopped by an unexpected error: $($_.Exception.Message)"
            try {
                & $uiLogger $clickError 'danger'
            } catch {
                try { $txtLog.AppendText($clickError + "`r`n") } catch { $null = $_ }
            }
            try {
                $lblStatus.Text = 'Build error. See the log.'
                $lblStatus.ForeColor = ConvertTo-DrawingColor (Get-RtkRoleRgb 'danger' $script:GuiTheme)
            } catch { $null = $_ }
        } finally {
            $btnBuild.Enabled = $true
            $btnBrowse.Enabled = $true
            $txtPath.Enabled = $true
            $cardOpt.Enabled = $true
        }
    })

    $form.AcceptButton = $btnBuild
    $form.ShowDialog() | Out-Null
    return 0
}

# -------------------------------------------------------------------------
# CLI Folder Browser Dialog Fallback
# -------------------------------------------------------------------------
function Request-FolderDialog {
    # Needs an STA thread; the entry point relaunches the script before calling this when not STA.
    if (-not (Test-RcbStaThread)) { return $null }
    return (Invoke-InSTA {
        Add-Type -AssemblyName System.Windows.Forms
        $browser = New-Object System.Windows.Forms.FolderBrowserDialog
        $browser.Description = "Select Rust Workspace or Project Root Folder"
        $browser.ShowNewFolderButton = $false
        $dialogResult = $browser.ShowDialog()
        if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
            return $browser.SelectedPath
        }
        return $null
    })
}

# -------------------------------------------------------------------------
# Entry Point & Main Execution Block
# -------------------------------------------------------------------------
# Tests dot-source this file to load the functions without running a build.
if ($MyInvocation.InvocationName -eq '.' -or $env:RCB_NO_MAIN -eq '1') { return }

$scriptExitCode = 0

try {
    if ($Gui -or $ClassicGui) {
        $guiReason = 'classic window requested'
        if (-not $ClassicGui) {
            $guiDir = Join-Path $PSScriptRoot 'gui'
            $guiExeName = 'rcb-gui'
            if ($script:IsWindowsOS) { $guiExeName = 'rcb-gui.exe' }
            $guiReason = 'no rcb-gui executable found'
            # A rustup-only install has cargo in ~\.cargo\bin but not on PATH yet.
            $guiHasCargo = [bool](Add-CargoBinToPath)
            if ($guiHasCargo -and (Test-Path -LiteralPath (Join-Path $guiDir 'Cargo.toml'))) {
                # Building through the normal pipeline is what auto-bumps the GUI's own rtk tag.
                $guiBuild = Start-BuildPipeline -TargetFolder $guiDir -ActiveProfile 'release' -RunTests $false -NoInstallFlag $NoInstall.IsPresent -NoOpenFlag $true -NoRtkUpdateFlag $NoRtkUpdate.IsPresent
                if ($null -eq $guiBuild -or -not $guiBuild.Success) { $guiReason = 'the GUI build failed and no earlier rcb-gui build exists' }
            } else {
                $guiReason = 'cargo or gui\Cargo.toml is missing and there is no prebuilt rcb-gui'
            }
            $guiCandidates = @(
                (Join-Path $guiDir (Join-Path '_built' (Join-Path 'rcb-gui' $guiExeName))),
                (Join-Path $guiDir (Join-Path '_built' (Join-Path 'gui' $guiExeName)))
            )
            if (-not [string]::IsNullOrEmpty($env:CARGO_TARGET_DIR)) {
                $guiCandidates += (Join-Path $env:CARGO_TARGET_DIR (Join-Path 'release' $guiExeName))
            }
            $guiCandidates += (Join-Path $guiDir (Join-Path 'target' (Join-Path 'release' $guiExeName)))
            $guiCandidates += (Join-Path $guiDir (Join-Path 'bin' $guiExeName))
            $guiExe = $null
            foreach ($cand in $guiCandidates) {
                if (Test-Path -LiteralPath $cand -PathType Leaf) { $guiExe = $cand; break }
            }
            if ($null -ne $guiExe) {
                $guiArgs = @('--script', $PSCommandPath, '--theme', $Theme, '--profile', $BuildProfile)
                if (-not [string]::IsNullOrEmpty($Path)) { $guiArgs += @('--path', $Path) }
                if ($Test) { $guiArgs += '--test' }
                if ($NoRtkUpdate) { $guiArgs += '--no-rtk-update' }
                try {
                    # One quoted command line on every platform: Start-Process joins an
                    # array with plain spaces, which breaks paths that contain spaces.
                    Start-Process -FilePath $guiExe -ArgumentList (Join-RcbCommandLine $guiArgs)
                    $scriptExitCode = 0
                    exit 0
                } catch {
                    $guiReason = "could not start ${guiExe}: $($_.Exception.Message)"
                }
            }
        }
        if (-not $script:IsWindowsOS) {
            Write-Host "Error: GUI unavailable ($guiReason). The classic window requires Windows." -ForegroundColor Red
            $scriptExitCode = 1
            exit 1
        }
        if (-not $ClassicGui) {
            Write-Host "rtk GUI unavailable ($guiReason); opening the classic window" -ForegroundColor Yellow
        }
        # When not STA the script is relaunched; -ClassicGui makes the child skip the rtk GUI attempt.
        $staExtra = @()
        if (-not $ClassicGui) { $staExtra += '-ClassicGui' }
        $guiOut = @(Invoke-InSTA -Extra $staExtra -ScriptBlock {
            Show-BuildGui -InitialPath $Path -InitialProfile $BuildProfile -InitialTest $Test.IsPresent -InitialRtkUpdate (-not $NoRtkUpdate.IsPresent) -InitialTheme $Theme -NoInstall $NoInstall.IsPresent -NoOpen $NoOpen.IsPresent
        })
        $scriptExitCode = 0
        if ($guiOut.Count -gt 0 -and $guiOut[$guiOut.Count - 1] -is [int]) { $scriptExitCode = [int]$guiOut[$guiOut.Count - 1] }
        exit $scriptExitCode
    }

    # Non-GUI mode: resolve folder path (with -JsonProgress the pipeline validates
    # the folder itself so the summary event is still emitted; no dialog, no output)
    if (-not $JsonProgress -and [string]::IsNullOrEmpty($Path)) {
        if ($script:IsWindowsOS) {
            if (-not (Test-RcbStaThread)) {
                # The folder dialog needs STA: let an STA child run the whole build.
                $relaunchExtra = @()
                if (-not $NoPause) { $relaunchExtra += '-NoPause' }
                $scriptExitCode = [int](Invoke-RcbStaRelaunch -Extra $relaunchExtra)
                exit $scriptExitCode
            }
            Write-Host "No path supplied. Opening folder selection dialog..." -ForegroundColor Cyan
            $selected = Request-FolderDialog
            if ([string]::IsNullOrEmpty($selected)) {
                Write-Host "Folder selection cancelled by user." -ForegroundColor Yellow
                $scriptExitCode = 2
                exit $scriptExitCode
            }
            $Path = $selected
        } else {
            Write-Host "Error: -Path parameter is required on non-Windows platforms." -ForegroundColor Red
            $scriptExitCode = 2
            exit $scriptExitCode
        }
    }

    if (-not $JsonProgress -and -not (Test-Path -LiteralPath $Path)) {
        Write-Host "Error: Specified path '$Path' does not exist." -ForegroundColor Red
        $scriptExitCode = 2
        exit $scriptExitCode
    }

    # Run the build pipeline
    $pipelineResult = Start-BuildPipeline `
        -TargetFolder $Path `
        -ActiveProfile $BuildProfile `
        -RunTests $Test.IsPresent `
        -NoInstallFlag $NoInstall.IsPresent `
        -NoOpenFlag $NoOpen.IsPresent `
        -NoRtkUpdateFlag $NoRtkUpdate.IsPresent

    if ($null -eq $pipelineResult) {
        $scriptExitCode = 1
    } elseif ($pipelineResult.Cancelled) {
        $scriptExitCode = 2
    } elseif ($pipelineResult.Success) {
        $scriptExitCode = 0
    } else {
        $scriptExitCode = 1
    }
} catch {
    if ($JsonProgress) {
        Write-RcbEvent 'fatal' ([ordered]@{ message = [string]$_.Exception.Message })
    } else {
        Write-Host "FATAL: Unhandled script exception: $($_.Exception.Message)" -ForegroundColor Red
    }
    $scriptExitCode = 1
} finally {
    if (-not $JsonProgress -and -not [string]::IsNullOrEmpty($script:LogFilePath)) {
        Write-Host ""
        Write-Host "Full build log available at: $script:LogFilePath" -ForegroundColor Cyan
    }

    if (-not $JsonProgress -and -not $Gui -and -not $ClassicGui -and -not $NoPause) {
        # Read-Host throws in a non-interactive host; that must not replace the exit code.
        try {
            Write-Host ""
            $null = Read-Host "Press Enter to close"
        } catch { $null = $_ }
    }

    exit $scriptExitCode
}
