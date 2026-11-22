//! CLI tests for `overlap`. The harness is in common.rs. Each refusal or
//! cap has a control beside it that passes.

use crate::common::*;
use serde_json::{Value, json};

fn v(number: u64, status: &str, files: &[&str], symbols: &[&str], size: &str) -> Value {
    json!({"number": number, "status": status, "files": files, "symbols": symbols, "size": size,
           "change_kind": "bugfix", "pattern": "", "risk": false, "duplicate_of": null})
}

fn overlap_of(items: Vec<Value>) -> Value {
    let env = Env::new();
    env.write("verdicts.checked.json", &Value::Array(items).to_string());
    let out = env.run(&["overlap"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    json(&env.workdir.join("overlap.json"))
}

#[test]
fn matches_the_reference_run() {
    let env = Env::new();
    env.seed(&["verdicts.checked.json", "intake.json"]);
    let out = env.run(&["overlap"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(json(&env.workdir.join("overlap.json")), golden("overlap.json"));
    let ev = env.events_named("overlap");
    assert_eq!(ev.len(), 1);
    assert_eq!(ev[0]["pairs"], 2);
    assert_eq!(ev[0]["groups"], 2);
    assert_eq!(ev[0]["singles"], 2);
    assert!(out.stdout.contains("group #103 #106"), "{}", out.stdout);
}

#[test]
fn issues_sharing_no_file_are_singles() {
    let o = overlap_of(vec![
        v(1, "live", &["a.ts"], &["f"], "S"),
        v(2, "live", &["b.ts"], &["f"], "S"),
    ]);
    assert_eq!(o["pairs"], json!([]));
    assert_eq!(o["singles"], json!([1, 2]));
    // control: the same symbol plus a shared file groups
    let o = overlap_of(vec![
        v(1, "live", &["a.ts"], &["f"], "S"),
        v(2, "live", &["a.ts"], &["f"], "S"),
    ]);
    assert_eq!(o["groups"][0]["issues"], json!([1, 2]));
}

#[test]
fn a_shared_file_alone_is_only_adjacent() {
    let o = overlap_of(vec![
        v(1, "live", &["a.ts"], &["f"], "S"),
        v(2, "live", &["a.ts"], &["g"], "S"),
    ]);
    assert_eq!(o["pairs"][0]["relation"], "adjacent");
    assert_eq!(o["groups"], json!([]));
    assert_eq!(o["singles"], json!([1, 2]));
}

#[test]
fn a_folder_covers_the_files_under_it() {
    let o = overlap_of(vec![
        v(1, "live", &["src/timer/"], &["f"], "S"),
        v(2, "live", &["src/timer/countdown.ts"], &["f"], "S"),
        v(3, "live", &["src/timer2/x.ts"], &["g"], "S"),
    ]);
    assert_eq!(o["pairs"][0]["shared_files"], json!(["src/timer/countdown.ts"]));
    assert_eq!(o["pairs"].as_array().expect("pairs").len(), 1);
    assert_eq!(o["groups"][0]["issues"], json!([1, 2]));
}

#[test]
fn only_live_and_duplicate_issues_take_part() {
    let o = overlap_of(vec![
        v(1, "live", &["a.ts"], &["f"], "S"),
        v(2, "already_fixed", &["a.ts"], &["f"], "S"),
        v(3, "needs_human", &["a.ts"], &["f"], "S"),
        v(4, "unclear", &["a.ts"], &["f"], "S"),
    ]);
    assert_eq!(o["pairs"], json!([]));
    assert_eq!(o["singles"], json!([1]));
    // control: a duplicate_of does take part
    let mut d = v(5, "duplicate_of", &["a.ts"], &["f"], "S");
    d["duplicate_of"] = json!(1);
    let o = overlap_of(vec![v(1, "live", &["a.ts"], &["f"], "S"), d]);
    assert_eq!(o["pairs"][0]["relation"], "duplicate");
    assert_eq!(o["groups"][0]["live"], json!([1]));
    assert_eq!(o["groups"][0]["est_lines"], 50);
}

#[test]
fn a_risk_issue_is_not_offered_for_a_cluster() {
    let mut r = v(2, "live", &["a.ts"], &["f"], "S");
    r["risk"] = json!(true);
    let o = overlap_of(vec![v(1, "live", &["a.ts"], &["f"], "S"), r]);
    assert_eq!(o["pairs"][0]["relation"], "adjacent");
    assert_eq!(o["pairs"][0]["note"], "on a risk path, so not offered for a cluster");
    assert_eq!(o["groups"], json!([]));
}

#[test]
fn an_xl_or_unsized_issue_is_not_offered_for_a_cluster() {
    for size in ["XL", ""] {
        let o = overlap_of(vec![
            v(1, "live", &["a.ts"], &["f"], "S"),
            v(2, "live", &["a.ts"], &["f"], size),
        ]);
        assert_eq!(o["pairs"][0]["relation"], "adjacent", "size {size:?}");
        assert_eq!(o["groups"], json!([]));
    }
}

#[test]
fn the_same_mechanical_pattern_clusters_without_a_shared_file() {
    let mk = |n: u64, f: &str, pat: &str| {
        let mut x = v(n, "live", &[f], &[], "S");
        x["change_kind"] = json!("mechanical");
        x["pattern"] = json!(pat);
        x
    };
    let o = overlap_of(vec![mk(1, "a.ts", "rename foo"), mk(2, "b.ts", "rename foo")]);
    assert_eq!(o["pairs"][0]["relation"], "cluster_candidate");
    assert_eq!(o["pairs"][0]["note"], "same mechanical pattern: rename foo");
    // control: a different pattern does not
    let o = overlap_of(vec![mk(1, "a.ts", "rename foo"), mk(2, "b.ts", "rename bar")]);
    assert_eq!(o["pairs"], json!([]));
}

#[test]
fn a_chain_is_one_group() {
    let o = overlap_of(vec![
        v(3, "live", &["a.ts", "b.ts"], &["f", "g"], "S"),
        v(1, "live", &["a.ts"], &["f"], "S"),
        v(2, "live", &["b.ts"], &["g"], "S"),
    ]);
    assert_eq!(o["groups"][0]["issues"], json!([1, 2, 3]));
    assert_eq!(o["groups"][0]["files"], json!(["a.ts", "b.ts"]));
}

/// The spec flags a group past a cap; it does not split it. The tidepool
/// profile caps at 4 issues and 400 lines.
#[test]
fn a_group_past_the_issue_cap_says_so() {
    let n = |count: u64| {
        (1..=count)
            .map(|i| v(i, "live", &["a.ts"], &["f"], "S"))
            .collect::<Vec<_>>()
    };
    let o = overlap_of(n(5));
    assert_eq!(o["groups"][0]["over_cap"], true);
    assert_eq!(o["groups"][0]["over_lines"], false);
    // control: exactly the cap is not over
    let o = overlap_of(n(4));
    assert_eq!(o["groups"][0]["over_cap"], false);
}

#[test]
fn a_group_past_the_line_cap_says_so() {
    let two = |size: &str| {
        vec![
            v(1, "live", &["a.ts"], &["f"], size),
            v(2, "live", &["a.ts"], &["f"], size),
        ]
    };
    let o = overlap_of(two("L"));
    assert_eq!(o["groups"][0]["est_lines"], 800);
    assert_eq!(o["groups"][0]["over_lines"], true);
    // control: 2 x M = 300 is under 400
    let o = overlap_of(two("M"));
    assert_eq!(o["groups"][0]["est_lines"], 300);
    assert_eq!(o["groups"][0]["over_lines"], false);
}

#[test]
fn missing_or_malformed_input_exits_2() {
    let env = Env::new();
    let out = env.run(&["overlap"]);
    assert_eq!(out.code, 2, "{}", out.stderr);
    env.write("verdicts.checked.json", "{\"not\": \"an array\"}");
    assert_eq!(env.run(&["overlap"]).code, 2);
    env.write("verdicts.checked.json", "[oops");
    assert_eq!(env.run(&["overlap"]).code, 2);
    assert!(env.events_named("overlap").is_empty());
    // control
    env.write("verdicts.checked.json", "[]");
    assert_eq!(env.run(&["overlap"]).code, 0);
}

#[test]
fn in_and_out_flags_are_honoured() {
    let env = Env::new();
    let input = env.write("other.json", "[]");
    let out_path = env.workdir.join("mine.json");
    let out = env.run(&[
        "overlap",
        "--in",
        &input.display().to_string(),
        "--out",
        &out_path.display().to_string(),
    ]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(json(&out_path), json!({"pairs": [], "groups": [], "singles": []}));
    assert_eq!(env.run(&["overlap", "--bogus"]).code, 2);
}
