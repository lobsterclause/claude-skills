//! `issue-drain drive [--once]`: the driver. A loop with no model in it that
//! carries each queued unit from `queued` to a terminal state by calling this
//! crate's own subcommands, and stops on the stop conditions below.
//!
//! Output. Stdout is one JSON line, printed when the driver ends. Progress goes
//! to stderr, one line each, prefixed `drive: `: every log step and every state
//! move (`drive: U1 -> parked (cap reached)`), a line before each long child
//! (`unit-run`, `merge-gate`, `base-sync`, `post-merge`, `stamp-remote-pass`,
//! `unit-prepare`, `cleanup`, `retro`) naming its `drive/<seq>-<name>.out|.err`
//! files, and, while CI is awaited, a line about every five minutes (never more
//! than one poll early) saying which unit and PR the driver waits on. The lines
//! are best effort: a stderr nobody reads loses lines, never stalls the driver.
//! A `running` line is printed once its two files exist. `--quiet` turns all of
//! it off. While
//! the driver runs, `<run folder>/drive.pid` holds its pid; the file is removed
//! on any return, but a killed driver leaves it, so a watcher must check the
//! pid is alive (`kill -0`). The repo-level `drive.lock` below also holds a pid.
//!
//! Calls. Every step runs a subcommand as a child of this same binary
//! (`std::env::current_exe()`), through `exec`, with the same environment, so
//! each command keeps the exit codes, refusals and logging it is tested for.
//! Their stdout and stderr go to `<run folder>/drive/<seq>-<command>.out|.err`,
//! and the driver reads the JSON line at the end of stdout. Each step also logs
//! a `drive` event. A unit process cannot run the driver (exit 3). The driver's
//! own `gh` reads (the PR view and the rest) are cut off after 60 s
//! (ISSUE_DRAIN_GH_READ_TIMEOUT_SECS) and count as unreadable reads.
//!
//! State. Every unit move goes through `state event`; only the driver moves
//! state. The snapshot (`state show --json`) decides what to do next, so a
//! driver killed and started again carries on from the recorded state, and each
//! handler is safe to run twice: `unit-prepare` reuses a worktree, a unit left
//! in `implementing` with a `result.json` is read without starting claude, a
//! `merged` unit runs `post-merge` again, and the end-of-unit work (tracker
//! comment, claim release, cleanup) is done once per unit, guarded by
//! `units/<n>/drive-ended.json`. Only a unit the driver has touched
//! (`units/<n>/drive-owned`) gets that end-of-unit work. The state log is
//! started at startup from `tracker parse` (saved as `parsed.json`) and
//! `state init --parsed` when the run has none.
//!
//! One driver per repo. The driver holds an advisory lock (`flock`) on
//! `$HOME/.issue-drain/<owner>__<repo>/drive.lock` for its whole life and writes
//! its pid there for whoever is refused; the kernel releases the lock when the
//! process exits, however it exits, and the file is left in place. (pr-drain's `lock.sh`
//! is not located by this crate, so the lock is made here.) While a child runs,
//! its process group is in `drive-child.pid` beside the lock; a driver killed
//! mid-call leaves that file, and the next driver refuses (exit 3) while that
//! group is alive and removes the file once it is not. `caffeinate -i -w <pid>`
//! keeps the Mac awake while the driver runs, if `caffeinate` exists.
//!
//! Unattended runs. Without `--once` the driver carries unit after unit with
//! nobody watching, so it refuses (exit 3) unless ISSUE_DRAIN_UNATTENDED_OK=1:
//! set that once the unit's GitHub identity is a non-admin token.
//!
//! Per unit, by state:
//!   queued        `claim take`. An exit 3 (an issue is someone else's) goes to
//!                 skipped. A unit the tracker no longer lists goes to skipped.
//!   claimed       `unit-prepare`; failure goes to blocked. The driver's limit
//!                 on it is the profile's bootstrap and codegraph limits plus a
//!                 margin (at least 1800 s), so a slow bootstrap fails as the
//!                 bootstrap, not as a driver timeout.
//!   prepared      move to implementing.
//!   implementing  read `result.json`; if absent, `unit-run` (first attempt), or
//!                 one retry a model tier up (haiku, sonnet, opus, limited to
//!                 the profile's `allowed_models`), resuming the session when
//!                 session.json has one. A second miss goes to blocked. Then
//!                 outcome: skipped, blocked as written; pr_open moves to
//!                 pr_open after a live read shows the PR open, from the unit's
//!                 branch and aimed at the base; cap_reached or parked with a
//!                 PR moves to pr_open then parked; without a PR it goes to
//!                 blocked.
//!   pr_open       move to reviewing.
//!   reviewing     `merge-gate --dry-run`. A refusal that needs a person parks
//!                 the unit. No review refusal moves to ci_wait (an unreadable
//!                 gate is read once more, then blocked as infrastructure).
//!                 Otherwise the unit is resumed to run a review pass, at most
//!                 MAX_REVIEW_PASSES over its life (`drive-review-passes`); a
//!                 refusal right after a pass (`drive-review-resumed`), or the
//!                 cap, goes to parked. A resume whose run fails, or whose
//!                 result.json says blocked, parked or cap_reached, ends the
//!                 unit that way; repair resumes are read the same way. A
//!                 resume has failed when `unit-run` fails, or when its JSON
//!                 says the claude process exited nonzero or timed out, or when
//!                 result.json is not newer than the `drive-resume-started`
//!                 mark written just before the resume (an old result is not
//!                 this round's answer); each blocks the unit.
//!   ci_wait       poll `merge-gate --dry-run` every ISSUE_DRAIN_DRIVE_POLL_SECS
//!                 (default 180) until no refusal says a check is pending, then
//!                 move to gate. Five unreadable gate reads in a row block the
//!                 unit as infrastructure; a pending read resets that count. This uses the gate's own live reading of the
//!                 required checks, not pr-drain's poll-ci.sh, whose check list
//!                 is fixed. Past ISSUE_DRAIN_DRIVE_CI_MAX_SECS (default 3600)
//!                 the unit goes to blocked with an infrastructure note.
//!   gate          `merge-gate` for real. Exit 0 records merged with the merge
//!                 commit; exit 4 (in the merge queue) waits one poll and asks
//!                 again, and past the CI limit stops the drain with the unit
//!                 still in gate (nothing to undo; drive again once it merges);
//!                 exit 3 is mapped as below.
//!   repairing     resume the unit with the reason that was recorded when the
//!                 move was made; the second repair uses one tier up; then
//!                 ci_wait.
//!   merged        `post-merge`, then done. A tree mismatch (`tree_match`
//!                 false) writes `units/<n>/drive-tree-mismatch` before done
//!                 and stops the drain, since verifying the base tip is a
//!                 person's job for now. Every later drive refuses while that
//!                 file exists. A
//!                 post-merge failure stops the drain and leaves the unit in
//!                 merged, so a restart runs post-merge again.
//!
//! Refusal map at the gate, most specific first. The first that applies wins:
//!   hold_label, waits_for, risk_path, not_open, closed_unmerged, pr_unit,
//!   wrong_base, closing_issue_*   parked, with the refusal list in the note.
//!                                 These come before the repair steps on
//!                                 purpose: a person has to act on the PR, and
//!                                 syncing or repairing it would move the head
//!                                 under them.
//!                                 A unit in `gate` with a `base-sync-pending.json`
//!                                 (a sync cut short by a restart) runs `base-sync`
//!                                 first, before the gate is read; it finishes
//!                                 that sync and spends no second one.
//!   behind_base                   `base-sync` (an exit 1 is tried up to
//!                                 BASE_SYNC_TRIES times, since GitHub may not
//!                                 have applied the update yet), then ci_wait, or reviewing if
//!                                 base-sync says a review round is needed. A
//!                                 unit at its sync cap, a refused base-sync, or
//!                                 a failed delivery check goes to parked.
//!   check_failed, or required_check that is not pending
//!                                 repairing and a resume naming the checks.
//!                                 At MAX_REPAIRS the unit goes to parked.
//!   required_check pending or with no run, not_mergeable UNKNOWN
//!                                 wait one poll inside gate (a move from gate
//!                                 to ci_wait would use up one of the unit's
//!                                 base syncs) until the CI limit, then parked
//!                                 with an infrastructure note.
//!   review, review_proof, review_author
//!                                 reviewing.
//!   threads_open                  repairing and a resume to reply and resolve.
//!   anything else                 parked, with the refusal list in the note.
//!   read_error alone              one more try after a poll; the second goes to
//!                                 parked, infrastructure (the table has no move
//!                                 from gate to blocked).
//!
//! End of a unit (done, skipped, blocked or parked): one comment on the
//! tracker through `gh-write comment` saying the unit, its issues, the outcome,
//! the PR and the note. Blocked, skipped and parked units get `claim release`
//! (which removes only a claim that is ours, and no worktree: a person may want
//! it); a done unit gets `cleanup --unit --pr`, which removes its worktree and
//! branch and releases the claim if still held. The claim release comes first:
//! if it fails (anything but exit 0, or exit 3 for a claim that is not ours),
//! the driver stops with that exit code before the comment and before
//! `drive-ended.json`, so a restart ends the unit again. A failed `cleanup` does
//! not do that: the comment is posted and `drive-ended.json` written, and
//! `drive-cleanup-pending` stays until a later `cleanup` succeeds. Each pass
//! of the loop, and each start, retries it (a retry posts no second comment).
//!
//! Stop conditions. Before claiming a unit: a `STOP` file in the run folder, or
//! `tracker parse` saying the tracker is not OPEN, has a STOP line, or lists
//! something the run never offered (a null tracker_state is accepted only in a
//! dry run). `tracker parse` exits 1 when it names such lines; that JSON is
//! read, and the driver refuses with them. At startup: a
//! `units/<n>/drive-tree-mismatch` file. Always: three units in a row that ended blocked; two in a row that
//! ended blocked or parked with an infrastructure note; a post-merge tree
//! mismatch or failure; a drain already stopped in the state log. The count of
//! units in a row is read back from the `drive-ended.json` files, so a restart
//! does not forget it. It is checked only when there is a next unit to carry,
//! so a queue that finished runs its retro; a stop for it records a floor
//! (after the stop is recorded) so a resumed drain starts counting again. A stop other than finishing runs `state stop --reason` and
//! posts a tracker comment. Finishing (`state next` names no unit) runs
//! `retro --publish`.
//!
//! `--once` carries one unit to a terminal state and exits, with no retro. With
//! ISSUE_DRAIN_DRY_RUN=1 every child inherits it and each unit gets one step,
//! since a dry-run gate never merges.
//!
//! Known gaps. The tracker has no rolling status comment, because there is no
//! comment-edit verb: it gets one comment per ended unit and one per stop. The
//! end-of-unit comment is tried once; a failed post is logged and not retried.
//! A unit that fails inside an exit-1 child (GitHub or git down) while queued,
//! claimed or merged ends the driver with exit 1 rather than being blocked,
//! since the table has no move to blocked from queued and a merged unit is
//! already merged.
//!
//! Test hook: with ISSUE_DRAIN_DRIVE_TESTING=1, ISSUE_DRAIN_DRIVE_EXE names the
//! program run in place of this binary for every child call. The tests give it
//! a wrapper that answers some subcommands from canned files and passes the rest
//! to the real binary. Without ISSUE_DRAIN_DRIVE_TESTING=1 it is ignored.
//!
//! Output: one JSON line, `{"processed": [{"unit", "state"}], "stopped": <reason
//! or null>}`. Exit: 0 on a clean finish or a requested stop (the STOP file, or
//! the tracker's STOP line or closing); 3 when another stop condition fired, the
//! unit is a unit process, or another driver holds the lock; 1 on an internal
//! failure (a child that failed in a way no state covers, a write that failed);
//! 2 on a missing setting.

