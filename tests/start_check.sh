#!/bin/bash
# shellcheck disable=SC2016  # the checks look for literal dollar signs
# Starts the built image for real (Synapse + a throwaway Postgres on the host network) the way prod and a fresh install start it.
# Usage: bash tests/start_check.sh <image> [old-template-file]
set -u
IMAGE="${1:?image name}"
OLD_TEMPLATE="${2:-}"
FAILED=0
pass() { echo "ok   - $1"; }
fail() { FAILED=$((FAILED + 1)); echo "FAIL - $1"; }
expect() { if [[ $1 -eq 0 ]]; then pass "$2"; else fail "$2"; fi; }

WORK=$(mktemp -d)
PUBLIC_TEXT='${JWT_SECRET:-}'

# shellcheck disable=SC2329  # runs from the trap
stop_all() { docker rm -f synapse-start-check pg-start-check >/dev/null 2>&1; }
trap 'stop_all; sudo rm -rf "$WORK" 2>/dev/null || rm -rf "$WORK"' EXIT

start_postgres() {
  docker rm -f pg-start-check >/dev/null 2>&1
  docker run -d --name pg-start-check --network host -e POSTGRES_USER=synapse -e POSTGRES_PASSWORD=pw -e POSTGRES_DB=synapse \
    -e POSTGRES_INITDB_ARGS="--encoding=UTF8 --lc-collate=C --lc-ctype=C" postgres:17-alpine >/dev/null
  for _ in $(seq 1 30); do docker exec pg-start-check pg_isready -U synapse >/dev/null 2>&1 && return 0; sleep 1; done
  return 1
}

# start_synapse <data dir> [docker run options]: waits until the client API answers
start_synapse() {
  local data="$1"; shift
  docker rm -f synapse-start-check >/dev/null 2>&1
  docker run -d --name synapse-start-check --network host -v "$data:/data" \
    -e SYNAPSE_SERVER_NAME=chat.example.net -e SYNAPSE_PUBLIC_BASEURL=http://localhost:8008 \
    -e POSTGRES_HOST=127.0.0.1 -e POSTGRES_USER=synapse -e POSTGRES_PASSWORD=pw -e POSTGRES_DATABASE=synapse \
    -e SYNAPSE_REGISTRATION_SHARED_SECRET=r -e SYNAPSE_MACAROON_SECRET_KEY=m -e SYNAPSE_FORM_SECRET=f \
    -e AUTHENTIK_ISSUER=https://id.example.net -e AUTHENTIK_CLIENT_ID=c -e AUTHENTIK_CLIENT_SECRET=s \
    -e S3_BUCKET_NAME=b -e S3_REGION=auto -e S3_ACCESS_KEY_ID=k -e S3_SECRET_ACCESS_KEY=s -e S3_ENDPOINT_URL=http://127.0.0.1:9 \
    "$@" "$IMAGE" >/dev/null
  for _ in $(seq 1 90); do
    curl -fs http://localhost:8008/_matrix/client/v3/login >/dev/null 2>&1 && return 0
    [[ "$(docker inspect -f '{{.State.Running}}' synapse-start-check 2>/dev/null)" == "true" ]] || break
    sleep 2
  done
  echo "--- container log (last 40 lines)"; docker logs --tail 40 synapse-start-check 2>&1
  return 1
}

