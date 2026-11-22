//! `issue-drain state`: where each unit of the drain is.
//!
//! `events.jsonl` is the record. Every `state` command rebuilds its view by
//! replaying the state events in it, so a `state.json` that is missing or
//! stale never changes an answer; `state.json` is only a snapshot written for
//! readers. The replay is also the rule check: the same function that
//! accepts a new event accepts each old one, so a hand-edited log is caught
//! by `rebuild` as well as a bad command line.
//!
//! The log is shared with the other commands (`Ctx::event`). Their lines carry
//! an `event` key; a state event never does, and replay skips theirs.
//! Nothing here touches GitHub or git.

use std::fs::{self, OpenOptions};
use std::io::Write as _;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::ctx::{Ctx, read_json, rfc3339, write_json};
use crate::error::{Fail, Res};
use crate::merge_gate::is_sha;
use crate::model::Queue;

/// Base syncs (gate back to ci_wait) one unit may take.
pub const MAX_BASE_SYNCS: u32 = 4;
/// Moves into repairing one unit may take.
pub const MAX_REPAIRS: u32 = 2;

/// `to` of the event that records a drain-level stop, and of the one that
/// clears it. Neither names a unit.
const STOP: &str = "stop";
const RESUME: &str = "resume";

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum State {
    Queued,
    Claimed,
    Prepared,
    Implementing,
    PrOpen,
    Reviewing,
    CiWait,
    Repairing,
    Gate,
    Merged,
    Done,
    Skipped,
    Blocked,
    Parked,
}

use State::*;

impl State {
    pub const ALL: [State; 14] = [
        Queued,
        Claimed,
        Prepared,
        Implementing,
        PrOpen,
        Reviewing,
        CiWait,
        Repairing,
        Gate,
        Merged,
        Done,
        Skipped,
        Blocked,
        Parked,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Queued => "queued",
            Claimed => "claimed",
            Prepared => "prepared",
            Implementing => "implementing",
            PrOpen => "pr_open",
            Reviewing => "reviewing",
            CiWait => "ci_wait",
            Repairing => "repairing",
            Gate => "gate",
            Merged => "merged",
            Done => "done",
            Skipped => "skipped",
            Blocked => "blocked",
            Parked => "parked",
        }
    }

    pub fn from_name(name: &str) -> Option<State> {
        State::ALL.into_iter().find(|s| s.as_str() == name)
    }

    /// Nothing more happens to a unit in one of these.
    pub fn is_terminal(self) -> bool {
        matches!(self, Done | Skipped | Blocked | Parked)
    }

    /// The transition table: every state a unit may move to from this one.
    pub fn exits(self) -> &'static [State] {
        match self {
            Queued => &[Claimed, Skipped],
            Claimed => &[Prepared, Skipped, Blocked],
            Prepared => &[Implementing, Skipped, Blocked],
            Implementing => &[PrOpen, Skipped, Blocked],
            PrOpen => &[Reviewing, Parked, Blocked, Skipped],
            Reviewing => &[CiWait, Parked, Blocked],
            CiWait => &[Gate, Repairing, Blocked],
            Repairing => &[Reviewing, CiWait, Parked, Blocked],
            Gate => &[Merged, CiWait, Repairing, Reviewing, Parked],
            Merged => &[Done],
            Done | Skipped | Blocked | Parked => &[],
        }
    }
}

