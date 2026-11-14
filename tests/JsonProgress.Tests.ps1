# Pester 5 tests for the -JsonProgress protocol (fake cargo, non-Windows only).

Describe 'JSON progress protocol' -Skip:($IsWindows -or $env:OS -eq 'Windows_NT') {
    BeforeAll {
        $script:Root = Split-Path -Parent $PSScriptRoot
        $script:Fixtures = Join-Path $PSScriptRoot 'fixtures'
        $script:JBin = Join-Path $TestDrive 'jsonbin'
        New-Item -ItemType Directory -Path $script:JBin | Out-Null
        Copy-Item (Join-Path $script:Fixtures 'fake-cargo.sh') (Join-Path $script:JBin 'cargo')
        & /bin/chmod +x (Join-Path $script:JBin 'cargo')
        $script:JSavedPath = $env:PATH
        $env:PATH = $script:JBin + [System.IO.Path]::PathSeparator + $env:PATH
        $env:FAKE_CARGO_LOG = Join-Path $TestDrive 'json-cargo-calls.log'

        function Copy-JsonFixture {
            param([string]$Name, [string]$DestName)
            $dest = Join-Path $TestDrive $DestName
            Copy-Item -Recurse (Join-Path $script:Fixtures $Name) $dest
            return $dest
        }
        function Invoke-JsonBuild {
            param([string]$Dir)
            $lines = @(& pwsh -NoProfile -File (Join-Path $script:Root 'build.ps1') -Path $Dir -BuildProfile debug -NoInstall -NoRtkUpdate -JsonProgress)
            $code = $LASTEXITCODE
            $lines = @($lines | ForEach-Object { [string]$_ } | Where-Object { $_ -ne '' })
            return [PSCustomObject]@{ Lines = $lines; ExitCode = $code }
        }
        function ConvertFrom-JsonLine {
            param([string[]]$Lines)
            return @($Lines | ForEach-Object { $_.Substring(6) | ConvertFrom-Json })
        }
    }
    AfterAll {
        $env:PATH = $script:JSavedPath
        Remove-Item Env:\FAKE_CARGO_LOG, Env:\FAKE_CARGO_FAIL_TAG -ErrorAction SilentlyContinue
    }
    AfterEach {
        Remove-Item Env:\FAKE_CARGO_FAIL_TAG -ErrorAction SilentlyContinue
    }

    It 'emits only protocol lines, in order, and exits 0 on success' {
        $dir = Copy-JsonFixture 'tag-old' 'json-ok'
        $run = Invoke-JsonBuild $dir
        $run.Lines.Count | Should -BeGreaterThan 0
        foreach ($l in $run.Lines) { $l.StartsWith('@@RCB ') | Should -BeTrue }
        $events = ConvertFrom-JsonLine $run.Lines
        $names = @($events | ForEach-Object { [string]$_.event })
        $last = -1
        foreach ($n in @('start', 'discovered', 'project_start', 'project_end', 'summary')) {
            $i = [array]::IndexOf($names, $n)
            $i | Should -BeGreaterThan $last
            $last = $i
        }
        @($names | Where-Object { $_ -eq 'summary' }).Count | Should -Be 1
        $run.ExitCode | Should -Be 0
        $summary = $events | Where-Object { $_.event -eq 'summary' }
        $summary.exit_code | Should -Be 0
        $summary.success | Should -BeTrue
        ($events | Where-Object { $_.event -eq 'start' }).version | Should -Be 1
        ($events | Where-Object { $_.event -eq 'project_end' }).build | Should -Be 'PASS'
    }

    It 'reports a failed build with errors and exit code 1' {
        $env:FAKE_CARGO_FAIL_TAG = 'v0.8.2'
        $dir = Copy-JsonFixture 'tag-old' 'json-fail'
        $run = Invoke-JsonBuild $dir
        foreach ($l in $run.Lines) { $l.StartsWith('@@RCB ') | Should -BeTrue }
        $events = ConvertFrom-JsonLine $run.Lines
        $end = $events | Where-Object { $_.event -eq 'project_end' }
        $end.build | Should -Be 'FAIL'
        @($end.errors).Count | Should -BeGreaterThan 0
        @($end.errors)[0] | Should -Match 'error\[E0425\]'
        ($events | Where-Object { $_.event -eq 'summary' }).exit_code | Should -Be 1
        $run.ExitCode | Should -Be 1
    }

    It 'round-trips a non-ASCII folder name as ASCII-only JSON' {
        $name = 'projekt-ae-' + [char]0xE4
        $dir = Copy-JsonFixture 'tag-old' $name
        $run = Invoke-JsonBuild $dir
        foreach ($l in $run.Lines) { $l | Should -Not -Match '[^\x00-\x7E]' }
        $startLine = $run.Lines | Where-Object { $_ -like '*"event":"start"*' } | Select-Object -First 1
        $startLine | Should -Match '\\u00e4'
        $start = $startLine.Substring(6) | ConvertFrom-Json
        ([string]$start.path).EndsWith($name) | Should -BeTrue
        $run.ExitCode | Should -Be 0
    }
}
