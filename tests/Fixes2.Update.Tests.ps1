#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Regression tests for the second round of fixes in lib/RtkUpdate.ps1:
# URL normalization, https-first latest-tag lookup, API pagination, long paths.
# Network and processes are mocked; nothing here talks to GitHub or needs Rust.
# Run: Invoke-Pester ./tests

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:Root (Join-Path 'lib' 'RtkTheme.ps1'))
    . (Join-Path $script:Root (Join-Path 'lib' 'RtkUpdate.ps1'))

    $script:RtkUrl = 'https://github.com/ubcool2ic/rtk'
}

Describe 'ConvertTo-RtkHttpsUrl' {
    It 'maps <Url> to the canonical https URL' -ForEach @(
        @{ Url = 'git@github.com:ubcool2ic/rtk.git' }
        @{ Url = 'git@github.com:ubcool2ic/rtk' }
        @{ Url = 'ssh://git@github.com/ubcool2ic/rtk' }
        @{ Url = 'ssh://git@github.com/ubcool2ic/rtk.git' }
        @{ Url = 'ssh://git@github.com:22/ubcool2ic/rtk.git' }
        @{ Url = 'git://github.com/ubcool2ic/rtk.git' }
        @{ Url = 'http://github.com/ubcool2ic/rtk' }
        @{ Url = 'https://github.com/ubcool2ic/rtk' }
        @{ Url = 'https://github.com/ubcool2ic/rtk.git' }
        @{ Url = 'https://github.com/ubcool2ic/rtk/' }
        @{ Url = 'https://github.com/ubcool2ic/rtk.git/' }
        @{ Url = 'https://user@github.com/ubcool2ic/rtk.git' }
        @{ Url = 'HTTPS://GitHub.com/UbCool2ic/RTK' }
        @{ Url = '  https://github.com/ubcool2ic/rtk  ' }
    ) {
        ConvertTo-RtkHttpsUrl $Url | Should -BeExactly 'https://github.com/ubcool2ic/rtk'
    }

    It 'returns null for non-rtk "<Url>"' -ForEach @(
        @{ Url = 'https://github.com/other/rtk' }
        @{ Url = 'https://github.com/ubcool2ic/rtk2' }
        @{ Url = 'https://evil.example/github.com/ubcool2ic/rtk' }
        @{ Url = 'git@gitlab.com:ubcool2ic/rtk.git' }
        @{ Url = '--upload-pack=touch /tmp/x' }
        @{ Url = '' }
    ) {
        ConvertTo-RtkHttpsUrl $Url | Should -BeNullOrEmpty
    }

    It 'returns null for $null' {
        ConvertTo-RtkHttpsUrl $null | Should -BeNullOrEmpty
    }
}

