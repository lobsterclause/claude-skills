//! `issue-drain close-verified`. Ported from scripts/close-verified.sh, which is the specification.

use crate::ctx::Ctx;
use crate::error::{Fail, Res};

#[derive(clap::Args)]
pub struct Args {}

pub fn run(_ctx: &Ctx, _args: &Args) -> Res<()> {
    Err(Fail::failed("not built yet"))
}
