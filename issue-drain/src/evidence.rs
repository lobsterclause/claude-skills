//! `issue-drain evidence-check`.
//!
//! A reader is a cheap model reading an issue someone else wrote. Its verdict
//! is a claim, and this is where the claim meets the repo:
//!   - every quoted line must be a blob on the ref, in that file, within
//!     `evidence_line_slack` lines of where the reader said (the line is
//!     corrected to where it was found). A quote that is not there downgrades
//!     the verdict to "unclear";
//!   - "already_fixed" needs a quoted line last changed AFTER the issue was
//!     opened. `git blame` names that commit; the reader does not get to;
//!   - a fix that lives on a protected path becomes "needs_human";
//!   - an eligible issue with no verdict gets an "unclear" one;
//!   - a verdict about an issue this run did not take in is dropped, loudly.
//!
//! A line that a formatter touched after the issue was opened looks like a
//! fix to blame. The session re-reads each closure before it is offered, and
//! a person ticks it; those two checks cover that case.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

use regex::Regex;
use serde_json::{Value, json};

use crate::ctx::{Ctx, parse_rfc3339, read_json, rfc3339, write_json};
use crate::error::{Fail, Res};
use crate::git;
use crate::model::{Checked, FixCommit, Line, Quote};
use crate::profile::Profile;
use crate::text::{norm_quote, parse_number, repo_path};

#[derive(clap::Args)]
pub struct Args {
    /// One or more files, each a JSON array of reader verdicts.
    inputs: Vec<PathBuf>,
    /// The ref to check against. Default: origin/<base_branch>.
    #[arg(long = "ref")]
    reference: Option<String>,
    /// Where to write the result. Default: <run folder>/verdicts.checked.json.
    #[arg(long)]
    out: Option<PathBuf>,
}

static COMMIT_ID: LazyLock<Regex> = LazyLock::new(|| Regex::new("^[0-9a-f]{7,40}$").expect("a fixed pattern"));

const STATUSES: [&str; 5] = ["live", "already_fixed", "duplicate_of", "needs_human", "unclear"];

/// What a check is held against: one ref of one local checkout, under one profile.
struct Basis<'a> {
    profile: &'a Profile,
    dir: &'a Path,
    reference: &'a str,
    sha: String,
}

/// jq's `tostring`, with null and false read as "not given".
fn tostr(v: Option<&Value>) -> String {
    match v {
        None | Some(Value::Null) | Some(Value::Bool(false)) => String::new(),
        Some(Value::String(s)) => s.clone(),
        Some(other) => other.to_string(),
    }
}

fn strings(v: Option<&Value>) -> Vec<String> {
    match v {
        Some(Value::Array(items)) => items.iter().filter_map(|i| i.as_str().map(str::to_string)).collect(),
        _ => Vec::new(),
    }
}

/// An issue number written as a JSON number or as digits in a string.
fn number_of(v: &Value) -> Option<u64> {
    match v.get("number")? {
        Value::Number(n) => n.as_u64().filter(|n| *n > 0),
        Value::String(s) => parse_number(s),
        _ => None,
    }
}

fn line_text(line: &Line) -> String {
    match line {
        Line::Number(n) => n.to_string(),
        Line::Text(t) => t.clone(),
    }
}

fn given_line(line: &str) -> Line {
    line.parse()
        .map(Line::Number)
        .unwrap_or_else(|_| Line::Text(line.to_string()))
}

/// The line of `text` nearest `want`, within `slack` lines, that holds `nq`
/// once its own spacing is normalised. Lines count from 1; the first of two
/// equally near lines wins.
fn find_line(text: &str, want: i64, slack: i64, nq: &str) -> u64 {
    // A reader may name any line number, so nothing here may overflow.
    let (low, high) = (want.saturating_sub(slack), want.saturating_add(slack));
    let mut best: Option<(i64, u64)> = None;
    for (i, raw) in text.split('\n').enumerate() {
        let n = i64::try_from(i).map_or(i64::MAX, |i| i.saturating_add(1));
        if n < low || n > high || !norm_quote(raw).contains(nq) {
            continue;
        }
        let d = n.abs_diff(want);
        if best.is_none_or(|(_, best_d)| d < best_d) {
            best = Some((n, d));
        }
    }
    best.map_or(0, |(n, _)| n as u64)
}

struct Blamed {
    sha: String,
    time: i64,
    subject: String,
}

fn blame(basis: &Basis, file: &str, line: u64) -> Option<Blamed> {
    let range = format!("{line},{line}");
    let out = git::out(
        basis.dir,
        &["blame", "-L", &range, "--porcelain", &basis.sha, "--", file],
    )?;
    let sha = out.lines().next()?.split(' ').next()?.to_string();
    let time = out
        .lines()
        .find_map(|l| l.strip_prefix("committer-time "))?
        .trim()
        .parse()
        .ok()?;
    let subject = out
        .lines()
        .find_map(|l| l.strip_prefix("summary "))
        .unwrap_or_default()
        .to_string();
    Some(Blamed { sha, time, subject })
}

