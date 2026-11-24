//! `issue-drain review-proof --unit <n> --run-dir <path> --head <sha>`: read
//! one cross-review run folder and write `units/<n>/review-proof.json`, the
//! file `merge-gate` reads. This records who produced output; merge-gate
//! judges it.
//!
//! A run folder holds `raw/<reviewer>.stdout` and `raw/<reviewer>.meta.json`.
//! Cross-review's rewritten-history procedure passes `--out "$run_dir"`, which
//! leaves the same files at the run folder's root; they are read from there
//! only when there is no `raw/`.
//!
//! A reviewer has output only when its meta file shows it succeeded
//! (`exit_code` 0, not timed out, `failure_kind` null) AND its stdout is not
//! blank. A short verdict such as `{"findings":[]}` is output: cross-review
//! itself accepts it (`output_no_verdict` in `run_reviewers.sh`). Only the
//! codex baseline also needs 200 non-blank bytes, its "present and not trivial"
//! rule. A reviewer that printed a page and then died on its quota has none,
//! and one with no meta file is not proven. `failure_kind` is recorded as the
//! meta has it.
//!
//! When the run folder has a `context.json` (cross-review's `worktree.sh start`
//! writes it, with the `head_sha` it reviewed), its `head_sha` must equal
//! `--head`: a folder left over from an earlier round cannot be stamped with a
//! newer head. One that cannot be read, or has no `head_sha`, is refused too.
//! A folder with no `context.json` (the rewritten-history procedure) is taken
//! on the caller's `--head`.
//!
//! Codex's findings are read too, for the driver's cap default: the
//! `- [Pn] ...` lines after the last `Full review comments:` or
//! `Review comment:` line of its stdout (codex prints its review block twice;
//! the last one is whole). A codex run with neither line, or with no finding
//! line after it, has `findings: None`, which the driver reads as a pass it
//! cannot weigh. No other reviewer's output is parsed.
//!
//! Each run also appends `{"run_dir", "proof"}` to
//! `units/<n>/review-history.jsonl`, so the driver can tell one pass from the
//! next; `review-proof.json` holds only the newest. A unit writes the run
//! folder itself, so the history is as trusted as the proof: the unit's word.
//!
//! Exit: 0 written; 3 no reviewer folder or no reviewer in it; 2 bad
//! arguments; 1 the filesystem failed.

use std::collections::BTreeSet;
use std::fs::{self, OpenOptions};
use std::io::Write as _;
use std::path::{Path, PathBuf};

use serde_json::json;

use crate::ctx::{Ctx, write_json};
use crate::error::{Fail, Res};
use crate::merge_gate::{Proof, Reviewer, is_sha};

#[derive(clap::Args)]
pub struct Args {
    /// The unit; its file is <run folder>/units/<n>/review-proof.json.
    #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
    unit: u64,
    /// The cross-review run folder (holds raw/).
    #[arg(long)]
    run_dir: PathBuf,
    /// The commit that was reviewed, in full.
    #[arg(long)]
    head: String,
}

/// Codex's output shorter than this many non-whitespace bytes is not a review.
const CODEX_MIN_BYTES: usize = 200;

/// The reviewer a file in `raw/` belongs to, or `None` for a file that is not
/// one reviewer's own output.
fn reviewer_of(file: &str) -> Option<&str> {
    if file.contains(".attempt") || file.contains(".primary-failed") {
        return None;
    }
    let name = file
        .strip_suffix(".stdout")
        .or_else(|| file.strip_suffix(".meta.json"))?;
    // Run-level records share the folder when the reviewers' files are at its root.
    (!name.is_empty() && !matches!(name, "run" | "context.files")).then_some(name)
}

/// Whether `stdout` is output for the reviewer `name`: not blank, and for the
/// codex baseline at least `CODEX_MIN_BYTES` non-blank bytes.
fn has_output(name: &str, stdout: &[u8]) -> bool {
    let floor = if name.eq_ignore_ascii_case("codex") {
        CODEX_MIN_BYTES
    } else {
        1
    };
    stdout.iter().filter(|b| !b.is_ascii_whitespace()).count() >= floor
}

