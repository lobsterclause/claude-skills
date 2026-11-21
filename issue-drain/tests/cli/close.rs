//! `issue-drain close-verified`. Each refusal has a control beside it that
//! passes: `a_ticked_closure_is_commented_then_closed` is the same setup with
//! nothing wrong.

use std::fs;

use serde_json::{Value, json};

use crate::common::*;

const CLOSURE_BOX: &str = "- [ ] close #101 ·";
const TICKED_CLOSURE: &str = "- [x] close #101 ·";
const MARKER: &str = "<!-- issue-drain:closure run=run -->";
/// A live run takes no --ref and no --no-fetch: it fetches origin's base.
const ARGS: [&str; 1] = ["close-verified"];
const DRY_ARGS: [&str; 4] = ["close-verified", "--ref", "develop", "--no-fetch"];

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

/// The issue as gh shows it. Every comment is the viewer's own.
fn issue(env: &Env, number: u64, state: &str, labels: &[&str], comments: &[&str]) {
    let comments: Vec<(&str, bool)> = comments.iter().map(|c| (*c, true)).collect();
    issue_with(env, number, state, labels, &comments);
}

/// The same, with each comment marked as the viewer's own or someone else's.
/// The title and body are the ones intake saved.
fn issue_with(env: &Env, number: u64, state: &str, labels: &[&str], comments: &[(&str, bool)]) {
    let saved = json(&fixtures().join(format!("run/issues/{number}.json")));
    issue_text(env, number, state, labels, comments, &saved["title"], &saved["body"]);
}

#[allow(clippy::too_many_arguments)]
fn issue_text(
    env: &Env,
    number: u64,
    state: &str,
    labels: &[&str],
    comments: &[(&str, bool)],
    title: &Value,
    body: &Value,
) {
    let labels: Vec<Value> = labels.iter().map(|l| json!({"name": l})).collect();
    let comments: Vec<Value> = comments
        .iter()
        .map(|(body, own)| json!({"body": body, "viewerDidAuthor": own}))
        .collect();
    env.stub_file(
        &format!("issue-view-{number}.json"),
        &json!({"state": state, "labels": labels, "comments": comments, "title": title, "body": body}).to_string(),
    );
}

/// A published run whose tracker has #101 ticked, and #101 open and unlabelled.
/// The checkout is a clone of the fixture repo with tidepool as its origin.
fn ready() -> Env {
    let mut env = Env::new();
    let checkout = origin_clone(env.dir.path(), fixture_repo());
    env.set("ISSUE_DRAIN_REPO_DIR", &checkout.display().to_string());
    publish(&env);
    env
}

/// The run folder and the stub answers `ready` sets up, without a checkout.
fn publish(env: &Env) {
    env.seed(&["queue.json", "verdicts.checked.json", "issues"]);
    env.write(
        "tracker.json",
        r#"{"number": 900, "url": "https://github.com/example/tidepool/issues/900", "run": "run", "published_at": "2026-11-21T03:53:00Z"}"#,
    );
    tracker(env, &ticked(), "OPEN");
    issue(env, 101, "OPEN", &["bug", "p2"], &["a first comment"]);
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
    let out = env.run(&["close-verified", "101"]);
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
    let out = env.run(&["close-verified", "101", "102"]);
    refused_all(&env, &out, "#102 is not a ticked closure on the tracker");
}

#[test]
fn a_body_file_is_for_dry_runs_only() {
    let env = ready();
    let body = env.write("body.md", &ticked()).display().to_string();
    let out = env.run(&["close-verified", "--body-file", &body]);
    assert_eq!(out.code, 2);
    assert!(out.stderr.contains("--body-file is for dry runs"), "{}", out.stderr);
    assert_eq!(env.gh_calls(), Vec::<String>::new());
}

