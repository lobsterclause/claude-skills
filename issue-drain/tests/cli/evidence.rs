//! CLI tests for `evidence-check`. Each refusal has a control beside it that passes.

use std::path::PathBuf;

use serde_json::{Value, json};

use crate::common::*;

fn good_file() -> String {
    eval_fixtures().join("verdicts.good.json").display().to_string()
}

fn checked_path(env: &Env) -> PathBuf {
    env.workdir.join("verdicts.checked.json")
}

#[test]
fn the_good_verdicts_check_out_to_the_golden_file() {
    let env = Env::new();
    env.seed(&["intake.json", "issues"]);
    let out = env.run(&["evidence-check", &good_file(), "--ref", "develop"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(json(&checked_path(&env)), golden("verdicts.checked.json"));
    let events = env.events_named("evidence_check");
    assert_eq!(events.len(), 1);
    let e = &events[0];
    assert_eq!(e["verdicts"], 12);
    assert_eq!(e["dropped"], 0);
    assert_eq!(e["downgraded"], 2);
    assert_eq!(
        e["by_status"],
        json!({"already_fixed": 2, "duplicate_of": 1, "live": 5, "needs_human": 2, "unclear": 2})
    );
    assert_eq!(e["ref"], "develop");
    assert!(
        out.stdout
            .contains("#107: live -> needs_human (protected path: .github/workflows/ci.yml)"),
        "{}",
        out.stdout
    );
    assert!(out.stdout.contains("#112: already_fixed -> unclear"), "{}", out.stdout);
}

#[test]
fn a_folder_inside_the_checkout_checks_out_the_same() {
    // Quoted paths are relative to the root of the repo, wherever in it
    // ISSUE_DRAIN_REPO_DIR points.
    let mut env = Env::new();
    env.set(
        "ISSUE_DRAIN_REPO_DIR",
        &fixture_repo().join("src").display().to_string(),
    );
    env.seed(&["intake.json", "issues"]);
    let out = env.run(&["evidence-check", &good_file(), "--ref", "develop"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(json(&checked_path(&env)), golden("verdicts.checked.json"));
}

// ---- one verdict at a time ----

fn good(number: u64) -> Value {
    json(&eval_fixtures().join("verdicts.good.json"))
        .as_array()
        .expect("an array")
        .iter()
        .find(|v| v["number"] == number)
        .expect("that verdict")
        .clone()
}

/// Check these verdicts (intake and issues seeded) and return the output and
/// the checked rows.
fn check_all(env: &Env, verdicts: &Value) -> (Out, Value) {
    env.seed(&["intake.json", "issues"]);
    let input = env.write("in.json", &verdicts.to_string());
    let out = env.run(&["evidence-check", &input.display().to_string(), "--ref", "develop"]);
    let rows = std::fs::read_to_string(checked_path(env))
        .map(|t| serde_json::from_str(&t).expect("JSON"))
        .unwrap_or(Value::Null);
    (out, rows)
}

fn row(rows: &Value, number: u64) -> Value {
    rows.as_array()
        .expect("rows")
        .iter()
        .find(|r| r["number"] == number)
        .expect("a row for that issue")
        .clone()
}

/// The checked row for one issue after checking this one verdict.
fn check_one(verdict: &Value) -> Value {
    let env = Env::new();
    let (out, rows) = check_all(&env, &json!([verdict]));
    assert_eq!(out.code, 0, "{}", out.stderr);
    row(&rows, verdict["number"].as_u64().expect("a number"))
}

fn with(mut v: Value, key: &str, value: Value) -> Value {
    v[key] = value;
    v
}

fn with_quote(number: u64, file: &str, line: Value, quote: &str) -> Value {
    with(
        good(number),
        "evidence",
        json!([{"file": file, "line": line, "quote": quote}]),
    )
}

const COUNTDOWN: &str = "src/timer/countdown.ts";
const QUOTE: &str = "return minutes + \":\" + seconds;";

#[test]
fn a_quote_must_be_at_that_file_and_line() {
    let control = check_one(&good(103));
    assert_eq!(control["status"], "live");
    assert_eq!(control["evidence"][0]["ok"], true);

    let r = check_one(&with_quote(103, COUNTDOWN, json!(5), "return minutes - seconds;"));
    assert_eq!(r["status"], "unclear");
    assert_eq!(r["original_status"], "live");
    assert_eq!(r["evidence"][0]["ok"], false);
    let why = r["downgrade_reason"].as_str().expect("a reason");
    assert!(
        why.starts_with("evidence failed the check: src/timer/countdown.ts:5 "),
        "{why}"
    );
    assert!(
        why.contains("quote is not within 3 lines of that line on develop"),
        "{why}"
    );
}

#[test]
fn a_quote_is_compared_without_its_spacing() {
    let spaced = "\t return   minutes +  \":\"\t+ seconds;  ";
    let r = check_one(&with_quote(103, COUNTDOWN, json!(5), spaced));
    assert_eq!(r["status"], "live", "{r}");
    assert_eq!(r["evidence"][0]["ok"], true);
    assert_eq!(
        r["evidence"][0]["quote"], spaced,
        "the reader's quote is kept as written"
    );
}

#[test]
fn a_quote_is_found_within_the_slack_and_the_line_is_corrected() {
    let near = check_one(&with_quote(103, COUNTDOWN, json!(2), QUOTE));
    assert_eq!(near["evidence"][0]["ok"], true, "{near}");
    assert_eq!(near["evidence"][0]["line"], 5);
    let far = check_one(&with_quote(103, COUNTDOWN, json!(1), QUOTE));
    assert_eq!(far["evidence"][0]["ok"], false);
    assert_eq!(far["evidence"][0]["line"], 1, "a failed quote keeps the reader's line");
}

#[test]
fn a_line_given_as_a_string_works_and_a_junk_line_fails() {
    assert_eq!(
        check_one(&with_quote(103, COUNTDOWN, json!("5"), QUOTE))["status"],
        "live"
    );
    for bad in [json!("five"), json!(0), json!(-1), json!(5.5), json!(null)] {
        let r = check_one(&with_quote(103, COUNTDOWN, bad.clone(), QUOTE));
        assert_eq!(r["evidence"][0]["reason"], "has no line number", "{bad}");
    }
}

#[test]
fn a_short_or_multi_line_quote_fails() {
    let short = check_one(&with_quote(103, COUNTDOWN, json!(5), "return"));
    assert_eq!(short["evidence"][0]["reason"], "quote is shorter than 8 characters");
    let multi = check_one(&with_quote(103, COUNTDOWN, json!(5), "const seconds = 1;\nreturn 2;"));
    assert_eq!(multi["evidence"][0]["reason"], "quote spans more than one line");
}

#[test]
fn a_file_must_be_a_blob_on_the_ref() {
    assert_eq!(check_one(&good(103))["evidence"][0]["ok"], true);
    for missing in ["src/timer/nope.ts", "src/timer", "src"] {
        let r = check_one(&with_quote(103, missing, json!(5), QUOTE));
        assert_eq!(r["evidence"][0]["reason"], "file is not on develop", "{missing}");
        assert_eq!(r["status"], "unclear");
    }
}

#[test]
fn a_path_that_is_not_repo_relative_or_has_a_control_character_fails() {
    for bad in [
        "../etc/passwd",
        "src/../src/timer/countdown.ts",
        "/etc/passwd",
        "-countdown.ts",
        "",
        "src/timer/countdown.ts\u{7}",
        "src/timer/countdown.ts\n",
        "src/timer/count\u{0}down.ts",
    ] {
        let r = check_one(&with_quote(103, bad, json!(5), QUOTE));
        assert_eq!(r["evidence"][0]["ok"], false, "{bad:?}");
        assert_eq!(r["status"], "unclear", "{bad:?}");
    }
    let control = check_one(&with_quote(103, "src/timer/countdown.ts\u{7}", json!(5), QUOTE));
    assert_eq!(control["evidence"][0]["reason"], "has a control character in its path");
}

#[test]
fn a_line_number_at_the_edge_of_the_range_fails_and_does_not_overflow() {
    let r = check_one(&with_quote(103, COUNTDOWN, json!(i64::MAX), QUOTE));
    assert_eq!(
        r["evidence"][0]["reason"],
        "quote is not within 3 lines of that line on develop"
    );
    assert_eq!(
        check_one(&with_quote(103, COUNTDOWN, json!(5), QUOTE))["status"],
        "live"
    );
}

#[test]
fn a_likely_file_that_is_no_repo_path_makes_the_verdict_unclear() {
    for (number, status) in [(103, "live"), (101, "already_fixed"), (106, "duplicate_of")] {
        assert_eq!(check_one(&good(number))["status"], status, "control #{number}");
        for bad in ["../outside.ts", "/etc/passwd", "-rf", "src/./a.ts", ""] {
            let r = check_one(&with(good(number), "likely_files", json!([COUNTDOWN, bad])));
            assert_eq!(r["status"], "unclear", "#{number} {bad:?}");
            assert_eq!(r["downgrade_reason"], "a likely file is not a repo-relative path");
            assert_eq!(r["likely_files"], json!([COUNTDOWN]), "the bad path is not kept");
            assert!(!r["files"].as_array().expect("files").iter().any(|f| f == bad));
        }
    }
    let r = check_one(&with(good(103), "likely_files", json!(["src/a\u{7}.ts"])));
    assert_eq!(
        r["downgrade_reason"],
        "a likely file has a control character in its path"
    );
}

#[test]
fn a_likely_file_that_is_a_folder_on_the_ref_is_kept_without_its_slash() {
    for number in [103, 101] {
        let r = check_one(&with(good(number), "likely_files", json!([COUNTDOWN, "src/timer/"])));
        assert_ne!(r["status"], "unclear", "#{number} {r}");
        assert_eq!(r["likely_files"], json!([COUNTDOWN, "src/timer"]));
    }
    // Controls: a folder that is not on the ref, and a file with a slash, still fail.
    for bad in ["src/nowhere/", "src/timer/countdown.ts/"] {
        let r = check_one(&with(good(103), "likely_files", json!([COUNTDOWN, bad])));
        assert_eq!(r["status"], "unclear", "{bad}");
        assert_eq!(r["downgrade_reason"], "a likely file is not a repo-relative path");
    }
}

#[test]
fn an_already_fixed_issue_on_a_protected_path_is_still_already_fixed() {
    // Nothing is written for it, so there is nothing for a person to change.
    let r = check_one(&with(
        good(101),
        "likely_files",
        json!(["src/auth/session.ts", ".github/workflows/ci.yml"]),
    ));
    assert_eq!(r["status"], "already_fixed", "{r}");
    assert!(r["downgrade_reason"].is_null());
    // Control: the same path sends a live issue to a person.
    let live = check_one(&with(
        good(103),
        "likely_files",
        json!([COUNTDOWN, ".github/workflows/ci.yml"]),
    ));
    assert_eq!(live["status"], "needs_human");
}

#[test]
fn a_failed_reuse_quote_is_dropped_and_counted() {
    let control = check_one(&good(103));
    assert_eq!(control["reuse"].as_array().expect("reuse").len(), 1);
    assert_eq!(control["reuse_dropped"], 0);
    let r = check_one(&with(
        good(103),
        "reuse",
        json!([
            {"file": "src/lib/format.ts", "line": 2, "quote": "export function formatDuration(ms: number): string {"},
            {"file": "src/lib/format.ts", "line": 2, "quote": "export function nothingLikeThis(): void {"},
        ]),
    ));
    assert_eq!(r["status"], "live", "a bad reuse quote does not downgrade the verdict");
    assert_eq!(r["reuse"].as_array().expect("reuse").len(), 1);
    assert_eq!(r["reuse_dropped"], 1);
}

#[test]
fn already_fixed_needs_a_quoted_line_newer_than_the_issue() {
    let control = check_one(&good(101));
    assert_eq!(control["status"], "already_fixed");
    assert_eq!(control["closable"], true);
    assert_eq!(control["fix_commit"]["file"], "src/auth/session.ts");

    // The same claim about a line from the first commit, older than the issue.
    let old = with(
        with_quote(103, COUNTDOWN, json!(5), QUOTE),
        "status",
        json!("already_fixed"),
    );
    let r = check_one(&old);
    assert_eq!(r["status"], "unclear");
    assert_eq!(
        r["downgrade_reason"],
        "every quoted line is older than the issue, so none of them is its fix"
    );
    assert_eq!(r["closable"], false);
    assert!(r["fix_commit"].is_null());
}

#[test]
fn a_behavioural_fix_is_not_closable() {
    let r = check_one(&good(102));
    assert_eq!(r["status"], "already_fixed");
    assert_eq!(r["closable"], false);
}

#[test]
fn a_named_fixing_commit_must_be_on_the_ref() {
    let mut env = Env::new();
    let repo = private_repo(env.dir.path());
    env.set("ISSUE_DRAIN_REPO_DIR", &repo.display().to_string());
    let on_ref = git(&repo, &["rev-parse", "develop"]);
    git(&repo, &["switch", "-q", "-c", "side"]);
    git(
        &repo,
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@example.invalid",
            "commit",
            "-q",
            "--allow-empty",
            "-m",
            "x",
        ],
    );
    let off_ref = git(&repo, &["rev-parse", "side"]);
    git(&repo, &["switch", "-q", "develop"]);

    let run = |named: &str| {
        let verdict = with(good(101), "fixing_commit", json!(named));
        let (out, rows) = check_all(&env, &json!([verdict]));
        assert_eq!(out.code, 0, "{}", out.stderr);
        row(&rows, 101)
    };
    assert_eq!(run(&on_ref)["status"], "already_fixed", "control: a commit on the ref");
    assert_eq!(
        run(&on_ref[..9])["status"],
        "already_fixed",
        "control: an abbreviated id"
    );
    for (named, why) in [
        (off_ref.as_str(), "is not on develop"),
        ("deadbeefdeadbeef", "does not exist in the repo"),
        ("HEAD", "is not a commit id"),
        ("--all", "is not a commit id"),
    ] {
        let r = run(named);
        assert_eq!(r["status"], "unclear", "{named}");
        assert_eq!(
            r["downgrade_reason"],
            format!("the fixing commit the reader named {why}"),
            "{named}"
        );
    }
}

#[test]
fn a_fix_on_a_protected_path_goes_to_a_person() {
    assert_eq!(check_one(&good(103))["status"], "live");
    for file in [".github/workflows/ci.yml", ".husky/pre-commit"] {
        let r = check_one(&with(good(103), "likely_files", json!([COUNTDOWN, file])));
        assert_eq!(r["status"], "needs_human", "{file}");
        assert_eq!(r["downgrade_reason"], format!("protected path: {file}"));
        assert!(r["files"].as_array().expect("files").iter().any(|f| f == file));
    }
}

#[test]
fn a_risk_path_is_flagged_without_a_downgrade() {
    let r = check_one(&good(108));
    assert_eq!(r["status"], "live");
    assert_eq!(r["risk"], true);
    assert_eq!(r["risk_paths"], json!(["src/crisis/keywords.ts"]));
    assert_eq!(check_one(&good(103))["risk"], false);
}

#[test]
fn a_status_a_reader_may_not_return_is_unclear() {
    assert_eq!(check_one(&good(103))["status"], "live");
    for bad in [json!("maybe"), json!(""), json!(null), json!(3)] {
        let r = check_one(&with(good(103), "status", bad.clone()));
        assert_eq!(r["status"], "unclear", "{bad}");
        assert!(
            r["downgrade_reason"]
                .as_str()
                .expect("a reason")
                .ends_with("is not a status a reader may return"),
            "{r}"
        );
    }
}

#[test]
fn a_live_verdict_needs_evidence_and_a_task() {
    let none = check_one(&with(good(103), "evidence", json!([])));
    assert_eq!(none["downgrade_reason"], "no evidence was quoted");
    let no_task = check_one(&with(good(103), "task", json!("")));
    assert_eq!(no_task["downgrade_reason"], "no task statement or acceptance check");
    let no_acceptance = check_one(&with(good(103), "acceptance", json!(null)));
    assert_eq!(
        no_acceptance["downgrade_reason"],
        "no task statement or acceptance check"
    );
}

#[test]
fn a_duplicate_must_name_another_issue_of_this_run() {
    let control = check_one(&good(106));
    assert_eq!(control["status"], "duplicate_of");
    for bad in [json!(106), json!(999), json!("104"), json!(null)] {
        let r = check_one(&with(good(106), "duplicate_of", bad.clone()));
        assert_eq!(r["status"], "unclear", "{bad}");
        assert_eq!(
            r["downgrade_reason"],
            "duplicate_of does not name another issue in this run"
        );
    }
}

#[test]
fn keys_the_spec_does_not_know_are_dropped() {
    let r = check_one(&with(good(103), "run_this", json!("rm -rf /")));
    assert_eq!(r["status"], "live");
    assert!(r.get("run_this").is_none(), "{r}");
}

#[test]
fn a_verdict_for_an_issue_not_in_intake_is_dropped() {
    let env = Env::new();
    let (out, rows) = check_all(&env, &json!([good(103), with(good(103), "number", json!(999))]));
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stderr.contains("dropped a verdict for '#999'"), "{}", out.stderr);
    assert_eq!(env.events_named("evidence_check")[0]["dropped"], 1);
    let numbers: Vec<u64> = rows
        .as_array()
        .expect("rows")
        .iter()
        .map(|r| r["number"].as_u64().expect("n"))
        .collect();
    assert!(!numbers.contains(&999));
    assert!(
        numbers.contains(&103),
        "control: the verdict about an issue in intake stays"
    );
}

#[test]
fn a_second_verdict_for_an_issue_is_dropped_and_the_first_stands() {
    let env = Env::new();
    let second = with(good(103), "status", json!("unclear"));
    let (out, rows) = check_all(&env, &json!([good(103), second]));
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(
        out.stderr.contains("dropped a second verdict for #103"),
        "{}",
        out.stderr
    );
    assert_eq!(row(&rows, 103)["status"], "live");
}

#[test]
fn an_issue_with_no_verdict_gets_an_unclear_one() {
    let env = Env::new();
    let (out, rows) = check_all(&env, &json!([good(103)]));
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(rows.as_array().expect("rows").len(), 12, "one row per eligible issue");
    let r = row(&rows, 104);
    assert_eq!(r["status"], "unclear");
    assert!(r["original_status"].is_null());
    assert_eq!(r["downgrade_reason"], "no reader returned a verdict for this issue");
}

#[test]
fn several_inputs_are_joined_and_out_can_be_named() {
    let env = Env::new();
    env.seed(&["intake.json", "issues"]);
    let a = env.write("a.json", &json!([good(103)]).to_string());
    let b = env.write("b.json", &json!([good(101)]).to_string());
    let out_path = env.dir.path().join("elsewhere.json");
    let out = env.run(&[
        "evidence-check",
        &a.display().to_string(),
        &b.display().to_string(),
        "--ref",
        "develop",
        "--out",
        &out_path.display().to_string(),
    ]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let rows = json(&out_path);
    assert_eq!(row(&rows, 103)["status"], "live");
    assert_eq!(row(&rows, 101)["status"], "already_fixed");
    assert!(!checked_path(&env).exists());
}

#[test]
fn a_checked_verdict_can_be_checked_again() {
    let env = Env::new();
    env.seed(&["intake.json", "issues"]);
    assert_eq!(env.run(&["evidence-check", &good_file(), "--ref", "develop"]).code, 0);
    let again = env.dir.path().join("again.json");
    let out = env.run(&[
        "evidence-check",
        &checked_path(&env).display().to_string(),
        "--ref",
        "develop",
        "--out",
        &again.display().to_string(),
    ]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let second = json(&again);
    for a in golden("verdicts.checked.json").as_array().expect("rows") {
        let b = row(&second, a["number"].as_u64().expect("n"));
        assert_eq!(a["status"], b["status"], "#{}", a["number"]);
        assert_eq!(a["closable"], b["closable"], "#{}", a["number"]);
        assert_eq!(a["fix_commit"], b["fix_commit"], "#{}", a["number"]);
    }
}

// ---- input and arguments ----

#[test]
fn bad_input_is_a_usage_error_and_writes_nothing() {
    let env = Env::new();
    env.seed(&["intake.json", "issues"]);
    let run = |path: &str| env.run(&["evidence-check", path, "--ref", "develop"]);

    let out = env.run(&["evidence-check", "--ref", "develop"]);
    assert_eq!(out.code, 2, "no input file: {}", out.stderr);
    assert_eq!(run("/nonexistent/verdicts.json").code, 2, "missing file");
    let malformed = env.write("malformed.json", "[{\"number\": 103,");
    assert_eq!(run(&malformed.display().to_string()).code, 2, "malformed");
    let object = env.write("object.json", "{\"number\": 103}");
    assert_eq!(run(&object.display().to_string()).code, 2, "not an array");
    assert!(!checked_path(&env).exists());
    assert!(env.events().is_empty());

    assert_eq!(run(&good_file()).code, 0, "control");
    assert!(checked_path(&env).exists());
}

#[test]
fn a_missing_intake_is_a_usage_error() {
    let env = Env::new();
    let out = env.run(&["evidence-check", &good_file(), "--ref", "develop"]);
    assert_eq!(out.code, 2);
    assert!(out.stderr.contains("intake.json"), "{}", out.stderr);
}

#[test]
fn a_ref_that_names_no_commit_is_a_usage_error() {
    let env = Env::new();
    env.seed(&["intake.json", "issues"]);
    for bad in ["nonesuch", "develop:src", "--upload-pack=x"] {
        let out = env.run(&["evidence-check", &good_file(), "--ref", bad]);
        assert_eq!(out.code, 2, "{bad}: {}", out.stderr);
    }
    assert!(!checked_path(&env).exists());
    assert_eq!(
        env.run(&["evidence-check", &good_file(), "--ref", "develop"]).code,
        0,
        "control"
    );
}

#[test]
fn the_default_ref_is_origin_and_the_base_branch() {
    let env = Env::new();
    env.seed(&["intake.json", "issues"]);
    let out = env.run(&["evidence-check", &good_file()]);
    assert_eq!(
        out.code, 2,
        "the fixture has no remote, so origin/develop is no commit: {}",
        out.stderr
    );
    assert!(out.stderr.contains("origin/develop"), "{}", out.stderr);
}

#[test]
fn the_default_ref_is_the_remote_branch_and_not_a_tag_of_that_name() {
    let mut env = Env::new();
    let checkout = origin_clone(env.dir.path(), fixture_repo());
    let root = git(&checkout, &["rev-list", "--max-parents=0", "HEAD"]);
    git(&checkout, &["tag", "origin/develop", &root]);
    env.set("ISSUE_DRAIN_REPO_DIR", &checkout.display().to_string());
    env.seed(&["intake.json", "issues"]);
    let input = env.write("in.json", &json!([good(101)]).to_string());
    let out = env.run(&["evidence-check", &input.display().to_string()]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let checked = row(&json(&checked_path(&env)), 101);
    assert_eq!(checked["status"], "already_fixed", "{checked}");
    assert_eq!(checked["checked_ref"], "origin/develop");
}

#[test]
fn a_line_blamed_on_the_edge_of_a_shallow_clone_proves_nothing() {
    // In a shallow clone every line older than the cut is blamed on the
    // commit at the cut, so that commit is not known to be the one that
    // wrote the line.
    let mut env = Env::new();
    let shallow = env.dir.path().join("shallow");
    git(
        env.dir.path(),
        &[
            "clone",
            "-q",
            "--depth",
            "1",
            &format!("file://{}", fixture_repo().display()),
            &shallow.display().to_string(),
        ],
    );
    env.set("ISSUE_DRAIN_REPO_DIR", &shallow.display().to_string());
    let (out, rows) = check_all(&env, &json!([good(101)]));
    assert_eq!(out.code, 0, "{}", out.stderr);
    let checked = row(&rows, 101);
    assert_eq!(checked["status"], "unclear", "{checked}");
    assert_eq!(checked["evidence"][0]["ok"], false, "{checked}");
    let reason = checked["evidence"][0]["reason"].as_str().unwrap_or_default();
    assert!(reason.contains("shallow"), "{reason}");
}

#[test]
fn an_unknown_option_is_a_usage_error() {
    let env = Env::new();
    env.seed(&["intake.json", "issues"]);
    let out = env.run(&["evidence-check", &good_file(), "--ref", "develop", "--force"]);
    assert_eq!(out.code, 2);
}
