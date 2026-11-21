//! `issue-drain tracker publish` and `tracker parse`. Each refusal has a
//! control beside it that passes, so a test cannot go green because everything
//! fails. Edited bodies are built from the golden tracker.md.

use std::fs;

use serde_json::{Value, json};

use crate::common::*;

const CLOSURE_BOX: &str = "- [ ] close #101 ·";
const TICKED_CLOSURE: &str = "- [x] close #101 ·";
const U2_LINE: &str = "- U2 · #104 #105 · Fix pageCount for totals that divide evenly · sonnet/medium · ~45 min · `pnpm vitest run src/list`";

fn tracker_md() -> String {
    fs::read_to_string(fixtures().join("run/tracker.md")).expect("the golden tracker")
}

/// An env with the golden queue, and the given body in a file; returns the
/// `--body-file` path.
fn with_body(env: &Env, body: &str) -> String {
    env.seed(&["queue.json"]);
    env.write("body.md", body).display().to_string()
}

fn parse_body(env: &Env, body: &str) -> Out {
    let path = with_body(env, body);
    env.run(&["tracker", "parse", "--body-file", &path])
}

fn parsed(out: &Out) -> Value {
    serde_json::from_str(out.stdout.trim()).unwrap_or_else(|e| panic!("stdout is one JSON line ({e}): {}", out.stdout))
}

fn replaced(from: &str, to: &str) -> String {
    let body = tracker_md();
    assert!(body.contains(from), "the golden tracker lost {from:?}");
    body.replacen(from, to, 1)
}

#[test]
fn parse_of_the_golden_tracker_finds_the_queue_and_nothing_approved() {
    let env = Env::new();
    let out = parse_body(&env, &tracker_md());
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        parsed(&out),
        json!({
            "run": "run",
            "stop": false,
            // U4 waits for a person: its box is empty, so it is not in the queue.
            "units": ["U1", "U2", "U3"],
            "approved_closures": [],
            "release_claims": [],
            "tracker_state": null,
            "unknown": [],
        })
    );
    assert_eq!(out.stdout.lines().count(), 1, "compact JSON, one line");
    assert!(
        out.stdout
            .starts_with(r#"{"run":"run","stop":false,"units":["U1","U2","U3"],"#)
    );
    let logged = env.events_named("tracker_parsed");
    assert_eq!(logged.len(), 1);
    assert_eq!(logged[0]["units"], 3);
    assert_eq!(logged[0]["stop"], false);
    assert!(env.gh_calls().is_empty());
}

#[test]
fn a_ticked_closure_is_approved_and_an_empty_box_is_not() {
    let env = Env::new();
    let control = parse_body(&env, &tracker_md());
    assert_eq!(parsed(&control)["approved_closures"], json!([]));

    for tick in ["- [x] close #101 ·", "- [X] close #101 ·"] {
        let out = parse_body(&env, &replaced(CLOSURE_BOX, tick));
        assert_eq!(out.code, 0, "{tick}: {}", out.stderr);
        assert_eq!(parsed(&out)["approved_closures"], json!([101]), "{tick}");
    }
}

#[test]
fn a_ticked_waiting_unit_runs_before_the_queue() {
    let env = Env::new();
    let body = replaced("- [ ] U4 ·", "- [x] U4 ·");
    let out = parse_body(&env, &body);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(parsed(&out)["units"], json!(["U4", "U1", "U2", "U3"]));
}

#[test]
fn a_deleted_unit_line_drops_that_unit() {
    let env = Env::new();
    let body = replaced(&format!("{U2_LINE}\n"), "");
    let out = parse_body(&env, &body);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(parsed(&out)["units"], json!(["U1", "U3"]));
    assert_eq!(parsed(&out)["unknown"], json!([]));
}

#[test]
fn moved_unit_lines_are_read_in_the_order_written() {
    let env = Env::new();
    let u2 = format!("{U2_LINE}\n");
    let body = replaced(&u2, "").replacen("## Queue\n\n", &format!("## Queue\n\n{u2}"), 1);
    let out = parse_body(&env, &body);
    assert_eq!(parsed(&out)["units"], json!(["U2", "U1", "U3"]));
}

#[test]
fn a_repeated_unit_line_counts_once() {
    let env = Env::new();
    let body = replaced(&format!("{U2_LINE}\n"), &format!("{U2_LINE}\n{U2_LINE}\n"));
    let out = parse_body(&env, &body);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(parsed(&out)["units"], json!(["U1", "U2", "U3"]));
}

