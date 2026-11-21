//! What every command needs: the run folder, the repo, the profile, the event
//! log and the clock.
//!
//! There is no default run folder. pr-drain's scripts once defaulted to a
//! folder relative to the working directory, and since every tool call starts
//! wherever it starts, each call site got its own log: one drain wrote 1 event
//! to its named folder and 44 to the repo checkout. So the folder is named, as
//! an absolute path, or the command stops.

use std::fs::{self, OpenOptions};
use std::io::Write as _;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

use crate::error::{Fail, Res};
use crate::git;
use crate::model::{Queue, Unit};
use crate::profile::Profile;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode {
    Session,
    Driver,
    Unit,
}

impl Mode {
    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Session => "session",
            Mode::Driver => "driver",
            Mode::Unit => "unit",
        }
    }
}

pub struct Ctx {
    pub workdir: PathBuf,
    pub skill_dir: PathBuf,
    pub profile: Profile,
    pub dry_run: bool,
}

pub fn env_str(name: &str) -> String {
    std::env::var(name).unwrap_or_default()
}

/// Letters, digits, dot, dash and underscore: safe in a file name and in a gh
/// argument.
pub fn is_slug(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c))
}

fn repo_from_env() -> Res<String> {
    let repo = env_str("ISSUE_DRAIN_REPO");
    match repo.split_once('/') {
        Some((owner, name)) if is_slug(owner) && is_slug(name) => Ok(repo),
        _ => Err(Fail::usage(format!(
            "set ISSUE_DRAIN_REPO to <owner>/<repo> (got '{repo}')"
        ))),
    }
}

/// `<dir>/<owner>__<repo>.toml`, matched without regard to case: GitHub does
/// not tell `Owner/Repo` from `owner/repo`, and most filesystems do.
fn default_profile(dir: &Path, repo: &str) -> PathBuf {
    let name = format!("{}.toml", repo.replace('/', "__"));
    let on_disk = fs::read_dir(dir).ok().and_then(|entries| {
        entries
            .flatten()
            .map(|entry| entry.file_name())
            .find(|file| file.to_string_lossy().eq_ignore_ascii_case(&name))
    });
    match on_disk {
        Some(file) => dir.join(file),
        None => dir.join(name),
    }
}

impl Ctx {
    pub fn load() -> Res<Ctx> {
        let workdir = env_str("ISSUE_DRAIN_WORKDIR");
        if !workdir.starts_with('/') {
            return Err(Fail::usage(format!(
                "set ISSUE_DRAIN_WORKDIR to an absolute path, e.g. $HOME/.issue-drain/<owner>__<repo>/<run> (got '{workdir}')"
            )));
        }
        // The launcher sets ISSUE_DRAIN_SKILL_DIR. A binary run straight from
        // target/ falls back to the folder it was built in.
        let skill_dir = match env_str("ISSUE_DRAIN_SKILL_DIR") {
            dir if dir.starts_with('/') => PathBuf::from(dir),
            _ => PathBuf::from(env!("CARGO_MANIFEST_DIR")),
        };
        let profile_path = match env_str("ISSUE_DRAIN_PROFILE") {
            path if !path.is_empty() => PathBuf::from(path),
            _ => default_profile(&skill_dir.join("profiles"), &repo_from_env()?),
        };
        Ok(Ctx {
            workdir: PathBuf::from(workdir),
            profile: Profile::load(&profile_path, &skill_dir)?,
            skill_dir,
            dry_run: env_str("ISSUE_DRAIN_DRY_RUN") == "1",
        })
    }

    /// `<owner>/<repo>`. It reaches file names and gh arguments, so its shape
    /// is checked.
    pub fn repo(&self) -> Res<String> {
        repo_from_env()
    }

    /// A local checkout of the repo (any worktree). Only read from.
    pub fn repo_dir(&self) -> Res<PathBuf> {
        let dir = env_str("ISSUE_DRAIN_REPO_DIR");
        if !dir.starts_with('/') {
            return Err(Fail::usage(format!(
                "set ISSUE_DRAIN_REPO_DIR to the absolute path of a local checkout (got '{dir}')"
            )));
        }
        let dir = PathBuf::from(dir);
        if !git::ok(&dir, &["rev-parse", "--git-dir"]) {
            return Err(Fail::usage(format!(
                "ISSUE_DRAIN_REPO_DIR is not a git checkout: {}",
                dir.display()
            )));
        }
        // Quoted paths are relative to the root, so every git call runs there
        // even when the setting names a folder inside the checkout.
        let root = git::out(&dir, &["rev-parse", "--show-toplevel"])
            .map(|root| PathBuf::from(root.trim_end_matches('\n')))
            .filter(|root| root.is_absolute());
        Ok(root.unwrap_or(dir))
    }

    pub fn mode(&self) -> Res<Mode> {
        match env_str("ISSUE_DRAIN_MODE").as_str() {
            "" | "session" => Ok(Mode::Session),
            "driver" => Ok(Mode::Driver),
            "unit" => Ok(Mode::Unit),
            other => Err(Fail::usage(format!(
                "ISSUE_DRAIN_MODE must be session, driver or unit (got '{other}')"
            ))),
        }
    }

    /// Refuse when this is a unit process: `command` is the driver's job.
    pub fn require_driver(&self, command: &str) -> Res<()> {
        match self.mode()? {
            Mode::Unit => Err(Fail::refused(format!(
                "{command} is the driver's job; a unit process may not run it"
            ))),
            Mode::Session | Mode::Driver => Ok(()),
        }
    }

