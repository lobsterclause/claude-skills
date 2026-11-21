//! `gh-write`: pr-create, the thread verbs, and the verb set of a unit
//! (ISSUE_DRAIN_MODE=unit). Each refusal makes no gh call.

use crate::common::*;

fn body(env: &Env) -> String {
    env.write("body.md", "A body.\n").display().to_string()
}

#[test]
fn pr_create_reaches_gh_and_prints_the_url() {
    let env = Env::new();
    let body = body(&env);
    let out = env.run(&[
        "gh-write",
        "pr-create",
        "--head",
        "feat/x",
        "--base",
        "develop",
        "--title",
        "Add x",
        "--body-file",
        &body,
        "--draft",
        "--label",
        "a",
        "--label",
        "b",
    ]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(out.stdout.trim(), "https://github.com/example/tidepool/pull/901");
    assert_eq!(
        env.gh_calls(),
        [format!(
            "pr create --repo {REPO} --head feat/x --base develop --title Add x --body-file {body} --draft --label a --label b"
        )]
    );
}

#[test]
fn pr_create_refusals_make_no_call() {
    let env = Env::new();
    let body = body(&env);
    let empty = env.write("empty.md", "").display().to_string();
    let cases: [(&[&str], i32); 5] = [
        (
            &[
                "--head",
                "agent/x",
                "--base",
                "develop",
                "--title",
                "t",
                "--body-file",
                &body,
            ],
            3,
        ),
        (
            &[
                "--head",
                "develop",
                "--base",
                "develop",
                "--title",
                "t",
                "--body-file",
                &body,
            ],
            3,
        ),
        (
            &[
                "--head",
                "feat/x",
                "--base",
                "develop",
                "--title",
                "t",
                "--body-file",
                &empty,
            ],
            2,
        ),
        (
            &[
                "--head",
                "feat/x",
                "--base",
                "develop",
                "--title",
                "t",
                "--body-file",
                "/nonexistent.md",
            ],
            2,
        ),
        (&["--head", "feat/x", "--base", "develop", "--title", "t"], 2),
    ];
    for (rest, code) in cases {
        let mut args = vec!["gh-write", "pr-create"];
        args.extend(rest);
        let out = env.run(&args);
        assert_eq!(out.code, code, "{args:?}: {}", out.stderr);
    }
    assert!(env.gh_calls().is_empty(), "{:?}", env.gh_calls());
    assert_eq!(env.events_named("gh_write_refused").len(), 2);
}

#[test]
fn thread_verbs_reach_gh() {
    let env = Env::new();
    let body = body(&env);
    let reply = env.run(&[
        "gh-write",
        "thread-reply",
        "--thread",
        "PRRT_kwDOAbc-1=",
        "--body-file",
        &body,
    ]);
    assert_eq!(reply.code, 0, "{}", reply.stderr);
    let resolve = env.run(&["gh-write", "thread-resolve", "--thread", "PRRT_kwDOAbc-1="]);
    assert_eq!(resolve.code, 0, "{}", resolve.stderr);
    let calls = env.gh_calls();
    assert_eq!(calls.len(), 2, "{calls:?}");
    assert!(
        calls[0].starts_with("api graphql -f query=mutation($id:ID!,$body:String!){addPullRequestReviewThreadReply(")
    );
    assert!(
        calls[0].ends_with(&format!("-f id=PRRT_kwDOAbc-1= -F body=@{body}")),
        "{}",
        calls[0]
    );
    assert!(calls[1].starts_with("api graphql -f query=mutation($id:ID!){resolveReviewThread("));
    assert!(calls[1].ends_with("-f id=PRRT_kwDOAbc-1="), "{}", calls[1]);
}

#[test]
fn a_bad_thread_id_is_refused_before_gh() {
    let env = Env::new();
    let body = body(&env);
    for bad in ["", "a b", "x;y", "$(id)", "a/b"] {
        let reply = env.run(&["gh-write", "thread-reply", "--thread", bad, "--body-file", &body]);
        assert_eq!(reply.code, 3, "{bad:?}: {}", reply.stderr);
        let resolve = env.run(&["gh-write", "thread-resolve", "--thread", bad]);
        assert_eq!(resolve.code, 3, "{bad:?}: {}", resolve.stderr);
    }
    let missing = env.run(&["gh-write", "thread-resolve"]);
    assert_eq!(missing.code, 3);
    assert!(env.gh_calls().is_empty(), "{:?}", env.gh_calls());
}

#[test]
fn dry_run_prints_would_and_calls_nothing() {
    let mut env = Env::new();
    env.set("ISSUE_DRAIN_DRY_RUN", "1");
    let body = body(&env);
    let cases: [&[&str]; 3] = [
        &[
            "gh-write",
            "pr-create",
            "--head",
            "feat/x",
            "--base",
            "develop",
            "--title",
            "Add x",
            "--body-file",
            &body,
        ],
        &["gh-write", "thread-reply", "--thread", "PRRT_a", "--body-file", &body],
        &["gh-write", "thread-resolve", "--thread", "PRRT_a"],
    ];
    for args in cases {
        let out = env.run(args);
        assert_eq!(out.code, 0, "{args:?}: {}", out.stderr);
        assert!(out.stdout.starts_with("WOULD: gh "), "{}", out.stdout);
    }
    assert!(env.gh_calls().is_empty(), "{:?}", env.gh_calls());
}

#[test]
fn a_unit_is_refused_the_drivers_verbs_and_allowed_the_rest() {
    let mut env = Env::new();
    env.set("ISSUE_DRAIN_MODE", "unit");
    let body = body(&env);
    let refused: [&[&str]; 4] = [
        &["gh-write", "close-issue", "7"],
        &["gh-write", "remove-label", "7", "agent-in-progress"],
        &["gh-write", "merge-pr", "7"],
        &["gh-write", "issue-create", "--title", "x", "--body-file", &body],
    ];
    for args in refused {
        let out = env.run(args);
        assert_eq!(out.code, 3, "{args:?}: {}", out.stderr);
        assert!(
            out.stderr
                .contains(&format!("refused: {} is the driver's job in a unit", args[1])),
            "{}",
            out.stderr
        );
    }
    assert!(env.gh_calls().is_empty(), "{:?}", env.gh_calls());

    let allowed: [&[&str]; 6] = [
        &["gh-write", "comment", "7", "--body-file", &body],
        &["gh-write", "add-label", "7", "needs-human"],
        &["gh-write", "ensure-label", "issue-drain"],
        &[
            "gh-write",
            "pr-create",
            "--head",
            "feat/x",
            "--base",
            "develop",
            "--title",
            "t",
            "--body-file",
            &body,
        ],
        &["gh-write", "thread-reply", "--thread", "PRRT_a", "--body-file", &body],
        &["gh-write", "thread-resolve", "--thread", "PRRT_a"],
    ];
    for args in allowed {
        let out = env.run(args);
        assert_eq!(out.code, 0, "{args:?}: {}", out.stderr);
    }
    // ensure-label makes a list call then a create call; the rest one each.
    assert_eq!(env.gh_calls().len(), 7, "{:?}", env.gh_calls());
}

/// A claim is the label plus a marker comment, and only `claim take` makes
/// both. A unit adding the label alone would make a claim with no marker.
#[test]
fn a_unit_may_not_add_the_claim_label_whatever_its_case() {
    let mut env = Env::new();
    env.set("ISSUE_DRAIN_MODE", "unit");
    for label in ["agent-in-progress", "Agent-In-Progress"] {
        let out = env.run(&["gh-write", "add-label", "7", label]);
        assert_eq!(out.code, 3, "{label}: {}", out.stderr);
        assert!(out.stderr.contains("claim label"), "{}", out.stderr);
    }
    assert!(env.gh_calls().is_empty(), "{:?}", env.gh_calls());
    let why = env.events_named("gh_write_refused");
    assert_eq!(why.len(), 2);
    assert_eq!(why[0]["mode"], "unit");

    // Controls: the other label a unit may add, and the claim label outside a unit.
    assert_eq!(env.run(&["gh-write", "add-label", "7", "needs-human"]).code, 0);
    env.set("ISSUE_DRAIN_MODE", "driver");
    assert_eq!(env.run(&["gh-write", "add-label", "7", "agent-in-progress"]).code, 0);
}

#[test]
fn without_the_variable_the_same_verb_is_not_refused_as_the_drivers() {
    let env = Env::new();
    let out = env.run(&["gh-write", "close-issue", "7"]);
    assert!(!out.stderr.contains("driver's job"), "{}", out.stderr);
}

/// Every verb below is the driver's. A unit process must be refused before it
/// posts, labels or logs anything: `close-verified` used to comment before the
/// close was refused, `tracker publish` to make a label before the issue, and
/// `merge-gate` to log an event and answer for a merged PR.
const DRIVERS_VERBS: [&[&str]; 8] = [
    &["close-verified", "7"],
    &["tracker", "publish"],
    &["merge-gate", "--unit", "3", "--pr", "12"],
    &["state", "init"],
    &["state", "event", "3", "working"],
    &["state", "stop", "--reason", "x"],
    &["state", "resume"],
    &["state", "show"],
];

fn assert_refused_as_the_drivers(env: &Env, why: &str) {
    for args in DRIVERS_VERBS {
        let out = env.run(args);
        assert_eq!(out.code, 3, "{why}: {args:?}: {}", out.stderr);
        assert!(out.stderr.contains("driver's job"), "{why}: {args:?}: {}", out.stderr);
    }
    for args in [&["state", "rebuild"][..], &["state", "next"][..]] {
        let out = env.run(args);
        assert_eq!(out.code, 3, "{why}: {args:?}: {}", out.stderr);
    }
    assert!(env.gh_calls().is_empty(), "{why}: {:?}", env.gh_calls());
    assert!(env.events().is_empty(), "{why}: {:?}", env.events());
}

#[test]
fn a_unit_process_is_refused_the_drivers_commands_before_they_do_anything() {
    let mut env = Env::new();
    env.set("ISSUE_DRAIN_MODE", "unit");
    assert_refused_as_the_drivers(&env, "ISSUE_DRAIN_MODE=unit");
}

#[test]
fn a_unit_file_with_no_mode_is_a_unit_process() {
    let mut env = Env::new();
    env.set("ISSUE_DRAIN_UNIT_FILE", "/state/unit-3.json");
    assert_refused_as_the_drivers(&env, "only ISSUE_DRAIN_UNIT_FILE");
    // The same variable does not override a mode that was named.
    env.set("ISSUE_DRAIN_MODE", "driver");
    let out = env.run(&["state", "show"]);
    assert!(!out.stderr.contains("driver's job"), "{}", out.stderr);
}
