# Pinned to the version prod runs: a rebuild (new variable, redeploy) must not also upgrade Synapse.
# Upgrade on purpose by changing this tag, after reading the Synapse release notes.
FROM matrixdotorg/synapse:v1.160.0

# Install gettext-base for envsubst and pip for S3 storage provider
RUN apt-get update && apt-get install -y gettext-base && rm -rf /var/lib/apt/lists/*

# Install S3 storage provider for Synapse
RUN pip install --no-cache-dir synapse-s3-storage-provider==1.7.0

# Create data directory
RUN mkdir -p /data

# Copy configuration template and entrypoint script
COPY homeserver.yaml.template /data/homeserver.yaml.template
COPY entrypoint.sh /entrypoint.sh
COPY appservice.sh /appservice.sh
COPY jwt.sh /jwt.sh
RUN chmod +x /entrypoint.sh /appservice.sh /jwt.sh

# Set working directory
WORKDIR /data

# Expose Synapse port
EXPOSE 8008

# Health check for Railway
# Using the standard Matrix client versions endpoint
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=5 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8008/_matrix/client/versions')" || exit 1

# Use custom entrypoint
ENTRYPOINT ["/entrypoint.sh"]

