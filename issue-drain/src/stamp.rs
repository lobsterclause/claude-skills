//! `issue-drain stamp-remote-pass --unit <n> --log <file> --head <sha>`: after
//! a homelab verify passed at an exact commit, record the repo's local verify
//! stamp, so pre-push and the Stop gate do not run the same checks again.
//!
//! A stamp says "these exact bytes passed the full verify", and a wrong one
//! lets a real check be skipped, so every doubt is a refusal. It stamps only
//! when all of these hold; otherwise it exits 3, names each one that failed,
//! and writes nothing:
//!
//!   - the log's first line is `host=<h> head=<sha> dirty=<n>` (what
//!     `pr-drain/scripts/remote-verify.sh` writes first), with `<sha>` equal to
//!     `--head` and `dirty=0`;
//!   - the log records the command that ran, as a `cmd=<command>` line among its
//!     first lines, and it is the profile's `full_verify_command`, word for word;
//!   - every exit it shows is 0: `verify exit=N` and `remote rc=N` lines in the
//!     log, and the same lines in the `rv-<name>.out` file that
//!     `rverify-<name>.log` is written beside. At least one must exist;
//!   - the unit worktree's HEAD is `--head` and its tree is clean;
//!   - the tree hash (`HEAD^{tree}`) and HEAD are the same after the stamp
//!     command as before it, and the tree is still clean.
//!
//! remote-verify.sh writes the `cmd=` line right after the header. A log from
//! a copy of the script older than that has none, so nothing is stamped for it.
//!
//! Exit: 0 stamped, or no stamp command in the profile (`stamped: false`);
//! 3 a condition failed; 2 bad arguments, an unreadable log, or no
//! `units/<n>/unit.json`; 1 git or the stamp command failed.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::json;

use crate::ctx::{Ctx, read_json, write_json};
use crate::error::{Fail, Res};
use crate::exec;
use crate::git;
use crate::merge_gate::is_sha;

#[derive(clap::Args)]
pub struct Args {
    /// The unit; its files are under <run folder>/units/<n>/.
    #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
    unit: u64,
    /// The log `remote-verify.sh` wrote (`rverify-<name>.log`).
    #[arg(long)]
    log: PathBuf,
    /// The commit the verify ran at, in full.
    #[arg(long)]
    head: String,
}

const STAMP_LIMIT: Duration = Duration::from_secs(120);
/// The `cmd=` line must be near the top, where the script's own output is,
/// not somewhere in the verify's output.
const CMD_WITHIN_LINES: usize = 5;

/// Each condition of the log that fails, in words. Pure.
pub fn judge_log(log: &str, out_file: Option<&str>, head: &str, full_command: &str) -> Vec<String> {
    let mut failed = Vec::new();

    let header = log.lines().next().unwrap_or_default();
    let mut words = header.split_whitespace();
    let field = |word: Option<&str>, key: &str| word.and_then(|w| w.strip_prefix(key)).map(str::to_string);
    match (
        field(words.next(), "host="),
        field(words.next(), "head="),
        field(words.next(), "dirty="),
        words.next(),
    ) {
        (Some(_), Some(logged), Some(dirty), None) => {
            if !logged.eq_ignore_ascii_case(head) {
                failed.push(format!("the log is for head {logged}, not {head}"));
            }
            if dirty != "0" {
                failed.push(format!("the remote tree was dirty (dirty={dirty})"));
            }
        }
        _ => failed.push("no head recorded: the log's first line is not `host=<h> head=<sha> dirty=<n>`".to_string()),
    }

    if full_command.is_empty() {
        failed.push("the profile has no full_verify_command, so no log can show the full verify ran".to_string());
    } else {
        let ran = log
            .lines()
            .take(CMD_WITHIN_LINES)
            .find_map(|line| line.strip_prefix("cmd="));
        match ran {
            None => failed
                .push("the log records no `cmd=` line near its top, so it does not show which command ran".to_string()),
            Some(ran) if ran.trim_end() != full_command => failed.push(format!(
                "the log's command is '{}', not the profile's full verify command '{full_command}'",
                ran.trim_end()
            )),
            Some(_) => {}
        }
    }

    let exits: Vec<&str> = log
        .lines()
        .chain(out_file.unwrap_or_default().lines())
        .filter_map(|line| {
            let line = line.trim_end();
            line.strip_prefix("verify exit=")
                .or_else(|| line.strip_prefix("remote rc="))
        })
        .collect();
    if exits.is_empty() {
        failed.push("no `verify exit=` line in the log or in the .out file beside it".to_string());
    }
    for code in exits.iter().filter(|code| **code != "0") {
        failed.push(format!("the verify exited {code}, not 0"));
    }
    failed
}

/// `rverify-<name>.log` is written beside `rv-<name>.out`.
fn out_file_beside(log: &Path) -> Option<PathBuf> {
    let name = log.file_name()?.to_str()?;
    let middle = name.strip_prefix("rverify-")?.strip_suffix(".log")?;
    Some(log.with_file_name(format!("rv-{middle}.out")))
}

fn git_text(dir: &Path, args: &[&str]) -> Res<String> {
    git::out(dir, args)
        .map(|s| s.trim().to_string())
        .ok_or_else(|| Fail::failed(format!("git {} failed in {}", args.join(" "), dir.display())))
}

/// HEAD, its tree, and whether the working tree is clean (untracked files count).
fn state(dir: &Path) -> Res<(String, String, bool)> {
    Ok((
        git_text(dir, &["rev-parse", "HEAD"])?,
        git_text(dir, &["rev-parse", "HEAD^{tree}"])?,
        git_text(dir, &["status", "--porcelain", "--untracked-files=all"])?.is_empty(),
    ))
}