Describe 'Get-RtkLatestRelease URL handling' {
    BeforeEach {
        $script:RtkLatestCache = @{}
        $script:SavedToken = $env:GH_TOKEN
        Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue
    }
    AfterEach {
        if ($null -ne $script:SavedToken) { $env:GH_TOKEN = $script:SavedToken } else { Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue }
    }

    It 'asks the https URL first with a 15 s timeout for an ssh-only dep URL' {
        Mock Invoke-RtkLsRemote {
            [PSCustomObject]@{
                ExitCode = 0
                StdOut   = "b630eb22aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`trefs/tags/v1.0.0`n85125ab0d7efaa8b37279e10276a9b60e826901a`trefs/tags/v1.0.1`n431514bfbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb`trefs/tags/v0.8.2"
                StdErr   = ''
                TimedOut = $false
            }
        }
        $r = Get-RtkLatestRelease -RepoUrl 'git@github.com:ubcool2ic/rtk.git'
        $r.Tag | Should -Be 'v1.0.1'
        $r.Sha | Should -Be '85125ab0d7efaa8b37279e10276a9b60e826901a'
        $r.Source | Should -Be 'git ls-remote'
        $r.Error | Should -BeNullOrEmpty
        $r.TagShas.Count | Should -Be 3
        Should -Invoke Invoke-RtkLsRemote -Times 1 -Exactly
        Should -Invoke Invoke-RtkLsRemote -Times 1 -Exactly -ParameterFilter { $RepoUrl -ceq 'https://github.com/ubcool2ic/rtk' -and $TimeoutSec -eq 15 }
    }

    It 'falls back to the original ssh URL when https fails' {
        Mock Invoke-RtkLsRemote {
            [PSCustomObject]@{ ExitCode = 128; StdOut = ''; StdErr = 'fatal: could not read Username'; TimedOut = $false }
        } -ParameterFilter { $RepoUrl -like 'https://*' }
        Mock Invoke-RtkLsRemote {
            [PSCustomObject]@{ ExitCode = 0; StdOut = "85125ab0d7efaa8b37279e10276a9b60e826901a`trefs/tags/v1.0.1"; StdErr = ''; TimedOut = $false }
        } -ParameterFilter { $RepoUrl -like 'git@*' }
        $r = Get-RtkLatestRelease -RepoUrl 'git@github.com:ubcool2ic/rtk.git'
        $r.Tag | Should -Be 'v1.0.1'
        $r.Source | Should -Be 'git ls-remote'
        Should -Invoke Invoke-RtkLsRemote -Times 2 -Exactly
        Should -Invoke Invoke-RtkLsRemote -Times 1 -Exactly -ParameterFilter { $RepoUrl -ceq 'https://github.com/ubcool2ic/rtk' -and $TimeoutSec -eq 15 }
        Should -Invoke Invoke-RtkLsRemote -Times 1 -Exactly -ParameterFilter { $RepoUrl -ceq 'git@github.com:ubcool2ic/rtk.git' -and $TimeoutSec -eq 15 }
    }

    It 'tries distinct -AlternateUrls only once each after https failed' {
        Mock Invoke-RtkLsRemote {
            [PSCustomObject]@{ ExitCode = 128; StdOut = ''; StdErr = 'fatal: nope'; TimedOut = $false }
        } -ParameterFilter { $RepoUrl -like 'https://*' }
        Mock Invoke-RtkLsRemote {
            [PSCustomObject]@{ ExitCode = 0; StdOut = "85125ab0d7efaa8b37279e10276a9b60e826901a`trefs/tags/v1.0.1"; StdErr = ''; TimedOut = $false }
        } -ParameterFilter { $RepoUrl -like 'ssh://*' }
        $alts = @('https://github.com/ubcool2ic/rtk', 'ssh://git@github.com/ubcool2ic/rtk', 'ssh://git@github.com/ubcool2ic/rtk')
        $r = Get-RtkLatestRelease -RepoUrl 'https://github.com/ubcool2ic/rtk' -AlternateUrls $alts
        $r.Tag | Should -Be 'v1.0.1'
        Should -Invoke Invoke-RtkLsRemote -Times 2 -Exactly
        Should -Invoke Invoke-RtkLsRemote -Times 1 -Exactly -ParameterFilter { $RepoUrl -ceq 'ssh://git@github.com/ubcool2ic/rtk' -and $TimeoutSec -eq 15 }
    }

    It 'does not try alternates when https worked' {
        Mock Invoke-RtkLsRemote {
            [PSCustomObject]@{ ExitCode = 0; StdOut = "85125ab0d7efaa8b37279e10276a9b60e826901a`trefs/tags/v1.0.1"; StdErr = ''; TimedOut = $false }
        }
        $r = Get-RtkLatestRelease -RepoUrl 'https://github.com/ubcool2ic/rtk.git' -AlternateUrls @('git@github.com:ubcool2ic/rtk.git')
        $r.Tag | Should -Be 'v1.0.1'
        Should -Invoke Invoke-RtkLsRemote -Times 1 -Exactly
    }

    It 'caches per normalized URL (ssh and https spellings share one lookup)' {
        Mock Invoke-RtkLsRemote {
            [PSCustomObject]@{ ExitCode = 0; StdOut = "85125ab0d7efaa8b37279e10276a9b60e826901a`trefs/tags/v1.0.1"; StdErr = ''; TimedOut = $false }
        }
        $a = Get-RtkLatestRelease -RepoUrl 'git@github.com:ubcool2ic/rtk.git'
        $b = Get-RtkLatestRelease -RepoUrl 'https://github.com/ubcool2ic/rtk'
        $c = Get-RtkLatestRelease -RepoUrl 'ssh://git@github.com/ubcool2ic/rtk' -AlternateUrls @('git@github.com:ubcool2ic/rtk.git')
        $a.Tag | Should -Be 'v1.0.1'
        $b.Tag | Should -Be 'v1.0.1'
        $c.Tag | Should -Be 'v1.0.1'
        Should -Invoke Invoke-RtkLsRemote -Times 1 -Exactly
    }

    It 'does not cache a failure; a later lookup is tried again and keeps the result shape' {
        Mock Invoke-RtkLsRemote {
            [PSCustomObject]@{ ExitCode = 128; StdOut = ''; StdErr = 'fatal: offline'; TimedOut = $false }
        }
        $a = Get-RtkLatestRelease -RepoUrl 'https://github.com/ubcool2ic/rtk'
        $b = Get-RtkLatestRelease -RepoUrl 'https://github.com/ubcool2ic/rtk'
        $a.Tag | Should -BeNullOrEmpty
        $a.Error | Should -Match 'git ls-remote failed \(exit 128\)'
        $a.Error | Should -Match 'GH_TOKEN is not set'
        $b.Error | Should -Be $a.Error
        @($a.PSObject.Properties.Name) | Should -Be @('Tag', 'Sha', 'Source', 'TagShas', 'Error')
        Should -Invoke Invoke-RtkLsRemote -Times 2 -Exactly
    }
}

