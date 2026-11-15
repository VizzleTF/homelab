#!/bin/bash
# Verifies keyless cosign signatures of images built by a GitHub Actions workflow.
#
#   scripts/cosign-verify.sh <workflow-identity> <image@sha256:...>...
#   scripts/cosign-verify.sh https://github.com/VizzleTF/alerse/.github/workflows/site.yml@refs/heads/main \
#     ghcr.io/vizzletf/alerse-site@sha256:<d1> ghcr.io/vizzletf/alerse-site-ru@sha256:<d2>
#
# cosign is not installed locally, so it runs from its container. v3 is required: v2.4.1 reports
# "no signatures found" for the same digests. Exit 1 if any image fails.
set -uo pipefail

[ $# -ge 2 ] || { sed -n '2,9p' "$0" >&2; exit 2; }
ID=$1; shift
rc=0
for ref in "$@"; do
  if out=$(docker run --rm ghcr.io/sigstore/cosign/cosign:v3.0.2 verify "$ref" \
      --certificate-identity "$ID" \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com 2>&1 >/dev/null); then
    echo "ok   $ref"
  else
    echo "FAIL $ref: $(grep -v '^\[' <<< "$out" | tail -1)"; rc=1
  fi
done
exit $rc
