//! `issue-drain unit-prepare --unit <n>`: the driver's step before it starts a
//! unit process. It cuts a linked worktree from the fresh tip of the base
//! branch, runs the profile's bootstrap in it, and writes the two files the
//! unit starts from:
//!
//!   units/<n>/unit.json         what `references/unit.md` says a unit reads
//!   units/<n>/guards-unit.json  what the guards mod's `parseUnit` accepts
//!                               (the driver points ISSUE_DRAIN_UNIT_FILE at it)
//!
//! The worktree is `<run folder>/worktrees/<n>`, beside the run's other state
//! (`base/`, `units/`), so a run's folder holds everything the run made.
//!
//! Exit: 0 prepared (stdout is one line of JSON naming the worktree and the
//! guards file); 3 refused (a unit process asked, the checkout is of another
//! repo, a bootstrap precondition is missing, or an existing worktree or
//! branch of this unit is not one to reuse); 2 no queue or no such unit;
//! 1 git, the bootstrap or the filesystem failed.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};

use crate::ctx::{Ctx, read_json, write_json};
use crate::error::{Fail, Res};
use crate::exec;
use crate::git;

#[derive(clap::Args)]
pub struct Args {
    /// The unit; its files are under <run folder>/units/<n>/.
    #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
    unit: u64,
}

const SLUG_MAX: usize = 40;
const GIT_LIMIT: Duration = Duration::from_secs(120);

/// Lowercase letters and digits, one dash between runs of anything else, at
/// most `SLUG_MAX` of them. Never empty.
pub fn slug(text: &str) -> String {
    let mut out = String::new();
    for c in text.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
        } else if !out.is_empty() && !out.ends_with('-') {
            out.push('-');
        }
    }
    out.truncate(SLUG_MAX);
    let out = out.trim_end_matches('-');
    if out.is_empty() { "unit".into() } else { out.into() }
}

/// `feat/<n>-<slug>` for a feature, else `fix/<n>-<slug>`. The prefix is one
/// of those two whatever the unit's kind says, so the branch can never start
/// with `agent/` (a workflow in kma rewrites closing keywords on those).
pub fn branch_name(kind: &str, unit: u64, title: &str) -> String {
    let prefix = if kind.to_lowercase().contains("feat") {
        "feat"
    } else {
        "fix"
    };
    format!("{prefix}/{unit}-{}", slug(title))
}

/// The checkout the worktrees hang off, found the way `worktree-bootstrap.sh`
/// finds it: the folder that holds the common git dir.
fn main_checkout(repo_dir: &Path) -> PathBuf {
    common_dir(repo_dir)
        .filter(|dir| dir.file_name().is_some_and(|name| name == ".git"))
        .and_then(|dir| dir.parent().map(Path::to_path_buf))
        .unwrap_or_else(|| repo_dir.to_path_buf())
}

fn common_dir(dir: &Path) -> Option<PathBuf> {
    let out = git::out(dir, &["rev-parse", "--path-format=absolute", "--git-common-dir"])?;
    fs::canonicalize(out.trim()).ok()
}

fn on_path(program: &str) -> bool {
    use std::os::unix::fs::PermissionsExt;
    let path = std::env::var_os("PATH").unwrap_or_default();
    std::env::split_paths(&path).any(|dir| {
        fs::metadata(dir.join(program)).is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
    })
}

/// `["codegraph"...]` result for unit.json: ready, absent or failed.
fn init_codegraph(ctx: &Ctx, worktree: &Path, log: &Path) -> &'static str {
    if !ctx.profile.codegraph_init || !on_path("codegraph") {
        return "absent";
    }
    let limit = Duration::from_secs(ctx.profile.codegraph_timeout_secs);
    let args = ["init".to_string(), "-i".to_string()];
    match exec::run("codegraph", &args, worktree, limit, log) {
        Ok(ran) if ran.ok() => "ready",
        Ok(ran) => {
            eprintln!(
                "issue-drain unit-prepare: codegraph init {}; the unit falls back to Grep and LSP",
                ran.failure(limit)
            );
            "failed"
        }
        Err(e) => {
            eprintln!(
                "issue-drain unit-prepare: {}; the unit falls back to Grep and LSP",
                e.msg
            );
            "failed"
        }
    }
}

