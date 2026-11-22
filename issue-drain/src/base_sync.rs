//! `issue-drain base-sync --unit <n> [--pr <n>]`: bring a unit's PR up to date
//! with the base branch, and say what that did to the checks that were already
//! done.
//!
//! The steps, in order: `gh pr update-branch` (GitHub merges the base into the
//! PR's branch); fetch the branch and the base into the unit's worktree and
//! fast-forward the worktree to the PR's head; run the delivery check there, so
//! `units/<n>/deliver.json` is at the new head and merge base; then compare the
//! review proof with the new head. A head the proof does not name needs a review
//! round, except a single merge whose first parent is the reviewed commit and
//! whose other parent is on the base branch: the repo's review status clears that
//! one itself.
//!
//! The PR is `--pr`, or else the last PR the run's log names for the unit (the
//! `state event ... --pr` and `merge-gate` lines carry it).
//!
//! The PR is held to what `merge-gate` holds it to (head repo, head branch, base)
//! before anything is called on it.
//!
//! `review_round_needed` is false only when the review proof covers the head as
//! above and the gate's own review read (`merge_preflight.sh`) says `clear`; a
//! read that fails needs a round.
//!
//! A unit takes at most `MAX_BASE_SYNCS` syncs (the plan's cap). A slot is spent
//! when GitHub is asked to update the branch: a `base_sync_remote` line is
//! logged right after that call, before any local step. They are counted from
//! those lines, from the finished `base_sync` lines and from the state snapshot's
//! `base_syncs`, whichever is highest, so a driver that also records the move back
//! to `ci_wait` is not counted twice. The next one is refused. A retry that finds
//! the PR head moved on from the head recorded with the last unfinished remote
//! update only does the local steps and spends no slot.
//!
//! With ISSUE_DRAIN_DRY_RUN=1 it prints what it would call and changes nothing.
//! A unit process may not run it, as with `merge-gate`.
//!
//! Output: one JSON line, `{unit, pr, old_head, new_head, deliver_ok,
//! review_round_needed}`. Exit: 0 synced (a failing delivery check is
//! `deliver_ok: false`, not an exit code); 3 refused (a unit process asked, the
//! cap is reached, the PR is not open or not the unit's branch, or the worktree
//! is not clean and on the branch); 2 no queue, unit files or PR number; 1 gh or
//! git failed.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};

use crate::ctx::{Ctx, read_json};
use crate::deliver_check;
use crate::error::{Fail, Res};
use crate::exec;
use crate::gh;
use crate::git;
use crate::merge_gate::{PrState, PrView, Proof, binding, preflight, read_view};
use crate::state::{MAX_BASE_SYNCS, Snapshot};

#[derive(clap::Args)]
pub struct Args {
    /// The unit; its files are under <run folder>/units/<n>/.
    #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
    unit: u64,
    /// The unit's pull request (default: the last one the run's log names for it).
    #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
    pr: Option<u64>,
}

const GIT_LIMIT: Duration = Duration::from_secs(120);

/// What `units/<n>/unit.json` says this command needs.
pub struct UnitFiles {
    pub worktree: PathBuf,
    pub branch: String,
}

pub fn unit_files(ctx: &Ctx, unit: u64) -> Res<UnitFiles> {
    let path = ctx.path(&format!("units/{unit}/unit.json"));
    let value: Value = read_json(&path)
        .ok_or_else(|| Fail::usage(format!("{} is missing; run `unit-prepare` first", path.display())))?;
    let text = |key: &str| value[key].as_str().unwrap_or_default().to_string();
    let (worktree, branch) = (text("worktree"), text("branch"));
    if !worktree.starts_with('/') || branch.is_empty() {
        return Err(Fail::usage(format!("{} names no worktree and branch", path.display())));
    }
    Ok(UnitFiles {
        worktree: PathBuf::from(worktree),
        branch,
    })
}

/// The last PR number the log names for `unit`: a `state event --pr` line or a
/// line another command logged (`merge-gate`).
pub fn pr_from_log(ctx: &Ctx, unit: u64) -> Option<u64> {
    let text = fs::read_to_string(ctx.path("events.jsonl")).ok()?;
    text.lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(|v| v["unit"] == unit)
        // A PR the gate refused as not the unit's is not the unit's PR.
        .filter(|v| {
            v["event"] != "merge_gate"
                || !v["refusals"]
                    .as_array()
                    .is_some_and(|codes| codes.iter().any(|c| c == "pr_unit" || c == "wrong_base"))
        })
        .filter_map(|v| v["pr"].as_u64())
        .next_back()
}

/// The unit's lines in the log, oldest first.
fn unit_events(ctx: &Ctx, unit: u64) -> Vec<Value> {
    fs::read_to_string(ctx.path("events.jsonl"))
        .unwrap_or_default()
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(|v| v["unit"] == unit)
        .collect()
}

