//! `issue-drain tracker publish` and `tracker parse`.
//!
//! The tracker body is a person's: they tick, delete, reorder and type in it.
//! So parse reads by line prefix and by nothing else, and what the queue never
//! offered is reported, never acted on. The drain never edits the body.
//!
//! Two functions are for other commands (close-verified):
//!   - [`parse_body`]: a body and the queue in, a [`Parsed`] out; no I/O;
//!   - [`fetch_tracker`]: reads the live tracker through gh, then the same.

use std::fs::{self, OpenOptions};
use std::io::ErrorKind;
use std::path::PathBuf;
use std::sync::LazyLock;

use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::ctx::{Ctx, read_json, rfc3339, write_json};
use crate::error::{Fail, Res};
use crate::gh::{self, Write};
use crate::model::Queue;
use crate::text::parse_number;

#[derive(clap::Args)]
pub struct PublishArgs {}

#[derive(clap::Args)]
pub struct ParseArgs {
    /// Read the tracker body from this file instead of from GitHub (the
    /// tracker's state is then null).
    #[arg(long)]
    pub body_file: Option<PathBuf>,
}

/// tracker.json: written by publish, read to find the tracker again.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Published {
    pub number: u64,
    pub url: String,
    pub run: String,
    pub published_at: String,
}

/// What a person left on the tracker. This is `tracker parse`'s output, as one
/// line of JSON.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Parsed {
    /// The queue's run id.
    pub run: String,
    /// A line holding only the word STOP is present.
    pub stop: bool,
    /// The queue units the body still lists, in the order to run them: ticked
    /// units first (in the order written), then the plain unit lines. Each
    /// unit once, and only units the queue offered.
    pub units: Vec<String>,
    /// Ticked closures the queue offered, ascending.
    pub approved_closures: Vec<u64>,
    /// Ticked stale-claim releases the queue offered, ascending.
    pub release_claims: Vec<u64>,
    /// OPEN or CLOSED for a live read; null when the body came from a file.
    pub tracker_state: Option<String>,
    /// Lines that name something the queue never offered, as "unit U9",
    /// "close #999" or "release #55". Not empty means a caller must refuse:
    /// a box can approve only what render offered.
    pub unknown: Vec<String>,
}

static MARKER: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^<!-- issue-drain:tracker v1 run=([A-Za-z0-9._-]+) -->\s*$").expect("a fixed pattern")
});
static TICKED_UNIT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^- \[[xX]\] (U[0-9]+) · ").expect("a fixed pattern"));
static PLAIN_UNIT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^- (U[0-9]+) · ").expect("a fixed pattern"));
static CLOSE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^- \[[xX]\] close #([0-9]+)( |$)").expect("a fixed pattern"));
static RELEASE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^- \[[xX]\] release #([0-9]+)( |$)").expect("a fixed pattern"));
static STOP: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\s*STOP\s*$").expect("a fixed pattern"));

/// The first capture of `re` on every line that matches it, in order.
fn captures<'a>(lines: &[&'a str], re: &Regex) -> Vec<&'a str> {
    lines
        .iter()
        .filter_map(|line| re.captures(line).and_then(|c| c.get(1)).map(|m| m.as_str()))
        .collect()
}

/// Split the digits of a "#<n>" reference into the numbers the queue offered
/// (ascending, once each) and the ones it did not, as they should be shown.
fn split_numbers(found: &[&str], offered: &[u64]) -> (Vec<u64>, Vec<String>) {
    let mut approved = Vec::new();
    let mut unknown: Vec<String> = Vec::new();
    for digits in found {
        match digits.parse::<u64>() {
            Ok(n) if offered.contains(&n) => approved.push(n),
            Ok(n) => unknown.push(n.to_string()),
            Err(_) => unknown.push((*digits).to_string()),
        }
    }
    approved.sort_unstable();
    approved.dedup();
    let mut seen = Vec::new();
    unknown.retain(|n| {
        let fresh = !seen.contains(n);
        seen.push(n.clone());
        fresh
    });
    (approved, unknown)
}

