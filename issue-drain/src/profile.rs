//! The per-repo profile: hold labels, protected paths, caps.
//!
//! A repo with no profile is an error, not a silent run on defaults. The hold
//! labels and protected paths are the profile, and guessing them is how an
//! agent ends up editing a workflow file. Unknown keys are rejected for the
//! same reason: a misspelt `protected_path_re` must not quietly fall back to
//! the default.

use std::fs;
use std::path::{Path, PathBuf};

use regex::{Regex, RegexBuilder};
use serde::Deserialize;

use crate::error::{Fail, Res};

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct Profile {
    pub base_branch: String,
    pub hold_labels: Vec<String>,
    pub claim_label: String,
    pub blocked_label: String,
    pub tracker_label: String,
    pub priority_labels: Vec<String>,
    pub protected_path_re: String,
    pub frozen_paths: Vec<String>,
    pub risk_path_re: String,
    pub trusted_associations: Vec<String>,
    pub intake_cap: usize,
    pub stale_claim_days: i64,
    pub issue_classifier: String,
    pub cluster_max_issues: usize,
    pub cluster_max_lines: u64,
    pub evidence_line_slack: usize,
    pub evidence_min_quote: usize,
    pub allowed_models: Vec<String>,
    pub allowed_efforts: Vec<String>,
    pub unit_permissions: String,
    pub guard_protected_paths: Vec<String>,
    pub bootstrap_command: String,
    pub bootstrap_requires: Vec<String>,
    pub bootstrap_timeout_secs: u64,
    pub codegraph_init: bool,
    pub codegraph_timeout_secs: u64,
    pub full_verify_command: String,
    pub stamp_command: String,
    pub unit_timeout_secs: u64,
    pub unit_allowed_tools: Vec<String>,
    #[serde(skip)]
    protected: Option<Regex>,
    #[serde(skip)]
    risk: Option<Regex>,
    #[serde(skip)]
    pub file: PathBuf,
}

fn words(s: &str) -> Vec<String> {
    s.split_whitespace().map(str::to_string).collect()
}

impl Default for Profile {
    fn default() -> Profile {
        Profile {
            base_branch: "main".into(),
            hold_labels: words("needs-human blocked"),
            claim_label: "agent-in-progress".into(),
            blocked_label: "needs-human".into(),
            tracker_label: "issue-drain".into(),
            priority_labels: Vec::new(),
            protected_path_re: r"^(\.github/workflows/|\.husky/|\.claude/)".into(),
            frozen_paths: Vec::new(),
            risk_path_re: String::new(),
            trusted_associations: words("OWNER MEMBER COLLABORATOR"),
            intake_cap: 40,
            stale_claim_days: 3,
            issue_classifier: String::new(),
            cluster_max_issues: 4,
            cluster_max_lines: 400,
            evidence_line_slack: 3,
            evidence_min_quote: 8,
            allowed_models: words("haiku sonnet opus"),
            allowed_efforts: words("low medium high"),
            unit_permissions: "not set in the profile".into(),
            guard_protected_paths: words(".github/workflows .husky .claude"),
            bootstrap_command: String::new(),
            bootstrap_requires: Vec::new(),
            bootstrap_timeout_secs: 900,
            codegraph_init: false,
            codegraph_timeout_secs: 300,
            full_verify_command: String::new(),
            stamp_command: String::new(),
            unit_timeout_secs: 5400,
            unit_allowed_tools: words(
                "Bash Read Edit Write Grep Glob Agent ToolSearch mcp__codegraph__codegraph_explore",
            ),
            protected: None,
            risk: None,
            file: PathBuf::new(),
        }
    }
}

/// Whether `path` is `entry` or lies under the folder `entry` (a trailing
/// slash on the entry is optional).
pub fn path_within(path: &str, entry: &str) -> bool {
    let entry = entry.trim_end_matches('/');
    !entry.is_empty() && (path == entry || path.strip_prefix(entry).is_some_and(|rest| rest.starts_with('/')))
}

/// Whether a scope entry covers `path`: an entry ending in `/` is a folder and
/// covers what is under it; any other entry covers only that exact path.
pub fn scope_covers(entry: &str, path: &str) -> bool {
    path == entry || (entry.ends_with('/') && path.starts_with(entry))
}

/// The more specific of two file entries when one covers the other, else `None`.
pub fn shared_entry<'a>(a: &'a str, b: &'a str) -> Option<&'a str> {
    if scope_covers(a, b) {
        Some(b)
    } else if scope_covers(b, a) {
        Some(a)
    } else {
        None
    }
}

/// GitHub treats label names as case-insensitive, so `Blocked` is the hold
/// label `blocked`.
pub fn same_label(a: &str, b: &str) -> bool {
    a.to_lowercase() == b.to_lowercase()
}

