//! Runner integration test: a tiny shell script stands in for PowerShell.
#![cfg(unix)]

use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use rcb_gui::protocol::{Event, Line, Role};
use rcb_gui::runner::{self, BuildRequest, CommandSpec, Profile, Runner, RunnerMsg, Sink};
use rtk::Tk;

const SCRIPT: &str = r#"#!/bin/sh
echo '@@RCB {"event":"start","version":1,"path":"/tmp/x","profile":"release","test":false,"rtk_update":true,"log_file":"/tmp/x/log.txt"}'
echo 'plain line'
echo 'warn on stderr' 1>&2
echo '@@RCB {"event":"prompt","id":"p1","question":"Continue?"}'
read answer
echo "@@RCB {\"event\":\"log\",\"text\":\"answer=$answer\",\"role\":\"info\"}"
echo '@@RCB {"event":"summary","success":true,"cancelled":false,"exit_code":0,"built_dir":"/tmp/x/_built","log_file":"/tmp/x/log.txt","passed":1,"failed":0}'
exit 0
"#;

type Collected = Arc<Mutex<Vec<RunnerMsg>>>;

fn collecting_sink() -> (Collected, Sink) {
    let collected: Collected = Arc::new(Mutex::new(Vec::new()));
    let store = Arc::clone(&collected);
    let sink: Sink = Arc::new(move |_tk: &mut Tk, msg: RunnerMsg| {
        if let Ok(mut items) = store.lock() {
            items.push(msg);
        }
    });
    (collected, sink)
}

