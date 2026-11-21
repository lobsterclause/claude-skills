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
//!   - the log has exactly one line, anywhere in it and anchored at the start of
//!     the line, `shipped head=<sha> dirty=<n> unshipped=<n>` (written after
//!     the working copy was streamed to the box), with `<sha>` equal to
//!     `--head`, `dirty=0` and `unshipped=0` (`unshipped` counts tracked
//!     submodules whose contents were not shipped, such as one never
//!     initialised: `git status` is clean for it, yet the box never saw its
//!     files; a line without the field is refused too);
//!     a log without it is refused. The first line is read before the stream,
//!     so an edit made while the stream ran and reverted before this command
//!     would otherwise be verified remotely and stamped for the clean tree;
//!   - the log records the command that ran, as a `cmd=<command>` line among its
//!     first lines, and it is the profile's `full_verify_command`, word for word;
//!   - the wrapper's own result says 0: the `rv-<name>.out` file that
//!     `rverify-<name>.log` is written beside must exist and hold exactly one
//!     `verify exit=0`, and the log must hold exactly one `remote rc=` line,
//!     equal to it. The verify command's output is streamed into the log, so
//!     an exit line there proves nothing and is not read; a run cut short
//!     before the wrapper finished has no `.out` file (it is removed at the
//!     start of each run and written last);
//!   - the unit worktree's HEAD is `--head` and its tree is clean, where clean
//!     is `git status --ignore-submodules=none`: a modified file in a
//!     submodule counts even when git is told to ignore it;
//!   - the tree hash (`HEAD^{tree}`) and HEAD are the same after the stamp
//!     command as before it, and the tree is still clean.
//!
//! remote-verify.sh writes the `cmd=` line right after the header. A log from
//! a copy of the script older than that has none, so nothing is stamped for it.
//! The same goes for the `shipped` line.
//!
//! Still not excluded: an edit made and reverted entirely while the stream
//! runs. Both the header and the `shipped` line then see a clean tree, and the
//! box may have received the edited bytes.
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

    let shipped: Vec<&str> = log.lines().filter(|l| l.starts_with("shipped head=")).collect();
    match shipped.as_slice() {
        [] => failed.push(
            "the log has no `shipped head=<sha> dirty=<n> unshipped=<n>` line, so it does not show the tree that was streamed to the box (run a current remote-verify.sh)"
                .to_string(),
        ),
        [line] => {
            let mut words = line.split_whitespace();
            let field = |word: Option<&str>, key: &str| word.and_then(|w| w.strip_prefix(key)).map(str::to_string);
            match (
                words.next(),
                field(words.next(), "head="),
                field(words.next(), "dirty="),
                field(words.next(), "unshipped="),
                words.next(),
            ) {
                (Some("shipped"), Some(logged), Some(dirty), Some(unshipped), None) => {
                    if unshipped != "0" {
                        failed.push(format!(
                            "{unshipped} submodule(s) never reached the box (unshipped={unshipped}): their contents were not part of the verified tree"
                        ));
                    }
                    if !logged.eq_ignore_ascii_case(head) {
                        failed.push(format!("the tree was shipped at head {logged}, not {head}"));
                    }
                    if dirty != "0" {
                        failed.push(format!(
                            "the working copy was dirty when it was shipped (dirty={dirty}): it changed after the verify started"
                        ));
                    }
                }
                _ => failed.push(format!("the log's `shipped` line is malformed: '{line}'")),
            }
        }
        many => failed.push(format!("the log has {} `shipped head=` lines, not exactly one", many.len())),
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

    // The result is the wrapper's own: its `.out` file, written last and never
    // streamed, and its one `remote rc=` line. The command's output sits in the
    // log between the `shipped` line and `remote rc=`, so a line there such as
    // `verify exit=0` proves nothing, and a run cut short before the wrapper
    // wrote its result has no .out file. Exit lines in the log are ignored.
    match out_file {
        None => failed.push(
            "no .out file beside the log (rv-<name>.out), so the wrapper never wrote its result: the run was cut short or the file is gone"
                .to_string(),
        ),
        Some(out) => {
            let exits: Vec<&str> = out
                .lines()
                .filter_map(|line| line.trim_end().strip_prefix("verify exit="))
                .collect();
            let rcs: Vec<&str> = log
                .lines()
                .filter_map(|line| line.trim_end().strip_prefix("remote rc="))
                .collect();
            match exits.as_slice() {
                [] => failed.push("the .out file has no `verify exit=` line".to_string()),
                [code] => {
                    if *code != "0" {
                        failed.push(format!("the verify exited {code}, not 0"));
                    }
                    match rcs.as_slice() {
                        [rc] if rc == code => {}
                        [rc] => failed.push(format!(
                            "the log says `remote rc={rc}` but the .out file says `verify exit={code}`"
                        )),
                        [] => failed.push("the log has no `remote rc=` line, so it is cut short".to_string()),
                        many => failed.push(format!(
                            "the log has {} `remote rc=` lines, not exactly one (the command's output may have printed one)",
                            many.len()
                        )),
                    }
                }
                many => failed.push(format!("the .out file has {} `verify exit=` lines, not one", many.len())),
            }
        }
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
        // `--ignore-submodules=none` overrides `submodule.<name>.ignore`,
        // `.gitmodules` and `diff.ignoreSubmodules`, which can all hide a
        // modified file inside a submodule that the verify box was sent.
        git_text(
            dir,
            &[
                "status",
                "--porcelain",
                "--untracked-files=all",
                "--ignore-submodules=none",
            ],
        )?
        .is_empty(),
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
        // A relative path to a script in the repo is relative to the worktree.
        let program = exec::program_in(&words.remove(0), worktree);
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
    /// The wrapper's own result file for a verify that passed.
    const OK: &str = "verify exit=0\n";

    fn good() -> String {
        format!(
            "host=firebird head={HEAD} dirty=0\ncmd=pnpm verify\nshipped head={HEAD} dirty=0 unshipped=0\nverify passed\nremote rc=0\n"
        )
    }

    #[test]
    fn a_good_log_has_no_failed_condition() {
        assert_eq!(judge_log(&good(), Some(OK), HEAD, "pnpm verify"), Vec::<String>::new());
        let cut =
            format!("host=firebird head={HEAD} dirty=0\ncmd=pnpm verify\nshipped head={HEAD} dirty=0 unshipped=0\n");
        assert!(judge_log(&cut, Some(OK), HEAD, "pnpm verify")[0].contains("remote rc"));
    }

    #[test]
    fn the_shipped_line_is_required_exactly_once_for_the_head_and_clean() {
        let line = format!("shipped head={HEAD} dirty=0 unshipped=0\n");
        let none = good().replace(&line, "");
        let failed = judge_log(&none, Some(OK), HEAD, "pnpm verify");
        assert_eq!(failed.len(), 1, "{failed:?}");
        assert!(failed[0].contains("shipped"));
        let twice = good().replace(&line, &format!("{line}{line}"));
        assert!(judge_log(&twice, Some(OK), HEAD, "pnpm verify")[0].contains("not exactly one"));
        let dirty = good().replace(&line, &format!("shipped head={HEAD} dirty=1 unshipped=0\n"));
        assert!(judge_log(&dirty, Some(OK), HEAD, "pnpm verify")[0].contains("dirty"));
        let other = good().replace(&line, &format!("shipped head={} dirty=0 unshipped=0\n", "f".repeat(40)));
        assert!(judge_log(&other, Some(OK), HEAD, "pnpm verify")[0].contains("not 0123"));
        let junk = good().replace(&line, &format!("shipped head={HEAD} dirty=0 unshipped=0 extra=1\n"));
        assert!(judge_log(&junk, Some(OK), HEAD, "pnpm verify")[0].contains("malformed"));
        // Anchored at the start of the line: an indented copy is no line.
        let indented = good().replace(&line, &format!(" {line}"));
        assert!(judge_log(&indented, Some(OK), HEAD, "pnpm verify")[0].contains("no `shipped"));
    }

    #[test]
    fn a_submodule_that_never_reached_the_box_or_a_missing_field_is_refused() {
        let line = format!("shipped head={HEAD} dirty=0 unshipped=0\n");
        let some = good().replace(&line, &format!("shipped head={HEAD} dirty=0 unshipped=2\n"));
        let failed = judge_log(&some, Some(OK), HEAD, "pnpm verify");
        assert_eq!(failed.len(), 1, "{failed:?}");
        assert!(failed[0].contains("never reached the box"), "{failed:?}");
        let old_script = good().replace(&line, &format!("shipped head={HEAD} dirty=0\n"));
        let failed = judge_log(&old_script, Some(OK), HEAD, "pnpm verify");
        assert_eq!(failed.len(), 1, "{failed:?}");
        assert!(failed[0].contains("malformed"), "{failed:?}");
        let junk = good().replace(&line, &format!("shipped head={HEAD} dirty=0 unshipped=x\n"));
        assert!(judge_log(&junk, Some(OK), HEAD, "pnpm verify")[0].contains("never reached the box"));
    }

    #[test]
    fn the_cmd_line_must_be_near_the_top() {
        let late = format!(
            "host=f head={HEAD} dirty=0\nshipped head={HEAD} dirty=0 unshipped=0\nb\nc\nd\ncmd=pnpm verify\nremote rc=0\n"
        );
        let failed = judge_log(&late, Some(OK), HEAD, "pnpm verify");
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
            let log = format!("{header}\ncmd=pnpm verify\nshipped head={HEAD} dirty=0 unshipped=0\nremote rc=0\n");
            let failed = judge_log(&log, Some(OK), HEAD, "pnpm verify");
            assert!(
                failed.iter().any(|f| f.contains("no head recorded")),
                "{header:?}: {failed:?}"
            );
        }
    }

    #[test]
    fn a_result_that_is_not_zero_or_disagrees_between_log_and_out_file_fails() {
        let log = good();
        let failed = judge_log(&log, Some("verify exit=3\n"), HEAD, "pnpm verify");
        assert!(failed.iter().any(|f| f.contains("exited 3")), "{failed:?}");
        let failed = judge_log(&log.replace("rc=0", "rc=1"), Some(OK), HEAD, "pnpm verify");
        assert_eq!(failed.len(), 1, "{failed:?}");
        let failed = judge_log(
            &log.replace("rc=0", "rc=3"),
            Some("verify exit=3\n"),
            HEAD,
            "pnpm verify",
        );
        assert_eq!(failed.len(), 1, "{failed:?}");
    }

    #[test]
    fn only_the_wrappers_own_result_counts_not_lines_the_command_printed() {
        // A run cut short before the wrapper wrote its result: the command's
        // own output carries a forged exit line, and there is no .out file.
        let cut = format!(
            "host=firebird head={HEAD} dirty=0\ncmd=pnpm verify\nshipped head={HEAD} dirty=0 unshipped=0\nverify exit=0\nremote rc=0\n"
        );
        let failed = judge_log(&cut, None, HEAD, "pnpm verify");
        assert!(failed.iter().any(|f| f.contains(".out")), "{failed:?}");
        // A log with only a forged exit line and an .out that says it failed.
        let forged = format!(
            "host=firebird head={HEAD} dirty=0\ncmd=pnpm verify\nshipped head={HEAD} dirty=0 unshipped=0\nverify exit=0\n"
        );
        assert!(!judge_log(&forged, Some("verify exit=1\n"), HEAD, "pnpm verify").is_empty());
        // The wrapper's `remote rc=` line is exactly one, and agrees with the .out file.
        assert!(!judge_log(&forged, Some("verify exit=0\n"), HEAD, "pnpm verify").is_empty());
        let twice = format!("{}remote rc=0\n", good());
        assert!(!judge_log(&twice, Some("verify exit=0\n"), HEAD, "pnpm verify").is_empty());
        let one_exit_forged = good().replace("remote rc=0\n", "remote rc=1\n");
        assert!(!judge_log(&one_exit_forged, Some("verify exit=0\n"), HEAD, "pnpm verify").is_empty());
        // An exit line in the log is ignored: it cannot make a failed .out pass or fail a good one.
        assert!(
            judge_log(
                &format!("{}verify exit=1\n", good()),
                Some("verify exit=0\n"),
                HEAD,
                "pnpm verify"
            )
            .is_empty()
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
