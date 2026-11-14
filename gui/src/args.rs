//! Command-line parsing and `build.ps1` discovery.

use std::ffi::OsString;
use std::fmt;
use std::path::{Path, PathBuf};

use crate::runner::Profile;
use crate::theme::ThemeChoice;

/// Usage text printed for `--help` and on argument errors.
pub const USAGE: &str = "Usage: rcb-gui [options]
  --script <path>         Path to build.ps1 (default: RCB_BUILD_SCRIPT, else auto-detected)
  --path <folder>         Folder containing Cargo projects
  --profile <p>           release | debug
  --theme <t>             System | Light | Dark | HighContrast
  --test                  Run tests after building
  --no-rtk-update         Do not check for rtk updates before building
  --screenshot-dir <dir>  Render the screenshot set headlessly and exit
  --help                  Show this help";

/// Parsed command-line options.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Args {
    /// Explicit path to `build.ps1`.
    pub script: Option<PathBuf>,
    /// Folder to build.
    pub path: Option<PathBuf>,
    /// Build profile.
    pub profile: Option<Profile>,
    /// Theme selection.
    pub theme: Option<ThemeChoice>,
    /// Run tests.
    pub test: bool,
    /// Skip the rtk update check.
    pub no_rtk_update: bool,
    /// Headless screenshot output directory.
    pub screenshot_dir: Option<PathBuf>,
    /// `--help` was given.
    pub help: bool,
}

/// A command-line error with a human-readable message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArgsError(pub String);

impl fmt::Display for ArgsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ArgsError {}

/// Parses the arguments (without the program name).
pub fn parse<I, S>(args: I) -> Result<Args, ArgsError>
where
    I: IntoIterator<Item = S>,
    S: Into<OsString>,
{
    let mut out = Args::default();
    let mut it = args.into_iter().map(Into::into);
    while let Some(arg) = it.next() {
        let flag = arg.to_string_lossy().into_owned();
        match flag.as_str() {
            "--script" => out.script = Some(PathBuf::from(value(&mut it, &flag)?)),
            "--path" => out.path = Some(PathBuf::from(value(&mut it, &flag)?)),
            "--screenshot-dir" => {
                out.screenshot_dir = Some(PathBuf::from(value(&mut it, &flag)?));
            }
            "--profile" => {
                let raw = value(&mut it, &flag)?.to_string_lossy().into_owned();
                out.profile = Some(Profile::parse(&raw).ok_or_else(|| {
                    ArgsError(format!(
                        "invalid --profile '{raw}' (expected release or debug)"
                    ))
                })?);
            }
            "--theme" => {
                let raw = value(&mut it, &flag)?.to_string_lossy().into_owned();
                out.theme = Some(ThemeChoice::parse(&raw).ok_or_else(|| {
                    ArgsError(format!(
                        "invalid --theme '{raw}' (expected System, Light, Dark or HighContrast)"
                    ))
                })?);
            }
            "--test" => out.test = true,
            "--no-rtk-update" => out.no_rtk_update = true,
            "--help" | "-h" => out.help = true,
            other => return Err(ArgsError(format!("unknown argument '{other}'"))),
        }
    }
    Ok(out)
}

/// Fetches the value following `flag`.
fn value(it: &mut impl Iterator<Item = OsString>, flag: &str) -> Result<OsString, ArgsError> {
    it.next()
        .ok_or_else(|| ArgsError(format!("missing value for {flag}")))
}

/// Resolves the build script: explicit path, then `RCB_BUILD_SCRIPT`, then a
/// `build.ps1` that sits next to a `gui/` folder in any ancestor of the
/// executable's directory or the current directory.
pub fn find_script(explicit: Option<&Path>) -> Option<PathBuf> {
    if let Some(path) = explicit {
        return Some(path.to_path_buf());
    }
    if let Some(env) = std::env::var_os("RCB_BUILD_SCRIPT").filter(|v| !v.is_empty()) {
        return Some(PathBuf::from(env));
    }
    let mut starts: Vec<PathBuf> = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            starts.push(dir.to_path_buf());
        }
    }
    if let Ok(cwd) = std::env::current_dir() {
        starts.push(cwd);
    }
    starts.iter().find_map(|start| search_upward(start))
}

/// Walks the ancestors of `start` looking for `build.ps1` next to `gui/`.
pub fn search_upward(start: &Path) -> Option<PathBuf> {
    start.ancestors().find_map(|dir| {
        let script = dir.join("build.ps1");
        (script.is_file() && dir.join("gui").is_dir()).then_some(script)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_all_options() {
        let args = parse([
            "--script",
            "C:\\repo\\build.ps1",
            "--path",
            "D:\\My Projects",
            "--profile",
            "debug",
            "--theme",
            "HIGHCONTRAST",
            "--test",
            "--no-rtk-update",
            "--screenshot-dir",
            "out",
        ])
        .expect("valid args");
        assert_eq!(args.script, Some(PathBuf::from("C:\\repo\\build.ps1")));
        assert_eq!(args.path, Some(PathBuf::from("D:\\My Projects")));
        assert_eq!(args.profile, Some(Profile::Debug));
        assert_eq!(args.theme, Some(ThemeChoice::HighContrast));
        assert!(args.test);
        assert!(args.no_rtk_update);
        assert_eq!(args.screenshot_dir, Some(PathBuf::from("out")));
    }

    #[test]
    fn defaults_are_empty() {
        let args = parse(Vec::<String>::new()).expect("empty ok");
        assert_eq!(args, Args::default());
    }

    #[test]
    fn theme_is_case_insensitive() {
        for (raw, want) in [
            ("system", ThemeChoice::System),
            ("Light", ThemeChoice::Light),
            ("DARK", ThemeChoice::Dark),
            ("high-contrast", ThemeChoice::HighContrast),
        ] {
            let args = parse(["--theme", raw]).expect("theme");
            assert_eq!(args.theme, Some(want));
        }
    }

    #[test]
    fn rejects_bad_input() {
        assert!(parse(["--profile", "fast"]).is_err());
        assert!(parse(["--theme", "pink"]).is_err());
        assert!(parse(["--path"]).is_err());
        assert!(parse(["--wat"]).is_err());
    }

    #[test]
    fn search_upward_finds_script_next_to_gui() {
        let base = std::env::temp_dir().join(format!("rcb-gui-args-{}", std::process::id()));
        let nested = base.join("gui").join("target").join("debug");
        std::fs::create_dir_all(&nested).expect("mkdir");
        std::fs::write(base.join("build.ps1"), "# test").expect("write");
        assert_eq!(search_upward(&nested), Some(base.join("build.ps1")));
        let _ = std::fs::remove_dir_all(&base);
    }
}
