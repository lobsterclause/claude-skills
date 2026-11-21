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
