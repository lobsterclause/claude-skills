//! `issue-drain merge-gate --unit <n> --pr <n> [--dry-run]`: the one path by
//! which a PR gets merged.
//!
//! A PR was once merged on green checks ten days old, 12 PRs were merged with
//! 11 review threads open, and a review script exited 0 for a PR nobody had
//! reviewed. So this gate reads everything live, judges every condition (it
//! does not stop at the first refusal), and merges only when none refuses. A
//! read that fails or does not parse is a refusal, never a pass.
//!
//! The work is split in two. `gather` does the I/O and fills `Facts`; a field
//! it could not read is an `Err` naming what. `judge` is a pure function of
//! `Facts`, so each condition is tested without a GitHub. The PR's head SHA is
//! read once, and the merge call carries it as `--match-head-commit`, so a
//! head that moves after the decision cannot be merged.
//!
//! Required checks are the contexts of the base branch's classic protection
//! and of every ruleset that applies to it (`rules/branches/<base>`); a branch
//! with no classic protection has no classic requirements only when the rules
//! were read. A check is a name from one source (a workflow, or a commit
//! status), and a required name needs every source that carries it to be ok.
//! Hold labels are read on the unit's queued issues and on the issues the PR
//! closes, and a PR that closes an issue the unit was not queued with is
//! refused (`closing_issue_unit`).
//!
//! A unit whose queue entry names someone in `waits_for` is never merged here:
//! a person merges it, and the gate does not try to verify that person's
//! approval. The same goes for a unit whose delivered diff touches a risk path
//! (`risk_path`): `deliver.json` lists them as `risk_paths_touched`, and a
//! report without that field is refused (`deliver_check`), so a unit planned
//! without risk paths cannot merge unattended. The delivery check must have diffed from the same merge base the
//! PR has against the live base branch (GitHub's compare answer), so a
//! `deliver-check --base` that audited only part of the PR is refused.
//!
//! The PR must be the unit's (`pr_unit`): its head branch is the `branch` in
//! `units/<n>/unit.json` and its head repository is the profile's repo, and it
//! must target the profile's base branch (`wrong_base`). This holds for the
//! already-merged answer as well, which is read only after it.
//! The PR must also be mergeable now (`not_mergeable`): `mergeStateStatus` is
//! CLEAN, HAS_HOOKS or UNSTABLE (only non-required checks failing or pending,
//! which this gate judges itself), and `reviewDecision` is neither
//! CHANGES_REQUESTED nor REVIEW_REQUIRED. On a merge-queue branch `gh pr merge`
//! can otherwise arm auto-merge for a PR that is not eligible yet, and GitHub
//! would merge it later with none of these conditions read again.
//!
//! The review script's `head` is the live head; its `reviewed` is the commit
//! the newest record was stamped at. They differ on purpose when the script
//! clears a base-only sync (digest equality) or a union of records. Then the
//! gate accepts only when `reviewed` is an ancestor of the head (GitHub's
//! compare answer) and the review proof on disk is for the head or, on that
//! path only, for `reviewed` (one proof check; the second needs the ancestry
//! shown); a record naming no `reviewed` is refused. The script asks local git
//! about the PR's commits, so it runs in the drained repository's checkout
//! (`ISSUE_DRAIN_REPO_DIR`), and a checkout whose origin is not the profile's
//! repo is a `read_error`.
//!
//! The script takes the newest stamped `## Cross-review` comment whoever wrote
//! it, so the gate reads the PR's comments itself (paginated) and finds that
//! same comment: newest, starting `## Cross-review`, with a marker or the
//! `Reviewed` prose. It refuses (`review_author`) unless that comment's author
//! has an `author_association` in the profile's `trusted_associations` (the list
//! that decides whose issue text agents see; case does not matter, an empty
//! list trusts no one) and its stamp names the commit and the CLEAN verdict the
//! script reported. The script also clears a moved head by combining every
//! stamped record, so an older record can supply coverage the newest lacks; the
//! gate does not redo that range arithmetic, and refuses (`review_author`,
//! naming the author) when any older stamped record other than a BLOCKED or
//! NEEDS_DECISION one was written by an untrusted author. A person must then
//! merge the PR or remove that comment.
//! No record, or comments that cannot be read, refuse too.
//! GitHub's association is what the gate can read; a login is not compared.
//!
//! Within one check name and source, the newest entry is kept per workflow run,
//! the run id being read from the entry's `detailsUrl` (`.../actions/runs/<id>/...`),
//! and every kept entry must pass. The rollup names no workflow file or id, only
//! a display name, so two workflow files that share a display name (and a job
//! name) are told apart by run id: one run's failure is not hidden by another's
//! later pass. A re-run of failed jobs keeps the run id, so it still replaces the
//! earlier attempt. The limit: a fresh run of the same workflow at the same head
//! (a second event, or a manual dispatch) is a second run id, so an earlier
//! failed run keeps blocking until it is re-run itself. An entry with no
//! parseable URL (a commit status, a pinned-app read without one) shares one
//! bucket, as before.
//!
//! A required check pinned to an app (classic `app_id`, ruleset
//! `integration_id`; null and -1 mean any app) needs a run from that app. The
//! rollup carries no app id, so a pinned check reads
//! `commits/<head>/check-runs`; a failed read refuses (`read_error`). A pinned
//! check can also be a commit status (a workflow posting one with its token),
//! which is not a check run: `commits/<head>/statuses` is read too, and a
//! status counts for the app whose bot posted it (`<slug>[bot]`, the id from
//! `apps/<slug>`). A status a person posted counts for no app.
//!
//! A unit with no file scope (`scope_checked` not true in `deliver.json`) is
//! refused (`deliver_check`): a person merges it. The gate may not be run by a
//! unit process (`ISSUE_DRAIN_MODE=unit`, or `ISSUE_DRAIN_UNIT_FILE` with no mode).
//!
//! A PR already in the merge queue is read first (`gh pr view --json` has no
//! field for it, so it is `isInMergeQueue` through `gh api graphql`; a failed
//! read is a `read_error`). The gate then answers queued without calling
//! `gh pr merge`, which errors for such a PR.
//!
//! `gh pr merge` exiting 0 does not mean merged: on a merge-queue branch it
//! means queued, or auto-merge armed. The PR is read again after the call
//! (state, merge commit, `autoMergeRequest`), and `merged: true` is printed
//! only when GitHub says MERGED. An open PR with an auto-merge request has it
//! turned off (`gh pr merge --disable-auto`, through the write path) and the
//! gate exits 3; if that fails it exits 1 and says it is still armed. Only an
//! open PR with no request is reported as queued.
//!
//! Exit: 0 merged (or already merged, or a dry run that would have); 3 a
//! condition refused, or auto-merge was armed and turned off; 1 the merge call
//! itself failed, or the read after it did (the PR may then have been merged),
//! or auto-merge is still armed; 4 the merge call was accepted but the PR is
//! not merged yet, or was already in the merge queue (queued: `merged: false,
//! queued: true`); 2 bad arguments.

use std::collections::BTreeMap;
use std::process::{Command, Stdio};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::ctx::{Ctx, env_str, read_json};
use crate::error::{Fail, Res};
use crate::gh::{self, Write};
use crate::git;
use crate::profile::same_label;
use regex::Regex;

#[derive(clap::Args)]
pub struct Args {
    /// The unit this PR carries; its files are in <run folder>/units/<n>/.
    #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
    unit: u64,
    /// The pull request to merge.
    #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
    pr: u64,
    /// Judge and print, but do not merge: the merge is printed as WOULD.
    #[arg(long)]
    pub dry_run: bool,
}

/// Labels that park a PR for a person, whatever the profile says.
const ALWAYS_HOLD: [&str; 3] = ["needs-human", "ready-for-human", "security-review"];

/// A value that was read, or the name of what could not be.
pub type Read<T> = Result<T, String>;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum PrState {
    Open,
    Closed,
    Merged,
    Other,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Outcome {
    Pass,
    Fail,
    Pending,
    /// Cancelled, stale, or a word this gate does not know: not a pass.
    Other,
}

/// One run of one check at the head.
#[derive(Clone, Debug)]
pub struct Run {
    pub name: String,
    /// What produced it: the workflow of a check run, `status` for a commit
    /// status. Two sources can use one display name; they are two checks.
    pub source: String,
    /// The Actions workflow run this entry belongs to (from its details URL);
    /// empty for a commit status and for an entry that names none.
    pub run: String,
    pub outcome: Outcome,
    /// The conclusion or state as GitHub words it, for messages.
    pub word: String,
    /// Sorts by start time. A run that has not started sorts newest.
    pub started: String,
}

/// An issue the PR will close, and the repository it is in (`owner/name`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Closing {
    pub number: u64,
    pub repo: String,
}

#[derive(Clone, Debug)]
pub struct PrView {
    pub state: PrState,
    pub head: String,
    /// The PR's head branch, and the repository (`owner/name`) it is in; empty
    /// when GitHub no longer names the repository (a deleted fork).
    pub head_ref: String,
    pub head_repo: String,
    /// GitHub's `mergeStateStatus` and `reviewDecision` (empty: no decision).
    pub merge_state: String,
    pub review_decision: String,
    pub base_ref: String,
    pub labels: Vec<String>,
    pub body: String,
    pub closing: Vec<Closing>,
    pub changed_files: u64,
    pub runs: Vec<Run>,
    /// The merge commit, once GitHub names one.
    pub merge_commit: Option<String>,
}

/// What the unit's queue entry says that the gate needs.
#[derive(Clone, Debug)]
pub struct UnitEntry {
    /// Who reviews its PR; `None` when nobody.
    pub waits_for: Option<String>,
    /// The issues the unit was queued with.
    pub issues: Vec<u64>,
}

#[derive(Clone, Debug)]
pub struct Preflight {
    pub status: String,
    pub verdict: String,
    /// The live head the script read.
    pub head: String,
    /// The commit the newest review record was stamped at; it differs from the
    /// head when the script cleared a base-only sync or a union of records.
    pub reviewed: String,
}

/// A cross-review record comment: who wrote it (login and GitHub's
/// `author_association`) and what its stamp says.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReviewRecord {
    pub author: String,
    pub association: String,
    /// The stamped commit: 40 characters from a marker, 7 to 40 from prose.
    pub sha: String,
    /// The marker's `verdict=`; empty when it carries none.
    pub verdict: String,
}

/// Whether an `author_association` is in the profile's trusted list (case
/// does not matter; an empty association or list trusts no one).
fn is_trusted(trusted: &[String], association: &str) -> bool {
    !association.is_empty() && trusted.iter().any(|t| t.eq_ignore_ascii_case(association))
}

/// A required check: the context, and the app it is pinned to (classic
/// protection `app_id`, ruleset `integration_id`) when it is pinned.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Required {
    pub context: String,
    pub app_id: Option<u64>,
}

impl From<&str> for Required {
    fn from(context: &str) -> Self {
        Required {
            context: context.to_string(),
            app_id: None,
        }
    }
}

