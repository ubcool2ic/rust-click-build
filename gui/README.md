# rcb-gui

A native front-end for `build.ps1` (Rust Click Build), written with the
[rtk](https://github.com/ubcool2ic/rtk) toolkit. It does **not** reimplement
building: it starts `build.ps1 -JsonProgress` as a child process and renders
the progress events (projects table, progress bar, coloured live log).

It only uses rtk's public API (`rtk::…` re-exports and public modules).

## Build and run

Windows:

```powershell
cd gui
cargo run --release -- --path C:\path\to\projects
```

Linux / macOS (needs `pwsh` on PATH, or set `RCB_PWSH`):

```sh
cd gui
cargo run --release -- --path ~/projects --theme dark
```

Options: `--script <build.ps1>` (default: `RCB_BUILD_SCRIPT`, else searched
upward from the executable and the current directory), `--path <folder>`,
`--profile release|debug`, `--theme System|Light|Dark|HighContrast`, `--test`,
`--no-rtk-update`, `--screenshot-dir <dir>`.

Keyboard: `Ctrl+Enter` / `F5` start, `Esc` cancel. The build log is monospace and scrollable with the mouse wheel. It keeps the last 2000 lines and stays pinned to the bottom unless you scroll up.

If the folder picker call ever stops compiling against a newer rtk, build with
`--no-default-features` (the Browse button then uses a text prompt).

## Screenshots

```sh
cargo run -- --screenshot-dir ../docs/screenshots
```

Renders `rcb-gui-{light,dark,highcontrast}-{idle,building,results}.png`
headlessly (no window, no child process) from
`tests/fixtures/sample-run.jsonl`.

## Tests

```sh
cargo test
cargo clippy --all-targets -- -D warnings
```

On Linux and macOS the end-to-end test runs the real `build.ps1` and fails if
`pwsh` is not on PATH. Set `RCB_SKIP_E2E=1` to skip it on purpose; it then
prints `SKIPPED`. The tests use only rtk's public API.

## Protocol

`build.ps1 -JsonProgress` writes one event per stdout line: `@@RCB ` followed
by compact JSON with an `event` field: `start`, `log`, `discovered`,
`project_start`, `phase`, `rtk`, `project_end`, `prompt`, `summary`, `fatal`.
Other stdout lines and all stderr lines are shown as muted log lines. Unknown
events and fields are ignored; malformed JSON becomes a muted log line. A
`prompt` is answered by writing `yes\n` or `no\n` to the child's stdin. If the
child exits without a `summary`, the GUI shows a failure with the exit code.
