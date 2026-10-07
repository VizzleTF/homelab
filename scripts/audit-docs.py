#!/usr/bin/env python3
"""Deterministic drift checks between the repo and its documentation.

Covers what a script can verify without judgement: Obsidian registries and
cheatsheets vs argocd/{apps,infra,standalone}, wave/namespace in the registry
tables and cheatsheet headers vs config.yaml, pinned chart versions in
cheatsheets, broken wikilinks, the skills index vs skill folders, and repo
paths in backticks that do not exist. Facts in prose (commands, runbook steps)
need a reviewer: see the auditing-docs skill.

Usage: scripts/audit-docs.py [--vault obsidian]   (run from the repo root)
Without the vault (CI) only the skills index and repo-path checks run.
Output: `path: level: message`. Exit 1 on any error.
"""
import argparse
import re
import sys
from pathlib import Path

import yaml

ap = argparse.ArgumentParser()
ap.add_argument("--vault", default="obsidian")
args = ap.parse_args()

REPO = Path(".")
VAULT = Path(args.vault)
APPS_REG = VAULT / "112 ArgoCD/Apps/Applications.md"
INFRA_REG = VAULT / "112 ArgoCD/Infrastructure/Infrastructure.md"
APPS_CS = VAULT / "112 ArgoCD/Apps/all"
INFRA_CS = VAULT / "112 ArgoCD/Infrastructure/all"
# CI has no vault (gitignored symlink): run only the repo-side checks there.
HAVE_VAULT = VAULT.is_dir()

# Infra folders documented under another cheatsheet name.
CHEATSHEET_ALIAS = {
    "intel-device-plugins-operator": "intel-device-plugins",
    "intel-device-plugins-gpu": "intel-device-plugins",
    "victoria-metrics-k8s-stack": "victoria-metrics",
}
# Cheatsheets in Infrastructure/all that are not ArgoCD Applications.
NON_APP_CHEATSHEETS = {"talos-etcd-backup"}  # systemd timer on the ops node
# Standalone Applications: file name -> Application name.
STANDALONE = {"argocd-application.yaml": "argocd", "gateway-api.yaml": "gateway-api"}

findings = []


def report(path, level, msg):
    findings.append((str(path), level, msg))


def load_configs(kind):
    out = {}
    for cfg in sorted((REPO / f"argocd/{kind}").glob("*/config.yaml")):
        c = yaml.safe_load(cfg.read_text()) or {}
        name = cfg.parent.name
        out[name] = {
            "wave": str(c.get("wave", "")).strip(),
            "namespace": str(c.get("namespace") or name),
        }
    return out


def table_rows(text):
    """Yield (header_cells, row_cells, raw_row) for every markdown table."""
    header = None
    for line in text.splitlines():
        if not line.startswith("|"):
            header = None
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if header is None:
            header = [c.lower() for c in cells]
        elif not set(line) <= set("|-: "):
            yield header, cells, line


def row_name(cell, raw):
    m = re.search(r"папка `([^`]+)`", raw)
    if m:
        return m.group(1)
    m = re.match(r"\[\[([^\]|#]+)", cell)
    return m.group(1) if m else cell.split()[0]


def col(header, row, *names):
    for n in names:
        if n in header and header.index(n) < len(row):
            return row[header.index(n)].strip("` ")
    return None


apps, infra = load_configs("apps"), load_configs("infra")
for f, name in STANDALONE.items():
    doc = yaml.safe_load((REPO / "argocd/standalone" / f).read_text())
    wave = doc["metadata"].get("annotations", {}).get("argocd.argoproj.io/sync-wave", "")
    infra[name] = {"wave": str(wave), "namespace": doc["spec"]["destination"]["namespace"]}

# 1-2. Registries vs code, wave/namespace columns.
for reg, configs in ((APPS_REG, apps), (INFRA_REG, infra)) if HAVE_VAULT else ():
    seen = set()
    for header, row, raw in table_rows(reg.read_text()):
        if "name" not in header or not row[0]:
            continue
        name = row_name(row[0], raw)
        if name not in configs:
            report(reg, "error", f"row '{name}' has no folder in argocd/ or standalone")
            continue
        seen.add(name)
        wave = col(header, row, "wave")
        if wave is not None and wave != configs[name]["wave"]:
            report(reg, "error", f"{name}: wave {wave} != config {configs[name]['wave']}")
        ns = col(header, row, "namespace", "ns")
        if ns is not None and ns != configs[name]["namespace"]:
            report(reg, "error", f"{name}: namespace {ns} != config {configs[name]['namespace']}")
    for name in sorted(set(configs) - seen):
        report(reg, "error", f"'{name}' exists in argocd/ but has no registry row")

