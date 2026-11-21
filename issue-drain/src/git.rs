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

/// `owner/repo` of the checkout's origin on GitHub, or `None` when origin is
/// unset or is not a github.com URL. This is the URL as configured, which is
/// what says whose code the checkout holds; where a fetch really goes (an
/// `insteadOf` rewrite, a mirror) is the machine's own business.
pub fn origin_repo(dir: &Path) -> Option<String> {
    let url = out(dir, &["config", "--get", "remote.origin.url"])?;
    github_repo(url.trim())
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
