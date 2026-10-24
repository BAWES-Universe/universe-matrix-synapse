#!/bin/bash
# shellcheck disable=SC2016  # the checks look for literal dollar signs
# Runs the config steps of entrypoint.sh inside the built image, with the files the image ships.
# Usage: bash tests/image_check.sh <image>
set -u
IMAGE="${1:?image name}"
FAILED=0
pass() { echo "ok   - $1"; }
fail() { FAILED=$((FAILED + 1)); echo "FAIL - $1"; }

# Renders the template the way entrypoint.sh does and prints the result; the extra arguments are docker run options
render() {
  docker run --rm --entrypoint bash \
    -e SYNAPSE_SERVER_NAME=chat.example.net -e SYNAPSE_PUBLIC_BASEURL=https://chat.example.net \
    -e POSTGRES_HOST=db -e POSTGRES_USER=u -e POSTGRES_PASSWORD=p -e POSTGRES_DATABASE=d -e POSTGRES_PORT=5432 \
    -e SYNAPSE_REGISTRATION_SHARED_SECRET=r -e SYNAPSE_MACAROON_SECRET_KEY=m -e SYNAPSE_FORM_SECRET=f \
    -e AUTHENTIK_ISSUER=https://id.example.net -e AUTHENTIK_CLIENT_ID=c -e AUTHENTIK_CLIENT_SECRET=s "$@" \
    "$IMAGE" -c 'source /jwt.sh && prepare_jwt_secret && envsubst < /data/homeserver.yaml.template > /tmp/h.yaml \
      && apply_jwt_config /tmp/h.yaml >&2 && reject_unrendered /tmp/h.yaml && cat /tmp/h.yaml'
}

# Records a result: expect <exit status that means pass> <name>
expect() { if [[ $1 -eq 0 ]]; then pass "$2"; else fail "$2"; fi; }

out=$(render 2>/dev/null); rc=$?
expect $rc "no secret: the image renders the config"
! grep -q 'jwt_config' <<<"$out"; expect $? "no secret: jwt_config is left out"
grep -q '^oidc_providers:' <<<"$out"; expect $? "no secret: the rest of the config is there"

out=$(render -e "JWT_SECRET=ab\"c\\d\$e" 2>/dev/null); rc=$?
expect $rc "secret set: the image renders the config"
grep -q '^jwt_config:' <<<"$out"; expect $? "secret set: jwt_config is there"
grep -qF "secret: \"ab\\\"c\\\\d\$e\"" <<<"$out"; expect $? "secret set: the secret is written as YAML text"
! grep -qF '${' <<<"$out"; expect $? "secret set: no placeholder text"

docker run --rm --entrypoint bash "$IMAGE" -c 'bash -n /entrypoint.sh && grep -q "prepare_jwt_secret || exit 1" /entrypoint.sh'
expect $? "the image's entrypoint parses and runs the JWT steps"

echo
if [[ $FAILED -eq 0 ]]; then echo "all passed"; else echo "$FAILED failed"; fi
exit $((FAILED > 0))
