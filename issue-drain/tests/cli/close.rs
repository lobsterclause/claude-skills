//! `issue-drain close-verified`. Each refusal has a control beside it that
//! passes: `a_ticked_closure_is_commented_then_closed` is the same setup with
//! nothing wrong.

use std::fs;

use serde_json::{Value, json};

use crate::common::*;

const CLOSURE_BOX: &str = "- [ ] close #101 ·";
const TICKED_CLOSURE: &str = "- [x] close #101 ·";
const MARKER: &str = "<!-- issue-drain:closure run=run -->";
const ARGS: [&str; 4] = ["close-verified", "--ref", "develop", "--no-fetch"];

fn tracker_md() -> String {
    fs::read_to_string(fixtures().join("run/tracker.md")).expect("the golden tracker")
}

fn ticked() -> String {
    let body = tracker_md();
    assert!(body.contains(CLOSURE_BOX), "the golden tracker lost its closure box");
    body.replacen(CLOSURE_BOX, TICKED_CLOSURE, 1)
}

fn tracker(env: &Env, body: &str, state: &str) {
    env.stub_file(
        "issue-view-900.json",
        &json!({"body": body, "state": state}).to_string(),
    );
}

fn issue(env: &Env, number: u64, state: &str, labels: &[&str], comments: &[&str]) {
    let labels: Vec<Value> = labels.iter().map(|l| json!({"name": l})).collect();
    let comments: Vec<Value> = comments.iter().map(|c| json!({"body": c})).collect();
    env.stub_file(
        &format!("issue-view-{number}.json"),
        &json!({"state": state, "labels": labels, "comments": comments}).to_string(),
    );
}

/// A published run whose tracker has #101 ticked, and #101 open and unlabelled.
fn ready() -> Env {
    let env = Env::new();
    env.seed(&["queue.json", "verdicts.checked.json", "issues"]);
    env.write(
        "tracker.json",
        r#"{"number": 900, "url": "https://github.com/example/tidepool/issues/900", "run": "run", "published_at": "2026-11-21T03:53:00Z"}"#,
    );
    tracker(&env, &ticked(), "OPEN");
    issue(&env, 101, "OPEN", &["bug", "p2"], &["a first comment"]);
    env
}

/// The calls that change something on GitHub.
fn writes(env: &Env) -> Vec<String> {
    env.gh_calls()
        .into_iter()
        .filter(|c| !c.starts_with("issue view"))
        .collect()
}

fn refused_all(env: &Env, out: &Out, why: &str) {
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains(why), "{}", out.stderr);
    assert_eq!(writes(env), Vec::<String>::new());
    let events = env.events_named("closure_refused");
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["number"], Value::Null);
}

fn refused_one(env: &Env, out: &Out, why: &str) {
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stdout.contains("refused #101: "), "{}", out.stdout);
    assert!(out.stdout.contains(why), "{}", out.stdout);
    assert_eq!(writes(env), Vec::<String>::new());
    assert_eq!(env.events_named("closure_refused")[0]["number"], 101);
    assert!(env.events_named("closure").is_empty());
}

#[test]
fn a_ticked_closure_is_commented_then_closed() {
    let env = ready();
    let out = env.run(&ARGS);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stdout.contains("closed #101 (fixed by 4b960d3)"), "{}", out.stdout);

    let w = writes(&env);
    assert_eq!(w.len(), 2, "{w:?}");
    assert!(w[0].starts_with("issue comment 101 "), "{w:?}");
    assert!(w[1].starts_with("issue close 101 "), "{w:?}");

    let comment = fs::read_to_string(env.workdir.join("closures/101.md")).expect("the comment");
    let lines: Vec<&str> = comment.lines().collect();
    assert_eq!(lines[0], MARKER);
    assert_eq!(lines[1], "Closing as already fixed on `develop`.");
    assert!(
        comment.contains(
            "The fix is [`4b960d3`](https://github.com/example/tidepool/commit/4b960d35c51fd2ea594ba28136452eff970e3eb9), \
             \"fix(auth): clear the badge count on logout (#12)\", committed 2026-10-15."
        ),
        "{comment}"
    );
    assert!(
        comment.contains("- [`src/auth/session.ts:16`](https://github.com/example/tidepool/blob/"),
        "{comment}"
    );
    assert!(comment.contains("/src/auth/session.ts#L16): `"), "{comment}");
    assert!(
        comment.contains("Re-read logout(): the reset is unconditional and nothing else caches the count."),
        "{comment}"
    );
    assert!(
        comment.contains("Checked by issue-drain run `run` and approved on #900. Reopen this if it still reproduces."),
        "{comment}"
    );
    assert!(!comment.contains('\u{2014}'), "no em dash in a closing comment");

    let events = env.events_named("closure");
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["number"], 101);
    assert_eq!(events[0]["fix_commit"], "4b960d35c51fd2ea594ba28136452eff970e3eb9");
    assert_eq!(events[0]["tracker"], 900);
}

