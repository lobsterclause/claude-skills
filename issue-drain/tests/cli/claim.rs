//! `issue-drain claim take|release|check`. The stub gh answers `issue view`
//! (the labels) from `issue-view-<n>.json` and the timeline, where the claim
//! markers and the label events are read, from `timeline-<n>.json`; a test that
//! wants to show a later state rewrites those files, as GitHub would have
//! changed.

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

/// Where the events of a timeline sit in time.
const T1: &str = "2026-11-21T01:00:00Z";
const T2: &str = "2026-11-21T02:00:00Z";
const T3: &str = "2026-11-21T03:00:00Z";

/// One timeline event: (kind, text, time). For `labeled` and `unlabeled` the
/// text is the label; for `commented` it is the body.
type Event<'a> = (&'a str, &'a str, &'a str);

fn event_json((kind, text, at): &Event) -> Value {
    match *kind {
        "commented" => json!({"event": kind, "created_at": at, "body": text}),
        _ => json!({"event": kind, "created_at": at, "label": {"name": text}}),
    }
}

/// `gh api .../issues/<n>/timeline` as one page.
fn timeline_page(events: &[Event]) -> Value {
    Value::Array(events.iter().map(event_json).collect())
}

fn timeline(env: &Env, n: u64, events: &[Event]) {
    env.stub_file(&format!("timeline-{n}.json"), &timeline_page(events).to_string());
}

/// What `gh issue view <n> --json labels` says.
fn labels(env: &Env, n: u64, labels: &[&str]) {
    let labels: Vec<Value> = labels.iter().map(|l| json!({"name": l})).collect();
    env.stub_file(&format!("issue-view-{n}.json"), &json!({"labels": labels}).to_string());
}

/// The usual state of an issue: its labels, and a timeline in which the claim
/// label, if it is on, was added at T1 and every comment was made at T1.
fn view(env: &Env, n: u64, names: &[&str], comments: &[&str]) {
    let timed: Vec<(&str, &str)> = comments.iter().map(|c| (*c, T1)).collect();
    view_at(env, n, names, &timed);
}

