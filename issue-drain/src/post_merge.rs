//! `issue-drain post-merge --unit <n> --pr <n>`: the checks after a unit's PR
//! merged. Stub; being built.

use crate::ctx::Ctx;
use crate::error::{Fail, Res};

#[derive(clap::Args)]
pub struct Args {
    /// The unit; its files are under <run folder>/units/<n>/.
    #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
    pub unit: u64,
    /// The unit's merged pull request.
    #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
    pub pr: u64,
}

pub fn run(ctx: &Ctx, _args: &Args) -> Res<()> {
    ctx.require_driver("post-merge")?;
    Err(Fail::failed("post-merge is not built yet"))
}
