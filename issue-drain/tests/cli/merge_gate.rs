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
        "headRefName": "fix/tide", "headRepository": {"name": "tidepool"},
        "headRepositoryOwner": {"login": "example"}, "mergeStateStatus": "CLEAN",
        "reviewDecision": "", "autoMergeRequest": null,
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
        &json!({"status": "clear", "pr": "12", "head": HEAD, "reviewed": HEAD, "verdict": "CLEAN"}).to_string(),
        0,
    );
}

/// A cross-review record comment stamped at `sha`, as post_comment.sh writes it.
fn record(sha: &str, verdict: &str) -> String {
    format!(
        "## Cross-review\n\nReviewed `{}`\n\n<!-- cross-review: sha={sha} base={BASE_TIP} pass=1 digest={} verdict={verdict} -->",
        &sha[..9],
        "a".repeat(64)
    )
}

/// One comment as the REST comments endpoint prints it.
fn comment(body: &str, association: &str) -> Value {
    json!({"body": body, "author_association": association, "user": {"login": "someone"}})
}

fn comments(env: &Env, list: &[Value]) {
    put(env, "comments.json", &json!(list));
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
    comments(&env, &[comment(&record(HEAD, "CLEAN"), "OWNER")]);
    put(
        &env,
        "merge-queue.json",
        &json!({"data": {"repository": {"pullRequest": {"isInMergeQueue": false}}}}),
    );
    let checkout = origin_clone(env.dir.path(), fixture_repo());
    env.set("ISSUE_DRAIN_REPO_DIR", &checkout.display().to_string());
    proof(
        &env,
        json!([
            {"name": "codex", "has_output": true, "failure_kind": null},
            {"name": "kimi", "has_output": true, "failure_kind": null}
        ]),
    );
    env.write(
        "units/3/deliver.json",
        &json!({"ok": true, "head": HEAD, "merge_base": BASE_TIP, "risk_paths_touched": [], "scope_checked": true})
            .to_string(),
    );
    env.write("units/3/guards-marker", "");
    env.write("units/3/unit.json", &json!({"branch": "fix/tide"}).to_string());
    env
}

/// What GitHub says about PR 12 after a merge that went through.
fn merged_view() -> Value {
    json!({"state": "MERGED", "mergeCommit": {"oid": "fedcba9876543210fedcba9876543210fedcba98"}, "autoMergeRequest": null})
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
    let record = fs::read_to_string(env.workdir.join("units/3/merge-approved-head")).expect("the approved head");
    assert_eq!(record.trim(), HEAD);
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
fn an_already_merged_pr_that_is_not_the_units_is_not_reported_for_it() {
    for (key, value) in [
        ("headRefName", json!("fix/other")),
        ("headRepositoryOwner", json!({"login": "stranger"})),
    ] {
        let env = ready();
        let mut view = pr_view("MERGED", &[], "");
        view[key] = value;
        put(&env, "pr-view-12.json", &view);
        let out = env.run(&ARGS);
        assert_eq!(out.code, 3, "{}", out.stderr);
        let r = result(&out);
        assert_eq!(
            (r["merged"].clone(), codes(&r)),
            (json!(false), vec!["pr_unit".to_string()]),
            "{key}"
        );
        assert!(merged_calls(&env).is_empty());
    }
    // No unit.json: nothing says which branch is the unit's.
    let env = ready();
    fs::remove_file(env.workdir.join("units/3/unit.json")).expect("remove");
    put(&env, "pr-view-12.json", &pr_view("MERGED", &[], ""));
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(codes(&result(&out)), ["pr_unit"]);
}

#[test]
fn a_pr_that_is_not_the_units_is_not_merged() {
    for (key, value) in [
        ("headRefName", json!("fix/other")),
        ("headRepositoryOwner", json!({"login": "stranger"})),
    ] {
        let env = ready();
        let mut view = pr_view("OPEN", &["bug"], "Fixes #5");
        view[key] = value;
        put(&env, "pr-view-12.json", &view);
        let out = env.run(&ARGS);
        assert_eq!(out.code, 3, "{}", out.stderr);
        assert_eq!(codes(&result(&out)), ["pr_unit"], "{key}");
        assert!(merged_calls(&env).is_empty());
    }
}

#[test]
fn a_pr_github_would_only_queue_for_later_is_refused_before_the_merge_call() {
    for (key, value) in [
        ("mergeStateStatus", "BLOCKED"),
        ("mergeStateStatus", "UNKNOWN"),
        ("reviewDecision", "REVIEW_REQUIRED"),
        ("reviewDecision", "CHANGES_REQUESTED"),
    ] {
        let env = ready();
        let mut view = pr_view("OPEN", &["bug"], "Fixes #5");
        view[key] = json!(value);
        put(&env, "pr-view-12.json", &view);
        let out = env.run(&ARGS);
        assert_eq!(out.code, 3, "{value}: {}", out.stderr);
        assert_eq!(codes(&result(&out)), ["not_mergeable"], "{value}");
        assert!(merged_calls(&env).is_empty(), "{value}");
    }
    // Control: UNSTABLE and an approval merge.
    let env = ready();
    let mut view = pr_view("OPEN", &["bug"], "Fixes #5");
    view["mergeStateStatus"] = json!("UNSTABLE");
    view["reviewDecision"] = json!("APPROVED");
    put(&env, "pr-view-12.json", &view);
    assert_eq!(env.run(&ARGS).code, 0);
}

fn armed_view() -> Value {
    let mut view = pr_view("OPEN", &["bug"], "Fixes #5");
    view["autoMergeRequest"] = json!({"enabledAt": "2026-11-21T02:00:00Z", "mergeMethod": "SQUASH"});
    view
}

fn disable_calls(env: &Env) -> Vec<String> {
    env.gh_calls()
        .into_iter()
        .filter(|c| c.contains("--disable-auto"))
        .collect()
}

#[test]
fn auto_merge_armed_by_the_merge_call_is_turned_off_and_refused() {
    let env = ready();
    put(&env, "pr-view-12.after-merge.json", &armed_view());
    let mut after = pr_view("OPEN", &["bug"], "Fixes #5");
    after["autoMergeRequest"] = Value::Null;
    put(&env, "pr-view-12.after-disable.json", &after);
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("turned off"), "{}", out.stderr);
    let r = result(&out);
    assert_eq!(
        (r["merged"].clone(), r["auto_merge_disabled"].clone()),
        (json!(false), json!(true))
    );
    assert!(r.get("queued").is_none());
    assert_eq!(
        disable_calls(&env),
        ["pr merge 12 --repo example/tidepool --disable-auto"]
    );
}

