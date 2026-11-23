//! `issue-drain retro [--publish]`: the run's retrospective, from local files
//! only: `events.jsonl` (the state events and the commands' own lines), each
//! unit's `result.json`, `session.json` and `deliver.json`, and `queue.json`
//! for the size and kind of each unit.
//!
//! It writes `retro.md` (a table, totals and proposals) and `retro.json` (the
//! same facts for a program) in the run folder, prints the path of
//! `retro.json` and a one-line summary. A value no file recorded is a dash in
//! the table and `null` in the JSON: nothing is guessed. Cost is the sum of the
//! sessions' reported costs and is labelled an estimate.
//!
//! The proposals only propose. Nothing is filed and no profile is changed.
//!
//! `--publish` posts `retro.md` as a comment on the tracker issue
//! (`tracker.json`), through `gh::write`; a dry run prints the `WOULD` line and
//! posts nothing. Without it nothing leaves the machine. A unit process is
//! refused either way.
//!
//! Exit: 0 done; 2 `--publish` with no `tracker.json`; 3 a unit process asked;
//! 1 a file or the comment could not be written.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;

use serde_json::{Map, Value, json};

use crate::ctx::{Ctx, parse_rfc3339, read_json, rfc3339, write_atomic, write_json};
use crate::error::{Fail, Res};
use crate::gh::{self, Write};
use crate::state::{Event, Snapshot, State};
use crate::tracker::io::Published;

#[derive(clap::Args)]
pub struct Args {
    /// Post the retro as a comment on the tracker (through gh-write).
    #[arg(long)]
    pub publish: bool,
}

const DASH: &str = "-";

/// What the event log says about one unit.
#[derive(Default)]
struct Log {
    /// Timestamps (epoch seconds) of the unit's state events, in order.
    stamps: Vec<i64>,
    /// Refusal codes the merge gate gave, with how often.
    refusals: BTreeMap<String, u64>,
    /// How many times the gate ran for it.
    gate_runs: u64,
}

struct Replayed {
    snapshot: Snapshot,
    logs: BTreeMap<u64, Log>,
    /// First and last timestamp of any line.
    span: Option<(i64, i64)>,
}

/// Fold the log. Lines the state rules refuse are skipped here: `state
/// rebuild` is where a bad log is reported, and a retro is read-only.
fn replay(ctx: &Ctx) -> Replayed {
    let text = fs::read_to_string(ctx.path("events.jsonl")).unwrap_or_default();
    let mut out = Replayed {
        snapshot: Snapshot::default(),
        logs: BTreeMap::new(),
        span: None,
    };
    for line in text.lines() {
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let stamp = value["ts"].as_str().and_then(parse_rfc3339);
        if let Some(t) = stamp {
            out.span = Some(out.span.map_or((t, t), |(a, b)| (a.min(t), b.max(t))));
        }
        let unit = value["unit"].as_u64();
        match value["event"].as_str() {
            Some("merge_gate") => {
                if let Some(n) = unit {
                    let log = out.logs.entry(n).or_default();
                    log.gate_runs += 1;
                    for code in value["refusals"].as_array().into_iter().flatten() {
                        let code = code.as_str().or_else(|| code["code"].as_str());
                        if let Some(code) = code {
                            *log.refusals.entry(code.to_string()).or_default() += 1;
                        }
                    }
                }
            }
            Some(_) => {}
            None => {
                let Ok(ev) = serde_json::from_value::<Event>(value) else {
                    continue;
                };
                if out.snapshot.apply(&ev).is_ok() {
                    if let (Some(n), Some(t)) = (ev.unit, stamp) {
                        out.logs.entry(n).or_default().stamps.push(t);
                    }
                }
            }
        }
    }
    out
}

fn unit_file(ctx: &Ctx, unit: u64, name: &str) -> Option<Value> {
    read_json(&ctx.path(&format!("units/{unit}/{name}")))
}

/// The unit numbers the run knows: the replayed queue and the unit folders.
fn unit_numbers(ctx: &Ctx, snapshot: &Snapshot) -> Vec<u64> {
    let mut all: BTreeSet<u64> = snapshot.units.iter().map(|u| u.unit).collect();
    for entry in fs::read_dir(ctx.path("units")).into_iter().flatten().flatten() {
        if let Some(n) = entry.file_name().to_str().and_then(|s| s.parse().ok()) {
            all.insert(n);
        }
    }
    all.into_iter().collect()
}

