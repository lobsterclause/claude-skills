//! `issue-drain unit-prepare`. Each test runs the binary against a clone whose
//! origin is a bare repo, so "the fresh origin tip" is a real thing to fetch.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use issue_drain::profile::Profile;
use serde_json::{Value, json};

use crate::common::*;

const BRANCH: &str = "fix/3-zero-pad-the-countdown-seconds-with-form";

struct Case {
    env: Env,
    work: PathBuf,
    bare: PathBuf,
    checkout: PathBuf,
}

fn case(extra: &str) -> Case {
    case_with(extra, json!({}))
}

/// A work repo, a bare clone of it as `origin.git`, and a checkout of that
/// whose origin is the tidepool repo on github.com (rewritten to the bare
/// folder). `extra` is appended to the tidepool profile, with `{dir}` read as
/// the test's folder; `unit` overrides fields of queue unit U3.
fn case_with(extra: &str, unit: Value) -> Case {
    let mut env = Env::new();
    let dir = env.dir.path().to_path_buf();
    let work = private_repo(&dir);
    let bare = dir.join("origin.git");
    git(
        &dir,
        &[
            "clone",
            "-q",
            "--bare",
            &work.display().to_string(),
            &bare.display().to_string(),
        ],
    );
    let checkout = origin_clone(&dir, &bare);
    let profile = dir.join("profile.toml");
    let base = fs::read_to_string(eval_fixtures().join("tidepool.toml")).expect("the tidepool profile");
    let extra = extra.replace("{dir}", &dir.display().to_string());
    fs::write(&profile, format!("{base}\n{extra}\n")).expect("the profile");
    env.set("ISSUE_DRAIN_REPO_DIR", &checkout.display().to_string());
    env.set("ISSUE_DRAIN_PROFILE", &profile.display().to_string());
    env.write("queue.json", &queue_with_unit(unit).to_string());
    Case {
        env,
        work,
        bare,
        checkout,
    }
}

impl Case {
    fn prepare(&self) -> Out {
        self.env.run(&["unit-prepare", "--unit", "3"])
    }

    fn prepared(&self) -> Value {
        let out = self.prepare();
        assert_eq!(out.code, 0, "{}", out.stderr);
        serde_json::from_str(out.stdout.trim()).expect("JSON on stdout")
    }

    /// A new commit on origin's develop, which the checkout has not fetched.
    fn advance_origin(&self) -> String {
        fs::write(self.work.join("NEW.md"), "new\n").expect("the file");
        git(&self.work, &["add", "NEW.md"]);
        git(
            &self.work,
            &[
                "-c",
                "user.name=T",
                "-c",
                "user.email=t@example.invalid",
                "commit",
                "-q",
                "-m",
                "new",
            ],
        );
        git(&self.work, &["push", "-q", &self.bare.display().to_string(), "develop"]);
        git(&self.work, &["rev-parse", "HEAD"])
    }

    fn run_dir(&self) -> PathBuf {
        fs::canonicalize(&self.env.workdir).expect("the run folder exists")
    }

    fn worktree(&self) -> PathBuf {
        self.run_dir().join("worktrees/3")
    }

    fn unit_json(&self) -> Value {
        json(&self.run_dir().join("units/3/unit.json"))
    }

    fn script(&self, name: &str, text: &str) -> String {
        let path = self.env.dir.path().join(name);
        fs::write(&path, text).expect("the script");
        path.display().to_string()
    }

    fn path_with(&self, bins: &[&Path]) -> String {
        let mut parts: Vec<String> = bins.iter().map(|p| p.display().to_string()).collect();
        parts.push(manifest_dir().join("tests/stub").display().to_string());
        parts.push("/usr/bin:/bin".into());
        parts.join(":")
    }

    /// A folder holding an executable `codegraph` that runs `body`.
    fn fake_codegraph(&self, body: &str) -> PathBuf {
        let bin = self.env.dir.path().join("fakebin");
        fs::create_dir_all(&bin).expect("the folder");
        let file = bin.join("codegraph");
        fs::write(&file, format!("#!/bin/sh\n{body}\n")).expect("the stub");
        fs::set_permissions(&file, fs::Permissions::from_mode(0o755)).expect("the mode");
        bin
    }
}

