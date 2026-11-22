//! What a person does to a unit by hand, with the reason on the record.
//!
//!   guards-marker --unit <n> --by-hand --reason <text>
//!       Writes `units/<n>/guards-marker`, the file `merge-gate` looks for and
//!       the guards mod writes (`<time> drain-guards <version>`). This one reads
//!       `<time> by-hand <reason>`, so nobody mistakes it for the mod's own.
//!   scope widen --unit <n> --file <path> --reason <text>
//!       Adds a path to the unit's `files` in queue.json, and in
//!       `units/<n>/unit.json` when the unit has one. A protected path is refused.
//!
//! Both are the driver's: a unit process is refused (exit 3), so a unit cannot
//! mark its own guards as run or widen its own scope. Exit 2 for bad
//! arguments, 1 when a file cannot be written.

use serde_json::{Value, json};

use crate::ctx::{Ctx, read_json, rfc3339, write_atomic, write_json};
use crate::error::{Fail, Res};
use crate::git;
use crate::text::repo_path;

#[derive(clap::Args)]
pub struct MarkerArgs {
    #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
    unit: u64,
    /// Required: the marker says it was written by hand.
    #[arg(long)]
    by_hand: bool,
    /// Why the mod's own marker is not there; one line.
    #[arg(long)]
    reason: String,
}

#[derive(clap::Subcommand)]
pub enum ScopeCommand {
    /// Add a file to a unit's scope.
    Widen(WidenArgs),
}

#[derive(clap::Args)]
pub struct WidenArgs {
    #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
    unit: u64,
    /// A repo-relative file path.
    #[arg(long)]
    file: String,
    /// Why the unit needs it; one line.
    #[arg(long)]
    reason: String,
}

fn one_line(reason: &str) -> Res<String> {
    let reason = reason.trim();
    if reason.is_empty() || reason.chars().any(char::is_control) {
        return Err(Fail::usage("--reason must be one line of text"));
    }
    Ok(reason.to_string())
}

pub fn guards_marker(ctx: &Ctx, args: &MarkerArgs) -> Res<()> {
    ctx.require_driver("guards-marker")?;
    if !args.by_hand {
        return Err(Fail::usage(
            "guards-marker writes only a by-hand marker; pass --by-hand (the guards mod writes its own)",
        ));
    }
    let reason = one_line(&args.reason)?;
    ctx.queue_unit(args.unit)?;
    let line = format!("{} by-hand {reason}\n", rfc3339(ctx.now()));
    write_atomic(
        &ctx.path(&format!("units/{}/guards-marker", args.unit)),
        line.as_bytes(),
    )?;
    ctx.event(
        "guards_marker",
        json!({"unit": args.unit, "by_hand": true, "reason": reason}),
    )
}

/// Whether `file` is a folder at the unit's worktree HEAD, or at the queue's
/// base commit when there is no worktree yet. A path git cannot find is not.
fn is_folder(ctx: &Ctx, queue: &Value, unit: u64, file: &str) -> Res<bool> {
    let copy: Value = read_json(&ctx.path(&format!("units/{unit}/unit.json"))).unwrap_or(Value::Null);
    let (dir, rev) = match copy["worktree"].as_str() {
        Some(worktree) => (std::path::PathBuf::from(worktree), "HEAD".to_string()),
        None => (
            ctx.repo_dir()?,
            queue["base_sha"].as_str().unwrap_or("HEAD").to_string(),
        ),
    };
    Ok(git::out(&dir, &["cat-file", "-t", &format!("{rev}:{file}")]).is_some_and(|t| t.trim() == "tree"))
}

pub fn scope(ctx: &Ctx, command: &ScopeCommand) -> Res<()> {
    let ScopeCommand::Widen(args) = command;
    ctx.require_driver("scope widen")?;
    let reason = one_line(&args.reason)?;
    if args.file.ends_with('/') {
        return Err(Fail::usage("--file names a file, not a folder"));
    }
    repo_path(&args.file).map_err(|why| Fail::usage(format!("--file '{}' {why}", args.file)))?;
    if ctx.profile.is_protected(&args.file) {
        return Err(Fail::refused(format!(
            "{} is a protected path; a unit that needs it goes to a person",
            args.file
        )));
    }
    let queue_path = ctx.path("queue.json");
    let mut queue: Value = read_json(&queue_path).ok_or_else(|| {
        Fail::usage(format!(
            "no queue in {}; run `tracker render` first",
            queue_path.display()
        ))
    })?;
    let id = format!("U{}", args.unit);
    if is_folder(ctx, &queue, args.unit, &args.file)? {
        return Err(Fail::refused(format!(
            "{} is a folder; name a file, or a new path",
            args.file
        )));
    }
    // Only the target unit's `files` changes; every other key is left as it is.
    let files = queue["units"]
        .as_array_mut()
        .and_then(|units| units.iter_mut().find(|u| u["id"] == id))
        .ok_or_else(|| Fail::usage(format!("queue.json has no unit {id}")))?["files"]
        .as_array_mut()
        .ok_or_else(|| Fail::usage(format!("{id} in queue.json has no files list")))?;
    let added = !files.iter().any(|f| f == &args.file);
    if added {
        files.push(json!(args.file));
        write_json(&queue_path, &queue)?;
    }
    // The unit's own copy, when `unit-prepare` has made one.
    let copy_path = ctx.path(&format!("units/{}/unit.json", args.unit));
    if let Some(mut copy) = read_json::<Value>(&copy_path)
        && let Some(files) = copy["files"].as_array_mut()
        && !files.iter().any(|f| f == &args.file)
    {
        files.push(json!(args.file));
        write_json(&copy_path, &copy)?;
    }
    ctx.event(
        "scope_widen",
        json!({"unit": args.unit, "file": args.file, "reason": reason, "added": added}),
    )?;
    println!(
        "{} {} {id}'s scope",
        args.file,
        if added { "added to" } else { "was already in" }
    );
    Ok(())
}
