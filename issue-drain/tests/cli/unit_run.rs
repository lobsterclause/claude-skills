//! `issue-drain unit-run`. A fake `claude` first on PATH records how it was
//! started and prints stream-json; the real one is never run.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

use serde_json::{Value, json};

use crate::common::*;

const FAKE: &str = r#"#!/bin/sh
n=1
while [ -e "$FAKE_REC/argv.$n" ]; do n=$((n+1)); done
printf '%s\n' "$@" > "$FAKE_REC/argv.$n"
pwd -P > "$FAKE_REC/cwd.$n"
printf '%s\n%s\n%s\n%s\n' "$VERIFY_GATE_SKIP" "$CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS" "$ISSUE_DRAIN_MODE" "$ISSUE_DRAIN_UNIT_FILE" > "$FAKE_REC/env.$n"
[ -e "$FAKE_REC/sleep" ] && sleep "$(cat "$FAKE_REC/sleep")"
echo 'a line that is not json'
echo '{"type":"system","subtype":"init","session_id":"sess-1"}'
echo '{"type":"result","subtype":"success","session_id":"sess-1","total_cost_usd":0.25,"is_error":false,"num_turns":7}'
[ -e "$FAKE_REC/result" ] && cp "$FAKE_REC/result" "$FAKE_RESULT"
exit "$(cat "$FAKE_REC/exit" 2>/dev/null || echo 0)"
"#;

struct Case {
    env: Env,
    rec: PathBuf,
    worktree: PathBuf,
}

fn case(profile_extra: &str) -> Case {
    let mut env = Env::new();
    let dir = env.dir.path().to_path_buf();
    let bin = dir.join("fakebin");
    let rec = dir.join("rec");
    let worktree = dir.join("wt");
    for d in [&bin, &rec, &worktree] {
        fs::create_dir_all(d).expect("the folder");
    }
    let claude = bin.join("claude");
    fs::write(&claude, FAKE).expect("the fake");
    fs::set_permissions(&claude, fs::Permissions::from_mode(0o755)).expect("the mode");
    let path = format!(
        "{}:{}:/usr/bin:/bin",
        bin.display(),
        manifest_dir().join("tests/stub").display()
    );
    env.set("PATH", &path);
    env.set("FAKE_REC", &rec.display().to_string());
    let base = fs::read_to_string(eval_fixtures().join("tidepool.toml")).expect("the profile");
    let profile = dir.join("profile.toml");
    fs::write(&profile, format!("{base}\n{profile_extra}\n")).expect("the profile");
    env.set("ISSUE_DRAIN_PROFILE", &profile.display().to_string());
    env.write(
        "units/3/unit.json",
        &json!({"unit": 3, "worktree": worktree, "model": "haiku", "effort": "low", "branch": "fix/3"}).to_string(),
    );
    env.set(
        "FAKE_RESULT",
        &env.workdir.join("units/3/result.json").display().to_string(),
    );
    Case { env, rec, worktree }
}

impl Case {
    fn unit_dir(&self) -> PathBuf {
        self.env.workdir.join("units/3")
    }

    fn argv(&self, n: u32) -> Vec<String> {
        let text = fs::read_to_string(self.rec.join(format!("argv.{n}"))).expect("the fake ran");
        text.lines().map(str::to_string).collect()
    }

    fn calls(&self) -> usize {
        fs::read_dir(&self.rec)
            .expect("rec")
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().starts_with("argv."))
            .count()
    }

    fn start(&self) -> Value {
        let out = self.env.run(&["unit-run", "--unit", "3"]);
        assert_eq!(out.code, 0, "{}", out.stderr);
        serde_json::from_str(out.stdout.trim()).expect("JSON on stdout")
    }

    fn resume(&self, text: &str, extra: &[&str]) -> Out {
        let prompt = self.env.dir.path().join("prompt.txt");
        fs::write(&prompt, text).expect("the prompt");
        let mut args = vec!["unit-run", "--unit", "3", "--resume", "--prompt-file"];
        let prompt = prompt.display().to_string();
        args.push(&prompt);
        args.extend_from_slice(extra);
        self.env.run(&args)
    }
}

fn after<'a>(argv: &'a [String], flag: &str) -> &'a str {
    let i = argv
        .iter()
        .position(|a| a == flag)
        .unwrap_or_else(|| panic!("no {flag} in {argv:?}"));
    &argv[i + 1]
}