fn bootstrap(ctx: &Ctx, worktree: &Path, log: &Path) -> Res<()> {
    let p = &ctx.profile;
    let shown = worktree.display().to_string();
    let mut words = exec::expand(&p.bootstrap_command, &[("worktree", &shown)])
        .map_err(|e| Fail::usage(format!("profile key bootstrap_command: {e}")))?;
    let program = words.remove(0);
    // A relative path to a script in the repo is relative to the worktree.
    let program = exec::program_in(&program, worktree);
    let limit = Duration::from_secs(p.bootstrap_timeout_secs);
    let ran = exec::run(&program, &words, worktree, limit, log)?;
    if ran.ok() {
        Ok(())
    } else {
        Err(Fail::failed(format!(
            "the bootstrap ({}) failed: {}",
            p.bootstrap_command,
            ran.failure(limit)
        )))
    }
}

/// Branch name checked out in `dir`, if any.
fn current_branch(dir: &Path) -> Option<String> {
    git::out(dir, &["symbolic-ref", "--short", "-q", "HEAD"]).map(|b| b.trim().to_string())
}

/// Why `worktree` is not one to reuse for `branch`, or `None` when it is.
fn not_reusable(repo_dir: &Path, worktree: &Path, branch: &str) -> Option<String> {
    let same_repo = common_dir(worktree).is_some_and(|theirs| common_dir(repo_dir) == Some(theirs))
        && git::out(worktree, &["rev-parse", "--show-toplevel"])
            .and_then(|top| fs::canonicalize(top.trim()).ok())
            .is_some_and(|top| fs::canonicalize(worktree).is_ok_and(|w| w == top));
    if !same_repo {
        return Some(format!(
            "{} exists and is not a git worktree of {}",
            worktree.display(),
            repo_dir.display()
        ));
    }
    let on = current_branch(worktree).unwrap_or_default();
    if on != branch {
        let on = if on.is_empty() { "no branch (detached)" } else { &on };
        return Some(format!("the worktree {} is on {on}, not {branch}", worktree.display()));
    }
    match git::out(worktree, &["status", "--porcelain", "--untracked-files=all"]) {
        Some(status) if status.trim().is_empty() => None,
        Some(_) => Some(format!("the worktree {} is not clean", worktree.display())),
        None => Some(format!("git cannot read the status of {}", worktree.display())),
    }
}

fn read_text(value: &Value, key: &str) -> String {
    value[key].as_str().unwrap_or_default().trim().to_string()
}

/// Per issue: whether its author is trusted, from intake.json. An issue intake
/// does not list is not trusted.
fn trusted_authors(ctx: &Ctx, issues: &[u64]) -> Value {
    let intake: Value = read_json(&ctx.path("intake.json")).unwrap_or(Value::Null);
    let eligible = intake["eligible"].as_array().cloned().unwrap_or_default();
    let trusted = |n: u64| eligible.iter().any(|e| e["number"] == n && e["trusted_author"] == true);
    Value::Object(issues.iter().map(|n| (n.to_string(), json!(trusted(*n)))).collect())
}

/// Per issue: the reader's task statement for it, from the checked verdicts.
/// Issues with none are left out.
fn issue_tasks(ctx: &Ctx, issues: &[u64]) -> Value {
    let verdicts: Value = read_json(&ctx.path("verdicts.checked.json")).unwrap_or(Value::Null);
    let all = verdicts.as_array().cloned().unwrap_or_default();
    Value::Object(
        issues
            .iter()
            .filter_map(|n| {
                let task = all.iter().find(|v| v["number"] == *n).map(|v| read_text(v, "task"))?;
                (!task.is_empty()).then(|| (n.to_string(), json!(task)))
            })
            .collect(),
    )
}

