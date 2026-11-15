#!/bin/bash
# Masks secrets in text on stdin before it reaches the transcript: env files, compose
# (`KEY=v`, `- KEY=v`, `KEY: v`), URL credentials, Bearer/token headers, subscription URLs.
#
#   ssh vps-panel 'sudo cat /opt/remnawave/docker-compose.yml' | scripts/mask-secrets.sh
#   scripts/mask-secrets.sh --selftest
#
# An expression anchored at line start leaked `      - SECRET_KEY=…` from a compose list:
# the key may sit anywhere in the line. Over-masking is fine, a miss is a leak.
set -euo pipefail

mask() {
  sed -E \
    -e 's/(^|[^A-Za-z0-9_])([A-Za-z0-9_.-]*(SECRET|PASSWORD|PASSWD|TOKEN|KEY|JWT|HASH|PASS|CREDENTIAL|PRIVATE)[A-Za-z0-9_.-]*)("?[[:space:]]*[=:][[:space:]]*).*/\1\2\4***/I' \
    -e 's#://[^:/@[:space:]]+:[^@[:space:]]+@#://***:***@#g' \
    -e 's/((Bearer|Token|Basic)[[:space:]]+)[A-Za-z0-9._~+\/=-]{8,}/\1***/Ig' \
    -e "s#(url'?[[:space:]=:]+'?https?://[^/'\"[:space:]]+/)[^'\"[:space:]]+#\1<redacted>#Ig"
}

[ "${1:-}" = --selftest ] || { mask; exit 0; }

fail=0
check() {  # <input> <expected>
  local got; got=$(printf '%s\n' "$1" | mask)
  [ "$got" = "$2" ] || { echo "FAIL mask-secrets: '$1' -> '$got', want '$2'"; fail=1; }
}
check 'SECRET_KEY=abc123'                         'SECRET_KEY=***'
check '      - SECRET_KEY=abc123'                 '      - SECRET_KEY=***'
check '  JWT_AUTH_SECRET: "x9y8"'                 '  JWT_AUTH_SECRET: ***'
check 'WEBHOOK_SECRET_HEADER=v'                   'WEBHOOK_SECRET_HEADER=***'
check 'export POSTGRES_PASSWORD="p w"'            'export POSTGRES_PASSWORD=***'
check '"api_key": "abc"'                          '"api_key": ***'
check 'DATABASE_URL=postgresql://u:p4ss@db:5432/x' 'DATABASE_URL=postgresql://***:***@db:5432/x'
check '-H "Authorization: Bearer eyJhbGciOi.x.y"' '-H "Authorization: Bearer ***"'
check 'X-Auth: token aaaaaaaaaaaa'                  'X-Auth: token ***'
check "nikki.sub.url='https://sub.example.org/AbCdEf123'" "nikki.sub.url='https://sub.example.org/<redacted>'"
check 'image: remnawave/backend:3.4.11'           'image: remnawave/backend:3.4.11'
check 'APP_PORT=3000'                             'APP_PORT=3000'
check 'restart: always'                           'restart: always'
[ $fail = 0 ] && echo "mask-secrets: selftest ok"
exit $fail
