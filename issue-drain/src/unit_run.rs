//! `issue-drain unit-run --unit <n> [--resume --prompt-file <f>] [--model <m>] [--effort <e>]`:
//! start, or resume, one unit's headless `claude -p` process and record the
//! session.
//!
//! The unit must have been prepared (`unit-prepare` writes `units/<n>/unit.json`);
//! without it the command stops with exit 2. The model and effort are `--model`
//! and `--effort` when given, otherwise the ones in unit.json, and both must be in
//! the profile's `allowed_models` and `allowed_efforts`.
//!
//! A new run starts a session with a fixed prompt that names the run, points at
//! `references/unit.md` and at the unit file. It is refused when
//! `units/<n>/session.json` already names a session: that unit has one, and the
//! way on is `--resume`. A resume needs a recorded session id and a `--prompt-file`,
//! whose text is the message; it keeps the session and may change model and effort.
//!
//! The process is `claude -p` with `--permission-mode acceptEdits`,
//! `--permission-prompts none`, the profile's `unit_allowed_tools`, the skill's
//! `guards` mod as `--plugin-dir`, and `--output-format stream-json --verbose`. It
//! runs in the unit's worktree and inherits the environment, plus
//! `VERIFY_GATE_SKIP=1`, `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`,
//! `ISSUE_DRAIN_MODE=unit` and `ISSUE_DRAIN_UNIT_FILE`. It is killed, with its
//! process group, after the profile's `unit_timeout_secs`. `claude` is looked up
//! on PATH.
//!
//! Files, all under `units/<n>/`:
//!   transcript-<attempt>.jsonl   its stdout, one stream-json object per line
//!   transcript-<attempt>.stderr  its stderr
//!   session.json                 `{session_id, attempts: [{attempt, resumed, model,
//!                                effort, started, ended, exit_code, timed_out,
//!                                cost_usd, num_turns, is_error, session_id}]}`,
//!                                written atomically, one attempt appended per run
//!
//! The session id is the first object's `session_id` (normally the `init` line); the
//! cost, turn count and error flag come from the last `result` object. Lines that
//! are not JSON are skipped. The first session id is kept: a resume does not replace
//! it, and the id a resume reported is in that attempt's own `session_id`.
//!
//! With ISSUE_DRAIN_DRY_RUN=1 it prints `WOULD: claude ...` and changes nothing.
//! A unit process may not run it. The driver can call `launch` in-process.
//!
//! Output: one JSON line, `{unit, attempt, session_id, resumed, model, effort,
//! exit_code, timed_out, cost_usd, result}`, where `result` is units/<n>/result.json
//! as the process left it, or null. An `unit_run` event is logged too. Exit: 0 when
//! the process ran, whatever its own exit code (the caller reads `exit_code` and
//! `timed_out`); 2 no unit file, no session to resume or no prompt file; 3 refused
//! (a unit process asked, a new run over an existing session, or a model or effort
//! the profile does not allow); 1 the process could not be started or a file could
//! not be written.

use std::fs;
use std::path::PathBuf;
use std::time::Duration;

use serde_json::{Value, json};

use crate::ctx::{Ctx, read_json, rfc3339, write_json};
use crate::error::{Fail, Res};
use crate::exec;

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

/// What a transcript says: the session, and the last result line's numbers.
#[derive(Default, Debug, PartialEq)]
struct Transcript {
    session_id: Option<String>,
    cost_usd: Option<f64>,
    num_turns: Option<u64>,
    is_error: Option<bool>,
}

fn parse_transcript(text: &str) -> Transcript {
    let mut t = Transcript::default();
    for obj in text
        .lines()
        .filter_map(|l| serde_json::from_str::<Value>(l.trim()).ok())
    {
        if t.session_id.is_none() {
            t.session_id = obj["session_id"].as_str().filter(|s| !s.is_empty()).map(str::to_string);
        }
        if obj["type"] == "result" {
            if let Some(id) = obj["session_id"].as_str().filter(|s| !s.is_empty()) {
                t.session_id = t.session_id.or_else(|| Some(id.to_string()));
            }
            t.cost_usd = obj["total_cost_usd"].as_f64();
            t.num_turns = obj["num_turns"].as_u64();
            t.is_error = obj["is_error"].as_bool();
        }
    }
    t
}

