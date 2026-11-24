//! `issue-drain post-merge --unit <n> --pr <n>`: the checks after a unit's PR
//! merged (plan step 9).
//!
//! 1. The PR must be MERGED, and it must be the unit's: aimed at the profile's
//!    base branch, from the branch `unit.json` names, in the profile's
//!    repository (`merge_gate::binding`). Exit 3 otherwise.
//! 2. Tree check: the merge commit's tree is compared with the tree of the PR
//!    head the gate approved, in the unit's worktree when it still exists, else
//!    in the repo checkout. A different tree is not an error: the base moved
//!    between the gate and the merge, so the base tip needs a verify of its
//!    own. It is reported as `tree_match: false` and said on stderr.
//! 3. Closures: the unit's queued issues that the PR names as closed (its
//!    same-repository closing references, or a closing keyword in its body),
//!    narrowed to `result.json` `closes` when that file exists. An issue the
//!    unit was not queued with is never touched, whatever the PR says. GitHub
//!    closes them itself on a merge into the default branch, but a merge into
//!    another base branch does not, and the autoclose can lag. Each is read,
//!    polling up to ISSUE_DRAIN_POST_MERGE_WAIT_SECS (default 60). One still
//!    open is read again: if it now carries a hold label (the profile's or
//!    `needs-human`, `ready-for-human`, `security-review`) it is left open for
//!    a person and listed in `held`; otherwise it is closed here with a
//!    comment, through `gh::write` (the same path `close-verified` uses), and
//!    read back. The comment opens with a marker line, and a retry that finds
//!    its own marked comment on the issue does not post it again.
//! 4. The unit's claim is released (`claim::release_unit`) once every issue is
//!    closed; a run without `tracker.json` took no claim.
//!
//! It does not remove the worktree (`cleanup --unit` does) and does not edit
//! the tracker. With ISSUE_DRAIN_DRY_RUN=1 the reads happen and the writes
//! print `WOULD: ...`; the issues it would close are listed in `closed_here`.
//!
//! Exit: 0 done (a tree mismatch included); 3 the PR is not merged or not the
//! unit's, an issue is held for a person, or a unit process asked; 1 GitHub or
//! git failed, or an issue is still open; 2 usage.

use std::fs;
use std::path::PathBuf;
use std::sync::LazyLock;
use std::thread::sleep;
use std::time::{Duration, Instant};

use regex::Regex;
use serde_json::{Value, json};

use crate::claim;
use crate::ctx::{Ctx, env_str, read_json, write_atomic};
use crate::error::{Fail, Res};
use crate::exec;
use crate::gh::{self, Write};
use crate::git;
use crate::merge_gate::{self, ALWAYS_HOLD, PrState, PrView, UnitBranch, is_sha};
use crate::profile::same_label;
use crate::text::sha7;

#[derive(clap::Args)]
pub struct Args {
    /// The unit; its files are under <run folder>/units/<n>/.
    #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
    pub unit: u64,
    /// The unit's merged pull request.
    #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
    pub pr: u64,
}

const GIT_LIMIT: Duration = Duration::from_secs(120);
const DEFAULT_WAIT_SECS: u64 = 60;
const POLL: Duration = Duration::from_secs(5);

/// A closing keyword and the issue it names, as GitHub reads a PR body:
/// `Fixes #12`, `closes: owner/repo#12`.
static CLOSING_KEYWORD: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s+(?:([\w.-]+/[\w.-]+))?#(\d+)\b")
        .expect("a fixed pattern")
});

static HTML_COMMENT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?s)<!--.*?-->").expect("a fixed pattern"));

/// `body` without the text GitHub does not read for closing keywords: fenced
/// code blocks, indented code, HTML comments and inline code. A PR body that
/// quotes "Fixes #12" as an example does not close #12. Every line indented by
/// four spaces or a tab is dropped, nested list items too: a keyword missed
/// here leaves an issue open, which is the safe way to be wrong.
fn prose(body: &str) -> String {
    let mut kept = String::new();
    let mut fence: Option<(char, usize)> = None;
    for line in body.lines() {
        let trimmed = line.trim_start();
        let run = |c: char| trimmed.chars().take_while(|&x| x == c).count();
        match fence {
            Some((c, n)) => {
                if run(c) >= n && trimmed.trim_start_matches(c).trim().is_empty() {
                    fence = None;
                }
            }
            None => {
                let opener = ['`', '~'].into_iter().map(|c| (c, run(c))).find(|&(_, n)| n >= 3);
                match opener {
                    Some(open) => fence = Some(open),
                    None if line.starts_with("    ") || line.starts_with('\t') => {}
                    None => {
                        kept.push_str(line);
                        kept.push('\n');
                    }
                }
            }
        }
    }
    let kept = HTML_COMMENT.replace_all(&kept, " ");
    without_code_spans(&kept)
}