Describe 'Invoke-RtkTagApi pagination' {
    BeforeEach {
        $script:RtkLatestCache = @{}
        $script:SavedToken = $env:GH_TOKEN
    }
    AfterEach {
        if ($null -ne $script:SavedToken) { $env:GH_TOKEN = $script:SavedToken } else { Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue }
    }

    It 'reads 3 pages (100, 100, 7) and returns 207 tags' {
        Mock Invoke-RtkTagApiPage {
            if ($Page -eq 1) { return @(0..99 | ForEach-Object { [PSCustomObject]@{ Name = "v0.1.$_"; Sha = ('a' * 40) } }) }
            if ($Page -eq 2) { return @(0..99 | ForEach-Object { [PSCustomObject]@{ Name = "v0.2.$_"; Sha = ('b' * 40) } }) }
            if ($Page -eq 3) {
                $last = @(0..4 | ForEach-Object { [PSCustomObject]@{ Name = "v0.3.$_"; Sha = ('d' * 40) } })
                $last += [PSCustomObject]@{ Name = 'v9.9.9'; Sha = ('C' * 40) }
                $last += [PSCustomObject]@{ Name = 'v10.0.0-rc1'; Sha = ('e' * 40) }
                return $last
            }
            throw "unexpected page $Page"
        }
        $tags = @(Invoke-RtkTagApi -Token 't')
        $tags.Count | Should -Be 207
        Should -Invoke Invoke-RtkTagApiPage -Times 3 -Exactly
        Should -Invoke Invoke-RtkTagApiPage -Times 1 -Exactly -ParameterFilter { $Page -eq 3 -and $Token -eq 't' }
    }

    It 'Get-RtkLatestRelease picks the max stable tag from page 3' {
        Mock Invoke-RtkLsRemote {
            [PSCustomObject]@{ ExitCode = 128; StdOut = ''; StdErr = 'fatal: offline'; TimedOut = $false }
        }
        Mock Invoke-RtkTagApiPage {
            if ($Page -eq 1) { return @(0..99 | ForEach-Object { [PSCustomObject]@{ Name = "v0.1.$_"; Sha = ('a' * 40) } }) }
            if ($Page -eq 2) { return @(0..99 | ForEach-Object { [PSCustomObject]@{ Name = "v0.2.$_"; Sha = ('b' * 40) } }) }
            if ($Page -eq 3) {
                $last = @(0..4 | ForEach-Object { [PSCustomObject]@{ Name = "v0.3.$_"; Sha = ('d' * 40) } })
                $last += [PSCustomObject]@{ Name = 'v9.9.9'; Sha = ('C' * 40) }
                $last += [PSCustomObject]@{ Name = 'v10.0.0-rc1'; Sha = ('e' * 40) }
                return $last
            }
            throw "unexpected page $Page"
        }
        $env:GH_TOKEN = 't'
        $r = Get-RtkLatestRelease -RepoUrl 'https://github.com/ubcool2ic/rtk'
        $r.Tag | Should -Be 'v9.9.9'
        $r.Sha | Should -BeExactly ('c' * 40)
        $r.Source | Should -Be 'GitHub API (GH_TOKEN)'
        $r.TagShas.Count | Should -Be 207
    }

    It 'stops on an error on a later page and keeps the earlier pages' {
        Mock Invoke-RtkTagApiPage {
            if ($Page -eq 1) { return @(0..99 | ForEach-Object { [PSCustomObject]@{ Name = "v0.1.$_"; Sha = ('a' * 40) } }) }
            throw 'HTTP 502'
        }
        $tags = @(Invoke-RtkTagApi -Token 't')
        $tags.Count | Should -Be 100
        Should -Invoke Invoke-RtkTagApiPage -Times 2 -Exactly
    }

    It 'throws when the very first page fails' {
        Mock Invoke-RtkTagApiPage { throw 'HTTP 401' }
        { Invoke-RtkTagApi -Token 't' } | Should -Throw '*401*'
        Should -Invoke Invoke-RtkTagApiPage -Times 1 -Exactly
    }

    It 'stops after an empty page that follows a full page' {
        Mock Invoke-RtkTagApiPage {
            if ($Page -eq 1) { return @(0..99 | ForEach-Object { [PSCustomObject]@{ Name = "v0.1.$_"; Sha = ('a' * 40) } }) }
            return @()
        }
        $tags = @(Invoke-RtkTagApi -Token 't')
        $tags.Count | Should -Be 100
        Should -Invoke Invoke-RtkTagApiPage -Times 2 -Exactly
    }

    It 'never reads more than 20 pages' {
        Mock Invoke-RtkTagApiPage {
            $p = $Page
            return @(0..99 | ForEach-Object { [PSCustomObject]@{ Name = "v$p.0.$_"; Sha = ('a' * 40) } })
        }
        $tags = @(Invoke-RtkTagApi -Token 't')
        $tags.Count | Should -Be 2000
        Should -Invoke Invoke-RtkTagApiPage -Times 20 -Exactly
    }
}

