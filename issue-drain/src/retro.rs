//! `issue-drain retro [--publish]`: the run's retrospective, from the event
//! log. Stub; being built.

use crate::ctx::Ctx;
use crate::error::{Fail, Res};

#[derive(clap::Args)]
pub struct Args {
    /// Post the retro as a comment on the tracker (through gh-write).
    #[arg(long)]
    pub publish: bool,
}

pub fn run(ctx: &Ctx, _args: &Args) -> Res<()> {
    ctx.require_driver("retro")?;
    Err(Fail::failed("retro is not built yet"))
}
