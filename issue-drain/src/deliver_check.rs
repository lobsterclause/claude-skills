//! `issue-drain deliver-check --unit <n> [--base <ref>] [--head <ref>]`: hold a
//! unit's diff against its scope and the profile's path rules, and write
//! `units/<n>/deliver.json`, the file `merge-gate` reads.
//!
//! Run it in the unit's worktree. `judge` is a pure function of the diff, so
//! each rule is tested without git; `run` only gathers the diff. Every failed
//! rule is reported, not the first. A git call that fails is an error (exit 1),
//! never an `ok: true`.
//!
//! Exit: 0 ok; 3 a rule refused (deliver.json is written with `ok: false`);
//! 2 bad arguments or no queue; 1 git or the filesystem failed.

use std::path::Path;

use serde_json::{Value, json};

use crate::ctx::{Ctx, read_json, write_json};
use crate::error::{Fail, Res};
use crate::git;
use crate::profile::path_within;

#[derive(clap::Args)]
pub struct Args {
    /// The unit; its file is <run folder>/units/<n>/deliver.json.
    #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
    unit: u64,
    /// The commit to compare from (default: the base branch on origin).
    #[arg(long)]
    base: Option<String>,
    /// The commit to check (default: HEAD).
    #[arg(long)]
    head: Option<String>,
}

/// Deletions must exceed additions by this factor...
const DESTRUCTIVE_FACTOR: u64 = 3;
/// ...and be over this many lines, for a diff to count as net destructive.
const DESTRUCTIVE_FLOOR: u64 = 100;

