//! `issue-drain merge-gate`. `ready` is a PR that every condition lets
//! through; each refusal below changes one thing about it and has the merge
//! test beside it as its control.

use std::fs;
use std::os::unix::fs::PermissionsExt;

use serde_json::{Value, json};

use crate::common::*;

const HEAD: &str = "0123456789abcdef0123456789abcdef01234567";
const MERGE: &str =
    "pr merge 12 --repo example/tidepool --squash --match-head-commit 0123456789abcdef0123456789abcdef01234567";
const BASE_TIP: &str = "1dc973bdb697cc0a92e481f73e5d6599b8f7be66";
const ARGS: [&str; 5] = ["merge-gate", "--unit", "3", "--pr", "12"];

/// One entry of `closingIssuesReferences`, shaped as `gh pr view --json` prints it.
fn closing(number: u64, owner: &str, name: &str) -> Value {
    json!({"number": number, "repository": {"name": name, "owner": {"login": owner}},
        "url": format!("https://github.com/{owner}/{name}/issues/{number}")})
}

fn pr_view(state: &str, labels: &[&str], body: &str) -> Value {
    let labels: Vec<Value> = labels.iter().map(|l| json!({"name": l})).collect();
    json!({
        "state": state, "headRefOid": HEAD, "baseRefName": "develop", "body": body,
        "labels": labels, "mergeCommit": null, "changedFiles": 2,
        "closingIssuesReferences": [closing(103, "example", "tidepool"), closing(106, "example", "tidepool")],
        "statusCheckRollup": [
            {"__typename": "CheckRun", "name": "build", "workflowName": "CI", "status": "COMPLETED", "conclusion": "SUCCESS", "startedAt": "2026-11-21T01:00:00Z"},
            {"__typename": "StatusContext", "context": "lint", "state": "SUCCESS", "startedAt": "2026-11-21T01:00:00Z"},
            {"__typename": "CheckRun", "name": "docs", "status": "COMPLETED", "conclusion": "CANCELLED", "startedAt": "2026-11-21T01:00:00Z"}
        ]
    })
}

fn put(env: &Env, file: &str, value: &Value) {
    env.stub_file(file, &value.to_string());
}

fn preflight(env: &mut Env, output: &str, exit: i32) {
    let path = env.dir.path().join("preflight.sh");
    fs::write(&path, format!("#!/bin/sh\ncat <<'EOF'\n{output}\nEOF\nexit {exit}\n")).expect("the script");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).expect("chmod");
    env.set("ISSUE_DRAIN_MERGE_PREFLIGHT", &path.display().to_string());
}

fn clean_preflight(env: &mut Env) {
    preflight(
        env,
        &json!({"status": "clear", "pr": "12", "head": HEAD, "verdict": "CLEAN"}).to_string(),
        0,
    );
}

fn proof(env: &Env, reviewers: Value) {
    env.write(
        "units/3/review-proof.json",
        &json!({"head": HEAD, "reviewers": reviewers}).to_string(),
    );
}

/// A PR open on develop, green, reviewed, delivered, with no thread open.
fn ready() -> Env {
    let mut env = Env::new();
    put(&env, "pr-view-12.json", &pr_view("OPEN", &["bug"], "Fixes #5"));
    put(
        &env,
        "protection.json",
        &json!({"required_status_checks": {"contexts": ["build"], "checks": [{"context": "lint"}]}}),
    );
    put(
        &env,
        "compare.json",
        &json!({"behind_by": 0, "ahead_by": 2, "merge_base_commit": {"sha": BASE_TIP}}),
    );
    env.write("queue.json", &queue_with_unit(json!({})).to_string());
    put(&env, "pr-view-12.after-merge.json", &merged_view());
    put(
        &env,
        "graphql-12.json",
        &json!({"data": {"repository": {"pullRequest": {"reviewThreads": {
            "pageInfo": {"hasNextPage": false, "endCursor": null},
            "nodes": [{"isResolved": true}]}}}}}),
    );
    for n in [103, 106] {
        put(
            &env,
            &format!("issue-view-{n}.json"),
            &json!({"labels": [{"name": "bug"}]}),
        );
    }
    clean_preflight(&mut env);
    proof(
        &env,
        json!([
            {"name": "codex", "has_output": true, "failure_kind": null},
            {"name": "kimi", "has_output": true, "failure_kind": null}
        ]),
    );
    env.write(
        "units/3/deliver.json",
        &json!({"ok": true, "head": HEAD, "merge_base": BASE_TIP, "risk_paths_touched": []}).to_string(),
    );
    env.write("units/3/guards-marker", "");
    env
}

