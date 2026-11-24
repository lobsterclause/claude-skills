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
//! A sync in flight leaves `units/<n>/base-sync-pending.json`, written before
//! `gh pr update-branch` and removed when the sync is done. A process killed
//! between the call and the log line that records it would otherwise leave no
//! trace of a request GitHub may have applied. The next run that finds the marker
//! with no such line logs the request, once, and finishes that sync (fetch,
//! fast-forward, deliver check) instead of starting another; if the base is not
//! in the PR's head it asks GitHub again, with no second slot. The driver also
//! reads the marker (see `drive`): a unit that has one in `gate` finishes the
//! sync before the gate is read.
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
//! those lines, each once; a `gate` to `ci_wait` move the driver records for a
//! request already logged is not counted again, and one with no request behind it
//! (a sync recorded by hand) is. The next one is refused. A sync is done only when
//! the fetched base is in the PR's head; if GitHub has not applied the update yet
//! the request stays pending. A retry for the same PR whose head has moved on from
//! the head recorded before the request only does the local steps and spends no
//! slot. `review_round_needed` is false only if the review read is of the new head.
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

use crate::ctx::{Ctx, read_json, write_json};
use crate::deliver_check;
use crate::error::{Fail, Res};
use crate::exec;
use crate::gh;
use crate::git;
use crate::merge_gate::{PrState, PrView, Proof, binding, preflight, read_view};
use crate::state::MAX_BASE_SYNCS;

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

/// In the unit's folder from just before `gh pr update-branch` until the sync is
/// done: `{pr, pr_head, local_head, base_head}`. The request's own log line is
/// written after the call, so a process killed between the two would leave no
/// trace of a request GitHub may have applied. The driver also reads it: a unit
/// that has it finishes the sync before anything else.
pub const PENDING_MARKER: &str = "base-sync-pending.json";

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
    let text = crate::state::log_text(ctx).ok()?;
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
    crate::state::log_text(ctx)
        .unwrap_or_default()
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(|v| v["unit"] == unit)
        .collect()
}

/// Base syncs already taken by `unit`. A sync is spent when GitHub is asked to
/// update the branch: each `base_sync_remote` line counts once. A recorded
/// `gate` to `ci_wait` move accounts for the earliest request not yet accounted
/// for, and counts as a sync of its own when there is none (a sync a person
/// recorded by hand). Finished `base_sync` lines add nothing: their request is
/// already counted.
fn syncs_taken(ctx: &Ctx, unit: u64) -> u32 {
    let (mut total, mut unaccounted) = (0u32, 0u32);
    for v in unit_events(ctx, unit) {
        if v["event"] == "base_sync_remote" {
            total += 1;
            unaccounted += 1;
        } else if v.get("event").is_none() && v["from"] == "gate" && v["to"] == "ci_wait" {
            if unaccounted > 0 {
                unaccounted -= 1;
            } else {
                total += 1;
            }
        }
    }
    total
}

/// What the last remote update's line says, if that update has no finished
/// local follow-up after it: the PR it was for, the PR's head and the worktree's
/// head before the request. Fields the line lacks are `None`.
struct Pending {
    pr: Option<u64>,
    pr_head: Option<String>,
    local_head: Option<String>,
    /// The base commit the request aimed at; old lines lack it.
    base_head: Option<String>,
}

