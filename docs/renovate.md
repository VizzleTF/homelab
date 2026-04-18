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
| Scan schedule | Daily 02:00 UTC (`0 2 * * *`) — refreshes Dependency Dashboard every day |
| PR creation window | Monday 00:00–06:00 UTC (per-repo `schedule: before 6am on monday`) |
| Automerge window | Any time (`automergeSchedule: at any time`) — PRs can auto-merge on any day once CI passes |

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
| `minor` updates (everything else) | Auto-merged |
| `minor` updates for critical infra (`cilium`, `vault`, `cert-manager`, `longhorn`, `argo-cd`, `victoria-metrics-k8s-stack`) | Manual — label `critical-infra` + `manual-review` |
| `major` anything | Manual — requires Dependency Dashboard approval (`dependencyDashboardApproval: true`) |
| Docker `digest` pin updates | Disabled (too noisy) |

**Merge strategy:** Renovate performs the merge itself via its PAT (`automerge: true`, `platformAutomerge: false`) so the flow works identically on the public (`home_proxmox`) and private (`home-proxmox-values`) repos — GitHub's native auto-merge is not available on private repos without a paid plan.

### Grouping (one PR per directory bundle)

Updates are bundled into one PR per directory group to cut noise. The group name becomes the branch prefix (`renovate/<group>`).

**`home_proxmox`:**

| Path glob | Group |
| --- | --- |
| `terraform_proxmox/**` | `terraform-providers` |
| `charts/**` | `homelab-common` |
| `.github/workflows/**` | `github-actions` |
| `argocd/**` (Helm `targetRevision`) | `argocd-charts` |

**`home-proxmox-values`:**

| Path glob | Group |
| --- | --- |
| `values/applications/**` | `applications` |
| `values/infrastructure/**` | `infrastructure` |
| `manifests/**` | `manifests` |

Rebase strategy: `rebaseWhen: "auto"` — Renovate rebases PRs as needed, so branches never go stale.

### Daily Telegram Digest

A second CronJob `renovate-notify` runs every day at **08:00 UTC** (after the 02:00 scan finishes) and posts a summary to the same Telegram channel as VictoriaMetrics alerts.

| Piece | Where |
| --- | --- |
| CronJob | `renovate-notify` in namespace `renovate` |
| Script | `ConfigMap/renovate-notify-script` (`digest.sh`), sourced from `manifests/infrastructure/renovate/notify-cronjob.yaml` |
| Image | `badouralix/curl-jq:latest` (non-root, minimal) |
| GitHub auth | reuses `Secret/renovate-github-token` |
| Telegram bot | shared with alerts — Vault KV at `homelab/k8s/telegram/victoria-metrics-bot` (`token`, `chat_id`) |

Digest content per repo:

- ✅ merged PRs in last 24h (successes — shows Renovate is working)
- ❌ closed-without-merge PRs in last 24h
- 📥 open dependency PRs with full list (links to each)
- ⚠️ PRs labelled `manual-review` (actionable — critical-infra minor that needs your eyes)
- 🔘 Dependency Dashboard counters: pending approval (major — tick a checkbox to greenlight) + awaiting schedule

Manual run (don't wait for 08:00):

```bash
kubectl -n renovate create job --from=cronjob/renovate-notify notify-$(date +%s)
kubectl -n renovate logs -l job-name=notify-* --tail=20
```

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

## Helm Chart Pinning (ArgoCD)

All ArgoCD Helm sources are pinned to explicit versions — no `targetRevision: "*"` on Helm charts (Git-source `HEAD` is still used where appropriate). Renovate detects updates via three regex matchers in `renovate.json` (`customManagers`), scoped to `argocd/**/*.yaml`.

| # | Matches | Example file / structure |
|---|---|---|
| 1 | ApplicationSet list entry **with** `chart:` field (chart name differs from entry name) | `infra-appset.yaml` → `cnpg-operator` (chart `cloudnative-pg`), `pve-exporter` (chart `prometheus-pve-exporter`) |
| 2 | ApplicationSet list entry **without** `chart:` (entry name == chart name) | `infra-appset.yaml` → `cert-manager`, `vault`, `cilium`, ... |
| 3 | Standalone Application `sources[].chart` block | `argocd-application.yaml`, inline cnpg-cluster 2nd source in `apps-appset.yaml` templatePatch |

Regex #2 does **not** match entries with `chart:` because `\s+...\s+repoURL:` requires pure whitespace between name and repoURL — a `chart:` line breaks the pattern. Re2 has no lookahead, so we cannot safely handle partial pinning: **every entry must carry an explicit `targetRevision:`**. A missing `targetRevision:` falls back to the `"*"` safety net in templatePatch — Renovate won't see those entries.

**Where to edit versions manually** — just change the `targetRevision:` string in the entry. Renovate will match the new value and propose upstream updates on the next cron run.

**Safety net:** `templatePatch` in both `infra-appset.yaml` and `apps-appset.yaml` keeps `{{ dig "targetRevision" "*" . }}` as the fallback for any new entry added without a pin. Prefer pinning from day one.

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
