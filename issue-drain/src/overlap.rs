//! `issue-drain overlap`.
//!
//! Proposes which issues overlap, from the checked verdicts. Two issues that
//! are both still to be worked (status live or duplicate_of) are related as
//! duplicate, cluster_candidate or adjacent. Groups are the connected
//! components over duplicate and cluster edges.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use serde_json::{Value, json};

use crate::ctx::{Ctx, write_json};
use crate::error::{Fail, Res};
use crate::model::{Group, Overlap, Pair};
use crate::profile::shared_entry;

#[derive(clap::Args)]
pub struct Args {
    /// The checked verdicts (default: verdicts.checked.json in the run folder).
    #[arg(long = "in")]
    input: Option<PathBuf>,
    /// Where to write the proposal (default: overlap.json in the run folder).
    #[arg(long)]
    out: Option<PathBuf>,
}

/// The fields of a checked verdict that overlap reads.
struct Cand {
    number: u64,
    live: bool,
    duplicate_of: Option<u64>,
    files: BTreeSet<String>,
    symbols: BTreeSet<String>,
    mechanical: bool,
    pattern: String,
    size: String,
    risk: bool,
}

/// Estimated lines for a size; None for XL, unsized or anything else.
fn lines(size: &str) -> Option<u64> {
    match size {
        "S" => Some(50),
        "M" => Some(150),
        "L" => Some(400),
        _ => None,
    }
}