/// One line of the log that `state` owns.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Event {
    pub ts: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unit: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
    pub to: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pr: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head: Option<String>,
    /// On a unit's `queued` event only: the issues it carries, so the log alone
    /// can rebuild the snapshot.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub issues: Option<Vec<u64>>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct UnitState {
    pub unit: u64,
    pub issues: Vec<u64>,
    pub state: State,
    pub pr: Option<u64>,
    pub head: Option<String>,
    pub base_syncs: u32,
    pub repairs: u32,
    /// When the unit last changed.
    pub updated: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Stopped {
    pub ts: String,
    pub reason: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
pub struct Snapshot {
    /// Unit numbers in the order to run them.
    pub queue: Vec<u64>,
    pub stopped: Option<Stopped>,
    /// In queue order.
    pub units: Vec<UnitState>,
}

impl Snapshot {
    fn unit(&self, number: u64) -> Option<&UnitState> {
        self.units.iter().find(|u| u.unit == number)
    }

    /// Check `ev` against the rules and, only if it passes, fold it in. The
    /// error is the reason, ready to print.
    pub fn apply(&mut self, ev: &Event) -> Result<(), String> {
        match ev.to.as_str() {
            STOP => self.apply_stop(ev),
            RESUME => self.apply_resume(ev),
            _ => self.apply_unit(ev),
        }
    }

    fn apply_stop(&mut self, ev: &Event) -> Result<(), String> {
        if ev.unit.is_some() {
            return Err("a stop names no unit".into());
        }
        if let Some(stopped) = &self.stopped {
            return Err(format!("the drain is already stopped ({})", stopped.reason));
        }
        match ev.note.as_deref().map(str::trim) {
            Some(reason) if !reason.is_empty() => {
                self.stopped = Some(Stopped {
                    ts: ev.ts.clone(),
                    reason: reason.to_string(),
                });
                Ok(())
            }
            _ => Err("a stop needs a reason".into()),
        }
    }

    fn apply_resume(&mut self, ev: &Event) -> Result<(), String> {
        if ev.unit.is_some() {
            return Err("a resume names no unit".into());
        }
        if self.stopped.take().is_none() {
            return Err("the drain is not stopped, so there is nothing to resume".into());
        }
        Ok(())
    }

    fn apply_unit(&mut self, ev: &Event) -> Result<(), String> {
        let number = ev
            .unit
            .ok_or_else(|| format!("an event to '{}' names no unit", ev.to))?;
        let to = State::from_name(&ev.to).ok_or_else(|| format!("'{}' is not a state", ev.to))?;
        if let Some(stopped) = &self.stopped {
            return Err(format!(
                "the drain is stopped ({}); unit {number} cannot move to {} until `state resume`",
                stopped.reason,
                to.as_str()
            ));
        }
        let Some(at) = self.units.iter().position(|u| u.unit == number) else {
            if to != Queued || ev.from.is_some() {
                return Err(format!(
                    "unit {number} is not in the queue; it cannot move to {}",
                    to.as_str()
                ));
            }
            self.queue.push(number);
            self.units.push(UnitState {
                unit: number,
                issues: ev.issues.clone().unwrap_or_default(),
                state: Queued,
                pr: None,
                head: None,
                base_syncs: 0,
                repairs: 0,
                updated: ev.ts.clone(),
            });
            return Ok(());
        };
        let unit = &mut self.units[at];
        let from = unit.state;
        if ev.from.as_deref().is_some_and(|f| f != from.as_str()) {
            return Err(format!(
                "unit {number} is in state {} but the event says it moves from {}",
                from.as_str(),
                ev.from.as_deref().unwrap_or_default()
            ));
        }
        if !from.exits().contains(&to) {
            return Err(format!(
                "unit {number} is in state {} and cannot move to {}",
                from.as_str(),
                to.as_str()
            ));
        }
        let base_sync = from == Gate && to == CiWait;
        if base_sync && unit.base_syncs >= MAX_BASE_SYNCS {
            return Err(format!(
                "unit {number} is in state gate and has already taken its {MAX_BASE_SYNCS} base syncs; it cannot move to ci_wait"
            ));
        }
        if to == Repairing && unit.repairs >= MAX_REPAIRS {
            return Err(format!(
                "unit {number} is in state {} and has already been repaired {MAX_REPAIRS} times; it cannot move to repairing",
                from.as_str()
            ));
        }
        if to == PrOpen && ev.pr.is_none() {
            return Err(format!("unit {number} cannot move to pr_open without --pr"));
        }
        if to == Merged && ev.head.is_none() {
            return Err(format!("unit {number} cannot move to merged without --head"));
        }
        unit.state = to;
        unit.base_syncs += u32::from(base_sync);
        unit.repairs += u32::from(to == Repairing);
        if ev.pr.is_some() {
            unit.pr = ev.pr;
        }
        if ev.head.is_some() {
            unit.head.clone_from(&ev.head);
        }
        unit.updated = ev.ts.clone();
        Ok(())
    }
}

/// What a replay of the log found.
struct Replay {
    snapshot: Snapshot,
    /// State events seen; 0 means `state init` has not run.
    events: usize,
    /// The log's text, for appending after.
    text: String,
}

fn log_path(ctx: &Ctx) -> PathBuf {
    ctx.path("events.jsonl")
}

/// Replay the log. A line that does not parse as a state event, or that the
/// rules refuse, is a failure naming its line number. Other commands' lines
/// (those with an `event` key) are skipped.
fn replay(ctx: &Ctx) -> Res<Replay> {
    let path = log_path(ctx);
    let text = match fs::read_to_string(&path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(e) => return Err(Fail::failed(format!("cannot read {}: {e}", path.display()))),
    };
    let mut snapshot = Snapshot::default();
    let mut events = 0;
    for (index, line) in text.lines().enumerate() {
        let number = index + 1;
        if line.trim().is_empty() {
            continue;
        }
        let value: Value = serde_json::from_str(line)
            .map_err(|e| Fail::failed(format!("{} line {number} is not JSON: {e}", path.display())))?;
        if value.get("event").is_some() {
            continue;
        }
        let ev: Event = serde_json::from_value(value)
            .map_err(|e| Fail::failed(format!("{} line {number} is not a state event: {e}", path.display())))?;
        snapshot
            .apply(&ev)
            .map_err(|why| Fail::failed(format!("{} line {number}: {why}", path.display())))?;
        events += 1;
    }
    Ok(Replay { snapshot, events, text })
}

/// A replay that must find a started drain.
fn started(ctx: &Ctx) -> Res<Replay> {
    let replay = replay(ctx)?;
    if replay.events == 0 {
        return Err(Fail::usage(format!(
            "no state events in {}; run `issue-drain state init` first",
            log_path(ctx).display()
        )));
    }
    Ok(replay)
}

fn append(ctx: &Ctx, before: &str, events: &[Event]) -> Res<()> {
    let path = log_path(ctx);
    let mut out = String::new();
    if !before.is_empty() && !before.ends_with('\n') {
        out.push('\n');
    }
    for ev in events {
        out.push_str(&serde_json::to_string(ev).map_err(|e| Fail::failed(format!("cannot encode an event: {e}")))?);
        out.push('\n');
    }
    let write = || -> std::io::Result<()> {
        fs::create_dir_all(&ctx.workdir)?;
        OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)?
            .write_all(out.as_bytes())
    };
    write().map_err(|e| Fail::failed(format!("cannot write {}: {e}", path.display())))
}

