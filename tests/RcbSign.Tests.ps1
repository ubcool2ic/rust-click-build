#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Optional Authenticode signing: mocked signtool, config, GUI wiring.

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $prevMain = $env:RCB_NO_MAIN
    $env:RCB_NO_MAIN = '1'
    . (Join-Path $script:Root (Join-Path 'lib' 'BuildCore.ps1'))
    . (Join-Path $script:Root (Join-Path 'lib' 'RcbSign.ps1'))
    . (Join-Path $script:Root 'build.ps1')
    if ($null -eq $prevMain) { Remove-Item Env:\RCB_NO_MAIN -ErrorAction SilentlyContinue } else { $env:RCB_NO_MAIN = $prevMain }

    function New-FakeSignTool {
        param([string]$Dir, [int]$SignExit = 0, [int]$VerifyExit = 0)
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $tool = Join-Path $Dir 'signtool'
        $log = Join-Path $Dir 'argv.log'
        $script = @"
#!/usr/bin/env bash
log_path="`${RCB_SIGNTOOL_LOG:-}"
if [ -n "`$log_path" ]; then
  printf '%s\n' "`$*" >> "`$log_path" || true
fi
if [ "`$1" = "verify" ]; then
  exit `${RCB_SIGNTOOL_VERIFY_EXIT:-$VerifyExit}
fi
exit `${RCB_SIGNTOOL_SIGN_EXIT:-$SignExit}
"@
        [System.IO.File]::WriteAllText($tool, $script.Replace("`r", ""))
        if (-not $IsWindows) { & /bin/chmod +x $tool }
        return [PSCustomObject]@{ Path = $tool; Log = $log }
    }
}

Describe 'Get-RcbSignSettings' {
    It 'is off by default even when a thumbprint is supplied' {
        $s = Get-RcbSignSettings -SignFlag $false -CertThumbprint 'AABBCC'
        $s.Enabled | Should -BeFalse
        $s.CertThumbprint | Should -Be 'AABBCC'
        $s.TimestampUrl | Should -Be 'http://timestamp.digicert.com'
    }

    It 'loads defaults from rcb.sign.json and lets the CLI win' {
        $dir = Join-Path $TestDrive 'cfg'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $cfg = Join-Path $dir 'rcb.sign.json'
        Set-Content -LiteralPath $cfg -Value '{"sign":true,"certThumbprint":"FROMFILE","pfxPath":"file.pfx","timestampUrl":"http://from-file","password":"SHOULD-NEVER-BE-USED"}'
        $s = Get-RcbSignSettings -SignFlag $false -ProjectFolder $dir
        $s.Enabled | Should -BeTrue
        $s.CertThumbprint | Should -Be 'FROMFILE'
        $s.PfxPath | Should -Be 'file.pfx'
        $s.TimestampUrl | Should -Be 'http://from-file'
        $s.PSObject.Properties.Name | Should -Not -Contain 'Password'
        $json = Get-Content -Raw -LiteralPath $cfg
        # The helper must not copy a password field onto the settings object.
        ($s | ConvertTo-Json -Compress) | Should -Not -Match 'SHOULD-NEVER-BE-USED'

        $cli = Get-RcbSignSettings -SignFlag $true -CertThumbprint 'CLITHUMB' -PfxPath 'cli.pfx' -TimestampUrl 'http://cli' -SignConfigPath $cfg
        $cli.CertThumbprint | Should -Be 'CLITHUMB'
        $cli.PfxPath | Should -Be 'cli.pfx'
        $cli.TimestampUrl | Should -Be 'http://cli'
        ($cli | ConvertTo-Json -Compress) | Should -Not -Match 'SHOULD-NEVER-BE-USED'
        $json | Should -Match 'SHOULD-NEVER-BE-USED' # file itself is unchanged
    }

    It 'throws a clear error for unreadable JSON' {
        $bad = Join-Path $TestDrive 'bad.sign.json'
        Set-Content -LiteralPath $bad -Value '{not json'
        { Get-RcbSignSettings -SignFlag $true -SignConfigPath $bad } | Should -Throw -ExceptionType ([System.Exception])
    }
}

Describe 'Get-RcbRedactedSignArgs' {
    It 'replaces the /p value and never echoes the password' {
        $shown = Get-RcbRedactedSignArgs -ArgumentList @('sign','/fd','SHA256','/f','dev.pfx','/p','s3cret-value','app.exe')
        $shown | Should -Match '/p <redacted>'
        $shown | Should -Not -Match 's3cret-value'
        $shown | Should -Match 'app.exe'
    }
}

