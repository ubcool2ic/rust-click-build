//! The `@@RCB` line protocol spoken by `build.ps1 -JsonProgress`.

use serde_json::Value;

/// Prefix marking a machine-readable stdout line.
pub const PREFIX: &str = "@@RCB";

/// Visual role of a log line.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Role {
    /// Plain text.
    Text,
    /// De-emphasised text.
    Muted,
    /// Section heading (bold).
    Heading,
    /// Accent-coloured text.
    Accent,
    /// Informational.
    Info,
    /// Success.
    Success,
    /// Warning.
    Warning,
    /// Error.
    Danger,
    /// An rtk version change.
    RtkChange,
}

impl Role {
    /// Parses a role name; unknown names fall back to [`Role::Text`].
    pub fn parse(name: &str) -> Self {
        match name.to_ascii_lowercase().as_str() {
            "muted" => Role::Muted,
            "heading" => Role::Heading,
            "accent" => Role::Accent,
            "info" => Role::Info,
            "success" => Role::Success,
            "warning" => Role::Warning,
            "danger" => Role::Danger,
            "rtkchange" => Role::RtkChange,
            _ => Role::Text,
        }
    }
}

/// A protocol event.
#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    /// The script started.
    Start {
        /// Protocol version.
        version: u64,
        /// Folder being built.
        path: String,
        /// `release` or `debug`.
        profile: String,
        /// Tests enabled.
        test: bool,
        /// rtk update check enabled.
        rtk_update: bool,
        /// Log file path.
        log_file: String,
    },
    /// A log line.
    Log {
        /// Line text.
        text: String,
        /// Visual role.
        role: Role,
    },
    /// Projects were discovered.
    Discovered {
        /// Number of projects.
        count: u64,
        /// Project names.
        projects: Vec<String>,
    },
    /// A project started (1-based index).
    ProjectStart {
        /// 1-based index.
        index: u64,
        /// Total number of projects.
        total: u64,
        /// Project name.
        name: String,
        /// Project directory.
        dir: String,
    },
    /// A project entered a phase.
    Phase {
        /// 1-based index.
        index: u64,
        /// Project name.
        name: String,
        /// `rtk`, `build`, `test` or `collect`.
        phase: String,
    },
    /// rtk dependency status for a project.
    Rtk {
        /// 1-based index.
        index: u64,
        /// Project name.
        name: String,
        /// Status text.
        status: String,
        /// Whether the dependency was changed.
        changed: bool,
    },
    /// A project finished.
    ProjectEnd {
        /// 1-based index.
        index: u64,
        /// Project name.
        name: String,
        /// `PASS` or `FAIL`.
        build: String,
        /// `PASS`, `FAIL` or `N/A`.
        test: String,
        /// Number of collected artifacts.
        artifacts: u64,
        /// Duration in seconds.
        seconds: f64,
        /// rtk status text.
        rtk: String,
        /// Error lines.
        errors: Vec<String>,
        /// Hint lines.
        hints: Vec<String>,
    },
    /// The script asks a yes/no question.
    Prompt {
        /// Prompt identifier.
        id: String,
        /// Question text.
        question: String,
    },
    /// Final summary.
    Summary {
        /// Everything passed.
        success: bool,
        /// The run was cancelled.
        cancelled: bool,
        /// Script exit code.
        exit_code: i32,
        /// Output folder.
        built_dir: String,
        /// Log file path.
        log_file: String,
        /// Passed projects.
        passed: u64,
        /// Failed projects.
        failed: u64,
    },
    /// A fatal error.
    Fatal {
        /// Error message.
        message: String,
    },
}

/// Classification of one output line.
#[derive(Clone, Debug, PartialEq)]
pub enum Line {
    /// A recognised event.
    Event(Event),
    /// A well-formed event of an unknown kind (ignored).
    Unknown(String),
    /// A prefixed line whose JSON could not be used (shown muted).
    Malformed(String),
    /// A non-protocol line (shown muted).
    Text(String),
}

