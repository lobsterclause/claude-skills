//! CLI tests: each runs the built binary against a stub `gh` (tests/stub/gh)
//! and the tidepool fixture repo. One module per command, so a command's
//! tests live in one file.

mod common;

mod base_sync;
mod by_hand;
mod claim;
mod cleanup;
mod close;
mod deliver_check;
mod drive;
mod evalscore;
mod evidence;
mod gh_write;
mod gh_write_unit;
mod intake;
mod merge_gate;
mod overlap;
mod packaging;
mod post_merge;
mod render;
mod retro;
mod review_proof;
mod stamp;
mod state;
mod tracker_io;
mod unit_prepare;
mod unit_run;