/// What the PR after a merge call looks like.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AfterMerge {
    pub state: PrState,
    pub merge_commit: Option<String>,
    /// An auto-merge request is armed on the PR.
    pub auto_merge: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Reviewer {
    pub name: String,
    pub has_output: bool,
    #[serde(default)]
    pub failure_kind: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Proof {
    pub head: String,
    pub reviewers: Vec<Reviewer>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Deliver {
    #[serde(default)]
    pub ok: bool,
    #[serde(default)]
    pub head: String,
    /// The merge base `deliver-check` diffed from. Absent in a report written
    /// before the field existed, which the gate does not accept.
    #[serde(default)]
    pub merge_base: String,
    /// The changed paths that match the profile's risk path rule. `None` for a
    /// report written before the field existed, which the gate does not accept.
    #[serde(default)]
    pub risk_paths_touched: Option<Vec<String>>,
    /// Whether the diff was checked against a file scope. `false` for a unit
    /// with `files: []`, which the gate does not accept; absent in an old report.
    #[serde(default)]
    pub scope_checked: Option<bool>,
}

/// Everything the decision depends on. `Err` is a field that could not be read.
pub struct Facts {
    pub unit: u64,
    pub pr: u64,
    /// `owner/name`, as the run names it.
    pub repo: String,
    pub base: String,
    /// The profile's hold labels.
    pub hold_labels: Vec<String>,
    pub view: Read<PrView>,
    /// The branch `units/<n>/unit.json` says the unit works on.
    pub unit_branch: Read<String>,
    pub required: Read<Vec<Required>>,
    /// The check runs at the head with the app that made each (`source` is
    /// `app:<id>`); read only when a required check is pinned to an app.
    pub app_runs: Read<Vec<Run>>,
    pub preflight: Read<Preflight>,
    /// The newest cross-review record comment on the PR and who wrote it;
    /// `None` when the PR has none.
    pub review_record: Read<Option<ReviewRecord>>,
    /// Every stamped record comment before the newest one. The script can
    /// count any of them toward coverage, so each must be trusted too.
    pub review_earlier: Vec<ReviewRecord>,
    /// The profile's `trusted_associations`: whose record comment counts.
    pub trusted_authors: Vec<String>,
    /// Whether the PR is already in the merge queue.
    pub in_merge_queue: Read<bool>,
    /// Whether `preflight.reviewed` is an ancestor of the head; `None` when it
    /// is the head and nothing was asked.
    pub reviewed_ancestry: Option<Read<bool>>,
    /// For `proof` and `deliver`, `Err` means the file is absent or not the
    /// shape asked for, which has a refusal code of its own.
    pub proof: Read<Proof>,
    pub deliver: Read<Deliver>,
    pub guards_marker: bool,
    pub threads: Read<usize>,
    /// Labels of each issue the unit was queued with and each issue of this
    /// repository the PR will close.
    pub issue_labels: Vec<(u64, Read<Vec<String>>)>,
    pub behind_by: Read<u64>,
    /// The merge base of the PR head and the live base branch, from GitHub.
    pub merge_base: Read<String>,
    /// The unit's queue entry.
    pub unit_entry: Read<UnitEntry>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
    pub code: &'static str,
    pub detail: String,
}

fn refusal(code: &'static str, detail: impl Into<String>) -> Refusal {
    Refusal {
        code,
        detail: detail.into(),
    }
}

/// The newest run of each check in each workflow run, a check being a name from
/// one source. A tie for newest keeps every tied run, so a disagreement counts
/// against the check. A later success of one workflow does not hide a failure of
/// a same-named check of another, nor of a same-named workflow (another run id).
fn newest(runs: &[Run]) -> BTreeMap<(&str, &str), Vec<&Run>> {
    let mut by_check: BTreeMap<(&str, &str), Vec<&Run>> = BTreeMap::new();
    for run in runs {
        by_check
            .entry((run.name.as_str(), run.source.as_str()))
            .or_default()
            .push(run);
    }
    for group in by_check.values_mut() {
        // Newest per workflow run: two workflow files can share a display name,
        // and a later success of one must not hide a failure of the other. A
        // run id tells them apart; entries with none share one bucket.
        let mut latest: BTreeMap<&str, &str> = BTreeMap::new();
        for r in group.iter().copied() {
            let at = latest.entry(r.run.as_str()).or_default();
            if r.started.as_str() > *at {
                *at = r.started.as_str();
            }
        }
        group.retain(|r| latest.get(r.run.as_str()) == Some(&r.started.as_str()));
    }
    by_check
}

/// The names of the reviewers that produced output, in the proof's order.
pub fn reviewers(f: &Facts) -> Vec<String> {
    match &f.proof {
        Ok(proof) => proof
            .reviewers
            .iter()
            .filter(|r| r.has_output)
            .map(|r| r.name.clone())
            .collect(),
        Err(_) => Vec::new(),
    }
}

/// Whether `short` (a full SHA or the abbreviation a review stamp carries, at
/// least 7 characters) names the commit `full`.
fn same_commit(short: &str, full: &str) -> bool {
    short.len() >= 7 && full.len() >= short.len() && full[..short.len()].eq_ignore_ascii_case(short)
}

/// The PR must be the unit's: it is aimed at the profile's base branch, its head
/// branch is the one `unit.json` names and it is in the profile's repository.
/// Nothing else ties `--pr` to `--unit`, so
/// the already-merged answer needs it as much as a merge does.
fn binding(repo: &str, base: &str, unit: u64, pr: u64, view: &PrView, branch: &Read<String>) -> Vec<Refusal> {
    let mut out = Vec::new();
    if view.base_ref != base {
        out.push(refusal(
            "wrong_base",
            format!("PR #{pr} targets '{}', not '{base}'", view.base_ref),
        ));
    }
    match branch {
        Err(what) => out.push(refusal("pr_unit", what.clone())),
        Ok(branch) if branch.is_empty() || *branch != view.head_ref => out.push(refusal(
            "pr_unit",
            format!(
                "PR #{pr} is from branch '{}', not unit {unit}'s branch '{branch}'",
                view.head_ref
            ),
        )),
        Ok(_) => {}
    }
    if !view.head_repo.eq_ignore_ascii_case(repo) {
        let from = if view.head_repo.is_empty() {
            "an unknown repository"
        } else {
            &view.head_repo
        };
        out.push(refusal(
            "pr_unit",
            format!("PR #{pr} comes from {from}, not from {repo}"),
        ));
    }
    out
}

/// Every condition that stops the merge. No I/O. An empty list is the only
/// way to a merge.
pub fn judge(f: &Facts) -> Vec<Refusal> {
    let mut out = Vec::new();
    let n = f.pr;

    let view = match &f.view {
        Ok(view) => Some(view),
        Err(what) => {
            out.push(refusal("read_error", format!("could not read PR #{n}: {what}")));
            None
        }
    };
    let head = view.map(|v| v.head.as_str());

    // 1. open, and aimed at the base branch
    if let Some(v) = view {
        match v.state {
            PrState::Open => {}
            PrState::Closed => out.push(refusal("closed_unmerged", format!("PR #{n} is closed and not merged"))),
            PrState::Merged => out.push(refusal("not_open", format!("PR #{n} is already merged"))),
            PrState::Other => out.push(refusal("not_open", format!("PR #{n} is not open"))),
        }
        out.extend(binding(&f.repo, &f.base, f.unit, n, v, &f.unit_branch));
        // On a merge-queue branch `gh pr merge` enables auto-merge when the PR
        // is not eligible now, and GitHub then merges later with none of this
        // gate's conditions read again. So the PR must be mergeable now.
        // UNSTABLE is only non-required checks failing or pending, which this
        // gate judges itself.
        if v.state == PrState::Open {
            if !matches!(v.merge_state.as_str(), "CLEAN" | "HAS_HOOKS" | "UNSTABLE") {
                out.push(refusal(
                    "not_mergeable",
                    format!("GitHub says PR #{n} is '{}', not mergeable now", v.merge_state),
                ));
            }
            if matches!(v.review_decision.as_str(), "CHANGES_REQUESTED" | "REVIEW_REQUIRED") {
                out.push(refusal(
                    "not_mergeable",
                    format!("PR #{n} review decision is {}", v.review_decision),
                ));
            }
        }
    }

    // 2 and 3. checks at the head
    let pinned = f.required.as_ref().is_ok_and(|r| r.iter().any(|c| c.app_id.is_some()));
    if pinned {
        if let Err(what) = &f.app_runs {
            out.push(refusal("read_error", format!("could not read {what}")));
        }
    }
    match (&f.required, view) {
        (Err(what), _) => out.push(refusal("read_error", format!("could not read {what}"))),
        (Ok(required), Some(v)) => {
            let latest = newest(&v.runs);
            let apps = f.app_runs.as_deref().unwrap_or_default();
            let latest_apps = newest(apps);
            for check in required {
                let context = &check.context;
                // Every source that carries the name must be ok. A check
                // pinned to an app is satisfied only by that app's runs.
                let (groups, from): (Vec<&Vec<&Run>>, String) = match check.app_id {
                    None => (
                        latest
                            .iter()
                            .filter(|((name, _), _)| *name == context.as_str())
                            .map(|(_, group)| group)
                            .collect(),
                        String::new(),
                    ),
                    Some(id) => {
                        let source = format!("app:{id}");
                        (
                            latest_apps
                                .iter()
                                .filter(|((name, src), _)| *name == context.as_str() && *src == source)
                                .map(|(_, group)| group)
                                .collect(),
                            format!(" from app {id}"),
                        )
                    }
                };
                if groups.is_empty() {
                    if check.app_id.is_some() && f.app_runs.is_err() {
                        continue; // the read error is already named
                    }
                    out.push(refusal(
                        "required_check",
                        format!("required check '{context}' has no run{from} at the head"),
                    ));
                    continue;
                }
                if let Some(bad) = groups
                    .iter()
                    .flat_map(|group| group.iter())
                    .find(|r| r.outcome != Outcome::Pass)
                {
                    out.push(refusal(
                        "required_check",
                        format!("required check '{context}'{from} is {} at the head", bad.word),
                    ));
                }
            }
            for ((name, _), group) in &latest {
                if required.iter().any(|r| r.context == *name) {
                    continue;
                }
                if let Some(bad) = group.iter().find(|r| r.outcome == Outcome::Fail) {
                    out.push(refusal("check_failed", format!("check '{name}' is {}", bad.word)));
                }
            }
        }
        (Ok(_), None) => {}
    }

    // 4. the review record
    match &f.preflight {
        Err(what) => out.push(refusal("read_error", format!("could not read {what}"))),
        Ok(p) => {
            if p.status != "clear" || p.verdict != "CLEAN" {
                out.push(refusal(
                    "review",
                    format!("the review record says status '{}', verdict '{}'", p.status, p.verdict),
                ));
            } else if p.head.is_empty() {
                out.push(refusal("review", "the review record names no head commit"));
            } else if head.is_some_and(|h| p.head != h) {
                out.push(refusal(
                    "review",
                    format!("the review record is for {}, not the head", p.head),
                ));
            } else if head.is_some_and(|h| !same_commit(&p.reviewed, h)) {
                // The script clears a head that moved when the records cover it
                // (a base-only sync is cleared by digest equality on purpose),
                // so the commit the record was stamped at is not the head.
                // That is accepted only when the stamped commit is an ancestor
                // of the head; section 5 then takes the proof for the head or for it.
                if p.reviewed.is_empty() {
                    out.push(refusal("review", "the review record names no reviewed commit"));
                } else {
                    match &f.reviewed_ancestry {
                        Some(Ok(true)) => {}
                        Some(Ok(false)) => out.push(refusal(
                            "review",
                            format!(
                                "the review record is for {}, which is not an ancestor of the head",
                                p.reviewed
                            ),
                        )),
                        Some(Err(what)) => out.push(refusal("read_error", format!("could not read {what}"))),
                        None => out.push(refusal(
                            "read_error",
                            "could not read whether the reviewed commit is an ancestor",
                        )),
                    }
                }
            }
        }
    }

    // 4b. who wrote the review record. The review script takes the newest
    // stamped record whoever wrote it, so the gate reads the PR's comments
    // itself: that comment must be by a trusted author and say what the script
    // reported (the commit, and CLEAN).
    match &f.review_record {
        Err(what) => out.push(refusal("read_error", format!("could not read {what}"))),
        Ok(None) => out.push(refusal(
            "review_author",
            format!("PR #{n} has no cross-review record comment"),
        )),
        Ok(Some(rec)) => {
            if !is_trusted(&f.trusted_authors, &rec.association) {
                out.push(refusal(
                    "review_author",
                    format!(
                        "the newest cross-review record on PR #{n} was written by '{}' ({}), who is not a trusted author",
                        rec.author,
                        if rec.association.is_empty() {
                            "no association"
                        } else {
                            &rec.association
                        }
                    ),
                ));
            } else if let Some(p) = f.preflight.as_ref().ok().filter(|p| !p.reviewed.is_empty()) {
                // An empty `reviewed` is refused under 4 already.
                let same = same_commit(&rec.sha, &p.reviewed) || same_commit(&p.reviewed, &rec.sha);
                if !same || rec.verdict != "CLEAN" {
                    out.push(refusal(
                        "review_author",
                        format!(
                            "the newest cross-review record on PR #{n} is stamped at '{}' with verdict '{}', \
                             not at '{}' with CLEAN as the review script reported",
                            rec.sha, rec.verdict, p.reviewed
                        ),
                    ));
                }
            }
        }
    }

    // 4c. the older records. The script unions every stamped record it does
    // not skip (BLOCKED and NEEDS_DECISION cover nothing), so an older record
    // can supply the coverage the newest lacks. Which commits each one covers
    // is the script's range arithmetic, not repeated here: any record that
    // could count must have a trusted author.
    for older in f
        .review_earlier
        .iter()
        .filter(|r| !matches!(r.verdict.as_str(), "BLOCKED" | "NEEDS_DECISION"))
        .filter(|r| !is_trusted(&f.trusted_authors, &r.association))
    {
        out.push(refusal(
            "review_author",
            format!(
                "an older cross-review record on PR #{n}, stamped at '{}', was written by '{}' ({}), who is not a trusted author; \
                 the review script may count it toward coverage, so a person must merge the PR or remove that comment",
                older.sha,
                older.author,
                if older.association.is_empty() {
                    "no association"
                } else {
                    &older.association
                }
            ),
        ));
    }

    // 5. who reviewed. The proof is for the head; on the preflight path that
    // cleared a base-only sync it may be for the stamped ancestor instead, but
    // only once that commit is shown to be an ancestor of the head.
    let ancestor = match (&f.preflight, head) {
        (Ok(p), Some(h))
            if p.status == "clear"
                && p.verdict == "CLEAN"
                && !p.reviewed.is_empty()
                && !same_commit(&p.reviewed, h)
                && matches!(f.reviewed_ancestry, Some(Ok(true))) =>
        {
            Some(p.reviewed.as_str())
        }
        _ => None,
    };
    match &f.proof {
        Err(what) => out.push(refusal("review_proof", what.clone())),
        Ok(proof) => {
            if head.is_some_and(|h| proof.head != h && !ancestor.is_some_and(|a| same_commit(a, &proof.head))) {
                out.push(refusal(
                    "review_proof",
                    match ancestor {
                        Some(a) => format!("the review proof is for '{}', neither the head nor {a}", proof.head),
                        None => format!("the review proof is for '{}', not the head", proof.head),
                    },
                ));
            }
            match proof.reviewers.iter().find(|r| r.name.eq_ignore_ascii_case("codex")) {
                Some(codex) if codex.has_output => {}
                Some(_) => out.push(refusal("review_proof", "codex produced no output")),
                None => out.push(refusal("review_proof", "codex is not among the reviewers")),
            }
            for r in proof.reviewers.iter().filter(|r| !r.name.eq_ignore_ascii_case("codex")) {
                let explained = r.failure_kind.as_deref().is_some_and(|k| !k.trim().is_empty());
                if !r.has_output && !explained {
                    out.push(refusal(
                        "review_proof",
                        format!("reviewer '{}' has no output and no failure_kind", r.name),
                    ));
                }
            }
        }
    }

    // 6. review threads
    match &f.threads {
        Err(what) => out.push(refusal("read_error", format!("could not read {what}"))),
        Ok(0) => {}
        Ok(open) => out.push(refusal("threads_open", format!("{open} unresolved review threads"))),
    }

    // 7. hold labels and the held-for-human note
    let holds = |labels: &[String]| -> Option<String> {
        labels
            .iter()
            .find(|l| {
                f.hold_labels
                    .iter()
                    .map(String::as_str)
                    .chain(ALWAYS_HOLD)
                    .any(|hold| same_label(l, hold))
            })
            .cloned()
    };
    if let Some(v) = view {
        if let Some(label) = holds(&v.labels) {
            out.push(refusal("hold_label", format!("PR #{n} carries '{label}'")));
        }
        if v.body.to_lowercase().contains("held for human") {
            out.push(refusal("hold_label", format!("PR #{n} says it is held for human")));
        }
        for closing in v.closing.iter().filter(|c| !c.repo.eq_ignore_ascii_case(&f.repo)) {
            out.push(refusal(
                "closing_issue_repo",
                format!(
                    "PR #{n} closes {}#{}, which is not in {}; its labels are not read here",
                    closing.repo, closing.number, f.repo
                ),
            ));
        }
        // The PR may close only what the unit was queued with. A cross-repo
        // number means something else here and is refused above.
        if let Ok(entry) = &f.unit_entry {
            for closing in v
                .closing
                .iter()
                .filter(|c| c.repo.eq_ignore_ascii_case(&f.repo) && !entry.issues.contains(&c.number))
            {
                out.push(refusal(
                    "closing_issue_unit",
                    format!(
                        "PR #{n} closes #{}, which is not one of unit {}'s issues",
                        closing.number, f.unit
                    ),
                ));
            }
        }
    }
    for (issue, labels) in &f.issue_labels {
        match labels {
            Err(what) => out.push(refusal("read_error", format!("could not read {what}"))),
            Ok(labels) => {
                if let Some(label) = holds(labels) {
                    out.push(refusal("hold_label", format!("issue #{issue} carries '{label}'")));
                }
            }
        }
    }

    // 8. the base branch's tip
    match &f.behind_by {
        Err(what) => out.push(refusal("read_error", format!("could not read {what}"))),
        Ok(0) => {}
        Ok(behind) => out.push(refusal(
            "behind_base",
            format!("the PR branch is {behind} commits behind {}", f.base),
        )),
    }

    // 8b. the merge queue: `Ok(true)` is not a refusal, `run` answers it
    // (queued) without a merge call; a read that failed is.
    if let Err(what) = &f.in_merge_queue {
        out.push(refusal("read_error", format!("could not read {what}")));
    }

    // 9. something to merge
    if view.is_some_and(|v| v.changed_files == 0) {
        out.push(refusal("empty_diff", format!("PR #{n} changes no files")));
    }

    // 10 and 11. the unit's own checks
    let unit = f.unit;
    match &f.deliver {
        Err(what) => out.push(refusal("deliver_check", what.clone())),
        Ok(d) => {
            if !d.ok {
                out.push(refusal("deliver_check", format!("units/{unit}/deliver.json is not ok")));
            }
            if head.is_some_and(|h| d.head != h) {
                out.push(refusal(
                    "deliver_check",
                    format!("units/{unit}/deliver.json is for '{}', not the head", d.head),
                ));
            }
            if d.scope_checked != Some(true) {
                out.push(refusal(
                    "deliver_check",
                    format!(
                        "unit {unit} has no file scope, so nothing checked what its diff touches; a person merges it"
                    ),
                ));
            }
            match &d.risk_paths_touched {
                None => out.push(refusal(
                    "deliver_check",
                    format!("units/{unit}/deliver.json records no risk_paths_touched; run deliver-check again"),
                )),
                Some(paths) if !paths.is_empty() => out.push(refusal(
                    "risk_path",
                    format!(
                        "the delivered diff touches risk paths ({}); a person merges this unit, this gate does not",
                        paths.join(", ")
                    ),
                )),
                Some(_) => {}
            }
            if d.merge_base.is_empty() {
                out.push(refusal(
                    "deliver_check",
                    format!("units/{unit}/deliver.json records no merge_base; run deliver-check again"),
                ));
            } else {
                match &f.merge_base {
                    Err(what) => out.push(refusal("read_error", format!("could not read {what}"))),
                    Ok(live) if *live != d.merge_base => out.push(refusal(
                        "deliver_check",
                        format!(
                            "units/{unit}/deliver.json diffed from {}, but the PR's merge base with {} is {live}; \
                             run deliver-check again without --base, after fetching",
                            d.merge_base, f.base
                        ),
                    )),
                    Ok(_) => {}
                }
            }
        }
    }
    if !f.guards_marker {
        out.push(refusal(
            "guards_marker",
            format!("units/{unit}/guards-marker is missing"),
        ));
    }

    // 12. a person's merge
    match &f.unit_entry {
        Err(what) => out.push(refusal("read_error", format!("could not read {what}"))),
        Ok(UnitEntry {
            waits_for: Some(who), ..
        }) if !who.trim().is_empty() => out.push(refusal(
            "waits_for",
            format!(
                "unit {unit} waits for {}; a person merges it, this gate does not",
                who.trim()
            ),
        )),
        Ok(_) => {}
    }
    out
}

// ---- parsing what gh printed ----

fn field<'a>(v: &'a Value, key: &str) -> Read<&'a Value> {
    v.get(key).filter(|x| !x.is_null()).ok_or_else(|| format!("no '{key}'"))
}