/// The finding lines of codex's last review block, and how many are P0 or P1.
/// `None` when the output has no `Full review comments:` or `Review comment:`
/// line, or none of the `- [Pn]` lines after the last one.
pub(crate) fn codex_findings(stdout: &str) -> Option<(Vec<String>, u64)> {
    let lines: Vec<&str> = stdout.lines().collect();
    let start = lines
        .iter()
        .rposition(|l| matches!(l.trim(), "Full review comments:" | "Review comment:"))?;
    let findings: Vec<String> = lines[start + 1..]
        .iter()
        .map(|l| l.trim())
        .filter(|l| severity(l).is_some())
        .map(str::to_string)
        .collect();
    if findings.is_empty() {
        return None;
    }
    let blocking = findings.iter().filter(|l| severity(l).is_some_and(|p| p <= 1)).count() as u64;
    Some((findings, blocking))
}

/// The `n` of a `- [Pn] ...` finding line.
fn severity(line: &str) -> Option<u8> {
    let rest = line.strip_prefix("- [P")?;
    let (digit, after) = rest.split_at_checked(1)?;
    let n = digit.parse::<u8>().ok()?;
    after.starts_with(']').then_some(n)
}

/// The run folder's own record of the reviewed commit. `Ok(None)` when there is
/// no `context.json`; `Err` when it is there and unreadable or names no head.
fn context_head(run_dir: &Path) -> Result<Option<String>, String> {
    let path = run_dir.join("context.json");
    if !path.exists() {
        return Ok(None);
    }
    let text = fs::read_to_string(&path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    let value: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("{} is not JSON: {e}", path.display()))?;
    match value.get("head_sha").and_then(serde_json::Value::as_str) {
        Some(head) if is_sha(head) => Ok(Some(head.to_string())),
        _ => Err(format!("{} has no usable head_sha", path.display())),
    }
}

/// The string `failure_kind` of a meta file, if it has one.
fn failure_kind(meta: &str) -> Option<String> {
    let value: serde_json::Value = serde_json::from_str(meta).ok()?;
    value.get("failure_kind")?.as_str().map(str::to_string)
}

/// Whether a meta file says the reviewer ran to the end: `exit_code` is 0, it
/// did not time out, and `failure_kind` is null. A reviewer can print a page
/// and then die on its quota, so output alone proves nothing. Anything the file
/// does not say is not success.
fn succeeded(meta: &str) -> bool {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(meta) else {
        return false;
    };
    value.get("exit_code").and_then(serde_json::Value::as_i64) == Some(0)
        && value.get("timed_out").is_none_or(|t| t.as_bool() == Some(false))
        && value.get("failure_kind").is_none_or(serde_json::Value::is_null)
}

/// The folder the reviewers' files are in: `raw/` when the run has one, else
/// the run folder itself, where cross-review's rewritten-history procedure
/// (`--out "$run_dir"`) leaves them.
fn reviewer_dir(run_dir: &Path) -> PathBuf {
    let raw = run_dir.join("raw");
    if raw.exists() { raw } else { run_dir.to_path_buf() }
}