/// `text` with each inline code span replaced by a space. A span opens with a
/// run of backticks and closes at the next run of the same length, so
/// ``` ``Fixes #1`` ``` is code too. A run with no closer is literal text.
fn without_code_spans(text: &str) -> String {
    let b = text.as_bytes();
    let run_at = |i: usize| b[i..].iter().take_while(|&&c| c == b'`').count();
    let mut out = String::with_capacity(text.len());
    let (mut i, mut copied) = (0, 0);
    while i < b.len() {
        // A backtick is escaped by an odd run of backslashes before it; after
        // an even run the backslashes escape each other and the tick opens.
        let escapes = b[..i].iter().rev().take_while(|&&c| c == b'\\').count();
        if b[i] != b'`' || escapes % 2 == 1 {
            i += 1;
            continue;
        }
        let n = run_at(i);
        let mut j = i + n;
        let block = block_end(text, j);
        let close = loop {
            match b[j..block].iter().position(|&c| c == b'`') {
                None => break None,
                Some(k) => {
                    let m = b[j + k..block].iter().take_while(|&&c| c == b'`').count();
                    if m == n {
                        break Some(j + k + m);
                    }
                    j += k + m;
                }
            }
        };
        match close {
            Some(end) => {
                out.push_str(&text[copied..i]);
                out.push(' ');
                copied = end;
                i = end;
            }
            None => i += n,
        }
    }
    out.push_str(&text[copied..]);
    out
}

/// Where the block that holds `from` ends: at the next blank line, or the end
/// of the text. A code span cannot cross a blank line.
fn block_end(text: &str, from: usize) -> usize {
    let mut at = from;
    for line in text[from..].split_inclusive('\n') {
        // Blank means spaces and tabs only, as Markdown counts it; a line of
        // other whitespace (a no-break space) does not end a paragraph.
        let content = line
            .strip_suffix('\n')
            .map_or(line, |l| l.strip_suffix('\r').unwrap_or(l));
        if at > from && content.bytes().all(|c| c == b' ' || c == b'\t') {
            return at;
        }
        at += line.len();
    }
    text.len()
}

/// The issues in `repo` that `body` says it closes.
fn body_closes(body: &str, repo: &str) -> Vec<u64> {
    CLOSING_KEYWORD
        .captures_iter(&prose(body))
        .filter(|c| c.get(1).is_none_or(|r| r.as_str().eq_ignore_ascii_case(repo)))
        .filter_map(|c| c[2].parse().ok())
        .collect()
}

fn state_name(state: PrState) -> &'static str {
    match state {
        PrState::Open => "OPEN",
        PrState::Closed => "CLOSED",
        PrState::Merged => "MERGED",
        PrState::Other => "in an unknown state",
    }
}

/// Where the trees are compared: the unit's worktree while it exists.
fn compare_dir(ctx: &Ctx, unit: u64) -> Res<PathBuf> {
    let unit_json: Option<Value> = read_json(&ctx.path(&format!("units/{unit}/unit.json")));
    let worktree = unit_json
        .as_ref()
        .and_then(|u| u["worktree"].as_str())
        .map(PathBuf::from)
        .filter(|w| w.is_absolute() && git::ok(w, &["rev-parse", "--git-dir"]));
    match worktree {
        Some(w) => Ok(w),
        None => ctx.repo_dir(),
    }
}