Describe 'ConvertTo-RcbLongPath' {
    It 'prefixes a drive path with -Force' {
        ConvertTo-RcbLongPath 'C:\a\b' -Force | Should -BeExactly '\\?\C:\a\b'
    }
    It 'prefixes a UNC path with -Force' {
        ConvertTo-RcbLongPath '\\srv\share\x' -Force | Should -BeExactly '\\?\UNC\srv\share\x'
    }
    It 'never double-prefixes' {
        ConvertTo-RcbLongPath '\\?\C:\a\b' -Force | Should -BeExactly '\\?\C:\a\b'
        ConvertTo-RcbLongPath '\\?\UNC\srv\share\x' -Force | Should -BeExactly '\\?\UNC\srv\share\x'
        ConvertTo-RcbLongPath (ConvertTo-RcbLongPath 'C:\a\b' -Force) -Force | Should -BeExactly '\\?\C:\a\b'
    }
    It 'leaves a short path alone without -Force' {
        ConvertTo-RcbLongPath 'C:\a\b' | Should -BeExactly 'C:\a\b'
        ConvertTo-RcbLongPath '\\srv\share\x' | Should -BeExactly '\\srv\share\x'
    }
    It 'leaves relative and non-Windows paths alone even with -Force' {
        ConvertTo-RcbLongPath 'a\b' -Force | Should -BeExactly 'a\b'
        ConvertTo-RcbLongPath '/tmp/a/b' -Force | Should -BeExactly '/tmp/a/b'
        ConvertTo-RcbLongPath '' -Force | Should -BeNullOrEmpty
    }
    It 'ConvertFrom-RcbLongPath strips the prefix again' {
        ConvertFrom-RcbLongPath '\\?\C:\a\b' | Should -BeExactly 'C:\a\b'
        ConvertFrom-RcbLongPath '\\?\UNC\srv\share\x' | Should -BeExactly '\\srv\share\x'
        ConvertFrom-RcbLongPath 'C:\a\b' | Should -BeExactly 'C:\a\b'
    }
    It 'Get-RcbErrorText gives the long-path hint for PathTooLongException (also when wrapped)' {
        $inner = New-Object System.IO.PathTooLongException 'too long'
        $outer = New-Object System.Exception('wrapped', $inner)
        Get-RcbErrorText $inner | Should -Match 'path is longer than 260 characters'
        Get-RcbErrorText $outer | Should -Match 'LongPathsEnabled=1'
        Get-RcbErrorText (New-Object System.Exception 'plain') | Should -Be 'plain'
    }
}

Describe 'File operations still return plain paths' {
    It 'Get-RcbCargoManifest lists manifests un-prefixed, parents first, pruning target' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($d in @($root, (Join-Path $root 'a'), (Join-Path (Join-Path $root 'target') 'x'))) {
            [System.IO.Directory]::CreateDirectory($d) | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $d 'Cargo.toml'), "[package]`nname = `"x`"`n")
        }
        $found = @(Get-RcbCargoManifest -RootDirectory $root)
        $found.Count | Should -Be 2
        $found[0] | Should -Be (Join-Path $root 'Cargo.toml')
        $found[1] | Should -Be (Join-Path (Join-Path $root 'a') 'Cargo.toml')
    }

    It 'Backup-RtkFile and Restore-RtkBackup round-trip' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [System.IO.Directory]::CreateDirectory($root) | Out-Null
        $toml = Join-Path $root 'Cargo.toml'
        $lock = Join-Path $root 'Cargo.lock'
        [System.IO.File]::WriteAllText($toml, 'old')
        $pairs = Backup-RtkFile -Files @($toml, $lock) -BackupDir (Join-Path $root 'bk')
        $pairs.Count | Should -Be 2
        $pairs[0].Backup | Should -Not -BeLike '\\?\*'
        [System.IO.File]::WriteAllText($toml, 'new')
        [System.IO.File]::WriteAllText($lock, 'made by update')
        Restore-RtkBackup -Pairs $pairs
        [System.IO.File]::ReadAllText($toml) | Should -Be 'old'
        [System.IO.File]::Exists($lock) | Should -BeFalse
    }
}