fn write_snapshot(ctx: &Ctx, snapshot: &Snapshot) -> Res<()> {
    write_json(&ctx.path("state.json"), snapshot)
}

/// Apply one new event to a started drain, then record it.
fn record(ctx: &Ctx, ev: Event) -> Res<()> {
    let Replay { mut snapshot, text, .. } = started(ctx)?;
    snapshot.apply(&ev).map_err(Fail::refused)?;
    append(ctx, &text, &[ev])?;
    write_snapshot(ctx, &snapshot)
}

#[derive(clap::Subcommand)]
pub enum Command {
    /// Queue every unit of the run, in queue order.
    Init(InitArgs),
    /// Move a unit to a new state, if the table allows it.
    Event(EventArgs),
    /// Stop the drain: no unit moves until `state resume`.
    Stop(StopArgs),
    /// Lift a stop.
    Resume,
    /// Print where every unit is.
    Show(ShowArgs),
    /// Print the number of the next unit still to work, if any.
    Next,
    /// Rebuild state.json from events.jsonl alone.
    Rebuild,
}

#[derive(clap::Args)]
pub struct InitArgs {
    /// Output saved from `tracker parse`: queue only the units it lists, in
    /// its order (default: every unit of queue.json, in its order).
    #[arg(long)]
    parsed: Option<PathBuf>,
}

#[derive(clap::Args)]
pub struct EventArgs {
    /// The unit's number (3 for U3).
    unit: u64,
    /// The state to move to.
    to: String,
    #[arg(long)]
    note: Option<String>,
    /// The PR's number. Required on the move to pr_open.
    #[arg(long)]
    pr: Option<u64>,
    /// The merge commit, a full 40 or 64 digit SHA. Required on the move to merged.
    #[arg(long)]
    head: Option<String>,
}

