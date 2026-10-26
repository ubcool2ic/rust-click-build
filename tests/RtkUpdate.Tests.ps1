#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for the forced rtk update check. Network (git ls-remote, GitHub API)
# and cargo are mocked; nothing here talks to GitHub or needs Rust.
# Run: Invoke-Pester ./tests

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures'
    . (Join-Path $script:Root (Join-Path 'lib' 'RtkTheme.ps1'))
    . (Join-Path $script:Root (Join-Path 'lib' 'RtkUpdate.ps1'))

    # Remote tags as git ls-remote prints them (annotated tags have ^{} lines).
    $script:LsRemoteOut = @(
        "b630eb22aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`trefs/tags/v1.0.0"
        "0000000000000000000000000000000000000001`trefs/tags/v1.0.1"
        "85125ab0d7efaa8b37279e10276a9b60e826901a`trefs/tags/v1.0.1^{}"
        "431514bfbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb`trefs/tags/v0.8.2"
        "cccccccccccccccccccccccccccccccccccccccc`trefs/tags/v1.1.0-rc.1"
        "dddddddddddddddddddddddddddddddddddddddd`trefs/tags/nightly"
    ) -join "`n"

    function script:Copy-Fixture([string]$Name) {
        $dest = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath (Join-Path $script:Fixtures $Name) -Destination $dest -Recurse
        return $dest
    }
    function script:New-LogSink {
        $sink = New-Object System.Collections.Generic.List[object]
        $sb = { param($m, $r) $sink.Add([PSCustomObject]@{ Msg = $m; Role = $r }) }.GetNewClosure()
        return [PSCustomObject]@{ Lines = $sink; Log = $sb }
    }
}

Describe 'Version helpers' {
    It 'compares semver tags with or without v' {
        Compare-RtkVersion 'v0.8.2' 'v1.0.1' | Should -BeLessThan 0
        Compare-RtkVersion '1.0.1' 'v1.0.1' | Should -Be 0
        Compare-RtkVersion 'v1.0.10' 'v1.0.9' | Should -BeGreaterThan 0
    }
    It 'sorts a prerelease below its release' {
        Compare-RtkVersion 'v1.1.0-rc.1' 'v1.1.0' | Should -BeLessThan 0
    }
    It 'picks the newest stable tag and ignores prereleases and junk' {
        Select-RtkLatestTag @('v0.8.2', 'v1.0.1', 'v1.0.0', 'v1.1.0-rc.1', 'nightly') | Should -Be 'v1.0.1'
    }
    It 'parses ls-remote output, preferring the peeled commit of annotated tags' {
        $map = ConvertFrom-LsRemoteTag $script:LsRemoteOut
        $map['v1.0.1'] | Should -Be '85125ab0d7efaa8b37279e10276a9b60e826901a'
        $map.ContainsKey('v0.8.2') | Should -BeTrue
    }
}

Describe 'Get-RtkDependency' {
    It 'finds a <Kind> pin in <Fixture>' -TestCases @(
        @{ Fixture = 'tag-old';     Kind = 'tag';    Value = 'v0.8.2' }
        @{ Fixture = 'tag-current'; Kind = 'tag';    Value = 'v1.0.1' }
        @{ Fixture = 'rev';         Kind = 'rev';    Value = '85125ab0d7ef' }
        @{ Fixture = 'branch';      Kind = 'branch'; Value = 'main' }
        @{ Fixture = 'unpinned';    Kind = 'none';   Value = $null }
    ) {
        $d = @(Get-RtkDependency -ManifestPath (Join-Path (Join-Path $script:Fixtures $Fixture) 'Cargo.toml'))
        $d.Count | Should -Be 1
        $d[0].PinKind | Should -Be $Kind
        $d[0].PinValue | Should -Be $Value
    }
    It 'ignores commented-out rtk lines and other repos called rtk' {
        @(Get-RtkDependency -ManifestPath (Join-Path $script:Fixtures 'no-rtk/Cargo.toml')).Count | Should -Be 0
    }
    It 'reads workspace.dependencies, renamed table-form deps and target deps' {
        $ws = Join-Path $script:Fixtures 'workspace'
        $all = @()
        foreach ($m in (Get-ProjectManifestSet -ManifestPath (Join-Path $ws 'Cargo.toml'))) { $all += @(Get-RtkDependency -ManifestPath $m) }
        $all.Count | Should -Be 3
        ($all | Where-Object Section -eq 'workspace.dependencies').PinValue | Should -Be 'v1.0.0'
        $ui = $all | Where-Object DepName -eq 'ui'
        $ui.Form | Should -Be 'table'
        $ui.PinValue | Should -Be 'v0.8.2'
        ($all | Where-Object DepName -eq 'rtk-extra').PinKind | Should -Be 'branch'
    }
}