fn wait_until(tk: &mut Tk, collected: &Collected, secs: u64, pred: impl Fn(&RunnerMsg) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(secs);
    loop {
        tk.process_posted();
        let snapshot = collected.lock().expect("lock").clone();
        if snapshot.iter().any(&pred) {
            return;
        }
        assert!(Instant::now() < deadline, "timed out: {snapshot:?}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn sh(script: &str) -> CommandSpec {
    CommandSpec {
        program: "/bin/sh".into(),
        args: vec!["-c".into(), script.into()],
    }
}

#[test]
fn cancel_kills_the_tree_and_finishes_promptly() {
    let mut tk = Tk::new();
    let (collected, sink) = collecting_sink();
    // The background sleep inherits stdout/stderr and outlives the shell.
    let spec = sh("echo started; sleep 30 & wait");
    let runner = Runner::spawn(&spec, tk.proxy(), sink).expect("spawn sh");
    wait_until(&mut tk, &collected, 20, |m| {
        matches!(m, RunnerMsg::Line(Line::Text(t)) if t == "started")
    });
    runner.cancel();
    runner.cancel();
    wait_until(&mut tk, &collected, 20, |m| matches!(m, RunnerMsg::Exited(_)));
    assert!(runner.is_finished());
    // Cancel and prompt answers after the end are harmless.
    runner.cancel();
    runner.answer(true);
    runner.answer(false);
    runner.join();
}

#[test]
fn exit_is_reported_even_if_a_grandchild_keeps_the_pipes_open() {
    let mut tk = Tk::new();
    let (collected, sink) = collecting_sink();
    let spec = sh("echo done; sleep 20 & exit 0");
    let runner = Runner::spawn(&spec, tk.proxy(), sink).expect("spawn sh");
    wait_until(&mut tk, &collected, 12, |m| matches!(m, RunnerMsg::Exited(_)));
    assert!(runner.is_finished());
    let all = collected.lock().expect("lock").clone();
    assert_eq!(all.last(), Some(&RunnerMsg::Exited(Some(0))));
    assert!(all.contains(&RunnerMsg::Line(Line::Text("done".into()))));
    runner.join();
}

#[test]
fn cancel_writes_a_cancel_line_so_the_child_can_restore() {
    let mut tk = Tk::new();
    let (collected, sink) = collecting_sink();
    // The child waits for a stdin line; "cancel" makes it print and exit 0.
    let spec = sh("read line; echo got=$line; if [ \"$line\" = cancel ]; then exit 0; else sleep 30; fi");
    let runner = Runner::spawn(&spec, tk.proxy(), sink).expect("spawn sh");
    std::thread::sleep(Duration::from_millis(100));
    runner.cancel();
    wait_until(&mut tk, &collected, 8, |m| matches!(m, RunnerMsg::Exited(_)));
    assert!(runner.is_finished());
    let all = collected.lock().expect("lock").clone();
    assert_eq!(all.last(), Some(&RunnerMsg::Exited(Some(0))));
    assert!(all.iter().any(|m| matches!(m, RunnerMsg::Line(Line::Text(t)) if t == "got=cancel")));
    runner.join();
}

#[test]
fn spawn_failure_is_an_error_not_a_panic() {
    let tk = Tk::new();
    let (_collected, sink) = collecting_sink();
    let spec = CommandSpec {
        program: "/nonexistent/rcb-gui-no-such-shell".into(),
        args: vec!["-File".into(), "build.ps1".into()],
    };
    assert!(Runner::spawn(&spec, tk.proxy(), sink).is_err());
}

#[test]
fn delivers_events_in_order_and_answers_prompt() {
    let dir = std::env::temp_dir().join(format!("rcb-gui-runner-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("temp dir");
    let script = dir.join("fake pwsh.sh");
    std::fs::write(&script, SCRIPT).expect("write script");
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).expect("chmod");

    // This is the only test in this binary, so mutating the environment is safe.
    std::env::set_var("RCB_PWSH", &script);
    let request = BuildRequest {
        script: PathBuf::from("build.ps1"),
        path: dir.clone(),
        profile: Profile::Release,
        test: false,
        rtk_update: true,
        sign: false,
        cert_thumbprint: None,
        pfx_path: None,
        timestamp_url: None,
        sign_config: None,
    };
    let spec = runner::build_command_for_host(&request);
    assert_eq!(spec.program, script.clone().into_os_string());

    let mut tk = Tk::new();
    let collected: Arc<Mutex<Vec<RunnerMsg>>> = Arc::new(Mutex::new(Vec::new()));
    let sink_store = Arc::clone(&collected);
    let sink: Sink = Arc::new(move |_tk: &mut Tk, msg: RunnerMsg| {
        if let Ok(mut items) = sink_store.lock() {
            items.push(msg);
        }
    });

    let mut spawned = None;
    for _ in 0..5 {
        match Runner::spawn(&spec, tk.proxy(), Arc::clone(&sink)) {
            Ok(runner) => {
                spawned = Some(runner);
                break;
            }
            Err(_) => std::thread::sleep(Duration::from_millis(50)),
        }
    }
    let runner = spawned.expect("spawn fake shell");

    let deadline = Instant::now() + Duration::from_secs(30);
    let mut answered = false;
    loop {
        tk.process_posted();
        let snapshot = collected.lock().expect("lock").clone();
        if !answered
            && snapshot
                .iter()
                .any(|m| matches!(m, RunnerMsg::Line(Line::Event(Event::Prompt { .. }))))
        {
            runner.answer(true);
            answered = true;
        }
        if snapshot.iter().any(|m| matches!(m, RunnerMsg::Exited(_))) {
            break;
        }
        assert!(Instant::now() < deadline, "runner timed out: {snapshot:?}");
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(runner.is_finished());
    runner.join();

    let all = collected.lock().expect("lock").clone();
    assert_eq!(all.last(), Some(&RunnerMsg::Exited(Some(0))));
    assert!(all.contains(&RunnerMsg::Stderr("warn on stderr".into())));

    let stdout: Vec<&Line> = all
        .iter()
        .filter_map(|m| match m {
            RunnerMsg::Line(line) => Some(line),
            _ => None,
        })
        .collect();
    assert_eq!(stdout.len(), 5, "{stdout:?}");
    assert!(matches!(stdout[0], Line::Event(Event::Start { .. })));
    assert_eq!(stdout[1], &Line::Text("plain line".into()));
    assert_eq!(
        stdout[2],
        &Line::Event(Event::Prompt {
            id: "p1".into(),
            question: "Continue?".into()
        })
    );
    assert_eq!(
        stdout[3],
        &Line::Event(Event::Log {
            text: "answer=yes".into(),
            role: Role::Info
        })
    );
    assert!(matches!(
        stdout[4],
        Line::Event(Event::Summary { success: true, .. })
    ));

    let _ = std::fs::remove_dir_all(&dir);
}
