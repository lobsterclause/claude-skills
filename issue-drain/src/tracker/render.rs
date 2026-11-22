//! `issue-drain tracker render`.
//!
//! The session's decisions.json, held against the checked verdicts, becomes
//! queue.json (what the drain reads) and tracker.md (what a person edits). A
//! queue that breaks a rule is refused with every reason listed, and nothing
//! is written. decisions.json comes from a model, so it is read as loose JSON
//! and every field is validated here.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

use regex::Regex;
use serde_json::{Map, Value, json};

use crate::ctx::{Ctx, read_json, write_atomic, write_json};
use crate::error::{Fail, Res};
use crate::model::{Checked, Eligible, FixCommit, Intake, Line, Queue};
use crate::text::{clean, code, count, repo_path, sha7};

#[derive(clap::Args)]
pub struct Args {
    /// The session's decisions (default: decisions.json in the run folder).
    #[arg(long)]
    pub decisions: Option<PathBuf>,
}

static PR_IN_SUBJECT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\(#([0-9]+)\)\s*$").expect("a fixed pattern"));

/// GitHub's limit on an issue body is 65536; stay under it.
const BODY_LIMIT: usize = 65000;

pub fn run(ctx: &Ctx, args: &Args) -> Res<()> {
    let run = ctx.run_id()?;
    let repo = ctx.repo()?;
    let intake_path = ctx.path("intake.json");
    let checked_path = ctx.path("verdicts.checked.json");
    for path in [&intake_path, &checked_path] {
        if !path.is_file() {
            return Err(Fail::usage(format!(
                "missing {}; run intake and evidence-check first",
                path.display()
            )));
        }
    }
    // Held from the look for tracker.json to the last write: a publish that
    // has seen no tracker.json must find the queue and body it then sends
    // unchanged.
    let _lock = super::io::lock(ctx)?;
    let published = ctx.path("tracker.json");
    if published.exists() {
        let url = read_json::<Value>(&published)
            .and_then(|v| v.get("url").and_then(Value::as_str).map(str::to_string))
            .unwrap_or_default();
        return Err(Fail::refused(format!(
            "this run is already published as {url}; start a new run to triage again"
        )));
    }
    let decisions_path = args.decisions.clone().unwrap_or_else(|| ctx.path("decisions.json"));
    let decisions = fs::read_to_string(&decisions_path)
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .filter(Value::is_object)
        .ok_or_else(|| {
            Fail::usage(format!(
                "no decisions object at {} (see references/triage.md)",
                decisions_path.display()
            ))
        })?;
    let intake: Intake = read_json(&intake_path)
        .ok_or_else(|| Fail::usage(format!("{} is not an intake file", intake_path.display())))?;
    if !intake.repo.eq_ignore_ascii_case(&repo) {
        return Err(Fail::usage(format!(
            "this run's intake is of {}, and ISSUE_DRAIN_REPO is {repo}",
            intake.repo
        )));
    }
    let checked: Vec<Checked> = read_json(&checked_path)
        .ok_or_else(|| Fail::usage(format!("{} is not a list of checked verdicts", checked_path.display())))?;

    let base_sha = checked.first().map(|c| c.checked_sha.clone()).unwrap_or_default();
    let input = Input {
        run: &run,
        repo: &repo,
        base: &ctx.profile.base_branch,
        base_sha: &base_sha,
        perms: &ctx.profile.unit_permissions,
        cluster_max: ctx.profile.cluster_max_issues,
        models: &ctx.profile.allowed_models,
        efforts: &ctx.profile.allowed_efforts,
        ctx,
        intake: &intake,
        checked: &checked,
        decisions: &decisions,
        decisions_path: &decisions_path,
    };
    let result = render(&input)?;

    if !result.errors.is_empty() {
        for error in &result.errors {
            eprintln!("  {error}");
        }
        ctx.event("tracker_render_refused", json!({ "errors": result.errors }))?;
        return Err(Fail::refused(
            "refused: the queue breaks the rules above; fix decisions.json and render again",
        ));
    }
    // The body of an earlier render goes first, so a render cut off between
    // the two writes leaves nothing to publish, not a new queue beside the
    // old body.
    let body_path = ctx.path("tracker.md");
    match fs::remove_file(&body_path) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
            return Err(Fail::failed(format!("cannot replace {}: {e}", body_path.display())));
        }
        _ => {}
    }
    write_json(&ctx.path("queue.json"), &result.queue)?;
    write_atomic(&body_path, result.md.as_bytes())?;
    let size = |key: &str| result.queue[key].as_array().map_or(0, Vec::len);
    let summary = json!({
        "units": size("units"),
        "waits": result.queue["units"].as_array().map_or(0, |u| u.iter().filter(|u| u["waits"] == true).count()),
        "closures": size("closures"),
        "stale_claims": size("stale_claims"),
    });
    ctx.event("tracker_render", summary.clone())?;
    println!("tracker: {summary} -> {}", ctx.path("tracker.md").display());
    Ok(())
}