/// Read what a person left on the tracker. No I/O.
///
/// Lines are read by prefix and nothing else:
///   `- U3 · ...`            a queue unit, in the order written
///   `- [x] U5 · ...`        a ticked unit; these run before the queue
///   `- [x] close #101 ...`  an approved closure
///   `- [x] release #9 ...`  a stale claim to release
///   `STOP`                  alone on a line
/// `[X]` counts as `[x]` and CRLF line endings are fine. The marker line
/// `<!-- issue-drain:tracker v1 run=<id> -->` must name `queue.run`, or the
/// body is some other tracker and this fails with a usage error (exit 2).
/// `tracker_state` is left null; a live read sets it.
pub fn parse_body(body: &str, queue: &Queue) -> Res<Parsed> {
    parse_body_for(body, queue, &queue.run)
}

/// The lines of a body, with or without CRLF endings.
fn lines_of(body: &str) -> Vec<&str> {
    body.split('\n').map(|l| l.strip_suffix('\r').unwrap_or(l)).collect()
}

fn parse_body_for(body: &str, queue: &Queue, run: &str) -> Res<Parsed> {
    let lines = lines_of(body);

    let marker = captures(&lines, &MARKER).first().copied();
    if marker != Some(run) {
        return Err(Fail::usage(format!(
            "that body is not the tracker for run {run} (its marker line says '{}'); refusing to read a queue from it",
            marker.unwrap_or("nothing")
        )));
    }

    let mut order: Vec<&str> = Vec::new();
    for id in captures(&lines, &TICKED_UNIT)
        .into_iter()
        .chain(captures(&lines, &PLAIN_UNIT))
    {
        if !order.contains(&id) {
            order.push(id);
        }
    }
    let known = |id: &&str| queue.units.iter().any(|u| u.id == *id);
    let units: Vec<String> = order.iter().filter(|id| known(id)).map(|id| id.to_string()).collect();
    let unknown_units = order.iter().filter(|id| !known(id));

    let closures: Vec<u64> = queue.closures.iter().map(|c| c.number).collect();
    let claims: Vec<u64> = queue.stale_claims.iter().map(|c| c.number).collect();
    let (approved_closures, unknown_closes) = split_numbers(&captures(&lines, &CLOSE), &closures);
    let (release_claims, unknown_releases) = split_numbers(&captures(&lines, &RELEASE), &claims);

    let mut unknown: Vec<String> = unknown_units.map(|id| format!("unit {id}")).collect();
    unknown.extend(unknown_closes.iter().map(|n| format!("close #{n}")));
    unknown.extend(unknown_releases.iter().map(|n| format!("release #{n}")));

    Ok(Parsed {
        run: queue.run.clone(),
        stop: lines.iter().any(|line| STOP.is_match(line)),
        units,
        approved_closures,
        release_claims,
        tracker_state: None,
        unknown,
    })
}

/// The body and state of the tracker issue this run published.
fn live(ctx: &Ctx) -> Res<(String, Option<String>)> {
    let saved: Published = read_json(&ctx.path("tracker.json")).ok_or_else(|| {
        Fail::usage("this run is not published; pass --body-file or run `issue-drain tracker publish`")
    })?;
    let number = saved.number.to_string();
    let unreadable = || Fail::failed(format!("could not read tracker #{number}"));
    let raw = gh::read(&["issue", "view", &number, "--repo", &ctx.repo()?, "--json", "body,state"])
        .map_err(|_| unreadable())?;
    let view: Value = serde_json::from_str(&raw).map_err(|_| unreadable())?;
    let body = view["body"].as_str().unwrap_or_default().to_string();
    Ok((body, view["state"].as_str().map(str::to_string)))
}

/// Read the live tracker issue this run published (tracker.json names it)
/// through gh, and parse it as [`parse_body`] does, with `tracker_state` set
/// to the issue's state (OPEN or CLOSED).
///
/// Errors: usage (exit 2) when the run is not published or the body is not
/// this run's tracker; failed (exit 1) when gh cannot read the issue.
pub fn fetch_tracker(ctx: &Ctx, queue: &Queue) -> Res<Parsed> {
    let run = ctx.run_id()?;
    let (body, state) = live(ctx)?;
    let mut parsed = parse_body_for(&body, queue, &run)?;
    parsed.tracker_state = state;
    Ok(parsed)
}

