# Production Matrix Synapse on Railway

This repository contains a production-ready Matrix Synapse server configuration for deployment on Railway with PostgreSQL and Authentik OIDC authentication.

## Features

- Production-ready Synapse configuration
- PostgreSQL database support
- S3 storage for media files (scalable and cost-effective)
- Authentik OIDC authentication integration
- No guest access (security best practice)
- Registration only through OIDC (no public registration)
- Admin user management
- Health checks for Railway
- Automatic database migrations
- Proper logging configuration

## Prerequisites

- Railway account
- Authentik instance with OIDC provider configured
- Domain name pointing to Railway (chat.bawes.net)

## Railway Setup

### 1. Create a New Project

1. Log in to [Railway](https://railway.app)
2. Create a new project
3. Add a PostgreSQL service to your project

### 2. Deploy Synapse Service

1. Add a new service from GitHub (or connect your repository)
2. Railway will automatically detect the Dockerfile
3. Configure the following environment variables (see `.env.example` for reference):

#### Required Environment Variables

**Server Configuration:**
- `SYNAPSE_SERVER_NAME` - Your Matrix server domain (e.g., `chat.bawes.net`)
- `SYNAPSE_PUBLIC_BASEURL` - Public URL (e.g., `https://chat.bawes.net/`)

**PostgreSQL Database:**
Railway will automatically provide these if you add a PostgreSQL service:
- `POSTGRES_HOST` - Database host
- `POSTGRES_PORT` - Database port (default: 5432)
- `POSTGRES_USER` - Database user
- `POSTGRES_PASSWORD` - Database password
- `POSTGRES_DATABASE` - Database name

**Synapse Secrets:**
Generate secure random strings for these (at least 32 characters):
```bash
# Generate secrets
openssl rand -base64 32  # For SYNAPSE_REGISTRATION_SHARED_SECRET
openssl rand -base64 32  # For SYNAPSE_MACAROON_SECRET_KEY
openssl rand -base64 32  # For SYNAPSE_FORM_SECRET
```

- `SYNAPSE_REGISTRATION_SHARED_SECRET` - Secret for admin user registration
- `SYNAPSE_MACAROON_SECRET_KEY` - Secret for access tokens
- `SYNAPSE_FORM_SECRET` - Secret for form submissions

**Authentik OIDC:**
- `AUTHENTIK_ISSUER` - OIDC issuer URL (e.g., `https://auth.bawes.net/application/o/universe-chat/`)
- `AUTHENTIK_CLIENT_ID` - OIDC client ID from Authentik
- `AUTHENTIK_CLIENT_SECRET` - OIDC client secret from Authentik

**Railway Bucket Storage (Required for media files):**
- `S3_BUCKET_NAME` - Your Railway bucket name
- `S3_REGION` - Region (can be any value, Railway buckets are region-agnostic, e.g., `us-east-1`)
- `S3_ACCESS_KEY_ID` - Access key from Railway bucket credentials
- `S3_SECRET_ACCESS_KEY` - Secret key from Railway bucket credentials
- `S3_ENDPOINT_URL` - **Required for Railway buckets** - Endpoint URL from Railway bucket credentials

**Optional:**
- `JWT_SECRET` - JWT secret for WorkAdventure integration (if needed)
- `MATRIX_ADMIN_USER` - Admin username (only used on first run)
- `MATRIX_ADMIN_PASSWORD` - Admin password (only used on first run)

### 3. Configure Domain

1. In Railway, go to your Synapse service settings
2. Add a custom domain: `chat.bawes.net`
3. Railway will provide SSL certificates automatically

### 4. Persistent Volume (Automatic - No Configuration Needed)

**Important:** Railway **automatically** provides persistent storage for the `/data` directory. **You do NOT need to manually create a volume** - Railway handles this automatically.

The persistent `/data` directory is **required** for:
- **Signing keys** (`/data/chat.bawes.net.signing.key`) - **CRITICAL**: Must be persistent. Losing this key will break federation with other Matrix servers.
- Logs and configuration files

**Note:** Media files are stored in Railway's bucket service (configured in step 5), so they don't require persistent volume storage. This makes the deployment more scalable and cost-effective.

### 5. Configure Railway Bucket Storage

Media files (images, videos, files) are stored in Railway's bucket service instead of local storage. This provides:
- Better scalability
- Lower costs for large media files
- Ability to share storage across multiple instances
- Integrated with Railway infrastructure

**Where to configure Railway Bucket:**

1. **Create a Railway Bucket:**
   - In your Railway project, right-click on the canvas (or click the "+" button)
   - Select **"Bucket"** from the service options
   - Choose your desired region
   - Railway will create the bucket and provide credentials automatically

2. **Get Bucket Credentials:**
   - Click on the bucket service in your Railway project
   - Go to the **"Credentials"** tab
   - You'll see the following values:
     - `BUCKET_NAME` - Your bucket name
     - `ACCESS_KEY_ID` - Access key
     - `SECRET_ACCESS_KEY` - Secret key
     - `ENDPOINT` - S3-compatible endpoint URL (this is important!)

3. **Set environment variables in Railway:**
   - Go to your **Synapse service** in Railway (not the bucket service)
   - Navigate to **Variables** tab
   - Add the bucket configuration variables:
     - `S3_BUCKET_NAME` - Copy from bucket's `BUCKET_NAME`
     - `S3_REGION` - Can be any value (e.g., `us-east-1`), Railway buckets are region-agnostic
     - `S3_ACCESS_KEY_ID` - Copy from bucket's `ACCESS_KEY_ID`
     - `S3_SECRET_ACCESS_KEY` - Copy from bucket's `SECRET_ACCESS_KEY`
     - `S3_ENDPOINT_URL` - **Required!** Copy from bucket's `ENDPOINT`

**Important:** Railway buckets use S3-compatible API, so you **must** set `S3_ENDPOINT_URL` with the endpoint value from your bucket's credentials.

## Authentik OIDC Configuration

### 1. Create OIDC Provider in Authentik

1. Go to Authentik admin panel
2. Navigate to Applications → Providers
3. Create a new OIDC/OpenID Provider:
   - **Name**: Matrix Synapse
   - **Authorization flow**: Use default or create custom flow
   - **Redirect URIs**: `https://chat.bawes.net/_synapse/client/oidc/callback`
   - **Scopes**: `openid`, `email`, `profile`

### 2. Create OIDC Application

1. Navigate to Applications → Applications
2. Create a new application:
   - **Name**: Matrix Synapse
   - **Provider**: Select the provider created above
   - **Launch URL**: `https://chat.bawes.net`

### 3. Get Client Credentials

1. Copy the **Client ID** and **Client Secret** from the provider
2. Set them as `AUTHENTIK_CLIENT_ID` and `AUTHENTIK_CLIENT_SECRET` in Railway

## Admin User Management

The admin user is created automatically on first run if `MATRIX_ADMIN_USER` and `MATRIX_ADMIN_PASSWORD` are set. After the first run, you can:

1. Remove these environment variables (optional)
2. Use the admin user to manage the server through the WorkAdventure repository
3. Create additional admin users via the Matrix CLI:
   ```bash
   register_new_matrix_user -c /data/homeserver.yaml -u username -p password -a
   ```

## Security Features

- **No guest access**: Guests cannot access rooms
- **No public registration**: Users can only register through OIDC
- **Rate limiting**: Production-grade rate limiting on all endpoints
- **Secure secrets**: All secrets managed via environment variables
- **TLS termination**: Handled by Railway
- **Database connection pooling**: Optimized PostgreSQL connections

## Monitoring

The server exposes metrics on port 9090 (internal). Railway health checks use the `/_matrix/client/versions` endpoint.

## Troubleshooting

### Database Connection Issues

- Verify PostgreSQL service is running in Railway
- Check that all database environment variables are set correctly
- Ensure the database exists (Railway creates it automatically)

### OIDC Authentication Not Working

- Verify `AUTHENTIK_ISSUER`, `AUTHENTIK_CLIENT_ID`, and `AUTHENTIK_CLIENT_SECRET` are correct
- Check that the redirect URI in Authentik matches: `https://chat.bawes.net/_synapse/client/oidc/callback`
- Ensure the OIDC provider has the correct scopes: `openid`, `email`, `profile`

### Signing Key Issues

The signing key is automatically generated on first run. If you need to regenerate it, delete the key file in the persistent volume and restart the service.

**Important:** Never delete or lose your signing key! It's stored in the persistent volume at `/data/chat.bawes.net.signing.key`. Losing this key will break federation with other Matrix servers.

### Railway Bucket Storage Issues

- **Media uploads failing**: Check that your Railway bucket exists and is connected to the same project
- **Access denied errors**: Verify `S3_ACCESS_KEY_ID` and `S3_SECRET_ACCESS_KEY` are correct (copy from bucket's Credentials tab)
- **Connection errors**: Ensure `S3_ENDPOINT_URL` is set correctly - this is **required** for Railway buckets
- **Missing endpoint**: Railway buckets require `S3_ENDPOINT_URL` to be set - get this from the bucket's Credentials tab

## Local Development

For local testing, you can use Docker Compose:

```bash
docker-compose up
```

Make sure to set all environment variables in a `.env` file (see `.env.example`).

## Additional Resources

- [Synapse Documentation](https://matrix-org.github.io/synapse/latest/)
- [Railway Documentation](https://docs.railway.app/)
- [Authentik Documentation](https://goauthentik.io/docs/)

## License

This configuration is provided as-is for production use.

