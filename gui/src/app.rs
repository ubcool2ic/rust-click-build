//! Interactive controller: wires widgets, the runner and the reducer.

use std::cell::RefCell;
use std::error::Error;
use std::mem::discriminant;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::rc::Rc;
use std::sync::Arc;

use rtk::{dialog, ToastKind, Tk, WidgetId};

use crate::args::{self, Args};
use crate::protocol::{Event, Line, Role};
use crate::runner::{self, BuildRequest, Profile, Runner, RunnerMsg, Sink};
use crate::state::{BuildState, Status};
use crate::theme::{self, ThemeChoice};
use crate::ui::{self, Ui};
use crate::{WINDOW_HEIGHT, WINDOW_WIDTH};

/// Controller state living on the UI thread.
struct App {
    ui: Ui,
    state: BuildState,
    runner: Option<Runner>,
    script: Option<PathBuf>,
}

/// Observer of every runner message (test hook).
type Tap = Box<dyn FnMut(&RunnerMsg)>;

thread_local! {
    static APP: RefCell<Option<Rc<RefCell<App>>>> = const { RefCell::new(None) };
    static TAP: RefCell<Option<Tap>> = const { RefCell::new(None) };
}

/// Runs `f` with the controller, or returns `None` if it is not installed
/// or is already in use further up the call stack.
fn with_app<R>(f: impl FnOnce(&mut App) -> R) -> Option<R> {
    let rc = APP.with(|slot| slot.borrow().clone())?;
    let mut guard = rc.try_borrow_mut().ok()?;
    Some(f(&mut guard))
}

/// Result types the folder picker callback may deliver.
#[cfg(feature = "folder-picker")]
trait FirstPath {
    fn first_path(self) -> Option<PathBuf>;
}

#[cfg(feature = "folder-picker")]
impl FirstPath for Option<PathBuf> {
    fn first_path(self) -> Option<PathBuf> {
        self
    }
}

#[cfg(feature = "folder-picker")]
impl FirstPath for Option<Vec<PathBuf>> {
    fn first_path(self) -> Option<PathBuf> {
        self.and_then(|paths| paths.into_iter().next())
    }
}

/// Directory the folder dialog starts in: the folder typed in the path entry
/// when it exists, else the user's home directory, else the current directory.
#[cfg(feature = "folder-picker")]
fn start_dir(current: &str) -> Option<PathBuf> {
    let typed = current.trim().trim_matches('"');
    if !typed.is_empty() {
        let path = PathBuf::from(typed);
        if path.is_dir() {
            return Some(path);
        }
    }
    ["USERPROFILE", "HOME"]
        .into_iter()
        .filter_map(std::env::var_os)
        .map(PathBuf::from)
        .find(|path| path.is_dir())
        .or_else(|| std::env::current_dir().ok())
}

/// Opens rtk's folder picker, starting in the currently typed folder when it
/// exists. A future signature fix is confined to this function.
#[cfg(feature = "folder-picker")]
fn browse_folder(tk: &mut Tk, current: &str, done: fn(&mut Tk, PathBuf)) {
    let mut request = rtk::FileDialog::new().title("Choose a folder of Cargo projects");
    if let Some(dir) = start_dir(current) {
        request = request.directory(dir);
    }
    tk.file_dialog_pick_folder(&request, move |tk, result| {
        if let Some(path) = FirstPath::first_path(result) {
            done(tk, path);
        }
    });
}

/// Fallback without the folder picker: a documented text prompt.
#[cfg(not(feature = "folder-picker"))]
fn browse_folder(tk: &mut Tk, current: &str, done: fn(&mut Tk, PathBuf)) {
    dialog::ask_string(
        tk,
        "Choose folder",
        "Folder containing Cargo projects:",
        current,
        move |tk, result| {
            if let Some(text) = result {
                done(tk, PathBuf::from(text.to_string()));
            }
        },
    );
}