/// Whether the merge commit and the approved head hold the same tree.
fn trees_match(ctx: &Ctx, unit: u64, merge: &str, head: &str) -> Res<bool> {
    let dir = compare_dir(ctx, unit)?;
    let log = ctx.path(&format!("units/{unit}/post-merge.log"));
    let base = &ctx.profile.base_branch;
    let refspec = format!("+refs/heads/{base}:refs/remotes/origin/{base}");
    let fetched = exec::git(&dir, &["fetch", "--quiet", "origin", &refspec], GIT_LIMIT, &log)?;
    if !fetched.ok() {
        return Err(Fail::failed(format!(
            "could not fetch {base} in {}: {}",
            dir.display(),
            fetched.failure(GIT_LIMIT)
        )));
    }
    for sha in [merge, head] {
        if git::commit(&dir, sha).is_none() {
            // Best effort: a commit the base fetch did not bring (the PR head).
            let _ = exec::git(&dir, &["fetch", "--quiet", "origin", sha], GIT_LIMIT, &log)?;
        }
        if git::commit(&dir, sha).is_none() {
            return Err(Fail::failed(format!(
                "commit {} is not in {}",
                sha7(sha),
                dir.display()
            )));
        }
    }
    let tree = |sha: &str| {
        git::out(&dir, &["rev-parse", &format!("{sha}^{{tree}}")])
            .map(|t| t.trim().to_string())
            .ok_or_else(|| Fail::failed(format!("git cannot read the tree of {}", sha7(sha))))
    };
    Ok(tree(merge)? == tree(head)?)
}

/// The issues to check: the unit's queued issues that the PR names as closed
/// (same-repository closing references or body keywords), narrowed to what
/// the unit's result.json says it closes when there is one.
fn closing_issues(ctx: &Ctx, unit: u64, repo: &str, view: &PrView) -> Res<Vec<u64>> {
    let queued = ctx.queue_unit(unit)?.issues;
    let mut named: Vec<u64> = view
        .closing
        .iter()
        .filter(|c| c.repo.eq_ignore_ascii_case(repo))
        .map(|c| c.number)
        .collect();
    named.extend(body_closes(&view.body, repo));
    named.retain(|n| queued.contains(n));
    if let Some(result) = read_json::<Value>(&ctx.path(&format!("units/{unit}/result.json")))
        && let Some(closes) = result["closes"].as_array()
    {
        let closes: Vec<u64> = closes.iter().filter_map(Value::as_u64).collect();
        named.retain(|n| closes.contains(n));
    }
    named.sort_unstable();
    named.dedup();
    Ok(named)
}

/// An issue's state and labels.
struct Issue {
    state: String,
    labels: Vec<String>,
}

fn read_issue(repo: &str, number: u64) -> Res<Issue> {
    let unread = || Fail::failed(format!("could not read #{number}"));
    let raw = gh::read(&[
        "issue",
        "view",
        &number.to_string(),
        "--repo",
        repo,
        "--json",
        "state,labels",
    ])
    .map_err(|_| unread())?;
    let value: Value = serde_json::from_str(&raw).map_err(|_| unread())?;
    let state = value["state"].as_str().ok_or_else(unread)?.to_string();
    let labels = value["labels"]
        .as_array()
        .ok_or_else(unread)?
        .iter()
        .map(|l| l["name"].as_str().map(str::to_string).ok_or_else(unread))
        .collect::<Res<Vec<String>>>()?;
    Ok(Issue { state, labels })
}

/// The hold label on `labels`, if any.
fn hold(ctx: &Ctx, labels: &[String]) -> Option<String> {
    labels
        .iter()
        .find(|l| {
            ctx.profile
                .hold_labels
                .iter()
                .map(String::as_str)
                .chain(ALWAYS_HOLD)
                .any(|h| same_label(l, h))
        })
        .cloned()
}

/// The first line of the closing comment, so a retry can find its own.
fn comment_marker(pr: u64, merge: &str) -> String {
    format!("<!-- issue-drain:post-merge pr={pr} merge={merge} -->")
}

/// Whether `me` already posted the marked closing comment on the issue.
fn commented(repo: &str, number: u64, marker: &str, me: &str) -> Res<bool> {
    let raw = gh::read(&[
        "api",
        &format!("repos/{repo}/issues/{number}/comments?per_page=100"),
        "--paginate",
    ])
    .map_err(|rc| Fail::failed(format!("could not read the comments on #{number} (gh exit {rc})")))?;
    merge_gate::marked_comment(&raw, marker, me)
        .map_err(|e| Fail::failed(format!("could not read the comments on #{number}: {e}")))
}

fn whoami() -> Res<String> {
    gh::read(&["api", "user", "--jq", ".login"])
        .ok()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
        .ok_or_else(|| Fail::failed("could not read who gh is logged in as"))
}

fn wait_limit() -> Duration {
    let secs = env_str("ISSUE_DRAIN_POST_MERGE_WAIT_SECS")
        .parse()
        .unwrap_or(DEFAULT_WAIT_SECS);
    Duration::from_secs(secs)
}

