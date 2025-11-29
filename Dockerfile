FROM matrixdotorg/synapse:latest

# Install gettext-base for envsubst and pip for S3 storage provider
RUN apt-get update && apt-get install -y gettext-base && rm -rf /var/lib/apt/lists/*

# Install S3 storage provider for Synapse
RUN pip install --no-cache-dir synapse-s3-storage-provider

# Create data directory
RUN mkdir -p /data

# Copy configuration template and entrypoint script
COPY homeserver.yaml.template /data/homeserver.yaml.template
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Set working directory
WORKDIR /data

# Expose Synapse port
EXPOSE 8008

# Health check for Railway
# Using /health endpoint which is simpler and more reliable
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8008/health')" || exit 1

# Use custom entrypoint
ENTRYPOINT ["/entrypoint.sh"]