#[test]
fn stop_counts_only_on_a_line_of_its_own() {
    let env = Env::new();
    // The golden body already says `STOP` inside prose and a code span: that is the control.
    assert_eq!(parsed(&parse_body(&env, &tracker_md()))["stop"], false);

    for not_a_stop in [
        "Please do not STOP yet.\n",
        "`STOP`\n",
        "STOPPED\n",
        "- STOP\n",
        "stop\n",
    ] {
        let body = format!("{}\n{not_a_stop}", tracker_md());
        assert_eq!(parsed(&parse_body(&env, &body))["stop"], false, "{not_a_stop:?}");
    }
    for a_stop in ["STOP\n", "  STOP  \n", "\tSTOP\r\n", "STOP"] {
        let body = format!("{}\n{a_stop}", tracker_md());
        let out = parse_body(&env, &body);
        assert_eq!(out.code, 0, "{a_stop:?}: {}", out.stderr);
        assert_eq!(parsed(&out)["stop"], true, "{a_stop:?}");
    }
}

#[test]
fn a_ticked_line_the_run_never_offered_exits_1_and_is_named() {
    let env = Env::new();
    let body = format!(
        "{}\n- [x] close #999 · Something nobody offered\n- [x] U9 · A unit nobody offered\n- [x] release #55 · stale\n",
        tracker_md()
    );
    let out = parse_body(&env, &body);
    assert_eq!(out.code, 1, "{}", out.stderr);
    // The result is still printed, so a caller can read what was found.
    assert_eq!(parsed(&out)["units"], json!(["U1", "U2", "U3"]));
    assert_eq!(parsed(&out)["unknown"], json!(["unit U9", "close #999", "release #55"]));
    for what in ["unit U9", "close #999", "release #55"] {
        assert!(
            out.stderr.contains(&format!(
                "the tracker asks for something this run never offered: {what}"
            )),
            "{}",
            out.stderr
        );
    }
    assert_eq!(env.events_named("tracker_parsed").len(), 1);

    // Control: the same body without those lines is clean.
    assert_eq!(parse_body(&env, &tracker_md()).code, 0);
}

#[test]
fn an_unknown_unit_line_that_is_not_ticked_is_also_reported() {
    let env = Env::new();
    let body = replaced("## Queue\n\n", "## Queue\n\n- U9 · #1 · a line someone typed\n");
    let out = parse_body(&env, &body);
    assert_eq!(out.code, 1);
    assert_eq!(parsed(&out)["unknown"], json!(["unit U9"]));
}