use std::cell::Cell;
use std::fs::{self, File, OpenOptions, TryLockError};
use std::io::{Seek as _, SeekFrom, Write as _};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{Receiver, SyncSender, sync_channel};
use std::thread::sleep;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::ctx::{Ctx, env_str, read_json, write_atomic};
use crate::error::{Fail, Res};
use crate::exec;
use crate::merge_gate::{PrState, PrView, binding, in_merge_queue, is_sha, read_view};
use crate::state::{self, MAX_BASE_SYNCS, MAX_REPAIRS, Snapshot, State, UnitState};
use crate::tracker::io::Published;

#[derive(clap::Args)]
pub struct Args {
    /// Carry one unit to a terminal state, then exit.
    #[arg(long)]
    pub once: bool,
    /// Print no progress lines on stderr.
    #[arg(long)]
    pub quiet: bool,
}

pub(crate) const LADDER: [&str; 3] = ["haiku", "sonnet", "opus"];
const MAX_STEPS: u32 = 200;
/// Review passes the driver asks of one unit, over its whole life.
const MAX_REVIEW_PASSES: u32 = 4;
/// Calls of `base-sync` for one sync while GitHub has not applied the update.
const BASE_SYNC_TRIES: u32 = 3;
const CHILD_PID: &str = "drive-child.pid";
/// The driver's pid, in the run folder, while the driver runs.
const DRIVE_PID: &str = "drive.pid";
/// Children that can run for minutes. The driver names their output files on
/// stderr before it calls them, so a watcher knows what to tail.
const LONG_CHILDREN: [&str; 8] = [
    "unit-run",
    "unit-prepare",
    "merge-gate",
    "base-sync",
    "post-merge",
    "stamp-remote-pass",
    "cleanup",
    "retro",
];
/// Longest gap between two waiting lines for one unit.
const HEARTBEAT: Duration = Duration::from_secs(300);
/// Touched just before a resume; the resume's result.json must be newer.
const RESUME_STARTED: &str = "drive-resume-started";
/// Written when a done unit's `cleanup` failed; removed when it succeeds.
const CLEANUP_PENDING: &str = "drive-cleanup-pending";
const TREE_MISMATCH: &str = "drive-tree-mismatch";
/// Written when the gate queued the PR or sent a merge call whose outcome is
/// unknown, and removed once the PR is read back merged, or open and out of
/// the merge queue. While it exists no refusal parks the unit: a park releases
/// the claim on a PR that may still merge.
const MERGE_ASKED: &str = "drive-merge-asked";
const INFRA: &str = "infrastructure failure: ";
const CLAIM_REFUSED: &str = "claim refused: ";
const REMOVED: &str = "removed from the tracker";

/// What became of a merge the gate asked for.
enum Outcome {
    Merged(String),
    /// Open and out of the merge queue, or closed: nothing can merge it now.
    NotMerging,
    Unsure(String),
}

/// What a child printed and how it ended.
struct Reply {
    code: i32,
    timed_out: bool,
    stdout: String,
    stderr: String,
}

impl Reply {
    fn ok(&self) -> bool {
        self.code == 0 && !self.timed_out
    }

    /// A failure of the machinery (exit 1, or killed at its time limit), not
    /// a refusal.
    fn infra(&self) -> bool {
        self.timed_out || self.code == 1
    }

    /// The JSON object or list on the last line that has one.
    fn json(&self) -> Option<Value> {
        last_json(&self.stdout)
    }

    /// Why it failed, in a few words.
    fn why(&self) -> String {
        let line = |text: &str| {
            text.lines()
                .rev()
                .map(str::trim)
                .find(|l| !l.is_empty())
                .map(|l| l.chars().take(300).collect::<String>())
        };
        let said = line(&self.stderr).or_else(|| line(&self.stdout));
        match said {
            Some(said) if self.timed_out => format!("timed out: {said}"),
            Some(said) => format!("exit {}: {said}", self.code),
            None if self.timed_out => "timed out".to_string(),
            None => format!("exit {}", self.code),
        }
    }
}

/// How long the driver lets one child run. `unit-run` gets the unit's own
/// limit plus a margin. `unit-prepare` runs the profile's bootstrap under
/// `bootstrap_timeout_secs`, codegraph under `codegraph_timeout_secs` (up to two
/// runs) and two git calls of 120 s; its limit is those plus a margin, so the
/// inner limit always fires first and a slow bootstrap is reported as a
/// bootstrap failure, not a driver timeout.
fn call_limit(p: &crate::profile::Profile, command: Option<&str>) -> Duration {
    let secs = match command {
        Some("unit-run") => p.unit_timeout_secs + 900,
        Some("unit-prepare") => (p.bootstrap_timeout_secs + 2 * p.codegraph_timeout_secs + 2 * 120 + 900).max(1800),
        _ => 1800,
    };
    Duration::from_secs(secs)
}

/// Why the claude process inside a successful `unit-run` failed, from the
/// `exit_code` and `timed_out` in its JSON; `None` when it exited 0.
fn child_failure(ran: &Reply) -> Option<String> {
    let Some(j) = ran.json() else {
        return Some("unit-run printed no result, so the process's status is unknown".into());
    };
    if j["timed_out"] == true {
        return Some("the unit's process timed out".into());
    }
    match j["exit_code"].as_i64() {
        Some(0) => None,
        Some(code) => Some(format!("the unit's process exited {code}")),
        None => Some("the unit's process was killed".into()),
    }
}

fn last_json(text: &str) -> Option<Value> {
    text.lines().rev().find_map(|l| {
        let l = l.trim();
        if l.starts_with('{') || l.starts_with('[') {
            serde_json::from_str(l).ok()
        } else {
            None
        }
    })
}

#[derive(Clone, Debug, PartialEq)]
struct Refusal {
    code: String,
    detail: String,
}

fn refusals_of(reply: &Reply) -> Vec<Refusal> {
    let list = reply.json().and_then(|j| j["refusals"].as_array().cloned());
    match list {
        Some(list) if !list.is_empty() => list
            .iter()
            .map(|r| Refusal {
                code: r["code"].as_str().unwrap_or_default().to_string(),
                detail: r["detail"].as_str().unwrap_or_default().to_string(),
            })
            .collect(),
        _ if reply.code == 3 => vec![Refusal {
            code: "unreadable".into(),
            detail: reply.why(),
        }],
        _ => Vec::new(),
    }
}

fn listed(refusals: &[Refusal]) -> String {
    refusals
        .iter()
        .map(|r| format!("{}: {}", r.code, r.detail))
        .collect::<Vec<_>>()
        .join("; ")
}

fn is_pending(r: &Refusal) -> bool {
    (r.code == "required_check" && (r.detail.contains(" is pending") || r.detail.contains("has no run")))
        || (r.code == "not_mergeable" && r.detail.contains("'UNKNOWN'"))
}

fn is_failed_check(r: &Refusal) -> bool {
    r.code == "check_failed" || (r.code == "required_check" && !is_pending(r))
}

fn is_review(r: &Refusal) -> bool {
    matches!(r.code.as_str(), "review" | "review_proof" | "review_author")
}

fn needs_a_person(r: &Refusal) -> bool {
    matches!(
        r.code.as_str(),
        "hold_label"
            | "waits_for"
            | "risk_path"
            | "not_open"
            | "closed_unmerged"
            | "pr_unit"
            | "wrong_base"
            | "closing_issue_repo"
            | "closing_issue_unit"
    )
}

/// What the gate's refusals call for.
#[derive(Debug, PartialEq)]
enum Action {
    Park(String),
    BaseSync,
    Repair(String),
    Pending,
    Review,
    Threads(String),
    ReadError,
}

fn decide(refusals: &[Refusal]) -> Action {
    let of = |keep: fn(&Refusal) -> bool| refusals.iter().filter(|r| keep(r)).cloned().collect::<Vec<_>>();
    let person = of(needs_a_person);
    if !person.is_empty() {
        return Action::Park(format!("needs a person: {}", listed(&person)));
    }
    if refusals.iter().any(|r| r.code == "behind_base") {
        return Action::BaseSync;
    }
    let failed = of(is_failed_check);
    if !failed.is_empty() {
        return Action::Repair(format!(
            "These required checks failed on the PR's head: {}.",
            listed(&failed)
        ));
    }
    if refusals.iter().any(is_pending) {
        return Action::Pending;
    }
    if refusals.iter().any(is_review) {
        return Action::Review;
    }
    let threads = of(|r| r.code == "threads_open");
    if !threads.is_empty() {
        return Action::Threads(listed(&threads));
    }
    let other = of(|r| r.code != "read_error");
    if !other.is_empty() {
        return Action::Park(format!("the gate refuses: {}", listed(&other)));
    }
    Action::ReadError
}

/// The next model up the ladder that the profile allows; `None` at the top.
fn tier_up(current: &str, allowed: &[String]) -> Option<String> {
    let at = LADDER.iter().position(|m| *m == current).map_or(0, |i| i + 1);
    LADDER[at.min(LADDER.len())..]
        .iter()
        .find(|m| allowed.iter().any(|a| a == **m))
        .map(|m| m.to_string())
}

/// A failure that keeps the child's own exit code.
fn fail_code(code: i32, msg: String) -> Fail {
    Fail {
        code: u8::try_from(code).ok().filter(|c| (1..=4).contains(c)).unwrap_or(1),
        msg,
        reported: false,
    }
}

fn one_line(text: &str) -> String {
    text.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(600)
        .collect()
}

/// The notes a unit wrote in result.json, as one line.
fn notes_of(result: &Value) -> String {
    match &result["notes"] {
        Value::Array(list) => list.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" "),
        Value::String(s) => s.clone(),
        _ => String::new(),
    }
}

/// The tracker lines the run never offered, when `tracker parse` named any.
fn unknown_lines(j: &Value) -> Option<String> {
    let list: Vec<&str> = j["unknown"].as_array()?.iter().filter_map(Value::as_str).collect();
    (!list.is_empty()).then(|| list.join("; "))
}

/// Whether the gate's dry read could not be taken at all. Exit 4 with
/// `queued: true` is a read: the PR is already in the merge queue.
fn unreadable(r: &Reply, refusals: &[Refusal]) -> bool {
    let queued = r.code == 4 && !r.timed_out && r.json().is_some_and(|j| j["queued"] == true);
    (!r.ok() && !queued && (r.timed_out || r.code != 3))
        || (!refusals.is_empty() && decide(refusals) == Action::ReadError)
}

/// Why the driver stops, and the exit code that goes with it.
struct Stop {
    reason: String,
    code: u8,
}

