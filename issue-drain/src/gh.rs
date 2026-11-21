//! Every call to `gh`, and the one path by which issue-drain writes to GitHub.
//!
//! Why one write path: pr-drain's poller once merged 12 PRs with 11 review
//! threads still open, because the thread gate only watched Claude's own Bash
//! calls. A rule that lives in the one write path cannot be skipped by a
//! second path. Three rules live in `write`:
//!   - dry-run is one switch: with ISSUE_DRAIN_DRY_RUN=1 every write prints
//!     "WOULD: ..." and calls nothing;
//!   - labels are limited to the three the drain owns (claim, blocked,
//!     tracker), and only the claim label can be removed;
//!   - a unit process (ISSUE_DRAIN_MODE=unit) can use the verbs in `unit_may` and nothing else.
//!     Claims, hold labels and closures belong to the driver and the session.
//!
//! Bodies come from a file, never from an argument, so issue text never meets
//! argument parsing.

use std::path::Path;
use std::process::{Command, Stdio};

use serde_json::json;

use crate::ctx::{Ctx, Mode};
use crate::error::{Fail, Res};
use crate::text::parse_number;

pub enum Write<'a> {
    /// Create the tracker issue, labelled with the tracker label.
    IssueCreate {
        title: &'a str,
        body_file: &'a Path,
    },
    Comment {
        number: u64,
        body_file: &'a Path,
    },
    EnsureLabel {
        label: &'a str,
    },
    AddLabel {
        number: u64,
        label: &'a str,
    },
    RemoveLabel {
        number: u64,
        label: &'a str,
    },
    CloseIssue {
        number: u64,
    },
    /// Squash-merge a PR, only if its head is still `head`. Reached only from
    /// `merge-gate`, which holds every condition a merge needs.
    MergePr {
        number: u64,
        head: &'a str,
    },
    /// Open a PR. The body comes from a file.
    PrCreate {
        head: &'a str,
        base: &'a str,
        title: &'a str,
        body_file: &'a Path,
        draft: bool,
        labels: &'a [String],
    },
    /// Reply on a review thread (a GraphQL node id).
    ThreadReply {
        thread: &'a str,
        body_file: &'a Path,
    },
    ThreadResolve {
        thread: &'a str,
    },
}

/// The argument list of the merge call. It is built here and nowhere else, and
/// it carries no flag that skips a requirement or defers the merge.
pub fn merge_argv(repo: &str, number: u64, head: &str) -> Vec<String> {
    [
        "pr",
        "merge",
        &number.to_string(),
        "--repo",
        repo,
        "--squash",
        "--match-head-commit",
        head,
    ]
    .map(str::to_string)
    .to_vec()
}

pub fn pr_create_argv(
    repo: &str,
    head: &str,
    base: &str,
    title: &str,
    body_file: &Path,
    draft: bool,
    labels: &[String],
) -> Vec<String> {
    let mut argv: Vec<String> = [
        "pr", "create", "--repo", repo, "--head", head, "--base", base, "--title", title,
    ]
    .map(str::to_string)
    .to_vec();
    argv.push("--body-file".into());
    argv.push(body_file.display().to_string());
    if draft {
        argv.push("--draft".into());
    }
    for label in labels {
        argv.push("--label".into());
        argv.push(label.clone());
    }
    argv
}

const THREAD_REPLY_QUERY: &str = "mutation($id:ID!,$body:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$id,body:$body}){comment{id}}}";
const THREAD_RESOLVE_QUERY: &str =
    "mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{id isResolved}}}";

/// `-f id=` sends the id as a string, whatever it looks like; `-F body=@file`
/// reads the body from the file, so it never passes through an argument.
pub fn thread_reply_argv(thread: &str, body_file: &Path) -> Vec<String> {
    let body = format!("body=@{}", body_file.display());
    [
        "api",
        "graphql",
        "-f",
        &format!("query={THREAD_REPLY_QUERY}"),
        "-f",
        &format!("id={thread}"),
        "-F",
        &body,
    ]
    .map(str::to_string)
    .to_vec()
}

