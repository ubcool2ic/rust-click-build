# Optional Authenticode signing of collected _built artifacts.
# The PFX password is read only from $env:RCB_SIGN_PFX_PASSWORD. It is never
# written to a log, a file, or the configuration JSON.

$script:RcbDefaultTimestampUrl = 'http://timestamp.digicert.com'
$script:RcbSignConfigName = 'rcb.sign.json'

function Get-RcbRedactedSignArgs {
    param([string[]]$ArgumentList)
    $out = New-Object System.Collections.Generic.List[string]
    $hideNext = $false
    foreach ($a in @($ArgumentList)) {
        if ($hideNext) { $out.Add('<redacted>'); $hideNext = $false; continue }
        if ($a -eq '/p' -or $a -eq '-pass' -or $a -eq '-password') { $out.Add($a); $hideNext = $true; continue }
        $out.Add($a)
    }
    return ($out -join ' ')
}

<#
.SYNOPSIS
    Reads optional signing defaults from rcb.sign.json (never a password).
#>
function Read-RcbSignConfigFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        $raw = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path)
        $obj = $raw | ConvertFrom-Json
        return $obj
    } catch {
        throw "Could not read signing config '$Path': $($_.Exception.Message)"
    }
}

function Resolve-RcbSignConfigPath {
    param([string]$Explicit, [string]$ProjectFolder, [string]$ToolRoot)
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) { return $Explicit }
    foreach ($dir in @($ProjectFolder, $ToolRoot)) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        $cand = Join-Path $dir $script:RcbSignConfigName
        if (Test-Path -LiteralPath $cand -PathType Leaf) { return $cand }
    }
    return $null
}

<#
.SYNOPSIS
    Merges CLI signing options with rcb.sign.json. CLI wins. Password is never
    taken from the file.
#>
function Get-RcbSignSettings {
    param(
        [bool]$SignFlag,
        [string]$CertThumbprint = '',
        [string]$PfxPath = '',
        [string]$TimestampUrl = '',
        [string]$SignConfigPath = '',
        [string]$ProjectFolder = '',
        [string]$ToolRoot = ''
    )
    $cfgPath = Resolve-RcbSignConfigPath -Explicit $SignConfigPath -ProjectFolder $ProjectFolder -ToolRoot $ToolRoot
    $cfg = $null
    if (-not [string]::IsNullOrWhiteSpace($cfgPath)) {
        $cfg = Read-RcbSignConfigFile -Path $cfgPath
    }
    $enabled = $SignFlag
    if (-not $enabled -and $null -ne $cfg -and $cfg.PSObject.Properties['sign'] -and [bool]$cfg.sign) {
        $enabled = $true
    }
    $thumb = $CertThumbprint
    if ([string]::IsNullOrWhiteSpace($thumb) -and $null -ne $cfg) { $thumb = [string]$cfg.certThumbprint }
    $pfx = $PfxPath
    if ([string]::IsNullOrWhiteSpace($pfx) -and $null -ne $cfg) { $pfx = [string]$cfg.pfxPath }
    $ts = $TimestampUrl
    if ([string]::IsNullOrWhiteSpace($ts) -and $null -ne $cfg) { $ts = [string]$cfg.timestampUrl }
    if ([string]::IsNullOrWhiteSpace($ts)) { $ts = $script:RcbDefaultTimestampUrl }
    return [PSCustomObject]@{
        Enabled        = [bool]$enabled
        CertThumbprint = ([string]$thumb).Trim()
        PfxPath        = ([string]$pfx).Trim()
        TimestampUrl   = ([string]$ts).Trim()
        ConfigPath     = $cfgPath
        Tool           = $null
        ToolKind       = $null
        Error          = $null
    }
}

<#
.SYNOPSIS
    Locates signtool.exe (Windows SDK, newest Kits bin) or osslsigncode.
    RCB_SIGNTOOL, if set, wins (used by tests).
