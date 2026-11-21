//! `issue-drain close-verified`: close the issues a person ticked on the
//! tracker as already fixed, each with a comment that shows the fix.
//!
//! "30 closed" was once reported with none closed, and three of eight
//! "obsolete" calls were wrong. So an issue is closed only when all of this
//! holds at the moment of closing, not at the moment of triage:
//!   - `tracker render` offered it as a closure and its box is ticked on the
//!     tracker; the tracker has no STOP line, no ticked line the run never
//!     offered, and is still open;
//!   - the evidence check, run again on the base branch as it is now, still
//!     calls it already_fixed and closable, and names the same fixing commit
//!     the tracker showed;
//!   - the issue is open and carries no hold label and no claim label.
//!
//! The comment goes first and the close second, so no issue is closed without
//! its reason. A closure killed between the two is finished by running this
//! again: the comment is recognised by its first line and not posted twice.
//! After the close call the issue is read back; "closed" means GitHub says so.
//!
//! Exit: 0 every issue asked for is closed, or was closed already; 1 a GitHub
//! or git call failed or a close did not take; 2 usage or missing input; 3 at
//! least one closure was refused (the rest were still done).

use std::path::PathBuf;

use serde_json::{Value, json};

use crate::ctx::{Ctx, parse_rfc3339, read_json, write_atomic};
use crate::error::{Fail, Res};
use crate::evidence::check_verdict;
use crate::gh::{self, Write};
use crate::git;
use crate::model::{Checked, Closure, FixCommit, Line, Queue};
use crate::text::{parse_number, safe, sha7, span, uri_segment};
use crate::tracker::io::{Published, fetch_tracker, parse_body};

#[derive(clap::Args)]
pub struct Args {
    /// Issues to close (default: every closure ticked on the tracker).
    numbers: Vec<String>,
    /// The ref to check the code on. Dry runs only: a live closure is checked
    /// on origin/<base branch>, fetched at that moment.
    #[arg(long = "ref")]
    reference: Option<String>,
    /// Do not fetch the base branch first. Dry runs only.
    #[arg(long)]
    no_fetch: bool,
    /// Read the tracker body from a file. Dry runs only: a live closure reads
    /// the published tracker, so the tick it acts on is one a person made on
    /// GitHub, not one written to a file.
    #[arg(long)]
    body_file: Option<PathBuf>,
}

/// What stops one closure. The others still run.
enum Stop {
    Refused(String),
    Skipped(&'static str),
}

struct Run<'a> {
    ctx: &'a Ctx,
    repo: String,
    repo_dir: PathBuf,
    /// The commit the code is checked on, resolved once so every closure in
    /// the run is held against the same tree.
    reference: String,
    /// That commit's name, for messages.
    shown: String,
    run: String,
    marker: String,
    tracker: Option<u64>,
    verdicts: Vec<Value>,
    known: Vec<u64>,
}

fn refuse_all(ctx: &Ctx, why: impl Into<String>) -> Fail {
    let why = why.into();
    match ctx.event("closure_refused", json!({"number": null, "why": why})) {
        Ok(()) => Fail::refused(format!("refused: {why}")),
        Err(e) => e,
    }
}

fn line_text(line: &Line) -> String {
    match line {
        Line::Number(n) => n.to_string(),
        Line::Text(s) => s.clone(),
    }
}