#[test]
fn auto_merge_that_cannot_be_turned_off_is_reported_still_armed() {
    let env = ready();
    put(&env, "pr-view-12.after-merge.json", &armed_view());
    env.stub_file("fail-disable-auto", "");
    let out = env.run(&ARGS);
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert!(out.stderr.contains("STILL ARMED"), "{}", out.stderr);
    assert_eq!(result(&out)["auto_merge_armed"], true);
}

#[test]
fn an_open_pr_with_no_auto_merge_request_is_queued_and_nothing_is_turned_off() {
    let env = ready();
    put(
        &env,
        "pr-view-12.after-merge.json",
        &pr_view("OPEN", &["bug"], "Fixes #5"),
    );
    let out = env.run(&ARGS);
    assert_eq!(out.code, 4, "{}", out.stderr);
    assert!(disable_calls(&env).is_empty());
    // An answer that does not say whether auto-merge is armed is not "not armed".
    let mut unsure = pr_view("OPEN", &["bug"], "Fixes #5");
    unsure.as_object_mut().unwrap().remove("autoMergeRequest");
    put(&env, "pr-view-12.after-merge.json", &unsure);
    fs::remove_file(env.stub.join("merged-12")).expect("the stub forgets the merge");
    assert_eq!(env.run(&ARGS).code, 1);
}

#[test]
fn a_unit_process_cannot_turn_auto_merge_off_either() {
    // The write path refuses any verb a unit may not use, so the new one is too.
    let mut env = ready();
    env.set("ISSUE_DRAIN_MODE", "unit");
    let out = env.run(&["gh-write", "disable-auto-merge", "12"]);
    assert_ne!(out.code, 0);
    assert!(disable_calls(&env).is_empty());
}

fn pinned_ruleset() -> Value {
    json!([{"type": "required_status_checks", "parameters": {"required_status_checks": [
        {"context": "build", "integration_id": 15368}]}}])
}

fn runs_of(app: u64, conclusion: &str) -> Value {
    json!({"total_count": 1, "check_runs": [
        {"name": "build", "status": "completed", "conclusion": conclusion, "started_at": "2026-11-21T01:00:00Z", "app": {"id": app}}]})
}

#[test]
fn a_check_pinned_to_an_app_needs_a_run_from_that_app() {
    let env = ready();
    put(&env, "rules.json", &pinned_ruleset());
    // The rollup's `build` passes, but nothing says which app made it.
    put(&env, "check-runs.json", &runs_of(99, "success"));
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    let r = result(&out);
    assert_eq!(codes(&r), ["required_check"]);
    assert!(r["refusals"][0]["detail"].as_str().unwrap().contains("app 15368"));
    assert!(merged_calls(&env).is_empty());
    assert!(
        env.gh_calls()
            .iter()
            .any(|c| c.starts_with(&format!("api repos/example/tidepool/commits/{HEAD}/check-runs")))
    );
    // The right app, failing.
    put(&env, "check-runs.json", &runs_of(15368, "failure"));
    assert_eq!(codes(&result(&env.run(&ARGS))), ["required_check"]);
    // The right app, passing.
    put(&env, "check-runs.json", &runs_of(15368, "success"));
    assert_eq!(env.run(&ARGS).code, 0);
}

fn status_of(login: &str, kind: &str, state: &str, at: &str) -> Value {
    json!({"context": "build", "state": state, "created_at": at, "creator": {"login": login, "type": kind}})
}

#[test]
fn a_check_pinned_to_an_app_is_satisfied_by_a_commit_status_that_apps_bot_posted() {
    let env = ready();
    put(&env, "rules.json", &pinned_ruleset());
    // No check run named `build` from the app: a status is the only source.
    put(&env, "check-runs.json", &json!({"total_count": 0, "check_runs": []}));
    put(
        &env,
        "app-github-actions.json",
        &json!({"id": 15368, "slug": "github-actions"}),
    );
    put(&env, "app-other.json", &json!({"id": 7}));
    let at = "2026-11-21T02:00:00Z";
    let bot = "github-actions[bot]";
    let refused = |statuses: Value| {
        put(&env, "statuses.json", &statuses);
        let r = result(&env.run(&ARGS));
        assert_eq!(codes(&r), ["required_check"], "{statuses}");
        assert!(merged_calls(&env).is_empty());
        r
    };
    // A status from a person counts for no app.
    let r = refused(json!([status_of("mallory", "User", "success", at)]));
    assert!(r["refusals"][0]["detail"].as_str().unwrap().contains("app 15368"));
    // Nor does one from a user who only carries the bot's name, or from another app's bot.
    refused(json!([status_of(bot, "User", "success", at)]));
    refused(json!([status_of("other[bot]", "Bot", "success", at)]));
    // The newest status from the right app decides: a later failure refuses.
    refused(json!([
        status_of(bot, "Bot", "failure", "2026-11-21T03:00:00Z"),
        status_of(bot, "Bot", "success", at)
    ]));
    // The right app's bot, passing.
    put(&env, "statuses.json", &json!([status_of(bot, "Bot", "success", at)]));
    let out = env.run(&ARGS);
    assert_eq!(out.code, 0, "{}", out.stderr);
}