/// The session id on a `result` line, which may differ from the first one.
fn result_session(text: &str) -> Option<String> {
    text.lines()
        .filter_map(|l| serde_json::from_str::<Value>(l.trim()).ok())
        .filter(|o| o["type"] == "result")
        .filter_map(|o| o["session_id"].as_str().map(str::to_string))
        .next_back()
}

fn check_allowed(key: &str, value: &str, allowed: &[String]) -> Res<()> {
    if allowed.iter().any(|a| a == value) {
        Ok(())
    } else {
        Err(Fail::refused(format!(
            "{key} '{value}' is not allowed by the profile (allowed: {})",
            allowed.join(", ")
        )))
    }
}

fn recorded_session(session: &Value) -> Option<String> {
    session["session_id"]
        .as_str()
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

/// Do the work and return what `run` prints. In a dry run it returns
/// `{"unit", "dry_run": true, "argv": [...]}` and writes nothing.
pub fn launch(ctx: &Ctx, args: &Args) -> Res<Value> {
    ctx.require_driver("unit-run")?;
    let unit = args.unit;
    let state_dir = ctx.path(&format!("units/{unit}"));
    let unit_file = state_dir.join("unit.json");
    let prepared: Value = read_json(&unit_file).ok_or_else(|| {
        Fail::usage(format!(
            "no unit file at {}; run `unit-prepare --unit {unit}` first",
            unit_file.display()
        ))
    })?;
    let p = &ctx.profile;
    let model = args
        .model
        .clone()
        .or_else(|| prepared["model"].as_str().map(str::to_string))
        .ok_or_else(|| Fail::usage(format!("{} has no model; pass --model", unit_file.display())))?;
    let effort = args
        .effort
        .clone()
        .or_else(|| prepared["effort"].as_str().map(str::to_string))
        .ok_or_else(|| Fail::usage(format!("{} has no effort; pass --effort", unit_file.display())))?;
    check_allowed("model", &model, &p.allowed_models)?;
    check_allowed("effort", &effort, &p.allowed_efforts)?;
    let worktree = prepared["worktree"]
        .as_str()
        .map(PathBuf::from)
        .filter(|w| w.is_dir())
        .ok_or_else(|| {
            Fail::usage(format!(
                "{} names no worktree folder that exists; run `unit-prepare --unit {unit}`",
                unit_file.display()
            ))
        })?;

    let session_file = state_dir.join("session.json");
    let mut session: Value = read_json(&session_file).unwrap_or_else(|| json!({}));
    let known = recorded_session(&session);
    let prompt_and_resume = if args.resume {
        let id = known.clone().ok_or_else(|| {
            Fail::usage(format!(
                "unit {unit} has no session to resume ({} names none); start it without --resume",
                session_file.display()
            ))
        })?;
        let file = args
            .prompt_file
            .as_ref()
            .ok_or_else(|| Fail::usage("--resume needs --prompt-file"))?;
        let text = fs::read_to_string(file)
            .map_err(|e| Fail::usage(format!("cannot read the prompt file {}: {e}", file.display())))?;
        if text.trim().is_empty() {
            return Err(Fail::usage(format!("the prompt file {} is empty", file.display())));
        }
        (text, Some(id))
    } else {
        if let Some(id) = known {
            return Err(Fail::refused(format!(
                "unit {unit} already has session {id}; use --resume with a --prompt-file"
            )));
        }
        let prompt = format!(
            "Run unit {unit} of issue-drain run {}. Read {}/references/unit.md and follow it. Your unit file is {}.",
            ctx.run_id()?,
            ctx.skill_dir.display(),
            unit_file.display()
        );
        (prompt, None)
    };
    let (prompt, resume_id) = prompt_and_resume;

    let mut argv: Vec<String> = vec!["-p".into(), prompt];
    if let Some(id) = &resume_id {
        argv.extend(["--resume".into(), id.clone()]);
    }
    argv.extend(["--model".into(), model.clone(), "--effort".into(), effort.clone()]);
    argv.extend(["--permission-mode".into(), "acceptEdits".into()]);
    argv.extend(["--permission-prompts".into(), "none".into()]);
    argv.push("--allowedTools".into());
    argv.extend(p.unit_allowed_tools.iter().cloned());
    argv.extend([
        "--plugin-dir".into(),
        ctx.skill_dir.join("guards").display().to_string(),
        "--output-format".into(),
        "stream-json".into(),
        "--verbose".into(),
    ]);

    if ctx.dry_run {
        return Ok(
            json!({"unit": unit, "dry_run": true, "argv": std::iter::once("claude".to_string()).chain(argv).collect::<Vec<_>>()}),
        );
    }

    let attempts = session["attempts"].as_array().cloned().unwrap_or_default();
    let attempt = attempts.len() as u64 + 1;
    let transcript = state_dir.join(format!("transcript-{attempt}.jsonl"));
    let stderr_log = state_dir.join(format!("transcript-{attempt}.stderr"));
    let unit_file_text = unit_file.display().to_string();
    let env = [
        ("VERIFY_GATE_SKIP", "1"),
        ("CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS", "0"),
        ("ISSUE_DRAIN_MODE", "unit"),
        ("ISSUE_DRAIN_UNIT_FILE", unit_file_text.as_str()),
    ];
    let started = ctx.now();
    let ran = exec::run_env(
        "claude",
        &argv,
        &worktree,
        Duration::from_secs(p.unit_timeout_secs),
        (&transcript, &stderr_log),
        &env,
    )?;
    let ended = ctx.now();

    let text = fs::read_to_string(&transcript).unwrap_or_default();
    let seen = parse_transcript(&text);
    let session_id = known_or(&session, seen.session_id.clone());
    let cost = seen.cost_usd;
    let mut record = json!({
        "attempt": attempt,
        "resumed": args.resume,
        "model": model,
        "effort": effort,
        "started": rfc3339(started),
        "ended": rfc3339(ended),
        "exit_code": ran.code,
        "timed_out": ran.timed_out,
        "cost_usd": cost,
        "num_turns": seen.num_turns,
        "is_error": seen.is_error,
    });
    if let Some(id) = result_session(&text).or(seen.session_id) {
        record["session_id"] = json!(id);
    }
    let mut all = attempts;
    all.push(record);
    session = json!({"session_id": session_id, "attempts": all});
    write_json(&session_file, &session)?;

    ctx.event(
        "unit_run",
        json!({"unit": unit, "attempt": attempt, "resumed": args.resume, "model": model,
               "effort": effort, "exit_code": ran.code, "timed_out": ran.timed_out, "cost_usd": cost}),
    )?;
    let result: Value = read_json(&state_dir.join("result.json")).unwrap_or(Value::Null);
    Ok(json!({
        "unit": unit,
        "attempt": attempt,
        "session_id": session_id,
        "resumed": args.resume,
        "model": model,
        "effort": effort,
        "exit_code": ran.code,
        "timed_out": ran.timed_out,
        "cost_usd": cost,
        "result": result,
    }))
}

/// The session already recorded, else the one this run reported.
fn known_or(session: &Value, seen: Option<String>) -> Option<String> {
    recorded_session(session).or(seen)
}

pub fn run(ctx: &Ctx, args: &Args) -> Res<()> {
    let out = launch(ctx, args)?;
    if out["dry_run"] == true {
        let words: Vec<String> = out["argv"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(|w| shlex::try_quote(w).map_or_else(|_| w.to_string(), |q| q.into_owned()))
            .collect();
        println!("WOULD: {}", words.join(" "));
    } else {
        println!("{out}");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_transcript_gives_the_session_and_the_last_result_and_skips_noise() {
        let text = "not json\n{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"s-1\"}\n\
                    {\"type\":\"result\",\"session_id\":\"s-1\",\"total_cost_usd\":0.5,\"is_error\":false,\"num_turns\":3}\n\
                    {\"type\":\"result\",\"session_id\":\"s-1\",\"total_cost_usd\":0.75,\"is_error\":true,\"num_turns\":4}\n";
        let t = parse_transcript(text);
        assert_eq!(t.session_id.as_deref(), Some("s-1"));
        assert_eq!((t.cost_usd, t.num_turns, t.is_error), (Some(0.75), Some(4), Some(true)));
        assert_eq!(parse_transcript("{}\n[1]\n"), Transcript::default());
    }

    #[test]
    fn a_session_only_on_the_result_line_is_still_found() {
        let t = parse_transcript("{\"type\":\"result\",\"session_id\":\"s-9\"}\n");
        assert_eq!(t.session_id.as_deref(), Some("s-9"));
    }
}
