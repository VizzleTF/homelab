#!/usr/bin/env python3
"""Shellcheck shell scripts embedded in YAML under argocd/.

Three kinds: a container (mapping with `image` and `command`/`args`) whose
argv is `<sh|bash|ash> ... -c <script>` (also -ec, -euc); a ConfigMap-style
`<name>.sh: |` value (dialect from its shebang, sh without one); a script
written out by `cat > <file>.sh <<'TAG'` inside either (shellcheck sees a
heredoc as data). Strings with Helm templating (`{{`) are skipped.

Usage: scripts/shellcheck-inline.py [shellcheck-binary]   (from the repo root)
Exit code: 1 when any script has a warning.
"""
import re
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

import yaml

SHELLS = {"sh": "sh", "ash": "sh", "bash": "bash"}
C_FLAG = re.compile(r"^-[a-z]*c[a-z]*$")
HEREDOC = re.compile(r"cat > (\S+\.sh) <<'?(\w+)'?\n(.*?)\n[ \t]*\2\n", re.S)


def shebang_shell(body):
    return "bash" if "bash" in body.split("\n", 1)[0] else "sh"


def container_script(c):
    argv = [a for a in (c.get("command") or []) + (c.get("args") or []) if isinstance(a, str)]
    shell = SHELLS.get(argv[0].rsplit("/", 1)[-1]) if argv else None
    i = next((n + 1 for n, a in enumerate(argv) if C_FLAG.match(a)), len(argv))
    if shell is None or i >= len(argv):
        return None
    return c.get("name", "container"), shell, argv[i]


def scripts_in(node):
    """Yield (name, shell, body) for every embedded script under node."""
    if isinstance(node, dict):
        if "image" in node and ("command" in node or "args" in node):
            found = container_script(node)
            if found:
                yield found
        for k, v in node.items():
            if isinstance(k, str) and k.endswith(".sh") and isinstance(v, str) and "\n" in v:
                yield k, shebang_shell(v), v
            else:
                yield from scripts_in(v)
    elif isinstance(node, list):
        for v in node:
            yield from scripts_in(v)


def expand(name, shell, body):
    """The script plus every .sh file it writes out by heredoc."""
    yield name, shell, body
    for m in HEREDOC.finditer(body):
        nested = textwrap.dedent(m[3])
        yield Path(m[1]).name, shebang_shell(nested), nested


def selfcheck():
    doc = yaml.safe_load("""
spec:
  containers:
    - {name: a, image: x, command: [/bin/sh, -ec], args: ["echo a\\ncat > /t/n.sh <<'SH'\\n  #!/bin/bash\\n  echo n\\n  SH\\n"]}
    - {name: b, image: x, args: [--flag]}
data:
  lib.sh: "f() {\\n  :\\n}\\n"
""")
    got = [(n, sh) for found in scripts_in(doc) for n, sh, _ in expand(*found)]
    assert got == [("a", "sh"), ("n.sh", "bash"), ("lib.sh", "sh")], got


def main():
    selfcheck()
    shellcheck = sys.argv[1] if len(sys.argv) > 1 else "shellcheck"
    files = subprocess.run(["git", "ls-files", "argocd/*.yaml"], check=True,
                           capture_output=True, text=True).stdout.split()
    tmp = Path(tempfile.mkdtemp())
    scripts = []
    for f in files:
        for doc in yaml.safe_load_all(Path(f).read_text()):
            for name, shell, body in scripts_in(doc):
                if "{{" in body:
                    continue
                for name, shell, body in expand(name, shell, body):
                    out = tmp / f"{f.replace('/', '__')}__{name}__{len(scripts)}.{shell}"
                    out.write_text(body)
                    scripts.append((str(out), shell))
    rc = 0
    for path, shell in scripts:
        rc |= subprocess.run([shellcheck, "-S", "warning", "-s", shell, path]).returncode
    print(f"checked {len(scripts)} inline scripts", file=sys.stderr)
    sys.exit(1 if rc else 0)


if __name__ == "__main__":
    main()