#[test]
fn a_named_ref_and_a_skipped_fetch_are_for_dry_runs_only() {
    // Either would let a closure be checked on code that is not the base as
    // it is now: a stale local branch, or any ref at all.
    for args in [
        &DRY_ARGS[..],
        &["close-verified", "--ref", "develop"],
        &["close-verified", "--no-fetch"],
    ] {
        let env = ready();
        let out = env.run(args);
        assert_eq!(out.code, 2, "{args:?}");
        assert!(
            out.stderr
                .contains("--ref and --no-fetch are for dry runs; a live closure is checked on origin/develop"),
            "{}",
            out.stderr
        );
        assert_eq!(env.gh_calls(), Vec::<String>::new());
    }
}

#[test]
fn a_checkout_of_another_repo_refuses_every_closure() {
    let env = ready();
    let checkout = env.dir.path().join("checkout");
    git(
        &checkout,
        &["config", "remote.origin.url", "https://github.com/example/other.git"],
    );
    refused_all(&env, &env.run(&ARGS), "has origin example/other, not example/tidepool");

    let no_origin = ready();
    git(&no_origin.dir.path().join("checkout"), &["remote", "remove", "origin"]);
    refused_all(
        &no_origin,
        &no_origin.run(&ARGS),
        "has origin unset, not on github.com, or set to more than one repo, not example/tidepool",
    );
}

#[test]
fn a_queue_rendered_for_another_repo_is_a_usage_error() {
    let mut env = ready();
    env.set("ISSUE_DRAIN_REPO", "example/other");
    let out = env.run(&ARGS);
    assert_eq!(out.code, 2);
    assert!(
        out.stderr
            .contains("this run's queue is for example/tidepool, and ISSUE_DRAIN_REPO is example/other"),
        "{}",
        out.stderr
    );
    assert_eq!(env.gh_calls(), Vec::<String>::new());

    // Control: GitHub does not tell owner and repo names apart by case.
    let mut same = ready();
    same.set("ISSUE_DRAIN_REPO", "Example/Tidepool");
    let out = same.run(&ARGS);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(same.events_named("closure").len(), 1);
}

#[test]
fn the_tracker_is_read_again_after_the_code_is_checked() {
    // The evidence check sits between the first read of the issue and the
    // second. The tracker's second read belongs after it, beside the issue's:
    // a STOP typed while the code was being checked must stop the write.
    let env = ready();
    assert_eq!(env.run(&ARGS).code, 0);
    let views: Vec<String> = env
        .gh_calls()
        .iter()
        .filter_map(|c| c.strip_prefix("issue view "))
        .filter_map(|c| c.split(' ').next().map(str::to_string))
        .collect();
    assert_eq!(views[..4], ["900", "101", "900", "101"], "{views:?}");
}

#[test]
fn a_tag_named_like_the_base_does_not_stand_in_for_it() {
    // git reads `origin/develop` as the tag of that name before the remote
    // branch. The closure is checked on the branch that was just fetched.
    let env = ready();
    let checkout = env.dir.path().join("checkout");
    let root = git(&checkout, &["rev-list", "--max-parents=0", "HEAD"]);
    git(&checkout, &["tag", "origin/develop", &root]);
    let out = env.run(&ARGS);
    assert_eq!(out.code, 0, "{}{}", out.stdout, out.stderr);
    assert_eq!(env.events_named("closure").len(), 1);
}

#[test]
fn a_stop_added_after_the_run_began_refuses_every_closure() {
    // The tracker is read once for the whole run and again for each closure,
    // after its evidence check. The second read is the one that sees the STOP.
    let env = ready();
    env.stub_file(
        "issue-view-900.next.json",
        &json!({"body": format!("{}\nSTOP\n", ticked()), "state": "OPEN"}).to_string(),
    );
    refused_all(&env, &env.run(&ARGS), "the tracker now says STOP; stopped before #101");
}

#[test]
fn a_tracker_closed_after_the_run_began_refuses_every_closure() {
    let env = ready();
    env.stub_file(
        "issue-view-900.next.json",
        &json!({"body": ticked(), "state": "CLOSED"}).to_string(),
    );
    refused_all(
        &env,
        &env.run(&ARGS),
        "the tracker issue is now closed; stopped before #101",
    );
}

