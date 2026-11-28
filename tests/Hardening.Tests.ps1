#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Regression tests for the hardening of lib/RtkUpdate.ps1 and lib/RtkTheme.ps1.
# Network and cargo are mocked; nothing here talks to GitHub or needs Rust.
# Run: Invoke-Pester ./tests

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures'
    . (Join-Path $script:Root (Join-Path 'lib' 'RtkTheme.ps1'))
    . (Join-Path $script:Root (Join-Path 'lib' 'RtkUpdate.ps1'))

    $script:RtkUrl = 'https://github.com/ubcool2ic/rtk'
    $script:LsRemoteOut = @(
        "b630eb22aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`trefs/tags/v1.0.0"
        "85125ab0d7efaa8b37279e10276a9b60e826901a`trefs/tags/v1.0.1"
        "431514bfbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb`trefs/tags/v0.8.2"
    ) -join "`n"

    function script:New-TempDir {
        $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [System.IO.Directory]::CreateDirectory($d) | Out-Null
        return $d
    }
    function script:Copy-Fixture([string]$Name) {
        $dest = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath (Join-Path $script:Fixtures $Name) -Destination $dest -Recurse
        return $dest
    }
    function script:Write-Utf8([string]$Path, [string]$Text, [switch]$Bom) {
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
        [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding([bool]$Bom)))
    }
}