fn text(v: &Value, key: &str) -> Read<String> {
    field(v, key)?
        .as_str()
        .map(str::to_string)
        .ok_or_else(|| format!("'{key}' is not text"))
}

fn names(v: &Value, key: &str) -> Read<Vec<String>> {
    field(v, key)?
        .as_array()
        .ok_or_else(|| format!("'{key}' is not a list"))?
        .iter()
        .map(|l| text(l, "name"))
        .collect()
}

pub fn is_sha(s: &str) -> bool {
    matches!(s.len(), 40 | 64) && s.bytes().all(|b| b.is_ascii_hexdigit())
}

fn outcome_of_conclusion(conclusion: &str) -> Outcome {
    match conclusion {
        "SUCCESS" | "SKIPPED" | "NEUTRAL" => Outcome::Pass,
        "FAILURE" | "TIMED_OUT" | "ACTION_REQUIRED" | "STARTUP_FAILURE" => Outcome::Fail,
        _ => Outcome::Other,
    }
}

fn parse_run(entry: &Value) -> Read<Run> {
    let upper = |key: &str| {
        entry
            .get(key)
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_uppercase()
    };
    let started = entry.get("startedAt").and_then(Value::as_str).unwrap_or_default();
    let unstarted = started.is_empty() || started.starts_with("0001");
    let is_check_run =
        entry.get("__typename").and_then(Value::as_str) == Some("CheckRun") || entry.get("context").is_none();
    let (name, source, outcome, word) = if is_check_run {
        let name = text(entry, "name")?;
        let source = format!(
            "check:{}",
            entry.get("workflowName").and_then(Value::as_str).unwrap_or_default()
        );
        let conclusion = upper("conclusion");
        if upper("status") != "COMPLETED" {
            (name, source, Outcome::Pending, "pending".to_string())
        } else {
            (
                name,
                source,
                outcome_of_conclusion(&conclusion),
                conclusion.to_lowercase(),
            )
        }
    } else {
        let state = upper("state");
        let outcome = match state.as_str() {
            "SUCCESS" => Outcome::Pass,
            "FAILURE" | "ERROR" => Outcome::Fail,
            "PENDING" | "EXPECTED" => Outcome::Pending,
            _ => Outcome::Other,
        };
        (
            text(entry, "context")?,
            "status".to_string(),
            outcome,
            state.to_lowercase(),
        )
    };
    let started = if !unstarted {
        started.to_string()
    } else if outcome == Outcome::Pending {
        // Not started yet: newer than every run that has.
        "9999-12-31T23:59:59Z".to_string()
    } else {
        String::new()
    };
    let run = entry
        .get("detailsUrl")
        .and_then(Value::as_str)
        .map(run_id_of)
        .unwrap_or_default();
    Ok(Run {
        name,
        source,
        run,
        outcome,
        word,
        started,
    })
}

/// The Actions workflow run id in a check's details URL
/// (`.../actions/runs/<id>/job/<job>`); empty when the URL names none.
fn run_id_of(url: &str) -> String {
    url.split_once("/actions/runs/")
        .map(|(_, rest)| rest.chars().take_while(char::is_ascii_digit).collect())
        .unwrap_or_default()
}

fn pr_state(v: &Value) -> Read<PrState> {
    Ok(match text(v, "state")?.as_str() {
        "OPEN" => PrState::Open,
        "CLOSED" => PrState::Closed,
        "MERGED" => PrState::Merged,
        _ => PrState::Other,
    })
}

/// One `closingIssuesReferences` entry: `{number, repository: {name, owner:
/// {login}}}`. An entry that does not say which repository it is in cannot be
/// looked up, so it does not parse.
fn parse_closing(entry: &Value) -> Read<Closing> {
    let number = entry
        .get("number")
        .and_then(Value::as_u64)
        .ok_or_else(|| "a closing issue has no number".to_string())?;
    let repo = entry.get("repository");
    let name = repo.and_then(|r| r.get("name")).and_then(Value::as_str);
    let owner = repo.and_then(|r| r.pointer("/owner/login")).and_then(Value::as_str);
    match (owner, name) {
        (Some(owner), Some(name)) if !owner.is_empty() && !name.is_empty() => Ok(Closing {
            number,
            repo: format!("{owner}/{name}"),
        }),
        _ => Err(format!(
            "closing issue #{number} does not say which repository it is in"
        )),
    }
}

/// `gh pr view --json state,headRefOid,headRefName,headRepository,
/// headRepositoryOwner,mergeStateStatus,reviewDecision,baseRefName,labels,body,
/// closingIssuesReferences,changedFiles,statusCheckRollup,mergeCommit`.
pub fn parse_view(raw: &str) -> Read<PrView> {
    let v: Value = serde_json::from_str(raw).map_err(|_| "the answer is not JSON".to_string())?;
    let state = pr_state(&v)?;
    let head = text(&v, "headRefOid")?;
    if !is_sha(&head) {
        return Err(format!("the head '{head}' is not a commit SHA"));
    }
    let closing = field(&v, "closingIssuesReferences")?
        .as_array()
        .ok_or("'closingIssuesReferences' is not a list")?
        .iter()
        .map(parse_closing)
        .collect::<Read<Vec<Closing>>>()?;
    let runs = field(&v, "statusCheckRollup")?
        .as_array()
        .ok_or("'statusCheckRollup' is not a list")?
        .iter()
        .map(parse_run)
        .collect::<Read<Vec<Run>>>()?;
    // `reviewDecision` is "" (or null) when nothing requires a review; the key
    // itself must be there. A head repository GitHub no longer names (a deleted
    // fork) is empty, which `binding` refuses.
    let review_decision = match v.get("reviewDecision") {
        Some(Value::Null) => String::new(),
        Some(Value::String(s)) => s.clone(),
        _ => return Err("no 'reviewDecision'".into()),
    };
    let head_repo = match (
        v.pointer("/headRepositoryOwner/login").and_then(Value::as_str),
        v.pointer("/headRepository/name").and_then(Value::as_str),
    ) {
        (Some(owner), Some(name)) if !owner.is_empty() && !name.is_empty() => format!("{owner}/{name}"),
        _ => String::new(),
    };
    Ok(PrView {
        state,
        head,
        head_ref: text(&v, "headRefName")?,
        head_repo,
        merge_state: text(&v, "mergeStateStatus")?,
        review_decision,
        base_ref: text(&v, "baseRefName")?,
        labels: names(&v, "labels")?,
        body: v.get("body").and_then(Value::as_str).unwrap_or_default().to_string(),
        closing,
        changed_files: field(&v, "changedFiles")?
            .as_u64()
            .ok_or("'changedFiles' is not a number")?,
        runs,
        merge_commit: merge_commit_of(&v),
    })
}

/// `mergeCommit.oid` of a PR view; null until the PR is merged.
fn merge_commit_of(v: &Value) -> Option<String> {
    v.pointer("/mergeCommit/oid")
        .and_then(Value::as_str)
        .filter(|oid| is_sha(oid))
        .map(str::to_string)
}

/// An app id as classic protection (`app_id`) and rulesets (`integration_id`)
/// give it. Null, absent and -1 all mean any app.
fn pinned_app(entry: &Value, key: &str) -> Read<Option<u64>> {
    match entry.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(v) => match v.as_i64() {
            Some(-1) => Ok(None),
            Some(id) if id > 0 => Ok(Some(id as u64)),
            _ => Err(format!("a required check has an '{key}' that is not an app id")),
        },
    }
}

/// `gh api repos/{o}/{r}/branches/{base}/protection`: the required checks.
pub fn parse_protection(raw: &str) -> Read<Vec<Required>> {
    let v: Value = serde_json::from_str(raw).map_err(|_| "the answer is not JSON".to_string())?;
    if !v.is_object() {
        return Err("the answer is not an object".into());
    }
    let mut required = Vec::new();
    let Some(checks) = v.get("required_status_checks").filter(|c| !c.is_null()) else {
        return Ok(required);
    };
    let strings = |key: &str| -> Read<Vec<Required>> {
        match checks.get(key) {
            None | Some(Value::Null) => Ok(Vec::new()),
            Some(Value::Array(list)) => list
                .iter()
                .map(|c| {
                    let context = match key {
                        "contexts" => c.as_str(),
                        _ => c.get("context").and_then(Value::as_str),
                    }
                    .ok_or_else(|| format!("a '{key}' entry has no context"))?;
                    let app_id = if key == "contexts" {
                        None
                    } else {
                        pinned_app(c, "app_id")?
                    };
                    Ok(Required {
                        context: context.to_string(),
                        app_id,
                    })
                })
                .collect(),
            Some(_) => Err(format!("'{key}' is not a list")),
        }
    };
    required.extend(strings("contexts")?);
    required.extend(strings("checks")?);
    required.sort();
    required.dedup();
    Ok(required)
}

/// What GitHub answers to a read of classic branch protection on a branch that
/// has none: a 404 whose message says so. A 404 for anything else (no such
/// repository, no right to read it) is not that.
fn is_not_protected(raw: &str) -> bool {
    serde_json::from_str::<Value>(raw).is_ok_and(|v| {
        v.get("message").and_then(Value::as_str) == Some("Branch not protected")
            && v.get("status")
                .is_some_and(|s| s.as_str() == Some("404") || s.as_u64() == Some(404))
    })
}

/// `gh api repos/{o}/{r}/rules/branches/{base} --paginate`: the contexts of
/// every `required_status_checks` rule that applies to the branch. `--paginate`
/// prints one JSON array per page, one after the other.
pub fn parse_rules(raw: &str) -> Read<Vec<Required>> {
    let mut required = Vec::new();
    let mut pages = 0;
    for page in serde_json::Deserializer::from_str(raw).into_iter::<Value>() {
        let page = page.map_err(|_| "the answer is not JSON".to_string())?;
        let rules = page.as_array().ok_or("a page is not a list of rules")?;
        pages += 1;
        for rule in rules {
            let kind = rule.get("type").and_then(Value::as_str).ok_or("a rule has no type")?;
            if kind != "required_status_checks" {
                continue;
            }
            let checks = rule
                .pointer("/parameters/required_status_checks")
                .and_then(Value::as_array)
                .ok_or("a required_status_checks rule lists no checks")?;
            for check in checks {
                let context = check
                    .get("context")
                    .and_then(Value::as_str)
                    .ok_or("a rule's required check has no context")?;
                required.push(Required {
                    context: context.to_string(),
                    app_id: pinned_app(check, "integration_id")?,
                });
            }
        }
    }
    if pages == 0 {
        return Err("the answer is empty".into());
    }
    required.sort();
    required.dedup();
    Ok(required)
}

const THREADS_QUERY: &str = "query($owner:String!,$name:String!,$number:Int!,$after:String){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100,after:$after){pageInfo{hasNextPage endCursor} nodes{isResolved}}}}}";