struct Input<'a> {
    run: &'a str,
    repo: &'a str,
    base: &'a str,
    base_sha: &'a str,
    perms: &'a str,
    cluster_max: usize,
    models: &'a [String],
    efforts: &'a [String],
    ctx: &'a Ctx,
    intake: &'a Intake,
    checked: &'a [Checked],
    decisions: &'a Value,
    decisions_path: &'a Path,
}

struct Rendered {
    errors: Vec<String>,
    queue: Value,
    md: String,
}

/// A unit as the session proposed it, with what the checked verdicts add.
struct Draft {
    issues: Vec<u64>,
    live: Vec<u64>,
    title: String,
    kind: Value,
    size: Value,
    model: Value,
    effort: Value,
    est_minutes: Value,
    test_command: Value,
    files: Vec<String>,
    acceptance: Vec<(u64, String)>,
    reuse: Vec<String>,
    risk: bool,
    risk_paths: Vec<String>,
    waits_for: Value,
    priority: usize,
}

struct ClosureOut {
    number: u64,
    title: String,
    body: String,
    fix_commit: Option<FixCommit>,
    pr: Option<u64>,
    note: String,
}

/// jq's `//`: null and false fall through.
fn truthy(v: Option<&Value>) -> Option<&Value> {
    v.filter(|v| !matches!(v, Value::Null | Value::Bool(false)))
}

/// jq's `tostring`.
fn ts(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

/// A number the way jq prints it: 30.0 is 30.
fn num_text(v: &Value) -> String {
    match v {
        Value::Number(n) => match n.as_f64() {
            Some(f) if f.fract() == 0.0 && f.abs() < 1e15 => format!("{}", f as i64),
            _ => n.to_string(),
        },
        other => ts(other),
    }
}

/// `.[]` over a field the session wrote: an array's items, an object's values,
/// nothing for null or false. Anything else cannot be iterated.
fn items<'a>(v: Option<&'a Value>, path: &Path) -> Res<Vec<&'a Value>> {
    match v {
        None | Some(Value::Null) | Some(Value::Bool(false)) => Ok(Vec::new()),
        Some(Value::Array(a)) => Ok(a.iter().collect()),
        Some(Value::Object(m)) => Ok(m.values().collect()),
        Some(_) => Err(Fail::usage(format!("could not render {}", path.display()))),
    }
}

fn rank(size: &str) -> usize {
    match size {
        "S" => 0,
        "M" => 1,
        "L" => 2,
        _ => 3,
    }
}

fn sorted_unique(mut v: Vec<String>) -> Vec<String> {
    v.sort();
    v.dedup();
    v
}

fn hashes(numbers: &[u64]) -> String {
    numbers.iter().map(|n| format!("#{n}")).collect::<Vec<_>>().join(" ")
}

fn line_text(line: &Line) -> String {
    match line {
        Line::Number(n) => n.to_string(),
        Line::Text(s) => s.clone(),
    }
}

/// Units that share a file run back to back: place a unit, then pull the later
/// units that touch one of its files up behind it.
fn adjacent_order(mut rem: Vec<&Draft>) -> Vec<&Draft> {
    let mut out = Vec::new();
    while !rem.is_empty() {
        let first = rem.remove(0);
        let (friends, rest): (Vec<&Draft>, Vec<&Draft>) = rem
            .into_iter()
            .partition(|d| d.files.iter().any(|f| first.files.contains(f)));
        out.push(first);
        out.extend(friends);
        rem = rest;
    }
    out
}

