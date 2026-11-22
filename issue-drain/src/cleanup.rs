//! `issue-drain cleanup --unit <n> [--pr <n>] [--force]` and
//! `issue-drain cleanup --run [--force]`: take away what a unit made once its
//! work is done. The driver calls `cleanup --unit` after a unit's post-merge
//! checks; `cleanup --run` sweeps the whole run folder at the end.
//!
//! For a unit:
//!   - its worktree is removed with `git worktree remove`. A worktree with
//!     uncommitted changes is refused unless `--force`. A worktree that holds
//!     this process's working directory is refused always: that is the by-hand
//!     case, and removing it would pull the folder from under the caller.
//!   - the PR must be the unit's (the checks `merge-gate` makes: head repo, head
//!     branch, base), and the local branch tip must be the PR's head or one of
//!     its ancestors, or nothing is removed; `--force` does not cover that.
//!     A PR number from a gate line that refused it as not the unit's is skipped.
//!   - its local branch is deleted only when the PR is merged. The PR is
//!     `--pr`, or else the last one the run's log names for the unit. An open or
//!     closed-unmerged PR, or none known, keeps the branch.
//!   - its claim label is released if still held, with `claim release`'s own
//!     code (so only a claim that is ours is touched). A run with no
//!     `tracker.json` has no claim to release.
//!
//! `--run` does every unit under `units/` whose PR is merged or closed, and
//! says why it skipped each other one. It then removes `<run folder>/base`
//! (the triage readers' detached worktree) when no unit worktree is left.
//!
//! Nothing outside the run folder is touched: a worktree that is not under
//! `<run folder>/worktrees/` is refused. With ISSUE_DRAIN_DRY_RUN=1 each step
//! prints `WOULD: ...` and nothing is removed. A unit process may not run it.
//!
//! One JSON line per unit (`--run` adds `{"base": ...}`). Exit: 0 done; 3
//! refused (a unit process asked, a dirty worktree, the current folder, a path
//! outside the run folder); 2 bad arguments or no unit files; 1 git, gh or the
//! filesystem failed. With `--run`, every unit is tried and the highest failing
//! exit code is returned.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};

use crate::base_sync::{owned_view, pr_from_log, unit_files};
use crate::claim;
use crate::ctx::Ctx;
use crate::error::{Fail, Res};
use crate::exec;
use crate::git;
use crate::merge_gate::PrState;

#[derive(clap::Args)]
#[command(group(clap::ArgGroup::new("target").required(true).args(["unit", "run"])))]
pub struct Args {
    /// Clean up one unit.
    #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
    unit: Option<u64>,
    /// Clean up every unit whose PR is merged or closed, then the base clone.
    #[arg(long)]
    run: bool,
    /// The unit's pull request (default: the last one the run's log names for it).
    #[arg(long, requires = "unit", value_parser = clap::value_parser!(u64).range(1..))]
    pr: Option<u64>,
    /// Remove a worktree that has uncommitted changes too.
    #[arg(long)]
    force: bool,
}

const GIT_LIMIT: Duration = Duration::from_secs(120);