pub fn thread_resolve_argv(thread: &str) -> Vec<String> {
    [
        "api",
        "graphql",
        "-f",
        &format!("query={THREAD_RESOLVE_QUERY}"),
        "-f",
        &format!("id={thread}"),
    ]
    .map(str::to_string)
    .to_vec()
}

/// What a unit (ISSUE_DRAIN_MODE=unit) may ask of `gh-write`. A verb is refused
/// until it is listed here, so a verb added later is the driver's by default.
pub fn unit_may(verb: &str) -> bool {
    matches!(
        verb,
        "comment" | "add-label" | "ensure-label" | "pr-create" | "thread-reply" | "thread-resolve"
    )
}

fn thread_ok(thread: &str) -> bool {
    !thread.is_empty() && thread.bytes().all(|b| b.is_ascii_alphanumeric() || b"_=-".contains(&b))
}

impl Write<'_> {
    fn verb(&self) -> &'static str {
        match self {
            Write::IssueCreate { .. } => "issue-create",
            Write::Comment { .. } => "comment",
            Write::EnsureLabel { .. } => "ensure-label",
            Write::AddLabel { .. } => "add-label",
            Write::RemoveLabel { .. } => "remove-label",
            Write::CloseIssue { .. } => "close-issue",
            Write::MergePr { .. } => "merge-pr",
            Write::PrCreate { .. } => "pr-create",
            Write::ThreadReply { .. } => "thread-reply",
            Write::ThreadResolve { .. } => "thread-resolve",
        }
    }
}

pub struct Written {
    /// False in a dry run, and when `ensure-label` found the label in place.
    pub called: bool,
    pub stdout: String,
}

/// gh, with the host pinned. A repo is named `owner/repo`, and the checkout's
/// origin is checked to be on github.com; a GH_HOST left in the environment
/// would send the same `owner/repo` to another GitHub.
fn gh() -> Command {
    let mut command = Command::new("gh");
    command.env("GH_HOST", "github.com").stdin(Stdio::null());
    command
}

/// Run gh for a read: its exit code and its stdout, whatever the code. gh's
/// stderr is dropped: every caller turns a failure into its own message.
pub fn read_raw(args: &[&str]) -> (i32, String) {
    match gh().args(args).stderr(Stdio::null()).output() {
        Ok(out) => (
            out.status.code().unwrap_or(1),
            String::from_utf8_lossy(&out.stdout).into_owned(),
        ),
        Err(_) => (127, String::new()),
    }
}

/// Run gh for a read. stdout on exit 0, else gh's exit code.
pub fn read(args: &[&str]) -> Result<String, i32> {
    match read_raw(args) {
        (0, stdout) => Ok(stdout),
        (rc, _) => Err(rc),
    }
}

fn refuse(ctx: &Ctx, verb: &str, mode: Mode, why: String) -> Fail {
    let logged = ctx.event(
        "gh_write_refused",
        json!({"verb": verb, "why": why, "mode": mode.as_str()}),
    );
    match logged {
        Ok(()) => Fail::refused(format!("refused: {why}")),
        Err(e) => e,
    }
}

fn need_body(file: &Path) -> Res<()> {
    match std::fs::metadata(file) {
        Ok(meta) if meta.is_file() && meta.len() > 0 => Ok(()),
        _ => Err(Fail::usage(format!(
            "body file is missing or empty: {}",
            file.display()
        ))),
    }
}