#[test]
fn a_fresh_prepare_makes_the_worktree_at_the_origin_tip_on_a_new_branch() {
    let c = case("guard_protected_paths = [\".github/workflows\", \"infra\"]\n");
    let tip = c.advance_origin();
    c.env.seed(&["intake.json", "verdicts.checked.json"]);
    let printed = c.prepared();
    let (run, wt) = (c.run_dir(), c.worktree());
    let state = run.join("units/3");

    assert_eq!(printed["unit"], 3);
    assert_eq!(printed["reused"], false);
    assert_eq!(printed["worktree"], wt.display().to_string());
    assert_eq!(printed["branch"], BRANCH);
    assert_eq!(
        printed["guards_unit_file"],
        state.join("guards-unit.json").display().to_string()
    );
    assert_eq!(
        git(&wt, &["rev-parse", "HEAD"]),
        tip,
        "the tip origin has now, not the checkout's"
    );
    assert_eq!(git(&wt, &["rev-parse", "--abbrev-ref", "HEAD"]), BRANCH);
    assert_eq!(git(&wt, &["status", "--porcelain"]), "");

    let u = c.unit_json();
    let golden_intake = golden("intake.json");
    let trusted = |n: u64| {
        golden_intake["eligible"]
            .as_array()
            .expect("eligible")
            .iter()
            .find(|e| e["number"] == n)
            .map(|e| e["trusted_author"].clone())
            .expect("an eligible issue")
    };
    assert_eq!(u["unit"], 3);
    assert_eq!(u["id"], "U3");
    assert_eq!(u["repo"], REPO);
    assert_eq!(u["issues"], json!([103, 106]));
    assert_eq!(u["live"], json!([103]));
    assert_eq!(u["title"], "Zero-pad the countdown seconds with formatDuration");
    assert_eq!(u["task"], u["title"]);
    assert_eq!(u["kind"], "bugfix");
    assert_eq!(u["files"], json!(["src/timer/countdown.ts"]));
    assert_eq!(u["acceptance"]["103"], "countdownLabel(65000) returns \"1:05\".");
    assert_eq!(u["reuse"], json!(["src/lib/format.ts:2"]));
    assert_eq!(u["test_command"], "pnpm vitest run src/timer");
    assert_eq!(
        (u["model"].clone(), u["effort"].clone()),
        (json!("haiku"), json!("low"))
    );
    assert_eq!(u["base"], "develop");
    assert_eq!(u["base_sha"], tip);
    assert_eq!(u["branch"], BRANCH);
    assert_eq!(u["worktree"], wt.display().to_string());
    assert_eq!(u["state_dir"], state.display().to_string());
    assert_eq!(u["run_dir"], run.display().to_string());
    assert_eq!(u["codegraph"], "absent");
    assert_eq!(u["bootstrap"], "none");
    assert_eq!(u["trusted_authors"], json!({"103": trusted(103), "106": trusted(106)}));
    assert_eq!(u["frozen_paths"], json!(["vendor/"]));
    assert!(u["protected_path_re"].as_str().expect("a pattern").contains(".github"));

    // The guards file is exactly what the guards mod's parseUnit accepts.
    assert_eq!(
        json(&state.join("guards-unit.json")),
        json!({
            "unit": 3,
            "worktree": wt.display().to_string(),
            "branch": BRANCH,
            "state_dir": state.display().to_string(),
            "protected_paths": [".github/workflows", "infra"]
        })
    );
    assert_eq!(c.env.events_named("unit_prepared").len(), 1);
}

#[test]
fn the_task_of_each_issue_comes_from_the_checked_verdicts() {
    let c = case("");
    let mut checked = golden("verdicts.checked.json");
    for v in checked.as_array_mut().expect("verdicts") {
        if v["number"] == 103 {
            v["task"] = json!("Use formatDuration in countdownLabel.");
        }
    }
    c.env.write("verdicts.checked.json", &checked.to_string());
    c.prepared();
    assert_eq!(
        c.unit_json()["issue_tasks"],
        json!({
            "103": "Use formatDuration in countdownLabel.",
            "106": "Same fix as #103: zero-pad the seconds in countdownLabel."
        })
    );
}

#[test]
fn a_feature_unit_gets_a_feat_branch() {
    let c = case_with("", json!({"kind": "feature", "title": "Add a pause button"}));
    assert_eq!(c.prepared()["branch"], "feat/3-add-a-pause-button");
}

