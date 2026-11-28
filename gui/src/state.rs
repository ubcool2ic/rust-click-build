//! Pure view-state reducer: protocol events in, display data out.

use std::collections::VecDeque;

use crate::protocol::{Event, Line, Role};

/// Default maximum number of retained log lines.
pub const DEFAULT_LOG_CAPACITY: usize = 4000;
/// Upper bound on project indices accepted from the child.
const MAX_PROJECTS: u64 = 10_000;
/// Longest retained log line in characters; longer lines are cut.
const MAX_LOG_LINE_CHARS: usize = 4096;

/// Index to show as "current project": 0 (none) when out of range.
fn shown_index(index: u64) -> u64 {
    if (1..=MAX_PROJECTS).contains(&index) {
        index
    } else {
        0
    }
}

/// Overall run status shown in the header chip.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    /// Nothing has run yet.
    Idle,
    /// A build is in progress.
    Building,
    /// The run finished successfully.
    Passed,
    /// The run failed.
    Failed,
    /// The run was cancelled.
    Cancelled,
}

impl Status {
    /// Short label for the status chip.
    pub fn label(self) -> &'static str {
        match self {
            Status::Idle => "Idle",
            Status::Building => "Building",
            Status::Passed => "Passed",
            Status::Failed => "Failed",
            Status::Cancelled => "Cancelled",
        }
    }
}

/// Lifecycle of one project row.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RowState {
    /// Not started yet.
    Queued,
    /// Currently being processed.
    Running,
    /// Finished.
    Done,
}

/// One row of the results table.
#[derive(Clone, Debug, PartialEq)]
pub struct ProjectRow {
    /// Project name.
    pub name: String,
    /// Lifecycle state.
    pub state: RowState,
    /// Current phase (`rtk`, `build`, `test`, `collect`, `sign`).
    pub phase: String,
    /// Build result (`PASS`/`FAIL`), empty until finished.
    pub build: String,
    /// Test result, empty until finished.
    pub test: String,
    /// rtk status text.
    pub rtk: String,
    /// Whether the rtk dependency was changed.
    pub rtk_changed: bool,
    /// Duration in seconds.
    pub seconds: Option<f64>,
    /// Number of artifacts.
    pub artifacts: Option<u64>,
    /// Signing status (`signed`, `SIGN FAILED`, `skipped`).
    pub sign: String,
    /// Error lines reported for the project.
    pub errors: Vec<String>,
    /// Hint lines reported for the project.
    pub hints: Vec<String>,
}

impl ProjectRow {
    fn queued(name: &str) -> Self {
        Self {
            name: name.to_string(),
            state: RowState::Queued,
            phase: String::new(),
            build: String::new(),
            test: String::new(),
            rtk: String::new(),
            rtk_changed: false,
            seconds: None,
            artifacts: None,
            sign: String::new(),
            errors: Vec::new(),
            hints: Vec::new(),
        }
    }
}

/// The final summary reported by the script.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Summary {
    /// Everything passed.
    pub success: bool,
    /// The run was cancelled.
    pub cancelled: bool,
    /// Script exit code.
    pub exit_code: i32,
    /// Output folder.
    pub built_dir: String,
    /// Log file path.
    pub log_file: String,
    /// Passed projects.
    pub passed: u64,
    /// Failed projects.
    pub failed: u64,
}

/// Human-readable label for a phase name.
pub fn phase_label(phase: &str) -> &str {
    match phase {
        "rtk" => "checking rtk",
        "build" => "building",
        "test" => "testing",
        "collect" => "collecting artifacts",
        "sign" => "signing",
        "" => "starting",
        other => other,
    }
}

/// Everything the UI needs to draw a run.
#[derive(Clone, Debug)]
pub struct BuildState {
    status: Status,
    running: bool,
    cancel_requested: bool,
    rows: Vec<ProjectRow>,
    total: u64,
    current_index: u64,
    current_name: String,
    current_phase: String,
    log: VecDeque<(Role, String)>,
    log_capacity: usize,
    log_rev: u64,
    table_rev: u64,
    summary: Option<Summary>,
    fatal: Option<String>,
    exit_code: Option<i32>,
    log_file: String,
}

impl Default for BuildState {
    fn default() -> Self {
        Self::new()
    }
}

impl BuildState {
    /// Creates an idle state with the default log capacity.
    pub fn new() -> Self {
        Self::with_log_capacity(DEFAULT_LOG_CAPACITY)
    }

