//! `issue-drain post-merge`. Each test starts from `base_sync::case()` (a bare
//! origin, a checkout and a unit worktree with one pushed commit), plays
//! GitHub's squash merge into origin's develop, and has the stub gh answer
//! PR 7 as merged at that commit.

use std::fs;

use serde_json::{Value, json};

use crate::base_sync::{BRANCH, Case, PR, case, identity, pr_json};
use crate::common::*;

/// Squash the unit's branch onto origin's develop, as GitHub does. Returns
/// the merge commit.
fn squash_merge(c: &Case) -> String {
    git(&c.work, &["fetch", "-q", &c.bare.display().to_string(), BRANCH]);
    git(&c.work, &["merge", "--squash", "FETCH_HEAD"]);
    identity(&c.work, &["commit", "-q", "-m", "pad (#7)"]);
    git(&c.work, &["push", "-q", &c.bare.display().to_string(), "develop"]);
    git(&c.work, &["rev-parse", "HEAD"])
}

/// PR 7 merged at `merge`, closing `refs`.
fn merged(c: &Case, merge: &str, refs: &[u64]) {
    let mut view = pr_json("MERGED", &c.old_head, "example", "develop");
    view["mergeCommit"] = json!({"oid": merge});
    view["closingIssuesReferences"] = json!(refs.iter().map(|n| json!({"number": n})).collect::<Vec<_>>());
    c.pr_with(&view);
}

fn issue(c: &Case, number: u64, state: &str) {
    c.env.stub_file(
        &format!("issue-view-{number}.json"),
        &json!({"state": state}).to_string(),
    );
}

fn post_merge(c: &Case) -> Out {
    c.env.run(&["post-merge", "--unit", "3", "--pr", PR])
}

fn printed(out: &Out) -> Value {
    serde_json::from_str(out.stdout.trim().lines().last().expect("a line")).expect("a JSON line")
}

fn quick(c: &mut Case) {
    c.env.set("ISSUE_DRAIN_POST_MERGE_WAIT_SECS", "0");
}

#[test]
fn a_merge_with_the_approved_tree_and_an_issue_the_merge_closed() {
    let mut c = case();
    quick(&mut c);
    let merge = squash_merge(&c);
    merged(&c, &merge, &[103, 999]);
    issue(&c, 103, "CLOSED");
    c.env
        .write("units/3/result.json", &json!({"unit": 3, "closes": [103]}).to_string());
    let out = post_merge(&c);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let r = printed(&out);
    assert_eq!(r["unit"], 3);
    assert_eq!(r["pr"], 7);
    assert_eq!(r["merge_commit"], merge);
    assert_eq!(r["head"], c.old_head);
    assert_eq!(r["tree_match"], true);
    assert_eq!(r["closed_by_merge"], json!([103]));
    assert_eq!(r["closed_here"], json!([]));
    assert_eq!(r["still_open"], json!([]));
    assert_eq!(r["claims_released"], json!([]));
    assert!(!out.stderr.contains("moved"), "{}", out.stderr);
    // result.json narrows the PR's references: #999 is never read or closed.
    let calls = c.env.gh_calls().join("\n");
    assert!(!calls.contains("999"), "{calls}");
    assert!(!calls.contains("issue close"), "{calls}");
    assert_eq!(c.env.events_named("post_merge").len(), 1);
    assert!(c.wt.exists(), "post-merge leaves the worktree to cleanup");
}

#[test]
fn a_moved_base_is_reported_but_is_not_an_error() {
    let mut c = case();
    quick(&mut c);
    c.advance_base();
    let merge = squash_merge(&c);
    merged(&c, &merge, &[103]);
    issue(&c, 103, "CLOSED");
    let out = post_merge(&c);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(printed(&out)["tree_match"], false);
    assert!(out.stderr.contains("develop moved"), "{}", out.stderr);
    assert!(out.stderr.contains("verify"), "{}", out.stderr);
}

#[test]
fn the_trees_are_compared_in_the_checkout_once_the_worktree_is_gone() {
    let mut c = case();
    quick(&mut c);
    let merge = squash_merge(&c);
    merged(&c, &merge, &[103]);
    issue(&c, 103, "CLOSED");
    let checkout = c.env.dir.path().join("checkout");
    git(
        &checkout,
        &["worktree", "remove", "--force", &c.wt.display().to_string()],
    );
    let out = post_merge(&c);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(printed(&out)["tree_match"], true);
}

#[test]
fn an_issue_the_merge_left_open_is_closed_here_with_a_comment() {
    let mut c = case();
    quick(&mut c);
    let merge = squash_merge(&c);
    merged(&c, &merge, &[103]);
    issue(&c, 103, "OPEN");
    let out = post_merge(&c);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let r = printed(&out);
    assert_eq!(r["closed_by_merge"], json!([]));
    assert_eq!(r["closed_here"], json!([103]));
    assert_eq!(r["still_open"], json!([]));
    let body = fs::read_to_string(c.env.stub.join("last-comment-body")).expect("a comment was posted");
    assert_eq!(body, format!("Fixed by #7 (merged as {}).\n", &merge[..7]));
    let calls = c.env.gh_calls();
    let comment = calls
        .iter()
        .position(|l| l.starts_with("issue comment 103"))
        .expect("a comment");
    let close = calls
        .iter()
        .position(|l| l.starts_with("issue close 103"))
        .expect("a close");
    assert!(comment < close, "the reason goes first: {calls:?}");
}

#[test]
fn an_issue_that_stays_open_fails_the_command() {
    let mut c = case();
    quick(&mut c);
    c.env.set("GH_STUB_CLOSE_NOOP", "1");
    let merge = squash_merge(&c);
    merged(&c, &merge, &[103]);
    issue(&c, 103, "OPEN");
    let out = post_merge(&c);
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert_eq!(printed(&out)["still_open"], json!([103]));
    assert!(out.stderr.contains("#103"), "{}", out.stderr);
}

#[test]
fn a_pr_that_is_not_merged_is_refused() {
    let mut c = case();
    quick(&mut c);
    c.pr_with(&pr_json("OPEN", &c.old_head, "example", "develop"));
    let out = post_merge(&c);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("OPEN"), "{}", out.stderr);
    assert!(c.env.events_named("post_merge").is_empty());
}

#[test]
fn a_unit_process_is_refused() {
    let mut c = case();
    c.env.set("ISSUE_DRAIN_MODE", "unit");
    let before = c.env.gh_calls().len();
    let out = post_merge(&c);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("driver"), "{}", out.stderr);
    assert_eq!(c.env.gh_calls().len(), before, "a refused command reads nothing");
}

#[test]
fn a_dry_run_reads_but_writes_nothing() {
    let mut c = case();
    quick(&mut c);
    c.env.set("ISSUE_DRAIN_DRY_RUN", "1");
    let merge = squash_merge(&c);
    merged(&c, &merge, &[103]);
    issue(&c, 103, "OPEN");
    let out = post_merge(&c);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stdout.contains("WOULD: gh issue comment 103"), "{}", out.stdout);
    assert!(out.stdout.contains("WOULD: gh issue close 103"), "{}", out.stdout);
    let r = printed(&out);
    assert_eq!(r["closed_here"], json!([103]));
    assert_eq!(r["dry_run"], true);
    let calls = c.env.gh_calls();
    assert!(
        !calls
            .iter()
            .any(|l| l.starts_with("issue comment") || l.starts_with("issue close")),
        "{calls:?}"
    );
    assert!(!c.env.stub.join("closed-103").exists());
}
