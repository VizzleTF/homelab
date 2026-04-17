# Renovate Self-Hosted

Self-hosted Renovate bot that scans both homelab repositories and opens pull requests when new versions of Helm charts, Docker images, Terraform providers, or GitHub Actions become available.

## Why

Most public Helm charts in `infra-appset.yaml` are pinned with `targetRevision: "*"`, which means ArgoCD pulls the latest chart on every sync. If an upstream maintainer ships a breaking release overnight, the cluster breaks and there is no record of which version was running before.

Renovate fixes this by:

- Pinning every dependency to an exact version via a single `:pinDependencies` PR on first run.
- Opening a focused PR per update with the upstream changelog in the description.
- Posting a weekly `Dependency Dashboard` issue in each repo with the full state of pending work.

## Architecture

| Piece | Where |
| --- | --- |
| ArgoCD app | `argocd/infrastructure/infra-appset.yaml` entry `renovate` (sync-wave `2`) |
| Helm chart | `renovate/renovate` from `https://docs.renovatebot.com/helm-charts` |
| Helm values | `home-proxmox-values:values/infrastructure/renovate.yaml` |
| GitHub PAT | Vault KV at `homelab/k8s/renovate/github-token`, field `token` |
| Bot-level config | Inline JSON under `renovate.config` in the values file |
| Per-repo config | `renovate.json` in the root of each repo |
| Schedule | Every Monday 02:00 UTC (`0 2 * * 1`) |

The Kubernetes object is a `CronJob` in namespace `renovate` — one-shot pod that runs through every listed repository, opens/updates PRs, then exits. No long-running service.

## PR Workflow

1. CronJob fires, bot scans both repos.
2. Renovate opens a PR per update on a dedicated branch (`renovate/<dep>-<range>`).
3. You review in GitHub, approve, merge.
4. ArgoCD (`syncPolicy.automated`) picks up the commit on `main` and reconciles.
5. Any failures trigger ArgoCD health alerts through the Victoria Metrics / Alertmanager → Telegram chain.

### Automation Rules (live)

| Scope | Automation |
| --- | --- |
| `patch` + `pin` updates (both repos) | Auto-merged by Renovate once the PR is mergeable |
| `minor` GitHub Actions bumps (`home_proxmox`) | Auto-merged (low blast radius) |
| `minor` updates for user-facing apps (`home-proxmox-values:values/applications/**`) | Auto-merged |
| `minor` updates for infra Helm charts | Manual review |
| `major` anything | Manual — requires Dependency Dashboard approval (`dependencyDashboardApproval: true`) |
| Docker `digest` pin updates | Disabled (too noisy) |

**Merge strategy:** Renovate performs the merge itself via its PAT (`automerge: true`, `platformAutomerge: false`) so the flow works identically on the public (`home_proxmox`) and private (`home-proxmox-values`) repos — GitHub's native auto-merge is not available on private repos without a paid plan.

To push the envelope later: add grouping (`groupName` per ecosystem) or relax infra-minor to automerge after a few weeks of confidence.

## Operations

### Manual run (do not wait for cron)

```bash
kubectl -n renovate create job --from=cronjob/renovate manual-$(date +%s)
kubectl -n renovate logs -f -l job-name=<job-name>
```

### Check status

```bash
kubectl -n renovate get cronjob,job,externalsecret,secret
kubectl -n renovate get events --sort-by=.lastTimestamp
```

### Rotate the GitHub token

Current token is a classic PAT (`ghp_…`) with `repo, workflow` scopes. Rotation steps:

1. Create a new classic PAT in GitHub → Settings → Developer settings → Personal access tokens (classic). Scopes: `repo`, `workflow`. Expiry: 1 year. Set a calendar reminder.
2. Put it in Vault:
   ```bash
   vault kv put home/homelab/k8s/renovate/github-token token=<new-pat>
   ```
3. Force ExternalSecret refresh:
   ```bash
   kubectl -n renovate annotate externalsecret renovate-github-token force-sync=$(date +%s) --overwrite
   ```
4. Next cron run picks up the new token automatically — CronJob creates a fresh pod each run.
5. Revoke the old PAT in GitHub after confirming a successful cron run.

### Change the schedule

Edit `cronjob.schedule` in `values/infrastructure/renovate.yaml` and push. ArgoCD reconciles the CronJob spec within minutes.

### Disable temporarily

Set `cronjob.suspend: true` in the values file, commit, push. ArgoCD reconciles, future runs skip. Revert to re-enable.

## Configuration Split

**Bot-level config** (in `values/infrastructure/renovate.yaml` under `renovate.config`): platform, token source, repository list, `autodiscover: false`, `onboarding: false`, `requireConfig: required`, bot git identity.

**Per-repo config** (`renovate.json` at repo root): presets, timezone, schedule, `packageRules`, `customManagers`, label strategy. Each repo owns its own tuning — `home_proxmox` (public, infra + Terraform) has different update rhythm than `home-proxmox-values` (private, Helm values).

## Troubleshooting

- **Pod in `Error` with `RENOVATE_TOKEN` missing** → ExternalSecret hasn't synced. Check `kubectl -n renovate describe externalsecret renovate-github-token` and confirm the Vault path exists.
- **Auth error `401` in logs** → PAT expired or scope stripped. Rotate per steps above.
- **No PRs appearing** → confirm `renovate.json` is present in the repo root and `requireConfig: required` can find it. Check logs for `WARN: Config does not exist`.
- **Regex managers not matching** → run `LOG_LEVEL=debug` via `cronjob.env.LOG_LEVEL=debug` and manual-run; search logs for `customManager` entries.

## Rollback

```bash
# 1. Remove the renovate entry from infra-appset.yaml → commit → push
# 2. ArgoCD deletes the Application (finalizer cleans namespace)
kubectl delete namespace renovate
```

Vault secret at `homelab/k8s/renovate/github-token` persists for re-deploy without rotation.
