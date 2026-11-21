//! Packaging: the kma profile, the launcher, the eval setup and the CI workflow.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use issue_drain::profile::Profile;

use crate::common::*;

fn load(path: &Path) -> Profile {
    Profile::load(path, manifest_dir()).unwrap_or_else(|e| panic!("{} does not load: {e:?}", path.display()))
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

fn executable(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().expect("a parent")).expect("the folder");
    fs::write(path, text).expect("the script");
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).expect("chmod");
}

#[test]
fn the_launcher_builds_from_the_crate_not_from_the_callers_folder() {
    // The caller's folder is the repo being drained. Cargo started there would
    // read its .cargo/config.toml, so the launcher must start cargo in the
    // crate. A stand-in cargo records where it was started and with what.
    let dir = tempfile::tempdir().expect("a temporary folder");
    let caller = dir.path().join("drained-repo");
    fs::create_dir_all(caller.join(".cargo")).expect("the caller's folder");
    fs::write(
        caller.join(".cargo/config.toml"),
        "[build]\nrustc-wrapper = \"/nonexistent/wrapper\"\n",
    )
    .expect("a hostile config");
    let seen = dir.path().join("cargo-seen");
    executable(
        &dir.path().join("bin/cargo"),
        &format!(
            "#!/bin/sh\n{{ pwd -P; echo \"$*\"; echo \"target=${{CARGO_BUILD_TARGET:-unset}}\"; }} > '{}'\n",
            seen.display()
        ),
    );
    // CARGO_TARGET_DIR is relative, as a caller might set it: it is the
    // caller's folder it is relative to.
    executable(&caller.join("out/release/issue-drain"), "#!/bin/sh\necho \"ran $*\"\n");

    let path = format!(
        "{}:{}",
        dir.path().join("bin").display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let out = Command::new(manifest_dir().join("bin/issue-drain"))
        .args(["intake", "--all"])
        .current_dir(&caller)
        .env("PATH", path)
        .env("CARGO_TARGET_DIR", "out")
        .env("CARGO_BUILD_TARGET", "wasm32-unknown-unknown")
        .output()
        .expect("the launcher runs");
    let out = Out::from(out);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(out.stdout, "ran intake --all\n");

    let seen = fs::read_to_string(&seen).expect("cargo was called");
    let lines: Vec<&str> = seen.lines().collect();
    let crate_dir = fs::canonicalize(manifest_dir()).expect("the crate folder");
    let caller = fs::canonicalize(&caller).expect("the caller's folder");
    assert_eq!(Path::new(lines[0]), crate_dir, "cargo started in the wrong folder");
    assert!(lines[1].starts_with("build --release --locked "), "{seen}");
    assert!(
        lines[1].ends_with(&format!("--target-dir {}", caller.join("out").display()))
            || lines[1].ends_with(&format!("--target-dir {}/out", caller.display())),
        "{seen}"
    );
    assert_eq!(lines[2], "target=unset");
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