    /// Creates an idle state retaining at most `capacity` log lines.
    pub fn with_log_capacity(capacity: usize) -> Self {
        Self {
            status: Status::Idle,
            running: false,
            cancel_requested: false,
            rows: Vec::new(),
            total: 0,
            current_index: 0,
            current_name: String::new(),
            current_phase: String::new(),
            log: VecDeque::new(),
            log_capacity: capacity.max(1),
            log_rev: 0,
            table_rev: 0,
            summary: None,
            fatal: None,
            exit_code: None,
            log_file: String::new(),
        }
    }

    /// Resets everything for a new run and marks it as building.
    pub fn begin(&mut self) {
        let (cap, log_rev, table_rev) = (self.log_capacity, self.log_rev, self.table_rev);
        *self = Self::with_log_capacity(cap);
        self.log_rev = log_rev + 1;
        self.table_rev = table_rev + 1;
        self.status = Status::Building;
        self.running = true;
    }

    /// Applies one classified output line.
    pub fn apply_line(&mut self, line: Line) {
        match line {
            Line::Event(event) => self.apply(&event),
            Line::Unknown(_) => {}
            Line::Malformed(text) | Line::Text(text) => self.push_log(Role::Muted, text),
        }
    }

    /// Applies one protocol event.
    pub fn apply(&mut self, event: &Event) {
        match event {
            Event::Start { log_file, .. } => {
                if self.status == Status::Idle {
                    self.status = Status::Building;
                    self.running = true;
                }
                self.log_file = log_file.clone();
            }
            Event::Log { text, role } => self.push_log(*role, text.clone()),
            Event::Discovered { count, projects } => {
                self.total = (*count).min(MAX_PROJECTS);
                self.rows = projects
                    .iter()
                    .take(MAX_PROJECTS as usize)
                    .map(|p| ProjectRow::queued(p))
                    .collect();
                self.table_rev += 1;
            }
            Event::ProjectStart {
                index, total, name, ..
            } => {
                self.total = self.total.max((*total).min(MAX_PROJECTS));
                self.current_index = shown_index(*index);
                self.current_name = name.clone();
                self.current_phase.clear();
                if let Some(row) = self.row_mut(*index) {
                    row.name = name.clone();
                    row.state = RowState::Running;
                    row.phase.clear();
                }
            }
            Event::Phase { index, name, phase } => {
                self.current_index = shown_index(*index);
                self.current_name = name.clone();
                self.current_phase = phase.clone();
                if let Some(row) = self.row_mut(*index) {
                    if row.state != RowState::Done {
                        row.state = RowState::Running;
                        row.phase = phase.clone();
                    }
                }
            }
            Event::Rtk {
                index,
                status,
                changed,
                ..
            } => {
                if let Some(row) = self.row_mut(*index) {
                    row.rtk = status.clone();
                    row.rtk_changed = *changed;
                }
            }
            Event::Sign {
                index,
                status,
                error,
                ..
            } => {
                if let Some(row) = self.row_mut(*index) {
                    if status.eq_ignore_ascii_case("SIGN FAILED") || !error.is_empty() {
                        row.sign = "SIGN FAILED".into();
                    } else if row.sign != "SIGN FAILED" {
                        row.sign = status.clone();
                    }
                }
            }
            Event::ProjectEnd {
                index,
                name,
                build,
                test,
                artifacts,
                seconds,
                rtk,
                sign,
                errors,
                hints,
            } => {
                if let Some(row) = self.row_mut(*index) {
                    row.name = name.clone();
                    row.state = RowState::Done;
                    row.build = build.clone();
                    row.test = test.clone();
                    row.artifacts = Some(*artifacts);
                    row.seconds = Some(*seconds);
                    if !rtk.is_empty() {
                        row.rtk = rtk.clone();
                    }
                    if !sign.is_empty() {
                        row.sign = sign.clone();
                    }
                    row.errors = errors.clone();
                    row.hints = hints.clone();
                }
            }
            Event::Prompt { question, .. } => {
                self.push_log(Role::Accent, format!("? {question}"));
            }
            Event::Summary {
                success,
                cancelled,
                exit_code,
                built_dir,
                log_file,
                passed,
                failed,
            } => {
                self.status = if *cancelled {
                    Status::Cancelled
                } else if *success {
                    Status::Passed
                } else {
                    Status::Failed
                };
                if !log_file.is_empty() {
                    self.log_file = log_file.clone();
                }
                self.summary = Some(Summary {
                    success: *success,
                    cancelled: *cancelled,
                    exit_code: *exit_code,
                    built_dir: built_dir.clone(),
                    log_file: log_file.clone(),
                    passed: *passed,
                    failed: *failed,
                });
                self.table_rev += 1;
            }
            Event::Fatal { message } => {
                self.push_log(Role::Danger, format!("fatal: {message}"));
                self.fatal = Some(message.clone());
                self.status = Status::Failed;
            }
        }
    }