fn compile(key: &str, source: &str) -> Res<Option<Regex>> {
    if source.is_empty() {
        return Ok(None);
    }
    RegexBuilder::new(source)
        .case_insensitive(true)
        .build()
        .map(Some)
        .map_err(|e| Fail::usage(format!("profile key {key} is not a regular expression: {e}")))
}

impl Profile {
    pub fn load(path: &Path, skill_dir: &Path) -> Res<Profile> {
        if !path.is_file() {
            return Err(Fail::usage(format!(
                "no profile at {}. Copy one from {}/profiles and edit it (see references/profile.md)",
                path.display(),
                skill_dir.display()
            )));
        }
        let text = fs::read_to_string(path)
            .map_err(|e| Fail::usage(format!("cannot read the profile {}: {e}", path.display())))?;
        let mut p: Profile = toml::from_str(&text).map_err(|e| {
            Fail::usage(format!(
                "the profile {} does not parse: {}",
                path.display(),
                e.to_string().trim_end()
            ))
        })?;
        p.validate()?;
        p.protected = compile("protected_path_re", &p.protected_path_re)?;
        p.risk = compile("risk_path_re", &p.risk_path_re)?;
        p.file = path.to_path_buf();
        Ok(p)
    }

    fn validate(&self) -> Res<()> {
        // The base branch becomes a git argument, and the three labels become
        // gh arguments. gh splits a label argument on commas, so a comma here
        // would let one "owned" label name two.
        let branch_ok = !self.base_branch.is_empty()
            && !self.base_branch.starts_with('-')
            && self
                .base_branch
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || "._/-".contains(c));
        if !branch_ok {
            return Err(Fail::usage(format!(
                "profile key base_branch must be a branch name (got '{}')",
                self.base_branch
            )));
        }
        for (key, label) in [
            ("claim_label", &self.claim_label),
            ("blocked_label", &self.blocked_label),
            ("tracker_label", &self.tracker_label),
        ] {
            let ok = !label.trim().is_empty()
                && !label.starts_with('-')
                && !label.chars().any(|c| c == ',' || c.is_control());
            if !ok {
                return Err(Fail::usage(format!(
                    "profile key {key} must be one label name, with no comma (got '{label}')"
                )));
            }
        }
        if self.intake_cap == 0 || self.cluster_max_issues == 0 {
            return Err(Fail::usage(
                "profile keys intake_cap and cluster_max_issues must be above 0",
            ));
        }
        if self.bootstrap_timeout_secs == 0 || self.codegraph_timeout_secs == 0 {
            return Err(Fail::usage(
                "profile keys bootstrap_timeout_secs and codegraph_timeout_secs must be above 0",
            ));
        }
        if self.unit_timeout_secs == 0 {
            return Err(Fail::usage("profile key unit_timeout_secs must be above 0"));
        }
        // `--allowedTools` takes every word after it, so an empty list would
        // swallow the next flag, and a word starting with '-' would be one.
        if self.unit_allowed_tools.is_empty()
            || self
                .unit_allowed_tools
                .iter()
                .any(|t| t.trim().is_empty() || t.starts_with('-'))
        {
            return Err(Fail::usage(
                "profile key unit_allowed_tools must hold at least one tool name, none empty or starting with '-'",
            ));
        }
        // A required path is joined onto the main checkout: it stays inside it.
        for path in &self.bootstrap_requires {
            let inside = !path.is_empty() && !path.starts_with('/') && !path.split('/').any(|part| part == "..");
            if !inside {
                return Err(Fail::usage(format!(
                    "profile key bootstrap_requires must hold paths inside the checkout (got '{path}')"
                )));
            }
        }
        Ok(())
    }

    /// A path no agent may change: the unit parks for a person.
    pub fn is_protected(&self, path: &str) -> bool {
        self.protected.as_ref().is_some_and(|re| re.is_match(path))
    }

    /// A path the unit's diff may not touch: a listed file, or anything under
    /// a listed folder.
    pub fn is_frozen(&self, path: &str) -> bool {
        self.frozen_paths.iter().any(|entry| path_within(path, entry))
    }

    /// A path whose PR waits for a named reviewer.
    pub fn is_risk(&self, path: &str) -> bool {
        self.risk.as_ref().is_some_and(|re| re.is_match(path))
    }

    /// The first hold label the issue carries, in the profile's order.
    pub fn hold_label_on<'a>(&'a self, labels: &[String]) -> Option<&'a str> {
        self.hold_labels
            .iter()
            .find(|hold| labels.iter().any(|l| same_label(l, hold)))
            .map(String::as_str)
    }

    pub fn has_claim(&self, labels: &[String]) -> bool {
        labels.iter().any(|l| same_label(l, &self.claim_label))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn load(text: &str) -> Res<Profile> {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("p.toml");
        fs::write(&file, text).unwrap();
        Profile::load(&file, dir.path())
    }

    #[test]
    fn an_empty_file_gives_the_defaults() {
        let p = load("").unwrap();
        assert_eq!(p.base_branch, "main");
        assert_eq!(p.intake_cap, 40);
        assert!(p.is_protected(".github/workflows/ci.yml"));
        assert!(!p.is_protected("src/app.ts"));
        assert!(!p.is_risk("src/crisis/keywords.ts"));
    }

    #[test]
    fn an_unknown_key_is_rejected() {
        let err = load("protected_paths_re = \"x\"\n").unwrap_err();
        assert_eq!(err.code, 2);
        assert!(err.msg.contains("protected_paths_re"), "{}", err.msg);
    }

    #[test]
    fn frozen_paths_match_a_file_or_a_folder_but_not_a_name_prefix() {
        let p = load("frozen_paths = [\"Cargo.lock\", \"vendor/\", \"docs\"]\n").unwrap();
        assert!(p.is_frozen("Cargo.lock"));
        assert!(p.is_frozen("vendor/a/b.rs"));
        assert!(p.is_frozen("docs/readme.md"));
        assert!(!p.is_frozen("docs-extra/readme.md"));
        assert!(!p.is_frozen("src/Cargo.lock"));
        assert!(!load("").unwrap().is_frozen("vendor/a"));
        assert_eq!(load("frozen_path = []\n").unwrap_err().code, 2);
    }

    #[test]
    fn a_bad_regex_names_its_key() {
        let err = load("risk_path_re = \"(\"\n").unwrap_err();
        assert_eq!(err.code, 2);
        assert!(err.msg.contains("risk_path_re"), "{}", err.msg);
    }

    #[test]
    fn path_rules_ignore_case() {
        let p = load("risk_path_re = \"(^|/)billing/\"\n").unwrap();
        assert!(p.is_risk("src/Billing/charge.ts"));
        assert!(p.is_protected(".GitHub/workflows/ci.yml"));
    }

    #[test]
    fn a_label_with_a_comma_is_rejected() {
        let err = load("claim_label = \"agent-in-progress,bug\"\n").unwrap_err();
        assert_eq!(err.code, 2);
        assert!(err.msg.contains("claim_label"), "{}", err.msg);
    }

    #[test]
    fn a_base_branch_that_looks_like_an_option_is_rejected() {
        assert_eq!(load("base_branch = \"--upload-pack=x\"\n").unwrap_err().code, 2);
    }

    #[test]
    fn the_unit_keys_default_to_off() {
        let p = load("").unwrap();
        assert_eq!(p.guard_protected_paths, [".github/workflows", ".husky", ".claude"]);
        assert!(p.bootstrap_command.is_empty() && p.bootstrap_requires.is_empty());
        assert!(!p.codegraph_init);
        assert_eq!((p.bootstrap_timeout_secs, p.codegraph_timeout_secs), (900, 300));
        assert!(p.full_verify_command.is_empty() && p.stamp_command.is_empty());
    }

    #[test]
    fn a_required_path_outside_the_checkout_or_a_zero_timeout_is_rejected() {
        for bad in ["/etc", "../x", "a/../b", ""] {
            let err = load(&format!("bootstrap_requires = [\"{bad}\"]\n")).unwrap_err();
            assert_eq!(err.code, 2, "{bad}");
            assert!(err.msg.contains("bootstrap_requires"), "{}", err.msg);
        }
        assert!(load("bootstrap_requires = [\"node_modules\", \"a/b\"]\n").is_ok());
        assert_eq!(load("bootstrap_timeout_secs = 0\n").unwrap_err().code, 2);
        assert_eq!(load("codegraph_timeout_secs = 0\n").unwrap_err().code, 2);
    }

    #[test]
    fn the_unit_process_keys_have_defaults_and_a_zero_timeout_is_rejected() {
        let p = load("").unwrap();
        assert_eq!(p.unit_timeout_secs, 5400);
        assert_eq!(p.unit_allowed_tools.len(), 9);
        assert!(
            p.unit_allowed_tools
                .contains(&"mcp__codegraph__codegraph_explore".to_string())
        );
        let p = load("unit_timeout_secs = 60\nunit_allowed_tools = [\"Read\"]\n").unwrap();
        assert_eq!(
            (p.unit_timeout_secs, p.unit_allowed_tools),
            (60, vec!["Read".to_string()])
        );
        assert_eq!(load("unit_timeout_secs = 0\n").unwrap_err().code, 2);
        assert_eq!(load("unit_allowed_tools = [\"\"]\n").unwrap_err().code, 2);
        assert_eq!(load("unit_allowed_tools = []\n").unwrap_err().code, 2);
        assert_eq!(load("unit_allowed_tools = [\"--plugin-dir\"]\n").unwrap_err().code, 2);
    }

    #[test]
    fn hold_labels_match_whatever_the_case() {
        let p = load("hold_labels = [\"needs-human\", \"blocked\"]\n").unwrap();
        let labels = vec!["bug".to_string(), "Blocked".to_string()];
        assert_eq!(p.hold_label_on(&labels), Some("blocked"));
        assert!(p.has_claim(&["Agent-In-Progress".to_string()]));
    }
}
