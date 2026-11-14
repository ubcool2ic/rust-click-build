# Pester 5 regression tests for the crash/bug sweep (fake cargo, non-Windows only).

Describe 'Crash and bug sweep fixes' -Skip:($IsWindows -or $env:OS -eq 'Windows_NT') {
    BeforeAll {
        $script:SwRoot = Split-Path -Parent $PSScriptRoot
        $script:SwFixtures = Join-Path $PSScriptRoot 'fixtures'
        $script:SwBuild = Join-Path $script:SwRoot 'build.ps1'

        # Load the functions without running a build; the variable must not leak to child runs.
        $prevNoMain = $env:RCB_NO_MAIN
        $env:RCB_NO_MAIN = '1'
        . $script:SwBuild
        if ($null -eq $prevNoMain) {
            Remove-Item Env:\RCB_NO_MAIN -ErrorAction SilentlyContinue
        } else {
            $env:RCB_NO_MAIN = $prevNoMain
        }

        $script:SwBin = Join-Path $TestDrive 'sweepbin'
        New-Item -ItemType Directory -Path $script:SwBin | Out-Null
        Copy-Item (Join-Path $script:SwFixtures 'fake-cargo.sh') (Join-Path $script:SwBin 'cargo')
        & /bin/chmod +x (Join-Path $script:SwBin 'cargo')
        $script:SwSavedPath = $env:PATH
        $env:PATH = $script:SwBin + [System.IO.Path]::PathSeparator + $env:PATH
        $env:FAKE_CARGO_LOG = Join-Path $TestDrive 'sweep-cargo-calls.log'

        function Invoke-SweepJsonBuild {
            param([string]$DestName)
            $dest = Join-Path $TestDrive $DestName
            Copy-Item -Recurse (Join-Path $script:SwFixtures 'tag-old') $dest
            $lines = @(& pwsh -NoProfile -File $script:SwBuild -Path $dest -BuildProfile debug -NoInstall -NoRtkUpdate -JsonProgress)
            $code = $LASTEXITCODE
            $lines = @($lines | ForEach-Object { [string]$_ } | Where-Object { $_ -ne '' })
            return [PSCustomObject]@{ Lines = $lines; ExitCode = $code }
        }
    }
    AfterAll {
        $env:PATH = $script:SwSavedPath
        Remove-Item Env:\FAKE_CARGO_LOG, Env:\FAKE_CARGO_FAIL_TAG -ErrorAction SilentlyContinue
    }
    AfterEach {
        Remove-Item Env:\FAKE_CARGO_FAIL_TAG -ErrorAction SilentlyContinue
    }

    It 'writes a single project and empty error lists as JSON arrays' {
        $run = Invoke-SweepJsonBuild 'sweep-one'
        $disc = $run.Lines | Where-Object { $_ -like '*"event":"discovered"*' } | Select-Object -First 1
        $disc | Should -Match '"count":1'
        $disc | Should -Match '"projects":\["sweep-one"\]'
        $end = $run.Lines | Where-Object { $_ -like '*"event":"project_end"*' } | Select-Object -First 1
        $end | Should -Match '"errors":\[\]'
        $end | Should -Match '"hints":\[\]'
        foreach ($l in $run.Lines) { $l | Should -Not -MatchExactly '"Count":' }
        $run.ExitCode | Should -Be 0
    }

    It 'writes the errors of a failed single project as a JSON array' {
        $env:FAKE_CARGO_FAIL_TAG = 'v0.8.2'
        $run = Invoke-SweepJsonBuild 'sweep-fail'
        $end = $run.Lines | Where-Object { $_ -like '*"event":"project_end"*' } | Select-Object -First 1
        $end | Should -Match '"errors":\["error'
        $end | Should -Match '"build":"FAIL"'
        $run.ExitCode | Should -Be 1
    }

    It 'copies list values of an event into plain arrays' {
        $list = New-Object System.Collections.Generic.List[string]
        $list.Add('only')
        $d = ConvertTo-RcbEventData -Name 'e' -Data ([ordered]@{ projects = $list; errors = [string[]]@(); n = 1 })
        ($d['projects'] -is [array]) | Should -BeTrue
        ($d['errors'] -is [array]) | Should -BeTrue
        ConvertTo-RcbJson $d | Should -Be '{"event":"e","projects":["only"],"errors":[],"n":1}'
    }

    It 'treats a failing prompt callback as "no"' {
        $answer = Request-RcbConfirm -Id 'x' -Question 'q' -PromptUser { throw 'boom' }
        $answer | Should -BeFalse
        (Request-RcbConfirm -Id 'x' -Question 'q' -PromptUser { $true }) | Should -BeTrue
    }

    It 'reads target_directory even when cargo warnings precede the JSON' {
        $lines = @('warning: unused manifest key: package.foo', '{"packages":[],"target_directory":"/tmp/sweep-target","version":1}')
        Get-RcbMetadataTargetDir -Lines $lines | Should -Be '/tmp/sweep-target'
        Get-RcbMetadataTargetDir -Lines @('{', '  "target_directory": "/tmp/multi"', '}') | Should -Be '/tmp/multi'
        Get-RcbMetadataTargetDir -Lines @('error: no manifest') | Should -BeNullOrEmpty
        Get-RcbMetadataTargetDir -Lines @() | Should -BeNullOrEmpty
    }

    It 'does not throw when CARGO_HOME points to a drive that does not exist' {
        $savedHome = $env:CARGO_HOME
        $savedPath = $env:PATH
        try {
            $env:CARGO_HOME = 'Zq9:/no/such/cargo'
            { $null = Add-CargoBinToPath } | Should -Not -Throw
        } finally {
            $env:PATH = $savedPath
            if ($null -eq $savedHome) {
                Remove-Item Env:\CARGO_HOME -ErrorAction SilentlyContinue
            } else {
                $env:CARGO_HOME = $savedHome
            }
        }
    }

    It 'kills the child process when the output callback throws' {
        $script:SwPid = 0
        {
            Invoke-ToolProcess -FilePath '/bin/sh' -ArgumentList @('-c', 'echo $$ >&2; exec sleep 30') -OnOutputLine {
                param($l)
                $script:SwPid = [int]$l
                throw 'callback failed'
            }
        } | Should -Throw
        $script:SwPid | Should -BeGreaterThan 0
        $gone = $false
        for ($i = 0; $i -lt 50; $i++) {
            if ($null -eq (Get-Process -Id $script:SwPid -ErrorAction SilentlyContinue)) { $gone = $true; break }
            Start-Sleep -Milliseconds 100
        }
        $gone | Should -BeTrue
    }

    It 'rejects a file given as the project folder (cancelled, no crash)' {
        $file = Join-Path $TestDrive 'not-a-folder.txt'
        Set-Content -LiteralPath $file -Value 'x'
        $r = Start-BuildPipeline -TargetFolder $file -ActiveProfile 'debug' -RunTests $false -NoInstallFlag $true -NoOpenFlag $true -NoRtkUpdateFlag $true
        $r | Should -Not -BeNullOrEmpty
        $r.Cancelled | Should -BeTrue
        $r.Success | Should -BeFalse
    }

    It 'keeps exit code 2 when the closing pause cannot read input' {
        $missing = Join-Path $TestDrive 'does-not-exist'
        $null = & pwsh -NoProfile -NonInteractive -File $script:SwBuild -Path $missing -NoInstall -NoRtkUpdate
        $LASTEXITCODE | Should -Be 2
    }
}