    /// Returns the row for a 1-based index, growing the table if needed.
    fn row_mut(&mut self, index: u64) -> Option<&mut ProjectRow> {
        if index == 0 || index > MAX_PROJECTS {
            return None;
        }
        let idx = usize::try_from(index).ok()?;
        while self.rows.len() < idx {
            self.rows.push(ProjectRow::queued(""));
        }
        self.table_rev += 1;
        self.rows.get_mut(idx - 1)
    }

    /// Appends a log line, dropping the oldest beyond the capacity.
    pub fn push_log(&mut self, role: Role, text: impl Into<String>) {
        while self.log.len() >= self.log_capacity {
            self.log.pop_front();
        }
        let mut text: String = text.into();
        if let Some((cut, _)) = text.char_indices().nth(MAX_LOG_LINE_CHARS) {
            text.truncate(cut);
            text.push('…');
        }
        self.log.push_back((role, text));
        self.log_rev += 1;
    }

    /// Records that the user asked to cancel.
    pub fn request_cancel(&mut self) {
        if self.running && !self.cancel_requested {
            self.cancel_requested = true;
            self.push_log(Role::Warning, "Cancelling build...");
        }
    }

    /// Records that the child process exited with `code`.
    pub fn child_exited(&mut self, code: Option<i32>) {
        self.running = false;
        self.exit_code = code;
        if self.summary.is_some() {
            return;
        }
        if self.cancel_requested {
            self.status = Status::Cancelled;
            self.push_log(Role::Warning, "Build cancelled.");
        } else {
            self.status = Status::Failed;
            let msg = match code {
                Some(c) => format!("build.ps1 exited without a summary (exit code {c})"),
                None => "build.ps1 was terminated without a summary".to_string(),
            };
            self.push_log(Role::Danger, msg);
        }
    }

    /// Current status.
    pub fn status(&self) -> Status {
        self.status
    }

    /// Whether a child process is believed to be running.
    pub fn is_running(&self) -> bool {
        self.running
    }

    /// Project rows.
    pub fn rows(&self) -> &[ProjectRow] {
        &self.rows
    }

    /// Total number of projects.
    pub fn total(&self) -> u64 {
        self.total.max(self.rows.len() as u64)
    }

    /// Number of finished projects.
    pub fn finished(&self) -> u64 {
        self.rows
            .iter()
            .filter(|r| r.state == RowState::Done)
            .count() as u64
    }

    /// Number of passed projects (summary value if available).
    pub fn passed(&self) -> u64 {
        match &self.summary {
            Some(summary) => summary.passed,
            None => self
                .rows
                .iter()
                .filter(|r| r.state == RowState::Done && !row_failed(r))
                .count() as u64,
        }
    }

    /// Number of failed projects (summary value if available).
    pub fn failed(&self) -> u64 {
        match &self.summary {
            Some(summary) => summary.failed,
            None => self
                .rows
                .iter()
                .filter(|r| r.state == RowState::Done && row_failed(r))
                .count() as u64,
        }
    }

    /// Fraction of finished projects in `0.0..=1.0`.
    pub fn progress_fraction(&self) -> f64 {
        let total = self.total();
        if total == 0 {
            return 0.0;
        }
        (self.finished() as f64 / total as f64).clamp(0.0, 1.0)
    }

    /// One-line description of what is happening.
    pub fn progress_text(&self) -> String {
        match self.status {
            Status::Idle => "Ready - choose a folder and press Start build".to_string(),
            Status::Building => {
                if self.cancel_requested {
                    "Cancelling...".to_string()
                } else if self.current_index > 0 {
                    format!(
                        "Project {} of {} - {} - {}",
                        self.current_index,
                        self.total(),
                        self.current_name,
                        phase_label(&self.current_phase)
                    )
                } else if self.total() > 0 {
                    format!("{} projects discovered", self.total())
                } else {
                    "Starting build.ps1...".to_string()
                }
            }
            Status::Passed | Status::Failed | Status::Cancelled => {
                if self.summary.is_some() {
                    format!(
                        "{} of {} projects finished - {} passed, {} failed",
                        self.finished(),
                        self.total(),
                        self.passed(),
                        self.failed()
                    )
                } else if let Some(fatal) = &self.fatal {
                    format!("Build failed: {fatal}")
                } else if self.status == Status::Cancelled {
                    "Build cancelled".to_string()
                } else {
                    match self.exit_code {
                        Some(code) => format!("Build stopped unexpectedly (exit code {code})"),
                        None => "Build stopped unexpectedly".to_string(),
                    }
                }
            }
        }
    }

