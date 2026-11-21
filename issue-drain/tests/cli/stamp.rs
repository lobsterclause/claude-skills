//! `issue-drain stamp-remote-pass`. The unit worktree is a copy of the
//! tidepool repo; the log is written the way `remote-verify.sh` writes it,
//! plus the `cmd=` line the command asks for (see src/stamp.rs).

use std::fs;
use std::path::{Path, PathBuf};

use serde_json::json;

use crate::common::*;

struct Case {
    env: Env,
    wt: PathBuf,
    head: String,
    tree: String,
    /// The stamp command appends the tree it was given here.
    stamped: PathBuf,
}

const GOOD_LOG: &str = "host=firebird head={head} dirty=0\ncmd=pnpm verify\nshipped head={head} dirty=0 unshipped=0\nsome verify output\nverify passed\nremote rc=0\nverify exit=0\n";

fn case_with(extra: &str) -> Case {
    let mut env = Env::new();
    let dir = env.dir.path().to_path_buf();
    let wt = private_repo(&dir);
    let stamped = dir.join("stamped.txt");
    let script = dir.join("stamp.sh");
    fs::write(&script, format!("echo \"$1\" >> {}\n", stamped.display())).expect("the script");
    let base = fs::read_to_string(eval_fixtures().join("tidepool.toml")).expect("the tidepool profile");
    let extra = extra
        .replace("{dir}", &dir.display().to_string())
        .replace("{script}", &script.display().to_string());
    let profile = dir.join("profile.toml");
    fs::write(&profile, format!("{base}\n{extra}\n")).expect("the profile");
    env.set("ISSUE_DRAIN_PROFILE", &profile.display().to_string());
    let head = git(&wt, &["rev-parse", "HEAD"]);
    let tree = git(&wt, &["rev-parse", "HEAD^{tree}"]);
    env.write(
        "units/3/unit.json",
        &json!({"unit": 3, "worktree": wt.display().to_string()}).to_string(),
    );
    Case {
        env,
        wt,
        head,
        tree,
        stamped,
    }
}

fn case() -> Case {
    case_with("full_verify_command = \"pnpm verify\"\nstamp_command = \"sh {script} {tree}\"\n")
}

impl Case {
    fn log(&self, text: &str) -> PathBuf {
        let text = text.replace("{head}", &self.head);
        let path = self.env.dir.path().join("rverify-x.log");
        fs::write(&path, text).expect("the log");
        path
    }

    fn stamp(&self, log: &Path, head: &str) -> Out {
        self.env.run(&[
            "stamp-remote-pass",
            "--unit",
            "3",
            "--log",
            &log.display().to_string(),
            "--head",
            head,
        ])
    }

    fn stamp_file(&self) -> PathBuf {
        self.env.workdir.join("units/3/stamp.json")
    }

    /// Exit 3, the failing condition named, nothing stamped, nothing written.
    fn refused(&self, out: &Out, named: &str) {
        assert_eq!(out.code, 3, "{}", out.stderr);
        assert!(out.stderr.contains(named), "wanted '{named}' in: {}", out.stderr);
        assert!(!self.stamped.exists(), "the stamp command ran");
        assert!(!self.stamp_file().exists(), "stamp.json was written");
    }
}

#[test]
fn a_full_verify_that_passed_at_the_head_is_stamped() {
    let c = case();
    let out = c.stamp(&c.log(GOOD_LOG), &c.head.clone());
    assert_eq!(out.code, 0, "{}", out.stderr);
    let want = json!({"head": c.head, "tree": c.tree, "stamped": true, "reason": "stamp command exited 0"});
    assert_eq!(json(&c.stamp_file()), want);
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(out.stdout.trim()).expect("JSON on stdout"),
        want
    );
    assert_eq!(
        fs::read_to_string(&c.stamped).expect("the stamp command ran").trim(),
        c.tree
    );
    assert_eq!(c.env.events_named("stamp_remote_pass").len(), 1);
}

