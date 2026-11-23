//! `issue-drain unit-run --unit <n> [--resume --prompt-file <f>] [--model <m>] [--effort <e>]`:
//! start (or resume) a unit's headless `claude -p` process. Stub; being built.

use std::path::PathBuf;

use crate::ctx::Ctx;
use crate::error::{Fail, Res};

#[derive(clap::Args)]
pub struct Args {
    /// The unit; its files are under <run folder>/units/<n>/.
    #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
    pub unit: u64,
    /// Resume the unit's recorded session instead of starting a new one.
    #[arg(long)]
    pub resume: bool,
    /// The message for a resumed session (a failed check's log, open threads).
    #[arg(long)]
    pub prompt_file: Option<PathBuf>,
    /// Override the unit's model (must be in the profile's allowed_models).
    #[arg(long)]
    pub model: Option<String>,
    /// Override the unit's effort (must be in the profile's allowed_efforts).
    #[arg(long)]
    pub effort: Option<String>,
}

pub fn run(ctx: &Ctx, _args: &Args) -> Res<()> {
    ctx.require_driver("unit-run")?;
    Err(Fail::failed("unit-run is not built yet"))
}