pub fn run(ctx: &Ctx, args: &Args) -> Res<()> {
    ctx.require_driver("unit-prepare")?;
    let unit = args.unit;
    let q = ctx.queue_unit(unit)?;
    let repo = ctx.repo()?;
    let repo_dir = ctx.repo_dir()?;
    let p = &ctx.profile;

    // The checkout must be of the repo being drained, or the unit would work
    // on someone else's code.
    match git::origin_repo(&repo_dir) {
        Some(origin) if origin.eq_ignore_ascii_case(&repo) => {}
        origin => {
            return Err(Fail::refused(format!(
                "the checkout at {} has origin {}, not {repo}",
                repo_dir.display(),
                origin
                    .as_deref()
                    .unwrap_or("unset, not on github.com, or set to more than one repo")
            )));
        }
    }
    let main = main_checkout(&repo_dir);
    for need in &p.bootstrap_requires {
        if !main.join(need).exists() {
            return Err(Fail::refused(format!(
                "the bootstrap needs {need} in {}, which is not there; install it there first",
                main.display()
            )));
        }
    }

    // A by-hand run may never have run `state init`. The state is started from
    // the approved tracker before anything is made, so a refusal leaves nothing behind.
    if crate::state::init_if_missing(ctx)? {
        eprintln!("issue-drain unit-prepare: no state in the run folder, so it was started (state init)");
    }

    fs::create_dir_all(&ctx.workdir)
        .map_err(|e| Fail::failed(format!("cannot create {}: {e}", ctx.workdir.display())))?;
    let run_dir = fs::canonicalize(&ctx.workdir)
        .map_err(|e| Fail::failed(format!("cannot resolve {}: {e}", ctx.workdir.display())))?;
    let state_dir = run_dir.join(format!("units/{unit}"));
    fs::create_dir_all(&state_dir).map_err(|e| Fail::failed(format!("cannot create {}: {e}", state_dir.display())))?;
    let log = |step: &str| state_dir.join(format!("prepare-{step}.log"));

    // The base as it is now. The refspec is spelled out: a checkout that does
    // not track the base would otherwise move only FETCH_HEAD.
    let base = &p.base_branch;
    let refspec = format!("+refs/heads/{base}:refs/remotes/origin/{base}");
    let fetched = exec::git(
        &repo_dir,
        &["fetch", "--quiet", "origin", &refspec],
        GIT_LIMIT,
        &log("fetch"),
    )?;
    if !fetched.ok() {
        return Err(Fail::failed(format!(
            "could not fetch {base} in {}: {}",
            repo_dir.display(),
            fetched.failure(GIT_LIMIT)
        )));
    }
    let tip = git::base_commit(&repo_dir, base)
        .ok_or_else(|| Fail::failed(format!("no refs/remotes/origin/{base} after the fetch")))?;

    let branch = branch_name(&q.kind, unit, &q.title);
    let worktree = run_dir.join(format!("worktrees/{unit}"));
    let unit_file = state_dir.join("unit.json");
    let before: Value = read_json(&unit_file).unwrap_or(Value::Null);

    let reused = worktree.exists();
    let base_sha = if reused {
        if let Some(why) = not_reusable(&repo_dir, &worktree, &branch) {
            return Err(Fail::refused(why));
        }
        git::out(
            &worktree,
            &["merge-base", "HEAD", &format!("refs/remotes/origin/{base}")],
        )
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| tip.clone())
    } else {
        if git::ok(
            &repo_dir,
            &["rev-parse", "--verify", "-q", &format!("refs/heads/{branch}")],
        ) {
            return Err(Fail::refused(format!(
                "the branch {branch} exists but its worktree {} does not; look at it before the unit starts over",
                worktree.display()
            )));
        }
        let wt = worktree.display().to_string();
        let added = exec::git(
            &repo_dir,
            &["worktree", "add", "--quiet", "-b", &branch, &wt, &tip],
            GIT_LIMIT,
            &log("worktree"),
        )?;
        if !added.ok() {
            return Err(Fail::failed(format!(
                "git worktree add failed: {}",
                added.failure(GIT_LIMIT)
            )));
        }
        tip.clone()
    };

    // A rerun does not repeat what an earlier run finished.
    let done = |key: &str, value: &str| reused && before[key] == value;
    let bootstrapped = if p.bootstrap_command.is_empty() {
        "none"
    } else {
        if !done("bootstrap", "ok") {
            bootstrap(ctx, &worktree, &log("bootstrap"))?;
        }
        "ok"
    };
    let codegraph = if done("codegraph", "ready") {
        "ready"
    } else {
        init_codegraph(ctx, &worktree, &log("codegraph"))
    };

    let state = state_dir.display().to_string();
    let wt = worktree.display().to_string();
    let out = json!({
        "unit": unit,
        "id": q.id,
        "repo": repo,
        "run_dir": run_dir.display().to_string(),
        "state_dir": state,
        "base": base,
        "base_sha": base_sha,
        "branch": branch,
        "worktree": wt,
        "kind": q.kind,
        "title": q.title,
        "task": q.title,
        "issue_tasks": issue_tasks(ctx, &q.issues),
        "issues": q.issues,
        "live": q.live,
        "files": q.files,
        "acceptance": q.acceptance,
        "reuse": q.reuse,
        "test_command": q.test_command,
        "model": q.model,
        "effort": q.effort,
        "risk": q.risk,
        "risk_paths": q.risk_paths,
        "waits_for": q.waits_for,
        "trusted_authors": trusted_authors(ctx, &q.issues),
        "protected_path_re": p.protected_path_re,
        "frozen_paths": p.frozen_paths,
        "risk_path_re": p.risk_path_re,
        "bootstrap": bootstrapped,
        "codegraph": codegraph,
    });
    write_json(&unit_file, &out)?;
    let guards_file = state_dir.join("guards-unit.json");
    write_json(
        &guards_file,
        &json!({
            "unit": unit,
            "worktree": wt,
            "branch": branch,
            "state_dir": state,
            "protected_paths": p.guard_protected_paths,
        }),
    )?;

    ctx.event(
        "unit_prepared",
        json!({"unit": unit, "branch": branch, "worktree": wt, "base_sha": base_sha,
               "reused": reused, "bootstrap": bootstrapped, "codegraph": codegraph}),
    )?;
    println!(
        "{}",
        json!({
            "unit": unit,
            "worktree": wt,
            "branch": branch,
            "reused": reused,
            "unit_file": unit_file.display().to_string(),
            "guards_unit_file": guards_file.display().to_string(),
        })
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_slug_is_lowercase_dashed_capped_and_never_empty() {
        assert_eq!(slug("Zero-pad the Countdown!"), "zero-pad-the-countdown");
        assert_eq!(slug("  --a__b  "), "a-b");
        assert_eq!(slug("../etc/passwd"), "etc-passwd");
        assert_eq!(slug(""), "unit");
        assert_eq!(slug("日本語"), "unit");
        let long = slug(&format!("{} tail", "a".repeat(39)));
        assert_eq!(long, "a".repeat(39), "a dash at the cut is dropped");
        assert_eq!(slug(&"b".repeat(100)).len(), SLUG_MAX);
    }

    #[test]
    fn the_branch_prefix_is_fix_or_feat_and_nothing_else() {
        assert_eq!(branch_name("bugfix", 3, "x"), "fix/3-x");
        assert_eq!(branch_name("feature", 3, "x"), "feat/3-x");
        assert_eq!(branch_name("Feature", 3, "x"), "feat/3-x");
        assert_eq!(branch_name("", 3, "x"), "fix/3-x");
        assert_eq!(branch_name("agent/x", 3, "agent/x"), "fix/3-agent-x");
    }
}
