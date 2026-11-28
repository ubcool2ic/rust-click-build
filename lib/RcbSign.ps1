# Optional Authenticode signing of collected _built artifacts.
# The PFX password is read only from $env:RCB_SIGN_PFX_PASSWORD. It is never
# logged, never committed, never put on a child command line, and never stored
# in rcb.sign.json. On Windows a PFX is loaded in-process and signed with
# /sha1 after a temporary CurrentUser\My import (removed in finally). For
# osslsigncode the password is written to a 0600 temp file passed as -readpass
# and that file is deleted in finally.

# DigiCert's RFC 3161 TSA is HTTP-only (port 80). https://timestamp.digicert.com
# does not serve the protocol (connection refused / timed out); DigiCert's
# documented URL is http://timestamp.digicert.com. A non-HTTPS URL still warns.
$script:RcbDefaultTimestampUrl = 'http://timestamp.digicert.com'
$script:RcbTempPfxFriendlyName = 'rcb-temp-sign'
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
    Merges CLI / GUI signing options with rcb.sign.json defaults (thumbprint,
    PFX path, timestamp URL). Signing is enabled only by -Sign / the GUI
    toggle; a "sign": true field in the file cannot turn it on. Password is
    never taken from the file.
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
    # Config supplies defaults only. -Sign / the GUI "Sign output" toggle is
    # the only way to enable signing, so a toggle-off (or a CLI run without
    # -Sign) always wins over rcb.sign.json.
    $enabled = [bool]$SignFlag
    $thumb = $CertThumbprint
    if ([string]::IsNullOrWhiteSpace($thumb) -and $null -ne $cfg) { $thumb = [string]$cfg.certThumbprint }
    $pfx = $PfxPath
    if ([string]::IsNullOrWhiteSpace($pfx) -and $null -ne $cfg) { $pfx = [string]$cfg.pfxPath }
    $ts = $TimestampUrl
    if ([string]::IsNullOrWhiteSpace($ts) -and $null -ne $cfg) { $ts = [string]$cfg.timestampUrl }
    if ([string]::IsNullOrWhiteSpace($ts)) { $ts = $script:RcbDefaultTimestampUrl }
    $normThumb = Get-RcbNormalizedThumbprint -Value $thumb
    $thumbError = $null
    if (-not [string]::IsNullOrWhiteSpace($thumb) -and $null -eq $normThumb) {
        $thumbError = 'certificate thumbprint must be 40 hexadecimal characters'
    } elseif (-not [string]::IsNullOrWhiteSpace($normThumb)) {
        $thumb = $normThumb
    }
    $ts = ([string]$ts).Trim()
    $tsWarn = (-not [string]::IsNullOrWhiteSpace($ts) -and $ts -notmatch '^[Hh][Tt][Tt][Pp][Ss]://')
    return [PSCustomObject]@{
        Enabled        = [bool]$enabled
        CertThumbprint = ([string]$thumb).Trim()
        PfxPath        = ([string]$pfx).Trim()
        TimestampUrl   = $ts
        TimestampHttpWarning = [bool]$tsWarn
        ConfigPath     = $cfgPath
        Tool           = $null
        ToolKind       = $null
        Error          = $thumbError
    }
}

function Get-RcbNormalizedThumbprint {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $hex = ([string]$Value).Trim() -replace '[\s:]',''
    if ($hex -notmatch '^[0-9A-Fa-f]{40}$') { return $null }
    return $hex.ToUpperInvariant()
}

function Test-RcbCertThumbprint {
    param([string]$Value)
    $n = Get-RcbNormalizedThumbprint -Value $Value
    return (-not [string]::IsNullOrWhiteSpace($n))
}

function Get-RcbTempPfxFriendlyName { return [string]$script:RcbTempPfxFriendlyName }

<#
.SYNOPSIS
    Adds a certificate to a store, tags it rcb-temp-sign, and runs an optional
    after-add hook so a later throw can be undone by Undo-RcbPfxStoreAdd.
#>
function Invoke-RcbPfxStoreAdd {
    param($Store, $Cert)
    if ($null -eq $Store -or $null -eq $Cert) { throw 'Invoke-RcbPfxStoreAdd requires a store and a certificate' }
    try { $Cert.FriendlyName = (Get-RcbTempPfxFriendlyName) } catch { $null = $_ }
    $Store.Add($Cert)
    if ($null -ne $script:RcbPfxAfterAddHook) { & $script:RcbPfxAfterAddHook $Store $Cert }
}

function Undo-RcbPfxStoreAdd {
    param($Store, $Cert)
    if ($null -eq $Store -or $null -eq $Cert) { return }
    try { $Store.Remove($Cert) } catch { $null = $_ }
}

<#
.SYNOPSIS
    Removes leftover rcb-sign-*.pass files from the temp directory and, on
    Windows, any CurrentUser\My certificates tagged FriendlyName rcb-temp-sign.