/// The closing comment. Every string that came from a reader, a commit or the
/// session is escaped or held in a code span, so none of it can add a mention,
/// a marker or markup of its own.
fn comment(r: &Run, fresh: &Checked, fix: &FixCommit, note: &str) -> String {
    let base = &r.ctx.profile.base_branch;
    let mut lines = vec![
        r.marker.clone(),
        format!("Closing as already fixed on `{base}`."),
        String::new(),
        format!(
            "The fix is [`{}`](https://github.com/{}/commit/{}), \"{}\", committed {}. On `{base}` at `{}` the code reads:",
            sha7(&fix.sha),
            r.repo,
            fix.sha,
            safe(&fix.subject),
            fix.date.get(..10).unwrap_or(&fix.date),
            sha7(&fresh.checked_sha),
        ),
        String::new(),
    ];
    for q in &fresh.evidence {
        let line = line_text(&q.line);
        let path: Vec<String> = q.file.split('/').map(uri_segment).collect();
        lines.push(format!(
            "- [{}](https://github.com/{}/blob/{}/{}#L{}): {}",
            span(&format!("{}:{line}", q.file)),
            r.repo,
            fresh.checked_sha,
            path.join("/"),
            uri_segment(&line),
            span(&q.quote),
        ));
    }
    lines.push(String::new());
    if !note.is_empty() {
        lines.push(safe(note));
        lines.push(String::new());
    }
    lines.push(format!(
        "Checked by issue-drain run `{}`{}. Reopen this if it still reproduces.",
        r.run,
        r.tracker.map_or(String::new(), |n| format!(" and approved on #{n}")),
    ));
    lines.join("\n") + "\n"
}

fn created_at(ctx: &Ctx, number: u64) -> Option<i64> {
    let issue: Value = read_json(&ctx.path(&format!("issues/{number}.json")))?;
    parse_rfc3339(issue.get("createdAt")?.as_str()?)
}

