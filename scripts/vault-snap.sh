#!/usr/bin/env bash
# Commit the Obsidian vault (private git, remote vizzle/vault) before and after bulk agent edits:
# rollback is `git restore`/`git revert` in the vault. Windows git.exe: WSL git on /mnt/c breaks modes and is slow.
# Usage: scripts/vault-snap.sh <message>
set -euo pipefail
G="/mnt/c/Program Files/Git/cmd/git.exe"
W='C:\Users\IVAN\Documents\obsidian'
msg="${1:?usage: scripts/vault-snap.sh <message>}"
"$G" -C "$W" add -A
if "$G" -C "$W" diff --cached --quiet; then echo "vault: nothing to commit"; exit 0; fi
"$G" -C "$W" commit -qm "agent: $msg"
"$G" -C "$W" log --oneline -1