#[test]
fn a_branch_never_starts_with_agent_whatever_the_title_and_kind_say() {
    for (title, kind) in [
        ("agent/take over", "agent"),
        ("Agent: take over", "feature"),
        ("  ", "bugfix"),
        ("../../etc passwd; rm -rf", ""),
    ] {
        let c = case_with("", json!({"kind": kind, "title": title}));
        let branch = c.prepared()["branch"].as_str().expect("a branch").to_string();
        assert!(
            branch.starts_with("fix/3-") || branch.starts_with("feat/3-"),
            "{branch}"
        );
        assert!(
            branch
                .chars()
                .all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || "/-".contains(ch)),
            "{branch}"
        );
        assert!(!branch.contains("//") && !branch.ends_with('-'), "{branch}");
        assert!(!git(&c.checkout, &["check-ref-format", "--branch", &branch]).is_empty());
    }
}

#[test]
fn a_long_title_is_cut_to_forty_characters_of_slug() {
    let c = case_with("", json!({"title": "a".repeat(120)}));
    let branch = c.prepared()["branch"].as_str().expect("a branch").to_string();
    assert_eq!(branch, format!("fix/3-{}", "a".repeat(40)));
}

#[test]
fn a_rerun_reuses_a_clean_worktree_on_its_branch() {
    let c = case("");
    c.prepared();
    let wt = c.worktree();
    fs::write(wt.join("work.txt"), "work\n").expect("the file");
    git(&wt, &["add", "work.txt"]);
    git(
        &wt,
        &[
            "-c",
            "user.name=T",
            "-c",
            "user.email=t@example.invalid",
            "commit",
            "-q",
            "-m",
            "work",
        ],
    );
    let head = git(&wt, &["rev-parse", "HEAD"]);
    let first = c.unit_json();
    c.advance_origin(); // the base moved on; the unit's own work must stay put

    let again = c.prepared();
    assert_eq!(again["reused"], true);
    assert_eq!(again["worktree"], wt.display().to_string());
    assert_eq!(git(&wt, &["rev-parse", "HEAD"]), head);
    let u = c.unit_json();
    assert_eq!(u["branch"], first["branch"]);
    assert_eq!(u["base_sha"], first["base_sha"], "the commit the unit was cut from");
}

#[test]
fn a_dirty_worktree_is_not_reused() {
    let c = case("");
    c.prepared();
    fs::write(c.worktree().join("stray.txt"), "x\n").expect("the file");
    let out = c.prepare();
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("not clean"), "{}", out.stderr);
}

#[test]
fn a_worktree_on_another_branch_is_not_reused() {
    let c = case("");
    c.prepared();
    git(&c.worktree(), &["checkout", "-q", "-b", "other"]);
    let out = c.prepare();
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("other"), "{}", out.stderr);
}

#[test]
fn a_folder_that_is_not_a_worktree_of_this_repo_is_not_reused() {
    let c = case("");
    fs::create_dir_all(c.run_dir().join("worktrees/3")).expect("the folder");
    let out = c.prepare();
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("worktree"), "{}", out.stderr);
}

#[test]
fn a_branch_that_exists_without_its_worktree_is_refused() {
    let c = case("");
    git(&c.checkout, &["branch", BRANCH, "origin/develop"]);
    let out = c.prepare();
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains(BRANCH), "{}", out.stderr);
    assert!(!c.worktree().exists());
}

#[test]
fn a_checkout_of_another_repo_is_refused() {
    let mut c = case("");
    c.env.set("ISSUE_DRAIN_REPO", "example/other");
    let out = c.prepare();
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("origin"), "{}", out.stderr);
}

#[test]
fn a_fetch_that_fails_is_an_error() {
    let c = case("");
    fs::remove_dir_all(&c.bare).expect("the bare repo");
    let out = c.prepare();
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert!(!c.worktree().exists());
}

#[test]
fn a_missing_bootstrap_precondition_is_refused_before_anything_is_made() {
    let c = case("bootstrap_command = \"sh {dir}/bootstrap.sh {worktree}\"\nbootstrap_requires = [\"node_modules\"]\n");
    let script = c.script("bootstrap.sh", "echo \"$1\" > \"$0.arg\"\n");
    let out = c.prepare();
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("node_modules"), "{}", out.stderr);
    assert!(!c.worktree().exists());
    assert!(
        !Path::new(&format!("{script}.arg")).exists(),
        "the bootstrap did not run"
    );

    fs::create_dir_all(c.checkout.join("node_modules")).expect("the folder");
    assert_eq!(c.prepare().code, 0);
}