struct Report {
    processed: Vec<(u64, State)>,
}

/// Held for the driver's life: an advisory lock (`flock`) on the lock file.
/// The kernel releases it when the process exits by any path, so there is no
/// stale lock to reap. The file is never removed: removing a locked file lets
/// a later driver lock a new file at the same path while an earlier one still
/// holds the old one.
///
/// A child the driver ran is tracked in `drive-child.pid` beside the lock file
/// while it runs. A driver killed mid-call leaves that file behind, and the
/// child may still be running in its own process group; the next driver will
/// not start while that group is alive.
struct Lock {
    _file: File,
    dir: PathBuf,
}

impl Lock {
    fn take(ctx: &Ctx) -> Res<Lock> {
        let repo = ctx.repo()?;
        let home = env_str("HOME");
        let base = if home.starts_with('/') {
            PathBuf::from(home).join(".issue-drain")
        } else {
            ctx.workdir.parent().map_or_else(|| ctx.workdir.clone(), PathBuf::from)
        };
        // Lowercased: GitHub does not tell `Owner/Repo` from `owner/repo`, so
        // neither may the lock, or two spellings would run two drivers.
        let dir = base.join(repo.to_ascii_lowercase().replace('/', "__"));
        let path = dir.join("drive.lock");
        fs::create_dir_all(&dir).map_err(|e| Fail::failed(format!("cannot make {}: {e}", dir.display())))?;
        let mut f = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(&path)
            .map_err(|e| Fail::failed(format!("cannot open {}: {e}", path.display())))?;
        match f.try_lock() {
            Ok(()) => {}
            Err(TryLockError::WouldBlock) => {
                let held = fs::read_to_string(&path).unwrap_or_default();
                let held = held.trim();
                let who = if held.is_empty() {
                    String::new()
                } else {
                    format!(" (pid {held})")
                };
                return Err(Fail::refused(format!("another driver{who} holds {}", path.display())));
            }
            Err(TryLockError::Error(e)) => {
                return Err(Fail::failed(format!("cannot lock {}: {e}", path.display())));
            }
        }
        f.set_len(0)
            .and_then(|()| f.seek(SeekFrom::Start(0)).map(|_| ()))
            .and_then(|()| writeln!(f, "{}", std::process::id()))
            .map_err(|e| Fail::failed(format!("cannot write {}: {e}", path.display())))?;
        let child = dir.join(CHILD_PID);
        if let Ok(text) = fs::read_to_string(&child) {
            let pid = text.trim();
            let alive = pid.parse::<u32>().is_ok()
                && Command::new("kill")
                    .args(["-0", "--", &format!("-{pid}")])
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status()
                    .is_ok_and(|s| s.success());
            if alive {
                return Err(Fail::refused(format!(
                    "a process an earlier driver started (process group {pid}) is still running; wait for it to end or kill it, then remove {}",
                    child.display()
                )));
            }
            fs::remove_file(&child).map_err(|e| Fail::failed(format!("cannot remove {}: {e}", child.display())))?;
        }
        Ok(Lock { _file: f, dir })
    }
}

/// `<run folder>/drive.pid` holds the driver's pid for as long as the driver
/// runs, and is removed when it returns by any path. A driver that is killed
/// leaves the file, so a watcher must check that the pid is alive (`kill -0`).
struct PidFile(PathBuf);

impl PidFile {
    fn write(dir: &Path) -> Res<PidFile> {
        let path = dir.join(DRIVE_PID);
        write_atomic(&path, format!("{}\n", std::process::id()).as_bytes())?;
        Ok(PidFile(path))
    }
}

impl Drop for PidFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

/// Progress lines that may be queued while stderr is not being read. Past
/// this, lines are dropped rather than wait.
const PROGRESS_BACKLOG: usize = 256;
/// How long the driver waits at exit for queued lines to reach stderr.
const PROGRESS_FLUSH: Duration = Duration::from_secs(2);

/// Writes progress lines to stderr on its own thread. A write to a pipe nobody
/// drains blocks; this way it blocks only the writer, never the driver.
struct Progress {
    tx: Option<SyncSender<String>>,
    done: Receiver<()>,
}

impl Progress {
    fn start() -> Progress {
        Progress::to(std::io::stderr())
    }

    fn to(mut err: impl std::io::Write + Send + 'static) -> Progress {
        let (tx, rx) = sync_channel::<String>(PROGRESS_BACKLOG);
        let (done_tx, done) = sync_channel(1);
        std::thread::spawn(move || {
            for line in rx {
                let _ = writeln!(err, "{line}");
            }
            let _ = done_tx.send(());
        });
        Progress { tx: Some(tx), done }
    }

    fn say(&self, line: &str) {
        if let Some(tx) = &self.tx {
            let _ = tx.try_send(format!("drive: {line}"));
        }
    }

    /// The command's own last line, `issue-drain drive: <why>`, queued behind
    /// the progress lines and flushed like them. A failing driver says why
    /// through here, so a stuck stderr cannot keep it from exiting either.
    fn finish(self, fail: Fail) -> Fail {
        if let Some(tx) = &self.tx {
            let _ = tx.try_send(format!("issue-drain drive: {}", fail.msg));
        }
        drop(self);
        Fail { reported: true, ..fail }
    }
}

impl Drop for Progress {
    /// Give queued lines a moment to reach stderr, without waiting on a reader
    /// that never comes.
    fn drop(&mut self) {
        drop(self.tx.take());
        let _ = self.done.recv_timeout(PROGRESS_FLUSH);
    }
}

/// One poll's sleep cut into pieces no longer than `beat`, so a waiting line
/// can be said between them. A zero poll is no sleep at all.
fn poll_slices(poll: Duration, beat: Duration) -> Vec<Duration> {
    let mut left = poll;
    let mut out = Vec::new();
    while !left.is_zero() && !beat.is_zero() {
        let slice = left.min(beat);
        out.push(slice);
        left -= slice;
    }
    out
}

struct Caffeinate(Option<Child>);

impl Caffeinate {
    fn start() -> Caffeinate {
        let pid = std::process::id().to_string();
        Caffeinate(
            Command::new("caffeinate")
                .args(["-i", "-w", &pid])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .ok(),
        )
    }
}