#[test]
fn the_exit_line_may_be_in_the_out_file_beside_the_log() {
    let c = case();
    let log = c.log(
        "host=firebird head={head} dirty=0\ncmd=pnpm verify\nshipped head={head} dirty=0 unshipped=0\nverify output\n",
    );
    let out = c.stamp(&log, &c.head.clone());
    c.refused(&out, "verify exit");
    fs::write(c.env.dir.path().join("rv-x.out"), "verify exit=0\n").expect("the out file");
    let out = c.stamp(&log, &c.head.clone());
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(json(&c.stamp_file())["stamped"], true);
}

#[test]
fn a_dirty_remote_tree_is_refused() {
    let c = case();
    let out = c.stamp(&c.log(&GOOD_LOG.replace("dirty=0", "dirty=1")), &c.head.clone());
    c.refused(&out, "dirty");
}

#[test]
fn a_log_without_the_shipped_line_is_refused() {
    let c = case();
    let out = c.stamp(
        &c.log(&GOOD_LOG.replacen("shipped head={head} dirty=0 unshipped=0\n", "", 1)),
        &c.head.clone(),
    );
    c.refused(&out, "shipped");
    assert!(!c.stamp_file().exists());
}

#[test]
fn a_shipped_line_for_another_head_or_a_dirty_copy_is_refused() {
    let c = case();
    let other = "a".repeat(40);
    let out = c.stamp(
        &c.log(&GOOD_LOG.replacen("shipped head={head}", &format!("shipped head={other}"), 1)),
        &c.head.clone(),
    );
    c.refused(&out, "shipped at head");
    let out = c.stamp(
        &c.log(&GOOD_LOG.replacen(
            "shipped head={head} dirty=0 unshipped=0",
            "shipped head={head} dirty=1 unshipped=0",
            1,
        )),
        &c.head.clone(),
    );
    c.refused(&out, "dirty when it was shipped");
}

#[test]
fn a_shipped_line_with_unshipped_submodules_or_without_the_field_is_refused() {
    let c = case();
    let out = c.stamp(
        &c.log(&GOOD_LOG.replacen("unshipped=0", "unshipped=1", 1)),
        &c.head.clone(),
    );
    c.refused(&out, "never reached the box");
    let out = c.stamp(&c.log(&GOOD_LOG.replacen(" unshipped=0", "", 1)), &c.head.clone());
    c.refused(&out, "malformed");
}

#[test]
fn two_shipped_lines_or_an_indented_one_do_not_count() {
    let c = case();
    let twice = GOOD_LOG.replacen(
        "shipped head={head} dirty=0 unshipped=0\n",
        "shipped head={head} dirty=0 unshipped=0\nshipped head={head} dirty=0 unshipped=0\n",
        1,
    );
    let out = c.stamp(&c.log(&twice), &c.head.clone());
    c.refused(&out, "not exactly one");
    let indented = GOOD_LOG.replacen("shipped head", " shipped head", 1);
    let out = c.stamp(&c.log(&indented), &c.head.clone());
    c.refused(&out, "shipped");
}

#[test]
fn the_shipped_line_may_come_after_other_output() {
    let c = case();
    let moved = GOOD_LOG.replacen("shipped head={head} dirty=0 unshipped=0\n", "", 1)
        + "shipped head={head} dirty=0 unshipped=0\n";
    let out = c.stamp(&c.log(&moved), &c.head.clone());
    assert_eq!(out.code, 0, "{}", out.stderr);
}

#[test]
fn a_log_for_another_head_is_refused() {
    let c = case();
    let other = "a".repeat(40);
    let out = c.stamp(
        &c.log(&GOOD_LOG.replace("head={head}", &format!("head={other}"))),
        &c.head.clone(),
    );
    c.refused(&out, "head");
}

#[test]
fn a_verify_other_than_the_full_one_is_refused() {
    for cmd in [
        "pnpm verify:fast",
        "pnpm vitest run src/timer",
        "pnpm verify && true",
        "pnpm  verify",
    ] {
        let c = case();
        let out = c.stamp(
            &c.log(&GOOD_LOG.replace("cmd=pnpm verify", &format!("cmd={cmd}"))),
            &c.head.clone(),
        );
        c.refused(&out, "command");
    }
}

