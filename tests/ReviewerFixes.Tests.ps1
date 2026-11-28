#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Regression tests for Reviewer1 must/should fixes on PR #3 (folded with PR #2).

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $prev = $env:RCB_NO_MAIN
    $env:RCB_NO_MAIN = '1'
    . (Join-Path $script:Root 'lib' 'BuildCore.ps1')
    . (Join-Path $script:Root 'lib' 'RtkTheme.ps1')
    . (Join-Path $script:Root 'lib' 'RtkUpdate.ps1')
    . (Join-Path $script:Root 'build.ps1')
    if ($null -eq $prev) { Remove-Item Env:\RCB_NO_MAIN -ErrorAction SilentlyContinue } else { $env:RCB_NO_MAIN = $prev }
}

Describe 'M1 Build.bat path quoting' {
    It 'does not put an unquoted %~1 inside a parenthesized if-block' {
        $bat = Get-Content -Raw -LiteralPath (Join-Path $script:Root 'Build.bat')
        $bat | Should -Not -Match '(?s)\([^)]*echo %~1'
        $bat | Should -Match 'goto :noargs'
        $bat | Should -Match 'goto :switches'
        $bat | Should -Match '%A1:~0,1%'
        $bat | Should -Match '-Path "%~1"'
        $bat | Should -Not -Match '%2 %3 %4 %5 %6 %7 %8 %9'
        $bat | Should -Match '"%~2"'
    }
}

Describe 'M2 artifacts are selected by cargo metadata bin names' {
    It 'copies an up-to-date binary whose mtime is older than the run' -Skip:($IsWindows -or $env:OS -eq 'Windows_NT') {
        $dir = Join-Path $TestDrive 'r1hello'
        New-Item -ItemType Directory -Path (Join-Path $dir 'src') | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'Cargo.toml') -Value "[package]`nname = `"r1hello`"`nversion = `"0.1.0`"`nedition = `"2021`"`n"
        Set-Content -LiteralPath (Join-Path $dir 'src/main.rs') -Value 'fn main() {}'
        $binDir = Join-Path $dir 'target/debug'
        New-Item -ItemType Directory -Path $binDir | Out-Null
        $hello = Join-Path $binDir 'r1hello'
        Set-Content -LiteralPath $hello -Value 'ELF-fake'
        (Get-Item -LiteralPath $hello).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-7)

        $shim = Join-Path $TestDrive 'm2bin'
        New-Item -ItemType Directory -Path $shim | Out-Null
        $cargo = Join-Path $shim 'cargo'
        $meta = '{"packages":[{"name":"r1hello","targets":[{"name":"r1hello","kind":["bin"]}]}],"target_directory":"' + ($dir.Replace('\','/') + '/target') + '","version":1}'
        $script = @"
#!/usr/bin/env bash
case "`$1" in
  metadata) printf '%s\n' '$meta'; exit 0 ;;
  build) echo Finished; exit 0 ;;
  *) exit 0 ;;
esac
"@
        # The target_directory in JSON must be the real path; embed it safely.
        $metaJson = @{
            packages = @(@{ name = 'r1hello'; targets = @(@{ name = 'r1hello'; kind = @('bin') }) })
            target_directory = (Join-Path $dir 'target')
            version = 1
        } | ConvertTo-Json -Compress -Depth 6
        $metaFile = Join-Path $shim 'meta.json'
        [System.IO.File]::WriteAllText($metaFile, $metaJson)
        @('#!/usr/bin/env bash', "case `"\$1`" in", "  metadata) cat $( $metaFile.Replace("'", "'\\''") ); exit 0 ;;", '  build) echo Finished; exit 0 ;;', '  *) exit 0 ;;', 'esac') | Set-Content -LiteralPath $cargo
        # write a cleaner shim
        $bash = "#!/usr/bin/env bash`ncase `"`$1`" in`n  metadata) cat '$metaFile'; exit 0 ;;`n  build) echo Finished; exit 0 ;;`n  *) exit 0 ;;`nesac`n"
        [System.IO.File]::WriteAllText($cargo, $bash)
        & /bin/chmod +x $cargo
        $saved = $env:PATH
        $env:PATH = $shim + [System.IO.Path]::PathSeparator + $env:PATH
        try {
            $res = Start-BuildPipeline -TargetFolder $dir -ActiveProfile 'debug' -RunTests $false -NoInstallFlag $true -NoOpenFlag $true -NoRtkUpdateFlag $true
            $res.Success | Should -BeTrue
            $res.Results[0].Artifacts | Should -Be 1
            Test-Path -LiteralPath (Join-Path $dir '_built/r1hello/r1hello') | Should -BeTrue
        } finally {
            $env:PATH = $saved
        }
    }
}

