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
fn a_unit_process_cannot_close_unlabel_or_open_an_issue() {
    let mut env = Env::new();
    let body = body(&env);
    env.set("ISSUE_DRAIN_MODE", "unit");
    let refusals: [&[&str]; 3] = [
        &["gh-write", "close-issue", "7"],
        &["gh-write", "remove-label", "7", "agent-in-progress"],
        &["gh-write", "issue-create", "--title", "x", "--body-file", &body],
    ];
    for args in refusals {
        let out = env.run(args);
        assert_eq!(out.code, 3, "{args:?}: {}", out.stderr);
        assert!(out.stderr.contains("is the driver's job in a unit"), "{}", out.stderr);
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

#[test]
fn run_rerun_reaches_gh_with_the_failed_flag_passed_through() {
    let env = Env::new();
    let out = env.run(&["gh-write", "run-rerun", "555"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let out = env.run(&["gh-write", "run-rerun", "555", "--failed"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        env.gh_calls(),
        [
            format!("run rerun 555 --repo {REPO}"),
            format!("run rerun 555 --repo {REPO} --failed")
        ]
    );
    let out = env.run(&["gh-write", "run-rerun", "five"]);
    assert_eq!(out.code, 2, "{}", out.stderr);
    assert_eq!(env.gh_calls().len(), 2);
}

#[test]
fn a_dry_run_of_run_rerun_and_pr_edit_prints_would() {
    let mut env = Env::new();
    env.set("ISSUE_DRAIN_DRY_RUN", "1");
    let body = body(&env);
    let out = env.run(&["gh-write", "run-rerun", "555", "--failed"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        out.stdout.trim(),
        format!("WOULD: gh run rerun 555 --repo {REPO} --failed")
    );
    let out = env.run(&["gh-write", "pr-edit", "9", "--body-file", &body]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        out.stdout.trim(),
        format!("WOULD: gh pr edit 9 --repo {REPO} --body-file {body}")
    );
    assert!(env.gh_calls().is_empty());
}

#[test]
fn pr_edit_replaces_the_body_from_a_file() {
    let env = Env::new();
    let body = body(&env);
    let out = env.run(&["gh-write", "pr-edit", "9", "--body-file", &body]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(env.gh_calls(), [format!("pr edit 9 --repo {REPO} --body-file {body}")]);
    for args in [
        &["gh-write", "pr-edit", "9"][..],
        &["gh-write", "pr-edit", "nine", "--body-file", &body][..],
    ] {
        assert_eq!(env.run(args).code, 2, "{args:?}");
    }
    assert_eq!(env.gh_calls().len(), 1);
}

#[test]
fn a_unit_may_use_neither_run_rerun_nor_pr_edit() {
    let mut env = Env::new();
    env.set("ISSUE_DRAIN_MODE", "unit");
    let body = body(&env);
    for args in [
        &["gh-write", "run-rerun", "555"][..],
        &["gh-write", "pr-edit", "9", "--body-file", &body][..],
    ] {
        let out = env.run(args);
        assert_eq!(out.code, 3, "{args:?}: {}", out.stderr);
    }
    assert!(env.gh_calls().is_empty());
}

#[test]
fn help_prints_the_verbs_and_each_verbs_usage_and_calls_nothing() {
    let env = Env::new();
    let out = env.run(&["gh-write", "--help"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    for verb in ["issue-create", "run-rerun", "pr-edit", "thread-resolve", "remove-label"] {
        assert!(out.stdout.contains(verb), "{verb}: {}", out.stdout);
    }
    let out = env.run(&["gh-write", "pr-edit", "--help"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stdout.contains("--body-file"), "{}", out.stdout);
    let out = env.run(&["gh-write", "run-rerun", "-h"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stdout.contains("--failed"), "{}", out.stdout);
    let out = env.run(&["gh-write", "help"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(env.gh_calls().is_empty());
}

#[test]
fn the_word_help_as_an_option_value_is_not_a_help_request() {
    let env = Env::new();
    let body = body(&env);
    let out = env.run(&["gh-write", "issue-create", "--title", "help", "--body-file", &body]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(env.gh_calls().len(), 1);
    let out = env.run(&["gh-write", "comment", "7", "--body-file", &body, "-h"]);
    // Not right after the verb, so not help: the call goes through.
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(env.gh_calls().len(), 2);
}

#[test]
fn help_needs_no_run_folder_or_profile() {
    let mut env = Env::new();
    env.set("ISSUE_DRAIN_WORKDIR", "")
        .set("ISSUE_DRAIN_REPO", "")
        .set("ISSUE_DRAIN_PROFILE", "");
    let out = env.run(&["gh-write", "--help"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stdout.contains("run-rerun"));
    let out = env.run(&["gh-write", "pr-edit", "--help"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
}

// ---- issue-edit ----

fn api_issue(env: &Env, n: u64, json: &str) {
    env.stub_file(&format!("issue-api-{n}.json"), json);
}

fn writes(env: &Env) -> Vec<String> {
    env.gh_calls().into_iter().filter(|c| c.starts_with("issue ")).collect()
}

#[test]
fn issue_edit_needs_a_flag_and_a_real_body_file() {
    let env = Env::new();
    let empty = env.write("empty.md", "").display().to_string();
    let cases: [&[&str]; 5] = [
        &["gh-write", "issue-edit", "7"],
        &["gh-write", "issue-edit", "seven", "--title", "T"],
        &["gh-write", "issue-edit", "7", "--body-file", &empty],
        &["gh-write", "issue-edit", "7", "--body-file", "-"],
        &["gh-write", "issue-edit", "7", "--body-file", "/nonexistent/b.md"],
    ];
    for args in cases {
        let out = env.run(args);
        assert_eq!(out.code, 2, "{args:?}: {}", out.stderr);
    }
    assert!(env.gh_calls().is_empty(), "{:?}", env.gh_calls());
}

#[test]
fn issue_edit_refuses_a_pull_request_and_a_unit() {
    let mut env = Env::new();
    api_issue(
        &env,
        8,
        r#"{"number":8,"title":"t","body":"b","pull_request":{"url":"x"}}"#,
    );
    let out = env.run(&["gh-write", "issue-edit", "8", "--title", "New"]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("is a pull request; use pr-edit"), "{}", out.stderr);
    assert!(writes(&env).is_empty(), "{:?}", env.gh_calls());

    env.set("ISSUE_DRAIN_MODE", "unit");
    let before = env.gh_calls().len();
    let out = env.run(&["gh-write", "issue-edit", "7", "--title", "New"]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("is the driver's job in a unit"), "{}", out.stderr);
    assert_eq!(env.gh_calls().len(), before);
}

#[test]
fn issue_edit_read_failure_is_exit_1() {
    let env = Env::new();
    let out = env.run(&["gh-write", "issue-edit", "7", "--title", "New"]);
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert!(writes(&env).is_empty());
}

#[test]
fn issue_edit_changes_title_and_body_and_reports_what_github_says() {
    let env = Env::new();
    let body = env.write("new-body.md", "New body\n").display().to_string();
    api_issue(&env, 7, r#"{"number":7,"title":"Old","body":"Old body"}"#);
    env.stub_file(
        "issue-api-7.after-edit.json",
        r#"{"number":7,"title":"New","body":"New body"}"#,
    );
    let out = env.run(&["gh-write", "issue-edit", "7", "--title", "New", "--body-file", &body]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        env.gh_calls(),
        [
            format!("api repos/{REPO}/issues/7"),
            format!("issue edit 7 --repo {REPO} --title New --body-file {body}"),
            format!("api repos/{REPO}/issues/7"),
        ]
    );
    let line: serde_json::Value = serde_json::from_str(out.stdout.trim()).expect("one JSON line");
    assert_eq!(line["issue"], 7);
    assert_eq!(line["title_changed"], true);
    assert_eq!(line["body_changed"], true);
}

#[test]
fn issue_edit_reports_a_change_github_did_not_take() {
    let env = Env::new();
    api_issue(&env, 7, r#"{"number":7,"title":"Old","body":"b"}"#);
    // No after-edit file: the read-back still shows the old title.
    let out = env.run(&["gh-write", "issue-edit", "7", "--title", "New"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let line: serde_json::Value = serde_json::from_str(out.stdout.trim()).expect("one JSON line");
    assert_eq!(line["title_changed"], false);
    assert_eq!(line["body_changed"], false);
}

#[test]
fn issue_edit_dry_run_prints_would_and_calls_nothing() {
    let mut env = Env::new();
    env.set("ISSUE_DRAIN_DRY_RUN", "1");
    let body = body(&env);
    let out = env.run(&["gh-write", "issue-edit", "7", "--title", "New", "--body-file", &body]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        out.stdout.trim(),
        format!("WOULD: gh issue edit 7 --repo {REPO} --title New --body-file {body}")
    );
    assert!(env.gh_calls().is_empty(), "{:?}", env.gh_calls());
}

// ---- unblock ----

const UNBLOCK: &[&str] = &["gh-write", "unblock", "7"];

fn unblock<'a>(extra: &[&'a str]) -> Vec<&'a str> {
    let mut args: Vec<&str> = UNBLOCK.to_vec();
    args.extend_from_slice(extra);
    args
}

#[test]
fn unblock_refuses_non_hold_labels_and_the_claim_label() {
    let env = Env::new();
    let out = env.run(&unblock(&["--label", "bug", "--reason", "r"]));
    assert_eq!(out.code, 3, "{}", out.stderr);
    let out = env.run(&unblock(&["--label", "agent-in-progress", "--reason", "r"]));
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("use claim release"), "{}", out.stderr);
    // One bad label refuses the whole call before any write.
    let out = env.run(&unblock(&["--label", "needs-human", "--label", "bug", "--reason", "r"]));
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(env.gh_calls().is_empty(), "{:?}", env.gh_calls());
}

#[test]
fn unblock_needs_a_reason_a_label_and_a_number() {
    let env = Env::new();
    let cases: [&[&str]; 4] = [
        &["gh-write", "unblock", "7", "--label", "needs-human"],
        &["gh-write", "unblock", "7", "--label", "needs-human", "--reason", ""],
        &["gh-write", "unblock", "7", "--reason", "r"],
        &[
            "gh-write",
            "unblock",
            "seven",
            "--label",
            "needs-human",
            "--reason",
            "r",
        ],
    ];
    for args in cases {
        let out = env.run(args);
        assert_eq!(out.code, 2, "{args:?}: {}", out.stderr);
    }
    assert!(env.gh_calls().is_empty());
}

#[test]
fn unblock_is_refused_in_a_unit() {
    let mut env = Env::new();
    env.set("ISSUE_DRAIN_MODE", "unit");
    let out = env.run(&unblock(&["--label", "needs-human", "--reason", "r"]));
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(env.gh_calls().is_empty());
}

#[test]
fn unblock_skips_a_label_that_is_not_on_the_item() {
    let env = Env::new();
    api_issue(&env, 7, r#"{"number":7,"labels":[{"name":"bug"}]}"#);
    let out = env.run(&unblock(&["--label", "needs-human", "--reason", "r"]));
    assert_eq!(out.code, 0, "{}", out.stderr);
    let line: serde_json::Value = serde_json::from_str(out.stdout.trim()).expect("one JSON line");
    assert_eq!(line["removed"], serde_json::json!([]));
    assert_eq!(line["skipped"], serde_json::json!(["needs-human"]));
    assert_eq!(line["labels_now"], serde_json::json!(["bug"]));
    assert!(writes(&env).is_empty(), "{:?}", env.gh_calls());
}

#[test]
fn unblock_comments_first_then_removes_then_reads_back() {
    let env = Env::new();
    api_issue(
        &env,
        7,
        r#"{"number":7,"labels":[{"name":"needs-human"},{"name":"Blocked"},{"name":"bug"}]}"#,
    );
    env.stub_file(
        "issue-api-7.after-edit.json",
        r#"{"number":7,"labels":[{"name":"bug"}]}"#,
    );
    let out = env.run(&unblock(&[
        "--label",
        "needs-human",
        "--label",
        "blocked",
        "--label",
        "bug-not-hold-skip",
        "--reason",
        "owner answered",
    ]));
    // bug-not-hold-skip is not a hold label: the whole call is refused.
    assert_eq!(out.code, 3, "{}", out.stderr);

    let out = env.run(&unblock(&[
        "--label",
        "needs-human",
        "--label",
        "blocked",
        "--reason",
        "owner answered",
    ]));
    assert_eq!(out.code, 0, "{}", out.stderr);
    let calls = env.gh_calls();
    assert_eq!(calls.len(), 5, "{calls:?}");
    assert_eq!(calls[0], format!("api repos/{REPO}/issues/7"));
    assert!(
        calls[1].starts_with(&format!("issue comment 7 --repo {REPO} --body-file ")),
        "{calls:?}"
    );
    assert_eq!(
        calls[2],
        format!("issue edit 7 --repo {REPO} --remove-label needs-human")
    );
    assert_eq!(calls[3], format!("issue edit 7 --repo {REPO} --remove-label Blocked"));
    assert_eq!(calls[4], format!("api repos/{REPO}/issues/7"));
    let posted = std::fs::read_to_string(env.stub.join("last-comment-body")).expect("the comment body");
    assert_eq!(posted.trim_end(), "Removed `needs-human`, `Blocked`: owner answered");
    let line: serde_json::Value = serde_json::from_str(out.stdout.trim()).expect("one JSON line");
    assert_eq!(line["number"], 7);
    assert_eq!(line["removed"], serde_json::json!(["needs-human", "Blocked"]));
    assert_eq!(line["skipped"], serde_json::json!([]));
    assert_eq!(line["labels_now"], serde_json::json!(["bug"]));
}

#[test]
fn unblock_fails_when_the_label_is_still_there_after_the_write() {
    let env = Env::new();
    // No after-edit file: the read-back still shows needs-human.
    api_issue(&env, 7, r#"{"number":7,"labels":[{"name":"needs-human"}]}"#);
    let out = env.run(&unblock(&["--label", "needs-human", "--reason", "r"]));
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert!(out.stderr.contains("still"), "{}", out.stderr);
}

#[test]
fn unblock_dry_run_prints_would_lines_and_writes_nothing() {
    let mut env = Env::new();
    env.set("ISSUE_DRAIN_DRY_RUN", "1");
    let out = env.run(&unblock(&["--label", "needs-human", "--reason", "r"]));
    assert_eq!(out.code, 0, "{}", out.stderr);
    let lines: Vec<&str> = out.stdout.lines().collect();
    assert_eq!(lines.len(), 2, "{}", out.stdout);
    assert!(
        lines[0].starts_with(&format!("WOULD: gh issue comment 7 --repo {REPO} --body-file ")),
        "{}",
        out.stdout
    );
    assert_eq!(
        lines[1],
        format!("WOULD: gh issue edit 7 --repo {REPO} --remove-label needs-human")
    );
    assert!(env.gh_calls().is_empty(), "{:?}", env.gh_calls());
}

// ---- review fixes ----

#[test]
fn issue_edit_refuses_the_tracker_issue_by_label_and_by_tracker_json() {
    let env = Env::new();
    api_issue(
        &env,
        9,
        r#"{"number":9,"title":"t","body":"b","labels":[{"name":"issue-drain"}]}"#,
    );
    let out = env.run(&["gh-write", "issue-edit", "9", "--title", "New"]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("tracker label"), "{}", out.stderr);
    assert!(writes(&env).is_empty(), "{:?}", env.gh_calls());

    std::fs::create_dir_all(&env.workdir).unwrap();
    std::fs::write(env.workdir.join("tracker.json"), r#"{"number":10}"#).unwrap();
    let before = env.gh_calls().len();
    let out = env.run(&["gh-write", "issue-edit", "10", "--title", "New"]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("tracker issue"), "{}", out.stderr);
    let mut env = env;
    env.set("ISSUE_DRAIN_DRY_RUN", "1");
    let out = env.run(&["gh-write", "issue-edit", "10", "--title", "New"]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(env.gh_calls().len(), before, "{:?}", env.gh_calls());
}

#[test]
fn unblock_refuses_a_label_with_a_comma_before_any_write() {
    let env = Env::new();
    let out = env.run(&unblock(&["--label", "needs-human,blocked", "--reason", "r"]));
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("contains a comma"), "{}", out.stderr);
    assert!(env.gh_calls().is_empty(), "{:?}", env.gh_calls());
}

#[test]
fn issue_edit_refuses_a_body_file_that_is_not_utf8() {
    let env = Env::new();
    let path = env.dir.path().join("bad.md");
    std::fs::write(&path, [0xff, 0xfe, 0xfd]).unwrap();
    let out = env.run(&[
        "gh-write",
        "issue-edit",
        "7",
        "--body-file",
        &path.display().to_string(),
    ]);
    assert_eq!(out.code, 2, "{}", out.stderr);
    assert!(env.gh_calls().is_empty(), "{:?}", env.gh_calls());
}

#[test]
fn an_option_without_its_value_is_a_usage_error() {
    let env = Env::new();
    for opt in ["--body-file", "--title", "--head", "--base", "--thread", "--reason"] {
        let out = env.run(&["gh-write", "issue-edit", "7", "--title", "x", opt]);
        assert_eq!(out.code, 2, "{opt}: {}", out.stderr);
        assert!(out.stderr.contains("needs a value"), "{opt}: {}", out.stderr);
    }
    assert!(env.gh_calls().is_empty(), "{:?}", env.gh_calls());
}

#[test]
fn unblock_stages_its_comment_in_a_per_process_file() {
    let env = Env::new();
    api_issue(&env, 7, r#"{"number":7,"labels":[{"name":"needs-human"}]}"#);
    env.stub_file("issue-api-7.after-edit.json", r#"{"number":7,"labels":[]}"#);
    let out = env.run(&unblock(&["--label", "needs-human", "--reason", "r"]));
    assert_eq!(out.code, 0, "{}", out.stderr);
    let staged: Vec<String> = std::fs::read_dir(&env.workdir)
        .unwrap()
        .filter_map(|e| e.ok()?.file_name().into_string().ok())
        .filter(|n| n.starts_with("unblock-7-") && n.ends_with("-comment.md"))
        .collect();
    assert_eq!(staged.len(), 1, "{staged:?}");
    assert_ne!(staged[0], "unblock-7-comment.md");
}

#[test]
fn an_option_is_not_a_value_for_the_option_before_it() {
    let env = Env::new();
    let body = env.write("notes.md", "n\n").display().to_string();
    let cases: [&[&str]; 2] = [
        &["gh-write", "issue-edit", "7", "--title", "--body-file", &body],
        &[
            "gh-write",
            "unblock",
            "7",
            "--label",
            "needs-human",
            "--reason",
            "--something",
        ],
    ];
    for args in cases {
        let out = env.run(args);
        assert_eq!(out.code, 2, "{args:?}: {}", out.stderr);
        assert!(out.stderr.contains("needs a value"), "{}", out.stderr);
    }
    assert!(env.gh_calls().is_empty(), "{:?}", env.gh_calls());
}

#[test]
fn unblock_refuses_a_label_gh_would_reinterpret_as_csv() {
    let env = Env::new();
    let out = env.run(&unblock(&["--label", "needs\"human", "--reason", "r"]));
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("would reinterpret"), "{}", out.stderr);
    assert!(env.gh_calls().is_empty(), "{:?}", env.gh_calls());
}

#[test]
fn a_body_file_of_dash_is_refused_even_when_such_a_file_exists() {
    let env = Env::new();
    env.write("-", "x\n");
    for args in [
        &["gh-write", "issue-edit", "7", "--body-file", "-"][..],
        &["gh-write", "comment", "7", "--body-file", "-"][..],
        &["gh-write", "pr-edit", "7", "--body-file", "-"][..],
    ] {
        let out = env.run(args);
        assert_eq!(out.code, 2, "{args:?}: {}", out.stderr);
        assert!(out.stderr.contains("./-"), "{}", out.stderr);
    }
    assert!(env.gh_calls().is_empty(), "{:?}", env.gh_calls());
}

#[test]
fn unblock_fails_when_a_skipped_label_shows_up_by_the_read_back() {
    let env = Env::new();
    api_issue(&env, 7, r#"{"number":7,"labels":[{"name":"needs-human"}]}"#);
    env.stub_file(
        "issue-api-7.after-edit.json",
        r#"{"number":7,"labels":[{"name":"blocked"}]}"#,
    );
    let out = env.run(&unblock(&[
        "--label",
        "needs-human",
        "--label",
        "blocked",
        "--reason",
        "r",
    ]));
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert!(out.stderr.contains("'blocked' is still on"), "{}", out.stderr);
}

#[test]
fn issue_edit_does_not_call_an_unchanged_title_changed() {
    let env = Env::new();
    api_issue(&env, 7, r#"{"number":7,"title":"Same","body":"b"}"#);
    let out = env.run(&["gh-write", "issue-edit", "7", "--title", "Same"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let line: serde_json::Value = serde_json::from_str(out.stdout.trim()).expect("one JSON line");
    assert_eq!(line["title_changed"], false);
}