#[derive(clap::Args)]
pub struct StopArgs {
    #[arg(long)]
    reason: String,
}

#[derive(clap::Args)]
pub struct ShowArgs {
    /// Print the snapshot as JSON.
    #[arg(long)]
    json: bool,
}

pub fn run(ctx: &Ctx, command: &Command) -> Res<()> {
    // references/unit.md tells a unit to run none of the state verbs: the
    // driver records unit events itself, and a unit that wrote one could move
    // its own unit along. So none is open to a unit.
    ctx.require_driver("state")?;
    match command {
        Command::Init(args) => {
            let queued = init(ctx, args)?;
            println!("queued {queued} units");
            Ok(())
        }
        Command::Event(args) => event(ctx, args),
        Command::Stop(args) => record(ctx, now_event(ctx, None, STOP, Some(args.reason.clone()))),
        Command::Resume => record(ctx, now_event(ctx, None, RESUME, None)),
        Command::Show(args) => show(ctx, args),
        Command::Next => next(ctx),
        Command::Rebuild => rebuild(ctx),
    }
}

fn now_event(ctx: &Ctx, unit: Option<u64>, to: &str, note: Option<String>) -> Event {
    Event {
        ts: rfc3339(ctx.now()),
        unit,
        from: None,
        to: to.to_string(),
        note,
        pr: None,
        head: None,
        issues: None,
    }
}

/// `U3` is unit 3.
fn unit_number(id: &str) -> Option<u64> {
    id.strip_prefix('U')?.parse().ok()
}

/// The go-ahead SKILL.md asks for before anything runs: the tracker is open,
/// has no STOP line, and holds nothing the run never offered. A saved parse
/// that does not say all three is not the output of `tracker parse`. A null
/// `tracker_state` means the body came from a file, which only a dry run does.
fn called_off(parsed: &Value, path: &str, dry_run: bool, run: &str) -> Res<()> {
    let missing = |key: &str| {
        Fail::usage(format!(
            "{} has no \"{key}\"; it is not what `tracker parse` prints",
            path
        ))
    };
    let parsed_run = parsed
        .get("run")
        .and_then(Value::as_str)
        .ok_or_else(|| missing("run"))?;
    let stop = parsed
        .get("stop")
        .and_then(Value::as_bool)
        .ok_or_else(|| missing("stop"))?;
    let unknown = parsed
        .get("unknown")
        .and_then(Value::as_array)
        .ok_or_else(|| missing("unknown"))?;
    let tracker_state = match parsed.get("tracker_state") {
        Some(Value::String(state)) => Some(state.as_str()),
        Some(Value::Null) => None,
        _ => return Err(missing("tracker_state")),
    };
    if parsed_run != run {
        return Err(Fail::refused(format!(
            "{} is the parse of run '{parsed_run}', not of this run '{run}'",
            path
        )));
    }
    if stop {
        return Err(Fail::refused(
            "the tracker has a STOP line: the user called the run off",
        ));
    }
    match tracker_state {
        Some("OPEN") => {}
        Some(state) => {
            return Err(Fail::refused(format!(
                "the tracker is {state}, not OPEN: the user called the run off"
            )));
        }
        None if dry_run => {}
        None => {
            return Err(Fail::refused(
                "tracker_state is null, so this parse did not read the live tracker (only a dry run may start from a file)",
            ));
        }
    }
    if !unknown.is_empty() {
        let lines: Vec<&str> = unknown.iter().filter_map(Value::as_str).collect();
        return Err(Fail::refused(format!(
            "the tracker has lines the run never offered: {}",
            lines.join("; ")
        )));
    }
    Ok(())
}

/// Queue the units; the number queued.
fn init(ctx: &Ctx, args: &InitArgs) -> Res<usize> {
    let source = match &args.parsed {
        None => None,
        Some(path) => {
            let parsed: Value = read_json(path).ok_or_else(|| {
                Fail::usage(format!(
                    "{} is not the JSON that `tracker parse` prints",
                    path.display()
                ))
            })?;
            Some((parsed, path.display().to_string()))
        }
    };
    init_from(ctx, source)
}

