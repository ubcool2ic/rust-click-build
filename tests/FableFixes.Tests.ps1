#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Regression tests for the Fable 5.2 bug and performance pass.

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures'
    $env:RCB_NO_MAIN = '1'
    . (Join-Path $script:Root (Join-Path 'lib' 'BuildCore.ps1'))
    . (Join-Path $script:Root (Join-Path 'lib' 'RtkTheme.ps1'))
    . (Join-Path $script:Root (Join-Path 'lib' 'RtkUpdate.ps1'))
    . (Join-Path $script:Root (Join-Path 'lib' 'RcbProgress.ps1'))

    function script:Copy-Fixture([string]$Name) {
        $dest = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath (Join-Path $script:Fixtures $Name) -Destination $dest -Recurse
        return $dest
    }
}

Describe 'Resolve-CommandPath' {
    It 'returns only the first executable on PATH' {
        $path = Resolve-CommandPath -Name 'cargo'
        $path | Should -Not -Match ' '
        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
    }
}

Describe 'ConvertTo-CommandLineArgument' {
    It 'quotes a trailing backslash that also needs quotes' {
        ConvertTo-CommandLineArgument 'C:\my dir\' | Should -Be '"C:\my dir\\"'
    }
    It 'emits empty quotes for an empty argument' {
        ConvertTo-CommandLineArgument '' | Should -Be '""'
    }
    It 'escapes an embedded quote and surrounding backslashes' {
        ConvertTo-CommandLineArgument 'say "hi"' | Should -Be '"say \"hi\""'
    }
    It 'leaves a simple path unquoted' {
        ConvertTo-CommandLineArgument 'C:\src\Cargo.toml' | Should -Be 'C:\src\Cargo.toml'
    }
}

Describe 'Test-RtkGitUrl' {
    It 'accepts https, ssh and git@ forms' {
        Test-RtkGitUrl 'https://github.com/ubcool2ic/rtk' | Should -BeTrue
        Test-RtkGitUrl 'https://github.com/ubcool2ic/rtk.git' | Should -BeTrue
        Test-RtkGitUrl 'git@github.com:ubcool2ic/rtk.git' | Should -BeTrue
        Test-RtkGitUrl 'ssh://git@github.com/ubcool2ic/rtk.git' | Should -BeTrue
    }
    It 'rejects look-alike and transport-injection URLs' {
        Test-RtkGitUrl 'https://evil.example/github.com/ubcool2ic/rtk' | Should -BeFalse
        Test-RtkGitUrl 'ext::cmd /c calc & rem github.com/ubcool2ic/rtk' | Should -BeFalse
        Test-RtkGitUrl '--upload-pack=evil github.com/ubcool2ic/rtk' | Should -BeFalse
        Test-RtkGitUrl 'https://github.com/someone-else/rtk' | Should -BeFalse
    }
}

Describe 'Get-CargoTomlFiles' {
    It 'does not descend into target, node_modules, .git or _built' {
        $root = Join-Path $TestDrive 'disc'
        New-Item -ItemType Directory -Path (Join-Path $root 'app/src') | Out-Null
        Set-Content (Join-Path $root 'app/Cargo.toml') "[package]`nname=`"app`"`nversion=`"0.1.0`"`n"
        foreach ($skip in @('target', 'node_modules', '.git', '_built')) {
            $hidden = Join-Path $root "app/$skip/nested"
            New-Item -ItemType Directory -Path $hidden | Out-Null
            Set-Content (Join-Path $hidden 'Cargo.toml') "[package]`nname=`"hidden`"`nversion=`"0.1.0`"`n"
            1..20 | ForEach-Object { Set-Content (Join-Path $hidden "f$_.o") 'x' }
        }
        $found = @(Get-CargoTomlFiles -RootDirectory $root)
        $found.Count | Should -Be 1
        $found[0].Directory.Name | Should -Be 'app'
    }
    It 'still finds a project whose root path contains a target segment' {
        $root = Join-Path $TestDrive 'work/target/myapp'
        New-Item -ItemType Directory -Path (Join-Path $root 'src') | Out-Null
        Set-Content (Join-Path $root 'Cargo.toml') "[package]`nname=`"myapp`"`nversion=`"0.1.0`"`n"
        $found = @(Get-CargoTomlFiles -RootDirectory $root)
        $found.Count | Should -Be 1
        $env:RCB_NO_MAIN = '1'
        . (Join-Path $script:Root 'build.ps1')
        @(Find-CargoProjects -RootDirectory $root).Count | Should -Be 1
    }
}