/// What GitHub says about PR 12 after a merge that went through.
fn merged_view() -> Value {
    json!({"state": "MERGED", "mergeCommit": {"oid": "fedcba9876543210fedcba9876543210fedcba98"}})
}

fn result(out: &Out) -> Value {
    let line = out.stdout.lines().last().unwrap_or_default();
    serde_json::from_str(line).unwrap_or_else(|e| panic!("stdout is not JSON ({e}): {}", out.stdout))
}

fn codes(result: &Value) -> Vec<String> {
    result["refusals"]
        .as_array()
        .expect("a refusals list")
        .iter()
        .map(|r| r["code"].as_str().expect("a code").to_string())
        .collect()
}

fn merged_calls(env: &Env) -> Vec<String> {
    env.gh_calls()
        .into_iter()
        .filter(|c| c.starts_with("pr merge"))
        .collect()
}

#[test]
fn a_clear_pr_is_merged_with_the_exact_arguments() {
    let env = ready();
    let out = env.run(&ARGS);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let r = result(&out);
    assert_eq!(r["merged"], true);
    assert_eq!(r["pr"], 12);
    assert_eq!(r["unit"], 3);
    assert_eq!(r["head"], HEAD);
    assert_eq!(r["refusals"], json!([]));
    assert_eq!(r["reviewers"], json!(["codex", "kimi"]));
    assert_eq!(merged_calls(&env), [MERGE]);
    let calls = env.gh_calls();
    assert!(
        calls.iter().all(|c| !c.contains("--admin") && !c.contains("--auto")),
        "{calls:?}"
    );
    let writes = [
        "issue edit",
        "label ",
        "--add-label",
        "--remove-label",
        "issue comment",
        "issue close",
    ];
    assert!(calls.iter().all(|c| writes.iter().all(|w| !c.contains(w))), "{calls:?}");
    assert!(
        calls
            .iter()
            .any(|c| c.starts_with("api repos/example/tidepool/branches/develop/protection"))
    );
    assert!(
        calls
            .iter()
            .any(|c| c == &format!("api repos/example/tidepool/compare/develop...{HEAD}"))
    );
    assert_eq!(env.events_named("merge_gate").len(), 1);
}

#[test]
fn a_read_that_fails_is_a_read_error_and_nothing_is_merged() {
    let env = ready();
    fs::remove_file(env.stub.join("protection.json")).expect("remove");
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    let r = result(&out);
    assert_eq!(r["merged"], false);
    assert_eq!(codes(&r), ["read_error"]);
    assert!(
        r["refusals"][0]["detail"]
            .as_str()
            .unwrap()
            .contains("branch protection")
    );
    assert!(merged_calls(&env).is_empty());
}

#[test]
fn every_read_failing_refuses_and_nothing_is_merged() {
    let env = ready();
    env.stub_file("fail", "");
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    let r = result(&out);
    assert_eq!(r["head"], "");
    assert!(codes(&r).contains(&"read_error".to_string()));
    assert!(merged_calls(&env).is_empty());
}

#[test]
fn a_thread_read_that_does_not_parse_refuses() {
    let env = ready();
    env.stub_file("graphql-12.json", "not json");
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3);
    assert_eq!(codes(&result(&out)), ["read_error"]);
    assert!(merged_calls(&env).is_empty());
}

#[test]
fn an_already_merged_pr_exits_0_without_a_merge_call() {
    let env = ready();
    let mut view = pr_view("MERGED", &[], "");
    view["mergeCommit"] = json!({"oid": "fedcba9876543210fedcba9876543210fedcba98"});
    put(&env, "pr-view-12.json", &view);
    let out = env.run(&ARGS);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let r = result(&out);
    assert_eq!(r["merged"], true);
    assert_eq!(r["already"], true);
    assert_eq!(r["head"], HEAD);
    assert_eq!(r["merge_commit"], "fedcba9876543210fedcba9876543210fedcba98");
    assert!(merged_calls(&env).is_empty());
    assert_eq!(env.gh_calls().len(), 1, "only the PR was read");
}

#[test]
fn a_closed_unmerged_pr_is_refused() {
    let env = ready();
    put(&env, "pr-view-12.json", &pr_view("CLOSED", &["bug"], "Fixes #5"));
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3);
    assert_eq!(codes(&result(&out)), ["closed_unmerged"]);
    assert!(merged_calls(&env).is_empty());
}