#>
function Find-RcbSignTool {
    if (-not [string]::IsNullOrWhiteSpace($env:RCB_SIGNTOOL) -and (Test-Path -LiteralPath $env:RCB_SIGNTOOL -PathType Leaf)) {
        $kind = 'signtool'
        $leaf = [System.IO.Path]::GetFileNameWithoutExtension($env:RCB_SIGNTOOL)
        if ($leaf -match 'osslsigncode') { $kind = 'osslsigncode' }
        return [PSCustomObject]@{ Path = $env:RCB_SIGNTOOL; Kind = $kind }
    }
    $cmd = Get-Command signtool -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and -not [string]::IsNullOrEmpty($cmd.Source)) {
        return [PSCustomObject]@{ Path = [string]$cmd.Source; Kind = 'signtool' }
    }
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($pf in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, ${env:ProgramW6432})) {
        if ([string]::IsNullOrWhiteSpace($pf)) { continue }
        $roots.Add((Join-Path $pf (Join-Path 'Windows Kits' (Join-Path '10' 'bin'))))
        $roots.Add((Join-Path $pf (Join-Path 'Windows Kits' (Join-Path '11' 'bin'))))
    }
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        try {
            foreach ($verDir in [System.IO.Directory]::GetDirectories($root)) {
                foreach ($arch in @('x64', 'x86', 'arm64')) {
                    $exe = [System.IO.Path]::Combine($verDir, $arch, 'signtool.exe')
                    if ([System.IO.File]::Exists($exe)) { $found.Add($exe) }
                }
            }
        } catch { $null = $_ }
    }
    if ($found.Count -gt 0) {
        $picked = @($found | Sort-Object -Descending)[0]
        return [PSCustomObject]@{ Path = $picked; Kind = 'signtool' }
    }
    $ossl = Get-Command osslsigncode -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $ossl -and -not [string]::IsNullOrEmpty($ossl.Source)) {
        return [PSCustomObject]@{ Path = [string]$ossl.Source; Kind = 'osslsigncode' }
    }
    return $null
}

function Test-RcbSignableArtifact {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $ext = [System.IO.Path]::GetExtension($Path)
    return ($ext -match '^\.(exe|dll|sys|ocx)$')
}

