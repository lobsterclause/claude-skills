//! The harness the CLI tests share.
//!
//! `Env::new()` gives a test its own temporary folder holding a run folder
//! (`run`, so the run id is "run"), a folder that steers the stub gh, and the
//! stub's call log. `env.run(&[...])` runs the binary there. The clock is
//! pinned, so output can be compared with the files in tests/fixtures/run.
#![allow(dead_code)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::OnceLock;

use serde_json::Value;

pub const REPO: &str = "example/tidepool";
/// 2026-11-21T03:53:00Z, the `generated_at` of tests/fixtures/run/intake.json.
pub const NOW: &str = "1795233180";

pub fn manifest_dir() -> &'static Path {
    Path::new(env!("CARGO_MANIFEST_DIR"))
}

/// tests/fixtures: the reference run under `run/`, written by the bash
/// implementation this crate replaced.
pub fn fixtures() -> PathBuf {
    manifest_dir().join("tests/fixtures")
}

/// evals/fixtures: issues.json, verdicts.good.json, decisions.good.json and
/// the tidepool profile.
pub fn eval_fixtures() -> PathBuf {
    manifest_dir().join("evals/fixtures")
}

fn build_repo(dest: &Path) {
    let script = eval_fixtures().join("build-repo.sh");
    let built = Command::new("bash").arg(script).arg(dest).output().expect("bash runs");
    assert!(
        built.status.success(),
        "build-repo.sh failed: {}",
        String::from_utf8_lossy(&built.stderr)
    );
}

/// The tidepool fixture repo (branch `develop`, no remote), built once for
/// the whole test run. Read-only: a test that changes the repo builds its own
/// with `private_repo`.
pub fn fixture_repo() -> &'static Path {
    static REPO_DIR: OnceLock<PathBuf> = OnceLock::new();
    REPO_DIR.get_or_init(|| {
        let dest = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("tidepool-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dest);
        build_repo(&dest);
        dest
    })
}

/// A fresh copy of the fixture repo inside `dir`, for a test that commits to it.
pub fn private_repo(dir: &Path) -> PathBuf {
    let dest = dir.join("repo");
    build_repo(&dest);
    dest
}

/// `git -C <repo> <args>`, trimmed stdout. Panics if git fails.
pub fn git(repo: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(args)
        .output()
        .expect("git runs");
    assert!(
        out.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

pub struct Out {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}

impl From<Output> for Out {
    fn from(out: Output) -> Out {
        Out {
            code: out.status.code().unwrap_or(-1),
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        }
    }
}

pub struct Env {
    /// Removed when the test ends.
    pub dir: tempfile::TempDir,
    /// ISSUE_DRAIN_WORKDIR: `<dir>/run`. Not created until something writes to it.
    pub workdir: PathBuf,
    /// GH_STUB_DIR: files here steer the stub gh (see tests/stub/gh).
    pub stub: PathBuf,
    vars: Vec<(String, String)>,
}

impl Env {
    pub fn new() -> Env {
        let dir = tempfile::tempdir().expect("a temporary folder");
        let workdir = dir.path().join("run");
        let stub = dir.path().join("gh");
        fs::create_dir_all(&stub).expect("the stub folder");
        let mut env = Env {
            dir,
            workdir,
            stub,
            vars: Vec::new(),
        };
        let text = |p: &Path| p.display().to_string();
        env.set("ISSUE_DRAIN_WORKDIR", &text(&env.workdir));
        env.set("ISSUE_DRAIN_REPO", REPO);
        env.set("ISSUE_DRAIN_REPO_DIR", &text(fixture_repo()));
        env.set("ISSUE_DRAIN_PROFILE", &text(&eval_fixtures().join("tidepool.toml")));
        env.set("ISSUE_DRAIN_SKILL_DIR", &text(manifest_dir()));
        env.set("ISSUE_DRAIN_NOW", NOW);
        env.set("GH_STUB_DIR", &text(&env.stub));
        env.set("GH_STUB_LOG", &text(&env.dir.path().join("gh.log")));
        env
    }

    /// Set a variable for every later `run`. An empty value unsets it for the
    /// binary's purposes: every ISSUE_DRAIN_* setting treats empty as unset.
    pub fn set(&mut self, key: &str, value: &str) -> &mut Env {
        self.vars.retain(|(k, _)| k != key);
        self.vars.push((key.to_string(), value.to_string()));
        self
    }

    /// Run `issue-drain <args>` with the stub gh first on PATH.
    pub fn run(&self, args: &[&str]) -> Out {
        let stub_bin = manifest_dir().join("tests/stub");
        let path = format!("{}:{}", stub_bin.display(), std::env::var("PATH").unwrap_or_default());
        let mut command = Command::new(env!("CARGO_BIN_EXE_issue-drain"));
        for (key, _) in std::env::vars() {
            if key.starts_with("ISSUE_DRAIN_") || key.starts_with("GH_STUB_") {
                command.env_remove(key);
            }
        }
        command
            .args(args)
            .env("PATH", path)
            .envs(self.vars.iter().map(|(k, v)| (k, v)));
        command.output().expect("the binary runs").into()
    }

    /// Every call the stub gh received, one line of arguments each.
    pub fn gh_calls(&self) -> Vec<String> {
        let log = fs::read_to_string(self.dir.path().join("gh.log")).unwrap_or_default();
        log.lines().map(str::to_string).collect()
    }

    /// The run's events.jsonl, parsed. Empty when nothing was logged.
    pub fn events(&self) -> Vec<Value> {
        let log = fs::read_to_string(self.workdir.join("events.jsonl")).unwrap_or_default();
        log.lines()
            .map(|line| serde_json::from_str(line).expect("an event is one JSON object"))
            .collect()
    }

    /// The events with this name.
    pub fn events_named(&self, name: &str) -> Vec<Value> {
        self.events().into_iter().filter(|e| e["event"] == name).collect()
    }

    /// Write a file under the run folder, creating folders as needed.
    pub fn write(&self, name: &str, text: &str) -> PathBuf {
        let path = self.workdir.join(name);
        fs::create_dir_all(path.parent().expect("a parent")).expect("the folder");
        fs::write(&path, text).expect("the file");
        path
    }

    /// Write a file that steers the stub gh.
    pub fn stub_file(&self, name: &str, text: &str) {
        fs::write(self.stub.join(name), text).expect("the stub file");
    }

    /// Copy named files from the reference run (tests/fixtures/run) into the
    /// run folder: `env.seed(&["intake.json", "issues"])`. A folder is copied
    /// one level deep.
    pub fn seed(&self, names: &[&str]) {
        for name in names {
            let from = fixtures().join("run").join(name);
            let to = self.workdir.join(name);
            if from.is_dir() {
                fs::create_dir_all(&to).expect("the folder");
                for entry in fs::read_dir(&from).expect("the fixture folder") {
                    let entry = entry.expect("an entry");
                    fs::copy(entry.path(), to.join(entry.file_name())).expect("the copy");
                }
            } else {
                fs::create_dir_all(&self.workdir).expect("the run folder");
                fs::copy(&from, &to).unwrap_or_else(|e| panic!("copy {}: {e}", from.display()));
            }
        }
    }
}

/// A file as JSON. Panics with the path when it is missing or not JSON.
pub fn json(path: &Path) -> Value {
    let text = fs::read_to_string(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {}: {e}", path.display()))
}

/// A file of the reference run, as JSON.
pub fn golden(name: &str) -> Value {
    json(&fixtures().join("run").join(name))
}
