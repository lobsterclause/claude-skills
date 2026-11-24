//! CLI tests for `drive`.
//!
//! The driver runs its subcommands as children. These tests give it a wrapper
//! program (`ISSUE_DRAIN_DRIVE_EXE`, honoured only with
//! `ISSUE_DRAIN_DRIVE_TESTING=1`) that logs each call and answers some of them
//! from canned files, passing the rest to the real binary. Real here: `state`,
//! `unit-run` (with a fake `claude`) and `gh-write` (with the stub gh). Canned:
//! `claim`, `unit-prepare`, `merge-gate`, `base-sync`, `post-merge`, `cleanup`,
//! `retro` and `tracker parse`. The real `claude` and GitHub are never touched.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

use serde_json::{Value, json};

use crate::common::*;

const WRAPPER: &str = r#"#!/bin/sh
case "$1" in tracker|state|claim) sub="$1-$2";; *) sub="$1";; esac
printf '%s\n' "$*" >> "$FAKE_DIR/calls.log"
n=$(cat "$FAKE_DIR/count.$sub" 2>/dev/null || echo 0)
n=$((n+1))
echo "$n" > "$FAKE_DIR/count.$sub"
pick() { for f in "$FAKE_DIR/$sub.$n.$1" "$FAKE_DIR/$sub.$1"; do if [ -e "$f" ]; then echo "$f"; return; fi; done; }
out=$(pick out); code=$(pick code); hook=$(pick sh)
if [ -z "$out$code$hook" ]; then exec "$REAL_BIN" "$@"; fi
if [ -n "$hook" ]; then . "$hook"; fi
if [ -n "$out" ]; then cat "$out"; fi
if [ -n "$code" ]; then exit "$(cat "$code")"; fi
exit 0
"#;

const CLAUDE: &str = r#"#!/bin/sh
d=$(dirname "$ISSUE_DRAIN_UNIT_FILE")
u=$(basename "$d")
k=1
while [ -e "$FAKE_REC/argv.$u.$k" ]; do k=$((k+1)); done
printf '%s\n' "$@" > "$FAKE_REC/argv.$u.$k"
echo '{"type":"system","subtype":"init","session_id":"sess-1"}'
echo '{"type":"result","subtype":"success","session_id":"sess-1","total_cost_usd":0.1,"is_error":false,"num_turns":2}'
if [ -e "$FAKE_REC/result.$u" ]; then cp "$FAKE_REC/result.$u" "$d/result.json"; fi
exit "$(cat "$FAKE_REC/exit.$u" 2>/dev/null || echo 0)"
"#;

const MERGE_SHA: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

struct Case {
    env: Env,
    fake: PathBuf,
    rec: PathBuf,
}

fn script(path: &PathBuf, text: &str) {
    fs::write(path, text).expect("the script");
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).expect("the mode");
}

fn case(units: &[u64]) -> Case {
    let mut env = Env::new();
    let dir = env.dir.path().to_path_buf();
    let (fake, rec, bin, home, wt) = (
        dir.join("fake"),
        dir.join("rec"),
        dir.join("fakebin"),
        dir.join("home"),
        dir.join("wt"),
    );
    for d in [&fake, &rec, &bin, &home, &wt] {
        fs::create_dir_all(d).expect("the folder");
    }
    script(&bin.join("claude"), CLAUDE);
    let wrapper = dir.join("wrapper.sh");
    script(&wrapper, WRAPPER);
    let path = format!(
        "{}:{}:/usr/bin:/bin",
        bin.display(),
        manifest_dir().join("tests/stub").display()
    );
    let text = |p: &PathBuf| p.display().to_string();
    env.set("PATH", &path)
        .set("HOME", &text(&home))
        .set("FAKE_DIR", &text(&fake))
        .set("FAKE_REC", &text(&rec))
        .set("REAL_BIN", env!("CARGO_BIN_EXE_issue-drain"))
        .set("ISSUE_DRAIN_DRIVE_TESTING", "1")
        .set("ISSUE_DRAIN_DRIVE_EXE", &text(&wrapper))
        .set("ISSUE_DRAIN_DRIVE_POLL_SECS", "0")
        .set("ISSUE_DRAIN_DRIVE_CI_MAX_SECS", "5")
        .set("ISSUE_DRAIN_UNATTENDED_OK", "1");

    // The queue: one unit per number, issues 100+n.
    let mut queue = queue_with_unit(json!({}));
    let template = queue["units"][0].clone();
    let entries: Vec<Value> = units
        .iter()
        .map(|n| {
            let mut e = template.clone();
            let issue = 100 + n;
            e["id"] = json!(format!("U{n}"));
            e["issues"] = json!([issue]);
            e["live"] = json!([issue]);
            e["acceptance"] = json!({ issue.to_string(): "it works" });
            e
        })
        .collect();
    queue["units"] = json!(entries);
    env.write("queue.json", &queue.to_string());
    env.write(
        "tracker.json",
        &json!({"number": 50, "url": "https://github.com/example/tidepool/issues/50", "run": "run",
                "published_at": "2026-11-21T00:00:00Z"})
        .to_string(),
    );
    for n in units {
        env.write(
            &format!("units/{n}/unit.json"),
            &json!({"unit": n, "worktree": wt, "model": "haiku", "effort": "low", "branch": format!("fix/{n}")})
                .to_string(),
        );
        // What unit-prepare writes beside unit.json; unit-run refuses without it.
        env.write(
            &format!("units/{n}/guards-unit.json"),
            &json!({"unit": n, "worktree": wt, "branch": format!("fix/{n}"), "protected_paths": []}).to_string(),
        );
    }
    let c = Case { env, fake, rec };
    let ids: Vec<String> = units.iter().map(|n| format!("U{n}")).collect();
    let parsed = json!({"run": "run", "stop": false, "units": ids, "approved_closures": [],
                        "release_claims": [], "tracker_state": "OPEN", "unknown": []});
    c.canned("tracker-parse", 0, &parsed.to_string());
    c.env.write("parsed.json", &parsed.to_string());
    c.canned("claim-take", 0, "[]");
    c.canned("claim-release", 0, "[]");
    c.canned("unit-prepare", 0, "");
    c.canned("cleanup", 0, "{}");
    c.canned("retro", 0, "");
    c.canned("post-merge", 0, &json!({"tree_match": true}).to_string());
    c
}