Describe 'Find-RcbSignTool' {
    It 'prefers RCB_SIGNTOOL when that path exists' {
        $fake = New-FakeSignTool -Dir (Join-Path $TestDrive 'find-tool')
        $prev = $env:RCB_SIGNTOOL
        $env:RCB_SIGNTOOL = $fake.Path
        try {
            $t = Find-RcbSignTool
            $t.Path | Should -Be $fake.Path
            $t.Kind | Should -Be 'signtool'
        } finally {
            if ($null -eq $prev) { Remove-Item Env:\RCB_SIGNTOOL -ErrorAction SilentlyContinue } else { $env:RCB_SIGNTOOL = $prev }
        }
    }

    It 'returns null when signtool is missing' {
        $prevTool = $env:RCB_SIGNTOOL
        $prevPath = $env:PATH
        $env:RCB_SIGNTOOL = ''
        Remove-Item Env:\RCB_SIGNTOOL -ErrorAction SilentlyContinue
        $env:PATH = '/tmp/rcb-empty-path-no-tools'
        try {
            Find-RcbSignTool | Should -Be $null
        } finally {
            $env:PATH = $prevPath
            if ($null -eq $prevTool) { Remove-Item Env:\RCB_SIGNTOOL -ErrorAction SilentlyContinue } else { $env:RCB_SIGNTOOL = $prevTool }
        }
    }
}