impl Drop for Caffeinate {
    fn drop(&mut self) {
        if let Some(child) = &mut self.0 {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

struct Driver<'a> {
    ctx: &'a Ctx,
    exe: PathBuf,
    repo: String,
    poll: Duration,
    ci_max: Duration,
    dry: bool,
    seq: Cell<u32>,
    child_pid: PathBuf,
    progress: Option<Progress>,
    /// The unit the driver is napping for, since when, and the last waiting line.
    waiting: Cell<Option<(u64, Instant)>>,
    last_beat: Cell<Option<Instant>>,
}

fn secs(name: &str, default: u64) -> Duration {
    Duration::from_secs(env_str(name).parse().unwrap_or(default))
}

impl<'a> Driver<'a> {
    fn new(ctx: &'a Ctx, lock: &Lock, quiet: bool) -> Res<Driver<'a>> {
        let exe = match env_str("ISSUE_DRAIN_DRIVE_EXE") {
            hook if env_str("ISSUE_DRAIN_DRIVE_TESTING") == "1" && !hook.is_empty() => PathBuf::from(hook),
            _ => std::env::current_exe().map_err(|e| Fail::failed(format!("cannot find this program: {e}")))?,
        };
        fs::create_dir_all(&ctx.workdir)
            .map_err(|e| Fail::failed(format!("cannot make {}: {e}", ctx.workdir.display())))?;
        let logged = fs::read_dir(ctx.path("drive")).map_or(0, |d| d.count()) as u32;
        Ok(Driver {
            ctx,
            exe,
            repo: ctx.repo()?,
            poll: secs("ISSUE_DRAIN_DRIVE_POLL_SECS", 180),
            ci_max: secs("ISSUE_DRAIN_DRIVE_CI_MAX_SECS", 3600),
            dry: ctx.dry_run,
            seq: Cell::new(logged / 2),
            child_pid: lock.dir.join(CHILD_PID),
            progress: (!quiet).then(Progress::start),
            waiting: Cell::new(None),
            last_beat: Cell::new(None),
        })
    }

    /// A driver marker's file name. A dry run's markers carry a `dry-` prefix,
    /// so a later live run neither reads nor ends anything a dry run touched.
    fn mark(&self, name: &str) -> String {
        if self.dry {
            format!("dry-{name}")
        } else {
            name.to_string()
        }
    }

    /// One progress line on stderr, unless `--quiet`. Best effort: the line is
    /// handed to the writer thread and dropped if it is backed up, so a closed
    /// or undrained stderr never stops the run.
    fn say(&self, line: &str) {
        if let Some(p) = &self.progress {
            p.say(line);
        }
    }

    fn log(&self, unit: Option<u64>, what: &str, detail: Value) -> Res<()> {
        let who = unit.map_or_else(String::new, |n| format!("U{n} "));
        let detail_text = match &detail {
            Value::Object(m) if what == "step" && m.contains_key("state") => {
                format!(" in {}", m["state"].as_str().unwrap_or_default())
            }
            Value::Null => String::new(),
            Value::Object(m) if m.is_empty() => String::new(),
            other => format!(" {}", one_line(&other.to_string())),
        };
        self.say(&format!("{who}{}{detail_text}", what.replace('_', " ")));
        self.ctx
            .event("drive", json!({"unit": unit, "step": what, "detail": detail}))
    }

    /// Sleep one poll. While one unit keeps the driver waiting, say so about
    /// every five minutes: never more than one poll early, and late by no more
    /// than the gate call between polls. A poll longer than the heartbeat is
    /// slept in slices, with a line between them, so GitHub is not asked any
    /// more often than the poll says.
    fn nap(&self, u: &UnitState) {
        let since = match self.waiting.get() {
            Some((unit, at)) if unit == u.unit => at,
            _ => {
                let now = Instant::now();
                self.waiting.set(Some((u.unit, now)));
                self.last_beat.set(None);
                now
            }
        };
        let beat = || {
            let pr = u.pr.map_or_else(String::new, |p| format!(" PR #{p}"));
            self.say(&format!(
                "U{}{pr} in {} waiting, {}s so far",
                u.unit,
                u.state.as_str(),
                since.elapsed().as_secs()
            ));
            self.last_beat.set(Some(Instant::now()));
        };
        // Say it now if waiting for the next poll would pass the heartbeat, so
        // the gap between lines stays within HEARTBEAT plus one gate call.
        if self
            .last_beat
            .get()
            .is_none_or(|t| t.elapsed() + self.poll.min(HEARTBEAT) >= HEARTBEAT)
        {
            beat();
        }
        let slices = poll_slices(self.poll, HEARTBEAT);
        for (i, slice) in slices.iter().enumerate() {
            if i > 0 {
                beat();
            }
            sleep(*slice);
        }
    }

    /// Run `issue-drain <args>` as a child and read what it said.
    fn call(&self, args: &[&str]) -> Res<Reply> {
        let seq = self.seq.get() + 1;
        self.seq.set(seq);
        let name: String = args
            .iter()
            .take(2)
            .flat_map(|a| a.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-'))
            .collect();
        let out = self.ctx.path(&format!("drive/{seq:05}-{name}.out"));
        let err = self.ctx.path(&format!("drive/{seq:05}-{name}.err"));
        let limit = call_limit(&self.ctx.profile, args.first().copied());
        // The logs exist before they are named, so a watcher can tail them at once.
        let files = exec::open_logs((&out, &err))?;
        if args.first().is_some_and(|a| LONG_CHILDREN.contains(a)) {
            let rel = |p: &PathBuf| p.strip_prefix(&self.ctx.workdir).unwrap_or(p).display().to_string();
            self.say(&format!(
                "running {} (stdout {}, stderr {})",
                args.join(" "),
                rel(&out),
                rel(&err)
            ));
        }
        let argv: Vec<String> = args.iter().map(|a| a.to_string()).collect();
        // Children run in the run folder, so they get the profile's absolute path.
        let profile = self.ctx.profile_path.display().to_string();
        let ran = exec::run_opened(
            &self.exe.display().to_string(),
            &argv,
            &self.ctx.workdir,
            limit,
            files,
            &err,
            &[("ISSUE_DRAIN_PROFILE", &profile)],
            Some(&self.child_pid),
        )?;
        let reply = Reply {
            code: ran.code.unwrap_or(-1),
            timed_out: ran.timed_out,
            stdout: fs::read_to_string(&out).unwrap_or_default(),
            stderr: fs::read_to_string(&err).unwrap_or_default(),
        };
        self.ctx.event(
            "drive",
            json!({"unit": null, "step": "call", "detail": {"args": args, "code": reply.code}}),
        )?;
        Ok(reply)
    }

    fn snapshot(&self) -> Res<Snapshot> {
        let r = self.call(&["state", "show", "--json"])?;
        if !r.ok() {
            return Err(Fail::failed(format!("state show failed: {}", r.why())));
        }
        serde_json::from_str(&r.stdout).map_err(|e| Fail::failed(format!("state show printed no snapshot: {e}")))
    }

    fn unit_state(&self, unit: u64) -> Res<UnitState> {
        self.snapshot()?
            .units
            .into_iter()
            .find(|u| u.unit == unit)
            .ok_or_else(|| Fail::failed(format!("unit {unit} is not in the state log")))
    }

    fn mv(&self, unit: u64, to: &str, note: Option<&str>, pr: Option<u64>, head: Option<&str>) -> Res<()> {
        let n = unit.to_string();
        let note = note.map(one_line);
        let pr = pr.map(|p| p.to_string());
        let mut args = vec!["state", "event", &n, to];
        if let Some(note) = &note {
            args.extend(["--note", note]);
        }
        if let Some(pr) = &pr {
            args.extend(["--pr", pr]);
        }
        if let Some(head) = head {
            args.extend(["--head", head]);
        }
        let r = self.call(&args)?;
        if r.ok() {
            self.waiting.set(None);
            let why = note.as_deref().map_or_else(String::new, |n| format!(" ({n})"));
            self.say(&format!("U{unit} -> {to}{why}"));
            return Ok(());
        }
        let msg = format!("unit {unit} could not move to {to}: {}", r.why());
        Err(match r.code {
            2 => Fail::usage(msg),
            3 => Fail::refused(msg),
            _ => Fail::failed(msg),
        })
    }

    /// End a unit that cannot go on. `prefer` is the state to use when the
    /// table allows it; otherwise the other of blocked and parked.
    fn settle(&self, u: &UnitState, prefer: State, note: &str, infra: bool) -> Res<()> {
        let exits = u.state.exits();
        let other = if prefer == State::Parked {
            State::Blocked
        } else {
            State::Parked
        };
        let to = [prefer, other]
            .into_iter()
            .find(|s| exits.contains(s))
            .ok_or_else(|| Fail::failed(format!("unit {} in {} has no way to end", u.unit, u.state.as_str())))?;
        let note = if infra {
            format!("{INFRA}{note}")
        } else {
            note.to_string()
        };
        self.mv(u.unit, to.as_str(), Some(&note), None, None)
    }

    fn block(&self, u: &UnitState, note: &str, infra: bool) -> Res<()> {
        self.settle(u, State::Blocked, note, infra)
    }

    fn park(&self, u: &UnitState, note: &str, infra: bool) -> Res<()> {
        self.settle(u, State::Parked, note, infra)
    }

    fn unit_dir(&self, unit: u64) -> PathBuf {
        self.ctx.path(&format!("units/{unit}"))
    }

    fn pr_of(&self, u: &UnitState) -> Res<u64> {
        u.pr.ok_or_else(|| {
            Fail::failed(format!(
                "unit {} is in {} with no PR recorded",
                u.unit,
                u.state.as_str()
            ))
        })
    }

    // ---- startup and boundaries ----

    /// Start the state log from the approved tracker when the run has none.
    fn ensure_state(&self) -> Res<()> {
        let shown = self.call(&["state", "show", "--json"])?;
        match shown.code {
            0 => return Ok(()),
            2 => {}
            _ => return Err(Fail::failed(format!("state show failed: {}", shown.why()))),
        }
        let parsed = self.call(&["tracker", "parse"])?;
        if !parsed.ok() {
            if let Some(list) = parsed.json().as_ref().and_then(unknown_lines) {
                return Err(Fail::refused(format!(
                    "the tracker has lines the run never offered: {list}"
                )));
            }
            return Err(fail_code(
                parsed.code,
                format!("tracker parse failed: {}", parsed.why()),
            ));
        }
        let line = parsed
            .json()
            .ok_or_else(|| Fail::failed("tracker parse printed no JSON"))?;
        let path = self.ctx.path("parsed.json");
        write_atomic(&path, format!("{line}\n").as_bytes())?;
        let shown_path = path.display().to_string();
        let init = self.call(&["state", "init", "--parsed", &shown_path])?;
        if init.ok() {
            self.log(None, "state_started", json!({"parsed": shown_path}))
        } else {
            Err(fail_code(init.code, format!("state init failed: {}", init.why())))
        }
    }

    /// The reason to stop before claiming a unit, and the units the tracker
    /// still lists.
    fn boundary(&self) -> Res<(Option<Stop>, Vec<String>)> {
        if self.ctx.path("STOP").exists() {
            let reason = "the STOP file is in the run folder".to_string();
            return Ok((Some(Stop { reason, code: 0 }), Vec::new()));
        }
        let r = self.call(&["tracker", "parse"])?;
        // `tracker parse` prints its JSON and exits 1 when it names lines the
        // run never offered; that JSON is read like any other.
        let j = match r.json() {
            Some(j) if r.ok() || (r.code == 1 && !r.timed_out && unknown_lines(&j).is_some()) => j,
            _ if r.ok() => return Err(Fail::failed("tracker parse printed no JSON")),
            _ => return Err(fail_code(r.code, format!("tracker parse failed: {}", r.why()))),
        };
        let stop = |reason: String, code: u8| Ok((Some(Stop { reason, code }), Vec::new()));
        match j["tracker_state"].as_str() {
            Some("OPEN") => {}
            Some(other) => return stop(format!("the tracker is {other}, not OPEN"), 0),
            None if self.dry => {}
            None => return stop("tracker parse did not read the live tracker".into(), 3),
        }
        if j["stop"].as_bool().unwrap_or(true) {
            return stop("the tracker has a STOP line".into(), 0);
        }
        let unknown: Vec<&str> = j["unknown"]
            .as_array()
            .map(|a| a.iter().filter_map(Value::as_str).collect())
            .unwrap_or_else(|| vec!["tracker parse listed no 'unknown'"]);
        if !unknown.is_empty() {
            return stop(
                format!("the tracker has lines the run never offered: {}", unknown.join("; ")),
                3,
            );
        }
        let units = j["units"]
            .as_array()
            .map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect())
            .unwrap_or_default();
        Ok((None, units))
    }

    // ---- the loop ----

    fn drive(&self, once: bool, report: &mut Report) -> Res<Option<Stop>> {
        if let Some(marker) = self.tree_mismatch() {
            return Ok(Some(Stop {
                reason: format!(
                    "a unit merged a different tree than the gate approved; verify the base tip, then remove {}",
                    marker.display()
                ),
                code: 3,
            }));
        }
        let mut visited: Vec<u64> = Vec::new();
        loop {
            self.reconcile()?;
            let snap = self.snapshot()?;
            if let Some(stopped) = &snap.stopped {
                return Ok(Some(Stop {
                    reason: format!("the drain is already stopped: {}", stopped.reason),
                    code: 3,
                }));
            }
            let next = if self.dry {
                snap.units
                    .iter()
                    .find(|u| !u.state.is_terminal() && !visited.contains(&u.unit))
                    .map(|u| (u.unit, u.state))
            } else {
                let r = self.call(&["state", "next"])?;
                if !r.ok() {
                    return Err(Fail::failed(format!("state next failed: {}", r.why())));
                }
                r.stdout
                    .trim()
                    .parse::<u64>()
                    .ok()
                    .and_then(|n| snap.units.iter().find(|u| u.unit == n))
                    .map(|u| (u.unit, u.state))
            };
            let Some((unit, state)) = next else {
                if !once {
                    let r = self.call(&["retro", "--publish"])?;
                    if !r.ok() {
                        return Err(fail_code(r.code, format!("retro --publish failed: {}", r.why())));
                    }
                }
                return Ok(None);
            };
            if let Some((stop, top)) = self.streak_stop() {
                let stopped = self.stop(stop)?;
                write_atomic(
                    &self.ctx.path(&self.mark("drive-streak-floor")),
                    format!("{top}\n").as_bytes(),
                )?;
                return Ok(stopped);
            }
            visited.push(unit);
            if state == State::Queued {
                let (stop, listed) = self.boundary()?;
                if let Some(stop) = stop {
                    return self.stop(stop);
                }
                if !listed.contains(&format!("U{unit}")) {
                    self.touch(unit)?;
                    self.mv(unit, "skipped", Some(REMOVED), None, None)?;
                    report.processed.push((unit, State::Skipped));
                    if once {
                        self.reconcile()?;
                        return Ok(None);
                    }
                    continue;
                }
            }
            let halt = self.carry(unit)?;
            report.processed.push((unit, self.unit_state(unit)?.state));
            if let Some(reason) = halt {
                return self.stop(Stop { reason, code: 3 });
            }
            if once {
                self.reconcile()?;
                return Ok(None);
            }
        }
    }

    /// Record a stop, tell the tracker, and hand the reason back.
    fn stop(&self, stop: Stop) -> Res<Option<Stop>> {
        self.reconcile()?;
        let snap = self.snapshot()?;
        if snap.stopped.is_none() {
            let r = self.call(&["state", "stop", "--reason", &one_line(&stop.reason)])?;
            if !r.ok() {
                return Err(Fail::failed(format!("state stop failed: {}", r.why())));
            }
            let body = format!(
                "issue-drain run {} has stopped: {}.\n\nNo further unit will be claimed until a person resumes the drain.\n",
                self.ctx.run_id()?,
                stop.reason.trim_end_matches('.')
            );
            self.comment_tracker("stop", &body)?;
        }
        Ok(Some(stop))
    }

    fn comment_tracker(&self, name: &str, body: &str) -> Res<()> {
        let Some(tracker) = read_json::<Published>(&self.ctx.path("tracker.json")) else {
            return self.log(None, "no_tracker_comment", json!({"what": name}));
        };
        let file = self.ctx.path(&format!("drive/comment-{name}.md"));
        write_atomic(&file, body.as_bytes())?;
        let (n, f) = (tracker.number.to_string(), file.display().to_string());
        let r = self.call(&["gh-write", "comment", &n, "--body-file", &f])?;
        if !r.ok() {
            self.log(None, "tracker_comment_failed", json!({"what": name, "why": r.why()}))?;
        }
        Ok(())
    }

    fn touch(&self, unit: u64) -> Res<()> {
        let dir = self.unit_dir(unit);
        fs::create_dir_all(&dir).map_err(|e| Fail::failed(format!("cannot make {}: {e}", dir.display())))?;
        write_atomic(&dir.join(self.mark("drive-owned")), b"1\n")
    }

    /// The first `units/<n>/drive-tree-mismatch` marker, if any unit left one.
    /// A dry run also sees its own `dry-` marker; a live run sees only live ones.
    fn tree_mismatch(&self) -> Option<PathBuf> {
        let names = [TREE_MISMATCH.to_string(), self.mark(TREE_MISMATCH)];
        let mut found: Vec<PathBuf> = fs::read_dir(self.ctx.path("units"))
            .into_iter()
            .flatten()
            .flatten()
            .flat_map(|e| names.iter().map(move |n| e.path().join(n)))
            .filter(|p| p.exists())
            .collect();
        found.sort();
        found.into_iter().next()
    }

    /// Take a unit to a terminal state (or one step, in a dry run). `Some` is a
    /// reason to stop the drain.
    fn carry(&self, unit: u64) -> Res<Option<String>> {
        self.touch(unit)?;
        for _ in 0..MAX_STEPS {
            let u = self.unit_state(unit)?;
            if u.state.is_terminal() {
                return Ok(None);
            }
            let halt = self.step(&u)?;
            if halt.is_some() || self.dry {
                return Ok(halt);
            }
        }
        Err(Fail::failed(format!("unit {unit} did not settle in {MAX_STEPS} steps")))
    }

    fn step(&self, u: &UnitState) -> Res<Option<String>> {
        self.log(Some(u.unit), "step", json!({"state": u.state.as_str()}))?;
        let moved = match u.state {
            State::Queued => self.queued(u),
            State::Claimed => self.claimed(u),
            State::Prepared => self.mv(u.unit, "implementing", None, None, None),
            State::Implementing => self.implementing(u),
            State::PrOpen => self.pr_open(u),
            State::Reviewing => self.reviewing(u),
            State::CiWait => self.ci_wait(u),
            State::Repairing => self.repairing(u),
            State::Gate => return self.gate(u),
            State::Merged => return self.merged(u.unit, self.pr_of(u)?),
            State::Done | State::Skipped | State::Blocked | State::Parked => Ok(()),
        };
        moved.map(|()| None)
    }

    // ---- handlers ----

    fn queued(&self, u: &UnitState) -> Res<()> {
        let n = u.unit.to_string();
        let r = self.call(&["claim", "take", "--unit", &n])?;
        match r.code {
            0 => self.mv(u.unit, "claimed", None, None, None),
            3 => self.mv(
                u.unit,
                "skipped",
                Some(&format!("{CLAIM_REFUSED}{}", r.why())),
                None,
                None,
            ),
            _ => Err(fail_code(
                r.code,
                format!("claim take failed for unit {}: {}", u.unit, r.why()),
            )),
        }
    }

    fn claimed(&self, u: &UnitState) -> Res<()> {
        let n = u.unit.to_string();
        let r = self.call(&["unit-prepare", "--unit", &n])?;
        if r.ok() {
            self.mv(u.unit, "prepared", None, None, None)
        } else {
            self.block(u, &format!("unit-prepare failed: {}", r.why()), r.infra())
        }
    }

    /// The model the unit last ran on.
    fn last_model(&self, unit: u64) -> String {
        let dir = self.unit_dir(unit);
        let session: Value = read_json(&dir.join("session.json")).unwrap_or(Value::Null);
        let unit_file: Value = read_json(&dir.join("unit.json")).unwrap_or(Value::Null);
        session["attempts"]
            .as_array()
            .and_then(|a| a.last())
            .and_then(|a| a["model"].as_str())
            .or_else(|| unit_file["model"].as_str())
            .unwrap_or("haiku")
            .to_string()
    }

    /// Write `text` as the next prompt file of the unit and resume its session.
    fn resume(&self, unit: u64, text: &str, model: Option<&str>) -> Res<Reply> {
        let dir = self.unit_dir(unit);
        fs::create_dir_all(&dir).map_err(|e| Fail::failed(format!("cannot make {}: {e}", dir.display())))?;
        let count = fs::read_dir(&dir).map_or(0, |d| {
            d.flatten()
                .filter(|e| e.file_name().to_string_lossy().starts_with("drive-prompt-"))
                .count()
        });
        let file = dir.join(format!("drive-prompt-{}.md", count + 1));
        write_atomic(&file, text.as_bytes())?;
        let (n, f) = (unit.to_string(), file.display().to_string());
        // Always named: a resume without one would fall back to the unit's
        // first model and undo an earlier step up the ladder.
        let model = model.map_or_else(|| self.last_model(unit), str::to_string);
        // A fresh mark: the resume must write result.json after this.
        write_atomic(&dir.join(self.mark(RESUME_STARTED)), b"1\n")?;
        self.call(&[
            "unit-run",
            "--unit",
            &n,
            "--resume",
            "--prompt-file",
            &f,
            "--model",
            &model,
        ])
    }

    /// After a resume: `true` when the unit is now ended, because the run
    /// failed or its result.json says it blocked or parked.
    fn settled_by_resume(&self, u: &UnitState, ran: &Reply, what: &str) -> Res<bool> {
        if !ran.ok() {
            self.block(u, &format!("{what} failed: {}", ran.why()), ran.infra())?;
            return Ok(true);
        }
        // `unit-run` exits 0 whatever its claude process did; the process's own
        // status is in its JSON.
        if let Some(why) = child_failure(ran) {
            self.block(
                u,
                &format!("{what} failed: {why}"),
                ran.json().is_some_and(|j| j["timed_out"] == true),
            )?;
            return Ok(true);
        }
        // An old result.json is not this resume's answer. The prompt tells the
        // unit to update the file in place, so it is dated, not deleted.
        let dir = self.unit_dir(u.unit);
        let mtime = |name: &str| fs::metadata(dir.join(name)).and_then(|m| m.modified()).ok();
        if !mtime("result.json")
            .zip(mtime(&self.mark(RESUME_STARTED)))
            .is_some_and(|(result, started)| result >= started)
        {
            self.block(u, &format!("{what} ended without writing a new result.json"), false)?;
            return Ok(true);
        }
        let result: Value = read_json(&dir.join("result.json")).unwrap_or(Value::Null);
        let notes = notes_of(&result);
        let said = |outcome: &str| {
            if notes.is_empty() {
                format!("after {what}, the unit reported {outcome}")
            } else {
                format!("after {what}, the unit reported {outcome}: {notes}")
            }
        };
        match result["outcome"].as_str() {
            Some("blocked") => self.block(u, &said("blocked"), false).map(|()| true),
            Some(o @ ("parked" | "cap_reached")) => self.park(u, &said(o), false).map(|()| true),
            _ => Ok(false),
        }
    }

    fn model_up(&self, unit: u64) -> Option<String> {
        tier_up(&self.last_model(unit), &self.ctx.profile.allowed_models)
    }

    fn implementing(&self, u: &UnitState) -> Res<()> {
        let dir = self.unit_dir(u.unit);
        if let Some(result) = read_json::<Value>(&dir.join("result.json")) {
            return self.read_result(u, &result);
        }
        let session: Value = read_json(&dir.join("session.json")).unwrap_or(Value::Null);
        let attempts = session["attempts"].as_array().map_or(0, Vec::len);
        let n = u.unit.to_string();
        let ran = match attempts {
            0 => self.call(&["unit-run", "--unit", &n])?,
            1 => {
                let model = self.model_up(u.unit);
                self.log(Some(u.unit), "retry_one_tier_up", json!({"model": model}))?;
                if session["session_id"].as_str().is_some_and(|s| !s.is_empty()) {
                    let text = "The previous run ended without writing result.json. Continue from where it stopped, \
                                finish the unit as references/unit.md describes, and write result.json last.\n";
                    self.resume(u.unit, text, model.as_deref())?
                } else {
                    match &model {
                        Some(m) => self.call(&["unit-run", "--unit", &n, "--model", m])?,
                        None => self.call(&["unit-run", "--unit", &n])?,
                    }
                }
            }
            _ => return self.block(u, "the unit's process ended twice without writing result.json", false),
        };
        if ran.ok() {
            Ok(())
        } else {
            self.block(u, &format!("unit-run failed: {}", ran.why()), ran.infra())
        }
    }

    /// Whether the PR is open, from the unit's branch and aimed at the base:
    /// `None` when it is, else why not. `Err` is a read that failed.
    fn check_pr(&self, unit: u64, pr: u64) -> Result<Option<String>, String> {
        let view = read_view(&self.repo, pr).map_err(|e| format!("could not read PR #{pr}: {e}"))?;
        if view.state != PrState::Open {
            return Ok(Some(format!("PR #{pr} is not open")));
        }
        Ok(self.not_the_units(unit, pr, &view))
    }

    /// Why the PR is not the unit's (wrong base, branch or repository), or
    /// `None` when it is.
    fn not_the_units(&self, unit: u64, pr: u64, view: &PrView) -> Option<String> {
        let unit_file: Value = read_json(&self.unit_dir(unit).join("unit.json")).unwrap_or(Value::Null);
        let branch = unit_file["branch"]
            .as_str()
            .map(str::to_string)
            .ok_or_else(|| format!("unit {unit} has no branch in unit.json"));
        let refusals = binding(&self.repo, &self.ctx.profile.base_branch, unit, pr, view, &branch);
        if refusals.is_empty() {
            None
        } else {
            let text: Vec<String> = refusals.iter().map(|r| format!("{}: {}", r.code, r.detail)).collect();
            Some(text.join("; "))
        }
    }

    fn read_result(&self, u: &UnitState, result: &Value) -> Res<()> {
        let outcome = result["outcome"].as_str().unwrap_or_default();
        let notes = notes_of(result);
        let said = |what: &str| {
            if notes.is_empty() {
                what.to_string()
            } else {
                format!("{what}: {notes}")
            }
        };
        match outcome {
            "skipped" => self.mv(
                u.unit,
                "skipped",
                Some(&said("the unit found nothing to do")),
                None,
                None,
            ),
            "blocked" => self.mv(u.unit, "blocked", Some(&said("the unit blocked")), None, None),
            "pr_open" | "cap_reached" | "parked" => {
                let Some(pr) = result["pr"].as_u64() else {
                    return self.block(u, &format!("result.json says {outcome} but names no PR"), false);
                };
                match self.check_pr(u.unit, pr) {
                    Err(why) => self.block(u, &why, true),
                    Ok(Some(why)) => self.block(
                        u,
                        &format!("result.json says {outcome} with PR #{pr}, but {why}"),
                        false,
                    ),
                    Ok(None) => {
                        self.mv(u.unit, "pr_open", None, Some(pr), None)?;
                        if outcome == "pr_open" {
                            Ok(())
                        } else {
                            let to = self.unit_state(u.unit)?;
                            self.park(&to, &said(&format!("the unit reported {outcome}")), false)
                        }
                    }
                }
            }
            other => self.block(
                u,
                &format!("result.json has outcome '{other}', which the driver does not know"),
                false,
            ),
        }
    }

    /// `pr_open` goes on to review, unless the unit's result says it parked
    /// or reached the review cap: a driver killed between recording the PR
    /// and recording the park must not carry a PR left for a person to merge.
    fn pr_open(&self, u: &UnitState) -> Res<()> {
        let result: Value = read_json(&self.unit_dir(u.unit).join("result.json")).unwrap_or(Value::Null);
        let outcome = result["outcome"].as_str().unwrap_or_default();
        if matches!(outcome, "parked" | "cap_reached") && result["pr"].as_u64() == u.pr {
            let notes = notes_of(&result);
            let note = if notes.is_empty() {
                format!("the unit reported {outcome}")
            } else {
                format!("the unit reported {outcome}: {notes}")
            };
            return self.park(u, &note, false);
        }
        self.mv(u.unit, "reviewing", None, None, None)
    }

    fn gate_dry(&self, u: &UnitState) -> Res<(Reply, Vec<Refusal>)> {
        let (n, p) = (u.unit.to_string(), self.pr_of(u)?.to_string());
        let r = self.call(&["merge-gate", "--unit", &n, "--pr", &p, "--dry-run"])?;
        let refusals = refusals_of(&r);
        Ok((r, refusals))
    }

    fn reviewing(&self, u: &UnitState) -> Res<()> {
        let dir = self.unit_dir(u.unit);
        let marker = dir.join(self.mark("drive-review-resumed"));
        let passes_file = dir.join(self.mark("drive-review-passes"));
        let mut reads = 0;
        loop {
            let (r, refusals) = self.gate_dry(u)?;
            let person: Vec<Refusal> = refusals.iter().filter(|x| needs_a_person(x)).cloned().collect();
            if !person.is_empty() {
                return self.park(u, &format!("needs a person: {}", listed(&person)), false);
            }
            let review: Vec<Refusal> = refusals.iter().filter(|x| is_review(x)).cloned().collect();
            if review.is_empty() {
                if unreadable(&r, &refusals) {
                    reads += 1;
                    if self.dry {
                        return Ok(());
                    }
                    if reads >= 2 {
                        return self.block(u, &format!("the gate could not be read: {}", r.why()), true);
                    }
                    self.nap(u);
                    continue;
                }
                match fs::remove_file(&marker) {
                    Ok(()) => {}
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                    Err(e) => return Err(Fail::failed(format!("cannot remove {}: {e}", marker.display()))),
                }
                return self.mv(u.unit, "ci_wait", None, None, None);
            }
            if marker.exists() {
                return self.park(
                    u,
                    &format!("still refused after a review pass: {}", listed(&review)),
                    false,
                );
            }
            let passes: u32 = fs::read_to_string(&passes_file)
                .ok()
                .and_then(|t| t.trim().parse().ok())
                .unwrap_or(0);
            if passes >= MAX_REVIEW_PASSES {
                return self.park(
                    u,
                    &format!(
                        "review cap reached: the driver asked for {passes} review passes; still refused: {}",
                        listed(&review)
                    ),
                    false,
                );
            }
            if self.dry {
                return Ok(());
            }
            let text = format!(
                "A review pass is due on PR #{}. The merge gate refuses: {}. Run the cross-review on the PR's \
                 current head, address what it finds, post the review record, update result.json and stop.\n",
                self.pr_of(u)?,
                listed(&review)
            );
            write_atomic(&passes_file, format!("{}\n", passes + 1).as_bytes())?;
            self.say(&format!("U{} review pass {} started", u.unit, passes + 1));
            let ran = self.resume(u.unit, &text, None)?;
            if self.settled_by_resume(u, &ran, "the review pass")? {
                return Ok(());
            }
            write_atomic(&marker, b"1\n")?;
            return Ok(());
        }
    }

    fn ci_wait(&self, u: &UnitState) -> Res<()> {
        let start = Instant::now();
        let mut reads = 0;
        loop {
            let (r, refusals) = self.gate_dry(u)?;
            if unreadable(&r, &refusals) {
                reads += 1;
                if reads >= 5 {
                    return self.block(u, &format!("the gate could not be read five times: {}", r.why()), true);
                }
            } else if !refusals.is_empty() && decide(&refusals) == Action::Pending {
                reads = 0;
            } else {
                return self.mv(u.unit, "gate", None, None, None);
            }
            if self.dry {
                return Ok(());
            }
            if start.elapsed() >= self.ci_max {
                let why = format!("the checks did not finish within {} seconds", self.ci_max.as_secs());
                return self.block(u, &why, true);
            }
            self.nap(u);
        }
    }

    /// The PR as GitHub has it, when it is merged.
    fn merged_view(&self, pr: u64) -> Option<PrView> {
        read_view(&self.repo, pr).ok().filter(|v| v.state == PrState::Merged)
    }

    /// Settle a unit whose PR merged while a base sync was in flight.
    fn settle_merged(&self, u: &UnitState, pr: u64, view: &PrView, marker: &Path) -> Res<Option<String>> {
        if let Some(why) = self.not_the_units(u.unit, pr, view) {
            return self
                .park(u, &format!("PR #{pr} merged, but {why}"), false)
                .map(|()| None);
        }
        let Some(commit) = view.merge_commit.clone().filter(|c| is_sha(c)) else {
            return self
                .park(u, &format!("PR #{pr} is merged, but no merge commit was named"), false)
                .map(|()| None);
        };
        let _ = fs::remove_file(marker);
        self.mv(u.unit, "merged", None, None, Some(&commit))?;
        self.merge_settled(u.unit)?;
        self.merged(u.unit, pr)
    }

    fn gate(&self, u: &UnitState) -> Res<Option<String>> {
        let pr = self.pr_of(u)?;
        let (n, p) = (u.unit.to_string(), pr.to_string());
        // A base sync a dead driver left half done: finish it before the gate
        // is read, or the gate would see a moved head and spend another sync
        // or a repair round, or merge a head the delivery check never saw.
        let marker = self.unit_dir(u.unit).join(crate::base_sync::PENDING_MARKER);
        if !self.dry && marker.exists() {
            // A PR that merged while the driver was down needs no sync, and
            // base-sync would refuse it as not open: settle it as merged.
            if let Some(view) = self.merged_view(pr) {
                return self.settle_merged(u, pr, &view, &marker);
            }
            // A hold put on while the driver was down still stops the unit:
            // the sync would push to the PR a person asked to be left alone.
            let (_, refusals) = self.gate_dry(u)?;
            let person: Vec<Refusal> = refusals.iter().filter(|x| needs_a_person(x)).cloned().collect();
            if !person.is_empty() {
                return self
                    .park(u, &format!("needs a person: {}", listed(&person)), false)
                    .map(|()| None);
            }
            if u.base_syncs >= MAX_BASE_SYNCS {
                return self.base_sync(u).map(|()| None);
            }
            let r = self.sync_call(u)?;
            // The sync may have failed because the PR merged in the meantime.
            if !r.ok()
                && let Some(view) = self.merged_view(pr)
            {
                return self.settle_merged(u, pr, &view, &marker);
            }
            self.after_sync(u, &r)?;
            return Ok(None);
        }
        let start = Instant::now();
        let mut errors = 0;
        loop {
            let r = self.call(&["merge-gate", "--unit", &n, "--pr", &p])?;
            match r.code {
                0 => {
                    let j = r.json().unwrap_or(Value::Null);
                    if j["merged"] != true {
                        // A dry run: the gate says it would merge, and nothing did.
                        return Ok(None);
                    }
                    let commit = match j["merge_commit"].as_str().filter(|s| is_sha(s)) {
                        Some(sha) => sha.to_string(),
                        None => read_view(&self.repo, pr)
                            .ok()
                            .and_then(|v| v.merge_commit)
                            .ok_or_else(|| Fail::failed(format!("PR #{pr} merged, but no merge commit was named")))?,
                    };
                    self.mv(u.unit, "merged", None, None, Some(&commit))?;
                    self.merge_settled(u.unit)?;
                    return self.merged(u.unit, pr);
                }
                4 => {
                    // In the merge queue: not merged yet, and nothing to undo.
                    // The unit stays in gate for the next driver to ask again.
                    if self.dry {
                        return Ok(None);
                    }
                    self.merge_asked(u.unit)?;
                    if start.elapsed() >= self.ci_max {
                        return Ok(Some(format!(
                            "PR #{pr} of unit {} is still in the merge queue after {} seconds; once it merges, run `state resume` and drive again",
                            u.unit,
                            self.ci_max.as_secs()
                        )));
                    }
                    self.nap(u);
                }
                3 => {
                    if !self.dry && self.unit_dir(u.unit).join(MERGE_ASKED).exists() {
                        match self.merge_outcome(pr) {
                            Outcome::Merged(commit) => {
                                self.mv(u.unit, "merged", None, None, Some(&commit))?;
                                self.merge_settled(u.unit)?;
                                return self.merged(u.unit, pr);
                            }
                            Outcome::NotMerging => self.merge_settled(u.unit)?,
                            Outcome::Unsure(why) => {
                                // The refusals cannot be acted on yet: a park
                                // would release the claim on a PR that may merge.
                                if start.elapsed() >= self.ci_max {
                                    return Ok(Some(format!(
                                        "a merge of PR #{pr} of unit {} was asked for and is not settled ({why}): check the PR, then `state resume` and drive again",
                                        u.unit
                                    )));
                                }
                                self.nap(u);
                                continue;
                            }
                        }
                    }
                    if !self.at_gate(u, &refusals_of(&r), start, &mut errors)? {
                        return Ok(None);
                    }
                }
                _ if r.json().is_some_and(|j| j["auto_merge_armed"] == true) => {
                    // The gate asked for a merge and could not take auto-merge
                    // off again: GitHub may still merge the PR. Parking would
                    // release the claim on a PR that can land, so the drain
                    // stops with the unit at the gate.
                    return Ok(Some(format!(
                        "auto-merge is still armed on PR #{pr} of unit {}: run `gh pr merge {pr} --disable-auto`, then `state resume` and drive again",
                        u.unit
                    )));
                }
                _ if r.json().is_some_and(|j| j["state_unknown"] == true) => {
                    // GitHub took the merge call but the read-back failed: the
                    // PR may have merged. Parking would release the claim and
                    // skip the post-merge checks, so ask once more, then stop
                    // with the unit at the gate.
                    if !self.dry {
                        self.merge_asked(u.unit)?;
                    }
                    errors += 1;
                    if errors >= 2 || self.dry {
                        return Ok(Some(format!(
                            "the merge call on PR #{pr} of unit {} was sent but GitHub did not say whether it merged: check the PR, then `state resume` and drive again",
                            u.unit
                        )));
                    }
                    self.nap(u);
                }
                _ => {
                    errors += 1;
                    if errors >= 2 || self.dry {
                        self.park(u, &format!("the merge call failed: {}", r.why()), true)?;
                        return Ok(None);
                    }
                    self.nap(u);
                }
            }
        }
    }

    fn merge_asked(&self, unit: u64) -> Res<()> {
        write_atomic(&self.unit_dir(unit).join(MERGE_ASKED), b"a merge was asked for\n")
    }

    fn merge_settled(&self, unit: u64) -> Res<()> {
        match fs::remove_file(self.unit_dir(unit).join(MERGE_ASKED)) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(Fail::failed(format!(
                "cannot remove the merge record of unit {unit}: {e}"
            ))),
            _ => Ok(()),
        }
    }

    /// What became of a merge the gate asked for, read from GitHub.
    fn merge_outcome(&self, pr: u64) -> Outcome {
        let view = match read_view(&self.repo, pr) {
            Ok(v) => v,
            Err(e) => return Outcome::Unsure(format!("PR #{pr} could not be read: {e}")),
        };
        match view.state {
            PrState::Merged => match view.merge_commit.filter(|c| is_sha(c)) {
                Some(commit) => Outcome::Merged(commit),
                None => Outcome::Unsure(format!("PR #{pr} is merged, but no merge commit was named")),
            },
            PrState::Closed => Outcome::NotMerging,
            PrState::Open => match in_merge_queue(&self.repo, pr) {
                Ok(false) => Outcome::NotMerging,
                Ok(true) => Outcome::Unsure(format!("PR #{pr} is still in the merge queue")),
                Err(e) => Outcome::Unsure(format!("could not read {e}")),
            },
            PrState::Other => Outcome::Unsure(format!("PR #{pr} is in a state the driver does not know")),
        }
    }

    /// The gate refused: act on what the refusals call for. `true` asks the
    /// caller to ask the gate again, with the unit still in gate.
    fn at_gate(&self, u: &UnitState, refusals: &[Refusal], start: Instant, errors: &mut u32) -> Res<bool> {
        let moved = |result: Res<()>| result.map(|()| false);
        match decide(refusals) {
            Action::Park(note) => moved(self.park(u, &note, false)),
            Action::BaseSync => moved(self.base_sync(u)),
            Action::Repair(reason) => moved(self.to_repair(u, &reason)),
            Action::Threads(list) => moved(self.to_repair(
                u,
                &format!("The PR has unresolved review threads ({list}). Reply to each thread and resolve it."),
            )),
            Action::Review => moved(self.mv(u.unit, "reviewing", None, None, None)),
            Action::Pending => {
                *errors = 0;
                if self.dry {
                    return Ok(false);
                }
                if start.elapsed() >= self.ci_max {
                    return moved(self.park(u, "the checks stayed pending", true));
                }
                self.nap(u);
                Ok(true)
            }
            Action::ReadError => {
                *errors += 1;
                if self.dry {
                    return Ok(false);
                }
                if *errors >= 2 {
                    return moved(self.park(
                        u,
                        &format!("the gate could not be read twice: {}", listed(refusals)),
                        true,
                    ));
                }
                self.nap(u);
                Ok(true)
            }
        }
    }

    fn base_sync(&self, u: &UnitState) -> Res<()> {
        if u.base_syncs >= MAX_BASE_SYNCS {
            return self.park(
                u,
                &format!("the PR fell behind the base after {MAX_BASE_SYNCS} base syncs"),
                false,
            );
        }
        let r = self.sync_call(u)?;
        self.after_sync(u, &r)
    }

    /// Call `base-sync`, retrying an exit 1.
    fn sync_call(&self, u: &UnitState) -> Res<Reply> {
        let (n, p) = (u.unit.to_string(), self.pr_of(u)?.to_string());
        // Exit 1 is often GitHub not having applied the update yet; a retry
        // spends no sync slot.
        let mut tries = 0;
        loop {
            let r = self.call(&["base-sync", "--unit", &n, "--pr", &p])?;
            tries += 1;
            if r.code == 1 && !r.timed_out && tries < BASE_SYNC_TRIES && !self.dry {
                self.nap(u);
                continue;
            }
            return Ok(r);
        }
    }

    /// Move the unit on from what `base-sync` answered.
    fn after_sync(&self, u: &UnitState, r: &Reply) -> Res<()> {
        if !r.ok() {
            return self.park(u, &format!("base-sync failed: {}", r.why()), r.infra());
        }
        let j = r.json().unwrap_or(Value::Null);
        if j["deliver_ok"] == false {
            return self.park(u, "the delivery check failed after the base sync", false);
        }
        if j["review_round_needed"] == true {
            self.mv(
                u.unit,
                "reviewing",
                Some("a review round is needed after the base sync"),
                None,
                None,
            )
        } else {
            self.mv(u.unit, "ci_wait", Some("base synced"), None, None)
        }
    }

    fn to_repair(&self, u: &UnitState, reason: &str) -> Res<()> {
        if u.repairs >= MAX_REPAIRS {
            return self.park(
                u,
                &format!("repaired {MAX_REPAIRS} times already; still refused. {reason}"),
                false,
            );
        }
        write_atomic(
            &self.unit_dir(u.unit).join("drive-repair-reason.txt"),
            reason.as_bytes(),
        )?;
        self.mv(u.unit, "repairing", Some(&one_line(reason)), None, None)
    }

    fn repairing(&self, u: &UnitState) -> Res<()> {
        let reason = fs::read_to_string(self.unit_dir(u.unit).join("drive-repair-reason.txt"))
            .unwrap_or_else(|_| "The merge gate refused the PR. Run its checks again and fix what fails.".into());
        let text = format!(
            "A repair is due on PR #{}. {}\nFetch and fast-forward the worktree to the PR's remote head, do only \
             what this asks, rerun the checks the change makes stale, update result.json and stop.\n",
            self.pr_of(u)?,
            reason.trim()
        );
        let model = if u.repairs >= 2 { self.model_up(u.unit) } else { None };
        let ran = self.resume(u.unit, &text, model.as_deref())?;
        if self.settled_by_resume(u, &ran, "the repair run")? {
            return Ok(());
        }
        self.mv(u.unit, "ci_wait", None, None, None)
    }

    /// After a merge: `post-merge`, then done. `Some` stops the drain.
    fn merged(&self, unit: u64, pr: u64) -> Res<Option<String>> {
        let (n, p) = (unit.to_string(), pr.to_string());
        let r = self.call(&["post-merge", "--unit", &n, "--pr", &p])?;
        if !r.ok() {
            return Ok(Some(format!(
                "the post-merge checks of unit {unit} failed: {}",
                r.why()
            )));
        }
        let mismatch = r.json().is_some_and(|j| j["tree_match"] == false);
        if mismatch {
            // Written before `done`, so a driver that dies between the two
            // still refuses to go on.
            write_atomic(
                &self.unit_dir(unit).join(self.mark(TREE_MISMATCH)),
                format!("unit {unit}, PR #{pr}: the merge commit's tree is not the tree the gate approved\n")
                    .as_bytes(),
            )?;
        }
        self.mv(unit, "done", None, None, None)?;
        Ok(mismatch.then(|| {
            format!(
                "unit {unit} merged a different tree than the gate approved; the base tip needs a verify by a person"
            )
        }))
    }

    // ---- the end of a unit ----

    /// The note of the unit's last move into `state`.
    fn last_note(&self, unit: u64, state: State) -> Option<String> {
        let text = state::log_text(self.ctx).ok()?;
        text.lines()
            .filter_map(|l| serde_json::from_str::<Value>(l).ok())
            .rfind(|v| v.get("event").is_none() && v["unit"] == unit && v["to"] == state.as_str())
            .and_then(|v| v["note"].as_str().map(str::to_string))
    }

    fn reconcile(&self) -> Res<()> {
        let snap = self.snapshot()?;
        for u in snap.units.iter().filter(|u| u.state.is_terminal()) {
            let dir = self.unit_dir(u.unit);
            if !dir.join(self.mark("drive-owned")).exists() {
                continue;
            }
            if !dir.join(self.mark("drive-ended.json")).exists() {
                self.end_unit(u)?;
            } else if u.state == State::Done && dir.join(self.mark(CLEANUP_PENDING)).exists() {
                // The unit ended, comment and all; only its cleanup is owed.
                self.cleanup_unit(u)?;
            }
        }
        Ok(())
    }

    fn end_unit(&self, u: &UnitState) -> Res<()> {
        let note = self.last_note(u.unit, u.state).unwrap_or_default();
        let infra = note.starts_with(INFRA);
        let n = u.unit.to_string();
        if u.state == State::Done {
            self.cleanup_unit(u)?;
        } else if !note.starts_with(CLAIM_REFUSED) && note != REMOVED {
            let r = self.call(&["claim", "release", "--unit", &n])?;
            match r.code {
                0 if !r.timed_out => {}
                // Not this run's claim (or no claim left): nothing to release.
                3 if !r.timed_out => self.log(Some(u.unit), "claim_not_ours", json!({"why": r.why()}))?,
                // Before the comment and the ended marker, so a restart tries again.
                _ => {
                    return Err(fail_code(
                        r.code,
                        format!("claim release failed for unit {}: {}", u.unit, r.why()),
                    ));
                }
            }
        }
        let issues: Vec<String> = u.issues.iter().map(|i| format!("#{i}")).collect();
        let outcome = match u.state {
            State::Done => "done and merged",
            State::Skipped => "skipped",
            State::Blocked => "blocked",
            _ => "parked, waiting for a person",
        };
        let mut body = format!(
            "issue-drain run {}: unit U{} ({}) is {}.\n",
            self.ctx.run_id()?,
            u.unit,
            issues.join(", "),
            outcome
        );
        if let Some(pr) = u.pr {
            body.push_str(&format!("\nPull request: https://github.com/{}/pull/{pr}\n", self.repo));
        }
        let note = note.strip_prefix(INFRA).unwrap_or(&note);
        if !note.is_empty() {
            let kind = if infra {
                "Note (an infrastructure failure)"
            } else {
                "Note"
            };
            body.push_str(&format!("\n{kind}: {note}\n"));
        }
        self.comment_tracker(&format!("unit-{}", u.unit), &body)?;
        let seq = self.ended().len() as u64 + 1;
        let marker = json!({"unit": u.unit, "seq": seq, "state": u.state.as_str(), "infra": infra});
        write_atomic(
            &self.unit_dir(u.unit).join(self.mark("drive-ended.json")),
            format!("{marker}\n").as_bytes(),
        )
    }

    /// `cleanup` for a done unit. A failure leaves `drive-cleanup-pending`, which
    /// is apart from `drive-ended.json` (the comment was posted, once) and which
    /// `reconcile` retries until `cleanup` succeeds.
    fn cleanup_unit(&self, u: &UnitState) -> Res<()> {
        let n = u.unit.to_string();
        let pr = u.pr.map(|p| p.to_string());
        let mut args = vec!["cleanup", "--unit", &n];
        if let Some(pr) = &pr {
            args.extend(["--pr", pr]);
        }
        let pending = self.unit_dir(u.unit).join(self.mark(CLEANUP_PENDING));
        let r = self.call(&args)?;
        if r.ok() {
            let _ = fs::remove_file(&pending);
            return Ok(());
        }
        self.log(Some(u.unit), "cleanup_failed", json!({"why": r.why()}))?;
        write_atomic(&pending, format!("{}\n", one_line(&r.why())).as_bytes())
    }

    /// `(seq, blocked, infra)` of every unit the driver ended, in order.
    fn ended(&self) -> Vec<(u64, bool, bool)> {
        let mut list: Vec<(u64, bool, bool)> = fs::read_dir(self.ctx.path("units"))
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|e| read_json::<Value>(&e.path().join(self.mark("drive-ended.json"))))
            .map(|m| {
                (
                    m["seq"].as_u64().unwrap_or(0),
                    m["state"] == "blocked",
                    m["infra"] == true,
                )
            })
            .collect();
        list.sort();
        list
    }

    /// A streak that stops the drain, and the newest ended unit's seq: the
    /// floor the caller writes once the stop is recorded.
    fn streak_stop(&self) -> Option<(Stop, u64)> {
        let floor: u64 = fs::read_to_string(self.ctx.path(&self.mark("drive-streak-floor")))
            .ok()
            .and_then(|t| t.trim().parse().ok())
            .unwrap_or(0);
        let list: Vec<(u64, bool, bool)> = self.ended().into_iter().filter(|e| e.0 > floor).collect();
        let blocked = list.iter().rev().take_while(|e| e.1).count();
        let infra = list.iter().rev().take_while(|e| e.2).count();
        let reason = if blocked >= 3 {
            "three units in a row ended blocked"
        } else if infra >= 2 {
            "two units in a row ended with an infrastructure failure"
        } else {
            return None;
        };
        let top = list.last().map_or(floor, |e| e.0);
        Some((
            Stop {
                reason: reason.into(),
                code: 3,
            },
            top,
        ))
    }
}

/// Remove the markers an earlier dry run left: the `dry-` files in the run
/// folder and in each unit's folder.
fn reset_dry_markers(ctx: &Ctx) -> Res<()> {
    let mut dirs = vec![ctx.workdir.clone()];
    dirs.extend(
        fs::read_dir(ctx.path("units"))
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path()),
    );
    for dir in dirs {
        for entry in fs::read_dir(&dir).into_iter().flatten().flatten() {
            let path = entry.path();
            if path.is_file() && entry.file_name().to_string_lossy().starts_with("dry-drive-") {
                fs::remove_file(&path).map_err(|e| Fail::failed(format!("cannot remove {}: {e}", path.display())))?;
            }
        }
    }
    Ok(())
}