#[test]
fn an_app_that_cannot_be_looked_up_refuses_the_pinned_check() {
    let env = ready();
    put(&env, "rules.json", &pinned_ruleset());
    put(&env, "check-runs.json", &json!({"total_count": 0, "check_runs": []}));
    put(
        &env,
        "statuses.json",
        &json!([status_of(
            "github-actions[bot]",
            "Bot",
            "success",
            "2026-11-21T02:00:00Z"
        )]),
    );
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(codes(&result(&out)), ["read_error"]);
    assert!(merged_calls(&env).is_empty());
}

#[test]
fn an_unreadable_check_run_list_refuses_a_pinned_check_and_is_not_read_for_an_unpinned_one() {
    let env = ready();
    put(&env, "rules.json", &pinned_ruleset());
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(codes(&result(&out)), ["read_error"]);
    let env = ready();
    assert_eq!(env.run(&ARGS).code, 0);
    assert!(
        env.gh_calls().iter().all(|c| !c.contains("check-runs")),
        "{:?}",
        env.gh_calls()
    );
}

#[test]
fn a_review_stamped_before_the_head_needs_an_ancestor() {
    let mut env = ready();
    let stamped = &BASE_TIP[..9];
    preflight(
        &mut env,
        &json!({"status": "clear", "head": HEAD, "reviewed": stamped, "verdict": "CLEAN"}).to_string(),
        0,
    );
    comments(&env, &[comment(&record(BASE_TIP, "CLEAN"), "OWNER")]);
    put(
        &env,
        "compare-reviewed.json",
        &json!({"status": "diverged", "behind_by": 1, "ahead_by": 1}),
    );
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(codes(&result(&out)), ["review"]);
    assert!(merged_calls(&env).is_empty());
    env.stub_file("compare-reviewed.json", "");
    fs::remove_file(env.stub.join("compare-reviewed.json")).expect("remove");
    assert_eq!(codes(&result(&env.run(&ARGS))), ["read_error"]);
    put(
        &env,
        "compare-reviewed.json",
        &json!({"status": "ahead", "behind_by": 0, "ahead_by": 1}),
    );
    assert_eq!(env.run(&ARGS).code, 0);
    assert!(
        env.gh_calls()
            .iter()
            .any(|c| c == &format!("api repos/example/tidepool/compare/{stamped}...{HEAD}"))
    );
}

#[test]
fn a_unit_with_no_file_scope_is_refused_by_the_gate() {
    let env = ready();
    env.write(
        "units/3/deliver.json",
        &json!({"ok": true, "head": HEAD, "merge_base": BASE_TIP, "risk_paths_touched": [], "scope_checked": false})
            .to_string(),
    );
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    let r = result(&out);
    assert_eq!(codes(&r), ["deliver_check"]);
    assert!(r["refusals"][0]["detail"].as_str().unwrap().contains("no file scope"));
    assert!(merged_calls(&env).is_empty());
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

/// A PR whose review stopped at the cap: the record at the head says
/// FIXES_APPLIED, the proof covered the whole diff, and the live driver's cap
/// decision accepted the head. The newest record carries comment id 41.
fn capped(association: &str) -> Env {
    let mut env = ready();
    preflight(
        &mut env,
        &json!({"status": "pending", "pr": "12", "head": HEAD, "reviewed": HEAD, "verdict": "FIXES_APPLIED"})
            .to_string(),
        0,
    );
    let mut c = comment(&record(HEAD, "FIXES_APPLIED"), association);
    c["id"] = json!(41);
    comments(&env, &[c]);
    env.write(
        "units/3/review-proof.json",
        &json!({"head": HEAD, "scoped": false, "reviewers": [
            {"name": "codex", "has_output": true, "failure_kind": null}
        ]})
        .to_string(),
    );
    env.write(
        "units/3/drive-cap-accepted.json",
        &json!({"reviewed": HEAD}).to_string(),
    );
    env
}

fn capped_args() -> Vec<&'static str> {
    let mut args = ARGS.to_vec();
    args.extend(["--dry-run", "--accept-cap", HEAD]);
    args
}

#[test]
fn the_live_drivers_cap_decision_is_read_by_a_gate_asked_with_dry_run() {
    // The live driver writes drive-cap-accepted.json and judges with
    // `merge-gate --dry-run`; the gate's no-merge flag must not send it
    // looking for the dry-run driver's dry- file.
    let env = capped("OWNER");
    let out = env.run(&capped_args());
    assert_eq!(out.code, 0, "{}", out.stderr);
    let r = result(&out);
    assert_eq!(r["refusals"], json!([]), "{}", out.stdout);
    assert_eq!(r["merged"], false);
    assert!(merged_calls(&env).is_empty());
    let pin: Value =
        serde_json::from_str(&fs::read_to_string(env.workdir.join("units/3/cap-waived-record.json")).expect("the pin"))
            .expect("JSON");
    assert_eq!(pin, json!({"reviewed": HEAD, "record": 41}));
    assert!(!env.workdir.join("units/3/dry-cap-waived-record.json").exists());
}