/// Why a quote fails, or the line it was found on and who last changed it.
fn quote_outcome(basis: &Basis, file: &str, line: &str, quote: &str) -> Result<(u64, Blamed), String> {
    let slack = basis.profile.evidence_line_slack;
    let min = basis.profile.evidence_min_quote;
    let nq = norm_quote(quote);
    repo_path(file)?;
    let want = parse_number(line)
        .and_then(|n| i64::try_from(n).ok())
        .ok_or("has no line number")?;
    if quote.contains('\n') {
        return Err("quote spans more than one line".into());
    }
    if nq.chars().count() < min {
        return Err(format!("quote is shorter than {min} characters"));
    }
    let spec = format!("{}:{file}", basis.sha);
    if git::out(basis.dir, &["cat-file", "-t", &spec]).is_none_or(|t| t.trim() != "blob") {
        return Err(format!("file is not on {}", basis.reference));
    }
    let content = git::out(basis.dir, &["show", &spec]).ok_or_else(|| format!("file is not on {}", basis.reference))?;
    let found = find_line(&content, want, slack as i64, &nq);
    if found == 0 {
        return Err(format!(
            "quote is not within {slack} lines of that line on {}",
            basis.reference
        ));
    }
    let blamed = blame(basis, file, found).ok_or("git blame gave no commit for that line")?;
    Ok((found, blamed))
}

fn check_quote(basis: &Basis, item: &Value) -> Quote {
    let file = tostr(item.get("file"));
    let line = tostr(item.get("line"));
    let quote = tostr(item.get("quote"));
    match quote_outcome(basis, &file, &line, &quote) {
        Ok((found, blamed)) => Quote {
            file,
            line: Line::Number(found),
            quote,
            ok: true,
            reason: None,
            commit: blamed.sha,
            commit_time: Some(blamed.time),
            subject: blamed.subject,
        },
        Err(reason) => Quote {
            file,
            line: given_line(&line),
            quote,
            ok: false,
            reason: Some(reason),
            commit: String::new(),
            commit_time: None,
            subject: String::new(),
        },
    }
}

fn check_items(basis: &Basis, verdict: &Value, key: &str) -> Vec<Quote> {
    match verdict.get(key) {
        Some(Value::Array(items)) => items.iter().map(|item| check_quote(basis, item)).collect(),
        _ => Vec::new(),
    }
}

/// `Ok` when the commit the reader named is on the ref; the reason otherwise.
fn check_fixing_commit(basis: &Basis, named: &str) -> Result<(), String> {
    if !COMMIT_ID.is_match(named) {
        return Err("is not a commit id".into());
    }
    if !git::ok(basis.dir, &["cat-file", "-e", &format!("{named}^{{commit}}")]) {
        return Err("does not exist in the repo".into());
    }
    if !git::ok(basis.dir, &["merge-base", "--is-ancestor", named, &basis.sha]) {
        return Err(format!("is not on {}", basis.reference));
    }
    Ok(())
}

