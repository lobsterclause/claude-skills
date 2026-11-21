//! `issue-drain claim take|release|check`. The stub gh answers `issue view`
//! from `issue-view-<n>.json`; a test that wants to show a later state
//! rewrites that file, as GitHub would have changed.

use serde_json::{Value, json};

use crate::common::*;

const MARKER: &str = "<!-- issue-drain:claim tracker=12 unit=3 -->";
const LABEL: &str = "agent-in-progress";

/// The queue unit U3 holds issues 103 and 106, and the run published tracker #12.
fn setup() -> Env {
    let env = Env::new();
    env.write("queue.json", &queue_with_unit(json!({})).to_string());
    env.write(
        "tracker.json",
        &json!({"number": 12, "url": "https://example.invalid/12", "run": "run", "published_at": "2026-11-21T00:00:00Z"})
            .to_string(),
    );
    env
}

/// Where the comments of `view` sit in time, and the start of the timeline
/// events a test builds with `at`.
const T1: &str = "2026-11-21T01:00:00Z";
const T2: &str = "2026-11-21T02:00:00Z";
const T3: &str = "2026-11-21T03:00:00Z";

/// What `gh issue view <n> --json labels,comments` says, every comment made at T1.
fn view(env: &Env, n: u64, labels: &[&str], comments: &[&str]) {
    let timed: Vec<(&str, &str)> = comments.iter().map(|c| (*c, T1)).collect();
    view_at(env, n, labels, &timed);
}

/// The same, with each comment's creation time.
fn view_at(env: &Env, n: u64, labels: &[&str], comments: &[(&str, &str)]) {
    let labels: Vec<Value> = labels.iter().map(|l| json!({"name": l})).collect();
    let comments: Vec<Value> = comments
        .iter()
        .map(|(body, at)| json!({"body": body, "createdAt": at}))
        .collect();
    env.stub_file(
        &format!("issue-view-{n}.json"),
        &json!({"labels": labels, "comments": comments}).to_string(),
    );
}

/// `gh api .../issues/<n>/timeline` as one page: (event, label, time).
fn timeline_page(events: &[(&str, &str, &str)]) -> Value {
    Value::Array(
        events
            .iter()
            .map(|(event, label, at)| json!({"event": event, "created_at": at, "label": {"name": label}}))
            .collect(),
    )
}

fn timeline(env: &Env, n: u64, events: &[(&str, &str, &str)]) {
    env.stub_file(&format!("timeline-{n}.json"), &timeline_page(events).to_string());
}

/// What a run with another tracker (13) would have posted.
fn theirs() -> String {
    ours().replace("tracker=12", "tracker=13")
}

fn clean(env: &Env) {
    view(env, 103, &["bug"], &[]);
    view(env, 106, &["bug"], &[]);
}

fn ours() -> String {
    format!("{MARKER}\nAn agent picked this up as unit 3 of the drain tracked in #12.")
}

/// The calls that change something on GitHub.
fn writes(env: &Env) -> Vec<String> {
    env.gh_calls()
        .into_iter()
        .filter(|c| !c.starts_with("issue view") && !c.starts_with("label list") && !c.starts_with("api "))
        .collect()
}

fn run(env: &Env, verb: &str) -> Out {
    env.run(&["claim", verb, "--unit", "3"])
}

fn comment_body(env: &Env, n: u64) -> String {
    std::fs::read_to_string(env.workdir.join(format!("units/3/claim-{n}.md"))).expect("the marker comment's body file")
}

