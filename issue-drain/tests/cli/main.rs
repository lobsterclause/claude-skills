//! CLI tests: each runs the built binary against a stub `gh` (tests/stub/gh)
//! and the tidepool fixture repo. One module per command, so a command's
//! tests live in one file.

mod common;

mod evidence;
mod gh_write;
mod intake;
mod overlap;
mod packaging;
mod render;
mod tracker_io;
