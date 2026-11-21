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
//! `gh pr merge` exiting 0 does not mean merged: on a merge-queue branch it
//! means queued. The PR is read again after the call, and `merged: true` is
//! printed only when GitHub says MERGED.
//!
//! Exit: 0 merged (or already merged, or a dry run that would have); 3 a
//! condition refused; 1 the merge call itself failed, or the read after it did
//! (the PR may then have been merged); 4 the merge call was accepted but the PR
//! is not merged yet (queued: `merged: false, queued: true`); 2 bad arguments.

use std::collections::BTreeMap;
use std::process::{Command, Stdio};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::ctx::{Ctx, env_str, read_json};
use crate::error::{Fail, Res};
use crate::gh::{self, Write};
use crate::profile::same_label;

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
    pub head: String,
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
    pub required: Read<Vec<String>>,
    pub preflight: Read<Preflight>,
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

/// The newest run of each check, a check being a name from one source. A tie
/// for newest keeps every tied run, so a disagreement counts against the check.
/// A later success of one workflow does not hide a failure of a same-named
/// check of another.
fn newest(runs: &[Run]) -> BTreeMap<(&str, &str), Vec<&Run>> {
    let mut by_check: BTreeMap<(&str, &str), Vec<&Run>> = BTreeMap::new();
    for run in runs {
        by_check
            .entry((run.name.as_str(), run.source.as_str()))
            .or_default()
            .push(run);
    }
    for group in by_check.values_mut() {
        let latest = group
            .iter()
            .map(|r| r.started.as_str())
            .max()
            .unwrap_or_default()
            .to_string();
        group.retain(|r| r.started == latest);
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
        if v.base_ref != f.base {
            out.push(refusal(
                "wrong_base",
                format!("PR #{n} targets '{}', not '{}'", v.base_ref, f.base),
            ));
        }
    }

    // 2 and 3. checks at the head
    match (&f.required, view) {
        (Err(what), _) => out.push(refusal("read_error", format!("could not read {what}"))),
        (Ok(required), Some(v)) => {
            let latest = newest(&v.runs);
            for context in required {
                // Every source that carries the name must be ok.
                let groups: Vec<&Vec<&Run>> = latest
                    .iter()
                    .filter(|((name, _), _)| *name == context.as_str())
                    .map(|(_, group)| group)
                    .collect();
                if groups.is_empty() {
                    out.push(refusal(
                        "required_check",
                        format!("required check '{context}' has no run at the head"),
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
                        format!("required check '{context}' is {} at the head", bad.word),
                    ));
                }
            }
            for ((name, _), group) in &latest {
                if required.iter().any(|r| r == name) {
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
            }
        }
    }

    // 5. who reviewed
    match &f.proof {
        Err(what) => out.push(refusal("review_proof", what.clone())),
        Ok(proof) => {
            if head.is_some_and(|h| proof.head != h) {
                out.push(refusal(
                    "review_proof",
                    format!("the review proof is for '{}', not the head", proof.head),
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
    Ok(Run {
        name,
        source,
        outcome,
        word,
        started,
    })
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

/// `gh pr view --json state,headRefOid,baseRefName,labels,body,
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
    Ok(PrView {
        state,
        head,
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

/// `gh api repos/{o}/{r}/branches/{base}/protection`: the required contexts.
pub fn parse_protection(raw: &str) -> Read<Vec<String>> {
    let v: Value = serde_json::from_str(raw).map_err(|_| "the answer is not JSON".to_string())?;
    if !v.is_object() {
        return Err("the answer is not an object".into());
    }
    let mut required = Vec::new();
    let Some(checks) = v.get("required_status_checks").filter(|c| !c.is_null()) else {
        return Ok(required);
    };
    let strings = |key: &str| -> Read<Vec<String>> {
        match checks.get(key) {
            None | Some(Value::Null) => Ok(Vec::new()),
            Some(Value::Array(list)) => list
                .iter()
                .map(|c| {
                    match key {
                        "contexts" => c.as_str(),
                        _ => c.get("context").and_then(Value::as_str),
                    }
                    .map(str::to_string)
                    .ok_or_else(|| format!("a '{key}' entry has no context"))
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
pub fn parse_rules(raw: &str) -> Read<Vec<String>> {
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
                required.push(context.to_string());
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

/// `gh pr view --json state,mergeCommit` after the merge call: whether the PR
/// is merged, and the merge commit when GitHub names one.
fn parse_after_merge(raw: &str) -> Read<(PrState, Option<String>)> {
    let v: Value = serde_json::from_str(raw).map_err(|_| "the answer is not JSON".to_string())?;
    Ok((pr_state(&v)?, merge_commit_of(&v)))
}

fn parse_preflight(raw: &str) -> Read<Preflight> {
    let v: Value = serde_json::from_str(raw.trim()).map_err(|_| "its output is not JSON".to_string())?;
    if !v.is_object() {
        return Err("its output is not an object".into());
    }
    let word = |key: &str| v.get(key).and_then(Value::as_str).unwrap_or_default().to_string();
    Ok(Preflight {
        status: word("status"),
        verdict: word("verdict"),
        head: word("head"),
    })
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
/// for a PR nobody reviewed.
fn preflight(repo: &str, pr: u64) -> Read<Preflight> {
    let what = "merge_preflight.sh";
    let path = preflight_path().map_err(|e| format!("{what}: {e}"))?;
    let out = Command::new(&path)
        .args(["--pr", &pr.to_string(), "--repo", repo, "--json"])
        .env("GH_HOST", "github.com")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .map_err(|e| format!("{what} did not run ({path}: {e})"))?;
    parse_preflight(&String::from_utf8_lossy(&out.stdout)).map_err(|e| format!("{what}: {e}"))
}

fn unit_file<T: serde::de::DeserializeOwned>(ctx: &Ctx, unit: u64, name: &str) -> Read<T> {
    read_json(&ctx.path(&format!("units/{unit}/{name}")))
        .ok_or_else(|| format!("units/{unit}/{name} is missing or not the expected shape"))
}

/// Every read the decision needs. Nothing here decides anything.
fn gather(ctx: &Ctx, repo: &str, unit: u64, pr: u64, view: Read<PrView>) -> Facts {
    let base = ctx.profile.base_branch.clone();
    let head = view.as_ref().ok().map(|v| v.head.clone());
    let unit_entry = ctx
        .queue_unit(unit)
        .map(|u| UnitEntry {
            waits_for: u.waits_for,
            issues: u.issues,
        })
        .map_err(|e| format!("the queue entry of unit {unit} ({})", e.msg));
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

    Facts {
        unit,
        pr,
        repo: repo.to_string(),
        base,
        hold_labels: ctx.profile.hold_labels.clone(),
        view,
        required,
        preflight: preflight(repo, pr),
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
fn required_checks(repo: &str, base: &str) -> Read<Vec<String>> {
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
        "state,headRefOid,baseRefName,labels,body,closingIssuesReferences,changedFiles,statusCheckRollup,mergeCommit",
    ])?;
    parse_view(&raw)
}

/// The PR's state and merge commit, read again after the merge call.
fn read_after_merge(repo: &str, pr: u64) -> Read<(PrState, Option<String>)> {
    read_gh(&[
        "pr",
        "view",
        &pr.to_string(),
        "--repo",
        repo,
        "--json",
        "state,mergeCommit",
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
    let repo = ctx.repo()?;
    let (unit, pr) = (args.unit, args.pr);
    let view = read_view(&repo, pr);

    // A restarted driver asks again for a PR it already merged.
    if let Ok(v) = &view {
        if v.state == PrState::Merged {
            report(ctx, unit, pr, &v.head, true, &[]);
            let out = json!({"pr": pr, "unit": unit, "head": v.head, "merged": true, "already": true, "merge_commit": v.merge_commit, "refusals": [], "reviewers": []});
            println!("{out}");
            return Ok(());
        }
    }

    let facts = gather(ctx, &repo, unit, pr, view);
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
                Ok((PrState::Merged, oid)) => {
                    report(ctx, unit, pr, &head, true, &[]);
                    println!("{}", output_with(true, json!({"merge_commit": oid})));
                    Ok(())
                }
                Ok((state, _)) => {
                    report(ctx, unit, pr, &head, false, &[]);
                    println!("{}", output_with(false, json!({"queued": true})));
                    Err(Fail::queued(format!(
                        "PR #{pr}: the merge call was accepted but the PR is {state:?}, not merged (queued?); ask again later"
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
            required: Ok(vec!["build".into()]),
            preflight: Ok(Preflight {
                status: "clear".into(),
                verdict: "CLEAN".into(),
                head: HEAD.into(),
            }),
            proof: Ok(Proof {
                head: HEAD.into(),
                reviewers: vec![reviewer("codex", true), reviewer("kimi", true)],
            }),
            deliver: Ok(Deliver {
                ok: true,
                head: HEAD.into(),
                merge_base: BASE_TIP.into(),
                risk_paths_touched: Some(Vec::new()),
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
        });
        assert_eq!(codes(&f), ["review"]);
        f.preflight = Ok(Preflight {
            status: "clear".into(),
            verdict: "FIXES_APPLIED".into(),
            head: HEAD.into(),
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
            "state": "OPEN", "headRefOid": HEAD, "baseRefName": "develop", "body": "x",
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
            "state": "OPEN", "headRefOid": HEAD, "baseRefName": "develop", "body": "",
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
        assert_eq!(parse_protection(raw).unwrap(), ["a", "b", "c"]);
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
            "state": "OPEN", "headRefOid": HEAD, "baseRefName": "develop", "body": "",
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
        assert_eq!(parse_rules(&format!("{page1}\n{page2}")).unwrap(), ["a", "b", "c"]);
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
            "state": "MERGED", "headRefOid": HEAD, "baseRefName": "develop", "body": "",
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
}
