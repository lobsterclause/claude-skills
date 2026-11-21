use std::process::ExitCode;

use clap::{Parser, Subcommand};
use issue_drain::ctx::Ctx;
use issue_drain::error::Res;
use issue_drain::{close, evalscore, evidence, gh, intake, overlap, state, tracker};

/// Triage a set of GitHub issues and carry each one through to a merged PR.
///
/// Every command reads ISSUE_DRAIN_WORKDIR (the run folder, an absolute path)
/// and ISSUE_DRAIN_REPO (<owner>/<repo>). Exit codes: 2 for bad arguments or
/// a missing input, 3 when a rule refused the action, 1 when GitHub, git or
/// the filesystem failed.
#[derive(Parser)]
#[command(name = "issue-drain", version)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Fetch the issue set into the run folder and sort out the ineligible.
    Intake(intake::Args),
    /// Hold every reader verdict against the code on the base branch.
    EvidenceCheck(evidence::Args),
    /// Propose which issues share a fix.
    Overlap(overlap::Args),
    /// Render, publish or read back the tracker issue.
    #[command(subcommand)]
    Tracker(tracker::Command),
    /// Close the already-fixed issues ticked on the tracker.
    CloseVerified(close::Args),
    /// The one path by which issue-drain writes to GitHub.
    GhWrite {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },
    /// Score a triage run against the fixture's expected answers.
    EvalScore(evalscore::Args),
    /// Where each unit of the drain is, kept as a log of moves.
    #[command(subcommand)]
    State(state::Command),
}

fn name(command: &Command) -> &'static str {
    match command {
        Command::Intake(_) => "intake",
        Command::EvidenceCheck(_) => "evidence-check",
        Command::Overlap(_) => "overlap",
        Command::Tracker(tracker::Command::Render(_)) => "tracker render",
        Command::Tracker(tracker::Command::Publish(_)) => "tracker publish",
        Command::Tracker(tracker::Command::Parse(_)) => "tracker parse",
        Command::CloseVerified(_) => "close-verified",
        Command::GhWrite { .. } => "gh-write",
        Command::EvalScore(_) => "eval-score",
        Command::State(state::Command::Init(_)) => "state init",
        Command::State(state::Command::Event(_)) => "state event",
        Command::State(state::Command::Stop(_)) => "state stop",
        Command::State(state::Command::Resume) => "state resume",
        Command::State(state::Command::Show(_)) => "state show",
        Command::State(state::Command::Next) => "state next",
        Command::State(state::Command::Rebuild) => "state rebuild",
    }
}

fn run(command: &Command) -> Res<()> {
    let ctx = Ctx::load()?;
    match command {
        Command::Intake(args) => intake::run(&ctx, args),
        Command::EvidenceCheck(args) => evidence::run(&ctx, args),
        Command::Overlap(args) => overlap::run(&ctx, args),
        Command::Tracker(command) => tracker::run(&ctx, command),
        Command::CloseVerified(args) => close::run(&ctx, args),
        Command::GhWrite { args } => gh::cli(&ctx, args),
        Command::EvalScore(args) => evalscore::run(&ctx, args),
        Command::State(command) => state::run(&ctx, command),
    }
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match run(&cli.command) {
        Ok(()) => ExitCode::SUCCESS,
        Err(fail) => {
            eprintln!("issue-drain {}: {}", name(&cli.command), fail.msg);
            ExitCode::from(fail.code)
        }
    }
}
