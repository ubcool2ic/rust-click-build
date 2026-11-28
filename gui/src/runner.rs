//! Child process handling: command building, IO threads, prompts, cancel.

use std::ffi::OsString;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use rtk::{Tk, TkProxy};

use crate::protocol::{parse_line, Line};

/// `CREATE_NO_WINDOW` process creation flag.
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// Longest piece of output (in bytes) delivered as one line; longer lines
/// are split so a child that never prints a newline cannot exhaust memory.
const MAX_LINE_BYTES: usize = 256 * 1024;

/// How long the output readers may keep draining after the child itself has
/// exited. A grandchild that inherited the pipes can hold them open forever.
const READER_GRACE: Duration = Duration::from_secs(3);

/// How long cancel/close waits for build.ps1 to honor a `cancel` stdin line
/// (and restore any rtk pin it just bumped) before the process tree is killed.
const CANCEL_GRACE: Duration = Duration::from_secs(12);

/// Cargo build profile.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Profile {
    /// Optimised build.
    Release,
    /// Debug build.
    Debug,
}

impl Profile {
    /// Parses `release` / `debug` (case-insensitive).
    pub fn parse(raw: &str) -> Option<Self> {
        match raw.to_ascii_lowercase().as_str() {
            "release" => Some(Profile::Release),
            "debug" => Some(Profile::Debug),
            _ => None,
        }
    }

    /// The value passed to `-BuildProfile`.
    pub fn as_str(self) -> &'static str {
        match self {
            Profile::Release => "release",
            Profile::Debug => "debug",
        }
    }
}

/// Which shell conventions to use.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShellKind {
    /// `powershell.exe` with an execution-policy bypass.
    Windows,
    /// `pwsh`.
    Unix,
}

/// What to build.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BuildRequest {
    /// Path to `build.ps1`.
    pub script: PathBuf,
    /// Folder containing Cargo projects.
    pub path: PathBuf,
    /// Build profile.
    pub profile: Profile,
    /// Run tests.
    pub test: bool,
    /// Check for rtk updates first.
    pub rtk_update: bool,
    /// Authenticode-sign collected artifacts.
    pub sign: bool,
    /// Certificate thumbprint (CurrentUser or LocalMachine My store).
    pub cert_thumbprint: Option<String>,
    /// PFX path. The password is read by build.ps1 from RCB_SIGN_PFX_PASSWORD.
    pub pfx_path: Option<PathBuf>,
    /// RFC 3161 timestamp URL override.
    pub timestamp_url: Option<String>,
    /// Optional rcb.sign.json path.
    pub sign_config: Option<PathBuf>,
}

/// A program plus its argument vector (never a single joined string).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CommandSpec {
    /// Executable to start.
    pub program: OsString,
    /// Arguments, one element per argument.
    pub args: Vec<OsString>,
}

/// Builds the argument vector for `build.ps1`.
pub fn build_args(req: &BuildRequest, kind: ShellKind) -> Vec<OsString> {
    let mut args: Vec<OsString> = vec!["-NoProfile".into()];
    if kind == ShellKind::Windows {
        args.push("-ExecutionPolicy".into());
        args.push("Bypass".into());
    }
    args.push("-File".into());
    args.push(req.script.clone().into_os_string());
    args.push("-Path".into());
    args.push(req.path.clone().into_os_string());
    args.push("-BuildProfile".into());
    args.push(req.profile.as_str().into());
    if req.test {
        args.push("-Test".into());
    }
    if !req.rtk_update {
        args.push("-NoRtkUpdate".into());
    }
    if req.sign {
        args.push("-Sign".into());
    }
    if let Some(thumb) = req.cert_thumbprint.as_ref().filter(|s| !s.is_empty()) {
        args.push("-CertThumbprint".into());
        args.push(thumb.clone().into());
    }
    if let Some(pfx) = req.pfx_path.as_ref() {
        args.push("-PfxPath".into());
        args.push(pfx.clone().into_os_string());
    }
    if let Some(url) = req.timestamp_url.as_ref().filter(|s| !s.is_empty()) {
        args.push("-TimestampUrl".into());
        args.push(url.clone().into());
    }
    if let Some(cfg) = req.sign_config.as_ref() {
        args.push("-SignConfig".into());
        args.push(cfg.clone().into_os_string());
    }
    args.push("-NoOpen".into());
    args.push("-JsonProgress".into());
    args
}

/// Builds the full command; `shell_override` replaces the default shell.
pub fn build_command(
    req: &BuildRequest,
    kind: ShellKind,
    shell_override: Option<OsString>,
) -> CommandSpec {
    let program = shell_override.unwrap_or_else(|| match kind {
        ShellKind::Windows => "powershell.exe".into(),
        ShellKind::Unix => "pwsh".into(),
    });
    CommandSpec {
        program,
        args: build_args(req, kind),
    }
}

