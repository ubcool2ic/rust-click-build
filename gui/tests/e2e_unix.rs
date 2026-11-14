//! End-to-end: the real `build.ps1` (run by `pwsh`) driven through the real
//! GUI, headlessly, with a fake `cargo` on PATH.
#![cfg(unix)]

use std::cell::RefCell;
use std::ffi::OsString;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::{Duration, Instant};

use rcb_gui::app::{self, UiHandles};
use rcb_gui::args::{self, Args};
use rcb_gui::runner::Profile;
use rcb_gui::state::Status;
use rcb_gui::theme::ThemeChoice;
use rcb_gui::{WINDOW_HEIGHT, WINDOW_WIDTH};
use rtk::{Tk, WidgetId};

fn on_path(program: &str) -> bool {
    std::env::var_os("PATH")
        .map(|paths| std::env::split_paths(&paths).any(|dir| dir.join(program).is_file()))
        .unwrap_or(false)
}

fn copy_tree(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).expect("create dir");
    for entry in std::fs::read_dir(from).expect("read fixture dir") {
        let entry = entry.expect("dir entry");
        let target = to.join(entry.file_name());
        if entry.path().is_dir() {
            copy_tree(&entry.path(), &target);
        } else {
            std::fs::copy(entry.path(), &target).expect("copy file");
        }
    }
}

fn make_projects(fixtures: &Path, dir: &Path) {
    copy_tree(&fixtures.join("tag-old"), &dir.join("app-one"));
    copy_tree(&fixtures.join("no-rtk"), &dir.join("app-two"));
}

fn make_args(script: &Path, projects: &Path, theme: ThemeChoice) -> Args {
    let mut parsed = match args::parse(std::iter::empty::<OsString>()) {
        Ok(parsed) => parsed,
        Err(_) => panic!("empty argument list must parse"),
    };
    parsed.script = Some(script.to_path_buf());
    parsed.path = Some(projects.to_path_buf());
    parsed.profile = Some(Profile::Debug);
    parsed.test = true;
    parsed.no_rtk_update = true;
    parsed.theme = Some(theme);
    parsed
}

fn click(tk: &mut Tk, id: WidgetId) {
    let rect = tk.widget_rect(id).expect("widget is laid out");
    tk.sim_click(rect.x + rect.width / 2.0, rect.y + rect.height / 2.0);
}

/// Sets the app up, records every runner message and clicks "Start build".
fn launch(parsed: &Args) -> (Tk, UiHandles, Rc<RefCell<Vec<String>>>) {
    let mut tk = Tk::new();
    app::setup(&mut tk, parsed).expect("setup");
    tk.sim_resize(WINDOW_WIDTH, WINDOW_HEIGHT);
    let transcript = Rc::new(RefCell::new(Vec::new()));
    let store = Rc::clone(&transcript);
    app::set_message_tap(Some(Box::new(move |msg| {
        store.borrow_mut().push(format!("{msg:?}"));
    })));
    let handles = app::ui_handles().expect("handles");
    click(&mut tk, handles.start);
    (tk, handles, transcript)
}

