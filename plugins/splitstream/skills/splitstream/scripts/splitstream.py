#!/usr/bin/env python3
"""Deterministic guardrails for Splitstream orchestration.

This helper does not create branches, worktrees, commits, or pull requests. It
validates plans, freezes a base commit, audits completed branches, and scores a
round summary. All mutating repository work remains explicit and reviewable.
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import fnmatch
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Optional


VERSION = 1
PROOF_MODES = {
    "regression-test",
    "existing-suite",
    "static-check",
    "visual-evidence",
    "manual-contract",
}
COMMAND_PROOF_MODES = {"regression-test", "existing-suite", "static-check"}
TERMINAL_STATUSES = {
    "committed",
    "no_work_needed",
    "stated_target_not_reproducible",
    "blocked",
    "errored",
}
MODELS = {"haiku", "sonnet", "opus"}
RISKS = {"low", "normal", "high"}
PUBLISH_MODES = {"draft-pr", "branches-only", "none"}
ISSUE_MUTATIONS = {"ask", "authorized", "none"}
ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,79}$")
BRANCH_RE = re.compile(r"^(?![./])(?!.*(?:\.\.|//|@\{|[~^:?*\[\\]))(?!.*[./]$)[A-Za-z0-9._/-]+$")
SHA_RE = re.compile(r"^[0-9a-f]{40,64}$")
SHELL_CONTROL_RE = re.compile(r"(?:&&|\|\||[|;<>`]|\$\(|[\r\n])")
GLOB_CHARS = set("*?[")
FORBIDDEN_PATH_PREFIXES = (".git/", ".claude/worktrees/", ".splitstream/")
FORBIDDEN_ARTIFACTS = {"AGENT_LOG.md", "TASK.md", "runlog.jsonl"}


def issue(level: str, code: str, message: str, shard: Optional[str] = None) -> dict[str, Any]:
    value: dict[str, Any] = {"level": level, "code": code, "message": message}
    if shard is not None:
        value["shard"] = shard
    return value


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ValueError(f"file not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid JSON in {path}: {exc}") from exc


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=False) + "\n", encoding="utf-8")


def run_git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(
            ["git", "-C", str(repo), *args],
            check=check,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except FileNotFoundError as exc:
        raise ValueError("git is not installed or not on PATH") from exc
    except subprocess.CalledProcessError as exc:
        detail = redact_credentials(exc.stderr.decode("utf-8", errors="replace").strip())
        raise ValueError(f"git {' '.join(args)} failed: {detail or 'unknown error'}") from exc


def git_text(repo: Path, *args: str) -> str:
    return run_git(repo, *args).stdout.decode("utf-8", errors="replace").strip()


def redact_credentials(value: str) -> str:
    return re.sub(r"(?i)(https?://)[^/@\s]+@", r"\1***@", value)


def require_repo(repo: Path) -> Path:
    resolved = repo.resolve()
    if git_text(resolved, "rev-parse", "--is-inside-work-tree") != "true":
        raise ValueError(f"not a Git worktree: {resolved}")
    return resolved


def sanitize_remote_identity(remote: str) -> Optional[str]:
    """Return owner/repo without ever returning credentials or a full URL."""
    clean = remote.strip().split("#", 1)[0].split("?", 1)[0].rstrip("/")
    match = re.search(r"[:/]([^/:\s]+/[^/\s]+?)(?:\.git)?$", clean)
    return match.group(1) if match else None


def repository_identity(repo: Path) -> tuple[Optional[str], str]:
    remote = run_git(repo, "remote", "get-url", "origin", check=False)
    identity = sanitize_remote_identity(remote.stdout.decode("utf-8", errors="replace")) if remote.returncode == 0 else None
    common_result = run_git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir", check=False)
    if common_result.returncode == 0:
        common_dir = common_result.stdout.decode("utf-8", errors="replace").strip()
    else:
        raw = git_text(repo, "rev-parse", "--git-common-dir")
        candidate = Path(raw)
        common_dir = str(candidate.resolve() if candidate.is_absolute() else (repo / candidate).resolve())
    return identity, common_dir


def normalize_scope(value: Any) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError("scope entry must be a non-empty string")
    scope = value.strip().replace("\\", "/")
    while scope.startswith("./"):
        scope = scope[2:]
    if scope.startswith("/"):
        raise ValueError(f"absolute paths are forbidden: {value}")
    parts = PurePosixPath(scope).parts
    if ".." in parts:
        raise ValueError(f"parent traversal is forbidden: {value}")
    if not parts:
        raise ValueError("empty scope is forbidden")
    literal_prefix = static_prefix(scope)
    if literal_prefix == ".git" or literal_prefix.startswith(".git/"):
        raise ValueError(f"Git internals are forbidden: {value}")
    if literal_prefix == ".claude/worktrees" or literal_prefix.startswith(".claude/worktrees/"):
        raise ValueError(f"worktree control paths are forbidden: {value}")
    if literal_prefix == ".splitstream" or literal_prefix.startswith(".splitstream/"):
        raise ValueError(f"orchestration state must live outside the repository: {value}")
    return scope


def static_prefix(pattern: str) -> str:
    indexes = [pattern.find(char) for char in GLOB_CHARS if char in pattern]
    cut = min(indexes) if indexes else len(pattern)
    return pattern[:cut].rstrip("/")


def has_glob(pattern: str) -> bool:
    return any(char in pattern for char in GLOB_CHARS)


def scope_matches(path: str, pattern: str) -> bool:
    normalized = path.replace("\\", "/").lstrip("./")
    scope = pattern.rstrip("/")
    if has_glob(pattern):
        return fnmatch.fnmatchcase(normalized, pattern) or fnmatch.fnmatchcase(normalized, scope)
    return normalized == scope or normalized.startswith(scope + "/")


def scopes_conflict(left: Iterable[str], right: Iterable[str]) -> bool:
    for a in left:
        for b in right:
            a_plain = a.rstrip("/")
            b_plain = b.rstrip("/")
            if a_plain == b_plain:
                return True
            if not has_glob(a) and not has_glob(b):
                if a_plain.startswith(b_plain + "/") or b_plain.startswith(a_plain + "/"):
                    return True
                continue
            if fnmatch.fnmatchcase(a_plain, b) or fnmatch.fnmatchcase(b_plain, a):
                return True
            a_prefix = static_prefix(a)
            b_prefix = static_prefix(b)
            if not a_prefix or not b_prefix:
                return True
            if (
                a_prefix == b_prefix
                or a_prefix.startswith(b_prefix + "/")
                or b_prefix.startswith(a_prefix + "/")
            ):
                return True
    return False


def validate_command(command: Any) -> list[str]:
    problems: list[str] = []
    if not isinstance(command, str) or not command.strip():
        return ["proof command must be a non-empty string"]
    if SHELL_CONTROL_RE.search(command):
        problems.append("shell control operators, substitutions, redirects, and newlines are forbidden")
    try:
        tokens = shlex.split(command)
    except ValueError as exc:
        return [f"proof command cannot be parsed: {exc}"]
    lowered = [token.lower() for token in tokens]
    joined = " ".join(lowered)
    if not tokens:
        problems.append("proof command is empty")
    if lowered and lowered[0] in {"sudo", "rm", "curl", "wget", "ssh", "scp"}:
        problems.append(f"proof command may not start with {tokens[0]}")
    banned_fragments = {
        "git reset": "history/worktree reset",
        "git clean": "worktree cleaning",
        "git checkout": "branch/worktree switching",
        "git switch": "branch/worktree switching",
        "git push": "publication",
        "gh pr": "pull request mutation",
        "gh issue": "issue mutation",
    }
    for fragment, label in banned_fragments.items():
        if fragment in joined:
            problems.append(f"proof command contains forbidden {label}: {fragment}")
    if "--no-verify" in lowered or "skip_prepush" in joined or "husky=0" in joined:
        problems.append("hook bypasses are forbidden")
    return problems


def validate_manifest(manifest: Any) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    errors: list[dict[str, Any]] = []
    warnings: list[dict[str, Any]] = []
    if not isinstance(manifest, dict):
        return [issue("error", "MANIFEST_NOT_OBJECT", "manifest must be a JSON object")], warnings

    if manifest.get("version") != VERSION:
        errors.append(issue("error", "MANIFEST_VERSION", f"version must be {VERSION}"))
    round_id = manifest.get("round_id")
    if not isinstance(round_id, str) or not ID_RE.fullmatch(round_id):
        errors.append(issue("error", "ROUND_ID_INVALID", "round_id has an invalid format"))
    base = manifest.get("base")
    if not isinstance(base, str) or not base.strip():
        errors.append(issue("error", "BASE_MISSING", "base must be a non-empty ref"))
    base_sha = manifest.get("base_sha")
    if base_sha is not None and (not isinstance(base_sha, str) or not SHA_RE.fullmatch(base_sha)):
        errors.append(issue("error", "BASE_SHA_INVALID", "base_sha must be a full lowercase Git object ID"))

    concurrency = manifest.get("max_concurrency")
    if not isinstance(concurrency, int) or isinstance(concurrency, bool) or not 1 <= concurrency <= 16:
        errors.append(issue("error", "CONCURRENCY_INVALID", "max_concurrency must be an integer from 1 to 16"))

    publish = manifest.get("publish")
    if not isinstance(publish, dict):
        errors.append(issue("error", "PUBLISH_INVALID", "publish must be an object"))
    else:
        if publish.get("mode") not in PUBLISH_MODES:
            errors.append(issue("error", "PUBLISH_MODE_INVALID", "publish.mode is invalid"))
        if publish.get("issue_mutations") not in ISSUE_MUTATIONS:
            errors.append(issue("error", "ISSUE_MUTATION_POLICY_INVALID", "publish.issue_mutations is invalid"))
        if publish.get("issue_mutations") == "authorized":
            warnings.append(issue("warning", "ISSUE_MUTATIONS_AUTHORIZED", "this round permits issue mutations; confirm the current invocation explicitly granted that authority"))

    shards = manifest.get("shards")
    if not isinstance(shards, list) or not shards:
        return errors + [issue("error", "SHARDS_MISSING", "shards must be a non-empty array")], warnings

    ids: set[str] = set()
    branches: set[str] = set()
    normalized_scopes: dict[str, list[str]] = {}
    for index, shard in enumerate(shards):
        fallback_id = f"index-{index}"
        if not isinstance(shard, dict):
            errors.append(issue("error", "SHARD_NOT_OBJECT", "shard must be an object", fallback_id))
            continue
        shard_id = shard.get("id")
        label = shard_id if isinstance(shard_id, str) else fallback_id
        if not isinstance(shard_id, str) or not ID_RE.fullmatch(shard_id):
            errors.append(issue("error", "SHARD_ID_INVALID", "shard id has an invalid format", label))
        elif shard_id in ids:
            errors.append(issue("error", "SHARD_ID_DUPLICATE", f"duplicate shard id: {shard_id}", label))
        else:
            ids.add(shard_id)
        for field in ("title", "task"):
            if not isinstance(shard.get(field), str) or not shard[field].strip():
                errors.append(issue("error", f"SHARD_{field.upper()}_MISSING", f"{field} must be non-empty", label))
        branch = shard.get("branch")
        if not isinstance(branch, str) or not BRANCH_RE.fullmatch(branch):
            errors.append(issue("error", "BRANCH_INVALID", "branch name is invalid or unsafe", label))
        elif branch in branches:
            errors.append(issue("error", "BRANCH_DUPLICATE", f"duplicate branch: {branch}", label))
        else:
            branches.add(branch)
        if isinstance(base, str) and branch == base:
            errors.append(issue("error", "BRANCH_IS_BASE", "worker branch may not equal the base ref", label))
        if shard.get("model") not in MODELS:
            errors.append(issue("error", "MODEL_INVALID", "model must be haiku, sonnet, or opus", label))
        if shard.get("risk") not in RISKS:
            errors.append(issue("error", "RISK_INVALID", "risk must be low, normal, or high", label))
        if shard.get("model") == "haiku" and shard.get("risk") != "low":
            warnings.append(issue("warning", "HAIKU_NON_LOW_RISK", "Haiku is intended only for low-risk mechanical shards", label))
        if shard.get("risk") == "high":
            warnings.append(issue("warning", "HIGH_RISK_SHARD", "high-risk work needs explicit human attention after verification", label))

        scopes = shard.get("scope")
        cleaned: list[str] = []
        if not isinstance(scopes, list) or not scopes:
            errors.append(issue("error", "SCOPE_MISSING", "scope must be a non-empty array", label))
        else:
            for raw_scope in scopes:
                try:
                    cleaned.append(normalize_scope(raw_scope))
                except ValueError as exc:
                    errors.append(issue("error", "SCOPE_INVALID", str(exc), label))
        normalized_scopes[label] = cleaned

        proof = shard.get("proof")
        if not isinstance(proof, dict):
            errors.append(issue("error", "PROOF_INVALID", "proof must be an object", label))
        else:
            mode = proof.get("mode")
            if mode not in PROOF_MODES:
                errors.append(issue("error", "PROOF_MODE_INVALID", "proof.mode is invalid", label))
            if not isinstance(proof.get("expectation"), str) or not proof["expectation"].strip():
                errors.append(issue("error", "PROOF_EXPECTATION_MISSING", "proof.expectation must be non-empty", label))
            if mode in COMMAND_PROOF_MODES:
                for problem in validate_command(proof.get("command")):
                    errors.append(issue("error", "PROOF_COMMAND_UNSAFE", problem, label))
            elif proof.get("command") is not None:
                for problem in validate_command(proof.get("command")):
                    errors.append(issue("error", "PROOF_COMMAND_UNSAFE", problem, label))

    valid_shards = [s for s in shards if isinstance(s, dict) and isinstance(s.get("id"), str)]
    for index, left in enumerate(valid_shards):
        for right in valid_shards[index + 1 :]:
            if scopes_conflict(normalized_scopes.get(left["id"], []), normalized_scopes.get(right["id"], [])):
                warnings.append(issue("warning", "SCOPE_COLLISION", f"scope overlaps shard {right['id']}; the shards will run in different waves", left["id"]))
    return errors, warnings


def dirty_paths(repo: Path) -> list[str]:
    output = run_git(repo, "status", "--porcelain=v1", "-z", "--untracked-files=all").stdout
    records = output.decode("utf-8", errors="replace").split("\0")
    paths: list[str] = []
    index = 0
    while index < len(records):
        record = records[index]
        index += 1
        if not record:
            continue
        if len(record) < 4:
            continue
        status = record[:2]
        paths.append(record[3:])
        if ("R" in status or "C" in status) and index < len(records) and records[index]:
            paths.append(records[index])
            index += 1
    return sorted(set(paths))


def resolve_base(repo: Path, manifest: dict[str, Any], fetch: bool) -> tuple[str, str]:
    if fetch:
        result = run_git(repo, "fetch", "--quiet", "origin", check=False)
        if result.returncode != 0:
            detail = redact_credentials(result.stderr.decode("utf-8", errors="replace").strip())
            raise ValueError(f"git fetch origin failed: {detail or 'unknown error'}")
    declared_sha = manifest.get("base_sha")
    if isinstance(declared_sha, str):
        sha = git_text(repo, "rev-parse", "--verify", f"{declared_sha}^{{commit}}")
        return sha, declared_sha
    base = manifest["base"]
    candidates = [f"refs/remotes/origin/{base}", base]
    for candidate in candidates:
        result = run_git(repo, "rev-parse", "--verify", f"{candidate}^{{commit}}", check=False)
        if result.returncode == 0:
            return result.stdout.decode().strip(), candidate
    raise ValueError(f"cannot resolve base ref: {base}")


def calculate_waves(shards: list[dict[str, Any]], max_concurrency: int) -> list[list[str]]:
    waves: list[list[dict[str, Any]]] = []
    for shard in shards:
        placed = False
        for wave in waves:
            if len(wave) >= max_concurrency:
                continue
            if all(not scopes_conflict(shard["scope"], other["scope"]) for other in wave):
                wave.append(shard)
                placed = True
                break
        if not placed:
            waves.append([shard])
    return [[shard["id"] for shard in wave] for wave in waves]


def markdown_preflight(report: dict[str, Any]) -> str:
    manifest = report.get("manifest", {})
    wave_lookup = {
        shard_id: index + 1
        for index, wave in enumerate(manifest.get("waves", []))
        for shard_id in wave
    }

    def cell(value: Any) -> str:
        return str(value).replace("|", "\\|").replace("\n", " ")

    lines = [
        f"Splitstream preflight: **{'READY' if report.get('ok') else 'BLOCKED'}**",
        "",
        f"Frozen base: `{manifest.get('base_sha', 'unresolved')}` from `{report.get('resolved_from', 'unresolved')}`",
        f"Repository: `{manifest.get('repo_identity') or 'local/no-origin'}`; Git common dir: `{manifest.get('git_common_dir', 'unresolved')}`",
        f"Publish policy: `{manifest.get('publish', {}).get('mode', 'unknown')}`; issue mutations: `{manifest.get('publish', {}).get('issue_mutations', 'unknown')}`",
        "",
        "| # | Shard | Model | Risk | Branch | Scope | Proof | Command | Wave |",
        "|---:|---|---|---|---|---|---|---|---:|",
    ]
    for index, shard in enumerate(manifest.get("shards", []), start=1):
        proof = shard.get("proof", {})
        lines.append(
            "| "
            + " | ".join(
                cell(value)
                for value in (
                    index,
                    f"{shard.get('id')}: {shard.get('title')}",
                    shard.get("model"),
                    shard.get("risk"),
                    shard.get("branch"),
                    ", ".join(shard.get("scope", [])),
                    proof.get("mode"),
                    proof.get("command", "—"),
                    wave_lookup.get(shard.get("id"), "—"),
                )
            )
            + " |"
        )
    for heading, key in (("Errors", "errors"), ("Warnings", "warnings")):
        values = report.get(key, [])
        if values:
            lines.extend(["", f"{heading}:"])
            for value in values:
                shard = f" [{value['shard']}]" if value.get("shard") else ""
                lines.append(f"- `{value['code']}`{shard}: {value['message']}")
    if report.get("dirty_paths"):
        lines.extend(["", "Existing dirty paths (preserved):"])
        lines.extend(f"- `{path}`" for path in report["dirty_paths"])
    return "\n".join(lines) + "\n"


def command_preflight(args: argparse.Namespace) -> int:
    repo = require_repo(Path(args.repo))
    manifest = read_json(Path(args.manifest))
    errors, warnings = validate_manifest(manifest)
    prepared = copy.deepcopy(manifest) if isinstance(manifest, dict) else {}
    resolved_from: Optional[str] = None
    if not errors:
        try:
            base_sha, resolved_from = resolve_base(repo, prepared, args.fetch)
            prepared["base_sha"] = base_sha
            repo_identity, common_dir = repository_identity(repo)
            prepared["repo_identity"] = repo_identity
            prepared["git_common_dir"] = common_dir
            if repo_identity is None:
                warnings.append(issue("warning", "ORIGIN_IDENTITY_UNAVAILABLE", "origin has no parseable credential-free owner/repo identity; workers must rely on git_common_dir"))
        except ValueError as exc:
            errors.append(issue("error", "BASE_RESOLUTION_FAILED", str(exc)))

    dirty = dirty_paths(repo)
    if not errors:
        for shard in prepared["shards"]:
            branch_check = run_git(repo, "check-ref-format", "--branch", shard["branch"], check=False)
            if branch_check.returncode != 0:
                errors.append(issue("error", "BRANCH_REF_INVALID", "Git rejected the declared branch name", shard["id"]))
            local_branch = run_git(repo, "show-ref", "--verify", "--quiet", f"refs/heads/{shard['branch']}", check=False)
            remote_branch = run_git(repo, "show-ref", "--verify", "--quiet", f"refs/remotes/origin/{shard['branch']}", check=False)
            if local_branch.returncode == 0 or remote_branch.returncode == 0:
                errors.append(issue("error", "BRANCH_ALREADY_EXISTS", "declared worker branch already exists locally or on origin", shard["id"]))
            overlaps = [path for path in dirty if any(scope_matches(path, scope) for scope in shard["scope"])]
            if overlaps:
                errors.append(issue("error", "DIRTY_SCOPE_OVERLAP", f"existing dirty paths overlap this shard: {', '.join(overlaps)}", shard["id"]))
        if not errors:
            prepared["waves"] = calculate_waves(prepared["shards"], prepared["max_concurrency"])
            prepared["prepared_at"] = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()

    report = {
        "ok": not errors,
        "errors": errors,
        "warnings": warnings,
        "resolved_from": resolved_from,
        "dirty_paths": dirty,
        "manifest": prepared,
    }
    if args.output and not errors:
        write_json(Path(args.output), prepared)
    if args.markdown:
        sys.stdout.write(markdown_preflight(report))
    else:
        json.dump(report, sys.stdout, indent=2)
        sys.stdout.write("\n")
    return 0 if report["ok"] else 2


def changed_paths(repo: Path, base_sha: str, commit: str) -> list[str]:
    output = run_git(repo, "diff", "--name-only", "-z", f"{base_sha}..{commit}").stdout
    return sorted(path for path in output.decode("utf-8", errors="replace").split("\0") if path)


def forbidden_changed_path(path: str) -> bool:
    normalized = path.replace("\\", "/")
    return normalized in FORBIDDEN_ARTIFACTS or any(normalized.startswith(prefix) for prefix in FORBIDDEN_PATH_PREFIXES)


def command_audit(args: argparse.Namespace) -> int:
    repo = require_repo(Path(args.repo))
    manifest = read_json(Path(args.manifest))
    manifest_errors, manifest_warnings = validate_manifest(manifest)
    errors = list(manifest_errors)
    warnings = list(manifest_warnings)
    shard = None
    if isinstance(manifest, dict):
        shard = next((value for value in manifest.get("shards", []) if value.get("id") == args.shard_id), None)
    if shard is None:
        errors.append(issue("error", "SHARD_UNKNOWN", f"manifest has no shard {args.shard_id}"))
    base_sha = manifest.get("base_sha") if isinstance(manifest, dict) else None
    if not isinstance(base_sha, str) or not SHA_RE.fullmatch(base_sha):
        errors.append(issue("error", "BASE_NOT_FROZEN", "manifest must contain a valid base_sha"))
    expected_common_dir = manifest.get("git_common_dir") if isinstance(manifest, dict) else None
    actual_identity, actual_common_dir = repository_identity(repo)
    if not isinstance(expected_common_dir, str) or not expected_common_dir:
        errors.append(issue("error", "REPOSITORY_NOT_FROZEN", "approved manifest must contain git_common_dir"))
    elif Path(expected_common_dir).resolve() != Path(actual_common_dir).resolve():
        errors.append(issue("error", "REPOSITORY_MISMATCH", "audit repository does not match the approved Git common directory"))
    expected_identity = manifest.get("repo_identity") if isinstance(manifest, dict) else None
    if expected_identity is not None and expected_identity != actual_identity:
        errors.append(issue("error", "REPOSITORY_IDENTITY_MISMATCH", "audit repository origin identity does not match the approved manifest"))

    result = read_json(Path(args.result)) if args.result else None
    status = result.get("status") if isinstance(result, dict) else "committed"
    if result is not None:
        if not isinstance(result, dict):
            errors.append(issue("error", "RESULT_NOT_OBJECT", "result must be a JSON object", args.shard_id))
        else:
            if result.get("version") != VERSION:
                errors.append(issue("error", "RESULT_VERSION", f"result version must be {VERSION}", args.shard_id))
            if result.get("round_id") != manifest.get("round_id"):
                errors.append(issue("error", "RESULT_ROUND_MISMATCH", "result round_id does not match manifest", args.shard_id))
            if result.get("shard_id") != args.shard_id:
                errors.append(issue("error", "RESULT_SHARD_MISMATCH", "result shard_id does not match requested shard", args.shard_id))
            if status not in TERMINAL_STATUSES:
                errors.append(issue("error", "RESULT_STATUS_INVALID", "result status is invalid", args.shard_id))
            if shard and result.get("branch") != shard.get("branch"):
                errors.append(issue("error", "RESULT_BRANCH_MISMATCH", "result branch does not match manifest", args.shard_id))
            proof = result.get("proof")
            if not isinstance(proof, dict):
                errors.append(issue("error", "RESULT_PROOF_MISSING", "result proof must be an object", args.shard_id))
            elif shard and proof.get("mode") != shard.get("proof", {}).get("mode"):
                errors.append(issue("error", "RESULT_PROOF_MODE_MISMATCH", "result proof mode does not match manifest", args.shard_id))
            elif shard and proof.get("command") != shard.get("proof", {}).get("command"):
                errors.append(issue("error", "RESULT_PROOF_COMMAND_MISMATCH", "result proof command does not match the approved manifest", args.shard_id))
            if not isinstance(result.get("changed_paths"), list) or not all(isinstance(path, str) for path in result.get("changed_paths", [])):
                errors.append(issue("error", "RESULT_CHANGED_PATHS_INVALID", "result changed_paths must be an array of strings", args.shard_id))
            if not isinstance(result.get("follow_ups"), list) or not all(isinstance(item, str) for item in result.get("follow_ups", [])):
                errors.append(issue("error", "RESULT_FOLLOW_UPS_INVALID", "result follow_ups must be an array of strings", args.shard_id))

    branch = args.branch or (shard.get("branch") if shard else None)
    commit: Optional[str] = None
    actual_paths: list[str] = []
    if status == "committed" and shard and isinstance(base_sha, str) and branch:
        resolution = run_git(repo, "rev-parse", "--verify", f"refs/heads/{branch}^{{commit}}", check=False)
        if resolution.returncode != 0:
            errors.append(issue("error", "BRANCH_MISSING", f"local branch does not exist: {branch}", args.shard_id))
        else:
            commit = resolution.stdout.decode().strip()
            ancestor = run_git(repo, "merge-base", "--is-ancestor", base_sha, commit, check=False)
            if ancestor.returncode != 0:
                errors.append(issue("error", "BASE_NOT_ANCESTOR", "branch does not descend from the frozen base", args.shard_id))
            actual_paths = changed_paths(repo, base_sha, commit)
            if not actual_paths:
                errors.append(issue("error", "EMPTY_COMMIT_RANGE", "committed result has no changes from the frozen base", args.shard_id))
            outside = [path for path in actual_paths if not any(scope_matches(path, scope) for scope in shard["scope"])]
            if outside:
                errors.append(issue("error", "SCOPE_VIOLATION", f"changed paths outside scope: {', '.join(outside)}", args.shard_id))
            forbidden = [path for path in actual_paths if forbidden_changed_path(path)]
            if forbidden:
                errors.append(issue("error", "FORBIDDEN_ARTIFACT", f"forbidden orchestration paths changed: {', '.join(forbidden)}", args.shard_id))
            if isinstance(result, dict):
                reported_commit = result.get("commit")
                if reported_commit != commit:
                    errors.append(issue("error", "COMMIT_MISMATCH", "reported commit is not the branch tip", args.shard_id))
                reported_paths = sorted(set(result.get("changed_paths", []))) if isinstance(result.get("changed_paths"), list) else []
                if reported_paths != actual_paths:
                    errors.append(issue("error", "CHANGED_PATHS_MISMATCH", "reported changed_paths do not match the Git diff", args.shard_id))
                proof = result.get("proof", {})
                if proof.get("outcome") != "passed":
                    errors.append(issue("error", "PROOF_NOT_PASSED", "committed results require passed proof", args.shard_id))
                if not isinstance(proof.get("evidence"), str) or not proof["evidence"].strip():
                    errors.append(issue("error", "PROOF_EVIDENCE_MISSING", "committed results require proof evidence", args.shard_id))
    elif isinstance(result, dict):
        if result.get("commit") not in (None, ""):
            warnings.append(issue("warning", "NONCOMMITTED_HAS_COMMIT", "non-committed result reports a commit; it will not be published", args.shard_id))
        if result.get("changed_paths"):
            errors.append(issue("error", "NONCOMMITTED_HAS_CHANGES", "non-committed terminal result may not report changed paths", args.shard_id))
        summary = result.get("summary")
        if not isinstance(summary, str) or not summary.strip():
            errors.append(issue("error", "RESULT_SUMMARY_MISSING", "terminal result requires an evidence-based summary", args.shard_id))

    report = {
        "ok": not errors,
        "shard_id": args.shard_id,
        "status": status,
        "branch": branch,
        "base_sha": base_sha,
        "commit": commit,
        "changed_paths": actual_paths,
        "errors": errors,
        "warnings": warnings,
    }
    json.dump(report, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0 if report["ok"] else 2


def command_score(args: argparse.Namespace) -> int:
    payload = read_json(Path(args.round))
    entries = payload.get("shards") if isinstance(payload, dict) else None
    if not isinstance(entries, list):
        raise ValueError("round JSON must contain a shards array")

    scored: list[dict[str, Any]] = []
    aggregates: dict[str, list[float]] = {"safety": [], "correctness": [], "delivery": [], "efficiency": []}
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict) or not isinstance(entry.get("result"), dict):
            raise ValueError(f"round shard at index {index} must contain a result object")
        result = entry["result"]
        status = result.get("status")
        audit = entry.get("audit") if isinstance(entry.get("audit"), dict) else {}
        verifier = entry.get("verifier") if isinstance(entry.get("verifier"), dict) else {}
        applicable = status == "committed"
        dimensions: dict[str, Optional[float]] = {
            "safety": None,
            "correctness": None,
            "delivery": 100.0 if status in TERMINAL_STATUSES else 0.0,
            "efficiency": None,
        }
        codes: list[str] = []
        if applicable:
            audit_errors = audit.get("errors", []) if isinstance(audit.get("errors"), list) else []
            dimensions["safety"] = max(0.0, 100.0 - 25.0 * len(audit_errors))
            if audit_errors:
                codes.append("AUDIT_ERRORS")
            proof_passed = result.get("proof", {}).get("outcome") == "passed"
            verifier_approved = verifier.get("verdict") == "approve"
            dimensions["correctness"] = (50.0 if proof_passed else 0.0) + (25.0 if audit.get("ok") else 0.0) + (25.0 if verifier_approved else 0.0)
            if not proof_passed:
                codes.append("PROOF_NOT_PASSED")
            if not verifier_approved:
                codes.append("VERIFIER_NOT_APPROVED")
            dimensions["delivery"] = 100.0 if entry.get("draft_pr_url") else 60.0 if entry.get("pushed") else 30.0
        else:
            codes.append("QUALITY_NOT_APPLICABLE")
        elapsed = result.get("elapsed_seconds")
        budget = result.get("budget_seconds")
        if isinstance(elapsed, (int, float)) and isinstance(budget, (int, float)) and budget > 0:
            dimensions["efficiency"] = round(max(0.0, min(100.0, 100.0 * budget / max(elapsed, budget))), 1)
        for name, value in dimensions.items():
            if value is not None:
                aggregates[name].append(value)
        scored.append({
            "shard_id": result.get("shard_id"),
            "status": status,
            "quality_applicable": applicable,
            "dimensions": dimensions,
            "codes": codes,
        })

    aggregate_values = {
        name: (round(sum(values) / len(values), 1) if values else None)
        for name, values in aggregates.items()
    }
    report = {"version": VERSION, "dimensions": aggregate_values, "shards": scored}
    json.dump(report, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


def command_doctor(args: argparse.Namespace) -> int:
    repo = require_repo(Path(args.repo))
    state_root = os.environ.get("CLAUDE_PLUGIN_DATA") or str(Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude"))) / "splitstream")
    branch = git_text(repo, "branch", "--show-current") or None
    repo_identity, common_dir = repository_identity(repo)
    report = {
        "ok": True,
        "repo": str(repo),
        "branch": branch,
        "repo_identity": repo_identity,
        "git_common_dir": common_dir,
        "git": shutil.which("git"),
        "python": sys.executable,
        "gh": shutil.which("gh"),
        "state_root": state_root,
        "dirty_paths": dirty_paths(repo),
    }
    json.dump(report, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Splitstream deterministic guardrails")
    parser.add_argument("--version", action="version", version=f"splitstream {VERSION}")
    subparsers = parser.add_subparsers(dest="command", required=True)

    doctor = subparsers.add_parser("doctor", help="inspect local prerequisites without mutation")
    doctor.add_argument("--repo", default=".")
    doctor.set_defaults(func=command_doctor)

    preflight = subparsers.add_parser("preflight", help="validate a manifest and freeze its base SHA")
    preflight.add_argument("--repo", default=".")
    preflight.add_argument("--manifest", required=True)
    preflight.add_argument("--output")
    preflight.add_argument("--fetch", action="store_true", help="fetch origin before resolving the base")
    preflight.add_argument("--markdown", action="store_true")
    preflight.set_defaults(func=command_preflight)

    audit = subparsers.add_parser("audit", help="audit one worker result against its approved shard")
    audit.add_argument("--repo", default=".")
    audit.add_argument("--manifest", required=True)
    audit.add_argument("--shard-id", required=True)
    audit.add_argument("--branch")
    audit.add_argument("--result")
    audit.set_defaults(func=command_audit)

    score = subparsers.add_parser("score", help="score a completed round without penalizing legitimate no-op outcomes")
    score.add_argument("--round", required=True)
    score.set_defaults(func=command_score)
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except ValueError as exc:
        json.dump({"ok": False, "errors": [issue("error", "INPUT_ERROR", str(exc))]}, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