pub fn write(ctx: &Ctx, w: &Write) -> Res<Written> {
    let repo = ctx.repo()?;
    let mode = ctx.mode()?;
    let p = &ctx.profile;
    let verb = w.verb();
    if mode == Mode::Unit && !unit_may(verb) {
        return Err(refuse(ctx, verb, mode, format!("{verb} is the driver's job in a unit")));
    }

    let own = |s: &str| s.to_string();
    let (what, argv): (String, Vec<String>) = match w {
        Write::IssueCreate { title, body_file } => {
            need_body(body_file)?;
            if title.is_empty() {
                return Err(Fail::usage("issue-create needs --title"));
            }
            (
                "tracker issue".into(),
                vec![
                    own("issue"),
                    own("create"),
                    own("--repo"),
                    repo,
                    own("--title"),
                    own(title),
                    own("--body-file"),
                    body_file.display().to_string(),
                    own("--label"),
                    p.tracker_label.clone(),
                ],
            )
        }
        Write::Comment { number, body_file } => {
            need_body(body_file)?;
            (
                format!("comment on #{number}"),
                vec![
                    own("issue"),
                    own("comment"),
                    number.to_string(),
                    own("--repo"),
                    repo,
                    own("--body-file"),
                    body_file.display().to_string(),
                ],
            )
        }
        Write::EnsureLabel { label } => {
            if ![&p.claim_label, &p.blocked_label, &p.tracker_label]
                .iter()
                .any(|l| l == label)
            {
                return Err(refuse(
                    ctx,
                    verb,
                    mode,
                    format!(
                        "'{label}' is not a label the drain owns ({}, {}, {})",
                        p.claim_label, p.blocked_label, p.tracker_label
                    ),
                ));
            }
            if !ctx.dry_run {
                let listed = read(&[
                    "label", "list", "--repo", &repo, "--search", label, "--json", "name", "--jq", ".[].name",
                ])
                .map_err(|rc| Fail::failed(format!("could not list the labels of {repo} (gh exit {rc})")))?;
                if listed.lines().any(|name| crate::profile::same_label(name, label)) {
                    return Ok(Written {
                        called: false,
                        stdout: String::new(),
                    });
                }
            }
            // No --force: an existing label keeps the colour and text its owner gave it.
            (
                format!("label {label}"),
                vec![own("label"), own("create"), own(label), own("--repo"), repo],
            )
        }
        Write::AddLabel { number, label } => {
            if *label != p.claim_label && *label != p.blocked_label {
                return Err(refuse(
                    ctx,
                    verb,
                    mode,
                    format!(
                        "may only add '{}' or '{}' (asked for '{label}')",
                        p.claim_label, p.blocked_label
                    ),
                ));
            }
            (
                format!("add {label} to #{number}"),
                vec![
                    own("issue"),
                    own("edit"),
                    number.to_string(),
                    own("--repo"),
                    repo,
                    own("--add-label"),
                    own(label),
                ],
            )
        }
        Write::RemoveLabel { number, label } => {
            if *label != p.claim_label {
                return Err(refuse(
                    ctx,
                    verb,
                    mode,
                    format!("may only remove '{}' (asked for '{label}')", p.claim_label),
                ));
            }
            (
                format!("remove {label} from #{number}"),
                vec![
                    own("issue"),
                    own("edit"),
                    number.to_string(),
                    own("--repo"),
                    repo,
                    own("--remove-label"),
                    own(label),
                ],
            )
        }
        Write::CloseIssue { number } => (
            format!("close #{number}"),
            vec![
                own("issue"),
                own("close"),
                number.to_string(),
                own("--repo"),
                repo,
                own("--reason"),
                own("completed"),
            ],
        ),
        Write::MergePr { number, head } => {
            if !head.bytes().all(|b| b.is_ascii_hexdigit()) || head.len() < 40 {
                return Err(Fail::usage(format!("'{head}' is not a full commit SHA")));
            }
            (format!("merge #{number} at {head}"), merge_argv(&repo, *number, head))
        }
        Write::PrCreate {
            head,
            base,
            title,
            body_file,
            draft,
            labels,
        } => {
            if head.starts_with("agent/") {
                return Err(refuse(
                    ctx,
                    verb,
                    mode,
                    format!("'{head}' is an agent/ branch: a workflow rewrites closing keywords on those"),
                ));
            }
            if head == base {
                return Err(refuse(ctx, verb, mode, format!("head and base are both '{head}'")));
            }
            if head.is_empty() || base.is_empty() || title.is_empty() {
                return Err(Fail::usage("pr-create needs --head, --base and --title"));
            }
            need_body(body_file)?;
            (
                format!("pr {head} into {base}"),
                pr_create_argv(&repo, head, base, title, body_file, *draft, labels),
            )
        }
        Write::ThreadReply { thread, body_file } => {
            if !thread_ok(thread) {
                return Err(refuse(ctx, verb, mode, format!("'{thread}' is not a review thread id")));
            }
            need_body(body_file)?;
            (
                format!("reply on thread {thread}"),
                thread_reply_argv(thread, body_file),
            )
        }
        Write::ThreadResolve { thread } => {
            if !thread_ok(thread) {
                return Err(refuse(ctx, verb, mode, format!("'{thread}' is not a review thread id")));
            }
            (format!("resolve thread {thread}"), thread_resolve_argv(thread))
        }
    };

    if ctx.dry_run {
        let mut words = vec!["gh"];
        words.extend(argv.iter().map(String::as_str));
        let printable = shlex::try_join(words).unwrap_or_else(|_| format!("gh {}", argv.join(" ")));
        println!("WOULD: {printable}");
        ctx.event("gh_write", json!({"verb": verb, "what": what, "dry_run": true}))?;
        return Ok(Written {
            called: false,
            stdout: String::new(),
        });
    }

    // stdout is captured (issue-create prints the new URL there); stderr goes
    // straight through, so gh's own error reaches the person running this.
    let run = gh().args(&argv).stderr(Stdio::inherit()).output();
    let (rc, stdout) = match run {
        Ok(out) => (
            out.status.code().unwrap_or(1),
            String::from_utf8_lossy(&out.stdout).into_owned(),
        ),
        Err(_) => (127, String::new()),
    };
    // The call has happened. A log that cannot be written must not turn a
    // write GitHub accepted into a failure the caller would retry.
    if let Err(e) = ctx.event(
        "gh_write",
        json!({"verb": verb, "what": what, "dry_run": false, "rc": rc}),
    ) {
        eprintln!(
            "issue-drain: warning: {what} ran (gh exit {rc}) but was not logged: {}",
            e.msg
        );
    }
    if rc != 0 {
        return Err(Fail::failed(format!("gh failed (exit {rc}): {what}")));
    }
    Ok(Written { called: true, stdout })
}