/// Builds the command for the current OS, honouring `RCB_PWSH`.
pub fn build_command_for_host(req: &BuildRequest) -> CommandSpec {
    let kind = if cfg!(windows) {
        ShellKind::Windows
    } else {
        ShellKind::Unix
    };
    let shell = std::env::var_os("RCB_PWSH").filter(|v| !v.is_empty());
    build_command(req, kind, shell)
}

/// The Windows command that kills a whole process tree.
pub fn kill_tree_command(pid: u32) -> CommandSpec {
    CommandSpec {
        program: "taskkill".into(),
        args: vec![
            "/T".into(),
            "/F".into(),
            "/PID".into(),
            pid.to_string().into(),
        ],
    }
}

/// A message delivered to the UI thread.
#[derive(Clone, Debug, PartialEq)]
pub enum RunnerMsg {
    /// A parsed stdout line.
    Line(Line),
    /// A raw stderr line.
    Stderr(String),
    /// The child exited (after all output was delivered).
    Exited(Option<i32>),
}

/// Callback invoked on the UI thread for every [`RunnerMsg`].
pub type Sink = Arc<dyn Fn(&mut Tk, RunnerMsg) + Send + Sync>;

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn post(proxy: &TkProxy, sink: &Sink, msg: RunnerMsg) {
    let sink = Arc::clone(sink);
    proxy.post(move |tk| sink(tk, msg));
}

/// Reads `reader` line by line (lossy UTF-8) until EOF or an error.
fn pump<R: Read>(reader: R, mut on_line: impl FnMut(String)) {
    let mut reader = BufReader::new(reader);
    let mut buf = Vec::new();
    loop {
        buf.clear();
        match reader
            .by_ref()
            .take(MAX_LINE_BYTES as u64)
            .read_until(b'\n', &mut buf)
        {
            Ok(0) | Err(_) => break,
            Ok(_) => {
                let text = String::from_utf8_lossy(&buf);
                on_line(text.trim_end_matches(['\r', '\n']).to_string());
            }
        }
    }
}

/// Kills the child's process tree. With `wait` the kill has completed when
/// this returns (used on drop, where the process may exit right afterwards);
/// otherwise it runs in the background so the UI thread is not blocked.
#[cfg(windows)]
fn kill_tree(pid: u32, child: &Arc<Mutex<Child>>, wait: bool) {
    use std::os::windows::process::CommandExt;
    let spec = kill_tree_command(pid);
    let child = Arc::clone(child);
    let kill = move || {
        let ok = Command::new(&spec.program)
            .args(&spec.args)
            .creation_flags(CREATE_NO_WINDOW)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|status| status.success())
            .unwrap_or(false);
        if !ok {
            let _ = lock(&child).kill();
        }
    };
    if wait {
        kill();
    } else {
        thread::spawn(kill);
    }
}

/// Kills the child and, on Unix, the process group it leads (the child is
/// started in its own group), so grandchildren such as cargo die as well.
#[cfg(not(windows))]
fn kill_tree(pid: u32, child: &Arc<Mutex<Child>>, wait: bool) {
    let _ = lock(child).kill();
    #[cfg(unix)]
    {
        let group = move || {
            let _ = Command::new("kill")
                .arg("-KILL")
                .arg("--")
                .arg(format!("-{pid}"))
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        };
        if wait {
            group();
        } else {
            thread::spawn(group);
        }
    }
    #[cfg(not(unix))]
    let _ = (pid, wait);
}

/// A running `build.ps1` child with its IO threads.
pub struct Runner {
    pid: u32,
    child: Arc<Mutex<Child>>,
    stdin: Arc<Mutex<Option<ChildStdin>>>,
    done: Arc<AtomicBool>,
    /// Set once nothing more may be posted to the UI thread.
    quiet: Arc<AtomicBool>,
    waiter: Option<JoinHandle<()>>,
}

impl Runner {
    /// Spawns the child and its reader threads. Every output line and the
    /// final exit are delivered to `sink` on the UI thread through `proxy`.
    pub fn spawn(spec: &CommandSpec, proxy: TkProxy, sink: Sink) -> io::Result<Runner> {
        let mut cmd = Command::new(&spec.program);
        cmd.args(&spec.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            cmd.creation_flags(CREATE_NO_WINDOW);
        }
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            // Own process group, so cancel can kill the whole tree.
            cmd.process_group(0);
        }
        let mut child = cmd.spawn()?;
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();
        let stdin = child.stdin.take();
        let pid = child.id();
        let child = Arc::new(Mutex::new(child));
        let done = Arc::new(AtomicBool::new(false));
        let quiet = Arc::new(AtomicBool::new(false));