pub fn run(ctx: &Ctx, args: &Args) -> Res<()> {
    if !is_sha(&args.head) {
        return Err(Fail::usage(format!(
            "--head must be a full 40 or 64 digit commit SHA (got '{}')",
            args.head
        )));
    }
    match context_head(&args.run_dir) {
        Ok(Some(reviewed)) if !reviewed.eq_ignore_ascii_case(&args.head) => {
            return Err(Fail::refused(format!(
                "the run folder's context.json says the reviewers read head {reviewed}, not {}; \
                 run the review at this head, or pass the head it recorded",
                args.head
            )));
        }
        Ok(_) => {}
        Err(what) => return Err(Fail::refused(what)),
    }
    let raw = reviewer_dir(&args.run_dir);
    let entries = fs::read_dir(&raw).map_err(|e| Fail::refused(format!("cannot read {}: {e}", raw.display())))?;
    let names: BTreeSet<String> = entries
        .flatten()
        .filter_map(|entry| reviewer_of(&entry.file_name().to_string_lossy()).map(str::to_string))
        .collect();
    if names.is_empty() {
        return Err(Fail::refused(format!("no reviewer output in {}", raw.display())));
    }
    let reviewers: Vec<Reviewer> = names
        .into_iter()
        .map(|name| {
            let meta = fs::read_to_string(raw.join(format!("{name}.meta.json"))).ok();
            let stdout = fs::read(raw.join(format!("{name}.stdout"))).ok();
            // Non-blank output AND a meta file that says the run succeeded.
            let output = meta.as_deref().is_some_and(succeeded)
                && stdout.as_deref().is_some_and(|bytes| has_output(&name, bytes));
            let parsed = (output && name.eq_ignore_ascii_case("codex"))
                .then(|| {
                    stdout
                        .as_deref()
                        .and_then(|b| codex_findings(&String::from_utf8_lossy(b)))
                })
                .flatten();
            Reviewer {
                has_output: output,
                failure_kind: meta.as_deref().and_then(failure_kind),
                findings: parsed.as_ref().map(|(f, _)| f.clone()),
                blocking: parsed.map(|(_, b)| b),
                name,
            }
        })
        .collect();
    let unit = args.unit;
    let proof = Proof {
        head: args.head.clone(),
        reviewers,
    };
    write_json(&ctx.path(&format!("units/{unit}/review-proof.json")), &proof)?;
    let run_dir = fs::canonicalize(&args.run_dir).unwrap_or_else(|_| args.run_dir.clone());
    append_history(
        &ctx.path(&format!("units/{unit}/review-history.jsonl")),
        &json!({"run_dir": run_dir.to_string_lossy(), "proof": proof}),
    )?;
    let with_output: Vec<&str> = proof
        .reviewers
        .iter()
        .filter(|r| r.has_output)
        .map(|r| r.name.as_str())
        .collect();
    if let Err(e) = ctx.event(
        "review_proof",
        json!({"unit": unit, "head": proof.head, "reviewers": with_output}),
    ) {
        eprintln!("issue-drain: warning: the review proof was not logged: {}", e.msg);
    }
    println!("{}", json!(proof));
    Ok(())
}

