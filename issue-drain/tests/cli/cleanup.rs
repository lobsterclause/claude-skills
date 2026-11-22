//! `issue-drain cleanup`. The tests start from `base_sync::case()`: a unit
//! worktree made by `unit-prepare`, on its branch, pushed. The stub gh answers
//! the PR's state from `pr-view-7.json`.

use std::fs;
use std::path::PathBuf;

use serde_json::{Value, json};

use crate::base_sync::{BRANCH, Case, PR, case, identity, pr_json};
use crate::common::*;

const LABEL: &str = "agent-in-progress";

fn pr_is(c: &Case, state: &str) {
    c.pr_with(&pr_json(state, &c.old_head, "example", "develop"));
}

fn checkout(c: &Case) -> PathBuf {
    c.env.dir.path().join("checkout")
}

fn branches(c: &Case) -> String {
    git(&checkout(c), &["branch", "--list", BRANCH])
}

fn cleanup(c: &Case, extra: &[&str]) -> Out {
    let mut args = vec!["cleanup", "--unit", "3", "--pr", PR];
    args.extend_from_slice(extra);
    c.env.run(&args)
}

fn printed(out: &Out) -> Value {
    assert_eq!(out.code, 0, "{}", out.stderr);
    serde_json::from_str(out.stdout.trim().lines().last().expect("a line")).expect("a JSON line")
}

/// Issue 103 carries the claim label and this run's marker (ours); 106 has none.
fn claim_held(c: &Case) {
    c.env.write(
        "tracker.json",
        &json!({"number": 12, "url": "https://example.invalid/12", "run": "run", "published_at": "2026-11-21T00:00:00Z"})
            .to_string(),
    );
    let marker = "<!-- issue-drain:claim tracker=12 unit=3 -->\nAn agent picked this up as unit 3.";
    c.env.stub_file(
        "issue-view-103.json",
        &json!({"labels": [{"name": "bug"}, {"name": LABEL}]}).to_string(),
    );
    c.env.stub_file(
        "timeline-103.json",
        &json!([
            {"event": "labeled", "created_at": "2026-11-21T01:00:00Z", "label": {"name": LABEL}},
            {"event": "commented", "created_at": "2026-11-21T01:00:00Z", "body": marker}
        ])
        .to_string(),
    );
    c.env
        .stub_file("issue-view-106.json", &json!({"labels": [{"name": "bug"}]}).to_string());
}

#[test]
fn a_merged_units_worktree_and_branch_are_removed() {
    let c = case();
    pr_is(&c, "MERGED");
    assert!(branches(&c).contains(BRANCH));
    let out = printed(&cleanup(&c, &[]));
    assert_eq!(out["unit"], 3);
    assert_eq!(out["worktree"], "removed");
    assert_eq!(out["branch"], "deleted");
    assert!(!c.wt.exists());
    assert_eq!(branches(&c), "");
    assert_eq!(c.env.events_named("cleanup").len(), 1);
}

#[test]
fn an_unmerged_units_branch_is_kept() {
    let c = case();
    pr_is(&c, "OPEN");
    let out = printed(&cleanup(&c, &[]));
    assert_eq!(out["worktree"], "removed");
    assert_eq!(out["branch"], "kept_unmerged");
    assert!(!c.wt.exists());
    assert!(
        branches(&c).contains(BRANCH),
        "the branch is the only copy of unpushed work"
    );
}

#[test]
fn a_closed_but_unmerged_pr_keeps_the_branch_too() {
    let c = case();
    pr_is(&c, "CLOSED");
    assert_eq!(printed(&cleanup(&c, &[]))["branch"], "kept_unmerged");
}

#[test]
fn a_dirty_worktree_is_refused_unless_forced() {
    let c = case();
    pr_is(&c, "MERGED");
    fs::write(c.wt.join("scratch.txt"), "work\n").expect("the file");
    let out = cleanup(&c, &[]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("uncommitted"), "{}", out.stderr);
    assert!(c.wt.join("scratch.txt").exists());
    assert!(branches(&c).contains(BRANCH));

    let forced = printed(&cleanup(&c, &["--force"]));
    assert_eq!(forced["worktree"], "removed");
    assert!(!c.wt.exists());
}

#[test]
fn a_worktree_that_holds_the_current_folder_is_not_removed() {
    let c = case();
    pr_is(&c, "MERGED");
    let args = ["cleanup", "--unit", "3", "--pr", PR, "--force"];
    let out = c.env.run_in(Some(&c.wt.join("src")), &args);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("working directory"), "{}", out.stderr);
    assert!(c.wt.exists());
    assert!(branches(&c).contains(BRANCH));
}

