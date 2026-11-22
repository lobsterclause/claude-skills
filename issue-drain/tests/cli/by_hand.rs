//! `guards-marker --by-hand` and `scope widen`: the two things a person does
//! to a unit by hand. Both are refused in a unit process.

use serde_json::json;

use crate::common::*;

fn setup() -> Env {
    let env = Env::new();
    env.write("queue.json", &queue_with_unit(json!({})).to_string());
    env
}

#[test]
fn a_by_hand_marker_is_written_with_its_reason() {
    let env = setup();
    let marker = env.workdir.join("units/3/guards-marker");
    let out = env.run(&[
        "guards-marker",
        "--unit",
        "3",
        "--by-hand",
        "--reason",
        "mod did not load",
    ]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        std::fs::read_to_string(&marker).expect("the marker"),
        "2026-11-21T03:53:00Z by-hand mod did not load\n"
    );
    assert_eq!(env.events_named("guards_marker")[0]["reason"], "mod did not load");
}

#[test]
fn a_by_hand_marker_needs_the_flag_a_reason_and_a_unit_of_the_queue() {
    let env = setup();
    let marker = env.workdir.join("units/3/guards-marker");
    let cases: [&[&str]; 5] = [
        &["guards-marker", "--unit", "3", "--reason", "x"],
        &["guards-marker", "--unit", "3", "--by-hand"],
        &["guards-marker", "--unit", "3", "--by-hand", "--reason", "  "],
        &["guards-marker", "--unit", "3", "--by-hand", "--reason", "two\nlines"],
        &["guards-marker", "--unit", "9", "--by-hand", "--reason", "x"],
    ];
    for args in cases {
        assert_eq!(env.run(args).code, 2, "{args:?}");
    }
    assert!(!marker.exists());
}

#[test]
fn neither_command_runs_in_a_unit_process() {
    let mut env = setup();
    env.set("ISSUE_DRAIN_MODE", "unit");
    let before = std::fs::read_to_string(env.workdir.join("queue.json")).expect("the queue");
    let marker = ["guards-marker", "--unit", "3", "--by-hand", "--reason", "x"];
    let widen = ["scope", "widen", "--unit", "3", "--file", "src/a.ts", "--reason", "x"];
    for args in [&marker[..], &widen[..]] {
        let out = env.run(args);
        assert_eq!(out.code, 3, "{args:?}: {}", out.stderr);
    }
    assert!(!env.workdir.join("units/3/guards-marker").exists());
    assert_eq!(
        std::fs::read_to_string(env.workdir.join("queue.json")).expect("the queue"),
        before
    );
}

#[test]
fn scope_widen_adds_the_file_to_the_queue_and_the_units_copy_and_logs_why() {
    let env = setup();
    env.write(
        "units/3/unit.json",
        &json!({"unit": 3, "files": ["src/timer/countdown.ts"]}).to_string(),
    );
    let args = [
        "scope",
        "widen",
        "--unit",
        "3",
        "--file",
        "src/lib/format.ts",
        "--reason",
        "needs the helper",
    ];
    let out = env.run(&args);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let expect = json!(["src/timer/countdown.ts", "src/lib/format.ts"]);
    assert_eq!(json(&env.workdir.join("queue.json"))["units"][0]["files"], expect);
    assert_eq!(json(&env.workdir.join("units/3/unit.json"))["files"], expect);
    let logged = env.events_named("scope_widen");
    assert_eq!(logged[0]["file"], "src/lib/format.ts");
    assert_eq!(logged[0]["reason"], "needs the helper");
    // Again: nothing is added twice.
    assert_eq!(env.run(&args).code, 0);
    assert_eq!(json(&env.workdir.join("queue.json"))["units"][0]["files"], expect);
}

#[test]
fn scope_widen_refuses_a_protected_path_and_a_bad_path() {
    let env = setup();
    let before = std::fs::read_to_string(env.workdir.join("queue.json")).expect("the queue");
    let run =
        |file: &str, reason: &str| env.run(&["scope", "widen", "--unit", "3", "--file", file, "--reason", reason]);
    assert_eq!(run(".github/workflows/ci.yml", "x").code, 3);
    assert_eq!(run("../outside.ts", "x").code, 2);
    assert_eq!(run("src/a.ts", "").code, 2);
    assert_eq!(run("src/a.ts/", "x").code, 2);
    assert_eq!(
        std::fs::read_to_string(env.workdir.join("queue.json")).expect("the queue"),
        before
    );
    // Control: an ordinary path goes in.
    assert_eq!(run("src/a.ts", "x").code, 0);
}