/// A line of the queue for the unit: its size and kind.
fn queue_entry(queue: &Option<Value>, unit: u64) -> (Option<String>, Option<String>) {
    let id = format!("U{unit}");
    let entry = queue
        .as_ref()
        .and_then(|q| q["units"].as_array())
        .and_then(|units| units.iter().find(|u| u["id"] == id));
    let text = |key: &str| entry.and_then(|e| e[key].as_str()).map(str::to_string);
    (text("size"), text("kind"))
}

fn as_text(v: &Value) -> String {
    v.as_str().map_or_else(|| v.to_string(), str::to_string)
}

/// Everything the retro says about one unit.
struct UnitRetro {
    json: Value,
    state: Option<State>,
    size: Option<String>,
    kind: Option<String>,
    first_model: Option<String>,
    last_model: Option<String>,
    attempts: usize,
    tier_ups: usize,
    resumes: usize,
    cost: Option<f64>,
    refusals: u64,
    base_syncs: Option<u32>,
    changed: Option<(u64, u64)>,
    wall: Option<i64>,
    limits: Vec<String>,
    shortcuts: Vec<String>,
}

fn unit_retro(ctx: &Ctx, replayed: &Replayed, queue: &Option<Value>, unit: u64) -> UnitRetro {
    let snap = replayed.snapshot.units.iter().find(|u| u.unit == unit);
    let log = replayed.logs.get(&unit);
    let state = snap.map(|u| u.state);
    let (size, kind) = queue_entry(queue, unit);
    let result = unit_file(ctx, unit, "result.json");
    let session = unit_file(ctx, unit, "session.json");
    let deliver = unit_file(ctx, unit, "deliver.json");

    let attempts: Option<&Vec<Value>> = session.as_ref().and_then(|s| s["attempts"].as_array());
    let model_of = |a: &Value| a["model"].as_str().map(str::to_string);
    let first_model = attempts.and_then(|a| a.first()).and_then(model_of);
    let last_model = attempts.and_then(|a| a.iter().rev().find_map(model_of));
    let tier_ups = attempts.map_or(0, |list| {
        list.iter()
            .filter(|a| model_of(a).is_some() && model_of(a) != first_model)
            .count()
    });
    let resumes = attempts.map_or(0, |list| list.iter().filter(|a| a["resumed"] == true).count());
    let costs: Vec<f64> = attempts
        .into_iter()
        .flatten()
        .filter_map(|a| a["cost_usd"].as_f64())
        .collect();
    let cost = (!costs.is_empty()).then(|| costs.iter().sum());
    let mut models: Vec<String> = Vec::new();
    for a in attempts.into_iter().flatten() {
        if let Some(m) = model_of(a) {
            let label = match a["effort"].as_str() {
                Some(e) => format!("{m}/{e}"),
                None => m,
            };
            if !models.contains(&label) {
                models.push(label);
            }
        }
    }

    let wall = match (state, log) {
        (Some(s), Some(l)) if s.is_terminal() && l.stamps.len() > 1 => Some(l.stamps[l.stamps.len() - 1] - l.stamps[0]),
        _ => None,
    };
    let refusals: u64 = log.map_or(0, |l| l.refusals.values().sum());
    let gate: Value = match log {
        Some(l) if l.gate_runs > 0 => json!({"runs": l.gate_runs, "refusals": l.refusals}),
        _ => Value::Null,
    };
    let changed = deliver.as_ref().and_then(|d| {
        let n = |key: &str| d[key].as_u64();
        Some((n("additions")?, n("deletions")?))
    });
    let review = result.as_ref().map(|r| &r["review"]).filter(|r| r.is_object());

    let limits: Vec<String> = result
        .as_ref()
        .and_then(|r| r["known_limits"].as_array())
        .into_iter()
        .flatten()
        .map(as_text)
        .collect();
    // Shortcuts: the notes a unit wrote as `shortcut: ...` and the
    // `shortcut:` comments deliver-check found in the diff.
    let mut shortcuts: Vec<String> = result
        .as_ref()
        .and_then(|r| r["notes"].as_array())
        .into_iter()
        .flatten()
        .map(as_text)
        .filter(|n| n.trim_start().starts_with("shortcut:"))
        .collect();
    for s in deliver
        .as_ref()
        .and_then(|d| d["flags"]["shortcuts"].as_array())
        .into_iter()
        .flatten()
    {
        if let Some(text) = s["text"].as_str() {
            let file = s["file"].as_str().unwrap_or_default();
            shortcuts.push(format!("{} ({file})", text.trim()));
        }
    }

    let json = json!({
        "unit": unit,
        "issues": snap.map(|u| u.issues.clone()),
        "size": size,
        "kind": kind,
        "state": state.map(State::as_str),
        "pr": snap.and_then(|u| u.pr),
        "wall_secs": wall,
        "cost_usd_estimate": cost,
        "models": attempts.map(|_| models.clone()),
        "attempts": attempts.map(Vec::len),
        "escalations": attempts.map(|_| json!({"tier_ups": tier_ups, "resumes": resumes})),
        "outcome": result.as_ref().and_then(|r| r["outcome"].as_str()),
        "review": review.map(|r| json!({"passes": r["passes"], "verdict": r["verdict"]})),
        "gate": gate,
        "base_syncs": snap.map(|u| u.base_syncs),
        "changed_lines": changed.map(|(a, d)| json!({"additions": a, "deletions": d})),
        "known_limits": limits,
        "shortcuts": shortcuts,
    });
    UnitRetro {
        json,
        state,
        size,
        kind,
        first_model,
        last_model,
        attempts: attempts.map_or(0, Vec::len),
        tier_ups,
        resumes,
        cost,
        refusals,
        base_syncs: snap.map(|u| u.base_syncs),
        changed,
        wall,
        limits,
        shortcuts,
    }
}

