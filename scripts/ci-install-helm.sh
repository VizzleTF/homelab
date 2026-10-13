#!/usr/bin/env bash
# Install the helm version pinned in .mise.toml (Renovate-tracked) into
# /usr/local/bin, verifying the release checksum. Used by the CI jobs and the
# chart publish workflow so they render with the same helm major as ArgoCD.
set -euo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
VERSION=$(sed -n 's/^helm[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' .mise.toml)
[ -n "$VERSION" ] || { echo "::error::helm version not found in .mise.toml" >&2; exit 1; }

TARBALL="helm-v${VERSION}-linux-amd64.tar.gz"
curl -fsSL -o "/tmp/${TARBALL}" "https://get.helm.sh/${TARBALL}"
curl -fsSL -o "/tmp/${TARBALL}.sha256sum" "https://get.helm.sh/${TARBALL}.sha256sum"
( cd /tmp && sha256sum -c "${TARBALL}.sha256sum" )
tar -xzf "/tmp/${TARBALL}" -C /tmp linux-amd64/helm
install -m 755 /tmp/linux-amd64/helm /usr/local/bin/helm
helm version --short
