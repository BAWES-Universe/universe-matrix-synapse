#!/bin/bash
# shellcheck disable=SC2016,SC2034  # check() takes its condition as a single-quoted string that is evaluated later
# Tests for jwt.sh and the template's jwt_config. Run: bash tests/jwt_test.sh
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="${TEMPLATE:-$HERE/homeserver.yaml.template}"
FAILED=0

pass() { echo "ok   - $1"; }
fail() { FAILED=$((FAILED + 1)); echo "FAIL - $1"; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Renders the template the way entrypoint.sh does, with the variables it needs and the given extras
render() {
  local out="$1"; shift
  env -i PATH="$PATH" SYNAPSE_SERVER_NAME=chat.example.net SYNAPSE_PUBLIC_BASEURL=https://chat.example.net \
    POSTGRES_HOST=db POSTGRES_USER=u POSTGRES_PASSWORD=p POSTGRES_DATABASE=d POSTGRES_PORT=5432 \
    SYNAPSE_REGISTRATION_SHARED_SECRET=r SYNAPSE_MACAROON_SECRET_KEY=m SYNAPSE_FORM_SECRET=f \
    AUTHENTIK_ISSUER=https://id.example.net AUTHENTIK_CLIENT_ID=c AUTHENTIK_CLIENT_SECRET=s "$@" \
    bash -c "source '$HERE/jwt.sh'; prepare_jwt_secret && envsubst < '$TEMPLATE'" > "$out"
}
# Runs both steps of the entrypoint on a rendered file
finish() { env -i PATH="$PATH" "${@:2}" bash -c "source '$HERE/jwt.sh'; apply_jwt_config '$1' && reject_unrendered '$1'"; }

# 1. No secret: the block is gone, the rest of the file is intact
render "$TMP/off.yaml"
finish "$TMP/off.yaml" >/dev/null; rc=$?
check "no secret: both steps pass" '[[ $rc -eq 0 ]]'
check "no secret: no jwt_config in the file" '! grep -q "jwt_config" "$TMP/off.yaml"'
check "no secret: no placeholder text anywhere" '! grep -q "\${" "$TMP/off.yaml"'
check "no secret: the next block (oidc_providers) is still there" 'grep -q "^oidc_providers:" "$TMP/off.yaml"'
check "no secret: the config before it is still there" 'grep -q "^form_secret: \"f\"" "$TMP/off.yaml"'

# 2. Secret set: the block stays and holds the value, never the placeholder
render "$TMP/on.yaml" JWT_SECRET=s3cret-value
finish "$TMP/on.yaml" JWT_SECRET=s3cret-value >/dev/null; rc=$?
check "secret set: both steps pass" '[[ $rc -eq 0 ]]'
check "secret set: the file holds the secret" 'grep -q "secret: \"s3cret-value\"" "$TMP/on.yaml"'
check "secret set: no placeholder text" '! grep -q "\${" "$TMP/on.yaml"'

# 3. An empty secret counts as not set
render "$TMP/empty.yaml" JWT_SECRET=
finish "$TMP/empty.yaml" JWT_SECRET= >/dev/null
check "empty secret: no jwt_config in the file" '! grep -q "jwt_config" "$TMP/empty.yaml"'

# 4. A placeholder envsubst cannot fill stops the start
printf 'a: 1\nsecret: "${JWT_SECRET:-}"\n' > "$TMP/literal.yaml"
out=$(env -i PATH="$PATH" bash -c "source '$HERE/jwt.sh'; reject_unrendered '$TMP/literal.yaml'" 2>&1); rc=$?
check "placeholder text left: refused" '[[ $rc -ne 0 ]]'
check "placeholder text left: says which line" '[[ "$out" == *"line(s) 2"* ]]'

# 5. A secret with a backslash, a quote or a dollar sign reaches Synapse as typed
tricky="a\\nb\"c\$d\\\\"
render "$TMP/tricky.yaml" "JWT_SECRET=$tricky"
finish "$TMP/tricky.yaml" "JWT_SECRET=$tricky" >/dev/null
got=$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["jwt_config"]["secret"], end="")' "$TMP/tricky.yaml" 2>&1)
check "tricky secret: the file reads back as the same secret" '[[ "$got" == "$tricky" ]]'

# 6. A secret with a line break cannot be written and stops the start
out=$(env -i PATH="$PATH" "JWT_SECRET=$(printf 'a\nb')" bash -c "source '$HERE/jwt.sh'; prepare_jwt_secret" 2>&1); rc=$?
check "line break in the secret: refused" '[[ $rc -ne 0 ]]'

# 7. If the block cannot be taken out, the start stops instead of leaving it on with an empty secret
render "$TMP/stuck.yaml"
mkdir "$TMP/stuck.yaml.tmp"
env -i PATH="$PATH" bash -c "source '$HERE/jwt.sh'; apply_jwt_config '$TMP/stuck.yaml'" >/dev/null 2>&1; rc=$?
check "block cannot be taken out: refused" '[[ $rc -ne 0 ]]'

# 8. The shipped template never holds the text envsubst cannot fill
check "template has no \${NAME:-default} form" '! grep -q "\${[A-Za-z_]*:" "$TEMPLATE"'
check "entrypoint runs every step and stops when one fails" 'grep -q "prepare_jwt_secret || exit 1" "$HERE/entrypoint.sh" && grep -q "apply_jwt_config /data/homeserver.yaml || exit 1" "$HERE/entrypoint.sh" && grep -q "reject_unrendered /data/homeserver.yaml || exit 1" "$HERE/entrypoint.sh"'
check "image copies jwt.sh" 'grep -q "COPY jwt.sh /jwt.sh" "$HERE/Dockerfile"'

echo
if [[ $FAILED -eq 0 ]]; then echo "all passed"; else echo "$FAILED failed"; fi
exit $((FAILED > 0))