    /// Secondary line under the results table.
    pub fn summary_text(&self) -> String {
        if self.status == Status::Idle {
            return "No results yet".to_string();
        }
        if self.log_file.is_empty() {
            format!("{} of {} finished", self.finished(), self.total())
        } else {
            format!(
                "{} of {} finished  -  log: {}",
                self.finished(),
                self.total(),
                self.log_file
            )
        }
    }

    /// Rows for the results table: Project, Build, Tests, rtk, Time, Artifacts, Sign.
    pub fn table_rows(&self) -> Vec<Vec<String>> {
        self.rows
            .iter()
            .map(|row| {
                let (build, test) = match row.state {
                    RowState::Queued => ("queued".to_string(), String::new()),
                    RowState::Running => (format!("{}...", phase_label(&row.phase)), String::new()),
                    RowState::Done => (row.build.clone(), row.test.clone()),
                };
                vec![
                    row.name.clone(),
                    build,
                    test,
                    row.rtk.clone(),
                    row.seconds.map(|s| format!("{s:.1}s")).unwrap_or_default(),
                    row.artifacts.map(|a| a.to_string()).unwrap_or_default(),
                    row.sign.clone(),
                ]
            })
            .collect()
    }

    /// Number of retained log lines.
    pub fn log_len(&self) -> usize {
        self.log.len()
    }

    /// The last `n` log lines, oldest first.
    pub fn log_tail(&self, n: usize) -> impl Iterator<Item = &(Role, String)> {
        self.log.iter().skip(self.log.len().saturating_sub(n))
    }

    /// Changes whenever the log changes.
    pub fn log_revision(&self) -> u64 {
        self.log_rev
    }

    /// Changes whenever the table may have changed.
    pub fn table_revision(&self) -> u64 {
        self.table_rev
    }

    /// The final summary, if one was received.
    pub fn summary(&self) -> Option<&Summary> {
        self.summary.as_ref()
    }

    /// Output folder reported by the summary, if any.
    pub fn built_dir(&self) -> Option<&str> {
        self.summary
            .as_ref()
            .map(|s| s.built_dir.as_str())
            .filter(|d| !d.is_empty())
    }

    /// Exit code of the child, once it has exited.
    pub fn exit_code(&self) -> Option<i32> {
        self.exit_code
    }

    /// Fatal error message, if any.
    pub fn fatal(&self) -> Option<&str> {
        self.fatal.as_deref()
    }
}