    /// Unit `n` of this run's queue.json.
    pub fn queue_unit(&self, n: u64) -> Res<Unit> {
        let path = self.path("queue.json");
        let queue: Queue = read_json(&path)
            .ok_or_else(|| Fail::usage(format!("no queue in {}; run `tracker render` first", path.display())))?;
        let id = format!("U{n}");
        queue
            .units
            .into_iter()
            .find(|u| u.id == id)
            .ok_or_else(|| Fail::usage(format!("queue.json has no unit {id}")))
    }

    /// The run id is the run folder's name. It goes into the tracker's marker
    /// line, so its shape is checked. The name is the real folder's: a run
    /// reached through its `tracker-<n>` link, or as `<run>/.`, is the same run.
    pub fn run_id(&self) -> Res<String> {
        let real = fs::canonicalize(&self.workdir).unwrap_or_else(|_| self.workdir.clone());
        let name = real.file_name().and_then(|n| n.to_str()).unwrap_or_default();
        if is_slug(name) {
            Ok(name.to_string())
        } else {
            Err(Fail::usage(format!(
                "the run folder's name is the run id and must be letters, digits, dot, dash or underscore (got '{name}')"
            )))
        }
    }

    pub fn path(&self, name: &str) -> PathBuf {
        self.workdir.join(name)
    }

    /// Seconds since the epoch. ISSUE_DRAIN_NOW pins it, for tests.
    pub fn now(&self) -> i64 {
        env_str("ISSUE_DRAIN_NOW")
            .parse()
            .unwrap_or_else(|_| OffsetDateTime::now_utc().unix_timestamp())
    }

    /// Append one line to `<workdir>/events.jsonl`. This is local state, so it
    /// is written in a dry run too: the log is a dry run's output.
    pub fn event(&self, event: &str, extra: Value) -> Res<()> {
        let mut line = Map::new();
        line.insert("ts".into(), Value::String(rfc3339(self.now())));
        line.insert("event".into(), Value::String(event.into()));
        if let Value::Object(extra) = extra {
            line.extend(extra);
        }
        let file = self.path("events.jsonl");
        let append = || -> std::io::Result<()> {
            fs::create_dir_all(&self.workdir)?;
            let mut f = OpenOptions::new().create(true).append(true).open(&file)?;
            writeln!(f, "{}", Value::Object(line))
        };
        append().map_err(|e| Fail::failed(format!("cannot write {}: {e}", file.display())))
    }
}

pub fn rfc3339(epoch: i64) -> String {
    OffsetDateTime::from_unix_timestamp(epoch)
        .ok()
        .and_then(|t| t.format(&Rfc3339).ok())
        .unwrap_or_default()
}

pub fn parse_rfc3339(text: &str) -> Option<i64> {
    OffsetDateTime::parse(text, &Rfc3339)
        .ok()
        .map(OffsetDateTime::unix_timestamp)
}

/// Write to a temporary name beside the target, then rename: a reader never
/// sees half a file.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> Res<()> {
    let write = || -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut tmp = path.as_os_str().to_owned();
        tmp.push(format!(".tmp.{}", std::process::id()));
        let tmp = PathBuf::from(tmp);
        fs::write(&tmp, bytes)?;
        fs::rename(&tmp, path)
    };
    write().map_err(|e| Fail::failed(format!("cannot write {}: {e}", path.display())))
}

pub fn write_json<T: Serialize>(path: &Path, value: &T) -> Res<()> {
    let mut text = serde_json::to_string_pretty(value)
        .map_err(|e| Fail::failed(format!("cannot encode {}: {e}", path.display())))?;
    text.push('\n');
    write_atomic(path, text.as_bytes())
}

/// Read a JSON file. `None` when the file is absent, unreadable or not the
/// shape asked for; the caller owns the message, since it knows which command
/// should have written the file.
pub fn read_json<T: DeserializeOwned>(path: &Path) -> Option<T> {
    serde_json::from_str(&fs::read_to_string(path).ok()?).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_profile_is_found_whatever_the_case_of_the_repo() {
        let dir = tempfile::tempdir().expect("a temporary folder");
        fs::write(dir.path().join("Not-Every-Mom__Tidepool.toml"), "").expect("the profile");
        let found = default_profile(dir.path(), "not-every-mom/tidepool");
        assert_eq!(found.file_name().unwrap(), "Not-Every-Mom__Tidepool.toml");
        let missing = default_profile(dir.path(), "example/other");
        assert_eq!(missing.file_name().unwrap(), "example__other.toml");
    }

    #[test]
    fn timestamps_round_trip_in_utc() {
        assert_eq!(rfc3339(1_793_491_200), "2026-11-01T00:00:00Z");
        assert_eq!(parse_rfc3339("2026-11-01T00:00:00Z"), Some(1_793_491_200));
        assert_eq!(parse_rfc3339("2026-11-01T02:00:00+02:00"), Some(1_793_491_200));
        assert_eq!(parse_rfc3339("yesterday"), None);
    }

    #[test]
    fn a_slug_has_no_slash_space_or_emptiness() {
        assert!(is_slug("run-2026.11_a"));
        assert!(!is_slug(""));
        assert!(!is_slug("a/b"));
        assert!(!is_slug("a b"));
    }
}
