//! `issue-drain review-proof`: a cross-review run folder in, the proof file
//! out.

use std::fs;
use std::path::{Path, PathBuf};

use issue_drain::ctx::read_json;
use issue_drain::merge_gate::Proof;
use serde_json::json;

use crate::common::*;

const HEAD: &str = "0123456789abcdef0123456789abcdef01234567";

fn review() -> String {
    "a finding about the change. ".repeat(20)
}

/// A run folder under the test's folder with the given `raw/` files.
fn run_dir(env: &Env, files: &[(&str, &str)]) -> PathBuf {
    let dir = env.dir.path().join("cr-run");
    fs::create_dir_all(dir.join("raw")).expect("raw/");
    for (name, text) in files {
        fs::write(dir.join("raw").join(name), text).expect("a raw file");
    }
    dir
}

fn prove(env: &Env, dir: &Path, head: &str) -> Out {
    env.run(&[
        "review-proof",
        "--unit",
        "3",
        "--run-dir",
        &dir.display().to_string(),
        "--head",
        head,
    ])
}

fn proof_file(env: &Env) -> serde_json::Value {
    json(&env.workdir.join("units/3/review-proof.json"))
}

#[test]
fn each_reviewer_is_recorded_with_its_output_and_failure_kind() {
    let env = Env::new();
    let text = review();
    let dir = run_dir(
        &env,
        &[
            ("codex.stdout", &text),
            ("codex.meta.json", r#"{"failure_kind": null}"#),
            ("kimi.stdout", "short"),
            ("kimi.meta.json", r#"{"failure_kind": "timeout"}"#),
            ("gemini.meta.json", "{}"),
        ],
    );
    let out = prove(&env, &dir, HEAD);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        proof_file(&env),
        json!({"head": HEAD, "reviewers": [
            {"name": "codex", "has_output": true, "failure_kind": null},
            {"name": "gemini", "has_output": false, "failure_kind": null},
            {"name": "kimi", "has_output": false, "failure_kind": "timeout"},
        ]})
    );
    assert_eq!(env.events_named("review_proof").len(), 1);
}

#[test]
fn retries_and_failed_primaries_are_not_listed() {
    let env = Env::new();
    let text = review();
    let dir = run_dir(
        &env,
        &[
            ("codex.stdout", &text),
            ("codex.attempt1.stdout", &text),
            ("kimi.primary-failed.meta.json", "{}"),
            ("kimi.stderr", &text),
        ],
    );
    assert_eq!(prove(&env, &dir, HEAD).code, 0);
    let names: Vec<_> = proof_file(&env)["reviewers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["name"].clone())
        .collect();
    assert_eq!(names, [json!("codex")]);
}

#[test]
fn output_below_the_floor_counts_whitespace_for_nothing() {
    let env = Env::new();
    let thin = format!("{}{}", "x".repeat(199), " \n".repeat(400));
    let edge = "x".repeat(200);
    let dir = run_dir(&env, &[("thin.stdout", &thin), ("edge.stdout", &edge)]);
    assert_eq!(prove(&env, &dir, HEAD).code, 0);
    let proof = proof_file(&env);
    assert_eq!(proof["reviewers"][0]["name"], "edge");
    assert_eq!(proof["reviewers"][0]["has_output"], true);
    assert_eq!(proof["reviewers"][1]["has_output"], false);
}

#[test]
fn a_run_folder_without_raw_is_refused() {
    let env = Env::new();
    let dir = env.dir.path().join("empty-run");
    fs::create_dir_all(&dir).expect("the folder");
    let out = prove(&env, &dir, HEAD);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(!env.workdir.join("units/3/review-proof.json").exists());
}

#[test]
fn a_raw_folder_with_no_reviewer_is_refused() {
    let env = Env::new();
    let dir = run_dir(&env, &[("codex.attempt1.stdout", &review()), ("notes.txt", "x")]);
    let out = prove(&env, &dir, HEAD);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("no reviewer"), "{}", out.stderr);
}

#[test]
fn a_head_that_is_not_a_full_sha_is_a_usage_error() {
    let env = Env::new();
    let dir = run_dir(&env, &[("codex.stdout", &review())]);
    for head in ["0123abc", "HEAD", &"g".repeat(40)] {
        assert_eq!(prove(&env, &dir, head).code, 2, "{head}");
    }
    assert_eq!(prove(&env, &dir, &"a".repeat(64)).code, 0);
}

#[test]
fn merge_gate_reads_what_review_proof_wrote() {
    let env = Env::new();
    let dir = run_dir(
        &env,
        &[
            ("codex.stdout", &review()),
            ("kimi.meta.json", r#"{"failure_kind":"quota"}"#),
        ],
    );
    assert_eq!(prove(&env, &dir, HEAD).code, 0);
    let read: Proof = read_json(&env.workdir.join("units/3/review-proof.json")).expect("merge-gate's shape");
    assert_eq!(read.head, HEAD);
    assert_eq!(read.reviewers.len(), 2);
    assert!(read.reviewers[0].has_output);
    assert_eq!(read.reviewers[1].failure_kind.as_deref(), Some("quota"));
}