#[test]
fn a_dry_run_prints_the_merge_and_records_no_write() {
    let env = ready();
    let mut args = ARGS.to_vec();
    args.push("--dry-run");
    let out = env.run(&args);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stdout.contains(&format!("WOULD: gh {MERGE}")), "{}", out.stdout);
    let r = result(&out);
    assert_eq!(r["merged"], false);
    assert_eq!(r["refusals"], json!([]));
    assert!(merged_calls(&env).is_empty());
    let events = env.events_named("gh_write");
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["dry_run"], true);
}

#[test]
fn a_dry_run_still_refuses_what_a_live_run_would() {
    let env = ready();
    env.write("units/3/guards-marker", "");
    fs::remove_file(env.workdir.join("units/3/guards-marker")).expect("remove");
    let mut args = ARGS.to_vec();
    args.push("--dry-run");
    let out = env.run(&args);
    assert_eq!(out.code, 3);
    assert!(!out.stdout.contains("WOULD"));
    assert_eq!(codes(&result(&out)), ["guards_marker"]);
}

#[test]
fn a_review_script_that_prints_not_clear_and_exits_0_is_a_refusal() {
    let mut env = ready();
    preflight(
        &mut env,
        &json!({"status": "stale", "head": HEAD, "verdict": "CLEAN"}).to_string(),
        0,
    );
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3);
    let r = result(&out);
    assert_eq!(codes(&r), ["review"]);
    assert!(r["refusals"][0]["detail"].as_str().unwrap().contains("stale"));
    assert!(merged_calls(&env).is_empty());
}

#[test]
fn a_review_script_that_exits_1_with_clear_json_still_counts_only_the_json() {
    let mut env = ready();
    clean_preflight(&mut env);
    let out = env.run(&ARGS);
    assert_eq!(out.code, 0);
    fs::remove_file(env.stub.join("merged-12")).expect("the stub forgets the merge");
    preflight(
        &mut env,
        &json!({"status": "clear", "head": HEAD, "verdict": "CLEAN"}).to_string(),
        1,
    );
    assert_eq!(env.run(&ARGS).code, 0, "its exit code is ignored");
}

#[test]
fn a_review_script_with_no_json_or_no_such_file_is_a_read_error() {
    let mut env = ready();
    preflight(&mut env, "all fine", 0);
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3);
    assert_eq!(codes(&result(&out)), ["read_error"]);

    env.set("ISSUE_DRAIN_MERGE_PREFLIGHT", "/nonexistent/merge_preflight.sh");
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3);
    assert_eq!(codes(&result(&out)), ["read_error"]);
    assert!(merged_calls(&env).is_empty());
}

#[test]
fn several_refusals_come_back_together() {
    let env = ready();
    put(&env, "pr-view-12.json", &pr_view("OPEN", &["Blocked"], "Fixes #5"));
    put(
        &env,
        "graphql-12.json",
        &json!({"data": {"repository": {"pullRequest": {"reviewThreads": {
            "pageInfo": {"hasNextPage": false, "endCursor": null},
            "nodes": [{"isResolved": false}, {"isResolved": false}, {"isResolved": true}]}}}}}),
    );
    put(
        &env,
        "compare.json",
        &json!({"behind_by": 4, "merge_base_commit": {"sha": BASE_TIP}}),
    );
    fs::remove_file(env.workdir.join("units/3/deliver.json")).expect("remove");
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3);
    let r = result(&out);
    assert_eq!(
        codes(&r),
        ["threads_open", "hold_label", "behind_base", "deliver_check"]
    );
    assert_eq!(r["refusals"][0]["detail"], "2 unresolved review threads");
    assert!(merged_calls(&env).is_empty());
}

#[test]
fn a_required_check_that_is_missing_refuses_naming_it() {
    let env = ready();
    put(
        &env,
        "protection.json",
        &json!({"required_status_checks": {"contexts": ["build", "e2e"], "checks": []}}),
    );
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3);
    let r = result(&out);
    assert_eq!(codes(&r), ["required_check"]);
    assert!(r["refusals"][0]["detail"].as_str().unwrap().contains("e2e"));
}

#[test]
fn a_hold_label_on_the_issue_the_pr_closes_refuses() {
    let env = ready();
    put(
        &env,
        "issue-view-103.json",
        &json!({"labels": [{"name": "ready-for-human"}]}),
    );
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3);
    assert_eq!(codes(&result(&out)), ["hold_label"]);
    assert!(merged_calls(&env).is_empty());
}