fn section(title: &str, intro: &str, lines: Vec<String>) -> Vec<String> {
    if lines.is_empty() {
        return Vec::new();
    }
    let mut out = vec![String::new(), format!("## {title}"), String::new()];
    if !intro.is_empty() {
        out.push(intro.to_string());
        out.push(String::new());
    }
    out.extend(lines);
    out
}

fn render(input: &Input) -> Res<Rendered> {
    let path = input.decisions_path;
    let d = input.decisions;
    let el: HashMap<u64, &Eligible> = input.intake.eligible.iter().map(|e| (e.number, e)).collect();
    let ck: HashMap<u64, &Checked> = input.checked.iter().map(|c| (c.number, c)).collect();
    let conf: Vec<(Value, String)> = items(d.get("confirmed_closures"), path)?
        .into_iter()
        .filter_map(|c| match c {
            Value::Number(_) => Some((c.clone(), String::new())),
            Value::Object(m) => Some((
                m.get("number").cloned().unwrap_or(Value::Null),
                truthy(m.get("note")).map(ts).unwrap_or_default(),
            )),
            _ => None,
        })
        .collect();
    let left: Vec<&Map<String, Value>> = items(d.get("left_out"), path)?
        .into_iter()
        .filter_map(Value::as_object)
        .collect();

    let mut errors: Vec<String> = Vec::new();
    let mut drafts: Vec<Draft> = Vec::new();
    for (index, u) in items(d.get("units"), path)?
        .into_iter()
        .filter(|u| u.is_object())
        .enumerate()
    {
        let mut nums: Vec<u64> = Vec::new();
        let mut not_numbers: Vec<String> = Vec::new();
        for it in items(u.get("issues"), path)? {
            if let Value::Number(n) = it {
                match n.as_u64() {
                    Some(n) => nums.push(n),
                    None => not_numbers.push(n.to_string()),
                }
            }
        }
        nums.sort_unstable();
        nums.dedup();
        let vs: Vec<&Checked> = nums.iter().filter_map(|n| ck.get(n).copied()).collect();
        let live_vs: Vec<&&Checked> = vs.iter().filter(|v| v.status == "live").collect();
        let acc = u.get("acceptance").and_then(Value::as_object);
        let title = truthy(u.get("title")).map(ts).unwrap_or_default();

        let files = sorted_unique(match u.get("files") {
            Some(Value::Array(a)) => a.iter().filter_map(Value::as_str).map(str::to_string).collect(),
            _ => vs.iter().flat_map(|v| v.files.iter().cloned()).collect(),
        });
        let size = truthy(u.get("size")).cloned().unwrap_or_else(|| {
            // The largest live issue's size; the last of equals, as jq's max_by.
            let mut best: Option<&str> = None;
            for v in &live_vs {
                if best.is_none_or(|b| rank(&v.size) >= rank(b)) {
                    best = Some(&v.size);
                }
            }
            Value::String(best.unwrap_or("M").to_string())
        });
        let kind = truthy(u.get("kind"))
            .cloned()
            .unwrap_or_else(|| Value::String(live_vs.first().map_or("bugfix", |v| v.change_kind.as_str()).to_string()));
        let acceptance = nums
            .iter()
            .map(|n| {
                let key = n.to_string();
                let text = match truthy(acc.and_then(|a| a.get(&key))) {
                    Some(v) => ts(v),
                    None => ck.get(n).map(|v| v.acceptance.clone()).unwrap_or_default(),
                };
                (*n, text)
            })
            .collect();
        let reuse = sorted_unique(
            vs.iter()
                .flat_map(|v| v.reuse.iter())
                .map(|q| format!("{}:{}", q.file, line_text(&q.line)))
                .collect(),
        );
        // The session may name the unit's files itself, so a risk path is
        // looked for in the final list too and not only in the verdicts.
        let risk_paths = sorted_unique(
            vs.iter()
                .flat_map(|v| v.risk_paths.iter().cloned())
                .chain(files.iter().filter(|f| input.ctx.profile.is_risk(f)).cloned())
                .collect(),
        );
        let draft = Draft {
            live: live_vs.iter().map(|v| v.number).collect(),
            risk: !risk_paths.is_empty() || vs.iter().any(|v| v.risk),
            risk_paths,
            priority: nums
                .iter()
                .map(|n| el.get(n).map_or(99, |e| e.priority))
                .min()
                .unwrap_or(99),
            issues: nums,
            title,
            kind,
            size,
            model: u.get("model").cloned().unwrap_or(Value::Null),
            effort: u.get("effort").cloned().unwrap_or(Value::Null),
            est_minutes: u.get("est_minutes").cloned().unwrap_or(Value::Null),
            test_command: u.get("test_command").cloned().unwrap_or(Value::Null),
            waits_for: truthy(u.get("waits_for")).cloned().unwrap_or(Value::Null),
            files,
            acceptance,
            reuse,
        };
        unit_errors(input, index + 1, &draft, &not_numbers, &ck, &mut errors);
        drafts.push(draft);
    }

    // An issue in two units.
    let mut owners: Vec<(u64, usize)> = Vec::new();
    for (i, draft) in drafts.iter().enumerate() {
        owners.extend(draft.issues.iter().map(|n| (*n, i)));
    }
    owners.sort_by_key(|(n, _)| *n);
    let mut seen: Vec<u64> = Vec::new();
    for pair in owners.windows(2) {
        if pair[0].0 == pair[1].0 && !seen.contains(&pair[0].0) {
            seen.push(pair[0].0);
            errors.push(format!("#{} is in more than one unit", pair[0].0));
        }
    }

    // Closures.
    for (number, _) in &conf {
        let n = number.as_u64().and_then(|n| ck.get_key_value(&n));
        match n.map(|(_, v)| v) {
            None => errors.push(format!("closure #{}: not taken in by this run", ts(number))),
            Some(v) if v.status != "already_fixed" => {
                errors.push(format!(
                    "closure #{}: it is {}, not already_fixed",
                    ts(number),
                    v.status
                ));
            }
            Some(v) if !v.closable => errors.push(format!(
                "closure #{}: the bug is behavioural, so a code reading cannot close it",
                ts(number)
            )),
            Some(_) => {}
        }
    }

    // Every live issue is in a unit or has a reason.
    let queued: Vec<u64> = drafts.iter().flat_map(|u| u.issues.iter().copied()).collect();
    for v in input
        .checked
        .iter()
        .filter(|v| v.status == "live" || v.status == "duplicate_of")
    {
        let excused = left.iter().any(|l| {
            l.get("number").and_then(Value::as_u64) == Some(v.number)
                && truthy(l.get("reason")).is_some_and(|r| !ts(r).is_empty())
        });
        let is_queued = queued.contains(&v.number);
        if is_queued && excused {
            errors.push(format!("#{} is both in a unit and in left_out", v.number));
        } else if !is_queued && !excused {
            errors.push(format!(
                "#{} is {} but in no unit; queue it, or give the reason in left_out",
                v.number, v.status
            ));
        }
    }
    for l in &left {
        let known = l
            .get("number")
            .and_then(Value::as_u64)
            .is_some_and(|n| ck.contains_key(&n));
        if !known {
            let named = truthy(l.get("number")).map_or("nothing".to_string(), ts);
            errors.push(format!("left_out names #{named}, which this run did not take in"));
        }
    }
    if !errors.is_empty() {
        // Nothing is written, so there is no body to size.
        return Ok(Rendered {
            errors,
            queue: Value::Null,
            md: String::new(),
        });
    }

    let mut sorted: Vec<&Draft> = drafts.iter().collect();
    sorted.sort_by_key(|u| {
        (
            u.priority,
            rank(u.size.as_str().unwrap_or("")),
            u.issues.iter().min().copied(),
        )
    });
    let (risky, plain): (Vec<&Draft>, Vec<&Draft>) = sorted.into_iter().partition(|u| u.risk);
    let all: Vec<&Draft> = adjacent_order(plain).into_iter().chain(risky).collect();

    let mut closures: Vec<ClosureOut> = Vec::new();
    for (number, note) in &conf {
        let Some(n) = number.as_u64() else { continue };
        let Some(v) = ck.get(&n) else { continue };
        if v.status != "already_fixed" || !v.closable {
            continue;
        }
        let pr = v.fix_commit.as_ref().and_then(|f| {
            PR_IN_SUBJECT
                .captures(&f.subject)
                .and_then(|c| c[1].parse::<u64>().ok())
        });
        // The report as intake saved it goes into the queue: close-verified
        // holds the live issue against this copy, which nothing writes again.
        let saved_path = input.ctx.path(&format!("issues/{n}.json"));
        let saved: Value = read_json(&saved_path).ok_or_else(|| {
            Fail::usage(format!(
                "missing {}; a closure needs the report intake saved",
                saved_path.display()
            ))
        })?;
        let text = |key: &str| saved[key].as_str().unwrap_or_default().to_string();
        closures.push(ClosureOut {
            number: n,
            title: text("title"),
            body: text("body"),
            fix_commit: v.fix_commit.clone(),
            pr,
            note: note.clone(),
        });
    }

    let md = body(input, &all, &closures, &el);
    let length = md.chars().count();
    if length > BODY_LIMIT {
        errors.push(format!(
            "the tracker body is {length} characters; GitHub allows 65536. Take fewer issues in one run"
        ));
    }

    let title = format!(
        "issue-drain: {} and {} from {} ({})",
        count(all.len(), "unit"),
        count(closures.len(), "closure"),
        count(input.intake.eligible.len(), "issue"),
        input.run
    );
    let units: Vec<Value> = all.iter().enumerate().map(|(i, u)| unit_json(i, u)).collect();
    let closures_json: Vec<Value> = closures
        .iter()
        .map(|c| closure_json(c, ck.get(&c.number).copied()))
        .collect();
    let mut queue = Map::new();
    queue.insert("version".into(), json!(1));
    queue.insert("run".into(), json!(input.run));
    queue.insert("repo".into(), json!(input.repo));
    queue.insert("base".into(), json!(input.base));
    queue.insert("base_sha".into(), json!(input.base_sha));
    queue.insert("units".into(), Value::Array(units));
    queue.insert("closures".into(), Value::Array(closures_json));
    queue.insert(
        "stale_claims".into(),
        serde_json::to_value(&input.intake.stale_claims).expect("plain data"),
    );
    queue.insert("title".into(), json!(title));
    // close-verified and the tracker commands read queue.json as a Queue, so
    // one that does not read back is never written.
    let queue = Value::Object(queue);
    if let Err(e) = serde_json::from_value::<Queue>(queue.clone()) {
        return Err(Fail::failed(format!("the rendered queue does not read back: {e}")));
    }
    Ok(Rendered { errors, queue, md })
}

