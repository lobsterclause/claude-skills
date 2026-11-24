//! Read-only git calls against the local checkout.

use std::path::Path;
use std::process::{Command, Stdio};

/// stdout when git exits 0, else `None`. git's stderr is dropped: every caller
/// turns a failure into its own message.
pub fn out(dir: &Path, args: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if output.status.success() {
        Some(String::from_utf8_lossy(&output.stdout).into_owned())
    } else {
        None
    }
}

pub fn ok(dir: &Path, args: &[&str]) -> bool {
    out(dir, args).is_some()
}

/// The commit a ref names, or `None` if it names none.
pub fn commit(dir: &Path, reference: &str) -> Option<String> {
    let spec = format!("{reference}^{{commit}}");
    out(dir, &["rev-parse", "--verify", "-q", "--end-of-options", &spec])
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// The files that would conflict if `a` and `b` were merged, from
/// `git merge-tree --write-tree --name-only`. It changes no ref and no
/// worktree. `Some(empty)` when the merge is clean; `None` when git cannot say.
pub fn merge_conflicts(dir: &Path, a: &str, b: &str) -> Option<Vec<String>> {
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["merge-tree", "--write-tree", "--name-only", "--no-messages", a, b])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    match output.status.code()? {
        0 => Some(Vec::new()),
        1 => {
            let text = String::from_utf8_lossy(&output.stdout);
            let mut files: Vec<String> = text
                .lines()
                .skip(1)
                .take_while(|line| !line.is_empty())
                .map(str::to_string)
                .collect();
            files.sort();
            files.dedup();
            Some(files)
        }
        _ => None,
    }
}

/// The commit origin's branch `base` was at when it was last fetched. The ref
/// is named in full: `origin/<base>` alone is read as a tag or a local branch
/// of that name before the remote branch.
pub fn base_commit(dir: &Path, base: &str) -> Option<String> {
    commit(dir, &format!("refs/remotes/origin/{base}"))
}

/// The best common ancestor of two commits: where `a...b` starts. `None` when
/// they share none, or git cannot say.
pub fn merge_base(dir: &Path, a: &str, b: &str) -> Option<String> {
    out(dir, &["merge-base", a, b])
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Whether the checkout is shallow and `sha` is a commit its history was cut
/// at. Such a commit's parents are missing, so blame credits it with every
/// line older than the cut.
pub fn at_shallow_cut(dir: &Path, sha: &str) -> bool {
    let Some(path) = out(dir, &["rev-parse", "--git-path", "shallow"]) else {
        return false;
    };
    // git prints the path relative to the folder it ran in.
    let path = dir.join(path.trim());
    std::fs::read_to_string(path).is_ok_and(|cuts| cuts.lines().any(|cut| cut.trim() == sha))
}

/// `owner/repo` of the checkout's origin on GitHub, or `None` when origin is
/// unset, is not a github.com URL, or has URLs that name more than one repo
/// (git fetches from the first of them). This is the URL as configured, which
/// is what says whose code the checkout holds; where a fetch really goes (an
/// `insteadOf` rewrite, a mirror) is the machine's own business.
pub fn origin_repo(dir: &Path) -> Option<String> {
    let urls = out(dir, &["config", "--get-all", "remote.origin.url"])?;
    let mut repos = urls.lines().map(|url| github_repo(url.trim()));
    let first = repos.next()??;
    repos
        .all(|repo| repo.is_some_and(|repo| repo.eq_ignore_ascii_case(&first)))
        .then_some(first)
}

/// Whether `file` is the same at both commits. A failed comparison is a
/// difference. The path is taken as written, not as a pathspec pattern.
pub fn same_file(dir: &Path, a: &str, b: &str, file: &str) -> bool {
    ok(dir, &["--literal-pathspecs", "diff", "--quiet", a, b, "--", file])
}

/// `owner/repo` from an https, ssh or scp-style github.com URL.
fn github_repo(url: &str) -> Option<String> {
    let rest = ["https://github.com/", "ssh://git@github.com/", "git@github.com:"]
        .iter()
        .find_map(|prefix| url.strip_prefix(prefix))?;
    let rest = rest.strip_suffix('/').unwrap_or(rest);
    let rest = rest.strip_suffix(".git").unwrap_or(rest);
    let (owner, repo) = rest.split_once('/')?;
    let plain = |s: &str| !s.is_empty() && !s.contains('/');
    (plain(owner) && plain(repo)).then(|| format!("{owner}/{repo}"))
}

#[cfg(test)]
mod tests {
    use super::github_repo;

    #[test]
    fn origin_urls_name_their_repo() {
        for url in [
            "https://github.com/example/tidepool.git",
            "https://github.com/example/tidepool",
            "https://github.com/example/tidepool/",
            "git@github.com:example/tidepool.git",
            "ssh://git@github.com/example/tidepool",
        ] {
            assert_eq!(github_repo(url).as_deref(), Some("example/tidepool"), "{url}");
        }
    }

    #[test]
    fn other_hosts_and_shapes_name_none() {
        for url in [
            "https://gitlab.com/example/tidepool.git",
            "https://github.com.evil.example/example/tidepool",
            "https://github.com/example",
            "https://github.com/example/tidepool/extra",
            "/tmp/tidepool",
            "",
        ] {
            assert_eq!(github_repo(url), None, "{url}");
        }
    }
}
