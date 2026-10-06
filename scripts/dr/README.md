# DR Recovery Automation

Idempotent disaster recovery for the homelab cluster. Brings a freshly-bootstrapped Talos cluster back to a fully-functional Healthy state by restoring an OpenBao Raft snapshot from S3 and letting ESO/ArgoCD replay everything else from there.

## Design principles

1. **DR pack is the single source of truth** for bootstrap-time secrets (Shamir keys + 3 env files). Everything else flows out of the restored Vault.
2. **Phases are idempotent.** Each phase has `pre_flight` (skip if already done), `do_phase`, and `validate`. Re-running is safe.
3. **No manual TODO in the pack.** If something can't be auto-included it's a bug in `build.sh`, not a checkbox for the operator.
4. **Self-contained scripts.** No hardcoded tokens / UUIDs / account IDs — those come from env vars or `~/dr-pack/` files at runtime.

## Quick start (after fresh Talos cluster is up + kubeconfig in place)

```bash
# Validate the DR pack is complete and Vaultwarden has the passphrase note
scripts/dr-pack/verify.sh

# Run every phase end-to-end
scripts/dr/restore.sh all

# Or run individual phases
scripts/dr/restore.sh phase 01-network
scripts/dr/restore.sh phase 06-vault-restore
```

## DR pack layout (minimal v3)

```
~/dr-pack/
├── 00-shamir.json.gpg          # gpg -c, passphrase in Vaultwarden secure note "00 - DR Pack Passphrase"
├── 01-bootstrap.env            # CF_API_TOKEN, GARAGE_RESTIC_*, GARAGE_SNAPSHOTS_*, OVH_S3_*, RESTIC_PASSWORD_GARAGE/_OVH
├── 02-vault-raft-snapshot.snap # latest Raft snapshot pulled from S3 by build.sh
├── 03-cluster.env              # cluster topology: GATEWAY_INTERNAL_IP, GATEWAY_EXTERNAL_IP, GATEWAY_TLS_IP, OPENWRT_HOST
└── README.md
```

Generate / refresh with `scripts/dr-pack/build.sh`.

After Vault is restored, every other secret (Forgejo SSH, OIDC client_secrets, Cloudflared tunnel JSON, OpenWrt creds, all S3 keys) is read from Vault — they never need to live in the DR pack.

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
| 07 | eso | Vault now holds everything else; ESO policies and roles from `scripts/openbao-eso-access.sh` |
| 08 | cnpg | git (CNPG operator chart); Cluster CRs and barman recovery come with ArgoCD |
| 10 | argocd | Forgejo on the ops node must answer; ArgoCD bootstrap, then ApplicationSets render everything |
| 11 | apps | VolSync restic repositories, one volume per app via `restore-app.sh` |

There is no phase 09: it restored the in-cluster Forgejo and was removed when Forgejo moved to the ops node.

## Per-app restore wrapper

```bash
scripts/dr/restore-app.sh <app-name> [backup-name]
```

Restores one volume from its VolSync restic repository (`DR_RESTIC_TARGET=garage|ovh`). Knows app-specific gotchas: ResourceModifier for PVC `volumeName`, post-restore DB ownership reassignment for immich.

## Sanitization

Nothing in this directory carries secrets — only logic. `gitleaks` runs both pre-commit (Forgejo) and as the mirror gate before the GitHub push. All sensitive values are read at runtime from env vars or files under `~/dr-pack/` (which never enters git).
