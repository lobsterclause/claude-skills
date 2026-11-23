//! `issue-drain drive [--once]`: the driver loop. Stub; being built.

use crate::ctx::Ctx;
use crate::error::{Fail, Res};

#[derive(clap::Args)]
pub struct Args {
    /// Take one step and exit, instead of looping until a stop condition.
    #[arg(long)]
    pub once: bool,
}

pub fn run(ctx: &Ctx, _args: &Args) -> Res<()> {
    ctx.require_driver("drive")?;
    Err(Fail::failed("drive is not built yet"))
}
