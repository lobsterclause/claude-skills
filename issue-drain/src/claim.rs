//! `issue-drain claim take|release|check --unit <n>`: the claim label on a
//! unit's issues, and the record of whose claim it is.
//!
//! A label alone does not say who put it there, so `take` also posts a comment
//! whose first line is a machine marker naming the run's tracker issue and the
//! unit. A claim is ours when the label is on the issue and a comment starts
//! with our marker. Anything else carrying the label is someone else's, and is
//! never taken over, released or written to.
//!
//! The claim label is written only through `gh::write`, so a dry run prints
//! `WOULD: ...` and writes nothing. These are the driver's commands: a unit
//! process is refused.
//!
//! Exit: 0 done; 3 an issue is claimed by someone else (everything taken in
//! this call is released first) or a unit process asked; 2 no queue, unit or
//! tracker; 1 a read or a write on GitHub failed. A read that fails is never
//! taken to mean "not claimed".

use serde_json::{Value, json};

use crate::ctx::{Ctx, read_json};
use crate::error::{Fail, Res};
use crate::gh::{self, Write};
use crate::tracker::io::Published;

#[derive(clap::Args)]
pub struct Args {
    /// The unit whose issues are claimed.
    #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
    unit: u64,
}

#[derive(clap::Subcommand)]
pub enum Command {
    /// Label each issue of the unit and post the marker comment.
    Take(Args),
    /// Remove the label where the marker says the claim is ours.
    Release(Args),
    /// Print, for each issue, whether it is labelled and whether the claim is ours.
    Check(Args),
}

/// The first line of the comment `take` posts.
pub fn marker(tracker: u64, unit: u64) -> String {
    format!("<!-- issue-drain:claim tracker={tracker} unit={unit} -->")
}

struct Seen {
    labelled: bool,
    ours: bool,
}

/// Whether a comment is our marker: its first line, and nothing else, is
/// `marker`. A quote or a reply that repeats the marker further down is not.
fn is_marker(body: &str, marker: &str) -> bool {
    body.lines().next().is_some_and(|first| first.trim_end() == marker)
}

/// What GitHub shows on the issue now.
fn read_issue(ctx: &Ctx, repo: &str, number: u64, marker: &str) -> Res<Seen> {
    let n = number.to_string();
    let raw = gh::read(&["issue", "view", &n, "--repo", repo, "--json", "labels,comments"]).map_err(|rc| {
        Fail::failed(format!(
            "could not read #{number} (gh exit {rc}); a failed read is not taken to mean it is unclaimed"
        ))
    })?;
    let unreadable = || {
        Fail::failed(format!(
            "could not read #{number}: gh answered with something else than JSON"
        ))
    };
    let view: Value = serde_json::from_str(&raw).map_err(|_| unreadable())?;
    let labels = view["labels"].as_array().ok_or_else(unreadable)?;
    let comments = view["comments"].as_array().ok_or_else(unreadable)?;
    let names: Vec<String> = labels
        .iter()
        .filter_map(|l| l["name"].as_str().map(str::to_string))
        .collect();
    // shortcut: a comment is "ours" by its text alone, not by who wrote it; anyone who can comment can forge the marker. Check the author against `gh api user` if that ever matters.
    let ours = comments
        .iter()
        .any(|c| c["body"].as_str().is_some_and(|body| is_marker(body, marker)));
    Ok(Seen {
        labelled: ctx.profile.has_claim(&names),
        ours,
    })
}

struct Run<'a> {
    ctx: &'a Ctx,
    repo: String,
    unit: u64,
    tracker: u64,
    issues: Vec<u64>,
}

