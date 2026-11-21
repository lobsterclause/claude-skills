//! issue-drain: triage a set of GitHub issues and carry each one through to a
//! merged PR. One module per subcommand; `ctx`, `gh`, `git`, `model`,
//! `profile` and `text` are shared by all of them.

pub mod close;
pub mod ctx;
pub mod error;
pub mod evalscore;
pub mod evidence;
pub mod gh;
pub mod git;
pub mod intake;
pub mod model;
pub mod overlap;
pub mod profile;
pub mod text;
pub mod tracker;
