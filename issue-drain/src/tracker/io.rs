//! `issue-drain tracker publish` and `tracker parse`. Ported from the publish
//! and parse halves of scripts/tracker.sh, which is the specification.

use crate::ctx::Ctx;
use crate::error::{Fail, Res};

#[derive(clap::Args)]
pub struct PublishArgs {}

#[derive(clap::Args)]
pub struct ParseArgs {}

pub fn publish(_ctx: &Ctx, _args: &PublishArgs) -> Res<()> {
    Err(Fail::failed("not built yet"))
}

pub fn parse(_ctx: &Ctx, _args: &ParseArgs) -> Res<()> {
    Err(Fail::failed("not built yet"))
}