impl Run<'_> {
    fn marker(&self) -> String {
        marker(self.tracker, self.unit)
    }

    fn seen(&self, number: u64) -> Res<Seen> {
        read_issue(self.ctx, &self.repo, number, &self.marker())
    }

    fn label(&self) -> &str {
        &self.ctx.profile.claim_label
    }

    fn remove_label(&self, number: u64) -> Res<()> {
        gh::write(
            self.ctx,
            &Write::RemoveLabel {
                number,
                label: self.label(),
            },
        )
        .map(|_| ())
    }

    /// Release what this call took, then hand back the error that stopped it.
    fn roll_back(&self, taken: &[u64], cause: Fail) -> Fail {
        let stuck: Vec<String> = taken
            .iter()
            .rev()
            .filter_map(|n| self.remove_label(*n).err().map(|e| format!("#{n}: {}", e.msg)))
            .collect();
        if !stuck.is_empty() {
            return Fail::failed(format!(
                "{}; and the claims taken in this call could not all be released ({})",
                cause.msg,
                stuck.join("; ")
            ));
        }
        if taken.is_empty() {
            return cause;
        }
        let list: Vec<String> = taken.iter().map(|n| format!("#{n}")).collect();
        Fail {
            code: cause.code,
            msg: format!("{}; released {}", cause.msg, list.join(", ")),
        }
    }

    fn post_marker(&self, number: u64) -> Res<()> {
        let sentence = format!(
            "An agent has picked this up as unit {} of the drain tracked in #{}.",
            self.unit, self.tracker
        );
        let file = self.ctx.path(&format!("units/{}/claim-{number}.md", self.unit));
        crate::ctx::write_atomic(&file, format!("{}\n{sentence}\n", self.marker()).as_bytes())?;
        gh::write(
            self.ctx,
            &Write::Comment {
                number,
                body_file: &file,
            },
        )
        .map(|_| ())
    }

    fn take(&self) -> Res<Vec<Value>> {
        let mut taken: Vec<u64> = Vec::new();
        let mut report = Vec::new();
        let mut label_ready = false;
        for &number in &self.issues {
            let step = (|| -> Res<&'static str> {
                let seen = self.seen(number)?;
                if seen.labelled && seen.ours {
                    return Ok("already");
                }
                if seen.labelled {
                    return Err(Fail::refused(format!(
                        "#{number} is claimed by someone else: it carries '{}' without this unit's marker comment",
                        self.label()
                    )));
                }
                if !label_ready {
                    gh::write(self.ctx, &Write::EnsureLabel { label: self.label() })?;
                    label_ready = true;
                }
                // The comment first: a label with no marker looks like someone else's.
                if !seen.ours {
                    self.post_marker(number)?;
                }
                gh::write(
                    self.ctx,
                    &Write::AddLabel {
                        number,
                        label: self.label(),
                    },
                )?;
                Ok("taken")
            })();
            match step {
                Ok(action) => {
                    if action == "taken" {
                        taken.push(number);
                    }
                    report.push(json!({"issue": number, "action": action}));
                }
                Err(e) => return Err(self.roll_back(&taken, e)),
            }
        }
        self.ctx.event(
            "claim_take",
            json!({"unit": self.unit, "tracker": self.tracker, "taken": taken}),
        )?;
        Ok(report)
    }

    fn release(&self) -> Res<Vec<Value>> {
        let mut released = Vec::new();
        let mut report = Vec::new();
        for &number in &self.issues {
            let seen = self.seen(number)?;
            let action = if !seen.labelled {
                "not_labelled"
            } else if !seen.ours {
                "not_ours"
            } else {
                self.remove_label(number)?;
                released.push(number);
                "released"
            };
            report.push(json!({"issue": number, "action": action}));
        }
        self.ctx.event(
            "claim_release",
            json!({"unit": self.unit, "tracker": self.tracker, "released": released}),
        )?;
        Ok(report)
    }

    fn check(&self) -> Res<Vec<Value>> {
        self.issues
            .iter()
            .map(|&number| {
                let seen = self.seen(number)?;
                Ok(json!({"issue": number, "labelled": seen.labelled, "ours": seen.ours}))
            })
            .collect()
    }
}

pub fn run(ctx: &Ctx, command: &Command) -> Res<()> {
    let (name, args) = match command {
        Command::Take(a) => ("claim take", a),
        Command::Release(a) => ("claim release", a),
        Command::Check(a) => ("claim check", a),
    };
    ctx.require_driver(name)?;
    let unit = ctx.queue_unit(args.unit)?;
    let tracker: Published = read_json(&ctx.path("tracker.json")).ok_or_else(|| {
        Fail::usage("no tracker.json in the run folder: a claim names the tracker issue, so publish it first")
    })?;
    let run = Run {
        ctx,
        repo: ctx.repo()?,
        unit: args.unit,
        tracker: tracker.number,
        issues: unit.issues,
    };
    let report = match command {
        Command::Take(_) => run.take()?,
        Command::Release(_) => run.release()?,
        Command::Check(_) => run.check()?,
    };
    println!("{}", Value::Array(report));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_comment_whose_first_line_is_the_marker_is_ours() {
        let m = marker(12, 3);
        assert_eq!(m, "<!-- issue-drain:claim tracker=12 unit=3 -->");
        assert!(is_marker(&format!("{m}\nA sentence."), &m));
        assert!(is_marker(&format!("{m}\r\nA sentence."), &m));
        assert!(is_marker(&m, &m));
        assert!(!is_marker(&format!("quote\n{m}"), &m));
        assert!(!is_marker(&format!("{m} and more"), &m));
        assert!(!is_marker(&format!("{m}\n").replace("unit=3", "unit=33"), &m));
        assert!(!is_marker("", &m));
    }
}