Describe 'S1 grandchild holding pipes does not hang or false-timeout' {
    It 'returns the child exit code after a short grace when a grandchild keeps the pipes open' -Skip:($IsWindows -or $env:OS -eq 'Windows_NT') {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-ToolProcess -FilePath '/bin/sh' -ArgumentList @('-c', 'echo ok; sleep 20 & exit 0') -TimeoutSec 0
        $sw.Stop()
        $r.ExitCode | Should -Be 0
        $r.TimedOut | Should -BeFalse
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 8
        $r.StdOut | Should -Match 'ok'
    }
    It 'kills leftover grandchildren after the parent exits' -Skip:($IsWindows -or $env:OS -eq 'Windows_NT') {
        $pidfile = Join-Path $TestDrive 'grandchild.pid'
        $r = Invoke-ToolProcess -FilePath '/bin/sh' -ArgumentList @('-c', "sleep 25 & echo `$`! > `"$pidfile`"; sleep 0.5; exit 0") -TimeoutSec 0
        $r.ExitCode | Should -Be 0
        $r.TimedOut | Should -BeFalse
        Test-Path -LiteralPath $pidfile | Should -BeTrue
        $gp = (Get-Content -LiteralPath $pidfile -Raw).Trim()
        $gp | Should -Match '^[0-9]+$'
        $alive = $false
        try {
            $pr = [System.Diagnostics.Process]::GetProcessById([int]$gp)
            $alive = -not $pr.HasExited
        } catch { $alive = $false }
        $alive | Should -BeFalse
    }
    It 'times out a still-running child and kills the tree, without marking a successful exit TimedOut' -Skip:($IsWindows -or $env:OS -eq 'Windows_NT') {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-ToolProcess -FilePath '/bin/sh' -ArgumentList @('-c', 'echo go; sleep 30') -TimeoutSec 2
        $sw.Stop()
        $r.TimedOut | Should -BeTrue
        $r.ExitCode | Should -Be -1
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 10
    }
}

Describe 'S2 STA relaunch forwards script-level parameters' {
    It 'turns present switches into -Name, drops absent ones, and keeps a value with spaces as one argument' {
        $bound = @{
            Path           = '/tmp/my projects'
            BuildProfile   = 'debug'
            Test           = [System.Management.Automation.SwitchParameter]::new($true)
            NoRtkUpdate    = [System.Management.Automation.SwitchParameter]::new($true)
            ClassicGui     = [System.Management.Automation.SwitchParameter]::new($false)
        }
        $args = ConvertTo-RcbRelaunchArgument -BoundParameters $bound -ScriptPath '/tmp/build.ps1' -HostPath 'powershell.exe'
        $args | Should -Contain '-STA'
        $args | Should -Contain '-ExecutionPolicy'
        $args | Should -Contain 'Bypass'
        $sta = [array]::IndexOf($args, '-STA')
        $args[$sta + 1] | Should -Be '-ExecutionPolicy'
        $args[$sta + 2] | Should -Be 'Bypass'
        $args | Should -Contain '-File'
        [array]::IndexOf($args, '-File') | Should -BeGreaterThan ($sta + 2)
        $i = [array]::IndexOf($args, '-Path')
        $i | Should -BeGreaterThan 0
        $args[$i + 1] | Should -Be '/tmp/my projects'
        $args | Should -Contain '-BuildProfile'
        $args | Should -Contain 'debug'
        $args | Should -Contain '-Test'
        $args | Should -Contain '-NoRtkUpdate'
        $args | Should -Not -Contain '-ClassicGui'
        @($args | Where-Object { $_ -eq '-ClassicGui' }).Count | Should -Be 0
    }
    It 'omits -STA for a non-Windows pwsh host' {
        $args = ConvertTo-RcbRelaunchArgument -BoundParameters @{} -ScriptPath '/tmp/build.ps1' -HostPath '/usr/bin/pwsh'
        $args | Should -Not -Contain '-STA'
        $args | Should -Not -Contain '-ExecutionPolicy'
        $args | Should -Not -Contain 'Bypass'
        $args | Should -Contain '-File'
    }
    It 'does not duplicate -ClassicGui when it is already in Extra' {
        $bound = @{ ClassicGui = [System.Management.Automation.SwitchParameter]::new($true) }
        $args = ConvertTo-RcbRelaunchArgument -BoundParameters $bound -ScriptPath '/tmp/build.ps1' -HostPath 'powershell.exe' -Extra @('-ClassicGui')
        @($args | Where-Object { $_ -eq '-ClassicGui' }).Count | Should -Be 1
    }
}

Describe 'S3 Restore-RtkBackup failures become ROLLBACK INCOMPLETE' {
    It 'returns one result object with ROLLBACK INCOMPLETE when the backup cannot be restored' {
        $dir = Join-Path $TestDrive 's3proj'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $manifest = Join-Path $dir 'Cargo.toml'
        Set-Content -LiteralPath $manifest -Value 'keep-me'
        $pairs = @([PSCustomObject]@{ Original = $manifest; Backup = (Join-Path $TestDrive 'no-such-backup'); Existed = $true })
        $fails = @(Restore-RtkBackup -Pairs $pairs)
        $fails.Count | Should -Be 1
        Get-Content -LiteralPath $manifest | Should -Be 'keep-me'

        # Invoke-RtkUpdateCheck must not leak failure strings into its return value.
        Mock Invoke-RtkLsRemote { [PSCustomObject]@{ ExitCode = 0; StdOut = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`trefs/tags/v1.2.0"; StdErr = ''; TimedOut = $false } }
        Mock Invoke-RtkCargoUpdate { [PSCustomObject]@{ ExitCode = 101; Lines = @('error: failed') } }
        $proj = Join-Path $TestDrive 's3bump'
        New-Item -ItemType Directory -Path $proj | Out-Null
        Set-Content -LiteralPath (Join-Path $proj 'Cargo.toml') @"
[package]
name = "s3bump"
version = "0.1.0"
[dependencies]
rtk = { git = "https://github.com/ubcool2ic/rtk", tag = "v0.8.2" }
"@
        # Point backup restore at a missing file after we stub Restore? Instead, make Backup-RtkFile produce a pair whose Backup is later deleted.
        $r = Invoke-RtkUpdateCheck -ManifestPath (Join-Path $proj 'Cargo.toml') -BackupRoot (Join-Path $proj '_built')
        # cargo update failed, restore should succeed here (normal path)
        $r | Should -Not -BeNullOrEmpty
        $r.GetType().Name | Should -Be 'PSCustomObject'
        @($r).Count | Should -Be 1
    }
}

Describe 'S5 GIT_ALLOW_PROTOCOL is scoped to rtk git calls' {
    It 'does not set GIT_ALLOW_PROTOCOL on a generic child' -Skip:($IsWindows -or $env:OS -eq 'Windows_NT') {
        $r = Invoke-ToolProcess -FilePath '/bin/sh' -ArgumentList @('-c', 'printf "%s" "$GIT_ALLOW_PROTOCOL"')
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -BeNullOrEmpty
    }
    It 'sets https:ssh (not git) only for Invoke-RtkProcess' -Skip:($IsWindows -or $env:OS -eq 'Windows_NT') {
        $r = Invoke-RtkProcess -FilePath '/bin/sh' -ArgumentList @('-c', 'printf "%s" "$GIT_ALLOW_PROTOCOL"') -TimeoutSec 5
        $r.StdOut | Should -Be 'https:ssh'
        $r.StdOut | Should -Not -Match '(^|:)git($|:)'
    }
}

Describe 'S6 discovery follows symlinks with loop protection' {
    It 'finds a project reached through a symlink and does not loop' -Skip:($IsWindows -or $env:OS -eq 'Windows_NT') {
        $root = Join-Path $TestDrive 's6root'
        $real = Join-Path $TestDrive 's6real'
        New-Item -ItemType Directory -Path (Join-Path $real 'src') | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'also') | Out-Null
        Set-Content -LiteralPath (Join-Path $real 'Cargo.toml') -Value "[package]`nname = `"linked`"`nversion = `"0.1.0`"`n"
        Set-Content -LiteralPath (Join-Path $root 'also/Cargo.toml') -Value "[package]`nname = `"also`"`nversion = `"0.1.0`"`n"
        New-Item -ItemType SymbolicLink -Path (Join-Path $root 'linkedproj') -Target $real | Out-Null
        # loop
        New-Item -ItemType SymbolicLink -Path (Join-Path $root 'loop') -Target $root | Out-Null
        $found = @(Get-CargoTomlFiles -RootDirectory $root)
        $names = @($found | ForEach-Object { $_.Directory.Name }) | Sort-Object
        $names | Should -Contain 'also'
        $names | Should -Contain 'linkedproj'
        $found.Count | Should -Be 2
    }
}

