//! Run a local command with a time limit and keep what it printed.
//!
//! The commands here (a bootstrap, `codegraph init`, a stamp command, git
//! writes) can hang or print a lot. Output goes to a log file, not a pipe, so
//! a chatty command cannot fill a pipe and stall; the caller gets the tail of
//! the file. The command runs in its own process group, so a timeout kills
//! what it started too.

use std::fs::File;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant};

use crate::error::{Fail, Res};

pub struct Ran {
    /// `None` when the command was killed for running too long or by a signal.
    pub code: Option<i32>,
    pub timed_out: bool,
    /// The last lines of what it printed, stdout and stderr together.
    pub tail: String,
}

impl Ran {
    pub fn ok(&self) -> bool {
        self.code == Some(0)
    }

    /// Why it failed, in a few words and the tail: "exit 4", "timed out after 5s".
    pub fn failure(&self, limit: Duration) -> String {
        let how = match (self.timed_out, self.code) {
            (true, _) => format!("timed out after {}s", limit.as_secs()),
            (false, Some(code)) => format!("exit {code}"),
            (false, None) => "killed by a signal".to_string(),
        };
        if self.tail.is_empty() {
            how
        } else {
            format!("{how}; its output ended:\n{}", self.tail)
        }
    }
}

const TAIL_LINES: usize = 15;

fn tail_of(log: &Path) -> String {
    let text = std::fs::read(log).map(|b| String::from_utf8_lossy(&b).into_owned());
    let text = text.unwrap_or_default();
    let lines: Vec<&str> = text.lines().collect();
    lines[lines.len().saturating_sub(TAIL_LINES)..].join("\n")
}

/// Run `program args` in `dir`, logging to `log`, for at most `limit`. A
/// program that cannot start is an error; one that exits nonzero is not (see
/// `Ran::ok`).
pub fn run(program: &str, args: &[String], dir: &Path, limit: Duration, log: &Path) -> Res<Ran> {
    let open = || -> std::io::Result<(File, File)> {
        if let Some(parent) = log.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let out = fresh(log)?;
        let err = out.try_clone()?;
        Ok((out, err))
    };
    let (out, err) = open().map_err(|e| Fail::failed(format!("cannot write {}: {e}", log.display())))?;
    supervise(program, args, dir, limit, (out, err), &[], log, None)
}

/// `run`, with extra environment variables for the child and stdout and stderr
/// in separate files (`tail` is the end of stderr). The child inherits the rest
/// of the environment. With `pidfile`, the child's pid (also its process
/// group) is written there while it runs, and the file is removed after it ends.
pub fn run_env(
    program: &str,
    args: &[String],
    dir: &Path,
    limit: Duration,
    logs: (&Path, &Path),
    env: &[(&str, &str)],
    pidfile: Option<&Path>,
) -> Res<Ran> {
    let open = |path: &Path| -> Res<File> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| Fail::failed(format!("cannot write {}: {e}", path.display())))?;
        }
        fresh(path).map_err(|e| Fail::failed(format!("cannot write {}: {e}", path.display())))
    };
    let files = (open(logs.0)?, open(logs.1)?);
    supervise(program, args, dir, limit, files, env, logs.1, pidfile)
}

/// A new, empty log file at `path`. Whatever was there is removed first
/// (`remove_file` removes a symlink, not what it points at) and the file is
/// made with `create_new`, so a link planted at the path is never followed.
fn fresh(path: &Path) -> std::io::Result<File> {
    match std::fs::remove_file(path) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    std::fs::OpenOptions::new().write(true).create_new(true).open(path)
}

#[allow(clippy::too_many_arguments)] // private; every caller passes all of them
fn supervise(
    program: &str,
    args: &[String],
    dir: &Path,
    limit: Duration,
    (out, err): (File, File),
    env: &[(&str, &str)],
    tail_log: &Path,
    pidfile: Option<&Path>,
) -> Res<Ran> {
    let mut child = Command::new(program)
        .args(args)
        .envs(env.iter().copied())
        .current_dir(dir)
        .stdin(Stdio::null())
        .stdout(out)
        .stderr(err)
        .process_group(0)
        .spawn()
        .map_err(|e| Fail::failed(format!("cannot run {program}: {e}")))?;
    if let Some(pidfile) = pidfile
        && let Err(e) = std::fs::write(pidfile, format!("{}\n", child.id()))
    {
        let _ = Command::new("kill")
            .args(["-KILL", "--", &format!("-{}", child.id())])
            .status();
        let _ = child.kill();
        let _ = child.wait();
        return Err(Fail::failed(format!("cannot write {}: {e}", pidfile.display())));
    }
    let deadline = Instant::now() + limit;
    let (code, timed_out) = loop {
        match child.try_wait() {
            Ok(Some(status)) => break (status.code(), false),
            Ok(None) if Instant::now() >= deadline => {
                // A negative pid is the whole group. `kill` is the tool for it:
                // this crate forbids unsafe code, so no libc call.
                let group = format!("-{}", child.id());
                let _ = Command::new("kill").args(["-KILL", "--", &group]).status();
                let _ = child.kill();
                let _ = child.wait();
                break (None, true);
            }
            Ok(None) => sleep(Duration::from_millis(20)),
            Err(e) => return Err(Fail::failed(format!("cannot wait for {program}: {e}"))),
        }
    };
    if let Some(pidfile) = pidfile {
        let _ = std::fs::remove_file(pidfile);
    }
    Ok(Ran {
        code,
        timed_out,
        tail: tail_of(tail_log),
    })
}

