# DR pack tooling

Generates and validates the minimal disaster-recovery bundle used by `scripts/dr/restore.sh`.

## Files produced under `~/dr-pack/`

| File | Purpose | Sensitivity |
|---|---|---|
| `00-shamir.json.gpg` | OpenBao 3 unseal keys + root token, `gpg --symmetric` encrypted. Passphrase lives in Vaultwarden secure note "00 - DR Pack Passphrase". | RED — full Vault root |
| `01-bootstrap.env` | Pre-Vault bootstrap secrets: `CF_API_TOKEN`, `GARAGE_VELERO_*`, optional `OVH_S3_*`, optional `OPENWRT_*` | RED |
| `02-vault-raft-snapshot.snap` | Latest OpenBao Raft snapshot pulled from S3 (encrypted at rest by Vault). | RED |
| `03-cluster.env` | Cluster topology / gateway IPs (non-secret, but pinned for reproducibility) | yellow |

## Usage

```bash
# Refresh DR pack (idempotent — overwrites stale files)
scripts/dr-pack/build.sh

# Sanity-check the pack BEFORE you need it
scripts/dr-pack/verify.sh

# Quarterly DR drill (spawns kind cluster, replays phases 00-06)
scripts/dr-pack/verify.sh --drill
```

`build.sh` requires:

- `kubectl` access to the live cluster (to dump the current `openbao-keys` Secret).
- `VAULT_TOKEN` (will read from `~/.vault-token` or env).
- `gpg` with the DR pack passphrase available (interactive prompt or `GPG_PASSPHRASE` env).
- AWS CLI configured with Garage `velero` key (to download the latest Raft snapshot from S3).

## Cron candidate

```cron
# Weekly DR pack refresh + verify (Sundays 04:00 local)
0 4 * * 0 cd /home/ivan && ./Documents/home/homelab/scripts/dr-pack/build.sh > ~/dr-pack/last-build.log 2>&1 && ./Documents/home/homelab/scripts/dr-pack/verify.sh >> ~/dr-pack/last-build.log 2>&1
```

If `build.sh` exits non-zero a Telegram alert via VictoriaMetrics Alertmanager fires (see [[Monitoring Stack Gotchas]]).