/// The same, with each comment's creation time.
fn view_at(env: &Env, n: u64, names: &[&str], comments: &[(&str, &str)]) {
    labels(env, n, names);
    let mut events: Vec<Event> = Vec::new();
    if names.iter().any(|l| l.eq_ignore_ascii_case(LABEL)) {
        events.push(("labeled", LABEL, T1));
    }
    events.extend(comments.iter().map(|(body, at)| ("commented", *body, *at)));
    timeline(env, n, &events);
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

/// Make the stub behave as GitHub would once 103 has been taken: on the first
/// read of `before` (the next issue), 103 gets the claim label and a marker of
/// `by`'s making. Without it 103 stays as `clean` left it, which is not a claim
/// of ours, and a rollback that checks ownership would rightly leave it alone.
fn once_103_is_taken_by(env: &Env, before: u64, by: &str) {
    let dir = env.stub.display();
    let labels = json!({"labels": [{"name": "bug"}, {"name": LABEL}]}).to_string();
    let timeline = timeline_page(&[("labeled", LABEL, T1), ("commented", by, T2)]).to_string();
    let script = format!(
        "cat > '{dir}/issue-view-103.json' <<'EOF'\n{labels}\nEOF\ncat > '{dir}/timeline-103.json' <<'EOF'\n{timeline}\nEOF\n"
    );
    env.stub_file(&format!("once-issue-view-{before}"), &script);
}

fn position(calls: &[String], starts: &str) -> usize {
    calls
        .iter()
        .position(|c| c.starts_with(starts))
        .unwrap_or_else(|| panic!("no call starting '{starts}' in {calls:?}"))
}

#[test]
fn take_labels_each_issue_then_posts_a_marker_comment_that_starts_with_the_marker() {
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
        assert!(
            position(&calls, &format!("issue edit {n} ")) < position(&calls, &format!("issue comment {n} ")),
            "the label goes first: {calls:?}"
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
fn an_old_marker_with_no_label_gets_the_label_and_a_fresh_marker() {
    let env = setup();
    view(&env, 103, &["bug"], &[&ours()]);
    view(&env, 106, &["bug", LABEL], &[&ours()]);
    assert_eq!(run(&env, "take").code, 0);
    let calls = writes(&env);
    assert!(
        calls.contains(&format!("issue edit 103 --repo {REPO} --add-label {LABEL}")),
        "{calls:?}"
    );
    assert!(
        calls.iter().any(|c| c.starts_with("issue comment 103 ")),
        "the old marker predates the new label, so it does not count: {calls:?}"
    );
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
        once_103_is_taken_by(&env, 106, &ours());
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

/// 103 was taken, then 106 turned out to be someone else's. Before the
/// rollback a stranger took 103's claim over (the label stayed, the marker is
/// theirs): taking the label off would be taking theirs.
#[test]
fn a_rollback_leaves_an_earlier_claim_alone_when_it_is_no_longer_ours() {
    for by in [theirs(), "I am on it".to_string()] {
        let env = setup();
        view(&env, 103, &["bug"], &[]);
        view(&env, 106, &["bug", LABEL], &[]);
        once_103_is_taken_by(&env, 106, &by);
        let out = run(&env, "take");
        assert_eq!(out.code, 3, "{}", out.stderr);
        assert!(out.stderr.contains("left #103 alone"), "{}", out.stderr);
        assert!(removals(&env).is_empty(), "{:?}", writes(&env));
    }
    // Control: while 103 is still ours it is released.
    let env = setup();
    view(&env, 103, &["bug"], &[]);
    view(&env, 106, &["bug", LABEL], &[]);
    once_103_is_taken_by(&env, 106, &ours());
    let out = run(&env, "take");
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(
        removals(&env),
        [format!("issue edit 103 --repo {REPO} --remove-label {LABEL}")]
    );
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
fn a_marker_that_fails_to_post_takes_its_label_back_off() {
    let env = setup();
    clean(&env);
    env.stub_file("fail-comment", "");
    let out = run(&env, "take");
    assert_eq!(out.code, 1, "{}", out.stderr);
    let calls = writes(&env);
    assert!(
        position(&calls, "issue edit 103 --repo example/tidepool --add-label") < position(&calls, "issue comment 103 "),
        "{calls:?}"
    );
    assert_eq!(
        calls.last().map(String::as_str),
        Some(format!("issue edit 103 --repo {REPO} --remove-label {LABEL}").as_str()),
        "{calls:?}"
    );
    assert!(!calls.iter().any(|c| c.contains(" 106 ")), "{calls:?}");
}

/// The label call fails, so no marker is posted; a stranger then adds the
/// label. Nothing of ours is on the issue for the stranger's label to borrow.
#[test]
fn a_label_call_that_fails_leaves_no_marker_for_a_strangers_label_to_borrow() {
    let env = setup();
    clean(&env);
    env.stub_file("fail-add-label", "");
    let out = run(&env, "take");
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert!(
        !writes(&env).iter().any(|c| c.starts_with("issue comment")),
        "{:?}",
        writes(&env)
    );
    for n in [103, 106] {
        labels(&env, n, &["bug", LABEL]);
        timeline(&env, n, &[("labeled", LABEL, T2)]);
    }
    let out = run(&env, "check");
    assert!(out.stdout.contains("\"ours\":false"), "{}", out.stdout);
    assert!(!out.stdout.contains("\"ours\":true"), "{}", out.stdout);
    let before = writes(&env).len();
    let out = run(&env, "take");
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(writes(&env).len(), before, "nothing written on a foreign claim");
}

/// The marker is older than the latest `labeled` event, so the label on the
/// issue is not the one the marker was posted for.
#[test]
fn a_label_added_after_our_marker_is_not_ours_and_a_label_with_no_event_is_not_ours() {
    let env = setup();
    for n in [103, 106] {
        labels(&env, n, &["bug", LABEL]);
        timeline(&env, n, &[("commented", &ours(), T1), ("labeled", LABEL, T2)]);
    }
    let out = run(&env, "release");
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stdout.contains("not_ours"), "{}", out.stdout);
    assert_eq!(writes(&env), Vec::<String>::new());

    // A label the timeline never shows being added: not ours either.
    for n in [103, 106] {
        labels(&env, n, &["bug", LABEL]);
        timeline(&env, n, &[("commented", &ours(), T1)]);
    }
    let out = run(&env, "check");
    assert!(!out.stdout.contains("\"ours\":true"), "{}", out.stdout);
    assert_eq!(run(&env, "take").code, 3);
    assert_eq!(writes(&env), Vec::<String>::new());

    // Control: the marker at the second of the label, or after it, is ours.
    for n in [103, 106] {
        timeline(&env, n, &[("labeled", LABEL, T1), ("commented", &ours(), T1)]);
    }
    let out = run(&env, "check");
    assert!(!out.stdout.contains("\"ours\":false"), "{}", out.stdout);
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
            {"issue": 106, "labelled": false, "ours": false}
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
        once_103_is_taken_by(&env, 106, &ours());
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
        labels(&env, n, &["bug"]);
        timeline(
            &env,
            n,
            &[
                ("labeled", LABEL, T1),
                ("commented", &ours(), T1),
                ("unlabeled", LABEL, T2),
            ],
        );
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
        labels(&env, n, &["bug", LABEL]);
        timeline(
            &env,
            n,
            &[
                ("labeled", LABEL, T1),
                ("commented", &ours(), T1),
                ("unlabeled", LABEL, T2),
                ("labeled", LABEL, T3),
                ("commented", &ours(), T3),
            ],
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
            labels(&env, n, &["bug", LABEL]);
            let mut events: Vec<Event> = vec![("labeled", LABEL, T1), ("unlabeled", LABEL, T2), ("labeled", LABEL, T3)];
            events.extend(comments.iter().map(|(body, at)| ("commented", body.as_str(), *at)));
            timeline(&env, n, &events);
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
        labels(&env, n, &["bug", LABEL]);
        timeline(
            &env,
            n,
            &[
                ("labeled", LABEL, T1),
                ("commented", &ours(), T1),
                ("unlabeled", LABEL, T2),
                ("labeled", LABEL, T3),
            ],
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
        labels(&env, n, &["bug", LABEL]);
        timeline(
            &env,
            n,
            &[
                ("commented", &theirs(), T1),
                ("unlabeled", LABEL, T1),
                ("labeled", LABEL, T2),
                ("commented", &ours(), T2),
                ("unlabeled", "bug", T3),
                ("labeled", "bug", T3),
            ],
        );
    }
    let out = run(&env, "release");
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(removals(&env).len(), 2, "{:?}", writes(&env));

    // Control: the same timeline with the claim label itself coming off at T3.
    let env = setup();
    for n in [103, 106] {
        labels(&env, n, &["bug", LABEL]);
        timeline(
            &env,
            n,
            &[
                ("commented", &ours(), T2),
                ("labeled", LABEL, T2),
                ("unlabeled", LABEL, T3),
            ],
        );
    }
    let out = run(&env, "release");
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(removals(&env), Vec::<String>::new());
}

#[test]
fn the_timeline_is_read_page_by_page_and_an_unlabel_on_a_later_page_counts() {
    let env = setup();
    for n in [103, 106] {
        labels(&env, n, &["bug", LABEL]);
    }
    // What `gh api --paginate` prints for two pages: two arrays, one after the other.
    let page1 = timeline_page(&[("labeled", LABEL, T1), ("commented", &ours(), T1)]);
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

/// More than 100 comments: the markers come from the paginated timeline, not
/// from `gh issue view`, which cuts the comments at the first 100.
#[test]
fn a_marker_beyond_the_first_hundred_comments_is_found() {
    let chatter: Vec<String> = (0..99).map(|i| format!("comment {i}")).collect();
    let mut first: Vec<Event> = vec![("labeled", LABEL, T1)];
    first.extend(chatter.iter().map(|c| ("commented", c.as_str(), T1)));
    assert_eq!(first.len(), 100, "a full first page");
    let page1 = timeline_page(&first);

    // Our marker is on the second page: ours.
    let env = setup();
    for n in [103, 106] {
        labels(&env, n, &["bug", LABEL]);
        let page2 = timeline_page(&[("commented", &ours(), T2)]);
        env.stub_file(&format!("timeline-{n}.json"), &format!("{page1}\n{page2}\n"));
    }
    let out = run(&env, "check");
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(!out.stdout.contains("\"ours\":false"), "{}", out.stdout);
    assert!(
        env.gh_calls()
            .iter()
            .filter(|c| c.starts_with("issue view"))
            .all(|c| !c.contains("comments")),
        "{:?}",
        env.gh_calls()
    );
    assert_eq!(run(&env, "release").code, 0);
    assert_eq!(removals(&env).len(), 2, "{:?}", writes(&env));

    // Another run's newer marker on the second page: not ours.
    let env = setup();
    let mine = ours();
    let mut first = first.clone();
    first.push(("commented", mine.as_str(), T1));
    for n in [103, 106] {
        labels(&env, n, &["bug", LABEL]);
        let page2 = timeline_page(&[("commented", &theirs(), T2)]);
        env.stub_file(
            &format!("timeline-{n}.json"),
            &format!("{}\n{page2}\n", timeline_page(&first)),
        );
    }
    let out = run(&env, "check");
    assert!(!out.stdout.contains("\"ours\":true"), "{}", out.stdout);
    assert_eq!(run(&env, "take").code, 3);
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
        for bad in [
            "not json",
            r#"{"message":"Not Found"}"#,
            r#"[{"event":"unlabeled"}]"#,
            r#"[{"event":"labeled"}]"#,
        ] {
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
    labels(&env, 103, &[LABEL]);
    env.stub_file(
        "timeline-103.json",
        &json!([{"event": "labeled", "created_at": T1, "label": {"name": LABEL}}, {"event": "commented", "body": ours()}])
            .to_string(),
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

/// A release and a retake inside one second: every event carries the same
/// timestamp, so the order is the timeline's order.
#[test]
fn a_release_and_a_retake_in_one_second_is_ours_and_a_stranger_in_that_second_is_not() {
    let env = setup();
    for n in [103, 106] {
        labels(&env, n, &["bug", LABEL]);
        timeline(
            &env,
            n,
            &[
                ("labeled", LABEL, T1),
                ("commented", &ours(), T1),
                ("unlabeled", LABEL, T2),
                ("labeled", LABEL, T2),
                ("commented", &ours(), T2),
            ],
        );
    }
    let out = run(&env, "check");
    assert!(!out.stdout.contains("\"ours\":false"), "{}", out.stdout);
    let out = run(&env, "release");
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(removals(&env).len(), 2, "{:?}", writes(&env));

    // Control: a stranger's label that follows our marker within the second.
    let env = setup();
    for n in [103, 106] {
        labels(&env, n, &["bug", LABEL]);
        timeline(
            &env,
            n,
            &[
                ("labeled", LABEL, T1),
                ("commented", &ours(), T2),
                ("unlabeled", LABEL, T2),
                ("labeled", LABEL, T2),
            ],
        );
    }
    let out = run(&env, "check");
    assert!(!out.stdout.contains("\"ours\":true"), "{}", out.stdout);
    let out = run(&env, "take");
    assert_eq!(out.code, 3, "{}", out.stderr);
}