#[test]
fn a_failed_merge_call_exits_1() {
    let env = ready();
    env.stub_file("fail-merge", "");
    let out = env.run(&ARGS);
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert_eq!(result(&out)["merged"], false);
    assert_eq!(merged_calls(&env), [MERGE]);
}

#[test]
fn codex_alone_is_reported_when_the_others_have_a_failure_kind() {
    let env = ready();
    proof(
        &env,
        json!([
            {"name": "codex", "has_output": true, "failure_kind": null},
            {"name": "kimi", "has_output": false, "failure_kind": "quota"}
        ]),
    );
    let out = env.run(&ARGS);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(result(&out)["reviewers"], json!(["codex"]));
}

#[test]
fn a_review_proof_for_another_head_refuses() {
    let env = ready();
    env.write(
        "units/3/review-proof.json",
        &json!({"head": "f".repeat(40), "reviewers": [{"name": "codex", "has_output": true}]}).to_string(),
    );
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3);
    assert_eq!(codes(&result(&out)), ["review_proof"]);
}

#[test]
fn a_unit_process_cannot_merge() {
    let mut env = ready();
    env.set("ISSUE_DRAIN_MODE", "unit");
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(merged_calls(&env).is_empty());
}

#[test]
fn bad_arguments_exit_2() {
    let env = ready();
    assert_eq!(env.run(&["merge-gate", "--unit", "3"]).code, 2);
    assert_eq!(env.run(&["merge-gate", "--unit", "0", "--pr", "12"]).code, 2);
}

fn queue_waiting_for(who: Value) -> String {
    queue_with_unit(json!({"waits": true, "waits_for": who})).to_string()
}

#[test]
fn a_unit_that_waits_for_a_person_is_never_merged_by_the_gate() {
    let env = ready();
    env.write("queue.json", &queue_waiting_for(json!("clinical review")));
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    let r = result(&out);
    assert_eq!(codes(&r), ["waits_for"]);
    let detail = r["refusals"][0]["detail"].as_str().unwrap();
    assert!(
        detail.contains("clinical review") && detail.contains("a person merges"),
        "{detail}"
    );
    assert!(merged_calls(&env).is_empty());
}

#[test]
fn a_blank_waits_for_does_not_refuse_and_an_unreadable_queue_does() {
    let env = ready();
    env.write("queue.json", &queue_waiting_for(json!("  ")));
    assert_eq!(env.run(&ARGS).code, 0);

    let env = ready();
    fs::remove_file(env.workdir.join("queue.json")).expect("remove");
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(codes(&result(&out)), ["read_error"]);
    assert!(merged_calls(&env).is_empty());
}

#[test]
fn a_delivery_audited_from_another_base_than_the_live_one_refuses() {
    let env = ready();
    let other = "2".repeat(40);
    env.write(
        "units/3/deliver.json",
        &json!({"ok": true, "head": HEAD, "merge_base": other, "risk_paths_touched": []}).to_string(),
    );
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    let r = result(&out);
    assert_eq!(codes(&r), ["deliver_check"]);
    assert!(r["refusals"][0]["detail"].as_str().unwrap().contains(&other));
    assert!(merged_calls(&env).is_empty());
}

#[test]
fn a_delivery_report_with_no_merge_base_refuses() {
    let env = ready();
    env.write(
        "units/3/deliver.json",
        &json!({"ok": true, "head": HEAD, "risk_paths_touched": []}).to_string(),
    );
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(codes(&result(&out)), ["deliver_check"]);
}

#[test]
fn a_delivery_that_touched_a_risk_path_is_refused_and_a_person_merges_it() {
    let env = ready();
    env.write(
        "units/3/deliver.json",
        &json!({"ok": true, "head": HEAD, "merge_base": BASE_TIP, "risk_paths_touched": ["src/billing/charge.ts"]})
            .to_string(),
    );
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    let r = result(&out);
    assert_eq!(codes(&r), ["risk_path"]);
    let detail = r["refusals"][0]["detail"].as_str().unwrap();
    assert!(
        detail.contains("src/billing/charge.ts") && detail.contains("person"),
        "{detail}"
    );
    assert!(merged_calls(&env).is_empty());
}

#[test]
fn a_delivery_report_without_the_risk_field_is_refused() {
    let env = ready();
    env.write(
        "units/3/deliver.json",
        &json!({"ok": true, "head": HEAD, "merge_base": BASE_TIP}).to_string(),
    );
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    let r = result(&out);
    assert_eq!(codes(&r), ["deliver_check"]);
    assert!(
        r["refusals"][0]["detail"]
            .as_str()
            .unwrap()
            .contains("deliver-check again")
    );
    assert!(merged_calls(&env).is_empty());
}