fn unit_errors(
    input: &Input,
    number: usize,
    u: &Draft,
    not_numbers: &[String],
    ck: &HashMap<u64, &Checked>,
    errors: &mut Vec<String>,
) {
    let name = format!("unit {number} ({})", clean(&u.title, 60));
    let mut push = |msg: String| errors.push(format!("{name}: {msg}"));
    if u.issues.is_empty() {
        push("names no issue".into());
    }
    if u.issues.len() > input.cluster_max {
        push(format!(
            "{} issues in one unit; the cap is {}",
            u.issues.len(),
            input.cluster_max
        ));
    }
    if !u.issues.is_empty() && u.live.is_empty() {
        push("has no live issue; a unit needs one issue to fix".into());
    }
    for bad in not_numbers {
        push(format!("#{bad} was not taken in by this run"));
    }
    for n in &u.issues {
        match ck.get(n) {
            None => push(format!("#{n} was not taken in by this run")),
            Some(v) if v.status == "live" => {}
            Some(v) if v.status == "duplicate_of" => match v.duplicate_of {
                Some(original) if u.issues.contains(&original) => {
                    // Follow the duplicates to the issue that gets fixed. Two
                    // that name each other lead nowhere.
                    let mut seen = vec![*n];
                    let mut at = original;
                    let dead_end = loop {
                        if seen.contains(&at) || !u.issues.contains(&at) {
                            break true;
                        }
                        seen.push(at);
                        match ck.get(&at) {
                            Some(next) if next.status == "duplicate_of" => match next.duplicate_of {
                                Some(further) => at = further,
                                None => break true,
                            },
                            // Live, or refused under its own number.
                            _ => break false,
                        }
                    };
                    if dead_end {
                        push(format!(
                            "#{n} duplicates #{original}, and following the duplicates from there never reaches a live issue in this unit"
                        ));
                    }
                }
                other => push(format!(
                    "#{n} duplicates #{}, which is not in this unit",
                    other.map_or("null".to_string(), |o| o.to_string())
                )),
            },
            Some(v) => push(format!("#{n} is {}, not live", v.status)),
        }
    }
    if u.risk && u.live.len() > 1 {
        push(format!(
            "touches a risk path ({}) and has more than one live issue; a risk-path issue shares a unit only with its own duplicates",
            u.risk_paths.join(", ")
        ));
    }
    if u.risk && (u.waits_for.is_null() || ts(&u.waits_for).is_empty()) {
        push(format!(
            "touches a risk path ({}); name who reviews its PR in waits_for",
            u.risk_paths.join(", ")
        ));
    }
    for file in &u.files {
        // A folder is a repo path with one trailing slash, which stays.
        if let Err(why) = repo_path(file.strip_suffix('/').unwrap_or(file)) {
            push(format!("names a file that {why} ({})", clean(file, 80)));
        } else if input.ctx.profile.is_protected(file) {
            push(format!("names a protected path ({file}); that work needs a person"));
        }
    }
    if u.title.is_empty() {
        push("no title".into());
    }
    let allowed = |value: &Value, list: &[String]| value.as_str().is_some_and(|s| list.iter().any(|a| a == s));
    let got = |value: &Value| truthy(Some(value)).map_or("none".to_string(), ts);
    if !allowed(&u.model, input.models) {
        push(format!(
            "model must be one of {} (got {})",
            input.models.join(" "),
            got(&u.model)
        ));
    }
    if !allowed(&u.effort, input.efforts) {
        push(format!(
            "effort must be one of {} (got {})",
            input.efforts.join(" "),
            got(&u.effort)
        ));
    }
    // queue.json is typed (model::Unit), so each field has its type here.
    if u.est_minutes.as_u64().is_none_or(|m| m == 0) {
        push("est_minutes must be a whole number above 0".into());
    }
    if u.kind.as_str().is_none_or(str::is_empty) {
        push("kind must be a word such as bugfix".into());
    }
    if !(u.waits_for.is_null() || u.waits_for.is_string()) {
        push("waits_for must be text or left out".into());
    }
    if !u.size.as_str().is_some_and(|s| ["S", "M", "L", "XL"].contains(&s)) {
        push("size must be S, M, L or XL".into());
    }
    let command = u.test_command.as_str().unwrap_or_default();
    if command.is_empty() || command.contains(['\n', '\r']) {
        push("test_command must be one non-empty line".into());
    }
    for (n, text) in &u.acceptance {
        if ck.contains_key(n) && text.is_empty() {
            push(format!("no acceptance check for #{n}"));
        }
    }
}