#[test]
fn a_box_unticked_after_the_run_began_refuses_that_closure() {
    let env = ready();
    env.stub_file(
        "issue-view-900.next.json",
        &json!({"body": tracker_md(), "state": "OPEN"}).to_string(),
    );
    refused_one(&env, &env.run(&ARGS), "its box is no longer ticked on the tracker");
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
fn an_issue_closed_already_is_skipped_even_when_the_code_has_moved() {
    // Without the local record the evidence check fails (the test below).
    // A closed issue is skipped before that check, not refused by it.
    let env = ready();
    issue(&env, 101, "CLOSED", &[], &[]);
    fs::remove_file(env.workdir.join("issues/101.json")).expect("drop the record");
    let out = env.run(&ARGS);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stdout.contains("skipped #101: already closed"), "{}", out.stdout);
    assert!(env.events_named("closure_refused").is_empty());
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
fn a_marker_someone_else_wrote_does_not_stand_in_for_the_comment() {
    // Anyone who can comment can paste the marker. Only the drain's own
    // comment, with the marker as its whole first line, counts as posted.
    let theirs = format!("{MARKER}\nnothing to see");
    let quoted = format!("{MARKER} and more\nClosing as already fixed");
    let env = ready();
    issue_with(&env, 101, "OPEN", &[], &[(&theirs, false), (&quoted, true)]);
    let out = env.run(&ARGS);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let w = writes(&env);
    assert_eq!(w.len(), 2, "{w:?}");
    assert!(w[0].starts_with("issue comment 101 "), "{w:?}");
    assert!(w[1].starts_with("issue close 101 "), "{w:?}");
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
    // The change lands upstream; the run's own fetch is what brings it in.
    let mut env = Env::new();
    let repo = private_repo(env.dir.path());
    let checkout = origin_clone(env.dir.path(), &repo);
    env.set("ISSUE_DRAIN_REPO_DIR", &checkout.display().to_string());
    publish(&env);
    // Control: the private copy closes as the shared one does.
    assert_eq!(env.run(&ARGS).code, 0);
    fs::remove_file(env.stub.join("closed-101")).expect("reopen");
    fs::remove_file(env.dir.path().join("gh.log")).expect("clear the call log");
    fs::remove_file(env.workdir.join("events.jsonl")).expect("clear the events");

    drop_the_session_module(&repo);
    refused_one(
        &env,
        &env.run(&ARGS),
        "on origin/develop it no longer checks out as fixed",
    );
}

#[test]
fn a_report_edited_since_intake_refuses() {
    // The closure was approved for the report as intake saved it. A body the
    // reporter has since changed is a report nobody triaged.
    let env = ready();
    let saved = json(&fixtures().join("run/issues/101.json"));
    let edited = json!(format!(
        "{}\n\nEdit: it still happens after a token refresh.",
        saved["body"].as_str().expect("a body")
    ));
    issue_text(&env, 101, "OPEN", &["bug"], &[], &saved["title"], &edited);
    refused_one(
        &env,
        &env.run(&ARGS),
        "its title or body was edited after the tracker was rendered",
    );

    // The same text with GitHub's line endings is the same report.
    let env = ready();
    let crlf = json!(saved["body"].as_str().expect("a body").replace('\n', "\r\n"));
    issue_text(&env, 101, "OPEN", &["bug"], &[], &saved["title"], &crlf);
    assert_eq!(env.run(&ARGS).code, 0);
}

#[test]
fn a_later_change_to_the_quoted_file_refuses() {
    // The quoted line and its blame are untouched, but the file around it is
    // not the one that was read at triage: an early return above the fix
    // would look the same to the evidence check.
    let mut env = Env::new();
    let repo = private_repo(env.dir.path());
    let checkout = origin_clone(env.dir.path(), &repo);
    env.set("ISSUE_DRAIN_REPO_DIR", &checkout.display().to_string());
    publish(&env);

    // Control: a commit to another file leaves the closure alone.
    fs::write(repo.join("NOTES.md"), "a note\n").expect("the note");
    git(&repo, &["add", "NOTES.md"]);
    commit_all(&repo, "docs: a note");
    assert_eq!(env.run(&ARGS).code, 0);
    fs::remove_file(env.stub.join("closed-101")).expect("reopen");
    fs::remove_file(env.dir.path().join("gh.log")).expect("clear the call log");
    fs::remove_file(env.workdir.join("events.jsonl")).expect("clear the events");

    let file = repo.join("src/auth/session.ts");
    let text = fs::read_to_string(&file).expect("the module");
    fs::write(&file, format!("{text}\nexport const LATER = true;\n")).expect("the edit");
    commit_all(&repo, "feat: something later in the same file");
    refused_one(
        &env,
        &env.run(&ARGS),
        "src/auth/session.ts changed on origin/develop after the tracker was rendered",
    );
}

#[test]
fn an_origin_with_a_second_url_refuses_every_closure() {
    // git fetches from the first URL and `git config --get` reads the last.
    // An origin with two is not known to be the repo being drained.
    let env = ready();
    let checkout = env.dir.path().join("checkout");
    let fork = "https://github.com/example/fork.git";
    let target = format!("https://github.com/{REPO}.git");
    let rewrite = format!("url.{}.insteadOf", fixture_repo().display());
    git(&checkout, &["config", "--add", &rewrite, fork]);
    git(&checkout, &["config", "--replace-all", "remote.origin.url", fork]);
    git(&checkout, &["config", "--add", "remote.origin.url", &target]);
    refused_all(&env, &env.run(&ARGS), "not example/tidepool");
}

fn commit_all(repo: &std::path::Path, subject: &str) {
    git(
        repo,
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@example.invalid",
            "commit",
            "-q",
            "-am",
            subject,
        ],
    );
}

