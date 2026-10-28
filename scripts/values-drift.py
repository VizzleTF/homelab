#!/usr/bin/env python3
"""Report values that repeat the chart default or that the chart does not know.

For each argocd/{apps,infra}/<app> with an upstream chart, compare values.yaml
(minus homelab-common) with `helm show values` of the pinned version and print:
  default  - leaf keys equal to the chart default (convention: only
             non-defaults; a deliberate pin has `# pinned:` on its line, skipped)
  unknown  - keys absent from the chart defaults: often a typo or removed
             option, but free-form maps (env, annotations, config) land here
             too: read before deleting.
  gomem    - GOMEMLIMIT outside 0.80-0.90 x sibling resources.limits.memory.
A report, not a gate: exit code is always 0.

Usage: scripts/values-drift.py [app ...]   (run from the repo root; needs helm)
"""
import re
import subprocess
import sys
from pathlib import Path

import yaml

FREE_FORM = {"env", "extraEnv", "additionalEnv", "envFrom", "podAnnotations", "podLabels",
             "annotations", "labels", "nodeSelector", "tolerations", "affinity", "resources",
             "securityContext", "podSecurityContext", "config", "extraArgs", "args"}
MEM = re.compile(r"(\d+(?:\.\d+)?)([KMG]i)B?")  # 512Mi, 3Gi (k8s) and 430MiB (Go)
UNIT = {"Ki": 2**10, "Mi": 2**20, "Gi": 2**30}


def mem_bytes(s):
    m = MEM.fullmatch(str(s))
    return float(m[1]) * UNIT[m[2]] if m else None


assert mem_bytes("3Gi") == mem_bytes("3072MiB") == 3 * 2**30
assert mem_bytes("68MiB") / mem_bytes("80Mi") == 0.85
assert mem_bytes("1G") is None and mem_bytes(None) is None


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


def gomemlimit(v):
    """GOMEMLIMIT from an env list ([{name, value}]) or an env map ({GOMEMLIMIT: x})."""
    if isinstance(v, dict):
        return v.get("GOMEMLIMIT")
    if isinstance(v, list):
        return next((e.get("value") for e in v
                     if isinstance(e, dict) and e.get("name") == "GOMEMLIMIT"), None)
    return None


def gomem(node, path, report):
    """Report maps whose GOMEMLIMIT / sibling resources.limits.memory is outside 0.80-0.90."""
    if isinstance(node, list):
        for i, v in enumerate(node):
            gomem(v, f"{path}[{i}]", report)
        return
    if not isinstance(node, dict):
        return
    res = node.get("resources")
    limit = (res.get("limits") or {}).get("memory") if isinstance(res, dict) else None
    gml = next((g for g in map(gomemlimit, node.values()) if g), None)
    if gml and limit:
        g, lim = mem_bytes(gml), mem_bytes(limit)
        if not (g and lim and 0.80 <= g / lim <= 0.90):
            ratio = f"{g / lim:.2f}" if g and lim else "?"  # ? = a unit mem_bytes cannot parse
            report["gomem"].append(f"{path or '.'} {gml}/{limit}={ratio}")
    for k, v in node.items():
        gomem(v, f"{path}.{k}" if path else str(k), report)


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
        report = {"default": [], "unknown": [], "gomem": []}
        walk(values, defaults, "", report, False)
        gomem(values, "", report)
        # Keys on a `# pinned:` line are deliberate; match by the last path segment.
        pinned = {values_path.read_text().splitlines()[n - 1].split(":")[0].strip()
                  for n in pinned_lines(values_path)}
        report["default"] = [k for k in report["default"] if k.rsplit(".", 1)[-1] not in pinned]
        if any(report.values()):
            print(f"## {app} ({cfg['chart']} {cfg['targetRevision']})")
            for kind in report:
                for k in report[kind]:
                    print(f"  {kind:8} {k}")


if __name__ == "__main__":
    main()
