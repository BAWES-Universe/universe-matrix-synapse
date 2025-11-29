FROM matrixdotorg/synapse:latest

# Install gettext-base for envsubst
RUN apt-get update && apt-get install -y gettext-base && rm -rf /var/lib/apt/lists/*

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
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8008/_matrix/client/versions')" || exit 1

# Use custom entrypoint
ENTRYPOINT ["/entrypoint.sh"]