/// A folder's real path, or the path as given when it does not exist.
fn real(path: &Path) -> PathBuf {
    fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

/// Refuse when this process's working directory is inside `dir`.
fn not_the_cwd(dir: &Path) -> Res<()> {
    let cwd = std::env::current_dir().ok().map(|c| real(&c));
    if cwd.is_some_and(|cwd| cwd.starts_with(real(dir))) {
        return Err(Fail::refused(format!(
            "{} holds this process's working directory; leave it and run cleanup from another folder, or remove it by hand",
            dir.display()
        )));
    }
    Ok(())
}

fn remove_worktree(repo_dir: &Path, wt: &Path, force: bool, log: &Path) -> Res<()> {
    let shown = wt.display().to_string();
    let mut args = vec!["worktree", "remove"];
    if force {
        args.push("--force");
    }
    args.push(&shown);
    let ran = exec::git(repo_dir, &args, GIT_LIMIT, log)?;
    if ran.ok() {
        Ok(())
    } else {
        Err(Fail::failed(format!(
            "git worktree remove {shown} failed: {}",
            ran.failure(GIT_LIMIT)
        )))
    }
}

/// Refuse unless `tip` is the PR's head or one of its ancestors. A PR head this
/// checkout has not seen (the PR's branch is often deleted on merge) is fetched
/// from GitHub's `refs/pull/<n>/head` first.
fn unpushed_work_check(
    repo_dir: &Path,
    pr: u64,
    head: &str,
    tip: &str,
    branch: &str,
    log: &Path,
    dry_run: bool,
) -> Res<()> {
    let have = |sha: &str| git::ok(repo_dir, &["cat-file", "-e", &format!("{sha}^{{commit}}")]);
    if !have(head) {
        let spec = format!("refs/pull/{pr}/head");
        if dry_run {
            // A dry run leaves the checkout as it is: the check is not made.
            println!(
                "WOULD: git fetch origin {spec} (the ancestry check of {branch} needs a fetch, skipped in a dry run)"
            );
            return Ok(());
        }
        let _ = exec::git(repo_dir, &["fetch", "--quiet", "origin", &spec], GIT_LIMIT, log);
    }
    if have(head) && git::ok(repo_dir, &["merge-base", "--is-ancestor", tip, head]) {
        return Ok(());
    }
    Err(Fail::refused(format!(
        "the local branch {branch} is at {tip}, which is not on the PR's head {head}: it holds commits the PR never had. Push or save them; --force does not cover this"
    )))
}

/// One unit's cleanup. `only_finished` is `--run`: a unit whose PR is not known,
/// or is still open, is skipped, and the skip is the `Ok` answer.
fn unit(ctx: &Ctx, args: &Args, n: u64, only_finished: bool) -> Res<Value> {
    let files = unit_files(ctx, n)?;
    let repo = ctx.repo()?;
    let repo_dir = ctx.repo_dir()?;
    let run_dir = real(&ctx.workdir);
    let pr = args.pr.or_else(|| pr_from_log(ctx, n));
    // The PR must be the unit's before its state means anything: a merged PR
    // of another branch or repo is no reason to delete this unit's work.
    let view = match pr {
        Some(pr) => Some(owned_view(ctx, &repo, n, pr, &files.branch)?),
        None => None,
    };
    let state = view.as_ref().map(|v| match v.state {
        PrState::Open => "OPEN".to_string(),
        PrState::Closed => "CLOSED".to_string(),
        PrState::Merged => "MERGED".to_string(),
        PrState::Other => "OTHER".to_string(),
    });
    if only_finished {
        match state.as_deref() {
            None => return Ok(json!({"unit": n, "skipped": "no_pr"})),
            Some("MERGED" | "CLOSED") => {}
            Some(_) => return Ok(json!({"unit": n, "pr": pr, "skipped": "pr_open"})),
        }
    }
    let merged = state.as_deref() == Some("MERGED");

    // Everything below happens in the run folder, or not at all.
    let wt = files.worktree;
    let worktrees = run_dir.join("worktrees");
    let wt_real = real(&wt);
    if !wt_real.starts_with(&worktrees) || wt_real == worktrees {
        return Err(Fail::refused(format!(
            "unit {n}'s worktree {} is not under the run folder's worktrees/ ({}); it is not touched",
            wt.display(),
            worktrees.display()
        )));
    }
    let present = wt.exists();
    if present {
        not_the_cwd(&wt)?;
        if !args.force {
            match git::out(&wt, &["status", "--porcelain", "--untracked-files=all"]) {
                Some(status) if status.trim().is_empty() => {}
                Some(_) => {
                    return Err(Fail::refused(format!(
                        "the worktree {} has uncommitted changes; commit or discard them, or pass --force",
                        wt.display()
                    )));
                }
                None => {
                    return Err(Fail::failed(format!("git cannot read the status of {}", wt.display())));
                }
            }
        }
    }

    let log = ctx.path(&format!("units/{n}/cleanup-worktree.log"));
    let branch = files.branch;
    let has_branch = git::ok(
        &repo_dir,
        &["rev-parse", "--verify", "-q", &format!("refs/heads/{branch}")],
    );
    // A clean worktree can still hold commits the PR never had. --force covers
    // a dirty tree, never those. The comparison is with the PR's head, not with
    // the squash commit the merge made.
    if let (Some(view), Some(pr)) = (&view, pr) {
        // The branch's tip, and the worktree's own HEAD: a worktree detached at
        // an unpushed commit would leave that commit unreachable once removed.
        let tips = [
            git::commit(&repo_dir, &format!("refs/heads/{branch}")),
            present.then(|| git::commit(&wt, "HEAD")).flatten(),
        ];
        for tip in tips.into_iter().flatten() {
            unpushed_work_check(&repo_dir, pr, &view.head, &tip, &branch, &log, ctx.dry_run)?;
        }
    }
    // With no PR the branch is kept, but a detached HEAD is not on it: a commit
    // no kept ref reaches would be lost with the worktree.
    if view.is_none() && present {
        if let Some(head) = git::commit(&wt, "HEAD") {
            let kept = git::out(
                &repo_dir,
                &[
                    "for-each-ref",
                    "--contains",
                    &head,
                    "refs/heads",
                    "refs/remotes",
                    "refs/tags",
                ],
            );
            if kept.is_none_or(|refs| refs.trim().is_empty()) {
                return Err(Fail::refused(format!(
                    "the worktree {} is at {head}, which is not reachable from any branch, remote ref or tag; it would be lost. Push or save it first; --force does not cover this",
                    wt.display()
                )));
            }
        }
    }
    let (worktree_result, branch_result) = if ctx.dry_run {
        if present {
            println!("WOULD: git worktree remove {}", wt.display());
        }
        if merged && has_branch {
            println!("WOULD: git branch -D {branch}");
        }
        (
            if present { "would_remove" } else { "absent" },
            match (merged, has_branch) {
                (true, true) => "would_delete",
                (true, false) => "absent",
                (false, _) => "kept_unmerged",
            },
        )
    } else {
        if present {
            remove_worktree(&repo_dir, &wt, args.force, &log)?;
        }
        let branch_result = match (merged, has_branch) {
            (false, _) => "kept_unmerged",
            (true, false) => "absent",
            (true, true) => {
                let ran = exec::git(&repo_dir, &["branch", "-D", &branch], GIT_LIMIT, &log)?;
                if !ran.ok() {
                    return Err(Fail::failed(format!(
                        "git branch -D {branch} failed: {}",
                        ran.failure(GIT_LIMIT)
                    )));
                }
                "deleted"
            }
        };
        (if present { "removed" } else { "absent" }, branch_result)
    };

    // The claim: a run that never published a tracker never took one.
    let claim_result = if ctx.path("tracker.json").is_file() {
        Value::Array(claim::release_unit(ctx, n)?)
    } else {
        json!("none")
    };

    let out = json!({
        "unit": n,
        "pr": pr,
        "pr_state": state,
        "worktree": worktree_result,
        "branch": branch_result,
        "claim": claim_result,
    });
    if !ctx.dry_run {
        ctx.event("cleanup", out.clone())?;
    }
    Ok(out)
}

/// The unit numbers that have a `units/<n>/unit.json`, in order.
fn prepared_units(ctx: &Ctx) -> BTreeSet<u64> {
    fs::read_dir(ctx.path("units"))
        .into_iter()
        .flatten()
        .flatten()
        .filter(|entry| entry.path().join("unit.json").is_file())
        .filter_map(|entry| entry.file_name().to_str()?.parse().ok())
        .collect()
}

/// `<run folder>/base`, once no unit worktree remains outside `cleaned`.
fn base_clone(ctx: &Ctx, force: bool, cleaned: &BTreeSet<u64>) -> Res<Option<Value>> {
    let run_dir = real(&ctx.workdir);
    let base = run_dir.join("base");
    // A link is looked at before it is followed: `git worktree remove --force`
    // on a link to a worktree elsewhere removes the target.
    match fs::symlink_metadata(&base) {
        Err(_) => return Ok(None),
        Ok(meta) if meta.file_type().is_symlink() => {
            return Err(Fail::refused(format!(
                "{} is a symlink; it is not followed or removed. Remove the link by hand",
                base.display()
            )));
        }
        Ok(_) => {}
    }
    let inside = fs::canonicalize(&base).is_ok_and(|real| real.starts_with(&run_dir) && real != run_dir);
    if !inside {
        return Err(Fail::refused(format!(
            "{} does not resolve to a folder inside the run folder {}; it is not touched",
            base.display(),
            run_dir.display()
        )));
    }
    let left: Vec<String> = fs::read_dir(run_dir.join("worktrees"))
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| entry.file_name().into_string().ok())
        .filter(|name| !name.parse::<u64>().is_ok_and(|n| cleaned.contains(&n)))
        .collect();
    if !left.is_empty() {
        return Ok(Some(
            json!({"base": "kept", "why": "unit worktrees remain", "worktrees": left}),
        ));
    }
    not_the_cwd(&base)?;
    if ctx.dry_run {
        let flag = if force { " --force" } else { "" };
        println!("WOULD: git worktree remove{flag} {}", base.display());
        return Ok(Some(json!({"base": "would_remove"})));
    }
    remove_worktree(&ctx.repo_dir()?, &base, force, &ctx.path("cleanup-base.log"))?;
    Ok(Some(json!({"base": "removed"})))
}