fn load_queue(ctx: &Ctx) -> Res<Queue> {
    let path = ctx.path("queue.json");
    if !path.is_file() {
        return Err(Fail::usage(format!(
            "no queue.json in {}; this run has no rendered tracker",
            ctx.workdir.display()
        )));
    }
    let queue: Queue = read_json(&path).ok_or_else(|| Fail::usage(format!("{} is not a queue", path.display())))?;
    // A queue is published to, and read against, the repo it was rendered for.
    // GitHub does not tell owner and repo names apart by case.
    let repo = ctx.repo()?;
    if !queue.repo.eq_ignore_ascii_case(&repo) {
        return Err(Fail::usage(format!(
            "this queue was rendered for {}, and ISSUE_DRAIN_REPO is {repo}",
            queue.repo
        )));
    }
    Ok(queue)
}

/// Held while a publish runs, so two cannot both create a tracker. The file
/// is removed when the publish returns.
struct Lock(PathBuf);

impl Drop for Lock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

fn lock(ctx: &Ctx) -> Res<Lock> {
    let path = ctx.path("publish.lock");
    match OpenOptions::new().write(true).create_new(true).open(&path) {
        Ok(_) => Ok(Lock(path)),
        Err(e) if e.kind() == ErrorKind::AlreadyExists => Err(Fail::refused(format!(
            "another publish of this run is in progress ({} exists); if none is, remove that file",
            path.display()
        ))),
        Err(e) => Err(Fail::failed(format!("cannot create {}: {e}", path.display()))),
    }
}

/// An open tracker issue this run already created: the viewer's own, carrying
/// the tracker label and this run's marker line. A publish that died between
/// `gh issue create` and tracker.json leaves one, and a second create would
/// leave two trackers for one queue.
fn existing(ctx: &Ctx, run: &str) -> Res<Option<(u64, String, String)>> {
    let repo = ctx.repo()?;
    let unreadable = || {
        Fail::failed(format!(
            "could not list the open trackers of {repo}, so nothing was created"
        ))
    };
    let raw = gh::read(&[
        "issue",
        "list",
        "--repo",
        &repo,
        "--label",
        &ctx.profile.tracker_label,
        "--author",
        "@me",
        "--state",
        "open",
        "--limit",
        "100",
        "--json",
        "number,url,body",
    ])
    .map_err(|_| unreadable())?;
    let issues: Vec<Value> = serde_json::from_str(&raw).map_err(|_| unreadable())?;
    Ok(issues.iter().find_map(|issue| {
        let lines = lines_of(issue["body"].as_str()?);
        if captures(&lines, &MARKER).first().copied() != Some(run) {
            return None;
        }
        Some((
            issue["number"].as_u64()?,
            issue["url"].as_str()?.to_string(),
            issue["body"].as_str()?.to_string(),
        ))
    }))
}

/// Write tracker.json and the `tracker-<n>` link, log `event` and print the URL.
fn record(ctx: &Ctx, event: &str, number: u64, url: &str, run: String) -> Res<()> {
    let published = Published {
        number,
        url: url.to_string(),
        run,
        published_at: rfc3339(ctx.now()),
    };
    write_json(&ctx.path("tracker.json"), &published)?;

    // Find the run by its tracker number later: <repo folder>/tracker-<n> -> this run.
    if let Some(parent) = ctx.workdir.parent() {
        let link = parent.join(format!("tracker-{number}"));
        let _ = fs::remove_file(&link);
        let _ = std::os::unix::fs::symlink(&ctx.workdir, link);
    }
    ctx.event(
        event,
        json!({"number": published.number, "url": published.url, "run": published.run,
               "published_at": published.published_at}),
    )?;
    println!("{url}");
    Ok(())
}