#[test]
fn take_labels_each_issue_and_posts_a_marker_comment_that_starts_with_the_marker() {
    let env = setup();
    clean(&env);
    let out = run(&env, "take");
    assert_eq!(out.code, 0, "{}", out.stderr);
    let calls = writes(&env);
    let body = |n: u64| env.workdir.join(format!("units/3/claim-{n}.md")).display().to_string();
    for n in [103, 106] {
        assert!(
            calls.contains(&format!("issue comment {n} --repo {REPO} --body-file {}", body(n))),
            "{calls:?}"
        );
        assert!(
            calls.contains(&format!("issue edit {n} --repo {REPO} --add-label {LABEL}")),
            "{calls:?}"
        );
        let text = comment_body(&env, n);
        let (first, rest) = text.split_once('\n').expect("a marker line, then a sentence");
        assert_eq!(first, MARKER);
        assert!(!rest.trim().is_empty() && !rest.contains('\u{2014}'), "{rest:?}");
    }
    assert!(
        calls.contains(&format!("label create {LABEL} --repo {REPO}")),
        "the label is made when the repo lacks it: {calls:?}"
    );
    let taken: Value = serde_json::from_str(out.stdout.trim()).expect("JSON on stdout");
    assert_eq!(
        taken,
        json!([{"issue": 103, "action": "taken"}, {"issue": 106, "action": "taken"}])
    );
    assert_eq!(env.events_named("claim_take").len(), 1);
}

#[test]
fn taking_twice_writes_once() {
    let env = setup();
    clean(&env);
    assert_eq!(run(&env, "take").code, 0);
    let first = writes(&env).len();
    assert!(first > 0);
    // GitHub now shows the label and the marker comment.
    for n in [103, 106] {
        view(&env, n, &["bug", LABEL], &[&ours()]);
    }
    let out = run(&env, "take");
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(writes(&env).len(), first, "{:?}", writes(&env));
    assert!(out.stdout.contains("already"), "{}", out.stdout);
}

#[test]
fn a_marker_with_no_label_gets_only_the_label() {
    let env = setup();
    view(&env, 103, &["bug"], &[&ours()]);
    view(&env, 106, &["bug", LABEL], &[&ours()]);
    assert_eq!(run(&env, "take").code, 0);
    let calls = writes(&env);
    assert!(
        calls.contains(&format!("issue edit 103 --repo {REPO} --add-label {LABEL}")),
        "{calls:?}"
    );
    assert!(!calls.iter().any(|c| c.starts_with("issue comment")), "{calls:?}");
    assert!(!calls.iter().any(|c| c.contains(" 106 ")), "{calls:?}");
}

#[test]
fn a_label_with_someone_elses_marker_or_none_is_a_foreign_claim() {
    let theirs = [
        vec![],
        vec!["I am on it".to_string()],
        vec![MARKER.replace("unit=3", "unit=4")],
        vec![MARKER.replace("tracker=12", "tracker=13")],
        // The marker anchors on the first line: a quote of it is not ours.
        vec![format!("> quoting\n{MARKER}")],
    ];
    for comments in theirs {
        let env = setup();
        view(&env, 103, &["bug"], &[]);
        let refs: Vec<&str> = comments.iter().map(String::as_str).collect();
        view(&env, 106, &["bug", LABEL], &refs);
        let out = run(&env, "take");
        assert_eq!(out.code, 3, "{comments:?}: {}", out.stderr);
        assert!(out.stderr.contains("claimed by someone else"), "{}", out.stderr);
        assert!(out.stderr.contains("106"), "{}", out.stderr);
        // 103 was taken before 106 was read, so it is released again.
        let calls = writes(&env);
        assert!(
            calls.contains(&format!("issue edit 103 --repo {REPO} --add-label {LABEL}")),
            "{calls:?}"
        );
        assert_eq!(
            calls.last().map(String::as_str),
            Some(format!("issue edit 103 --repo {REPO} --remove-label {LABEL}").as_str()),
            "{calls:?}"
        );
        assert!(
            !calls.iter().any(|c| c.contains(" 106 ")),
            "nothing written on 106: {calls:?}"
        );
    }
}

#[test]
fn a_foreign_claim_on_the_first_issue_writes_nothing() {
    let env = setup();
    view(&env, 103, &["bug", LABEL], &[]);
    view(&env, 106, &["bug"], &[]);
    let out = run(&env, "take");
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(writes(&env), Vec::<String>::new());
}

