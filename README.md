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
| Ingress               | Cilium Gateway API                      | Two Gateways: internal, TLS passthrough; experimental-channel CRDs |
| External access       | NetBird mesh + Reverse Proxy on a VPS   | Apps are LAN + mesh only; the proxy publishes single services (cleanbot webhook) |
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
│       └── manifests/                # optional raw K8s yamls (extraManifests: true)
├── infra/                            # Same shape as apps/, per-component
└── values/
    ├── apps.yaml / infra.yaml        # homelab-common values per AppSet (lanEgressDeny)
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

Each component declares a `wave:` in `argocd/{infra,apps}/*/config.yaml`: the dependency layer it belongs to. It is documentation, not an ordering mechanism. ApplicationSet-generated Applications sync independently (progressive syncs are off because RollingSync disables autosync), so the template does not stamp a sync-wave on them; the per-app `retry` plus `SkipDryRunOnMissingResource` absorb CRDs that arrive with another app. The two standalone Applications under `argocd/standalone/` carry a real annotation, ordered by the root app. Cold-start order lives in `scripts/dr/phases/`.

| Wave    | Components |
|---------|------------|
| **-10** | argocd (self-management), gateway-api (CRDs) |
| **-5**  | cilium, cert-manager |
| **-4**  | longhorn, openbao, snapshot-controller, local-path-provisioner |
| **-3**  | kubelet-csr-approver, metrics-server, spegel, volsync |
| **-2**  | external-secrets, cnpg-operator, keda, external-dns, external-dns-openwrt, victoria-metrics-k8s-stack |
| **-1**  | cnpg-barman-plugin, intel-device-plugins-operator, keda-add-ons-http, tuppr, victoria-logs, wazuh-operator |
| **0**   | intel-device-plugins-gpu, kyverno, reloader, smartctl-exporter, snmp-exporter, tfstate-mirror |
| **1**   | cnpg (shared cluster), valkey, openbao-autounseal, robusta, kyverno-policies, backup-drill |
| **2**   | renovate; apps: atuin, authentik, cleanbot, immich, lampac, may, obsidian-livesync, opencloud, rss-to-telegram-bot, spotify-backup, trek, vaultwarden, wazuh |
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
Internet  →  NetBird Reverse Proxy (VPS vps-fi) → mesh ↓   published services only
LAN, mesh →  cilium-gateway-internal    every HTTPRoute     (10.11.10.138)
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

external-dns writes the LAN records to OpenWrt; mesh clients use the router as their nameserver. Public records (NetBird, its proxy) are manual in Cloudflare. dnsmasq cannot store TXT records, so the OpenWrt instance (a forked webhook provider) runs with `registry: noop`. The provider marks the uci records it owns, and that marker makes `policy: sync` safe.

To serve a new app, add `httpRoutes:` to the app's `values.yaml`: `homelab-common` renders the HTTPRoute on the internal gateway and external-dns adds the LAN record. To publish one to the internet, add a service on the NetBird Reverse Proxy (`docs/netbird-reverse-proxy.md`).