pub fn publish(ctx: &Ctx, _args: &PublishArgs) -> Res<()> {
    let run = ctx.run_id()?;
    let (body, queue_file, saved) = (ctx.path("tracker.md"), ctx.path("queue.json"), ctx.path("tracker.json"));
    if !(body.is_file() && queue_file.is_file()) {
        return Err(Fail::usage(
            "nothing to publish; run `issue-drain tracker render` first",
        ));
    }
    // The lock comes first: the check below is only true for as long as no
    // other publish can write tracker.json.
    let _lock = lock(ctx)?;
    if saved.exists() {
        let url = read_json::<Published>(&saved).map(|p| p.url).unwrap_or_default();
        return Err(Fail::refused(format!("already published: {url}")));
    }
    let queue = load_queue(ctx)?;

    // A dry run reads nothing from GitHub, as everywhere else.
    if !ctx.dry_run {
        if let Some((number, url, theirs)) = existing(ctx, &run)? {
            // The run can be rendered again between a publish that died and
            // this one. A tracker showing the earlier render is not adopted:
            // a tick on it approves an offer this queue may not make.
            let ours =
                fs::read_to_string(&body).map_err(|e| Fail::failed(format!("cannot read {}: {e}", body.display())))?;
            let text = |s: &str| s.replace("\r\n", "\n").trim_end().to_string();
            if text(&ours) != text(&theirs) {
                return Err(Fail::refused(format!(
                    "this run already created tracker #{number} ({url}), and its body does not match the queue \
                     rendered now; close #{number} and publish again, or render the decisions it was made from"
                )));
            }
            return record(ctx, "tracker_adopted", number, &url, run);
        }
    }

    gh::write(
        ctx,
        &Write::EnsureLabel {
            label: &ctx.profile.tracker_label,
        },
    )?;
    let made = gh::write(
        ctx,
        &Write::IssueCreate {
            title: &queue.title,
            body_file: &body,
        },
    )?;
    if ctx.dry_run {
        return Ok(());
    }

    let url = made
        .stdout
        .lines()
        .rfind(|l| l.starts_with("https://"))
        .unwrap_or_default();
    let Some(number) = url.rsplit('/').next().and_then(parse_number) else {
        return Err(Fail::failed(format!(
            "the issue was created but its number could not be read from gh's output: {}",
            made.stdout.trim()
        )));
    };
    record(ctx, "tracker_published", number, url, run)
}

pub fn parse(ctx: &Ctx, args: &ParseArgs) -> Res<()> {
    let run = ctx.run_id()?;
    let queue = load_queue(ctx)?;
    let file = args.body_file.as_ref().filter(|f| !f.as_os_str().is_empty());
    let (body, state) = match file {
        None => live(ctx)?,
        Some(file) => {
            if !file.is_file() {
                return Err(Fail::usage(format!("no body file at {}", file.display())));
            }
            let bytes = fs::read(file).map_err(|e| Fail::failed(format!("cannot read {}: {e}", file.display())))?;
            (String::from_utf8_lossy(&bytes).into_owned(), None)
        }
    };
    let mut parsed = parse_body_for(&body, &queue, &run)?;
    parsed.tracker_state = state;

    println!(
        "{}",
        serde_json::to_string(&parsed).map_err(|e| Fail::failed(format!("cannot encode the result: {e}")))?
    );
    ctx.event(
        "tracker_parsed",
        json!({"stop": parsed.stop, "units": parsed.units.len(),
               "approved_closures": parsed.approved_closures, "release_claims": parsed.release_claims,
               "tracker_state": parsed.tracker_state, "unknown": parsed.unknown}),
    )?;
    if parsed.unknown.is_empty() {
        return Ok(());
    }
    let said: Vec<String> = parsed
        .unknown
        .iter()
        .map(|what| format!("the tracker asks for something this run never offered: {what}"))
        .collect();
    Err(Fail::failed(said.join("\n")))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn queue() -> Queue {
        let text = include_str!("../../tests/fixtures/run/queue.json");
        serde_json::from_str(text).expect("the golden queue")
    }

    #[test]
    fn parse_body_is_pure_and_checks_the_marker() {
        let q = queue();
        let ok = parse_body(
            "<!-- issue-drain:tracker v1 run=run -->\n- U2 · x\n- [x] close #101 · y\n",
            &q,
        )
        .expect("parses");
        assert_eq!(ok.units, ["U2"]);
        assert_eq!(ok.approved_closures, [101]);
        assert_eq!(ok.tracker_state, None);
        assert_eq!(parse_body("- U2 · x\n", &q).unwrap_err().code, 2);
    }

    #[test]
    fn a_number_too_big_for_u64_is_unknown_not_a_panic() {
        let q = queue();
        let body = "<!-- issue-drain:tracker v1 run=run -->\n- [x] close #99999999999999999999999 · y\n";
        let found = parse_body(body, &q).expect("parses");
        assert_eq!(found.unknown, ["close #99999999999999999999999"]);
    }

    #[test]
    fn a_leading_zero_is_the_same_number() {
        let q = queue();
        let body = "<!-- issue-drain:tracker v1 run=run -->\n- [x] close #0101 · y\n";
        assert_eq!(parse_body(body, &q).expect("parses").approved_closures, [101]);
    }
}
