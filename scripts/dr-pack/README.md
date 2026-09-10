# DR pack tooling

Generates and validates the minimal disaster-recovery bundle used by `scripts/dr/restore.sh`.

## Files produced under `~/dr-pack/`

| File | Purpose | Sensitivity |
|---|---|---|
| `00-shamir.json.gpg` | OpenBao 3 unseal keys + root token, `gpg --symmetric` encrypted. Passphrase lives in Vaultwarden secure note "00 - DR Pack Passphrase". | RED — full OpenBao root |
| `01-bootstrap.env` | Pre-OpenBao bootstrap secrets: `CF_API_TOKEN`, `GARAGE_RESTIC_*`, `GARAGE_SNAPSHOTS_*`, `OVH_S3_*`, `RESTIC_PASSWORD_GARAGE`/`_OVH`, optional `OPENWRT_*` | RED |
| `02-vault-raft-snapshot.snap` | Latest OpenBao Raft snapshot pulled from S3 (encrypted at rest by OpenBao). | RED |
| `03-cluster.env` | Cluster topology / gateway IPs (non-secret, but pinned for reproducibility) | yellow |

The cluster builds the same pack weekly on its own — CronJob `openbao/openbao-dr-pack-offsite`
uploads `dr-pack-<ts>.tar.gz.gpg` (the whole tarball encrypted, passphrase in Vault
`shared/dr-pack`) to both S3 targets. Unpack it into `~/dr-pack/` and the phases accept it:
`00-shamir.json` comes out in the clear instead of `00-shamir.json.gpg`, and it carries an
extra `04-nodes.txt`.

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
- `BAO_TOKEN` (read from `~/.vault-token` or env; legacy `VAULT_TOKEN` still honoured).
- `gpg` with the DR pack passphrase available (interactive prompt or `GPG_PASSPHRASE` env).
- Nothing extra: phase 05 pulls the latest Raft snapshot from S3 with an in-cluster rclone pod using the keys in `01-bootstrap.env`.

## Cron candidate

```cron
# Weekly DR pack refresh + verify (Sundays 04:00 local)
0 4 * * 0 cd /home/ivan && ./Documents/home/homelab/scripts/dr-pack/build.sh > ~/dr-pack/last-build.log 2>&1 && ./Documents/home/homelab/scripts/dr-pack/verify.sh >> ~/dr-pack/last-build.log 2>&1
```

If `build.sh` exits non-zero a Telegram alert via VictoriaMetrics Alertmanager fires (see [[Monitoring Stack Gotchas]]).