flows() { curl -fs http://localhost:8008/_matrix/client/v3/login | python3 -c 'import json,sys; print(" ".join(f["type"] for f in json.load(sys.stdin)["flows"]))'; }

# A JWT (HS256) for the Matrix user "alice", signed with the given secret
jwt_for() {
  python3 - "$1" <<'PY'
import base64, hashlib, hmac, json, sys
def b(x): return base64.urlsafe_b64encode(x).rstrip(b"=")
head = b(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
body = b(json.dumps({"matrixUserId": "alice"}).encode())
sig = b(hmac.new(sys.argv[1].encode(), head + b"." + body, hashlib.sha256).digest())
print((head + b"." + body + b"." + sig).decode())
PY
}
jwt_login_status() {
  curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost:8008/_matrix/client/v3/login \
    -H 'Content-Type: application/json' -d "{\"type\":\"org.matrix.login.jwt\",\"token\":\"$(jwt_for "$1")\"}"
}

echo "== 1. fresh install: empty /data, no JWT secret"
start_postgres; expect $? "postgres is up"
fresh="$WORK/fresh"; mkdir -p "$fresh"
start_synapse "$fresh"; expect $? "fresh install: Synapse starts with an empty /data"
f=$(flows)
grep -q 'm.login.password' <<<"$f"; expect $? "fresh install: password sign-in is offered ($f)"
! grep -q 'org.matrix.login.jwt' <<<"$f"; expect $? "fresh install: JWT sign-in is off without a secret"
! grep -qF '${' "$fresh/homeserver.yaml"; expect $? "fresh install: no placeholder text in homeserver.yaml"
docker logs synapse-start-check 2>&1 | grep -q 'JWT sign-in: off'; expect $? "fresh install: the log says JWT sign-in is off"

echo "== 2. prod style: /data holds an older template (with the public secret text), JWT secret set"
start_postgres
prod="$WORK/prod"; mkdir -p "$prod"
if [[ -n "$OLD_TEMPLATE" && -f "$OLD_TEMPLATE" ]]; then cp "$OLD_TEMPLATE" "$prod/homeserver.yaml.template"; else printf '# OLD_TEMPLATE\njwt_config:\n  enabled: true\n  secret: "%s"\n' "$PUBLIC_TEXT" > "$prod/homeserver.yaml.template"; fi
REAL_SECRET='Zk9$real"secret\with-odd-chars'
start_synapse "$prod" -e "JWT_SECRET=$REAL_SECRET"; expect $? "prod style: Synapse starts with an older template in /data"
! grep -qF 'JWT_SECRET:-' "$prod/homeserver.yaml"; expect $? "prod style: the public secret text is gone from homeserver.yaml"
grep -c '^jwt_config:' "$prod/homeserver.yaml" | grep -qx 1; expect $? "prod style: exactly one jwt_config block"
grep -q 'org.matrix.login.jwt' <<<"$(flows)"; expect $? "prod style: JWT sign-in is on because a secret is set"
code=$(jwt_login_status "$PUBLIC_TEXT"); [[ "$code" == "403" ]]; expect $? "prod style: a JWT signed with the public text is refused (403)"
code=$(jwt_login_status "$REAL_SECRET"); [[ "$code" == "200" ]]; expect $? "prod style: a JWT signed with the real secret signs in (200)"
f=$(flows); grep -q 'm.login.password' <<<"$f" && grep -q 'm.login.token' <<<"$f"; expect $? "prod style: password and token sign-in are unchanged ($f)"

echo "== 3. restart on the same /data (a dev reset keeps /data, a redeploy restarts on it)"
start_synapse "$prod" -e "JWT_SECRET=$REAL_SECRET"; expect $? "restart: Synapse starts again on the same /data"
grep -c '^jwt_config:' "$prod/homeserver.yaml" | grep -qx 1; expect $? "restart: still exactly one jwt_config block"
code=$(jwt_login_status "$REAL_SECRET"); [[ "$code" == "200" ]]; expect $? "restart: the real secret still signs in"

echo "== 4. a secret with a line break stops the start before Synapse runs"
docker rm -f synapse-start-check >/dev/null 2>&1
docker run --name synapse-start-check --network host -v "$fresh:/data" \
  -e SYNAPSE_SERVER_NAME=chat.example.net -e SYNAPSE_PUBLIC_BASEURL=http://localhost:8008 \
  -e POSTGRES_HOST=127.0.0.1 -e POSTGRES_USER=synapse -e POSTGRES_PASSWORD=pw -e POSTGRES_DATABASE=synapse \
  -e SYNAPSE_REGISTRATION_SHARED_SECRET=r -e SYNAPSE_MACAROON_SECRET_KEY=m -e SYNAPSE_FORM_SECRET=f \
  -e AUTHENTIK_ISSUER=https://id.example.net -e AUTHENTIK_CLIENT_ID=c -e AUTHENTIK_CLIENT_SECRET=s \
  -e "JWT_SECRET=$(printf 'a\nb')" "$IMAGE" >"$WORK/linebreak.log" 2>&1; rc=$?
[[ $rc -ne 0 ]]; expect $? "line break: the container exits instead of starting"
grep -q 'ERROR: JWT_SECRET contains a line break' "$WORK/linebreak.log"; expect $? "line break: the log says why"

echo
if [[ $FAILED -eq 0 ]]; then echo "all passed"; else echo "$FAILED failed"; fi
exit $((FAILED > 0))
