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
    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'

# Determine Windows platform reliably across PS 5.1 and pwsh Core
$script:IsWindowsOS = ($env:OS -eq 'Windows_NT')
if ($PSVersionTable.PSVersion.Major -ge 6) {
    if ($PSVersionTable.Platform -eq 'Unix') {
        $script:IsWindowsOS = $false
    }
}

# -------------------------------------------------------------------------
# Helper: STA Thread Runner (required for WinForms dialogs on pwsh Core)
# -------------------------------------------------------------------------
function Invoke-InSTA {
    param([scriptblock]$ScriptBlock)
    $currentApartment = [System.Threading.Thread]::CurrentThread.GetApartmentState()
    if ($currentApartment -eq [System.Threading.ApartmentState]::STA) {
        return (& $ScriptBlock)
    }

    $result = $null
    $threadError = $null
    $thread = New-Object System.Threading.Thread([System.Threading.ThreadStart]{
        try {
            $script:staOutput = & $ScriptBlock
        } catch {
            $script:staError = $_
        }
    })
    $thread.SetApartmentState([System.Threading.ApartmentState]::STA)
    $thread.Start()
    $thread.Join()

    if ($null -ne $script:staError) {
        $err = $script:staError
        $script:staError = $null
        throw $err
    }
    $res = $script:staOutput
    $script:staOutput = $null
    return $res
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
        [scriptblock]$UiCallback = $null
    )

    if ($ForegroundColor -ne [System.ConsoleColor]::Gray) {
        Write-Host $Message -ForegroundColor $ForegroundColor
    } else {
        Write-Host $Message
    }

    if ($null -ne $script:LogFilePath -and [System.IO.File]::Exists($script:LogFilePath)) {
        try {
            [System.IO.File]::AppendAllText($script:LogFilePath, "$Message`r`n")
        } catch {
            # Suppress log write failures
        }
    }

    if ($null -ne $UiCallback) {
        try {
            & $UiCallback $Message
        } catch {
            # Suppress UI write failures
        }
    }
}

# -------------------------------------------------------------------------
# Environment & PATH Refresh
# -------------------------------------------------------------------------
function Refresh-SystemPath {
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
        }
    }
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
    $escapedArgs = @()
    foreach ($arg in $ArgumentList) {
        if ($arg -match '\s|"') {
            $escapedArgs += ('"' + ($arg -replace '"', '\"') + '"')
        } else {
            $escapedArgs += $arg
        }
    }
    $psi.Arguments = ($escapedArgs -join ' ')
    if (-not [string]::IsNullOrEmpty($WorkingDirectory)) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $capturedLines = New-Object System.Collections.Generic.List[string]

    $process.Start() | Out-Null
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
}