#[test]
fn the_claim_label_matches_whatever_the_case() {
    let env = setup();
    view(&env, 103, &["Agent-In-Progress"], &[&ours()]);
    view(&env, 106, &["bug"], &[]);
    assert_eq!(run(&env, "take").code, 0);
    assert_eq!(writes(&env).len(), 3, "only 106 is written: {:?}", writes(&env));
}

#[test]
fn a_write_that_fails_part_way_releases_what_was_taken() {
    let env = setup();
    clean(&env);
    env.stub_file("fail-comment", "");
    let out = run(&env, "take");
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert!(
        !writes(&env).iter().any(|c| c.contains("--add-label")),
        "{:?}",
        writes(&env)
    );
}

#[test]
fn release_removes_the_label_only_where_the_marker_is_ours() {
    let env = setup();
    view(&env, 103, &["bug", LABEL], &[&ours()]);
    view(&env, 106, &["bug", LABEL], &["someone else's claim"]);
    let out = run(&env, "release");
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        writes(&env),
        [format!("issue edit 103 --repo {REPO} --remove-label {LABEL}")]
    );
    let released: Value = serde_json::from_str(out.stdout.trim()).expect("JSON on stdout");
    assert_eq!(
        released,
        json!([{"issue": 103, "action": "released"}, {"issue": 106, "action": "not_ours"}])
    );
}

#[test]
fn releasing_again_or_with_no_label_writes_nothing() {
    let env = setup();
    view(&env, 103, &["bug"], &[&ours()]);
    view(&env, 106, &["bug"], &[]);
    let out = run(&env, "release");
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(writes(&env), Vec::<String>::new());
    assert!(out.stdout.contains("not_labelled"), "{}", out.stdout);
}

#[test]
fn check_prints_labelled_and_ours_for_each_issue_and_writes_nothing() {
    let env = setup();
    view(&env, 103, &["bug", LABEL], &[&ours()]);
    view(&env, 106, &["bug"], &[&ours()]);
    let out = run(&env, "check");
    assert_eq!(out.code, 0, "{}", out.stderr);
    let got: Value = serde_json::from_str(out.stdout.trim()).expect("JSON on stdout");
    assert_eq!(
        got,
        json!([
            {"issue": 103, "labelled": true, "ours": true},
            {"issue": 106, "labelled": false, "ours": true}
        ])
    );
    assert_eq!(writes(&env), Vec::<String>::new());
}

#[test]
fn a_dry_run_records_no_write() {
    let mut env = setup();
    clean(&env);
    env.set("ISSUE_DRAIN_DRY_RUN", "1");
    let out = run(&env, "take");
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stdout.contains("WOULD: gh issue edit 103"), "{}", out.stdout);
    assert!(out.stdout.contains("WOULD: gh issue comment 103"), "{}", out.stdout);
    assert_eq!(writes(&env), Vec::<String>::new());

    view(&env, 103, &["bug", LABEL], &[&ours()]);
    view(&env, 106, &["bug", LABEL], &[&ours()]);
    let out = run(&env, "release");
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stdout.contains("WOULD: gh issue edit 103"), "{}", out.stdout);
    assert_eq!(writes(&env), Vec::<String>::new());
}

#[test]
fn a_unit_process_may_not_claim_release_or_check() {
    let mut env = setup();
    clean(&env);
    env.set("ISSUE_DRAIN_MODE", "unit");
    for verb in ["take", "release", "check"] {
        let out = run(&env, verb);
        assert_eq!(out.code, 3, "{verb}: {}", out.stderr);
        assert!(out.stderr.contains("driver"), "{}", out.stderr);
    }
    assert_eq!(env.gh_calls(), Vec::<String>::new());
}

