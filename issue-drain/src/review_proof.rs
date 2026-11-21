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
//! A reviewer has output only when its stdout is substantive (200 non-blank
//! bytes) AND its meta file shows it succeeded (`exit_code` 0, not timed out,
//! `failure_kind` null). A reviewer that printed a page and then died on its
//! quota has none, and one with no meta file is not proven. `failure_kind` is
//! recorded as the meta has it.
//!
//! Exit: 0 written; 3 no reviewer folder or no reviewer in it; 2 bad
//! arguments; 1 the filesystem failed.

use std::collections::BTreeSet;
use std::fs;
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

/// Output shorter than this many non-whitespace bytes is not a review.
const MIN_OUTPUT_BYTES: usize = 200;

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

fn has_output(stdout: &[u8]) -> bool {
    stdout.iter().filter(|b| !b.is_ascii_whitespace()).count() >= MIN_OUTPUT_BYTES
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
    // shortcut: nothing in a reviewer's meta or in the run folder names the commit that was reviewed (run.meta.json is written only for a skipped run, and the repeat-pass guard keeps its record elsewhere), so a reused run folder with stale reviewer files cannot be told from a fresh one; `--head` is taken on the caller's word. Add a head check here if cross-review ever stamps one.
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
            Reviewer {
                // Substantive output AND a meta file that says the run succeeded.
                has_output: meta.as_deref().is_some_and(succeeded)
                    && fs::read(raw.join(format!("{name}.stdout"))).is_ok_and(|bytes| has_output(&bytes)),
                failure_kind: meta.as_deref().and_then(failure_kind),
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

#[cfg(test)]
mod tests {
    use super::*;

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
    fn output_counts_only_non_whitespace_bytes() {
        assert!(has_output("x".repeat(MIN_OUTPUT_BYTES).as_bytes()));
        assert!(!has_output("x".repeat(MIN_OUTPUT_BYTES - 1).as_bytes()));
        let padded = format!("{}{}", "x ".repeat(MIN_OUTPUT_BYTES - 1), " \n\t".repeat(500));
        assert!(!has_output(padded.as_bytes()));
        assert!(!has_output(b""));
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