        let out_thread = stdout.map(|stream| {
            let (p, k, q) = (proxy.clone(), Arc::clone(&sink), Arc::clone(&quiet));
            thread::spawn(move || {
                pump(stream, |line| {
                    if !q.load(Ordering::SeqCst) {
                        post(&p, &k, RunnerMsg::Line(parse_line(&line)));
                    }
                });
            })
        });
        let err_thread = stderr.map(|stream| {
            let (p, k, q) = (proxy.clone(), Arc::clone(&sink), Arc::clone(&quiet));
            thread::spawn(move || {
                pump(stream, |line| {
                    if !q.load(Ordering::SeqCst) {
                        post(&p, &k, RunnerMsg::Stderr(line));
                    }
                });
            })
        });

        let child_w = Arc::clone(&child);
        let done_w = Arc::clone(&done);
        let quiet_w = Arc::clone(&quiet);
        let waiter = thread::spawn(move || {
            // Reap the child first: the readers may never see EOF when a
            // grandchild inherited the pipes and outlives the child.
            let code = loop {
                let polled = lock(&child_w).try_wait();
                match polled {
                    Ok(Some(status)) => break status.code(),
                    Ok(None) => thread::sleep(Duration::from_millis(20)),
                    Err(_) => break None,
                }
            };
            let readers: Vec<JoinHandle<()>> =
                [out_thread, err_thread].into_iter().flatten().collect();
            let deadline = Instant::now() + READER_GRACE;
            while Instant::now() < deadline && !readers.iter().all(|h| h.is_finished()) {
                thread::sleep(Duration::from_millis(5));
            }
            // Readers that are still blocked are detached and muted.
            let dropped = quiet_w.swap(true, Ordering::SeqCst);
            for handle in readers {
                if handle.is_finished() {
                    let _ = handle.join();
                }
            }
            done_w.store(true, Ordering::SeqCst);
            if !dropped {
                post(&proxy, &sink, RunnerMsg::Exited(code));
            }
        });