#[test]
fn a_review_record_the_gate_refuses_is_not_pinned_by_the_cap_waiver() {
    let env = capped("NONE");
    let out = env.run(&capped_args());
    assert_eq!(out.code, 3, "{}", out.stdout);
    assert!(
        codes(&result(&out)).contains(&"review_author".to_string()),
        "{}",
        out.stdout
    );
    assert!(!env.workdir.join("units/3/cap-waived-record.json").exists());
    assert!(!env.workdir.join("units/3/dry-cap-waived-record.json").exists());
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
        &json!({"status": "stale", "head": HEAD, "reviewed": HEAD, "verdict": "CLEAN"}).to_string(),
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
        &json!({"status": "clear", "head": HEAD, "reviewed": HEAD, "verdict": "CLEAN"}).to_string(),
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
    // The status read in ready() does not say the PR is open and idle, so the
    // outcome is unknown and the record of the approved head is kept.
    let record = env.workdir.join("units/3/merge-approved-head");
    assert!(record.exists(), "an unknown outcome keeps the record");
}

#[test]
fn a_merge_call_github_turned_down_forgets_the_approved_head() {
    let env = ready();
    env.stub_file("fail-merge", "");
    put(
        &env,
        "merge-queue.json",
        &json!({"data": {"repository": {"pullRequest": {
            "state": "OPEN", "isInMergeQueue": false, "mergeCommit": null, "autoMergeRequest": null}}}}),
    );
    let out = env.run(&ARGS);
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert!(
        !env.workdir.join("units/3/merge-approved-head").exists(),
        "a head that never merged is not left as the approved one"
    );
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
        &json!({"ok": true, "head": HEAD, "merge_base": other, "risk_paths_touched": [], "scope_checked": true})
            .to_string(),
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
        &json!({"ok": true, "head": HEAD, "risk_paths_touched": [], "scope_checked": true}).to_string(),
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
        &json!({"ok": true, "head": HEAD, "merge_base": BASE_TIP, "risk_paths_touched": ["src/billing/charge.ts"], "scope_checked": true})
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
        &json!({"ok": true, "head": HEAD, "merge_base": BASE_TIP, "scope_checked": true}).to_string(),
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
    let checks: Vec<Value> = contexts.iter().map(|c| json!({"context": c})).collect();
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

// ---- fifth review round ----

#[test]
fn a_review_record_by_someone_who_is_not_trusted_is_refused() {
    for association in ["NONE", "CONTRIBUTOR", "FIRST_TIME_CONTRIBUTOR", ""] {
        let env = ready();
        comments(&env, &[comment(&record(HEAD, "CLEAN"), association)]);
        let out = env.run(&ARGS);
        assert_eq!(out.code, 3, "{association}: {}", out.stderr);
        assert_eq!(codes(&result(&out)), ["review_author"], "{association}");
        assert!(merged_calls(&env).is_empty(), "{association}");
    }
}

#[test]
fn the_newest_record_is_judged_for_the_script_report_and_the_case_of_the_association_does_not_matter() {
    let env = ready();
    let forged = comment(&record(HEAD, "CLEAN"), "NONE");
    let real = comment(&record(HEAD, "CLEAN"), "member");
    let chatter = comment("looks fine to me", "NONE");
    // The newest record is the forged one, however old the real one is.
    comments(&env, &[real.clone(), forged.clone(), chatter.clone()]);
    assert_eq!(codes(&result(&env.run(&ARGS))), ["review_author"]);
    // Two trusted records, the newest in another case, pass.
    comments(&env, &[real.clone(), comment(&record(HEAD, "CLEAN"), "OWNER"), chatter]);
    let out = env.run(&ARGS);
    assert_eq!(out.code, 0, "{}", out.stderr);
}

#[test]
fn an_older_record_by_someone_who_is_not_trusted_is_refused_by_name() {
    // The review script unions every stamped record, so an older record that
    // supplies coverage must be trusted too, whatever the newest one says.
    let env = ready();
    let forged = json!({"body": record(BASE_TIP, "CLEAN"), "author_association": "NONE", "user": {"login": "mallory"}});
    let real = comment(&record(HEAD, "CLEAN"), "MEMBER");
    comments(&env, &[forged, real.clone()]);
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(codes(&result(&out)), ["review_author"]);
    assert!(out.stdout.contains("mallory"), "{}", out.stdout);
    assert!(merged_calls(&env).is_empty());
    // A record the script never counts (BLOCKED, NEEDS_DECISION) or chatter does not matter.
    for verdict in ["BLOCKED", "NEEDS_DECISION"] {
        // A merge changes the stub's state, so each verdict gets its own.
        let env = ready();
        comments(&env, &[comment(&record(BASE_TIP, verdict), "NONE"), real.clone()]);
        let out = env.run(&ARGS);
        assert_eq!(out.code, 0, "{verdict}: {}", out.stderr);
    }
    // Two verdict fields: the script reads the last one (CLEAN) and may count
    // the record, so the first one (BLOCKED) earns no exemption.
    let env = ready();
    let both = record(BASE_TIP, "BLOCKED").replace("verdict=BLOCKED", "verdict=BLOCKED verdict=CLEAN");
    assert!(both.contains("verdict=BLOCKED verdict=CLEAN"), "{both}");
    comments(&env, &[comment(&both, "NONE"), real]);
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(codes(&result(&out)), ["review_author"]);
    assert!(merged_calls(&env).is_empty());
}

#[test]
fn a_review_record_on_a_later_page_of_comments_is_found() {
    let env = ready();
    let filler: Vec<Value> = (0..3).map(|_| comment("noise", "NONE")).collect();
    let page_two = json!([comment(&record(HEAD, "CLEAN"), "OWNER")]);
    env.stub_file("comments.json", &format!("{}\n{}\n", json!(filler), page_two));
    let out = env.run(&ARGS);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(
        env.gh_calls()
            .iter()
            .any(|c| c.starts_with("api repos/example/tidepool/issues/12/comments") && c.contains("--paginate")),
        "{:?}",
        env.gh_calls()
    );
}

#[test]
fn a_record_that_disagrees_with_the_review_script_or_is_missing_is_refused() {
    // Stamped at another commit than the script reported.
    let env = ready();
    comments(&env, &[comment(&record(BASE_TIP, "CLEAN"), "OWNER")]);
    assert_eq!(codes(&result(&env.run(&ARGS))), ["review_author"]);
    // A verdict that is not CLEAN.
    comments(&env, &[comment(&record(HEAD, "FIXES_APPLIED"), "OWNER")]);
    assert_eq!(codes(&result(&env.run(&ARGS))), ["review_author"]);
    // No record, only talk.
    comments(&env, &[comment("not a record", "OWNER")]);
    assert_eq!(codes(&result(&env.run(&ARGS))), ["review_author"]);
    // The comments cannot be read.
    fs::remove_file(env.stub.join("comments.json")).expect("remove");
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(codes(&result(&out)).contains(&"read_error".to_string()));
    assert!(merged_calls(&env).is_empty());
}

#[test]
fn a_profile_with_no_trusted_authors_trusts_no_review_record() {
    let mut env = ready();
    let text = fs::read_to_string(eval_fixtures().join("tidepool.toml")).expect("the profile");
    let text = text.replace(
        "trusted_associations = [\"OWNER\", \"MEMBER\", \"COLLABORATOR\"]",
        "trusted_associations = []",
    );
    assert!(text.contains("trusted_associations = []"));
    let profile = env.dir.path().join("empty-trust.toml");
    fs::write(&profile, text).expect("the profile");
    env.set("ISSUE_DRAIN_PROFILE", &profile.display().to_string());
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(codes(&result(&out)), ["review_author"]);
}

#[test]
fn an_already_merged_pr_on_another_base_branch_is_not_reported() {
    let env = ready();
    let mut view = pr_view("MERGED", &[], "");
    view["baseRefName"] = json!("main");
    put(&env, "pr-view-12.json", &view);
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    let r = result(&out);
    assert_eq!(
        (r["merged"].clone(), codes(&r)),
        (json!(false), vec!["wrong_base".to_string()])
    );
}

fn in_queue(env: &Env, queued: bool) {
    put(
        env,
        "merge-queue.json",
        &json!({"data": {"repository": {"pullRequest": {"isInMergeQueue": queued}}}}),
    );
}

#[test]
fn a_pr_already_in_the_merge_queue_is_reported_queued_without_a_merge_call() {
    let env = ready();
    in_queue(&env, true);
    let out = env.run(&ARGS);
    assert_eq!(out.code, 4, "{}", out.stderr);
    let r = result(&out);
    assert_eq!((r["merged"].clone(), r["queued"].clone()), (json!(false), json!(true)));
    assert!(merged_calls(&env).is_empty());
}

#[test]
fn a_merge_queue_read_that_fails_refuses_before_the_merge_call() {
    let env = ready();
    fs::remove_file(env.stub.join("merge-queue.json")).expect("remove");
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(codes(&result(&out)), ["read_error"]);
    assert!(merged_calls(&env).is_empty());
}

#[test]
fn a_review_stamped_at_an_ancestor_is_accepted_with_a_proof_for_that_ancestor() {
    let mut env = ready();
    let stamped = BASE_TIP;
    preflight(
        &mut env,
        &json!({"status": "clear", "head": HEAD, "reviewed": stamped, "verdict": "CLEAN"}).to_string(),
        0,
    );
    comments(&env, &[comment(&record(stamped, "CLEAN"), "OWNER")]);
    put(
        &env,
        "compare-reviewed.json",
        &json!({"status": "ahead", "behind_by": 0, "ahead_by": 1}),
    );
    env.write(
        "units/3/review-proof.json",
        &json!({"head": stamped, "reviewers": [{"name": "codex", "has_output": true}]}).to_string(),
    );
    let out = env.run(&ARGS);
    assert_eq!(out.code, 0, "{}", out.stderr);
    // The proof for the ancestor is not accepted when the ancestry is not shown.
    put(
        &env,
        "compare-reviewed.json",
        &json!({"status": "diverged", "behind_by": 1, "ahead_by": 1}),
    );
    fs::remove_file(env.stub.join("merged-12")).expect("the stub forgets the merge");
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(codes(&result(&out)).contains(&"review".to_string()));
    // A proof for some third commit is never accepted.
    put(
        &env,
        "compare-reviewed.json",
        &json!({"status": "ahead", "behind_by": 0, "ahead_by": 1}),
    );
    env.write(
        "units/3/review-proof.json",
        &json!({"head": "f".repeat(40), "reviewers": [{"name": "codex", "has_output": true}]}).to_string(),
    );
    assert_eq!(codes(&result(&env.run(&ARGS))), ["review_proof"]);
}

#[test]
fn the_review_script_runs_in_the_drained_checkout_and_that_checkout_must_be_the_repo() {
    let mut env = ready();
    let seen = env.dir.path().join("cwd.txt");
    let path = env.dir.path().join("pwd-preflight.sh");
    fs::write(
        &path,
        format!(
            "#!/bin/sh\npwd > {}\ncat <<'EOF'\n{}\nEOF\n",
            seen.display(),
            json!({"status": "clear", "head": HEAD, "reviewed": HEAD, "verdict": "CLEAN"})
        ),
    )
    .expect("the script");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).expect("chmod");
    env.set("ISSUE_DRAIN_MERGE_PREFLIGHT", &path.display().to_string());
    let from = env.dir.path().join("elsewhere");
    fs::create_dir_all(&from).expect("a folder");
    let out = env.run_in(Some(&from), &ARGS);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let checkout = fs::canonicalize(env.dir.path().join("checkout")).expect("the checkout");
    let ran_in = fs::canonicalize(fs::read_to_string(&seen).expect("the script ran").trim()).expect("its folder");
    assert_eq!(ran_in, checkout);

    // A checkout whose origin is another repository is refused, and the script is not run.
    fs::remove_file(&seen).expect("remove");
    fs::remove_file(env.stub.join("merged-12")).expect("the stub forgets the merge");
    git(
        &checkout,
        &["config", "remote.origin.url", "https://github.com/other/thing.git"],
    );
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    let r = result(&out);
    assert_eq!(codes(&r), ["read_error"]);
    assert!(r["refusals"][0]["detail"].as_str().unwrap().contains("origin"));
    assert!(!seen.exists());
    // So is a folder that is no checkout at all.
    env.set("ISSUE_DRAIN_REPO_DIR", &from.display().to_string());
    assert_eq!(codes(&result(&env.run(&ARGS))), ["read_error"]);
    assert!(!seen.exists());
}