Describe 'Get-RelativeBuiltName and Get-CargoLockPath' {
    It 'uses a relative path so two cli projects do not collide' {
        $root = Join-Path $TestDrive 'multi'
        Get-RelativeBuiltName -Root $root -ProjectDir (Join-Path $root 'a/cli') | Should -Be 'a--cli'
        Get-RelativeBuiltName -Root $root -ProjectDir (Join-Path $root 'b/cli') | Should -Be 'b--cli'
        Get-RelativeBuiltName -Root $root -ProjectDir (Join-Path $root 'a_cli') | Should -Be 'a_cli'
    }
    It 'backs up the workspace-root Cargo.lock for a member crate' {
        $ws = Join-Path $script:Fixtures 'workspace'
        Get-CargoLockPath -ManifestPath (Join-Path $ws 'app/Cargo.toml') | Should -Be (Join-Path $ws 'Cargo.lock')
    }
}

Describe 'Restore-RtkBackup and cargo-update throw' {
    It 'continues past a missing backup file and reports the failure' {
        $orig = Join-Path $TestDrive 'Cargo.toml'
        Set-Content $orig 'keep-me'
        $pairs = @([PSCustomObject]@{ Original = $orig; Backup = (Join-Path $TestDrive 'no-such-backup'); Existed = $true })
        $fails = @(Restore-RtkBackup -Pairs $pairs)
        $fails.Count | Should -Be 1
        Get-Content -Raw $orig | Should -Match 'keep-me'
    }
    It 'restores Cargo.toml when Invoke-RtkCargoUpdate throws' {
        Mock Invoke-RtkLsRemote { [PSCustomObject]@{ ExitCode = 0; StdOut = "85125ab0d7efaa8b37279e10276a9b60e826901a`trefs/tags/v1.0.1`n"; StdErr = '' } }
        Mock Invoke-RtkCargoUpdate { throw 'Process.Start failed' }
        $script:RtkLatestCache = @{}
        $dir = Copy-Fixture 'tag-old'
        $before = Get-Content -Raw (Join-Path $dir 'Cargo.toml')
        $r = Invoke-RtkUpdateCheck -ManifestPath (Join-Path $dir 'Cargo.toml') -BackupRoot (Join-Path $dir '_built')
        $r.Changed | Should -BeFalse
        $r.Status | Should -Match 'cargo update -p rtk failed; kept'
        Get-Content -Raw (Join-Path $dir 'Cargo.toml') | Should -Be $before
    }

    It 'restores the workspace-root Cargo.lock when cargo update fails on a member crate' {
        Mock Invoke-RtkLsRemote { [PSCustomObject]@{ ExitCode = 0; StdOut = "85125ab0d7efaa8b37279e10276a9b60e826901a`trefs/tags/v1.0.1`n"; StdErr = '' } }
        $ws = Copy-Fixture 'workspace'
        $rootLock = Join-Path $ws 'Cargo.lock'
        Set-Content -LiteralPath $rootLock -Value "root-lock-v1`n"
        $memberLock = Join-Path $ws 'app/Cargo.lock'
        Set-Content -LiteralPath $memberLock -Value "member-lock-should-not-be-backed-up`n"
        $script:WsRootForLock = $ws
        Mock Invoke-RtkCargoUpdate {
            Set-Content -LiteralPath (Join-Path $script:WsRootForLock 'Cargo.lock') -Value "mutated-by-failed-update`n"
            throw 'cargo update failed'
        }
        $script:RtkLatestCache = @{}
        $r = Invoke-RtkUpdateCheck -ManifestPath (Join-Path $ws 'widgets/Cargo.toml') -BackupRoot (Join-Path $ws '_built')
        $r.Changed | Should -BeFalse
        $r.Status | Should -Match 'cargo update -p rtk failed; kept'
        (Get-Content -Raw -LiteralPath $rootLock).Trim() | Should -Be 'root-lock-v1'
        $origs = @($r.Backup | ForEach-Object { $_.Original })
        $origs | Should -Contain $rootLock
        $origs | Should -Not -Contain $memberLock
    }
}

Describe 'failed tag lookup is not cached' {
    It 'queries again after a failed lookup' {
        $script:RtkLatestCache = @{}
        $env:GH_TOKEN = ''
        Mock Invoke-RtkLsRemote { [PSCustomObject]@{ ExitCode = 128; StdOut = ''; StdErr = 'offline' } }
        $null = Get-RtkLatestRelease
        $null = Get-RtkLatestRelease
        Should -Invoke Invoke-RtkLsRemote -Times 2
    }
}

Describe 'ls-remote arguments include --' {
    It 'passes -- before the repo URL' {
        Mock Invoke-ToolProcess { param($FilePath, $ArgumentList) [PSCustomObject]@{ ExitCode = 0; StdOut = ''; StdErr = ''; Lines = @(); TimedOut = $false; Cancelled = $false } }
        $null = Invoke-RtkLsRemote -RepoUrl 'https://github.com/ubcool2ic/rtk'
        Should -Invoke Invoke-ToolProcess -Times 1 -ParameterFilter {
            $ArgumentList -contains '--' -and $ArgumentList[-1] -eq 'https://github.com/ubcool2ic/rtk'
        }
    }
}