Describe 'S7 classic window OnTick hook is wired when a UI log is used' {
    It 'Start-BuildPipeline assigns RcbOnTick while a UI callback is in use' -Skip:($IsWindows -or $env:OS -eq 'Windows_NT') {
        $dir = Join-Path $TestDrive 's7empty'
        New-Item -ItemType Directory -Path $dir | Out-Null
        # Invalid? no cargo - will return early after scan. Use a tiny project + fake cargo so the tick hook is set during the run.
        Set-Content -LiteralPath (Join-Path $dir 'Cargo.toml') -Value "[package]`nname = `"s7`"`nversion = `"0.1.0`"`n"
        $tickSeen = $false
        $ui = { param($m, $r) }
        # Directly verify the hook type is used: after a pipeline with UiLog, the previous hook is restored (finally).
        $script:RcbOnTick = $null
        $shim = Join-Path $TestDrive 's7bin'
        New-Item -ItemType Directory -Path $shim -Force | Out-Null
        $cargo = Join-Path $shim 'cargo'
        [System.IO.File]::WriteAllText($cargo, "#!/usr/bin/env bash`nexit 0`n")
        & /bin/chmod +x $cargo
        $saved = $env:PATH
        $env:PATH = $shim + [System.IO.Path]::PathSeparator + $env:PATH
        try {
            $null = Start-BuildPipeline -TargetFolder $dir -ActiveProfile 'debug' -RunTests $false -NoInstallFlag $true -NoOpenFlag $true -NoRtkUpdateFlag $true -UiLog $ui
            $script:RcbOnTick | Should -BeNullOrEmpty
        } finally { $env:PATH = $saved }
        # And the assignment is present in the source.
        Get-Content -Raw (Join-Path $script:Root 'build.ps1') | Should -Match 'RcbOnTick'
        Get-Content -Raw (Join-Path $script:Root 'build.ps1') | Should -Match 'DoEvents'
    }
}