fn wait_finished(tk: &mut Tk, transcript: &Rc<RefCell<Vec<String>>>) {
    let deadline = Instant::now() + Duration::from_secs(120);
    loop {
        app::pump(tk);
        let running = app::with_state(|s| s.is_running()).unwrap_or(false);
        if !running && !app::has_runner() {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "build timed out: {:#?}",
            transcript.borrow()
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    app::pump(tk);
}

fn save(tk: &mut Tk, shots: Option<&PathBuf>, name: &str) {
    if let Some(dir) = shots {
        std::fs::create_dir_all(dir).expect("shots dir");
        tk.save_png(dir.join(name), WINDOW_WIDTH, WINDOW_HEIGHT)
            .expect("save png");
    }
}

#[test]
fn real_build_script_through_the_gui() {
    if !on_path("pwsh") {
        eprintln!("skipping e2e test: `pwsh` is not on PATH");
        return;
    }
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
    let script = repo.join("build.ps1");
    let fixtures = repo.join("tests").join("fixtures");
    assert!(script.is_file(), "missing {}", script.display());

    let tmp = std::env::temp_dir().join(format!("rcb-gui-e2e-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp);
    let bin = tmp.join("bin");
    std::fs::create_dir_all(&bin).expect("bin dir");
    let cargo = bin.join("cargo");
    std::fs::copy(fixtures.join("fake-cargo.sh"), &cargo).expect("copy fake cargo");
    std::fs::set_permissions(&cargo, std::fs::Permissions::from_mode(0o755)).expect("chmod");

    // Single test function in this binary, so mutating the environment is safe.
    let mut paths = vec![bin.clone()];
    if let Some(old) = std::env::var_os("PATH") {
        paths.extend(std::env::split_paths(&old));
    }
    std::env::set_var("PATH", std::env::join_paths(paths).expect("join PATH"));
    std::env::remove_var("RCB_PWSH");
    std::env::remove_var("FAKE_CARGO_FAIL_TAG");
    let shots = std::env::var_os("RCB_E2E_SHOTS").map(PathBuf::from);

    // --- Scenario A: everything passes -----------------------------------
    {
        let projects = tmp.join("projects");
        make_projects(&fixtures, &projects);
        let parsed = make_args(&script, &projects, ThemeChoice::Light);
        let (mut tk, _handles, transcript) = launch(&parsed);
        assert!(app::has_runner(), "Start build did not spawn the script");
        wait_finished(&mut tk, &transcript);

        let (status, total, passed, failed, exit, can_open) = app::with_state(|s| {
            (
                s.status(),
                s.total(),
                s.passed(),
                s.failed(),
                s.summary().map(|x| x.exit_code),
                s.built_dir().map(PathBuf::from).is_some(),
            )
        })
        .expect("state");
        let log = transcript.borrow().join("\n");
        assert_eq!(status, Status::Passed, "{log}");
        assert_eq!(total, 2, "{log}");
        assert_eq!(passed, 2, "{log}");
        assert_eq!(failed, 0, "{log}");
        assert_eq!(exit, Some(0), "{log}");
        assert!(can_open, "output folder should be available: {log}");

        for (slug, choice) in [
            ("light", ThemeChoice::Light),
            ("dark", ThemeChoice::Dark),
            ("highcontrast", ThemeChoice::HighContrast),
        ] {
            app::select_theme(&mut tk, choice);
            app::pump(&mut tk);
            save(&mut tk, shots.as_ref(), &format!("rcb-gui-e2e-pass-{slug}.png"));
        }
        app::teardown();
    }

    // --- Scenario B: app-one fails to compile ------------------------------
    {
        std::env::set_var("FAKE_CARGO_FAIL_TAG", "v0.8.2");
        let projects = tmp.join("projects-fail");
        make_projects(&fixtures, &projects);
        let parsed = make_args(&script, &projects, ThemeChoice::Dark);
        let (mut tk, _handles, transcript) = launch(&parsed);
        assert!(app::has_runner(), "Start build did not spawn the script");
        wait_finished(&mut tk, &transcript);

        let (status, passed, failed, exit) = app::with_state(|s| {
            (
                s.status(),
                s.passed(),
                s.failed(),
                s.summary().map(|x| x.exit_code),
            )
        })
        .expect("state");
        let log = transcript.borrow().join("\n");
        assert_eq!(status, Status::Failed, "{log}");
        assert_eq!(passed, 1, "{log}");
        assert_eq!(failed, 1, "{log}");
        assert_eq!(exit, Some(1), "{log}");
        assert!(log.contains("app-one"), "{log}");
        assert!(log.contains("E0425"), "error block missing: {log}");

        save(&mut tk, shots.as_ref(), "rcb-gui-e2e-fail-dark.png");
        app::teardown();
        std::env::remove_var("FAKE_CARGO_FAIL_TAG");
    }

    // --- Scenario C: missing folder -> inline error, nothing spawned -------
    {
        let missing = tmp.join("does-not-exist");
        let parsed = make_args(&script, &missing, ThemeChoice::Light);
        let (mut tk, handles, transcript) = launch(&parsed);
        app::pump(&mut tk);
        assert!(!app::has_runner());
        assert_eq!(app::with_state(|s| s.status()), Some(Status::Idle));
        assert!(transcript.borrow().is_empty());
        let hint = tk.widget_text(handles.error_label).unwrap_or_default();
        assert!(hint.contains("does not exist"), "hint was: {hint:?}");
        app::teardown();
    }

    let _ = std::fs::remove_dir_all(&tmp);
}