fn on_folder_chosen(tk: &mut Tk, path: PathBuf) {
    with_app(|app| {
        tk.entry_set(app.ui.folder_entry, path.to_string_lossy().into_owned());
        ui::set_error(tk, &app.ui, None);
    });
}

fn on_browse(tk: &mut Tk) {
    let current = with_app(|app| tk.entry_get(app.ui.folder_entry).unwrap_or_default());
    if let Some(current) = current {
        browse_folder(tk, current.as_str(), on_folder_chosen);
    }
}

/// Maps a dropped path to the folder to build: a directory is used as is,
/// a file yields its parent directory, anything else is rejected.
pub fn drop_dir(path: &Path) -> Option<PathBuf> {
    if path.is_dir() {
        Some(path.to_path_buf())
    } else if path.is_file() {
        path.parent()
            .filter(|parent| parent.is_dir())
            .map(Path::to_path_buf)
    } else {
        None
    }
}

/// Handles files/folders dropped on the window.
fn on_file_drop(tk: &mut Tk, paths: &[PathBuf]) {
    let Some(dir) = paths.iter().find_map(|p| drop_dir(p)) else {
        return;
    };
    with_app(|app| {
        if app.state.is_running() {
            return;
        }
        tk.entry_set(app.ui.folder_entry, dir.to_string_lossy().into_owned());
        ui::set_error(tk, &app.ui, None);
    });
}

/// Registers the drop handler on `id`. The opaque return type keeps this
/// call site independent of what `bind_file_drop` returns.
fn install_drop(tk: &mut Tk, id: WidgetId) -> impl Sized {
    tk.bind_file_drop(id, on_file_drop)
}

/// Opens `dir` in the platform file manager.
fn open_folder(dir: &Path) {
    let program = if cfg!(windows) {
        "explorer.exe"
    } else if cfg!(target_os = "macos") {
        "open"
    } else {
        "xdg-open"
    };
    let spawned = Command::new(program)
        .arg(dir)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    if let Ok(mut child) = spawned {
        std::thread::spawn(move || {
            let _ = child.wait();
        });
    }
}

impl App {
    /// Validates the inputs and starts `build.ps1`.
    fn start(&mut self, tk: &mut Tk) {
        if self.state.is_running() {
            return;
        }
        let folder = tk.entry_get(self.ui.folder_entry).unwrap_or_default();
        let folder = folder.trim().trim_matches('"').to_string();
        if folder.is_empty() {
            ui::set_error(
                tk,
                &self.ui,
                Some("Choose the folder that contains your Cargo projects."),
            );
            return;
        }
        let path = PathBuf::from(&folder);
        if !path.is_dir() {
            ui::set_error(tk, &self.ui, Some("That folder does not exist."));
            return;
        }
        if self.script.is_none() {
            self.script = args::find_script(None);
        }
        let script = match &self.script {
            Some(script) if script.is_file() => script.clone(),
            _ => {
                ui::set_error(
                    tk,
                    &self.ui,
                    Some("build.ps1 was not found. Start with --script <path>."),
                );
                return;
            }
        };
        let request = BuildRequest {
            script,
            path,
            profile: if self.ui.profile_var.get(tk) == Some(1) {
                Profile::Debug
            } else {
                Profile::Release
            },
            test: self.ui.test_var.get(tk).unwrap_or(false),
            rtk_update: self.ui.rtk_var.get(tk).unwrap_or(true),
        };
        let spec = runner::build_command_for_host(&request);
        let sink: Sink = Arc::new(|tk: &mut Tk, msg: RunnerMsg| on_runner_msg(tk, msg));
        match Runner::spawn(&spec, tk.proxy(), sink) {
            Ok(runner) => {
                self.state.begin();
                self.runner = Some(runner);
                ui::set_error(tk, &self.ui, None);
            }
            Err(err) => {
                let message = format!(
                    "Could not start {}: {err}",
                    spec.program.to_string_lossy()
                );
                ui::set_error(tk, &self.ui, Some(&message));
            }
        }
        ui::render(tk, &self.ui, &self.state);
    }

