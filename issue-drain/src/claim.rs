//! `issue-drain claim take|release|check --unit <n>`: the claim label on a
//! unit's issues, and the record of whose claim it is.
//!
//! A label alone does not say who put it there, so `take` adds the label and
//! then posts a comment whose first line is a machine marker naming the run's
//! tracker issue and the unit. The label goes first: a label call that fails
//! leaves no marker behind for a stranger's later label to borrow, and a marker
//! that fails to post takes the label back off.
//!
//! A claim is ours only when all of these hold, read from the issue's labels
//! and its timeline (one paginated source, so an issue with more than 100
//! comments is read whole):
//!   - the claim label is on the issue now;
//!   - the newest claim marker (any tracker, any unit) is ours;
//!   - that marker comes after the latest `labeled` event of the claim label,
//!     so the label it describes is the one on the issue; a label with no
//!     `labeled` event is not ours;
//!   - no `unlabeled` event of the claim label comes after the marker.
//!
//! "After" is the pair (creation time, position in the timeline): GitHub's
//! times are whole seconds, and a release and a retake inside one second share
//! one, so the order of events with equal times is the timeline's, which is
//! chronological.
//!
//! So an old marker of ours does not make a later run's claim, or a label a
//! stranger added after our release or after our label call failed, ours;
//! `take` posts a fresh marker when the old one no longer counts. Anything else
//! carrying the label is someone else's, and is never taken over, released or
//! written to.
//!
//! Two runs taking the same issue at the same moment are not excluded here: the
//! driver's one-per-repo lock is what prevents that.
//!
//! The claim label is written only through `gh::write`, so a dry run prints
//! `WOULD: ...` and writes nothing. These are the driver's commands: a unit
//! process is refused.
//!
//! When a later issue fails during `take`, the claims taken earlier in the call
//! are released only while they are still ours (the check `release` makes); one
//! that is not is left alone and named. The issue whose own marker failed to
//! post gets its label taken off without that check: it never had a marker.
//!
//! Exit: 0 done; 3 an issue is claimed by someone else (everything taken in
//! this call is released first, where still ours) or a unit process asked; 2 no queue, unit or
//! tracker; 1 a read or a write on GitHub failed (the issue, or its timeline).
//! A read that fails is never taken to mean "not claimed", or "still ours".

use std::sync::LazyLock;

use regex::Regex;
use serde_json::{Value, json};

use crate::ctx::{Ctx, parse_rfc3339, read_json};
use crate::error::{Fail, Res};
use crate::gh::{self, Write};
use crate::profile::same_label;
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

/// Whether a comment is a claim marker of any tracker and unit.
fn is_any_marker(body: &str) -> bool {
    static ANY: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"^<!-- issue-drain:claim tracker=[0-9]+ unit=[0-9]+ -->$").expect("a fixed pattern")
    });
    body.lines().next().is_some_and(|first| ANY.is_match(first.trim_end()))
}

/// What the issue's timeline says about claims.
#[derive(Default)]
struct Timeline {
    /// Each claim marker comment: when, its place in the timeline, its body.
    markers: Vec<(i64, usize, String)>,
    /// The latest (time, place) the claim label was added; `None` when it never was.
    labeled: Option<(i64, usize)>,
    /// When the claim label was taken off, each time, with its place.
    unlabeled: Vec<(i64, usize)>,
}

/// The issue's whole timeline, every page. A time that cannot be read counts as
/// the latest possible for a label event, so a doubt about the order is a
/// refusal to call the claim ours.
fn read_timeline(repo: &str, number: u64, label: &str) -> Res<Timeline> {
    let url = format!("repos/{repo}/issues/{number}/timeline?per_page=100");
    let raw = gh::read(&["api", &url, "--paginate"]).map_err(|rc| {
        Fail::failed(format!(
            "could not read the timeline of #{number} (gh exit {rc}); a failed read is not taken to mean the claim is still ours"
        ))
    })?;
    let unreadable = |what: &str| Fail::failed(format!("could not read the timeline of #{number}: {what}"));
    let mut found = Timeline::default();
    let mut index = 0;
    // `--paginate` prints one JSON array per page, one after the other.
    for page in serde_json::Deserializer::from_str(&raw).into_iter::<Value>() {
        let page = page.map_err(|_| unreadable("gh answered with something else than JSON"))?;
        let events = page
            .as_array()
            .ok_or_else(|| unreadable("a page is not a list of events"))?;
        for event in events {
            index += 1;
            let kind = event["event"]
                .as_str()
                .ok_or_else(|| unreadable("an event has no name"))?;
            let at = event["created_at"].as_str().and_then(parse_rfc3339);
            match kind {
                // shortcut: a comment is "ours" by its text alone, not by who wrote it; anyone who can comment can forge the marker. Check the author against `gh api user` if that ever matters.
                "commented" => {
                    let Some(body) = event["body"].as_str().filter(|body| is_any_marker(body)) else {
                        continue;
                    };
                    let at = at.ok_or_else(|| unreadable("a claim marker comment has no creation time"))?;
                    found.markers.push((at, index, body.to_string()));
                }
                "labeled" | "unlabeled" => {
                    let named = event["label"]["name"]
                        .as_str()
                        .ok_or_else(|| unreadable("a label event has no label name"))?;
                    if !same_label(named, label) {
                        continue;
                    }
                    let at = (at.unwrap_or(i64::MAX), index);
                    if kind == "labeled" {
                        found.labeled = found.labeled.max(Some(at));
                    } else {
                        found.unlabeled.push(at);
                    }
                }
                _ => {}
            }
        }
    }
    Ok(found)
}