#[test]
fn a_compare_answer_with_no_merge_base_is_a_read_error() {
    let env = ready();
    put(&env, "compare.json", &json!({"behind_by": 0}));
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(codes(&result(&out)).contains(&"read_error".to_string()));
    assert!(merged_calls(&env).is_empty());
}

#[test]
fn a_merge_that_only_queued_the_pr_is_not_reported_merged() {
    let env = ready();
    put(
        &env,
        "pr-view-12.after-merge.json",
        &pr_view("OPEN", &["bug"], "Fixes #5"),
    );
    let out = env.run(&ARGS);
    assert_eq!(out.code, 4, "{}", out.stderr);
    let r = result(&out);
    assert_eq!(r["merged"], false);
    assert_eq!(r["queued"], true);
    assert_eq!(merged_calls(&env), [MERGE]);
}

#[test]
fn a_merged_pr_reports_its_merge_commit() {
    let env = ready();
    let out = env.run(&ARGS);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let r = result(&out);
    assert_eq!(r["merged"], true);
    assert_eq!(r["merge_commit"], "fedcba9876543210fedcba9876543210fedcba98");
}

#[test]
fn a_read_that_fails_after_the_merge_call_says_the_merge_may_have_happened() {
    let env = ready();
    fs::remove_file(env.stub.join("pr-view-12.after-merge.json")).expect("remove");
    let out = env.run(&ARGS);
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert!(out.stderr.contains("may have been merged"), "{}", out.stderr);
    assert_eq!(merged_calls(&env), [MERGE]);
}

#[test]
fn an_issue_the_pr_closes_in_another_repository_refuses_naming_it() {
    let env = ready();
    let mut view = pr_view("OPEN", &["bug"], "Fixes #5");
    view["closingIssuesReferences"] = json!([closing(103, "example", "tidepool"), closing(7, "other", "elsewhere")]);
    put(&env, "pr-view-12.json", &view);
    put(&env, "issue-view-7.json", &json!({"labels": [{"name": "bug"}]}));
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    let r = result(&out);
    assert_eq!(codes(&r), ["closing_issue_repo"]);
    assert!(r["refusals"][0]["detail"].as_str().unwrap().contains("other/elsewhere"));
    assert!(
        env.gh_calls().iter().all(|c| !c.starts_with("issue view 7")),
        "the other repository's issue is not read by number here"
    );
    assert!(merged_calls(&env).is_empty());
}

#[test]
fn a_closing_issue_with_no_repository_does_not_parse() {
    let env = ready();
    let mut view = pr_view("OPEN", &["bug"], "Fixes #5");
    view["closingIssuesReferences"] = json!([{"number": 5}]);
    put(&env, "pr-view-12.json", &view);
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(codes(&result(&out)).contains(&"read_error".to_string()));
    assert!(merged_calls(&env).is_empty());
}

/// A ruleset's `required_status_checks` rule, as `rules/branches/<b>` lists it.
fn ruleset_requiring(contexts: &[&str]) -> Value {
    let checks: Vec<Value> = contexts
        .iter()
        .map(|c| json!({"context": c, "integration_id": 15368}))
        .collect();
    json!([
        {"type": "deletion", "ruleset_source_type": "Repository", "ruleset_source": REPO, "ruleset_id": 1},
        {"type": "required_status_checks", "ruleset_source_type": "Repository", "ruleset_source": REPO,
         "ruleset_id": 1, "parameters": {"strict_required_status_checks_policy": false,
         "required_status_checks": checks}}
    ])
}

#[test]
fn a_check_a_ruleset_requires_is_required_beside_classic_protection() {
    let env = ready();
    put(&env, "rules.json", &ruleset_requiring(&["e2e"]));
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    let r = result(&out);
    assert_eq!(codes(&r), ["required_check"]);
    assert!(r["refusals"][0]["detail"].as_str().unwrap().contains("'e2e'"));
    assert!(merged_calls(&env).is_empty());
    assert!(
        env.gh_calls()
            .iter()
            .any(|c| c.starts_with("api repos/example/tidepool/rules/branches/develop") && c.contains("--paginate")),
        "{:?}",
        env.gh_calls()
    );
    // control: a ruleset requirement that the PR meets
    put(&env, "rules.json", &ruleset_requiring(&["build"]));
    assert_eq!(env.run(&ARGS).code, 0);
}

