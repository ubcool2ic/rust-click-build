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

**Total: $20.5071**

### Hand edits (2026-11-14, Fable 5.2 round)
These were made by hand, not by Fable:
- `tests/Hardening.Tests.ps1`: the truecolour test read ANSI through `Out-String`, which strips it on pwsh 7.2+. It now reads the raw message.
- `gui/src/app.rs`: one `&` added (`file_dialog_pick_folder(&request, ...)`), clippy's redundant-closure fixes, and a `MessageTap` type alias.
- `gui/src/lib.rs`: one clippy fix.
- `gui/src/theme.rs`: the end of the truncated r3 output was joined to the previous version, and the two new palette fields were filled in.
- `build.ps1`: lint-only fixes. Approved names (`Update-SessionPath`, `Test-BuildPrerequisite`, `Find-CargoProject`) with aliases for the old names, `$null = $_` in empty catch blocks, and two unused variables removed.
- `tests/JsonProgress.Tests.ps1`: a helper renamed to a singular noun.
- README, SPEND, `.gitignore` and `docs/` were edited by hand.
