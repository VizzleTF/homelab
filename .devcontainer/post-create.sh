#!/usr/bin/env bash
# Idempotent first-run + reopen setup.
# Helm repos come from the https repoURLs in argocd/{apps,infra}/*/config.yaml,
# so the list follows the repo instead of drifting. OCI (scheme-less) and git
# sources need no `helm repo add`. No version pins here: config.yaml has them.

set -euo pipefail

echo "[post-create] Adding helm repositories..."
REPO_DIR=/workspaces/homelab
declare -A SEEN=()
for f in "$REPO_DIR"/argocd/{apps,infra}/*/config.yaml; do
  url=$(sed -n 's/^repoURL:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "$f")
  [[ "$url" == https://* ]] || continue
  [[ -n "${SEEN[$url]:-}" ]] && continue
  SEEN[$url]=1
  helm repo add "$(basename "$(dirname "$f")")" "$url" --force-update >/dev/null
done
helm repo update >/dev/null
echo "[post-create] $(helm repo list | tail -n +2 | wc -l) helm repos configured."

echo "[post-create] Caching MCP server npm packages..."
# Pre-install globally so the first `claude` invocation (which uses `npx -y ...`
# under the hood) finds them in the global prefix and doesn't fetch on demand.
# `npx --help` doesn't work as a warm-up — stdio MCP servers block on stdin.
npm install -g --silent \
  @modelcontextprotocol/server-github \
  kubernetes-mcp-server \
  2>&1 | tail -3 || true

echo "[post-create] Installing pre-commit hooks..."
if [ -f /workspaces/homelab/.pre-commit-config.yaml ]; then
  (cd /workspaces/homelab && pre-commit install --install-hooks >/dev/null)
fi

# chezmoi state and source are bind-mounted from the host. We do NOT run
# `chezmoi apply` here: ~/.claude, ~/.kube, ~/.gitconfig are also bind-mounted
# from the host, and an apply would overwrite host files through the bind.
# Run `chezmoi diff` / `chezmoi apply` manually inside the container if needed.
if command -v chezmoi >/dev/null 2>&1 && [ -d "$HOME/.local/share/chezmoi" ]; then
  echo "[post-create] chezmoi available — run 'chezmoi diff' / 'chezmoi apply' manually."
fi

echo "[post-create] Done. Run 'claude' to start."