# -------------------------------------------------------------------------
# Prerequisite Verification & Installation
# -------------------------------------------------------------------------
function Test-And-InstallPrereqs {
    param(
        [bool]$NoInstallFlag,
        [scriptblock]$UiLog = $null,
        [scriptblock]$PromptUser = $null
    )

    # 1. Cargo check & cargo/bin PATH check
    $userHome = $env:USERPROFILE
    if ([string]::IsNullOrEmpty($userHome)) {
        $userHome = $env:HOME
    }

    if (-not [string]::IsNullOrEmpty($userHome)) {
        $cargoBin = Join-Path $userHome (Join-Path ".cargo" "bin")
        if ((Test-Path -LiteralPath $cargoBin) -and ($null -eq (Get-Command cargo -ErrorAction SilentlyContinue))) {
            $pathParts = $env:PATH -split [System.IO.Path]::PathSeparator
            if (-not ($pathParts -contains $cargoBin)) {
                $env:PATH = "$cargoBin" + [System.IO.Path]::PathSeparator + $env:PATH
            }
        }
    }

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
            $vsCheck = & $vswherePath -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
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

    $consent = $false
    if ($null -ne $PromptUser) {
        $consent = & $PromptUser $installQuestion
    } else {
        Write-Host ""
        Write-Host $installQuestion -ForegroundColor Yellow
        $response = Read-Host "Proceed with automated installation? (Y/N)"
        if ($response -match '^[Yy]') {
            $consent = $true
        }
    }

    if (-not $consent) {
        Write-BuildLog "Installation declined by user. Required prerequisites missing." -ForegroundColor Red -UiCallback $UiLog
        return $false
    }

    $hasWinget = $false
    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($null -ne $wingetCmd) {
        $hasWinget = $true
    }

    # Install Rust
    if ($needsCargo) {
        Write-BuildLog "Installing Rust toolchain..." -ForegroundColor Cyan -UiCallback $UiLog
        if ($hasWinget) {
            & winget install --id Rustlang.Rustup -e --accept-source-agreements --accept-package-agreements
        } else {
            if ($script:IsWindowsOS) {
                $tempInit = Join-Path $env:TEMP "rustup-init.exe"
                Write-BuildLog "Downloading rustup-init from https://win.rustup.rs/x86_64..." -ForegroundColor Cyan -UiCallback $UiLog
                Invoke-WebRequest -Uri "https://win.rustup.rs/x86_64" -OutFile $tempInit
                & $tempInit -y
            } else {
                Write-BuildLog "Please install rustup manually: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh" -ForegroundColor Red -UiCallback $UiLog
            }
        }
    }

    # Install MSVC Build Tools
    if ($needsMsvc) {
        Write-BuildLog "Installing Visual Studio C++ Build Tools..." -ForegroundColor Cyan -UiCallback $UiLog
        if ($hasWinget) {
            & winget install --id Microsoft.VisualStudio.2022.BuildTools -e --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
        } else {
            Write-BuildLog "winget not found. Opening Visual Studio Build Tools download page..." -ForegroundColor Yellow -UiCallback $UiLog
            $url = "https://visualstudio.microsoft.com/visual-cpp-build-tools/"
            Write-BuildLog "Download URL: $url" -ForegroundColor Cyan -UiCallback $UiLog
            if ($script:IsWindowsOS) {
                Start-Process $url
            }
        }
    }

    Refresh-SystemPath

    if (-not [string]::IsNullOrEmpty($userHome)) {
        $cargoBin = Join-Path $userHome (Join-Path ".cargo" "bin")
        if ((Test-Path -LiteralPath $cargoBin) -and ($null -eq (Get-Command cargo -ErrorAction SilentlyContinue))) {
            $pathParts = $env:PATH -split [System.IO.Path]::PathSeparator
            if (-not ($pathParts -contains $cargoBin)) {
                $env:PATH = "$cargoBin" + [System.IO.Path]::PathSeparator + $env:PATH
            }
        }
    }

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
function Find-CargoProjects {
    param([string]$RootDirectory)

    $allTomls = Get-ChildItem -LiteralPath $RootDirectory -Filter "Cargo.toml" -Recurse -File -Force -ErrorAction SilentlyContinue
    if ($null -eq $allTomls -or $allTomls.Count -eq 0) {
        return @()
    }

    # Filter invalid paths: target, .git, node_modules, _built
    $validManifests = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($item in $allTomls) {
        $fullPath = $item.FullName
        $sep = [System.IO.Path]::DirectorySeparatorChar
        $alt = [System.IO.Path]::AltDirectorySeparatorChar
        if ($fullPath -match "[\$sep$alt]target[\$sep$alt]" -or
            $fullPath -match "[\$sep$alt]\.git[\$sep$alt]" -or
            $fullPath -match "[\$sep$alt]node_modules[\$sep$alt]" -or
            $fullPath -match "[\$sep$alt]_built[\$sep$alt]") {
            continue
        }
        $validManifests.Add($item)
    }

    # Sort manifests by folder depth so top-level workspaces are evaluated first
    $sortedManifests = $validManifests | Sort-Object { ($_.DirectoryName -split '[\\/]').Count }

    $acceptedWorkspaceRoots = New-Object System.Collections.Generic.List[string]
    $finalProjects = New-Object System.Collections.Generic.List[System.IO.FileInfo]

    foreach ($manifest in $sortedManifests) {
        $dir = $manifest.DirectoryName

        # Check if dir is under any accepted workspace root
        $isInsideWorkspace = $false
        foreach ($wsRoot in $acceptedWorkspaceRoots) {
            $prefix = $wsRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
            if ($dir.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isInsideWorkspace = $true
                break
            }
        }

        if ($isInsideWorkspace) {
            continue
        }

        # Check if this Cargo.toml declares a [workspace]
        $content = Get-Content -LiteralPath $manifest.FullName -Raw -ErrorAction SilentlyContinue
        $isWorkspace = $false
        if (-not [string]::IsNullOrEmpty($content)) {
            if ($content -match '(?m)^\s*\[workspace\]') {
                $isWorkspace = $true
            }
        }

        if ($isWorkspace) {
            $acceptedWorkspaceRoots.Add($dir)
        }
        $finalProjects.Add($manifest)
    }

    return $finalProjects.ToArray()
}

# -------------------------------------------------------------------------
# Core Build Engine
# -------------------------------------------------------------------------
function Start-BuildPipeline {
    param(
        [string]$TargetFolder,
        [string]$ActiveProfile,
        [bool]$RunTests,
        [bool]$NoInstallFlag,
        [bool]$NoOpenFlag,
        [scriptblock]$UiLog = $null,
        [scriptblock]$PromptUser = $null
    )

    $summaryResults = New-Object System.Collections.Generic.List[PSCustomObject]
    $overallSuccess = $true

    try {
        # Check folder validity
        if ([string]::IsNullOrEmpty($TargetFolder) -or -not (Test-Path -LiteralPath $TargetFolder)) {
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

        Write-BuildLog "==========================================================" -ForegroundColor Cyan -UiCallback $UiLog
        Write-BuildLog " Rust Project Builder: $resolvedPath" -ForegroundColor Cyan -UiCallback $UiLog
        Write-BuildLog " Log File: $script:LogFilePath" -ForegroundColor Cyan -UiCallback $UiLog
        Write-BuildLog "==========================================================" -ForegroundColor Cyan -UiCallback $UiLog

        # Check prereqs
        $prereqsOk = Test-And-InstallPrereqs -NoInstallFlag $NoInstallFlag -UiLog $UiLog -PromptUser $PromptUser
        if (-not $prereqsOk) {
            Write-BuildLog "Terminating: Prerequisites are unmet." -ForegroundColor Red -UiCallback $UiLog
            return [PSCustomObject]@{ Success = $false; Cancelled = $false; Results = $summaryResults }
        }

        # Project discovery
        Write-BuildLog "Scanning for Cargo projects..." -ForegroundColor Gray -UiCallback $UiLog
        $projects = Find-CargoProjects -RootDirectory $resolvedPath

        if ($projects.Count -eq 0) {
            Write-BuildLog "No Cargo.toml manifests found in '$resolvedPath'. Pick the folder that contains your Rust project (the one with Cargo.toml)." -ForegroundColor Yellow -UiCallback $UiLog
            return [PSCustomObject]@{ Success = $false; Cancelled = $true; Results = $summaryResults }
        }

        Write-BuildLog "Discovered $($projects.Count) project(s)/workspace(s).`n" -ForegroundColor Green -UiCallback $UiLog

        $projIndex = 0
        foreach ($manifest in $projects) {
            $projIndex++
            $projName = $manifest.Directory.Name
            $projDir = $manifest.DirectoryName
            $projManifestPath = $manifest.FullName

            $projTimer = [System.Diagnostics.Stopwatch]::StartNew()
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
                    $jsonText = ($metaProc.Lines -join "`n")
                    $metaObj = $jsonText | ConvertFrom-Json
                    if ($null -ne $metaObj.target_directory) {
                        $targetDir = $metaObj.target_directory
                    }
                }
            } catch {
                # Fallback on target directory error
            }

            if ([string]::IsNullOrEmpty($targetDir)) {
                $targetDir = Join-Path $projDir "target"
            }

            $profileSubdir = if ($ActiveProfile -eq 'release') { 'release' } else { 'debug' }
            $outputDir = Join-Path $targetDir $profileSubdir

            # Build Step
            try {
                $buildArgs = @("build", "--manifest-path", $projManifestPath)
                if ($ActiveProfile -eq 'release') {
                    $buildArgs += "--release"
                }

                $capturedLines = New-Object System.Collections.Generic.List[string]
                $procResult = Invoke-ToolProcess -FilePath "cargo" -ArgumentList $buildArgs -WorkingDirectory $projDir -OnOutputLine {
                    param($line)
                    Write-BuildLog "  $line" -ForegroundColor Gray -UiCallback $UiLog
                }

                if ($procResult.ExitCode -eq 0) {
                    $buildPassed = $true
                } else {
                    $buildPassed = $false
                    $overallSuccess = $false

                    # Parse errors from build output
                    $recordingError = $false
                    $currentErrBlock = ""
                    foreach ($line in $procResult.Lines) {
                        if ($line -match '^error(\[E\d+\])?:') {
                            if (-not [string]::IsNullOrEmpty($currentErrBlock) -and $firstErrors.Count -lt 3) {
                                $firstErrors.Add($currentErrBlock)
                            }
                            $currentErrBlock = $line
                            $recordingError = $true
                            $hint = Get-FriendlyHint -Text $line
                            if (-not [string]::IsNullOrEmpty($hint) -and -not ($firstHints -contains $hint)) {
                                $firstHints.Add($hint)
                            }
                        } elseif ($recordingError -and $line -match '^\s*-->\s+') {
                            $currentErrBlock += "`n  " + $line
                            $recordingError = $false
                        } else {
                            $hint = Get-FriendlyHint -Text $line
                            if (-not [string]::IsNullOrEmpty($hint) -and -not ($firstHints -contains $hint)) {
                                $firstHints.Add($hint)
                            }
                        }
                    }
                    if (-not [string]::IsNullOrEmpty($currentErrBlock) -and $firstErrors.Count -lt 3) {
                        $firstErrors.Add($currentErrBlock)
                    }
                }
            } catch {
                $buildPassed = $false
                $overallSuccess = $false
                Write-BuildLog "Build execution exception: $($_.Exception.Message)" -ForegroundColor Red -UiCallback $UiLog
            }

            # Test Step (optional)
            if ($buildPassed -and $RunTests) {
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
                            Copy-Item -LiteralPath $exe.FullName -Destination $targetPath -Force
                            $exeCount++
                        }
                    } else {
                        # Non-Windows executable copy: regular files without extensions having executable permissions
                        $allCandidates = Get-ChildItem -LiteralPath $outputDir -File -Force -ErrorAction SilentlyContinue
                        foreach ($cand in $allCandidates) {
                            if ([string]::IsNullOrEmpty($cand.Extension) -and $cand.Name -notmatch '\.') {
                                $targetPath = Join-Path $destProjBuilt $cand.Name
                                Copy-Item -LiteralPath $cand.FullName -Destination $targetPath -Force
                                $exeCount++
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
            })

            Write-BuildLog "" -UiCallback $UiLog
        }

        # Summary Display
        Write-BuildLog "============================= SUMMARY =============================" -ForegroundColor Cyan -UiCallback $UiLog
        $summaryTable = $summaryResults | Format-Table -Property Project, BuildStatus, TestStatus, Artifacts, Seconds -AutoSize | Out-String
        Write-BuildLog $summaryTable -ForegroundColor White -UiCallback $UiLog
        Write-BuildLog "===================================================================" -ForegroundColor Cyan -UiCallback $UiLog

        if (-not $NoOpenFlag -and $script:IsWindowsOS -and (Test-Path -LiteralPath $builtDir)) {
            try {
                Start-Process "explorer.exe" -ArgumentList "`"$builtDir`""
            } catch {
                # Ignore explorer launch failures
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
# WinForms GUI Interface
# -------------------------------------------------------------------------
function Show-BuildGui {
    param(
        [string]$InitialPath,
        [string]$InitialProfile,
        [bool]$InitialTest
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Rust Cargo Builder"
    $form.Size = New-Object System.Drawing.Size(820, 680)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
    $form.MinimumSize = New-Object System.Drawing.Size(650, 450)

    # Path Section
    $lblPath = New-Object System.Windows.Forms.Label
    $lblPath.Text = "Project Folder:"
    $lblPath.Location = New-Object System.Drawing.Point(15, 15)
    $lblPath.Size = New-Object System.Drawing.Size(90, 23)
    $form.Controls.Add($lblPath)

    $txtPath = New-Object System.Windows.Forms.TextBox
    $txtPath.Location = New-Object System.Drawing.Point(110, 12)
    $txtPath.Size = New-Object System.Drawing.Size(570, 23)
    $txtPath.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    if (-not [string]::IsNullOrEmpty($InitialPath)) {
        $txtPath.Text = $InitialPath
    } else {
        $txtPath.Text = (Get-Location).Path
    }
    $form.Controls.Add($txtPath)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = "Browse..."
    $btnBrowse.Location = New-Object System.Drawing.Point(690, 10)
    $btnBrowse.Size = New-Object System.Drawing.Size(95, 26)
    $btnBrowse.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
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
    $form.Controls.Add($btnBrowse)

    # Options Group
    $grpOptions = New-Object System.Windows.Forms.GroupBox
    $grpOptions.Text = "Build Options"
    $grpOptions.Location = New-Object System.Drawing.Point(15, 45)
    $grpOptions.Size = New-Object System.Drawing.Size(770, 55)
    $grpOptions.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

    $rbRelease = New-Object System.Windows.Forms.RadioButton
    $rbRelease.Text = "Release"
    $rbRelease.Location = New-Object System.Drawing.Point(20, 20)
    $rbRelease.Size = New-Object System.Drawing.Size(90, 24)
    $rbRelease.Checked = ($InitialProfile -eq 'release')
    $grpOptions.Controls.Add($rbRelease)

    $rbDebug = New-Object System.Windows.Forms.RadioButton
    $rbDebug.Text = "Debug"
    $rbDebug.Location = New-Object System.Drawing.Point(115, 20)
    $rbDebug.Size = New-Object System.Drawing.Size(90, 24)
    $rbDebug.Checked = ($InitialProfile -eq 'debug')
    $grpOptions.Controls.Add($rbDebug)

    $chkTest = New-Object System.Windows.Forms.CheckBox
    $chkTest.Text = "Run tests (cargo test)"
    $chkTest.Location = New-Object System.Drawing.Point(230, 20)
    $chkTest.Size = New-Object System.Drawing.Size(180, 24)
    $chkTest.Checked = $InitialTest
    $grpOptions.Controls.Add($chkTest)

    $btnBuild = New-Object System.Windows.Forms.Button
    $btnBuild.Text = "Start Build"
    $btnBuild.Font = New-Object System.Drawing.Font($btnBuild.Font.FontFamily, 9.5, [System.Drawing.FontStyle]::Bold)
    $btnBuild.Location = New-Object System.Drawing.Point(630, 16)
    $btnBuild.Size = New-Object System.Drawing.Size(130, 30)
    $btnBuild.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $grpOptions.Controls.Add($btnBuild)

    $form.Controls.Add($grpOptions)

    # Log Textbox
    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Multiline = $true
    $txtLog.ReadOnly = $true
    $txtLog.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
    $txtLog.Font = New-Object System.Drawing.Font("Consolas", 9.5)
    $txtLog.Location = New-Object System.Drawing.Point(15, 110)
    $txtLog.Size = New-Object System.Drawing.Size(770, 515)
    $txtLog.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $txtLog.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $txtLog.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
    $form.Controls.Add($txtLog)

    $uiLogger = {
        param($line)
        $txtLog.AppendText($line + "`r`n")
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
        $btnBuild.Enabled = $false
        $btnBrowse.Enabled = $false
        $txtPath.Enabled = $false
        $grpOptions.Enabled = $false
        $txtLog.Clear()

        $chosenProfile = if ($rbRelease.Checked) { 'release' } else { 'debug' }
        $chosenTest = $chkTest.Checked
        $folder = $txtPath.Text.Trim()

        try {
            $pipeResult = Start-BuildPipeline `
                -TargetFolder $folder `
                -ActiveProfile $chosenProfile `
                -RunTests $chosenTest `
                -NoInstallFlag $NoInstall `
                -NoOpenFlag $NoOpen `
                -UiLog $uiLogger `
                -PromptUser $guiPrompt
        } finally {
            $btnBuild.Enabled = $true
            $btnBrowse.Enabled = $true
            $txtPath.Enabled = $true
            $grpOptions.Enabled = $true
        }
    })

    $form.ShowDialog() | Out-Null
    return 0
}

