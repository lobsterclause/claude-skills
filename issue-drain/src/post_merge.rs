//! `issue-drain post-merge --unit <n> --pr <n>`: the checks after a unit's PR
//! merged (plan step 9).
//!
//! 1. The PR must be MERGED (exit 3 otherwise).
//! 2. Tree check: the merge commit's tree is compared with the tree of the PR
//!    head the gate approved, in the unit's worktree when it still exists, else
//!    in the repo checkout. A different tree is not an error: the base moved
//!    between the gate and the merge, so the base tip needs a verify of its
//!    own. It is reported as `tree_match: false` and said on stderr.
//! 3. Closures: the issues the PR closes (intersected with `result.json`
//!    `closes` when that file exists). GitHub closes them itself on a merge
//!    into the default branch, but a merge into another base branch does not,
//!    and the autoclose can lag. Each is read, polling up to
//!    ISSUE_DRAIN_POST_MERGE_WAIT_SECS (default 60); one still open is closed
//!    here with a comment, through `gh::write` (the same path `close-verified`
//!    uses), and read back. Anything still open after that is a failure.
//! 4. The unit's claim is released (`claim::release_unit`) once every issue is
//!    closed; a run without `tracker.json` took no claim.
//!
//! It does not remove the worktree (`cleanup --unit` does) and does not edit
//! the tracker. With ISSUE_DRAIN_DRY_RUN=1 the reads happen and the writes
//! print `WOULD: ...`; the issues it would close are listed in `closed_here`.
//!
//! Exit: 0 done (a tree mismatch included); 3 the PR is not merged or a unit
//! process asked; 1 GitHub or git failed, or an issue is still open; 2 usage.

use std::path::PathBuf;
use std::thread::sleep;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::claim;
use crate::ctx::{Ctx, env_str, read_json, write_atomic};
use crate::error::{Fail, Res};
use crate::exec;
use crate::gh::{self, Write};
use crate::git;
use crate::merge_gate::is_sha;
use crate::text::sha7;

#[derive(clap::Args)]
pub struct Args {
    /// The unit; its files are under <run folder>/units/<n>/.
    #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
    pub unit: u64,
    /// The unit's merged pull request.
    #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
    pub pr: u64,
}

const GIT_LIMIT: Duration = Duration::from_secs(120);
const DEFAULT_WAIT_SECS: u64 = 60;
const POLL: Duration = Duration::from_secs(5);

fn read_pr(repo: &str, pr: u64) -> Res<Value> {
    let n = pr.to_string();
    let raw = gh::read(&[
        "pr",
        "view",
        &n,
        "--repo",
        repo,
        "--json",
        "state,mergeCommit,headRefOid,baseRefName,closingIssuesReferences",
    ])
    .map_err(|rc| Fail::failed(format!("could not read PR #{pr} (gh exit {rc})")))?;
    serde_json::from_str(&raw).map_err(|_| Fail::failed(format!("could not read PR #{pr}: gh did not return JSON")))
}

/// The merge commit: `{"oid": ...}` as gh prints it, or a bare string.
fn merge_commit(view: &Value) -> Option<String> {
    let c = &view["mergeCommit"];
    c["oid"].as_str().or_else(|| c.as_str()).map(str::to_string)
}

/// Where the trees are compared: the unit's worktree while it exists.
fn compare_dir(ctx: &Ctx, unit: u64) -> Res<PathBuf> {
    let unit_json: Option<Value> = read_json(&ctx.path(&format!("units/{unit}/unit.json")));
    let worktree = unit_json
        .as_ref()
        .and_then(|u| u["worktree"].as_str())
        .map(PathBuf::from)
        .filter(|w| w.is_absolute() && git::ok(w, &["rev-parse", "--git-dir"]));
    match worktree {
        Some(w) => Ok(w),
        None => ctx.repo_dir(),
    }
}

/// Whether the merge commit and the approved head hold the same tree.
fn trees_match(ctx: &Ctx, unit: u64, merge: &str, head: &str) -> Res<bool> {
    let dir = compare_dir(ctx, unit)?;
    let log = ctx.path(&format!("units/{unit}/post-merge.log"));
    let base = &ctx.profile.base_branch;
    let refspec = format!("+refs/heads/{base}:refs/remotes/origin/{base}");
    let fetched = exec::git(&dir, &["fetch", "--quiet", "origin", &refspec], GIT_LIMIT, &log)?;
    if !fetched.ok() {
        return Err(Fail::failed(format!(
            "could not fetch {base} in {}: {}",
            dir.display(),
            fetched.failure(GIT_LIMIT)
        )));
    }
    for sha in [merge, head] {
        if git::commit(&dir, sha).is_none() {
            // Best effort: a commit the base fetch did not bring (the PR head).
            let _ = exec::git(&dir, &["fetch", "--quiet", "origin", sha], GIT_LIMIT, &log)?;
        }
        if git::commit(&dir, sha).is_none() {
            return Err(Fail::failed(format!(
                "commit {} is not in {}",
                sha7(sha),
                dir.display()
            )));
        }
    }
    let tree = |sha: &str| {
        git::out(&dir, &["rev-parse", &format!("{sha}^{{tree}}")])
            .map(|t| t.trim().to_string())
            .ok_or_else(|| Fail::failed(format!("git cannot read the tree of {}", sha7(sha))))
    };
    Ok(tree(merge)? == tree(head)?)
}