const VERBS: &str = "<issue-create|comment|ensure-label|add-label|remove-label|pr-create|thread-reply|thread-resolve>";

/// `issue-drain gh-write <verb> ...`. The verb and its options are read by
/// hand, not by clap, so that a unit process asking for a forbidden verb is
/// refused, and the refusal logged, before anything else about the call is
/// looked at.
///
/// There is no verb that closes an issue. `Write::CloseIssue` is reached only
/// from `close-verified`, which holds every condition a closure needs.
pub fn cli(ctx: &Ctx, argv: &[String]) -> Res<()> {
    ctx.repo()?;
    let mode = ctx.mode()?;
    let Some(verb) = argv.first().map(String::as_str).filter(|v| !v.is_empty()) else {
        return Err(Fail::usage(format!("usage: issue-drain gh-write {VERBS} ...")));
    };
    if mode == Mode::Unit && !unit_may(verb) {
        return Err(refuse(ctx, verb, mode, format!("{verb} is the driver's job in a unit")));
    }

    let mut body_file = String::new();
    let mut title = String::new();
    let (mut head, mut base, mut thread) = (String::new(), String::new(), String::new());
    let mut draft = false;
    let mut labels: Vec<String> = Vec::new();
    let mut args: Vec<&str> = Vec::new();
    let mut rest = argv[1..].iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--body-file" => body_file = rest.next().cloned().unwrap_or_default(),
            "--title" => title = rest.next().cloned().unwrap_or_default(),
            "--head" => head = rest.next().cloned().unwrap_or_default(),
            "--base" => base = rest.next().cloned().unwrap_or_default(),
            "--thread" => thread = rest.next().cloned().unwrap_or_default(),
            "--draft" => draft = true,
            "--label" => match rest.next() {
                Some(label) if !label.is_empty() => labels.push(label.clone()),
                _ => return Err(Fail::usage("--label needs a name")),
            },
            option if option.starts_with("--") => return Err(Fail::usage(format!("unknown option {option}"))),
            other => args.push(other),
        }
    }
    let arg = |i: usize| args.get(i).copied().unwrap_or_default();
    let number = || {
        parse_number(arg(0))
            .ok_or_else(|| Fail::usage(format!("{verb} needs an issue or PR number (got '{}')", arg(0))))
    };
    let body = || {
        if body_file.is_empty() {
            Err(Fail::usage(format!("{verb} needs --body-file <file>")))
        } else {
            Ok(Path::new(&body_file))
        }
    };

    let w = match verb {
        "issue-create" => Write::IssueCreate {
            body_file: body()?,
            title: &title,
        },
        "comment" => Write::Comment {
            number: number()?,
            body_file: body()?,
        },
        "ensure-label" => Write::EnsureLabel { label: arg(0) },
        "add-label" => Write::AddLabel {
            number: number()?,
            label: arg(1),
        },
        "remove-label" => Write::RemoveLabel {
            number: number()?,
            label: arg(1),
        },
        "pr-create" => Write::PrCreate {
            head: &head,
            base: &base,
            title: &title,
            body_file: body()?,
            draft,
            labels: &labels,
        },
        "thread-reply" => Write::ThreadReply {
            thread: &thread,
            body_file: body()?,
        },
        "thread-resolve" => Write::ThreadResolve { thread: &thread },
        "close-issue" => {
            return Err(refuse(
                ctx,
                verb,
                mode,
                "issues are closed only by `issue-drain close-verified`".to_string(),
            ));
        }
        other => return Err(Fail::usage(format!("unknown verb '{other}'"))),
    };
    print!("{}", write(ctx, &w)?.stdout);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pr_create_argv_is_exact() {
        let labels = ["a".to_string(), "b".to_string()];
        let argv = pr_create_argv("o/r", "feat/x", "develop", "T", Path::new("/b.md"), true, &labels);
        assert_eq!(
            argv.join(" "),
            "pr create --repo o/r --head feat/x --base develop --title T --body-file /b.md --draft --label a --label b"
        );
        let plain = pr_create_argv("o/r", "h", "b", "T", Path::new("/b.md"), false, &[]);
        assert_eq!(
            plain.join(" "),
            "pr create --repo o/r --head h --base b --title T --body-file /b.md"
        );
    }

    #[test]
    fn thread_argv_passes_the_body_from_the_file() {
        let reply = thread_reply_argv("PRRT_kw-1=", Path::new("/b.md"));
        assert_eq!(&reply[..3], ["api", "graphql", "-f"]);
        assert!(reply[3].starts_with("query=mutation($id:ID!,$body:String!){addPullRequestReviewThreadReply("));
        assert_eq!(reply[4..], ["-f", "id=PRRT_kw-1=", "-F", "body=@/b.md"]);
        let resolve = thread_resolve_argv("PRRT_kw-1=");
        assert!(resolve[3].contains("resolveReviewThread(input:{threadId:$id})"));
        assert_eq!(resolve[4..], ["-f", "id=PRRT_kw-1="]);
    }

    #[test]
    fn thread_ids_are_checked() {
        assert!(thread_ok("PRRT_kwDOAbc-1="));
        for bad in ["", "a b", "a;b", "@x", "a\nb", "a/b"] {
            assert!(!thread_ok(bad), "{bad:?}");
        }
    }

    #[test]
    fn a_unit_may_only_use_the_listed_verbs() {
        let allowed = [
            "comment",
            "add-label",
            "ensure-label",
            "pr-create",
            "thread-reply",
            "thread-resolve",
        ];
        let refused = [
            "issue-create",
            "remove-label",
            "close-issue",
            "merge-pr",
            "merge",
            "frobnicate",
            "",
        ];
        for verb in allowed {
            assert!(unit_may(verb), "{verb}");
        }
        for verb in refused {
            assert!(!unit_may(verb), "{verb}");
        }
    }
}