/// A commit upstream that removes the line #101's closure quotes.
fn drop_the_session_module(repo: &std::path::Path) {
    fs::write(repo.join("src/auth/session.ts"), "export {};\n").expect("the edit");
    git(
        repo,
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
}

#[test]
fn a_checkout_that_does_not_track_the_base_still_checks_the_base_as_it_is_now() {
    // With a fetch refspec that leaves the base out, `git fetch origin
    // develop` moves FETCH_HEAD and not origin/develop. The closure must be
    // checked on what was fetched, not on the ref the clone left behind.
    let mut env = Env::new();
    let repo = private_repo(env.dir.path());
    let checkout = origin_clone(env.dir.path(), &repo);
    git(
        &checkout,
        &[
            "config",
            "remote.origin.fetch",
            "+refs/heads/release:refs/remotes/origin/release",
        ],
    );
    env.set("ISSUE_DRAIN_REPO_DIR", &checkout.display().to_string());
    publish(&env);
    drop_the_session_module(&repo);
    refused_one(
        &env,
        &env.run(&ARGS),
        "on origin/develop it no longer checks out as fixed",
    );
}

#[test]
fn a_label_added_while_the_code_was_being_checked_refuses() {
    // The issue is read once before the evidence check and again right
    // before the comment. The second read is the one that sees the label.
    let env = ready();
    env.stub_file(
        "issue-view-101.next.json",
        &json!({"state": "OPEN", "labels": [{"name": "blocked"}], "comments": []}).to_string(),
    );
    refused_one(&env, &env.run(&ARGS), "it now carries the label 'blocked'");
}

#[test]
fn an_issue_closed_while_the_code_was_being_checked_is_skipped() {
    let env = ready();
    env.stub_file(
        "issue-view-101.next.json",
        &json!({"state": "CLOSED", "labels": [], "comments": []}).to_string(),
    );
    let out = env.run(&ARGS);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stdout.contains("skipped #101: already closed"), "{}", out.stdout);
    assert_eq!(writes(&env), Vec::<String>::new());
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
fn a_base_that_cannot_be_fetched_closes_nothing() {
    // The remote is gone, so the fetch fails; nothing is closed against a
    // base that could not be refreshed.
    let mut env = Env::new();
    let upstream = private_repo(env.dir.path());
    let checkout = origin_clone(env.dir.path(), &upstream);
    env.set("ISSUE_DRAIN_REPO_DIR", &checkout.display().to_string());
    publish(&env);
    fs::remove_dir_all(&upstream).expect("drop the remote");
    let out = env.run(&ARGS);
    assert_eq!(out.code, 1);
    assert!(out.stderr.contains("could not fetch develop"), "{}", out.stderr);
    assert_eq!(writes(&env), Vec::<String>::new());
}

#[test]
fn missing_input_and_bad_arguments_are_usage_errors() {
    let env = ready();
    assert_eq!(env.run(&["close-verified", "abc"]).code, 2);
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

#[test]
fn a_report_taken_in_again_after_approval_does_not_stand_in_for_the_one_approved() {
    // The tick was given for the report the tracker was rendered from. An
    // intake file written again later holds some other text, and agreeing
    // with it proves nothing.
    let env = ready();
    let mut saved = json(&env.workdir.join("issues/101.json"));
    let edited = json!(format!(
        "{}\n\nEdit: it still happens after a token refresh.",
        saved["body"].as_str().expect("a body")
    ));
    saved["body"] = edited.clone();
    env.write("issues/101.json", &saved.to_string());
    issue_text(&env, 101, "OPEN", &["bug"], &[], &saved["title"], &edited);
    refused_one(
        &env,
        &env.run(&ARGS),
        "its title or body was edited after the tracker was rendered",
    );
}

#[test]
fn a_base_that_moves_while_an_issue_is_checked_stops_the_run() {
    // The base was fetched when the run began. A commit that lands while the
    // first issue is being checked is code nobody held the closure against.
    let mut env = Env::new();
    let repo = private_repo(env.dir.path());
    let checkout = origin_clone(env.dir.path(), &repo);
    env.set("ISSUE_DRAIN_REPO_DIR", &checkout.display().to_string());
    publish(&env);
    fs::write(repo.join("NOTES.md"), "a note\n").expect("the note");
    git(&repo, &["add", "NOTES.md"]);
    env.stub_file(
        "once-issue-view-101",
        &format!(
            "git -C '{}' -c user.name=t -c user.email=t@example.invalid commit -q -m 'docs: a note'\n",
            repo.display()
        ),
    );
    let out = env.run(&ARGS);
    refused_all(&env, &out, "origin/develop moved while #101 was being checked");
    assert!(out.stderr.contains("stopped before #101"), "{}", out.stderr);

    // Control: run again with the base at rest, and it closes.
    fs::remove_file(env.workdir.join("events.jsonl")).expect("clear the events");
    assert_eq!(env.run(&ARGS).code, 0);
    assert_eq!(env.events_named("closure").len(), 1);
}

#[test]
fn a_verdict_checked_again_after_render_does_not_replace_the_evidence_shown() {
    // The tick was given for the lines the tracker quoted. A verdict written
    // again later can quote others, and those were never held against the
    // commit the tracker was rendered at.
    let env = ready();
    let mut checked = json(&env.workdir.join("verdicts.checked.json"));
    for v in checked.as_array_mut().unwrap() {
        if v["number"] == 101 {
            let mut more = v["evidence"][0].clone();
            more["line"] = json!(15);
            v["evidence"].as_array_mut().unwrap().push(more);
        }
    }
    env.write("verdicts.checked.json", &checked.to_string());
    refused_one(
        &env,
        &env.run(&ARGS),
        "its checked evidence is not the evidence the tracker showed",
    );
}

#[test]
fn markup_that_can_hide_a_box_refuses_every_closure() {
    let env = ready();
    tracker(&env, &format!("{}\n```\ncode\n```\n", ticked()), "OPEN");
    refused_all(&env, &env.run(&ARGS), "markup that can hide a box");
}
