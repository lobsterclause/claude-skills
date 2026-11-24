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

/// What `gh pr view` answers for PR 7: the unit's branch, in `owner`'s copy of
/// the tidepool repo, aimed at `base`.
pub fn pr_json(state: &str, head: &str, owner: &str, base: &str) -> Value {
    json!({
        "state": state, "headRefOid": head, "headRefName": BRANCH, "baseRefName": base,
        "headRepository": {"name": "tidepool"}, "headRepositoryOwner": {"login": owner},
        "mergeStateStatus": "CLEAN", "reviewDecision": "", "labels": [], "body": "",
        "closingIssuesReferences": [], "changedFiles": 1, "statusCheckRollup": [], "mergeCommit": null
    })
}

/// A stand-in merge_preflight.sh that reads `status` with a CLEAN verdict.
pub fn preflight(env: &Env, status: &str, head: &str) {
    use std::os::unix::fs::PermissionsExt;
    let path = env.dir.path().join("preflight.sh");
    let out = json!({"status": status, "verdict": "CLEAN", "head": head, "reviewed": head});
    fs::write(&path, format!("#!/bin/sh\ncat <<'EOF'\n{out}\nEOF\n")).expect("the script");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).expect("chmod");
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
    preflight(&env, "clear", &"a".repeat(40));
    let script = env.dir.path().join("preflight.sh").display().to_string();
    env.set("ISSUE_DRAIN_MERGE_PREFLIGHT", &script);
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
    pub fn advance_base(&self) -> String {
        let before = fs::read_to_string(self.work.join("NEW.md")).unwrap_or_default();
        fs::write(self.work.join("NEW.md"), format!("{before}new\n")).expect("the file");
        git(&self.work, &["add", "NEW.md"]);
        identity(&self.work, &["commit", "-q", "-m", "new"]);
        git(&self.work, &["push", "-q", &self.bare.display().to_string(), "develop"]);
        git(&self.work, &["rev-parse", "HEAD"])
    }

    /// What GitHub's update-branch does: merge develop into the branch and
    /// push. Returns the new head.
    pub fn update_branch(&self, merge: bool) -> String {
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

    pub fn pr_is_at(&self, head: &str) {
        self.pr_with(&pr_json("OPEN", head, "example", "develop"));
        // The review read is of this head, as it would be live.
        preflight(&self.env, "clear", head);
    }

    pub fn pr_with(&self, view: &Value) {
        self.env.stub_file(&format!("pr-view-{PR}.json"), &view.to_string());
    }

    pub fn proof_for(&self, head: &str) {
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
        .map(|_| json!({"ts": "2026-11-21T03:53:00Z", "event": "base_sync_remote", "unit": 3}).to_string())
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
        .map(|_| json!({"ts": "2026-11-21T03:53:00Z", "event": "base_sync_remote", "unit": 3}).to_string())
        .collect();
    lines.extend(
        (0..5).map(|_| json!({"ts": "2026-11-21T03:53:00Z", "event": "base_sync_remote", "unit": 9}).to_string()),
    );
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

#[test]
fn a_fork_pr_or_a_pr_for_another_base_is_never_updated() {
    let c = case();
    c.advance_base();
    let new_head = c.update_branch(true);
    for view in [
        pr_json("OPEN", &new_head, "someone-else", "develop"),
        pr_json("OPEN", &new_head, "example", "release"),
    ] {
        c.pr_with(&view);
        let out = c.sync();
        assert_eq!(out.code, 3, "{}", out.stderr);
        assert_eq!(c.update_calls(), 0);
    }
    assert_eq!(git(&c.wt, &["rev-parse", "HEAD"]), c.old_head);
}

#[test]
fn a_review_record_that_is_not_clear_needs_a_round_even_for_a_two_parent_head() {
    let c = case();
    c.advance_base();
    let new_head = c.update_branch(true);
    c.pr_is_at(&new_head);
    c.proof_for(&c.old_head);
    // The merge changed the reviewed diff's digest, so the script says stale.
    preflight(&c.env, "stale", &new_head);
    assert_eq!(printed(&c.sync())["review_round_needed"], true);
}

#[test]
fn an_unreadable_review_record_needs_a_round() {
    let mut c = case();
    c.advance_base();
    let new_head = c.update_branch(true);
    c.pr_is_at(&new_head);
    c.proof_for(&c.old_head);
    c.env
        .set("ISSUE_DRAIN_MERGE_PREFLIGHT", "/nonexistent/merge_preflight.sh");
    assert_eq!(printed(&c.sync())["review_round_needed"], true);
}

fn seed_remote_syncs(c: &Case, count: usize) {
    // Finished syncs: the remote update, then the local follow-up.
    let lines: Vec<String> = (0..count)
        .flat_map(|_| ["base_sync_remote", "base_sync"])
        .map(|name| json!({"ts": "2026-11-21T03:53:00Z", "event": name, "unit": 3}).to_string())
        .collect();
    c.env.write("events.jsonl", &format!("{}\n", lines.join("\n")));
}

#[test]
fn the_remote_update_is_logged_before_the_local_steps_and_spends_a_slot() {
    let c = case();
    c.advance_base();
    c.update_branch(true);
    seed_remote_syncs(&c, 3);
    // GitHub names a head the branch does not have, so the local follow-up fails.
    c.pr_is_at(&"f".repeat(40));
    assert_eq!(c.sync().code, 1);
    assert_eq!(c.env.events_named("base_sync_remote").len(), 4);
    assert_eq!(c.env.events_named("base_sync").len(), 3, "no new finished sync");
}

#[test]
fn a_retry_after_a_failed_follow_up_resumes_without_another_update_or_slot() {
    let c = case();
    c.advance_base();
    let new_head = c.update_branch(true);
    c.pr_is_at(&"f".repeat(40));
    assert_eq!(c.sync().code, 1);
    assert_eq!(c.update_calls(), 1);

    c.pr_is_at(&new_head);
    let out = printed(&c.sync());
    assert_eq!(out["new_head"], new_head);
    assert_eq!(out["old_head"], c.old_head);
    assert_eq!(c.update_calls(), 1, "the PR head had already moved: no second update");
    assert_eq!(c.env.events_named("base_sync_remote").len(), 1);
    assert_eq!(c.env.events_named("base_sync").len(), 1);
    assert_eq!(git(&c.wt, &["rev-parse", "HEAD"]), new_head);
}

#[test]
fn three_recorded_syncs_and_one_unmatched_request_reach_the_cap() {
    let c = case();
    c.advance_base();
    let new_head = c.update_branch(true);
    c.pr_is_at(&new_head);
    // Three gate-to-ci_wait moves a person recorded by hand, then a request no move accounts for.
    let mut lines: Vec<String> = (0..3)
        .map(|_| json!({"ts": "t", "unit": 3, "from": "gate", "to": "ci_wait"}).to_string())
        .collect();
    lines.push(json!({"ts": "t", "event": "base_sync_remote", "unit": 3, "pr": 7, "pr_head": new_head}).to_string());
    c.env.write("events.jsonl", &format!("{}\n", lines.join("\n")));
    let out = c.sync();
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(c.update_calls(), 0);
}

#[test]
fn a_request_a_later_transition_records_is_counted_once() {
    let c = case();
    c.advance_base();
    let new_head = c.update_branch(true);
    c.pr_is_at(&new_head);
    let mut lines: Vec<String> = Vec::new();
    for _ in 0..3 {
        lines.push(json!({"ts": "t", "event": "base_sync_remote", "unit": 3}).to_string());
        lines.push(json!({"ts": "t", "event": "base_sync", "unit": 3}).to_string());
        lines.push(json!({"ts": "t", "unit": 3, "from": "gate", "to": "ci_wait"}).to_string());
    }
    c.env.write("events.jsonl", &format!("{}\n", lines.join("\n")));
    assert_eq!(c.sync().code, 0, "3 syncs, each recorded twice, are 3");
}

#[test]
fn a_pending_request_for_another_pr_is_not_resumed() {
    let c = case();
    c.advance_base();
    let new_head = c.update_branch(true);
    c.pr_is_at(&new_head);
    let line = json!({"ts": "t", "event": "base_sync_remote", "unit": 3, "pr": 8, "pr_head": "e".repeat(40)});
    c.env.write("events.jsonl", &format!("{line}\n"));
    assert_eq!(c.sync().code, 0);
    assert_eq!(c.update_calls(), 1, "PR 7 gets its own request");
}

#[test]
fn an_update_github_has_not_applied_yet_is_not_recorded_as_done() {
    let c = case();
    c.advance_base();
    // The PR still stands at the old head: the base is not in it.
    c.pr_is_at(&c.old_head);
    let out = c.sync();
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert!(out.stderr.contains("not in the PR"), "{}", out.stderr);
    assert_eq!(c.env.events_named("base_sync_remote").len(), 1);
    assert!(c.env.events_named("base_sync").is_empty());
}

#[test]
fn a_review_read_of_another_head_does_not_clear_the_new_one() {
    let c = case();
    c.advance_base();
    let new_head = c.update_branch(true);
    c.pr_is_at(&new_head);
    c.proof_for(&c.old_head);
    preflight(&c.env, "clear", &"b".repeat(40));
    assert_eq!(printed(&c.sync())["review_round_needed"], true);
}

#[test]
fn a_pending_update_whose_base_is_not_in_the_pr_yet_waits_without_a_new_request() {
    let c = case();
    let base = c.advance_base();
    // The PR head has moved (someone pushed), but the base the request aimed at is not in it.
    c.pr_is_at(&c.old_head);
    let line = json!({"ts": "t", "event": "base_sync_remote", "unit": 3, "pr": 7,
        "pr_head": "e".repeat(40), "local_head": c.old_head, "base_head": base});
    c.env.write("events.jsonl", &format!("{line}\n"));
    let out = c.sync();
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert!(out.stderr.contains("still pending"), "{}", out.stderr);
    assert_eq!(c.update_calls(), 0);
    assert_eq!(c.env.events_named("base_sync_remote").len(), 1, "no second slot");
}

#[test]
fn a_pending_update_that_landed_but_whose_base_moved_again_gets_a_fresh_sync() {
    let c = case();
    let first = c.advance_base();
    let new_head = c.update_branch(true);
    c.advance_base();
    c.pr_is_at(&new_head);
    let line = json!({"ts": "t", "event": "base_sync_remote", "unit": 3, "pr": 7,
        "pr_head": c.old_head, "local_head": c.old_head, "base_head": first});
    c.env.write("events.jsonl", &format!("{line}\n"));
    let out = c.sync();
    assert_eq!(c.update_calls(), 1, "{}", out.stderr);
    assert_eq!(c.env.events_named("base_sync_remote").len(), 2);
}

#[test]
fn a_request_records_the_base_it_aimed_at() {
    let c = case();
    let base = c.advance_base();
    let new_head = c.update_branch(true);
    c.pr_is_at(&new_head);
    printed(&c.sync());
    assert_eq!(c.env.events_named("base_sync_remote")[0]["base_head"], base);
}

#[test]
fn a_sync_cut_short_right_after_the_update_call_is_finished_not_started_again() {
    let c = case();
    c.advance_base();
    let new_head = c.update_branch(true);
    c.pr_is_at(&new_head);
    c.env.stub_file("die-after-update-branch", "");
    let out = c.sync();
    assert_ne!(out.code, 0, "the process was killed");
    assert_eq!(c.update_calls(), 1);
    assert!(c.env.workdir.join("units/3/base-sync-pending.json").is_file());

    fs::remove_file(c.env.stub.join("die-after-update-branch")).unwrap();
    let out = printed(&c.sync());
    assert_eq!(out["new_head"], new_head);
    assert_eq!(c.update_calls(), 1, "GitHub had applied it: no second update");
    assert_eq!(c.env.events_named("base_sync_remote").len(), 1, "one slot for one sync");
    assert_eq!(c.env.events_named("base_sync").len(), 1);
    assert_eq!(git(&c.wt, &["rev-parse", "HEAD"]), new_head);
    assert!(!c.env.workdir.join("units/3/base-sync-pending.json").exists());
}

#[test]
fn a_pending_marker_whose_update_never_reached_github_asks_again_for_the_same_slot() {
    let c = case();
    let base = c.advance_base();
    c.pr_is_at(&c.old_head);
    let marker = json!({"pr": 7, "pr_head": c.old_head, "local_head": c.old_head, "base_head": base});
    c.env.write("units/3/base-sync-pending.json", &marker.to_string());
    let out = c.sync();
    assert_eq!(out.code, 1, "GitHub's update is still not in the head: {}", out.stderr);
    assert_eq!(c.update_calls(), 1, "the request is made again");
    assert_eq!(
        c.env.events_named("base_sync_remote").len(),
        1,
        "and spends no second slot"
    );
    assert!(c.env.workdir.join("units/3/base-sync-pending.json").is_file());
}

#[test]
fn a_failed_update_call_leaves_no_pending_marker() {
    let c = case();
    c.advance_base();
    let new_head = c.update_branch(true);
    c.pr_is_at(&new_head);
    c.env.stub_file("fail-update-branch", "");
    assert_eq!(c.sync().code, 1);
    assert!(!c.env.workdir.join("units/3/base-sync-pending.json").exists());
}

#[test]
fn a_recovered_request_whose_resend_failed_is_sent_again_next_time() {
    let c = case();
    let base = c.advance_base();
    c.pr_is_at(&c.old_head);
    let marker = json!({"pr": 7, "pr_head": c.old_head, "local_head": c.old_head, "base_head": base});
    c.env.write("units/3/base-sync-pending.json", &marker.to_string());
    c.env.stub_file("fail-update-branch", "");
    assert_eq!(c.sync().code, 1);
    assert_eq!(c.update_calls(), 1);
    assert_eq!(c.sync().code, 1);
    assert_eq!(
        c.update_calls(),
        2,
        "the request never reached GitHub: ask again, do not wait"
    );
    assert_eq!(c.env.events_named("base_sync_remote").len(), 1, "for the same slot");
}

#[test]
fn a_resent_request_is_waited_for_not_sent_a_third_time() {
    let c = case();
    let base = c.advance_base();
    c.pr_is_at(&c.old_head);
    let marker = json!({"pr": 7, "pr_head": c.old_head, "local_head": c.old_head, "base_head": base});
    c.env.write("units/3/base-sync-pending.json", &marker.to_string());
    assert_eq!(c.sync().code, 1);
    assert_eq!(c.update_calls(), 1);
    assert_eq!(c.env.events_named("base_sync_reissued").len(), 1);
    let out = c.sync();
    assert_eq!(out.code, 1);
    assert!(out.stderr.contains("still pending"), "{}", out.stderr);
    assert_eq!(c.update_calls(), 1);
}

#[test]
fn an_update_call_that_timed_out_keeps_the_pending_marker() {
    let mut c = case();
    c.env.set("ISSUE_DRAIN_GH_READ_TIMEOUT_SECS", "1");
    c.advance_base();
    let new_head = c.update_branch(true);
    c.pr_is_at(&new_head);
    c.env.stub_file("hang-update-branch", "");
    let out = c.sync();
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert!(out.stderr.contains("timed out"), "{}", out.stderr);
    assert!(
        c.env.workdir.join("units/3/base-sync-pending.json").is_file(),
        "whether GitHub took it is unknown"
    );
}

#[test]
fn a_newer_request_than_the_pending_line_is_counted_from_its_marker() {
    let c = case();
    let first = c.advance_base();
    let h1 = c.update_branch(true);
    let second = c.advance_base();
    // The second request landed, but the process died before logging it.
    let h2 = c.update_branch(true);
    c.pr_is_at(&h2);
    let line = json!({"ts": "t", "event": "base_sync_remote", "unit": 3, "pr": 7,
        "pr_head": c.old_head, "local_head": c.old_head, "base_head": first});
    c.env.write("events.jsonl", &format!("{line}\n"));
    let marker = json!({"pr": 7, "pr_head": h1, "local_head": c.old_head, "base_head": second});
    c.env.write("units/3/base-sync-pending.json", &marker.to_string());
    let out = printed(&c.sync());
    assert_eq!(out["new_head"], h2);
    assert_eq!(c.update_calls(), 0, "it landed: nothing is sent again");
    let remote = c.env.events_named("base_sync_remote");
    assert_eq!(remote.len(), 2, "the second request spent its own slot");
    assert_eq!(remote[1]["base_head"], second);
}