fn check_run(name: &str, conclusion: &str, started: &str, run: u64) -> Value {
    json!({"__typename": "CheckRun", "name": name, "workflowName": "CI", "status": "COMPLETED",
        "conclusion": conclusion, "startedAt": started,
        "detailsUrl": format!("https://github.com/example/tidepool/actions/runs/{run}/job/9{run}")})
}

fn with_rollup(env: &Env, entries: Vec<Value>) {
    let mut view = pr_view("OPEN", &["bug"], "Fixes #5");
    view["statusCheckRollup"] = json!(entries);
    put(env, "pr-view-12.json", &view);
}

#[test]
fn two_workflows_sharing_a_display_name_cannot_mask_each_others_failure() {
    let env = ready();
    let lint = json!({"__typename": "StatusContext", "context": "lint", "state": "SUCCESS", "startedAt": "2026-11-21T01:00:00Z"});
    // Workflow file A (run 111) failed `build`; workflow file B (run 222), also
    // named CI, passed it later.
    with_rollup(
        &env,
        vec![
            check_run("build", "FAILURE", "2026-11-21T01:00:00Z", 111),
            check_run("build", "SUCCESS", "2026-11-21T02:00:00Z", 222),
            lint.clone(),
        ],
    );
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(codes(&result(&out)), ["required_check"]);
    assert!(merged_calls(&env).is_empty());
    // The same failure on a check nobody requires is still a failure.
    with_rollup(
        &env,
        vec![
            check_run("build", "SUCCESS", "2026-11-21T01:00:00Z", 111),
            check_run("docs", "FAILURE", "2026-11-21T01:00:00Z", 111),
            check_run("docs", "SUCCESS", "2026-11-21T02:00:00Z", 222),
            lint.clone(),
        ],
    );
    assert_eq!(codes(&result(&env.run(&ARGS))), ["check_failed"]);
    // Controls: a re-run inside one workflow run replaces its earlier failure,
    // and two passing runs pass.
    with_rollup(
        &env,
        vec![
            check_run("build", "FAILURE", "2026-11-21T01:00:00Z", 111),
            check_run("build", "SUCCESS", "2026-11-21T02:00:00Z", 111),
            check_run("build", "SUCCESS", "2026-11-21T02:00:00Z", 222),
            lint,
        ],
    );
    let out = env.run(&ARGS);
    assert_eq!(out.code, 0, "{}", out.stderr);
}

