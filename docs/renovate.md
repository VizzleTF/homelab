# Renovate Self-Hosted

Self-hosted Renovate bot that scans both homelab repositories and opens pull requests when new versions of Helm charts, Docker images, Terraform providers, or GitHub Actions become available.

## Why

Most public Helm charts in `infra-appset.yaml` are pinned with `targetRevision: "*"`, which means ArgoCD pulls the latest chart on every sync. If an upstream maintainer ships a breaking release overnight, the cluster breaks and there is no record of which version was running before.

Renovate fixes this by:

- Pinning every dependency to an exact version via a single `:pinDependencies` PR on first run.
- Opening a focused PR per update with the upstream changelog in the description.
- Refreshing a `Dependency Dashboard` issue in each repo daily with the full state of pending work.

## Architecture

### Deployment

| Piece | Where |
| --- | --- |
| ArgoCD app | `argocd/infrastructure/infra-appset.yaml` entry `renovate` (sync-wave `2`) |
| Helm chart | `renovate/renovate` from `https://docs.renovatebot.com/helm-charts`, pinned via `targetRevision` |
| Helm values | `home-proxmox-values:values/infrastructure/renovate.yaml` |
| Extra manifests | `home-proxmox-values:manifests/infrastructure/renovate/` — pulled via `extraManifests: true` on the ApplicationSet entry (notify CronJob + its ConfigMap, VMRule) |
| GitHub PAT | Vault KV `homelab/k8s/renovate/github-token` (`token`) → `Secret/renovate-github-token` |
| Telegram creds | Vault KV `homelab/k8s/telegram/victoria-metrics-bot` (`token`, `chat_id`), shared with Alertmanager → `Secret/renovate-notify-telegram` |
| Bot-level config | Inline JSON under `renovate.config` in the values file |
| Per-repo config | `renovate.json` in the root of each repo |

The Kubernetes objects are two `CronJob`s in namespace `renovate` — one-shot pods that run through every listed repository, open/update PRs, post the digest, then exit. No long-running service.

### Scheduling & automerge

| Window | Value |
| --- | --- |
| Scan (main CronJob) | Daily 02:00 UTC (`0 2 * * *`) — also refreshes the Dependency Dashboard |
| Digest (notify CronJob) | Daily 08:00 UTC (`0 8 * * *`) — 6h after scan, so numbers are fresh |
| PR creation | **At any time** — no weekly window; PRs open on the next scan after an update is detected |
| Automerge | At any time — PRs can auto-merge on any day once CI passes |
| Release stabilization | `minimumReleaseAge: "3 days"` — wait 3 days after upstream tag before proposing an update (guards against reverted/broken releases) |
| Security PRs (CVE / OSV) | Bypass `minimumReleaseAge`, auto-merge enabled, label `security` |

### Persistent cache (PVC)

Renovate's repository cache (git clones, lookups, dashboard state) lives on a 2 GiB Longhorn PVC (`renovate.persistence.cache.enabled: true`) and is reused across runs. This cuts scan time significantly and reduces GitHub API rate-limit pressure.

### Resources & Node.js heap

Renovate's Node.js process does heavy in-memory dependency graph work during the `lookupUpdates` phase. With 30+ Helm deps across ArgoCD manifests, the default V8 heap hits OOM.

Current settings (`values/infrastructure/renovate.yaml`):

| Setting | Value | Why |
|---|---|---|
| `env.NODE_OPTIONS` | `--max-old-space-size=1536` | Raises V8 old-generation heap ceiling from default ~512 MB to 1.5 GB |
| `env.RENOVATE_REPOSITORY_CACHE` | `enabled` | Reuse cached repo metadata from PVC |
| `resources.requests` | `100m` / `512Mi` | Baseline extraction phase |
| `resources.limits` | `1000m` / `2Gi` | Headroom above the 1.5 GB heap cap for Node.js runtime + native libs |

If you add many more repos or dependencies and see `FATAL ERROR: Ineffective mark-compacts near heap limit`, bump `--max-old-space-size` (and keep `limits.memory` at least 512 MB above it).

