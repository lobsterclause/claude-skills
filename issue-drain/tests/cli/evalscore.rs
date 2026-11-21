//! `issue-drain eval-score`: a triage run scored against the fixture's
//! expected answers.

use serde_json::Value;

use crate::common::*;

fn expected() -> String {
    eval_fixtures().join("expected.json").display().to_string()
}

fn score(out: &Out) -> Value {
    serde_json::from_str(&out.stdout).unwrap_or_else(|e| panic!("stdout is not JSON ({e}): {}", out.stdout))
}

/// The golden verdicts with one issue's fields overwritten, as a file in the run folder.
fn with_change(env: &Env, number: u64, change: &[(&str, Value)]) -> String {
    let mut verdicts = golden("verdicts.checked.json");
    let rows = verdicts.as_array_mut().expect("an array");
    let row = rows.iter_mut().find(|r| r["number"] == number).expect("the issue");
    for (key, value) in change {
        row[*key] = value.clone();
    }
    env.write("changed.json", &verdicts.to_string()).display().to_string()
}

#[test]
fn the_reference_run_scores_clean() {
    let env = Env::new();
    env.seed(&["verdicts.checked.json"]);
    let out = env.run(&["eval-score", "--expected", &expected()]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let s = score(&out);
    assert_eq!(s["issues"], 12);
    assert_eq!(s["correct"], 12);
    assert_eq!(s["mismatches"], serde_json::json!([]));
    assert_eq!(s["false_closable"], serde_json::json!([]));
    assert_eq!(s["already_fixed"]["expected"], 2);
    assert_eq!(s["already_fixed"]["returned"], 2);
    assert_eq!(s["already_fixed"]["precision"], 1.0);
    assert_eq!(s["already_fixed"]["recall"], 1.0);
    assert_eq!(env.events_named("eval_score")[0]["correct"], 12);
}

#[test]
fn a_live_issue_called_fixed_is_a_miss_and_a_false_closure() {
    let env = Env::new();
    let changed = with_change(
        &env,
        103,
        &[("status", "already_fixed".into()), ("closable", true.into())],
    );
    let out = env.run(&["eval-score", "--expected", &expected(), "--in", &changed]);
    assert_eq!(out.code, 1);
    assert!(out.stderr.contains("1 of 12 issues scored wrong"), "{}", out.stderr);
    let s = score(&out);
    assert_eq!(s["correct"], 11);
    assert_eq!(s["false_closable"], serde_json::json!([103]));
    assert_eq!(s["already_fixed"]["returned"], 3);
    assert_eq!(s["already_fixed"]["true_positive"], 2);
    assert_eq!(s["already_fixed"]["recall"], 1.0);
    let miss = &s["mismatches"][0];
    assert_eq!(miss["number"], 103);
    assert_eq!(miss["field"], "status");
    assert_eq!(miss["got"], "already_fixed");
}

#[test]
fn a_missed_fix_lowers_recall() {
    let env = Env::new();
    let changed = with_change(&env, 101, &[("status", "live".into()), ("closable", false.into())]);
    let out = env.run(&["eval-score", "--expected", &expected(), "--in", &changed]);
    assert_eq!(out.code, 1);
    let s = score(&out);
    assert_eq!(s["already_fixed"]["returned"], 1);
    assert_eq!(s["already_fixed"]["precision"], 1.0);
    assert_eq!(s["already_fixed"]["recall"], 0.5);
}

#[test]
fn each_expected_field_is_held() {
    let env = Env::new();
    let cases: [(u64, &str, Value); 3] = [
        (106, "duplicate_of", 104.into()),
        (108, "risk", false.into()),
        (102, "closable", true.into()),
    ];
    for (number, field, value) in cases {
        let changed = with_change(&env, number, &[(field, value)]);
        let out = env.run(&["eval-score", "--expected", &expected(), "--in", &changed]);
        assert_eq!(out.code, 1, "{field}");
        let s = score(&out);
        assert_eq!(s["mismatches"][0]["number"], number, "{field}");
        assert_eq!(s["mismatches"][0]["field"], field);
    }
}

#[test]
fn an_acceptable_second_answer_scores() {
    let env = Env::new();
    let changed = with_change(&env, 110, &[("status", "needs_human".into())]);
    let out = env.run(&["eval-score", "--expected", &expected(), "--in", &changed]);
    assert_eq!(out.code, 0, "{}", out.stderr);
}

#[test]
fn an_issue_with_no_verdict_is_a_miss() {
    let env = Env::new();
    let mut verdicts = golden("verdicts.checked.json");
    verdicts
        .as_array_mut()
        .expect("an array")
        .retain(|r| r["number"] != 111);
    let short = env.write("short.json", &verdicts.to_string()).display().to_string();
    let out = env.run(&["eval-score", "--expected", &expected(), "--in", &short]);
    assert_eq!(out.code, 1);
    let s = score(&out);
    assert_eq!(s["mismatches"][0]["number"], 111);
    assert_eq!(s["mismatches"][0]["got"], Value::Null);
}

#[test]
fn missing_or_malformed_input_is_a_usage_error() {
    let env = Env::new();
    env.seed(&["verdicts.checked.json"]);
    assert_eq!(env.run(&["eval-score"]).code, 2);
    assert_eq!(env.run(&["eval-score", "--expected", "/nonexistent.json"]).code, 2);
    let bad = env.write("bad.json", "[{\"number\": 1, \"statuses\": []}]");
    assert_eq!(
        env.run(&["eval-score", "--expected", &bad.display().to_string()]).code,
        2
    );
    let none = Env::new();
    assert_eq!(none.run(&["eval-score", "--expected", &expected()]).code, 2);
}
