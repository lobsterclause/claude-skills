//! `issue-drain gh-write`: the one write path. Each refusal has a control
//! beside it that passes, so a test cannot go green because everything fails.

use crate::common::*;

fn body(env: &Env) -> String {
    env.write("body.md", "A comment.\n").display().to_string()
}

#[test]
fn no_verb_is_a_usage_error_and_calls_nothing() {
    let env = Env::new();
    let out = env.run(&["gh-write"]);
    assert_eq!(out.code, 2, "{}", out.stderr);
    assert!(out.stderr.starts_with("issue-drain gh-write: usage:"), "{}", out.stderr);
    assert!(env.gh_calls().is_empty());
}

#[test]
fn bad_arguments_are_usage_errors_and_call_nothing() {
    let env = Env::new();
    let body = body(&env);
    let cases: [&[&str]; 6] = [
        &["gh-write", "frobnicate"],
        &["gh-write", "comment", "7"],
        &["gh-write", "comment", "7", "--body-file", "/nonexistent/body.md"],
        &["gh-write", "comment", "seven", "--body-file", &body],
        &["gh-write", "comment", "7", "--body-file", &body, "--force"],
        &["gh-write", "issue-create", "--body-file", &body],
    ];
    for args in cases {
        let out = env.run(args);
        assert_eq!(out.code, 2, "{args:?}: {}", out.stderr);
    }
    assert!(env.gh_calls().is_empty(), "{:?}", env.gh_calls());
}

#[test]
fn an_empty_body_file_is_refused_before_gh() {
    let env = Env::new();
    let empty = env.write("empty.md", "").display().to_string();
    let out = env.run(&["gh-write", "comment", "7", "--body-file", &empty]);
    assert_eq!(out.code, 2);
    assert!(out.stderr.contains("missing or empty"), "{}", out.stderr);
    assert!(env.gh_calls().is_empty());
}

#[test]
fn a_comment_goes_to_gh_with_the_body_as_a_file() {
    let env = Env::new();
    let body = body(&env);
    let out = env.run(&["gh-write", "comment", "7", "--body-file", &body]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        env.gh_calls(),
        [format!("issue comment 7 --repo {REPO} --body-file {body}")]
    );
    let logged = env.events_named("gh_write");
    assert_eq!(logged.len(), 1);
    assert_eq!(logged[0]["verb"], "comment");
    assert_eq!(logged[0]["dry_run"], false);
    assert_eq!(logged[0]["rc"], 0);
    assert_eq!(logged[0]["ts"], "2026-11-21T03:53:00Z");
}

#[test]
fn a_dry_run_prints_the_call_and_makes_none() {
    let mut env = Env::new();
    env.set("ISSUE_DRAIN_DRY_RUN", "1");
    let body = body(&env);
    let cases: [(&[&str], String); 4] = [
        (
            &["gh-write", "comment", "7", "--body-file", &body],
            format!("issue comment 7 --repo {REPO} --body-file {body}"),
        ),
        (
            &["gh-write", "ensure-label", "issue-drain"],
            format!("label create issue-drain --repo {REPO}"),
        ),
        (
            &["gh-write", "add-label", "7", "agent-in-progress"],
            format!("issue edit 7 --repo {REPO} --add-label agent-in-progress"),
        ),
        (
            &[
                "gh-write",
                "issue-create",
                "--title",
                "The queue: 3 units",
                "--body-file",
                &body,
            ],
            format!("issue create --repo {REPO} --title 'The queue: 3 units' --body-file {body} --label issue-drain"),
        ),
    ];
    for (args, call) in &cases {
        let out = env.run(args);
        assert_eq!(out.code, 0, "{args:?}: {}", out.stderr);
        assert_eq!(out.stdout, format!("WOULD: gh {call}\n"));
    }
    assert!(env.gh_calls().is_empty(), "{:?}", env.gh_calls());
    let logged = env.events_named("gh_write");
    assert_eq!(logged.len(), cases.len());
    assert!(logged.iter().all(|e| e["dry_run"] == true));
}

