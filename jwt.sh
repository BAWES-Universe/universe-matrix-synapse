#!/bin/bash
# JWT sign-in settings for the generated homeserver.yaml. Sourced by entrypoint.sh; tested by tests/jwt_test.sh.

# Sets JWT_SECRET_YAML to JWT_SECRET written for a double-quoted YAML text, so a backslash or a quote in the secret
# reaches Synapse as it was typed. A secret with a line break or another control character cannot be written that
# way and stops the start. Run before envsubst.
prepare_jwt_secret() {
  local secret="${JWT_SECRET:-}"
  if [[ "$secret" =~ [[:cntrl:]] ]]; then
    echo "ERROR: JWT_SECRET contains a line break or control character; use a secret without one"
    return 1
  fi
  secret="${secret//\\/\\\\}"
  secret="${secret//\"/\\\"}"
  export JWT_SECRET_YAML="$secret"
}

# Leaves the jwt_config block out of the generated file unless JWT_SECRET is set, so the sign-in by JWT is off
# without a secret instead of checking against a made-up one. Fails when the block is still there afterwards.
apply_jwt_config() {
  local file="$1"
  if [[ -n "${JWT_SECRET:-}" ]]; then
    echo "JWT sign-in: on"
    return 0
  fi
  if ! awk 'skip && /^[[:space:]]/ { next } { skip = 0 } /^jwt_config:/ { skip = 1; next } { print }' "$file" > "$file.tmp" \
    || ! mv "$file.tmp" "$file"; then
    echo "ERROR: could not leave the JWT sign-in out of $file"
    return 1
  fi
  if grep -q '^jwt_config:' "$file"; then
    echo "ERROR: $file still has jwt_config without a JWT_SECRET"
    return 1
  fi
  echo "JWT sign-in: off (JWT_SECRET not set)"
}

# envsubst only knows ${NAME}: a placeholder in any other form (${NAME:-default}) is copied into the file as text.
# Stops the start instead of running with it.
reject_unrendered() {
  local file="$1" lines
  # shellcheck disable=SC2016  # the pattern is a literal dollar-brace
  lines=$(grep -n '\${' "$file" | cut -d: -f1 | paste -sd, -)
  if [[ -n "$lines" ]]; then
    echo "ERROR: $file still holds placeholder text at line(s) $lines: envsubst only fills \${NAME}"
    return 1
  fi
}