/// One page of review threads: how many are unresolved, and the cursor of the
/// next page when there is one.
pub fn parse_threads(raw: &str) -> Read<(usize, Option<String>)> {
    let v: Value = serde_json::from_str(raw).map_err(|_| "the answer is not JSON".to_string())?;
    if v.get("errors").is_some_and(|e| !e.is_null()) {
        return Err("GitHub answered with errors".into());
    }
    let threads = v
        .pointer("/data/repository/pullRequest/reviewThreads")
        .filter(|t| t.is_object())
        .ok_or("no review threads in the answer")?;
    let nodes = threads
        .get("nodes")
        .and_then(Value::as_array)
        .ok_or("the threads have no nodes")?;
    let mut open = 0;
    for node in nodes {
        match node.get("isResolved") {
            Some(Value::Bool(true)) => {}
            Some(Value::Bool(false)) => open += 1,
            _ => return Err("a thread has no isResolved".into()),
        }
    }
    let more = threads
        .pointer("/pageInfo/hasNextPage")
        .and_then(Value::as_bool)
        .ok_or("the threads have no pageInfo")?;
    let cursor = threads.pointer("/pageInfo/endCursor").and_then(Value::as_str);
    match (more, cursor) {
        (false, _) => Ok((open, None)),
        (true, Some(c)) if !c.is_empty() => Ok((open, Some(c.to_string()))),
        (true, _) => Err("another page of threads, but no cursor".into()),
    }
}

fn parse_behind(raw: &str) -> Read<u64> {
    let v: Value = serde_json::from_str(raw).map_err(|_| "the answer is not JSON".to_string())?;
    v.get("behind_by")
        .and_then(Value::as_u64)
        .ok_or_else(|| "no behind_by in the answer".to_string())
}

/// `merge_base_commit.sha` of the same compare answer.
fn parse_merge_base(raw: &str) -> Read<String> {
    let v: Value = serde_json::from_str(raw).map_err(|_| "the answer is not JSON".to_string())?;
    v.pointer("/merge_base_commit/sha")
        .and_then(Value::as_str)
        .filter(|sha| is_sha(sha))
        .map(str::to_string)
        .ok_or_else(|| "no merge_base_commit in the answer".to_string())
}

/// `gh pr view --json state,mergeCommit,autoMergeRequest` after the merge
/// call: whether the PR is merged, the merge commit when GitHub names one, and
/// whether an auto-merge request is armed. An open PR whose answer does not
/// say is unreadable, never "not armed".
fn parse_after_merge(raw: &str) -> Read<AfterMerge> {
    let v: Value = serde_json::from_str(raw).map_err(|_| "the answer is not JSON".to_string())?;
    let state = pr_state(&v)?;
    let auto_merge = match v.get("autoMergeRequest") {
        Some(Value::Null) => false,
        Some(_) => true,
        None if state == PrState::Open => return Err("no 'autoMergeRequest' in the answer".into()),
        None => false,
    };
    Ok(AfterMerge {
        state,
        merge_commit: merge_commit_of(&v),
        auto_merge,
    })
}

/// One page of `commits/<head>/check-runs`, or several one after another
/// (`--paginate`): every run with the app that made it (`source` is
/// `app:<id>`). A run without an app id cannot satisfy a pinned check, so it
/// is kept under `app:0`.
pub fn parse_check_runs(raw: &str) -> Read<Vec<Run>> {
    let mut runs = Vec::new();
    let mut pages = 0;
    for page in serde_json::Deserializer::from_str(raw).into_iter::<Value>() {
        let page = page.map_err(|_| "the answer is not JSON".to_string())?;
        let list = page
            .get("check_runs")
            .and_then(Value::as_array)
            .ok_or("a page has no check_runs")?;
        pages += 1;
        for entry in list {
            let name = text(entry, "name")?;
            let id = entry.pointer("/app/id").and_then(Value::as_u64).unwrap_or(0);
            let status = entry.get("status").and_then(Value::as_str).unwrap_or_default();
            let conclusion = entry.get("conclusion").and_then(Value::as_str).unwrap_or_default();
            let started = entry.get("started_at").and_then(Value::as_str).unwrap_or_default();
            let (outcome, word) = if !status.eq_ignore_ascii_case("completed") {
                (Outcome::Pending, "pending".to_string())
            } else {
                (
                    outcome_of_conclusion(&conclusion.to_uppercase()),
                    conclusion.to_lowercase(),
                )
            };
            let started = if !started.is_empty() {
                started.to_string()
            } else if outcome == Outcome::Pending {
                "9999-12-31T23:59:59Z".to_string()
            } else {
                String::new()
            };
            runs.push(Run {
                name,
                source: format!("app:{id}"),
                run: entry
                    .get("details_url")
                    .and_then(Value::as_str)
                    .map(run_id_of)
                    .unwrap_or_default(),
                outcome,
                word,
                started,
            });
        }
    }
    if pages == 0 {
        return Err("the answer is empty".into());
    }
    Ok(runs)
}

/// One page of `commits/<head>/statuses`, or several one after another
/// (`--paginate`): the statuses whose context is in `wanted`, each with the
/// app whose bot posted it (`source` is `app:<id>`). `app_of` turns an app
/// slug into its id; it is asked once per slug, and its failure fails the
/// read. A status posted by anything but an app's bot is kept under `app:0`,
/// which satisfies no pinned check.
pub fn parse_statuses(raw: &str, wanted: &[&str], app_of: &mut dyn FnMut(&str) -> Read<u64>) -> Read<Vec<Run>> {
    let mut runs = Vec::new();
    let mut ids: BTreeMap<String, u64> = BTreeMap::new();
    for page in serde_json::Deserializer::from_str(raw).into_iter::<Value>() {
        let page = page.map_err(|_| "the answer is not JSON".to_string())?;
        let list = page.as_array().ok_or("a page is not a list")?;
        for entry in list {
            let name = text(entry, "context")?;
            if !wanted.contains(&name.as_str()) {
                continue;
            }
            let login = entry
                .pointer("/creator/login")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let is_bot = entry.pointer("/creator/type").and_then(Value::as_str) == Some("Bot");
            let id = match login.strip_suffix("[bot]") {
                Some(slug) if is_bot && !slug.is_empty() => match ids.get(slug) {
                    Some(id) => *id,
                    None => {
                        let id = app_of(slug)?;
                        ids.insert(slug.to_string(), id);
                        id
                    }
                },
                _ => 0,
            };
            let state = entry
                .get("state")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_lowercase();
            let outcome = match state.as_str() {
                "success" => Outcome::Pass,
                "failure" | "error" => Outcome::Fail,
                "pending" => Outcome::Pending,
                _ => Outcome::Other,
            };
            runs.push(Run {
                name,
                source: format!("app:{id}"),
                run: String::new(),
                outcome,
                word: state,
                started: entry
                    .get("created_at")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
            });
        }
    }
    Ok(runs)
}

/// `status` of a compare answer: whether the first commit is an ancestor of
/// (or the same as) the second.
fn parse_ancestry(raw: &str) -> Read<bool> {
    let v: Value = serde_json::from_str(raw).map_err(|_| "the answer is not JSON".to_string())?;
    match v.get("status").and_then(Value::as_str) {
        Some("ahead" | "identical") => Ok(true),
        Some("behind" | "diverged") => Ok(false),
        _ => Err("no usable status in the answer".into()),
    }
}

fn parse_preflight(raw: &str) -> Read<Preflight> {
    let v: Value = serde_json::from_str(raw.trim()).map_err(|_| "its output is not JSON".to_string())?;
    if !v.is_object() {
        return Err("its output is not an object".into());
    }
    let word = |key: &str| v.get(key).and_then(Value::as_str).unwrap_or_default().to_string();
    let reviewed = word("reviewed");
    if !reviewed.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("its 'reviewed' is not a commit".into());
    }
    Ok(Preflight {
        status: word("status"),
        verdict: word("verdict"),
        head: word("head"),
        reviewed,
    })
}

/// What a comment's stamp says: the commit and the marker's verdict. This is
/// the rule `merge_preflight.sh` and `read_stamp.sh` use: a record starts with
/// `## Cross-review` and carries a marker (`<!-- cross-review: sha=<40> ...
/// -->`, which wins) or the prose `Reviewed `<7 to 40 hex>``; a comment with
/// neither is not a record. A verdict outside the vocabulary reads as none.
fn stamp_of(body: &str) -> Option<(String, String)> {
    if !body.starts_with("## Cross-review") {
        return None;
    }
    // One line only, as the script's grep reads it.
    let marker = Regex::new(r"<!-- cross-review: sha=([0-9a-f]{40})[^>\n]*-->").ok()?;
    if let Some(found) = marker.captures(body) {
        // The script reads the last `verdict=` field of the marker and this
        // reads the first, so a marker with more than one has no verdict here:
        // it cannot match a CLEAN report, nor pass as BLOCKED.
        // The script splits fields on ASCII whitespace only, so the pattern
        // does too, and a marker with any non-ASCII character has no verdict.
        let single = found[0].is_ascii() && found[0].matches("verdict=").count() == 1;
        let verdict = Regex::new(r"(?-u:\s)verdict=([A-Z_]+)(?:(?-u:\s)|-->)")
            .ok()
            .filter(|_| single)
            .and_then(|re| re.captures(&found[0]).map(|v| v[1].to_string()))
            .filter(|v| matches!(v.as_str(), "CLEAN" | "FIXES_APPLIED" | "NEEDS_DECISION" | "BLOCKED"))
            .unwrap_or_default();
        return Some((found[1].to_string(), verdict));
    }
    let prose = Regex::new(r"Reviewed `([0-9a-f]{7,40})`").ok()?;
    prose.captures(body).map(|found| (found[1].to_string(), String::new()))
}

/// `gh api repos/{o}/{r}/issues/{pr}/comments --paginate`: the newest comment
/// that is a cross-review record, with its author. The pages come oldest first,
/// one JSON array after another. A comment that is not an object, or a page
/// that is not a list, is an unreadable answer; a body that is absent is just
/// not a record.
pub fn parse_review_record(raw: &str) -> Read<Option<ReviewRecord>> {
    parse_review_records(raw).map(|mut all| all.pop())
}

/// Every stamped record comment, oldest first (the newest is the last).
pub fn parse_review_records(raw: &str) -> Read<Vec<ReviewRecord>> {
    let mut all = Vec::new();
    let mut pages = 0;
    for page in serde_json::Deserializer::from_str(raw).into_iter::<Value>() {
        let page = page.map_err(|_| "the answer is not JSON".to_string())?;
        let list = page.as_array().ok_or("a page is not a list of comments")?;
        pages += 1;
        for comment in list {
            if !comment.is_object() {
                return Err("a comment is not an object".into());
            }
            let body = comment.get("body").and_then(Value::as_str).unwrap_or_default();
            if let Some((sha, verdict)) = stamp_of(body) {
                let word = |pointer: &str| {
                    comment
                        .pointer(pointer)
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string()
                };
                all.push(ReviewRecord {
                    author: word("/user/login"),
                    association: word("/author_association"),
                    sha,
                    verdict,
                });
            }
        }
    }
    if pages == 0 {
        return Err("the answer is empty".into());
    }
    Ok(all)
}

const QUEUE_QUERY: &str = "query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){isInMergeQueue}}}";

/// `isInMergeQueue` of the GraphQL answer. `gh pr view --json` has no such
/// field (gh 2.96.0), so it is read through `gh api graphql`.
pub fn parse_in_queue(raw: &str) -> Read<bool> {
    let v: Value = serde_json::from_str(raw).map_err(|_| "the answer is not JSON".to_string())?;
    if v.get("errors").is_some_and(|e| !e.is_null()) {
        return Err("GitHub answered with errors".into());
    }
    v.pointer("/data/repository/pullRequest/isInMergeQueue")
        .and_then(Value::as_bool)
        .ok_or_else(|| "no isInMergeQueue in the answer".to_string())
}

// ---- reading ----

fn read_gh(args: &[&str]) -> Read<String> {
    gh::read(args).map_err(|rc| format!("gh exit {rc}"))
}

fn threads(repo: &str, pr: u64) -> Read<usize> {
    let (owner, name) = repo.split_once('/').ok_or("the repo is not owner/name")?;
    let (query, number) = (format!("query={THREADS_QUERY}"), format!("number={pr}"));
    let (owner_arg, name_arg) = (format!("owner={owner}"), format!("name={name}"));
    let mut open = 0;
    let mut cursor: Option<String> = None;
    for _ in 0..200 {
        let mut args = vec![
            "api", "graphql", "-f", &query, "-f", &owner_arg, "-f", &name_arg, "-F", &number,
        ];
        let after = cursor.as_ref().map(|c| format!("after={c}"));
        if let Some(after) = &after {
            args.extend(["-f", after.as_str()]);
        }
        let (page, next) = parse_threads(&read_gh(&args)?)?;
        open += page;
        match next {
            None => return Ok(open),
            Some(next) if cursor.as_deref() == Some(next.as_str()) => {
                return Err("the thread pages do not advance".into());
            }
            Some(next) => cursor = Some(next),
        }
    }
    Err("more than 200 pages of threads".into())
}

/// The newest cross-review record comment on the PR, and who wrote it.
fn review_records(repo: &str, pr: u64) -> Read<Vec<ReviewRecord>> {
    read_gh(&[
        "api",
        &format!("repos/{repo}/issues/{pr}/comments?per_page=100"),
        "--paginate",
    ])
    .and_then(|raw| parse_review_records(&raw))
    .map_err(|e| format!("the comments of PR #{pr} ({e})"))
}

/// Whether the PR is in the merge queue.
fn in_merge_queue(repo: &str, pr: u64) -> Read<bool> {
    let (owner, name) = repo.split_once('/').ok_or("the repo is not owner/name")?;
    let (query, number) = (format!("query={QUEUE_QUERY}"), format!("number={pr}"));
    let (owner_arg, name_arg) = (format!("owner={owner}"), format!("name={name}"));
    read_gh(&[
        "api", "graphql", "-f", &query, "-f", &owner_arg, "-f", &name_arg, "-F", &number,
    ])
    .and_then(|raw| parse_in_queue(&raw))
    .map_err(|e| format!("whether PR #{pr} is in the merge queue ({e})"))
}

fn preflight_path() -> Read<String> {
    let set = env_str("ISSUE_DRAIN_MERGE_PREFLIGHT");
    if !set.is_empty() {
        return Ok(set);
    }
    match env_str("HOME") {
        home if home.starts_with('/') => Ok(format!("{home}/.claude/skills/cross-review/scripts/merge_preflight.sh")),
        _ => Err("no HOME to find merge_preflight.sh in".into()),
    }
}

