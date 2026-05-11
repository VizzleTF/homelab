# [Proxmox Home Lab — Talos + ArgoCD](https://github.com/VizzleTF/homelab)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/VizzleTF/homelab)

Single-user homelab managed as a monorepo: Proxmox VE hosts → Terraform-provisioned **Talos Linux** VMs → Kubernetes cluster reconciled by **ArgoCD** (GitOps, App-of-Apps + ApplicationSets).

> **Note**: This GitHub copy is a sanitized mirror of a private Forgejo repo. After every successful merge to `main`, a Forgejo Actions workflow runs `gitleaks` and pushes a sanitized snapshot here via `git filter-repo --replace-text`. SHAs and replaced literals (domains, IPs, emails) will not match upstream.

![Repobeats](https://repobeats.axiom.co/api/embed/f8bae5bb43169239582bac61ee8996a95f0d64f3.svg "Repobeats analytics image")

## Repository Layout

```
argocd/
├── root-application.yaml           # App-of-Apps root
├── infrastructure/                 # 1 ApplicationSet + 3 standalone apps
│   ├── infra-appset.yaml           # 21 infra components
│   ├── argocd-application.yaml
│   ├── gateway-api.yaml            # CRDs pinned to v1.4.1 (Cilium 1.19 compat)
│   └── talos-etcd-backup.yaml
├── applications/                   # 1 ApplicationSet (14 apps)
│   └── apps-appset.yaml
├── values/
│   ├── infrastructure/             # Helm values per infra component
│   ├── applications/               # Helm values per app
│   └── shared/global.yaml          # $values reference target (homelab-common globals)
└── manifests/
    ├── infrastructure/<name>/      # Raw K8s manifests (ClusterIssuers, Gateways, IPPools, …)
    └── applications/<name>/        # KEDA HTTPScaledObjects, etc.

charts/homelab-common/              # In-house chart (HTTPRoute, ExternalSecret, CronJob, RBAC,
                                    #   LimitRange, CNPG Database, simple workloads)
                                    # Published to Forgejo OCI registry; ArgoCD pulls from there.
ansible/                            # Inventory + playbooks (PVE host config)
terraform_proxmox/                  # Proxmox VM provisioning (Talos + cloud-init devboxes)
scripts/                            # forgejo-pr.sh, forgejo-branch-protection.sh, …
.forgejo/workflows/ci.yaml          # yamllint, helm-lint, gitleaks, mirror-to-github
```

## Cluster

Six Talos Linux VMs across six Proxmox hosts:

| Role          | Count | vCPU | RAM    | Disk    |
|---------------|-------|------|--------|---------|
| control-plane | 3     | 3    | 12 GiB | 125–300 GB |
| worker        | 3     | 3–4  | 6–10 GiB | 100 GB |

- **OS**: Talos Linux (immutable, API-driven; `talosctl` only)
- **CNI**: Cilium 1.19 with eBPF, kube-proxy replacement, WireGuard pod-to-pod encryption, Hubble
- **Service LB**: Cilium LB-IPAM + L2 announcements
- **Gateway API**: three Gateways — public (via Cloudflare tunnel), internal (LAN-only), TLS-passthrough — sharing a single `*.example.com` / `*.internal.example` wildcard certificate
- **Storage**: Longhorn (default class, 2 replicas, `Retain` reclaim policy), backups to Garage S3 on a Synology NAS
- **Secrets**: HashiCorp Vault HA (KV v2 mount `home`) + External Secrets Operator (`ClusterSecretStore: vault-backend-cluster`) — never inlined in values

## Deployed Components

### Infrastructure (`argocd/infrastructure/`)

ArgoCD · Cert-Manager · Cilium · Cloudflared · CNPG Operator · Descheduler · External DNS (Cloudflare + OpenWrt) · External Secrets Operator · Gateway API CRDs · Intel Device Plugins (operator + GPU) · KEDA + KEDA HTTP add-on · Kubelet CSR Approver · Longhorn · Metrics Server · Node Feature Discovery · PVE Exporter · Renovate · Robusta · Talos etcd backup CronJob · Vault · Vault Autounseal · Victoria Metrics k8s-stack · Victoria Logs (with Vector)

### Applications (`argocd/applications/`)

CNPG cluster (shared PG17 — Nextcloud, Authentik, Umami) · CNPG cluster (Immich, dedicated for pgvector) · Valkey · Authentik · Forgejo (server + Actions runner) · Immich · Lampac · Nextcloud · Vaultwarden · Netboot.xyz · Omniroute · RSS-to-Telegram bot · Spotify backup · `may` (internal)

### Pinning & updates

- Public Helm charts use exact versions per `apps-appset.yaml` / `infra-appset.yaml`.
- `homelab-common` is consumed via Forgejo OCI registry, not the local `charts/` path.
- Renovate runs in-cluster (CronJob) and opens PRs against `main` for chart bumps.

## Networking

- **External access**: a single Cloudflared tunnel forwards a catch-all ingress to the public Cilium Gateway. Adding a new public service = one HTTPRoute (rendered by `homelab-common`); external-dns writes the CNAME automatically.
- **TLS**: Cert-Manager + Cloudflare DNS-01, single wildcard secret `wildcard-tls` in `kube-system` referenced by all Gateways.
- **Internal-only services** use the internal Gateway with LAN IP, served by external-dns to OpenWrt.

## Secrets & Backups

- **Vault** is the source of truth (auto-unsealed via Transit engine). External Secrets renders k8s `Secret`s on demand.
- **CNPG WAL/base backups** → Garage S3 (Synology) via Barman.
- **Application data** (Nextcloud, Vaultwarden, Immich, Vault) → in-cluster CronJobs to Garage S3.
- **etcd snapshots** → Talos `talos-etcd-backup` CronJob to Garage S3.
- **Off-site DR**: critical Vault unseal material kept in an off-cluster password manager (Vaultwarden secure note).

## Forgejo-First Workflow

Origin lives at `git.example.com/vizzle/homelab`; GitHub is read-only.

```
local branch ──push──▶ Forgejo  ──PR + gitleaks check──▶ squash-merge ──┐
                                                                        │
                                                  filter-repo sanitize  ▼
                                                            push ──▶ GitHub mirror
```

- Direct push to `main` is blocked by branch protection; use a PR.
- Pre-commit runs `gitleaks` + a filename blocklist; `--no-verify` is not used.
- The `mirror-to-github` job applies `MIRROR_SANITIZE_RULES` (Forgejo Actions secret) before force-pushing.

## Provisioning a Node

1. Add an entry to `terraform_proxmox/configs/vms.yaml`.
2. `terraform -chdir=terraform_proxmox apply` — provisions the VM, applies a Talos machine config, joins the cluster.
3. `kubectl get nodes` to verify; Cilium / Longhorn / NFD pick up the node automatically.

For a step-by-step runbook see the `provisioning-talos-node` Claude Code skill in this repo.

## Tooling

| Concern              | Tool                                        |
|----------------------|---------------------------------------------|
| VM provisioning      | Terraform + `bpg/proxmox`, `siderolabs/talos` |
| Host config          | Ansible (PVE hosts only)                    |
| Cluster bootstrap    | Talos machine configs (rendered by TF)      |
| App delivery         | ArgoCD (App-of-Apps + ApplicationSets)      |
| Renderable resources | `homelab-common` Helm chart                 |
| Dependency updates   | Renovate (in-cluster)                       |
| Observability        | Victoria Metrics + Victoria Logs + Robusta  |
| Secrets              | Vault + External Secrets Operator           |

## License

MIT.
