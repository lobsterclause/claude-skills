//! The files one command writes and another reads. Each shape is defined
//! once, here, so two commands cannot disagree about a field.
//!
//! Field order is the order in the file: serde writes fields as declared.
//!
//! Run folder:
//!   issues/<n>.json        Issue             intake
//!   intake.json            Intake            intake
//!   verdicts.checked.json  [Checked]         evidence-check
//!   overlap.json           Overlap           overlap
//!   queue.json             Queue             tracker render
//!
//! What a reader returns (verdicts.json) and what the session decides
//! (decisions.json) are written by a model, so the commands that read them
//! parse them leniently, by hand, and are not typed here.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// One issue as intake saved it.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Issue {
    pub number: u64,
    pub title: String,
    #[serde(default)]
    pub body: String,
    pub state: String,
    #[serde(default)]
    pub url: String,
    #[serde(rename = "createdAt")]
    pub created_at: String,
    #[serde(rename = "updatedAt", default)]
    pub updated_at: String,
    #[serde(default)]
    pub author: String,
    #[serde(rename = "authorAssociation", default)]
    pub author_association: String,
    #[serde(default)]
    pub labels: Vec<String>,
    /// Open PRs that say they close this issue.
    #[serde(default)]
    pub open_prs: Vec<u64>,
    /// When the claim label was last added, if the issue carries it.
    #[serde(default)]
    pub claim_labeled_at: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Intake {
    pub repo: String,
    pub generated_at: String,
    pub cap: usize,
    pub eligible: Vec<Eligible>,
    pub skipped: Vec<Skipped>,
    pub stale_claims: Vec<StaleClaim>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Eligible {
    pub number: u64,
    pub title: String,
    pub labels: Vec<String>,
    pub url: String,
    #[serde(rename = "createdAt")]
    pub created_at: String,
    /// Position of the issue's first priority label in the profile's list;
    /// 99 when it has none.
    pub priority: usize,
    pub trusted_author: bool,
    pub open_prs: Vec<u64>,
    /// Paths the profile's classifier put out of scope for this issue.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub out_of_scope_paths: Option<Vec<String>>,
    /// Present, and true, when the classifier failed on this issue.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub classifier_error: Option<bool>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Skipped {
    pub number: u64,
    pub title: String,
    pub reason: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct StaleClaim {
    pub number: u64,
    pub title: String,
    pub labeled_at: Option<String>,
    pub days: Option<i64>,
}

/// A line number, or the reader's own text when it was not a number.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(untagged)]
pub enum Line {
    Number(u64),
    Text(String),
}

/// One quoted line after the evidence check.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Quote {
    pub file: String,
    /// Where the quote was found; the reader's line when it was not found.
    pub line: Line,
    pub quote: String,
    pub ok: bool,
    /// Why it failed; null when `ok`.
    pub reason: Option<String>,
    /// The commit that last changed the line, from git blame. Absent when the
    /// quote failed.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub commit: String,
    /// That commit's committer time, seconds since the epoch; absent when the
    /// quote failed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commit_time: Option<i64>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub subject: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct FixCommit {
    pub sha: String,
    pub date: String,
    pub subject: String,
    pub file: String,
    pub line: u64,
}

/// One verdict after the evidence check: the reader's fields, then what the
/// check added.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Checked {
    pub number: u64,
    /// live, already_fixed, duplicate_of, needs_human or unclear.
    pub status: String,
    #[serde(default)]
    pub duplicate_of: Option<u64>,
    #[serde(default)]
    pub evidence: Vec<Quote>,
    #[serde(default)]
    pub likely_files: Vec<String>,
    #[serde(default)]
    pub symbols: Vec<String>,
    /// Existing code the fix should reuse. Only quotes that passed.
    #[serde(default)]
    pub reuse: Vec<Quote>,
    #[serde(default)]
    pub change_kind: String,
    #[serde(default)]
    pub pattern: String,
    /// S, M, L or XL.
    #[serde(default)]
    pub size: String,
    #[serde(default)]
    pub behavioural: Option<bool>,
    #[serde(default)]
    pub task: String,
    #[serde(default)]
    pub acceptance: String,
    #[serde(default)]
    pub reason: String,
    /// The reader's status, before any downgrade. Null when no reader
    /// returned a verdict for the issue.
    #[serde(default)]
    pub original_status: Option<String>,
    #[serde(default)]
    pub downgrade_reason: Option<String>,
    /// Files the fix will touch: the evidence files and the likely files that
    /// exist on the ref.
    #[serde(default)]
    pub files: Vec<String>,
    #[serde(default)]
    pub reuse_dropped: usize,
    #[serde(default)]
    pub fix_commit: Option<FixCommit>,
    /// already_fixed, not behavioural, and proved by a commit newer than the
    /// issue.
    #[serde(default)]
    pub closable: bool,
    #[serde(default)]
    pub risk: bool,
    #[serde(default)]
    pub risk_paths: Vec<String>,
    pub checked_ref: String,
    pub checked_sha: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Overlap {
    pub pairs: Vec<Pair>,
    pub groups: Vec<Group>,
    pub singles: Vec<u64>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Pair {
    pub a: u64,
    pub b: u64,
    pub relation: String,
    pub shared_files: Vec<String>,
    pub shared_symbols: Vec<String>,
    pub note: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Group {
    pub issues: Vec<u64>,
    pub live: Vec<u64>,
    pub files: Vec<String>,
    pub est_lines: u64,
    pub over_cap: bool,
    pub over_lines: bool,
    pub risk: bool,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Queue {
    pub version: u32,
    pub run: String,
    pub repo: String,
    pub base: String,
    pub base_sha: String,
    pub units: Vec<Unit>,
    pub closures: Vec<Closure>,
    pub stale_claims: Vec<StaleClaim>,
    pub title: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Unit {
    /// U1, U2, ... in queue order.
    pub id: String,
    pub issues: Vec<u64>,
    /// The issues that need a change; the rest are duplicates it closes.
    pub live: Vec<u64>,
    pub title: String,
    pub kind: String,
    pub size: String,
    pub model: String,
    pub effort: String,
    pub est_minutes: u64,
    pub test_command: String,
    pub files: Vec<String>,
    /// Issue number (as text) to its acceptance check, in issue order.
    pub acceptance: Map<String, Value>,
    /// "file:line" of code the fix should reuse.
    pub reuse: Vec<String>,
    pub risk: bool,
    pub risk_paths: Vec<String>,
    /// The PR opens and then waits for a named person.
    pub waits: bool,
    pub waits_for: Option<String>,
    pub priority: usize,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Closure {
    pub number: u64,
    /// The issue's title and body as intake saved them when the tracker was
    /// rendered. The verdict and the tick are about this text.
    pub title: String,
    pub body: String,
    pub fix_commit: FixCommit,
    /// The PR number in the fixing commit's subject, when it names one.
    pub pr: Option<u64>,
    pub evidence: Vec<ClosureQuote>,
    pub note: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct ClosureQuote {
    pub file: String,
    pub line: u64,
    pub quote: String,
}
