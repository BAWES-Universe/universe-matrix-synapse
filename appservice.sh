#!/bin/bash
# Bot direct messages: registers the Universe bot server with Synapse as a Matrix application service.
#
# Sourced by entrypoint.sh after homeserver.yaml has been generated. Everything comes from three variables, so a
# restart, a redeploy and a fresh install end with the same result and nothing is edited by hand on the server:
#
#   BOT_APPSERVICE_URL       where Synapse reaches the bot server, e.g. http://bot-server:3001
#   BOT_APPSERVICE_AS_TOKEN  the token the bot server sends to Synapse (the bot server's MATRIX_AS_TOKEN)
#   BOT_APPSERVICE_HS_TOKEN  the token Synapse sends to the bot server (the bot server's MATRIX_HS_TOKEN)
#
# None set: bot direct messages are off, no file is written and a file left from an earlier run is removed.
# Some missing or a value that is not valid: a warning, and the same as none set. Chat itself is never stopped by this.

APPSERVICE_FILE="${APPSERVICE_FILE:-/data/appservice-universe-bots.yaml}"
HOMESERVER_FILE="${HOMESERVER_FILE:-/data/homeserver.yaml}"

# Why the variables are not usable, or nothing when they are. Values are never printed (they hold secrets).
bot_appservice_problem() {
  local url="${BOT_APPSERVICE_URL:-}" as="${BOT_APPSERVICE_AS_TOKEN:-}" hs="${BOT_APPSERVICE_HS_TOKEN:-}"
  local server_name="${SYNAPSE_SERVER_NAME:-}"
  [[ -n "$url" && -n "$as" && -n "$hs" ]] || { echo "BOT_APPSERVICE_URL, BOT_APPSERVICE_AS_TOKEN and BOT_APPSERVICE_HS_TOKEN must all be set"; return; }
  [[ "$url" =~ ^https?://[A-Za-z0-9._-]+(:[0-9]{1,5})?$ ]] || { echo "BOT_APPSERVICE_URL must look like http://bot-server:3001 (no path)"; return; }
  [[ "$as" =~ ^[A-Za-z0-9._~-]{32,}$ ]] || { echo "BOT_APPSERVICE_AS_TOKEN must be at least 32 letters, digits or . _ ~ -"; return; }
  [[ "$hs" =~ ^[A-Za-z0-9._~-]{32,}$ ]] || { echo "BOT_APPSERVICE_HS_TOKEN must be at least 32 letters, digits or . _ ~ -"; return; }
  [[ "$as" != "$hs" ]] || { echo "BOT_APPSERVICE_AS_TOKEN and BOT_APPSERVICE_HS_TOKEN must differ"; return; }
  [[ "$server_name" =~ ^[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] || { echo "SYNAPSE_SERVER_NAME is not a plain host name"; return; }
}

configure_bot_appservice() {
  local any=""
  [[ -n "${BOT_APPSERVICE_URL:-}${BOT_APPSERVICE_AS_TOKEN:-}${BOT_APPSERVICE_HS_TOKEN:-}" ]] && any=1

  if [[ -z "$any" ]]; then
    rm -f "$APPSERVICE_FILE"
    echo "Bot direct messages: off (BOT_APPSERVICE_* not set)"
    return 0
  fi

  local problem
  problem="$(bot_appservice_problem)"
  if [[ -n "$problem" ]]; then
    rm -f "$APPSERVICE_FILE"
    echo "WARNING: Bot direct messages stay off: $problem"
    return 0
  fi

  if grep -q '^app_service_config_files:' "$HOMESERVER_FILE"; then
    rm -f "$APPSERVICE_FILE"
    echo "WARNING: Bot direct messages stay off: homeserver.yaml already sets app_service_config_files, add the bot file to it by hand"
    return 0
  fi

  # Only this server's bot accounts (@bot_<id>:<server name>), claimed exclusively. Dots are escaped for the pattern.
  local namespace="${SYNAPSE_SERVER_NAME//./\\.}"
  ( umask 077
    cat > "$APPSERVICE_FILE" <<YAML
id: universe-bots
url: ${BOT_APPSERVICE_URL}
as_token: ${BOT_APPSERVICE_AS_TOKEN}
hs_token: ${BOT_APPSERVICE_HS_TOKEN}
sender_localpart: universe-bots
rate_limited: false
namespaces:
  users:
    - exclusive: true
      regex: '@bot_.*:${namespace}'
  aliases: []
  rooms: []
YAML
  )
  chmod 600 "$APPSERVICE_FILE"

  cat >> "$HOMESERVER_FILE" <<YAML

# Bot direct messages (appservice.sh)
app_service_config_files:
  - ${APPSERVICE_FILE}
YAML
  echo "Bot direct messages: on, bot server at ${BOT_APPSERVICE_URL}"
}