#[test]
fn a_log_that_records_no_command_is_refused() {
    let c = case();
    let out = c.stamp(&c.log(&GOOD_LOG.replace("cmd=pnpm verify\n", "")), &c.head.clone());
    c.refused(&out, "command");
}

#[test]
fn a_profile_that_names_no_full_verify_command_refuses_everything() {
    let c = case_with("stamp_command = \"sh {script} {tree}\"\n");
    let out = c.stamp(&c.log(GOOD_LOG), &c.head.clone());
    c.refused(&out, "full_verify_command");
}

#[test]
fn a_nonzero_verify_exit_is_refused() {
    for tail in [
        "remote rc=1\nverify exit=1\n",
        "remote rc=0\nverify exit=1\n",
        "remote rc=1\nverify exit=0\n",
    ] {
        let c = case();
        let log = GOOD_LOG.replace("remote rc=0\nverify exit=0\n", tail);
        let out = c.stamp(&c.log(&log), &c.head.clone());
        c.refused(&out, "exit");
    }
}

#[test]
fn a_log_with_no_exit_line_is_refused() {
    let c = case();
    let out = c.stamp(
        &c.log(&GOOD_LOG.replace("remote rc=0\nverify exit=0\n", "")),
        &c.head.clone(),
    );
    c.refused(&out, "verify exit");
}

#[test]
fn a_log_with_no_head_line_is_refused() {
    let c = case();
    let out = c.stamp(
        &c.log(&GOOD_LOG.replacen("host=firebird head={head} dirty=0\n", "", 1)),
        &c.head.clone(),
    );
    c.refused(&out, "head");
    let c = case();
    let out = c.stamp(&c.log(""), &c.head.clone());
    c.refused(&out, "head");
}

#[test]
fn a_head_line_that_is_not_the_first_line_does_not_count() {
    let c = case();
    let forged = format!(
        "noise\nhost=firebird head={} dirty=0\ncmd=pnpm verify\nverify exit=0\n",
        c.head
    );
    let out = c.stamp(&c.log(&forged), &c.head.clone());
    c.refused(&out, "head");
}

#[test]
fn a_worktree_that_is_not_at_the_head_is_refused() {
    let c = case();
    let log = c.log(GOOD_LOG);
    fs::write(c.wt.join("more.txt"), "more\n").expect("the file");
    git(&c.wt, &["add", "more.txt"]);
    git(
        &c.wt,
        &[
            "-c",
            "user.name=T",
            "-c",
            "user.email=t@example.invalid",
            "commit",
            "-q",
            "-m",
            "more",
        ],
    );
    let out = c.stamp(&log, &c.head.clone());
    c.refused(&out, "worktree");
}

#[test]
fn a_dirty_worktree_is_refused() {
    for (name, text) in [("untracked.txt", "x\n"), ("README.md", "changed\n")] {
        let c = case();
        fs::write(c.wt.join(name), text).expect("the file");
        let out = c.stamp(&c.log(GOOD_LOG), &c.head.clone());
        c.refused(&out, "not clean");
    }
}

#[test]
fn a_stamp_command_that_changes_the_tree_is_refused() {
    let c = case_with("full_verify_command = \"pnpm verify\"\nstamp_command = \"sh {dir}/change.sh\"\n");
    fs::write(
        c.env.dir.path().join("change.sh"),
        "echo more > more.txt\ngit add more.txt\ngit -c user.name=T -c user.email=t@example.invalid commit -q -m more\n",
    )
    .expect("the script");
    let out = c.stamp(&c.log(GOOD_LOG), &c.head.clone());
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("changed"), "{}", out.stderr);
    assert!(!c.stamp_file().exists());
}

#[test]
fn a_stamp_command_that_leaves_the_tree_dirty_is_refused() {
    let c = case_with("full_verify_command = \"pnpm verify\"\nstamp_command = \"sh {dir}/dirty.sh\"\n");
    fs::write(c.env.dir.path().join("dirty.sh"), "echo scribble > README.md\n").expect("the script");
    let out = c.stamp(&c.log(GOOD_LOG), &c.head.clone());
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(out.stderr.contains("changed"), "{}", out.stderr);
    assert!(!c.stamp_file().exists());
}

