//! issue-drain: triage a set of GitHub issues and carry each one through to a
//! merged PR. One module per subcommand; `ctx`, `exec`, `gh`, `git`, `model`,
//! `profile` and `text` are shared by all of them.

pub mod base_sync;
pub mod by_hand;
pub mod claim;
pub mod cleanup;
pub mod close;
pub mod ctx;
pub mod deliver_check;
pub mod drive;
pub mod error;
pub mod evalscore;
pub mod evidence;
pub mod exec;
pub mod gh;
pub mod git;
pub mod intake;
pub mod merge_gate;
pub mod model;
pub mod overlap;
pub mod post_merge;
pub mod profile;
pub mod retro;
pub mod review_proof;
pub mod stamp;
pub mod state;
pub mod text;
pub mod tracker;
pub mod unit_prepare;
pub mod unit_run;