fn duration(secs: i64) -> String {
    let secs = secs.max(0);
    match secs {
        0..=59 => format!("{secs}s"),
        60..=3599 => format!("{}m", secs / 60),
        _ => format!("{}h{:02}m", secs / 3600, secs % 3600 / 60),
    }
}

fn cell(text: &str) -> String {
    text.replace('|', "\\|").replace('\n', " ")
}

fn row(u: &UnitRetro) -> String {
    let j = &u.json;
    let or_dash = |s: Option<String>| s.unwrap_or_else(|| DASH.to_string());
    let issues = j["issues"].as_array().map(|list| {
        let numbers: Vec<String> = list.iter().map(|n| format!("#{n}")).collect();
        numbers.join(" ")
    });
    let models = j["models"]
        .as_array()
        .filter(|m| !m.is_empty())
        .map(|m| m.iter().map(as_text).collect::<Vec<_>>().join(", "));
    let escalations = j["escalations"].as_object().map(|_| {
        let n = u.tier_ups + u.resumes;
        if n == 0 {
            "0".to_string()
        } else {
            format!("{n} ({} tier-up, {} resume)", u.tier_ups, u.resumes)
        }
    });
    let review = j["review"].as_object().map(|r| {
        let passes = r["passes"]
            .as_u64()
            .map_or(DASH.to_string(), |p| format!("{p} pass(es)"));
        let verdict = r["verdict"].as_str().unwrap_or(DASH);
        format!("{passes}, {verdict}")
    });
    let gate = j["gate"].as_object().map(|g| {
        let refusals = g["refusals"].as_object().cloned().unwrap_or_default();
        if refusals.is_empty() {
            "none".to_string()
        } else {
            refusals
                .iter()
                .map(|(code, n)| format!("{code} x{n}"))
                .collect::<Vec<_>>()
                .join(", ")
        }
    });
    let cells = [
        format!("U{}", j["unit"]),
        or_dash(issues),
        or_dash(u.state.map(|s| s.as_str().to_string())),
        or_dash(u.wall.map(duration)),
        or_dash(u.cost.map(|c| format!("${c:.2}"))),
        or_dash(models),
        or_dash(escalations),
        or_dash(review),
        or_dash(gate),
        or_dash(u.base_syncs.map(|n| n.to_string())),
        or_dash(u.changed.map(|(a, d)| format!("+{a}/-{d}"))),
        or_dash((!u.limits.is_empty()).then(|| u.limits.len().to_string())),
    ];
    let cells: Vec<String> = cells.iter().map(|c| cell(c)).collect();
    format!("| {} |", cells.join(" | "))
}