Describe 'Invoke-RcbSignOneFile with a mocked signtool' {
    BeforeEach {
        $script:FakeDir = Join-Path $TestDrive ("mock-" + [guid]::NewGuid().ToString('N'))
        $script:Fake = New-FakeSignTool -Dir $script:FakeDir
        $env:RCB_SIGNTOOL = $script:Fake.Path
        $env:RCB_SIGNTOOL_LOG = $script:Fake.Log
        $script:Artifact = Join-Path $script:FakeDir 'app.exe'
        Set-Content -LiteralPath $script:Artifact -Value 'fake-pe'
    }
    AfterEach {
        Remove-Item Env:\RCB_SIGNTOOL -ErrorAction SilentlyContinue
        Remove-Item Env:\RCB_SIGNTOOL_LOG -ErrorAction SilentlyContinue
        Remove-Item Env:\RCB_SIGN_PFX_PASSWORD -ErrorAction SilentlyContinue
        Remove-Item Env:\RCB_SIGNTOOL_SIGN_EXIT -ErrorAction SilentlyContinue
        Remove-Item Env:\RCB_SIGNTOOL_VERIFY_EXIT -ErrorAction SilentlyContinue
    }

    It 'passes /fd SHA256, /tr, /td SHA256 and /sha1 then verifies with /pa' {
        $settings = Get-RcbSignSettings -SignFlag $true -CertThumbprint 'DEADBEEFCAFE' -TimestampUrl 'http://timestamp.digicert.com'
        $tool = Find-RcbSignTool
        $settings.Tool = $tool.Path
        $settings.ToolKind = $tool.Kind
        $logs = New-Object System.Collections.Generic.List[string]
        $r = Invoke-RcbSignOneFile -Settings $settings -FilePath $script:Artifact -Log { param($m,$role) $logs.Add($m) }
        $r.Status | Should -Be 'signed'
        $argv = Get-Content -Raw -LiteralPath $script:Fake.Log
        $argv | Should -Match 'sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /sha1 DEADBEEFCAFE'
        $argv | Should -Match 'verify /pa'
        ($logs -join "`n") | Should -Not -Match 'RCB_SIGN_PFX_PASSWORD'
    }

    It 'passes /f and a redacted /p for a PFX, and refuses to log the password' {
        $pfx = Join-Path $script:FakeDir 'dev.pfx'
        Set-Content -LiteralPath $pfx -Value 'pfx-bytes'
        $env:RCB_SIGN_PFX_PASSWORD = 'super-secret-pass'
        $settings = Get-RcbSignSettings -SignFlag $true -PfxPath $pfx
        $tool = Find-RcbSignTool
        $settings.Tool = $tool.Path
        $settings.ToolKind = $tool.Kind
        $logs = New-Object System.Collections.Generic.List[string]
        $r = Invoke-RcbSignOneFile -Settings $settings -FilePath $script:Artifact -Log { param($m,$role) $logs.Add($m) }
        $r.Status | Should -Be 'signed'
        $argv = Get-Content -Raw -LiteralPath $script:Fake.Log
        $pattern = [regex]::Escape("/f $pfx /p super-secret-pass"); $argv | Should -Match $pattern
        $joined = $logs -join "`n"
        $joined | Should -Match '/p <redacted>'
        $joined | Should -Not -Match 'super-secret-pass'
    }

    It 'fails clearly when the PFX password env var is missing' {
        $pfx = Join-Path $script:FakeDir 'dev.pfx'
        Set-Content -LiteralPath $pfx -Value 'pfx-bytes'
        Remove-Item Env:\RCB_SIGN_PFX_PASSWORD -ErrorAction SilentlyContinue
        $settings = Get-RcbSignSettings -SignFlag $true -PfxPath $pfx
        $tool = Find-RcbSignTool
        $settings.Tool = $tool.Path
        $settings.ToolKind = $tool.Kind
        $r = Invoke-RcbSignOneFile -Settings $settings -FilePath $script:Artifact
        $r.Status | Should -Be 'SIGN FAILED'
        $r.Error | Should -Match 'RCB_SIGN_PFX_PASSWORD'
    }

    It 'fails clearly when neither a thumbprint nor a PFX is given' {
        $settings = Get-RcbSignSettings -SignFlag $true
        $settings.Tool = $script:Fake.Path
        $settings.ToolKind = 'signtool'
        $r = Invoke-RcbSignOneFile -Settings $settings -FilePath $script:Artifact
        $r.Status | Should -Be 'SIGN FAILED'
        $r.Error | Should -Match 'CertThumbprint|PfxPath'
    }

    It 'reports SIGN FAILED when the sign tool exits non-zero' {
        $env:RCB_SIGNTOOL_SIGN_EXIT = '1'
        # The mock reads its own exit defaults at start time, so rewrite with exit 1.
        $script:Fake = New-FakeSignTool -Dir $script:FakeDir -SignExit 1
        $env:RCB_SIGNTOOL = $script:Fake.Path
        $settings = Get-RcbSignSettings -SignFlag $true -CertThumbprint 'THUMB'
        $tool = Find-RcbSignTool
        $settings.Tool = $tool.Path
        $settings.ToolKind = $tool.Kind
        $r = Invoke-RcbSignOneFile -Settings $settings -FilePath $script:Artifact
        $r.Status | Should -Be 'SIGN FAILED'
        $r.Error | Should -Not -BeNullOrEmpty
    }

    It 'reports SIGN FAILED when verify /pa fails after a successful sign' {
        $script:Fake = New-FakeSignTool -Dir $script:FakeDir -SignExit 0 -VerifyExit 2
        $env:RCB_SIGNTOOL = $script:Fake.Path
        $settings = Get-RcbSignSettings -SignFlag $true -CertThumbprint 'THUMB'
        $tool = Find-RcbSignTool
        $settings.Tool = $tool.Path
        $settings.ToolKind = $tool.Kind
        $r = Invoke-RcbSignOneFile -Settings $settings -FilePath $script:Artifact
        $r.Status | Should -Be 'SIGN FAILED'
        $r.Error | Should -Match 'verify'
    }

    It 'reports SIGN FAILED when the tool is missing, and Get-RcbSignSummary rolls that up' {
        $settings = Get-RcbSignSettings -SignFlag $true -CertThumbprint 'THUMB'
        $settings.Tool = $null
        $r = Invoke-RcbSignOneFile -Settings $settings -FilePath $script:Artifact
        $r.Status | Should -Be 'SIGN FAILED'
        $r.Error | Should -Match 'signtool'
        Get-RcbSignSummary -Results @($r) | Should -Be 'SIGN FAILED'
        Get-RcbSignSummary -Results @() | Should -Be 'skipped'
    }
}