/// The issues to check: the PR's closing references, narrowed to what the
/// unit's result.json says it closes (the PR alone when there is none).
fn closing_issues(ctx: &Ctx, unit: u64, view: &Value) -> Vec<u64> {
    let mut refs: Vec<u64> = view["closingIssuesReferences"]
        .as_array()
        .map(|list| list.iter().filter_map(|i| i["number"].as_u64()).collect())
        .unwrap_or_default();
    if let Some(result) = read_json::<Value>(&ctx.path(&format!("units/{unit}/result.json"))) {
        if let Some(closes) = result["closes"].as_array() {
            let closes: Vec<u64> = closes.iter().filter_map(Value::as_u64).collect();
            refs.retain(|n| closes.contains(n));
        }
    }
    refs.sort_unstable();
    refs.dedup();
    refs
}

fn issue_state(repo: &str, number: u64) -> Res<String> {
    let unread = || Fail::failed(format!("could not read #{number}"));
    let raw =
        gh::read(&["issue", "view", &number.to_string(), "--repo", repo, "--json", "state"]).map_err(|_| unread())?;
    let value: Value = serde_json::from_str(&raw).map_err(|_| unread())?;
    Ok(value["state"].as_str().unwrap_or("unknown").to_string())
}

fn wait_limit() -> Duration {
    let secs = env_str("ISSUE_DRAIN_POST_MERGE_WAIT_SECS")
        .parse()
        .unwrap_or(DEFAULT_WAIT_SECS);
    Duration::from_secs(secs)
}

/// Read each issue, again and again until all are closed or the wait is over.
/// Returns (closed, still open).
fn await_autoclose(repo: &str, issues: &[u64]) -> Res<(Vec<u64>, Vec<u64>)> {
    let deadline = Instant::now() + wait_limit();
    let mut closed = Vec::new();
    let mut open: Vec<u64> = issues.to_vec();
    loop {
        let mut still = Vec::new();
        for &n in &open {
            if issue_state(repo, n)? == "CLOSED" {
                closed.push(n);
            } else {
                still.push(n);
            }
        }
        open = still;
        let now = Instant::now();
        if open.is_empty() || now >= deadline {
            return Ok((closed, open));
        }
        sleep(POLL.min(deadline - now));
    }
}

pub fn run(ctx: &Ctx, args: &Args) -> Res<()> {
    ctx.require_driver("post-merge")?;
    let (unit, pr) = (args.unit, args.pr);
    let repo = ctx.repo()?;
    let view = read_pr(&repo, pr)?;
    let state = view["state"].as_str().unwrap_or("unknown");
    if state != "MERGED" {
        return Err(Fail::refused(format!("PR #{pr} is {state}, not MERGED")));
    }
    let merge = merge_commit(&view)
        .filter(|s| is_sha(s))
        .ok_or_else(|| Fail::failed(format!("PR #{pr} is merged but names no merge commit")))?;
    let head = view["headRefOid"]
        .as_str()
        .filter(|s| is_sha(s))
        .ok_or_else(|| Fail::failed(format!("PR #{pr} names no head commit")))?
        .to_string();

    let tree_match = trees_match(ctx, unit, &merge, &head)?;
    if !tree_match {
        eprintln!(
            "issue-drain post-merge: the merge commit {} does not hold the tree of the approved head {}: {} moved between the gate and the merge. Run a verify of the {} tip.",
            sha7(&merge),
            sha7(&head),
            ctx.profile.base_branch,
            ctx.profile.base_branch
        );
    }

    let issues = closing_issues(ctx, unit, &view);
    let (closed_by_merge, open) = await_autoclose(&repo, &issues)?;
    let mut closed_here = Vec::new();
    let mut still_open = Vec::new();
    for number in open {
        let body = format!("Fixed by #{pr} (merged as {}).\n", sha7(&merge));
        let file = ctx.path(&format!("units/{unit}/post-merge-{number}.md"));
        write_atomic(&file, body.as_bytes())?;
        gh::write(
            ctx,
            &Write::Comment {
                number,
                body_file: &file,
            },
        )?;
        gh::write(ctx, &Write::CloseIssue { number })?;
        // A dry run wrote nothing, so there is nothing to read back.
        if ctx.dry_run || issue_state(&repo, number)? == "CLOSED" {
            closed_here.push(number);
        } else {
            still_open.push(number);
        }
    }

    // A claim is released only when the unit's issues are all closed.
    let mut claims_released: Vec<u64> = Vec::new();
    if still_open.is_empty() && ctx.path("tracker.json").is_file() {
        let report = claim::release_unit(ctx, unit)?;
        claims_released = report
            .iter()
            .filter(|r| r["action"] == "released")
            .filter_map(|r| r["issue"].as_u64())
            .collect();
    }

    let mut out = json!({
        "unit": unit,
        "pr": pr,
        "merge_commit": merge,
        "head": head,
        "tree_match": tree_match,
        "closed_by_merge": closed_by_merge,
        "closed_here": closed_here,
        "still_open": still_open,
        "claims_released": claims_released,
    });
    if ctx.dry_run {
        out["dry_run"] = json!(true);
    }
    ctx.event("post_merge", out.clone())?;
    println!("{out}");
    if still_open.is_empty() {
        Ok(())
    } else {
        let list: Vec<String> = still_open.iter().map(|n| format!("#{n}")).collect();
        Err(Fail::failed(format!(
            "still open after the merge and a close call: {}",
            list.join(", ")
        )))
    }
}