#[test]
fn a_stamp_command_that_fails_is_exit_1() {
    let c = case_with("full_verify_command = \"pnpm verify\"\nstamp_command = \"sh {dir}/fail.sh\"\n");
    fs::write(c.env.dir.path().join("fail.sh"), "echo no >&2\nexit 5\n").expect("the script");
    let out = c.stamp(&c.log(GOOD_LOG), &c.head.clone());
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert!(out.stderr.contains("no"), "{}", out.stderr);
    assert!(!c.stamp_file().exists());
}

#[test]
fn a_profile_with_no_stamp_command_records_that_and_stamps_nothing() {
    let c = case_with("full_verify_command = \"pnpm verify\"\n");
    let out = c.stamp(&c.log(GOOD_LOG), &c.head.clone());
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        json(&c.stamp_file()),
        json!({"head": c.head, "tree": c.tree, "stamped": false, "reason": "no stamp command in profile"})
    );
    assert!(!c.stamped.exists());
}

#[test]
fn the_conditions_are_judged_before_the_missing_stamp_command_is_mentioned() {
    let c = case_with("full_verify_command = \"pnpm verify\"\n");
    let out = c.stamp(&c.log(&GOOD_LOG.replace("dirty=0", "dirty=2")), &c.head.clone());
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(!c.stamp_file().exists());
}

#[test]
fn every_failing_condition_is_named() {
    let c = case();
    let log = GOOD_LOG
        .replace("dirty=0", "dirty=1")
        .replace("cmd=pnpm verify", "cmd=pnpm verify:fast");
    let out = c.stamp(&c.log(&log), &c.head.clone());
    c.refused(&out, "dirty");
    assert!(out.stderr.contains("command"), "{}", out.stderr);
}

#[test]
fn bad_arguments_and_missing_inputs_are_usage_errors() {
    let c = case();
    let log = c.log(GOOD_LOG);
    assert_eq!(c.stamp(&log, "not-a-sha").code, 2);
    assert_eq!(c.stamp(&c.env.dir.path().join("no-such.log"), &c.head.clone()).code, 2);
    fs::remove_file(c.env.workdir.join("units/3/unit.json")).expect("the unit file");
    let out = c.stamp(&log, &c.head.clone());
    assert_eq!(out.code, 2, "{}", out.stderr);
    assert!(out.stderr.contains("unit-prepare"), "{}", out.stderr);
}

/// A stamp command that is a path in the repo, as unit-prepare's bootstrap may
/// be, is relative to the unit worktree and not to wherever the driver runs.
#[test]
fn a_stamp_command_given_as_a_relative_path_runs_from_the_worktree() {
    use std::os::unix::fs::PermissionsExt;
    let mut c = case_with("full_verify_command = \"pnpm verify\"\nstamp_command = \"tools/stamp.sh {tree}\"\n");
    let script = c.wt.join("tools/stamp.sh");
    fs::create_dir_all(script.parent().expect("a parent")).expect("the folder");
    fs::write(&script, format!("#!/bin/sh\necho \"$1\" >> {}\n", c.stamped.display())).expect("the script");
    fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).expect("chmod");
    git(&c.wt, &["add", "tools/stamp.sh"]);
    git(
        &c.wt,
        &[
            "-c",
            "user.name=T",
            "-c",
            "user.email=t@example.invalid",
            "commit",
            "-q",
            "-m",
            "stamp script",
        ],
    );
    c.head = git(&c.wt, &["rev-parse", "HEAD"]);
    c.tree = git(&c.wt, &["rev-parse", "HEAD^{tree}"]);
    // Run from a folder that has no tools/stamp.sh.
    let elsewhere = c.env.dir.path().join("elsewhere");
    fs::create_dir_all(&elsewhere).expect("the folder");
    let log = c.log(GOOD_LOG);
    let out = c.env.run_in(
        Some(&elsewhere),
        &[
            "stamp-remote-pass",
            "--unit",
            "3",
            "--log",
            &log.display().to_string(),
            "--head",
            &c.head,
        ],
    );
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        fs::read_to_string(&c.stamped).expect("the stamp command ran").trim(),
        c.tree
    );
}