impl Case {
    /// Answer every call of `sub` (or call number `n`, with `canned_n`) from a file.
    fn canned(&self, sub: &str, code: i32, out: &str) {
        fs::write(self.fake.join(format!("{sub}.code")), code.to_string()).expect("code");
        if !out.is_empty() {
            fs::write(self.fake.join(format!("{sub}.out")), out).expect("out");
        }
    }

    fn canned_n(&self, sub: &str, n: u32, code: i32, out: &str) {
        fs::write(self.fake.join(format!("{sub}.{n}.code")), code.to_string()).expect("code");
        fs::write(self.fake.join(format!("{sub}.{n}.out")), out).expect("out");
    }

    fn clean() -> String {
        json!({"merged": false, "refusals": []}).to_string()
    }

    fn merged() -> String {
        json!({"merged": true, "merge_commit": MERGE_SHA, "refusals": []}).to_string()
    }

    fn refused(codes: &[(&str, &str)]) -> String {
        let list: Vec<Value> = codes.iter().map(|(c, d)| json!({"code": c, "detail": d})).collect();
        json!({"merged": false, "refusals": list}).to_string()
    }

    fn result(&self, unit: u64, result: Value) {
        fs::write(self.rec.join(format!("result.{unit}")), result.to_string()).expect("result");
    }

    fn pr_view(&self, unit: u64, pr: u64) {
        let view = json!({
            "state": "OPEN", "headRefOid": "b".repeat(40), "headRefName": format!("fix/{unit}"),
            "baseRefName": "develop", "headRepository": {"name": "tidepool"},
            "headRepositoryOwner": {"login": "example"}, "mergeStateStatus": "CLEAN", "reviewDecision": "",
            "labels": [], "body": "", "closingIssuesReferences": [], "changedFiles": 1,
            "statusCheckRollup": [], "mergeCommit": null
        });
        self.env.stub_file(&format!("pr-view-{pr}.json"), &view.to_string());
    }

    fn drive(&self, extra: &[&str]) -> (Out, Value) {
        let mut args = vec!["drive"];
        args.extend_from_slice(extra);
        let out = self.env.run(&args);
        let last = out.stdout.lines().last().unwrap_or_default();
        let report = serde_json::from_str(last).unwrap_or(Value::Null);
        (out, report)
    }

    fn calls(&self) -> Vec<String> {
        fs::read_to_string(self.fake.join("calls.log"))
            .unwrap_or_default()
            .lines()
            .map(str::to_string)
            .collect()
    }

    fn count(&self, prefix: &str) -> usize {
        self.calls().iter().filter(|c| c.starts_with(prefix)).count()
    }

    fn at(&self, prefix: &str) -> usize {
        self.calls()
            .iter()
            .position(|c| c.starts_with(prefix))
            .unwrap_or_else(|| panic!("no call starting '{prefix}' in {:?}", self.calls()))
    }

    fn snapshot(&self) -> Value {
        let out = self.env.run(&["state", "show", "--json"]);
        serde_json::from_str(&out.stdout).unwrap_or_else(|e| panic!("no snapshot ({e}): {}", out.stderr))
    }

    fn state_of(&self, unit: u64) -> String {
        let snap = self.snapshot();
        let found = snap["units"]
            .as_array()
            .and_then(|u| u.iter().find(|x| x["unit"] == unit));
        found.map_or("none".into(), |u| u["state"].as_str().unwrap_or_default().to_string())
    }

    /// Start the state log and walk a unit to `to`, as an earlier driver would have.
    fn seed(&self, unit: u64, to: &[&str], pr: Option<u64>) {
        let init = self.env.run(&[
            "state",
            "init",
            "--parsed",
            &self.env.workdir.join("parsed.json").display().to_string(),
        ]);
        assert_eq!(init.code, 0, "{}", init.stderr);
        let n = unit.to_string();
        for state in to {
            let mut args = vec!["state", "event", &n, state];
            let p = pr.map(|p| p.to_string());
            if *state == "pr_open" {
                args.extend(["--pr", p.as_deref().expect("a PR for pr_open")]);
            }
            let out = self.env.run(&args);
            assert_eq!(out.code, 0, "{state}: {}", out.stderr);
        }
        self.env.write(&format!("units/{unit}/drive-owned"), "1\n");
    }

    fn last_comment(&self) -> String {
        fs::read_to_string(self.env.stub.join("last-comment-body")).unwrap_or_default()
    }

    fn claude_runs(&self, unit: u64) -> usize {
        fs::read_dir(&self.rec)
            .expect("rec")
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().starts_with(&format!("argv.{unit}.")))
            .count()
    }
}

const GATE_PATH: [&str; 7] = [
    "claimed",
    "prepared",
    "implementing",
    "pr_open",
    "reviewing",
    "ci_wait",
    "gate",
];

#[test]
fn one_unit_goes_from_queued_to_done_with_post_merge_and_cleanup() {
    let c = case(&[1]);
    c.result(1, json!({"unit": 1, "outcome": "pr_open", "pr": 4701, "notes": []}));
    c.pr_view(1, 4701);
    c.canned("merge-gate", 0, &Case::clean());
    c.canned_n("merge-gate", 3, 0, &Case::merged());

    let (out, report) = c.drive(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        report,
        json!({"processed": [{"unit": 1, "state": "done"}], "stopped": null})
    );
    assert_eq!(c.state_of(1), "done");
    assert_eq!(c.claude_runs(1), 1);
    assert!(c.at("claim take --unit 1") < c.at("unit-prepare --unit 1"));
    assert!(c.at("merge-gate --unit 1 --pr 4701 --dry-run") < c.at("post-merge --unit 1 --pr 4701"));
    assert!(c.at("post-merge --unit 1 --pr 4701") < c.at("cleanup --unit 1 --pr 4701"));
    assert_eq!(c.count("retro --publish"), 1);
    assert!(c.env.gh_calls().iter().any(|l| l.starts_with("issue comment 50 ")));
    let comment = c.last_comment();
    assert!(comment.contains("unit U1 (#101) is done and merged"), "{comment}");
    assert!(comment.contains("pull/4701"), "{comment}");
    assert!(!comment.contains('\u{2014}'));
    // The merge commit went into the state log.
    assert_eq!(c.snapshot()["units"][0]["head"], MERGE_SHA);
}