#[test]
fn a_read_error_is_exit_1_and_never_read_as_not_claimed() {
    for verb in ["take", "release", "check"] {
        let env = setup();
        view(&env, 103, &["bug"], &[]);
        // No answer for 106: gh exits 1 for it.
        let out = run(&env, verb);
        assert_eq!(out.code, 1, "{verb}: {}", out.stderr);
        assert!(out.stderr.contains("106"), "{}", out.stderr);
        let after_read_of_103 = writes(&env);
        if verb == "take" {
            // 103 was taken, then 106 could not be read: 103 is released.
            assert_eq!(
                after_read_of_103.last().map(String::as_str),
                Some(format!("issue edit 103 --repo {REPO} --remove-label {LABEL}").as_str())
            );
        } else {
            assert_eq!(after_read_of_103, Vec::<String>::new());
        }
    }
}

fn removals(env: &Env) -> Vec<String> {
    writes(env)
        .into_iter()
        .filter(|c| c.contains("--remove-label"))
        .collect()
}

/// take, release, take: the first marker no longer proves the second claim, so
/// the second take posts its own, and a release afterwards removes that claim.
#[test]
fn take_release_take_posts_a_fresh_marker_and_a_later_release_still_works() {
    let env = setup();
    clean(&env);
    assert_eq!(run(&env, "take").code, 0);
    assert_eq!(
        writes(&env).iter().filter(|c| c.starts_with("issue comment")).count(),
        2
    );

    // Released: the label is off and the timeline says when.
    for n in [103, 106] {
        view_at(&env, n, &["bug"], &[(&ours(), T1)]);
        timeline(&env, n, &[("labeled", LABEL, T1), ("unlabeled", LABEL, T2)]);
    }
    let before = writes(&env).len();
    let out = run(&env, "take");
    assert_eq!(out.code, 0, "{}", out.stderr);
    let second = writes(&env)[before..].to_vec();
    assert_eq!(
        second.iter().filter(|c| c.starts_with("issue comment")).count(),
        2,
        "a fresh marker for each issue: {second:?}"
    );
    assert_eq!(
        second.iter().filter(|c| c.contains("--add-label")).count(),
        2,
        "{second:?}"
    );

    // GitHub now shows the second claim.
    for n in [103, 106] {
        view_at(&env, n, &["bug", LABEL], &[(&ours(), T1), (&ours(), T3)]);
        timeline(
            &env,
            n,
            &[("labeled", LABEL, T1), ("unlabeled", LABEL, T2), ("labeled", LABEL, T3)],
        );
    }
    let out = run(&env, "release");
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(removals(&env).len(), 2, "{:?}", writes(&env));
}

/// Run A took and released; run B (another tracker) took. A's retried release
/// must not call B's claim its own, whichever order the comments are listed in.
#[test]
fn a_later_runs_claim_is_not_ours_though_our_old_marker_is_still_there() {
    for comments in [[(ours(), T1), (theirs(), T3)], [(theirs(), T3), (ours(), T1)]] {
        let env = setup();
        for n in [103, 106] {
            let listed: Vec<(&str, &str)> = comments.iter().map(|(b, t)| (b.as_str(), *t)).collect();
            view_at(&env, n, &["bug", LABEL], &listed);
            timeline(
                &env,
                n,
                &[("labeled", LABEL, T1), ("unlabeled", LABEL, T2), ("labeled", LABEL, T3)],
            );
        }
        let out = run(&env, "release");
        assert_eq!(out.code, 0, "{}", out.stderr);
        assert_eq!(writes(&env), Vec::<String>::new());
        assert!(out.stdout.contains("not_ours"), "{}", out.stdout);

        let out = run(&env, "take");
        assert_eq!(out.code, 3, "{}", out.stderr);
        assert!(out.stderr.contains("claimed by someone else"), "{}", out.stderr);
        assert_eq!(writes(&env), Vec::<String>::new());

        let out = run(&env, "check");
        assert!(out.stdout.contains("\"ours\":false"), "{}", out.stdout);
    }
}

/// Someone else adds the label after our release: our old marker is still the
/// newest, but the claim it described ended with the unlabel.
#[test]
fn a_label_a_stranger_added_after_our_release_is_not_ours() {
    let env = setup();
    for n in [103, 106] {
        view_at(&env, n, &["bug", LABEL], &[(&ours(), T1)]);
        timeline(
            &env,
            n,
            &[("labeled", LABEL, T1), ("unlabeled", LABEL, T2), ("labeled", LABEL, T3)],
        );
    }
    let out = run(&env, "release");
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(removals(&env), Vec::<String>::new());
    assert!(out.stdout.contains("not_ours"), "{}", out.stdout);
    let out = run(&env, "take");
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(writes(&env), Vec::<String>::new());
}

