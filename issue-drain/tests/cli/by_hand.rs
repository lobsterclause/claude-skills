//! `guards-marker --by-hand` and `scope widen`: the two things a person does
//! to a unit by hand. Both are refused in a unit process.

use serde_json::json;

use crate::common::*;

fn setup() -> Env {
    let env = Env::new();
    env.write("queue.json", &queue_with_unit(json!({})).to_string());
    published(&env);
    env
}

/// What `tracker publish` leaves behind.
fn published(env: &Env) {
    env.write(
        "tracker.json",
        &json!({"number": 12, "url": "https://example.invalid/12", "run": "run", "published_at": "2026-11-21T00:00:00Z"})
            .to_string(),
    );
}

#[test]
fn scope_widen_waits_for_the_tracker_to_be_published() {
    let env = Env::new();
    env.write("queue.json", &queue_with_unit(json!({})).to_string());
    let args = ["scope", "widen", "--unit", "3", "--file", "src/a.ts", "--reason", "x"];
    let out = env.run(&args);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("publish"), "{}", out.stderr);
    published(&env);
    assert_eq!(env.run(&args).code, 0);
}

#[test]
fn scope_widen_does_not_bring_a_risk_path_into_an_ordinary_unit() {
    let env = setup();
    let run = |file: &str| env.run(&["scope", "widen", "--unit", "3", "--file", file, "--reason", "x"]);
    let out = run("src/crisis/keywords.ts");
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("risk path"), "{}", out.stderr);
    // A unit with a named reviewer and one issue may take it.
    env.write(
        "queue.json",
        &queue_with_unit(json!({"issues": [103], "risk": true, "waits": true, "waits_for": "gate"})).to_string(),
    );
    assert_eq!(run("src/crisis/keywords.ts").code, 0);
    // But not when it carries more than one issue.
    env.write(
        "queue.json",
        &queue_with_unit(json!({"risk": true, "waits": true, "waits_for": "gate"})).to_string(),
    );
    assert_eq!(run("src/crisis/other.ts").code, 3);
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

#[test]
fn scope_widen_changes_only_the_files_of_its_unit() {
    let env = Env::new();
    published(&env);
    let mut queue = queue_with_unit(json!({"acceptance_tests": ["src/timer/a.test.ts"]}));
    let mut second = queue["units"][0].clone();
    second["id"] = json!("U4");
    second["acceptance_tests"] = json!(["src/list/b.test.ts"]);
    second["extra_key"] = json!({"kept": true});
    queue["units"].as_array_mut().expect("units").push(second);
    env.write("queue.json", &queue.to_string());
    let out = env.run(&["scope", "widen", "--unit", "3", "--file", "src/a.ts", "--reason", "x"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let after = json(&env.workdir.join("queue.json"));
    queue["units"][0]["files"] = json!(["src/timer/countdown.ts", "src/a.ts"]);
    assert_eq!(after, queue);
}

#[test]
fn scope_widen_refuses_a_folder_without_a_slash_but_allows_a_file_not_there_yet() {
    let env = Env::new();
    published(&env);
    let sha = git(fixture_repo(), &["rev-parse", "develop"]);
    let mut queue = queue_with_unit(json!({}));
    queue["base_sha"] = json!(sha);
    env.write("queue.json", &queue.to_string());
    let run = |file: &str| env.run(&["scope", "widen", "--unit", "3", "--file", file, "--reason", "x"]);
    assert_eq!(run("src/timer").code, 3);
    assert_eq!(run("src/lib/format.ts").code, 0);
    assert_eq!(run("src/new/file.ts").code, 0);
}

#[test]
fn scope_widen_refuses_a_folder_that_exists_only_in_the_worktree() {
    let env = setup();
    let tree = private_repo(env.dir.path());
    std::fs::create_dir_all(tree.join("src/fresh")).expect("an uncommitted folder");
    std::fs::write(tree.join("src/fresh/a.ts"), "x").expect("a file");
    std::os::unix::fs::symlink(tree.join("src/timer"), tree.join("src/link")).expect("a symlink");
    env.write(
        "units/3/unit.json",
        &json!({"unit": 3, "worktree": tree.display().to_string(), "files": []}).to_string(),
    );
    let run = |file: &str| env.run(&["scope", "widen", "--unit", "3", "--file", file, "--reason", "x"]);
    assert_eq!(run("src/fresh").code, 3);
    assert_eq!(run("src/link").code, 3);
    assert_eq!(run("src/fresh/a.ts").code, 0, "a file in that folder is fine");
}
