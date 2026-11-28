//! `rcb-gui`: a native rtk front-end for rust-click-build's `build.ps1`.
//!
//! The crate is split into small, testable modules:
//!
//! * [`protocol`] – the `@@RCB` JSON line protocol.
//! * [`state`] – a pure reducer turning events into view state.
//! * [`runner`] – child process spawning, IO threads and cancellation.
//! * [`theme`] – theme selection and theme-derived colours/styles.
//! * [`ui`] – widget construction and the diffing `render` function.
//! * [`args`] – command-line parsing and build script discovery.
//! * [`app`] – the interactive controller that ties everything together.

pub mod app;
pub mod args;
pub mod protocol;
pub mod runner;
pub mod state;
pub mod theme;
pub mod ui;

use std::collections::HashSet;
use std::error::Error;
use std::path::{Path, PathBuf};

use rtk::Tk;

use protocol::{parse_line, Event, Line};
use state::BuildState;
use theme::ThemeChoice;

/// Default window width in logical pixels.
pub const WINDOW_WIDTH: u32 = 1120;
/// Default window height in logical pixels.
pub const WINDOW_HEIGHT: u32 = 760;

/// Canned protocol output used for headless screenshots and tests.
pub const SAMPLE_RUN: &str = include_str!("../tests/fixtures/sample-run.jsonl");

/// Which moment of the canned run a screenshot shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stage {
    /// Nothing has run yet.
    Idle,
    /// Mid-run, right after project 3 started building.
    Building,
    /// Finished, with the summary applied.
    Results,
}

impl Stage {
    /// All stages in file-name order.
    pub const ALL: [Stage; 3] = [Stage::Idle, Stage::Building, Stage::Results];

    /// File-name fragment for this stage.
    pub fn slug(self) -> &'static str {
        match self {
            Stage::Idle => "idle",
            Stage::Building => "building",
            Stage::Results => "results",
        }
    }
}

/// One rendered screenshot.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Screenshot {
    /// Where the PNG was written.
    pub path: PathBuf,
    /// Number of distinct sampled colours (capped); `1` means a blank image.
    pub distinct_colors: usize,
}

/// Builds the view state for `stage` from the canned [`SAMPLE_RUN`].
pub fn sample_state(stage: Stage) -> BuildState {
    let mut state = BuildState::new();
    if stage == Stage::Idle {
        return state;
    }
    state.begin();
    for raw in SAMPLE_RUN.lines() {
        if raw.trim().is_empty() {
            continue;
        }
        let line = parse_line(raw);
        let stop = stage == Stage::Building
            && matches!(&line, Line::Event(Event::Phase { index: 3, phase, .. }) if phase == "build");
        state.apply_line(line);
        if stop {
            break;
        }
    }
    if stage == Stage::Results {
        let code = state.summary().map(|s| s.exit_code);
        state.child_exited(code);
    }
    state
}

/// Renders the nine documented PNGs into `dir` without opening a window or
/// starting a child process, and returns what was written.
pub fn render_screenshots(dir: &Path) -> Result<Vec<Screenshot>, Box<dyn Error>> {
    std::fs::create_dir_all(dir)?;
    let themes = [
        ("light", ThemeChoice::Light),
        ("dark", ThemeChoice::Dark),
        ("highcontrast", ThemeChoice::HighContrast),
    ];
    let mut shots = Vec::new();
    for (theme_slug, choice) in themes {
        for stage in Stage::ALL {
            let path = dir.join(format!("rcb-gui-{theme_slug}-{}.png", stage.slug()));
            let distinct_colors = render_one(choice, stage, &path)?;
            shots.push(Screenshot {
                path,
                distinct_colors,
            });
        }
    }
    Ok(shots)
}

/// Renders a single screenshot and returns its distinct colour count.
fn render_one(choice: ThemeChoice, stage: Stage, path: &Path) -> Result<usize, Box<dyn Error>> {
    let mut tk = Tk::new();
    tk.title("Rust Click Build");
    tk.geometry(WINDOW_WIDTH, WINDOW_HEIGHT);
    theme::apply(&mut tk, choice);
    let ui = ui::build(&mut tk, choice)?;
    tk.entry_set(ui.folder_entry, "C:\\Users\\dev\\projects\\rust-apps");
    ui.test_var.set(&mut tk, true);
    ui.sign_var.set(&mut tk, true);
    tk.entry_set(ui.thumb_entry, "AABBCCDDEEFF00112233445566778899AABBCCDD");
    let state = sample_state(stage);
    ui::render(&mut tk, &ui, &state);
    let pixmap = tk.render_to_pixmap(WINDOW_WIDTH, WINDOW_HEIGHT)?;
    let distinct = count_distinct(pixmap.data());
    tk.save_png(path, WINDOW_WIDTH, WINDOW_HEIGHT)?;
    Ok(distinct)
}

/// Counts distinct RGBA values in a sample of `data`, capped at 64.
fn count_distinct(data: &[u8]) -> usize {
    let mut seen: HashSet<[u8; 4]> = HashSet::new();
    for px in data.chunks_exact(4).step_by(7) {
        seen.insert([px[0], px[1], px[2], px[3]]);
        if seen.len() >= 64 {
            break;
        }
    }
    seen.len()
}

#[cfg(test)]
mod tests {
    use super::*;
    use state::Status;

    #[test]
    fn sample_stages_have_expected_shape() {
        let idle = sample_state(Stage::Idle);
        assert_eq!(idle.status(), Status::Idle);

        let building = sample_state(Stage::Building);
        assert_eq!(building.status(), Status::Building);
        assert!(building.is_running());
        assert_eq!(building.total(), 5);
        assert_eq!(building.finished(), 2);
        assert!(building.progress_text().contains("Project 3 of 5"));

        let results = sample_state(Stage::Results);
        assert_eq!(results.status(), Status::Failed);
        assert!(!results.is_running());
        assert_eq!(results.passed(), 4);
        assert_eq!(results.failed(), 1);
        assert_eq!(results.finished(), 5);
    }

    #[test]
    fn distinct_counter_detects_blank() {
        let blank = vec![7u8; 4 * 100];
        assert_eq!(count_distinct(&blank), 1);
    }
}