/// Base syncs already taken by `unit`. A sync is spent when GitHub is asked to
/// update the branch (`base_sync_remote`), not when the local follow-up is
/// done (`base_sync`); a finished sync has both, so the higher count is the
/// number of syncs. The state snapshot's `base_syncs` counts too.
fn syncs_taken(ctx: &Ctx, unit: u64) -> u32 {
    let events = unit_events(ctx, unit);
    let count = |name: &str| events.iter().filter(|v| v["event"] == name).count() as u32;
    let snapshot: Option<Snapshot> = read_json(&ctx.path("state.json"));
    let counted = snapshot
        .and_then(|s| s.units.into_iter().find(|u| u.unit == unit))
        .map_or(0, |u| u.base_syncs);
    count("base_sync").max(count("base_sync_remote")).max(counted)
}

/// The head the worktree had when the last remote update was asked for, if that
/// update has no finished local follow-up after it. Empty when the line did
/// not record one.
fn follow_up_pending(ctx: &Ctx, unit: u64) -> Option<String> {
    let events = unit_events(ctx, unit);
    let last = |name: &str| events.iter().rposition(|v| v["event"] == name);
    let remote = last("base_sync_remote")?;
    if last("base_sync").is_some_and(|done| done > remote) {
        return None;
    }
    Some(events[remote]["local_head"].as_str().unwrap_or_default().to_string())
}

/// The PR, read now, and held to the same ownership `merge-gate` holds it to:
/// its head repository is the repo, its head branch is the unit's, and it
/// targets the profile's base. A read that fails is exit 1; a PR that is not the
/// unit's is a refusal.
pub fn owned_view(ctx: &Ctx, repo: &str, unit: u64, pr: u64, branch: &str) -> Res<PrView> {
    let view = read_view(repo, pr).map_err(|e| Fail::failed(format!("could not read PR #{pr}: {e}")))?;
    let refusals = binding(repo, &ctx.profile.base_branch, unit, pr, &view, &Ok(branch.to_string()));
    if refusals.is_empty() {
        return Ok(view);
    }
    let said: Vec<String> = refusals.iter().map(|r| format!("{}: {}", r.code, r.detail)).collect();
    Err(Fail::refused(format!(
        "PR #{pr} is not unit {unit}'s: {}",
        said.join("; ")
    )))
}

/// Whether the review proof no longer covers `new_head`. It does when the proof
/// names it, or when `new_head` is a merge whose first parent is the reviewed
/// commit and whose second parent is already on the base branch: a single
/// base-only merge.
fn review_round_needed(ctx: &Ctx, unit: u64, worktree: &Path, new_head: &str) -> bool {
    let Some(proof) = read_json::<Proof>(&ctx.path(&format!("units/{unit}/review-proof.json"))) else {
        return true;
    };
    if proof.head.eq_ignore_ascii_case(new_head) {
        return false;
    }
    let Some(line) = git::out(worktree, &["rev-list", "--parents", "-n", "1", new_head]) else {
        return true;
    };
    let words: Vec<&str> = line.split_whitespace().collect();
    let base = format!("refs/remotes/origin/{}", ctx.profile.base_branch);
    let single_base_merge = words.len() == 3
        && words[1].eq_ignore_ascii_case(&proof.head)
        && git::ok(worktree, &["merge-base", "--is-ancestor", words[2], &base]);
    !single_base_merge
}

/// The worktree is on `branch` and has nothing uncommitted.
pub fn require_ready(wt: &Path, branch: &str) -> Res<()> {
    let on = git::out(wt, &["symbolic-ref", "--short", "-q", "HEAD"]).map(|b| b.trim().to_string());
    if on.as_deref() != Some(branch) {
        return Err(Fail::refused(format!(
            "the worktree {} is on {}, not {branch}",
            wt.display(),
            on.as_deref().unwrap_or("no branch (detached)")
        )));
    }
    match git::out(wt, &["status", "--porcelain", "--untracked-files=all"]) {
        Some(status) if status.trim().is_empty() => Ok(()),
        Some(_) => Err(Fail::refused(format!(
            "the worktree {} is not clean; commit or discard first",
            wt.display()
        ))),
        None => Err(Fail::failed(format!("git cannot read the status of {}", wt.display()))),
    }
}