Describe 'Get-RtkLatestRelease' {
    BeforeEach { $script:RtkLatestCache = @{}; $script:savedToken = $env:GH_TOKEN }
    AfterEach { $env:GH_TOKEN = $script:savedToken }

    It 'uses git ls-remote first' {
        Mock Invoke-RtkLsRemote { [PSCustomObject]@{ ExitCode = 0; StdOut = $script:LsRemoteOut; StdErr = '' } }
        Mock Invoke-RtkTagApi { throw 'should not be called' }
        $r = Get-RtkLatestRelease
        $r.Tag | Should -Be 'v1.0.1'
        $r.Source | Should -Be 'git ls-remote'
        Should -Invoke Invoke-RtkTagApi -Times 0
    }
    It 'falls back to the GitHub API with GH_TOKEN' {
        $env:GH_TOKEN = 'test-token'
        Mock Invoke-RtkLsRemote { [PSCustomObject]@{ ExitCode = 128; StdOut = ''; StdErr = 'fatal: could not read Username' } }
        Mock Invoke-RtkTagApi { @([PSCustomObject]@{ Name = 'v1.0.1'; Sha = 'ABC' }, [PSCustomObject]@{ Name = 'v0.8.2'; Sha = 'def' }) }
        $r = Get-RtkLatestRelease
        $r.Tag | Should -Be 'v1.0.1'
        $r.Source | Should -Match 'GitHub API'
        Should -Invoke Invoke-RtkTagApi -Times 1 -ParameterFilter { $Token -eq 'test-token' }
    }
    It 'reports an error when offline and no token is set' {
        $env:GH_TOKEN = ''
        Mock Invoke-RtkLsRemote { [PSCustomObject]@{ ExitCode = 128; StdOut = ''; StdErr = 'fatal: unable to access' } }
        $r = Get-RtkLatestRelease
        $r.Tag | Should -BeNullOrEmpty
        $r.Error | Should -Match 'GH_TOKEN is not set'
    }
    It 'caches the answer for the rest of the run' {
        Mock Invoke-RtkLsRemote { [PSCustomObject]@{ ExitCode = 0; StdOut = $script:LsRemoteOut; StdErr = '' } }
        $null = Get-RtkLatestRelease; $null = Get-RtkLatestRelease
        Should -Invoke Invoke-RtkLsRemote -Times 1 -Exactly
    }
}

