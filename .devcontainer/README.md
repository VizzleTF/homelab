# Devcontainer

Reproducible dev environment for the homelab repo with pinned CLI toolchain and Claude Code.

## Open

VS Code: `code <repo>` → command palette → **Dev Containers: Reopen in Container**.
Cursor / JetBrains have the same flow (any IDE supporting the `devcontainer` spec).

First build: ~3–5 min (downloads pinned binaries + builds `terraform-mcp-server`). Subsequent reopens hit the local image cache.

## What's inside

| Tool | Pin ARG | Source |
|---|---|---|
| `kubectl` | `KUBECTL_VERSION` | `dl.k8s.io` |
| `helm` | `HELM_VERSION` | `get.helm.sh` |
| `talosctl` | `TALOSCTL_VERSION` | `github.com/siderolabs/talos` |
| `terraform` | `TERRAFORM_VERSION` | `releases.hashicorp.com` |
| `vault` | `VAULT_VERSION` | `releases.hashicorp.com` |
| `argocd` | `ARGOCD_VERSION` | `github.com/argoproj/argo-cd` |
| `gitleaks` | `GITLEAKS_VERSION` | `github.com/gitleaks/gitleaks` (matches `.pre-commit-config.yaml`) |
| `gh` | `GH_VERSION` | `github.com/cli/cli` |
| `claude` | `CLAUDE_CODE_VERSION` | npm `@anthropic-ai/claude-code` |
| `terraform-mcp-server` | `TERRAFORM_MCP_VERSION` | built from source (`hashicorp/terraform-mcp-server`) |
| `pre-commit` | `PRE_COMMIT_VERSION` | pip |
| `jq`, `yamllint`, `python3-yaml`, `psql` | apt | Debian bookworm |
| Node.js 22 | Nodesource | for npx-based MCP servers |

All `ARG` lines have `# renovate: ...` comments — Renovate opens PRs as new versions land.

## Host bind-mounts

| Host | Container | Mode | Why |
|---|---|---|---|
| `~/.claude` | `/home/vscode/.claude` | RW | memory, user-level skills/agents/rules, settings.json |
| `~/.claude.json` | `/home/vscode/.claude.json` | RW | Claude Code auth state |
| `~/.kube` | `/home/vscode/.kube` | RO | kubeconfig (note: local context is **not** homelab — use MCP) |
| `~/.config/argocd` | `/home/vscode/.config/argocd` | RW | argocd CLI tokens |
| `~/.ssh` | `/home/vscode/.ssh` | RO | SSH key for Forgejo push |
| `~/.gitconfig` | `/home/vscode/.gitconfig` | RO | git identity |

## Host env propagated via `remoteEnv`

- `VAULT_ADDR`, `VAULT_TOKEN` — needed by `scripts/forgejo-pr.sh` and most skills
- `ANTHROPIC_API_KEY` — if you use it (OAuth login also works without)
- `KUBECONFIG=/home/vscode/.kube/config` — pinned to mounted path
- `TFE_ADDRESS=https://app.terraform.io` — for terraform-mcp-server

Make sure these are exported on the host (e.g. via `~/.zshrc`) before opening the container.

## Rebuild after Dockerfile edit

Command palette → **Dev Containers: Rebuild Container**. BuildKit caches all stages, only the modified layer rebuilds.

To bump a tool manually, edit the `ARG` and rebuild. Renovate will do this for you on `main`.

## Verify after first build

```bash
# inside the container
kubectl version --client          # matches KUBECTL_VERSION
helm version --short              # matches HELM_VERSION
talosctl version --client         # matches TALOSCTL_VERSION
terraform -version                # matches TERRAFORM_VERSION
vault version                     # matches VAULT_VERSION
argocd version --client           # matches ARGOCD_VERSION
gitleaks version                  # matches GITLEAKS_VERSION (and .pre-commit-config.yaml)
gh --version                      # matches GH_VERSION
claude --version                  # matches CLAUDE_CODE_VERSION
terraform-mcp-server --version    # matches TERRAFORM_MCP_VERSION

# claude code state
claude
> /mcp      # terraform, github, kubernetes + user-level argocd-mcp — all connected
> /skills   # 19 project skills (gerund-named) + user-level

# secrets / cluster access
vault status         # Vault answers (means VAULT_ADDR + VAULT_TOKEN propagated)
ssh -T git@git.example.com   # Forgejo SSH key works
```

## MCP gotchas

- `terraform` MCP needs `/usr/local/bin/terraform-mcp-server` — installed by Dockerfile, path matches `.claude/settings.json`.
- `kubernetes` MCP needs `kubectl` in PATH (installed) and a valid kubeconfig (mounted RO). **It reads the local context** — which per `feedback_kubectl_context.md` is NOT homelab. For homelab cluster state, switch the local kubeconfig or set `KUBECONFIG` to a homelab-pointing file before using the MCP.
- `github` MCP is npx-cached on first run by `post-create.sh`.
- `argocd-mcp` (user-level) is in `~/.claude/settings.json` and travels via the bind-mount; needs `argocd` CLI (installed) + `~/.config/argocd/config` (mounted).