/// Read each issue, again and again until all are closed or the wait is over.
/// Returns (closed, still open).
fn await_autoclose(repo: &str, issues: &[u64]) -> Res<(Vec<u64>, Vec<u64>)> {
    let deadline = Instant::now() + wait_limit();
    let mut closed = Vec::new();
    let mut open: Vec<u64> = issues.to_vec();
    loop {
        let mut still = Vec::new();
        for &n in &open {
            if read_issue(repo, n)?.state == "CLOSED" {
                closed.push(n);
            } else {
                still.push(n);
            }
        }
        open = still;
        let now = Instant::now();
        if open.is_empty() || now >= deadline {
            return Ok((closed, open));
        }
        sleep(POLL.min(deadline - now));
    }
}

pub fn run(ctx: &Ctx, args: &Args) -> Res<()> {
    ctx.require_driver("post-merge")?;
    let (unit, pr) = (args.unit, args.pr);
    let repo = ctx.repo()?;
    let view = merge_gate::read_view(&repo, pr).map_err(|e| Fail::failed(format!("could not read PR #{pr}: {e}")))?;
    if view.state != PrState::Merged {
        return Err(Fail::refused(format!(
            "PR #{pr} is {}, not MERGED",
            state_name(view.state)
        )));
    }
    let branch = merge_gate::unit_file::<UnitBranch>(ctx, unit, "unit.json").map(|u| u.branch);
    let refusals = merge_gate::binding(&repo, &ctx.profile.base_branch, unit, pr, &view, &branch);
    if !refusals.is_empty() {
        let why: Vec<String> = refusals.into_iter().map(|r| r.detail).collect();
        return Err(Fail::refused(why.join("; ")));
    }
    let merge = view
        .merge_commit
        .clone()
        .filter(|s| is_sha(s))
        .ok_or_else(|| Fail::failed(format!("PR #{pr} is merged but names no merge commit")))?;
    let record = ctx.path(&format!("units/{unit}/{}", merge_gate::APPROVED_HEAD));
    let head = match fs::read_to_string(&record) {
        Ok(text) if is_sha(text.trim()) => text.trim().to_string(),
        Ok(_) => {
            return Err(Fail::failed(format!("{} does not hold a commit SHA", record.display())));
        }
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
            return Err(Fail::failed(format!("could not read {}: {e}", record.display())));
        }
        Err(_) => {
            eprintln!(
                "issue-drain post-merge: there is no record of the head the gate approved for unit {unit}; comparing with the PR's current head"
            );
            view.head.clone()
        }
    };

    let tree_match = trees_match(ctx, unit, &merge, &head)?;
    if !tree_match {
        eprintln!(
            "issue-drain post-merge: the merge commit {} does not hold the tree of the approved head {}: {} moved between the gate and the merge. Run a verify of the {} tip.",
            sha7(&merge),
            sha7(&head),
            ctx.profile.base_branch,
            ctx.profile.base_branch
        );
    }

    let issues = closing_issues(ctx, unit, &repo, &view)?;
    let (mut closed_by_merge, open) = await_autoclose(&repo, &issues)?;
    let mut closed_here = Vec::new();
    let mut still_open = Vec::new();
    let mut held: Vec<Value> = Vec::new();
    let marker = comment_marker(pr, &merge);
    let me = if open.is_empty() { String::new() } else { whoami()? };
    for number in open {
        // Read again: a hold label may have arrived while the PR waited.
        let now = read_issue(&repo, number)?;
        if now.state == "CLOSED" {
            closed_by_merge.push(number);
            continue;
        }
        if let Some(label) = hold(ctx, &now.labels) {
            held.push(json!({"issue": number, "label": label}));
            continue;
        }
        if !commented(&repo, number, &marker, &me)? {
            let body = format!("{marker}\n\nFixed by #{pr} (merged as {}).\n", sha7(&merge));
            let file = ctx.path(&format!("units/{unit}/post-merge-{number}.md"));
            write_atomic(&file, body.as_bytes())?;
            gh::write(
                ctx,
                &Write::Comment {
                    number,
                    body_file: &file,
                },
            )?;
        }
        gh::write(ctx, &Write::CloseIssue { number })?;
        // A dry run wrote nothing, so there is nothing to read back.
        if ctx.dry_run || read_issue(&repo, number)?.state == "CLOSED" {
            closed_here.push(number);
        } else {
            still_open.push(number);
        }
    }

    // A claim is released only when the unit's issues are all closed.
    let mut claims_released: Vec<u64> = Vec::new();
    if still_open.is_empty() && held.is_empty() && ctx.path("tracker.json").is_file() {
        let report = claim::release_unit(ctx, unit)?;
        claims_released = report
            .iter()
            .filter(|r| r["action"] == "released")
            .filter_map(|r| r["issue"].as_u64())
            .collect();
    }

    let mut out = json!({
        "unit": unit,
        "pr": pr,
        "merge_commit": merge,
        "head": head,
        "tree_match": tree_match,
        "closed_by_merge": closed_by_merge,
        "closed_here": closed_here,
        "still_open": still_open,
        "held": held,
        "claims_released": claims_released,
    });
    if ctx.dry_run {
        out["dry_run"] = json!(true);
    }
    ctx.event("post_merge", out.clone())?;
    println!("{out}");
    if !still_open.is_empty() {
        let list: Vec<String> = still_open.iter().map(|n| format!("#{n}")).collect();
        return Err(Fail::failed(format!(
            "still open after the merge and a close call: {}",
            list.join(", ")
        )));
    }
    if !held.is_empty() {
        let list: Vec<String> = held
            .iter()
            .map(|h| format!("#{} carries '{}'", h["issue"], h["label"].as_str().unwrap_or_default()))
            .collect();
        return Err(Fail::refused(format!("left open for a person: {}", list.join(", "))));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn closing_keywords_in_code_and_comments_close_nothing() {
        let body = "Fixes #101\n\
                    \n\
                    ```text\n\
                    Fixes #102\n\
                    ```\n\
                    ~~~~\n\
                    closes #103\n\
                    ```\n\
                    ~~~~\n\
                    <!-- Resolves #104\n\
                    still a comment -->\n\
                    An example: `Fixes #105`.\n\
                    Closes example/tidepool#106 and closes other/repo#107\n";
        assert_eq!(body_closes(body, "example/tidepool"), vec![101, 106]);
    }

    #[test]
    fn indented_code_closes_nothing() {
        let body = "Fixes #1\n\nFor example:\n\n    Fixes #2\n\tCloses #3\n";
        assert_eq!(body_closes(body, "a/b"), vec![1]);
    }

    #[test]
    fn a_code_span_of_any_backtick_run_closes_nothing() {
        let body = "Fixes #1, ``Fixes #2``, ```fixes #3 `x` ```.";
        assert_eq!(body_closes(body, "a/b"), vec![1]);
        // A run with no closer of its own length is literal, as GitHub reads it.
        assert_eq!(body_closes("``close #4` and fixes #5", "a/b"), vec![4, 5]);
        assert_eq!(body_closes("A lone ` then Fixes #6", "a/b"), vec![6]);
    }

    #[test]
    fn a_code_span_does_not_cross_a_blank_line() {
        let body = "A lone ` here.\n\nFixes #1 and `Fixes #2`.";
        assert_eq!(body_closes(body, "a/b"), vec![1]);
    }

    #[test]
    fn an_escaped_backtick_opens_nothing() {
        let body = "A \\` here, then Fixes #1 and `Fixes #2`.";
        assert_eq!(body_closes(body, "a/b"), vec![1]);
    }

    #[test]
    fn a_backtick_after_an_escaped_backslash_opens_a_span() {
        // Two backslashes escape each other, so the tick after them is code.
        let body = "A \\\\`Fixes #2` and Fixes #1.";
        assert_eq!(body_closes(body, "a/b"), vec![1]);
        let odd = "A \\\\\\` here, then Fixes #3 and `Fixes #4`.";
        assert_eq!(body_closes(odd, "a/b"), vec![3]);
    }

    #[test]
    fn a_line_of_other_whitespace_is_not_blank() {
        let body = "`Fixes #1\n\u{a0}\nstill code` and Fixes #2.";
        assert_eq!(body_closes(body, "a/b"), vec![2]);
        let spaces = "A lone ` here.\n \t\r\nFixes #3 and `Fixes #4`.";
        assert_eq!(body_closes(spaces, "a/b"), vec![3]);
    }

    #[test]
    fn an_unclosed_fence_hides_the_rest_of_the_body() {
        assert_eq!(body_closes("Fixes #1\n```\nFixes #2\n", "a/b"), vec![1]);
    }
}