pub fn run(ctx: &Ctx, args: &Args) -> Res<()> {
    ctx.require_driver("cleanup")?;
    if let Some(n) = args.unit {
        let out = unit(ctx, args, n, false)?;
        println!("{out}");
        return Ok(());
    }

    let mut worst: Option<Fail> = None;
    let mut cleaned = BTreeSet::new();
    for n in prepared_units(ctx) {
        match unit(ctx, args, n, true) {
            Ok(out) => {
                if out["worktree"].is_string() {
                    cleaned.insert(n);
                }
                println!("{out}");
            }
            Err(fail) => {
                println!("{}", json!({"unit": n, "error": fail.msg, "exit": fail.code}));
                if worst.as_ref().is_none_or(|w| fail.code > w.code) {
                    worst = Some(fail);
                }
            }
        }
    }
    match base_clone(ctx, args.force, &cleaned) {
        Ok(Some(out)) => println!("{out}"),
        Ok(None) => {}
        Err(fail) => {
            println!("{}", json!({"base": "error", "error": fail.msg, "exit": fail.code}));
            if worst.as_ref().is_none_or(|w| fail.code > w.code) {
                worst = Some(fail);
            }
        }
    }
    match worst {
        Some(fail) => Err(Fail {
            code: fail.code,
            msg: format!("not every unit was cleaned up; the worst: {}", fail.msg),
        }),
        None => Ok(()),
    }
}
