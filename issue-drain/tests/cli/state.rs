//! CLI tests for `state`. Each refusal has a control beside it that passes.

use std::fs;

use crate::common::*;
use serde_json::{Value, json};

const SHA: &str = "0123456789abcdef0123456789abcdef01234567";

fn ready() -> Env {
    let env = Env::new();
    env.seed(&["queue.json"]);
    let out = env.run(&["state", "init"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    env
}

fn ev(env: &Env, args: &[&str]) -> Out {
    let mut full = vec!["state", "event"];
    full.extend_from_slice(args);
    env.run(&full)
}

fn ok(env: &Env, args: &[&str]) {
    let out = ev(env, args);
    assert_eq!(out.code, 0, "{args:?}: {}", out.stderr);
}

fn state_events(env: &Env) -> Vec<Value> {
    env.events().into_iter().filter(|e| e.get("to").is_some()).collect()
}

fn snapshot(env: &Env) -> Value {
    json(&env.workdir.join("state.json"))
}

fn unit_state(env: &Env, unit: u64) -> String {
    let snap = snapshot(env);
    let found = snap["units"]
        .as_array()
        .unwrap()
        .iter()
        .find(|u| u["unit"] == unit)
        .unwrap()
        .clone();
    found["state"].as_str().unwrap().to_string()
}

/// Walk a unit along the named states, giving the flags a move needs.
fn walk(env: &Env, unit: &str, path: &[&str]) {
    for to in path {
        match *to {
            "pr_open" => ok(env, &[unit, to, "--pr", "7"]),
            "merged" => ok(env, &[unit, to, "--head", SHA]),
            _ => ok(env, &[unit, to]),
        }
    }
}

const HAPPY: &[&str] = &[
    "claimed",
    "prepared",
    "implementing",
    "pr_open",
    "reviewing",
    "ci_wait",
    "gate",
    "merged",
    "done",
];

const TO_CI_WAIT: &[&str] = &["claimed", "prepared", "implementing", "pr_open", "reviewing", "ci_wait"];

#[test]
fn init_queues_every_unit_in_order() {
    let env = ready();
    let events = state_events(&env);
    assert_eq!(events.len(), 4);
    assert!(
        events
            .iter()
            .all(|e| e["to"] == "queued" && e["ts"] == "2026-11-21T03:53:00Z")
    );
    assert_eq!(events[0]["unit"], 1);
    assert_eq!(events[0]["issues"], json!([103, 106]));
    let snap = snapshot(&env);
    assert_eq!(snap["queue"], json!([1, 2, 3, 4]));
    assert_eq!(snap["stopped"], Value::Null);
    assert_eq!(snap["units"][1]["issues"], json!([104, 105]));
    assert_eq!(snap["units"][1]["state"], "queued");
}

#[test]
fn init_without_a_queue_is_a_usage_error() {
    let env = Env::new();
    let out = env.run(&["state", "init"]);
    assert_eq!(out.code, 2, "{}", out.stderr);
}

#[test]
fn init_twice_is_refused_and_writes_nothing() {
    let env = ready();
    let before = fs::read_to_string(env.workdir.join("events.jsonl")).unwrap();
    let out = env.run(&["state", "init"]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(fs::read_to_string(env.workdir.join("events.jsonl")).unwrap(), before);
}

#[test]
fn init_leaves_other_commands_lines_in_the_log_alone() {
    let env = Env::new();
    env.seed(&["queue.json"]);
    env.write(
        "events.jsonl",
        "{\"ts\":\"2026-11-21T00:00:00Z\",\"event\":\"intake\"}\n",
    );
    let out = env.run(&["state", "init"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let log = fs::read_to_string(env.workdir.join("events.jsonl")).unwrap();
    assert!(log.contains("\"event\":\"intake\""));
    ok(&env, &["1", "claimed"]);
    assert_eq!(env.run(&["state", "rebuild"]).code, 0);
}

/// What `tracker parse` prints, with `units` and whatever else a test changes.
fn parsed_json(units: Value, over: Value) -> String {
    let mut parsed = json!({
        "run": "run", "stop": false, "units": units, "approved_closures": [], "release_claims": [],
        "tracker_state": "OPEN", "unknown": []
    });
    parsed
        .as_object_mut()
        .unwrap()
        .extend(over.as_object().unwrap().clone());
    parsed.to_string()
}

/// `state init --parsed` on a saved parse, in a fresh run.
fn init_from(parsed: &str, dry_run: bool) -> (Env, Out) {
    let mut env = Env::new();
    env.seed(&["queue.json"]);
    if dry_run {
        env.set("ISSUE_DRAIN_DRY_RUN", "1");
    }
    let file = env.write("parsed.json", parsed);
    let out = env.run(&["state", "init", "--parsed", &file.display().to_string()]);
    (env, out)
}

#[test]
fn init_follows_the_order_of_a_saved_tracker_parse() {
    let (env, out) = init_from(&parsed_json(json!(["U3", "U1"]), json!({})), false);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(snapshot(&env)["queue"], json!([3, 1]));
    let (_, out) = init_from(&parsed_json(json!(["U9"]), json!({})), false);
    assert_eq!(out.code, 2, "{}", out.stderr);
}

#[test]
fn init_refuses_a_parse_where_the_user_called_the_run_off_or_something_is_unknown() {
    let refused = [
        (json!({"stop": true}), "STOP"),
        (json!({"tracker_state": "CLOSED"}), "CLOSED"),
        (json!({"tracker_state": null}), "tracker_state"),
        (json!({"unknown": ["unit U9", "line 12 is a code fence"]}), "unit U9"),
    ];
    for (over, word) in refused {
        let (env, out) = init_from(&parsed_json(json!(["U1"]), over.clone()), false);
        assert_eq!(out.code, 3, "{over}: {}", out.stderr);
        assert!(out.stderr.contains(word), "{over}: {}", out.stderr);
        assert!(!env.workdir.join("state.json").exists(), "{over}: nothing is queued");
        assert!(state_events(&env).is_empty(), "{over}");
    }
}

#[test]
fn init_refuses_the_saved_parse_of_another_run() {
    let (env, out) = init_from(&parsed_json(json!(["U1"]), json!({"run": "other-run"})), false);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("other-run"), "{}", out.stderr);
    assert!(state_events(&env).is_empty());
    // control: this run's own parse goes through
    let (_, out) = init_from(&parsed_json(json!(["U1"]), json!({"run": "run"})), false);
    assert_eq!(out.code, 0, "{}", out.stderr);
}

#[test]
fn init_takes_a_null_tracker_state_only_in_a_dry_run() {
    let parsed = parsed_json(json!(["U1"]), json!({"tracker_state": null}));
    let (_, out) = init_from(&parsed, true);
    assert_eq!(out.code, 0, "a dry run may parse a file: {}", out.stderr);
}

#[test]
fn init_refuses_a_parse_that_leaves_out_what_decides_whether_to_go_on() {
    for key in ["run", "stop", "tracker_state", "unknown"] {
        let mut parsed: Value = serde_json::from_str(&parsed_json(json!(["U1"]), json!({}))).unwrap();
        parsed.as_object_mut().unwrap().remove(key);
        let (_, out) = init_from(&parsed.to_string(), true);
        assert_eq!(out.code, 2, "{key}: {}", out.stderr);
    }
}

#[test]
fn a_unit_walks_the_happy_path_to_done() {
    let env = ready();
    walk(&env, "1", HAPPY);
    assert_eq!(unit_state(&env, 1), "done");
    let snap = snapshot(&env);
    assert_eq!(snap["units"][0]["pr"], 7);
    assert_eq!(snap["units"][0]["head"], SHA);
    assert_eq!(snap["units"][0]["base_syncs"], 0);
    assert_eq!(snap["units"][0]["repairs"], 0);
    assert_eq!(snap["units"][0]["updated"], "2026-11-21T03:53:00Z");
    let last = state_events(&env).pop().unwrap();
    assert_eq!(last["unit"], 1);
    assert_eq!(last["from"], "merged");
    assert_eq!(last["to"], "done");
    // other units are untouched
    assert_eq!(unit_state(&env, 2), "queued");
}

#[test]
fn an_event_carries_its_note() {
    let env = ready();
    ok(&env, &["1", "claimed", "--note", "picked up"]);
    let last = state_events(&env).pop().unwrap();
    assert_eq!(last["note"], "picked up");
    assert!(last.get("pr").is_none() && last.get("head").is_none());
}

#[test]
fn an_illegal_move_names_the_unit_the_state_and_the_target() {
    let env = ready();
    let out = ev(&env, &["1", "merged", "--head", SHA]);
    assert_eq!(out.code, 3);
    for needle in ["unit 1", "queued", "merged"] {
        assert!(out.stderr.contains(needle), "{}", out.stderr);
    }
    assert_eq!(unit_state(&env, 1), "queued");
    assert_eq!(state_events(&env).len(), 4);
    // control: the legal move works
    ok(&env, &["1", "claimed"]);
    // a terminal state has no way out
    ok(&env, &["1", "skipped"]);
    assert_eq!(ev(&env, &["1", "claimed"]).code, 3);
    // nothing moves into queued
    assert_eq!(ev(&env, &["2", "queued"]).code, 3);
}

#[test]
fn an_unknown_unit_is_refused() {
    let env = ready();
    let out = ev(&env, &["9", "claimed"]);
    assert_eq!(out.code, 3);
    assert!(out.stderr.contains("unit 9"), "{}", out.stderr);
}

#[test]
fn an_unknown_state_name_is_a_usage_error() {
    let env = ready();
    assert_eq!(ev(&env, &["1", "flying"]).code, 2);
    assert_eq!(ev(&env, &["1", "stop"]).code, 2);
}

#[test]
fn pr_open_needs_a_pr_and_merged_needs_a_head() {
    let env = ready();
    walk(&env, "1", &["claimed", "prepared", "implementing"]);
    let out = ev(&env, &["1", "pr_open"]);
    assert_eq!(out.code, 3);
    assert!(out.stderr.contains("--pr"), "{}", out.stderr);
    assert_eq!(unit_state(&env, 1), "implementing");
    ok(&env, &["1", "pr_open", "--pr", "7"]);
    walk(&env, "1", &["reviewing", "ci_wait", "gate"]);
    let out = ev(&env, &["1", "merged"]);
    assert_eq!(out.code, 3);
    assert!(out.stderr.contains("--head"), "{}", out.stderr);
    ok(&env, &["1", "merged", "--head", SHA]);
}

#[test]
fn a_fifth_base_sync_is_refused() {
    let env = ready();
    walk(&env, "1", TO_CI_WAIT);
    for _ in 0..4 {
        walk(&env, "1", &["gate", "ci_wait"]);
    }
    assert_eq!(snapshot(&env)["units"][0]["base_syncs"], 4);
    ok(&env, &["1", "gate"]);
    let out = ev(&env, &["1", "ci_wait"]);
    assert_eq!(out.code, 3);
    assert!(
        out.stderr.contains("gate") && out.stderr.contains("ci_wait"),
        "{}",
        out.stderr
    );
    // control: the gate can still park
    ok(&env, &["1", "parked"]);
}

/// references/unit.md step 1: a unit whose base already has the fix ends as
/// skipped, which it finds out after the worktree is prepared and while it works.
#[test]
fn a_prepared_or_implementing_unit_can_end_as_skipped() {
    let env = ready();
    walk(&env, "1", &["claimed", "prepared", "skipped"]);
    assert_eq!(unit_state(&env, 1), "skipped");
    walk(&env, "2", &["claimed", "prepared", "implementing", "skipped"]);
    assert_eq!(unit_state(&env, 2), "skipped");
    // a unit in review has a PR and may not skip: control that the table still refuses
    walk(
        &env,
        "3",
        &["claimed", "prepared", "implementing", "pr_open", "reviewing"],
    );
    assert_eq!(ev(&env, &["3", "skipped"]).code, 3);
}

#[test]
fn a_third_repair_is_refused_from_either_state() {
    let env = ready();
    walk(&env, "1", TO_CI_WAIT);
    walk(
        &env,
        "1",
        &["repairing", "ci_wait", "gate", "repairing", "reviewing", "ci_wait"],
    );
    assert_eq!(snapshot(&env)["units"][0]["repairs"], 2);
    let out = ev(&env, &["1", "repairing"]);
    assert_eq!(out.code, 3);
    assert!(out.stderr.contains("repairing"), "{}", out.stderr);
    ok(&env, &["1", "gate"]);
    assert_eq!(ev(&env, &["1", "repairing"]).code, 3);
}

#[test]
fn nothing_moves_after_a_stop_until_resume() {
    let env = ready();
    let out = env.run(&["state", "stop", "--reason", "tracker says STOP"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(snapshot(&env)["stopped"]["reason"], "tracker says STOP");
    assert_eq!(snapshot(&env)["stopped"]["ts"], "2026-11-21T03:53:00Z");
    let out = ev(&env, &["1", "claimed"]);
    assert_eq!(out.code, 3);
    assert!(out.stderr.contains("stopped"), "{}", out.stderr);
    assert_eq!(env.run(&["state", "next"]).code, 3);
    assert_eq!(env.run(&["state", "stop", "--reason", "again"]).code, 3);
    assert_eq!(env.run(&["state", "resume"]).code, 0);
    assert_eq!(snapshot(&env)["stopped"], Value::Null);
    ok(&env, &["1", "claimed"]);
    assert_eq!(env.run(&["state", "resume"]).code, 3);
    // the stop and the resume are in the log, with no unit
    let log = state_events(&env);
    assert!(
        log.iter()
            .any(|e| e["to"] == "stop" && e.get("unit").is_none() && e["note"] == "tracker says STOP")
    );
    assert!(log.iter().any(|e| e["to"] == "resume" && e.get("unit").is_none()));
}

#[test]
fn next_skips_terminal_units() {
    let env = ready();
    assert_eq!(env.run(&["state", "next"]).stdout.trim(), "1");
    ok(&env, &["1", "skipped"]);
    assert_eq!(env.run(&["state", "next"]).stdout.trim(), "2");
    walk(&env, "2", &["claimed", "blocked"]);
    walk(&env, "3", &["claimed", "prepared", "implementing", "pr_open", "parked"]);
    // unit 4 is the only one left, and a unit in flight is not terminal
    assert_eq!(env.run(&["state", "next"]).stdout.trim(), "4");
    walk(&env, "4", &["claimed"]);
    assert_eq!(env.run(&["state", "next"]).stdout.trim(), "4");
    ok(&env, &["4", "skipped"]);
    let out = env.run(&["state", "next"]);
    assert_eq!((out.code, out.stdout.as_str()), (0, ""));
}

#[test]
fn next_without_init_is_a_usage_error() {
    assert_eq!(Env::new().run(&["state", "next"]).code, 2);
}

#[test]
fn show_prints_a_table_or_the_snapshot() {
    let env = ready();
    walk(&env, "1", &["claimed", "prepared", "implementing", "pr_open"]);
    let table = env.run(&["state", "show"]);
    assert_eq!(table.code, 0, "{}", table.stderr);
    assert!(
        table.stdout.contains("pr_open") && table.stdout.contains("queued"),
        "{}",
        table.stdout
    );
    let out = env.run(&["state", "show", "--json"]);
    let printed: Value = serde_json::from_str(&out.stdout).expect("json");
    assert_eq!(printed, snapshot(&env));
}

#[test]
fn a_missing_or_stale_snapshot_never_changes_an_answer() {
    let env = ready();
    fs::remove_file(env.workdir.join("state.json")).unwrap();
    assert_eq!(env.run(&["state", "next"]).stdout.trim(), "1");
    ok(&env, &["1", "claimed"]);
    assert_eq!(unit_state(&env, 1), "claimed");
    fs::write(
        env.workdir.join("state.json"),
        "{\"queue\":[],\"stopped\":null,\"units\":[]}",
    )
    .unwrap();
    assert_eq!(env.run(&["state", "next"]).stdout.trim(), "1");
    ok(&env, &["1", "prepared"]);
    assert_eq!(unit_state(&env, 1), "prepared");
}

#[test]
fn rebuild_reproduces_the_snapshot_byte_for_byte() {
    let env = ready();
    walk(&env, "1", HAPPY);
    env.run(&["state", "stop", "--reason", "pause"]);
    let before = fs::read(env.workdir.join("state.json")).unwrap();
    fs::remove_file(env.workdir.join("state.json")).unwrap();
    let out = env.run(&["state", "rebuild"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(fs::read(env.workdir.join("state.json")).unwrap(), before);
}

#[test]
fn rebuild_names_a_corrupt_line() {
    let env = ready();
    let path = env.workdir.join("events.jsonl");
    let mut text = fs::read_to_string(&path).unwrap();
    text.push_str("this is not json\n");
    fs::write(&path, text).unwrap();
    let out = env.run(&["state", "rebuild"]);
    assert_eq!(out.code, 1);
    assert!(out.stderr.contains("line 5"), "{}", out.stderr);
    // every write command refuses too
    assert_eq!(ev(&env, &["1", "claimed"]).code, 1);
}

#[test]
fn rebuild_names_an_illegal_transition_in_the_log() {
    let env = ready();
    let path = env.workdir.join("events.jsonl");
    let mut text = fs::read_to_string(&path).unwrap();
    text.push_str(
        "{\"ts\":\"2026-11-21T03:53:00Z\",\"unit\":1,\"from\":\"queued\",\"to\":\"merged\",\"head\":\"a\"}\n",
    );
    fs::write(&path, text).unwrap();
    let out = env.run(&["state", "rebuild"]);
    assert_eq!(out.code, 1);
    assert!(out.stderr.contains("line 5"), "{}", out.stderr);
}

#[test]
fn rebuild_without_a_log_is_a_usage_error() {
    assert_eq!(Env::new().run(&["state", "rebuild"]).code, 2);
}

#[test]
fn a_head_that_is_not_a_commit_sha_is_a_usage_error() {
    let env = ready();
    let to_gate = [
        "claimed",
        "prepared",
        "implementing",
        "pr_open",
        "reviewing",
        "ci_wait",
        "gate",
    ];
    walk(&env, "1", &to_gate);
    for bad in [
        "abc",
        "not a sha",
        "--squash",
        "\u{e9}123456789abcdef0123456789abcdef0123456",
    ] {
        let out = ev(&env, &["1", "merged", "--head", bad]);
        assert_eq!(out.code, 2, "{bad}: {}", out.stderr);
    }
    assert_eq!(unit_state(&env, 1), "gate");
}

/// An old log can hold a head that is not ASCII; `show` must not cut it inside a character.
#[test]
fn show_cuts_a_stored_head_on_a_character_boundary() {
    let env = ready();
    let path = env.workdir.join("events.jsonl");
    let mut text = fs::read_to_string(&path).unwrap();
    for (from, to) in [("queued", "claimed"), ("claimed", "prepared"), ("prepared", "skipped")] {
        let head = if to == "skipped" {
            ",\"head\":\"abcdefgh\u{e9}\u{e9}\u{e9}\""
        } else {
            ""
        };
        text.push_str(&format!(
            "{{\"ts\":\"2026-11-21T03:53:00Z\",\"unit\":1,\"from\":\"{from}\",\"to\":\"{to}\"{head}}}\n"
        ));
    }
    fs::write(&path, text).unwrap();
    let out = env.run(&["state", "show"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stdout.contains("abcdefgh"), "{}", out.stdout);
}

#[test]
fn no_temporary_file_is_left_behind() {
    let env = ready();
    walk(&env, "1", HAPPY);
    env.run(&["state", "rebuild"]);
    let mut names: Vec<String> = fs::read_dir(&env.workdir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    assert_eq!(names, ["events.jsonl", "queue.json", "state.json"]);
}

fn record(env: &Env, args: &[&str]) -> Out {
    let mut full = vec!["state", "record"];
    full.extend_from_slice(args);
    env.run(&full)
}

#[test]
fn record_writes_a_unit_worked_by_hand_as_merged_with_its_reason() {
    let env = ready();
    let out = record(
        &env,
        &[
            "--unit",
            "1",
            "--state",
            "merged",
            "--pr",
            "41",
            "--reason",
            "merged by hand",
        ],
    );
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(unit_state(&env, 1), "merged");
    let last = state_events(&env).pop().unwrap();
    assert_eq!(last["note"], "merged by hand");
    assert_eq!(last["pr"], 41);
    // the log alone rebuilds the same state
    assert_eq!(env.run(&["state", "rebuild"]).code, 0);
    assert_eq!(unit_state(&env, 1), "merged");
    // control: the unit is the only one that moved
    assert_eq!(unit_state(&env, 2), "queued");
}

#[test]
fn record_parks_a_unit_and_needs_no_pr() {
    let env = ready();
    let out = record(&env, &["--unit", "1", "--state", "parked", "--reason", "split into #9"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(unit_state(&env, 1), "parked");
}

#[test]
fn record_refuses_other_states_and_a_merge_without_a_pr() {
    let env = ready();
    let out = record(&env, &["--unit", "1", "--state", "done", "--reason", "x"]);
    assert_eq!(out.code, 2, "{}", out.stderr);
    let out = record(&env, &["--unit", "1", "--state", "merged", "--reason", "x"]);
    assert_eq!(out.code, 2, "{}", out.stderr);
    assert_eq!(unit_state(&env, 1), "queued");
}

#[test]
fn record_refuses_a_finished_unit_an_unknown_unit_and_a_unit_process() {
    let env = ready();
    ok(&env, &["1", "skipped"]);
    let out = record(&env, &["--unit", "1", "--state", "parked", "--reason", "x"]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    let out = record(&env, &["--unit", "99", "--state", "parked", "--reason", "x"]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    let mut unit = Env::new();
    unit.seed(&["queue.json"]);
    assert_eq!(unit.run(&["state", "init"]).code, 0);
    unit.set("ISSUE_DRAIN_MODE", "unit");
    let out = record(&unit, &["--unit", "1", "--state", "parked", "--reason", "x"]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(snapshot(&unit)["units"][0]["state"], "queued");
}

#[test]
fn record_refuses_an_empty_reason() {
    let env = ready();
    let out = record(&env, &["--unit", "1", "--state", "parked", "--reason", "  "]);
    assert_eq!(out.code, 2, "{}", out.stderr);
}