#[test]
fn the_bootstrap_runs_in_the_worktree_with_its_path_and_only_once() {
    let c = case("bootstrap_command = \"sh {dir}/bootstrap.sh {worktree}\"\n");
    let script = c.script("bootstrap.sh", "pwd > \"$0.cwd\"\necho \"$1\" > \"$0.arg\"\n");
    c.prepared();
    let arg = fs::read_to_string(format!("{script}.arg")).expect("the bootstrap ran");
    assert_eq!(arg.trim(), c.worktree().display().to_string());
    let cwd = fs::read_to_string(format!("{script}.cwd")).expect("the bootstrap ran");
    assert_eq!(fs::canonicalize(cwd.trim()).expect("a folder"), c.worktree());
    assert_eq!(c.unit_json()["bootstrap"], "ok");

    fs::remove_file(format!("{script}.arg")).expect("the marker");
    c.prepared();
    assert!(
        !Path::new(&format!("{script}.arg")).exists(),
        "a rerun does not bootstrap again"
    );
}

#[test]
fn a_failing_bootstrap_is_exit_1_with_the_tail_of_its_output() {
    let c = case("bootstrap_command = \"sh {dir}/fail.sh\"\n");
    c.script("fail.sh", "echo boom\necho kaboom >&2\nexit 4\n");
    let out = c.prepare();
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert!(
        out.stderr.contains("boom") && out.stderr.contains("kaboom"),
        "{}",
        out.stderr
    );
    assert!(!c.run_dir().join("units/3/unit.json").exists());
    // A rerun tries again: the failure was not remembered as a success.
    assert_eq!(c.prepare().code, 1);
}

#[test]
fn a_bootstrap_that_runs_too_long_is_killed_and_fails() {
    let c = case("bootstrap_command = \"sh {dir}/slow.sh\"\nbootstrap_timeout_secs = 1\n");
    c.script("slow.sh", "sleep 30\n");
    let started = Instant::now();
    let out = c.prepare();
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert!(out.stderr.contains("timed out"), "{}", out.stderr);
    assert!(started.elapsed() < Duration::from_secs(20));
}

#[test]
fn codegraph_is_initialised_in_the_worktree_when_the_profile_asks() {
    let mut c = case("codegraph_init = true\n");
    let seen = c.env.dir.path().join("codegraph.seen");
    let bin = c.fake_codegraph(&format!("echo \"$@\" > {0}\npwd >> {0}", seen.display()));
    let path = c.path_with(&[&bin]);
    c.env.set("PATH", &path);
    c.prepared();
    assert_eq!(c.unit_json()["codegraph"], "ready");
    let text = fs::read_to_string(&seen).expect("codegraph ran");
    let mut lines = text.lines();
    assert_eq!(lines.next(), Some("init -i"));
    assert_eq!(
        fs::canonicalize(lines.next().expect("a folder")).expect("a folder"),
        c.worktree()
    );
}

#[test]
fn a_codegraph_that_fails_or_is_missing_is_recorded_not_an_error() {
    let mut c = case("codegraph_init = true\n");
    let bin = c.fake_codegraph("exit 1");
    let path = c.path_with(&[&bin]);
    c.env.set("PATH", &path);
    c.prepared();
    assert_eq!(c.unit_json()["codegraph"], "failed");

    let mut c = case("codegraph_init = true\n");
    let path = c.path_with(&[]);
    c.env.set("PATH", &path);
    c.prepared();
    assert_eq!(c.unit_json()["codegraph"], "absent");
}

#[test]
fn codegraph_is_not_run_when_the_profile_does_not_ask() {
    let mut c = case("");
    let seen = c.env.dir.path().join("codegraph.seen");
    let bin = c.fake_codegraph(&format!("echo ran > {}", seen.display()));
    let path = c.path_with(&[&bin]);
    c.env.set("PATH", &path);
    c.prepared();
    assert_eq!(c.unit_json()["codegraph"], "absent");
    assert!(!seen.exists());
}

#[test]
fn a_codegraph_that_runs_too_long_is_killed_and_recorded_as_failed() {
    let mut c = case("codegraph_init = true\ncodegraph_timeout_secs = 1\n");
    let bin = c.fake_codegraph("sleep 30");
    let path = c.path_with(&[&bin]);
    c.env.set("PATH", &path);
    let started = Instant::now();
    c.prepared();
    assert_eq!(c.unit_json()["codegraph"], "failed");
    assert!(started.elapsed() < Duration::from_secs(20));
}

#[test]
fn a_unit_process_may_not_prepare_a_unit() {
    let mut c = case("");
    c.env.set("ISSUE_DRAIN_MODE", "unit");
    let out = c.prepare();
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("driver"), "{}", out.stderr);
    assert!(!c.run_dir().join("worktrees").exists());
}

