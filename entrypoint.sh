#!/bin/bash
set -e

echo "Starting Matrix Synapse entrypoint..."

# Check if all required environment variables are set
REQUIRED_VARS=(
  "SYNAPSE_SERVER_NAME"
  "SYNAPSE_PUBLIC_BASEURL"
  "POSTGRES_HOST"
  "POSTGRES_USER"
  "POSTGRES_PASSWORD"
  "POSTGRES_DATABASE"
  "SYNAPSE_REGISTRATION_SHARED_SECRET"
  "SYNAPSE_MACAROON_SECRET_KEY"
  "SYNAPSE_FORM_SECRET"
  "AUTHENTIK_ISSUER"
  "AUTHENTIK_CLIENT_ID"
  "AUTHENTIK_CLIENT_SECRET"
)

# S3 variables are optional (commented out S3 storage for now)
# "S3_BUCKET_NAME"
# "S3_REGION"
# "S3_ACCESS_KEY_ID"
# "S3_SECRET_ACCESS_KEY"
# "S3_ENDPOINT_URL"
)

MISSING_VARS=()
for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var}" ]]; then
    MISSING_VARS+=("$var")
  fi
done

if [[ ${#MISSING_VARS[@]} -ne 0 ]]; then
  echo "ERROR: Missing required environment variables:"
  printf '  - %s\n' "${MISSING_VARS[@]}"
  exit 1
fi

# Set default for POSTGRES_PORT if not provided
export POSTGRES_PORT=${POSTGRES_PORT:-5432}

# Generate homeserver.yaml from template
echo "Generating homeserver.yaml from template..."
envsubst < /data/homeserver.yaml.template > /data/homeserver.yaml

# Verify the generated config is valid
if [[ ! -f /data/homeserver.yaml ]]; then
  echo "ERROR: Failed to generate homeserver.yaml"
  exit 1
fi

echo "Configuration generated successfully"

# Generate log config if it doesn't exist
LOG_CONFIG="/data/${SYNAPSE_SERVER_NAME}.log.config"
if [[ ! -f "$LOG_CONFIG" ]]; then
  echo "Creating log configuration..."
  cat > "$LOG_CONFIG" << 'EOF'
version: 1

formatters:
    precise:
        format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(request)s - %(message)s'

handlers:
    file:
        class: logging.handlers.TimedRotatingFileHandler
        formatter: precise
        filename: /data/homeserver.log
        when: midnight
        backupCount: 3
        encoding: utf8

    buffer:
        class: synapse.logging.handlers.PeriodicallyFlushingMemoryHandler
        target: file
        capacity: 10
        flushLevel: 30
        period: 5

    console:
        class: logging.StreamHandler
        formatter: precise

loggers:
    synapse.storage.SQL:
        level: INFO

root:
    level: INFO
    handlers: [buffer, console]

disable_existing_loggers: false
EOF
fi

# Generate signing key if it doesn't exist
SIGNING_KEY="/data/${SYNAPSE_SERVER_NAME}.signing.key"
if [[ ! -f "$SIGNING_KEY" ]]; then
  echo "Generating signing key..."
  # Generate only the signing key, don't regenerate config
  python -m synapse.app.homeserver \
    --config-path /data/homeserver.yaml \
    --generate-keys \
    --report-stats=no || {
    echo "Warning: Signing key generation may have failed, but continuing..."
  }
fi

# Ensure proper permissions
chmod -R 755 /data

# Note: Database migrations are handled automatically by Synapse on startup
# Synapse will wait for the database and run migrations as needed

# Database migrations are handled automatically by Synapse on startup
# No need to run them separately

# Create admin user if provided
if [[ -n "${MATRIX_ADMIN_USER}" ]] && [[ -n "${MATRIX_ADMIN_PASSWORD}" ]]; then
  echo "Creating admin user..."
  register_new_matrix_user -c /data/homeserver.yaml \
    -u "${MATRIX_ADMIN_USER}" \
    -p "${MATRIX_ADMIN_PASSWORD}" \
    -a || echo "Admin user may already exist, skipping..."
fi

# Start Synapse
echo "Starting Synapse..."
echo "Server name: ${SYNAPSE_SERVER_NAME}"
echo "Public base URL: ${SYNAPSE_PUBLIC_BASEURL}"
echo "Database host: ${POSTGRES_HOST}"
echo "Starting Synapse server..."

# Start Synapse in foreground
exec python -m synapse.app.homeserver --config-path /data/homeserver.yaml

