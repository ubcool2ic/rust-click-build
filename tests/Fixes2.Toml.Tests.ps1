#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Multi-line TOML parsing and workspace members/exclude handling in lib/RtkUpdate.ps1.
# Nothing here talks to the network or needs Rust.
# Run: Invoke-Pester ./tests

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $themePath = Join-Path $script:Root (Join-Path 'lib' 'RtkTheme.ps1')
    if (Test-Path -LiteralPath $themePath) { . $themePath }
    . (Join-Path $script:Root (Join-Path 'lib' 'RtkUpdate.ps1'))

    $script:RtkUrl = 'https://github.com/ubcool2ic/rtk'

    function script:New-TempDir {
        $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [System.IO.Directory]::CreateDirectory($d) | Out-Null
        return $d
    }
    function script:Write-Utf8([string]$Path, [string]$Text) {
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
        [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
    }
    function script:Get-RelSet([string]$Base, [string[]]$Paths) {
        $rel = @($Paths | ForEach-Object { $_.Substring($Base.Length).TrimStart([char[]]'/\').Replace('\', '/') })
        return (($rel | Sort-Object) -join '|')
    }
    function script:New-WorkspaceTree {
        $root = New-TempDir
        $ws = @(
            '[workspace]'
            'members = ['
            '    "crates/*",   # every crate'
            ']'
            'exclude = ["crates/skip"]'
            ''
        ) -join "`n"
        Write-Utf8 (Join-Path $root 'Cargo.toml') $ws
        foreach ($rel in @('crates/a', 'crates/skip', 'tools/x')) {
            $name = Split-Path -Leaf $rel
            Write-Utf8 (Join-Path (Join-Path $root $rel) 'Cargo.toml') ("[package]`nname = `"$name`"`nversion = `"0.1.0`"`n")
        }
        return $root
    }
}

Describe 'Get-RtkDependency with multi-line TOML' {
    It 'reads an inline table spanning lines and rewrites the tag on its physical line' {
        $dir = New-TempDir
        $manifest = Join-Path $dir 'Cargo.toml'
        $lines = @(
            '[package]'
            'name = "demo"'
            ''
            '[dependencies]'
            'rtk = { git = "https://github.com/ubcool2ic/rtk",'
            '        features = ['
            '            "a",'
            '            "b",'
            '        ],'
            '        tag = "v0.8.2" }'
            'serde = "1"'
            ''
        )
        Write-Utf8 $manifest ($lines -join "`n")

        $deps = @(Get-RtkDependency -ManifestPath $manifest)
        $deps.Count | Should -Be 1
        $deps[0].DepName | Should -Be 'rtk'
        $deps[0].PinKind | Should -Be 'tag'
        $deps[0].PinValue | Should -Be 'v0.8.2'
        $deps[0].LineIndex | Should -Be 9
        $deps[0].Form | Should -Be 'inline'

        Set-RtkTagPin -ManifestPath $manifest -LineIndex $deps[0].LineIndex -OldTag 'v0.8.2' -NewTag 'v1.0.1'
        $after = [System.IO.File]::ReadAllText($manifest).Split([char]10)
        $after[9] | Should -Be '        tag = "v1.0.1" }'
        $after[4] | Should -Be $lines[4]
        $after.Length | Should -Be $lines.Length

        $again = @(Get-RtkDependency -ManifestPath $manifest)
        $again.Count | Should -Be 1
        $again[0].PinValue | Should -Be 'v1.0.1'
        $again[0].LineIndex | Should -Be 9
    }

    It 'reads a table-form dep with a multi-line features array' {
        $dir = New-TempDir
        $manifest = Join-Path $dir 'Cargo.toml'
        $lines = @(
            '[dependencies.rtk]'
            'git = "https://github.com/ubcool2ic/rtk"'
            'features = ['
            '    "a",'
            '    "b",'
            ']'
            'tag = "v0.8.2"'
            ''
        )
        Write-Utf8 $manifest ($lines -join "`n")
        $deps = @(Get-RtkDependency -ManifestPath $manifest)
        $deps.Count | Should -Be 1
        $deps[0].PinKind | Should -Be 'tag'
        $deps[0].PinValue | Should -Be 'v0.8.2'
        $deps[0].LineIndex | Should -Be 6
        $deps[0].Form | Should -Be 'table'
    }

    It 'ignores headers and deps inside multi-line strings' {
        $dir = New-TempDir
        $manifest = Join-Path $dir 'Cargo.toml'
        $lines = @(
            '[package]'
            'name = "demo"'
            'description = """'
            '[dependencies]'
            'rtk = { git = "https://github.com/ubcool2ic/rtk", tag = "v0.1.0" }'
            '"""'
            "notes = '''"
            '[dependencies.rtk]'
            "git = 'https://github.com/ubcool2ic/rtk'"
            "'''"
            ''
        )
        Write-Utf8 $manifest ($lines -join "`n")
        @(Get-RtkDependency -ManifestPath $manifest).Count | Should -Be 0
    }

    It 'still finds the real dep after multi-line strings, with the right line' {
        $dir = New-TempDir
        $manifest = Join-Path $dir 'Cargo.toml'
        $lines = @(
            '[package]'
            'name = "demo"'
            'description = """'
            '[dependencies]'
            'rtk = { git = "https://github.com/ubcool2ic/rtk", tag = "v0.1.0" }'
            '"""'
            "notes = '''"
            '[dependencies.rtk]'
            "git = 'https://github.com/ubcool2ic/rtk'"
            "'''"
            '[dependencies]'
            'rtk = { git = "https://github.com/ubcool2ic/rtk", tag = "v0.8.2" }'
            ''
        )
        Write-Utf8 $manifest ($lines -join "`n")
        $deps = @(Get-RtkDependency -ManifestPath $manifest)
        $deps.Count | Should -Be 1
        $deps[0].PinValue | Should -Be 'v0.8.2'
        $deps[0].LineIndex | Should -Be 11
    }

    It 'keeps single-line manifests working (CRLF)' {
        $dir = New-TempDir
        $manifest = Join-Path $dir 'Cargo.toml'
        Write-Utf8 $manifest ("[dependencies]`r`nrtk = { git = `"$($script:RtkUrl)`", tag = `"v0.8.2`" } # pin`r`n")
        $deps = @(Get-RtkDependency -ManifestPath $manifest)
        $deps.Count | Should -Be 1
        $deps[0].PinValue | Should -Be 'v0.8.2'
        $deps[0].LineIndex | Should -Be 1
    }
}

Describe 'Get-RcbWorkspaceInfo' {
    It 'reads members spanning lines and exclude' {
        $dir = New-TempDir
        $manifest = Join-Path $dir 'Cargo.toml'
        $lines = @(
            '[workspace]'
            'members = ['
            '    "crates/*",   # comment'
            "    'tools/cli',"
            ']'
            'exclude = ["crates/skip"]'
            'resolver = "2"'
            ''
            '[workspace.dependencies]'
            'serde = "1"'
            ''
        )
        Write-Utf8 $manifest ($lines -join "`n")
        $info = Get-RcbWorkspaceInfo -ManifestPath $manifest
        $info.IsWorkspace | Should -BeTrue
        ($info.Members -join '|') | Should -Be 'crates/*|tools/cli'
        ($info.Exclude -join '|') | Should -Be 'crates/skip'
        $info.HasPackage | Should -BeFalse
    }

    It 'reports a plain package as not a workspace' {
        $dir = New-TempDir
        $manifest = Join-Path $dir 'Cargo.toml'
        Write-Utf8 $manifest "[package]`nname = `"x`"`nmembers = [`"a`"]`n"
        $info = Get-RcbWorkspaceInfo -ManifestPath $manifest
        $info.IsWorkspace | Should -BeFalse
        $info.Members.Length | Should -Be 0
        $info.Exclude.Length | Should -Be 0
        $info.HasPackage | Should -BeTrue
    }

    It 'returns an empty result for a missing file' {
        $info = Get-RcbWorkspaceInfo -ManifestPath (Join-Path (New-TempDir) 'Cargo.toml')
        $info.IsWorkspace | Should -BeFalse
        $info.Members.Length | Should -Be 0
    }
}

Describe 'Test-RcbWorkspaceMember' {
    It 'path "<Rel>" -> <Expected>' -ForEach @(
        @{ Rel = 'crates/a'; Expected = $true }
        @{ Rel = 'tools/cli'; Expected = $true }
        @{ Rel = 'crates/skip'; Expected = $false }
        @{ Rel = 'crates/skip/inner'; Expected = $false }
        @{ Rel = 'tools/x'; Expected = $false }
        @{ Rel = 'crates/a/nested'; Expected = $false }
        @{ Rel = 'crates'; Expected = $false }
        @{ Rel = ''; Expected = $true }
    ) {
        $root = New-TempDir
        $pkg = $root
        if ($Rel -ne '') { $pkg = Join-Path $root $Rel }
        $r = Test-RcbWorkspaceMember -WorkspaceRoot $root -PackageDir $pkg -Members @('crates/*', 'tools/cli') -Exclude @('crates/skip')
        $r | Should -Be $Expected
    }

    It 'supports ? inside one segment and ./ prefixes' {
        $root = New-TempDir
        Test-RcbWorkspaceMember -WorkspaceRoot $root -PackageDir (Join-Path $root 'app1') -Members @('./app?') | Should -BeTrue
        Test-RcbWorkspaceMember -WorkspaceRoot $root -PackageDir (Join-Path $root 'app12') -Members @('./app?') | Should -BeFalse
    }
}

Describe 'Workspace-aware discovery' {
    It 'discovers the root plus excluded and non-member packages' {
        $root = New-WorkspaceTree
        $found = @(Get-RcbCargoManifest -RootDirectory $root -ExcludeWorkspaceMembers)
        Get-RelSet $root $found | Should -Be 'Cargo.toml|crates/skip/Cargo.toml|tools/x/Cargo.toml'
    }

    It 'Get-ProjectManifestSet returns the root and member packages only' {
        $root = New-WorkspaceTree
        $set = @(Get-ProjectManifestSet -ManifestPath (Join-Path $root 'Cargo.toml'))
        $set.Count | Should -Be 2
        Get-RelSet $root $set | Should -Be 'Cargo.toml|crates/a/Cargo.toml'
    }

    It 'keeps the old behaviour for a workspace without a members list' {
        $root = New-TempDir
        Write-Utf8 (Join-Path $root 'Cargo.toml') "[package]`nname = `"top`"`n`n[workspace]`n"
        Write-Utf8 (Join-Path (Join-Path $root 'sub') 'Cargo.toml') "[package]`nname = `"sub`"`n"
        $found = @(Get-RcbCargoManifest -RootDirectory $root -ExcludeWorkspaceMembers)
        Get-RelSet $root $found | Should -Be 'Cargo.toml'
        $set = @(Get-ProjectManifestSet -ManifestPath (Join-Path $root 'Cargo.toml'))
        Get-RelSet $root $set | Should -Be 'Cargo.toml|sub/Cargo.toml'
    }

    It 'walks everything without -ExcludeWorkspaceMembers' {
        $root = New-WorkspaceTree
        $found = @(Get-RcbCargoManifest -RootDirectory $root)
        $found.Count | Should -Be 4
    }
}