fn check_with(basis: &Basis, verdict: &Value, created: Option<i64>, known: &[u64]) -> Res<Checked> {
    let number = number_of(verdict).ok_or_else(|| Fail::usage("a verdict needs an issue number"))?;
    let orig = tostr(verdict.get("status"));
    let evidence = check_items(basis, verdict, "evidence");
    let reuse_all = check_items(basis, verdict, "reuse");
    // A likely file that is no repo path is not kept: it would reach the
    // queue's file list and from there a unit's scope.
    let (likely_files, bad_files): (Vec<String>, Vec<String>) = strings(verdict.get("likely_files"))
        .into_iter()
        .partition(|f| repo_path(f).is_ok());
    let bad_file = bad_files.first().and_then(|f| repo_path(f).err());
    let files: BTreeSet<&String> = likely_files
        .iter()
        .chain(evidence.iter().map(|q| &q.file))
        .filter(|f| !f.is_empty())
        .collect();
    let files: Vec<String> = files.into_iter().cloned().collect();
    let protected = files.iter().find(|f| basis.profile.is_protected(f));
    let risk_paths: Vec<String> = files.iter().filter(|f| basis.profile.is_risk(f)).cloned().collect();
    let bad = evidence.iter().find(|q| !q.ok);
    let fix = created.and_then(|created| {
        evidence
            .iter()
            .filter(|q| q.ok && q.commit_time.is_some_and(|t| t > created))
            .max_by_key(|q| q.commit_time)
    });
    let fixing = match tostr(verdict.get("fixing_commit")).as_str() {
        "" => None,
        named => Some(check_fixing_commit(basis, named)),
    };
    let duplicate_of = verdict.get("duplicate_of").and_then(Value::as_u64);
    let duplicate_ok = duplicate_of.is_some_and(|d| d != number && known.contains(&d));
    let no_task = tostr(verdict.get("task")).is_empty() || tostr(verdict.get("acceptance")).is_empty();

    let unclear = |why: String| (String::from("unclear"), Some(why));
    let (status, downgrade_reason) = if !STATUSES.contains(&orig.as_str()) {
        unclear(format!("\"{orig}\" is not a status a reader may return"))
    } else if orig == "needs_human" || orig == "unclear" {
        (orig.clone(), None)
    } else if evidence.is_empty() {
        unclear("no evidence was quoted".into())
    } else if let Some(q) = bad {
        unclear(format!(
            "evidence failed the check: {}:{} {}",
            q.file,
            line_text(&q.line),
            q.reason.as_deref().unwrap_or_default()
        ))
    } else if let Some(why) = bad_file {
        unclear(format!("a likely file {why}"))
    } else if orig == "already_fixed" && created.is_none() {
        unclear("no local record of the issue, so the fix cannot be dated".into())
    } else if orig == "already_fixed" && fix.is_none() {
        unclear("every quoted line is older than the issue, so none of them is its fix".into())
    } else if let (true, Some(Err(why))) = (orig == "already_fixed", &fixing) {
        unclear(format!("the fixing commit the reader named {why}"))
    } else if orig == "already_fixed" {
        // Before the protected-path rule on purpose: nothing is written for an
        // issue that is already fixed, so there is no change for a person to make.
        (orig.clone(), None)
    } else if orig == "duplicate_of" && !duplicate_ok {
        unclear("duplicate_of does not name another issue in this run".into())
    } else if let Some(path) = protected {
        ("needs_human".into(), Some(format!("protected path: {path}")))
    } else if no_task {
        unclear("no task statement or acceptance check".into())
    } else {
        (orig.clone(), None)
    };

    let fix_commit = match (&*status, fix) {
        ("already_fixed", Some(q)) => Some(FixCommit {
            sha: q.commit.clone(),
            date: rfc3339(q.commit_time.unwrap_or_default()),
            subject: q.subject.clone(),
            file: q.file.clone(),
            line: match q.line {
                Line::Number(n) => n,
                Line::Text(_) => 0,
            },
        }),
        _ => None,
    };
    let reuse_dropped = reuse_all.iter().filter(|q| !q.ok).count();
    Ok(Checked {
        number,
        closable: status == "already_fixed" && verdict.get("behavioural") == Some(&Value::Bool(false)),
        status,
        duplicate_of,
        evidence,
        likely_files,
        symbols: strings(verdict.get("symbols")),
        reuse: reuse_all.into_iter().filter(|q| q.ok).collect(),
        change_kind: tostr(verdict.get("change_kind")),
        pattern: tostr(verdict.get("pattern")),
        size: tostr(verdict.get("size")),
        behavioural: verdict.get("behavioural").and_then(Value::as_bool),
        task: tostr(verdict.get("task")),
        acceptance: tostr(verdict.get("acceptance")),
        reason: tostr(verdict.get("reason")),
        original_status: Some(orig),
        downgrade_reason,
        files,
        reuse_dropped,
        fix_commit,
        risk: !risk_paths.is_empty(),
        risk_paths,
        checked_ref: basis.reference.to_string(),
        checked_sha: basis.sha.clone(),
    })
}

/// Re-run the evidence check for ONE verdict against `reference` in the
/// checkout `repo_dir`, and return the result. It reads git and nothing else:
/// no run-folder file is read or written, so a caller (close-verified) can
/// call it on a verdict that was already checked.
///
/// `verdict` is a reader's verdict as JSON, or a serialised [`Checked`]; every
/// field is read leniently and unknown keys are ignored. `created` is when the
/// issue was opened (seconds since the epoch); `None` means there is no local
/// record of it, and then an `already_fixed` verdict cannot be dated and is
/// downgraded. `known` is the issue numbers this run took in, which a
/// `duplicate_of` must name. Fails with exit code 2 when the verdict has no
/// issue number or `reference` does not name a commit.
pub fn check_verdict(
    profile: &Profile,
    repo_dir: &Path,
    reference: &str,
    verdict: &Value,
    created: Option<i64>,
    known: &[u64],
) -> Res<Checked> {
    let basis = basis(profile, repo_dir, reference)?;
    check_with(&basis, verdict, created, known)
}

fn basis<'a>(profile: &'a Profile, dir: &'a Path, reference: &'a str) -> Res<Basis<'a>> {
    let sha = git::commit(dir, reference)
        .ok_or_else(|| Fail::usage(format!("cannot resolve {reference} in {}", dir.display())))?;
    Ok(Basis {
        profile,
        dir,
        reference,
        sha,
    })
}