#[test]
fn a_stale_claim_the_queue_offered_is_a_release_the_tracker_can_approve() {
    let env = Env::new();
    let mut queue = golden("queue.json");
    queue["stale_claims"] = json!([{"number": 77, "title": "Stuck", "labeled_at": null, "days": null}]);
    env.write("queue.json", &queue.to_string());
    let body = format!(
        "{}\n- [x] release #77 · Stuck\n- [ ] release #78 · not ticked\n",
        tracker_md()
    );
    let path = env.write("body.md", &body).display().to_string();
    let out = env.run(&["tracker", "parse", "--body-file", &path]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(parsed(&out)["release_claims"], json!([77]));
}

#[test]
fn a_line_with_extra_spaces_approves_nothing() {
    let env = Env::new();
    // Parsing is by exact prefix: a mangled box is not a tick, and not an error.
    for mangled in [
        "-  [x] close #101 ·",
        "- [x]  close #101 ·",
        "-[x] close #101 ·",
        "- [ x] close #101 ·",
    ] {
        let out = parse_body(&env, &replaced(CLOSURE_BOX, mangled));
        assert_eq!(out.code, 0, "{mangled}: {}", out.stderr);
        assert_eq!(parsed(&out)["approved_closures"], json!([]), "{mangled}");
    }
    // A trailing run of spaces after the number is fine ("close #101 " then text).
    let out = parse_body(&env, &replaced(CLOSURE_BOX, "- [x] close #101   ·"));
    assert_eq!(parsed(&out)["approved_closures"], json!([101]));
}

#[test]
fn a_body_with_windows_line_endings_reads_the_same() {
    let env = Env::new();
    let unix = replaced(CLOSURE_BOX, TICKED_CLOSURE);
    let dos = unix.replace('\n', "\r\n");
    let a = parse_body(&env, &unix);
    let b = parse_body(&env, &dos);
    assert_eq!(b.code, 0, "{}", b.stderr);
    assert_eq!(parsed(&a), parsed(&b));
    assert_eq!(parsed(&b)["approved_closures"], json!([101]));
}

#[test]
fn the_body_must_be_this_runs_tracker() {
    let env = Env::new();
    let wrong = tracker_md().replace("run=run", "run=other");
    let out = parse_body(&env, &wrong);
    assert_eq!(out.code, 2);
    assert!(out.stderr.contains("not the tracker for run run"), "{}", out.stderr);
    assert!(out.stderr.contains("says 'other'"), "{}", out.stderr);
    assert!(out.stdout.is_empty());

    let none = tracker_md().replacen("<!-- issue-drain:tracker v1 run=run -->\n", "", 1);
    let out = parse_body(&env, &none);
    assert_eq!(out.code, 2);
    assert!(out.stderr.contains("says 'nothing'"), "{}", out.stderr);

    // The marker can sit anywhere, but only as a line of its own.
    let inline = tracker_md().replacen(
        "<!-- issue-drain:tracker v1 run=run -->",
        "text <!-- issue-drain:tracker v1 run=run -->",
        1,
    );
    assert_eq!(parse_body(&env, &inline).code, 2);
    assert_eq!(parse_body(&env, &tracker_md()).code, 0);
}

#[test]
fn parse_needs_a_queue_a_body_and_known_arguments() {
    let env = Env::new();
    let path = env.write("body.md", &tracker_md()).display().to_string();
    // No queue.json yet.
    let out = env.run(&["tracker", "parse", "--body-file", &path]);
    assert_eq!(out.code, 2);
    assert!(out.stderr.contains("no queue.json"), "{}", out.stderr);

    env.seed(&["queue.json"]);
    assert_eq!(env.run(&["tracker", "parse", "--body-file", &path]).code, 0);

    let out = env.run(&["tracker", "parse", "--body-file", "/nonexistent/body.md"]);
    assert_eq!(out.code, 2);
    assert!(out.stderr.contains("no body file"), "{}", out.stderr);

    // Neither a body file nor a published tracker.
    let out = env.run(&["tracker", "parse"]);
    assert_eq!(out.code, 2);
    assert!(out.stderr.contains("not published"), "{}", out.stderr);

    assert_eq!(env.run(&["tracker", "parse", "--frobnicate"]).code, 2);
    assert!(env.gh_calls().is_empty());
}

fn published(env: &Env) {
    env.seed(&["queue.json"]);
    env.write(
        "tracker.json",
        r#"{"number": 900, "url": "https://github.com/example/tidepool/issues/900", "run": "run", "published_at": "2026-11-21T03:53:00Z"}"#,
    );
}

fn issue_view(env: &Env, body: &str, state: &str) {
    env.stub_file(
        "issue-view-900.json",
        &json!({"body": body, "state": state}).to_string(),
    );
}

#[test]
fn the_live_tracker_is_read_through_gh_with_its_state() {
    let env = Env::new();
    published(&env);
    issue_view(&env, &replaced(CLOSURE_BOX, TICKED_CLOSURE), "OPEN");
    let out = env.run(&["tracker", "parse"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let found = parsed(&out);
    assert_eq!(found["tracker_state"], "OPEN");
    assert_eq!(found["approved_closures"], json!([101]));
    assert_eq!(
        env.gh_calls(),
        [format!("issue view 900 --repo {REPO} --json body,state")]
    );
}

#[test]
fn a_closed_tracker_says_so() {
    let env = Env::new();
    published(&env);
    issue_view(&env, &tracker_md(), "CLOSED");
    let out = env.run(&["tracker", "parse"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(parsed(&out)["tracker_state"], "CLOSED");
    assert_eq!(env.events_named("tracker_parsed")[0]["tracker_state"], "CLOSED");
}

#[test]
fn a_gh_failure_reading_the_tracker_exits_1_and_prints_nothing() {
    let env = Env::new();
    published(&env);
    // Control: with the view in place it reads.
    issue_view(&env, &tracker_md(), "OPEN");
    assert_eq!(env.run(&["tracker", "parse"]).code, 0);

    fs::remove_file(env.stub.join("issue-view-900.json")).expect("remove the view");
    let out = env.run(&["tracker", "parse"]);
    assert_eq!(out.code, 1);
    assert!(out.stderr.contains("could not read tracker #900"), "{}", out.stderr);
    assert!(out.stdout.is_empty());

    env.stub_file("fail", "");
    issue_view(&env, &tracker_md(), "OPEN");
    assert_eq!(env.run(&["tracker", "parse"]).code, 1);
}

#[test]
fn a_body_file_beside_a_published_tracker_reads_the_file_and_not_gh() {
    let env = Env::new();
    published(&env);
    let path = env.write("body.md", &tracker_md()).display().to_string();
    let out = env.run(&["tracker", "parse", "--body-file", &path]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(parsed(&out)["tracker_state"], Value::Null);
    assert!(env.gh_calls().is_empty());
}

fn title() -> String {
    golden("queue.json")["title"].as_str().expect("a title").to_string()
}

fn publish_env() -> Env {
    let env = Env::new();
    env.seed(&["queue.json", "tracker.md"]);
    env
}

#[test]
fn a_dry_run_publish_prints_both_calls_and_makes_none() {
    let mut env = publish_env();
    env.set("ISSUE_DRAIN_DRY_RUN", "1");
    let out = env.run(&["tracker", "publish"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let body = env.workdir.join("tracker.md").display().to_string();
    let lines: Vec<&str> = out.stdout.lines().collect();
    assert_eq!(lines.len(), 2, "{}", out.stdout);
    assert_eq!(lines[0], format!("WOULD: gh label create issue-drain --repo {REPO}"));
    assert_eq!(
        lines[1],
        format!(
            "WOULD: gh issue create --repo {REPO} --title {} --body-file {body} --label issue-drain",
            shlex::try_quote(&title()).expect("quotable")
        )
    );
    assert!(env.gh_calls().is_empty(), "{:?}", env.gh_calls());
    assert!(
        !env.workdir.join("tracker.json").exists(),
        "a dry run publishes nothing"
    );
}

#[test]
fn publish_ensures_the_label_then_creates_the_issue() {
    let mut env = publish_env();
    env.set("GH_STUB_NEW_ISSUE", "4242");
    let out = env.run(&["tracker", "publish"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(out.stdout, "https://github.com/example/tidepool/issues/4242\n");

    let body = env.workdir.join("tracker.md").display().to_string();
    let calls = env.gh_calls();
    assert_eq!(calls.len(), 4, "{calls:?}");
    assert_eq!(calls[0], tracker_list_call());
    assert!(
        calls[1].starts_with(&format!("label list --repo {REPO} --search issue-drain")),
        "{calls:?}"
    );
    assert_eq!(calls[2], format!("label create issue-drain --repo {REPO}"));
    assert_eq!(
        calls[3],
        format!(
            "issue create --repo {REPO} --title {} --body-file {body} --label issue-drain",
            title()
        )
    );

    let saved = json(&env.workdir.join("tracker.json"));
    assert_eq!(
        saved,
        json!({
            "number": 4242,
            "url": "https://github.com/example/tidepool/issues/4242",
            "run": "run",
            "published_at": "2026-11-21T03:53:00Z",
        })
    );
    // The run is found again by the tracker's number.
    let link = env.dir.path().join("tracker-4242");
    assert_eq!(fs::read_link(&link).expect("a symlink"), env.workdir);
    let logged = env.events_named("tracker_published");
    assert_eq!(logged.len(), 1);
    assert_eq!(logged[0]["number"], 4242);
}

#[test]
fn publish_leaves_an_existing_label_alone() {
    let env = publish_env();
    env.stub_file("labels.txt", "Issue-Drain\n");
    let out = env.run(&["tracker", "publish"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let calls = env.gh_calls();
    assert_eq!(calls.len(), 3, "{calls:?}");
    assert!(calls[0].starts_with("issue list"));
    assert!(calls[1].starts_with("label list"));
    assert!(calls[2].starts_with("issue create"));
}

fn tracker_list_call() -> String {
    format!("issue list --repo {REPO} --label issue-drain --author @me --state open --limit 100 --json number,url,body")
}

fn listed(env: &Env, number: u64, body: &str) {
    let url = format!("https://github.com/{REPO}/issues/{number}");
    env.stub_file(
        "tracker-list.json",
        &json!([
            {"number": 7, "url": "https://github.com/example/tidepool/issues/7", "body": "some other issue"},
            {"number": number, "url": url, "body": body},
        ])
        .to_string(),
    );
}

#[test]
fn a_tracker_this_run_already_created_is_adopted_and_not_created_again() {
    // A publish that died after `gh issue create` left an issue and no tracker.json.
    let env = publish_env();
    listed(&env, 4100, &tracker_md().replace('\n', "\r\n"));
    let out = env.run(&["tracker", "publish"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(out.stdout, "https://github.com/example/tidepool/issues/4100\n");
    assert_eq!(env.gh_calls(), [tracker_list_call()]);
    assert_eq!(json(&env.workdir.join("tracker.json"))["number"], 4100);
    assert_eq!(
        fs::read_link(env.dir.path().join("tracker-4100")).expect("a symlink"),
        env.workdir
    );
    assert_eq!(env.events_named("tracker_adopted")[0]["number"], 4100);
    assert!(env.events_named("tracker_published").is_empty());
}

#[test]
fn a_tracker_this_run_created_from_another_render_is_not_adopted() {
    // The publish died, the decisions changed and the run was rendered again.
    // The issue on GitHub shows the earlier offer; ticks on it are not
    // approvals of this queue.
    let env = publish_env();
    listed(
        &env,
        4100,
        &format!("{}\n- an offer the new render dropped\n", tracker_md()),
    );
    let out = env.run(&["tracker", "publish"]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("#4100"), "{}", out.stderr);
    assert!(out.stderr.contains("does not match"), "{}", out.stderr);
    assert_eq!(env.gh_calls(), [tracker_list_call()]);
    assert!(!env.workdir.join("tracker.json").exists());
}

#[test]
fn another_runs_tracker_is_not_adopted() {
    let env = publish_env();
    listed(&env, 4100, &tracker_md().replace("run=run", "run=other"));
    let out = env.run(&["tracker", "publish"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(json(&env.workdir.join("tracker.json"))["number"], 900);
    assert!(env.events_named("tracker_adopted").is_empty());
    assert_eq!(env.events_named("tracker_published").len(), 1);
}

#[test]
fn a_publish_that_cannot_list_the_trackers_creates_nothing() {
    let env = publish_env();
    env.stub_file("fail-list", "");
    let out = env.run(&["tracker", "publish"]);
    assert_eq!(out.code, 1);
    assert!(
        out.stderr.contains("could not list the open trackers"),
        "{}",
        out.stderr
    );
    assert_eq!(env.gh_calls().len(), 1);
    assert!(!env.workdir.join("tracker.json").exists());
    assert!(!env.workdir.join("publish.lock").exists(), "the lock is released");

    env.stub_file("tracker-list.json", "not json");
    fs::remove_file(env.stub.join("fail-list")).expect("remove fail-list");
    assert_eq!(env.run(&["tracker", "publish"]).code, 1);
    assert!(!env.workdir.join("tracker.json").exists());

    // Control: a list that reads lets the publish through.
    fs::remove_file(env.stub.join("tracker-list.json")).expect("remove the list");
    assert_eq!(env.run(&["tracker", "publish"]).code, 0);
}

#[test]
fn a_publish_while_another_holds_the_lock_is_refused_before_any_gh_call() {
    let env = publish_env();
    let lock = env.write("publish.lock", "");
    let out = env.run(&["tracker", "publish"]);
    assert_eq!(out.code, 3);
    assert!(
        out.stderr
            .contains("another render or publish of this run is in progress"),
        "{}",
        out.stderr
    );
    assert!(env.gh_calls().is_empty());
    assert!(lock.exists(), "a lock someone else holds is left alone");

    // Control: with the lock gone the publish runs, and leaves no lock behind.
    fs::remove_file(&lock).expect("remove the lock");
    assert_eq!(env.run(&["tracker", "publish"]).code, 0);
    assert!(!lock.exists());
}

#[test]
fn a_queue_rendered_for_another_repo_is_not_published_or_parsed() {
    let mut env = publish_env();
    let body = env.write("body.md", &tracker_md()).display().to_string();
    env.set("ISSUE_DRAIN_REPO", "example/other");
    for args in [
        vec!["tracker", "publish"],
        vec!["tracker", "parse", "--body-file", &body],
    ] {
        let out = env.run(&args);
        assert_eq!(out.code, 2, "{args:?}: {}", out.stderr);
        assert!(
            out.stderr
                .contains("this queue was rendered for example/tidepool, and ISSUE_DRAIN_REPO is example/other"),
            "{}",
            out.stderr
        );
    }
    assert!(env.gh_calls().is_empty());
    assert!(!env.workdir.join("publish.lock").exists());

    // Control: the same repo in another case is the same repo.
    env.set("ISSUE_DRAIN_REPO", "Example/Tidepool");
    assert_eq!(env.run(&["tracker", "parse", "--body-file", &body]).code, 0);
}

#[test]
fn a_run_reached_through_its_tracker_link_keeps_its_run_id() {
    // publish leaves <repo folder>/tracker-<n> -> the run folder. The run id
    // is the real folder's name, not the link's.
    let mut env = Env::new();
    let body = with_body(&env, &tracker_md());
    let link = env.dir.path().join("tracker-900");
    std::os::unix::fs::symlink(&env.workdir, &link).expect("a symlink");
    env.set("ISSUE_DRAIN_WORKDIR", &link.display().to_string());
    let out = env.run(&["tracker", "parse", "--body-file", &body]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(parsed(&out)["run"], "run");
}

#[test]
fn a_failed_create_exits_1_and_records_no_tracker() {
    let env = publish_env();
    env.stub_file("fail-create", "");
    let out = env.run(&["tracker", "publish"]);
    assert_eq!(out.code, 1);
    assert!(
        out.stderr.contains("gh failed (exit 1): tracker issue"),
        "{}",
        out.stderr
    );
    assert!(!env.workdir.join("tracker.json").exists());
    assert!(env.events_named("tracker_published").is_empty());

    // Control: the failure was the create, so once it works the run publishes.
    fs::remove_file(env.stub.join("fail-create")).expect("remove fail-create");
    assert_eq!(env.run(&["tracker", "publish"]).code, 0);
    assert!(env.workdir.join("tracker.json").exists());
}

#[test]
fn a_second_publish_is_refused_before_any_gh_call() {
    let env = publish_env();
    let first = env.run(&["tracker", "publish"]);
    assert_eq!(first.code, 0, "{}", first.stderr);
    let calls = env.gh_calls().len();
    let url = first.stdout.trim().to_string();

    let again = env.run(&["tracker", "publish"]);
    assert_eq!(again.code, 3);
    assert!(
        again.stderr.contains(&format!("already published: {url}")),
        "{}",
        again.stderr
    );
    assert_eq!(env.gh_calls().len(), calls, "no new gh call");
}

#[test]
fn publish_needs_a_rendered_tracker_and_no_arguments() {
    let env = Env::new();
    for missing in ["queue.json", "tracker.md"] {
        let env = Env::new();
        env.seed(&["queue.json", "tracker.md"]);
        fs::remove_file(env.workdir.join(missing)).expect("remove");
        let out = env.run(&["tracker", "publish"]);
        assert_eq!(out.code, 2, "{missing}: {}", out.stderr);
        assert!(out.stderr.contains("nothing to publish"), "{}", out.stderr);
        assert!(env.gh_calls().is_empty());
    }
    // Control: both present.
    env.seed(&["queue.json", "tracker.md"]);
    assert_eq!(env.run(&["tracker", "publish"]).code, 0);

    assert_eq!(env.run(&["tracker", "publish", "extra"]).code, 2);
}

#[test]
fn markup_that_can_hide_a_box_stops_every_approval() {
    // A box inside a code block or raw HTML is text nobody ticked. Which
    // lines a block covers is GitHub's to decide, so the reader does not
    // decide it: a body with any such markup approves nothing and runs
    // nothing until the markup is gone.
    let env = Env::new();
    let tick = format!("{TICKED_CLOSURE} pasted");
    for markup in [
        format!("```\n{tick}\n```"),
        format!("~~~\n{tick}\n~~~"),
        // A fence in a list item closes on a line indented past three
        // spaces, so the next fence opens a block and does not close one.
        format!("- note\n  ```\n  code\n    ```\n```\n{tick}\n```"),
        format!("    ```\n{tick}"),
        format!("> ```\n{tick}"),
        format!("1. ~~~\n{tick}"),
        format!("<!--\n{tick}\n-->"),
        format!("<pre>\n{tick}\n</pre>"),
        format!("<div>\n{tick}\n</div>"),
        format!("  - <table>\n{tick}"),
    ] {
        let body = format!("{}\n{markup}\n", tracker_md());
        let out = parse_body(&env, &body);
        assert_eq!(out.code, 1, "{markup}: {}", out.stderr);
        let found = parsed(&out);
        assert_eq!(found["approved_closures"], json!([]), "{markup}");
        assert_eq!(found["release_claims"], json!([]), "{markup}");
        assert_eq!(found["units"], json!([]), "{markup}");
        let named = found["unknown"].as_array().expect("a list");
        assert!(!named.is_empty(), "{markup}");
        assert!(
            named.iter().all(|what| what.as_str().unwrap().starts_with("line ")),
            "{markup}: {named:?}"
        );
        assert!(
            out.stderr.contains("markup that can hide a box"),
            "{markup}: {}",
            out.stderr
        );
    }

    // The line is named by its number in the body: a blank line, then it.
    let lines = tracker_md().lines().count();
    let out = parse_body(&env, &format!("{}\n```\n", tracker_md()));
    assert_eq!(
        parsed(&out)["unknown"],
        json!([format!("line {} is a code fence", lines + 2)])
    );

    // Control: the same tick with no markup beside it is a tick.
    let out = parse_body(&env, &format!("{}\n{tick}\n", tracker_md()));
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(parsed(&out)["approved_closures"], json!([101]));

    // STOP is read everywhere: stopping on a line nobody sees costs a re-run.
    let body = format!("{}\n```\nSTOP\n```\n", tracker_md());
    assert_eq!(parsed(&parse_body(&env, &body))["stop"], true);
}

#[test]
fn the_rendered_details_block_is_read_only_as_render_wrote_it() {
    // The two <details> lines are the only HTML render writes. Each stands
    // before a blank line, which is where GitHub ends the HTML and reads
    // Markdown again. Without the blank line what follows is raw HTML.
    let env = Env::new();
    let opener = "each unit</summary>\n";
    let out = parse_body(&env, &replaced(&format!("{opener}\n"), opener));
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert_eq!(parsed(&out)["units"], json!([]));

    let out = parse_body(&env, &format!("{}{TICKED_CLOSURE} pasted\n", tracker_md()));
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert_eq!(parsed(&out)["approved_closures"], json!([]));

    // A line of non-breaking spaces is not blank to GitHub, so the HTML
    // goes on past it.
    let out = parse_body(&env, &replaced(&format!("{opener}\n"), &format!("{opener}\u{a0}\n")));
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert_eq!(parsed(&out)["units"], json!([]));
    // Control: spaces and tabs are blank.
    let out = parse_body(&env, &replaced(&format!("{opener}\n"), &format!("{opener} \t\n")));
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(parsed(&out)["units"], json!(["U1", "U2", "U3"]));

    // Any other HTML line is refused, the details lines changed included.
    let out = parse_body(&env, &replaced("<details><summary>", "<details open><summary>"));
    assert_eq!(out.code, 1, "{}", out.stderr);
}

#[test]
fn a_waiting_unit_runs_only_with_its_box_ticked() {
    // U4 waits for a named review. Its line with the box deleted is not a
    // tick: only "[x]" says a person approved it.
    let env = Env::new();
    let out = parse_body(&env, &replaced("- [ ] U4 ·", "- U4 ·"));
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(parsed(&out)["units"], json!(["U1", "U2", "U3"]));
    assert_eq!(parsed(&out)["unknown"], json!([]));
}

#[test]
fn a_comment_marker_inside_a_line_hides_nothing() {
    // A test command can hold "<!--", and render writes it in a code span.
    // Only a line that starts with HTML starts an HTML block, and a line
    // that starts with "- " starts a list item whatever stands above it.
    let env = Env::new();
    let body = replaced("`pnpm vitest run src/timer`", "`grep -F '<!-- generated -->' out.html`");
    let out = parse_body(&env, &body);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(parsed(&out)["units"], json!(["U1", "U2", "U3"]));

    let body = format!("{}\ntext <!-- a note\n{TICKED_CLOSURE} pasted\n", tracker_md());
    let out = parse_body(&env, &body);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(parsed(&out)["approved_closures"], json!([101]));

    // Control: the comment at the start of a line is refused.
    let body = format!("{}\n  <!-- a note\n{TICKED_CLOSURE} pasted\n", tracker_md());
    let out = parse_body(&env, &body);
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert_eq!(parsed(&out)["approved_closures"], json!([]));
}
