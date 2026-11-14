# rust-click-build

Click-and-go Rust builder for Windows. It is **not** a compiler: it finds every Cargo project in a folder and runs `cargo` for you, then collects the `.exe` files.

> **Status: not run on Windows.** The scripts lint clean in PowerShell 7 and the Pester tests pass on Linux with mocked network and a fake `cargo`. The rtk GUI (`gui/`) builds, passes its tests and runs end to end on Linux headlessly against the real `build.ps1` with a fake `cargo`. Nobody has run `Build.bat`, `BuildGUI.bat`, the rtk GUI or the classic WinForms window on a real Windows machine yet, and Windows PowerShell 5.1 itself has not been run (only PS 7 on Linux).

## Use it
1. Download this repo (Code -> Download ZIP) and unzip anywhere.
2. **Double-click `Build.bat`** and pick your project folder, **or drag a folder onto `Build.bat`**.
3. When it finishes, your programs are in `<your folder>\_built\<project>\` and that folder opens automatically. The window waits for Enter before closing.

Prefer a window? Double-click **`BuildGUI.bat`**. It opens the **rtk GUI**, a small Rust app in `gui/` built with [rtk](https://github.com/ubcool2ic/rtk): folder box with Browse and drag-and-drop, Release/Debug, "Run tests", "Check for rtk updates before building" (on by default), System/Light/Dark/High contrast themes, an accent Start build button, Cancel, a progress bar, a per-project results table, a live coloured log, and Open output folder.

![rtk GUI, dark theme, finished run](docs/screenshots/rcb-gui-dark-results.png)

These are real headless renders made with rtk's screenshot support, not mockups. `docs/screenshots/` has every theme in the idle, mid-build and results states (`rcb-gui-{light,dark,highcontrast}-{idle,building,results}.png`, from a canned event sequence). It also has `rcb-gui-e2e-*.png`, rendered after the GUI ran the real `build.ps1` on Linux with a fake `cargo` (a passing run and a failing run).

**How BuildGUI.bat works:** it runs `build.ps1 -Gui` in a visible console. That builds `gui\` with the normal pipeline, including the rtk update check, so the GUI picks up new rtk tags by itself. Then it launches `rcb-gui.exe` and the console closes. The first run compiles rtk and takes a few minutes, and it needs Rust and the MSVC build tools, which it offers to install. If cargo is missing and there is no previous build, it uses a prebuilt `gui\bin\rcb-gui.exe` if you put one there. If that is missing too, or the GUI fails to build, it falls back to the classic WinForms window with a warning. `build.ps1 -ClassicGui` opens the classic window directly.

Build the GUI by hand: `cd gui` then `cargo build --release` (Windows or Linux). On Linux it needs `pwsh` on PATH. See [gui/README.md](gui/README.md).

## What it does
- Checks for `cargo` (adds `%USERPROFILE%\.cargo\bin` if needed) and the MSVC C++ build tools (via `vswhere`).
- If missing, asks before installing with **winget** (`Rustlang.Rustup`, `Microsoft.VisualStudio.2022.BuildTools` with the VCTools workload). Without winget it downloads `rustup-init.exe` and opens the Build Tools download page.
- Finds all `Cargo.toml` files, skipping `target\`, `.git`, `node_modules`, `_built`, and members inside a `[workspace]` root (the workspace is built once).
- **Forced rtk update check** before every build (see below).
- Runs `cargo build --release` (or debug), optionally `cargo test`, for each project; a failure doesn't stop the rest.
- Colored progress, first errors per project (`error[E....]` + `file:line`) in red, friendly hints, summary table, log file at `_built\build-<timestamp>.log`.

## rtk update check
Before each project builds, the script looks for [rtk](https://github.com/ubcool2ic/rtk) git dependencies in every `Cargo.toml` of the project (inline `rtk = { git = ... }`, renamed deps with `package = "rtk"`, `[dependencies.rtk]` tables, `target.'cfg(..)'` sections and `[workspace.dependencies]`).

- **Latest release:** `git ls-remote --tags` with your own git login (Git Credential Manager), never prompting. It always asks `https://github.com/ubcool2ic/rtk` first, even when a manifest uses an ssh URL. It then tries the manifest's other URLs, with a 15 s limit on each attempt. If all of them fail and `GH_TOKEN` is set, it asks the GitHub API instead, reading every page of tags. Only stable `vX.Y.Z` tags count.
- **Manifests it understands:** inline tables and arrays that span several lines, and `"""`/`'''` strings. For workspaces it follows `members`/`exclude`, so excluded or non-member packages under a workspace root are built as separate projects.
- **Long paths:** on Windows PowerShell 5.1, paths of 248+ characters use the `\\?\` prefix. If Windows still refuses a path, the message explains how to enable Win32 long paths.
- **`tag = "..."` older than the latest:** backs up `Cargo.toml` + `Cargo.lock` to `_built\rtk-backup-<time>-<project>\`, rewrites the tag, runs `cargo update -p rtk`. The log and summary show `v0.8.2 -> v1.0.2` in colour. The rewrite is atomic and keeps BOM and line endings.
- **`branch = "..."` or no pin:** always runs `cargo update -p rtk`.
- **`rev = "..."`:** reported (latest or behind) but **not** rewritten, because a rev pin is a deliberate choice. Change it to a `tag` to get automatic bumps.
- **Build fails after a bump:** restores the backup, rebuilds on the old pin, and marks the project `rtk update broke the build, kept vX` with the first compiler errors from the new rtk.
- **Offline or no credentials:** prints a loud warning and builds with the pins you already have.
- **Turn it off:** `-NoRtkUpdate`, or untick the checkbox in the GUI.

Cargo is run with `CARGO_NET_GIT_FETCH_WITH_CLI=true` (when git is installed and you haven't set it) so git dependencies are fetched with your git login. rtk itself is public; its latest release is v1.0.2. rtk is updated separately, and this check picks up each new release tag automatically.

## Look and feel
The rtk GUI uses rtk's own themes, tokens and named styles directly (ModernLight / ModernDark / HighContrast, following the Windows setting under System), and only rtk's public API. The console and the classic WinForms window use rtk's theme tokens copied from rtk v1.0.1 `src/style.rs`: Noto Sans 14 px (bundled in `assets/fonts`, SIL OFL), rtk spacing (4/8/12/16/24), cards with 12 px corners and 16 px padding, flat bordered buttons with rtk hover/pressed shades, an accent "Start Build" button, and the ModernDark / ModernLight / high-contrast palettes. The theme follows Windows (light/dark/high contrast) unless you pick one in the Theme box or pass `-Theme Light|Dark|HighContrast`. Console colours use the same palette as 24-bit colour when the console supports it, and the nearest standard colours otherwise (`NO_COLOR` or `RCB_NO_TRUECOLOR=1` turn truecolour off).

## Friendly hints it recognizes
Missing `link.exe` (MSVC), no default toolchain, no internet / crates.io download failures, locked target dir or `.exe` in use, disk full, path too long, no `Cargo.toml` found, invalid folder, winget missing, picker cancelled. It also warns about folder paths with spaces or over 200 characters.

## Command line
```
Build.bat "C:\src\myproj"                         # release build
powershell -ExecutionPolicy Bypass -File build.ps1 -Path C:\src -BuildProfile debug -Test
```
Switches: `-Path`, `-BuildProfile release|debug`, `-Test`, `-Gui`, `-ClassicGui`, `-NoPause`, `-NoInstall`, `-NoOpen`, `-NoRtkUpdate`, `-JsonProgress`, `-Theme System|Light|Dark|HighContrast` (GUI).

`-JsonProgress` is the machine-readable mode the rtk GUI uses. stdout carries only lines of the form `@@RCB {json}`, ASCII-only. The events are `start`, `log`, `discovered`, `project_start`, `phase`, `rtk`, `project_end`, `prompt` (answer `yes`/`no` on stdin), `summary` and `fatal`. It never pauses.

Exit codes: `0` all passed, `1` any build/test failed, `2` cancelled / invalid folder / nothing to build.

Works with Windows PowerShell 5.1 and PowerShell 7.

## Tests and lint
```
pwsh -c "Invoke-Pester ./tests"                                   # Pester 5+
pwsh -c "Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"
cd gui && cargo test && cargo clippy --all-targets -- -D warnings  # rtk GUI (e2e test needs pwsh)
```
`tests/Hardening.Tests.ps1` covers the Fable 5.2 hardening fixes: argument quoting, BOM/CRLF-preserving and atomic tag rewrites, TOML edge cases, rollback when a bump half-fails or `Cargo.lock` was missing, unique backup folders, and pruned discovery. `tests/JsonProgress.Tests.ps1` runs `build.ps1 -JsonProgress` with the fake cargo.
`tests/RtkUpdate.Tests.ps1` covers tag (old and current), rev (latest and old), branch, unpinned, workspace (members, renamed table form, CRLF) and no-rtk fixtures in `tests/fixtures`, with `git ls-remote`, the GitHub API and `cargo` mocked. The pipeline tests use `tests/fixtures/fake-cargo.sh` and are skipped on Windows.

