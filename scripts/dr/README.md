# DR restore

Brings a freshly bootstrapped Talos cluster back to Healthy: restores the OpenBao Raft snapshot, then ESO and ArgoCD replay everything else.

## Rules for the phases

- The DR pack holds only bootstrap-time secrets; everything else comes from the restored OpenBao. A secret that cannot be auto-included is a bug in `build.sh`.
- Phases are idempotent (`helm_apply` in `lib/common.sh` = `helm upgrade --install --wait`).
- A `wait_for` target must follow from objects this or an earlier phase applied. No Application syncs before phase 10 ends (7e6e6f5a).

## Quick start (after fresh Talos cluster is up + kubeconfig in place)

```bash
# Validate the DR pack; with rbw/bw unlocked it also checks the Vaultwarden entries
scripts/dr-pack/verify.sh

# List phases
scripts/dr/restore.sh list

# Run every phase end-to-end
scripts/dr/restore.sh all

# Or run individual phases
scripts/dr/restore.sh phase 01-network
scripts/dr/restore.sh phase 06-vault-restore
```

## DR pack layout (minimal v3)

```
~/dr-pack/
├── 00-shamir.json.gpg          # gpg -c; by convention the passphrase is the Vaultwarden master password
├── 01-bootstrap.env            # CF_API_TOKEN, GARAGE_RESTIC_*, GARAGE_SNAPSHOTS_*, OVH_S3_*, RESTIC_PASSWORD_GARAGE/_OVH, optional OPENWRT_*
├── 02-vault-raft-snapshot.snap # Raft snapshot that build.sh takes from the live openbao-0
└── 03-cluster.env              # cluster topology: GATEWAY_EXTERNAL_IP, GATEWAY_INTERNAL_IP, GATEWAY_TLS_IP
```

Generate / refresh with `bash scripts/dr-pack/build.sh` (see [`../dr-pack/README.md`](../dr-pack/README.md)).

After OpenBao is restored, every other secret (Forgejo SSH key, OIDC client secrets, Cloudflared tunnel JSON, OpenWrt creds, all S3 keys) is read from it, so none of them live in the DR pack.

Forgejo is not part of this rebuild: it runs on the ops node, outside the cluster. Phase 10 only checks that `git.example.com` answers. If the ops node is lost too, recover it first (`obsidian/113 Backups/Forgejo Recovery.md`).

## Phases

| # | Name | Source of inputs |
|---|---|---|
| 00 | preflight | DR pack + Vaultwarden + cluster reachable |
| 01 | network | git (Cilium + Gateway API charts) |
| 02 | storage | git (local-path-provisioner, Longhorn, snapshot-controller, VolSync charts) |
| 03 | tls | `01-bootstrap.env` (CF_API_TOKEN), git (cert-manager) |
| 04 | dns | `01-bootstrap.env` (CF token, optional `OPENWRT_*`), git (external-dns CF + OpenWrt charts); bootstrap Secrets labelled `homelab.dr/bootstrap=true` |
| 05 | snapshot-fetch | `01-bootstrap.env` (Garage/OVH keys) — pulls the freshest OpenBao Raft snapshot from S3 if the DR pack copy is older than 7 days |
| 06 | vault-restore | `00-shamir.json.gpg` + `02-vault-raft-snapshot.snap` |
| 07 | eso | OpenBao now holds everything else; ESO policies and roles from `scripts/openbao-eso-access.sh` |
| 08 | cnpg | git (CNPG operator chart); Cluster CRs and barman recovery come with ArgoCD |
| 09 | apps | VolSync restic repositories, one volume per app via `restore-app.sh`; runs before ArgoCD so the PVCs do not exist yet, ArgoCD adopts them |
| 10 | argocd | Forgejo on the ops node must answer; deletes the bootstrap Secrets so ESO owns them, installs ArgoCD, then ApplicationSets render everything |

Chart versions are read at run time from git (`chart_version` in `lib/common.sh`): `argocd/infra/<name>/config.yaml` `targetRevision`, and `argocd/standalone/*.yaml` for Gateway API and ArgoCD. DR installs exactly what ArgoCD runs, so Renovate bumps need no second edit here.

## Per-app restore wrapper

```bash
scripts/dr/restore-app.sh --list                  # every restorable volume
scripts/dr/restore-app.sh <VOLSYNC_NAME>          # restore one
DR_NAMESPACE=<ns> scripts/dr/restore-app.sh x <REPO> <PVC> <SIZE> [<ACCESS_MODE>] [<UID>]
```

Restores one volume from its VolSync restic repository (`DR_RESTIC_TARGET=garage|ovh`, default `garage`). The volume list is `homelab-common.volsync[]` in git, with namespace, PVC, size, access mode and restic cache read from the same values file (VCT-based claims get their size from `VCT_SIZE` in the script); the mover runs as root so restic can give files back their owners. The wait is 1 min per Gi of the claim, never under 15 min. Phase 09 restores every volume on that list. The script refuses to run when the PVC already exists, unless `DR_FORCE=1`. For immich it also reassigns database objects left owned by `immich_user` to `immich`; in a full DR `immich-cluster` does not exist yet at phase 09, so this step warns and skips — run it by hand once the cluster is up.
