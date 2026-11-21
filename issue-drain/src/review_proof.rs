//! `issue-drain review-proof --unit <n> --run-dir <path> --head <sha>`: read
//! one cross-review run folder and write `units/<n>/review-proof.json`, the
//! file `merge-gate` reads. This records who produced output; merge-gate
//! judges it.
//!
//! A run folder holds `raw/<reviewer>.stdout` and `raw/<reviewer>.meta.json`.
//!
//! Exit: 0 written; 3 no `raw/` folder or no reviewer in it; 2 bad arguments;
//! 1 the filesystem failed.

use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;

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
    (!name.is_empty()).then_some(name)
}

fn has_output(stdout: &[u8]) -> bool {
    stdout.iter().filter(|b| !b.is_ascii_whitespace()).count() >= MIN_OUTPUT_BYTES
}

/// The string `failure_kind` of a meta file, if it has one.
fn failure_kind(meta: &str) -> Option<String> {
    let value: serde_json::Value = serde_json::from_str(meta).ok()?;
    value.get("failure_kind")?.as_str().map(str::to_string)
}

pub fn run(ctx: &Ctx, args: &Args) -> Res<()> {
    if !is_sha(&args.head) {
        return Err(Fail::usage(format!(
            "--head must be a full 40 or 64 digit commit SHA (got '{}')",
            args.head
        )));
    }
    let raw = args.run_dir.join("raw");
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
        .map(|name| Reviewer {
            has_output: fs::read(raw.join(format!("{name}.stdout"))).is_ok_and(|bytes| has_output(&bytes)),
            failure_kind: fs::read_to_string(raw.join(format!("{name}.meta.json")))
                .ok()
                .and_then(|meta| failure_kind(&meta)),
            name,
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