#[test]
fn a_blocked_result_ends_the_unit_with_a_comment_and_a_claim_release() {
    let c = case(&[1]);
    c.result(
        1,
        json!({"unit": 1, "outcome": "blocked", "notes": ["the tests would not run"]}),
    );

    let (out, report) = c.drive(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(report["processed"], json!([{"unit": 1, "state": "blocked"}]));
    assert_eq!(c.state_of(1), "blocked");
    assert!(c.count("claim release --unit 1") == 1);
    assert_eq!(c.count("merge-gate"), 0);
    assert_eq!(c.count("cleanup"), 0, "a blocked unit keeps its worktree");
    let comment = c.last_comment();
    assert!(comment.contains("is blocked"), "{comment}");
    assert!(comment.contains("the tests would not run"), "{comment}");
}

#[test]
fn three_blocked_units_in_a_row_stop_the_drain_with_exit_3() {
    let c = case(&[1, 2, 3, 4]);
    for n in 1..=4 {
        c.result(n, json!({"unit": n, "outcome": "blocked", "notes": ["no"]}));
    }
    let (out, report) = c.drive(&[]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(
        report["stopped"].as_str().unwrap().contains("three units in a row"),
        "{report}"
    );
    assert_eq!(report["processed"].as_array().unwrap().len(), 3);
    assert_eq!(c.count("claim take"), 3);
    assert_eq!(c.state_of(4), "queued");
    assert_eq!(c.count("retro"), 0);
    let snap = c.snapshot();
    assert!(
        snap["stopped"]["reason"].as_str().unwrap().contains("three units"),
        "{snap}"
    );
    assert!(c.last_comment().contains("has stopped"));
}

#[test]
fn a_stop_file_stops_the_drain_before_the_next_claim() {
    let c = case(&[1]);
    c.env.write("STOP", "");
    let (out, report) = c.drive(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(report["stopped"].as_str().unwrap().contains("STOP file"), "{report}");
    assert_eq!(c.count("claim take"), 0);
    assert_eq!(c.state_of(1), "queued");
    assert!(c.snapshot()["stopped"].is_object());
    assert!(c.last_comment().contains("has stopped"));
}

#[test]
fn a_unit_left_in_implementing_with_a_result_carries_on_without_claude() {
    let c = case(&[1]);
    c.seed(1, &["claimed", "prepared", "implementing"], None);
    c.env.write(
        "units/1/result.json",
        &json!({"unit": 1, "outcome": "skipped", "notes": ["already fixed on develop"]}).to_string(),
    );
    let (out, report) = c.drive(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(report["processed"], json!([{"unit": 1, "state": "skipped"}]));
    assert_eq!(c.claude_runs(1), 0);
    assert_eq!(c.count("unit-run"), 0);
    assert_eq!(c.count("claim take"), 0, "a restart does not claim again");
    assert!(c.last_comment().contains("already fixed on develop"));
}

#[test]
fn a_unit_left_in_implementing_with_no_result_is_retried_one_tier_up_then_blocked() {
    let c = case(&[1]);
    c.seed(1, &["claimed", "prepared", "implementing"], None);
    let (out, report) = c.drive(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(report["processed"], json!([{"unit": 1, "state": "blocked"}]));
    // First run on haiku, one retry on sonnet, then the unit is blocked.
    assert_eq!(c.claude_runs(1), 2);
    let second = fs::read_to_string(c.rec.join("argv.1.2")).expect("the retry");
    assert!(second.contains("sonnet"), "{second}");
    assert!(second.contains("--resume"), "{second}");
    assert!(c.last_comment().contains("ended twice without writing result.json"));
}

#[test]
fn behind_base_calls_base_sync_and_returns_to_ci_wait() {
    let c = case(&[1]);
    c.seed(1, &GATE_PATH, Some(4701));
    c.canned("merge-gate", 0, &Case::clean());
    c.canned_n(
        "merge-gate",
        1,
        3,
        &Case::refused(&[("behind_base", "the PR branch is 3 commits behind develop")]),
    );
    c.canned_n("merge-gate", 3, 0, &Case::merged());
    c.canned(
        "base-sync",
        0,
        &json!({"unit": 1, "deliver_ok": true, "review_round_needed": false}).to_string(),
    );

    let (out, report) = c.drive(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(report["processed"], json!([{"unit": 1, "state": "done"}]));
    assert!(c.at("base-sync --unit 1 --pr 4701") < c.at("merge-gate --unit 1 --pr 4701 --dry-run"));
    assert_eq!(c.snapshot()["units"][0]["base_syncs"], 1);
}

#[test]
fn a_failed_check_repairs_the_unit_and_names_the_check() {
    let c = case(&[1]);
    c.seed(1, &GATE_PATH, Some(4701));
    c.env.write(
        "units/1/session.json",
        &json!({"session_id": "sess-1", "attempts": [{"attempt": 1, "model": "haiku"}]}).to_string(),
    );
    c.canned("merge-gate", 0, &Case::clean());
    c.canned_n(
        "merge-gate",
        1,
        3,
        &Case::refused(&[("check_failed", "check 'lint' is failure")]),
    );
    c.canned_n("merge-gate", 3, 0, &Case::merged());
    c.result(1, json!({"unit": 1, "outcome": "pr_open", "pr": 4701, "notes": []}));

    let (out, report) = c.drive(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(report["processed"], json!([{"unit": 1, "state": "done"}]));
    let argv = fs::read_to_string(c.rec.join("argv.1.1")).expect("the resume");
    assert!(argv.contains("--resume") && argv.contains("sess-1"), "{argv}");
    let prompt = fs::read_to_string(c.env.workdir.join("units/1/drive-prompt-1.md")).expect("the prompt");
    assert!(prompt.contains("lint"), "{prompt}");
    assert_eq!(c.snapshot()["units"][0]["repairs"], 1);
}

#[test]
fn a_held_pr_is_parked_and_keeps_its_worktree() {
    let c = case(&[1]);
    c.seed(1, &GATE_PATH, Some(4701));
    c.canned(
        "merge-gate",
        3,
        &Case::refused(&[("hold_label", "PR #4701 carries 'needs-human'")]),
    );
    let (out, report) = c.drive(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(report["processed"], json!([{"unit": 1, "state": "parked"}]));
    assert_eq!(c.count("base-sync"), 0);
    assert_eq!(c.count("cleanup"), 0);
    assert_eq!(c.count("claim release --unit 1"), 1);
    assert!(c.last_comment().contains("hold_label"));
}

#[test]
fn checks_that_never_finish_block_the_unit_as_an_infrastructure_failure() {
    let mut c = case(&[1]);
    c.env.set("ISSUE_DRAIN_DRIVE_CI_MAX_SECS", "0");
    c.seed(
        1,
        &["claimed", "prepared", "implementing", "pr_open", "reviewing", "ci_wait"],
        Some(4701),
    );
    c.canned(
        "merge-gate",
        3,
        &Case::refused(&[("required_check", "required check 'ci' is pending at the head")]),
    );
    let (out, report) = c.drive(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(report["processed"], json!([{"unit": 1, "state": "blocked"}]));
    assert!(
        c.last_comment().contains("an infrastructure failure"),
        "{}",
        c.last_comment()
    );
}

#[test]
fn once_carries_one_unit_and_runs_no_retro() {
    let c = case(&[1, 2]);
    c.result(1, json!({"unit": 1, "outcome": "skipped", "notes": ["done elsewhere"]}));
    c.result(2, json!({"unit": 2, "outcome": "skipped", "notes": ["done elsewhere"]}));
    let (out, report) = c.drive(&["--once"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(report["processed"], json!([{"unit": 1, "state": "skipped"}]));
    assert_eq!(c.state_of(2), "queued");
    assert_eq!(c.count("claim take"), 1);
    assert_eq!(c.count("retro"), 0);
}

#[test]
fn a_unit_process_may_not_drive() {
    let mut c = case(&[1]);
    c.env.set("ISSUE_DRAIN_MODE", "unit");
    let (out, _) = c.drive(&[]);
    assert_eq!(out.code, 3);
    assert!(out.stderr.contains("driver's job"), "{}", out.stderr);
    assert!(c.calls().is_empty());
}

#[test]
fn a_held_lock_refuses_and_a_dead_drivers_file_does_not() {
    let c = case(&[1]);
    let lock_dir = c.env.dir.path().join("home/.issue-drain/example__tidepool");
    fs::create_dir_all(&lock_dir).unwrap();
    let lock = lock_dir.join("drive.lock");
    fs::write(&lock, "4242\n").unwrap();
    let held = fs::OpenOptions::new().read(true).write(true).open(&lock).unwrap();
    held.try_lock().unwrap();
    let (out, _) = c.drive(&[]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("another driver (pid 4242)"), "{}", out.stderr);
    assert!(c.calls().is_empty(), "a refused driver does nothing");
    drop(held);

    c.env.write("STOP", "");
    let (out, _) = c.drive(&[]);
    assert_eq!(
        out.code, 0,
        "a file left by a driver that exited does not block: {}",
        out.stderr
    );
    let after = fs::OpenOptions::new().read(true).write(true).open(&lock).unwrap();
    after.try_lock().expect("the lock is released on exit");
    assert!(
        !fs::read_to_string(&lock).unwrap().contains("4242"),
        "the new driver wrote its own pid"
    );
}

#[test]
fn without_once_the_driver_wants_the_unattended_opt_in() {
    let mut c = case(&[1]);
    c.env.set("ISSUE_DRAIN_UNATTENDED_OK", "0");
    let (out, _) = c.drive(&[]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("ISSUE_DRAIN_UNATTENDED_OK=1"), "{}", out.stderr);
    assert!(c.calls().is_empty(), "a refused driver does nothing");

    c.result(1, json!({"unit": 1, "outcome": "skipped", "notes": ["done elsewhere"]}));
    let (out, report) = c.drive(&["--once"]);
    assert_eq!(out.code, 0, "--once needs no opt-in: {}", out.stderr);
    assert_eq!(report["processed"], json!([{"unit": 1, "state": "skipped"}]));
}

#[test]
fn a_live_child_of_an_earlier_driver_refuses_and_a_dead_ones_file_is_removed() {
    use std::os::unix::process::CommandExt;
    let c = case(&[1]);
    let lock_dir = c.env.dir.path().join("home/.issue-drain/example__tidepool");
    fs::create_dir_all(&lock_dir).unwrap();
    let pidfile = lock_dir.join("drive-child.pid");
    let mut child = std::process::Command::new("sleep")
        .arg("60")
        .process_group(0)
        .spawn()
        .unwrap();
    fs::write(&pidfile, format!("{}\n", child.id())).unwrap();
    let (out, _) = c.drive(&[]);
    child.kill().unwrap();
    child.wait().unwrap();
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(
        out.stderr.contains(&format!("process group {}", child.id())),
        "{}",
        out.stderr
    );
    assert!(c.calls().is_empty(), "a refused driver does nothing");

    c.env.write("STOP", "");
    let (out, _) = c.drive(&[]);
    assert_eq!(out.code, 0, "a dead child's file does not block: {}", out.stderr);
    assert!(!pidfile.exists(), "the stale file is removed");
}

#[test]
fn the_driver_tracks_its_running_child_and_clears_the_file_after() {
    let c = case(&[1]);
    // The fake claude records whether the pid file was there while it ran.
    c.result(1, json!({"unit": 1, "outcome": "skipped", "notes": ["x"]}));
    let (out, _) = c.drive(&["--once"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let pidfile = c
        .env
        .dir
        .path()
        .join("home/.issue-drain/example__tidepool/drive-child.pid");
    assert!(!pidfile.exists(), "no pid file is left once the child ends");
}

#[test]
fn a_tree_mismatch_writes_a_marker_that_stops_every_later_drive() {
    let c = case(&[1, 2]);
    c.seed(1, &GATE_PATH, Some(4701));
    c.canned("merge-gate", 0, &Case::merged());
    c.canned("post-merge", 0, &json!({"tree_match": false}).to_string());
    let (out, report) = c.drive(&[]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(
        report["stopped"].as_str().unwrap().contains("different tree"),
        "{report}"
    );
    assert_eq!(c.state_of(1), "done");
    let marker = c.env.workdir.join("units/1/drive-tree-mismatch");
    assert!(marker.exists());

    c.env.run(&["state", "resume"]);
    let before = c.calls().len();
    let (out, report) = c.drive(&[]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(
        report["stopped"]
            .as_str()
            .unwrap_or_default()
            .contains("drive-tree-mismatch")
            || out.stderr.contains("drive-tree-mismatch"),
        "{report} {}",
        out.stderr
    );
    let later: Vec<String> = c.calls().split_off(before);
    assert!(
        later
            .iter()
            .all(|l| l.starts_with("tracker parse") || l.starts_with("state show")),
        "only reads run while the marker is there: {later:?}"
    );
    assert_eq!(c.state_of(2), "queued");

    fs::remove_file(&marker).unwrap();
    c.result(2, json!({"unit": 2, "outcome": "skipped", "notes": ["x"]}));
    let (out, _) = c.drive(&["--once"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(c.state_of(2), "skipped");
}

#[test]
fn a_pr_still_in_the_merge_queue_stops_the_drive_and_stays_at_the_gate() {
    let mut c = case(&[1]);
    c.env.set("ISSUE_DRAIN_DRIVE_CI_MAX_SECS", "0");
    c.seed(1, &GATE_PATH, Some(4701));
    c.canned("merge-gate", 0, &Case::clean());
    c.canned_n(
        "merge-gate",
        2,
        4,
        &json!({"merged": false, "queued": true, "refusals": []}).to_string(),
    );
    let (out, report) = c.drive(&[]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(report["stopped"].as_str().unwrap().contains("merge queue"), "{report}");
    assert_eq!(c.state_of(1), "gate", "a queued PR is not parked");
    assert_eq!(c.count("claim release"), 0);
}

#[test]
fn a_claim_release_that_fails_leaves_the_unit_to_end_again() {
    let c = case(&[1]);
    c.result(1, json!({"unit": 1, "outcome": "blocked", "notes": ["no"]}));
    c.canned("claim-release", 1, "");
    let (out, _) = c.drive(&[]);
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert!(out.stderr.contains("claim release failed for unit 1"), "{}", out.stderr);
    assert!(!c.env.workdir.join("units/1/drive-ended.json").exists());
    assert!(c.last_comment().is_empty(), "no comment before the claim is gone");

    c.canned("claim-release", 3, "");
    let (out, _) = c.drive(&[]);
    assert_eq!(
        out.code, 0,
        "a claim that is not ours is logged, not fatal: {}",
        out.stderr
    );
    assert!(c.env.workdir.join("units/1/drive-ended.json").exists());
    assert!(c.last_comment().contains("is blocked"));
}

#[test]
fn a_refusal_that_needs_a_person_parks_a_unit_in_review() {
    let c = case(&[1]);
    c.seed(
        1,
        &["claimed", "prepared", "implementing", "pr_open", "reviewing"],
        Some(4701),
    );
    c.canned(
        "merge-gate",
        3,
        &Case::refused(&[
            ("review", "no review at the head"),
            ("risk_path", "touches firestore.rules"),
        ]),
    );
    let (out, report) = c.drive(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(report["processed"], json!([{"unit": 1, "state": "parked"}]));
    assert_eq!(c.claude_runs(1), 0, "no review pass for a unit a person must see");
    assert!(c.last_comment().contains("risk_path"), "{}", c.last_comment());
}

#[test]
fn the_review_cap_parks_a_unit_after_four_passes() {
    let c = case(&[1]);
    c.seed(
        1,
        &["claimed", "prepared", "implementing", "pr_open", "reviewing"],
        Some(4701),
    );
    c.env.write("units/1/drive-review-passes", "4\n");
    c.canned("merge-gate", 3, &Case::refused(&[("review", "verdict is NEEDS_WORK")]));
    let (out, report) = c.drive(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(report["processed"], json!([{"unit": 1, "state": "parked"}]));
    assert_eq!(c.claude_runs(1), 0);
    assert!(c.last_comment().contains("review cap reached"), "{}", c.last_comment());
}

#[test]
fn a_review_pass_whose_result_says_blocked_blocks_the_unit() {
    let c = case(&[1]);
    c.seed(
        1,
        &["claimed", "prepared", "implementing", "pr_open", "reviewing"],
        Some(4701),
    );
    c.env.write(
        "units/1/session.json",
        &json!({"session_id": "sess-1", "attempts": [{"attempt": 1, "model": "sonnet"}]}).to_string(),
    );
    c.canned("merge-gate", 3, &Case::refused(&[("review", "no review at the head")]));
    c.result(
        1,
        json!({"unit": 1, "outcome": "blocked", "notes": ["reviewers all down"]}),
    );
    let (out, report) = c.drive(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(report["processed"], json!([{"unit": 1, "state": "blocked"}]));
    let argv = fs::read_to_string(c.rec.join("argv.1.1")).expect("the review pass");
    assert!(
        argv.contains("--model") && argv.contains("sonnet"),
        "the last model is kept: {argv}"
    );
    assert!(c.last_comment().contains("reviewers all down"), "{}", c.last_comment());
    assert_eq!(
        fs::read_to_string(c.env.workdir.join("units/1/drive-review-passes"))
            .unwrap()
            .trim(),
        "1"
    );
}

#[test]
fn a_base_sync_that_github_has_not_applied_yet_is_tried_again() {
    let c = case(&[1]);
    c.seed(1, &GATE_PATH, Some(4701));
    c.canned("merge-gate", 0, &Case::clean());
    c.canned_n(
        "merge-gate",
        1,
        3,
        &Case::refused(&[("behind_base", "the PR branch is 3 commits behind develop")]),
    );
    c.canned_n("merge-gate", 3, 0, &Case::merged());
    c.canned_n("base-sync", 1, 1, "");
    c.canned(
        "base-sync",
        0,
        &json!({"unit": 1, "deliver_ok": true, "review_round_needed": false}).to_string(),
    );
    let (out, report) = c.drive(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(report["processed"], json!([{"unit": 1, "state": "done"}]));
    assert_eq!(c.count("base-sync"), 2);
}

#[test]
fn a_tracker_with_lines_the_run_never_offered_refuses_at_the_boundary() {
    let c = case(&[1]);
    let parsed = json!({"run": "run", "stop": false, "units": ["U1"], "approved_closures": [],
                        "release_claims": [], "tracker_state": "OPEN", "unknown": ["line 9: - [x] close #999"]});
    c.canned("tracker-parse", 1, &parsed.to_string());
    let (out, _) = c.drive(&["--once"]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("close #999"), "{}", out.stderr);
    assert_eq!(c.count("claim take"), 0);
}

#[test]
fn a_relative_profile_reaches_the_children_as_an_absolute_path() {
    let mut c = case(&[1]);
    c.env.set("ISSUE_DRAIN_PROFILE", "tidepool.toml");
    fs::write(
        c.fake.join("claim-take.sh"),
        "printf '%s' \"$ISSUE_DRAIN_PROFILE\" > \"$FAKE_DIR/profile.seen\"\n",
    )
    .expect("the hook");
    c.result(1, json!({"unit": 1, "outcome": "skipped", "notes": ["x"]}));
    // Started in the fixtures folder, where the relative name resolves; the
    // children run in the run folder, where it would not.
    let out = c.env.run_in(Some(&eval_fixtures()), &["drive", "--once"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let seen = fs::read_to_string(c.fake.join("profile.seen")).expect("the child ran");
    assert_eq!(PathBuf::from(seen), eval_fixtures().join("tidepool.toml"));
}

#[test]
fn a_dry_run_keeps_its_state_apart_and_starts_again_from_the_live_log() {
    let mut c = case(&[1]);
    let init = c.env.run(&[
        "state",
        "init",
        "--parsed",
        &c.env.workdir.join("parsed.json").display().to_string(),
    ]);
    assert_eq!(init.code, 0, "{}", init.stderr);
    c.env.set("ISSUE_DRAIN_DRY_RUN", "1");
    for round in 1..=2 {
        let (out, report) = c.drive(&["--once"]);
        assert_eq!(out.code, 0, "{}", out.stderr);
        assert_eq!(
            report["processed"],
            json!([{"unit": 1, "state": "claimed"}]),
            "{report}"
        );
        // Each dry run starts from the live log, so it claims again.
        assert_eq!(c.count("claim take --unit 1"), round);
    }
    let dry = fs::read_to_string(c.env.workdir.join("events.dry.jsonl")).expect("the dry log");
    assert!(dry.contains("\"to\":\"claimed\""), "{dry}");
    assert!(c.env.workdir.join("units/1/dry-drive-owned").exists());
    assert!(!c.env.workdir.join("units/1/drive-owned").exists());

    c.env.set("ISSUE_DRAIN_DRY_RUN", "0");
    assert_eq!(c.state_of(1), "queued", "the live state did not move");
    let live = fs::read_to_string(c.env.workdir.join("events.jsonl")).expect("the live log");
    assert!(!live.contains("\"to\":\"claimed\""), "{live}");
}

#[test]
fn auto_merge_left_armed_stops_the_drain_with_the_unit_at_the_gate() {
    let mut c = case(&[1]);
    c.env.set("ISSUE_DRAIN_DRIVE_CI_MAX_SECS", "0");
    c.seed(1, &GATE_PATH, Some(4701));
    c.canned("merge-gate", 0, &Case::clean());
    c.canned_n("merge-gate", 2, 1, &json!({"auto_merge_armed": true}).to_string());
    let (out, report) = c.drive(&[]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    let stopped = report["stopped"].as_str().unwrap_or_default();
    assert!(stopped.contains("--disable-auto"), "{report}");
    assert_eq!(c.state_of(1), "gate", "the unit is not parked");
    assert_eq!(c.count("claim release"), 0);
}

#[test]
fn a_pr_already_in_the_merge_queue_reads_as_ready_at_ci_wait() {
    let mut c = case(&[1]);
    c.env.set("ISSUE_DRAIN_DRIVE_CI_MAX_SECS", "0");
    c.seed(1, &GATE_PATH[..6], Some(4701));
    let queued = json!({"merged": false, "queued": true, "refusals": []}).to_string();
    c.canned_n("merge-gate", 1, 4, &queued);
    c.canned("merge-gate", 0, &Case::merged());
    let (out, _) = c.drive(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(c.state_of(1), "done");
}

#[test]
fn the_lock_is_one_per_repo_whatever_the_case_of_its_name() {
    let mut c = case(&[1]);
    let lock_dir = c.env.dir.path().join("home/.issue-drain/example__tidepool");
    fs::create_dir_all(&lock_dir).unwrap();
    let lock = lock_dir.join("drive.lock");
    fs::write(&lock, "4242\n").unwrap();
    let held = fs::OpenOptions::new().read(true).write(true).open(&lock).unwrap();
    held.try_lock().unwrap();
    c.env.set("ISSUE_DRAIN_REPO", "Example/Tidepool");
    let (out, _) = c.drive(&[]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("4242"), "{}", out.stderr);
}

#[test]
fn a_park_lost_to_a_restart_is_kept_from_the_saved_result() {
    let c = case(&[1]);
    c.seed(1, &GATE_PATH[..4], Some(4701));
    c.env.write(
        "units/1/result.json",
        &json!({"unit": 1, "outcome": "cap_reached", "pr": 4701, "notes": ["two findings open"]}).to_string(),
    );
    let (out, _) = c.drive(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(c.state_of(1), "parked");
    assert_eq!(c.count("merge-gate"), 0, "nothing asked the gate");
}

#[test]
fn an_unknown_merge_outcome_stops_the_drain_with_the_claim_kept() {
    let mut c = case(&[1]);
    c.env.set("ISSUE_DRAIN_DRIVE_CI_MAX_SECS", "0");
    c.seed(1, &GATE_PATH, Some(4701));
    c.canned("merge-gate", 0, &Case::clean());
    let unknown = json!({"merged": false, "state_unknown": true}).to_string();
    c.canned_n("merge-gate", 2, 1, &unknown);
    c.canned_n("merge-gate", 3, 1, &unknown);
    let (out, report) = c.drive(&[]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    let stopped = report["stopped"].as_str().unwrap_or_default();
    assert!(stopped.contains("did not say whether it merged"), "{report}");
    assert_eq!(c.state_of(1), "gate", "the unit is not parked");
    assert_eq!(c.count("claim release"), 0);
}

/// PR 4701 as GitHub shows it: `state`, its merge commit, and whether it sits
/// in the merge queue.
fn pr_now(c: &Case, state: &str, merge_commit: Option<&str>, queued: bool) {
    c.pr_view(1, 4701);
    let path = c.env.stub.join("pr-view-4701.json");
    let mut view: Value = fs::read_to_string(&path)
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_else(|| json!({}));
    view["state"] = json!(state);
    view["mergeCommit"] = merge_commit.map_or(Value::Null, |c| json!({"oid": c}));
    c.env.stub_file("pr-view-4701.json", &view.to_string());
    let answer = json!({"data": {"repository": {"pullRequest": {"isInMergeQueue": queued}}}});
    c.env.stub_file("merge-queue.json", &answer.to_string());
}

#[test]
fn a_refusal_after_an_unknown_merge_outcome_keeps_the_claim_while_the_pr_is_queued() {
    let mut c = case(&[1]);
    c.env.set("ISSUE_DRAIN_DRIVE_CI_MAX_SECS", "0");
    c.seed(1, &GATE_PATH, Some(4701));
    pr_now(&c, "OPEN", None, true);
    let unknown = json!({"merged": false, "state_unknown": true}).to_string();
    c.canned_n("merge-gate", 1, 1, &unknown);
    c.canned(
        "merge-gate",
        3,
        &Case::refused(&[("read_error", "checks could not be read")]),
    );
    // The first drive stops on the unknown outcome; the next one sees a refusal.
    let (out, _) = c.drive(&[]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    let (out, report) = c.drive(&[]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    let stopped = report["stopped"].as_str().unwrap_or_default();
    assert!(stopped.contains("is not settled"), "{report}");
    assert!(stopped.contains("still in the merge queue"), "{report}");
    assert_eq!(c.state_of(1), "gate", "the unit is not parked");
    assert_eq!(c.count("claim release"), 0);
}

#[test]
fn a_hold_label_on_a_queued_pr_does_not_park_the_unit() {
    let mut c = case(&[1]);
    c.env.set("ISSUE_DRAIN_DRIVE_CI_MAX_SECS", "0");
    c.seed(1, &GATE_PATH, Some(4701));
    c.env.write("units/1/drive-merge-asked", "a merge was asked for\n");
    pr_now(&c, "OPEN", None, true);
    c.canned(
        "merge-gate",
        3,
        &Case::refused(&[("needs_a_person", "label needs-human is on the PR")]),
    );
    let (out, _) = c.drive(&[]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(c.state_of(1), "gate");
    assert_eq!(c.count("claim release"), 0);
    assert!(
        c.env.workdir.join("units/1/drive-merge-asked").exists(),
        "the record stays"
    );
}

#[test]
fn a_refusal_on_a_pr_that_merged_meanwhile_takes_the_merged_path() {
    let c = case(&[1]);
    c.seed(1, &GATE_PATH, Some(4701));
    c.env.write("units/1/drive-merge-asked", "a merge was asked for\n");
    pr_now(&c, "MERGED", Some(&"c".repeat(40)), false);
    c.canned(
        "merge-gate",
        3,
        &Case::refused(&[("read_error", "checks could not be read")]),
    );
    let (out, _) = c.drive(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(c.state_of(1), "done");
}

#[test]
fn a_refusal_once_the_pr_left_the_queue_is_acted_on() {
    let mut c = case(&[1]);
    c.env.set("ISSUE_DRAIN_DRIVE_CI_MAX_SECS", "0");
    c.seed(1, &GATE_PATH, Some(4701));
    c.env.write("units/1/drive-merge-asked", "a merge was asked for\n");
    pr_now(&c, "OPEN", None, false);
    c.canned(
        "merge-gate",
        3,
        &Case::refused(&[("needs_a_person", "label needs-human is on the PR")]),
    );
    let (out, _) = c.drive(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(c.state_of(1), "parked");
    assert_eq!(c.count("claim release"), 1);
    assert!(
        !c.env.workdir.join("units/1/drive-merge-asked").exists(),
        "the record is gone"
    );
}

fn one_unit_case() -> Case {
    let c = case(&[1]);
    c.result(1, json!({"unit": 1, "outcome": "pr_open", "pr": 4701, "notes": []}));
    c.pr_view(1, 4701);
    c.canned("merge-gate", 0, &Case::clean());
    c.canned_n("merge-gate", 3, 0, &Case::merged());
    c
}

#[test]
fn progress_goes_to_stderr_and_stdout_stays_one_json_line() {
    let c = one_unit_case();
    let (out, report) = c.drive(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(out.stdout.trim().lines().count(), 1, "{}", out.stdout);
    assert_eq!(report["processed"], json!([{"unit": 1, "state": "done"}]));
    assert!(out.stderr.lines().all(|l| l.starts_with("drive: ")), "{}", out.stderr);
    assert!(out.stderr.contains("drive: U1 -> implementing"), "{}", out.stderr);
    assert!(
        out.stderr
            .lines()
            .any(|l| l.starts_with("drive: running unit-run --unit 1 (stdout drive/")
                && l.contains(".out, stderr drive/")
                && l.ends_with(".err)")),
        "{}",
        out.stderr
    );
    assert!(!out.stderr.contains("state show"), "{}", out.stderr);
    // The files the line names exist in the run folder.
    let named = out
        .stderr
        .lines()
        .find(|l| l.contains("running unit-run"))
        .and_then(|l| l.split("stdout ").nth(1))
        .and_then(|l| l.split(',').next())
        .expect("a stdout path")
        .to_string();
    assert!(c.env.workdir.join(named).exists());
}

#[test]
fn quiet_turns_the_progress_lines_off() {
    let c = one_unit_case();
    let (out, report) = c.drive(&["--quiet"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(out.stderr, "");
    assert_eq!(report["processed"], json!([{"unit": 1, "state": "done"}]));
}

#[test]
fn drive_pid_is_gone_after_a_normal_exit_and_named_while_running() {
    let c = one_unit_case();
    let (out, _) = c.drive(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(!c.env.workdir.join("drive.pid").exists());
    // The first line names the pid and the run folder.
    assert!(out.stderr.lines().next().unwrap_or_default().starts_with("drive: pid "));
}

fn repair_case(c: &Case) {
    c.seed(1, &GATE_PATH, Some(4701));
    c.env.write(
        "units/1/session.json",
        &json!({"session_id": "sess-1", "attempts": [{"attempt": 1, "model": "haiku"}]}).to_string(),
    );
    c.canned_n(
        "merge-gate",
        1,
        3,
        &Case::refused(&[("check_failed", "check 'lint' is failure")]),
    );
    c.canned("merge-gate", 0, &Case::clean());
}

#[test]
fn a_repair_that_wrote_no_new_result_does_not_reuse_the_old_one() {
    let c = case(&[1]);
    repair_case(&c);
    // The previous round's result is on disk; the fake claude writes none.
    c.env.write(
        "units/1/result.json",
        &json!({"unit": 1, "outcome": "pr_open", "pr": 4701, "notes": []}).to_string(),
    );
    let (out, report) = c.drive(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(report["processed"], json!([{"unit": 1, "state": "blocked"}]));
    assert_eq!(c.count("merge-gate"), 1, "no CI wait on an old result");
    assert!(c.last_comment().contains("new result.json"), "{}", c.last_comment());
}

#[test]
fn a_repair_whose_claude_exited_nonzero_is_a_failed_repair() {
    let c = case(&[1]);
    repair_case(&c);
    c.result(1, json!({"unit": 1, "outcome": "pr_open", "pr": 4701, "notes": []}));
    fs::write(c.rec.join("exit.1"), "1").unwrap();
    let (out, report) = c.drive(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(report["processed"], json!([{"unit": 1, "state": "blocked"}]));
    assert!(c.last_comment().contains("exited 1"), "{}", c.last_comment());
}

#[test]
fn a_review_pass_whose_claude_exited_nonzero_is_not_a_pass() {
    let c = case(&[1]);
    c.seed(
        1,
        &["claimed", "prepared", "implementing", "pr_open", "reviewing"],
        Some(4701),
    );
    c.env.write(
        "units/1/session.json",
        &json!({"session_id": "sess-1", "attempts": [{"attempt": 1, "model": "haiku"}]}).to_string(),
    );
    c.canned("merge-gate", 3, &Case::refused(&[("review", "no review at the head")]));
    c.result(1, json!({"unit": 1, "outcome": "pr_open", "pr": 4701, "notes": []}));
    fs::write(c.rec.join("exit.1"), "2").unwrap();
    let (_, report) = c.drive(&[]);
    assert_eq!(report["processed"], json!([{"unit": 1, "state": "blocked"}]));
    assert!(!c.env.workdir.join("units/1/drive-review-resumed").exists());
}

#[test]
fn a_pr_read_that_hangs_is_cut_off_and_blocks_the_unit_as_infrastructure() {
    let mut c = case(&[1]);
    c.env.set("ISSUE_DRAIN_GH_READ_TIMEOUT_SECS", "1");
    c.result(1, json!({"unit": 1, "outcome": "pr_open", "pr": 4701, "notes": []}));
    c.pr_view(1, 4701);
    c.env.stub_file("hang-pr-view", "");
    let started = std::time::Instant::now();
    let (out, report) = c.drive(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(
        started.elapsed() < std::time::Duration::from_secs(20),
        "the read was not cut off"
    );
    assert_eq!(report["processed"], json!([{"unit": 1, "state": "blocked"}]));
    let comment = c.last_comment();
    assert!(comment.contains("timed out"), "{comment}");
    assert!(comment.contains("infrastructure"), "{comment}");
}

#[test]
fn a_unit_with_a_sync_in_flight_finishes_it_before_the_gate_is_read() {
    let c = case(&[1]);
    c.seed(1, &GATE_PATH, Some(4701));
    c.env.write("units/1/base-sync-pending.json", "{\"pr\": 4701}\n");
    // The real base-sync removes the marker when it finishes.
    fs::write(
        c.fake.join("base-sync.sh"),
        "rm -f \"$ISSUE_DRAIN_WORKDIR/units/1/base-sync-pending.json\"\n",
    )
    .unwrap();
    c.canned(
        "base-sync",
        0,
        &json!({"unit": 1, "deliver_ok": true, "review_round_needed": false}).to_string(),
    );
    c.canned("merge-gate", 0, &Case::clean());
    c.canned_n("merge-gate", 2, 0, &Case::merged());
    let (out, report) = c.drive(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        report["processed"],
        json!([{"unit": 1, "state": "done"}]),
        "{}",
        c.last_comment()
    );
    assert_eq!(c.count("base-sync --unit 1 --pr 4701"), 1);
    assert!(c.at("base-sync --unit 1") < c.at("merge-gate --unit 1 --pr 4701"));
}
