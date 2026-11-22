//! `issue-drain base-sync`. Each test has a bare origin, a checkout, a unit
//! worktree made by `unit-prepare` with one commit pushed on the unit's branch,
//! and a second clone that plays GitHub's "update branch": it merges or
//! rebases the base into the branch and pushes. The stub gh only records the
//! `gh pr update-branch` call and answers `gh pr view` with the new head.

use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use crate::common::*;

pub const BRANCH: &str = "fix/3-zero-pad-the-countdown-seconds-with-form";
pub const PR: &str = "7";

pub struct Case {
    pub env: Env,
    pub bare: PathBuf,
    pub work: PathBuf,
    /// The unit worktree.
    pub wt: PathBuf,
    /// The head the unit pushed, before any sync.
    pub old_head: String,
}

pub fn identity(dir: &Path, args: &[&str]) -> String {
    let mut all = vec!["-c", "user.name=T", "-c", "user.email=t@example.invalid"];
    all.extend_from_slice(args);
    git(dir, &all)
}

pub fn case() -> Case {
    let mut env = Env::new();
    let dir = env.dir.path().to_path_buf();
    let work = private_repo(&dir);
    let bare = dir.join("origin.git");
    git(
        &dir,
        &[
            "clone",
            "-q",
            "--bare",
            &work.display().to_string(),
            &bare.display().to_string(),
        ],
    );
    let checkout = origin_clone(&dir, &bare);
    env.set("ISSUE_DRAIN_REPO_DIR", &checkout.display().to_string());
    env.write("queue.json", &queue_with_unit(json!({})).to_string());
    let out = env.run(&["unit-prepare", "--unit", "3"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let wt = fs::canonicalize(&env.workdir)
        .expect("the run folder")
        .join("worktrees/3");
    fs::write(wt.join("src/timer/countdown.ts"), "export const padded = true;\n").expect("the file");
    git(&wt, &["add", "src/timer/countdown.ts"]);
    identity(&wt, &["commit", "-q", "-m", "pad"]);
    git(&wt, &["push", "-q", "origin", BRANCH]);
    let old_head = git(&wt, &["rev-parse", "HEAD"]);
    Case {
        env,
        bare,
        work,
        wt,
        old_head,
    }
}

impl Case {
    /// A new commit on origin's develop.
    fn advance_base(&self) -> String {
        fs::write(self.work.join("NEW.md"), "new\n").expect("the file");
        git(&self.work, &["add", "NEW.md"]);
        identity(&self.work, &["commit", "-q", "-m", "new"]);
        git(&self.work, &["push", "-q", &self.bare.display().to_string(), "develop"]);
        git(&self.work, &["rev-parse", "HEAD"])
    }

    /// What GitHub's update-branch does: merge develop into the branch and
    /// push. Returns the new head.
    fn update_branch(&self, merge: bool) -> String {
        let other = self.env.dir.path().join("other");
        if !other.exists() {
            git(
                self.env.dir.path(),
                &[
                    "clone",
                    "-q",
                    &self.bare.display().to_string(),
                    &other.display().to_string(),
                ],
            );
        }
        git(&other, &["fetch", "-q", "origin"]);
        git(&other, &["checkout", "-q", "-B", BRANCH, &format!("origin/{BRANCH}")]);
        if merge {
            identity(
                &other,
                &["merge", "-q", "--no-ff", "-m", "Update branch", "origin/develop"],
            );
        } else {
            identity(&other, &["rebase", "-q", "origin/develop"]);
        }
        git(&other, &["push", "-q", "--force", "origin", BRANCH]);
        git(&other, &["rev-parse", "HEAD"])
    }

    fn pr_is_at(&self, head: &str) {
        self.env.stub_file(
            &format!("pr-view-{PR}.json"),
            &json!({"headRefOid": head, "headRefName": BRANCH, "state": "OPEN"}).to_string(),
        );
    }

    fn proof_for(&self, head: &str) {
        self.env.write(
            "units/3/review-proof.json",
            &json!({"head": head, "reviewers": []}).to_string(),
        );
    }

    fn sync(&self) -> Out {
        self.env.run(&["base-sync", "--unit", "3", "--pr", PR])
    }

    fn update_calls(&self) -> usize {
        self.env
            .gh_calls()
            .iter()
            .filter(|c| c.contains("update-branch"))
            .count()
    }
}

fn printed(out: &Out) -> Value {
    assert_eq!(out.code, 0, "{}", out.stderr);
    serde_json::from_str(out.stdout.trim()).expect("one JSON line on stdout")
}

#[test]
fn a_sync_updates_the_branch_moves_the_worktree_and_rewrites_deliver_json() {
    let c = case();
    c.advance_base();
    let new_head = c.update_branch(true);
    c.pr_is_at(&new_head);
    c.proof_for(&c.old_head);

    let out = printed(&c.sync());
    assert_eq!(out["unit"], 3);
    assert_eq!(out["pr"], 7);
    assert_eq!(out["old_head"], c.old_head);
    assert_eq!(out["new_head"], new_head);
    assert_eq!(out["deliver_ok"], true);
    assert_eq!(git(&c.wt, &["rev-parse", "HEAD"]), new_head);
    assert_eq!(c.update_calls(), 1);
    assert!(
        c.env
            .gh_calls()
            .iter()
            .any(|call| call.starts_with("pr update-branch 7 --repo example/tidepool")),
        "{:?}",
        c.env.gh_calls()
    );

    let deliver = json(&c.env.workdir.join("units/3/deliver.json"));
    assert_eq!(deliver["head"], new_head);
    assert_eq!(deliver["ok"], true);
    assert_eq!(deliver["merge_base"], git(&c.wt, &["rev-parse", "origin/develop"]));
    assert_eq!(c.env.events_named("base_sync").len(), 1);
}

#[test]
fn a_single_base_only_merge_over_the_reviewed_head_needs_no_review_round() {
    let c = case();
    c.advance_base();
    let new_head = c.update_branch(true);
    c.pr_is_at(&new_head);
    c.proof_for(&c.old_head);
    let out = printed(&c.sync());
    assert_eq!(out["review_round_needed"], false, "{out}");
}

#[test]
fn a_merge_over_a_commit_that_was_not_reviewed_needs_a_review_round() {
    let c = case();
    let base = c.advance_base();
    let new_head = c.update_branch(true);
    c.pr_is_at(&new_head);
    // The proof is for an older commit, not the merge's first parent.
    c.proof_for(&base);
    let out = printed(&c.sync());
    assert_eq!(out["review_round_needed"], true, "{out}");
}

#[test]
fn a_head_that_added_work_besides_the_merge_needs_a_review_round() {
    let c = case();
    c.advance_base();
    c.update_branch(true);
    // Someone pushed one more commit after the merge: the head's first parent
    // is the merge, not the reviewed commit.
    let other = c.env.dir.path().join("other");
    fs::write(other.join("EXTRA.md"), "x\n").expect("the file");
    git(&other, &["add", "EXTRA.md"]);
    identity(&other, &["commit", "-q", "-m", "extra"]);
    git(&other, &["push", "-q", "origin", BRANCH]);
    let new_head = git(&other, &["rev-parse", "HEAD"]);
    c.pr_is_at(&new_head);
    c.proof_for(&c.old_head);
    let out = printed(&c.sync());
    assert_eq!(out["review_round_needed"], true, "{out}");
}

#[test]
fn no_review_proof_at_all_needs_a_review_round() {
    let c = case();
    c.advance_base();
    let new_head = c.update_branch(true);
    c.pr_is_at(&new_head);
    let out = printed(&c.sync());
    assert_eq!(out["review_round_needed"], true, "{out}");
}

#[test]
fn a_proof_that_already_names_the_new_head_needs_no_review_round() {
    let c = case();
    c.advance_base();
    let new_head = c.update_branch(true);
    c.pr_is_at(&new_head);
    c.proof_for(&new_head);
    let out = printed(&c.sync());
    assert_eq!(out["review_round_needed"], false, "{out}");
}

#[test]
fn the_fifth_sync_of_a_unit_is_refused_before_anything_is_called() {
    let c = case();
    c.advance_base();
    let new_head = c.update_branch(true);
    c.pr_is_at(&new_head);
    let lines: Vec<String> = (0..4)
        .map(|_| json!({"ts": "2026-11-21T03:53:00Z", "event": "base_sync", "unit": 3}).to_string())
        .collect();
    c.env.write("events.jsonl", &format!("{}\n", lines.join("\n")));

    let out = c.sync();
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("4"), "{}", out.stderr);
    assert_eq!(c.update_calls(), 0);
    assert_eq!(
        git(&c.wt, &["rev-parse", "HEAD"]),
        c.old_head,
        "the worktree did not move"
    );
}

#[test]
fn a_fourth_sync_still_goes_through_and_another_units_syncs_do_not_count() {
    let c = case();
    c.advance_base();
    let new_head = c.update_branch(true);
    c.pr_is_at(&new_head);
    let mut lines: Vec<String> = (0..3)
        .map(|_| json!({"ts": "2026-11-21T03:53:00Z", "event": "base_sync", "unit": 3}).to_string())
        .collect();
    lines.extend((0..5).map(|_| json!({"ts": "2026-11-21T03:53:00Z", "event": "base_sync", "unit": 9}).to_string()));
    c.env.write("events.jsonl", &format!("{}\n", lines.join("\n")));
    assert_eq!(c.sync().code, 0);
}

#[test]
fn a_dry_run_says_what_it_would_do_and_does_nothing() {
    let mut c = case();
    c.advance_base();
    let new_head = c.update_branch(true);
    c.pr_is_at(&new_head);
    c.env.set("ISSUE_DRAIN_DRY_RUN", "1");
    let out = c.sync();
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stdout.contains("WOULD: gh pr update-branch 7"), "{}", out.stdout);
    assert_eq!(c.update_calls(), 0);
    assert_eq!(git(&c.wt, &["rev-parse", "HEAD"]), c.old_head);
    assert!(c.env.events_named("base_sync").is_empty());
}

#[test]
fn a_unit_process_may_not_sync() {
    let mut c = case();
    c.env.set("ISSUE_DRAIN_MODE", "unit");
    let out = c.sync();
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(c.update_calls(), 0);
}

#[test]
fn a_failed_update_call_changes_nothing() {
    let c = case();
    c.advance_base();
    let new_head = c.update_branch(true);
    c.pr_is_at(&new_head);
    c.env.stub_file("fail-update-branch", "");
    let out = c.sync();
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert_eq!(git(&c.wt, &["rev-parse", "HEAD"]), c.old_head);
    assert!(c.env.events_named("base_sync").is_empty());
}

#[test]
fn the_pr_number_comes_from_the_state_log_when_not_given() {
    let c = case();
    c.advance_base();
    let new_head = c.update_branch(true);
    c.pr_is_at(&new_head);
    for to in ["claimed", "prepared", "implementing"] {
        assert_eq!(c.env.run(&["state", "event", "3", to]).code, 0);
    }
    assert_eq!(c.env.run(&["state", "event", "3", "pr_open", "--pr", PR]).code, 0);
    let out = c.env.run(&["base-sync", "--unit", "3"]);
    assert_eq!(printed(&out)["pr"], 7);
}
