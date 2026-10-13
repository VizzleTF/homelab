#!/usr/bin/env python3
"""Report values that repeat the chart default or that the chart does not know.

For every argocd/{apps,infra}/<app> with an upstream chart, compares values.yaml
(without the homelab-common section) with `helm show values` of the pinned
version and prints two lists per app:
  default  - leaf keys whose value equals the chart default (CLAUDE.md: write
             only non-defaults; a deliberate pin carries a `# pinned:` comment
             on the same line and is skipped)
  unknown  - keys the chart's default values do not have. Often a typo or a
             removed option, but charts with free-form maps (env, annotations,
             config files) show up here too: read before deleting.
A report, not a gate: exit code is always 0.

Usage: scripts/values-drift.py [app ...]   (run from the repo root; needs helm)
"""
import subprocess
import sys
from pathlib import Path

import yaml

FREE_FORM = {"env", "extraEnv", "additionalEnv", "envFrom", "podAnnotations", "podLabels",
             "annotations", "labels", "nodeSelector", "tolerations", "affinity", "resources",
             "securityContext", "podSecurityContext", "config", "extraArgs", "args"}


def chart_defaults(cfg):
    repo, chart, ver = cfg["repoURL"], cfg["chart"], str(cfg["targetRevision"])
    cmd = ["helm", "show", "values"]
    cmd += [chart, "--repo", repo] if "://" in repo else [f"oci://{repo}/{chart}"]
    out = subprocess.run(cmd + ["--version", ver], capture_output=True, text=True)
    if out.returncode:
        raise RuntimeError(out.stderr.strip().splitlines()[-1] if out.stderr else "helm failed")
    return yaml.safe_load(out.stdout) or {}


def pinned_lines(path):
    return {i + 1 for i, line in enumerate(path.read_text().splitlines()) if "# pinned:" in line}


def walk(values, defaults, path, report, free):
    for k, v in values.items():
        p = f"{path}.{k}" if path else str(k)
        if not isinstance(defaults, dict) or k not in defaults:
            if not free:
                report["unknown"].append(p)
            continue
        d = defaults[k]
        if isinstance(v, dict) and isinstance(d, dict) and v:
            # An empty default map ({}) is a free-form slot: its keys are not "unknown".
            walk(v, d, p, report, free or k in FREE_FORM or not d)
        elif v == d:
            report["default"].append(p)


def main():
    wanted = set(sys.argv[1:])
    for cfg_path in sorted(Path("argocd").glob("*/*/config.yaml")):
        app = cfg_path.parent.name
        if wanted and app not in wanted:
            continue
        cfg = yaml.safe_load(cfg_path.read_text()) or {}
        if cfg.get("homelabOnly"):
            continue
        values_path = cfg_path.parent / "values.yaml"
        values = yaml.safe_load(values_path.read_text()) or {}
        values.pop("homelab-common", None)
        try:
            defaults = chart_defaults(cfg)
        except RuntimeError as e:
            print(f"## {app}: cannot read chart defaults: {e}")
            continue
        report = {"default": [], "unknown": []}
        walk(values, defaults, "", report, False)
        # Keys on a `# pinned:` line are deliberate; match by the last path segment.
        pinned = {values_path.read_text().splitlines()[n - 1].split(":")[0].strip()
                  for n in pinned_lines(values_path)}
        report["default"] = [k for k in report["default"] if k.rsplit(".", 1)[-1] not in pinned]
        if report["default"] or report["unknown"]:
            print(f"## {app} ({cfg['chart']} {cfg['targetRevision']})")
            for kind in ("default", "unknown"):
                for k in report[kind]:
                    print(f"  {kind:8} {k}")


if __name__ == "__main__":
    main()
