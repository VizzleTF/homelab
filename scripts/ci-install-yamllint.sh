#!/usr/bin/env bash
# Install the yamllint version pinned in .mise.toml (Renovate-tracked) into a
# venv at /tmp/yamllint, linked into /usr/local/bin. Used by the CI yamllint job
# (whose shellcheck step reuses the venv's pip) and the kubeconform job (hook
# self-check). The Debian package lagged (1.29 vs 1.38).
set -euo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
VERSION=$(sed -n 's/^yamllint[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' .mise.toml)
[ -n "$VERSION" ] || { echo "::error::yamllint version not found in .mise.toml" >&2; exit 1; }

apt-get update -qq
apt-get install -y --no-install-recommends python3-venv python3-yaml
python3 -m venv /tmp/yamllint
/tmp/yamllint/bin/pip install --quiet "yamllint==${VERSION}"
ln -sf /tmp/yamllint/bin/yamllint /usr/local/bin/yamllint
yamllint --version
