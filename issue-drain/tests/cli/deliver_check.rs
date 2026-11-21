//! `issue-drain deliver-check`. Each test runs the binary in a copy of the
//! tidepool repo with a `unit` branch cut from `develop`; the happy path is
//! the control for every failure.

use std::fs;
use std::path::{Path, PathBuf};

use issue_drain::ctx::read_json;
use issue_drain::merge_gate::Deliver;
use serde_json::{Value, json};

use crate::common::*;

struct Case {
    env: Env,
    repo: PathBuf,
}

fn commit(repo: &Path, files: &[(&str, &str)], message: &str) {
    for (path, text) in files {
        let full = repo.join(path);
        fs::create_dir_all(full.parent().expect("a parent")).expect("the folder");
        fs::write(full, text).expect("the file");
    }
    git(repo, &["add", "-A"]);
    git(
        repo,
        &[
            "-c",
            "user.name=Test",
            "-c",
            "user.email=t@example.invalid",
            "commit",
            "-q",
            "-m",
            message,
        ],
    );
}

/// A repo whose `develop` holds a 300-line file, a `unit` branch cut from it,
/// and a queue whose unit U3 may change `src/timer/` and `package.json`.
fn case_with(unit: Value) -> Case {
    let env = Env::new();
    let repo = private_repo(env.dir.path());
    let big: String = (0..300).map(|i| format!("line {i}\n")).collect();
    commit(&repo, &[("src/timer/big.txt", &big)], "add a big file");
    git(&repo, &["checkout", "-q", "-b", "unit"]);
    let mut entry = json!({"id": "U3", "files": ["src/timer/", "package.json"]});
    entry.as_object_mut().unwrap().extend(unit.as_object().unwrap().clone());
    env.write("queue.json", &json!({"units": [entry]}).to_string());
    Case { env, repo }
}

fn case() -> Case {
    case_with(json!({}))
}

impl Case {
    fn check(&self, extra: &[&str]) -> Out {
        let mut args = vec!["deliver-check", "--unit", "3", "--base", "develop"];
        args.extend_from_slice(extra);
        self.env.run_in(Some(&self.repo), &args)
    }

    fn deliver(&self) -> Value {
        json(&self.env.workdir.join("units/3/deliver.json"))
    }

    fn failure_codes(&self) -> Vec<String> {
        self.deliver()["failures"]
            .as_array()
            .expect("failures")
            .iter()
            .map(|f| f["code"].as_str().expect("a code").to_string())
            .collect()
    }

    /// Commit `files` on the unit branch and expect a refusal with `code`.
    fn refuses(&self, files: &[(&str, &str)], code: &str) {
        commit(&self.repo, files, "change");
        let out = self.check(&[]);
        assert_eq!(out.code, 3, "{}", out.stderr);
        assert_eq!(self.deliver()["ok"], false);
        assert!(
            self.failure_codes().contains(&code.to_string()),
            "{:?}",
            self.failure_codes()
        );
    }
}