#[test]
fn an_app_known_from_a_check_run_is_not_looked_up_so_a_private_app_does_not_fail_the_read() {
    let env = ready();
    put(&env, "rules.json", &pinned_ruleset());
    // `apps/github-actions` answers 404 (no app file); the run carries the id.
    put(
        &env,
        "check-runs.json",
        &json!({"total_count": 1, "check_runs": [
            {"name": "lint", "status": "completed", "conclusion": "success", "started_at": "2026-11-21T01:00:00Z",
             "app": {"id": 15368, "slug": "github-actions"}}]}),
    );
    put(
        &env,
        "statuses.json",
        &json!([status_of(
            "github-actions[bot]",
            "Bot",
            "success",
            "2026-11-21T02:00:00Z"
        )]),
    );
    let out = env.run(&ARGS);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(env.gh_calls().iter().all(|c| !c.starts_with("api apps/")));
}

#[test]
fn a_cancelled_required_run_is_excused_by_a_later_pass_of_the_same_workflow() {
    let env = ready();
    let entry = |run: u64, conclusion: &str, at: &str| {
        json!({"__typename": "CheckRun", "name": "build", "workflowName": "CI", "status": "COMPLETED",
            "conclusion": conclusion, "startedAt": at,
            "detailsUrl": format!("https://github.com/example/tidepool/actions/runs/{run}/job/1")})
    };
    let mut view = pr_view("OPEN", &["bug"], "Fixes #5");
    view["statusCheckRollup"] = json!([
        entry(10, "CANCELLED", "2026-11-21T01:00:00Z"),
        entry(11, "SUCCESS", "2026-11-21T01:05:00Z"),
        {"__typename": "StatusContext", "context": "lint", "state": "SUCCESS", "startedAt": "2026-11-21T01:00:00Z"}
    ]);
    put(&env, "pr-view-12.json", &view);
    let workflow = |id: u64, workflow_id: u64| json!({"id": id, "workflow_id": workflow_id, "event": "pull_request", "head_sha": HEAD, "status": "completed", "conclusion": "success"});
    // Another workflow's later pass does not excuse it.
    put(
        &env,
        "workflow-runs.json",
        &json!({"total_count": 2, "workflow_runs": [workflow(10, 7), workflow(11, 8)]}),
    );
    let out = env.run(&ARGS);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(codes(&result(&out)), ["required_check"]);
    // The same workflow's does.
    put(
        &env,
        "workflow-runs.json",
        &json!({"total_count": 2, "workflow_runs": [workflow(10, 7), workflow(11, 7)]}),
    );
    let out = env.run(&ARGS);
    assert_eq!(out.code, 0, "{}", out.stderr);
}

