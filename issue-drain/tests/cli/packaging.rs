//! Packaging: the kma profile, the launcher, the eval setup and the CI workflow.

use std::collections::HashMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use issue_drain::profile::Profile;

use crate::common::*;

fn load(path: &Path) -> Profile {
    Profile::load(path, manifest_dir()).unwrap_or_else(|e| panic!("{} does not load: {e:?}", path.display()))
}

/// The `KEY="value"` lines of a shell-form profile.
fn env_profile(path: &Path) -> HashMap<String, String> {
    let text = fs::read_to_string(path).expect("the .env profile");
    text.lines()
        .filter(|l| !l.trim_start().starts_with('#') && l.contains('='))
        .map(|l| {
            let (k, v) = l.split_once('=').expect("a pair");
            let v = v.trim();
            let v = v
                .strip_prefix('"')
                .and_then(|v| v.strip_suffix('"'))
                .or_else(|| v.strip_prefix('\'').and_then(|v| v.strip_suffix('\'')))
                .unwrap_or(v);
            (k.trim().to_string(), v.to_string())
        })
        .collect()
}

fn words(s: &str) -> Vec<String> {
    s.split_whitespace().map(str::to_string).collect()
}

fn toml_files(dir: &Path) -> Vec<PathBuf> {
    let mut found: Vec<PathBuf> = fs::read_dir(dir)
        .expect("the folder")
        .map(|e| e.expect("an entry").path())
        .filter(|p| p.extension().is_some_and(|x| x == "toml"))
        .collect();
    found.sort();
    found
}

#[test]
fn the_kma_profile_matches_its_env_form() {
    let dir = manifest_dir().join("profiles");
    let env = env_profile(&dir.join("Not-Every-Mom__kindred-mama-ai.env"));
    let p = load(&dir.join("Not-Every-Mom__kindred-mama-ai.toml"));
    assert_eq!(p.base_branch, env["BASE_BRANCH"]);
    assert_eq!(p.hold_labels, words(&env["HOLD_LABELS"]));
    assert_eq!(p.claim_label, env["CLAIM_LABEL"]);
    assert_eq!(p.blocked_label, env["BLOCKED_LABEL"]);
    assert_eq!(p.tracker_label, env["TRACKER_LABEL"]);
    assert_eq!(p.priority_labels, words(&env["PRIORITY_LABELS"]));
    assert_eq!(p.protected_path_re, env["PROTECTED_PATH_RE"]);
    assert_eq!(p.risk_path_re, env["RISK_PATH_RE"]);
    assert_eq!(p.trusted_associations, words(&env["TRUSTED_ASSOCIATIONS"]));
    assert_eq!(p.intake_cap.to_string(), env["INTAKE_CAP"]);
    assert_eq!(p.stale_claim_days.to_string(), env["STALE_CLAIM_DAYS"]);
    assert_eq!(p.issue_classifier, env["ISSUE_CLASSIFIER"]);
    assert_eq!(p.cluster_max_issues.to_string(), env["CLUSTER_MAX_ISSUES"]);
    assert_eq!(p.cluster_max_lines.to_string(), env["CLUSTER_MAX_LINES"]);
    assert_eq!(p.evidence_line_slack.to_string(), env["EVIDENCE_LINE_SLACK"]);
    assert_eq!(p.evidence_min_quote.to_string(), env["EVIDENCE_MIN_QUOTE"]);
    assert_eq!(p.unit_permissions, env["UNIT_PERMISSIONS"]);
}

#[test]
fn every_shipped_profile_and_fixture_profile_loads() {
    let mut all = toml_files(&manifest_dir().join("profiles"));
    all.extend(toml_files(&eval_fixtures()));
    assert!(all.len() >= 2, "expected at least two profiles, found {all:?}");
    for path in all {
        load(&path);
    }
}

#[test]
fn the_launcher_is_an_executable_that_parses() {
    let launcher = manifest_dir().join("bin/issue-drain");
    let mode = fs::metadata(&launcher)
        .expect("bin/issue-drain exists")
        .permissions()
        .mode();
    assert!(mode & 0o111 == 0o111, "not executable: {mode:o}");
    let out = Command::new("bash")
        .arg("-n")
        .arg(&launcher)
        .output()
        .expect("bash runs");
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
}

#[test]
fn the_eval_setup_parses_and_names_no_bash_script() {
    let setup = manifest_dir().join("evals/setup.sh");
    let out = Command::new("bash").arg("-n").arg(&setup).output().expect("bash runs");
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let text = fs::read_to_string(&setup).expect("setup.sh");
    assert!(!text.contains("scripts/"), "setup.sh still names a scripts/ path");
    assert!(!text.contains("tidepool.env"), "setup.sh still uses the .env profile");
}

#[test]
fn the_workflow_runs_the_cargo_checks_and_is_not_pull_request_target() {
    let path = manifest_dir().join("../.github/workflows/issue-drain-tests.yml");
    let text = fs::read_to_string(&path).expect("the workflow file exists");
    for needed in [
        "cargo fmt",
        "cargo clippy",
        "cargo test",
        "-D warnings",
        "issue-drain/**",
    ] {
        assert!(text.contains(needed), "workflow lacks `{needed}`");
    }
    assert!(!text.contains("pull_request_target"));
}

#[test]
#[ignore = "runs a release build"]
fn the_launcher_builds_and_runs_through_a_symlink() {
    let dir = tempfile::tempdir().expect("a temporary folder");
    let link = dir.path().join("linked-issue-drain");
    std::os::unix::fs::symlink(manifest_dir().join("bin/issue-drain"), &link).expect("a symlink");
    let out = Command::new(&link)
        .arg("gh-write")
        .env("CARGO_TARGET_DIR", dir.path().join("target"))
        .env_remove("ISSUE_DRAIN_SKILL_DIR")
        .env("ISSUE_DRAIN_WORKDIR", dir.path().join("run"))
        .env("ISSUE_DRAIN_REPO", REPO)
        .env("ISSUE_DRAIN_PROFILE", eval_fixtures().join("tidepool.toml"))
        .output()
        .expect("the launcher runs");
    let out = Out::from(out);
    assert_eq!(out.code, 2, "{}", out.stderr);
    assert!(out.stderr.contains("gh-write: usage:"), "{}", out.stderr);
}