#[test]
fn a_diff_inside_scope_is_ok_and_names_the_head() {
    let c = case();
    commit(&c.repo, &[("src/timer/countdown.ts", "export const a = 1;\n")], "fix");
    let out = c.check(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let d = c.deliver();
    assert_eq!(d["ok"], true);
    assert_eq!(d["head"], git(&c.repo, &["rev-parse", "HEAD"]));
    assert_eq!(d["base"], git(&c.repo, &["rev-parse", "develop"]));
    assert_eq!(d["failures"], json!([]));
    assert_eq!(d["risk_paths_touched"], json!([]));
    assert_eq!(d["flags"], json!({"new_dependency": [], "shortcuts": []}));
    assert_eq!(
        (d["scope_checked"].clone(), d["acceptance_checked"].clone()),
        (json!(true), json!(false))
    );
    assert_eq!(c.env.events_named("deliver_check").len(), 1);
    assert_eq!(
        serde_json::from_str::<Value>(out.stdout.trim()).expect("JSON on stdout"),
        d
    );
}

#[test]
fn the_base_defaults_to_the_profile_branch_on_origin() {
    let c = case();
    commit(&c.repo, &[("src/timer/countdown.ts", "x\n")], "fix");
    let args = ["deliver-check", "--unit", "3"];
    let missing = c.env.run_in(Some(&c.repo), &args);
    assert_eq!(missing.code, 1, "no origin/develop yet: {}", missing.stderr);
    git(&c.repo, &["update-ref", "refs/remotes/origin/develop", "develop"]);
    let out = c.env.run_in(Some(&c.repo), &args);
    assert_eq!(out.code, 0, "{}", out.stderr);
}

#[test]
fn the_merge_base_the_diff_started_from_is_recorded() {
    let c = case();
    let fork = git(&c.repo, &["rev-parse", "develop"]);
    commit(&c.repo, &[("src/timer/a.ts", "a\n")], "first");
    let first = git(&c.repo, &["rev-parse", "HEAD"]);
    commit(&c.repo, &[("src/timer/b.ts", "b\n")], "second");
    assert_eq!(c.check(&[]).code, 0);
    assert_eq!(c.deliver()["merge_base"], fork, "the fork point, not the base's tip");

    // develop moves on: the diff is still taken from the fork point.
    git(&c.repo, &["checkout", "-q", "develop"]);
    commit(&c.repo, &[("docs/note.md", "n\n")], "develop moves");
    git(&c.repo, &["checkout", "-q", "unit"]);
    assert_eq!(c.check(&[]).code, 0);
    assert_eq!(c.deliver()["merge_base"], fork);

    // A --base that is part-way up the branch audits only part of the PR; the
    // report says where it started so the gate can see that.
    let part = c
        .env
        .run_in(Some(&c.repo), &["deliver-check", "--unit", "3", "--base", &first]);
    assert_eq!(part.code, 0, "{}", part.stderr);
    assert_eq!(c.deliver()["merge_base"], first);
    assert_ne!(c.deliver()["merge_base"], fork);
}

#[test]
fn a_risk_path_in_the_diff_is_recorded_and_the_check_still_passes() {
    // The fixture profile's risk_path_re matches `crisis` and `billing`. The
    // unit was planned without risk paths; a test file counts too.
    let c = case_with(json!({"files": ["src/timer/", "src/billing/"]}));
    commit(
        &c.repo,
        &[
            ("src/timer/countdown.ts", "x\n"),
            ("src/billing/charge.ts", "x\n"),
            ("tests/crisis.test.ts", "t\n"),
        ],
        "fix",
    );
    let out = c.check(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let d = c.deliver();
    assert_eq!(d["ok"], true);
    assert_eq!(
        d["risk_paths_touched"],
        json!(["src/billing/charge.ts", "tests/crisis.test.ts"])
    );
}

#[test]
fn an_empty_diff_is_refused() {
    let c = case();
    let out = c.check(&[]);
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert_eq!(c.failure_codes(), ["empty_diff"]);
}

#[test]
fn a_path_outside_the_unit_files_is_refused() {
    case().refuses(&[("src/ui/badge.ts", "x\n")], "out_of_scope");
}

#[test]
fn a_test_file_the_implementer_adds_is_in_scope_and_recorded() {
    let c = case_with(json!({"files": ["src/timer/countdown.ts"]}));
    commit(
        &c.repo,
        &[
            ("src/timer/countdown.ts", "x\n"),
            ("src/timer/countdown.test.ts", "t\n"),
            ("tests/timer.test.ts", "t\n"),
        ],
        "fix with tests",
    );
    let out = c.check(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        c.deliver()["test_paths"],
        json!(["src/timer/countdown.test.ts", "tests/timer.test.ts"])
    );
    // controls: a source file the unit does not own, and a test of another folder
    c.refuses(&[("src/timer/other.ts", "x\n")], "out_of_scope");
    c.refuses(&[("src/ui/badge.test.ts", "x\n")], "out_of_scope");
}

#[test]
fn a_test_file_under_a_frozen_or_protected_path_is_still_refused() {
    let c = case_with(json!({"files": ["vendor/x.js", ".github/workflows/ci.yml"]}));
    c.refuses(
        &[("vendor/x.test.js", "x\n"), (".github/workflows/ci.test.yml", "x\n")],
        "frozen_path",
    );
    assert_eq!(c.failure_codes(), ["protected_path", "frozen_path"]);
    assert_eq!(
        c.deliver()["test_paths"],
        json!([".github/workflows/ci.test.yml", "vendor/x.test.js"])
    );
}

#[test]
fn with_a_unit_json_the_check_runs_only_in_the_worktree_it_names() {
    let c = case();
    commit(&c.repo, &[("src/timer/countdown.ts", "x\n")], "fix");
    let worktree = c.repo.display().to_string();
    let unit_json = |worktree: Value| {
        c.env.write(
            "units/3/unit.json",
            &json!({"unit": 3, "worktree": worktree}).to_string(),
        )
    };
    let run_in = |dir: &Path| {
        c.env
            .run_in(Some(dir), &["deliver-check", "--unit", "3", "--base", "develop"])
    };

    // Another checkout, and a folder that is no checkout, are refused before git reads either.
    let other = c.env.dir.path().join("other");
    fs::create_dir_all(&other).expect("the folder");
    let plain = c.env.dir.path().join("plain");
    fs::create_dir_all(&plain).expect("the folder");
    git(&other, &["init", "-q"]);
    unit_json(json!(worktree));
    for dir in [&other, &plain] {
        let out = run_in(dir);
        assert_eq!(out.code, 2, "{}: {}", dir.display(), out.stderr);
        assert!(!c.env.workdir.join("units/3/deliver.json").exists());
    }
    // The worktree itself, and a folder inside it, are fine.
    assert_eq!(run_in(&c.repo).code, 0);
    assert_eq!(run_in(&c.repo.join("src/timer")).code, 0);

    // A unit.json that names no worktree refuses too; with none, `.` is used as before.
    unit_json(Value::Null);
    assert_eq!(run_in(&c.repo).code, 2);
    fs::remove_file(c.env.workdir.join("units/3/unit.json")).expect("remove");
    assert_eq!(run_in(&c.repo).code, 0);
}

#[test]
fn a_protected_path_is_refused() {
    case().refuses(&[(".github/workflows/ci.yml", "x\n")], "protected_path");
}

#[test]
fn a_frozen_path_is_refused() {
    case().refuses(&[("vendor/lib.js", "x\n")], "frozen_path");
}

#[test]
fn a_diff_that_mostly_deletes_is_refused() {
    let c = case();
    git(&c.repo, &["rm", "-q", "src/timer/big.txt"]);
    c.refuses(&[("src/timer/note.txt", "kept\n")], "net_destructive");
}

#[test]
fn a_named_acceptance_test_missing_from_the_diff_is_refused() {
    let c = case_with(json!({"acceptance_tests": ["tests/timer.test.ts"]}));
    c.refuses(&[("src/timer/countdown.ts", "x\n")], "acceptance_missing");
    assert_eq!(c.deliver()["acceptance_checked"], true);
}

#[test]
fn a_named_acceptance_test_in_the_diff_passes_even_outside_the_files() {
    let c = case_with(json!({"acceptance_tests": ["tests/timer.test.ts"]}));
    commit(
        &c.repo,
        &[("src/timer/countdown.ts", "x\n"), ("tests/timer.test.ts", "t\n")],
        "fix with a test",
    );
    let out = c.check(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(c.deliver()["acceptance_checked"], true);
}

#[test]
fn a_unit_with_no_files_skips_the_scope_check_and_says_so() {
    let c = case_with(json!({"files": []}));
    commit(&c.repo, &[("src/ui/badge.ts", "x\n")], "anywhere");
    let out = c.check(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(c.deliver()["scope_checked"], false);
}

#[test]
fn every_failure_is_listed() {
    let c = case();
    c.refuses(
        &[(".github/workflows/ci.yml", "x\n"), ("vendor/a.js", "x\n")],
        "protected_path",
    );
    assert_eq!(c.failure_codes(), ["out_of_scope", "protected_path", "frozen_path"]);
}

#[test]
fn an_added_dependency_is_flagged_without_failing() {
    let c = case();
    commit(
        &c.repo,
        &[("package.json", "{\"dependencies\":{\"left-pad\":\"1\"}}\n")],
        "dep",
    );
    let out = c.check(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(c.deliver()["ok"], true);
    assert_eq!(c.deliver()["flags"]["new_dependency"], json!(["package.json"]));
}

#[test]
fn an_added_shortcut_is_flagged_with_file_and_line() {
    let c = case();
    commit(
        &c.repo,
        &[("src/timer/countdown.ts", "a\nb\n// shortcut: hardcoded\n")],
        "quick",
    );
    let out = c.check(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        c.deliver()["flags"]["shortcuts"],
        json!([{"file": "src/timer/countdown.ts", "line": 3, "text": "// shortcut: hardcoded"}])
    );
}

#[test]
fn a_shortcut_marker_on_a_line_the_diff_did_not_add_is_not_flagged() {
    let c = case();
    commit(&c.repo, &[("src/timer/old.ts", "// shortcut: before\n")], "old");
    git(&c.repo, &["branch", "-f", "develop", "HEAD"]);
    commit(&c.repo, &[("src/timer/old.ts", "// shortcut: before\nmore\n")], "more");
    assert_eq!(c.check(&[]).code, 0);
    assert_eq!(c.deliver()["flags"]["shortcuts"], json!([]));
}

#[test]
fn a_ref_git_cannot_resolve_is_an_error_and_writes_nothing() {
    let c = case();
    let out = c.check(&["--head", "no-such-branch"]);
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert!(!c.env.workdir.join("units/3/deliver.json").exists());
}

#[test]
fn a_unit_the_queue_lacks_is_a_usage_error() {
    let c = case();
    let out = c
        .env
        .run_in(Some(&c.repo), &["deliver-check", "--unit", "9", "--base", "develop"]);
    assert_eq!(out.code, 2, "{}", out.stderr);
}

#[test]
fn merge_gate_reads_what_deliver_check_wrote() {
    let c = case();
    commit(&c.repo, &[("src/timer/countdown.ts", "x\n")], "fix");
    assert_eq!(c.check(&[]).code, 0);
    let read: Deliver = read_json(&c.env.workdir.join("units/3/deliver.json")).expect("merge-gate's shape");
    assert!(read.ok);
    assert_eq!(read.head, git(&c.repo, &["rev-parse", "HEAD"]));

    commit(&c.repo, &[("vendor/x.js", "x\n")], "frozen");
    assert_eq!(c.check(&[]).code, 3);
    let read: Deliver = read_json(&c.env.workdir.join("units/3/deliver.json")).expect("merge-gate's shape");
    assert!(!read.ok);
}
