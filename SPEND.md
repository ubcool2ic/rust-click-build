# Model spend

| Date (UTC-4) | Model | Purpose | Cost (USD) |
|---|---|---|---|
| 2026-10-17 | google/gemini-3.8-flash | Generate build.ps1 (incl. error handling) | $0.0495 |
| 2026-10-26 | none (hand-written) | rtk update check + rtk styling (PR feat/rtk-update-and-style) | $0.0000 |
| 2026-11-14 | anthropic/claude-fable-5.2 | Review + fix all PowerShell (whole repo in one call). Spent all 64k tokens reasoning, no output, nothing applied | $3.1576 |
| 2026-11-14 | anthropic/claude-fable-5.2 | First rtk GUI crate attempt. Spent all 64k tokens reasoning, no output | $3.1289 |
| 2026-11-14 | anthropic/claude-fable-5.2 | Rewrite lib/RtkUpdate.ps1 + RtkTheme.ps1 (bugs, perf), tests/Hardening.Tests.ps1 | $3.3980 |
| 2026-11-14 | anthropic/claude-fable-5.2 | rtk GUI crate gui/ (protocol, state, runner, UI, screenshots, tests) | $3.9861 |
| 2026-11-14 | anthropic/claude-fable-5.2 | build.ps1 -JsonProgress/-Gui pass. Aborted by my reasoning guard before any output, nothing applied | $1.4339 |
| 2026-11-14 | anthropic/claude-fable-5.2 | GUI visual polish from real renders (ui.rs, theme.rs). Hit max_tokens; theme.rs tail spliced by hand | $1.9813 |
| 2026-11-14 | anthropic/claude-fable-5.2 | build.ps1: -JsonProgress, -Gui launcher, -ClassicGui, perf, BuildGUI.bat, tests/JsonProgress.Tests.ps1 | $1.6334 |
| 2026-11-14 | anthropic/claude-fable-5.2 | GUI: drag-and-drop, setup/test hooks, end-to-end test against the real build.ps1 | $1.0666 |
| 2026-11-14 | anthropic/claude-fable-5.2 | GUI: Browse starts in typed folder + MockFileDialog test. Hit max_tokens; only app.rs kept | $0.6719 |
| 2026-11-14 | anthropic/claude-fable-5.2 | rtk updater: https-first tag lookup with 15 s timeout, API pagination, long-path helper + tests (reply cut off inside NOTES only; all code applied) | $1.4757 |
| 2026-11-14 | anthropic/claude-fable-5.2 | build.ps1: Add-CargoBinToPath for -Gui, per-line log flush, Invoke-InSTA relaunch, classic window handler fixes + tests | $1.4836 |
| 2026-11-14 | anthropic/claude-fable-5.2 | GUI: monospace log with scrollback, end-to-end rtk tag bump test | $0.9826 |
| 2026-11-14 | anthropic/claude-fable-5.2 | rtk updater: multi-line TOML, workspace members/exclude + tests | $1.6529 |
| 2026-11-14 | anthropic/claude-fable-5.2 | GUI crash/bug sweep (runner, protocol, state, app) + tests | $1.6909 |
| 2026-11-14 | anthropic/claude-fable-5.2 | PowerShell crash/bug sweep (build.ps1, RcbProgress.ps1) + tests | $1.4937 |

**Total: $29.2865**

### Hand edits (2026-11-14, Fable 5.2 round)
These were made by hand, not by Fable:
- `tests/Hardening.Tests.ps1`: the truecolour test read ANSI through `Out-String`, which strips it on pwsh 7.2+. It now reads the raw message.
- `gui/src/app.rs`: one `&` added (`file_dialog_pick_folder(&request, ...)`), clippy's redundant-closure fixes, and a `MessageTap` type alias.
- `gui/src/lib.rs`: one clippy fix.
- `gui/src/theme.rs`: the end of the truncated r3 output was joined to the previous version, and the two new palette fields were filled in.
- `build.ps1`: lint-only fixes. Approved names (`Update-SessionPath`, `Test-BuildPrerequisite`, `Find-CargoProject`) with aliases for the old names, `$null = $_` in empty catch blocks, and two unused variables removed.
- `tests/JsonProgress.Tests.ps1`: a helper renamed to a singular noun.
- README, SPEND, `.gitignore` and `docs/` were edited by hand.

### Hand edits (2026-11-14, bug-fix round)
- `build.ps1`: `ConvertTo-RcbRelaunchArgument` returned a nested array (`return ,$list.ToArray()`). Changed to a plain return, with the caller wrapping it in `@()`.
- `tests/Fixes2.Sweep.Tests.ps1`: a case-insensitive `-Match '"Count":'` also matched the protocol's own `"count":`. Changed to `-MatchExactly`.
- Screenshots in `docs/screenshots/` regenerated.