Describe 'Build pipeline extras' -Skip:($IsWindows -or $env:OS -eq 'Windows_NT') {
    BeforeAll {
        $env:RCB_NO_MAIN = '1'
        . (Join-Path $script:Root 'build.ps1')
        $script:FakeBin = Join-Path $TestDrive 'fakebin2'
        New-Item -ItemType Directory -Path $script:FakeBin | Out-Null
        Copy-Item (Join-Path $script:Fixtures 'fake-cargo.sh') (Join-Path $script:FakeBin 'cargo')
        & chmod +x (Join-Path $script:FakeBin 'cargo')
        $script:SavedPath = $env:PATH
        $env:PATH = $script:FakeBin + [System.IO.Path]::PathSeparator + $env:PATH
        $env:FAKE_CARGO_LOG = Join-Path $TestDrive 'cargo-calls2.log'
    }
    AfterAll {
        $env:PATH = $script:SavedPath
        Remove-Item Env:\FAKE_CARGO_LOG, Env:\FAKE_CARGO_FAIL_TAG, Env:\FAKE_CARGO_UPDATE_EXIT, Env:\FAKE_CARGO_META_STDERR -ErrorAction SilentlyContinue
    }
    BeforeEach {
        $script:RtkLatestCache = @{}
        Remove-Item Env:\FAKE_CARGO_FAIL_TAG -ErrorAction SilentlyContinue
        Mock Invoke-RtkLsRemote { [PSCustomObject]@{ ExitCode = 0; StdOut = "85125ab0d7efaa8b37279e10276a9b60e826901a`trefs/tags/v1.0.1`n"; StdErr = '' } }
        Set-Content -Path $env:FAKE_CARGO_LOG -Value ''
    }

    It 'does not blame rtk when the rebuild on the old pin also fails' {
        # Fail every build, including the rollback rebuild.
        $dir = Copy-Fixture 'tag-old'
        # Patch fake cargo via env: fail both tags by pointing at a tag always present? Use a wrapper.
        $wrapper = Join-Path $script:FakeBin 'cargo'
        Set-Content -Path $wrapper -Value @'
#!/usr/bin/env bash
echo "$*" >> "${FAKE_CARGO_LOG:-/dev/null}"
case "$1" in
  metadata) echo '{"target_directory":null}'; exit 0 ;;
  update) exit 0 ;;
  build)
    echo "error[E0000]: always broken" >&2
    echo "  --> src/main.rs:1:1" >&2
    exit 101 ;;
  *) exit 0 ;;
esac
'@
        & chmod +x $wrapper
        $res = Start-BuildPipeline -TargetFolder $dir -ActiveProfile 'debug' -RunTests $false -NoInstallFlag $true -NoOpenFlag $true
        $res.Success | Should -BeFalse
        $res.Results[0].Rtk | Should -Match 'build fails with and without the rtk update'
        Get-Content -Raw (Join-Path $dir 'Cargo.toml') | Should -Match 'v0\.8\.2'
    }

    It 'parses cargo metadata stdout even when stderr has a warning' {
        $dir = Copy-Fixture 'no-rtk'
        $wrapper = Join-Path $script:FakeBin 'cargo'
        $td = Join-Path $dir 'custom-target'
        New-Item -ItemType Directory -Path $td | Out-Null
        $scriptPath = @'
#!/usr/bin/env bash
echo "$*" >> "${FAKE_CARGO_LOG:-/dev/null}"
case "$1" in
  metadata) echo 'warning: unused manifest key' >&2; printf '%s\n' '{"target_directory":"TARGETDIR"}'; exit 0 ;;
  build) mkdir -p "TARGETDIR/debug"; printf 'x' > "TARGETDIR/debug/no-rtk"; chmod +x "TARGETDIR/debug/no-rtk"; echo Finished; exit 0 ;;
  *) exit 0 ;;
esac
'@
        $scriptPath = $scriptPath.Replace('TARGETDIR', $td)
        Set-Content -Path $wrapper -Value $scriptPath -NoNewline
        & chmod +x $wrapper
        $res = Start-BuildPipeline -TargetFolder $dir -ActiveProfile 'debug' -RunTests $false -NoInstallFlag $true -NoOpenFlag $true
        $res.Success | Should -BeTrue
        $res.Results[0].Artifacts | Should -Be 1
        $copied = @(Get-ChildItem -LiteralPath (Join-Path $dir '_built') -Recurse -File | Where-Object { $_.Name -eq 'no-rtk' })
        $copied.Count | Should -Be 1
    }
}


AfterAll {
    Remove-Item Env:\RCB_NO_MAIN -ErrorAction SilentlyContinue
}
