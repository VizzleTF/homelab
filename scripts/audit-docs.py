#!/usr/bin/env python3
"""Deterministic drift checks between the repo and its documentation.

Covers what a script can verify without judgement: the config.yaml contract
of every argocd/{apps,infra}/* folder, the homelab-common legacySelector guard,
cheatsheets without an argocd folder, broken wikilinks, repo paths in backticks that do not exist, apps-appset vs infra-appset parity,
and Authentik blueprints (grant_types set, no launch_url, no ambiguous profile
!Find, every blueprint ConfigMap mounted by blueprints.configMaps and back).
Facts in prose (commands, runbook steps) need a reviewer: see the
auditing-docs skill.

Usage: scripts/audit-docs.py [--vault obsidian]   (run from the repo root)
Without the vault (CI) the cheatsheet and wikilink checks are skipped.
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
# Cheatsheets in {Apps,Infrastructure}/all that are not ArgoCD Applications:
# both are services on the ops node (Forgejo, the etcd snapshot timer).
NON_APP_CHEATSHEETS = {"talos-etcd-backup", "forgejo"}
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


apps, infra = load_configs("apps"), load_configs("infra")
for f, name in STANDALONE.items():
    doc = yaml.safe_load((REPO / "argocd/standalone" / f).read_text())
    wave = doc["metadata"].get("annotations", {}).get("argocd.argoproj.io/sync-wave", "")
    infra[name] = {"wave": str(wave), "namespace": doc["spec"]["destination"]["namespace"]}

# 1. Every cheatsheet belongs to an argocd folder (a cheatsheet is optional).
for cs_dir, configs in ((APPS_CS, apps), (INFRA_CS, infra)) if HAVE_VAULT else ():
    expected = {CHEATSHEET_ALIAS.get(name, name) for name in configs}
    for p in sorted(cs_dir.glob("*.md")):
        if p.stem not in expected | NON_APP_CHEATSHEETS:
            report(p, "error", "cheatsheet without an argocd folder")

# 4. Wikilinks. Targets: vault notes.
notes = {p.stem for p in VAULT.rglob("*.md")}
docs = list(VAULT.rglob("*.md")) + [REPO / "CLAUDE.md"] + [p for p in (REPO / ".claude").rglob("*.md") if "worktrees" not in p.parts]
code_span = re.compile(r"```.*?```|`[^`\n]*`", re.S)
for doc in docs if HAVE_VAULT else ():
    text = code_span.sub("", doc.read_text())
    for target in re.findall(r"\[\[([^\]|#]+)", text):
        t = target.strip()
        if t and t not in notes:
            report(doc, "error", f"broken wikilink [[{t}]]")

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

# 7. config.yaml contract. The AppSet template reads optional keys with
# index/dig, so a typo (extraManifest, namspace) or a missing chart: renders
# silently wrong instead of failing; Renovate skips a file without chart:.
CONFIG_KEYS = {"chart", "repoURL", "targetRevision", "namespace", "wave", "homelabOnly",
               "extraManifests", "homelabValuesFile", "ignoreDiff"}
UPSTREAM_KEYS = ("chart", "repoURL", "targetRevision")
for kind in ("apps", "infra"):
    for cfg in sorted((REPO / f"argocd/{kind}").glob("*/config.yaml")):
        c = yaml.safe_load(cfg.read_text()) or {}
        folder = cfg.parent
        for k in sorted(set(c) - CONFIG_KEYS):
            report(cfg, "error", f"unknown key '{k}'")
        for k in ("homelabOnly", "extraManifests"):
            if k in c and c[k] is not True:
                report(cfg, "error", f"{k} must be true or absent, got {c[k]!r}")
        if c.get("homelabOnly"):
            for k in UPSTREAM_KEYS:
                if k in c:
                    report(cfg, "error", f"homelabOnly app must not set {k}")
        else:
            for k in UPSTREAM_KEYS:
                if not c.get(k):
                    report(cfg, "error", f"missing {k} (required unless homelabOnly)")
        rev = c.get("targetRevision")
        if rev is not None and not (isinstance(rev, str) and re.fullmatch(r"v?\d+(\.\d+)*([-+][\w.]+)?", rev)):
            report(cfg, "error", f"targetRevision must be an exact quoted version, got {rev!r}")
        if not (isinstance(c.get("wave"), str) and re.fullmatch(r"-?\d+", c["wave"])):
            report(cfg, "error", f"wave must be a quoted integer, got {c.get('wave')!r}")
        if c.get("namespace") == folder.name:
            report(cfg, "warning", "namespace equals the folder name; drop it")
        if bool(c.get("extraManifests")) != (folder / "manifests").is_dir():
            report(cfg, "error", "extraManifests: true if and only if manifests/ exists")
        if "homelabValuesFile" in c and not (folder / str(c["homelabValuesFile"])).is_file():
            report(cfg, "error", f"homelabValuesFile {c['homelabValuesFile']} does not exist")
        if "ignoreDiff" in c:
            try:
                ok = isinstance(c["ignoreDiff"], str) and isinstance(yaml.safe_load(c["ignoreDiff"]), list)
            except yaml.YAMLError:
                ok = False
            if not ok:
                report(cfg, "error", "ignoreDiff must be a block string holding a YAML list")

# 8. homelab-common guard: legacySelector keeps the immutable selector of a
# Deployment created before homelab-common 1.19; it is allowed only for these
# (app folder, workload name) pairs, never for a new workload.
LEGACY_SELECTOR_ALLOWED = {
    ("atuin", "atuin"), ("crowdsec-scraper", "scraper"), ("may", "may"),
    ("netbird", "peer"), ("netbird", "peer-2"), ("opencloud", "opencloud"),
    ("valkey", "valkey"), ("keda-add-ons-http", "loading-proxy"),
}
# 9. volsync[].name is the restic repository path: it must be unique across
# the whole cluster, not just the namespace (a collision mixes two volumes'
# snapshots in one repo).
volsync_names = {}
bp_cms = {}
values_files = sorted(REPO.glob("argocd/*/*/values.yaml")) + sorted(REPO.glob("argocd/*/*/homelab-values.yaml"))
for vf in values_files + [REPO / "argocd/values/argocd.yaml"]:
    hc = (yaml.safe_load(vf.read_text()) or {}).get("homelab-common") or {}
    for v in hc.get("volsync") or []:
        if v.get("name") in volsync_names:
            report(vf, "error", f"volsync name {v['name']} also used in {volsync_names[v['name']]}")
        volsync_names.setdefault(v.get("name"), vf.as_posix())
    for w in hc.get("workloads") or []:
        if "legacySelector" in w and (vf.parent.name, w.get("name")) not in LEGACY_SELECTOR_ALLOWED:
            report(vf, "error", f"workload {w.get('name')}: legacySelector only for Deployments created before 1.19")
    # Authentik blueprints: rules the importer does not enforce.
    for b in hc.get("authentikBlueprints") or []:
        if b.get("name") in bp_cms:
            report(vf, "error", f"blueprint ConfigMap {b['name']} also rendered by {bp_cms[b['name']]}")
        bp_cms.setdefault(b.get("name"), vf.as_posix())
        for fname, body in (b.get("blueprints") or {}).items():
            if "authentik_providers_oauth2.oauth2provider" in body and "grant_types:" not in body:
                report(vf, "error", f"{fname}: grant_types missing (model default [] rejects every login)")
            if re.search(r"^\s+launch_url:", body, re.M):
                report(vf, "error", f"{fname}: launch_url is read-only, use meta_launch_url")
            if "[scope_name, profile]" in body:
                report(vf, "error", f"{fname}: ambiguous !Find, match the profile mapping by name")
# Every blueprint ConfigMap must be mounted into the worker, and every mount
# must have a ConfigMap behind it.
AK_VALUES = REPO / "argocd/apps/authentik/values.yaml"
mounted = ((yaml.safe_load(AK_VALUES.read_text()) or {}).get("blueprints") or {}).get("configMaps") or []
for name in sorted(set(bp_cms) - set(mounted)):
    report(bp_cms[name], "error", f"blueprint ConfigMap {name} not in authentik blueprints.configMaps (never mounted)")
for name in sorted(set(mounted) - set(bp_cms)):
    report(AK_VALUES, "error", f"blueprints.configMaps lists {name}, which nothing renders (worker FailedMount)")

# 10. README "Sync waves" table: every argocd/{apps,infra} folder and the two
# standalone apps listed once, with the wave of its config.yaml (the public
# mirror has no other app catalogue).
readme = (REPO / "README.md").read_text()
if "## Sync waves" in readme:
    sec = readme[readme.index("## Sync waves"):]
    sec = sec[:sec.index("\n---")] if "\n---" in sec else sec
    listed = {}
    for wave, comps in re.findall(r"^\| \*\*(-?\d+)\*\*\s*\|\s*(.+?)\s*\|$", sec, re.M):
        for c in re.split(r"[,;]\s*", comps):
            c = re.sub(r"\s*\(.*\)", "", re.sub(r"^apps:\s*", "", c)).strip()
            if c:
                listed[c] = wave
    waves = {**{k: v["wave"] for k, v in apps.items()}, **{k: v["wave"] for k, v in infra.items()}}
    for name in sorted(set(waves) - set(listed)):
        report("README.md", "error", f"Sync waves table misses {name}")
    for name in sorted(set(listed) - set(waves)):
        report("README.md", "error", f"Sync waves table lists {name}, which has no argocd folder")
    for name in sorted(set(listed) & set(waves)):
        if listed[name] != waves[name]:
            report("README.md", "error", f"{name}: README wave {listed[name]} != config {waves[name]}")

# 11. The two AppSets differ only in name, generator path, project, the
# per-class values file and the part-of label (drift happened once: homelabOnly landed in infra-appset only).
def appset_norm(kind):
    text = (REPO / f"argocd/appsets/{kind}-appset.yaml").read_text()
    return re.sub(r"\b(applications|infrastructure)\b|(?<=argocd/)(apps|infra)(?=/)|(?<=argocd/values/)(apps|infra)(?=\.yaml)", "@", text)
if appset_norm("apps") != appset_norm("infra"):
    report("argocd/appsets/infra-appset.yaml", "error",
           "AppSets differ beyond name/generator path/project/part-of; keep them in step")

if not HAVE_VAULT:
    report(VAULT, "warning", "vault not found: registry, cheatsheet and wikilink checks skipped")
for path, level, msg in sorted(findings):
    print(f"{path}: {level}: {msg}")
errors = sum(1 for f in findings if f[1] == "error")
print(f"{errors} error(s), {len(findings) - errors} warning(s)")
sys.exit(1 if errors else 0)