Describe 'Windows command-line quoting' {
    It 'quotes <Arg> as <Expected>' -TestCases @(
        @{ Arg = 'simple';              Expected = 'simple' }
        @{ Arg = '';                    Expected = '""' }
        @{ Arg = 'a b';                 Expected = '"a b"' }
        @{ Arg = 'C:\plain\';           Expected = 'C:\plain\' }
        @{ Arg = 'C:\dir with space\';  Expected = '"C:\dir with space\\"' }
        @{ Arg = 'say "hi"';            Expected = '"say \"hi\""' }
        @{ Arg = 'a\"b';                Expected = '"a\\\"b"' }
        @{ Arg = 'a\\b c';              Expected = '"a\\b c"' }
    ) {
        ConvertTo-RcbWindowsArgument $Arg | Should -BeExactly $Expected
    }
    It 'joins a command line and keeps a trailing backslash inside quotes doubled' {
        Join-RcbCommandLine @('ls-remote', '--tags', 'C:\my repo\') | Should -BeExactly 'ls-remote --tags "C:\my repo\\"'
    }
    It 'fills ProcessStartInfo either through ArgumentList or a quoted Arguments string' {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        Set-RcbProcessArgument -StartInfo $psi -ArgumentList @('a b', 'c')
        if ($null -ne $psi.PSObject.Properties['ArgumentList']) {
            @($psi.ArgumentList) | Should -Be @('a b', 'c')
        } else {
            $psi.Arguments | Should -BeExactly '"a b" c'
        }
    }
}

Describe 'Invoke-RtkProcess' {
    It 'passes arguments with spaces, quotes and trailing backslashes intact' -Skip:($IsWindows -or $env:OS -eq 'Windows_NT') {
        $r = Invoke-RtkProcess -FilePath '/bin/sh' -ArgumentList @('-c', 'printf "%s|" "$@"', 'sh', 'a b', 'c"d', 'e\')
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -BeExactly 'a b|c"d|e\|'
    }
    It 'kills the process on timeout and reports it without throwing' -Skip:($IsWindows -or $env:OS -eq 'Windows_NT') {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-RtkProcess -FilePath '/bin/sh' -ArgumentList @('-c', 'sleep 30') -TimeoutSec 1
        $sw.Stop()
        $r.TimedOut | Should -BeTrue
        $r.ExitCode | Should -Be -1
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 15
    }
    It 'does not throw when the executable does not exist' {
        $r = Invoke-RtkProcess -FilePath 'rcb-no-such-program-xyz' -ArgumentList @('x')
        $r.ExitCode | Should -Not -Be 0
        $r.StdErr | Should -Match 'could not start'
    }
}

Describe 'TOML parsing edge cases' {
    It 'keeps # inside basic and literal strings and honours escaped quotes' {
        Remove-TomlComment 'a = "x # y" # c' | Should -BeExactly 'a = "x # y" '
        Remove-TomlComment 'a = "x \" # y" # c' | Should -BeExactly 'a = "x \" # y" '
        Remove-TomlComment "a = 'x # y' # c" | Should -BeExactly "a = 'x # y' "
        Remove-TomlComment 'a = 1 # "quoted" comment' | Should -BeExactly 'a = 1 '
        Remove-TomlComment 'no comment' | Should -BeExactly 'no comment'
    }
    It 'matches the key literally, not as a regex' {
        Get-TomlKeyValue 'axb = "wrong"' 'a.b' | Should -BeNullOrEmpty
        Get-TomlKeyValue '{ a.b = "right", axb = "wrong" }' 'a.b' | Should -Be 'right'
        { Get-TomlKeyValue 'x = "1"' 'ta(g[' } | Should -Not -Throw
    }
    It 'ignores key-looking text inside other string values' {
        Get-TomlKeyValue 'note = "x, tag = ''v9.9.9''", tag = "v0.8.2"' 'tag' | Should -Be 'v0.8.2'
        Get-TomlKeyValue "git = 'https://github.com/ubcool2ic/rtk'" 'git' | Should -Be 'https://github.com/ubcool2ic/rtk'
    }
    It 'reads an inline table with nested arrays, a # in a string and a trailing comment' {
        $dir = New-TempDir
        $p = Join-Path $dir 'Cargo.toml'
        Write-Utf8 $p ("[dependencies]`n" + 'rtk = { features = ["tag = \"v9.9.9\"", "a#b"], git = "' + $script:RtkUrl + '", tag = "v0.8.2" } # old "pin"' + "`n")
        $d = @(Get-RtkDependency -ManifestPath $p)
        $d.Count | Should -Be 1
        $d[0].PinKind | Should -Be 'tag'
        $d[0].PinValue | Should -Be 'v0.8.2'
        $d[0].LineIndex | Should -Be 1
    }
    It 'reads a manifest with a UTF-8 BOM, CRLF and a single-quoted tag' {
        $dir = New-TempDir
        $p = Join-Path $dir 'Cargo.toml'
        Write-Utf8 $p ("[dependencies]`r`nrtk = { git = '" + $script:RtkUrl + "', tag = 'v0.8.2' }`r`n") -Bom
        $d = @(Get-RtkDependency -ManifestPath $p)
        $d.Count | Should -Be 1
        $d[0].Section | Should -Be 'dependencies'
        $d[0].PinValue | Should -Be 'v0.8.2'
    }
    It 'finds several rtk deps in one file (inline, renamed, table form, dotted keys)' {
        $dir = New-TempDir
        $p = Join-Path $dir 'Cargo.toml'
        $text = @(
            '[package]'
            'name = "multi"'
            ''
            '[dependencies]'
            ('rtk = { git = "' + $script:RtkUrl + '", tag = "v0.8.2" }')
            ''
            '[dev-dependencies]'
            ('gui = { package = "rtk", git = "' + $script:RtkUrl + '.git", tag = "v1.0.0" }')
            ('extra.git = "' + $script:RtkUrl + '"')
            'extra.branch = "main"'
            ''
            '[build-dependencies.rtk]'
            ('git = "' + $script:RtkUrl + '"')
            "tag = 'v0.8.2'"
        ) -join "`n"
        Write-Utf8 $p $text
        $d = @(Get-RtkDependency -ManifestPath $p)
        $d.Count | Should -Be 4
        @($d | Where-Object PinKind -eq 'tag').Count | Should -Be 3
        $dot = $d | Where-Object Form -eq 'dotted'
        $dot.DepName | Should -Be 'extra'
        $dot.PinKind | Should -Be 'branch'
        ($d | Where-Object Form -eq 'table').LineIndex | Should -Be 13
    }
    It 'returns nothing for a file that never mentions rtk' {
        $dir = New-TempDir
        $p = Join-Path $dir 'Cargo.toml'
        Write-Utf8 $p "[package]`nname = `"x`"`n[dependencies]`nserde = `"1`"`n"
        @(Get-RtkDependency -ManifestPath $p).Count | Should -Be 0
    }
    It 'only accepts real rtk repository URLs' {
        Test-RtkGitUrl 'https://github.com/ubcool2ic/rtk' | Should -BeTrue
        Test-RtkGitUrl 'https://github.com/ubcool2ic/rtk.git' | Should -BeTrue
        Test-RtkGitUrl 'git@github.com:ubcool2ic/rtk.git' | Should -BeTrue
        Test-RtkGitUrl 'ssh://git@github.com/ubcool2ic/rtk' | Should -BeTrue
        Test-RtkGitUrl 'https://evil.example/github.com/ubcool2ic/rtk' | Should -BeFalse
        Test-RtkGitUrl 'https://notgithub.com/ubcool2ic/rtk' | Should -BeFalse
        Test-RtkGitUrl '--upload-pack=touch x github.com/ubcool2ic/rtk' | Should -BeFalse
        Test-RtkGitUrl '-oProxyCommand=x@github.com:ubcool2ic/rtk' | Should -BeFalse
    }
    It 'treats a tag with an absurdly large number as non-semver instead of throwing' {
        ConvertTo-RtkVersion 'v99999999999.0.0' | Should -BeNullOrEmpty
    }
}

Describe 'Set-RtkTagPin' {
    It 'preserves the BOM, CRLF, single quotes and leaves no temp file' {
        $dir = New-TempDir
        $p = Join-Path $dir 'Cargo.toml'
        Write-Utf8 $p ("[dependencies]`r`nrtk = { git = '" + $script:RtkUrl + "', tag = 'v0.8.2' } # c`r`n") -Bom
        Set-RtkTagPin -ManifestPath $p -LineIndex 1 -OldTag 'v0.8.2' -NewTag 'v1.0.1'
        $bytes = [System.IO.File]::ReadAllBytes($p)
        $bytes[0] | Should -Be 0xEF
        $bytes[1] | Should -Be 0xBB
        $bytes[2] | Should -Be 0xBF
        $bytes[3] | Should -Be ([byte][char]'[')
        $text = [System.IO.File]::ReadAllText($p)
        $text | Should -BeExactly ("[dependencies]`r`nrtk = { git = '" + $script:RtkUrl + "', tag = 'v1.0.1' } # c`r`n")
        @(Get-ChildItem -LiteralPath $dir -Force).Count | Should -Be 1
    }
    It 'does not add a BOM or a trailing newline that was not there' {
        $dir = New-TempDir
        $p = Join-Path $dir 'Cargo.toml'
        Write-Utf8 $p ("[dependencies]`nrtk = { git = `"" + $script:RtkUrl + "`", tag = `"v0.8.2`" }")
        Set-RtkTagPin -ManifestPath $p -LineIndex 1 -OldTag 'v0.8.2' -NewTag 'v1.0.1'
        $bytes = [System.IO.File]::ReadAllBytes($p)
        $bytes[0] | Should -Be ([byte][char]'[')
        $bytes[$bytes.Length - 1] | Should -Be ([byte][char]'}')
    }
    It 'keeps mixed line endings exactly as they were' {
        $dir = New-TempDir
        $p = Join-Path $dir 'Cargo.toml'
        Write-Utf8 $p ("[package]`r`nname = `"x`"`n[dependencies]`r`nrtk = { git = `"" + $script:RtkUrl + "`", tag = `"v0.8.2`" }`n`n")
        Set-RtkTagPin -ManifestPath $p -LineIndex 3 -OldTag 'v0.8.2' -NewTag 'v1.0.1'
        [System.IO.File]::ReadAllText($p) | Should -BeExactly ("[package]`r`nname = `"x`"`n[dependencies]`r`nrtk = { git = `"" + $script:RtkUrl + "`", tag = `"v1.0.1`" }`n`n")
    }
    It 'throws and leaves the file untouched when the tag is not on that line' {
        $dir = New-TempDir
        $p = Join-Path $dir 'Cargo.toml'
        $orig = "[dependencies]`nrtk = { git = `"" + $script:RtkUrl + "`", tag = `"v0.8.2`" }`n"
        Write-Utf8 $p $orig
        { Set-RtkTagPin -ManifestPath $p -LineIndex 0 -OldTag 'v0.8.2' -NewTag 'v1.0.1' } | Should -Throw
        { Set-RtkTagPin -ManifestPath $p -LineIndex 1 -OldTag 'v0.8.2' -NewTag 'v1"x' } | Should -Throw
        [System.IO.File]::ReadAllText($p) | Should -BeExactly $orig
    }
}

Describe 'Backup, restore and rollback' {
    BeforeEach {
        $script:RtkLatestCache = @{}
        Mock Invoke-RtkLsRemote { [PSCustomObject]@{ ExitCode = 0; StdOut = $script:LsRemoteOut; StdErr = '' } }
        Mock Invoke-RtkCargoUpdate { [PSCustomObject]@{ ExitCode = 0; Lines = @('    Updating git repository') } }
    }
    AfterEach { Remove-Item Env:\RCB_TEST_MARKER -ErrorAction SilentlyContinue }

    It 'removes a Cargo.lock created by a failed cargo update when none existed before' {
        Mock Invoke-RtkCargoUpdate {
            [System.IO.File]::WriteAllText((Join-Path $WorkingDirectory 'Cargo.lock'), 'new lock')
            [PSCustomObject]@{ ExitCode = 101; Lines = @('error: failed to fetch rtk') }
        }
        $dir = Copy-Fixture 'tag-old'
        $before = [System.IO.File]::ReadAllText((Join-Path $dir 'Cargo.toml'))
        $r = Invoke-RtkUpdateCheck -ManifestPath (Join-Path $dir 'Cargo.toml') -BackupRoot (Join-Path $dir '_built')
        $r.Changed | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $dir 'Cargo.lock') | Should -BeFalse
        [System.IO.File]::ReadAllText((Join-Path $dir 'Cargo.toml')) | Should -BeExactly $before
    }
    It 'Restore-RtkBackup deletes the new lock and restores the manifest after a successful bump' {
        Mock Invoke-RtkCargoUpdate {
            [System.IO.File]::WriteAllText((Join-Path $WorkingDirectory 'Cargo.lock'), 'new lock')
            [PSCustomObject]@{ ExitCode = 0; Lines = @() }
        }
        $dir = Copy-Fixture 'tag-old'
        $before = [System.IO.File]::ReadAllText((Join-Path $dir 'Cargo.toml'))
        $r = Invoke-RtkUpdateCheck -ManifestPath (Join-Path $dir 'Cargo.toml') -BackupRoot (Join-Path $dir '_built')
        $r.Changed | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $dir 'Cargo.lock') | Should -BeTrue
        Restore-RtkBackup -Pairs $r.Backup
        Test-Path -LiteralPath (Join-Path $dir 'Cargo.lock') | Should -BeFalse
        [System.IO.File]::ReadAllText((Join-Path $dir 'Cargo.toml')) | Should -BeExactly $before
    }
    It 'restores an existing Cargo.lock byte for byte when cargo update fails' {
        Mock Invoke-RtkCargoUpdate {
            [System.IO.File]::WriteAllText((Join-Path $WorkingDirectory 'Cargo.lock'), 'changed lock')
            [PSCustomObject]@{ ExitCode = 101; Lines = @('error: boom') }
        }
        $dir = Copy-Fixture 'tag-old'
        [System.IO.File]::WriteAllText((Join-Path $dir 'Cargo.lock'), "old lock`r`n")
        $null = Invoke-RtkUpdateCheck -ManifestPath (Join-Path $dir 'Cargo.toml') -BackupRoot (Join-Path $dir '_built')
        [System.IO.File]::ReadAllText((Join-Path $dir 'Cargo.lock')) | Should -BeExactly "old lock`r`n"
    }
    It 'rolls back and does not throw when cargo update throws' {
        Mock Invoke-RtkCargoUpdate { throw 'cargo could not be started' }
        $dir = Copy-Fixture 'tag-old'
        $before = [System.IO.File]::ReadAllText((Join-Path $dir 'Cargo.toml'))
        $r = Invoke-RtkUpdateCheck -ManifestPath (Join-Path $dir 'Cargo.toml') -BackupRoot (Join-Path $dir '_built')
        $r.Changed | Should -BeFalse
        $r.Status | Should -Match 'cargo update -p rtk failed; kept v0\.8\.2'
        [System.IO.File]::ReadAllText((Join-Path $dir 'Cargo.toml')) | Should -BeExactly $before
    }
    It 'restores every manifest when the bump fails half way through a workspace' {
        $env:RCB_TEST_MARKER = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Mock Set-RtkTagPin {
            if (Test-Path -LiteralPath $env:RCB_TEST_MARKER) { throw 'disk full' }
            [System.IO.File]::WriteAllText($env:RCB_TEST_MARKER, 'x')
            [System.IO.File]::WriteAllText($ManifestPath, 'HALF WRITTEN')
        }
        $dir = Copy-Fixture 'workspace'
        $rootBefore = [System.IO.File]::ReadAllText((Join-Path $dir 'Cargo.toml'))
        $memberBefore = [System.IO.File]::ReadAllText((Join-Path $dir 'widgets/Cargo.toml'))
        $r = Invoke-RtkUpdateCheck -ManifestPath (Join-Path $dir 'Cargo.toml') -BackupRoot (Join-Path $dir '_built')
        $r.Changed | Should -BeFalse
        $r.Status | Should -Match 'pin rewrite'
        [System.IO.File]::ReadAllText((Join-Path $dir 'Cargo.toml')) | Should -BeExactly $rootBefore
        [System.IO.File]::ReadAllText((Join-Path $dir 'widgets/Cargo.toml')) | Should -BeExactly $memberBefore
        Test-Path -LiteralPath (Join-Path $dir 'Cargo.lock') | Should -BeFalse
        Should -Invoke Invoke-RtkCargoUpdate -Times 0
    }
    It 'bumps every rtk tag in one file, keeping each quote style' {
        $dir = New-TempDir
        $p = Join-Path $dir 'Cargo.toml'
        $text = @(
            '[dependencies]'
            ('rtk = { git = "' + $script:RtkUrl + '", tag = "v0.8.2" }')
            '[dev-dependencies]'
            ('gui = { package = "rtk", git = "' + $script:RtkUrl + '", tag = "v1.0.0" }')
            '[build-dependencies.rtk]'
            ('git = "' + $script:RtkUrl + '"')
            "tag = 'v0.8.2'"
            ''
        ) -join "`n"
        Write-Utf8 $p $text
        $r = Invoke-RtkUpdateCheck -ManifestPath $p -BackupRoot (Join-Path $dir '_built')
        $r.Changed | Should -BeTrue
        @($r.Changes).Count | Should -Be 3
        $after = [System.IO.File]::ReadAllText($p)
        ([regex]::Matches($after, 'v1\.0\.1')).Count | Should -Be 3
        $after | Should -Match "tag = 'v1\.0\.1'"
        $after | Should -Not -Match 'v0\.8\.2|v1\.0\.0'
    }
    It 'makes file-name safe folder names and keeps unicode' {
        $safe = ConvertTo-RcbSafeFileName 'my proj: <x>|?* "q" a/b\c. '
        $safe | Should -Not -Match '[<>:"/\\|?*]'
        $safe | Should -Not -Match '[. ]$'
        $name = 'caf' + [char]0x00E9 + ' app'
        ConvertTo-RcbSafeFileName $name | Should -BeExactly $name
        ConvertTo-RcbSafeFileName '...' | Should -Be 'project'
        (ConvertTo-RcbSafeFileName ('x' * 200)).Length | Should -BeLessOrEqual 48
    }
    It 'never reuses a backup folder for two projects with the same name' {
        $root = New-TempDir
        $a = New-RtkBackupDirectory -BackupRoot $root -ProjectName 'app'
        $b = New-RtkBackupDirectory -BackupRoot $root -ProjectName 'app'
        $a | Should -Not -Be $b
        Test-Path -LiteralPath $a -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $b -PathType Container | Should -BeTrue
    }
    It 'backs up and bumps a project whose folder has spaces, brackets and unicode' {
        $parent = New-TempDir
        $dir = Join-Path $parent ('my caf' + [char]0x00E9 + ' [app]')
        Copy-Item -LiteralPath (Join-Path $script:Fixtures 'tag-old') -Destination $dir -Recurse
        $before = [System.IO.File]::ReadAllText((Join-Path $dir 'Cargo.toml'))
        $r = Invoke-RtkUpdateCheck -ManifestPath (Join-Path $dir 'Cargo.toml') -BackupRoot (Join-Path $dir '_built')
        $r.Changed | Should -BeTrue
        $pair = @($r.Backup | Where-Object { $_.Original -like '*Cargo.toml' })[0]
        [System.IO.File]::ReadAllText($pair.Backup) | Should -BeExactly $before
        [System.IO.File]::ReadAllText((Join-Path $dir 'Cargo.toml')) | Should -Match 'tag = "v1\.0\.1"'
    }
}

Describe 'Get-RcbCargoManifest' {
    BeforeEach {
        $script:Tree = New-TempDir
        foreach ($rel in @('Cargo.toml', 'a/Cargo.toml', 'a/b/Cargo.toml', 'target/x/Cargo.toml', 'a/Target/y/Cargo.toml',
                'a/node_modules/m/Cargo.toml', '.git/Cargo.toml', '_built/p/Cargo.toml', 'a/b/.git/z/Cargo.toml')) {
            Write-Utf8 (Join-Path $script:Tree $rel) "[package]`nname = `"x`"`n"
        }
    }
    It 'never descends into target, .git, node_modules or _built (any case)' {
        $found = @(Get-RcbCargoManifest -RootDirectory $script:Tree)
        $found.Count | Should -Be 3
        @($found | Where-Object { $_ -match '[\\/](target|\.git|node_modules|_built)[\\/]' }).Count | Should -Be 0
        $found[0] | Should -Be (Join-Path $script:Tree 'Cargo.toml')
    }
    It 'does not follow a symlink loop' -Skip:($IsWindows -or $env:OS -eq 'Windows_NT') {
        New-Item -ItemType SymbolicLink -Path (Join-Path $script:Tree 'a/loop') -Target $script:Tree | Out-Null
        $found = @(Get-RcbCargoManifest -RootDirectory $script:Tree)
        $found.Count | Should -Be 3
    }
    It 'stops at a workspace root with -ExcludeWorkspaceMembers' {
        $root = New-TempDir
        Write-Utf8 (Join-Path $root 'ws/Cargo.toml') "[workspace]`nmembers = [`"m`"]`n"
        Write-Utf8 (Join-Path $root 'ws/m/Cargo.toml') "[package]`nname = `"m`"`n"
        Write-Utf8 (Join-Path $root 'solo/Cargo.toml') "[package]`nname = `"solo`"`n"
        $found = @(Get-RcbCargoManifest -RootDirectory $root -ExcludeWorkspaceMembers)
        $found.Count | Should -Be 2
        @($found | Where-Object { $_ -like '*m?Cargo.toml' -and $_ -like '*ws*' -and $_ -notlike '*ws?Cargo.toml' }).Count | Should -Be 0
        @(Get-RcbCargoManifest -RootDirectory $root).Count | Should -Be 3
    }
    It 'returns nothing for a folder that does not exist' {
        @(Get-RcbCargoManifest -RootDirectory (Join-Path $TestDrive 'does-not-exist')).Count | Should -Be 0
    }
    It 'Get-ProjectManifestSet lists members but nothing under target' {
        $root = New-TempDir
        Write-Utf8 (Join-Path $root 'Cargo.toml') "[workspace]`nmembers = [`"m`"]`n"
        Write-Utf8 (Join-Path $root 'm/Cargo.toml') "[package]`nname = `"m`"`n"
        Write-Utf8 (Join-Path $root 'target/package/m-0.1.0/Cargo.toml') "[package]`nname = `"m`"`n"
        $set = @(Get-ProjectManifestSet -ManifestPath (Join-Path $root 'Cargo.toml'))
        $set.Count | Should -Be 2
        $set[0] | Should -Be (Join-Path $root 'Cargo.toml')
    }
}

Describe 'Get-RtkLatestRelease failure handling' {
    BeforeEach { $script:RtkLatestCache = @{}; $script:savedToken = $env:GH_TOKEN; $env:GH_TOKEN = '' }
    AfterEach { $env:GH_TOKEN = $script:savedToken }

    It 'does not cache a failure, so a later lookup is tried again' {
        Mock Invoke-RtkLsRemote { [PSCustomObject]@{ ExitCode = 128; StdOut = ''; StdErr = 'fatal: unable to access' } }
        $a = Get-RtkLatestRelease
        $b = Get-RtkLatestRelease
        $a.Tag | Should -BeNullOrEmpty
        $b.Error | Should -Match 'git ls-remote failed'
        Should -Invoke Invoke-RtkLsRemote -Times 2 -Exactly
    }
    It 'never throws, even when both lookups throw' {
        $env:GH_TOKEN = 'test-token'
        Mock Invoke-RtkLsRemote { throw 'git exploded' }
        Mock Invoke-RtkTagApi { throw 'api exploded' }
        $r = $null
        { $script:latestResult = Get-RtkLatestRelease } | Should -Not -Throw
        $r = $script:latestResult
        $r.Tag | Should -BeNullOrEmpty
        $r.Error | Should -Match 'git exploded'
        $r.Error | Should -Match 'api exploded'
    }
}

Describe 'Console colour helpers' {
    It 'writes plain text when RtkPlainConsole is set' {
        $savedPlain = $script:RtkPlainConsole; $savedTrue = $script:RtkTrueColor
        try {
            $script:RtkTrueColor = $true
            $script:RtkPlainConsole = $true
            $out = (Write-RtkSegment 'hello' 'danger' -NewLine 6>&1 | Out-String).Trim()
            $out | Should -BeExactly 'hello'
        } finally { $script:RtkPlainConsole = $savedPlain; $script:RtkTrueColor = $savedTrue }
    }
    It 'emits the rtk truecolour sequence for a role' {
        $savedPlain = $script:RtkPlainConsole; $savedTrue = $script:RtkTrueColor
        try {
            $script:RtkTrueColor = $true
            $script:RtkPlainConsole = $false
            # Read the raw message: Out-String would strip ANSI on pwsh 7.2+.
            $out = (@(Write-RtkSegment 'hello' 'danger' -NewLine 6>&1) | ForEach-Object { [string]$_.MessageData.Message }) -join ''
            $rgb = Get-RtkRoleRgb 'danger'
            $out | Should -Match ('38;2;{0};{1};{2}m' -f $rgb[0], $rgb[1], $rgb[2])
            $out | Should -Match 'hello'
        } finally { $script:RtkPlainConsole = $savedPlain; $script:RtkTrueColor = $savedTrue }
    }
}