## PR Workflow

1. CronJob fires, bot scans both repos.
2. Renovate opens a PR per update on a dedicated branch (`renovate/<group>-<range>`).
3. You review in GitHub, approve, merge — or Renovate auto-merges (see rules below).
4. ArgoCD (`syncPolicy.automated`) picks up the commit on `main` and reconciles.
5. Any failures trigger ArgoCD health alerts through the VictoriaMetrics / Alertmanager → Telegram chain.

### Automation Rules (live)

| Scope | Automation |
| --- | --- |
| Security PRs (CVE / OSV) | Auto-merged, bypass stabilization delay, label `security` |
| `patch` / `pin` / `minor` updates (both repos) | Auto-merged once the PR is mergeable |
| `minor` updates for critical infra (`cilium`, `vault`, `cert-manager`, `longhorn`, `argo-cd`, `victoria-metrics-k8s-stack`) | Manual — label `critical-infra` + `manual-review` |
| `major` anything | Manual — requires Dependency Dashboard approval (`dependencyDashboardApproval: true`) |
| Docker `digest` pin updates | Disabled (too noisy) |

**Merge strategy:** Renovate performs the merge itself via its PAT (`automerge: true`, `platformAutomerge: false`) so the flow works identically on the public (`home_proxmox`) and private (`home-proxmox-values`) repos — GitHub's native auto-merge is not available on private repos without a paid plan.

### Commit messages & labels

Renovate commits in both repos use `commitMessagePrefix: "chore(deps):"`, so `git log --grep '^chore(deps):'` gives a clean feed of dependency activity. Every PR carries a `dependencies` label, plus any of `automerge` / `manual-review` / `critical-infra` / `major` / `security` as applicable.

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

### Custom Managers

Beyond the built-in managers (Dockerfile, Helm values, Terraform, GitHub Actions, Kubernetes), each repo has its own extra pinning:

| Repo | Scope | Mechanism |
| --- | --- | --- |
| `home_proxmox` | `argocd/**/*.yaml` | Three regex patterns in `customManagers` that extract `chart` / `repoURL` / `targetRevision` from ApplicationSet list entries and standalone Applications (details in Helm Chart Pinning below). Native `argocd` manager does not cover list-generator entries, so the regex is load-bearing. |
| `home_proxmox` | `.github/workflows/**` | Preset `helpers:pinGitHubActionDigests` — pins every `uses: owner/action@vX` to an exact SHA and keeps it updated |
| `home-proxmox-values` | `values/**/*.yaml`, `manifests/**/*.yaml` | Regex manager picks up `# renovate: image=<image>` or `# renovate: datasource=<ds> depName=<name>` comments above an `image:` / version field. Use this to pin custom images/binaries that aren't in a Dockerfile or Helm chart |

**Adding a new custom-managed image in private-repo values:**

```yaml
# renovate: image=ghcr.io/owner/app
image: ghcr.io/owner/app:1.2.3
```

### Security fast-path

`vulnerabilityAlerts` + `osvVulnerabilityAlerts: true` pull CVE data from the GitHub Advisory DB and OSV.dev. Whenever a dependency in either repo matches a known advisory, Renovate opens a PR immediately (ignoring `minimumReleaseAge`) with the `security` label and auto-merges it on pass. This is independent of the daily schedule.

### Config migration

`configMigration: true` — if upstream renames or deprecates any option in `renovate.json`, Renovate will open a PR migrating the config. No manual hunting through changelogs.

## Daily Telegram Digest

A second CronJob `renovate-notify` runs every day at **08:00 UTC** (after the 02:00 scan finishes) and posts a summary to the same Telegram channel as VictoriaMetrics alerts.