pub fn run(ctx: &Ctx, args: &Args) -> Res<()> {
    ctx.require_driver("drive")?;
    if !args.once && env_str("ISSUE_DRAIN_UNATTENDED_OK") != "1" {
        return Err(Fail::refused(
            "drive without --once carries units with nobody watching; run it with --once, or set \
             ISSUE_DRAIN_UNATTENDED_OK=1 once the unit's GitHub identity is set up for unattended runs",
        ));
    }
    let lock = Lock::take(ctx)?;
    if ctx.dry_run {
        // Each dry run starts from the run as it is now.
        state::reset_dry(ctx)?;
        reset_dry_markers(ctx)?;
    }
    let driver = Driver::new(ctx, &lock, args.quiet)?;
    let _pid = PidFile::write(&ctx.workdir)?;
    driver.say(&format!(
        "pid {}, run folder {}",
        std::process::id(),
        ctx.workdir.display()
    ));
    let _awake = Caffeinate::start();
    driver.ensure_state()?;
    let mut report = Report { processed: Vec::new() };
    let done = driver.drive(args.once, &mut report);
    let stopped = match &done {
        Ok(Some(stop)) => json!(stop.reason),
        _ => Value::Null,
    };
    let processed: Vec<Value> = report
        .processed
        .iter()
        .map(|(unit, state)| json!({"unit": unit, "state": state.as_str()}))
        .collect();
    println!("{}", json!({"processed": processed, "stopped": stopped}));
    let result = match done {
        Ok(Some(stop)) if stop.code != 0 => Err(Fail::refused(stop.reason)),
        Ok(_) => Ok(()),
        Err(fail) => Err(fail),
    };
    match (result, driver.progress) {
        (Err(fail), Some(progress)) => Err(progress.finish(fail)),
        (result, _) => result,
    }
}