Describe 'pipeline still PASSes when signing fails' {
    It 'leaves the build result alone and records SIGN FAILED on the row' -Skip:($IsWindows -or $env:OS -eq 'Windows_NT') {
        $dir = Join-Path $TestDrive 'sign-pass-build'
        New-Item -ItemType Directory -Path (Join-Path $dir 'src') | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'Cargo.toml') -Value "[package]`nname = `"signme`"`nversion = `"0.1.0`"`nedition = `"2021`"`n"
        Set-Content -LiteralPath (Join-Path $dir 'src/main.rs') -Value 'fn main() {}'
        $binDir = Join-Path $dir 'target/release'
        New-Item -ItemType Directory -Path $binDir | Out-Null
        Set-Content -LiteralPath (Join-Path $binDir 'signme.exe') -Value 'MZ-fake'

        $shim = Join-Path $TestDrive 'sign-cargo-shim'
        New-Item -ItemType Directory -Path $shim | Out-Null
        $cargo = Join-Path $shim 'cargo'
        $metaJson = @{
            packages = @(@{ name = 'signme'; targets = @(@{ name = 'signme'; kind = @('bin') }) })
            target_directory = (Join-Path $dir 'target')
            version = 1
        } | ConvertTo-Json -Compress -Depth 6
        $metaFile = Join-Path $shim 'meta.json'
        [System.IO.File]::WriteAllText($metaFile, $metaJson)
        $bash = "#!/usr/bin/env bash`ncase `"`$1`" in`n  metadata) cat '$metaFile'; exit 0 ;;`n  build) echo Finished; exit 0 ;;`n  *) exit 0 ;;`nesac`n"
        [System.IO.File]::WriteAllText($cargo, $bash)
        & /bin/chmod +x $cargo

        $saved = $env:PATH
        $prevTool = $env:RCB_SIGNTOOL
        $env:PATH = $shim + [System.IO.Path]::PathSeparator + $env:PATH
        Remove-Item Env:\RCB_SIGNTOOL -ErrorAction SilentlyContinue
        try {
            $res = Start-BuildPipeline -TargetFolder $dir -ActiveProfile 'release' -RunTests $false -NoInstallFlag $true -NoOpenFlag $true -NoRtkUpdateFlag $true -SignFlag $true -CertThumbprint 'DEADBEEF'
            $res.Success | Should -BeTrue
            $res.Results[0].BuildStatus | Should -Be 'PASS'
            $res.Results[0].Sign | Should -Be 'SIGN FAILED'
            Test-Path -LiteralPath (Join-Path $dir '_built/sign-pass-build/signme.exe') | Should -BeTrue
        } finally {
            $env:PATH = $saved
            if ($null -eq $prevTool) { Remove-Item Env:\RCB_SIGNTOOL -ErrorAction SilentlyContinue } else { $env:RCB_SIGNTOOL = $prevTool }
        }
    }
}

Describe 'GUI and command-line wiring' {
    It 'forwards -Sign and cert/PFX fields from build.ps1 to rcb-gui' {
        $src = Get-Content -Raw -LiteralPath (Join-Path $script:Root 'build.ps1')
        $src | Should -Match '\[switch\]\$Sign'
        $src | Should -Match '\$guiArgs \+= ''--sign'''
        $src | Should -Match '--cert-thumbprint'
        $src | Should -Match '--pfx-path'
        $src | Should -Match 'RCB_SIGN_PFX_PASSWORD'
        $src | Should -Not -Match '\$guiArgs \+=.*password'
    }

    It 'parses sign switches in the rtk GUI and forwards them to build.ps1' {
        $argsRs = Get-Content -Raw -LiteralPath (Join-Path $script:Root (Join-Path 'gui' (Join-Path 'src' 'args.rs')))
        $argsRs | Should -Match '"--sign"'
        $argsRs | Should -Match '"--cert-thumbprint"'
        $argsRs | Should -Match '"--pfx-path"'
        $runner = Get-Content -Raw -LiteralPath (Join-Path $script:Root (Join-Path 'gui' (Join-Path 'src' 'runner.rs')))
        $runner | Should -Match '"-Sign"'
        $runner | Should -Match '"-CertThumbprint"'
        $runner | Should -Match '"-PfxPath"'
        $ui = Get-Content -Raw -LiteralPath (Join-Path $script:Root (Join-Path 'gui' (Join-Path 'src' 'ui.rs')))
        $ui | Should -Match 'Sign output'
        $ui | Should -Match 'thumb_entry'
        $ui | Should -Match '"Sign"'
        $gitignore = Get-Content -Raw -LiteralPath (Join-Path $script:Root '.gitignore')
        $gitignore | Should -Match 'rcb.sign.json'
        $gitignore | Should -Match '\*\.pfx'
    }
}

