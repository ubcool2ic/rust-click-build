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
    Writes one "@@RCB {json}" protocol line to stdout. No-op unless -JsonProgress.
#>
function Write-RcbEvent {
    param([string]$Name, $Data = $null)
    if (-not $script:RcbJsonProgress) { return }
    $o = [ordered]@{ event = $Name }
    if ($null -ne $Data) { foreach ($k in $Data.Keys) { $o[$k] = $Data[$k] } }
    try {
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
        $w = New-Object System.IO.StreamWriter($Path, $true, (New-Object System.Text.UTF8Encoding($false)))
        $w.AutoFlush = $false
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
function Request-RcbConfirm {
    param([string]$Id, [string]$Question, [scriptblock]$PromptUser = $null)
    if ($null -ne $PromptUser) { return [bool](& $PromptUser $Question) }
    if ($script:RcbJsonProgress) {
        Write-RcbEvent 'prompt' ([ordered]@{ id = $Id; question = $Question })
        $ans = $null
        try { $ans = [Console]::In.ReadLine() } catch { $ans = $null }
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