fn follow_up_pending(ctx: &Ctx, unit: u64) -> Option<Pending> {
    let events = unit_events(ctx, unit);
    let last = |name: &str| events.iter().rposition(|v| v["event"] == name);
    let remote = last("base_sync_remote")?;
    if last("base_sync").is_some_and(|done| done > remote) {
        return None;
    }
    let line = &events[remote];
    let text = |key: &str| line[key].as_str().map(str::to_string);
    Some(Pending {
        pr: line["pr"].as_u64(),
        pr_head: text("pr_head"),
        local_head: text("local_head"),
        base_head: text("base_head"),
    })
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

/// Fetch the unit's branch and the base into the worktree's remote-tracking refs.
fn fetch(wt: &Path, branch: &str, base: &str, log: &Path) -> Res<()> {
    let refspecs = [
        format!("+refs/heads/{branch}:refs/remotes/origin/{branch}"),
        format!("+refs/heads/{base}:refs/remotes/origin/{base}"),
    ];
    let fetched = exec::git(
        wt,
        &["fetch", "--quiet", "origin", &refspecs[0], &refspecs[1]],
        GIT_LIMIT,
        log,
    )?;
    if fetched.ok() {
        Ok(())
    } else {
        Err(Fail::failed(format!(
            "could not fetch {branch} and {base} in {}: {}",
            wt.display(),
            fetched.failure(GIT_LIMIT)
        )))
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

    // A remote update whose local follow-up failed already spent its slot, so
    // the retry for the same PR may only do the local steps. Whether GitHub did
    // its part is read from the base commit the request aimed at: not in the PR's
    // head yet means wait (no new request, no new slot); in it, and the base has
    // not moved again, means resume; in it, but the base has moved on, means a
    // fresh sync. A line with no recorded base falls back to the PR head having
    // moved on from the one recorded before the request.
    let log_dir = ctx.path(&format!("units/{unit}"));
    let log = |step: &str| log_dir.join(format!("base-sync-{step}.log"));
    let base = ctx.profile.base_branch.clone();
    let base_ref = format!("refs/remotes/origin/{base}");
    let marker = log_dir.join(PENDING_MARKER);
    let mut resume = false;
    let mut recovered = false;
    let mut reissue = false;
    let mut old_head = local_head;
    let mut pending = follow_up_pending(ctx, unit).filter(|p| p.pr == Some(pr));
    if pending.is_none()
        && !ctx.dry_run
        && let Some(m) = read_json::<Value>(&marker).filter(|m| m["pr"].as_u64() == Some(pr))
    {
        // The marker was written, but the request's line was not: the process
        // died around the call. That request spent the slot; log it now.
        let mut line = json!({"unit": unit, "pr": pr, "recovered": true});
        for key in ["pr_head", "local_head", "base_head"] {
            line[key] = m[key].clone();
        }
        ctx.event("base_sync_remote", line)?;
        pending = follow_up_pending(ctx, unit).filter(|p| p.pr == Some(pr));
        recovered = true;
    }
    if let Some(p) = pending {
        resume = match &p.base_head {
            Some(aimed) if !ctx.dry_run => {
                fetch(&wt, &branch, &base, &log("fetch"))?;
                let landed = git::ok(&wt, &["merge-base", "--is-ancestor", aimed, &before.head]);
                if !landed && !recovered {
                    return Err(Fail::failed(format!(
                        "the update of PR #{pr} to base {aimed} is still pending: the base is not in the PR's head {} yet. Wait, then run base-sync again (no slot is spent)",
                        before.head
                    )));
                }
                // A request the marker recovered may never have reached GitHub:
                // when the base is not in the head, ask again for the same slot.
                reissue = !landed;
                landed && git::ok(&wt, &["merge-base", "--is-ancestor", &base_ref, &before.head])
            }
            Some(_) => false,
            None => p
                .pr_head
                .as_deref()
                .is_some_and(|head| !before.head.eq_ignore_ascii_case(head)),
        };
        if (resume || reissue)
            && let Some(recorded) = p.local_head
        {
            old_head = recorded;
        }
    }
    let taken = syncs_taken(ctx, unit);
    if !resume && !reissue && taken >= MAX_BASE_SYNCS {
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
        // The base the request aims at, read before it is made.
        fetch(&wt, &branch, &base, &log("fetch"))?;
        let aimed = git::commit(&wt, &base_ref).unwrap_or_default();
        let pr_arg = pr.to_string();
        if !reissue {
            // Before the call, so a process killed around it leaves a trace.
            write_json(
                &marker,
                &json!({"pr": pr, "pr_head": before.head, "local_head": old_head, "base_head": aimed}),
            )?;
        }
        let (rc, _) = gh::read_raw(&["pr", "update-branch", &pr_arg, "--repo", &repo]);
        if rc != 0 {
            if !reissue {
                let _ = fs::remove_file(&marker);
            }
            return Err(Fail::failed(format!("gh pr update-branch {pr} failed (exit {rc})")));
        }
        // The slot is spent now, before any local step can fail. A recovered
        // request's slot was logged when the marker was found.
        if !reissue {
            ctx.event(
                "base_sync_remote",
                json!({"unit": unit, "pr": pr, "pr_head": before.head, "local_head": old_head, "base_head": aimed}),
            )?;
        }
        owned_view(ctx, &repo, unit, pr, &branch)?.head
    };

    fetch(&wt, &branch, &base, &log("fetch"))?;
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

    // GitHub may not have applied the update yet: the fetched base must be in
    // the PR's head before the sync counts as done. If it is not, the request
    // stays pending and a retry asks again.
    if !git::ok(&wt, &["merge-base", "--is-ancestor", &base_ref, &new_head]) {
        return Err(Fail::failed(format!(
            "{base} is not in the PR's head {new_head} yet; GitHub has not applied the update. Run base-sync again"
        )));
    }

    let checked = deliver_check::evaluate(ctx, unit, &wt, None, None)?;
    // The proof must cover the head, and the gate's own review read must say
    // `clear` (a merge that changed the reviewed diff's digest does not). A read
    // that fails needs a round.
    let clear = preflight(ctx, &repo, pr).is_ok_and(|p| p.status == "clear" && p.head.eq_ignore_ascii_case(&new_head));
    let needed = !clear || review_round_needed(ctx, unit, &wt, &new_head);
    let out = json!({
        "unit": unit,
        "pr": pr,
        "old_head": old_head,
        "new_head": new_head,
        "deliver_ok": checked.ok,
        "review_round_needed": needed,
    });
    // Before the line: a process killed between the two leaves a request with
    // no finished line, which the next run finishes from the log.
    let _ = fs::remove_file(&marker);
    ctx.event("base_sync", out.clone())?;
    println!("{out}");
    Ok(())
}