/// Run the review script and read its JSON. Its exit code is ignored: it is 0
/// for a PR nobody reviewed. The script asks local git about the PR's commits,
/// so it runs in the drained repository's checkout (`ISSUE_DRAIN_REPO_DIR`), and
/// only when that checkout's origin is the profile's repo.
fn preflight(ctx: &Ctx, repo: &str, pr: u64) -> Read<Preflight> {
    let what = "merge_preflight.sh";
    let dir = ctx.repo_dir().map_err(|e| format!("{what}: {}", e.msg))?;
    match git::origin_repo(&dir) {
        Some(origin) if origin.eq_ignore_ascii_case(repo) => {}
        other => {
            return Err(format!(
                "{what}: the checkout {} has origin {}, not {repo}",
                dir.display(),
                other.as_deref().unwrap_or("none")
            ));
        }
    }
    let path = preflight_path().map_err(|e| format!("{what}: {e}"))?;
    let out = Command::new(&path)
        .current_dir(&dir)
        .args(["--pr", &pr.to_string(), "--repo", repo, "--json"])
        .env("GH_HOST", "github.com")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .map_err(|e| format!("{what} did not run ({path}: {e})"))?;
    parse_preflight(&String::from_utf8_lossy(&out.stdout)).map_err(|e| format!("{what}: {e}"))
}

/// What `units/<n>/unit.json` says the gate needs: the unit's branch.
#[derive(Deserialize)]
struct UnitBranch {
    #[serde(default)]
    branch: String,
}

fn unit_file<T: serde::de::DeserializeOwned>(ctx: &Ctx, unit: u64, name: &str) -> Read<T> {
    read_json(&ctx.path(&format!("units/{unit}/{name}")))
        .ok_or_else(|| format!("units/{unit}/{name} is missing or not the expected shape"))
}

/// Every read the decision needs. Nothing here decides anything.
fn gather(
    ctx: &Ctx,
    repo: &str,
    unit: u64,
    pr: u64,
    view: Read<PrView>,
    unit_entry: Read<UnitEntry>,
    unit_branch: Read<String>,
) -> Facts {
    let base = ctx.profile.base_branch.clone();
    let head = view.as_ref().ok().map(|v| v.head.clone());
    // The unit's issues and the PR's own, so a hold label on either is seen. An
    // issue in another repository is refused by `judge`, not looked up here by
    // a number that means something else in this repo.
    let mut issues: Vec<u64> = unit_entry.as_ref().map(|u| u.issues.clone()).unwrap_or_default();
    if let Ok(v) = &view {
        issues.extend(
            v.closing
                .iter()
                .filter(|c| c.repo.eq_ignore_ascii_case(repo))
                .map(|c| c.number),
        );
    }
    issues.sort_unstable();
    issues.dedup();

    let required = required_checks(repo, &base);

    // One compare answer, read live from GitHub, gives both how far behind the
    // PR is and the merge base the delivery check must have diffed from.
    let compare = match &head {
        None => Err("its head is unknown".to_string()),
        Some(head) => read_gh(&["api", &format!("repos/{repo}/compare/{base}...{head}")]),
    };
    let behind_by = compare
        .as_ref()
        .map_err(Clone::clone)
        .and_then(|raw| parse_behind(raw))
        .map_err(|e| format!("how far the PR is behind {base} ({e})"));
    let merge_base = compare
        .as_ref()
        .map_err(Clone::clone)
        .and_then(|raw| parse_merge_base(raw))
        .map_err(|e| format!("the merge base of the PR and {base} ({e})"));

    let issue_labels = issues
        .iter()
        .map(|n| {
            let labels = read_gh(&["issue", "view", &n.to_string(), "--repo", repo, "--json", "labels"])
                .and_then(|raw| {
                    let v: Value = serde_json::from_str(&raw).map_err(|_| "the answer is not JSON".to_string())?;
                    names(&v, "labels")
                })
                .map_err(|e| format!("the labels of issue #{n} ({e})"));
            (*n, labels)
        })
        .collect();

    // Only a check pinned to an app needs the runs with their app ids, which
    // the rollup does not carry. A failed read refuses in `judge`.
    let app_runs = match (&required, &head) {
        (Ok(required), Some(head)) if required.iter().any(|c| c.app_id.is_some()) => read_gh(&[
            "api",
            &format!("repos/{repo}/commits/{head}/check-runs?per_page=100"),
            "--paginate",
        ])
        .and_then(|raw| parse_check_runs(&raw))
        .map_err(|e| format!("the check runs at the head ({e})"))
        .and_then(|mut runs| {
            let wanted: Vec<&str> = required
                .iter()
                .filter(|c| c.app_id.is_some())
                .map(|c| c.context.as_str())
                .collect();
            let mut app_of = |slug: &str| {
                let raw = read_gh(&["api", &format!("apps/{slug}")])?;
                let v: Value = serde_json::from_str(&raw).map_err(|_| "the answer is not JSON".to_string())?;
                v.get("id")
                    .and_then(Value::as_u64)
                    .ok_or_else(|| format!("app '{slug}' has no id"))
            };
            let statuses = read_gh(&[
                "api",
                &format!("repos/{repo}/commits/{head}/statuses?per_page=100"),
                "--paginate",
            ])
            .and_then(|raw| parse_statuses(&raw, &wanted, &mut app_of))
            .map_err(|e| format!("the commit statuses at the head ({e})"))?;
            runs.extend(statuses);
            Ok(runs)
        }),
        _ => Ok(Vec::new()),
    };
    let preflight = preflight(ctx, repo, pr);
    let reviewed_ancestry = match (&preflight, &head) {
        (Ok(p), Some(head)) if !p.reviewed.is_empty() && !same_commit(&p.reviewed, head) => Some(
            read_gh(&["api", &format!("repos/{repo}/compare/{}...{head}", p.reviewed)])
                .and_then(|raw| parse_ancestry(&raw))
                .map_err(|e| format!("whether {} is an ancestor of the head ({e})", p.reviewed)),
        ),
        _ => None,
    };

    let mut records = review_records(repo, pr);
    let review_record = records.clone().map(|mut all| all.pop());
    let review_earlier = records
        .as_mut()
        .map(|all| {
            all.pop();
            std::mem::take(all)
        })
        .unwrap_or_default();
    Facts {
        unit,
        pr,
        repo: repo.to_string(),
        base,
        hold_labels: ctx.profile.hold_labels.clone(),
        view,
        unit_branch,
        required,
        app_runs,
        preflight,
        review_record,
        review_earlier,
        trusted_authors: ctx.profile.trusted_associations.clone(),
        in_merge_queue: in_merge_queue(repo, pr),
        reviewed_ancestry,
        proof: unit_file(ctx, unit, "review-proof.json"),
        deliver: unit_file(ctx, unit, "deliver.json"),
        guards_marker: ctx.path(&format!("units/{unit}/guards-marker")).is_file(),
        threads: threads(repo, pr).map_err(|e| format!("the review threads of PR #{pr} ({e})")),
        issue_labels,
        behind_by,
        merge_base,
        unit_entry,
    }
}

/// The contexts the base branch requires: classic branch protection and every
/// ruleset that applies to it. A branch with no classic protection has no
/// classic requirements, but only when the rules were read; any other failure
/// of either read is an error, so a requirement is never assumed absent.
fn required_checks(repo: &str, base: &str) -> Read<Vec<Required>> {
    let classic = {
        let (rc, out) = gh::read_raw(&["api", &format!("repos/{repo}/branches/{base}/protection")]);
        match rc {
            0 => parse_protection(&out),
            _ if is_not_protected(&out) => Ok(Vec::new()),
            rc => Err(format!("gh exit {rc}")),
        }
    };
    let rules = read_gh(&[
        "api",
        &format!("repos/{repo}/rules/branches/{base}?per_page=100"),
        "--paginate",
    ])
    .and_then(|raw| parse_rules(&raw));
    let mut required = classic.map_err(|e| format!("the branch protection of {base} ({e})"))?;
    required.extend(rules.map_err(|e| format!("the branch rules of {base} ({e})"))?);
    required.sort();
    required.dedup();
    Ok(required)
}

fn read_view(repo: &str, pr: u64) -> Read<PrView> {
    let raw = read_gh(&[
        "pr",
        "view",
        &pr.to_string(),
        "--repo",
        repo,
        "--json",
        "state,headRefOid,headRefName,headRepository,headRepositoryOwner,mergeStateStatus,reviewDecision,baseRefName,labels,body,closingIssuesReferences,changedFiles,statusCheckRollup,mergeCommit",
    ])?;
    parse_view(&raw)
}

/// The PR's state, merge commit and auto-merge request, read again after the
/// merge call.
fn read_after_merge(repo: &str, pr: u64) -> Read<AfterMerge> {
    read_gh(&[
        "pr",
        "view",
        &pr.to_string(),
        "--repo",
        repo,
        "--json",
        "state,mergeCommit,autoMergeRequest",
    ])
    .and_then(|raw| parse_after_merge(&raw))
}

fn report(ctx: &Ctx, unit: u64, pr: u64, head: &str, merged: bool, refusals: &[Refusal]) {
    let codes: Vec<&str> = refusals.iter().map(|r| r.code).collect();
    let logged = ctx.event(
        "merge_gate",
        json!({"unit": unit, "pr": pr, "head": head, "merged": merged, "refusals": codes}),
    );
    if let Err(e) = logged {
        eprintln!("issue-drain: warning: the merge-gate result was not logged: {}", e.msg);
    }
}