| Piece | Where |
| --- | --- |
| CronJob | `renovate-notify` in namespace `renovate` |
| Script | `ConfigMap/renovate-notify-script` (`digest.sh`), sourced from `manifests/infrastructure/renovate/notify-cronjob.yaml` |
| Image | `badouralix/curl-jq:latest@sha256:<digest>` — digest-pinned; Renovate's kubernetes manager proposes digest updates (this manager's `digest` update-type is disabled in `renovate.json`, so bumps are manual — edit the sha256 in the manifest when you want a refresh) |
| Resource footprint | requests `20m` / `32Mi`, limits `200m` / `128Mi` — no tuning needed |
| GitHub auth | reuses `Secret/renovate-github-token` |
| Telegram bot | shared with alerts — Vault KV at `homelab/k8s/telegram/victoria-metrics-bot` (`token`, `chat_id`) → `Secret/renovate-notify-telegram` |

Digest content per repo:

- ✅ merged PRs in last 24h (successes — shows Renovate is working)
- ❌ closed-without-merge PRs in last 24h
- 📥 open dependency PRs with full list (links to each)
- ⚠️ PRs labelled `manual-review` (actionable — critical-infra minor that needs your eyes)
- 🔘 Dependency Dashboard counters: pending approval (major — tick a checkbox to greenlight) + awaiting schedule

## Alerting

VMRule `renovate` in `victoria-metrics` namespace (`manifests/infrastructure/renovate/vmrule.yaml`) fires on:

| Alert | Condition |
| --- | --- |
| `RenovateCronJobFailing` | `kube_job_failed{namespace="renovate"} > 0` for 15m — any Job in the namespace failed |
| `RenovateScanMissing` | No successful Renovate scan completion in the last 48h — PAT expired, ESO sync broken, or CronJob stuck |

Both fire through the same Alertmanager → Telegram chain as other warnings.

## Helm Chart Pinning (ArgoCD)

All ArgoCD Helm sources are pinned to explicit versions — no `targetRevision: "*"` on Helm charts (Git-source `HEAD` is still used where appropriate). Renovate detects updates via three regex matchers in `renovate.json` (`customManagers`), scoped to `argocd/**/*.yaml`.

| # | Matches | Example file / structure |
|---|---|---|
| 1 | ApplicationSet list entry **with** `chart:` field (chart name differs from entry name) | `infra-appset.yaml` → `cnpg-operator` (chart `cloudnative-pg`), `pve-exporter` (chart `prometheus-pve-exporter`) |
| 2 | ApplicationSet list entry **without** `chart:` (entry name == chart name) | `infra-appset.yaml` → `cert-manager`, `vault`, `cilium`, ... |
| 3 | Standalone Application `sources[].chart` block | `argocd-application.yaml`, inline cnpg-cluster 2nd source in `apps-appset.yaml` templatePatch |

Regex #2 does **not** match entries with `chart:` because `\s+...\s+repoURL:` requires pure whitespace between name and repoURL — a `chart:` line breaks the pattern. Re2 has no lookahead, so we cannot safely handle partial pinning: **every entry must carry an explicit `targetRevision:`**. A missing `targetRevision:` falls back to the `"*"` safety net in templatePatch — Renovate won't see those entries.

**Why not the native `argocd` manager?** It parses `kind: Application` resources and standalone `Application` YAML, but does not walk ApplicationSet `generators[].list.elements[]` entries where our homelab keeps most chart pins. The regex customManager remains load-bearing.

**Where to edit versions manually** — just change the `targetRevision:` string in the entry. Renovate will match the new value and propose upstream updates on the next cron run.

**Safety net:** `templatePatch` in both `infra-appset.yaml` and `apps-appset.yaml` keeps `{{ dig "targetRevision" "*" . }}` as the fallback for any new entry added without a pin. Prefer pinning from day one.

## Configuration Split

**Bot-level config** (in `values/infrastructure/renovate.yaml` under `renovate.config`): platform, token source, repository list, `autodiscover: false`, `onboarding: false`, `requireConfig: required`, bot git identity, persistent cache PVC.

**Per-repo config** (`renovate.json` at repo root): presets, timezone, `packageRules`, `customManagers`, `commitMessagePrefix`, label strategy, `minimumReleaseAge`, `vulnerabilityAlerts`, `configMigration`. Each repo owns its own tuning — `home_proxmox` (public; infra + Terraform + Actions digest pinning) and `home-proxmox-values` (private; Helm values + image-comment regex) use the same defaults but differ in which managers are active.