/// `init`, with the approved tracker (a `tracker parse` answer and the name to
/// call it in messages) already read.
fn init_from(ctx: &Ctx, source: Option<(Value, String)>) -> Res<usize> {
    let replay = replay(ctx)?;
    if replay.events > 0 {
        return Err(Fail::refused(format!(
            "{} already has {} state events; `state init` runs once per run",
            log_path(ctx).display(),
            replay.events
        )));
    }
    let queue_path = ctx.path("queue.json");
    let queue: Queue = read_json(&queue_path).ok_or_else(|| {
        Fail::usage(format!(
            "no queue in {}; run `tracker render` first",
            queue_path.display()
        ))
    })?;
    let mut units: Vec<(u64, Vec<u64>)> = Vec::new();
    for unit in &queue.units {
        let number = unit_number(&unit.id)
            .ok_or_else(|| Fail::usage(format!("queue.json has a unit named '{}', not U<number>", unit.id)))?;
        units.push((number, unit.issues.clone()));
    }
    if let Some((parsed, path)) = &source {
        let listed = parsed
            .get("units")
            .and_then(Value::as_array)
            .ok_or_else(|| Fail::usage(format!("{} has no \"units\" list", path)))?;
        called_off(parsed, path, ctx.dry_run, &queue.run)?;
        let mut ordered = Vec::new();
        for id in listed {
            let id = id.as_str().unwrap_or_default();
            let found = unit_number(id).and_then(|n| units.iter().find(|(m, _)| *m == n));
            let Some(found) = found else {
                return Err(Fail::usage(format!(
                    "{path} lists {id}, which queue.json does not have"
                )));
            };
            if ordered.contains(found) {
                return Err(Fail::usage(format!("{path} lists {id} twice")));
            }
            ordered.push(found.clone());
        }
        units = ordered;
    }
    if units.is_empty() {
        return Err(Fail::usage("there are no units to queue"));
    }
    let mut snapshot = Snapshot::default();
    let mut events = Vec::new();
    for (number, issues) in units {
        let mut ev = now_event(ctx, Some(number), Queued.as_str(), None);
        ev.issues = Some(issues);
        snapshot.apply(&ev).map_err(Fail::usage)?;
        events.push(ev);
    }
    append(ctx, &replay.text, &events)?;
    write_snapshot(ctx, &snapshot)?;
    Ok(events.len())
}

/// Start the state log with `state init`'s own code when the run has none: no
/// state event in `events.jsonl` and no `state.json`. A by-hand run that never
/// ran `state init` gets one this way. `Ok(true)` when it started the log.
pub fn init_if_missing(ctx: &Ctx) -> Res<bool> {
    if replay(ctx)?.events > 0 || ctx.path("state.json").exists() {
        return Ok(false);
    }
    // The approved tracker, when the run published one: units the person
    // deleted stay out and the order is theirs. Only a run that never
    // published one starts from queue.json.
    let source = if ctx.path("tracker.json").is_file() {
        let hint = |why: &str| {
            Fail::refused(format!(
                "this run has a published tracker, but its approved units could not be read ({why}); \
                 run `issue-drain tracker parse > parsed.json` and then `issue-drain state init --parsed parsed.json`"
            ))
        };
        let queue: Queue = read_json(&ctx.path("queue.json")).ok_or_else(|| hint("no queue.json"))?;
        let parsed = crate::tracker::io::fetch_tracker(ctx, &queue).map_err(|e| hint(&e.msg))?;
        let value = serde_json::to_value(&parsed).map_err(|e| hint(&e.to_string()))?;
        Some((value, "the published tracker".to_string()))
    } else {
        None
    };
    init_from(ctx, source).map_err(|e| {
        if ctx.path("tracker.json").is_file() && e.code != 1 {
            Fail::refused(format!(
                "{} (the run's tracker is the source; start the state with `state init --parsed` once that is fixed)",
                e.msg
            ))
        } else {
            e
        }
    })?;
    Ok(true)
}

