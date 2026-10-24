#!/bin/bash
# JWT sign-in settings for the generated homeserver.yaml. Sourced by entrypoint.sh; tested by tests/jwt_test.sh.

# Leaves the jwt_config block out of the generated file unless JWT_SECRET is set, so the sign-in by JWT is off
# without a secret instead of checking against a made-up one.
apply_jwt_config() {
  local file="$1"
  if [[ -n "${JWT_SECRET:-}" ]]; then
    echo "JWT sign-in: on"
    return 0
  fi
  awk 'skip && /^[[:space:]]/ { next } { skip = 0 } /^jwt_config:/ { skip = 1; next } { print }' "$file" > "$file.tmp" \
    && mv "$file.tmp" "$file"
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