#[test]
fn a_missing_unit_or_queue_is_a_usage_error() {
    let c = case("");
    let out = c.env.run(&["unit-prepare", "--unit", "9"]);
    assert_eq!(out.code, 2, "{}", out.stderr);
    assert!(out.stderr.contains("U9"), "{}", out.stderr);

    let c = case("");
    fs::remove_file(c.env.workdir.join("queue.json")).expect("the queue");
    let out = c.prepare();
    assert_eq!(out.code, 2, "{}", out.stderr);
}

#[test]
fn the_shipped_kma_profile_guards_what_its_protected_pattern_protects() {
    let skill = manifest_dir();
    let p = Profile::load(&skill.join("profiles/Not-Every-Mom__kindred-mama-ai.toml"), skill).expect("the profile");
    assert!(!p.guard_protected_paths.is_empty());
    for entry in &p.guard_protected_paths {
        assert!(
            p.is_protected(entry) || p.is_protected(&format!("{entry}/x")),
            "{entry} is guarded but not protected"
        );
    }
    for sample in [
        ".github/workflows/ci.yml",
        ".husky/pre-push",
        ".claude/verify.sh",
        "firestore.rules",
        "storage.rules",
        "infra/x.tf",
        "ci/x.go",
    ] {
        assert!(
            p.guard_protected_paths
                .iter()
                .any(|g| sample == g || sample.starts_with(&format!("{g}/"))),
            "{sample} is protected but not guarded"
        );
    }
    assert!(p.codegraph_init);
    assert_eq!(p.bootstrap_requires, ["node_modules"]);
    assert_eq!(p.bootstrap_command, ".claude/scripts/worktree-bootstrap.sh {worktree}");
    assert_eq!(p.full_verify_command, "pnpm verify");
    assert_eq!(p.stamp_command, "bash scripts/verify-stamp.sh write {tree}");
}

#[test]
fn a_prepare_with_no_state_starts_the_state_log() {
    let c = case("");
    assert!(!c.env.workdir.join("state.json").exists());
    c.prepared();
    let state = json(&c.env.workdir.join("state.json"));
    assert_eq!(state["queue"], json!([3]));
    assert_eq!(state["units"][0]["state"], "queued");
    let events = c.env.events();
    assert_eq!(events.len(), 2, "the queued event, then the unit's start: {events:?}");
    assert_eq!(events[0]["to"], "queued");
    assert_eq!(events[0]["unit"], 3);
    assert_eq!(events[1]["event"], "unit_prepared");
    // A second prepare finds the state and starts nothing new.
    c.prepared();
    assert_eq!(c.env.events().len(), 3);
    assert_eq!(c.env.events().iter().filter(|e| e["to"] == "queued").count(), 1);
}

#[test]
fn a_prepare_leaves_a_started_state_as_it_is() {
    let c = case("");
    assert_eq!(c.env.run(&["state", "init"]).code, 0);
    c.env.run(&["state", "event", "3", "claimed"]);
    let before = fs::read_to_string(c.env.workdir.join("events.jsonl")).expect("the log");
    c.prepared();
    let after = fs::read_to_string(c.env.workdir.join("events.jsonl")).expect("the log");
    assert!(after.starts_with(&before), "nothing earlier is rewritten");
    assert_eq!(
        after.lines().count(),
        before.lines().count() + 1,
        "only unit_prepared is new"
    );
    assert_eq!(json(&c.env.workdir.join("state.json"))["units"][0]["state"], "claimed");
}

fn two_unit_queue() -> Value {
    let mut queue = queue_with_unit(json!({}));
    let mut second = queue["units"][0].clone();
    second["id"] = json!("U4");
    second["issues"] = json!([104]);
    queue["units"].as_array_mut().expect("units").insert(0, second);
    queue
}

fn publish_tracker(c: &Case, body: &str) {
    c.env.write("queue.json", &two_unit_queue().to_string());
    c.env.write(
        "tracker.json",
        &json!({"number": 12, "url": "https://example.invalid/12", "run": "run", "published_at": "2026-11-21T00:00:00Z"})
            .to_string(),
    );
    c.env.stub_file(
        "issue-view-12.json",
        &json!({"body": body, "state": "OPEN"}).to_string(),
    );
}