    /// Cancels the running build, if any.
    fn cancel(&mut self, tk: &mut Tk) {
        if let Some(runner) = &self.runner {
            self.state.request_cancel();
            runner.cancel();
            ui::render(tk, &self.ui, &self.state);
        }
    }
}

/// Handles one runner message on the UI thread.
fn on_runner_msg(tk: &mut Tk, msg: RunnerMsg) {
    TAP.with(|tap| {
        if let Ok(mut guard) = tap.try_borrow_mut() {
            if let Some(observer) = guard.as_mut() {
                observer(&msg);
            }
        }
    });
    let mut prompt: Option<String> = None;
    let mut finished: Option<Status> = None;
    with_app(|app| {
        match msg {
            RunnerMsg::Line(line) => {
                if let Line::Event(Event::Prompt { question, .. }) = &line {
                    prompt = Some(question.clone());
                }
                app.state.apply_line(line);
            }
            RunnerMsg::Stderr(text) => app.state.push_log(Role::Muted, text),
            RunnerMsg::Exited(code) => {
                app.state.child_exited(code);
                if let Some(runner) = app.runner.take() {
                    runner.join();
                }
                finished = Some(app.state.status());
                ui::render(tk, &app.ui, &app.state);
            }
        };
    });
    if let Some(question) = prompt {
        dialog::ask_yes_no(tk, "Rust Click Build", &question, |_tk, yes| {
            with_app(|app| {
                if let Some(runner) = &app.runner {
                    runner.answer(yes);
                }
            });
        });
    }
    match finished {
        Some(Status::Passed) => {
            tk.toast("Build finished - all projects passed");
        }
        Some(Status::Cancelled) => {
            tk.toast("Build cancelled");
        }
        Some(Status::Failed) => {
            tk.toast_with("Build failed - see the log", ToastKind::Error, 5000);
        }
        _ => {}
    }
}

fn start_build(tk: &mut Tk) {
    with_app(|app| app.start(tk));
}

fn cancel_build(tk: &mut Tk) {
    with_app(|app| app.cancel(tk));
}

fn open_output(tk: &mut Tk) {
    let dir = with_app(|app| app.state.built_dir().map(PathBuf::from)).flatten();
    match dir {
        Some(dir) if dir.is_dir() => open_folder(&dir),
        Some(_) => {
            tk.toast_with("The output folder no longer exists", ToastKind::Error, 4000);
        }
        None => {}
    }
}

fn on_theme_changed(tk: &mut Tk) {
    with_app(|app| {
        let index = app.ui.theme_var.get(tk).unwrap_or(0);
        theme::apply(tk, ThemeChoice::from_index(index));
        ui::render(tk, &app.ui, &app.state);
    });
}

fn tick(tk: &mut Tk) {
    with_app(|app| ui::render(tk, &app.ui, &app.state));
}

/// Binds the first shortcut spelling the toolkit accepts.
fn bind_first(tk: &mut Tk, names: &[&str], action: fn(&mut Tk)) {
    for name in names {
        if tk.bind_shortcut(name, action).is_ok() {
            break;
        }
    }
}