fn describe(u: &UnitRetro) -> String {
    match (&u.size, &u.kind) {
        (Some(s), Some(k)) => format!("{s} {k} units"),
        (Some(s), None) => format!("{s} units"),
        (None, Some(k)) => format!("{k} units"),
        (None, None) => format!("units like U{}", u.json["unit"]),
    }
}

/// Routing proposals: a tier-up asks for a higher start; a first-try finish
/// on the cheapest tier asks to keep it.
fn routing(units: &[UnitRetro]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for u in units {
        let n = &u.json["unit"];
        let line = if u.tier_ups > 0 {
            let (from, to) = (
                u.first_model.as_deref().unwrap_or(DASH),
                u.last_model.as_deref().unwrap_or(DASH),
            );
            format!(
                "Proposal: start {} one tier above {from}. U{n} began on {from} and needed {to}.",
                describe(u)
            )
        } else if u.state == Some(State::Done)
            && u.attempts == 1
            && u.first_model.as_deref().is_some_and(|m| m.contains("haiku"))
        {
            format!(
                "Proposal: keep {} on {}. U{n} finished on its first attempt there.",
                describe(u),
                u.first_model.as_deref().unwrap_or(DASH)
            )
        } else {
            continue;
        };
        if !out.contains(&line) {
            out.push(line);
        }
    }
    out
}

fn follow_ups(units: &[UnitRetro]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for u in units {
        let n = &u.json["unit"];
        let lines = u
            .limits
            .iter()
            .map(|l| format!("Proposal: open a follow-up issue for U{n}'s known limit: {l}"))
            .chain(
                u.shortcuts
                    .iter()
                    .map(|s| format!("Proposal: open a follow-up issue for U{n}'s shortcut: {s}")),
            );
        for line in lines {
            if !out.contains(&line) {
                out.push(line);
            }
        }
    }
    out
}

fn markdown(
    run: &str,
    generated: &str,
    units: &[UnitRetro],
    totals: &Value,
    routing: &[String],
    ups: &[String],
) -> String {
    let mut md = vec![
        format!("# Retro: run {run}"),
        String::new(),
        format!(
            "Generated {generated} from the run's local files. A dash means no file recorded the value. Cost is an estimate: the sum of the costs the sessions reported."
        ),
        String::new(),
        "## Units".to_string(),
        String::new(),
        "| Unit | Issues | State | Wall time | Cost (est.) | Models | Escalations | Review | Gate refusals | Base syncs | Changed lines | Known limits |".to_string(),
        format!("|{}", " --- |".repeat(12)),
    ];
    md.extend(units.iter().map(row));
    let t = |key: &str| totals[key].clone();
    let states: Vec<String> = totals["by_state"]
        .as_object()
        .into_iter()
        .flatten()
        .map(|(s, n)| format!("{n} {s}"))
        .collect();
    md.extend([
        String::new(),
        "## Run totals".to_string(),
        String::new(),
        format!(
            "- Units: {}{}",
            t("units"),
            if states.is_empty() {
                String::new()
            } else {
                format!(" ({})", states.join(", "))
            }
        ),
        format!(
            "- Cost (estimate): {}",
            totals["cost_usd_estimate"]
                .as_f64()
                .map_or(DASH.to_string(), |c| format!("${c:.2}"))
        ),
        format!("- Session attempts: {}", t("attempts")),
        format!("- Tier-ups: {}, resumes: {}", t("tier_ups"), t("resumes")),
        format!("- Merge-gate refusals: {}", t("gate_refusals")),
        format!("- Base syncs: {}", t("base_syncs")),
        format!("- Changed lines: +{}/-{}", totals["additions"], totals["deletions"]),
        format!(
            "- Wall time (first to last log line): {}",
            totals["wall_secs"].as_i64().map_or(DASH.to_string(), duration)
        ),
        String::new(),
        "## Proposals".to_string(),
        String::new(),
        "These are proposals only. Nothing has been changed or filed.".to_string(),
        String::new(),
        "### Routing".to_string(),
        String::new(),
    ]);
    if routing.is_empty() {
        md.push("No routing change is suggested by this run.".to_string());
    }
    md.extend(routing.iter().map(|l| format!("- {l}")));
    md.extend([String::new(), "### Follow-up issues".to_string(), String::new()]);
    if ups.is_empty() {
        md.push("No known limits or shortcuts were recorded.".to_string());
    }
    md.extend(ups.iter().map(|l| format!("- {l}")));
    md.push(String::new());
    md.join("\n")
}