/// Dependency manifests: a file with this name (or `requirements*.txt`).
const MANIFESTS: [&str; 7] = [
    "package.json",
    "Cargo.toml",
    "pyproject.toml",
    "go.mod",
    "Podfile",
    "Package.swift",
    "Gemfile",
];

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Change {
    pub path: String,
    pub added: u64,
    pub deleted: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AddedLine {
    pub file: String,
    pub line: u64,
    pub text: String,
}

/// What `judge` needs, all of it already read.
pub struct Input {
    pub changes: Vec<Change>,
    pub added_lines: Vec<AddedLine>,
    /// The unit's files and folders; `None` when the queue records none.
    pub scope: Option<Vec<String>>,
    /// Acceptance test paths the unit must change; `None` when none are recorded.
    pub acceptance: Option<Vec<String>>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Failure {
    pub code: &'static str,
    pub message: String,
}

#[derive(Debug, Default)]
pub struct Verdict {
    pub failures: Vec<Failure>,
    pub new_dependency: Vec<String>,
    pub shortcuts: Vec<AddedLine>,
}

fn failure(code: &'static str, message: String) -> Failure {
    Failure { code, message }
}

fn is_manifest(path: &str) -> bool {
    let name = path.rsplit('/').next().unwrap_or(path);
    MANIFESTS.contains(&name) || (name.starts_with("requirements") && name.ends_with(".txt"))
}

/// Every rule, none stopping at the first. No I/O.
pub fn judge(input: &Input, is_protected: &dyn Fn(&str) -> bool, is_frozen: &dyn Fn(&str) -> bool) -> Verdict {
    let mut v = Verdict::default();
    let paths: Vec<&str> = input.changes.iter().map(|c| c.path.as_str()).collect();
    let listed = |hit: Vec<&str>| hit.join(", ");

    if paths.is_empty() {
        v.failures
            .push(failure("empty_diff", "the diff changes no files".into()));
    }
    let acceptance = input.acceptance.as_deref().unwrap_or_default();
    if let Some(scope) = &input.scope {
        let outside: Vec<&str> = paths
            .iter()
            .copied()
            .filter(|p| !scope.iter().chain(acceptance).any(|entry| path_within(p, entry)))
            .collect();
        if !outside.is_empty() {
            v.failures.push(failure(
                "out_of_scope",
                format!("outside the unit's files: {}", listed(outside)),
            ));
        }
    }
    let protected: Vec<&str> = paths.iter().copied().filter(|p| is_protected(p)).collect();
    if !protected.is_empty() {
        v.failures.push(failure(
            "protected_path",
            format!("changes protected paths: {}", listed(protected)),
        ));
    }
    let frozen: Vec<&str> = paths.iter().copied().filter(|p| is_frozen(p)).collect();
    if !frozen.is_empty() {
        v.failures.push(failure(
            "frozen_path",
            format!("changes frozen paths: {}", listed(frozen)),
        ));
    }
    let added: u64 = input.changes.iter().map(|c| c.added).sum();
    let deleted: u64 = input.changes.iter().map(|c| c.deleted).sum();
    if deleted > added.saturating_mul(DESTRUCTIVE_FACTOR) && deleted > DESTRUCTIVE_FLOOR {
        v.failures.push(failure(
            "net_destructive",
            format!("{deleted} lines deleted against {added} added (over {DESTRUCTIVE_FACTOR}x and {DESTRUCTIVE_FLOOR} lines)"),
        ));
    }
    let missing: Vec<&str> = acceptance
        .iter()
        .map(String::as_str)
        .filter(|a| !paths.contains(a))
        .collect();
    if !missing.is_empty() {
        v.failures.push(failure(
            "acceptance_missing",
            format!("acceptance tests not in the diff: {}", listed(missing)),
        ));
    }

    // shortcut: flags any added line in a manifest, upgrade to parsing dependency tables if it is noisy
    v.new_dependency = input
        .changes
        .iter()
        .filter(|c| c.added > 0 && is_manifest(&c.path))
        .map(|c| c.path.clone())
        .collect();
    v.shortcuts = input
        .added_lines
        .iter()
        .filter(|l| l.text.contains("shortcut:"))
        .cloned()
        .collect();
    v
}

/// `git diff --numstat -z --no-renames`: `<added>\t<deleted>\t<path>\0` each.
/// A binary file counts `-`, which is 0 lines.
pub fn parse_numstat(raw: &str) -> Vec<Change> {
    raw.split('\0')
        .filter(|record| !record.is_empty())
        .filter_map(|record| {
            let mut parts = record.splitn(3, '\t');
            let (added, deleted, path) = (parts.next()?, parts.next()?, parts.next()?);
            Some(Change {
                path: path.to_string(),
                added: added.parse().unwrap_or(0),
                deleted: deleted.parse().unwrap_or(0),
            })
        })
        .collect()
}

/// `@@ -a[,b] +c[,d] @@`: (b, c, d), a missing count being 1.
fn hunk(header: &str) -> Option<(u64, u64, u64)> {
    let mut parts = header.split_whitespace().skip(1);
    let (old, new) = (parts.next()?.strip_prefix('-')?, parts.next()?.strip_prefix('+')?);
    let count = |range: &str| -> Option<(u64, u64)> {
        match range.split_once(',') {
            Some((start, n)) => Some((start.parse().ok()?, n.parse().ok()?)),
            None => Some((range.parse().ok()?, 1)),
        }
    };
    Some((count(old)?.1, count(new)?.0, count(new)?.1))
}

/// Every added line of a `git diff -U0` patch, with its file and new line
/// number. Hunk counts say how many body lines follow, so an added line that
/// reads `++ b/x` is not taken for a file header.
pub fn parse_added(patch: &str) -> Vec<AddedLine> {
    let mut out = Vec::new();
    let (mut file, mut line) = (String::new(), 0);
    let (mut old_left, mut new_left) = (0, 0);
    for text in patch.lines() {
        if old_left + new_left > 0 {
            if text.starts_with('-') {
                old_left -= 1;
            } else if let Some(added) = text.strip_prefix('+') {
                new_left -= 1;
                out.push(AddedLine {
                    file: file.clone(),
                    line,
                    text: added.to_string(),
                });
                line += 1;
            }
            continue;
        }
        if let Some(path) = text.strip_prefix("+++ b/") {
            file = path.to_string();
        } else if text.starts_with("@@ ") {
            if let Some((old, start, new)) = hunk(text) {
                (old_left, line, new_left) = (old, start, new);
            }
        }
    }
    out
}

fn resolve(dir: &Path, reference: &str, flag: &str) -> Res<String> {
    git::commit(dir, reference)
        .ok_or_else(|| Fail::failed(format!("git cannot resolve {flag} '{reference}' to a commit")))
}

fn git_out(dir: &Path, args: &[&str]) -> Res<String> {
    git::out(dir, args).ok_or_else(|| Fail::failed(format!("git {} failed", args.join(" "))))
}

/// The unit's files and acceptance test paths from queue.json. A queue unit
/// has no field for acceptance tests yet; `acceptance_tests`, a list of paths,
/// is read when a unit carries one.
type Paths = Option<Vec<String>>;

fn unit_rules(ctx: &Ctx, unit: u64) -> Res<(Paths, Paths)> {
    let queue_path = ctx.path("queue.json");
    let queue: Value = read_json(&queue_path).ok_or_else(|| {
        Fail::usage(format!(
            "no queue in {}; run `tracker render` first",
            queue_path.display()
        ))
    })?;
    let id = format!("U{unit}");
    let entry = queue["units"]
        .as_array()
        .and_then(|units| units.iter().find(|u| u["id"] == id))
        .ok_or_else(|| Fail::usage(format!("queue.json has no unit {id}")))?;
    let list = |key: &str| -> Option<Vec<String>> {
        let items: Vec<String> = entry[key]
            .as_array()?
            .iter()
            .filter_map(|v| v.as_str().map(str::to_string))
            .collect();
        (!items.is_empty()).then_some(items)
    };
    Ok((list("files"), list("acceptance_tests")))
}

pub fn run(ctx: &Ctx, args: &Args) -> Res<()> {
    let dir = Path::new(".");
    let unit = args.unit;
    let (scope, acceptance) = unit_rules(ctx, unit)?;
    let head = resolve(dir, args.head.as_deref().unwrap_or("HEAD"), "--head")?;
    let base = match &args.base {
        Some(base) => resolve(dir, base, "--base")?,
        None => git::base_commit(dir, &ctx.profile.base_branch).ok_or_else(|| {
            Fail::failed(format!(
                "no refs/remotes/origin/{} here; fetch it or pass --base",
                ctx.profile.base_branch
            ))
        })?,
    };
    let range = format!("{base}...{head}");
    let numstat = git_out(
        dir,
        &["diff", "--numstat", "-z", "--no-renames", "--no-ext-diff", &range, "--"],
    )?;
    let patch = git_out(
        dir,
        &[
            "-c",
            "core.quotePath=false",
            "diff",
            "-U0",
            "--no-renames",
            "--no-ext-diff",
            "--no-color",
            "--src-prefix=a/",
            "--dst-prefix=b/",
            &range,
            "--",
        ],
    )?;
    let changes = parse_numstat(&numstat);
    let (added, deleted) = changes.iter().fold((0, 0), |(a, d), c| (a + c.added, d + c.deleted));
    let input = Input {
        changes,
        added_lines: parse_added(&patch),
        scope,
        acceptance,
    };
    let verdict = judge(&input, &|p| ctx.profile.is_protected(p), &|p| ctx.profile.is_frozen(p));
    let ok = verdict.failures.is_empty();
    let failures: Vec<Value> = verdict
        .failures
        .iter()
        .map(|f| json!({"code": f.code, "message": f.message}))
        .collect();
    let shortcuts: Vec<Value> = verdict
        .shortcuts
        .iter()
        .map(|s| json!({"file": s.file, "line": s.line, "text": s.text}))
        .collect();
    let out = json!({
        "unit": unit,
        "ok": ok,
        "head": head,
        "base": base,
        "files_changed": input.changes.len(),
        "additions": added,
        "deletions": deleted,
        "scope_checked": input.scope.is_some(),
        "acceptance_checked": input.acceptance.is_some(),
        "failures": failures,
        "flags": {"new_dependency": verdict.new_dependency, "shortcuts": shortcuts},
    });
    write_json(&ctx.path(&format!("units/{unit}/deliver.json")), &out)?;
    let codes: Vec<&str> = verdict.failures.iter().map(|f| f.code).collect();
    if let Err(e) = ctx.event(
        "deliver_check",
        json!({"unit": unit, "head": head, "ok": ok, "failures": codes}),
    ) {
        eprintln!(
            "issue-drain: warning: the deliver-check result was not logged: {}",
            e.msg
        );
    }
    println!("{out}");
    if ok {
        Ok(())
    } else {
        Err(Fail::refused(format!(
            "unit {unit} is not deliverable: {}",
            codes.join(", ")
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn change(path: &str, added: u64, deleted: u64) -> Change {
        Change {
            path: path.into(),
            added,
            deleted,
        }
    }

    fn input(changes: Vec<Change>) -> Input {
        Input {
            changes,
            added_lines: Vec::new(),
            scope: Some(vec!["src/timer/".into(), "src/lib/format.ts".into()]),
            acceptance: None,
        }
    }

    fn codes(v: &Verdict) -> Vec<&'static str> {
        v.failures.iter().map(|f| f.code).collect()
    }

    fn judge_plain(i: &Input) -> Verdict {
        judge(i, &|p| p.starts_with(".github/"), &|p| p.starts_with("vendor/"))
    }

    #[test]
    fn a_diff_inside_scope_is_clean() {
        let v = judge_plain(&input(vec![
            change("src/timer/a.ts", 5, 2),
            change("src/lib/format.ts", 1, 1),
        ]));
        assert!(v.failures.is_empty(), "{:?}", v.failures);
    }

    #[test]
    fn each_rule_fails_with_its_code() {
        assert_eq!(codes(&judge_plain(&input(vec![]))), ["empty_diff"]);
        assert_eq!(
            codes(&judge_plain(&input(vec![change("src/other.ts", 1, 0)]))),
            ["out_of_scope"]
        );
        let mut open = input(vec![change(".github/ci.yml", 1, 0), change("vendor/x.js", 1, 0)]);
        open.scope = None;
        assert_eq!(codes(&judge_plain(&open)), ["protected_path", "frozen_path"]);
        assert_eq!(
            codes(&judge_plain(&input(vec![change("src/timer/a.ts", 10, 101)]))),
            ["net_destructive"]
        );
    }

    #[test]
    fn every_failure_is_reported_not_the_first() {
        let v = judge_plain(&input(vec![change(".github/ci.yml", 0, 500)]));
        assert_eq!(codes(&v), ["out_of_scope", "protected_path", "net_destructive"]);
    }

    #[test]
    fn net_destructive_needs_both_the_factor_and_the_floor() {
        let at = |a, d| codes(&judge_plain(&input(vec![change("src/timer/a.ts", a, d)])));
        assert!(at(0, 100).is_empty(), "100 deletions is at the floor, not over it");
        assert_eq!(at(0, 101), ["net_destructive"]);
        assert!(at(40, 120).is_empty(), "3x exactly is not over the factor");
        assert_eq!(at(40, 121), ["net_destructive"]);
        assert!(at(10, 30).is_empty(), "over the factor but under the floor");
    }

    #[test]
    fn a_named_acceptance_test_must_be_in_the_diff_and_is_in_scope() {
        let mut i = input(vec![change("src/timer/a.ts", 1, 0)]);
        i.acceptance = Some(vec!["tests/timer.test.ts".into()]);
        assert_eq!(codes(&judge_plain(&i)), ["acceptance_missing"]);
        i.changes.push(change("tests/timer.test.ts", 9, 0));
        assert!(judge_plain(&i).failures.is_empty());
    }

    #[test]
    fn no_scope_and_no_acceptance_skip_those_rules() {
        let mut i = input(vec![change("anywhere/x.ts", 1, 0)]);
        i.scope = None;
        assert!(judge_plain(&i).failures.is_empty());
    }

    #[test]
    fn manifests_with_added_lines_are_flagged_and_do_not_fail() {
        let mut i = input(vec![
            change("package.json", 2, 0),
            change("api/requirements-dev.txt", 1, 0),
            change("Cargo.toml", 0, 3),
            change("src/timer/a.ts", 1, 0),
        ]);
        i.scope = None;
        let v = judge_plain(&i);
        assert!(v.failures.is_empty());
        assert_eq!(v.new_dependency, ["package.json", "api/requirements-dev.txt"]);
    }

    #[test]
    fn only_added_lines_with_the_marker_are_shortcuts() {
        let mut i = input(vec![change("src/timer/a.ts", 2, 0)]);
        i.added_lines = vec![
            AddedLine {
                file: "src/timer/a.ts".into(),
                line: 4,
                text: "// shortcut: skip the cache".into(),
            },
            AddedLine {
                file: "src/timer/a.ts".into(),
                line: 5,
                text: "plain".into(),
            },
        ];
        let v = judge_plain(&i);
        assert_eq!(v.shortcuts.len(), 1);
        assert_eq!(v.shortcuts[0].line, 4);
    }

    #[test]
    fn numstat_reads_paths_with_spaces_and_binary_files() {
        let got = parse_numstat("3\t1\ta b.ts\0-\t-\timg.png\0");
        assert_eq!(got, [change("a b.ts", 3, 1), change("img.png", 0, 0)]);
    }

    #[test]
    fn a_patch_gives_each_added_line_its_number() {
        let patch = "diff --git a/x.ts b/x.ts\n--- a/x.ts\n+++ b/x.ts\n@@ -2,2 +2,3 @@\n-old\n-older\n+one\n++ b/trap\n+// shortcut: x\n@@ -9 +11 @@\n-gone\n+kept\n\\ No newline at end of file\n";
        let got = parse_added(patch);
        let at = |i: usize| (got[i].line, got[i].text.as_str());
        assert_eq!(got.len(), 4);
        assert_eq!(at(0), (2, "one"));
        assert_eq!(at(1), (3, "+ b/trap"));
        assert_eq!(at(2), (4, "// shortcut: x"));
        assert_eq!((got[3].file.as_str(), at(3)), ("x.ts", (11, "kept")));
    }
}
