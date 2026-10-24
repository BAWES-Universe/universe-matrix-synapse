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
# None set: bot direct messages are off, no file is written and a file left from an earlier run is removed (unless
# homeserver.yaml still points at it, then it stays, so Synapse can always start).
# Some missing or a value that is not valid: a warning, and the same as none set. Chat itself is never stopped by this,
# not even when a file cannot be written: the file and the homeserver.yaml line are only added once both can be done.
# entrypoint.sh calls this as `configure_bot_appservice || echo WARNING`, which turns `set -e` off inside, so every step
# below checks its own result.

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

# Deletes the registration file from an earlier run, but never one that homeserver.yaml still points at: on a config
# that is not regenerated at every start, deleting it would leave Synapse unable to start.
drop_registration_file() {
  if [[ -e "$APPSERVICE_FILE" ]] && ! grep -qF -- "$APPSERVICE_FILE" "$HOMESERVER_FILE" 2>/dev/null; then
    rm -f "$APPSERVICE_FILE" || true
  fi
}

# Bot direct messages stay off; reason is printed without any value.
bot_appservice_off() {
  drop_registration_file
  echo "WARNING: Bot direct messages stay off: $1"
}

configure_bot_appservice() {
  local any=""
  [[ -n "${BOT_APPSERVICE_URL:-}${BOT_APPSERVICE_AS_TOKEN:-}${BOT_APPSERVICE_HS_TOKEN:-}" ]] && any=1

  if [[ -z "$any" ]]; then
    drop_registration_file
    echo "Bot direct messages: off (BOT_APPSERVICE_* not set)"
    return 0
  fi

  local problem
  problem="$(bot_appservice_problem)"
  if [[ -n "$problem" ]]; then
    bot_appservice_off "$problem"
    return 0
  fi

  if grep -q '^app_service_config_files:' "$HOMESERVER_FILE"; then
    # Whatever is there stays exactly as it is, including a registration file this script wrote earlier.
    echo "WARNING: Bot direct messages stay off: homeserver.yaml already sets app_service_config_files, add the bot file to it by hand"
    return 0
  fi

  # Only this server's bot accounts (@bot_<id>:<server name>), claimed exclusively. Dots are escaped for the pattern.
  local namespace="${SYNAPSE_SERVER_NAME//./\\.}"
  local reg_tmp hs_tmp
  reg_tmp="$(mktemp "${APPSERVICE_FILE}.XXXXXX" 2>/dev/null)" || { bot_appservice_off "cannot write ${APPSERVICE_FILE}"; return 0; }
  # mktemp creates the file private (mode 600); the tokens are only ever written into it.
  cat > "$reg_tmp" <<YAML || { rm -f "$reg_tmp"; bot_appservice_off "cannot write ${APPSERVICE_FILE}"; return 0; }
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
  if ! { chmod 600 "$reg_tmp" && mv -f "$reg_tmp" "$APPSERVICE_FILE"; }; then
    rm -f "$reg_tmp"
    bot_appservice_off "cannot write ${APPSERVICE_FILE}"
    return 0
  fi

  # homeserver.yaml is replaced in one step (copy, append, rename), so it never holds a half-written line, and the
  # line is only added after the file it names exists.
  hs_tmp="$(mktemp "${HOMESERVER_FILE}.XXXXXX" 2>/dev/null)" || { drop_registration_file; echo "WARNING: Bot direct messages stay off: cannot update ${HOMESERVER_FILE}"; return 0; }
  if ! {
    {
      cat "$HOMESERVER_FILE" &&
      printf '\n# Bot direct messages (appservice.sh)\napp_service_config_files:\n  - %s\n' "$APPSERVICE_FILE"
    } > "$hs_tmp" &&
      chmod --reference="$HOMESERVER_FILE" "$hs_tmp" &&
      mv -f "$hs_tmp" "$HOMESERVER_FILE"
  }; then
    rm -f "$hs_tmp"
    drop_registration_file
    echo "WARNING: Bot direct messages stay off: cannot update ${HOMESERVER_FILE}"
    return 0
  fi
  echo "Bot direct messages: on, bot server at ${BOT_APPSERVICE_URL}"
}