fn unit_json(index: usize, u: &Draft) -> Value {
    let mut m = Map::new();
    m.insert("id".into(), json!(format!("U{}", index + 1)));
    m.insert("issues".into(), json!(u.issues));
    m.insert("live".into(), json!(u.live));
    m.insert("title".into(), json!(u.title));
    m.insert("kind".into(), u.kind.clone());
    m.insert("size".into(), u.size.clone());
    m.insert("model".into(), u.model.clone());
    m.insert("effort".into(), u.effort.clone());
    m.insert("est_minutes".into(), u.est_minutes.clone());
    m.insert("test_command".into(), u.test_command.clone());
    m.insert("files".into(), json!(u.files));
    let acceptance: Map<String, Value> = u.acceptance.iter().map(|(n, t)| (n.to_string(), json!(t))).collect();
    m.insert("acceptance".into(), Value::Object(acceptance));
    m.insert("reuse".into(), json!(u.reuse));
    m.insert("risk".into(), json!(u.risk));
    m.insert("risk_paths".into(), json!(u.risk_paths));
    m.insert("waits".into(), json!(u.risk));
    m.insert("waits_for".into(), u.waits_for.clone());
    m.insert("priority".into(), json!(u.priority));
    Value::Object(m)
}

fn closure_json(c: &ClosureOut, verdict: Option<&Checked>) -> Value {
    let evidence: Vec<Value> = verdict
        .map(|v| {
            v.evidence
                .iter()
                .map(|q| json!({ "file": q.file, "line": q.line, "quote": q.quote }))
                .collect()
        })
        .unwrap_or_default();
    json!({
        "number": c.number,
        "title": c.title,
        "body": c.body,
        "fix_commit": c.fix_commit,
        "pr": c.pr,
        "evidence": evidence,
        "note": c.note,
    })
}