#[test]
fn a_held_claim_is_released_and_a_missing_tracker_is_not_an_error() {
    let c = case();
    pr_is(&c, "MERGED");
    claim_held(&c);
    let out = printed(&cleanup(&c, &[]));
    assert_eq!(
        out["claim"],
        json!([{"issue": 103, "action": "released"}, {"issue": 106, "action": "not_labelled"}])
    );
    assert!(
        c.env.gh_calls().iter().any(|call| call.contains("--remove-label")),
        "{:?}",
        c.env.gh_calls()
    );
}

#[test]
fn a_run_with_no_tracker_has_no_claim_to_release() {
    let c = case();
    pr_is(&c, "MERGED");
    assert_eq!(printed(&cleanup(&c, &[]))["claim"], "none");
}

#[test]
fn a_dry_run_removes_nothing() {
    let mut c = case();
    pr_is(&c, "MERGED");
    c.env.set("ISSUE_DRAIN_DRY_RUN", "1");
    let out = cleanup(&c, &[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stdout.contains("WOULD: git worktree remove"), "{}", out.stdout);
    assert!(out.stdout.contains("WOULD: git branch -D"), "{}", out.stdout);
    assert!(c.wt.exists());
    assert!(branches(&c).contains(BRANCH));
}

#[test]
fn a_unit_process_may_not_clean_up() {
    let mut c = case();
    pr_is(&c, "MERGED");
    c.env.set("ISSUE_DRAIN_MODE", "unit");
    assert_eq!(cleanup(&c, &[]).code, 3);
    assert!(c.wt.exists());
}

#[test]
fn a_worktree_outside_the_run_folder_is_never_touched() {
    let c = case();
    pr_is(&c, "MERGED");
    let mut unit: Value = json(&c.env.workdir.join("units/3/unit.json"));
    let elsewhere = c.env.dir.path().join("elsewhere");
    fs::create_dir_all(&elsewhere).expect("the folder");
    unit["worktree"] = json!(elsewhere.display().to_string());
    c.env.write("units/3/unit.json", &unit.to_string());
    let out = cleanup(&c, &["--force"]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("run folder"), "{}", out.stderr);
    assert!(elsewhere.exists());
}

fn add_base(c: &Case) -> PathBuf {
    let base = fs::canonicalize(&c.env.workdir).expect("the run folder").join("base");
    git(
        &checkout(c),
        &[
            "worktree",
            "add",
            "--quiet",
            "--detach",
            &base.display().to_string(),
            "origin/develop",
        ],
    );
    base
}

#[test]
fn the_run_cleanup_does_every_finished_unit_and_then_the_base_clone() {
    let c = case();
    pr_is(&c, "MERGED");
    // The log names the unit's PR, as `state event --pr` or merge-gate would.
    c.env.write(
        "events.jsonl",
        &format!(
            "{}\n",
            json!({"ts": "2026-11-21T03:53:00Z", "event": "merge_gate", "unit": 3, "pr": 7})
        ),
    );
    let base = add_base(&c);
    let out = c.env.run(&["cleanup", "--run"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let lines: Vec<Value> = out
        .stdout
        .lines()
        .map(|l| serde_json::from_str(l).expect("a JSON line"))
        .collect();
    assert_eq!(lines.len(), 2, "{}", out.stdout);
    assert_eq!(lines[0]["unit"], 3);
    assert_eq!(lines[0]["worktree"], "removed");
    assert_eq!(lines[1], json!({"base": "removed"}));
    assert!(!c.wt.exists());
    assert!(!base.exists());
}

#[test]
fn the_run_cleanup_leaves_an_open_unit_and_the_base_clone_alone() {
    let c = case();
    pr_is(&c, "OPEN");
    c.env.write(
        "events.jsonl",
        &format!(
            "{}\n",
            json!({"ts": "2026-11-21T03:53:00Z", "event": "merge_gate", "unit": 3, "pr": 7})
        ),
    );
    let base = add_base(&c);
    let out = c.env.run(&["cleanup", "--run"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stdout.contains("\"skipped\":\"pr_open\""), "{}", out.stdout);
    assert!(c.wt.exists());
    assert!(base.exists());
}

#[test]
fn the_run_cleanup_skips_a_unit_with_no_known_pr() {
    let c = case();
    let out = c.env.run(&["cleanup", "--run"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stdout.contains("\"skipped\":\"no_pr\""), "{}", out.stdout);
    assert!(c.wt.exists());
}

#[test]
fn a_unit_or_run_is_required_but_not_both() {
    let c = case();
    assert_eq!(c.env.run(&["cleanup"]).code, 2);
    assert_eq!(c.env.run(&["cleanup", "--run", "--unit", "3"]).code, 2);
}

#[test]
fn a_pr_that_is_not_the_units_is_refused_whatever_its_state() {
    let c = case();
    for view in [
        pr_json("MERGED", &c.old_head, "someone-else", "develop"),
        pr_json("MERGED", &c.old_head, "example", "release"),
    ] {
        c.pr_with(&view);
        let out = cleanup(&c, &["--force"]);
        assert_eq!(out.code, 3, "{}", out.stderr);
        assert!(c.wt.exists());
        assert!(branches(&c).contains(BRANCH));
    }
    let mut other_branch = pr_json("MERGED", &c.old_head, "example", "develop");
    other_branch["headRefName"] = json!("fix/9-someone-elses");
    c.pr_with(&other_branch);
    assert_eq!(cleanup(&c, &["--force"]).code, 3);
    assert!(c.wt.exists());
}

#[test]
fn a_pr_number_the_gate_refused_is_not_taken_from_the_log() {
    let c = case();
    pr_is(&c, "MERGED");
    let lines = [
        json!({"ts": "t", "event": "merge_gate", "unit": 3, "pr": 7, "refusals": ["review"]}),
        json!({"ts": "t", "event": "merge_gate", "unit": 3, "pr": 9, "refusals": ["pr_unit"]}),
        json!({"ts": "t", "event": "merge_gate", "unit": 3, "pr": 8, "refusals": ["wrong_base"]}),
    ];
    let text: Vec<String> = lines.iter().map(Value::to_string).collect();
    c.env.write("events.jsonl", &format!("{}\n", text.join("\n")));
    let out = printed(&c.env.run(&["cleanup", "--unit", "3"]));
    assert_eq!(out["pr"], 7);
    assert_eq!(out["branch"], "deleted");
}

#[test]
fn local_commits_the_pr_never_had_are_not_thrown_away_even_with_force() {
    let c = case();
    pr_is(&c, "MERGED");
    fs::write(c.wt.join("src/timer/countdown.ts"), "export const unpushed = 1;\n").expect("the file");
    git(&c.wt, &["add", "src/timer/countdown.ts"]);
    identity(&c.wt, &["commit", "-q", "-m", "never pushed"]);
    let out = cleanup(&c, &["--force"]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("not on the PR"), "{}", out.stderr);
    assert!(c.wt.exists());
    assert!(branches(&c).contains(BRANCH));
}

#[test]
fn a_branch_behind_the_pr_head_is_fine() {
    let c = case();
    // The PR head is a later commit of the same branch than the unit's own tip.
    let head = c.old_head.clone();
    fs::write(c.wt.join("src/timer/countdown.ts"), "export const more = 1;\n").expect("the file");
    git(&c.wt, &["add", "src/timer/countdown.ts"]);
    identity(&c.wt, &["commit", "-q", "-m", "later"]);
    let later = git(&c.wt, &["rev-parse", "HEAD"]);
    git(&c.wt, &["reset", "-q", "--hard", &head]);
    c.pr_with(&pr_json("MERGED", &later, "example", "develop"));
    assert_eq!(printed(&cleanup(&c, &[]))["branch"], "deleted");
}

#[test]
fn a_base_that_is_a_symlink_is_never_followed() {
    let c = case();
    pr_is(&c, "MERGED");
    c.env.write(
        "events.jsonl",
        &format!(
            "{}\n",
            json!({"ts": "t", "event": "merge_gate", "unit": 3, "pr": 7, "refusals": []})
        ),
    );
    let elsewhere = c.env.dir.path().join("elsewhere-wt");
    git(
        &checkout(&c),
        &[
            "worktree",
            "add",
            "--quiet",
            "--detach",
            &elsewhere.display().to_string(),
            "origin/develop",
        ],
    );
    let base = fs::canonicalize(&c.env.workdir).expect("the run folder").join("base");
    std::os::unix::fs::symlink(&elsewhere, &base).expect("the link");
    let out = c.env.run(&["cleanup", "--run"]);
    assert_eq!(out.code, 3, "{}{}", out.stdout, out.stderr);
    assert!(out.stdout.contains("symlink"), "{}", out.stdout);
    assert!(elsewhere.exists(), "the link's target survives");
}