        Ok(Runner {
            pid,
            child,
            stdin: Arc::new(Mutex::new(stdin)),
            done,
            quiet,
            waiter: Some(waiter),
        })
    }

    /// Process id of the child.
    pub fn pid(&self) -> u32 {
        self.pid
    }

    /// Whether the child has exited and all output was delivered.
    pub fn is_finished(&self) -> bool {
        self.done.load(Ordering::SeqCst)
    }

    /// Answers a prompt by writing `yes` or `no` to the child's stdin.
    /// Broken pipes are ignored.
    pub fn answer(&self, yes: bool) {
        let mut guard = lock(&self.stdin);
        if let Some(stdin) = guard.as_mut() {
            let text: &[u8] = if yes { b"yes\n" } else { b"no\n" };
            let ok = stdin.write_all(text).and_then(|()| stdin.flush()).is_ok();
            if !ok {
                *guard = None;
            }
        }
    }

    /// Asks the child to stop. Writes `cancel\n` on stdin so build.ps1 can
    /// restore an in-flight rtk bump, then hard-kills the tree if it has not
    /// exited after [`CANCEL_GRACE`]. Safe to call repeatedly.
    pub fn cancel(&self) {
        self.request_stop(CANCEL_GRACE);
    }

    fn request_stop(&self, grace: Duration) {
        if self.is_finished() {
            return;
        }
        {
            let mut guard = lock(&self.stdin);
            if let Some(stdin) = guard.as_mut() {
                let _ = stdin
                    .write_all(b"cancel\n")
                    .and_then(|()| stdin.flush());
            }
        }
        let deadline = Instant::now() + grace;
        while Instant::now() < deadline && !self.is_finished() {
            thread::sleep(Duration::from_millis(20));
        }
        if self.is_finished() {
            return;
        }
        *lock(&self.stdin) = None;
        kill_tree(self.pid, &self.child, false);
    }

    /// Waits for the bookkeeping thread. Call after [`RunnerMsg::Exited`].
    pub fn join(mut self) {
        if let Some(handle) = self.waiter.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for Runner {
    fn drop(&mut self) {
        // The owner is gone: nothing may be posted to the UI thread any more.
        self.quiet.store(true, Ordering::SeqCst);
        if self.is_finished() {
            return;
        }
        self.request_stop(CANCEL_GRACE);
        if !self.is_finished() {
            *lock(&self.stdin) = None;
            // Synchronous: the process may exit right after this drop, which
            // would abandon a background kill before it ran.
            kill_tree(self.pid, &self.child, true);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req(path: &str) -> BuildRequest {
        BuildRequest {
            script: PathBuf::from("C:\\Tools\\rust click build\\build.ps1"),
            path: PathBuf::from(path),
            profile: Profile::Release,
            test: true,
            rtk_update: false,
            sign: false,
            cert_thumbprint: None,
            pfx_path: None,
            timestamp_url: None,
            sign_config: None,
        }
    }

    fn strs(args: &[OsString]) -> Vec<String> {
        args.iter()
            .map(|a| a.to_string_lossy().into_owned())
            .collect()
    }

    #[test]
    fn windows_command() {
        let path = "D:\\Мои проекты\\büild täst";
        let spec = build_command(&req(path), ShellKind::Windows, None);
        assert_eq!(spec.program, OsString::from("powershell.exe"));
        assert_eq!(
            strs(&spec.args),
            vec![
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                "C:\\Tools\\rust click build\\build.ps1",
                "-Path",
                path,
                "-BuildProfile",
                "release",
                "-Test",
                "-NoRtkUpdate",
                "-NoOpen",
                "-JsonProgress",
            ]
        );
    }

    #[test]
    fn unix_command() {
        let mut request = req("/home/dev/my projects/üñï");
        request.test = false;
        request.rtk_update = true;
        request.profile = Profile::Debug;
        let spec = build_command(&request, ShellKind::Unix, None);
        assert_eq!(spec.program, OsString::from("pwsh"));
        assert_eq!(
            strs(&spec.args),
            vec![
                "-NoProfile",
                "-File",
                "C:\\Tools\\rust click build\\build.ps1",
                "-Path",
                "/home/dev/my projects/üñï",
                "-BuildProfile",
                "debug",
                "-NoOpen",
                "-JsonProgress",
            ]
        );
    }

    #[test]
    fn sign_flags_are_forwarded() {
        let mut request = req("/tmp/src");
        request.sign = true;
        request.cert_thumbprint = Some("DEADBEEF".into());
        request.pfx_path = Some(PathBuf::from("/tmp/dev.pfx"));
        request.timestamp_url = Some("http://timestamp.example".into());
        request.sign_config = Some(PathBuf::from("/tmp/rcb.sign.json"));
        let spec = build_command(&request, ShellKind::Unix, None);
        let got = strs(&spec.args);
        assert!(got.contains(&"-Sign".into()));
        assert!(got.contains(&"-CertThumbprint".into()));
        assert!(got.contains(&"DEADBEEF".into()));
        assert!(got.contains(&"-PfxPath".into()));
        assert!(got.contains(&"/tmp/dev.pfx".into()));
        assert!(got.contains(&"-TimestampUrl".into()));
        assert!(got.contains(&"http://timestamp.example".into()));
        assert!(got.contains(&"-SignConfig".into()));
        assert!(got.contains(&"/tmp/rcb.sign.json".into()));
        assert!(!got.iter().any(|a| a.contains("RCB_SIGN_PFX_PASSWORD") || a.contains("pass")));
    }

    #[test]
    fn shell_override_and_kill_command() {
        let spec = build_command(&req("x"), ShellKind::Unix, Some("/opt/my pwsh/pwsh".into()));
        assert_eq!(spec.program, OsString::from("/opt/my pwsh/pwsh"));
        let kill = kill_tree_command(4242);
        assert_eq!(strs(&kill.args), vec!["/T", "/F", "/PID", "4242"]);
    }

    #[test]
    fn profile_parsing() {
        assert_eq!(Profile::parse("Release"), Some(Profile::Release));
        assert_eq!(Profile::parse("DEBUG"), Some(Profile::Debug));
        assert_eq!(Profile::parse("fast"), None);
    }

    #[test]
    fn pump_splits_overlong_lines() {
        let data = vec![b'a'; MAX_LINE_BYTES * 2 + 10];
        let mut lens = Vec::new();
        pump(data.as_slice(), |line| lens.push(line.len()));
        assert_eq!(lens, vec![MAX_LINE_BYTES, MAX_LINE_BYTES, 10]);
    }

    #[test]
    fn pump_handles_invalid_utf8_and_crlf() {
        let data: &[u8] = b"one\r\ntw\xffo\nlast";
        let mut lines = Vec::new();
        pump(data, |line| lines.push(line));
        assert_eq!(lines.len(), 3);
        assert_eq!(lines[0], "one");
        assert!(lines[1].starts_with("tw"));
        assert_eq!(lines[2], "last");
    }
}