#[test]
fn a_branch_with_a_ruleset_and_no_classic_protection_is_judged_by_the_ruleset() {
    let env = ready();
    env.stub_file("protection.unprotected", "");
    put(&env, "rules.json", &ruleset_requiring(&["e2e"]));
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(codes(&result(&out)), ["required_check"]);

    put(&env, "rules.json", &ruleset_requiring(&["build"]));
    let out = env.run(&ARGS);
    assert_eq!(out.code, 0, "{}", out.stderr);
}

#[test]
fn no_classic_protection_is_no_requirement_only_when_the_rules_were_read() {
    let env = ready();
    env.stub_file("protection.unprotected", "");
    env.stub_file("fail-rules", "");
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    let r = result(&out);
    assert_eq!(codes(&r), ["read_error"]);
    assert!(r["refusals"][0]["detail"].as_str().unwrap().contains("branch rules"));
    assert!(merged_calls(&env).is_empty());

    // The rules read fails beside classic protection that was read: still a refusal.
    let env = ready();
    env.stub_file("fail-rules", "");
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(codes(&result(&out)), ["read_error"]);

    // Rules that do not parse.
    let env = ready();
    env.stub_file("rules.json", "{\"message\":\"Not Found\"}");
    assert_eq!(env.run(&ARGS).code, 3);
}

#[test]
fn a_protection_read_that_fails_for_another_reason_is_not_no_protection() {
    let env = ready();
    fs::remove_file(env.stub.join("protection.json")).expect("remove");
    put(&env, "rules.json", &ruleset_requiring(&["build"]));
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(
        result(&out)["refusals"][0]["detail"]
            .as_str()
            .unwrap()
            .contains("branch protection")
    );
    assert!(merged_calls(&env).is_empty());
}

#[test]
fn a_same_named_check_of_another_workflow_that_failed_is_not_hidden_by_a_later_success() {
    let env = ready();
    let mut view = pr_view("OPEN", &["bug"], "Fixes #103");
    view["statusCheckRollup"] = json!([
        {"__typename": "CheckRun", "name": "build", "workflowName": "CI", "status": "COMPLETED", "conclusion": "SUCCESS", "startedAt": "2026-11-21T02:00:00Z"},
        {"__typename": "CheckRun", "name": "build", "workflowName": "Nightly", "status": "COMPLETED", "conclusion": "FAILURE", "startedAt": "2026-11-21T01:00:00Z"},
        {"__typename": "StatusContext", "context": "lint", "state": "SUCCESS", "startedAt": "2026-11-21T01:00:00Z"}
    ]);
    put(&env, "pr-view-12.json", &view);
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(codes(&result(&out)), ["required_check"]);
    assert!(merged_calls(&env).is_empty());
}

#[test]
fn a_review_record_with_no_head_refuses() {
    let mut env = ready();
    preflight(&mut env, &json!({"status": "clear", "verdict": "CLEAN"}).to_string(), 0);
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(codes(&result(&out)), ["review"]);
    assert!(merged_calls(&env).is_empty());
}

#[test]
fn a_hold_label_on_an_issue_of_the_unit_that_the_pr_does_not_close_refuses() {
    let env = ready();
    let mut view = pr_view("OPEN", &["bug"], "Fixes #103");
    view["closingIssuesReferences"] = json!([closing(103, "example", "tidepool")]);
    put(&env, "pr-view-12.json", &view);
    put(
        &env,
        "issue-view-106.json",
        &json!({"labels": [{"name": "needs-human"}]}),
    );
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    let r = result(&out);
    assert_eq!(codes(&r), ["hold_label"]);
    assert!(r["refusals"][0]["detail"].as_str().unwrap().contains("issue #106"));
    assert!(merged_calls(&env).is_empty());
}

#[test]
fn a_pr_that_closes_an_issue_the_unit_does_not_carry_refuses() {
    let env = ready();
    let mut view = pr_view("OPEN", &["bug"], "Fixes #999");
    view["closingIssuesReferences"] = json!([
        closing(103, "example", "tidepool"),
        closing(106, "example", "tidepool"),
        closing(999, "example", "tidepool")
    ]);
    put(&env, "pr-view-12.json", &view);
    put(&env, "issue-view-999.json", &json!({"labels": [{"name": "bug"}]}));
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    let r = result(&out);
    assert_eq!(codes(&r), ["closing_issue_unit"]);
    assert!(r["refusals"][0]["detail"].as_str().unwrap().contains("#999"));
    assert!(merged_calls(&env).is_empty());
}
