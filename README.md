<div align="center">

# Homelab: Talos + ArgoCD

A single-tenant home cluster: four bare-metal Talos nodes managed by ArgoCD, with OpenBao as the only source of truth for secrets. Terraform provisions it, VictoriaMetrics monitors it, and VolSync backs it up to Garage S3 on a Synology NAS and to OVH.

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/VizzleTF/homelab)

</div>

> This GitHub copy is a sanitized read-only mirror. Origin lives on a private Forgejo instance. After every merge to `main`, a Forgejo Actions workflow rewrites history with `git filter-repo --replace-text`, scans the result with `gitleaks` and force-pushes it to GitHub. SHAs do not match upstream, and some literals (domains, IPs, emails) are replaced.

![Repobeats](https://repobeats.axiom.co/api/embed/f8bae5bb43169239582bac61ee8996a95f0d64f3.svg "Repobeats analytics image")

---

## Design choices

- Single operator. No human PR reviewer and no second admin account; CI checks gate every merge, and the root Application and ApplicationSets are guarded against cascade deletion.
- Four small boxes running Talos directly, not a rack. RAM is the binding constraint, not CPU.
- Origin git is off-cluster. Forgejo runs on a fifth box (`ops`, NixOS, declarative), so a dead cluster cannot take the GitOps source of truth with it.
- The Synology NAS is independent of the cluster: its own TLS (`acme.sh`), its own DNS (OpenWrt), its own reverse proxy (DSM nginx). Cluster failure does not affect stored data.

---

## Stack

| Layer                 | Choice                                  | Notes                                                                |
|-----------------------|-----------------------------------------|----------------------------------------------------------------------|
| Cluster OS            | Talos Linux (bare-metal)                | Immutable, no SSH, API-only via `talosctl`                           |
| Provisioning          | Terraform + `siderolabs/talos`          | Per-node entries in `terraform_talos/configs/nodes.yaml`             |
| CNI                   | Cilium                                  | eBPF, kube-proxy replacement, WireGuard pod-to-pod, BGP to OpenWrt   |
| Ingress               | Cilium Gateway API                      | Three Gateways: public, internal, TLS passthrough; experimental-channel CRDs |
| External access       | Cloudflared tunnel                      | Catch-all into the public Gateway; external-dns writes CNAMEs        |
| TLS                   | cert-manager + Cloudflare DNS-01        | One wildcard secret in `kube-system`, every Gateway references it    |
| Storage               | Longhorn + local-path                   | Longhorn is the default class (2 replicas, `Retain`); self-replicating or disposable stores (the shared CNPG cluster, OpenBao Raft, vmsingle) use local-path |
| Secrets               | OpenBao HA + External Secrets Operator  | MPL 2.0 fork of Vault 1.14.x, API-compatible; KV v2 mount `home`     |
| Databases             | CloudNativePG                           | Shared PG18 cluster, plus a dedicated Immich cluster for VectorChord |
| GitOps                | ArgoCD                                  | App-of-Apps + two ApplicationSets (infra + apps)                     |
| Observability         | VictoriaMetrics + VictoriaLogs + Vector | Grafana, Alertmanager into Robusta, Robusta into Telegram            |
| Policy and security   | Kyverno + Wazuh                         | Admission policies; Wazuh manager, indexer and dashboard in-cluster  |
| Dependency updates    | Renovate                                | In-cluster CronJob, opens PRs against Forgejo                        |
| Backups               | VolSync + Barman                        | Two independent restic chains (Garage on the NAS, OVH Frankfurt), each with its own key; Barman for Postgres WAL and PITR |

---

## CNCF maturity

Where the stack sits on the [CNCF Landscape](https://landscape.cncf.io/), and who owns the parts that are not on it:

| Layer             | Project                | Governance                          |
|-------------------|------------------------|-------------------------------------|
| Cluster OS        | Talos Linux            | Sidero Labs (not CNCF)               |
| CNI               | Cilium                 | Graduated                            |
| Container runtime | containerd (via Talos) | Graduated                            |
| Ingress           | Gateway API            | Kubernetes SIG (under K8s Graduated) |
| GitOps            | Argo CD                | Graduated                            |
| TLS               | cert-manager           | Graduated                            |
| Autoscaling       | KEDA                   | Graduated                            |
| Storage           | Longhorn               | Incubating                           |
| Secrets sync      | External Secrets       | Sandbox                              |
| Database operator | CloudNativePG          | Sandbox                              |
| DNS sync          | ExternalDNS            | Kubernetes SIG (under K8s Graduated) |
| Secrets backend   | OpenBao                | OpenSSF sandbox (MPL 2.0, fork of Vault 1.14.x) |
| Backup            | VolSync                | Red Hat / backube (not CNCF)         |
| CSI snapshotter   | kubernetes-csi/external-snapshotter | Kubernetes SIG (under K8s Graduated) |
| Metrics API       | Metrics Server         | Kubernetes SIG (under K8s Graduated) |
| Observability     | VictoriaMetrics / Logs | Not CNCF                             |
| Log shipper       | Vector                 | Datadog (not CNCF)                   |

---

## Architecture

![Architecture: Forgejo on the ops node, ArgoCD App-of-Apps, two independent backup chains](assets/architecture.svg)

Origin git lives on a separate NixOS box (`ops`) outside the cluster, so ArgoCD never depends on a service it deploys itself. Everything else (the App-of-Apps root, both ApplicationSets, OpenBao) runs on Talos. The SVG is generated from [`assets/architecture.archify.json`](assets/architecture.archify.json) and follows the reader's color scheme.

---

## Repository layout

```
argocd/
├── root-application.yaml             # App-of-Apps root (projects/, appsets/, standalone/)
├── projects/                         # AppProjects
├── appsets/
│   ├── infra-appset.yaml             # git.files generator over argocd/infra/*/config.yaml
│   └── apps-appset.yaml              # git.files generator over argocd/apps/*/config.yaml
├── standalone/                       # the only 2 non-AppSet Applications
│   ├── argocd-application.yaml       # ArgoCD self-management
│   └── gateway-api.yaml              # Gateway API CRDs (experimental channel)
├── apps/                             # Per-app self-contained folder (auto-discovered)
│   └── <app>/
│       ├── config.yaml               # chart, repoURL, targetRevision, namespace, wave, flags
│       ├── values.yaml               # chart values + homelab-common: section
│       ├── homelab-values.yaml       # optional split (when chart schema is strict)
│       ├── cnpg-values.yaml          # optional dedicated CNPG cluster (only immich today)
│       └── manifests/                # optional raw K8s yamls (extraManifests: true)
├── infra/                            # Same shape as apps/, per-component
└── values/
    ├── argocd.yaml                   # values for the standalone argocd Application
    └── global.yaml                   # $values target for homelab-common globals

charts/homelab-common/                # In-house Helm chart: HTTPRoute, ExternalSecret + SecretStore,
                                      # VolSync backups, RBAC, LimitRange, CNPG Database,
                                      # NetworkPolicy, simple workloads. Published to the Forgejo
                                      # Helm repository; ArgoCD pulls from there, not from this path.

terraform_talos/                      # Bare-metal Talos cluster provisioning
nodes/ops/                            # NixOS config of the ops node (Forgejo, etcd snapshots, runner)
scripts/                              # forgejo-pr.sh, talos-upgrade.sh, vm.sh, dr/, dr-pack/, …
.forgejo/workflows/ci.yaml            # yamllint, helm-lint, kubeconform, gitleaks, argocd-diff,
                                      # mirror-to-github
```

To add a new app, create `argocd/apps/<name>/` with `config.yaml` and `values.yaml`. The ApplicationSet discovers it on the next reconcile; the appset YAML stays untouched. Infra components under `argocd/infra/` follow the same flow. Chart versions are pinned in each `config.yaml` (`targetRevision:`); Renovate opens the bump PRs.

---

## Sync waves

Each component declares a `wave:` in `argocd/{infra,apps}/*/config.yaml`; the two standalone Applications under `argocd/standalone/` carry their own annotation. The waves record dependency order. ArgoCD enforces them only among resources of one sync: the root app orders the standalone Applications and the ApplicationSets, but ApplicationSet-generated Applications sync on their own (no progressive sync), and the per-app `retry` absorbs the rest.

| Wave    | Components |
|---------|------------|
| **-10** | argocd (self-management), gateway-api (CRDs) |
| **-5**  | cilium, cert-manager |
| **-4**  | longhorn, openbao, csi-snapshotter |
| **-3**  | kubelet-csr-approver, metrics-server, spegel, volsync |
| **-2**  | external-secrets, cnpg-operator, keda, external-dns, external-dns-openwrt, victoria-metrics-k8s-stack |
| **-1**  | cnpg-barman-plugin, intel-device-plugins-operator, keda-add-ons-http, node-feature-discovery, tuppr, victoria-logs, wazuh-operator |
| **0**   | cloudflared, intel-device-plugins-gpu, kyverno, local-path-provisioner, reloader, smartctl-exporter, tfstate-mirror |
| **1**   | cnpg (shared cluster), valkey, openbao-autounseal, robusta, kyverno-policies, backup-drill |
| **2**   | renovate; apps: atuin, authentik, cleanbot, forgejo, immich, lampac, may, obsidian-livesync, opencloud, rss-to-telegram-bot, spotify-backup, trek, vaultwarden, wazuh |
| **3**   | forgejo-runner, netbird, crowdsec-scraper, openwrt-backup |

---

## Hardware

Bare-metal hosts run Talos directly (no hypervisor underneath), plus one NixOS box that is deliberately not a cluster member:

| Role          | Count | Notes                                                  |
|---------------|-------|--------------------------------------------------------|
| control-plane | 3     | talos-cp-{01,02,03} on 10.11.11.{101,102,103}; 4 cores, 16 GiB each; the control-plane taint is removed, so they run workloads |
| worker        | 1     | talos-worker-01 on 10.11.11.111; 16 threads, 32 GiB, Intel iGPU for Immich ML |
| ops node      | 1     | NixOS, outside the cluster: Forgejo, backup timers, watchdog, a second Actions runner (`nodes/ops/`) |

Cold storage and backups live off-cluster on a Synology NAS, exposed as Garage S3 on a dedicated DSM volume with a local certificate.

---

## Networking

```
Internet  →  Cloudflare tunnel (cloudflared deployment in-cluster)
                ↓ catch-all
            cilium-gateway              public hosts        (10.11.10.137)

LAN       →  cilium-gateway-internal    LAN-only            (10.11.10.138)
LAN + TLS →  cilium-gateway-tls         TLSRoute passthrough (10.11.10.139)
```

Three L3 subnets, no L2 announcements:

| Subnet | Role |
|---|---|
| `10.11.10.0/24` | LB IP pool: Service `LoadBalancer` IPs, **L3-only** (no L2 segment), announced via BGP |
| `10.11.11.0/24` | Servers VLAN: k8s nodes, Talos VIP, ops node |
| `10.11.12.0/24` | LAN: Wi-Fi/DHCP clients, Synology NAS, router management |

Cilium peers eBGP with OpenWrt (BIRD2) from every node (ASN `65010` ↔ `65000`). Each LB IP is advertised as a `/32` with ECMP across all cluster nodes. An `externalTrafficPolicy: Local` service is advertised only from the node hosting its pod, so single-replica workloads keep the source IP. `scripts/openwrt-bgp-setup.sh` generates the BIRD config.

One wildcard cert lives in `kube-system/wildcard-tls`; every Gateway references it. cert-manager renews it via Cloudflare DNS-01.

external-dns writes records both ways: Cloudflare for public hosts, OpenWrt for the LAN. dnsmasq cannot store TXT records, so the OpenWrt instance (a forked webhook provider) runs with `registry: noop`. The provider marks the uci records it owns, and that marker makes `policy: sync` safe.

To expose a new public service, add `httpRoutes:` to the app's `values.yaml`. `homelab-common` renders the HTTPRoute, external-dns picks up the host, and the tunnel routes it.

Every namespace except `kube-system` and `netbird` has a default-deny ingress `CiliumNetworkPolicy`; a new cross-namespace client needs an `allow` entry in the target namespace.

---

## Secrets

OpenBao is the single source of truth for secrets. It runs in HA mode (3-member Raft). A separate `openbao-autounseal` Deployment (a fork of `pyToshka/vault-autounseal`) unseals the pods with Shamir keys kept in a cluster Secret; the unseal material also has an off-cluster copy in Vaultwarden.

External Secrets Operator renders Kubernetes `Secret` objects from OpenBao paths shaped like `home/homelab/k8s/<ns>/<app>`. There is no ClusterSecretStore: `homelab-common` renders one ServiceAccount and one `SecretStore` (`openbao-<release>`) per release, and each OpenBao role can read only its own namespace's path plus explicit grants.

Garage requires `AWS_DEFAULT_REGION=garage` in the env; without it, `HeadBucket` returns 400. This catches every S3 client (Barman, restic movers, Terraform S3 backend, rclone CronJobs).

---

## Backups

Two targets, and neither is a copy of the other: **Garage** on the Synology (`s3.example.com`) and **OVH Frankfurt** are both written to directly, each with its own restic repository and its own encryption password. Losing one target, or the key to it, leaves the other intact and readable.

| Layer | What | Where | Schedule | Retention |
|---|---|---|---|---|
| PVC data | 14 volumes across 11 apps, one `ReplicationSource` per target | `restic-apps/<name>` on both | Garage nightly 00:10–03:30 UTC; OVH mostly Sundays 01:40–08:00 UTC | Garage 7 daily + 4 weekly; OVH 12 weekly + 6 monthly |
| Forgejo (ops node) | `forgejo dump` via restic | `restic-apps/forgejo-ops` on both | daily 02:15 node-local time | 7 daily + 4 weekly + 6 monthly |
| Postgres | cnpg-cluster + immich-cluster, Barman WAL + base backups | `cnpg-backups/` on Garage | continuous WAL, base backup daily | 7d, PITR |
| Postgres, off-site | `pg_dump -Fc` per database, independent of Barman | `pg-logical/` on OVH | 03:50 UTC | 90d |
| etcd | `talosctl etcd snapshot` from the ops node | `snapshots/etcd/` on both | daily 04:15 node-local time | 30d |
| OpenBao | Raft snapshot over the HTTP API | `snapshots/openbao/` on both | 02:05 UTC | 90d |
| DR pack | Shamir keys, root token, Raft snapshot, bootstrap creds in one GPG file | `snapshots/dr-pack/` on both | Sundays 02:40 UTC | last 8 |
| Terraform state | Garage → OVH mirror | `terraform-state/` | 08:00 UTC | — |

### How the PVC layer works

Each volume declares a `volsync:` block in its app values; the `homelab-common` chart renders one `ReplicationSource` per target plus the `ExternalSecret` holding that repository's credentials.

- **`copyMethod: Snapshot`** for everything except immich: VolSync takes a Longhorn CSI snapshot, clones it, and the restic mover reads the clone, so the application never pauses. Clones live in `longhorn-volsync-clone` (one replica, `reclaimPolicy: Delete`): the default class retains, and a retained clone per volume per night leaves an orphaned PV behind each time.
- **`copyMethod: Direct`** for the immich library: a full-size clone would not fit the disks. The mover reads the live RWX volume in place, so files written mid-run land in the next snapshot instead.
- Longhorn freezes the filesystem for the snapshot, so a restored SQLite database opens cleanly instead of replaying a WAL as if the power had been cut.
- Repository names are cluster-unique: the name *is* the path under `restic-apps/`, and two volumes sharing one would interleave their snapshots and prune each other's history.

### Verifying backups

A weekly drill (`backup-drill`, Sundays 09:00 UTC) restores one repository into a throwaway namespace, rotating through eight repositories, including the ops node's Forgejo. The target switches between Garage and OVH after each full round, so every repository is checked on each target once in 16 weeks. It checks the restored data (non-empty, `PRAGMA integrity_check` for SQLite), pushes `homelab_restore_drill_*` to VictoriaMetrics and fires an alert on failure. Two more rules watch the drill itself: stale for over 16 days, or never seen at all.

### Restore

```bash
# One app, into its own namespace, from either target:
DR_RESTIC_TARGET=garage scripts/dr/restore-app.sh vaultwarden

# Whole cluster, once fresh Talos is up (terraform_talos apply):
scripts/dr/restore.sh all
```

`restore-app.sh` creates the repository Secret, the PVC and a `ReplicationDestination`, then waits for the mover. The full playbook runs eleven phases: preflight → network → storage → TLS → DNS → snapshot fetch → OpenBao (Shamir + Raft) → ESO → CNPG → ArgoCD adoption → per-app restore. Forgejo is not part of it: the ops node must already answer.

The circular dependency to know about: restic passwords live in OpenBao, and OpenBao itself is restored from a backup encrypted with them. The DR pack breaks the circle: it carries both, encrypted with a passphrase that lives in Vaultwarden and in OpenBao, never in the pack itself. See [`scripts/dr/README.md`](scripts/dr/README.md).

---

## Forgejo-first workflow

Origin is a self-hosted Forgejo instance on the `ops` node, outside the cluster. The in-cluster Forgejo is a read-only mirror, and so is GitHub.

```
local branch
   │ push
   ▼
Forgejo
   │ PR: gitleaks, yamllint, helm-lint, kubeconform, argocd-diff
   ▼
squash-merge to main
   │
   ▼
filter-repo sanitize + gitleaks on the rewritten history
   │ push
   ▼
GitHub mirror
```

Direct push to `main` is blocked by branch protection; changes go through a PR. Pre-commit runs gitleaks v8.30.1 plus a filename blocklist. Five Forgejo Actions checks must be green to merge: `gitleaks`, `yamllint`, `helm-lint`, `kubeconform` and `argocd-diff`. `argocd-diff` renders every touched Application with a throwaway ArgoCD and posts the manifest diff as a PR comment; a PR that prunes a resource or changes a CRD also needs the `diff-reviewed` label.

After merge, `mirror-to-github` strips `CLAUDE.md` and `.claude/`, applies `MIRROR_SANITIZE_RULES` (a multiline `<old>==><new>` Forgejo Actions secret), runs gitleaks over the rewritten history and force-pushes to GitHub.

`scripts/forgejo-pr.sh open|merge` wraps the API calls with a per-user token, so squash merges are attributed to the user, not to an admin account.

---

## Provisioning a node

Bare-metal Talos install:

1. Boot the host from a Talos factory ISO (image schematic from `terraform_talos/modules/talos/schematic.yaml`).
2. Add an entry to `terraform_talos/configs/nodes.yaml` (address, role, install disk, optional NIC MAC).
3. `terraform -chdir=terraform_talos apply` applies the machine config, joins the cluster, and waits for `talos_cluster_health`.
4. `kubectl get nodes` to verify. Cilium, Longhorn and NFD onboard the new node automatically.

Full procedure (including the Talos secrets cascade: any `talos_machine_secrets` mutation invalidates pod SA tokens cluster-wide, and the cilium / CSI / controller rollouts that follow take roughly fifteen minutes) is in the `managing-talos-node` Claude Code skill (private Forgejo origin only, see below).

---

## Gotchas

- Cilium checks the Gateway API GVKs it needs at startup. Cilium 1.20 requires the v1 `ReferenceGrant`, `TLSRoute` and `BackendTLSPolicy`, which means Gateway API v1.6.1 or newer from the experimental channel. Downgrading the CRDs deletes the objects stored in them.
- `ghcr.io/siderolabs/kubelet:<k8s-ver>` lags upstream Kubernetes releases. Do not bump the K8s version on the Talos side until the image is published; `scripts/talos-upgrade.sh check` HEADs the manifest first.
- Mutating Talos secrets triggers a cluster-wide auth cascade. Cilium agents lose the apiserver, and everything serial-fails `Unauthorized`. Expect roughly fifteen minutes of rollout afterwards.
- OpenWrt mt76 hardware flow offload breaks Wi-Fi roaming. FT/BTM transitions hang for ~60s under the conntrack timeout. Disable HW offload, keep SW offload.
- `vmagent`'s default 16 MiB scrape-size limit is too small for kube-apiserver `/metrics`. Raise `maxScrapeSize` to 64 MB; otherwise the target goes down and its series stop arriving.
- Forgejo Actions runner only emulates the GHES artifact protocol up to v3. Pin `actions/upload-artifact` v3.1.3 and `download-artifact` v3.1.0. v3.2.0 and later use the v4 protocol and fail with `GHESNotSupportedError`.
- kswapd starves the Wi-Fi driver before it pages. Keep ≥3 GiB of headroom per host.
- `homelab-common` publishes on git tag `homelab-common-v<version>`. Bump `Chart.yaml`, merge to main, push the tag: `.forgejo/workflows/publish-helm.yml` packages the chart and POSTs it to the Forgejo Helm chart museum (`/api/packages/vizzle/helm/api/charts`). Without the tag the new version never lands in the registry. Then bump the pin in both appsets and `argocd/standalone/argocd-application.yaml` in a separate PR.

---

## Claude Code skills

Routine operations are wrapped as [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) skills under `.claude/skills/`. Each skill is a Markdown runbook the agent loads on demand.

| Skill                       | What it does                                                                            |
|-----------------------------|------------------------------------------------------------------------------------------|
| `managing-talos-node`       | Add, replace or remove a node: PXE, terraform, rescue, BGP peer, Longhorn cleanup        |
| `upgrading-talos`           | Talos / Kubernetes upgrades through tuppr; `talosctl` script as break-glass             |
| `creating-garage-bucket`    | Provisions a Garage S3 bucket + key on the Synology, stores credentials in OpenBao       |
| `renewing-synology-cert`    | `acme.sh` + Cloudflare DNS-01, then reloads DSM nginx via `synow3tool`                   |
| `scaffolding-app`           | Boilerplate for a new app: values, HTTPRoute, ExternalSecret, ArgoCD wiring              |
| `scaffolding-authentik-oidc`| New OIDC client: secret, dual OpenBao paths, blueprint files, ESO wiring                 |
| `verifying-backups`         | Audits VolSync, CNPG, etcd and OpenBao backups and off-site freshness                    |
| `managing-monitoring`       | Triages firing alerts, queries metrics, silences, scrape targets                         |
| `checking-cluster-health`   | One-shot overview: nodes, pods, PVCs, certs, ArgoCD sync                                 |
| `restoring-app-volume`      | Restores one app volume: old PV rebind or VolSync restic, trial restore first            |
| `triaging-renovate-prs`     | Reviews open Renovate PRs against the argocd-diff comment and release notes              |
| `deploying-ops-node`        | Rolls a merged `nodes/ops` change onto the NixOS ops node, with rollback                 |

`.claude/` and `CLAUDE.md` live in the private Forgejo origin only; the public GitHub mirror strips them.

---

## Work in progress

- [ ] Local LLM behind KEDA scale-to-zero
- [ ] Disaster-recovery drill: drain a worker mid-day, observe recovery

---

## License

The repository ships as-is for reference. No formal LICENSE file: treat it as "all rights reserved" until one is added.
