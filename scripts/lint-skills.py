#!/usr/bin/env python3
"""Lint .claude/skills against the checkable parts of Anthropic's skill
authoring best practices (platform.claude.com/docs/en/agents-and-tools/
agent-skills/best-practices).

Usage: scripts/lint-skills.py [SKILLS_DIR]   (default: .claude/skills)
Exit 1 on any error; warnings only print.
"""
import re
import sys
from pathlib import Path

import yaml

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".claude/skills")
errors = warnings = 0


def report(level, path, msg):
    global errors, warnings
    if level == "error":
        errors += 1
    else:
        warnings += 1
    print(f"{path}: {level}: {msg}")


LINK = re.compile(r"\]\(([^)#\s]+\.md)\)")

for skill in sorted(p for p in root.iterdir() if p.is_dir()):
    md = skill / "SKILL.md"
    if not md.exists():
        report("error", skill, "no SKILL.md")
        continue
    text = md.read_text()
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m:
        report("error", md, "no YAML frontmatter")
        continue
    try:
        fm = yaml.safe_load(m.group(1)) or {}
    except yaml.YAMLError as e:
        report("error", md, f"frontmatter is not valid YAML: {e}")
        continue

    name, desc = fm.get("name", ""), fm.get("description", "")
    if name != skill.name:
        report("error", md, f"name '{name}' != directory '{skill.name}'")
    if not re.fullmatch(r"[a-z0-9-]{1,64}", name or ""):
        report("error", md, "name: 1-64 chars, lowercase letters, digits, hyphens")
    if re.search(r"anthropic|claude", name or ""):
        report("error", md, "name contains a reserved word")
    if not isinstance(desc, str) or not desc.strip():
        report("error", md, "description is empty")
        desc = ""
    if len(desc) > 1024:
        report("error", md, f"description is {len(desc)} chars (max 1024)")
    if re.search(r"<[A-Za-z/][^>]*>", desc):
        report("error", md, "description contains an XML-like tag")
    if re.match(r"\s*(I |You |I'm|Я |Ты )", desc):
        report("error", md, "description must be third person")
    if "use when" not in desc.lower() and "use for" not in desc.lower():
        report("warning", md, "description does not say when to use it ('Use when ...')")
    hint = fm.get("argument-hint")
    if hint is not None and not isinstance(hint, str):
        report("error", md, "argument-hint parsed as non-string; quote it")

    body_lines = text[m.end():].count("\n")
    if body_lines > 500:
        report("error", md, f"body is {body_lines} lines (max 500)")

    for ref in skill.rglob("*.md"):
        if ref.name == "SKILL.md":
            continue
        rtext = ref.read_text()
        if rtext.count("\n") > 100 and not re.search(r"^## (Contents|Содержание)", rtext, re.M):
            report("warning", ref, "over 100 lines without a '## Contents' list")
        for target in LINK.findall(rtext):
            if (ref.parent / target).resolve().is_relative_to(skill.resolve()) and target != "SKILL.md":
                report("warning", ref, f"links to another reference file ({target}); keep references one level deep")
        if ref.name not in text:
            report("warning", ref, "not linked from SKILL.md")

    if "\\" in "".join(LINK.findall(text)):
        report("error", md, "backslash in a file link")

print(f"{errors} error(s), {warnings} warning(s)")
sys.exit(1 if errors else 0)
