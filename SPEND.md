# Model spend

| Date (UTC-5, EST) | Round | Model | Purpose | Cost (USD) |
|---|---|---|---|---|
| 2026-10-17 | - | google/gemini-3.8-flash | Generate build.ps1 (incl. error handling) | $0.0495 |
| 2026-10-26 | - | none (hand-written) | rtk update check + rtk styling (PR feat/rtk-update-and-style) | $0.0000 |
| 2026-11-14 | 1 | anthropic/claude-fable-5.2 | Review + fix all PowerShell (whole repo in one call). Spent all 64k tokens reasoning, no output, nothing applied | $3.1576 |
| 2026-11-14 | 1 | anthropic/claude-fable-5.2 | First rtk GUI crate attempt. Spent all 64k tokens reasoning, no output | $3.1289 |
| 2026-11-14 | 1 | anthropic/claude-fable-5.2 | Rewrite lib/RtkUpdate.ps1 + RtkTheme.ps1 (bugs, perf), tests/Hardening.Tests.ps1 | $3.3980 |
| 2026-11-14 | 1 | anthropic/claude-fable-5.2 | rtk GUI crate gui/ (protocol, state, runner, UI, screenshots, tests) | $3.9861 |
| 2026-11-14 | 1 | anthropic/claude-fable-5.2 | build.ps1 -JsonProgress/-Gui pass. Aborted by my reasoning guard before any output, nothing applied | $1.4339 |
| 2026-11-14 | 1 | anthropic/claude-fable-5.2 | GUI visual polish from real renders (ui.rs, theme.rs). Hit max_tokens; theme.rs tail spliced by hand | $1.9813 |
| 2026-11-14 | 1 | anthropic/claude-fable-5.2 | build.ps1: -JsonProgress, -Gui launcher, -ClassicGui, perf, BuildGUI.bat, tests/JsonProgress.Tests.ps1 | $1.6334 |
| 2026-11-14 | 1 | anthropic/claude-fable-5.2 | GUI: drag-and-drop, setup/test hooks, end-to-end test against the real build.ps1 | $1.0666 |
| 2026-11-14 | 1 | anthropic/claude-fable-5.2 | GUI: Browse starts in typed folder + MockFileDialog test. Hit max_tokens; only app.rs kept | $0.6719 |
| 2026-11-14 | 2 | anthropic/claude-fable-5.2 | rtk updater: https-first tag lookup with 15 s timeout, API pagination, long-path helper + tests (reply cut off inside NOTES only; all code applied) | $1.4757 |
| 2026-11-14 | 2 | anthropic/claude-fable-5.2 | build.ps1: Add-CargoBinToPath for -Gui, per-line log flush, Invoke-InSTA relaunch, classic window handler fixes + tests | $1.4836 |
| 2026-11-14 | 2 | anthropic/claude-fable-5.2 | GUI: monospace log with scrollback, end-to-end rtk tag bump test | $0.9826 |
| 2026-11-14 | 2 | anthropic/claude-fable-5.2 | rtk updater: multi-line TOML, workspace members/exclude + tests | $1.6529 |
| 2026-11-14 | 2 | anthropic/claude-fable-5.2 | GUI crash/bug sweep (runner, protocol, state, app) + tests | $1.6909 |
| 2026-11-14 | 2 | anthropic/claude-fable-5.2 | PowerShell crash/bug sweep (build.ps1, RcbProgress.ps1) + tests | $1.4937 |

**Total: $29.2865**

## Per-round caps

| Round | Work | Cap (set by the Updater) | Spent | Fable calls |
|---|---|---|---|---|
| 1 | Fable 5.2 improvements + rtk GUI crate | $15, raised to $25 mid-round | $20.4577 | 9 |
| 2 | Bug and crash fixes | $15 | $8.7794 | 6 |
| 3 | Review fixes (public rtk API only, e2e pwsh check, this file) | no paid calls allowed | $0.0000 | 0 |

Neither cap was exceeded. Fable total: $29.2371.

## Generation ids

None are retained, so none are listed. Round 1 logged each OpenRouter generation id to a local `spend.jsonl`, but that file was in a scratch folder deleted at the end of the round. Round 2's call script did not record ids. The costs above come from the per-call usage reported by OpenRouter at the time. Ids for these calls can still be looked up in the OpenRouter activity log for the account (2026-11-14, model `anthropic/claude-fable-5.2`).

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

### Hand edits (2026-11-14, review-fix round, no model calls)
- `gui/src/lib.rs`: removed the redundant `tk.sim_resize()` before rendering (it is `#[doc(hidden)]` in rtk v1.0.2). Screenshots are pixel-identical without it.
- GUI tests: replaced the hidden `sim_*` helpers with public rtk API (`render_to_pixmap`, `a11y_do_action`, `yview_scroll`, `drop_target_at`). Drops call the bound handler directly, because rtk has no public way to fire a file drop.
- `gui/tests/e2e_unix.rs`: fails when `pwsh` is missing, unless `RCB_SKIP_E2E=1` is set, in which case it prints that it was skipped.
- SPEND: UTC-5 date label, a round column, per-round caps and the generation id note.