fn s(v: &Value, key: &str) -> String {
    v.get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn b(v: &Value, key: &str) -> bool {
    v.get(key).and_then(Value::as_bool).unwrap_or(false)
}

fn f(v: &Value, key: &str) -> f64 {
    v.get(key)
        .and_then(Value::as_f64)
        .filter(|x| x.is_finite())
        .unwrap_or(0.0)
}

fn n(v: &Value, key: &str) -> u64 {
    match v.get(key) {
        Some(x) => x.as_u64().unwrap_or_else(|| {
            let fl = x.as_f64().unwrap_or(0.0);
            if fl.is_finite() && fl > 0.0 {
                fl as u64
            } else {
                0
            }
        }),
        None => 0,
    }
}

fn list(v: &Value, key: &str) -> Vec<String> {
    v.get(key)
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

/// Parses one line of child output. Never panics.
pub fn parse_line(raw: &str) -> Line {
    let line = raw
        .trim_end_matches(['\r', '\n'])
        .trim_start_matches('\u{feff}');
    let Some(rest) = line.trim_start().strip_prefix(PREFIX) else {
        return Line::Text(line.to_string());
    };
    let value: Value = match serde_json::from_str(rest.trim()) {
        Ok(value) => value,
        Err(_) => return Line::Malformed(line.to_string()),
    };
    if !value.is_object() {
        return Line::Malformed(line.to_string());
    }
    let Some(kind) = value.get("event").and_then(Value::as_str) else {
        return Line::Malformed(line.to_string());
    };
    let v = &value;
    let event = match kind {
        "start" => Event::Start {
            version: n(v, "version"),
            path: s(v, "path"),
            profile: s(v, "profile"),
            test: b(v, "test"),
            rtk_update: b(v, "rtk_update"),
            log_file: s(v, "log_file"),
        },
        "log" => Event::Log {
            text: s(v, "text"),
            role: Role::parse(&s(v, "role")),
        },
        "discovered" => Event::Discovered {
            count: n(v, "count"),
            projects: list(v, "projects"),
        },
        "project_start" => Event::ProjectStart {
            index: n(v, "index"),
            total: n(v, "total"),
            name: s(v, "name"),
            dir: s(v, "dir"),
        },
        "phase" => Event::Phase {
            index: n(v, "index"),
            name: s(v, "name"),
            phase: s(v, "phase"),
        },
        "rtk" => Event::Rtk {
            index: n(v, "index"),
            name: s(v, "name"),
            status: s(v, "status"),
            changed: b(v, "changed"),
        },
        "project_end" => Event::ProjectEnd {
            index: n(v, "index"),
            name: s(v, "name"),
            build: s(v, "build"),
            test: s(v, "test"),
            artifacts: n(v, "artifacts"),
            seconds: f(v, "seconds"),
            rtk: s(v, "rtk"),
            errors: list(v, "errors"),
            hints: list(v, "hints"),
        },
        "prompt" => Event::Prompt {
            id: s(v, "id"),
            question: s(v, "question"),
        },
        "summary" => Event::Summary {
            success: b(v, "success"),
            cancelled: b(v, "cancelled"),
            exit_code: v
                .get("exit_code")
                .and_then(Value::as_i64)
                .and_then(|c| i32::try_from(c).ok())
                .unwrap_or(0),
            built_dir: s(v, "built_dir"),
            log_file: s(v, "log_file"),
            passed: n(v, "passed"),
            failed: n(v, "failed"),
        },
        "fatal" => Event::Fatal {
            message: s(v, "message"),
        },
        other => return Line::Unknown(other.to_string()),
    };
    Line::Event(event)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(json: &str) -> Event {
        match parse_line(&format!("@@RCB {json}")) {
            Line::Event(event) => event,
            other => panic!("expected event, got {other:?}"),
        }
    }

    #[test]
    fn parses_every_event() {
        assert_eq!(
            ev(
                r#"{"event":"start","version":1,"path":"C:\\x y","profile":"release","test":true,"rtk_update":false,"log_file":"l.txt"}"#
            ),
            Event::Start {
                version: 1,
                path: "C:\\x y".into(),
                profile: "release".into(),
                test: true,
                rtk_update: false,
                log_file: "l.txt".into()
            }
        );
        assert_eq!(
            ev(r#"{"event":"log","text":"hi","role":"rtkchange"}"#),
            Event::Log {
                text: "hi".into(),
                role: Role::RtkChange
            }
        );
        assert_eq!(
            ev(r#"{"event":"discovered","count":2,"projects":["a","b"]}"#),
            Event::Discovered {
                count: 2,
                projects: vec!["a".into(), "b".into()]
            }
        );
        assert_eq!(
            ev(r#"{"event":"project_start","index":1,"total":2,"name":"a","dir":"d"}"#),
            Event::ProjectStart {
                index: 1,
                total: 2,
                name: "a".into(),
                dir: "d".into()
            }
        );
        assert_eq!(
            ev(r#"{"event":"phase","index":1,"name":"a","phase":"build"}"#),
            Event::Phase {
                index: 1,
                name: "a".into(),
                phase: "build".into()
            }
        );
        assert_eq!(
            ev(r#"{"event":"rtk","index":1,"name":"a","status":"v1","changed":true}"#),
            Event::Rtk {
                index: 1,
                name: "a".into(),
                status: "v1".into(),
                changed: true
            }
        );
        assert_eq!(
            ev(
                r#"{"event":"project_end","index":1,"name":"a","build":"FAIL","test":"N/A","artifacts":0,"seconds":1.5,"rtk":"v1","errors":["e"],"hints":["h"]}"#
            ),
            Event::ProjectEnd {
                index: 1,
                name: "a".into(),
                build: "FAIL".into(),
                test: "N/A".into(),
                artifacts: 0,
                seconds: 1.5,
                rtk: "v1".into(),
                errors: vec!["e".into()],
                hints: vec!["h".into()]
            }
        );
        assert_eq!(
            ev(r#"{"event":"prompt","id":"p","question":"ok?"}"#),
            Event::Prompt {
                id: "p".into(),
                question: "ok?".into()
            }
        );
        assert_eq!(
            ev(
                r#"{"event":"summary","success":false,"cancelled":true,"exit_code":2,"built_dir":"b","log_file":"l","passed":1,"failed":2}"#
            ),
            Event::Summary {
                success: false,
                cancelled: true,
                exit_code: 2,
                built_dir: "b".into(),
                log_file: "l".into(),
                passed: 1,
                failed: 2
            }
        );
        assert_eq!(
            ev(r#"{"event":"fatal","message":"boom"}"#),
            Event::Fatal {
                message: "boom".into()
            }
        );
    }

    #[test]
    fn unknown_events_and_fields_are_tolerated() {
        assert_eq!(
            parse_line(r#"@@RCB {"event":"telemetry","x":1}"#),
            Line::Unknown("telemetry".into())
        );
        assert_eq!(
            ev(r#"{"event":"fatal","message":"m","future":{"a":[1,2]}}"#),
            Event::Fatal {
                message: "m".into()
            }
        );
        // Wrong types and missing fields degrade to defaults.
        assert_eq!(
            ev(r#"{"event":"log","text":5}"#),
            Event::Log {
                text: String::new(),
                role: Role::Text
            }
        );
    }

    #[test]
    fn malformed_json_is_reported_not_panicked() {
        for raw in [
            "@@RCB {not json",
            "@@RCB",
            "@@RCB [1,2]",
            "@@RCB {\"no_event\":1}",
        ] {
            assert!(matches!(parse_line(raw), Line::Malformed(_)), "{raw}");
        }
    }

    #[test]
    fn plain_lines_are_text() {
        assert_eq!(
            parse_line("   Compiling foo v0.1.0\r\n"),
            Line::Text("   Compiling foo v0.1.0".into())
        );
        assert_eq!(parse_line(""), Line::Text(String::new()));
        assert!(matches!(
            parse_line("\u{feff}@@RCB {\"event\":\"fatal\",\"message\":\"x\"}"),
            Line::Event(Event::Fatal { .. })
        ));
    }
}
