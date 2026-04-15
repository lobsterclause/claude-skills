#!/usr/bin/env python3
"""Build a Claude Code plugin marketplace from this repo's .skill archives
and SKILL.md packages.

For each skill source (either a zipped *.skill or a plain SKILL.md directory),
this writes:
  plugins/<name>/.claude-plugin/plugin.json
  plugins/<name>/skills/<name>/SKILL.md

Then emits .claude-plugin/marketplace.json listing every plugin.

Existing .skill archives are left in place. The generated tree under plugins/
is fully derivable — delete it and rerun this script to regenerate.

Usage: python3 scripts/build-marketplace.py
"""

from __future__ import annotations

import json
import shutil
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PLUGINS_DIR = REPO_ROOT / "plugins"
MARKETPLACE_MANIFEST = REPO_ROOT / ".claude-plugin" / "marketplace.json"

SKILL_ARCHIVE_ROOTS = [
    REPO_ROOT / "accessibility-skills-complete",
    REPO_ROOT / "design-skills",
]

SKILL_MD_PACKAGES = [
    REPO_ROOT / "cowork-agent-audit",
]


@dataclass
class Skill:
    name: str
    description: str
    skill_md: str
    source_hint: str


def parse_frontmatter(skill_md: str) -> dict[str, str]:
    if not skill_md.startswith("---\n"):
        raise ValueError("SKILL.md missing YAML frontmatter")
    end = skill_md.find("\n---", 4)
    if end == -1:
        raise ValueError("SKILL.md frontmatter not closed")
    block = skill_md[4:end]
    meta: dict[str, str] = {}
    current_key: str | None = None
    for raw in block.splitlines():
        if not raw.strip():
            continue
        if raw[0] in " \t" and current_key is not None:
            meta[current_key] += " " + raw.strip()
            continue
        if ":" not in raw:
            continue
        key, _, value = raw.partition(":")
        current_key = key.strip()
        meta[current_key] = value.strip()
    if "name" not in meta or "description" not in meta:
        raise ValueError(f"SKILL.md frontmatter missing name/description: {meta}")
    return meta


def load_skill_from_archive(path: Path) -> Skill:
    with zipfile.ZipFile(path) as zf:
        skill_md_name = next(
            (n for n in zf.namelist() if n.endswith("SKILL.md")), None
        )
        if skill_md_name is None:
            raise ValueError(f"{path}: no SKILL.md in archive")
        with zf.open(skill_md_name) as fh:
            skill_md = fh.read().decode("utf-8")
    meta = parse_frontmatter(skill_md)
    return Skill(
        name=meta["name"],
        description=meta["description"],
        skill_md=skill_md,
        source_hint=str(path.relative_to(REPO_ROOT)),
    )


def load_skill_from_package(path: Path) -> Skill:
    skill_md_path = path / "SKILL.md"
    skill_md = skill_md_path.read_text(encoding="utf-8")
    meta = parse_frontmatter(skill_md)
    return Skill(
        name=meta["name"],
        description=meta["description"],
        skill_md=skill_md,
        source_hint=str(skill_md_path.relative_to(REPO_ROOT)),
    )


def write_plugin(skill: Skill) -> None:
    plugin_root = PLUGINS_DIR / skill.name
    skill_dir = plugin_root / "skills" / skill.name
    meta_dir = plugin_root / ".claude-plugin"
    skill_dir.mkdir(parents=True, exist_ok=True)
    meta_dir.mkdir(parents=True, exist_ok=True)

    (skill_dir / "SKILL.md").write_text(skill.skill_md, encoding="utf-8")

    plugin_json = {
        "name": skill.name,
        "version": "0.1.0",
        "description": skill.description,
        "author": {
            "name": "matthewlarn",
            "url": "https://github.com/matthewlarn/claude-skills",
        },
    }
    (meta_dir / "plugin.json").write_text(
        json.dumps(plugin_json, indent=2) + "\n", encoding="utf-8"
    )


def collect_skills() -> list[Skill]:
    skills: dict[str, Skill] = {}

    for root in SKILL_ARCHIVE_ROOTS:
        if not root.exists():
            continue
        for archive in sorted(root.rglob("*.skill")):
            skill = load_skill_from_archive(archive)
            if skill.name in skills:
                print(
                    f"warn: duplicate skill name {skill.name!r} "
                    f"({skills[skill.name].source_hint} vs {skill.source_hint}); "
                    f"keeping first",
                    file=sys.stderr,
                )
                continue
            skills[skill.name] = skill

    for pkg in SKILL_MD_PACKAGES:
        if not (pkg / "SKILL.md").exists():
            continue
        skill = load_skill_from_package(pkg)
        if skill.name in skills:
            print(
                f"warn: duplicate skill name {skill.name!r} "
                f"({skills[skill.name].source_hint} vs {skill.source_hint}); "
                f"keeping first",
                file=sys.stderr,
            )
            continue
        skills[skill.name] = skill

    return sorted(skills.values(), key=lambda s: s.name)


def write_marketplace(skills: list[Skill]) -> None:
    MARKETPLACE_MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    description = (
        "Marketplace wrapper for matthewlarn/claude-skills — "
        "accessibility, design, and prototype-review skills packaged "
        "as Claude Code plugins so each can be toggled on demand."
    )
    manifest = {
        "$schema": "https://anthropic.com/claude-code/marketplace.schema.json",
        "name": "claude-skills",
        "description": description,
        "metadata": {"description": description},
        "owner": {
            "name": "lobsterclause",
            "url": "https://github.com/lobsterclause/claude-skills",
        },
        "plugins": [
            {
                "name": skill.name,
                "description": skill.description,
                "source": f"./plugins/{skill.name}",
            }
            for skill in skills
        ],
    }
    MARKETPLACE_MANIFEST.write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )


def main() -> int:
    if PLUGINS_DIR.exists():
        shutil.rmtree(PLUGINS_DIR)

    skills = collect_skills()
    if not skills:
        print("error: no skills found", file=sys.stderr)
        return 1

    for skill in skills:
        write_plugin(skill)

    write_marketplace(skills)
    print(f"wrote {len(skills)} plugins to {PLUGINS_DIR.relative_to(REPO_ROOT)}/")
    print(f"wrote marketplace manifest to {MARKETPLACE_MANIFEST.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