#>
function Clear-RcbSignLeftovers {
    $dir = [System.IO.Path]::GetTempPath()
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'rcb-sign-*.pass' -File -ErrorAction SilentlyContinue)) {
            try { [System.IO.File]::WriteAllBytes($f.FullName, [byte[]]@()) } catch { $null = $_ }
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue } catch { $null = $_ }
        }
    } catch { $null = $_ }
    $isWin = ($script:IsWindowsOS -or $env:OS -eq 'Windows_NT')
    if (-not $isWin) { return }
    $store = $null
    try {
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', 'CurrentUser')
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $name = Get-RcbTempPfxFriendlyName
        $toRemove = @($store.Certificates | Where-Object { [string]$_.FriendlyName -eq $name })
        foreach ($c in $toRemove) {
            try { $store.Remove($c) } catch { $null = $_ }
            try { $c.Dispose() } catch { $null = $_ }
        }
    } catch { $null = $_ }
    finally {
        if ($null -ne $store) { try { $store.Close() } catch { $null = $_ } }
    }
}

<#
.SYNOPSIS
    Creates a temp rcb-sign-*.pass file with mode 0600 (UnixCreateMode) before
    any bytes are written, so there is no 0644 window.
#>
function New-RcbSecurePassFile {
    param([string]$Contents)
    $dir = [System.IO.Path]::GetTempPath()
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    $bytes = $utf8NoBom.GetBytes([string]$Contents)
    $isWin = ($script:IsWindowsOS -or $env:OS -eq 'Windows_NT')
    $last = $null
    for ($i = 0; $i -lt 8; $i++) {
        $path = [System.IO.Path]::Combine($dir, ('rcb-sign-' + [guid]::NewGuid().ToString('N') + '.pass'))
        $fs = $null
        try {
            $opts = New-Object System.IO.FileStreamOptions
            $opts.Mode = [System.IO.FileMode]::CreateNew
            $opts.Access = [System.IO.FileAccess]::Write
            $opts.Share = [System.IO.FileShare]::None
            if (-not $isWin) {
                $opts.UnixCreateMode = [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite
            }
            $fs = [System.IO.FileStream]::new($path, $opts)
            if ($bytes.Length -gt 0) { $fs.Write($bytes, 0, $bytes.Length) }
            $fs.Flush()
            return $path
        } catch {
            $last = $_
            if (-not [string]::IsNullOrEmpty($path) -and (Test-Path -LiteralPath $path)) {
                try { [System.IO.File]::WriteAllBytes($path, [byte[]]@()) } catch { $null = $_ }
                try { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } catch { $null = $_ }
            }
        } finally {
            if ($null -ne $fs) { try { $fs.Dispose() } catch { $null = $_ } }
        }
    }
    $msg = if ($null -ne $last) { $last.Exception.Message } else { 'could not create a 0600 pass file' }
    throw $msg
}

function Import-RcbPfxCertificate {
    param([string]$PfxPath, [string]$Password)
    $result = [PSCustomObject]@{
        Thumbprint  = $null
        Temporary   = $false
        Store       = $null
        Certificate = $null
        Error       = $null
    }
    if ($null -ne $script:RcbPfxImportHook) {
        return & $script:RcbPfxImportHook $PfxPath $Password
    }
    $isWin = ($script:IsWindowsOS -or $env:OS -eq 'Windows_NT')
    if (-not $isWin) {
        $result.Error = 'PFX signing with signtool requires Windows so the certificate can be imported into CurrentUser\My and used with /sha1 (the password is never passed on the command line).'
        return $result
    }
    $store = $null
    $cert = $null
    $added = $false
    try {
        $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet
        try {
            # PersistKeySet is required so signtool can find the private key.
            # EphemeralKeySet keeps the key out of disk, but signtool cannot
            # see an in-process-only key, so a temporary store import is used.
            $flags = $flags -bor [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet
        } catch { $null = $_ }
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($PfxPath, $Password, $flags)
        $thumb = [string]$cert.Thumbprint
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', 'CurrentUser')
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $existing = $store.Certificates.Find([System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint, $thumb, $false)
        $temporary = $false
        if ($existing.Count -eq 0) {
            Invoke-RcbPfxStoreAdd -Store $store -Cert $cert
            $added = $true
            $temporary = $true
        }
        $result.Thumbprint = $thumb
        $result.Temporary = $temporary
        $result.Store = $store
        $result.Certificate = $cert
        return $result
    } catch {
        if ($added) {
            Undo-RcbPfxStoreAdd -Store $store -Cert $cert
            $added = $false
        }
        if ($null -ne $store) { try { $store.Close() } catch { $null = $_ }; $store = $null }
        if ($null -ne $cert) { try { $cert.Dispose() } catch { $null = $_ }; $cert = $null }
        $msg = $_.Exception.Message
        if (-not [string]::IsNullOrEmpty($Password)) { $msg = $msg.Replace($Password, '<redacted>') }
        $result.Error = $msg
        $result.Store = $null
        $result.Certificate = $null
        $result.Temporary = $false
        return $result
    }
}

function Remove-RcbTemporaryPfxCertificate {
    param($Import)
    if ($null -eq $Import) { return }
    try {
        if ($Import.Temporary -and $null -ne $Import.Store -and $null -ne $Import.Certificate) {
            try { $Import.Store.Remove($Import.Certificate) } catch { $null = $_ }
        }
    } finally {
        if ($null -ne $Import.Store) {
            try { $Import.Store.Close() } catch { $null = $_ }
        }
        if ($null -ne $Import.Certificate) {
            try { $Import.Certificate.Dispose() } catch { $null = $_ }
        }
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
    if ($hasThumb) {
        $norm = Get-RcbNormalizedThumbprint -Value $Settings.CertThumbprint
        if ([string]::IsNullOrWhiteSpace($norm)) {
            return [PSCustomObject]@{ File = $FilePath; Status = 'SIGN FAILED'; Error = 'certificate thumbprint must be 40 hexadecimal characters' }
        }
        $Settings.CertThumbprint = $norm
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
    $passFile = $null
    $imported = $null
    try {
        if ($kind -eq 'osslsigncode') {
            $outFile = $FilePath + '.signed-tmp'
            $args.Add('sign')
            if ($hasPfx) {
                $passFile = New-RcbSecurePassFile -Contents $pfxPass
                $args.Add('-pkcs12'); $args.Add($Settings.PfxPath)
                $args.Add('-readpass'); $args.Add($passFile)
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
            $sha1 = $null
            if ($hasThumb) {
                $sha1 = $Settings.CertThumbprint
            } elseif ($hasPfx) {
                $imported = Import-RcbPfxCertificate -PfxPath $Settings.PfxPath -Password $pfxPass
                if ([string]::IsNullOrWhiteSpace($imported.Thumbprint)) {
                    $err = $imported.Error
                    if ([string]::IsNullOrWhiteSpace($err)) { $err = 'could not import the PFX certificate' }
                    return [PSCustomObject]@{ File = $FilePath; Status = 'SIGN FAILED'; Error = $err }
                }
                $sha1 = $imported.Thumbprint
            }
            $args.Add('sign')
            $args.Add('/fd'); $args.Add('SHA256')
            if (-not [string]::IsNullOrWhiteSpace($Settings.TimestampUrl)) {
                $args.Add('/tr'); $args.Add($Settings.TimestampUrl)
                $args.Add('/td'); $args.Add('SHA256')
            }
            $args.Add('/sha1'); $args.Add($sha1)
            $args.Add($FilePath)
        }

        & $say ("  sign: " + (Get-RcbRedactedSignArgs -ArgumentList $args.ToArray())) 'muted'
        $run = Invoke-ToolProcess -FilePath $tool -ArgumentList $args.ToArray() -TimeoutSec 120 -RemoveEnvironment @('RCB_SIGN_PFX_PASSWORD')
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
                $msg = $_.Exception.Message
                if (-not [string]::IsNullOrEmpty($pfxPass)) { $msg = $msg.Replace($pfxPass, '<redacted>') }
                return [PSCustomObject]@{ File = $FilePath; Status = 'SIGN FAILED'; Error = $msg }
            }
        }

        $vArgs = New-Object System.Collections.Generic.List[string]
        if ($kind -eq 'osslsigncode') {
            $vArgs.Add('verify'); $vArgs.Add('-in'); $vArgs.Add($FilePath)
        } else {
            $vArgs.Add('verify'); $vArgs.Add('/pa'); $vArgs.Add($FilePath)
        }
        $ver = Invoke-ToolProcess -FilePath $tool -ArgumentList $vArgs.ToArray() -TimeoutSec 60 -RemoveEnvironment @('RCB_SIGN_PFX_PASSWORD')
        if ($ver.ExitCode -ne 0) {
            $err = $ver.StdErr
            if ([string]::IsNullOrWhiteSpace($err)) { $err = $ver.StdOut }
            if ([string]::IsNullOrWhiteSpace($err)) { $err = "signtool verify /pa failed (exit $($ver.ExitCode))" }
            if (-not [string]::IsNullOrEmpty($pfxPass)) { $err = $err.Replace($pfxPass, '<redacted>') }
            return [PSCustomObject]@{ File = $FilePath; Status = 'SIGN FAILED'; Error = $err.Trim() }
        }
        return [PSCustomObject]@{ File = $FilePath; Status = 'signed'; Error = $null }
    } finally {
        if (-not [string]::IsNullOrEmpty($passFile) -and (Test-Path -LiteralPath $passFile)) {
            try { [System.IO.File]::WriteAllBytes($passFile, [byte[]]@()) } catch { $null = $_ }
            try { Remove-Item -LiteralPath $passFile -Force -ErrorAction SilentlyContinue } catch { $null = $_ }
        }
        Remove-RcbTemporaryPfxCertificate -Import $imported
    }
}

<#
.SYNOPSIS
    Signs every .exe/.dll collected under a project's _built folder.
    Missing tool or cert is a clear error; a SIGN FAILED artifact fails the run.
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
    Clear-RcbSignLeftovers
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