pub fn run(ctx: &Ctx, args: &Args) -> Res<()> {
    ctx.require_driver("retro")?;
    let tracker = if args.publish {
        let published: Published = read_json(&ctx.path("tracker.json"))
            .ok_or_else(|| Fail::usage("no tracker.json in the run folder: publish the tracker before --publish"))?;
        Some(published.number)
    } else {
        None
    };

    let replayed = replay(ctx);
    let queue: Option<Value> = read_json(&ctx.path("queue.json"));
    let units: Vec<UnitRetro> = unit_numbers(ctx, &replayed.snapshot)
        .into_iter()
        .map(|n| unit_retro(ctx, &replayed, &queue, n))
        .collect();

    let mut by_state = Map::new();
    for u in &units {
        let name = u.state.map_or("unknown", State::as_str);
        let n = by_state.get(name).and_then(Value::as_u64).unwrap_or(0);
        by_state.insert(name.to_string(), json!(n + 1));
    }
    let costs: Vec<f64> = units.iter().filter_map(|u| u.cost).collect();
    let sum = |f: &dyn Fn(&UnitRetro) -> u64| units.iter().map(f).sum::<u64>();
    let totals = json!({
        "units": units.len(),
        "by_state": by_state,
        "cost_usd_estimate": (!costs.is_empty()).then(|| costs.iter().sum::<f64>()),
        "attempts": sum(&|u| u.attempts as u64),
        "tier_ups": sum(&|u| u.tier_ups as u64),
        "resumes": sum(&|u| u.resumes as u64),
        "gate_refusals": sum(&|u| u.refusals),
        "base_syncs": sum(&|u| u.base_syncs.map_or(0, u64::from)),
        "additions": sum(&|u| u.changed.map_or(0, |c| c.0)),
        "deletions": sum(&|u| u.changed.map_or(0, |c| c.1)),
        "wall_secs": replayed.span.map(|(a, b)| b - a),
    });
    let routing = routing(&units);
    let ups = follow_ups(&units);
    let generated = rfc3339(ctx.now());
    let run = ctx.run_id()?;
    let doc = json!({
        "run": run,
        "generated": generated,
        "units": units.iter().map(|u| u.json.clone()).collect::<Vec<_>>(),
        "totals": totals,
        "proposals": {"routing": routing, "follow_ups": ups},
    });

    let (json_path, md_path) = (ctx.path("retro.json"), ctx.path("retro.md"));
    write_json(&json_path, &doc)?;
    write_atomic(
        &md_path,
        markdown(&run, &generated, &units, &totals, &routing, &ups).as_bytes(),
    )?;

    let mut posted = None;
    if let Some(number) = tracker {
        gh::write(
            ctx,
            &Write::Comment {
                number,
                body_file: &md_path,
            },
        )?;
        posted = Some(number);
    }
    ctx.event(
        "retro",
        json!({"units": units.len(), "proposals": routing.len() + ups.len(), "published": posted, "dry_run": ctx.dry_run && posted.is_some()}),
    )?;

    let cost = totals["cost_usd_estimate"]
        .as_f64()
        .map_or(DASH.to_string(), |c| format!("~${c:.2}"));
    let states: Vec<String> = by_state.iter().map(|(s, n)| format!("{n} {s}")).collect();
    println!("{}", json_path.display());
    println!(
        "retro: {} units ({}), cost {cost}, {} proposals{}",
        units.len(),
        states.join(", "),
        routing.len() + ups.len(),
        match posted {
            Some(n) if ctx.dry_run => format!(", would post to #{n}"),
            Some(n) => format!(", posted to #{n}"),
            None => String::new(),
        }
    );
    Ok(())
}