#[test]
fn naming_the_ticked_number_closes_just_that_one() {
    let env = ready();
    let out = env.run(&["close-verified", "101", "--ref", "develop", "--no-fetch"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(writes(&env).len(), 2);
}

#[test]
fn nothing_ticked_is_nothing_to_do() {
    let env = ready();
    tracker(&env, &tracker_md(), "OPEN");
    let out = env.run(&ARGS);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(
        out.stdout.contains("no closure is ticked on the tracker"),
        "{}",
        out.stdout
    );
    assert_eq!(writes(&env), Vec::<String>::new());
}

#[test]
fn a_stop_line_refuses_every_closure() {
    let env = ready();
    tracker(&env, &format!("{}\nSTOP\n", ticked()), "OPEN");
    refused_all(&env, &env.run(&ARGS), "the tracker says STOP");
}

#[test]
fn a_ticked_line_the_run_never_offered_refuses_every_closure() {
    let env = ready();
    tracker(&env, &format!("{}\n- [x] close #999 · sneaked in\n", ticked()), "OPEN");
    refused_all(&env, &env.run(&ARGS), "a ticked line this run never offered");
}

#[test]
fn a_closed_tracker_refuses_every_closure() {
    let env = ready();
    tracker(&env, &ticked(), "CLOSED");
    refused_all(&env, &env.run(&ARGS), "the tracker issue is closed");
}

#[test]
fn a_number_that_is_not_ticked_refuses_every_closure() {
    let env = ready();
    let out = env.run(&["close-verified", "101", "102", "--ref", "develop", "--no-fetch"]);
    refused_all(&env, &out, "#102 is not a ticked closure on the tracker");
}

#[test]
fn a_body_file_is_for_dry_runs_only() {
    let env = ready();
    let body = env.write("body.md", &ticked()).display().to_string();
    let out = env.run(&["close-verified", "--ref", "develop", "--no-fetch", "--body-file", &body]);
    assert_eq!(out.code, 2);
    assert!(out.stderr.contains("--body-file is for dry runs"), "{}", out.stderr);
    assert_eq!(env.gh_calls(), Vec::<String>::new());
}

#[test]
fn a_dry_run_writes_the_comment_file_and_calls_nothing() {
    let mut env = ready();
    env.set("ISSUE_DRAIN_DRY_RUN", "1");
    fs::remove_file(env.workdir.join("tracker.json")).expect("unpublish");
    let body = env.write("body.md", &ticked()).display().to_string();
    let out = env.run(&["close-verified", "--ref", "develop", "--no-fetch", "--body-file", &body]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stdout.contains("WOULD: gh issue comment 101"), "{}", out.stdout);
    assert!(out.stdout.contains("WOULD: gh issue close 101"), "{}", out.stdout);
    assert!(
        out.stdout.contains("would close #101 (fixed by 4b960d3)"),
        "{}",
        out.stdout
    );
    assert_eq!(writes(&env), Vec::<String>::new());
    let comment = fs::read_to_string(env.workdir.join("closures/101.md")).expect("the comment");
    assert!(
        comment.contains("Checked by issue-drain run `run`. Reopen this"),
        "{comment}"
    );
    assert!(env.events_named("closure").is_empty());
}

#[test]
fn an_issue_closed_already_is_skipped() {
    let env = ready();
    issue(&env, 101, "CLOSED", &[], &[]);
    let out = env.run(&ARGS);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stdout.contains("skipped #101: already closed"), "{}", out.stdout);
    assert_eq!(writes(&env), Vec::<String>::new());
    assert_eq!(env.events_named("closure_skipped")[0]["number"], 101);
}

#[test]
fn a_hold_or_claim_label_added_since_triage_refuses() {
    for (label, shown) in [("Blocked", "blocked"), ("agent-in-progress", "agent-in-progress")] {
        let env = ready();
        issue(&env, 101, "OPEN", &["bug", label], &[]);
        refused_one(&env, &env.run(&ARGS), &format!("it now carries the label '{shown}'"));
    }
}

#[test]
fn a_comment_already_posted_is_not_posted_twice() {
    let env = ready();
    issue(
        &env,
        101,
        "OPEN",
        &[],
        &[&format!("{MARKER}\nClosing as already fixed")],
    );
    let out = env.run(&ARGS);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let w = writes(&env);
    assert_eq!(w.len(), 1, "{w:?}");
    assert!(w[0].starts_with("issue close 101 "), "{w:?}");
}

#[test]
fn a_close_that_did_not_take_is_a_failure_not_a_closure() {
    let mut env = ready();
    env.set("GH_STUB_CLOSE_NOOP", "1");
    let out = env.run(&ARGS);
    assert_eq!(out.code, 1);
    assert!(
        out.stderr.contains("#101 is still OPEN after the close call"),
        "{}",
        out.stderr
    );
    assert!(env.events_named("closure").is_empty());
    assert_eq!(env.events_named("closure_failed")[0]["state"], "OPEN");
}

#[test]
fn code_that_changed_since_triage_refuses() {
    let mut env = ready();
    let repo = private_repo(env.dir.path());
    env.set("ISSUE_DRAIN_REPO_DIR", &repo.display().to_string());
    // Control: the private copy closes as the shared one does.
    assert_eq!(env.run(&["close-verified", "--ref", "develop", "--no-fetch"]).code, 0);
    fs::remove_file(env.stub.join("closed-101")).expect("reopen");
    fs::remove_file(env.dir.path().join("gh.log")).expect("clear the call log");
    fs::remove_file(env.workdir.join("events.jsonl")).expect("clear the events");

    fs::write(repo.join("src/auth/session.ts"), "export {};\n").expect("the edit");
    git(
        &repo,
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@example.invalid",
            "commit",
            "-q",
            "-am",
            "refactor: drop the session module",
        ],
    );
    refused_one(&env, &env.run(&ARGS), "on develop it no longer checks out as fixed");
}