#[test]
fn a_new_run_starts_claude_in_the_worktree_with_the_unit_environment() {
    let c = case("");
    fs::write(c.rec.join("result"), "{\"status\":\"done\"}\n").unwrap();
    let out = c.start();

    let argv = c.argv(1);
    assert_eq!(argv[0], "-p");
    let run_id = "run";
    assert_eq!(
        argv[1],
        format!(
            "Run unit 3 of issue-drain run {run_id}. Read {}/references/unit.md and follow it. Your unit file is {}.",
            manifest_dir().display(),
            c.unit_dir().join("unit.json").display()
        )
    );
    assert_eq!(after(&argv, "--model"), "haiku");
    assert_eq!(after(&argv, "--effort"), "low");
    assert_eq!(after(&argv, "--permission-mode"), "acceptEdits");
    assert_eq!(after(&argv, "--permission-prompts"), "none");
    assert_eq!(after(&argv, "--output-format"), "stream-json");
    assert!(argv.contains(&"--verbose".to_string()) && !argv.contains(&"--resume".to_string()));
    assert_eq!(
        after(&argv, "--plugin-dir"),
        manifest_dir().join("guards").display().to_string()
    );
    let tools = argv.iter().position(|a| a == "--allowedTools").expect("tools");
    assert_eq!(&argv[tools + 1..tools + 4], ["Bash", "Read", "Edit"]);
    assert_eq!(argv[tools + 9], "mcp__codegraph__codegraph_explore");

    let cwd = fs::read_to_string(c.rec.join("cwd.1")).unwrap();
    assert_eq!(cwd.trim(), fs::canonicalize(&c.worktree).unwrap().display().to_string());
    let env = fs::read_to_string(c.rec.join("env.1")).unwrap();
    let env: Vec<&str> = env.lines().collect();
    assert_eq!(
        env,
        ["1", "0", "unit", &c.unit_dir().join("unit.json").display().to_string()]
    );

    assert_eq!(out["unit"], 3);
    assert_eq!(out["attempt"], 1);
    assert_eq!(out["session_id"], "sess-1");
    assert_eq!(out["resumed"], false);
    assert_eq!(
        (out["exit_code"].clone(), out["timed_out"].clone()),
        (json!(0), json!(false))
    );
    assert_eq!(out["cost_usd"], 0.25);
    assert_eq!(out["result"], json!({"status": "done"}));
    let transcript = fs::read_to_string(c.unit_dir().join("transcript-1.jsonl")).unwrap();
    assert!(transcript.contains("not json") && transcript.contains("sess-1"));
    let events = c.env.events_named("unit_run");
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["cost_usd"], 0.25);
    assert_eq!(events[0]["attempt"], 1);
}

#[test]
fn a_resume_names_the_session_and_sends_the_prompt_file() {
    let c = case("");
    c.start();
    let out = c.resume(
        "Fix the failing check: lint says no.",
        &["--model", "sonnet", "--effort", "medium"],
    );
    assert_eq!(out.code, 0, "{}", out.stderr);
    let argv = c.argv(2);
    assert_eq!(argv[..2], ["-p", "Fix the failing check: lint says no."]);
    assert_eq!(after(&argv, "--resume"), "sess-1");
    assert_eq!(after(&argv, "--model"), "sonnet");
    assert_eq!(after(&argv, "--effort"), "medium");
    assert_eq!(after(&argv, "--permission-mode"), "acceptEdits");
    let printed: Value = serde_json::from_str(out.stdout.trim()).unwrap();
    assert_eq!(
        (printed["attempt"].clone(), printed["resumed"].clone()),
        (json!(2), json!(true))
    );
    assert!(c.unit_dir().join("transcript-2.jsonl").is_file());
}

