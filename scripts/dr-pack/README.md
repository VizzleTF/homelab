# DR pack tooling

Generates and validates the minimal disaster-recovery bundle used by `scripts/dr/restore.sh`.

## Files produced under `~/dr-pack/`

| File | Purpose | Sensitivity |
|---|---|---|
| `00-shamir.json.gpg` | OpenBao 3 unseal keys + root token from the `openbao-keys` and `openbao-root-token` Secrets, `gpg --symmetric` (AES256). By convention the passphrase is the Vaultwarden master password (`GPG_PASSPHRASE=$BW_PASSWORD`), so it is not stored as a separate entry. | RED — full OpenBao root |
| `01-bootstrap.env` | Pre-OpenBao bootstrap secrets, read from live cluster Secrets: `CF_API_TOKEN`, `GARAGE_RESTIC_*`, `GARAGE_SNAPSHOTS_*`, `OVH_S3_*`, `OVH_CRYPT_PASSWORD`/`2` (rclone-obscured crypt key of the OVH snapshot, tfstate, pg_dump and router config copies), `RESTIC_PASSWORD_GARAGE`/`_OVH`, `GARAGE_RESTIC_VPS_*` and `RESTIC_VPS_PASSWORD_GARAGE`/`_OVH` (VPS fleet restic), optional `OPENWRT_PASS` (router host and login are in git) | RED |
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

# Copy DR secrets from OpenBao into Vaultwarden
S=$(bw unlock --passwordenv BW_PASSWORD --raw) && DR_CLIENT=bw BW_SESSION="$S" bash scripts/dr-pack/to-bitwarden.sh [--dry-run]; bw lock
```

`bw unlock --passwordenv` needs no TTY. `rbw unlock` does (pinentry: `Inappropriate ioctl for device`): run it in a separate terminal, the rbw agent then serves the Claude session too.

`verify.sh` checks that the four files exist, that the Shamir bundle decrypts with 3 keys and a root token, and that the Raft snapshot is over 1 KB and under 7 days old. With `rbw` or `bw` unlocked it also checks Vaultwarden entries 08, 09, 11, 12 and 13.

## Vaultwarden entries

Folder `Infra / Homelab DR`. This is the one list; runbooks cite entries by number.

| Entry | Holds | Written by |
|---|---|---|
| 01–07 | Talos PKI, terraform state, S3, DNS/TLS, Forgejo tokens, Vault map, misc | by hand |
| `08 - Restic repo passwords (backup v2)` | `shared/restic-garage`, `shared/restic-ovh` | `to-bitwarden.sh` |
| `09 - S3 keys backup v2 (restic-apps, snapshots, OVH)` | `shared/s3-restic-apps`, `shared/s3-snapshots`, `shared/s3-ovh` | `to-bitwarden.sh` |
| `10 - DR pack passphrase (off-site)` | `shared/dr-pack` | `to-bitwarden.sh` |
| `11 - Forgejo instance secrets` | `forgejo/instance-secrets` | `to-bitwarden.sh` |
| `12 - OVH rclone crypt (snapshots, tfstate)` | `shared/ovh-crypt` (crypt of etcd and OpenBao snapshots, tfstate, pg_dump, router configs) | `to-bitwarden.sh` |
| `13 - VPS restic (restic-vps)` | `shared/s3-restic-vps`, `shared/restic-vps-garage`, `shared/restic-vps-ovh` | `to-bitwarden.sh` |
| 99 | readme | by hand |

A new entry is a new `ITEMS` line in `to-bitwarden.sh` plus a row here. Entry 11 holds Forgejo's `SECRET_KEY` and the other instance secrets: without them a dump restored on a new ops node cannot decrypt Authentik client secrets, 2FA or mirror passwords, and OpenBao is not up yet in a full loss.

`build.sh` requires:

- `kubectl` access to the live cluster: it reads the `openbao-keys` and `openbao-root-token` Secrets, the S3 and restic Secrets, and execs into `openbao-0` for the snapshot.
- `gpg` with the DR pack passphrase available (interactive prompt or `GPG_PASSPHRASE` env).
- `jq`.

If the pack's snapshot is older than 7 days at restore time, phase 05 pulls a fresher one from S3.

Alerts `DrPackStale`, `DrPackNeverRan` and `DrPackSuspiciouslySmall` (`argocd/infra/openbao/manifests/vmrule-dr-pack.yaml`) watch only the in-cluster `openbao-dr-pack-offsite` CronJob; a locally built pack has no alert.