fn close_one(r: &Run, number: u64, offered: &Closure) -> Res<Result<(), Stop>> {
    let ctx = r.ctx;
    let refused = |why: String| Ok(Err(Stop::Refused(why)));

    // The issue, as it is now. Read first: an issue someone already closed is
    // skipped, whatever the code says today.
    let n = number.to_string();
    let unreadable = || Fail::failed(format!("could not read #{number}"));
    let raw = gh::read(&[
        "issue",
        "view",
        &n,
        "--repo",
        &r.repo,
        "--json",
        "state,labels,comments",
    ])
    .map_err(|_| unreadable())?;
    let live: Value = serde_json::from_str(&raw).map_err(|_| unreadable())?;
    let state = live["state"].as_str().unwrap_or_default();
    if state == "CLOSED" {
        return Ok(Err(Stop::Skipped("already closed")));
    }
    if state != "OPEN" {
        return refused(format!("its state is '{state}'"));
    }

    // The code, read again on the base as it is now.
    let Some(verdict) = r.verdicts.iter().find(|v| v["number"] == number) else {
        return refused("this run has no checked verdict for it".into());
    };
    let fresh = match check_verdict(
        &ctx.profile,
        &r.repo_dir,
        &r.reference,
        verdict,
        created_at(ctx, number),
        &r.known,
    ) {
        Ok(fresh) => fresh,
        Err(e) => return refused(format!("the evidence check did not run ({})", e.msg)),
    };
    let fix = match &fresh.fix_commit {
        Some(fix) if fresh.status == "already_fixed" && fresh.closable => fix,
        _ => {
            return refused(format!(
                "on {} it no longer checks out as fixed ({})",
                r.shown,
                fresh.downgrade_reason.as_deref().unwrap_or(&fresh.status)
            ));
        }
    };
    if fix.sha != offered.fix_commit.sha {
        return refused(format!(
            "the tracker showed {} as the fix, and the quoted line now comes from {}; triage it again",
            sha7(&offered.fix_commit.sha),
            sha7(&fix.sha)
        ));
    }

    let labels: Vec<String> = live["labels"]
        .as_array()
        .map(|l| {
            l.iter()
                .filter_map(|l| l["name"].as_str())
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    let held = ctx.profile.hold_label_on(&labels).or_else(|| {
        ctx.profile
            .has_claim(&labels)
            .then_some(ctx.profile.claim_label.as_str())
    });
    if let Some(label) = held {
        return refused(format!("it now carries the label '{label}'"));
    }

    let file = ctx.path(&format!("closures/{number}.md"));
    write_atomic(&file, comment(r, &fresh, fix, &offered.note).as_bytes())?;
    // Only the drain's own comment counts as posted: anyone can write the
    // marker, and a stranger's copy must not stand in for the reason.
    let posted = live["comments"].as_array().is_some_and(|c| {
        c.iter().any(|c| {
            c["viewerDidAuthor"] == true
                && c["body"].as_str().and_then(|b| b.lines().next()).map(str::trim_end) == Some(r.marker.as_str())
        })
    });
    if !posted {
        gh::write(
            ctx,
            &Write::Comment {
                number,
                body_file: &file,
            },
        )?;
    }
    gh::write(ctx, &Write::CloseIssue { number })?;
    if ctx.dry_run {
        println!(
            "would close #{number} (fixed by {}); the comment is in {}",
            sha7(&fix.sha),
            file.display()
        );
        return Ok(Ok(()));
    }

    let unread = || Fail::failed(format!("closed #{number} but could not read it back"));
    let raw = gh::read(&["issue", "view", &n, "--repo", &r.repo, "--json", "state"]).map_err(|_| unread())?;
    let after: Value = serde_json::from_str(&raw).map_err(|_| unread())?;
    let after = after["state"].as_str().unwrap_or("unknown");
    if after != "CLOSED" {
        ctx.event("closure_failed", json!({"number": number, "state": after}))?;
        return Err(Fail::failed(format!("#{number} is still {after} after the close call")));
    }
    ctx.event(
        "closure",
        json!({"number": number, "fix_commit": fix.sha, "tracker": r.tracker}),
    )?;
    println!("closed #{number} (fixed by {})", sha7(&fix.sha));
    Ok(Ok(()))
}

pub fn run(ctx: &Ctx, args: &Args) -> Res<()> {
    let repo = ctx.repo()?;
    let repo_dir = ctx.repo_dir()?;
    let run = ctx.run_id()?;
    let mut numbers = Vec::new();
    for text in &args.numbers {
        numbers.push(parse_number(text).ok_or_else(|| Fail::usage(format!("not an issue number: '{text}'")))?);
    }
    let body_file = args.body_file.as_ref().filter(|f| !f.as_os_str().is_empty());
    let named_ref = args.reference.as_ref().filter(|r| !r.is_empty());
    if !ctx.dry_run {
        if body_file.is_some() {
            return Err(Fail::usage(
                "--body-file is for dry runs; a live closure reads the published tracker",
            ));
        }
        if named_ref.is_some() || args.no_fetch {
            return Err(Fail::usage(format!(
                "--ref and --no-fetch are for dry runs; a live closure is checked on origin/{}, fetched now",
                ctx.profile.base_branch
            )));
        }
    }
    let (queue_path, checked_path) = (ctx.path("queue.json"), ctx.path("verdicts.checked.json"));
    for path in [&queue_path, &checked_path] {
        if !path.is_file() {
            return Err(Fail::usage(format!(
                "missing {}; this run has no rendered tracker",
                path.display()
            )));
        }
    }
    let queue: Queue =
        read_json(&queue_path).ok_or_else(|| Fail::usage(format!("{} is not a queue", queue_path.display())))?;
    let verdicts: Vec<Value> = read_json(&checked_path)
        .ok_or_else(|| Fail::usage(format!("{} is not a list of checked verdicts", checked_path.display())))?;
    if !queue.repo.eq_ignore_ascii_case(&repo) {
        return Err(Fail::usage(format!(
            "this run's queue is for {}, and ISSUE_DRAIN_REPO is {repo}",
            queue.repo
        )));
    }

    // What the tracker offers and what is ticked on it.
    let parsed = match body_file {
        None => fetch_tracker(ctx, &queue)?,
        Some(file) => {
            let bytes = std::fs::read(file).map_err(|_| Fail::usage(format!("no body file at {}", file.display())))?;
            parse_body(&String::from_utf8_lossy(&bytes), &queue)?
        }
    };
    if !parsed.unknown.is_empty() {
        return Err(refuse_all(
            ctx,
            format!(
                "the tracker has a ticked line this run never offered ({}); nothing is closed until that line is gone",
                parsed.unknown.join(", ")
            ),
        ));
    }
    if parsed.stop {
        return Err(refuse_all(ctx, "the tracker says STOP"));
    }
    if parsed.tracker_state.as_deref().unwrap_or("OPEN") != "OPEN" {
        return Err(refuse_all(ctx, "the tracker issue is closed"));
    }
    if numbers.is_empty() {
        numbers = parsed.approved_closures.clone();
    }
    if numbers.is_empty() {
        println!("close-verified: no closure is ticked on the tracker; nothing to do");
        return Ok(());
    }
    numbers.dedup();
    if let Some(n) = numbers.iter().find(|n| !parsed.approved_closures.contains(n)) {
        return Err(refuse_all(ctx, format!("#{n} is not a ticked closure on the tracker")));
    }

    let base = &ctx.profile.base_branch;
    if !ctx.dry_run {
        // The checkout must be of the repo whose issues are being closed, or
        // the "fix" is being read in someone else's code.
        match git::origin_repo(&repo_dir) {
            Some(origin) if origin.eq_ignore_ascii_case(&repo) => {}
            origin => {
                return Err(refuse_all(
                    ctx,
                    format!(
                        "the checkout at {} has origin {}, not {repo}",
                        repo_dir.display(),
                        origin.as_deref().unwrap_or("unset or not on github.com")
                    ),
                ));
            }
        }
    }
    if !args.no_fetch && !git::ok(&repo_dir, &["fetch", "--quiet", "origin", base]) {
        return Err(Fail::failed(format!(
            "could not fetch {base} in {}; a closure is checked against the base as it is now",
            repo_dir.display()
        )));
    }
    let shown = named_ref.cloned().unwrap_or_else(|| format!("origin/{base}"));
    let Some(reference) = git::commit(&repo_dir, &shown) else {
        return Err(Fail::failed(format!(
            "{shown} names no commit in {}",
            repo_dir.display()
        )));
    };

    let r = Run {
        ctx,
        repo,
        repo_dir,
        reference,
        shown,
        marker: format!("<!-- issue-drain:closure run={run} -->"),
        run,
        tracker: read_json::<Published>(&ctx.path("tracker.json")).map(|p| p.number),
        known: verdicts.iter().filter_map(|v| v["number"].as_u64()).collect(),
        verdicts,
    };
    let mut refused = 0;
    for number in &numbers {
        // Every number here is ticked, and only an offered closure can be.
        let Some(offered) = queue.closures.iter().find(|c| c.number == *number) else {
            continue;
        };
        // The tracker, read again: a STOP or an unticked box since the last
        // closure is honoured before the next one, not after the run.
        if !ctx.dry_run {
            let now = fetch_tracker(ctx, &queue)?;
            let halt = if !now.unknown.is_empty() {
                Some(format!(
                    "the tracker now has a ticked line this run never offered ({})",
                    now.unknown.join(", ")
                ))
            } else if now.stop {
                Some("the tracker now says STOP".to_string())
            } else if now.tracker_state.as_deref().unwrap_or("OPEN") != "OPEN" {
                Some("the tracker issue is now closed".to_string())
            } else {
                None
            };
            if let Some(why) = halt {
                return Err(refuse_all(ctx, format!("{why}; stopped before #{number}")));
            }
            if !now.approved_closures.contains(number) {
                let why = "its box is no longer ticked on the tracker";
                println!("refused #{number}: {why}");
                ctx.event("closure_refused", json!({"number": number, "why": why}))?;
                refused += 1;
                continue;
            }
        }
        match close_one(&r, *number, offered)? {
            Ok(()) => {}
            Err(Stop::Skipped(why)) => {
                println!("skipped #{number}: {why}");
                ctx.event("closure_skipped", json!({"number": number, "why": why}))?;
            }
            Err(Stop::Refused(why)) => {
                println!("refused #{number}: {why}");
                ctx.event("closure_refused", json!({"number": number, "why": why}))?;
                refused += 1;
            }
        }
    }
    if refused > 0 {
        return Err(Fail::refused(format!(
            "refused: {refused} of {} closures (reasons above)",
            numbers.len()
        )));
    }
    Ok(())
}
