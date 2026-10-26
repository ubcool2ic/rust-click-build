# Lint settings: Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Console tool: coloured Write-Host output is the point.
        'PSAvoidUsingWriteHost',
        # New-*/Set-* helpers here build in-memory WinForms objects or edit a
        # Cargo.toml after taking a backup; -WhatIf would not add anything.
        'PSUseShouldProcessForStateChangingFunctions',
        # Parameters used inside event/closure script blocks are not tracked.
        'PSReviewUnusedParameter'
    )
}