fn event(ctx: &Ctx, args: &EventArgs) -> Res<()> {
    let to = State::from_name(&args.to).ok_or_else(|| {
        let names: Vec<&str> = State::ALL.iter().map(|s| s.as_str()).collect();
        Fail::usage(format!(
            "'{}' is not a state; the states are {}",
            args.to,
            names.join(", ")
        ))
    })?;
    if let Some(head) = &args.head {
        if !is_sha(head) {
            return Err(Fail::usage(format!(
                "--head must be a full 40 or 64 digit commit SHA (got '{head}')"
            )));
        }
    }
    let Replay { mut snapshot, text, .. } = started(ctx)?;
    let Some(unit) = snapshot.unit(args.unit) else {
        return Err(Fail::refused(format!(
            "unit {} is not in the queue; it cannot move to {}",
            args.unit,
            to.as_str()
        )));
    };
    let mut ev = now_event(ctx, Some(args.unit), to.as_str(), args.note.clone());
    ev.from = Some(unit.state.as_str().to_string());
    ev.pr = args.pr;
    ev.head = args.head.clone();
    snapshot.apply(&ev).map_err(Fail::refused)?;
    append(ctx, &text, &[ev])?;
    write_snapshot(ctx, &snapshot)
}

fn show(ctx: &Ctx, args: &ShowArgs) -> Res<()> {
    let snapshot = started(ctx)?.snapshot;
    if args.json {
        let text = serde_json::to_string_pretty(&snapshot)
            .map_err(|e| Fail::failed(format!("cannot encode the snapshot: {e}")))?;
        println!("{text}");
        return Ok(());
    }
    match &snapshot.stopped {
        Some(stopped) => println!("STOPPED {}: {}", stopped.ts, stopped.reason),
        None => println!("running"),
    }
    println!(
        "{:<5} {:<13} {:<7} {:<10} {:<6} {:<8} {:<21} issues",
        "unit", "state", "pr", "head", "syncs", "repairs", "updated"
    );
    for unit in &snapshot.units {
        let issues: Vec<String> = unit.issues.iter().map(|n| format!("#{n}")).collect();
        println!(
            "{:<5} {:<13} {:<7} {:<10} {:<6} {:<8} {:<21} {}",
            format!("U{}", unit.unit),
            unit.state.as_str(),
            unit.pr.map_or("-".to_string(), |n| format!("#{n}")),
            unit.head
                .as_deref()
                .map_or("-".to_string(), |h| h.chars().take(9).collect::<String>()),
            unit.base_syncs,
            unit.repairs,
            unit.updated,
            issues.join(" ")
        );
    }
    Ok(())
}

fn next(ctx: &Ctx) -> Res<()> {
    let snapshot = started(ctx)?.snapshot;
    if let Some(stopped) = &snapshot.stopped {
        return Err(Fail::refused(format!("the drain is stopped ({})", stopped.reason)));
    }
    let first = snapshot.units.iter().find(|u| !u.state.is_terminal()).map(|u| u.unit);
    if let Some(number) = first {
        println!("{number}");
    }
    Ok(())
}

fn rebuild(ctx: &Ctx) -> Res<()> {
    let snapshot = started(ctx)?.snapshot;
    write_snapshot(ctx, &snapshot)?;
    println!("rebuilt state.json: {} units", snapshot.units.len());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_live_state_has_a_way_out_and_every_terminal_state_has_none() {
        for state in State::ALL {
            if state.is_terminal() {
                assert!(state.exits().is_empty(), "{} is terminal", state.as_str());
            } else {
                assert!(!state.exits().is_empty(), "{} is stuck", state.as_str());
            }
        }
    }

    #[test]
    fn every_state_but_queued_can_be_reached_and_nothing_re_enters_queued() {
        for state in State::ALL {
            let entered = State::ALL.iter().any(|from| from.exits().contains(&state));
            assert_eq!(entered, state != Queued, "{}", state.as_str());
        }
    }

    #[test]
    fn names_round_trip() {
        for state in State::ALL {
            assert_eq!(State::from_name(state.as_str()), Some(state));
        }
        assert_eq!(State::from_name("stop"), None);
    }
}