fn body(input: &Input, all: &[&Draft], closures: &[ClosureOut], el: &HashMap<u64, &Eligible>) -> String {
    let title_of = |n: u64| clean(el.get(&n).map_or("", |e| e.title.as_str()), 100);
    let info = |n: u64, why: &str| format!("- #{n} · {} · {}", title_of(n), clean(why, 240));
    let unit_line = |id: usize, u: &Draft| {
        format!(
            "U{id} · {} · {} · {}/{} · ~{} min",
            hashes(&u.issues),
            clean(&u.title, 100),
            ts(&u.model),
            ts(&u.effort),
            num_text(&u.est_minutes)
        )
    };
    let numbered: Vec<(usize, &Draft)> = all.iter().enumerate().map(|(i, u)| (i + 1, *u)).collect();
    let command = |u: &Draft| code(&ts(&u.test_command), 160);

    let mut lines: Vec<String> = vec![
        format!("<!-- issue-drain:tracker v1 run={} -->", input.run),
        format!(
            "This is the queue for an issue drain of `{}` into `{}`. Nothing has been changed yet: no issue is claimed, labelled or closed until you say go.",
            input.repo, input.base
        ),
        String::new(),
        "To change what runs, edit this body:".into(),
        String::new(),
        "- Delete a line under **Queue** to drop that unit. Move lines to reorder them.".into(),
        "- Tick a box to approve that item. An unticked box means no.".into(),
        "- Put the word `STOP` on a line of its own, anywhere in this body, to stop the drain once the unit in progress has finished.".into(),
        String::new(),
        "The drain reads this body at the start of each unit and never edits it. Progress is posted as comments.".into(),
        String::new(),
        format!(
            "Base `{}` at `{}` · {} issues taken in · {} units · permissions: {}",
            input.base,
            sha7(input.base_sha),
            input.intake.eligible.len(),
            all.len(),
            clean(input.perms, 200)
        ),
        String::new(),
        "## Queue".into(),
        String::new(),
    ];
    let queue: Vec<String> = numbered
        .iter()
        .filter(|(_, u)| !u.risk)
        .map(|(id, u)| format!("- {} · {}", unit_line(*id, u), command(u)))
        .collect();
    if queue.is_empty() {
        lines.push("No units.".into());
    } else {
        lines.extend(queue);
    }

    lines.extend(section(
        "Close as already fixed (tick to approve)",
        "Each was read twice against the base branch. The closing comment quotes the lines and names the fixing commit.",
        closures
            .iter()
            .map(|c| {
                let (sha, place) = c.fix_commit.as_ref().map_or((String::new(), String::new()), |f| {
                    (sha7(&f.sha).to_string(), format!("{}:{}", f.file, f.line))
                });
                format!(
                    "- [ ] close #{} · {} · fixed by `{}`{} · {}{}",
                    c.number,
                    clean(&c.title, 100),
                    sha,
                    c.pr.map_or(String::new(), |pr| format!(" (#{pr})")),
                    code(&place, 160),
                    if c.note.is_empty() {
                        String::new()
                    } else {
                        format!(" · {}", clean(&c.note, 200))
                    }
                )
            })
            .collect(),
    ));
    lines.extend(section(
        "Units that open a PR and then wait for a person (tick to include)",
        "Each touches a path that needs a named reviewer. A ticked unit runs before the queue, opens its PR and waits there, so the review can start while the rest drains.",
        numbered
            .iter()
            .filter(|(_, u)| u.risk)
            .map(|(id, u)| {
                format!(
                    "- [ ] {} · waits for: {} · {}",
                    unit_line(*id, u),
                    clean(&ts(&u.waits_for), 80),
                    command(u)
                )
            })
            .collect(),
    ));
    lines.extend(section(
        "Stale claims (tick to release)",
        "These carry the claim label and have no open PR. Releasing one removes the label and nothing else.",
        input
            .intake
            .stale_claims
            .iter()
            .map(|s| {
                format!(
                    "- [ ] release #{} · {} · {}, no open PR",
                    s.number,
                    clean(&s.title, 100),
                    s.days
                        .map_or("claim age unknown".to_string(), |d| format!("claimed {d} days ago"))
                )
            })
            .collect(),
    ));
    let why = |c: &Checked| c.downgrade_reason.clone().unwrap_or_else(|| c.reason.clone());
    let with_status = |status: &'static str| input.checked.iter().filter(move |c| c.status == status);
    lines.extend(section(
        "Needs a person",
        "",
        with_status("needs_human").map(|c| info(c.number, &why(c))).collect(),
    ));
    let closed: Vec<u64> = closures.iter().map(|c| c.number).collect();
    lines.extend(section(
        "Needs verification",
        "Code that looks like the fix is on the base branch, but nothing here closes these.",
        with_status("already_fixed")
            .filter(|c| !closed.contains(&c.number))
            .map(|c| {
                let (sha, subject) = c.fix_commit.as_ref().map_or((String::new(), String::new()), |f| {
                    (sha7(&f.sha).to_string(), f.subject.clone())
                });
                let tail = if c.closable {
                    "Not confirmed on a second read."
                } else {
                    "The bug is behavioural, so it needs a look in the running app."
                };
                info(c.number, &format!("looks fixed by {sha} ({subject}). {tail}"))
            })
            .collect(),
    ));
    lines.extend(section(
        "Unclear",
        "",
        with_status("unclear").map(|c| info(c.number, &why(c))).collect(),
    ));
    let left = items(input.decisions.get("left_out"), input.decisions_path).unwrap_or_default();
    lines.extend(section(
        "Not queued",
        "",
        left.iter()
            .filter_map(|l| {
                let n = l.get("number")?.as_u64()?;
                let reason = truthy(l.get("reason")).map_or("no reason given".to_string(), ts);
                Some(info(n, &reason))
            })
            .collect(),
    ));
    lines.extend(section(
        "Skipped at intake",
        "",
        input
            .intake
            .skipped
            .iter()
            .map(|s| format!("- #{} · {} · {}", s.number, clean(&s.title, 100), clean(&s.reason, 240)))
            .collect(),
    ));
    if !all.is_empty() {
        lines.extend([String::new(), super::io::DETAILS_OPEN.into(), String::new()]);
        for (id, u) in &numbered {
            lines.push(format!(
                "**U{id}** · {} · {} · size {}",
                hashes(&u.issues),
                clean(&ts(&u.kind), 20),
                ts(&u.size)
            ));
            lines.push(String::new());
            for (n, text) in &u.acceptance {
                lines.push(format!("- #{n}: {}", clean(text, 300)));
            }
            if !u.files.is_empty() {
                let files: Vec<String> = u.files.iter().map(|f| code(f, 160)).collect();
                lines.push(format!("- files: {}", files.join(", ")));
            }
            if !u.reuse.is_empty() {
                let reuse: Vec<String> = u.reuse.iter().map(|r| code(r, 160)).collect();
                lines.push(format!("- reuse: {}", reuse.join(", ")));
            }
            lines.push(String::new());
        }
        lines.push(super::io::DETAILS_CLOSE.into());
    }
    lines.join("\n") + "\n"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jq_alternative_skips_only_null_and_false() {
        assert!(truthy(Some(&json!(""))).is_some());
        assert!(truthy(Some(&json!(0))).is_some());
        assert!(truthy(Some(&json!(null))).is_none());
        assert!(truthy(Some(&json!(false))).is_none());
        assert!(truthy(None).is_none());
    }

    #[test]
    fn numbers_print_the_way_jq_prints_them() {
        assert_eq!(num_text(&json!(30)), "30");
        assert_eq!(num_text(&json!(30.0)), "30");
        assert_eq!(num_text(&json!(30.5)), "30.5");
    }

    #[test]
    fn units_that_share_a_file_are_pulled_together() {
        let draft = |file: &str| Draft {
            issues: vec![],
            live: vec![],
            title: file.into(),
            kind: Value::Null,
            size: Value::Null,
            model: Value::Null,
            effort: Value::Null,
            est_minutes: Value::Null,
            test_command: Value::Null,
            files: vec![file.into()],
            acceptance: vec![],
            reuse: vec![],
            risk: false,
            risk_paths: vec![],
            waits_for: Value::Null,
            priority: 0,
        };
        let (a, b, c) = (draft("a"), draft("b"), draft("a"));
        let order: Vec<&str> = adjacent_order(vec![&a, &b, &c])
            .iter()
            .map(|d| d.title.as_str())
            .collect();
        assert_eq!(order, ["a", "a", "b"]);
    }
}
