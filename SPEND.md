# Model spend

| Date | Zone | Model | Purpose | Cost (USD) |
|---|---|---|---|---|
| 2026-10-17 | UTC-4 | google/gemini-3.8-flash | Generate build.ps1 (incl. error handling) | $0.0495 |
| 2026-10-26 | UTC-4 | none (hand-written) | rtk update check + rtk styling (PR feat/rtk-update-and-style) | $0.0000 |
| 2026-11-27 5:59 PM | America/Indianapolis (ET) | anthropic/claude-fable-5.2 | Fable 5.2 low-reasoning review (gen-1795820202-TrSq5CVZaUe2AmUrmJOo); empty, finish_reason=length; measured | $1.129824 |
| 2026-11-27 6:04 PM | America/Indianapolis (ET) | anthropic/claude-fable-5.2 | Fable 5.2 retry after empty length finish, max_tokens 48000 (gen-1795820512-QXovReWJSE49R5moemV1); measured | $1.07408 |

Job cap for the 2026-11-27 Fable 5.2 check: **$5.00**. Account `total_usage` 636.840270624 (baseline 2026-11-27 5:53:59 PM ET) → 639.044174624 after both calls. Job sum **$2.203904** of $5.00. No further paid calls.

**Total: $2.253404**


## PR #2 historical spend (folded into this branch, append-only)

These rows are copied from PR #2 (`fable-5.2-improvements`) so the earlier Fable work is not lost. No generation ids were retained in that branch.

| Date (UTC-5, EST) | Round | Model | Purpose | Cost (USD) |
|---|---|---|---|---|
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

PR #2 Fable subtotal: **$29.2371**. PR #2 documented total including the original 2026-10-17 / 2026-10-26 rows (which already appear in the table above): **$29.2865**. Those two earlier rows are not added again.

## This fold (hand-written, $0)

| Date | Zone | Model | Purpose | Cost (USD) |
|---|---|---|---|---|
| 2026-11-27 | America/Indianapolis (ET) | none (hand-written) | Fold PR #2 fixes into PR #3; Reviewer1 M/S/N fixes; tests and lint | $0.0000 |
| 2026-11-27 | America/Indianapolis (ET) | none (hand-written) | Optional Authenticode signing (`-Sign`, rtk GUI, tests, docs, screenshots) | $0.0000 |
| 2026-11-27 | America/Indianapolis (ET) | none (hand-written) | Reviewer1 r2 should-fixes (S1–S4 + nits, tests, docs) | $0.0000 |
| 2026-11-27 | America/Indianapolis (ET) | none (hand-written) | Reviewer1 r3 nits (0600 pass file, PFX rollback/leftovers, DigiCert HTTP default, post-exit grandchild snapshot, Build.bat :append, -Sign with zero artifacts) | $0.0000 |

No further paid OpenRouter / Fable calls were made for the fold, signing, Reviewer1 r2 should-fixes, or r3 nits. Job cap for the 2026-11-27 Fable 5.2 check remains **$5.00**; job sum stays **$2.203904**.

**This branch's first table total (2026-10 rows + 2026-11-27 Fable): $2.253404.** Historical PR #2 Fable spend recorded above is **$29.2371** (the 2026-10-17 and 2026-10-26 rows are not counted twice). Fold + signing + r2 should-fixes + r3 nits: **$0**.
