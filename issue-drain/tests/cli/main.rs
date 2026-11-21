//! CLI tests: each runs the built binary against a stub `gh` (tests/stub/gh)
//! and the tidepool fixture repo. One module per command, so a command's
//! tests live in one file.

mod common;

mod close;
mod deliver_check;
mod evalscore;
mod evidence;
mod gh_write;
mod intake;
mod merge_gate;
mod overlap;
mod packaging;
mod render;
mod review_proof;
mod state;
mod tracker_io;