#[cfg(test)]
mod tests {
    /// A writer that never returns, like a pipe nobody reads.
    struct Stuck;

    impl std::io::Write for Stuck {
        fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
            loop {
                std::thread::park();
            }
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn a_stuck_stderr_never_holds_up_the_driver() {
        let started = Instant::now();
        let progress = Progress::to(Stuck);
        for n in 0..(PROGRESS_BACKLOG * 4) {
            progress.say(&format!("line {n}"));
        }
        drop(progress);
        assert!(
            started.elapsed() < PROGRESS_FLUSH + Duration::from_secs(5),
            "{:?}",
            started.elapsed()
        );
    }

    /// Writes into a shared buffer the test reads back.
    struct Shared(std::sync::Arc<std::sync::Mutex<Vec<u8>>>);

    impl std::io::Write for Shared {
        fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(b);
            Ok(b.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn a_failing_driver_says_why_last_and_a_stuck_stderr_cannot_hold_it() {
        let buf = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let progress = Progress::to(Shared(buf.clone()));
        progress.say("one");
        let fail = progress.finish(Fail::refused("STOP file"));
        assert!(fail.reported);
        assert_eq!(fail.code, 3);
        assert_eq!(
            String::from_utf8(buf.lock().unwrap().clone()).unwrap(),
            "drive: one\nissue-drain drive: STOP file\n"
        );

        let progress = Progress::to(Stuck);
        for n in 0..PROGRESS_BACKLOG + 10 {
            progress.say(&format!("line {n}"));
        }
        let start = Instant::now();
        let fail = progress.finish(Fail::failed("gh failed"));
        assert!(fail.reported);
        assert!(start.elapsed() < PROGRESS_FLUSH + Duration::from_secs(3));
    }

    #[test]
    fn a_long_poll_is_slept_in_heartbeat_slices() {
        let s = Duration::from_secs;
        assert_eq!(poll_slices(s(900), s(300)), vec![s(300), s(300), s(300)]);
        assert_eq!(poll_slices(s(700), s(300)), vec![s(300), s(300), s(100)]);
        assert_eq!(poll_slices(s(60), s(300)), vec![s(60)]);
        assert!(poll_slices(Duration::ZERO, s(300)).is_empty());
    }

    #[test]
    fn queued_lines_reach_stderr_in_order_before_the_driver_exits() {
        let buf = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let progress = Progress::to(Shared(buf.clone()));
        progress.say("one");
        progress.say("two");
        drop(progress);
        assert_eq!(
            String::from_utf8(buf.lock().unwrap().clone()).unwrap(),
            "drive: one\ndrive: two\n"
        );
    }

    use super::*;

    fn r(code: &str, detail: &str) -> Refusal {
        Refusal {
            code: code.into(),
            detail: detail.into(),
        }
    }

    #[test]
    fn the_unit_prepare_limit_is_longer_than_everything_it_runs() {
        let mut p = crate::profile::Profile::default();
        p.bootstrap_timeout_secs = 3000;
        p.codegraph_timeout_secs = 300;
        let limit = call_limit(&p, Some("unit-prepare")).as_secs();
        assert!(limit >= 3000 + 300 + 300 + 240 + 600, "{limit}");
        let quick = crate::profile::Profile::default();
        assert!(call_limit(&quick, Some("unit-prepare")).as_secs() >= 1800);
        assert_eq!(call_limit(&quick, Some("merge-gate")).as_secs(), 1800);
        assert_eq!(
            call_limit(&quick, Some("unit-run")).as_secs(),
            quick.unit_timeout_secs + 900
        );
    }

    fn names(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn the_ladder_goes_up_one_allowed_tier_and_stops_at_the_top() {
        let all = names(&["haiku", "sonnet", "opus"]);
        assert_eq!(tier_up("haiku", &all).as_deref(), Some("sonnet"));
        assert_eq!(tier_up("sonnet", &all).as_deref(), Some("opus"));
        assert_eq!(tier_up("opus", &all), None);
        assert_eq!(tier_up("haiku", &names(&["haiku", "opus"])).as_deref(), Some("opus"));
        assert_eq!(tier_up("haiku", &names(&["haiku"])), None);
    }

    #[test]
    fn a_person_comes_before_every_repair_and_behind_base_before_the_rest() {
        let held = r("hold_label", "PR #1 carries 'needs-human'");
        let behind = r("behind_base", "3 behind");
        let failed = r("check_failed", "check 'lint' is failure");
        assert!(matches!(
            decide(&[failed.clone(), behind.clone(), held]),
            Action::Park(_)
        ));
        assert_eq!(decide(&[failed.clone(), behind]), Action::BaseSync);
        assert!(matches!(decide(&[r("review", "x"), failed]), Action::Repair(_)));
    }

    #[test]
    fn pending_checks_are_told_from_failed_ones() {
        let pending = r("required_check", "required check 'ci' is pending at the head");
        let none = r("required_check", "required check 'ci' has no run at the head");
        let failed = r("required_check", "required check 'ci' is failure at the head");
        assert_eq!(decide(&[pending.clone(), r("review", "x")]), Action::Pending);
        assert_eq!(decide(&[none]), Action::Pending);
        assert!(matches!(decide(&[failed, pending]), Action::Repair(_)));
    }

    #[test]
    fn review_threads_other_and_read_errors_each_get_their_own_answer() {
        assert_eq!(decide(&[r("review_proof", "x")]), Action::Review);
        assert!(matches!(
            decide(&[r("threads_open", "2 unresolved review threads")]),
            Action::Threads(_)
        ));
        assert!(matches!(
            decide(&[r("deliver_check", "x"), r("read_error", "y")]),
            Action::Park(_)
        ));
        assert_eq!(decide(&[r("read_error", "y")]), Action::ReadError);
    }

    #[test]
    fn the_last_json_line_is_the_answer_whatever_came_before() {
        let text = "WOULD: gh pr merge 4\n{\"merged\":false}\n";
        assert_eq!(last_json(text), Some(json!({"merged": false})));
        assert_eq!(last_json("nothing\n"), None);
    }

    #[test]
    fn the_pid_file_holds_this_pid_and_goes_when_dropped() {
        let dir = std::env::temp_dir().join(format!("drive-pid-test-{}", std::process::id()));
        fs::create_dir_all(&dir).expect("dir");
        let guard = PidFile::write(&dir).expect("written");
        let text = fs::read_to_string(dir.join(DRIVE_PID)).expect("read");
        assert_eq!(text.trim(), std::process::id().to_string());
        drop(guard);
        assert!(!dir.join(DRIVE_PID).exists());
        let _ = fs::remove_dir_all(&dir);
    }
}
