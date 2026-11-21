//! `issue-drain review-proof`: a cross-review run folder in, the proof file
//! out.

use std::fs;
use std::path::{Path, PathBuf};

use issue_drain::ctx::read_json;
use issue_drain::merge_gate::Proof;
use serde_json::json;

use crate::common::*;

const HEAD: &str = "0123456789abcdef0123456789abcdef01234567";
/// What run_reviewers.sh writes for a reviewer that ran to the end.
const OK: &str = r#"{"exit_code": 0, "timed_out": false, "failure_kind": null}"#;

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

fn names(env: &Env) -> Vec<serde_json::Value> {
    proof_file(env)["reviewers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["name"].clone())
        .collect()
}

#[test]
fn each_reviewer_is_recorded_with_its_output_and_failure_kind() {
    let env = Env::new();
    let text = review();
    let dir = run_dir(
        &env,
        &[
            ("codex.stdout", &text),
            ("codex.meta.json", OK),
            ("kimi.stdout", "short"),
            ("kimi.meta.json", r#"{"exit_code": 1, "failure_kind": "timeout"}"#),
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
fn a_reviewer_that_printed_enough_and_then_failed_has_no_output() {
    let env = Env::new();
    let text = review();
    let dir = run_dir(
        &env,
        &[
            ("codex.stdout", &text),
            (
                "codex.meta.json",
                r#"{"exit_code": 0, "failure_kind": "quota_exhausted"}"#,
            ),
            ("kimi.stdout", &text),
            (
                "kimi.meta.json",
                r#"{"exit_code": 124, "timed_out": true, "failure_kind": null}"#,
            ),
            ("glm.stdout", &text),
            ("glm.meta.json", r#"{"exit_code": 1, "failure_kind": null}"#),
            ("agy.stdout", &text),
            ("agy.meta.json", r#"{"failure_kind": null}"#),
            ("mimo.stdout", &text),
            ("mimo.meta.json", "not json"),
        ],
    );
    assert_eq!(prove(&env, &dir, HEAD).code, 0);
    let proof = proof_file(&env);
    assert_eq!(proof["reviewers"].as_array().unwrap().len(), 5);
    for reviewer in proof["reviewers"].as_array().unwrap() {
        assert_eq!(reviewer["has_output"], false, "{reviewer}");
    }
    let codex = proof["reviewers"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["name"] == "codex")
        .expect("codex");
    assert_eq!(codex["failure_kind"], "quota_exhausted", "still recorded");
}

#[test]
fn a_reviewer_with_no_meta_file_is_not_proven() {
    let env = Env::new();
    let dir = run_dir(&env, &[("codex.stdout", &review())]);
    assert_eq!(prove(&env, &dir, HEAD).code, 0);
    assert_eq!(proof_file(&env)["reviewers"][0]["has_output"], false);
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
    assert_eq!(names(&env), [json!("codex")]);
}

#[test]
fn the_codex_baseline_needs_the_floor_and_whitespace_counts_for_nothing() {
    let env = Env::new();
    let thin = format!("{}{}", "x".repeat(199), " \n".repeat(400));
    let dir = run_dir(&env, &[("codex.stdout", &thin), ("codex.meta.json", OK)]);
    assert_eq!(prove(&env, &dir, HEAD).code, 0);
    assert_eq!(proof_file(&env)["reviewers"][0]["has_output"], false);
    let edge = "x".repeat(200);
    let dir = run_dir(&env, &[("codex.stdout", &edge), ("codex.meta.json", OK)]);
    assert_eq!(prove(&env, &dir, HEAD).code, 0);
    assert_eq!(proof_file(&env)["reviewers"][0]["has_output"], true);
}

/// cross-review accepts a short verdict from the other reviewers, such as an
/// empty findings array (`run_reviewers.sh`, `output_no_verdict`).
#[test]
fn another_reviewer_with_a_short_verdict_has_output_and_a_blank_one_has_none() {
    let env = Env::new();
    let dir = run_dir(
        &env,
        &[
            ("kimi.stdout", "{\"findings\":[]}"),
            ("kimi.meta.json", OK),
            ("glm.stdout", " \n\t "),
            ("glm.meta.json", OK),
            ("mimo.stdout", "LGTM"),
            ("mimo.meta.json", r#"{"exit_code": 1, "failure_kind": null}"#),
        ],
    );
    assert_eq!(prove(&env, &dir, HEAD).code, 0);
    let by_name = |n: &str| {
        proof_file(&env)["reviewers"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["name"] == n)
            .unwrap()["has_output"]
            .clone()
    };
    assert_eq!(by_name("kimi"), true);
    assert_eq!(by_name("glm"), false);
    assert_eq!(by_name("mimo"), false, "a failed run is no output however short");
}

#[test]
fn a_run_folder_whose_context_names_another_head_is_refused() {
    let env = Env::new();
    let dir = run_dir(&env, &[("codex.stdout", &review()), ("codex.meta.json", OK)]);
    let other = "b".repeat(40);
    fs::write(dir.join("context.json"), json!({"head_sha": other}).to_string()).expect("context.json");
    let out = prove(&env, &dir, HEAD);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(
        out.stderr.contains(&other) && out.stderr.contains("head"),
        "{}",
        out.stderr
    );
    assert!(!env.workdir.join("units/3/review-proof.json").exists());
    // The same folder with the matching head is the control.
    fs::write(dir.join("context.json"), json!({"head_sha": HEAD}).to_string()).expect("context.json");
    assert_eq!(prove(&env, &dir, HEAD).code, 0);
    assert_eq!(proof_file(&env)["head"], HEAD);
}

#[test]
fn an_unreadable_context_or_one_without_a_head_is_refused_and_a_missing_one_is_not() {
    let env = Env::new();
    let dir = run_dir(&env, &[("codex.stdout", &review()), ("codex.meta.json", OK)]);
    for bad in ["not json", "{}", r#"{"head_sha": 3}"#, r#"{"head_sha": ""}"#, ""] {
        fs::write(dir.join("context.json"), bad).expect("context.json");
        let out = prove(&env, &dir, HEAD);
        assert_eq!(out.code, 3, "{bad}: {}", out.stderr);
    }
    fs::remove_file(dir.join("context.json")).expect("remove");
    assert_eq!(prove(&env, &dir, HEAD).code, 0);
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

/// The rewritten-history procedure in cross-review's SKILL.md passes
/// `--out "$run_dir"`, so the reviewers' files sit at the run folder's root.
#[test]
fn reviewer_files_at_the_run_root_are_read_when_there_is_no_raw_folder() {
    let env = Env::new();
    let dir = env.dir.path().join("cr-root");
    fs::create_dir_all(&dir).expect("the folder");
    for (name, text) in [
        ("codex.stdout", review()),
        ("codex.meta.json", OK.to_string()),
        ("run.meta.json", r#"{"skipped": true}"#.to_string()),
        ("context.files.meta.json", "{}".to_string()),
    ] {
        fs::write(dir.join(name), text).expect("a file");
    }
    let out = prove(&env, &dir, HEAD);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        proof_file(&env),
        json!({"head": HEAD, "reviewers": [{"name": "codex", "has_output": true, "failure_kind": null}]})
    );
}

#[test]
fn a_raw_folder_is_read_instead_of_files_at_the_root() {
    let env = Env::new();
    let dir = run_dir(&env, &[("kimi.stdout", &review()), ("kimi.meta.json", OK)]);
    fs::write(dir.join("codex.stdout"), review()).expect("a stale root file");
    fs::write(dir.join("codex.meta.json"), OK).expect("a stale root file");
    assert_eq!(prove(&env, &dir, HEAD).code, 0);
    assert_eq!(names(&env), [json!("kimi")]);
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
            ("codex.meta.json", OK),
            ("kimi.meta.json", r#"{"exit_code": 3, "failure_kind":"quota"}"#),
        ],
    );
    assert_eq!(prove(&env, &dir, HEAD).code, 0);
    let read: Proof = read_json(&env.workdir.join("units/3/review-proof.json")).expect("merge-gate's shape");
    assert_eq!(read.head, HEAD);
    assert_eq!(read.reviewers.len(), 2);
    assert!(read.reviewers[0].has_output);
    assert_eq!(read.reviewers[1].failure_kind.as_deref(), Some("quota"));
}
