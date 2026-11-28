# JSON progress protocol (-JsonProgress), buffered log writer and the
# non-hanging yes/no prompt. Dot-sourced by build.ps1. Pure ASCII.

$script:RcbJsonProgress = $false
$script:RcbBuiltDir = $null
$script:LogWriter = $null

<#
.SYNOPSIS
    Compact JSON with every char above 0x7E escaped as \uXXXX (ASCII-only output).
#>
function ConvertTo-RcbJson {
    param($Data)
    $json = ConvertTo-Json -InputObject $Data -Compress -Depth 5
    if ($json -notmatch '[^\x00-\x7E]') { return $json }
    return [regex]::Replace($json, '[^\x00-\x7E]', { param($m) '\u{0:x4}' -f [int]$m.Value[0] })
}

<#
.SYNOPSIS
    Builds the ordered event payload. Every list value is copied into a plain
    object[] so it is always written as a JSON array (also with 0 or 1 items,
    and on Windows PowerShell 5.1 where wrapped arrays become {"value":..,"Count":..}).
#>
function ConvertTo-RcbEventData {
    param([string]$Name, $Data = $null)
    $o = [ordered]@{ event = $Name }
    if ($null -eq $Data) { return $o }
    foreach ($k in @($Data.Keys)) {
        $v = $Data[$k]
        if ($null -ne $v -and $v -isnot [string] -and $v -is [System.Collections.IList]) {
            $items = New-Object System.Collections.Generic.List[object]
            foreach ($item in $v) {
                if ($item -is [string]) { $items.Add([string]$item) } else { $items.Add($item) }
            }
            $o[$k] = $items.ToArray()
        } else {
            $o[$k] = $v
        }
    }
    return $o
}

<#
.SYNOPSIS
    Writes one "@@RCB {json}" protocol line to stdout. No-op unless -JsonProgress.
#>
function Write-RcbEvent {
    param([string]$Name, $Data = $null)
    if (-not $script:RcbJsonProgress) { return }
    try {
        $o = ConvertTo-RcbEventData -Name $Name -Data $Data
        [Console]::Out.WriteLine('@@RCB ' + (ConvertTo-RcbJson $o))
        [Console]::Out.Flush()
    } catch { $null = $_ }
}

<#
.SYNOPSIS
    Opens the script-scope build log writer (append, UTF-8 without BOM, CRLF).
#>
function Open-RcbLogWriter {
    param([string]$Path)
    Close-RcbLogWriter
    try {
        # FileShare.ReadWrite: the log can be read (tailed) while the build runs.
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $w = $null
        try {
            $w = New-Object System.IO.StreamWriter($fs, (New-Object System.Text.UTF8Encoding($false)))
        } catch {
            try { $fs.Dispose() } catch { $null = $_ }
            throw
        }
        # Flush after every line so the log tail survives a hard kill.
        $w.AutoFlush = $true
        $w.NewLine = "`r`n"
        $script:LogWriter = $w
    } catch { $script:LogWriter = $null }
}

function Close-RcbLogWriter {
    if ($null -ne $script:LogWriter) {
        try { $script:LogWriter.Dispose() } catch { $null = $_ }
        $script:LogWriter = $null
    }
}

function Write-RcbLogLine {
    param([string]$Text)
    if ($null -ne $script:LogWriter) {
        try { $script:LogWriter.WriteLine($Text) } catch { $null = $_ }
    }
}

<#
.SYNOPSIS
    Yes/no question. Order: -PromptUser scriptblock, JSON prompt event (one stdin
    line; yes/y = yes, anything else or EOF = no), Read-Host when interactive,
    otherwise $false. Never blocks on a redirected or non-interactive stdin.
#>
function Start-RcbStdinWatcher {
    if (-not $script:RcbJsonProgress) { return }
    if ($null -ne $script:RcbStdinWatchStarted -and $script:RcbStdinWatchStarted) { return }
    $script:RcbCancelBox = [hashtable]::Synchronized(@{ Value = $false })
    $script:RcbStdinQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $box = $script:RcbCancelBox
    $queue = $script:RcbStdinQueue
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('RcbCancelBox', $box)
    $runspace.SessionStateProxy.SetVariable('RcbStdinQueue', $queue)
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $runspace
    $null = $ps.AddScript({
        try {
            while ($true) {
                $line = $null
                try { $line = [Console]::In.ReadLine() } catch { break }
                if ($null -eq $line) { break }
                $trim = $line.Trim()
                if ($trim -eq 'cancel') { $RcbCancelBox['Value'] = $true }
                else { [void]$RcbStdinQueue.Enqueue($line) }
            }
        } catch { $null = $_ }
    })
    $script:RcbStdinWatchHandle = $ps.BeginInvoke()
    $script:RcbStdinWatchPS = $ps
    $script:RcbStdinWatchRunspace = $runspace
    $script:RcbStdinWatchStarted = $true
}

function Stop-RcbStdinWatcher {
    if ($null -eq $script:RcbStdinWatchStarted -or -not $script:RcbStdinWatchStarted) { return }
    # Closing this process's stdin unblocks ReadLine in the watcher. Do not
    # call Runspace.Close or PowerShell.Stop: both can wait on that ReadLine
    # and hang the script before [Environment]::Exit can run.
    try {
        if ([Console]::IsInputRedirected) { [Console]::In.Close() }
    } catch { $null = $_ }
    $script:RcbStdinWatchStarted = $false
}

function Request-RcbConfirm {
    param([string]$Id, [string]$Question, [scriptblock]$PromptUser = $null)
    if ($null -ne $PromptUser) {
        # A failing prompt callback counts as "no" instead of aborting the pipeline.
        try { return [bool](& $PromptUser $Question) } catch { return $false }
    }
    if ($script:RcbJsonProgress) {
        Write-RcbEvent 'prompt' ([ordered]@{ id = $Id; question = $Question })
        $ans = $null
        if ($null -ne $script:RcbStdinQueue) {
            $deadline = [datetime]::UtcNow.AddHours(1)
            while ([datetime]::UtcNow -lt $deadline) {
                if ($null -ne $script:RcbCancelBox -and [bool]$script:RcbCancelBox['Value']) { return $false }
                $got = $null
                if ($script:RcbStdinQueue.TryDequeue([ref]$got)) { $ans = $got; break }
                Start-Sleep -Milliseconds 50
            }
        } else {
            try { $ans = [Console]::In.ReadLine() } catch { $ans = $null }
        }
        if ($null -eq $ans) { return $false }
        return ($ans.Trim() -match '^(y|yes)$')
    }
    $interactive = $false
    try { $interactive = ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) } catch { $interactive = $false }
    if (-not $interactive) { return $false }
    try {
        Write-Host ""
        Write-Host $Question -ForegroundColor Yellow
        $response = Read-Host "Proceed with automated installation? (Y/N)"
        return ($response -match '^[Yy]')
    } catch {
        return $false
    }
}