## Operations

### Manual runs (do not wait for cron)

Main scan:

```bash
kubectl -n renovate create job --from=cronjob/renovate manual-$(date +%s)
kubectl -n renovate logs -f -l job-name=<job-name>
```

Digest:

```bash
kubectl -n renovate create job --from=cronjob/renovate-notify notify-$(date +%s)
kubectl -n renovate logs -l job-name=notify-* --tail=20
```

### Check status

```bash
kubectl -n renovate get cronjob,job,externalsecret,secret,pvc
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

### Rotate Telegram credentials

The digest CronJob shares its Telegram bot with VictoriaMetrics Alertmanager — rotating the token here affects both systems. Force-sync both ExternalSecrets:

```bash
vault kv put home/homelab/k8s/telegram/victoria-metrics-bot token=<new-token> chat_id=<same-chat-id>
kubectl -n renovate annotate externalsecret renovate-notify-telegram force-sync=$(date +%s) --overwrite
kubectl -n victoria-metrics annotate externalsecret alertmanager-config force-sync=$(date +%s) --overwrite
```

### Change the schedule

Edit `cronjob.schedule` in `values/infrastructure/renovate.yaml` and push. ArgoCD reconciles the CronJob spec within minutes.

### Disable temporarily

Set `cronjob.suspend: true` in the values file, commit, push. ArgoCD reconciles, future runs skip. Revert to re-enable.

### Wipe the cache

If the persistent cache gets corrupted (rare — usually only after interrupted runs), delete the PVC contents. ArgoCD will keep the PVC itself; the next Renovate run repopulates it:

```bash
kubectl -n renovate delete pod -l job-name=<stuck-job>           # if stuck
kubectl -n renovate exec -it <tmp-pod-on-pvc> -- rm -rf /tmp/renovate/*
```

## Troubleshooting

- **Pod in `Error` with `RENOVATE_TOKEN` missing** → ExternalSecret hasn't synced. Check `kubectl -n renovate describe externalsecret renovate-github-token` and confirm the Vault path exists.
- **Auth error `401` in logs** → PAT expired or scope stripped. Rotate per steps above. `RenovateScanMissing` alert fires after 48h of failures.
- **No PRs appearing** → confirm `renovate.json` is present in the repo root and `requireConfig: required` can find it. Check logs for `WARN: Config does not exist`.
- **Regex managers not matching** → run `LOG_LEVEL=debug` via `cronjob.env.LOG_LEVEL=debug` and manual-run; search logs for `customManager` entries.
- **`FATAL ERROR: Ineffective mark-compacts near heap limit` / JavaScript heap OOM** → Extraction succeeded but `lookupUpdates` exhausted the V8 heap. Check `env.NODE_OPTIONS` is set to `--max-old-space-size=1536` and `resources.limits.memory` is at least `2Gi`. Bump both proportionally if the dep count grows.
- **Dependency Dashboard shows a `regex (N)` heading** → hardcoded Renovate label for all `customManagers` of type `regex` (covers both ArgoCD pinning in the public repo and `# renovate: image=` comments in the private one). Cannot currently be renamed — no `customManagerName` / `displayName` option exists. Under the heading, entries are grouped by file path, which is the actionable part:
  ```
  regex (3)
  ├── argocd/applications/apps-appset.yaml (10)
  ├── argocd/infrastructure/argocd-application.yaml (1)
  └── argocd/infrastructure/infra-appset.yaml (21)
  ```

## Rollback

```bash
# 1. Remove the renovate entry from infra-appset.yaml → commit → push
# 2. ArgoCD deletes the Application (finalizer cleans namespace)
kubectl delete namespace renovate
```

Vault secrets at `homelab/k8s/renovate/github-token` and `homelab/k8s/telegram/victoria-metrics-bot` persist for re-deploy without rotation.