fn no_verdict(number: u64, basis: &Basis) -> Checked {
    Checked {
        number,
        status: "unclear".into(),
        duplicate_of: None,
        evidence: Vec::new(),
        likely_files: Vec::new(),
        symbols: Vec::new(),
        reuse: Vec::new(),
        change_kind: String::new(),
        pattern: String::new(),
        size: String::new(),
        behavioural: None,
        task: String::new(),
        acceptance: String::new(),
        reason: String::new(),
        original_status: None,
        downgrade_reason: Some("no reader returned a verdict for this issue".into()),
        files: Vec::new(),
        reuse_dropped: 0,
        fix_commit: None,
        closable: false,
        risk: false,
        risk_paths: Vec::new(),
        checked_ref: basis.reference.to_string(),
        checked_sha: basis.sha.clone(),
    }
}

fn read_verdicts(path: &Path) -> Res<Vec<Value>> {
    match read_json::<Value>(path) {
        Some(Value::Array(items)) => Ok(items),
        _ => Err(Fail::usage(format!("not a JSON array of verdicts: {}", path.display()))),
    }
}

fn eligible_numbers(ctx: &Ctx) -> Res<Vec<u64>> {
    let path = ctx.path("intake.json");
    if !path.is_file() {
        return Err(Fail::usage(format!(
            "no intake.json in {}; run intake first",
            ctx.workdir.display()
        )));
    }
    let intake: Value =
        read_json(&path).ok_or_else(|| Fail::usage(format!("intake.json is not valid JSON: {}", path.display())))?;
    Ok(intake
        .get("eligible")
        .and_then(Value::as_array)
        .map(|rows| rows.iter().filter_map(number_of).collect())
        .unwrap_or_default())
}

fn created_at(ctx: &Ctx, number: u64) -> Option<i64> {
    let issue: Value = read_json(&ctx.path(&format!("issues/{number}.json")))?;
    parse_rfc3339(issue.get("createdAt")?.as_str()?)
}

pub fn run(ctx: &Ctx, args: &Args) -> Res<()> {
    let dir = ctx.repo_dir()?;
    let reference = args
        .reference
        .clone()
        .unwrap_or_else(|| format!("origin/{}", ctx.profile.base_branch));
    let out = args.out.clone().unwrap_or_else(|| ctx.path("verdicts.checked.json"));
    if args.inputs.is_empty() {
        return Err(Fail::usage(
            "usage: evidence-check <verdicts.json>... [--ref <ref>] [--out <file>]",
        ));
    }
    let inputs = &args.inputs;
    let known = eligible_numbers(ctx)?;
    let mut all = Vec::new();
    for input in inputs {
        all.extend(read_verdicts(input)?);
    }
    let basis = basis(&ctx.profile, &dir, &reference)?;

    let mut rows: Vec<Checked> = Vec::new();
    let mut dropped = 0;
    for verdict in &all {
        let number = number_of(verdict).filter(|n| known.contains(n));
        let Some(number) = number else {
            let shown = crate::text::clean(&tostr(verdict.get("number")), 40);
            eprintln!(
                "issue-drain evidence-check: dropped a verdict for '#{shown}': this run did not take that issue in"
            );
            dropped += 1;
            continue;
        };
        if rows.iter().any(|r| r.number == number) {
            eprintln!("issue-drain evidence-check: dropped a second verdict for #{number}: the first one stands");
            dropped += 1;
            continue;
        }
        rows.push(check_with(&basis, verdict, created_at(ctx, number), &known)?);
    }
    // Every eligible issue ends with a verdict, even if no reader returned one.
    for number in &known {
        if !rows.iter().any(|r| r.number == *number) {
            rows.push(no_verdict(*number, &basis));
        }
    }
    rows.sort_by_key(|r| r.number);
    write_json(&out, &rows)?;

    let mut by_status: BTreeMap<&str, usize> = BTreeMap::new();
    for row in &rows {
        *by_status.entry(&row.status).or_default() += 1;
    }
    let downgraded = rows.iter().filter(|r| r.downgrade_reason.is_some()).count();
    let summary = json!({
        "verdicts": rows.len(), "dropped": dropped, "downgraded": downgraded, "by_status": by_status,
    });
    let mut event = summary.clone();
    event["ref"] = reference.clone().into();
    event["sha"] = basis.sha.clone().into();
    ctx.event("evidence_check", event)?;
    println!("evidence-check: {summary} -> {}", out.display());
    for row in rows.iter().filter(|r| r.downgrade_reason.is_some()) {
        println!(
            "  #{}: {} -> {} ({})",
            row.number,
            row.original_status.as_deref().unwrap_or("none"),
            row.status,
            row.downgrade_reason.as_deref().unwrap_or_default()
        );
    }
    Ok(())
}
