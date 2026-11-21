//! `issue-drain eval-score`: score a triage run against the fixture's expected
//! answers.

use crate::ctx::Ctx;
use crate::error::{Fail, Res};

#[derive(clap::Args)]
pub struct Args {}

pub fn run(_ctx: &Ctx, _args: &Args) -> Res<()> {
    Err(Fail::failed("not built yet"))
}