fn note(env: &Env) -> String {
    env.write("note.md", "Merged by the gate.\n").display().to_string()
}

#[test]
fn a_note_file_is_posted_after_the_merge_and_its_url_is_printed() {
    let env = ready();
    let file = note(&env);
    let out = env.run(&["merge-gate", "--unit", "3", "--pr", "12", "--note-file", &file]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let r = result(&out);
    assert_eq!(r["merged"], true);
    assert_eq!(
        r["note_url"],
        "https://github.com/example/tidepool/pull/12#issuecomment-5001"
    );
    let calls = env.gh_calls();
    let at = |what: &str| calls.iter().position(|c| c.starts_with(what)).expect(what);
    assert!(at("issue comment") > at("pr merge"), "{calls:?}");
    assert!(
        calls[at("issue comment")].starts_with("issue comment 12 --repo example/tidepool --body-file"),
        "{calls:?}"
    );
}

#[test]
fn a_note_that_fails_to_post_leaves_the_merge_standing() {
    let env = ready();
    env.stub_file("fail-comment", "");
    let file = note(&env);
    let out = env.run(&["merge-gate", "--unit", "3", "--pr", "12", "--note-file", &file]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let r = result(&out);
    assert_eq!(r["merged"], true);
    assert_eq!(r["note_url"], Value::Null);
    assert!(
        out.stderr.contains("warning") && out.stderr.contains(&file),
        "{}",
        out.stderr
    );
}

#[test]
fn a_dry_run_says_it_would_comment_and_posts_nothing() {
    let env = ready();
    let file = note(&env);
    let out = env.run(&[
        "merge-gate",
        "--unit",
        "3",
        "--pr",
        "12",
        "--dry-run",
        "--note-file",
        &file,
    ]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stdout.contains("WOULD: gh issue comment 12"), "{}", out.stdout);
    assert_eq!(result(&out)["note_url"], Value::Null);
    assert!(env.gh_calls().iter().all(|c| !c.starts_with("issue comment")));
}

#[test]
fn a_note_that_is_not_there_is_refused_before_anything_is_merged() {
    let env = ready();
    let out = env.run(&[
        "merge-gate",
        "--unit",
        "3",
        "--pr",
        "12",
        "--note-file",
        "/no/such/note.md",
    ]);
    assert_eq!(out.code, 2, "{}", out.stderr);
    assert!(merged_calls(&env).is_empty());
}

const MARKER: &str = "<!-- issue-drain:merge-note head=0123456789abcdef0123456789abcdef01234567 -->";

fn comment_calls(env: &Env) -> Vec<String> {
    env.gh_calls()
        .into_iter()
        .filter(|c| c.starts_with("issue comment"))
        .collect()
}

/// PR 12 already merged and the unit's own, as a driver retrying after exit 4 sees it.
fn merged_pr(env: &Env) {
    let mut view = pr_view("MERGED", &[], "");
    view["mergeCommit"] = json!({"oid": "fedcba9876543210fedcba9876543210fedcba98"});
    put(env, "pr-view-12.json", &view);
}

#[test]
fn a_retry_after_a_queued_merge_posts_the_note_once() {
    let env = ready();
    merged_pr(&env);
    env.stub_file("user.txt", "someone\n");
    let file = note(&env);
    let args = ["merge-gate", "--unit", "3", "--pr", "12", "--note-file", &file];
    comments(&env, &[comment("an unrelated comment", "OWNER")]);
    let out = env.run(&args);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let r = result(&out);
    assert_eq!(
        (r["merged"].as_bool(), r["already"].as_bool()),
        (Some(true), Some(true))
    );
    assert_eq!(
        r["note_url"],
        "https://github.com/example/tidepool/pull/12#issuecomment-5001"
    );
    assert_eq!(comment_calls(&env).len(), 1);
    let body = fs::read_to_string(env.stub.join("last-comment-body")).expect("the posted body");
    assert_eq!(body.lines().next(), Some(MARKER), "{body}");
    assert!(body.contains("Merged by the gate."), "{body}");
    // The posted note is now on the PR: a second retry posts nothing.
    comments(&env, &[comment(&body, "OWNER")]);
    let out = env.run(&args);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(result(&out)["note_url"], Value::Null);
    assert_eq!(comment_calls(&env).len(), 1);
    // A marker for another head does not count.
    comments(&env, &[comment(&MARKER.replace("0123", "9999"), "OWNER")]);
    env.run(&args);
    assert_eq!(comment_calls(&env).len(), 2);
}

#[test]
fn a_retry_that_cannot_read_the_comments_warns_and_posts_nothing() {
    let env = ready();
    merged_pr(&env);
    fs::remove_file(env.stub.join("comments.json")).expect("remove");
    let file = note(&env);
    let out = env.run(&["merge-gate", "--unit", "3", "--pr", "12", "--note-file", &file]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stderr.contains("warning"), "{}", out.stderr);
    assert!(comment_calls(&env).is_empty());
}

#[test]
fn a_note_file_named_dash_is_refused_not_read_from_stdin() {
    let env = ready();
    let dir = env.dir.path().join("cwd");
    fs::create_dir_all(&dir).expect("dir");
    fs::write(dir.join("-"), "text\n").expect("a file named -");
    let out = env.run_in(
        Some(&dir),
        &["merge-gate", "--unit", "3", "--pr", "12", "--note-file", "-"],
    );
    assert_eq!(out.code, 2, "{}", out.stderr);
    assert!(merged_calls(&env).is_empty());
}

fn comment_by(login: &str, body: &str) -> Value {
    json!({"body": body, "author_association": "OWNER", "user": {"login": login}})
}

#[test]
fn only_our_own_comment_that_opens_with_the_marker_counts_as_the_posted_note() {
    let env = ready();
    merged_pr(&env);
    env.stub_file("user.txt", "someone\n");
    let file = note(&env);
    let args = ["merge-gate", "--unit", "3", "--pr", "12", "--note-file", &file];
    let marked = format!("{MARKER}\n\nMerged by the gate.\n");
    // Someone else's comment with the marker does not count.
    comments(&env, &[comment_by("mallory", &marked)]);
    env.run(&args);
    assert_eq!(comment_calls(&env).len(), 1);
    // Nor does our own comment that only quotes it further down.
    comments(&env, &[comment_by("someone", &format!("quoting\n{marked}"))]);
    env.run(&args);
    assert_eq!(comment_calls(&env).len(), 2);
    // Ours, opening with it, does.
    comments(&env, &[comment_by("someone", &marked)]);
    env.run(&args);
    assert_eq!(comment_calls(&env).len(), 2);
}

#[test]
fn a_retry_that_cannot_tell_who_it_is_warns_and_posts_nothing() {
    let env = ready();
    merged_pr(&env);
    comments(&env, &[comment("an unrelated comment", "OWNER")]);
    let file = note(&env);
    let out = env.run(&["merge-gate", "--unit", "3", "--pr", "12", "--note-file", &file]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stderr.contains("warning"), "{}", out.stderr);
    assert!(comment_calls(&env).is_empty());
}

#[test]
fn posting_a_note_leaves_every_existing_file_in_the_unit_folder_alone() {
    let env = ready();
    // A draft where the old code staged its copy, and the note file itself.
    let draft = env.write("units/3/merge-note.md", "my draft\n");
    let out = env.run(&[
        "merge-gate",
        "--unit",
        "3",
        "--pr",
        "12",
        "--note-file",
        &draft.display().to_string(),
    ]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(fs::read_to_string(&draft).unwrap(), "my draft\n");
    let body = fs::read_to_string(env.stub.join("last-comment-body")).expect("the posted body");
    assert!(body.starts_with(MARKER) && body.contains("my draft"), "{body}");
    // The staged copy is gone.
    let staged: Vec<_> = fs::read_dir(draft.parent().unwrap())
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with("merge-note"))
        .collect();
    assert_eq!(staged, ["merge-note.md"]);
}

#[test]
fn a_dry_run_writes_no_file() {
    let env = ready();
    let draft = env.write("units/3/merge-note.md", "my draft\n");
    let out = env.run(&[
        "merge-gate",
        "--unit",
        "3",
        "--pr",
        "12",
        "--dry-run",
        "--note-file",
        &draft.display().to_string(),
    ]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(fs::read_to_string(&draft).unwrap(), "my draft\n");
    let names: Vec<_> = fs::read_dir(draft.parent().unwrap())
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with("merge-note"))
        .collect();
    assert_eq!(names, ["merge-note.md"]);
}

#[test]
fn a_retry_on_a_merged_pr_reports_it_merged_even_when_the_note_file_is_gone() {
    let env = ready();
    merged_pr(&env);
    for bad in ["/no/such/note.md", "-"] {
        let out = env.run(&["merge-gate", "--unit", "3", "--pr", "12", "--note-file", bad]);
        assert_eq!(out.code, 0, "{bad}: {}", out.stderr);
        let r = result(&out);
        assert_eq!(
            (r["merged"].as_bool(), r["already"].as_bool()),
            (Some(true), Some(true))
        );
        assert_eq!(r["note_url"], Value::Null);
        assert!(r["note_warning"].as_str().unwrap().contains(bad), "{r}");
        assert!(out.stderr.contains("warning"), "{}", out.stderr);
    }
    assert!(comment_calls(&env).is_empty());
}