fn strs(v: &Value, key: &str) -> BTreeSet<String> {
    v.get(key)
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

fn text(v: &Value, key: &str) -> String {
    v.get(key).and_then(Value::as_str).unwrap_or_default().to_string()
}

fn cand(v: &Value) -> Option<Cand> {
    let status = text(v, "status");
    let live = status == "live";
    if !live && status != "duplicate_of" {
        return None;
    }
    Some(Cand {
        number: v.get("number").and_then(Value::as_u64)?,
        live,
        duplicate_of: v.get("duplicate_of").and_then(Value::as_u64),
        files: strs(v, "files"),
        symbols: strs(v, "symbols"),
        mechanical: text(v, "change_kind") == "mechanical",
        pattern: text(v, "pattern"),
        size: text(v, "size"),
        risk: v.get("risk").and_then(Value::as_bool).unwrap_or(false),
    })
}

fn dup(a: &Cand, b: &Cand) -> bool {
    !a.live && a.duplicate_of == Some(b.number)
}

fn pair(a: &Cand, b: &Cand) -> Option<Pair> {
    let files: Vec<String> = a
        .files
        .iter()
        .flat_map(|x| b.files.iter().filter_map(move |y| shared_entry(x, y)))
        .map(str::to_string)
        .collect::<BTreeSet<String>>()
        .into_iter()
        .collect();
    let symbols: Vec<String> = a.symbols.intersection(&b.symbols).cloned().collect();
    let same_pattern = a.mechanical && b.mechanical && !a.pattern.is_empty() && a.pattern == b.pattern;
    let (relation, note) = if dup(a, b) || dup(b, a) {
        ("duplicate", None)
    } else if (!files.is_empty() && !symbols.is_empty()) || same_pattern {
        if a.risk || b.risk {
            (
                "adjacent",
                Some("on a risk path, so not offered for a cluster".to_string()),
            )
        } else if lines(&a.size).is_none() || lines(&b.size).is_none() {
            (
                "adjacent",
                Some("sized XL or unsized, so not offered for a cluster".to_string()),
            )
        } else {
            let note = same_pattern.then(|| format!("same mechanical pattern: {}", a.pattern));
            ("cluster_candidate", note)
        }
    } else if !files.is_empty() {
        ("adjacent", None)
    } else {
        return None;
    };
    Some(Pair {
        a: a.number,
        b: b.number,
        relation: relation.to_string(),
        shared_files: files,
        shared_symbols: symbols,
        note,
    })
}

fn root(parent: &mut BTreeMap<u64, u64>, mut n: u64) -> u64 {
    while parent[&n] != n {
        let up = parent[&parent[&n]];
        parent.insert(n, up);
        n = up;
    }
    n
}

pub fn run(ctx: &Ctx, args: &Args) -> Res<()> {
    let input = args.input.clone().unwrap_or_else(|| ctx.path("verdicts.checked.json"));
    let out = args.out.clone().unwrap_or_else(|| ctx.path("overlap.json"));
    let verdicts: Vec<Value> = std::fs::read_to_string(&input)
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .and_then(|v| match v {
            Value::Array(a) => Some(a),
            _ => None,
        })
        .ok_or_else(|| {
            Fail::usage(format!(
                "no checked verdicts at {}; run evidence-check first",
                input.display()
            ))
        })?;
    let cands: Vec<Cand> = verdicts.iter().filter_map(cand).collect();

    let mut pairs = Vec::new();
    for (i, a) in cands.iter().enumerate() {
        for b in &cands[i + 1..] {
            pairs.extend(pair(a, b));
        }
    }

    // Connected components over duplicate and cluster edges, labelled by the
    // lowest issue number in each.
    let mut parent: BTreeMap<u64, u64> = cands.iter().map(|c| (c.number, c.number)).collect();
    for p in pairs.iter().filter(|p| p.relation != "adjacent") {
        let (ra, rb) = (root(&mut parent, p.a), root(&mut parent, p.b));
        parent.insert(ra.max(rb), ra.min(rb));
    }
    let mut comps: BTreeMap<u64, Vec<u64>> = BTreeMap::new();
    for number in parent.keys().copied().collect::<Vec<_>>() {
        comps.entry(root(&mut parent, number)).or_default().push(number);
    }

    let by: BTreeMap<u64, &Cand> = cands.iter().map(|c| (c.number, c)).collect();
    let mut groups = Vec::new();
    let mut singles = Vec::new();
    for members in comps.values() {
        if let [only] = members.as_slice() {
            singles.push(*only);
            continue;
        }
        let m: Vec<&Cand> = members.iter().map(|n| by[n]).collect();
        let est: u64 = m.iter().filter(|c| c.live).map(|c| lines(&c.size).unwrap_or(0)).sum();
        let files: BTreeSet<&String> = m.iter().flat_map(|c| c.files.iter()).collect();
        groups.push(Group {
            issues: members.clone(),
            live: m.iter().filter(|c| c.live).map(|c| c.number).collect(),
            files: files.into_iter().cloned().collect(),
            est_lines: est,
            over_cap: members.len() > ctx.profile.cluster_max_issues,
            over_lines: est > ctx.profile.cluster_max_lines,
            risk: m.iter().any(|c| c.risk),
        });
    }
    let overlap = Overlap { pairs, groups, singles };
    write_json(&out, &overlap)?;

    let summary = json!({
        "pairs": overlap.pairs.len(),
        "groups": overlap.groups.len(),
        "singles": overlap.singles.len(),
    });
    ctx.event("overlap", summary.clone())?;
    println!("overlap: {summary} -> {}", out.display());
    for g in &overlap.groups {
        let ids: Vec<String> = g.issues.iter().map(|n| format!("#{n}")).collect();
        let mut line = format!("  group {}: ~{} lines", ids.join(" "), g.est_lines);
        if g.over_cap {
            line.push_str(", over the issue cap");
        }
        if g.over_lines {
            line.push_str(", over the line cap");
        }
        if g.risk {
            line.push_str(", has a risk-path issue");
        }
        println!("{line}");
    }
    for p in overlap.pairs.iter().filter(|p| p.relation == "adjacent") {
        let note = p.note.as_ref().map(|n| format!(" ({n})")).unwrap_or_default();
        println!("  adjacent #{} #{}: {}{note}", p.a, p.b, p.shared_files.join(", "));
    }
    Ok(())
}