pub fn run(ctx: &Ctx, args: &Args) -> Res<()> {
    ctx.require_driver("base-sync")?;
    let unit = args.unit;
    let repo = ctx.repo()?;
    let files = unit_files(ctx, unit)?;
    let (wt, branch) = (files.worktree, files.branch);
    if !wt.is_dir() {
        return Err(Fail::usage(format!("the worktree {} is not there", wt.display())));
    }
    let pr = args
        .pr
        .or_else(|| pr_from_log(ctx, unit))
        .ok_or_else(|| Fail::usage(format!("no PR is known for unit {unit}; pass --pr")))?;

    // Nothing is called on a PR that is not the unit's: not a fork's PR of the
    // same branch name, not one aimed at another base.
    let before = owned_view(ctx, &repo, unit, pr, &branch)?;
    if before.state != PrState::Open {
        return Err(Fail::refused(format!("PR #{pr} is not open")));
    }
    require_ready(&wt, &branch)?;
    let local_head = git::commit(&wt, "HEAD").ok_or_else(|| Fail::failed("git finds no HEAD in the worktree"))?;

    // A remote update whose local follow-up failed already spent its slot. If
    // the PR's head has moved on from the head recorded with that update,
    // GitHub did its part: the retry only does the local steps.
    let pending = follow_up_pending(ctx, unit).filter(|recorded| !before.head.eq_ignore_ascii_case(recorded));
    let resume = pending.is_some();
    let old_head = pending.filter(|recorded| !recorded.is_empty()).unwrap_or(local_head);
    let taken = syncs_taken(ctx, unit);
    if !resume && taken >= MAX_BASE_SYNCS {
        return Err(Fail::refused(format!(
            "unit {unit} has taken {taken} base syncs; the cap is {MAX_BASE_SYNCS}. Park it for a person"
        )));
    }

    if ctx.dry_run {
        println!("WOULD: gh pr update-branch {pr} --repo {repo}");
        println!(
            "WOULD: fetch {branch} and {} in {}, fast-forward it, run deliver-check",
            ctx.profile.base_branch,
            wt.display()
        );
        return Ok(());
    }

    // gh::write has no verb for this one, and the `gh-write` verbs belong to
    // another change; the dry-run and unit-mode rules are applied above.
    let new_head = if resume {
        before.head.clone()
    } else {
        let pr_arg = pr.to_string();
        let (rc, _) = gh::read_raw(&["pr", "update-branch", &pr_arg, "--repo", &repo]);
        if rc != 0 {
            return Err(Fail::failed(format!("gh pr update-branch {pr} failed (exit {rc})")));
        }
        // The slot is spent now, before any local step can fail.
        ctx.event(
            "base_sync_remote",
            json!({"unit": unit, "pr": pr, "local_head": old_head}),
        )?;
        owned_view(ctx, &repo, unit, pr, &branch)?.head
    };

    let log_dir = ctx.path(&format!("units/{unit}"));
    let log = |step: &str| log_dir.join(format!("base-sync-{step}.log"));
    let base = &ctx.profile.base_branch;
    let refspecs = [
        format!("+refs/heads/{branch}:refs/remotes/origin/{branch}"),
        format!("+refs/heads/{base}:refs/remotes/origin/{base}"),
    ];
    let fetched = exec::git(
        &wt,
        &["fetch", "--quiet", "origin", &refspecs[0], &refspecs[1]],
        GIT_LIMIT,
        &log("fetch"),
    )?;
    if !fetched.ok() {
        return Err(Fail::failed(format!(
            "could not fetch {branch} and {base} in {}: {}",
            wt.display(),
            fetched.failure(GIT_LIMIT)
        )));
    }
    let remote = format!("refs/remotes/origin/{branch}");
    let moved = exec::git(
        &wt,
        &["merge", "--ff-only", "--quiet", &remote],
        GIT_LIMIT,
        &log("merge"),
    )?;
    if !moved.ok() {
        return Err(Fail::failed(format!(
            "could not fast-forward {} to {remote}: {}",
            wt.display(),
            moved.failure(GIT_LIMIT)
        )));
    }
    let now = git::commit(&wt, "HEAD").unwrap_or_default();
    if !now.eq_ignore_ascii_case(&new_head) {
        return Err(Fail::failed(format!(
            "the worktree is at {now} after the fast-forward, but PR #{pr}'s head is {new_head}; fetch again"
        )));
    }

    let checked = deliver_check::evaluate(ctx, unit, &wt, None, None)?;
    // The proof must cover the head, and the gate's own review read must say
    // `clear` (a merge that changed the reviewed diff's digest does not). A read
    // that fails needs a round.
    let clear = preflight(ctx, &repo, pr).is_ok_and(|p| p.status == "clear");
    let needed = !clear || review_round_needed(ctx, unit, &wt, &new_head);
    let out = json!({
        "unit": unit,
        "pr": pr,
        "old_head": old_head,
        "new_head": new_head,
        "deliver_ok": checked.ok,
        "review_round_needed": needed,
    });
    ctx.event("base_sync", out.clone())?;
    println!("{out}");
    Ok(())
}