pub fn run(ctx: &Ctx, args: &Args) -> Res<()> {
    let unit = args.unit;
    if !is_sha(&args.head) {
        return Err(Fail::usage(format!(
            "--head must be a full 40 or 64 digit commit SHA (got '{}')",
            args.head
        )));
    }
    let log = fs::read_to_string(&args.log)
        .map_err(|e| Fail::usage(format!("cannot read the log {}: {e}", args.log.display())))?;
    let out_file = out_file_beside(&args.log).and_then(|p| fs::read_to_string(p).ok());
    let unit_file = ctx.path(&format!("units/{unit}/unit.json"));
    let worktree: String = read_json::<serde_json::Value>(&unit_file)
        .and_then(|u| u["worktree"].as_str().map(str::to_string))
        .ok_or_else(|| {
            Fail::usage(format!(
                "no worktree in {}; run `issue-drain unit-prepare --unit {unit}` first",
                unit_file.display()
            ))
        })?;
    let worktree = Path::new(&worktree);
    let p = &ctx.profile;

    let mut failed = judge_log(&log, out_file.as_deref(), &args.head, &p.full_verify_command);
    let (head, tree, clean) = state(worktree)?;
    if !head.eq_ignore_ascii_case(&args.head) {
        failed.push(format!("the worktree is at {head}, not {}", args.head));
    }
    if !clean {
        failed.push("the worktree is not clean".to_string());
    }
    if !failed.is_empty() {
        return Err(Fail::refused(format!(
            "nothing stamped for unit {unit}: {}",
            failed.join("; ")
        )));
    }

    let record =
        |stamped: bool, reason: &str| json!({"head": head, "tree": tree, "stamped": stamped, "reason": reason});
    let (stamped, reason) = if p.stamp_command.is_empty() {
        (false, "no stamp command in profile")
    } else {
        let mut words = exec::expand(&p.stamp_command, &[("tree", &tree), ("head", &head)])
            .map_err(|e| Fail::usage(format!("profile key stamp_command: {e}")))?;
        let program = words.remove(0);
        let log_file = ctx.path(&format!("units/{unit}/stamp-command.log"));
        let ran = exec::run(&program, &words, worktree, STAMP_LIMIT, &log_file)?;
        if !ran.ok() {
            return Err(Fail::failed(format!(
                "the stamp command ({}) failed: {}",
                p.stamp_command,
                ran.failure(STAMP_LIMIT)
            )));
        }
        let (head_after, tree_after, clean_after) = state(worktree)?;
        if head_after != head || tree_after != tree || !clean_after {
            return Err(Fail::refused(format!(
                "the worktree changed while the stamp command ran (head {head} then {head_after}, tree {tree} then {tree_after}, clean after: {clean_after}); the stamp it wrote, if any, is for the tree before",
            )));
        }
        (true, "stamp command exited 0")
    };

    let out = record(stamped, reason);
    write_json(&ctx.path(&format!("units/{unit}/stamp.json")), &out)?;
    ctx.event(
        "stamp_remote_pass",
        json!({"unit": unit, "head": head, "tree": tree, "stamped": stamped}),
    )?;
    println!("{out}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const HEAD: &str = "0123456789abcdef0123456789abcdef01234567";

    fn good() -> String {
        format!("host=firebird head={HEAD} dirty=0\ncmd=pnpm verify\nverify passed\nremote rc=0\n")
    }

    #[test]
    fn a_good_log_has_no_failed_condition() {
        assert_eq!(judge_log(&good(), None, HEAD, "pnpm verify"), Vec::<String>::new());
        let no_exit = "host=firebird head=0123456789abcdef0123456789abcdef01234567 dirty=0\ncmd=pnpm verify\n";
        assert!(judge_log(no_exit, Some("verify exit=0\n"), HEAD, "pnpm verify").is_empty());
    }

    #[test]
    fn the_cmd_line_must_be_near_the_top() {
        let late = format!("host=f head={HEAD} dirty=0\na\nb\nc\nd\ncmd=pnpm verify\nremote rc=0\n");
        let failed = judge_log(&late, None, HEAD, "pnpm verify");
        assert_eq!(failed.len(), 1, "{failed:?}");
        assert!(failed[0].contains("cmd="));
    }

    #[test]
    fn a_header_with_extra_or_missing_fields_is_no_header() {
        for header in [
            format!("host=f head={HEAD}"),
            format!("head={HEAD} dirty=0"),
            format!("host=f head={HEAD} dirty=0 extra=1"),
            String::new(),
        ] {
            let log = format!("{header}\ncmd=pnpm verify\nremote rc=0\n");
            let failed = judge_log(&log, None, HEAD, "pnpm verify");
            assert!(
                failed.iter().any(|f| f.contains("no head recorded")),
                "{header:?}: {failed:?}"
            );
        }
    }

    #[test]
    fn an_exit_line_in_either_place_that_is_not_zero_fails() {
        let log = good();
        assert_eq!(judge_log(&log, Some("verify exit=3\n"), HEAD, "pnpm verify").len(), 1);
        assert_eq!(
            judge_log(
                &log.replace("rc=0", "rc=1"),
                Some("verify exit=0\n"),
                HEAD,
                "pnpm verify"
            )
            .len(),
            1
        );
    }

    #[test]
    fn the_out_file_is_found_beside_the_log() {
        assert_eq!(
            out_file_beside(Path::new("/a/rverify-pr42.log")),
            Some(PathBuf::from("/a/rv-pr42.out"))
        );
        assert_eq!(out_file_beside(Path::new("/a/other.log")), None);
    }
}