/// Builds the UI into `tk` and installs the controller, callbacks, drop
/// targets, shortcuts and the refresh timer. Does not enter the event loop,
/// so tests can drive the real application headlessly.
pub fn setup(tk: &mut Tk, args: &Args) -> Result<(), Box<dyn Error>> {
    tk.title("Rust Click Build");
    tk.geometry(WINDOW_WIDTH, WINDOW_HEIGHT);
    tk.minsize(1000, 700);

    let choice = args.theme.unwrap_or(ThemeChoice::System);
    theme::apply(tk, choice);
    let ui = ui::build(tk, choice)?;

    if let Some(path) = &args.path {
        tk.entry_set(ui.folder_entry, path.to_string_lossy().into_owned());
    }
    if args.profile == Some(Profile::Debug) {
        ui.profile_var.set(tk, 1);
    }
    if args.test {
        ui.test_var.set(tk, true);
    }
    if args.no_rtk_update {
        ui.rtk_var.set(tk, false);
    }

    let (start_btn, cancel_btn, open_btn, browse_btn, theme_var, folder_entry) = (
        ui.start_btn,
        ui.cancel_btn,
        ui.open_btn,
        ui.browse_btn,
        ui.theme_var,
        ui.folder_entry,
    );
    let app = App {
        ui,
        state: BuildState::new(),
        runner: None,
        script: args::find_script(args.script.as_deref()),
    };
    APP.with(|slot| *slot.borrow_mut() = Some(Rc::new(RefCell::new(app))));

    tk.set_command(start_btn, start_build);
    tk.set_command(cancel_btn, cancel_build);
    tk.set_command(open_btn, open_output);
    tk.set_command(browse_btn, on_browse);
    theme_var.trace(tk, on_theme_changed);

    let root = tk.root();
    install_drop(tk, root);
    install_drop(tk, folder_entry);

    bind_first(tk, &["Ctrl+Enter", "Ctrl+Return"], start_build);
    bind_first(tk, &["F5"], start_build);
    bind_first(tk, &["Escape", "Esc"], cancel_build);

    tk.protocol_close(|tk| {
        with_app(|app| {
            if let Some(runner) = &app.runner {
                runner.cancel();
            }
        });
        tk.quit();
        true
    });
    tk.every(80, tick);
    tick(tk);
    Ok(())
}

/// Removes the controller from this thread (cancelling a running build).
pub fn teardown() {
    APP.with(|slot| *slot.borrow_mut() = None);
    TAP.with(|slot| *slot.borrow_mut() = None);
}

/// Builds the window, installs the controller and runs the event loop.
pub fn run(args: Args) -> Result<(), Box<dyn Error>> {
    let mut tk = Tk::new();
    setup(&mut tk, &args)?;
    let result = tk.mainloop();
    teardown();
    result
}

// ---------------------------------------------------------------------------
// Test hooks: small, read-mostly accessors for headless end-to-end tests.
// ---------------------------------------------------------------------------

/// Widget ids a headless test needs to drive the installed application.
#[derive(Clone, Copy, Debug)]
pub struct UiHandles {
    /// "Start build" button.
    pub start: WidgetId,
    /// "Cancel" button.
    pub cancel: WidgetId,
    /// "Open output folder" button.
    pub open: WidgetId,
    /// "Browse..." button.
    pub browse: WidgetId,
    /// Folder path entry.
    pub folder_entry: WidgetId,
    /// Inline hint / validation error label.
    pub error_label: WidgetId,
    /// Results table.
    pub table: WidgetId,
    /// Status chip in the header.
    pub status_chip: WidgetId,
}

/// Handles of the installed application, if [`setup`] ran on this thread.
pub fn ui_handles() -> Option<UiHandles> {
    with_app(|app| UiHandles {
        start: app.ui.start_btn,
        cancel: app.ui.cancel_btn,
        open: app.ui.open_btn,
        browse: app.ui.browse_btn,
        folder_entry: app.ui.folder_entry,
        error_label: app.ui.error_label,
        table: app.ui.table,
        status_chip: app.ui.status_chip,
    })
}

/// Delivers pending runner messages and runs the same refresh as the timer.
pub fn pump(tk: &mut Tk) {
    let _ = tk.process_posted();
    tick(tk);
}

/// Reads the current build state of the installed application.
pub fn with_state<R>(f: impl FnOnce(&BuildState) -> R) -> Option<R> {
    with_app(|app| f(&app.state))
}

/// Whether a child process is currently attached.
pub fn has_runner() -> bool {
    with_app(|app| app.runner.is_some()).unwrap_or(false)
}

/// Switches the theme through the selector variable and the same handler
/// the theme combobox triggers.
pub fn select_theme(tk: &mut Tk, choice: ThemeChoice) {
    let Some(var) = with_app(|app| app.ui.theme_var) else {
        return;
    };
    let want = discriminant(&choice);
    let index = (0..8i64).find(|&i| discriminant(&ThemeChoice::from_index(i)) == want);
    if let Some(index) = index {
        var.set(tk, index);
    }
    on_theme_changed(tk);
}