#[test]
fn session_json_collects_one_attempt_per_run_and_keeps_the_first_session() {
    let c = case("");
    c.start();
    fs::write(c.rec.join("exit"), "5\n").unwrap();
    assert_eq!(
        c.resume("again", &[]).code,
        0,
        "a nonzero exit of its own is still exit 0"
    );
    let session = json(&c.unit_dir().join("session.json"));
    assert_eq!(session["session_id"], "sess-1");
    let attempts = session["attempts"].as_array().unwrap();
    assert_eq!(attempts.len(), 2);
    assert_eq!(
        (attempts[0]["attempt"].clone(), attempts[0]["resumed"].clone()),
        (json!(1), json!(false))
    );
    assert_eq!(
        (attempts[1]["attempt"].clone(), attempts[1]["resumed"].clone()),
        (json!(2), json!(true))
    );
    assert_eq!(attempts[0]["exit_code"], 0);
    assert_eq!(attempts[1]["exit_code"], 5);
    for a in attempts {
        assert_eq!(a["model"], "haiku");
        assert_eq!(a["effort"], "low");
        assert_eq!(a["timed_out"], false);
        assert_eq!(a["cost_usd"], 0.25);
        assert_eq!(a["num_turns"], 7);
        assert_eq!(a["is_error"], false);
        assert_eq!(a["started"], "2026-11-21T03:53:00Z");
        assert!(a["ended"].is_string());
    }
}

#[test]
fn a_new_run_is_refused_when_the_unit_already_has_a_session() {
    let c = case("");
    c.start();
    let out = c.env.run(&["unit-run", "--unit", "3"]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(
        out.stderr.contains("sess-1") && out.stderr.contains("--resume"),
        "{}",
        out.stderr
    );
    assert_eq!(c.calls(), 1);
}

#[test]
fn a_resume_without_a_session_or_a_prompt_is_a_usage_error() {
    let c = case("");
    assert_eq!(c.resume("hello", &[]).code, 2, "no session yet");
    c.start();
    let out = c.env.run(&["unit-run", "--unit", "3", "--resume"]);
    assert_eq!(out.code, 2, "{}", out.stderr);
    assert!(out.stderr.contains("--prompt-file"), "{}", out.stderr);
    assert_eq!(c.calls(), 1);
}

#[test]
fn a_missing_unit_file_says_to_prepare_first() {
    let c = case("");
    fs::remove_file(c.unit_dir().join("unit.json")).unwrap();
    let out = c.env.run(&["unit-run", "--unit", "3"]);
    assert_eq!(out.code, 2);
    assert!(out.stderr.contains("unit-prepare"), "{}", out.stderr);
    assert_eq!(c.calls(), 0);
}

#[test]
fn a_model_or_effort_the_profile_does_not_allow_is_refused() {
    let c = case("allowed_models = [\"haiku\"]\n");
    let out = c.env.run(&["unit-run", "--unit", "3", "--model", "opus"]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("opus"), "{}", out.stderr);
    let out = c.env.run(&["unit-run", "--unit", "3", "--effort", "max"]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(c.calls(), 0);
    assert!(!c.unit_dir().join("session.json").exists());
}

#[test]
fn a_unit_process_may_not_start_another() {
    let mut c = case("");
    c.env.set("ISSUE_DRAIN_MODE", "unit");
    let out = c.env.run(&["unit-run", "--unit", "3"]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(c.calls(), 0);
}

#[test]
fn a_process_that_runs_too_long_is_killed_and_recorded_as_timed_out() {
    let c = case("unit_timeout_secs = 1\n");
    fs::write(c.rec.join("sleep"), "30").unwrap();
    let started = std::time::Instant::now();
    let out = c.start();
    assert!(started.elapsed() < std::time::Duration::from_secs(20));
    assert_eq!(out["timed_out"], true);
    assert!(out["exit_code"].is_null());
    let session = json(&c.unit_dir().join("session.json"));
    assert_eq!(session["attempts"][0]["timed_out"], true);
    assert_eq!(c.env.events_named("unit_run")[0]["timed_out"], true);
}

#[test]
fn a_dry_run_prints_the_command_and_changes_nothing() {
    let mut c = case("");
    c.env.set("ISSUE_DRAIN_DRY_RUN", "1");
    let out = c.env.run(&["unit-run", "--unit", "3"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stdout.starts_with("WOULD: claude -p "), "{}", out.stdout);
    assert!(out.stdout.contains("--permission-prompts none") && out.stdout.contains("--allowedTools Bash Read"));
    assert_eq!(c.calls(), 0);
    assert!(!c.unit_dir().join("session.json").exists());
    assert!(!c.unit_dir().join("transcript-1.jsonl").exists());
}

#[test]
fn a_command_that_cannot_start_exits_1() {
    let mut c = case("");
    c.env.set("PATH", "/usr/bin:/bin");
    let out = c.env.run(&["unit-run", "--unit", "3"]);
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert!(!c.unit_dir().join("session.json").exists());
}
