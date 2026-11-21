//! `issue-drain tracker <render|publish|parse>`: the tracker issue, the one
//! place a person approves, reorders or stops the drain.

use crate::ctx::Ctx;
use crate::error::Res;

pub mod io;
pub mod render;

#[derive(clap::Subcommand)]
pub enum Command {
    /// decisions.json and the checked verdicts become queue.json and tracker.md.
    Render(render::Args),
    /// Open the tracker issue from tracker.md.
    Publish(io::PublishArgs),
    /// Read the tracker body back as JSON.
    Parse(io::ParseArgs),
}

pub fn run(ctx: &Ctx, command: &Command) -> Res<()> {
    match command {
        Command::Render(args) => render::run(ctx, args),
        Command::Publish(args) => io::publish(ctx, args),
        Command::Parse(args) => io::parse(ctx, args),
    }
}