/// Installs (or clears) an observer that sees every runner message before
/// it is applied to the state.
/// Callback that observes every runner message (test hook).
pub type MessageTap = Box<dyn FnMut(&RunnerMsg)>;

pub fn set_message_tap(tap: Option<MessageTap>) {
    TAP.with(|slot| *slot.borrow_mut() = tap);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsString;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("rcb-gui-drop-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        dir
    }

    #[test]
    fn drop_dir_rules() {
        let dir = temp_dir("rules");
        let file = dir.join("Cargo.toml");
        std::fs::write(&file, "[package]\n").expect("write");
        assert_eq!(drop_dir(&dir), Some(dir.clone()));
        assert_eq!(drop_dir(&file), Some(dir.clone()));
        assert_eq!(drop_dir(&dir.join("missing")), None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn dropping_sets_the_folder_entry() {
        let dir = temp_dir("sim");
        let sub = dir.join("sub folder");
        std::fs::create_dir_all(&sub).expect("sub dir");
        let file = dir.join("main.rs");
        std::fs::write(&file, "fn main() {}\n").expect("write");

        let args = match args::parse(std::iter::empty::<OsString>()) {
            Ok(args) => args,
            Err(_) => panic!("empty argument list must parse"),
        };
        let mut tk = Tk::new();
        setup(&mut tk, &args).expect("setup");
        tk.sim_resize(WINDOW_WIDTH, WINDOW_HEIGHT);
        let handles = ui_handles().expect("handles");
        let rect = tk.widget_rect(handles.folder_entry).expect("entry rect");
        let (x, y) = (rect.x + rect.width / 2.0, rect.y + rect.height / 2.0);
        let entry_text = |tk: &mut Tk| tk.entry_get(handles.folder_entry).unwrap_or_default();

        // A directory dropped on the entry is used as is.
        tk.sim_file_drop(x, y, std::slice::from_ref(&sub));
        assert_eq!(entry_text(&mut tk).as_str(), sub.to_string_lossy());

        // A file dropped elsewhere on the window selects its parent.
        let table = tk.widget_rect(handles.table).expect("table rect");
        tk.sim_file_drop(
            table.x + table.width / 2.0,
            table.y + table.height / 2.0,
            std::slice::from_ref(&file),
        );
        assert_eq!(entry_text(&mut tk).as_str(), dir.to_string_lossy());

        // Drops are ignored while a build is running.
        with_app(|app| app.state.begin());
        tk.sim_file_drop(x, y, std::slice::from_ref(&sub));
        assert_eq!(entry_text(&mut tk).as_str(), dir.to_string_lossy());

        teardown();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(feature = "folder-picker")]
    #[test]
    fn browse_fills_the_entry_from_the_file_dialog() {
        use rtk::file_dialog::MockFileDialog;

        let dir = temp_dir("browse");

        let args = match args::parse(std::iter::empty::<OsString>()) {
            Ok(args) => args,
            Err(_) => panic!("empty argument list must parse"),
        };
        let mut tk = Tk::new();
        setup(&mut tk, &args).expect("setup");
        tk.sim_resize(WINDOW_WIDTH, WINDOW_HEIGHT);

        let mock = MockFileDialog::new();
        mock.push_response(Some(vec![dir.clone()]));
        tk.file_dialog_set_backend(mock.clone());

        let handles = ui_handles().expect("handles");
        let rect = tk.widget_rect(handles.browse).expect("browse rect");
        tk.sim_click(rect.x + rect.width / 2.0, rect.y + rect.height / 2.0);
        pump(&mut tk);

        let text = tk.entry_get(handles.folder_entry).unwrap_or_default();
        assert_eq!(text.as_str(), dir.to_string_lossy());
        assert_eq!(mock.request_count(), 1);

        teardown();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