pub fn run(ctx: &Ctx, args: &Args) -> Res<()> {
    // A unit does not merge, and must not get an answer (or a log line) for it.
    ctx.require_driver("merge-gate")?;
    let repo = ctx.repo()?;
    let (unit, pr) = (args.unit, args.pr);
    let view = read_view(&repo, pr);
    let unit_entry = ctx
        .queue_unit(unit)
        .map(|u| UnitEntry {
            waits_for: u.waits_for,
            issues: u.issues,
        })
        .map_err(|e| format!("the queue entry of unit {unit} ({})", e.msg));
    let unit_branch = unit_file::<UnitBranch>(ctx, unit, "unit.json").map(|u| u.branch);

    // A restarted driver asks again for a PR it already merged. Not for any
    // merged PR: this one must be the unit's, or `--pr` could name any number.
    if let Ok(v) = &view {
        if v.state == PrState::Merged {
            let mut refusals = binding(&repo, &ctx.profile.base_branch, unit, pr, v, &unit_branch);
            if let Err(what) = &unit_entry {
                refusals.push(refusal("read_error", format!("could not read {what}")));
            }
            if !refusals.is_empty() {
                report(ctx, unit, pr, &v.head, false, &refusals);
                let list: Vec<Value> = refusals
                    .iter()
                    .map(|r| json!({"code": r.code, "detail": r.detail}))
                    .collect();
                println!(
                    "{}",
                    json!({"pr": pr, "unit": unit, "head": v.head, "merged": false, "refusals": list, "reviewers": []})
                );
                let codes: Vec<&str> = refusals.iter().map(|r| r.code).collect();
                return Err(Fail::refused(format!(
                    "PR #{pr} was not reported: {}",
                    codes.join(", ")
                )));
            }
            report(ctx, unit, pr, &v.head, true, &[]);
            let out = json!({"pr": pr, "unit": unit, "head": v.head, "merged": true, "already": true, "merge_commit": v.merge_commit, "refusals": [], "reviewers": []});
            println!("{out}");
            return Ok(());
        }
    }

    let facts = gather(ctx, &repo, unit, pr, view, unit_entry, unit_branch);
    let refusals = judge(&facts);
    let head = facts.view.as_ref().map(|v| v.head.clone()).unwrap_or_default();
    let output = |merged: bool| {
        let list: Vec<Value> = refusals
            .iter()
            .map(|r| json!({"code": r.code, "detail": r.detail}))
            .collect();
        json!({"pr": pr, "unit": unit, "head": head, "merged": merged, "refusals": list, "reviewers": reviewers(&facts)})
    };
    // `output` plus the fields only a merge call has.
    let output_with = |merged: bool, extra: Value| {
        let mut out = output(merged);
        if let (Some(out), Value::Object(extra)) = (out.as_object_mut(), extra) {
            out.extend(extra);
        }
        out
    };

    if !refusals.is_empty() {
        report(ctx, unit, pr, &head, false, &refusals);
        println!("{}", output(false));
        let codes: Vec<&str> = refusals.iter().map(|r| r.code).collect();
        return Err(Fail::refused(format!("PR #{pr} was not merged: {}", codes.join(", "))));
    }

    // After exit 4 the documented step is to ask again. `gh pr merge` on a PR
    // that is already in the queue is an error, so say queued without calling it.
    if facts.in_merge_queue == Ok(true) {
        report(ctx, unit, pr, &head, false, &[]);
        println!("{}", output_with(false, json!({"queued": true})));
        return Err(Fail::queued(format!(
            "PR #{pr} is already in the merge queue; ask again later"
        )));
    }

    // The head was read at the start; the merge names it.
    match gh::write(
        ctx,
        &Write::MergePr {
            number: pr,
            head: &head,
        },
    ) {
        Ok(written) if !written.called => {
            // A dry run: nothing was sent.
            report(ctx, unit, pr, &head, false, &[]);
            println!("{}", output(false));
            Ok(())
        }
        Ok(_) => {
            // Exit 0 from `gh pr merge` also means "queued" on a merge-queue
            // branch, so ask GitHub what became of the PR.
            match read_after_merge(&repo, pr) {
                Ok(AfterMerge {
                    state: PrState::Merged,
                    merge_commit,
                    ..
                }) => {
                    report(ctx, unit, pr, &head, true, &[]);
                    println!("{}", output_with(true, json!({"merge_commit": merge_commit})));
                    Ok(())
                }
                Ok(AfterMerge {
                    state: PrState::Open,
                    auto_merge: true,
                    ..
                }) => {
                    // GitHub armed auto-merge instead of merging: it would merge
                    // later with none of this gate's conditions read again.
                    report(ctx, unit, pr, &head, false, &[]);
                    match gh::write(ctx, &Write::DisableAutoMerge { number: pr }) {
                        Ok(_) => {
                            println!("{}", output_with(false, json!({"auto_merge_disabled": true})));
                            Err(Fail::refused(format!(
                                "PR #{pr}: the merge call armed auto-merge instead of merging; auto-merge has been turned off"
                            )))
                        }
                        Err(_) => {
                            println!("{}", output_with(false, json!({"auto_merge_armed": true})));
                            Err(Fail::failed(format!(
                                "PR #{pr}: the merge call armed auto-merge and turning it off failed; it is STILL ARMED: run `gh pr merge {pr} --disable-auto`"
                            )))
                        }
                    }
                }
                Ok(AfterMerge {
                    state: PrState::Open, ..
                }) => {
                    report(ctx, unit, pr, &head, false, &[]);
                    println!("{}", output_with(false, json!({"queued": true})));
                    Err(Fail::queued(format!(
                        "PR #{pr}: the merge call was accepted but the PR is Open, not merged (queued?); ask again later"
                    )))
                }
                Ok(AfterMerge { state, .. }) => {
                    report(ctx, unit, pr, &head, false, &[]);
                    println!("{}", output_with(false, json!({"state_unknown": true})));
                    Err(Fail::failed(format!(
                        "PR #{pr}: the merge call exited 0 but the PR is {state:?}, neither merged nor open"
                    )))
                }
                Err(what) => {
                    report(ctx, unit, pr, &head, false, &[]);
                    println!("{}", output_with(false, json!({"state_unknown": true})));
                    Err(Fail::failed(format!(
                        "PR #{pr}: the merge call exited 0 but the PR could not be read afterwards ({what}); it may have been merged"
                    )))
                }
            }
        }
        Err(fail) => {
            report(ctx, unit, pr, &head, false, &[]);
            println!("{}", output(false));
            Err(fail)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HEAD: &str = "0123456789abcdef0123456789abcdef01234567";
    const BASE_TIP: &str = "1dc973bdb697cc0a92e481f73e5d6599b8f7be66";

    fn run_of(name: &str, outcome: Outcome, word: &str, started: &str) -> Run {
        from_source(name, "check:CI", outcome, word, started)
    }

    fn from_source(name: &str, source: &str, outcome: Outcome, word: &str, started: &str) -> Run {
        Run {
            name: name.into(),
            source: source.into(),
            run: String::new(),
            outcome,
            word: word.into(),
            started: started.into(),
        }
    }

    fn pass(name: &str) -> Run {
        run_of(name, Outcome::Pass, "success", "2026-11-21T01:00:00Z")
    }

    fn reviewer(name: &str, has_output: bool) -> Reviewer {
        Reviewer {
            name: name.into(),
            has_output,
            failure_kind: None,
        }
    }

    fn clear() -> Facts {
        Facts {
            unit: 3,
            pr: 12,
            repo: "example/tidepool".into(),
            base: "develop".into(),
            hold_labels: vec!["blocked".into()],
            view: Ok(PrView {
                state: PrState::Open,
                head: HEAD.into(),
                head_ref: "fix/tide".into(),
                head_repo: "example/tidepool".into(),
                merge_state: "CLEAN".into(),
                review_decision: String::new(),
                base_ref: "develop".into(),
                labels: vec!["bug".into()],
                body: "Fixes #5".into(),
                closing: vec![Closing {
                    number: 5,
                    repo: "example/tidepool".into(),
                }],
                changed_files: 2,
                runs: vec![pass("build"), pass("lint")],
                merge_commit: None,
            }),
            unit_branch: Ok("fix/tide".into()),
            required: Ok(vec!["build".into()]),
            app_runs: Ok(Vec::new()),
            reviewed_ancestry: None,
            preflight: Ok(Preflight {
                status: "clear".into(),
                verdict: "CLEAN".into(),
                head: HEAD.into(),
                reviewed: HEAD.into(),
            }),
            review_earlier: Vec::new(),
            review_record: Ok(Some(ReviewRecord {
                author: "gabe".into(),
                association: "OWNER".into(),
                sha: HEAD.into(),
                verdict: "CLEAN".into(),
            })),
            trusted_authors: vec!["OWNER".into(), "MEMBER".into()],
            in_merge_queue: Ok(false),
            proof: Ok(Proof {
                head: HEAD.into(),
                reviewers: vec![reviewer("codex", true), reviewer("kimi", true)],
            }),
            deliver: Ok(Deliver {
                ok: true,
                head: HEAD.into(),
                merge_base: BASE_TIP.into(),
                risk_paths_touched: Some(Vec::new()),
                scope_checked: Some(true),
            }),
            guards_marker: true,
            threads: Ok(0),
            issue_labels: vec![(5, Ok(vec!["bug".into()]))],
            behind_by: Ok(0),
            merge_base: Ok(BASE_TIP.into()),
            unit_entry: Ok(UnitEntry {
                waits_for: None,
                issues: vec![5],
            }),
        }
    }

    fn contexts(required: &[Required]) -> Vec<&str> {
        required.iter().map(|r| r.context.as_str()).collect()
    }

    fn entry(f: &mut Facts) -> &mut UnitEntry {
        f.unit_entry.as_mut().unwrap()
    }

    fn codes(f: &Facts) -> Vec<&'static str> {
        judge(f).iter().map(|r| r.code).collect()
    }

    fn view(f: &mut Facts) -> &mut PrView {
        f.view.as_mut().unwrap()
    }

    #[test]
    fn all_clear_has_no_refusal() {
        let f = clear();
        assert!(judge(&f).is_empty());
        assert_eq!(reviewers(&f), ["codex", "kimi"]);
    }

    #[test]
    fn an_unreadable_pr_is_a_read_error() {
        let mut f = clear();
        f.view = Err("gh exit 1".into());
        f.behind_by = Err("unknown".into());
        let found = codes(&f);
        assert!(found.contains(&"read_error"), "{found:?}");
        assert!(!found.contains(&"review_proof"), "no head means no head comparison");
    }

    #[test]
    fn a_closed_pr_is_closed_unmerged() {
        let mut f = clear();
        view(&mut f).state = PrState::Closed;
        assert_eq!(codes(&f), ["closed_unmerged"]);
    }

    #[test]
    fn a_merged_or_odd_state_is_not_open() {
        let mut f = clear();
        view(&mut f).state = PrState::Merged;
        assert_eq!(codes(&f), ["not_open"]);
        view(&mut f).state = PrState::Other;
        assert_eq!(codes(&f), ["not_open"]);
    }

    #[test]
    fn another_base_branch_is_refused() {
        let mut f = clear();
        view(&mut f).base_ref = "main".into();
        assert_eq!(codes(&f), ["wrong_base"]);
    }

    #[test]
    fn a_required_check_that_failed_or_is_missing_refuses_naming_it() {
        let mut f = clear();
        f.required = Ok(vec!["build".into(), "e2e".into()]);
        let found = judge(&f);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].code, "required_check");
        assert!(found[0].detail.contains("'e2e'"), "{}", found[0].detail);

        view(&mut f).runs = vec![run_of("build", Outcome::Fail, "failure", "2026-11-21T01:00:00Z")];
        f.required = Ok(vec!["build".into()]);
        let found = judge(&f);
        assert_eq!(found.len(), 1);
        assert!(found[0].detail.contains("failure"), "{}", found[0].detail);
    }

    #[test]
    fn a_required_check_whose_newest_run_is_pending_refuses_though_an_older_one_passed() {
        let mut f = clear();
        view(&mut f).runs = vec![
            run_of("build", Outcome::Pass, "success", "2026-11-20T01:00:00Z"),
            run_of("build", Outcome::Pending, "pending", "2026-11-21T01:00:00Z"),
        ];
        assert_eq!(codes(&f), ["required_check"]);
        // And the other way: an old failure does not count against a newer pass.
        view(&mut f).runs = vec![
            run_of("build", Outcome::Fail, "failure", "2026-11-20T01:00:00Z"),
            run_of("build", Outcome::Pass, "success", "2026-11-21T01:00:00Z"),
        ];
        assert!(codes(&f).is_empty());
    }

    #[test]
    fn a_cancelled_run_is_not_a_pass_for_a_required_check() {
        let mut f = clear();
        view(&mut f).runs = vec![run_of("build", Outcome::Other, "cancelled", "2026-11-21T01:00:00Z")];
        assert_eq!(codes(&f), ["required_check"]);
    }

    #[test]
    fn a_cancelled_optional_check_does_not_refuse_and_a_failed_one_does() {
        let mut f = clear();
        view(&mut f)
            .runs
            .push(run_of("docs", Outcome::Other, "cancelled", "2026-11-21T02:00:00Z"));
        view(&mut f)
            .runs
            .push(run_of("slow", Outcome::Pending, "pending", "2026-11-21T02:00:00Z"));
        assert!(codes(&f).is_empty());
        view(&mut f)
            .runs
            .push(run_of("docs", Outcome::Fail, "failure", "2026-11-21T03:00:00Z"));
        let found = judge(&f);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].code, "check_failed");
        assert!(found[0].detail.contains("docs"));
    }

    #[test]
    fn unreadable_protection_is_a_read_error() {
        let mut f = clear();
        f.required = Err("the branch protection of develop (gh exit 1)".into());
        assert_eq!(codes(&f), ["read_error"]);
    }

    #[test]
    fn a_review_that_is_not_clean_refuses() {
        let mut f = clear();
        f.preflight = Ok(Preflight {
            status: "stale".into(),
            verdict: "CLEAN".into(),
            head: HEAD.into(),
            reviewed: HEAD.into(),
        });
        assert_eq!(codes(&f), ["review"]);
        f.preflight = Ok(Preflight {
            status: "clear".into(),
            verdict: "FIXES_APPLIED".into(),
            head: HEAD.into(),
            reviewed: HEAD.into(),
        });
        assert_eq!(codes(&f), ["review"]);
    }

    #[test]
    fn a_review_record_with_status_clear_but_no_verdict_refuses() {
        let mut f = clear();
        f.preflight = Ok(Preflight {
            status: "clear".into(),
            verdict: String::new(),
            head: HEAD.into(),
            reviewed: HEAD.into(),
        });
        let found = judge(&f);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].code, "review");
        assert!(found[0].detail.contains("status 'clear'"), "{}", found[0].detail);
    }

    #[test]
    fn a_review_record_for_another_head_refuses() {
        let mut f = clear();
        f.preflight.as_mut().unwrap().head = "f".repeat(40);
        assert_eq!(codes(&f), ["review"]);
    }

    #[test]
    fn an_unreadable_review_is_a_read_error() {
        let mut f = clear();
        f.preflight = Err("merge_preflight.sh: its output is not JSON".into());
        assert_eq!(codes(&f), ["read_error"]);
    }

    #[test]
    fn the_review_proof_must_match_the_head_and_include_codex_output() {
        let mut f = clear();
        f.proof = Err("units/3/review-proof.json is missing".into());
        assert_eq!(codes(&f), ["review_proof"]);

        let mut f = clear();
        f.proof.as_mut().unwrap().head = "f".repeat(40);
        assert_eq!(codes(&f), ["review_proof"]);

        let mut f = clear();
        f.proof.as_mut().unwrap().reviewers[0].has_output = false;
        assert_eq!(codes(&f), ["review_proof"]);

        let mut f = clear();
        f.proof.as_mut().unwrap().reviewers.remove(0);
        assert_eq!(codes(&f), ["review_proof"]);
    }

    #[test]
    fn a_silent_reviewer_needs_a_failure_kind_and_codex_alone_is_enough() {
        let mut f = clear();
        f.proof.as_mut().unwrap().reviewers[1].has_output = false;
        assert_eq!(codes(&f), ["review_proof"]);
        f.proof.as_mut().unwrap().reviewers[1].failure_kind = Some("  ".into());
        assert_eq!(codes(&f), ["review_proof"]);
        f.proof.as_mut().unwrap().reviewers[1].failure_kind = Some("quota".into());
        assert!(codes(&f).is_empty());
        assert_eq!(reviewers(&f), ["codex"]);
    }

    #[test]
    fn open_threads_and_unreadable_threads_refuse() {
        let mut f = clear();
        f.threads = Ok(2);
        let found = judge(&f);
        assert_eq!(found[0].code, "threads_open");
        assert_eq!(found[0].detail, "2 unresolved review threads");
        f.threads = Err("the review threads (gh exit 1)".into());
        assert_eq!(codes(&f), ["read_error"]);
    }

    #[test]
    fn a_hold_label_on_the_pr_refuses_whatever_the_case() {
        let mut f = clear();
        view(&mut f).labels = vec!["Blocked".into()];
        assert_eq!(codes(&f), ["hold_label"]);
        for label in ALWAYS_HOLD {
            view(&mut f).labels = vec![label.into()];
            assert_eq!(codes(&f), ["hold_label"], "{label}");
        }
    }

    #[test]
    fn a_hold_label_on_a_linked_issue_refuses() {
        let mut f = clear();
        f.issue_labels = vec![(5, Ok(vec!["bug".into(), "security-review".into()]))];
        let found = judge(&f);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].code, "hold_label");
        assert!(found[0].detail.contains("issue #5"), "{}", found[0].detail);
        f.issue_labels = vec![(5, Err("the labels of issue #5 (gh exit 1)".into()))];
        assert_eq!(codes(&f), ["read_error"]);
    }

    #[test]
    fn a_body_that_says_held_for_human_refuses() {
        let mut f = clear();
        view(&mut f).body = "Done.\n\nHeld For Human review.".into();
        assert_eq!(codes(&f), ["hold_label"]);
    }

    #[test]
    fn a_branch_behind_the_base_refuses() {
        let mut f = clear();
        f.behind_by = Ok(3);
        assert_eq!(codes(&f), ["behind_base"]);
        f.behind_by = Err("how far (gh exit 1)".into());
        assert_eq!(codes(&f), ["read_error"]);
    }

    #[test]
    fn a_pr_that_changes_no_file_refuses() {
        let mut f = clear();
        view(&mut f).changed_files = 0;
        assert_eq!(codes(&f), ["empty_diff"]);
    }

    #[test]
    fn the_deliver_check_must_be_ok_and_for_the_head() {
        let mut f = clear();
        f.deliver = Err("units/3/deliver.json is missing".into());
        assert_eq!(codes(&f), ["deliver_check"]);
        let mut f = clear();
        f.deliver.as_mut().unwrap().ok = false;
        assert_eq!(codes(&f), ["deliver_check"]);
        let mut f = clear();
        f.deliver.as_mut().unwrap().head = "f".repeat(40);
        assert_eq!(codes(&f), ["deliver_check"]);
    }

    #[test]
    fn a_delivery_that_touched_a_risk_path_is_refused() {
        let mut f = clear();
        f.deliver.as_mut().unwrap().risk_paths_touched =
            Some(vec!["src/billing/a.ts".into(), "src/crisis/b.ts".into()]);
        let found = judge(&f);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].code, "risk_path");
        assert!(
            found[0].detail.contains("src/billing/a.ts, src/crisis/b.ts"),
            "{}",
            found[0].detail
        );
        let mut f = clear();
        f.deliver.as_mut().unwrap().risk_paths_touched = None;
        assert_eq!(codes(&f), ["deliver_check"]);
    }

    #[test]
    fn a_unit_that_waits_for_someone_is_refused_whatever_else_is_clear() {
        let mut f = clear();
        entry(&mut f).waits_for = Some(" clinical review ".into());
        let found = judge(&f);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].code, "waits_for");
        assert!(found[0].detail.contains("clinical review"), "{}", found[0].detail);
        entry(&mut f).waits_for = Some("  ".into());
        assert!(codes(&f).is_empty());
        f.unit_entry = Err("the queue entry of unit 3 (no queue)".into());
        assert_eq!(codes(&f), ["read_error"]);
    }

    #[test]
    fn the_deliver_check_must_name_the_live_merge_base() {
        let mut f = clear();
        f.deliver.as_mut().unwrap().merge_base = "2".repeat(40);
        assert_eq!(codes(&f), ["deliver_check"]);
        let mut f = clear();
        f.deliver.as_mut().unwrap().merge_base = String::new();
        assert_eq!(codes(&f), ["deliver_check"]);
        let mut f = clear();
        f.merge_base = Err("the merge base (gh exit 1)".into());
        assert_eq!(codes(&f), ["read_error"]);
    }

    #[test]
    fn an_issue_in_another_repository_is_refused_and_a_case_difference_is_not() {
        let mut f = clear();
        view(&mut f).closing[0].repo = "Example/Tidepool".into();
        assert!(codes(&f).is_empty());
        view(&mut f).closing.push(Closing {
            number: 9,
            repo: "other/elsewhere".into(),
        });
        let found = judge(&f);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].code, "closing_issue_repo");
        assert!(found[0].detail.contains("other/elsewhere#9"), "{}", found[0].detail);
    }

    #[test]
    fn the_guards_marker_must_exist() {
        let mut f = clear();
        f.guards_marker = false;
        assert_eq!(codes(&f), ["guards_marker"]);
    }

    #[test]
    fn several_refusals_are_all_reported_together() {
        let mut f = clear();
        f.threads = Ok(1);
        f.guards_marker = false;
        f.behind_by = Ok(1);
        view(&mut f).labels = vec!["needs-human".into()];
        view(&mut f).changed_files = 0;
        assert_eq!(
            codes(&f),
            [
                "threads_open",
                "hold_label",
                "behind_base",
                "empty_diff",
                "guards_marker"
            ]
        );
    }

    #[test]
    fn a_view_parses_checks_of_both_kinds_and_keeps_unstarted_runs_newest() {
        let raw = json!({
            "state": "OPEN", "headRefOid": HEAD, "headRefName": "fix/tide", "headRepository": {"name": "tidepool"}, "headRepositoryOwner": {"login": "example"}, "mergeStateStatus": "CLEAN", "reviewDecision": "", "baseRefName": "develop", "body": "x",
            "labels": [{"name": "bug"}], "closingIssuesReferences": [{"number": 5, "repository": {"name": "tidepool", "owner": {"login": "example"}}}], "changedFiles": 1,
            "statusCheckRollup": [
                {"__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS", "startedAt": "2026-11-20T01:00:00Z"},
                {"__typename": "CheckRun", "name": "build", "status": "QUEUED", "conclusion": "", "startedAt": "0001-01-01T00:00:00Z"},
                {"__typename": "StatusContext", "context": "ci/x", "state": "FAILURE", "startedAt": "2026-11-20T01:00:00Z"}
            ]
        })
        .to_string();
        let v = parse_view(&raw).unwrap();
        assert_eq!(v.runs.len(), 3);
        assert_eq!(v.closing.len(), 1);
        assert_eq!(
            (v.closing[0].number, v.closing[0].repo.as_str()),
            (5, "example/tidepool")
        );
        let mut f = clear();
        f.view = Ok(v);
        f.required = Ok(vec!["build".into()]);
        let found = judge(&f);
        assert!(
            found
                .iter()
                .any(|r| r.code == "required_check" && r.detail.contains("pending")),
            "{found:?}"
        );
        assert!(found.iter().any(|r| r.code == "check_failed"), "{found:?}");
    }

    #[test]
    fn a_view_missing_a_field_or_with_a_bad_head_does_not_parse() {
        let good = json!({
            "state": "OPEN", "headRefOid": HEAD, "headRefName": "fix/tide", "headRepository": {"name": "tidepool"}, "headRepositoryOwner": {"login": "example"}, "mergeStateStatus": "CLEAN", "reviewDecision": "", "baseRefName": "develop", "body": "",
            "labels": [], "closingIssuesReferences": [], "changedFiles": 1, "statusCheckRollup": []
        });
        assert!(parse_view(&good.to_string()).is_ok());
        for key in [
            "state",
            "headRefOid",
            "baseRefName",
            "labels",
            "closingIssuesReferences",
            "changedFiles",
            "statusCheckRollup",
        ] {
            let mut bad = good.clone();
            bad.as_object_mut().unwrap().remove(key);
            assert!(parse_view(&bad.to_string()).is_err(), "{key}");
        }
        let mut bad = good.clone();
        bad["headRefOid"] = json!("--squash");
        assert!(parse_view(&bad.to_string()).is_err());
        assert!(parse_view("nope").is_err());
    }

    #[test]
    fn protection_reads_both_shapes_and_nothing_else_is_assumed() {
        let raw = r#"{"required_status_checks":{"contexts":["a","b"],"checks":[{"context":"b"},{"context":"c","app_id":1}]}}"#;
        assert_eq!(contexts(&parse_protection(raw).unwrap()), ["a", "b", "c"]);
        assert!(parse_protection("{}").unwrap().is_empty());
        assert!(parse_protection("[]").is_err());
        assert!(parse_protection(r#"{"required_status_checks":{"contexts":"a"}}"#).is_err());
    }

    #[test]
    fn threads_count_unresolved_and_follow_the_cursor() {
        let page = |nodes: Value, more: bool, cursor: Value| {
            json!({"data": {"repository": {"pullRequest": {"reviewThreads": {
                "pageInfo": {"hasNextPage": more, "endCursor": cursor}, "nodes": nodes}}}}})
            .to_string()
        };
        let both = json!([{"isResolved": true}, {"isResolved": false}]);
        let (open, next) = parse_threads(&page(both, true, json!("c1"))).unwrap();
        assert_eq!((open, next.as_deref()), (1, Some("c1")));
        let (open, next) = parse_threads(&page(json!([{"isResolved": false}]), false, Value::Null)).unwrap();
        assert_eq!((open, next), (1, None));
        assert!(parse_threads(&page(json!([{"isResolved": false}]), true, Value::Null)).is_err());
        assert!(parse_threads(&page(json!([{}]), false, Value::Null)).is_err());
        assert!(parse_threads(r#"{"data":{"repository":{"pullRequest":null}}}"#).is_err());
        assert!(parse_threads(r#"{"errors":[{}],"data":{}}"#).is_err());
    }

    #[test]
    fn a_later_success_of_one_workflow_does_not_hide_a_failure_of_a_same_named_check() {
        let mut f = clear();
        view(&mut f).runs = vec![
            from_source("build", "check:A", Outcome::Fail, "failure", "2026-11-21T01:00:00Z"),
            from_source("build", "check:B", Outcome::Pass, "success", "2026-11-21T02:00:00Z"),
        ];
        let found = judge(&f);
        assert_eq!(found.len(), 1, "{found:?}");
        assert_eq!(found[0].code, "required_check");
        assert!(found[0].detail.contains("failure"), "{}", found[0].detail);
        // Both sources ok: the required check is satisfied.
        view(&mut f).runs[0].outcome = Outcome::Pass;
        assert!(codes(&f).is_empty());
        // A name that is not required refuses when any source's newest run failed.
        view(&mut f).runs = vec![
            pass("build"),
            from_source("docs", "check:A", Outcome::Fail, "failure", "2026-11-21T01:00:00Z"),
            from_source("docs", "check:B", Outcome::Pass, "success", "2026-11-21T02:00:00Z"),
        ];
        assert_eq!(codes(&f), ["check_failed"]);
        // A newer run in the same source still replaces an older one.
        view(&mut f).runs[1].started = "2026-11-21T03:00:00Z".into();
        view(&mut f).runs[1].outcome = Outcome::Pass;
        assert!(codes(&f).is_empty());
    }

    #[test]
    fn a_check_run_and_a_commit_status_of_one_name_are_two_checks() {
        let raw = json!({
            "state": "OPEN", "headRefOid": HEAD, "headRefName": "fix/tide", "headRepository": {"name": "tidepool"}, "headRepositoryOwner": {"login": "example"}, "mergeStateStatus": "CLEAN", "reviewDecision": "", "baseRefName": "develop", "body": "",
            "labels": [], "closingIssuesReferences": [], "changedFiles": 1,
            "statusCheckRollup": [
                {"__typename": "CheckRun", "name": "build", "workflowName": "CI", "status": "COMPLETED", "conclusion": "SUCCESS", "startedAt": "2026-11-21T03:00:00Z"},
                {"__typename": "CheckRun", "name": "build", "workflowName": "Other", "status": "COMPLETED", "conclusion": "FAILURE", "startedAt": "2026-11-21T01:00:00Z"},
                {"__typename": "StatusContext", "context": "build", "state": "SUCCESS", "startedAt": "2026-11-21T04:00:00Z"}
            ]
        })
        .to_string();
        let v = parse_view(&raw).unwrap();
        let sources: Vec<&str> = v.runs.iter().map(|r| r.source.as_str()).collect();
        assert_eq!(sources, ["check:CI", "check:Other", "status"]);
        let mut f = clear();
        f.view = Ok(v);
        assert_eq!(codes(&f), ["required_check"]);
    }

    #[test]
    fn a_review_record_that_names_no_head_refuses() {
        let mut f = clear();
        f.preflight.as_mut().unwrap().head = String::new();
        let found = judge(&f);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].code, "review");
        assert!(found[0].detail.contains("no head"), "{}", found[0].detail);
        let raw = r#"{"status":"clear","verdict":"CLEAN"}"#;
        assert_eq!(parse_preflight(raw).unwrap().head, "");
    }

    #[test]
    fn a_pr_may_close_only_issues_of_its_unit_and_the_units_issues_are_read_for_holds() {
        let mut f = clear();
        view(&mut f).closing.push(Closing {
            number: 9,
            repo: "example/tidepool".into(),
        });
        let found = judge(&f);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].code, "closing_issue_unit");
        assert!(found[0].detail.contains("#9"), "{}", found[0].detail);
        // An issue of the unit that the PR does not close still holds the merge.
        let mut f = clear();
        f.issue_labels = vec![(5, Ok(vec!["bug".into()])), (6, Ok(vec!["blocked".into()]))];
        entry(&mut f).issues = vec![5, 6];
        let found = judge(&f);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].code, "hold_label");
        assert!(found[0].detail.contains("issue #6"), "{}", found[0].detail);
        // Even when the PR itself could not be read.
        f.view = Err("gh exit 1".into());
        assert!(codes(&f).contains(&"hold_label"));
    }

    #[test]
    fn rules_give_the_contexts_of_every_required_status_checks_rule_across_pages() {
        let page1 = json!([
            {"type": "deletion", "ruleset_source_type": "Repository", "ruleset_source": "o/r", "ruleset_id": 1},
            {"type": "required_status_checks", "parameters": {
                "strict_required_status_checks_policy": false,
                "required_status_checks": [{"context": "b", "integration_id": 15368}, {"context": "a"}]}}
        ]);
        let page2 = json!([{"type": "required_status_checks", "parameters": {
            "required_status_checks": [{"context": "c"}, {"context": "a"}]}}]);
        assert_eq!(
            contexts(&parse_rules(&format!("{page1}\n{page2}")).unwrap()),
            ["a", "b", "c"]
        );
        assert!(parse_rules("[]").unwrap().is_empty());
        assert!(parse_rules("[{\"type\":\"deletion\"}]").unwrap().is_empty());
        for bad in [
            "",
            "nope",
            "{}",
            r#"[{"parameters":{}}]"#,
            r#"[{"type":"required_status_checks"}]"#,
            r#"[{"type":"required_status_checks","parameters":{"required_status_checks":[{"integration_id":1}]}}]"#,
        ] {
            assert!(parse_rules(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn only_the_not_protected_answer_is_no_classic_protection() {
        let body = |message: &str, status: &str| json!({"message": message, "status": status}).to_string();
        assert!(is_not_protected(&body("Branch not protected", "404")));
        assert!(!is_not_protected(&body("Not Found", "404")));
        assert!(!is_not_protected(&body("Branch not protected", "403")));
        assert!(!is_not_protected(""));
        assert!(!is_not_protected("Branch not protected"));
    }

    #[test]
    fn a_view_carries_the_merge_commit_when_github_names_one() {
        let mut raw = json!({
            "state": "MERGED", "headRefOid": HEAD, "headRefName": "fix/tide", "headRepository": {"name": "tidepool"},
            "headRepositoryOwner": {"login": "example"}, "mergeStateStatus": "UNKNOWN", "reviewDecision": null,
            "baseRefName": "develop", "body": "",
            "labels": [], "closingIssuesReferences": [], "changedFiles": 1, "statusCheckRollup": [],
            "mergeCommit": {"oid": BASE_TIP}
        });
        assert_eq!(
            parse_view(&raw.to_string()).unwrap().merge_commit.as_deref(),
            Some(BASE_TIP)
        );
        raw["mergeCommit"] = Value::Null;
        assert_eq!(parse_view(&raw.to_string()).unwrap().merge_commit, None);
    }

    #[test]
    fn the_merge_call_cannot_carry_admin_or_auto() {
        let argv = gh::merge_argv("example/tidepool", 12, HEAD);
        assert_eq!(
            argv,
            [
                "pr",
                "merge",
                "12",
                "--repo",
                "example/tidepool",
                "--squash",
                "--match-head-commit",
                HEAD
            ]
        );
        assert!(argv.iter().all(|a| a != "--admin" && a != "--auto"));
        // The only place an argument list is built is gh.rs, which has no such flag.
        for flag in ["\"--admin\"", "\"--auto\"", "CROSS_REVIEW_MERGE_OVERRIDE"] {
            assert!(!include_str!("gh.rs").contains(flag), "{flag} in gh.rs");
        }
    }

    #[test]
    fn a_pr_github_would_only_queue_is_not_mergeable_now() {
        let mut f = clear();
        for ok in ["CLEAN", "HAS_HOOKS", "UNSTABLE"] {
            view(&mut f).merge_state = ok.into();
            assert!(codes(&f).is_empty(), "{ok}");
        }
        for bad in ["BLOCKED", "BEHIND", "DIRTY", "DRAFT", "UNKNOWN", ""] {
            view(&mut f).merge_state = bad.into();
            assert_eq!(codes(&f), ["not_mergeable"], "{bad}");
        }
        view(&mut f).merge_state = "CLEAN".into();
        for bad in ["CHANGES_REQUESTED", "REVIEW_REQUIRED"] {
            view(&mut f).review_decision = bad.into();
            assert_eq!(codes(&f), ["not_mergeable"], "{bad}");
        }
        for ok in ["APPROVED", ""] {
            view(&mut f).review_decision = ok.into();
            assert!(codes(&f).is_empty(), "{ok}");
        }
    }

    #[test]
    fn the_pr_must_be_the_units_branch_in_the_profiles_repo() {
        let mut f = clear();
        view(&mut f).head_ref = "fix/other".into();
        assert_eq!(codes(&f), ["pr_unit"]);
        view(&mut f).head_ref = "fix/tide".into();
        view(&mut f).head_repo = "stranger/tidepool".into();
        assert_eq!(codes(&f), ["pr_unit"]);
        view(&mut f).head_repo = String::new();
        assert_eq!(codes(&f), ["pr_unit"]);
        view(&mut f).head_repo = "Example/Tidepool".into();
        assert!(codes(&f).is_empty(), "case does not matter");
        f.unit_branch = Err("units/3/unit.json is missing".into());
        assert_eq!(codes(&f), ["pr_unit"]);
        f.unit_branch = Ok(String::new());
        assert_eq!(codes(&f), ["pr_unit"]);
    }

    #[test]
    fn a_unit_with_no_file_scope_is_left_to_a_person() {
        let mut f = clear();
        f.deliver.as_mut().unwrap().scope_checked = Some(false);
        let found = judge(&f);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].code, "deliver_check");
        assert!(found[0].detail.contains("no file scope"), "{}", found[0].detail);
        f.deliver.as_mut().unwrap().scope_checked = None;
        assert_eq!(codes(&f), ["deliver_check"]);
    }

    #[test]
    fn a_review_stamped_at_another_commit_needs_an_ancestor_and_a_proof_for_the_head_or_it() {
        let reviewed = &BASE_TIP[..9];
        let mut f = clear();
        f.preflight.as_mut().unwrap().reviewed = reviewed.into();
        f.review_record.as_mut().unwrap().as_mut().unwrap().sha = BASE_TIP.into();
        f.reviewed_ancestry = Some(Ok(true));
        assert!(codes(&f).is_empty(), "an ancestor, proof for the head");
        f.reviewed_ancestry = Some(Ok(false));
        assert_eq!(codes(&f), ["review"]);
        f.reviewed_ancestry = Some(Err("whether it is an ancestor (gh exit 1)".into()));
        assert_eq!(codes(&f), ["read_error"]);
        f.reviewed_ancestry = None;
        assert_eq!(codes(&f), ["read_error"]);
        f.reviewed_ancestry = Some(Ok(true));
        f.proof.as_mut().unwrap().head = "e".repeat(40);
        let found = codes(&f);
        assert!(found.contains(&"review_proof"), "{found:?}");
        // The proof for the reviewed ancestor is the one proof check: accepted
        // once the ancestry is shown, and never without it.
        f.proof.as_mut().unwrap().head = BASE_TIP.into();
        assert!(codes(&f).is_empty(), "{:?}", judge(&f));
        f.reviewed_ancestry = Some(Ok(false));
        let found = codes(&f);
        assert!(
            found.contains(&"review") && found.contains(&"review_proof"),
            "{found:?}"
        );
        f.reviewed_ancestry = Some(Ok(true));
        f.proof.as_mut().unwrap().head = HEAD.into();
        f.preflight.as_mut().unwrap().reviewed = String::new();
        assert_eq!(codes(&f), ["review"]);
        // The head itself, whole or abbreviated, needs no ancestry read.
        f.preflight.as_mut().unwrap().reviewed = HEAD[..9].into();
        f.review_record.as_mut().unwrap().as_mut().unwrap().sha = HEAD.into();
        f.reviewed_ancestry = None;
        assert!(codes(&f).is_empty());
    }

    #[test]
    fn a_check_pinned_to_an_app_needs_that_apps_run() {
        let from = |id: u64, outcome: Outcome, word: &str| {
            from_source("build", &format!("app:{id}"), outcome, word, "2026-11-21T01:00:00Z")
        };
        let mut f = clear();
        f.required = Ok(vec![Required {
            context: "build".into(),
            app_id: Some(15368),
        }]);
        // The rollup has a passing `build`, but not from the pinned app.
        f.app_runs = Ok(vec![from(99, Outcome::Pass, "success")]);
        let found = judge(&f);
        assert_eq!(found.len(), 1);
        assert!(found[0].detail.contains("from app 15368"), "{}", found[0].detail);
        f.app_runs = Ok(vec![
            from(99, Outcome::Pass, "success"),
            from(15368, Outcome::Fail, "failure"),
        ]);
        assert_eq!(codes(&f), ["required_check"]);
        f.app_runs = Ok(vec![from(15368, Outcome::Pass, "success")]);
        assert!(codes(&f).is_empty());
        f.app_runs = Err("the check runs at the head (gh exit 1)".into());
        assert_eq!(codes(&f), ["read_error"]);
        // Unpinned: the unreadable runs do not matter.
        f.required = Ok(vec!["build".into()]);
        assert!(codes(&f).is_empty());
    }

    #[test]
    fn an_app_id_is_kept_unless_it_is_null_or_minus_one() {
        let raw = r#"{"required_status_checks":{"contexts":["a"],"checks":[{"context":"b","app_id":15368},{"context":"c","app_id":-1},{"context":"d","app_id":null},{"context":"e"}]}}"#;
        let got: Vec<(String, Option<u64>)> = parse_protection(raw)
            .unwrap()
            .into_iter()
            .map(|r| (r.context, r.app_id))
            .collect();
        assert_eq!(
            got,
            [
                ("a".to_string(), None),
                ("b".to_string(), Some(15368)),
                ("c".to_string(), None),
                ("d".to_string(), None),
                ("e".to_string(), None)
            ]
        );
        let rules = r#"[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"b","integration_id":15368},{"context":"c","integration_id":0}]}}]"#;
        assert!(parse_rules(rules).is_err(), "0 is not an app id");
        let rules = r#"[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"b","integration_id":15368},{"context":"c"}]}}]"#;
        let got = parse_rules(rules).unwrap();
        assert_eq!((got[0].app_id, got[1].app_id), (Some(15368), None));
        assert!(parse_protection(r#"{"required_status_checks":{"checks":[{"context":"b","app_id":"x"}]}}"#).is_err());
    }

    #[test]
    fn check_runs_keep_the_app_that_made_each() {
        let page1 = json!({"total_count": 2, "check_runs": [
            {"name": "build", "status": "completed", "conclusion": "success", "started_at": "2026-11-21T01:00:00Z", "app": {"id": 15368}}]});
        let page2 = json!({"total_count": 2, "check_runs": [
            {"name": "build", "status": "in_progress", "conclusion": null, "started_at": null, "app": {"id": 7}}]});
        let runs = parse_check_runs(&format!("{page1}\n{page2}")).unwrap();
        assert_eq!(runs.len(), 2);
        assert_eq!((runs[0].source.as_str(), runs[0].outcome), ("app:15368", Outcome::Pass));
        assert_eq!((runs[1].source.as_str(), runs[1].outcome), ("app:7", Outcome::Pending));
        assert!(parse_check_runs("").is_err());
        assert!(parse_check_runs("{}").is_err());
    }

    #[test]
    fn after_a_merge_call_the_pr_may_be_merged_queued_or_armed() {
        let read = |v: Value| parse_after_merge(&v.to_string());
        let merged = read(json!({"state": "MERGED", "mergeCommit": {"oid": BASE_TIP}})).unwrap();
        assert_eq!((merged.state, merged.auto_merge), (PrState::Merged, false));
        let queued = read(json!({"state": "OPEN", "mergeCommit": null, "autoMergeRequest": null})).unwrap();
        assert_eq!((queued.state, queued.auto_merge), (PrState::Open, false));
        let armed =
            read(json!({"state": "OPEN", "mergeCommit": null, "autoMergeRequest": {"enabledAt": "x"}})).unwrap();
        assert!(armed.auto_merge);
        assert!(
            read(json!({"state": "OPEN", "mergeCommit": null})).is_err(),
            "unknown is not 'not armed'"
        );
    }

    fn record_body(sha: &str, tail: &str) -> String {
        format!(
            "## Cross-review\n\nReviewed `{}`\n<!-- cross-review: sha={sha} base={sha} pass=1 {tail}-->",
            &sha[..9]
        )
    }

    #[test]
    fn a_stamp_is_read_the_way_the_review_script_reads_it() {
        let marked = stamp_of(&record_body(HEAD, "verdict=CLEAN ")).unwrap();
        assert_eq!(marked, (HEAD.to_string(), "CLEAN".to_string()));
        // No verdict, or one outside the vocabulary, reads as none.
        assert_eq!(stamp_of(&record_body(HEAD, "")).unwrap().1, "");
        assert_eq!(stamp_of(&record_body(HEAD, "verdict=GREAT ")).unwrap().1, "");
        // Two verdict fields: the script reads the last, so the gate reads
        // none, and such a record never earns the BLOCKED exemption.
        for tail in [
            "verdict=BLOCKED verdict=CLEAN ",
            "verdict=CLEAN verdict=BLOCKED ",
            "xverdict=BLOCKED verdict=CLEAN ",
        ] {
            assert_eq!(stamp_of(&record_body(HEAD, tail)).unwrap().1, "", "{tail}");
        }
        // Only ASCII spaces separate fields for the script, and a marker with
        // any other character is not one it wrote: no verdict.
        for tail in [
            "\u{a0}verdict=BLOCKED ",
            "verdict=BLOCKED\u{a0}",
            "verdict=BLOCKED\u{2003}",
            "é verdict=BLOCKED ",
        ] {
            assert_eq!(stamp_of(&record_body(HEAD, tail)).unwrap().1, "", "{tail:?}");
        }
        // A marker broken across lines is not one the script reads.
        let split =
            format!("## Cross-review\n\n<!-- cross-review: sha={HEAD}\nverdict=BLOCKED -->\nReviewed `0123456789`");
        assert_eq!(stamp_of(&split).unwrap(), ("0123456789".to_string(), String::new()));
        // The prose alone is a stamp, abbreviated.
        let prose = stamp_of("## Cross-review\n\nReviewed `0123456789`").unwrap();
        assert_eq!(prose, ("0123456789".to_string(), String::new()));
        // Not at the start, or no stamp at all: not a record.
        assert_eq!(stamp_of(&format!("see\n{}", record_body(HEAD, ""))), None);
        assert_eq!(stamp_of("## Cross-review\n\nno stamp here"), None);
    }

    #[test]
    fn the_newest_record_across_pages_is_the_one_read() {
        let comment =
            |body: &str, assoc: &str| json!({"body": body, "author_association": assoc, "user": {"login": "x"}});
        let page_one = json!([
            comment(&record_body(BASE_TIP, "verdict=CLEAN "), "OWNER"),
            comment("chat", "NONE")
        ]);
        let page_two = json!([comment(&record_body(HEAD, "verdict=CLEAN "), "NONE")]);
        let found = parse_review_record(&format!("{page_one}{page_two}")).unwrap().unwrap();
        assert_eq!((found.sha.as_str(), found.association.as_str()), (HEAD, "NONE"));
        assert_eq!(parse_review_record("[]").unwrap(), None);
        assert!(parse_review_record("").is_err(), "no page at all");
        assert!(parse_review_record("{}").is_err());
        assert!(parse_review_record("[1]").is_err());
        assert!(parse_review_record("nope").is_err());
    }

    fn record(f: &mut Facts) -> &mut ReviewRecord {
        f.review_record.as_mut().unwrap().as_mut().unwrap()
    }

    #[test]
    fn a_review_record_must_be_trusted_and_agree_with_the_review_script() {
        let mut f = clear();
        record(&mut f).association = "owner".into();
        assert!(codes(&f).is_empty(), "case does not matter");
        record(&mut f).association = "CONTRIBUTOR".into();
        assert_eq!(codes(&f), ["review_author"]);
        record(&mut f).association = String::new();
        assert_eq!(codes(&f), ["review_author"]);
        record(&mut f).association = "OWNER".into();
        f.trusted_authors = Vec::new();
        assert_eq!(codes(&f), ["review_author"], "an empty list trusts no one");
        f.trusted_authors = vec!["OWNER".into()];
        record(&mut f).verdict = "FIXES_APPLIED".into();
        assert_eq!(codes(&f), ["review_author"]);
        record(&mut f).verdict = "CLEAN".into();
        record(&mut f).sha = BASE_TIP.into();
        assert_eq!(codes(&f), ["review_author"]);
        f.review_record = Ok(None);
        assert_eq!(codes(&f), ["review_author"]);
        f.review_record = Err("the comments of PR #12 (gh exit 1)".into());
        assert_eq!(codes(&f), ["read_error"]);
    }

    #[test]
    fn the_merge_queue_answer_is_read_or_refused() {
        let answer = |v: Value| json!({"data": {"repository": {"pullRequest": v}}}).to_string();
        assert_eq!(parse_in_queue(&answer(json!({"isInMergeQueue": true}))), Ok(true));
        assert_eq!(parse_in_queue(&answer(json!({"isInMergeQueue": false}))), Ok(false));
        assert!(parse_in_queue(&answer(json!({}))).is_err());
        assert!(parse_in_queue(&answer(Value::Null)).is_err());
        assert!(parse_in_queue(&json!({"errors": [{}]}).to_string()).is_err());
        assert!(parse_in_queue("nope").is_err());
        let mut f = clear();
        f.in_merge_queue = Err("whether PR #12 is in the merge queue".into());
        assert_eq!(codes(&f), ["read_error"]);
        f.in_merge_queue = Ok(true);
        assert!(
            codes(&f).is_empty(),
            "run answers a queued PR, judge does not refuse it"
        );
    }

    #[test]
    fn a_workflow_run_id_is_read_from_the_details_url() {
        assert_eq!(run_id_of("https://github.com/o/r/actions/runs/123/job/456"), "123");
        assert_eq!(run_id_of("https://github.com/o/r/actions/runs/789"), "789");
        assert_eq!(run_id_of("https://example.com/status/1"), "");
        assert_eq!(run_id_of(""), "");
    }

    #[test]
    fn a_failure_in_one_workflow_run_is_not_hidden_by_a_later_pass_in_another() {
        let mut f = clear();
        let mut failed = run_of("build", Outcome::Fail, "failure", "2026-11-21T01:00:00Z");
        failed.run = "111".into();
        let mut passed = run_of("build", Outcome::Pass, "success", "2026-11-21T02:00:00Z");
        passed.run = "222".into();
        view(&mut f).runs = vec![failed.clone(), passed.clone()];
        assert_eq!(codes(&f), ["required_check"]);
        // Inside one run the later entry is a re-run and wins.
        passed.run = "111".into();
        view(&mut f).runs = vec![failed, passed];
        assert!(codes(&f).is_empty());
    }
}