/// Append one line to a unit's review history.
fn append_history(path: &Path, line: &serde_json::Value) -> Res<()> {
    let append = || -> std::io::Result<()> {
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        let mut f = OpenOptions::new().create(true).append(true).open(path)?;
        writeln!(f, "{line}")
    };
    append().map_err(|e| Fail::failed(format!("cannot write {}: {e}", path.display())))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codex_findings_come_from_the_last_review_block() {
        let out = "codex\nthinking...\nFull review comments:\n\n- [P1] old one — a.rs:1\n  body\n\
                   codex\nFull review comments:\n\n- [P2] Keep the head — src/a.rs:10-12\n  body text\n\
                   - [P1] Refuse the stale proof — src/b.rs:4\n  more\n- [P3] nit — c.rs:1\n";
        let (found, blocking) = codex_findings(out).expect("parsed");
        assert_eq!(
            found,
            [
                "- [P2] Keep the head — src/a.rs:10-12",
                "- [P1] Refuse the stale proof — src/b.rs:4",
                "- [P3] nit — c.rs:1"
            ]
        );
        assert_eq!(blocking, 1);
    }

    #[test]
    fn a_single_finding_block_is_read_and_p0_blocks() {
        let out = "codex\nReview comment:\n\n- [P0] Data loss — x.rs:3\n  body\n";
        assert_eq!(
            codex_findings(out),
            Some((vec!["- [P0] Data loss — x.rs:3".to_string()], 1))
        );
        let out = "codex\nReview comment:\n\n- [P2] Minor — x.rs:3\n";
        assert_eq!(codex_findings(out).map(|(_, b)| b), Some(0));
    }

    #[test]
    fn a_review_with_no_block_or_no_finding_line_is_not_weighed() {
        assert_eq!(
            codex_findings("codex\nI found no discrete issues in this diff.\n"),
            None
        );
        assert_eq!(codex_findings("codex\nFull review comments:\n\nnothing listed\n"), None);
        assert_eq!(codex_findings(""), None);
        // A line that only looks like a finding is not one.
        assert_eq!(codex_findings("Review comment:\n- [Px] no — a\n- [P12] no — b\n"), None);
    }

    #[test]
    fn a_reviewer_is_named_by_its_stdout_or_meta_file() {
        assert_eq!(reviewer_of("codex.stdout"), Some("codex"));
        assert_eq!(reviewer_of("kimi.meta.json"), Some("kimi"));
        assert_eq!(reviewer_of("codex.stderr"), None);
        assert_eq!(reviewer_of(".stdout"), None);
    }

    #[test]
    fn run_level_records_are_not_reviewers() {
        assert_eq!(reviewer_of("run.meta.json"), None);
        assert_eq!(reviewer_of("context.files.meta.json"), None);
    }

    #[test]
    fn success_needs_exit_0_no_timeout_and_a_null_failure_kind() {
        assert!(succeeded(
            r#"{"exit_code": 0, "timed_out": false, "failure_kind": null}"#
        ));
        assert!(succeeded(r#"{"exit_code": 0}"#));
        for bad in [
            r#"{"exit_code": 1}"#,
            r#"{"exit_code": "0"}"#,
            r#"{"exit_code": 0, "timed_out": true}"#,
            r#"{"exit_code": 0, "failure_kind": "quota_exhausted"}"#,
            r#"{"exit_code": 0, "failure_kind": 3}"#,
            r#"{"failure_kind": null}"#,
            "{}",
            "not json",
            "",
        ] {
            assert!(!succeeded(bad), "{bad}");
        }
    }

    #[test]
    fn retries_and_failed_primaries_are_not_reviewers() {
        assert_eq!(reviewer_of("codex.attempt2.stdout"), None);
        assert_eq!(reviewer_of("gemini.primary-failed.meta.json"), None);
        assert_eq!(reviewer_of("gemini.attempt1.meta.json"), None);
    }

    #[test]
    fn codex_is_codex_whatever_the_case_of_its_file_name() {
        // merge-gate matches the name with eq_ignore_ascii_case, so the floor does too.
        for name in ["codex", "Codex", "CODEX"] {
            assert!(!has_output(name, b"{\"findings\":[]}"), "{name}");
            assert!(has_output(name, "x".repeat(CODEX_MIN_BYTES).as_bytes()), "{name}");
        }
        assert!(has_output("kimi", b"{\"findings\":[]}"));
    }

    #[test]
    fn codex_needs_the_floor_in_non_whitespace_bytes_and_the_rest_need_any() {
        assert!(has_output("codex", "x".repeat(CODEX_MIN_BYTES).as_bytes()));
        assert!(!has_output("codex", "x".repeat(CODEX_MIN_BYTES - 1).as_bytes()));
        let padded = format!("{}{}", "x ".repeat(CODEX_MIN_BYTES - 1), " \n\t".repeat(500));
        assert!(!has_output("codex", padded.as_bytes()));
        assert!(!has_output("codex", b""));
        assert!(has_output("kimi", br#"{"findings":[]}"#));
        assert!(!has_output("kimi", b" \n\t"));
        assert!(!has_output("kimi", b""));
    }

    #[test]
    fn a_context_head_is_read_only_from_a_usable_file() {
        let dir = tempfile::tempdir().expect("a folder");
        assert_eq!(context_head(dir.path()), Ok(None));
        let head = "a".repeat(40);
        fs::write(dir.path().join("context.json"), format!(r#"{{"head_sha":"{head}"}}"#)).expect("file");
        assert_eq!(context_head(dir.path()), Ok(Some(head)));
        fs::write(dir.path().join("context.json"), "{}").expect("file");
        assert!(context_head(dir.path()).is_err());
    }

    #[test]
    fn a_failure_kind_must_be_a_string() {
        assert_eq!(
            failure_kind(r#"{"failure_kind":"timeout"}"#).as_deref(),
            Some("timeout")
        );
        assert_eq!(failure_kind(r#"{"failure_kind":null}"#), None);
        assert_eq!(failure_kind(r#"{"failure_kind":3}"#), None);
        assert_eq!(failure_kind("not json"), None);
        assert_eq!(failure_kind("{}"), None);
    }
}