fn row_failed(row: &ProjectRow) -> bool {
    row.build.eq_ignore_ascii_case("FAIL") || row.test.eq_ignore_ascii_case("FAIL")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn end(index: u64, build: &str, test: &str) -> Event {
        Event::ProjectEnd {
            index,
            name: format!("p{index}"),
            build: build.into(),
            test: test.into(),
            artifacts: 1,
            seconds: 2.25,
            rtk: "v1.0.2".into(),
            sign: "signed".into(),
            errors: vec![],
            hints: vec![],
        }
    }

    fn started() -> BuildState {
        let mut st = BuildState::new();
        st.begin();
        st.apply(&Event::Discovered {
            count: 4,
            projects: vec!["p1".into(), "p2".into(), "p3".into(), "p4".into()],
        });
        st
    }

    #[test]
    fn counts_and_progress() {
        let mut st = started();
        assert_eq!(st.status(), Status::Building);
        assert_eq!(st.total(), 4);
        assert_eq!(st.progress_fraction(), 0.0);
        st.apply(&Event::ProjectStart {
            index: 1,
            total: 4,
            name: "p1".into(),
            dir: "d".into(),
        });
        st.apply(&Event::Phase {
            index: 1,
            name: "p1".into(),
            phase: "build".into(),
        });
        assert_eq!(st.progress_text(), "Project 1 of 4 - p1 - building");
        assert_eq!(st.table_rows()[0][1], "building...");
        st.apply(&end(1, "PASS", "PASS"));
        st.apply(&end(2, "FAIL", "N/A"));
        assert_eq!(st.finished(), 2);
        assert_eq!(st.passed(), 1);
        assert_eq!(st.failed(), 1);
        assert!((st.progress_fraction() - 0.5).abs() < 1e-9);
        let rows = st.table_rows();
        assert_eq!(
            rows[1],
            vec!["p2", "FAIL", "N/A", "v1.0.2", "2.2s", "1", "signed"]
                .into_iter()
                .map(String::from)
                .collect::<Vec<_>>()
        );
        assert_eq!(rows[3][1], "queued");
    }

    #[test]
    fn failure_summary() {
        let mut st = started();
        st.apply(&end(1, "FAIL", "N/A"));
        st.apply(&Event::Summary {
            success: false,
            cancelled: false,
            exit_code: 1,
            built_dir: "out".into(),
            log_file: "log.txt".into(),
            passed: 3,
            failed: 1,
        });
        assert_eq!(st.status(), Status::Failed);
        assert!(st.is_running());
        st.child_exited(Some(1));
        assert!(!st.is_running());
        assert_eq!(st.status(), Status::Failed);
        assert_eq!(st.passed(), 3);
        assert_eq!(st.failed(), 1);
        assert_eq!(st.built_dir(), Some("out"));
        assert!(st.summary_text().contains("log.txt"));
    }

    #[test]
    fn bounded_log() {
        let mut st = BuildState::with_log_capacity(10);
        for i in 0..25 {
            st.push_log(Role::Text, format!("line {i}"));
        }
        assert_eq!(st.log_len(), 10);
        let tail: Vec<&str> = st.log_tail(100).map(|(_, t)| t.as_str()).collect();
        assert_eq!(tail.first().copied(), Some("line 15"));
        assert_eq!(tail.last().copied(), Some("line 24"));
        assert_eq!(st.log_tail(3).count(), 3);
    }

    #[test]
    fn missing_summary_uses_exit_code() {
        let mut st = started();
        st.child_exited(Some(3));
        assert_eq!(st.status(), Status::Failed);
        assert_eq!(st.exit_code(), Some(3));
        assert!(st.progress_text().contains("exit code 3"));
        assert!(st.log_tail(1).any(|(role, _)| *role == Role::Danger));
    }

    #[test]
    fn cancel_without_summary_is_cancelled() {
        let mut st = started();
        st.request_cancel();
        st.child_exited(None);
        assert_eq!(st.status(), Status::Cancelled);
    }

    #[test]
    fn hostile_indices_do_not_panic() {
        let mut st = started();
        st.apply(&end(0, "PASS", "PASS"));
        st.apply(&end(u64::MAX, "PASS", "PASS"));
        st.apply(&end(6, "PASS", "PASS"));
        assert_eq!(st.rows().len(), 6);
        st.apply_line(Line::Malformed("@@RCB {oops".into()));
        st.apply_line(Line::Unknown("x".into()));
        assert_eq!(st.log_len(), 1);
    }

    #[test]
    fn oversized_input_is_bounded() {
        let mut st = BuildState::new();
        st.begin();
        st.push_log(Role::Text, "é".repeat(MAX_LOG_LINE_CHARS * 3));
        let (_, text) = st.log_tail(1).next().expect("one line");
        assert_eq!(text.chars().count(), MAX_LOG_LINE_CHARS + 1);

        st.apply(&Event::Discovered {
            count: u64::MAX,
            projects: vec![String::new(); MAX_PROJECTS as usize + 50],
        });
        assert_eq!(st.rows().len(), MAX_PROJECTS as usize);
        assert_eq!(st.total(), MAX_PROJECTS);
    }

    #[test]
    fn out_of_range_current_index_is_not_shown() {
        let huge = u64::MAX.to_string();
        let mut st = started();
        st.apply(&Event::ProjectStart {
            index: u64::MAX,
            total: 4,
            name: "x".into(),
            dir: "d".into(),
        });
        assert!(!st.progress_text().contains(&huge));
        st.apply(&Event::Phase {
            index: u64::MAX,
            name: "x".into(),
            phase: "build".into(),
        });
        assert!(!st.progress_text().contains(&huge));
        assert_eq!(st.rows().len(), 4);
    }

    #[test]
    fn fatal_marks_failure() {
        let mut st = started();
        st.apply(&Event::Fatal {
            message: "cargo missing".into(),
        });
        st.child_exited(Some(2));
        assert_eq!(st.status(), Status::Failed);
        assert!(st.progress_text().contains("cargo missing"));
    }
}