Every namespace except `kube-system`, `netbird` and `longhorn-system` has a default-deny ingress `CiliumNetworkPolicy` (`longhorn-system` relies on the chart's per-component `NetworkPolicy` objects plus `longhorn-ui-gateway-only`); a new cross-namespace client needs an `allow` entry in the target namespace. The same namespaces get `lan-egress-deny`: no egress to private ranges except pods, Services and the release's `networkPolicy.lanEgress` (NAS, router, ops node), so a compromised image cannot reach the LAN.

---

## Secrets

OpenBao is the single source of truth for secrets. It runs in HA mode (3-member Raft). A separate `openbao-autounseal` Deployment (a fork of `pyToshka/vault-autounseal`) unseals the pods with Shamir keys kept in a cluster Secret; the unseal material also has an off-cluster copy in Vaultwarden.

External Secrets Operator renders Kubernetes `Secret` objects from OpenBao paths shaped like `home/homelab/k8s/<ns>/<purpose>`. There is no ClusterSecretStore: `homelab-common` renders one ServiceAccount and one `SecretStore` (`openbao-<release>`) per release, and each OpenBao role can read only its own namespace's path plus explicit grants.

Garage requires `AWS_DEFAULT_REGION=garage` in the env; without it, `HeadBucket` returns 400. This catches every S3 client (Barman, restic movers, Terraform S3 backend, rclone CronJobs).

---

## Backups

Two targets, and neither is a copy of the other: **Garage** on the Synology (`s3.example.com`) and **OVH Frankfurt** are both written to directly, each with its own restic repository and its own encryption password. Losing one target, or the key to it, leaves the other intact and readable.

| Layer | What | Where | Schedule | Retention |
|---|---|---|---|---|
| PVC data | 14 volumes across 11 apps, one `ReplicationSource` per target | `restic-apps/<name>` on both | Garage nightly 00:10–03:30 UTC; OVH mostly Sundays 01:40–08:00 UTC | Garage 7 daily + 4 weekly; OVH 12 weekly + 6 monthly |
| Forgejo (ops node) | `forgejo dump` via restic | `restic-apps/forgejo-ops` on both | daily 02:15 node-local time | 7 daily + 4 weekly + 6 monthly |
| Postgres | cnpg-cluster + immich-cluster, Barman WAL + base backups | `cnpg-backups/` on Garage | continuous WAL, base backup daily | 7d, PITR |
| Postgres, off-site | `pg_dump -Fc` per database, independent of Barman | `crypt/pg-logical/` (rclone crypt) on OVH | 03:50 UTC | 90d |
| etcd | `talosctl etcd snapshot` from the ops node | `snapshots/etcd/` on Garage, `crypt/snapshots/etcd/` (rclone crypt) on OVH | daily 04:15 node-local time | 30d |
| OpenBao | Raft snapshot over the HTTP API | `snapshots/openbao/` on Garage, `crypt/snapshots/openbao/` (rclone crypt) on OVH | 02:05 UTC | 90d |
| DR pack | Shamir keys, root token, Raft snapshot, bootstrap creds in one GPG file | `snapshots/dr-pack/` on both | Sundays 02:40 UTC | last 8 |
| Terraform state | Garage → OVH mirror | `crypt/terraform-state/` (rclone crypt) on OVH | 08:00 UTC | — |

Each volume declares `volsync:` in its values; `homelab-common` renders one `ReplicationSource` per target. Restic repository names are cluster-unique (the name is the path under `restic-apps/`). Everything except the immich library uses `copyMethod: Snapshot` (frozen Longhorn snapshot → clone in `longhorn-volsync-clone`); immich uses `Direct`, a full clone does not fit the disks. A weekly `backup-drill` restores one repository into a throwaway namespace, alternating targets, and alerts on failure.

### Restore

```bash
# One app, into its own namespace, from either target:
DR_RESTIC_TARGET=garage scripts/dr/restore-app.sh vaultwarden

# Whole cluster, once fresh Talos is up (terraform_talos apply):
scripts/dr/restore.sh all
```

`restore-app.sh` creates the repository Secret, the PVC and a `ReplicationDestination`, then waits for the mover. The full playbook runs eleven phases: preflight → network → storage → TLS → DNS → snapshot fetch → OpenBao (Shamir + Raft) → ESO → CNPG → per-app restore → ArgoCD adoption. Forgejo is not part of it: the ops node must already answer.

The circular dependency to know about: restic passwords live in OpenBao, and OpenBao itself is restored from a backup encrypted with them. The DR pack breaks the circle: it carries both, encrypted with a passphrase that lives in Vaultwarden and in OpenBao, never in the pack itself. See [`scripts/dr/README.md`](scripts/dr/README.md).

---

## Forgejo-first workflow

Origin is Forgejo on the `ops` node; GitHub is a read-only mirror. `main` is protected: every change is a PR that must pass `gitleaks`, `yamllint`, `helm-lint`, `kubeconform` and `argocd-diff` (renders every touched Application and posts the manifest diff; pruning a resource or changing a CRD also needs the `diff-reviewed` label). After the squash-merge, `mirror-to-github` strips `CLAUDE.md` and `.claude/`, rewrites history with `MIRROR_SANITIZE_RULES`, re-runs gitleaks and force-pushes. `scripts/forgejo-pr.sh` drives the PR with a per-user token, so merges are not attributed to an admin.

---

## Provisioning a node

Boot the Talos factory ISO (`terraform_talos/modules/talos/schematic.yaml`), add the node to `terraform_talos/configs/nodes.yaml`, run `terraform -chdir=terraform_talos apply`. Any `talos_machine_secrets` change invalidates pod SA tokens cluster-wide: expect ~15 min of rollouts.

---

## Gotchas

- Cilium checks the Gateway API GVKs it needs at startup. Cilium 1.20 requires the v1 `ReferenceGrant`, `TLSRoute` and `BackendTLSPolicy`, which means Gateway API v1.6.1 or newer from the experimental channel. Downgrading the CRDs deletes the objects stored in them.
- `ghcr.io/siderolabs/kubelet:<k8s-ver>` lags upstream Kubernetes releases. Do not bump the K8s version on the Talos side until the image is published; `scripts/talos-upgrade.sh check` HEADs the manifest first.
- OpenWrt mt76 hardware flow offload breaks Wi-Fi roaming. FT/BTM transitions hang for ~60s under the conntrack timeout. Disable HW offload, keep SW offload.
- `vmagent`'s default 16 MiB scrape-size limit is too small for kube-apiserver `/metrics`. Raise `maxScrapeSize` to 64 MB; otherwise the target goes down and its series stop arriving.
- Forgejo Actions runner only emulates the GHES artifact protocol up to v3. Pin `actions/upload-artifact` v3.1.3 and `download-artifact` v3.1.0. v3.2.0 and later use the v4 protocol and fail with `GHESNotSupportedError`.
- kswapd starves the Wi-Fi driver before it pages. Keep ≥3 GiB of headroom per host.
- `homelab-common` publishes on git tag `homelab-common-v<version>`. Bump `Chart.yaml`, merge to main, push the tag: `.forgejo/workflows/publish-helm.yml` packages the chart and POSTs it to the Forgejo Helm chart museum (`/api/packages/vizzle/helm/api/charts`). Without the tag the new version never lands in the registry. Then bump the pin in both appsets and `argocd/standalone/argocd-application.yaml` in a separate PR.

---

## License

MIT, see [LICENSE](LICENSE).