Describe 'real signing with osslsigncode' {
    It 'signs a throwaway PE with a temp self-signed cert and deletes the cert afterwards' {
        $ossl = Get-Command osslsigncode -ErrorAction SilentlyContinue
        $openssl = Get-Command openssl -ErrorAction SilentlyContinue
        if ($null -eq $ossl -or $null -eq $openssl) {
            Set-ItResult -Skipped -Because "osslsigncode or openssl is not installed on this box"
            return
        }
        $tmp = Join-Path $TestDrive 'ossl-real'
        New-Item -ItemType Directory -Path $tmp | Out-Null
        $key = Join-Path $tmp 'dev.key'
        $cer = Join-Path $tmp 'dev.cer'
        $pfx = Join-Path $tmp 'dev.pfx'
        $pe = Join-Path $tmp 'app.exe'
        $pass = 'tmp-ossl-' + [guid]::NewGuid().ToString('N')
        try {
            & openssl req -x509 -newkey rsa:2048 -keyout $key -out $cer -days 1 -nodes -subj '/CN=RCB Test Signer' 2>$null
            $LASTEXITCODE | Should -Be 0
            & openssl pkcs12 -export -out $pfx -inkey $key -in $cer -passout "pass:$pass" 2>$null
            $LASTEXITCODE | Should -Be 0
            python3 -c @"
import struct, pathlib
# Minimal 32-bit PE (IMAGE_FILE_MACHINE_I386) with one .text section, enough for osslsigncode.
dos = bytearray(64)
dos[0:2] = b'MZ'
# e_lfanew at 0x3c
struct.pack_into('<I', dos, 0x3c, 64)
pe = bytearray()
pe += b'PE\x00\x00'
pe += struct.pack('<HHIIIHH', 0x14c, 1, 0, 0, 0, 0xE0, 0x102)
# Optional header PE32
magic = 0x10b
opt = bytearray(0xE0)
struct.pack_into('<H', opt, 0, magic)
struct.pack_into('<I', opt, 16, 0x1000)  # AddressOfEntryPoint
struct.pack_into('<I', opt, 28, 0x400000)  # ImageBase
struct.pack_into('<I', opt, 32, 0x1000)  # SectionAlignment
struct.pack_into('<I', opt, 36, 0x200)  # FileAlignment
struct.pack_into('<H', opt, 40, 4)
struct.pack_into('<H', opt, 44, 4)
struct.pack_into('<H', opt, 48, 4)
struct.pack_into('<H', opt, 52, 4)
struct.pack_into('<I', opt, 56, 0x2000)  # SizeOfImage
struct.pack_into('<I', opt, 60, 0x200)  # SizeOfHeaders
struct.pack_into('<H', opt, 68, 3)  # Subsystem IMAGE_SUBSYSTEM_CONSOLE
struct.pack_into('<I', opt, 92, 16)  # NumberOfRvaAndSizes
# section
sec = bytearray(40)
sec[0:5] = b'.text'
struct.pack_into('<I', sec, 8, 0x200)   # VirtualSize
struct.pack_into('<I', sec, 12, 0x1000) # VirtualAddress
struct.pack_into('<I', sec, 16, 0x200)  # SizeOfRawData
struct.pack_into('<I', sec, 20, 0x200)  # PointerToRawData
struct.pack_into('<I', sec, 36, 0x60000020)
raw = bytes(dos) + bytes(pe) + bytes(opt) + bytes(sec)
raw = raw.ljust(0x200, b'\x00') + (b'\x90' * 0x200)
pathlib.Path(r'$pe').write_bytes(raw)
"@
            Test-Path -LiteralPath $pe | Should -BeTrue
            $env:RCB_SIGNTOOL = $ossl.Source
            $env:RCB_SIGN_PFX_PASSWORD = $pass
            $settings = Get-RcbSignSettings -SignFlag $true -PfxPath $pfx -TimestampUrl ''
            $settings.Tool = $ossl.Source
            $settings.ToolKind = 'osslsigncode'
            $r = Invoke-RcbSignOneFile -Settings $settings -FilePath $pe
            $r.Status | Should -Be 'signed'
        } finally {
            Remove-Item Env:\RCB_SIGNTOOL -ErrorAction SilentlyContinue
            Remove-Item Env:\RCB_SIGN_PFX_PASSWORD -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $key, $cer, $pfx -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            Test-Path -LiteralPath $pfx | Should -BeFalse
            Test-Path -LiteralPath $key | Should -BeFalse
        }
    }
}
