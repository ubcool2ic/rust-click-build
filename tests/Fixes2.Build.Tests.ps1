# Pester 5 tests for the second round of build.ps1 fixes (Linux pwsh 7).

Describe 'Fixes2 build.ps1' -Skip:($IsWindows -or $env:OS -eq 'Windows_NT') {
    BeforeAll {
        $script:F2Root = Split-Path -Parent $PSScriptRoot
        $script:F2BuildScript = Join-Path $script:F2Root 'build.ps1'
        $script:F2SavedNoMain = $env:RCB_NO_MAIN
        $env:RCB_NO_MAIN = '1'
        . $script:F2BuildScript

        $script:F2SavedPath = $env:PATH
        $script:F2SavedHome = $env:HOME
        $script:F2SavedCargoHome = $env:CARGO_HOME

        function New-F2FakeCargo {
            param([string]$BinDir)
            New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
            $file = Join-Path $BinDir 'cargo'
            [System.IO.File]::WriteAllText($file, "#!/bin/sh`nexit 0`n")
            & /bin/chmod +x $file
            return $file
        }
        function Restore-F2Env {
            $env:PATH = $script:F2SavedPath
            $env:HOME = $script:F2SavedHome
            if ($null -eq $script:F2SavedCargoHome) {
                Remove-Item Env:\CARGO_HOME -ErrorAction SilentlyContinue
            } else {
                $env:CARGO_HOME = $script:F2SavedCargoHome
            }
        }
    }
    AfterAll {
        Restore-F2Env
        if ($null -eq $script:F2SavedNoMain) {
            Remove-Item Env:\RCB_NO_MAIN -ErrorAction SilentlyContinue
        } else {
            $env:RCB_NO_MAIN = $script:F2SavedNoMain
        }
    }

    Context 'Add-CargoBinToPath' {
        BeforeEach {
            $script:F2Case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:F2EmptyBin = Join-Path $script:F2Case 'emptybin'
            $script:F2Home = Join-Path $script:F2Case 'home'
            New-Item -ItemType Directory -Path $script:F2EmptyBin -Force | Out-Null
            New-Item -ItemType Directory -Path $script:F2Home -Force | Out-Null
            Remove-Item Env:\CARGO_HOME -ErrorAction SilentlyContinue
        }
        AfterEach {
            Restore-F2Env
        }

        It 'puts ~/.cargo/bin at the front of PATH and reports cargo as resolvable' {
            $bin = Join-Path $script:F2Home (Join-Path '.cargo' 'bin')
            $null = New-F2FakeCargo $bin
            $env:HOME = $script:F2Home
            $env:PATH = $script:F2EmptyBin
            $result = Add-CargoBinToPath
            $result | Should -BeTrue
            $env:PATH.StartsWith($bin + [System.IO.Path]::PathSeparator) | Should -BeTrue
        }

        It 'does not add the directory twice' {
            $bin = Join-Path $script:F2Home (Join-Path '.cargo' 'bin')
            $null = New-F2FakeCargo $bin
            $env:HOME = $script:F2Home
            $env:PATH = $script:F2EmptyBin
            $null = Add-CargoBinToPath
            $second = Add-CargoBinToPath
            $second | Should -BeTrue
            $parts = @($env:PATH -split [System.IO.Path]::PathSeparator | Where-Object { $_ -eq $bin })
            $parts.Count | Should -Be 1
        }

        It 'respects CARGO_HOME' {
            $cargoHome = Join-Path $script:F2Case 'cargohome'
            $bin = Join-Path $cargoHome 'bin'
            $null = New-F2FakeCargo $bin
            $env:HOME = $script:F2Home
            $env:CARGO_HOME = $cargoHome
            $env:PATH = $script:F2EmptyBin
            $result = Add-CargoBinToPath
            $result | Should -BeTrue
            $env:PATH.StartsWith($bin + [System.IO.Path]::PathSeparator) | Should -BeTrue
        }

        It 'leaves PATH unchanged when the directory is missing' {
            $env:HOME = $script:F2Home
            $env:PATH = $script:F2EmptyBin
            $result = Add-CargoBinToPath
            $result | Should -BeFalse
            $env:PATH | Should -Be $script:F2EmptyBin
        }
    }

    Context 'Build log writer' {
        It 'flushes every line and allows reading while the log is open' {
            $log = Join-Path $TestDrive 'flush-test.log'
            Open-RcbLogWriter $log
            try {
                $null = Write-BuildLog 'x'
                $null = Write-BuildLog 'x'
                $text = ''
                $fs = [System.IO.File]::Open($log, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try {
                    $reader = New-Object System.IO.StreamReader($fs)
                    $text = $reader.ReadToEnd()
                } finally {
                    $fs.Dispose()
                }
                @($text -split "`r?`n" | Where-Object { $_ -eq 'x' }).Count | Should -Be 2
            } finally {
                Close-RcbLogWriter
            }
        }
    }

    Context 'ConvertTo-RcbRelaunchArgument' {
        BeforeAll {
            $script:F2Bound = @{
                Gui          = [switch]$true
                Test         = [switch]$true
                NoOpen       = [switch]$false
                Path         = '/tmp/my rust proj'
                BuildProfile = 'debug'
            }
        }

        It 'turns present switches into -Name and drops absent ones' {
            $a = @(ConvertTo-RcbRelaunchArgument -BoundParameters $script:F2Bound -ScriptPath '/x/build.ps1' -HostPath 'powershell.exe')
            $a | Should -Contain '-Gui'
            $a | Should -Contain '-Test'
            $a | Should -Not -Contain '-NoOpen'
        }

        It 'keeps a string with spaces as one argument after its name' {
            $a = @(ConvertTo-RcbRelaunchArgument -BoundParameters $script:F2Bound -ScriptPath '/x/build.ps1' -HostPath 'powershell.exe')
            $i = [array]::IndexOf($a, '-Path')
            $i | Should -BeGreaterThan -1
            $a[$i + 1] | Should -Be '/tmp/my rust proj'
            $j = [array]::IndexOf($a, '-BuildProfile')
            $a[$j + 1] | Should -Be 'debug'
        }

        It 'adds -STA before -File for powershell.exe and appends extras' {
            $a = @(ConvertTo-RcbRelaunchArgument -BoundParameters $script:F2Bound -ScriptPath '/x/build.ps1' -Extra @('-ClassicGui') -HostPath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe')
            $sta = [array]::IndexOf($a, '-STA')
            $file = [array]::IndexOf($a, '-File')
            $sta | Should -BeGreaterThan -1
            $file | Should -BeGreaterThan $sta
            $a[$file + 1] | Should -Be '/x/build.ps1'
            $a[$a.Count - 1] | Should -Be '-ClassicGui'
        }

        It 'omits -STA for a non-Windows pwsh host' {
            $a = @(ConvertTo-RcbRelaunchArgument -BoundParameters @{} -ScriptPath '/x/build.ps1' -HostPath '/usr/bin/pwsh')
            $a | Should -Not -Contain '-STA'
            $a | Should -Contain '-File'
        }
    }

    Context 'Classic window and -Gui wiring' {
        It 'Show-BuildGui takes NoInstall and NoOpen as bool parameters' {
            $cmd = Get-Command Show-BuildGui
            $cmd.Parameters.ContainsKey('NoInstall') | Should -BeTrue
            $cmd.Parameters.ContainsKey('NoOpen') | Should -BeTrue
            $cmd.Parameters['NoInstall'].ParameterType | Should -Be ([bool])
            $cmd.Parameters['NoOpen'].ParameterType | Should -Be ([bool])
        }

        It 'keeps Invoke-InSTA and no longer uses a raw thread' {
            (Get-Command Invoke-InSTA -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
            $content = [System.IO.File]::ReadAllText($script:F2BuildScript)
            $content | Should -Not -Match 'System\.Threading\.ThreadStart'
        }

        It 'the -Gui branch calls Add-CargoBinToPath before building the GUI' {
            $content = [System.IO.File]::ReadAllText($script:F2BuildScript)
            $start = $content.IndexOf('if ($Gui -or $ClassicGui) {')
            $start | Should -BeGreaterThan -1
            $build = $content.IndexOf('Start-BuildPipeline -TargetFolder $guiDir', $start)
            $build | Should -BeGreaterThan $start
            $call = $content.IndexOf('Add-CargoBinToPath', $start)
            $call | Should -BeGreaterThan $start
            $call | Should -BeLessThan $build
        }

        It 'the classic Build handler no longer reads the script-scope switches' {
            $content = [System.IO.File]::ReadAllText($script:F2BuildScript)
            $content | Should -Not -Match '-NoInstallFlag \$NoInstall\s*`'
            $content | Should -Not -Match '-NoOpenFlag \$NoOpen\s*`'
        }
    }
}