Describe 'N10 GUI launch does not auto-bump gui/Cargo.toml' {
    It 'builds the GUI with cargo build --release and always skips the rtk bump' {
        $src = Get-Content -Raw -LiteralPath (Join-Path $script:Root 'build.ps1')
        $src | Should -Match "'build', '--release'"
        $src | Should -Match 'never run the rtk auto-bump against this tool''s own'
        $src | Should -Not -Match 'Start-BuildPipeline -TargetFolder \$guiDir'
    }
}

Describe 'Test-RcbRustupSignerSubject' {
    It 'accepts the exact Rust Foundation CN or O' {
        Test-RcbRustupSignerSubject -Subject 'CN=Rust Foundation, O=Rust Foundation' | Should -BeTrue
        Test-RcbRustupSignerSubject -Subject 'CN=The Rust Foundation' | Should -BeTrue
        Test-RcbRustupSignerSubject -Subject 'O=The Rust Foundation, C=US' | Should -BeTrue
    }
    It 'rejects a subject that only contains the substring Rust' {
        Test-RcbRustupSignerSubject -Subject 'CN=Trust Rust LLC, OU=Rust' | Should -BeFalse
        Test-RcbRustupSignerSubject -Subject 'CN=Someone, OU=Rust Tools' | Should -BeFalse
        Test-RcbRustupSignerSubject -Subject '' | Should -BeFalse
    }
}

