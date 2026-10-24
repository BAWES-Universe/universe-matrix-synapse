#!/bin/bash
# shellcheck disable=SC2016,SC2034  # check() takes its condition as a single-quoted string that is evaluated later
# Tests for appservice.sh (bot direct messages). Run: bash tests/appservice_test.sh
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${APPSERVICE_SH:-$HERE/appservice.sh}"
FAILED=0
CASES=0

pass() { CASES=$((CASES + 1)); echo "ok   - $1"; }
fail() { CASES=$((CASES + 1)); FAILED=$((FAILED + 1)); echo "FAIL - $1"; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

AS=$(printf 'a%.0s' {1..40})
HS=$(printf 'b%.0s' {1..40})

# Runs configure_bot_appservice in a clean directory with a given environment; prints the output.
# Usage: run_case <dir> [VAR=value ...]
run_case() {
  local dir="$1"; shift
  mkdir -p "$dir"
  [[ -f "$dir/homeserver.yaml" ]] || printf 'server_name: "chat.example.net"\n' > "$dir/homeserver.yaml"
  env -i PATH="$PATH" APPSERVICE_FILE="$dir/appservice.yaml" HOMESERVER_FILE="$dir/homeserver.yaml" "$@" \
    bash -c "source '$SCRIPT'; configure_bot_appservice"
}

ENV_OK=(SYNAPSE_SERVER_NAME=chat.example.net BOT_APPSERVICE_URL=http://bot-server:3001 "BOT_APPSERVICE_AS_TOKEN=$AS" "BOT_APPSERVICE_HS_TOKEN=$HS")
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1. Nothing set: off, no file, homeserver.yaml untouched
d="$TMP/off"
out=$(run_case "$d" SYNAPSE_SERVER_NAME=chat.example.net)
check "nothing set: says off" '[[ "$out" == *"off"* ]]'
check "nothing set: no registration file" '[[ ! -e "$d/appservice.yaml" ]]'
check "nothing set: homeserver.yaml untouched" '! grep -q app_service_config_files "$d/homeserver.yaml"'

# 2. All set: file written with the right content, private, and listed once in homeserver.yaml
d="$TMP/on"
out=$(run_case "$d" "${ENV_OK[@]}")
check "all set: says on" '[[ "$out" == *"on, bot server at http://bot-server:3001"* ]]'
check "all set: file has id and url" 'grep -qx "id: universe-bots" "$d/appservice.yaml" && grep -qx "url: http://bot-server:3001" "$d/appservice.yaml"'
check "all set: tokens are in the file" 'grep -qx "as_token: $AS" "$d/appservice.yaml" && grep -qx "hs_token: $HS" "$d/appservice.yaml"'
check "all set: rate limit off for the bot server" 'grep -qx "rate_limited: false" "$d/appservice.yaml"'
check "all set: file is private (mode 600)" '[[ "$(stat -c %a "$d/appservice.yaml")" == "600" ]]'
check "all set: homeserver.yaml lists the file once" '[[ "$(grep -c "^app_service_config_files:" "$d/homeserver.yaml")" == "1" ]]'
check "all set: the listed path is the registration file" 'grep -qx "  - $d/appservice.yaml" "$d/homeserver.yaml"'
check "all set: the output never prints a token" '[[ "$out" != *"$AS"* && "$out" != *"$HS"* ]]'

# 3. The namespace pattern: dots escaped, only this server's bot accounts
pattern=$(sed -n "s/^      regex: '\(.*\)'$/\1/p" "$d/appservice.yaml")
check "pattern: dots are escaped" '[[ "$pattern" == "@bot_.*:chat\\.example\\.net" ]]'
match() { python3 -c 'import re,sys; sys.exit(0 if re.fullmatch(sys.argv[1], sys.argv[2]) else 1)' "$pattern" "$1"; }
check "pattern: matches a bot account" 'match "@bot_3f2a-9b:chat.example.net"'
check "pattern: not a person" '! match "@alice:chat.example.net"'
check "pattern: not another server" '! match "@bot_x:chatXexample.net" && ! match "@bot_x:other.example.net"'
if python3 -c 'import yaml' 2>/dev/null; then
  check "file is valid YAML with the expected keys" 'python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); assert d[\"id\"]==\"universe-bots\" and d[\"namespaces\"][\"users\"][0][\"exclusive\"] is True" "$d/appservice.yaml"'
  check "homeserver.yaml still parses and lists the file" 'python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); assert d[\"app_service_config_files\"]==[sys.argv[2]]" "$d/homeserver.yaml" "$d/appservice.yaml"'
else
  echo "skip - PyYAML is not installed, YAML parse checks not run"
fi

# 4. A second start with the same values (homeserver.yaml is regenerated at every start): still one line
printf 'server_name: "chat.example.net"\n' > "$d/homeserver.yaml"
run_case "$d" "${ENV_OK[@]}" > /dev/null
check "restart: one line again, not two" '[[ "$(grep -c "^app_service_config_files:" "$d/homeserver.yaml")" == "1" ]]'

# 5. Unset after being set: file removed, line absent from the freshly generated homeserver.yaml
printf 'server_name: "chat.example.net"\n' > "$d/homeserver.yaml"
run_case "$d" SYNAPSE_SERVER_NAME=chat.example.net > /dev/null
check "unset later: registration file removed" '[[ ! -e "$d/appservice.yaml" ]]'
check "unset later: no line in homeserver.yaml" '! grep -q app_service_config_files "$d/homeserver.yaml"'

# 6. Values that are not usable: warn, write nothing, never stop chat (exit code 0)
bad() { # name expected-text VAR=value...
  local name="$1" text="$2"; shift 2
  local dir="$TMP/bad-$name"
  local result rc
  result=$(run_case "$dir" "$@"); rc=$?
  check "bad ($name): exit code 0" '[[ "$rc" == "0" ]]'
  check "bad ($name): warns that it stays off" '[[ "$result" == *"WARNING: Bot direct messages stay off"* && "$result" == *"$text"* ]]'
  check "bad ($name): no file, no line" '[[ ! -e "$dir/appservice.yaml" ]] && ! grep -q app_service_config_files "$dir/homeserver.yaml"'
}
bad missing-url "must all be set" SYNAPSE_SERVER_NAME=chat.example.net "BOT_APPSERVICE_AS_TOKEN=$AS" "BOT_APPSERVICE_HS_TOKEN=$HS"
bad missing-token "must all be set" SYNAPSE_SERVER_NAME=chat.example.net BOT_APPSERVICE_URL=http://bot-server:3001 "BOT_APPSERVICE_AS_TOKEN=$AS"
bad url-with-path "no path" SYNAPSE_SERVER_NAME=chat.example.net BOT_APPSERVICE_URL=http://bot-server:3001/x "BOT_APPSERVICE_AS_TOKEN=$AS" "BOT_APPSERVICE_HS_TOKEN=$HS"
bad url-with-quote "no path" SYNAPSE_SERVER_NAME=chat.example.net "BOT_APPSERVICE_URL=http://bot-server:3001'; evil: 1" "BOT_APPSERVICE_AS_TOKEN=$AS" "BOT_APPSERVICE_HS_TOKEN=$HS"
bad short-token "at least 32" SYNAPSE_SERVER_NAME=chat.example.net BOT_APPSERVICE_URL=http://bot-server:3001 BOT_APPSERVICE_AS_TOKEN=short "BOT_APPSERVICE_HS_TOKEN=$HS"
bad token-with-newline "at least 32" SYNAPSE_SERVER_NAME=chat.example.net BOT_APPSERVICE_URL=http://bot-server:3001 "BOT_APPSERVICE_AS_TOKEN=$AS
evil: 1" "BOT_APPSERVICE_HS_TOKEN=$HS"
bad same-tokens "must differ" SYNAPSE_SERVER_NAME=chat.example.net BOT_APPSERVICE_URL=http://bot-server:3001 "BOT_APPSERVICE_AS_TOKEN=$AS" "BOT_APPSERVICE_HS_TOKEN=$AS"
bad odd-server-name "plain host name" "SYNAPSE_SERVER_NAME=chat.example.net'x" BOT_APPSERVICE_URL=http://bot-server:3001 "BOT_APPSERVICE_AS_TOKEN=$AS" "BOT_APPSERVICE_HS_TOKEN=$HS"

# 7. homeserver.yaml already sets app_service_config_files: do not add a second key
d="$TMP/dup"; mkdir -p "$d"
printf 'server_name: "chat.example.net"\napp_service_config_files:\n  - /data/other.yaml\n' > "$d/homeserver.yaml"
out=$(run_case "$d" "${ENV_OK[@]}")
check "existing key: warns and stays off" '[[ "$out" == *"already sets app_service_config_files"* ]]'
check "existing key: left as it was" '[[ "$(grep -c "^app_service_config_files:" "$d/homeserver.yaml")" == "1" && ! -e "$d/appservice.yaml" ]]'

# 8. The wiring: the image copies the file and the entrypoint runs it after the permissions change
check "Dockerfile copies appservice.sh" 'grep -q "COPY appservice.sh /appservice.sh" "$HERE/Dockerfile"'
check "entrypoint runs it after chmod" '[[ "$(grep -n "chmod -R 755 /data" "$HERE/entrypoint.sh" | head -1 | cut -d: -f1)" -lt "$(grep -n "configure_bot_appservice$" "$HERE/entrypoint.sh" | head -1 | cut -d: -f1)" ]]'

echo
echo "$CASES checks, $FAILED failed"
[[ "$FAILED" == "0" ]]
