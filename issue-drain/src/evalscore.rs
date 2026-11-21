//! `issue-drain eval-score`: score a triage run against the fixture's expected
//! answers.
//!
//! The input is the checked verdicts, so the score covers the reader and the
//! evidence check together: what matters is what would reach the tracker.
//! Two numbers get their own line because a wrong closure is the costly
//! mistake: precision and recall for "already_fixed", and `false_closable`,
//! the issues offered for closing that should not be.

use std::path::PathBuf;

use serde::Deserialize;
use serde_json::{Value, json};

use crate::ctx::{Ctx, read_json};
use crate::error::{Fail, Res};
use crate::model::Checked;

#[derive(clap::Args)]
pub struct Args {
    /// The expected answers (evals/fixtures/expected.json).
    #[arg(long)]
    expected: PathBuf,
    /// The checked verdicts to score (default: verdicts.checked.json in the run folder).
    #[arg(long = "in")]
    input: Option<PathBuf>,
}

/// The right answer for one issue. A field left out is not scored.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Want {
    number: u64,
    /// Every status that counts as right, the best one first.
    status: Vec<String>,
    duplicate_of: Option<u64>,
    closable: Option<bool>,
    risk: Option<bool>,
}

fn ratio(part: usize, whole: usize) -> Value {
    if whole == 0 {
        Value::Null
    } else {
        json!(part as f64 / whole as f64)
    }
}

pub fn run(ctx: &Ctx, args: &Args) -> Res<()> {
    let wants: Vec<Want> = read_json(&args.expected)
        .ok_or_else(|| Fail::usage(format!("no expected answers at {}", args.expected.display())))?;
    let input = args.input.clone().unwrap_or_else(|| ctx.path("verdicts.checked.json"));
    let got: Vec<Checked> = read_json(&input).ok_or_else(|| {
        Fail::usage(format!(
            "no checked verdicts at {}; run evidence-check first",
            input.display()
        ))
    })?;

    let mut mismatches = Vec::new();
    let mut wrong = 0;
    for want in &wants {
        let before = mismatches.len();
        let mut miss = |field: &str, expected: Value, got: Value| {
            mismatches.push(json!({"number": want.number, "field": field, "expected": expected, "got": got}));
        };
        match got.iter().find(|g| g.number == want.number) {
            None => miss("status", json!(want.status), Value::Null),
            Some(g) => {
                if !want.status.contains(&g.status) {
                    miss("status", json!(want.status), json!(g.status));
                }
                if g.status == "duplicate_of" && want.duplicate_of.is_some() && g.duplicate_of != want.duplicate_of {
                    miss("duplicate_of", json!(want.duplicate_of), json!(g.duplicate_of));
                }
                if want.closable.is_some_and(|c| c != g.closable) {
                    miss("closable", json!(want.closable), json!(g.closable));
                }
                if want.risk.is_some_and(|r| r != g.risk) {
                    miss("risk", json!(want.risk), json!(g.risk));
                }
            }
        }
        if mismatches.len() > before {
            wrong += 1;
        }
    }

    let fixed = |number: u64| {
        wants
            .iter()
            .any(|w| w.number == number && w.status.first().is_some_and(|s| s == "already_fixed"))
    };
    let expected_fixed = wants.iter().filter(|w| fixed(w.number)).count();
    let returned: Vec<u64> = got
        .iter()
        .filter(|g| g.status == "already_fixed")
        .map(|g| g.number)
        .collect();
    let true_positive = returned.iter().filter(|n| fixed(**n)).count();
    // Offered for closing without the fixture saying so. An issue the fixture
    // does not know counts: nothing unlisted should be closed.
    let false_closable: Vec<u64> = got
        .iter()
        .filter(|g| g.closable && !wants.iter().any(|w| w.number == g.number && w.closable == Some(true)))
        .map(|g| g.number)
        .collect();

    let summary = json!({
        "issues": wants.len(),
        "correct": wants.len() - wrong,
        "already_fixed": {
            "expected": expected_fixed,
            "returned": returned.len(),
            "true_positive": true_positive,
            "precision": ratio(true_positive, returned.len()),
            "recall": ratio(true_positive, expected_fixed),
        },
        "false_closable": false_closable,
        "mismatches": mismatches,
    });
    println!(
        "{}",
        serde_json::to_string_pretty(&summary).map_err(|e| Fail::failed(format!("cannot encode the score: {e}")))?
    );
    ctx.event(
        "eval_score",
        json!({"issues": wants.len(), "correct": wants.len() - wrong, "false_closable": false_closable}),
    )?;
    if wrong == 0 && false_closable.is_empty() {
        return Ok(());
    }
    Err(Fail::failed(format!(
        "{wrong} of {} issues scored wrong; {} offered for closing that should not be",
        wants.len(),
        false_closable.len()
    )))
}