#[test]
fn only_an_unlabel_of_the_claim_label_after_the_marker_ends_the_claim() {
    let env = setup();
    for n in [103, 106] {
        view_at(&env, n, &["bug", LABEL], &[(&theirs(), T1), (&ours(), T2)]);
        timeline(
            &env,
            n,
            &[
                ("unlabeled", LABEL, T1),
                ("labeled", LABEL, T2),
                ("unlabeled", "bug", T3),
                ("labeled", "bug", T3),
            ],
        );
    }
    let out = run(&env, "release");
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(removals(&env).len(), 2, "{:?}", writes(&env));
}

#[test]
fn the_timeline_is_read_page_by_page_and_an_unlabel_on_a_later_page_counts() {
    let env = setup();
    for n in [103, 106] {
        view_at(&env, n, &["bug", LABEL], &[(&ours(), T1)]);
    }
    // What `gh api --paginate` prints for two pages: two arrays, one after the other.
    let page1 = timeline_page(&[("labeled", LABEL, T1)]);
    let page2 = timeline_page(&[("unlabeled", LABEL, T2), ("labeled", LABEL, T3)]);
    for n in [103, 106] {
        env.stub_file(&format!("timeline-{n}.json"), &format!("{page1}\n{page2}\n"));
    }
    let out = run(&env, "check");
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(!out.stdout.contains("\"ours\":true"), "{}", out.stdout);
    let call = format!("api repos/{REPO}/issues/103/timeline?per_page=100 --paginate");
    assert!(env.gh_calls().contains(&call), "{:?}", env.gh_calls());
}

#[test]
fn a_timeline_that_cannot_be_read_is_exit_1_and_never_read_as_still_ours() {
    for verb in ["take", "release", "check"] {
        let env = setup();
        view(&env, 103, &["bug", LABEL], &[&ours()]);
        view(&env, 106, &["bug", LABEL], &[&ours()]);
        env.stub_file("fail-timeline", "");
        let out = run(&env, verb);
        assert_eq!(out.code, 1, "{verb}: {}", out.stderr);
        assert!(out.stderr.contains("timeline"), "{verb}: {}", out.stderr);
        assert_eq!(writes(&env), Vec::<String>::new(), "{verb}");

        // A timeline that is not JSON, and one that is not a list of events.
        for bad in ["not json", r#"{"message":"Not Found"}"#, r#"[{"event":"unlabeled"}]"#] {
            let env = setup();
            view(&env, 103, &["bug", LABEL], &[&ours()]);
            view(&env, 106, &["bug", LABEL], &[&ours()]);
            env.stub_file("timeline-103.json", bad);
            let out = run(&env, verb);
            assert_eq!(out.code, 1, "{verb} {bad}: {}", out.stderr);
            assert_eq!(writes(&env), Vec::<String>::new(), "{verb} {bad}");
        }
    }
}

#[test]
fn our_marker_with_no_usable_creation_time_is_a_read_error() {
    let env = setup();
    let body = ours();
    env.stub_file(
        "issue-view-103.json",
        &json!({"labels": [{"name": LABEL}], "comments": [{"body": body}]}).to_string(),
    );
    view(&env, 106, &["bug"], &[]);
    let out = run(&env, "check");
    assert_eq!(out.code, 1, "{}", out.stderr);
}

#[test]
fn a_run_with_no_tracker_or_unit_is_a_usage_error() {
    let env = setup();
    std::fs::remove_file(env.workdir.join("tracker.json")).expect("the tracker file");
    assert_eq!(run(&env, "take").code, 2);

    let env = setup();
    assert_eq!(env.run(&["claim", "take", "--unit", "9"]).code, 2);
}