/// Whether the claim on the issue is ours: see the module header. The newest
/// marker is the latest by creation time, a tie going to the later in the
/// timeline; every order question is decided by (time, place) the same way.
fn is_ours(timeline: &Timeline, marker: &str) -> bool {
    let Some((at, place, body)) = timeline.markers.iter().max_by_key(|(at, i, _)| (*at, *i)) else {
        return false;
    };
    let ours = (*at, *place);
    is_marker(body, marker)
        && timeline.labeled.is_some_and(|labeled| ours > labeled)
        && timeline.unlabeled.iter().all(|off| *off < ours)
}

/// What GitHub shows on the issue now.
fn read_issue(ctx: &Ctx, repo: &str, number: u64, marker: &str) -> Res<Seen> {
    let n = number.to_string();
    let raw = gh::read(&["issue", "view", &n, "--repo", repo, "--json", "labels"]).map_err(|rc| {
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
    let names: Vec<String> = labels
        .iter()
        .filter_map(|l| l["name"].as_str().map(str::to_string))
        .collect();
    let labelled = ctx.profile.has_claim(&names);
    let timeline = read_timeline(repo, number, &ctx.profile.claim_label)?;
    Ok(Seen {
        labelled,
        ours: labelled && is_ours(&timeline, marker),
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
    /// `verify` is for claims taken earlier in the call, which others may have
    /// changed since: each is released only while it is still ours, as `release`
    /// does. The issue whose own marker failed is not one of them: no marker
    /// was posted, so its label is taken off without asking.
    fn roll_back(&self, taken: &[u64], cause: Fail, verify: bool) -> Fail {
        let mut left: Vec<String> = Vec::new();
        let stuck: Vec<String> = taken
            .iter()
            .rev()
            .filter_map(|&n| {
                if verify {
                    match self.seen(n) {
                        Ok(seen) if seen.labelled && seen.ours => {}
                        Ok(_) => {
                            left.push(format!("#{n}"));
                            return None;
                        }
                        Err(e) => return Some(format!("#{n}: {}", e.msg)),
                    }
                }
                self.remove_label(n).err().map(|e| format!("#{n}: {}", e.msg))
            })
            .collect();
        if !stuck.is_empty() {
            return Fail::failed(format!(
                "{}; and the claims taken in this call could not all be released ({})",
                cause.msg,
                stuck.join("; ")
            ));
        }
        let released: Vec<String> = taken
            .iter()
            .map(|n| format!("#{n}"))
            .filter(|n| !left.contains(n))
            .collect();
        let mut msg = cause.msg;
        if !released.is_empty() {
            msg = format!("{msg}; released {}", released.join(", "));
        }
        if !left.is_empty() {
            msg = format!("{msg}; left {} alone: no longer this unit's claim", left.join(", "));
        }
        Fail { code: cause.code, msg }
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
                // The label first, so a marker is never left for a stranger's
                // later label to borrow. A marker that cannot be posted takes
                // the label back off: a label with no marker looks like
                // someone else's.
                gh::write(
                    self.ctx,
                    &Write::AddLabel {
                        number,
                        label: self.label(),
                    },
                )?;
                if let Err(e) = self.post_marker(number) {
                    return Err(self.roll_back(&[number], e, false));
                }
                Ok("taken")
            })();
            match step {
                Ok(action) => {
                    if action == "taken" {
                        taken.push(number);
                    }
                    report.push(json!({"issue": number, "action": action}));
                }
                Err(e) => return Err(self.roll_back(&taken, e, true)),
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

    const M: &str = "<!-- issue-drain:claim tracker=1 unit=1 -->";

    #[test]
    fn events_in_one_second_are_ordered_by_their_place_in_the_timeline() {
        let line = |markers: &[(i64, usize)], labeled, unlabeled: &[(i64, usize)]| Timeline {
            markers: markers.iter().map(|(t, i)| (*t, *i, M.to_string())).collect(),
            labeled,
            unlabeled: unlabeled.to_vec(),
        };
        // labeled 1, marker 2, unlabeled 3, labeled 4, marker 5: one second.
        assert!(is_ours(&line(&[(7, 2), (7, 5)], Some((7, 4)), &[(7, 3)]), M));
        // The label came after the marker: not ours.
        assert!(!is_ours(&line(&[(7, 2)], Some((7, 4)), &[(7, 3)]), M));
        // An unlabel after the marker: not ours.
        assert!(!is_ours(&line(&[(7, 2)], Some((7, 1)), &[(7, 3)]), M));
        // No label event at all: not ours.
        assert!(!is_ours(&line(&[(7, 2)], None, &[]), M));
    }

    #[test]
    fn any_trackers_marker_is_a_marker_but_only_on_the_first_line() {
        assert!(is_any_marker("<!-- issue-drain:claim tracker=13 unit=7 -->\nText."));
        assert!(is_any_marker("<!-- issue-drain:claim tracker=1 unit=1 -->\r\nText."));
        assert!(!is_any_marker("quote\n<!-- issue-drain:claim tracker=13 unit=7 -->"));
        assert!(!is_any_marker("<!-- issue-drain:claim tracker=x unit=7 -->"));
        assert!(!is_any_marker("<!-- issue-drain:claim tracker=13 unit=7 --> more"));
        assert!(!is_any_marker(""));
    }

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