#[test]
fn an_auto_started_state_follows_the_approved_tracker_not_the_queue() {
    let c = case("");
    // The person deleted U4's line and kept U3's ticked.
    publish_tracker(
        &c,
        "<!-- issue-drain:tracker v1 run=run -->\n- [x] U3 · Zero-pad the countdown\n",
    );
    c.prepared();
    let state = json(&c.env.workdir.join("state.json"));
    assert_eq!(state["queue"], json!([3]), "U4 stays out: {state}");
}

#[test]
fn an_auto_started_state_takes_the_trackers_order() {
    let c = case("");
    publish_tracker(
        &c,
        "<!-- issue-drain:tracker v1 run=run -->\n- [x] U3 · a\n- [x] U4 · b\n",
    );
    c.prepared();
    assert_eq!(json(&c.env.workdir.join("state.json"))["queue"], json!([3, 4]));
}

#[test]
fn an_unreadable_tracker_stops_the_auto_start_and_names_state_init_parsed() {
    let c = case("");
    publish_tracker(&c, "<!-- issue-drain:tracker v1 run=run -->\n- [x] U3 · a\n");
    c.env.stub_file("fail", "");
    let out = c.prepare();
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("state init --parsed"), "{}", out.stderr);
    assert!(!c.worktree().exists(), "nothing was made");
    assert!(!c.env.workdir.join("state.json").exists());
}

#[test]
fn a_tracker_with_a_stop_line_stops_the_auto_start() {
    let c = case("");
    publish_tracker(&c, "<!-- issue-drain:tracker v1 run=run -->\nSTOP\n- [x] U3 · a\n");
    let out = c.prepare();
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("STOP"), "{}", out.stderr);
}

#[test]
fn a_unit_the_approved_tracker_dropped_gets_no_branch_and_no_worktree() {
    let c = case("");
    // The person kept only U4; unit 3 was deleted from the tracker.
    publish_tracker(&c, "<!-- issue-drain:tracker v1 run=run -->\n- [x] U4 · b\n");
    let out = c.prepare();
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("unit 3"), "{}", out.stderr);
    assert!(!c.worktree().exists());
    assert_eq!(git(&c.checkout, &["branch", "--list", BRANCH]), "");
}

/// Puts an index in the main checkout for a unit to copy.
fn seed_main_index(c: &Case) {
    let dir = c.checkout.join(".codegraph");
    fs::create_dir_all(&dir).expect("the folder");
    fs::write(dir.join("codegraph.db"), "db").expect("the index");
    fs::write(dir.join("codegraph.db-wal"), "wal").expect("the log");
}

#[test]
fn a_main_checkout_index_is_copied_into_the_worktree_and_synced() {
    let mut c = case("codegraph_init = true\n");
    seed_main_index(&c);
    let seen = c.env.dir.path().join("codegraph.seen");
    let bin = c.fake_codegraph(&format!("echo \"$@\" >> {0}\npwd >> {0}", seen.display()));
    let path = c.path_with(&[&bin]);
    c.env.set("PATH", &path);
    c.prepared();
    assert_eq!(c.unit_json()["codegraph"], "ready");
    let text = fs::read_to_string(&seen).expect("codegraph ran");
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 2, "one call: {text}");
    assert_eq!(lines[0], "sync .");
    assert_eq!(fs::canonicalize(lines[1]).expect("a folder"), c.worktree());
    let copy = c.worktree().join(".codegraph");
    assert_eq!(fs::read_to_string(copy.join("codegraph.db")).expect("copied"), "db");
    assert_eq!(
        fs::read_to_string(copy.join("codegraph.db-wal")).expect("copied"),
        "wal"
    );
    assert!(!copy.join("codegraph.db-shm").exists());
    assert_eq!(
        fs::read_to_string(c.checkout.join(".codegraph/codegraph.db")).expect("left alone"),
        "db"
    );
}

#[test]
fn a_copied_index_that_will_not_sync_is_removed_and_built_fresh() {
    let mut c = case("codegraph_init = true\n");
    seed_main_index(&c);
    let seen = c.env.dir.path().join("codegraph.seen");
    let body = format!(
        "echo \"$@\" >> {0}\nif [ \"$1\" = sync ]; then exit 1; fi\nls .codegraph >> {0} 2>/dev/null || echo none >> {0}",
        seen.display()
    );
    let bin = c.fake_codegraph(&body);
    let path = c.path_with(&[&bin]);
    c.env.set("PATH", &path);
    c.prepared();
    assert_eq!(c.unit_json()["codegraph"], "ready");
    let text = fs::read_to_string(&seen).expect("codegraph ran");
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines, ["sync .", "init -i", "none"], "{text}");
}