#[test]
fn issue_create_prints_the_new_issue_url() {
    let mut env = Env::new();
    env.set("GH_STUB_NEW_ISSUE", "4242");
    let body = body(&env);
    let out = env.run(&["gh-write", "issue-create", "--title", "The queue", "--body-file", &body]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(out.stdout.trim(), "https://github.com/example/tidepool/issues/4242");
    assert_eq!(
        env.gh_calls(),
        [format!(
            "issue create --repo {REPO} --title The queue --body-file {body} --label issue-drain"
        )]
    );
}

#[test]
fn only_the_claim_and_blocked_labels_can_be_added() {
    let env = Env::new();
    let refused = env.run(&["gh-write", "add-label", "7", "wontfix"]);
    assert_eq!(refused.code, 3);
    assert!(refused.stderr.contains("refused: may only add"), "{}", refused.stderr);
    assert!(env.gh_calls().is_empty());
    let why = env.events_named("gh_write_refused");
    assert_eq!(why.len(), 1);
    assert_eq!(why[0]["verb"], "add-label");
    assert_eq!(why[0]["mode"], "session");

    for label in ["agent-in-progress", "needs-human"] {
        let out = env.run(&["gh-write", "add-label", "7", label]);
        assert_eq!(out.code, 0, "{label}: {}", out.stderr);
    }
    assert_eq!(
        env.gh_calls(),
        [
            format!("issue edit 7 --repo {REPO} --add-label agent-in-progress"),
            format!("issue edit 7 --repo {REPO} --add-label needs-human"),
        ]
    );
}

#[test]
fn only_the_claim_label_can_be_removed() {
    let env = Env::new();
    for label in ["needs-human", "issue-drain", "bug"] {
        let refused = env.run(&["gh-write", "remove-label", "7", label]);
        assert_eq!(refused.code, 3, "{label}");
        assert!(
            refused.stderr.contains("refused: may only remove 'agent-in-progress'"),
            "{}",
            refused.stderr
        );
    }
    assert!(env.gh_calls().is_empty());

    let out = env.run(&["gh-write", "remove-label", "7", "agent-in-progress"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        env.gh_calls(),
        [format!("issue edit 7 --repo {REPO} --remove-label agent-in-progress")]
    );
}

#[test]
fn a_label_rule_does_not_bend_on_case() {
    let env = Env::new();
    let out = env.run(&["gh-write", "add-label", "7", "Agent-In-Progress"]);
    assert_eq!(out.code, 3);
    assert!(env.gh_calls().is_empty());
}

#[test]
fn ensure_label_creates_only_a_missing_label_the_drain_owns() {
    let env = Env::new();
    let refused = env.run(&["gh-write", "ensure-label", "bug"]);
    assert_eq!(refused.code, 3);
    assert!(
        refused.stderr.contains("not a label the drain owns"),
        "{}",
        refused.stderr
    );
    assert!(env.gh_calls().is_empty());

    // Absent: listed, then created.
    let out = env.run(&["gh-write", "ensure-label", "issue-drain"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let calls = env.gh_calls();
    assert_eq!(calls.len(), 2, "{calls:?}");
    assert!(
        calls[0].starts_with(&format!("label list --repo {REPO} --search issue-drain")),
        "{calls:?}"
    );
    assert_eq!(calls[1], format!("label create issue-drain --repo {REPO}"));

    // Present under another case (GitHub label names ignore case): listed, not created.
    env.stub_file("labels.txt", "issue-drain-old\nIssue-Drain\n");
    let out = env.run(&["gh-write", "ensure-label", "issue-drain"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let calls = env.gh_calls();
    assert_eq!(calls.len(), 3, "{calls:?}");
    assert!(calls[2].starts_with("label list"), "{calls:?}");
}

#[test]
fn a_unit_process_may_comment_and_nothing_else() {
    let mut env = Env::new();
    let body = body(&env);
    env.set("ISSUE_DRAIN_MODE", "unit");
    let refusals: [&[&str]; 5] = [
        &["gh-write", "close-issue", "7"],
        &["gh-write", "add-label", "7", "agent-in-progress"],
        &["gh-write", "remove-label", "7", "agent-in-progress"],
        &["gh-write", "ensure-label", "issue-drain"],
        &["gh-write", "issue-create", "--title", "x", "--body-file", &body],
    ];
    for args in refusals {
        let out = env.run(args);
        assert_eq!(out.code, 3, "{args:?}: {}", out.stderr);
        assert!(out.stderr.contains("a unit process may only comment"), "{}", out.stderr);
    }
    assert!(env.gh_calls().is_empty());
    let why = env.events_named("gh_write_refused");
    assert_eq!(why.len(), refusals.len());
    assert!(why.iter().all(|e| e["mode"] == "unit"));

    let out = env.run(&["gh-write", "comment", "7", "--body-file", &body]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(env.gh_calls().len(), 1);
}

#[test]
fn no_mode_can_close_an_issue_through_gh_write() {
    // Closing belongs to close-verified, which holds the conditions. A bare
    // close verb would let any caller skip all of them.
    for mode in ["session", "driver"] {
        let mut env = Env::new();
        env.set("ISSUE_DRAIN_MODE", mode);
        let out = env.run(&["gh-write", "close-issue", "7"]);
        assert_eq!(out.code, 3, "{mode}: {}", out.stderr);
        assert!(
            out.stderr.contains("only by `issue-drain close-verified`"),
            "{}",
            out.stderr
        );
        assert!(env.gh_calls().is_empty(), "{mode}: {:?}", env.gh_calls());
        assert_eq!(env.events_named("gh_write_refused")[0]["verb"], "close-issue");

        env.set("ISSUE_DRAIN_DRY_RUN", "1");
        let out = env.run(&["gh-write", "close-issue", "7"]);
        assert_eq!(out.code, 3, "{mode} dry run: {}", out.stderr);
        assert!(!out.stdout.contains("WOULD"), "{}", out.stdout);
    }
}

#[test]
fn an_unknown_mode_stops_the_command() {
    let mut env = Env::new();
    env.set("ISSUE_DRAIN_MODE", "admin");
    let out = env.run(&["gh-write", "add-label", "7", "agent-in-progress"]);
    assert_eq!(out.code, 2);
    assert!(env.gh_calls().is_empty());
}

#[test]
fn a_gh_failure_exits_1_and_is_logged() {
    let env = Env::new();
    let body = body(&env);
    env.stub_file("fail-comment", "");
    let out = env.run(&["gh-write", "comment", "7", "--body-file", &body]);
    assert_eq!(out.code, 1);
    assert!(
        out.stderr.contains("gh failed (exit 1): comment on #7"),
        "{}",
        out.stderr
    );
    assert_eq!(env.events_named("gh_write")[0]["rc"], 1);
}

#[test]
fn the_run_folder_and_the_repo_must_be_named() {
    let mut env = Env::new();
    env.set("ISSUE_DRAIN_WORKDIR", "relative/run");
    assert_eq!(env.run(&["gh-write", "add-label", "7", "agent-in-progress"]).code, 2);

    let mut env = Env::new();
    env.set("ISSUE_DRAIN_REPO", "not a repo");
    let out = env.run(&["gh-write", "add-label", "7", "agent-in-progress"]);
    assert_eq!(out.code, 2);
    assert!(out.stderr.contains("ISSUE_DRAIN_REPO"), "{}", out.stderr);
    assert!(env.gh_calls().is_empty());
}

#[test]
fn a_missing_profile_stops_the_command() {
    let mut env = Env::new();
    env.set("ISSUE_DRAIN_PROFILE", "/nonexistent/profile.toml");
    let out = env.run(&["gh-write", "add-label", "7", "agent-in-progress"]);
    assert_eq!(out.code, 2);
    assert!(
        out.stderr.contains("no profile at /nonexistent/profile.toml"),
        "{}",
        out.stderr
    );
    assert!(env.gh_calls().is_empty());
}