Describe 'Invoke-RtkUpdateCheck' {
    BeforeEach {
        $script:RtkLatestCache = @{}
        Mock Invoke-RtkLsRemote { [PSCustomObject]@{ ExitCode = 0; StdOut = $script:LsRemoteOut; StdErr = '' } }
        Mock Invoke-RtkCargoUpdate { [PSCustomObject]@{ ExitCode = 0; Lines = @('    Updating git repository') } }
    }

    It 'bumps an old tag, backs up first and runs cargo update -p rtk' {
        $dir = Copy-Fixture 'tag-old'
        $before = Get-Content -Raw (Join-Path $dir 'Cargo.toml')
        $sink = New-LogSink
        $r = Invoke-RtkUpdateCheck -ManifestPath (Join-Path $dir 'Cargo.toml') -BackupRoot (Join-Path $dir '_built') -Log $sink.Log
        $r.Changed | Should -BeTrue
        $r.Status | Should -Be 'v0.8.2 -> v1.0.1'
        $r.KeptLabel | Should -Be 'v0.8.2'
        $after = Get-Content -Raw (Join-Path $dir 'Cargo.toml')
        $after | Should -Match 'tag = "v1\.0\.1" \} # pinned to an old release'
        $after | Should -Not -Match 'v0\.8\.2'
        Get-Content -Raw ($r.Backup | Where-Object { $_.Original -like '*Cargo.toml' }).Backup | Should -Be $before
        Should -Invoke Invoke-RtkCargoUpdate -Times 1 -Exactly
        ($sink.Lines | Where-Object Role -eq 'rtkchange').Msg | Should -Match 'v0\.8\.2 -> v1\.0\.1'
    }
    It 'leaves a current tag alone and does not call cargo' {
        $dir = Copy-Fixture 'tag-current'
        $r = Invoke-RtkUpdateCheck -ManifestPath (Join-Path $dir 'Cargo.toml') -BackupRoot (Join-Path $dir '_built')
        $r.Changed | Should -BeFalse
        $r.Status | Should -Be 'v1.0.1 (latest)'
        Should -Invoke Invoke-RtkCargoUpdate -Times 0
    }
    It 'accepts a rev that is the latest release commit' {
        $dir = Copy-Fixture 'rev'
        $r = Invoke-RtkUpdateCheck -ManifestPath (Join-Path $dir 'Cargo.toml') -BackupRoot (Join-Path $dir '_built')
        $r.Status | Should -Be 'rev = v1.0.1 (latest)'
        Should -Invoke Invoke-RtkCargoUpdate -Times 0
    }
    It 'warns about an old rev but does not rewrite it' {
        $dir = Copy-Fixture 'rev-old'
        $before = Get-Content -Raw (Join-Path $dir 'Cargo.toml')
        $sink = New-LogSink
        $r = Invoke-RtkUpdateCheck -ManifestPath (Join-Path $dir 'Cargo.toml') -BackupRoot (Join-Path $dir '_built') -Log $sink.Log
        $r.Status | Should -Match 'behind v1\.0\.1, not bumped'
        Get-Content -Raw (Join-Path $dir 'Cargo.toml') | Should -Be $before
        ($sink.Lines | Where-Object Role -eq 'warning').Count | Should -BeGreaterThan 0
    }
    It 'always runs cargo update for a <Fixture> dep' -TestCases @(@{ Fixture = 'branch' }, @{ Fixture = 'unpinned' }) {
        $dir = Copy-Fixture $Fixture
        $before = Get-Content -Raw (Join-Path $dir 'Cargo.toml')
        $r = Invoke-RtkUpdateCheck -ManifestPath (Join-Path $dir 'Cargo.toml') -BackupRoot (Join-Path $dir '_built')
        $r.Changed | Should -BeTrue
        $r.Status | Should -Match 'cargo update -p rtk'
        Get-Content -Raw (Join-Path $dir 'Cargo.toml') | Should -Be $before
        Should -Invoke Invoke-RtkCargoUpdate -Times 1 -Exactly
    }
    It 'bumps every old tag in a workspace and keeps CRLF line endings' {
        $dir = Copy-Fixture 'workspace'
        $r = Invoke-RtkUpdateCheck -ManifestPath (Join-Path $dir 'Cargo.toml') -BackupRoot (Join-Path $dir '_built')
        $r.Changed | Should -BeTrue
        @($r.Changes).Count | Should -Be 2
        Get-Content -Raw (Join-Path $dir 'Cargo.toml') | Should -Match 'tag = "v1\.0\.1"'
        $w = [System.IO.File]::ReadAllText((Join-Path $dir 'widgets/Cargo.toml'))
        $w | Should -Match "tag = `"v1\.0\.1`"`r`n"
        $w | Should -Match 'branch = "main"'
        ([regex]::Matches($w, "(?<!`r)`n")).Count | Should -Be 0
        [System.IO.File]::ReadAllBytes((Join-Path $dir 'widgets/Cargo.toml'))[0] | Should -Not -Be 0xEF
        Should -Invoke Invoke-RtkCargoUpdate -Times 1 -Exactly
        $r.Status | Should -Match 'v1\.0\.0 -> v1\.0\.1'
        $r.Status | Should -Match 'v0\.8\.2 -> v1\.0\.1'
    }
    It 'does nothing and never touches the network without an rtk dep' {
        $dir = Copy-Fixture 'no-rtk'
        $r = Invoke-RtkUpdateCheck -ManifestPath (Join-Path $dir 'Cargo.toml') -BackupRoot (Join-Path $dir '_built')
        $r.HasRtk | Should -BeFalse
        Should -Invoke Invoke-RtkLsRemote -Times 0
        Should -Invoke Invoke-RtkCargoUpdate -Times 0
    }
    It 'warns loudly and continues when offline with no credentials' {
        $saved = $env:GH_TOKEN; $env:GH_TOKEN = ''
        try {
            Mock Invoke-RtkLsRemote { [PSCustomObject]@{ ExitCode = 128; StdOut = ''; StdErr = 'fatal: could not read Username' } }
            $dir = Copy-Fixture 'tag-old'
            $sink = New-LogSink
            $r = Invoke-RtkUpdateCheck -ManifestPath (Join-Path $dir 'Cargo.toml') -BackupRoot (Join-Path $dir '_built') -Log $sink.Log
            $r.Status | Should -Be 'NOT CHECKED (offline/no credentials)'
            $r.Changed | Should -BeFalse
            ($sink.Lines | Where-Object { $_.Role -eq 'danger' -and $_.Msg -match 'COULD NOT CHECK' }).Count | Should -Be 1
            Get-Content -Raw (Join-Path $dir 'Cargo.toml') | Should -Match 'v0\.8\.2'
        } finally { $env:GH_TOKEN = $saved }
    }
    It 'restores the backup when cargo update fails' {
        Mock Invoke-RtkCargoUpdate { [PSCustomObject]@{ ExitCode = 101; Lines = @('error: failed to fetch rtk') } }
        $dir = Copy-Fixture 'tag-old'
        $before = Get-Content -Raw (Join-Path $dir 'Cargo.toml')
        $r = Invoke-RtkUpdateCheck -ManifestPath (Join-Path $dir 'Cargo.toml') -BackupRoot (Join-Path $dir '_built')
        $r.Changed | Should -BeFalse
        $r.Status | Should -Match 'cargo update -p rtk failed; kept v0\.8\.2'
        Get-Content -Raw (Join-Path $dir 'Cargo.toml') | Should -Be $before
    }
}

Describe 'Build pipeline with a fake cargo' -Skip:($IsWindows -or $env:OS -eq 'Windows_NT') {
    BeforeAll {
        $env:RCB_NO_MAIN = '1'
        . (Join-Path $script:Root 'build.ps1')
        $script:FakeBin = Join-Path $TestDrive 'fakebin'
        New-Item -ItemType Directory -Path $script:FakeBin | Out-Null
        Copy-Item (Join-Path $script:Fixtures 'fake-cargo.sh') (Join-Path $script:FakeBin 'cargo')
        & chmod +x (Join-Path $script:FakeBin 'cargo')
        $script:SavedPath = $env:PATH
        $env:PATH = $script:FakeBin + [System.IO.Path]::PathSeparator + $env:PATH
        $env:FAKE_CARGO_LOG = Join-Path $TestDrive 'cargo-calls.log'
    }
    AfterAll {
        $env:PATH = $script:SavedPath
        Remove-Item Env:\RCB_NO_MAIN, Env:\FAKE_CARGO_LOG, Env:\FAKE_CARGO_FAIL_TAG -ErrorAction SilentlyContinue
    }
    BeforeEach {
        $script:RtkLatestCache = @{}
        Remove-Item Env:\FAKE_CARGO_FAIL_TAG -ErrorAction SilentlyContinue
        Mock Invoke-RtkLsRemote { [PSCustomObject]@{ ExitCode = 0; StdOut = $script:LsRemoteOut; StdErr = '' } }
        Set-Content -Path $env:FAKE_CARGO_LOG -Value ''
    }

    It 'runs the rtk check before cargo build and shows the bump in the summary' {
        $dir = Copy-Fixture 'tag-old'
        $res = Start-BuildPipeline -TargetFolder $dir -ActiveProfile 'debug' -RunTests $false -NoInstallFlag $true -NoOpenFlag $true
        $res.Success | Should -BeTrue
        $res.Results[0].Rtk | Should -Be 'v0.8.2 -> v1.0.1'
        $calls = @(Get-Content $env:FAKE_CARGO_LOG | Where-Object { $_ -ne '' })
        $upd = [array]::IndexOf($calls, ($calls | Where-Object { $_ -like 'update -p rtk*' } | Select-Object -First 1))
        $bld = [array]::IndexOf($calls, ($calls | Where-Object { $_ -like 'build*' } | Select-Object -First 1))
        $upd | Should -BeGreaterOrEqual 0
        $upd | Should -BeLessThan $bld
    }
    It 'rolls back and rebuilds on the old pin when the new rtk breaks the build' {
        $env:FAKE_CARGO_FAIL_TAG = 'v1.0.1'
        $dir = Copy-Fixture 'workspace'
        $res = Start-BuildPipeline -TargetFolder $dir -ActiveProfile 'debug' -RunTests $false -NoInstallFlag $true -NoOpenFlag $true
        $row = $res.Results[0]
        $row.BuildStatus | Should -Be 'PASS'
        $row.Rtk | Should -Be 'rtk update broke the build, kept v1.0.0, v0.8.2, branch main'
        @($row.RtkErrors)[0] | Should -Match 'error\[E0425\]'
        Get-Content -Raw (Join-Path $dir 'Cargo.toml') | Should -Match 'tag = "v1\.0\.0"'
        [System.IO.File]::ReadAllText((Join-Path $dir 'widgets/Cargo.toml')) | Should -Match 'tag = "v0\.8\.2"'
        @(Get-Content $env:FAKE_CARGO_LOG | Where-Object { $_ -like 'build*' }).Count | Should -Be 2
    }
    It 'skips the check with -NoRtkUpdate' {
        $dir = Copy-Fixture 'tag-old'
        $res = Start-BuildPipeline -TargetFolder $dir -ActiveProfile 'debug' -RunTests $false -NoInstallFlag $true -NoOpenFlag $true -NoRtkUpdateFlag $true
        $res.Results[0].Rtk | Should -Be 'skipped (-NoRtkUpdate)'
        Get-Content -Raw (Join-Path $dir 'Cargo.toml') | Should -Match 'v0\.8\.2'
        Should -Invoke Invoke-RtkLsRemote -Times 0
    }
    It 'build.ps1 exposes the -NoRtkUpdate switch and the GUI checkbox' {
        $cmd = Get-Command (Join-Path $script:Root 'build.ps1')
        $cmd.Parameters.ContainsKey('NoRtkUpdate') | Should -BeTrue
        $cmd.Parameters['NoRtkUpdate'].ParameterType | Should -Be ([switch])
        Get-Content -Raw (Join-Path $script:Root 'build.ps1') | Should -Match 'Check for rtk updates before building'
    }
}

Describe 'rtk theme tokens' {
    It 'matches rtk v1.0.1 modern_dark / modern_light accents' {
        ConvertTo-RtkHex (Get-RtkTheme ModernDark).Colors.accent | Should -Be '#4F8CFF'
        ConvertTo-RtkHex (Get-RtkTheme ModernLight).Colors.accent | Should -Be '#2563EB'
        ConvertTo-RtkHex (Get-RtkTheme ModernDark).Colors.bg | Should -Be '#0F1115'
    }
    It 'uses the rtk hover blend (6% toward fg)' {
        (Get-RtkTheme ModernDark).Colors.hover | Should -Be @(35, 38, 45)
    }
    It 'maps legacy console colours to rtk roles' {
        ConvertTo-RtkRole 'Cyan' | Should -Be 'accent'
        ConvertTo-RtkRole 'Red' | Should -Be 'danger'
    }
}
