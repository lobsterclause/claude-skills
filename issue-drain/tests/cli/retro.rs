//! `issue-drain retro`: seeded run folders, local files only. Three units: U1
//! done after a tier-up and a resume, U2 blocked with no session record, U3
//! parked.

use std::fs;

use serde_json::{Value, json};

use crate::common::*;

fn state_line(ts: &str, unit: u64, from: Option<&str>, to: &str, extra: Value) -> String {
    let mut line = json!({"ts": format!("2026-11-21T{ts}Z"), "unit": unit, "to": to});
    if let Some(from) = from {
        line["from"] = json!(from);
    }
    line.as_object_mut()
        .expect("an object")
        .extend(extra.as_object().expect("an object").clone());
    line.to_string()
}

fn named(ts: &str, event: &str, extra: Value) -> String {
    let mut line = json!({"ts": format!("2026-11-21T{ts}Z"), "event": event});
    line.as_object_mut()
        .expect("an object")
        .extend(extra.as_object().expect("an object").clone());
    line.to_string()
}

fn seed(env: &Env) {
    let merge = "c".repeat(40);
    let lines = [
        state_line("01:00:00", 1, None, "queued", json!({"issues": [101, 102]})),
        state_line("01:00:00", 2, None, "queued", json!({"issues": [103]})),
        state_line("01:00:00", 3, None, "queued", json!({"issues": [104]})),
        state_line("01:01:00", 1, Some("queued"), "claimed", json!({})),
        state_line("01:02:00", 1, Some("claimed"), "prepared", json!({})),
        state_line("01:03:00", 1, Some("prepared"), "implementing", json!({})),
        state_line("01:10:00", 1, Some("implementing"), "pr_open", json!({"pr": 7})),
        state_line("01:11:00", 1, Some("pr_open"), "reviewing", json!({})),
        state_line("01:15:00", 1, Some("reviewing"), "ci_wait", json!({})),
        state_line("01:16:00", 1, Some("ci_wait"), "gate", json!({})),
        named(
            "01:16:10",
            "merge_gate",
            json!({"unit": 1, "pr": 7, "merged": false, "refusals": ["not_mergeable", "review_author"]}),
        ),
        state_line("01:17:00", 1, Some("gate"), "ci_wait", json!({})),
        state_line("01:20:00", 1, Some("ci_wait"), "gate", json!({})),
        named(
            "01:20:10",
            "merge_gate",
            json!({"unit": 1, "pr": 7, "merged": false, "refusals": ["not_mergeable"]}),
        ),
        named(
            "01:22:00",
            "merge_gate",
            json!({"unit": 1, "pr": 7, "merged": true, "refusals": []}),
        ),
        state_line("01:23:00", 1, Some("gate"), "merged", json!({"head": merge})),
        state_line("01:25:00", 1, Some("merged"), "done", json!({})),
        state_line("01:05:00", 2, Some("queued"), "claimed", json!({})),
        state_line(
            "01:06:00",
            2,
            Some("claimed"),
            "blocked",
            json!({"note": "tests would not run"}),
        ),
        state_line("01:04:00", 3, Some("queued"), "claimed", json!({})),
        state_line("01:05:30", 3, Some("claimed"), "prepared", json!({})),
        state_line("01:06:30", 3, Some("prepared"), "implementing", json!({})),
        state_line("01:30:00", 3, Some("implementing"), "pr_open", json!({"pr": 9})),
        state_line("01:40:00", 3, Some("pr_open"), "parked", json!({})),
    ];
    env.write("events.jsonl", &(lines.join("\n") + "\n"));
    env.write(
        "queue.json",
        &json!({"units": [
            {"id": "U1", "size": "S", "kind": "bugfix"},
            {"id": "U2", "size": "M", "kind": "feature"},
            {"id": "U3", "size": "L", "kind": "feature"}
        ]})
        .to_string(),
    );
    env.write(
        "units/1/session.json",
        &json!({"session_id": "s1", "attempts": [
            {"attempt": 1, "resumed": false, "model": "haiku", "effort": "low", "cost_usd": 0.2, "num_turns": 9, "exit_code": 0},
            {"attempt": 2, "resumed": true, "model": "sonnet", "effort": "medium", "cost_usd": 0.3, "num_turns": 12, "exit_code": 0}
        ]})
        .to_string(),
    );
    env.write(
        "units/1/result.json",
        &json!({"unit": 1, "outcome": "pr_open", "pr": 7, "closes": [101, 102],
            "review": {"passes": 2, "verdict": "CLEAN"},
            "known_limits": ["the countdown does not handle negative durations"], "notes": []})
        .to_string(),
    );
    env.write(
        "units/1/deliver.json",
        &json!({"unit": 1, "ok": true, "additions": 10, "deletions": 2,
            "flags": {"new_dependency": false, "shortcuts": []}})
        .to_string(),
    );
    env.write(
        "units/3/session.json",
        &json!({"session_id": "s3", "attempts": [
            {"attempt": 1, "resumed": false, "model": "opus", "effort": "high", "num_turns": 30, "exit_code": 0}
        ]})
        .to_string(),
    );
    env.write(
        "units/3/result.json",
        &json!({"unit": 3, "outcome": "parked", "pr": 9, "closes": [],
            "review": {"passes": 1, "verdict": "NEEDS_DECISION"},
            "known_limits": [], "notes": ["shortcut: the retry count is fixed at 3"]})
        .to_string(),
    );
}