#[test]
fn a_different_fixing_commit_than_the_tracker_showed_refuses() {
    let env = ready();
    let mut queue = golden("queue.json");
    queue["closures"][0]["fix_commit"]["sha"] = json!("0123456789abcdef0123456789abcdef01234567");
    env.write("queue.json", &queue.to_string());
    refused_one(
        &env,
        &env.run(&ARGS),
        "the tracker showed 0123456 as the fix, and the quoted line now comes from 4b960d3",
    );
}

#[test]
fn an_issue_with_no_local_record_cannot_be_dated_and_refuses() {
    let env = ready();
    fs::remove_file(env.workdir.join("issues/101.json")).expect("drop the record");
    refused_one(&env, &env.run(&ARGS), "it no longer checks out as fixed");
}

#[test]
fn a_gh_failure_reading_the_issue_exits_1() {
    let env = ready();
    fs::remove_file(env.stub.join("issue-view-101.json")).expect("drop the answer");
    let out = env.run(&ARGS);
    assert_eq!(out.code, 1);
    assert!(out.stderr.contains("could not read #101"), "{}", out.stderr);
    assert_eq!(writes(&env), Vec::<String>::new());
}

#[test]
fn the_base_is_fetched_unless_told_not_to() {
    // The fixture repo has no remote, so the fetch fails; nothing is closed
    // against a base that could not be refreshed.
    let env = ready();
    let out = env.run(&["close-verified", "--ref", "develop"]);
    assert_eq!(out.code, 1);
    assert!(out.stderr.contains("could not fetch develop"), "{}", out.stderr);
    assert_eq!(writes(&env), Vec::<String>::new());
}

#[test]
fn missing_input_and_bad_arguments_are_usage_errors() {
    let env = ready();
    assert_eq!(env.run(&["close-verified", "abc", "--no-fetch"]).code, 2);
    assert_eq!(env.run(&["close-verified", "--bogus"]).code, 2);

    let unpublished = ready();
    fs::remove_file(unpublished.workdir.join("tracker.json")).expect("unpublish");
    assert_eq!(unpublished.run(&ARGS).code, 2);

    let no_queue = ready();
    fs::remove_file(no_queue.workdir.join("queue.json")).expect("drop the queue");
    let out = no_queue.run(&ARGS);
    assert_eq!(out.code, 2);
    assert!(
        out.stderr.contains("this run has no rendered tracker"),
        "{}",
        out.stderr
    );
    assert_eq!(env.gh_calls(), Vec::<String>::new());
}