function Invoke-RcbSignOneFile {
    param(
        $Settings,
        [string]$FilePath,
        [scriptblock]$Log = $null
    )
    $say = {
        param($m, $r)
        if ($null -ne $Log) { & $Log $m $r }
    }
    if ($null -eq $Settings.Tool) {
        return [PSCustomObject]@{ File = $FilePath; Status = 'SIGN FAILED'; Error = 'signtool was not found' }
    }
    $hasThumb = -not [string]::IsNullOrWhiteSpace($Settings.CertThumbprint)
    $hasPfx = -not [string]::IsNullOrWhiteSpace($Settings.PfxPath)
    if (-not $hasThumb -and -not $hasPfx) {
        return [PSCustomObject]@{ File = $FilePath; Status = 'SIGN FAILED'; Error = 'no certificate: set -CertThumbprint or -PfxPath (PFX password: RCB_SIGN_PFX_PASSWORD)' }
    }
    if ($hasPfx -and -not (Test-Path -LiteralPath $Settings.PfxPath -PathType Leaf)) {
        return [PSCustomObject]@{ File = $FilePath; Status = 'SIGN FAILED'; Error = "PFX file not found: $($Settings.PfxPath)" }
    }
    $pfxPass = $env:RCB_SIGN_PFX_PASSWORD
    if ($hasPfx -and [string]::IsNullOrEmpty($pfxPass)) {
        return [PSCustomObject]@{ File = $FilePath; Status = 'SIGN FAILED'; Error = 'PFX signing requires env RCB_SIGN_PFX_PASSWORD' }
    }

    $tool = [string]$Settings.Tool
    $kind = [string]$Settings.ToolKind
    $args = New-Object System.Collections.Generic.List[string]
    $outFile = $null
    if ($kind -eq 'osslsigncode') {
        $outFile = $FilePath + '.signed-tmp'
        $args.Add('sign')
        if ($hasPfx) {
            $args.Add('-pkcs12'); $args.Add($Settings.PfxPath)
            $args.Add('-pass'); $args.Add($pfxPass)
        } else {
            return [PSCustomObject]@{ File = $FilePath; Status = 'SIGN FAILED'; Error = 'osslsigncode signing requires -PfxPath' }
        }
        $args.Add('-h'); $args.Add('sha256')
        if (-not [string]::IsNullOrWhiteSpace($Settings.TimestampUrl)) {
            $args.Add('-ts'); $args.Add($Settings.TimestampUrl)
        }
        $args.Add('-in'); $args.Add($FilePath)
        $args.Add('-out'); $args.Add($outFile)
    } else {
        $args.Add('sign')
        $args.Add('/fd'); $args.Add('SHA256')
        if (-not [string]::IsNullOrWhiteSpace($Settings.TimestampUrl)) {
            $args.Add('/tr'); $args.Add($Settings.TimestampUrl)
            $args.Add('/td'); $args.Add('SHA256')
        }
        if ($hasThumb) {
            $args.Add('/sha1'); $args.Add($Settings.CertThumbprint)
        } else {
            $args.Add('/f'); $args.Add($Settings.PfxPath)
            $args.Add('/p'); $args.Add($pfxPass)
        }
        $args.Add($FilePath)
    }

    & $say ("  sign: " + (Get-RcbRedactedSignArgs -ArgumentList $args.ToArray())) 'muted'
    $run = Invoke-ToolProcess -FilePath $tool -ArgumentList $args.ToArray() -TimeoutSec 120
    if ($run.ExitCode -ne 0) {
        $err = $run.StdErr
        if ([string]::IsNullOrWhiteSpace($err)) { $err = $run.StdOut }
        if ([string]::IsNullOrWhiteSpace($err)) { $err = "sign tool exited $($run.ExitCode)" }
        if (-not [string]::IsNullOrEmpty($pfxPass)) { $err = $err.Replace($pfxPass, '<redacted>') }
        if ($outFile -and (Test-Path -LiteralPath $outFile)) { Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue }
        return [PSCustomObject]@{ File = $FilePath; Status = 'SIGN FAILED'; Error = $err.Trim() }
    }
    if ($outFile) {
        try {
            [System.IO.File]::Copy($outFile, $FilePath, $true)
            Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
        } catch {
            return [PSCustomObject]@{ File = $FilePath; Status = 'SIGN FAILED'; Error = $_.Exception.Message }
        }
    }

    $vArgs = New-Object System.Collections.Generic.List[string]
    if ($kind -eq 'osslsigncode') {
        $vArgs.Add('verify'); $vArgs.Add('-in'); $vArgs.Add($FilePath)
    } else {
        $vArgs.Add('verify'); $vArgs.Add('/pa'); $vArgs.Add($FilePath)
    }
    $ver = Invoke-ToolProcess -FilePath $tool -ArgumentList $vArgs.ToArray() -TimeoutSec 60
    if ($ver.ExitCode -ne 0) {
        $err = $ver.StdErr
        if ([string]::IsNullOrWhiteSpace($err)) { $err = $ver.StdOut }
        if ([string]::IsNullOrWhiteSpace($err)) { $err = "signtool verify /pa failed (exit $($ver.ExitCode))" }
        if (-not [string]::IsNullOrEmpty($pfxPass)) { $err = $err.Replace($pfxPass, '<redacted>') }
        return [PSCustomObject]@{ File = $FilePath; Status = 'SIGN FAILED'; Error = $err.Trim() }
    }
    return [PSCustomObject]@{ File = $FilePath; Status = 'signed'; Error = $null }
}

<#
.SYNOPSIS
    Signs every .exe/.dll collected under a project's _built folder.
    Missing tool or cert is a clear error; the build result is left alone.
#>
function Invoke-RcbSignBuiltFolder {
    param(
        [string]$Folder,
        $Settings,
        [scriptblock]$Log = $null,
        [scriptblock]$OnFile = $null
    )
    $results = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Settings -or -not $Settings.Enabled) { return @() }
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { return @() }
    $files = @()
    try {
        $files = @(Get-ChildItem -LiteralPath $Folder -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { Test-RcbSignableArtifact -Path $_.FullName })
    } catch { $files = @() }
    if ($files.Count -eq 0) { return @() }
    foreach ($f in $files) {
        $one = Invoke-RcbSignOneFile -Settings $Settings -FilePath $f.FullName -Log $Log
        $results.Add($one)
        if ($null -ne $OnFile) { try { & $OnFile $one } catch { $null = $_ } }
        if ($null -ne $Log) {
            if ($one.Status -eq 'signed') { & $Log "  sign: signed $($f.Name)" 'success' }
            else { & $Log "  sign: SIGN FAILED $($f.Name): $($one.Error)" 'danger' }
        }
    }
    return $results.ToArray()
}

function Get-RcbSignSummary {
    param($Results)
    $all = @($Results)
    if ($all.Count -eq 0) { return 'skipped' }
    $failed = @($all | Where-Object { $_.Status -ne 'signed' })
    if ($failed.Count -gt 0) { return 'SIGN FAILED' }
    return 'signed'
}
