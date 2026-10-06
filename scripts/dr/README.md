# DR Recovery Automation

Idempotent disaster recovery for the homelab cluster. Brings a freshly-bootstrapped Talos cluster back to a fully-functional Healthy state by restoring an OpenBao Raft snapshot from S3 and letting ESO/ArgoCD replay everything else from there.

## Design principles

1. **DR pack is the single source of truth** for bootstrap-time secrets (Shamir keys, a Raft snapshot, two env files). Everything else flows out of the restored OpenBao.
2. **Phases are idempotent.** Each phase installs through `helm_apply` (`helm upgrade --install --wait`, `lib/common.sh`) and waits for readiness, so re-running is safe.
3. **No manual TODO in the pack.** If something can't be auto-included it's a bug in `build.sh`, not a checkbox for the operator.
4. **Self-contained scripts.** No hardcoded tokens / UUIDs / account IDs — those come from env vars or `~/dr-pack/` files at runtime.

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

Forgejo is not part of this rebuild: since 2026-09-12 it runs on the ops node, outside the cluster. Phase 10 only checks that `git.example.com` answers. If the ops node is lost too, recover it first (`obsidian/113 Backups/Forgejo Recovery.md`).

## Phases

| # | Name | Source of inputs |
|---|---|---|
| 00 | preflight | DR pack + Vaultwarden + cluster reachable |
| 01 | network | git (Cilium + Gateway API charts) |
| 02 | storage | git (Longhorn + snapshot-controller charts) |
| 03 | tls | `01-bootstrap.env` (CF_API_TOKEN), git (cert-manager) |
| 04 | dns | git (external-dns CF + OpenWrt charts) |
| 05 | snapshot-fetch | `01-bootstrap.env` (Garage/OVH keys) — pulls the freshest OpenBao Raft snapshot from S3 if the DR pack copy is older than 7 days |
| 06 | vault-restore | `00-shamir.json.gpg` + `02-vault-raft-snapshot.snap` |
| 07 | eso | OpenBao now holds everything else; ESO policies and roles from `scripts/openbao-eso-access.sh` |
| 08 | cnpg | git (CNPG operator chart); Cluster CRs and barman recovery come with ArgoCD |
| 10 | argocd | Forgejo on the ops node must answer; ArgoCD bootstrap, then ApplicationSets render everything |
| 11 | apps | VolSync restic repositories, one volume per app via `restore-app.sh` |

There is no phase 09: it restored the in-cluster Forgejo and was removed when Forgejo moved to the ops node.

Phases 01–08 and 10 pin their own chart versions (`--version` in each `phases/*.sh`); they are not read from `argocd/{infra,apps}/<name>/config.yaml`. Compare them before a real rebuild: ArgoCD later upgrades each release to the `config.yaml` version.

## Per-app restore wrapper

```bash
scripts/dr/restore-app.sh <APP> [<REPO> <PVC> <SIZE> [<ACCESS_MODE>] [<UID>]]
```

Restores one volume from its VolSync restic repository (`DR_RESTIC_TARGET=garage|ovh`, default `garage`). Known apps (`vaultwarden`, `cleanbot`, `may`, `rsstt`, `immich`, `opencloud`, `opencloud-config`, `trek`, `trek-data`, `obsidian-livesync`) need only `<APP>`; for anything else pass the repository, PVC and size. The script refuses to run when the PVC already exists, unless `DR_FORCE=1`. For immich it also reassigns database objects left owned by `immich_user` to `immich`.

Phase 11 skips netbird and crowdsec-scraper: their peer state lives outside the backed-up volume.

## Sanitization

Nothing in this directory carries secrets — only logic. `gitleaks` runs pre-commit, as a required PR check on Forgejo and as the mirror gate before the GitHub push. All sensitive values are read at runtime from env vars or files under `~/dr-pack/` (which never enters git).