fn seeded() -> Env {
    let env = Env::new();
    seed(&env);
    env
}

fn tracker(env: &Env) {
    env.write(
        "tracker.json",
        &json!({"number": 12, "url": "https://example.invalid/12", "run": "run", "published_at": "2026-11-21T00:00:00Z"})
            .to_string(),
    );
}

fn md(env: &Env) -> String {
    fs::read_to_string(env.workdir.join("retro.md")).expect("retro.md")
}

fn row(md: &str, unit: &str) -> Vec<String> {
    let line = md
        .lines()
        .find(|l| l.starts_with(&format!("| {unit} |")))
        .unwrap_or_else(|| panic!("no row for {unit} in\n{md}"));
    line.trim_matches('|')
        .split(" | ")
        .map(|c| c.trim().to_string())
        .collect()
}

#[test]
fn the_table_has_one_row_per_unit() {
    let env = seeded();
    let out = env.run(&["retro"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let lines: Vec<&str> = out.stdout.lines().collect();
    assert_eq!(lines[0], env.workdir.join("retro.json").display().to_string());
    assert!(lines[1].starts_with("retro: 3 units"), "{}", out.stdout);
    let md = md(&env);

    // Columns: unit, issues, state, wall, cost, models, escalations, review,
    // gate refusals, base syncs, changed lines, known limits.
    let u1 = row(&md, "U1");
    assert_eq!(u1[1], "#101 #102");
    assert_eq!(u1[2], "done");
    assert_eq!(u1[3], "25m");
    assert_eq!(u1[4], "$0.50");
    assert_eq!(u1[5], "haiku/low, sonnet/medium");
    assert_eq!(u1[6], "2 (1 tier-up, 1 resume)");
    assert_eq!(u1[7], "2 pass(es), CLEAN");
    assert_eq!(u1[8], "not_mergeable x2, review_author x1");
    assert_eq!(u1[9], "1");
    assert_eq!(u1[10], "+10/-2");
    assert_eq!(u1[11], "1");

    let u3 = row(&md, "U3");
    assert_eq!(u3[2], "parked");
    assert_eq!(u3[3], "40m");
    assert_eq!(u3[4], "-", "no cost was reported, so none is guessed");
    assert_eq!(u3[5], "opus/high");
    assert_eq!(u3[7], "1 pass(es), NEEDS_DECISION");
    assert_eq!(u3[8], "-", "the gate never ran for it");

    assert!(!md.contains('\u{2014}'), "no em dashes");
}

#[test]
fn a_unit_with_no_session_record_shows_dashes() {
    let env = seeded();
    assert_eq!(env.run(&["retro"]).code, 0);
    let u2 = row(&md(&env), "U2");
    assert_eq!(u2[2], "blocked");
    assert_eq!(u2[3], "6m");
    for column in [4, 5, 6, 7, 8, 10, 11] {
        assert_eq!(u2[column], "-", "column {column} of {u2:?}");
    }
    let doc = json(&env.workdir.join("retro.json"));
    let unit = &doc["units"][1];
    assert_eq!(unit["unit"], 2);
    assert!(unit["cost_usd_estimate"].is_null());
    assert!(unit["models"].is_null());
    assert!(unit["escalations"].is_null());
}

#[test]
fn proposals_are_worded_as_proposals() {
    let env = seeded();
    assert_eq!(env.run(&["retro"]).code, 0);
    let doc = json(&env.workdir.join("retro.json"));
    assert_eq!(doc["totals"]["units"], 3);
    assert_eq!(doc["totals"]["by_state"], json!({"done": 1, "blocked": 1, "parked": 1}));
    assert_eq!(doc["totals"]["tier_ups"], 1);
    assert_eq!(doc["totals"]["resumes"], 1);
    assert_eq!(doc["totals"]["gate_refusals"], 3);
    assert_eq!(doc["totals"]["base_syncs"], 1);

    let routing = doc["proposals"]["routing"].as_array().expect("a list");
    assert_eq!(routing.len(), 1, "{routing:?}");
    let text = routing[0].as_str().expect("text");
    assert!(
        text.starts_with("Proposal: start S bugfix units one tier above haiku"),
        "{text}"
    );
    assert!(text.contains("U1") && text.contains("sonnet"), "{text}");

    let ups: Vec<&str> = doc["proposals"]["follow_ups"]
        .as_array()
        .expect("a list")
        .iter()
        .filter_map(Value::as_str)
        .collect();
    assert_eq!(ups.len(), 2, "{ups:?}");
    assert!(
        ups.iter().any(|l| l.contains("U1") && l.contains("negative durations")),
        "{ups:?}"
    );
    assert!(
        ups.iter()
            .any(|l| l.contains("U3") && l.contains("retry count is fixed")),
        "{ups:?}"
    );

    let md = md(&env);
    assert!(md.contains("These are proposals only"), "{md}");
    assert!(env.gh_calls().is_empty(), "a local retro reads no GitHub");
}

#[test]
fn a_first_try_on_the_cheapest_tier_is_a_keep_proposal() {
    let env = Env::new();
    let lines = [
        state_line("01:00:00", 1, None, "queued", json!({"issues": [101]})),
        state_line("01:01:00", 1, Some("queued"), "skipped", json!({})),
    ];
    env.write("events.jsonl", &(lines.join("\n") + "\n"));
    assert_eq!(env.run(&["retro"]).code, 0);
    let doc = json(&env.workdir.join("retro.json"));
    assert_eq!(doc["proposals"]["routing"], json!([]));
    assert_eq!(doc["units"][0]["state"], "skipped");
    assert!(md(&env).contains("No routing change is suggested"));

    // A done unit with one haiku attempt.
    let env = seeded();
    env.write(
        "units/1/session.json",
        &json!({"attempts": [{"attempt": 1, "resumed": false, "model": "haiku", "effort": "low", "cost_usd": 0.1}]})
            .to_string(),
    );
    assert_eq!(env.run(&["retro"]).code, 0);
    let doc = json(&env.workdir.join("retro.json"));
    let routing = doc["proposals"]["routing"].as_array().expect("a list");
    assert_eq!(routing.len(), 1);
    assert!(
        routing[0]
            .as_str()
            .expect("text")
            .starts_with("Proposal: keep S bugfix units on haiku"),
        "{routing:?}"
    );
}

#[test]
fn publish_posts_exactly_one_comment_on_the_tracker() {
    let env = seeded();
    tracker(&env);
    let out = env.run(&["retro", "--publish"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let comments: Vec<String> = env
        .gh_calls()
        .into_iter()
        .filter(|l| l.starts_with("issue comment"))
        .collect();
    assert_eq!(comments.len(), 1, "{comments:?}");
    assert!(comments[0].starts_with("issue comment 12 "), "{comments:?}");
    let body = fs::read_to_string(env.stub.join("last-comment-body")).expect("the comment body");
    assert_eq!(body, md(&env));
    assert!(body.starts_with("# Retro: run run"), "{body}");
    assert!(out.stdout.contains("posted to #12"), "{}", out.stdout);
    assert_eq!(env.events_named("retro").len(), 1);
}

#[test]
fn a_dry_run_publishes_nothing() {
    let mut env = seeded();
    tracker(&env);
    env.set("ISSUE_DRAIN_DRY_RUN", "1");
    let out = env.run(&["retro", "--publish"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stdout.contains("WOULD: gh issue comment 12"), "{}", out.stdout);
    assert!(env.gh_calls().is_empty(), "{:?}", env.gh_calls());
    assert!(
        env.workdir.join("retro.md").is_file(),
        "the local files are still written"
    );
}

#[test]
fn publish_needs_a_tracker_and_a_unit_process_is_refused() {
    let mut env = seeded();
    let out = env.run(&["retro", "--publish"]);
    assert_eq!(out.code, 2, "{}", out.stderr);
    assert!(out.stderr.contains("tracker.json"), "{}", out.stderr);
    assert!(!env.workdir.join("retro.md").exists());

    env.set("ISSUE_DRAIN_MODE", "unit");
    let out = env.run(&["retro"]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(!env.workdir.join("retro.md").exists());
}

#[test]
fn a_tier_up_is_a_step_up_the_ladder_between_attempts() {
    let env = seeded();
    // haiku, then sonnet (up), then a sonnet resume, then haiku (down), then opus (up).
    let attempt = |n: u32, model: &str, resumed: bool| json!({"attempt": n, "resumed": resumed, "model": model, "effort": "low", "cost_usd": 0.1});
    env.write(
        "units/1/session.json",
        &json!({"attempts": [
            attempt(1, "haiku", false),
            attempt(2, "sonnet", false),
            attempt(3, "sonnet", true),
            attempt(4, "haiku", true),
            attempt(5, "opus", true),
        ]})
        .to_string(),
    );
    assert_eq!(env.run(&["retro"]).code, 0);
    let doc = json(&env.workdir.join("retro.json"));
    assert_eq!(doc["units"][0]["escalations"]["tier_ups"], 2, "{doc}");
    assert_eq!(doc["units"][0]["escalations"]["resumes"], 3, "{doc}");
}