# -------------------------------------------------------------------------
# CLI Folder Browser Dialog Fallback
# -------------------------------------------------------------------------
function Request-FolderDialog {
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
$scriptExitCode = 0

try {
    if ($Gui) {
        if (-not $script:IsWindowsOS) {
            Write-Host "GUI mode requires Windows Forms support." -ForegroundColor Red
            exit 1
        }
        $scriptExitCode = Invoke-InSTA {
            Show-BuildGui -InitialPath $Path -InitialProfile $BuildProfile -InitialTest $Test.IsPresent
        }
        exit $scriptExitCode
    }

    # Non-GUI mode: resolve folder path
    if ([string]::IsNullOrEmpty($Path)) {
        if ($script:IsWindowsOS) {
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

    if (-not (Test-Path -LiteralPath $Path)) {
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
        -NoOpenFlag $NoOpen.IsPresent

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
    Write-Host "FATAL: Unhandled script exception: $($_.Exception.Message)" -ForegroundColor Red
    $scriptExitCode = 1
} finally {
    if (-not [string]::IsNullOrEmpty($script:LogFilePath)) {
        Write-Host ""
        Write-Host "Full build log available at: $script:LogFilePath" -ForegroundColor Cyan
    }

    if (-not $Gui -and -not $NoPause) {
        Write-Host ""
        $null = Read-Host "Press Enter to close"
    }

    exit $scriptExitCode
}