# 1. Cheatsheets vs folders; cheatsheet header Namespace / Sync-wave.
for cs_dir, configs in ((APPS_CS, apps), (INFRA_CS, infra)) if HAVE_VAULT else ():
    expected = {}
    for name in configs:
        expected.setdefault(CHEATSHEET_ALIAS.get(name, name), name)
    present = {p.stem for p in cs_dir.glob("*.md")}
    for cs in sorted(set(expected) - present):
        report(cs_dir, "error", f"no cheatsheet {cs}.md for argocd folder '{expected[cs]}'")
    for cs in sorted(present - set(expected) - NON_APP_CHEATSHEETS):
        report(cs_dir / f"{cs}.md", "error", "cheatsheet without an argocd folder")
    for cs in sorted(present & set(expected)):
        path = cs_dir / f"{cs}.md"
        if cs in CHEATSHEET_ALIAS.values():
            continue  # one page for several folders; header names one of them
        cfg = configs[expected[cs]]
        text = path.read_text()
        for label, key in (("Namespace", "namespace"), ("Sync-wave", "wave")):
            m = re.search(rf"^\| \*\*{label}\*\* \| `([^`]+)`", text, re.M)
            if m and m.group(1) != cfg[key]:
                report(path, "error", f"{label} `{m.group(1)}` != config {cfg[key]}")
        # 3. Pinned versions (single source of truth is config.yaml targetRevision).
        for m in re.finditer(r"^\| \*\*(Chart|Version)\*\* \|.*$", text, re.M):
            if re.search(r"(?<![\w.])v?\d+\.\d+\.\d+(?![\w.])", m.group(0)):
                report(path, "warning", f"pinned version in **{m.group(1)}** row; use config.yaml targetRevision")

# 4. Wikilinks. Targets: vault notes, plus Claude memory notes (machine-local,
# linked from .claude/ docs); template placeholders are not links.
MEMORY = Path.home() / ".claude/projects/-home-ivan-Documents-home-homelab/memory"
PLACEHOLDER_LINKS = {"Memory page"}  # .claude/skills/README.md "adding a skill" template
notes = {p.stem for p in VAULT.rglob("*.md")} | {p.stem for p in MEMORY.glob("*.md")} | PLACEHOLDER_LINKS
docs = list(VAULT.rglob("*.md")) + [REPO / "CLAUDE.md"] + list((REPO / ".claude").rglob("*.md"))
code_span = re.compile(r"```.*?```|`[^`\n]*`", re.S)
for doc in docs if HAVE_VAULT else ():
    text = code_span.sub("", doc.read_text())
    for target in re.findall(r"\[\[([^\]|#]+)", text):
        t = target.strip()
        if t and t not in notes and not (t.startswith(("feedback_", "reference_", "project_")) and not MEMORY.exists()):
            report(doc, "error", f"broken wikilink [[{t}]]")

# 5. Skills index (.claude/skills/README.md) vs skill folders.
index = (REPO / ".claude/skills/README.md").read_text()
listed = set(re.findall(r"^\| \[`([a-z0-9-]+)`\]", index, re.M))
dirs = {p.name for p in (REPO / ".claude/skills").iterdir() if (p / "SKILL.md").exists()}
for s in sorted(dirs - listed):
    report(".claude/skills/README.md", "error", f"skill '{s}' missing from the index table")
for s in sorted(listed - dirs):
    report(".claude/skills/README.md", "error", f"index lists '{s}', no such skill")

# 6. Repo paths in backticks that do not exist.
# The path is the first word; arguments may follow inside the same backticks.
PATH_RE = re.compile(r"`((?:argocd|scripts|charts|nodes|terraform_talos|\.claude)/[^`\s]*)(?:\s[^`]*)?`")
ARGOCD_TOP = {p.name for p in (REPO / "argocd").iterdir()}
for doc in docs:
    for line in doc.read_text().splitlines():
        if re.search(r"git show|удал[её]н|removed|deleted", line):
            continue  # history: the path is meant to be gone
        for raw in PATH_RE.findall(line):
            p = raw.rstrip("/.,:")
            if re.search(r"[<>{}*$]|\.\.\.|\bmyapp\b", p):  # placeholders, globs, examples
                continue
            parts = p.split("/")
            if parts[0] == "argocd" and len(parts) > 1 and parts[1] not in ARGOCD_TOP:
                continue  # an OpenBao path (home/homelab/k8s/argocd/...), not a repo path
            if not (REPO / p).exists():
                # CLAUDE.md is always loaded: a dead path there is an error.
                level = "error" if doc.name == "CLAUDE.md" and doc.parent == REPO else "warning"
                report(doc, level, f"path `{p}` does not exist")

if not HAVE_VAULT:
    report(VAULT, "warning", "vault not found: registry, cheatsheet and wikilink checks skipped")
for path, level, msg in sorted(findings):
    print(f"{path}: {level}: {msg}")
errors = sum(1 for f in findings if f[1] == "error")
print(f"{errors} error(s), {len(findings) - errors} warning(s)")
sys.exit(1 if errors else 0)
