# DR pack tooling

Generates and validates the minimal disaster-recovery bundle used by `scripts/dr/restore.sh`.

## Files produced under `~/dr-pack/`

| File | Purpose | Sensitivity |
|---|---|---|
| `00-shamir.json.gpg` | OpenBao 3 unseal keys + root token from the `openbao-keys` and `openbao-root-token` Secrets, `gpg --symmetric` (AES256). By convention the passphrase is the Vaultwarden master password (`GPG_PASSPHRASE=$BW_PASSWORD`), so it is not stored as a separate entry. | RED — full OpenBao root |
| `01-bootstrap.env` | Pre-OpenBao bootstrap secrets, read from live cluster Secrets: `CF_API_TOKEN`, `GARAGE_RESTIC_*`, `GARAGE_SNAPSHOTS_*`, `OVH_S3_*`, `RESTIC_PASSWORD_GARAGE`/`_OVH`, optional `OPENWRT_*` | RED |
| `02-vault-raft-snapshot.snap` | OpenBao Raft snapshot taken from the live `openbao-0` (`bao operator raft snapshot save`). | RED |
| `03-cluster.env` | Gateway IPs (`GATEWAY_EXTERNAL_IP`, `GATEWAY_INTERNAL_IP`, `GATEWAY_TLS_IP`); not secret | yellow |

The cluster builds the same pack weekly on its own — CronJob `openbao/openbao-dr-pack-offsite`
uploads `dr-pack-<ts>.tar.gz.gpg` (the whole tarball encrypted, passphrase in Vault
`shared/dr-pack`) to both S3 targets. Unpack it into `~/dr-pack/`: the phases and `verify.sh` accept it.
`00-shamir.json` comes out in the clear instead of `00-shamir.json.gpg`, and the pack carries an
extra `04-nodes.txt`.

## Usage

```bash
# Refresh DR pack (idempotent — overwrites the four files, keeps extras)
bash scripts/dr-pack/build.sh

# Sanity-check the pack BEFORE you need it
scripts/dr-pack/verify.sh

# Copy DR secrets from OpenBao into Vaultwarden (rbw preferred, bw with BW_SESSION)
rbw unlock
bash scripts/dr-pack/to-bitwarden.sh [--dry-run]
```

`build.sh` and `to-bitwarden.sh` have no executable bit, hence `bash`.

`verify.sh` checks that the four files exist, that the Shamir bundle decrypts with 3 keys and a root token, and that the Raft snapshot is over 1 KB and under 7 days old. With `rbw` or `bw` unlocked it also checks the Vaultwarden entries `08 - Restic repo passwords (backup v2)` and `09 - S3 keys backup v2 (restic-apps, snapshots, OVH)`. `to-bitwarden.sh` writes those two plus `10 - DR pack passphrase (off-site)` into the `HomeLab DR` folder.

`build.sh` requires:

- `kubectl` access to the live cluster: it reads the `openbao-keys` and `openbao-root-token` Secrets, the S3 and restic Secrets, and execs into `openbao-0` for the snapshot.
- `gpg` with the DR pack passphrase available (interactive prompt or `GPG_PASSPHRASE` env).
- `jq`.

If the pack's snapshot is older than 7 days at restore time, phase 05 pulls a fresher one from S3.

## Cron candidate

```cron
# Weekly DR pack refresh + verify (Sundays 04:00 local)
0 4 * * 0 cd /home/ivan && bash ./Documents/home/homelab/scripts/dr-pack/build.sh > ~/dr-pack/last-build.log 2>&1 && ./Documents/home/homelab/scripts/dr-pack/verify.sh >> ~/dr-pack/last-build.log 2>&1
```

Nothing alerts on this local cron. Alerts `DrPackStale`, `DrPackNeverRan` and `DrPackSuspiciouslySmall` (`argocd/infra/openbao/manifests/vmrule-dr-pack.yaml`) watch only the in-cluster `openbao-dr-pack-offsite` CronJob.