/// `git -C <dir> <args>`, with the same limits and log.
pub fn git(dir: &Path, args: &[&str], limit: Duration, log: &Path) -> Res<Ran> {
    let mut all = vec!["-C".to_string(), dir.display().to_string()];
    all.extend(args.iter().map(|a| a.to_string()));
    run("git", &all, dir, limit, log)
}

/// The program to start in `dir`. A relative path to a script in the repo (it
/// has a `/`) is relative to `dir`; std leaves open whether it is relative to
/// that or to this process's folder, so it is made absolute here. A bare name
/// is looked up on PATH, as it always was.
pub fn program_in(program: &str, dir: &Path) -> String {
    if program.contains('/') && !program.starts_with('/') {
        dir.join(program).display().to_string()
    } else {
        program.to_string()
    }
}

/// The words of a profile command with `{name}` placeholders filled in. The
/// command is split like a shell would split it, but no shell runs it, so a
/// value with a space or a quote in it stays one argument.
pub fn expand(command: &str, values: &[(&str, &str)]) -> Result<Vec<String>, String> {
    let words = shlex::split(command).ok_or_else(|| format!("'{command}' is not a command (unbalanced quote)"))?;
    if words.is_empty() {
        return Err("the command is empty".into());
    }
    Ok(words
        .into_iter()
        .map(|word| {
            values
                .iter()
                .fold(word, |w, (name, value)| w.replace(&format!("{{{name}}}"), value))
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp() -> tempfile::TempDir {
        tempfile::tempdir().expect("a temporary folder")
    }

    #[test]
    fn placeholders_fill_in_after_splitting_so_values_stay_whole() {
        let words = expand("sh -c 'echo {x}' {y}", &[("x", "a b"), ("y", "c d")]).expect("a command");
        assert_eq!(words, ["sh", "-c", "echo a b", "c d"]);
        assert!(expand("sh 'oops", &[]).is_err());
        assert!(expand("   ", &[]).is_err());
    }

    #[test]
    fn a_relative_path_is_made_relative_to_the_folder_and_a_bare_name_is_left_alone() {
        let dir = Path::new("/work/tree");
        assert_eq!(program_in("scripts/stamp.sh", dir), "/work/tree/scripts/stamp.sh");
        assert_eq!(program_in("./stamp.sh", dir), "/work/tree/./stamp.sh");
        assert_eq!(program_in("/usr/bin/env", dir), "/usr/bin/env");
        assert_eq!(program_in("pnpm", dir), "pnpm");
    }

    #[test]
    fn a_log_path_that_is_a_symlink_is_replaced_and_its_target_left_alone() {
        let dir = temp();
        let target = dir.path().join("target.txt");
        std::fs::write(&target, "keep me").unwrap();
        let log = dir.path().join("l.log");
        std::os::unix::fs::symlink(&target, &log).unwrap();
        let args = ["-c", "echo new"].map(String::from);
        run("sh", &args, dir.path(), Duration::from_secs(10), &log).expect("ran");
        assert_eq!(std::fs::read_to_string(&target).unwrap(), "keep me");
        assert!(!std::fs::symlink_metadata(&log).unwrap().file_type().is_symlink());
        assert_eq!(std::fs::read_to_string(&log).unwrap().trim(), "new");
    }

    #[test]
    fn a_command_that_exits_nonzero_reports_its_code_and_tail() {
        let dir = temp();
        let args = ["-c", "echo out; echo err >&2; exit 3"].map(String::from);
        let ran = run(
            "sh",
            &args,
            dir.path(),
            Duration::from_secs(10),
            &dir.path().join("l.log"),
        )
        .expect("ran");
        assert_eq!(ran.code, Some(3));
        assert!(!ran.ok() && !ran.timed_out);
        assert!(ran.tail.contains("out") && ran.tail.contains("err"));
    }

    #[test]
    fn a_command_that_runs_too_long_is_killed_with_what_it_started() {
        let dir = temp();
        let marker = dir.path().join("grandchild");
        let script = format!("(sleep 2; echo late > {}) &\nsleep 30\n", marker.display());
        let args = ["-c".to_string(), script];
        let started = Instant::now();
        let ran = run(
            "sh",
            &args,
            dir.path(),
            Duration::from_millis(300),
            &dir.path().join("l.log"),
        )
        .expect("ran");
        assert!(ran.timed_out && ran.code.is_none());
        assert!(started.elapsed() < Duration::from_secs(10));
        sleep(Duration::from_millis(2500));
        assert!(!marker.exists(), "the background child was left running");
    }

    #[test]
    fn a_program_that_cannot_start_is_an_error() {
        let dir = temp();
        let err = run(
            "no-such-program-here",
            &[],
            dir.path(),
            Duration::from_secs(1),
            &dir.path().join("l.log"),
        )
        .err()
        .expect("an error");
        assert_eq!(err.code, 1);
    }

    #[test]
    fn the_tail_keeps_only_the_last_lines() {
        let dir = temp();
        let args = ["-c", "seq 1 100"].map(String::from);
        let ran = run(
            "sh",
            &args,
            dir.path(),
            Duration::from_secs(10),
            &dir.path().join("l.log"),
        )
        .expect("ran");
        assert_eq!(ran.tail.lines().count(), TAIL_LINES);
        assert!(ran.tail.ends_with("100"));
    }
}
