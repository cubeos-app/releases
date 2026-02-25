#!/bin/bash
# =============================================================================
# cubeos-generate-secrets.sh — Generate unique secrets for this device
# =============================================================================
# Creates cryptographic secrets for JWT signing, API authentication, etc.
# Runs once on first boot. Secrets are stored in /cubeos/config/secrets.env
# and as Docker Swarm secrets.
# =============================================================================
set -euo pipefail

SECRETS_FILE="/cubeos/config/secrets.env"

echo "[SECRETS] Generating device-unique secrets..."

# Don't regenerate if secrets already exist
if [ -f "$SECRETS_FILE" ]; then
    echo "[SECRETS] Secrets file already exists. Skipping."
    exit 0
fi

mkdir -p "$(dirname "$SECRETS_FILE")"

# Generate random secrets
JWT_SECRET=$(openssl rand -hex 32)
API_SECRET=$(openssl rand -hex 32)
ENCRYPTION_KEY=$(openssl rand -hex 16)
SESSION_SECRET=$(openssl rand -hex 32)
HAL_CORE_KEY=$(openssl rand -hex 32)
PIHOLE_PASSWORD="cubeos"

cat > "$SECRETS_FILE" << EOF
# =============================================================================
# CubeOS Device Secrets — AUTO-GENERATED, DO NOT EDIT
# Generated at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# =============================================================================

CUBEOS_JWT_SECRET=${JWT_SECRET}
CUBEOS_API_SECRET=${API_SECRET}
CUBEOS_ENCRYPTION_KEY=${ENCRYPTION_KEY}
CUBEOS_SESSION_SECRET=${SESSION_SECRET}
CUBEOS_PIHOLE_PASSWORD=${PIHOLE_PASSWORD}

# HAL per-caller ACL key (used by cubeos-api to authenticate with HAL)
HAL_CORE_KEY=${HAL_CORE_KEY}
EOF

# ---------------------------------------------------------------------------
# Write HAL ACL configuration file
# ---------------------------------------------------------------------------
HAL_ACL_DIR="/cubeos/coreapps/cubeos-hal/appdata"
mkdir -p "$HAL_ACL_DIR"
cat > "${HAL_ACL_DIR}/acl.json" << EOF
{"keys":{"${HAL_CORE_KEY}":"core"}}
EOF
chmod 640 "${HAL_ACL_DIR}/acl.json"
echo "[SECRETS] HAL ACL config written to ${HAL_ACL_DIR}/acl.json"

# Restrict permissions — group-readable for docker group (gitlab-runner needs access for CI redeploys)
chmod 640 "$SECRETS_FILE"
chown root:docker "$SECRETS_FILE"

echo "[SECRETS] Secrets generated and saved to ${SECRETS_FILE}"

# ---------------------------------------------------------------------------
# Create Docker Swarm secrets (if Swarm is active)
# ---------------------------------------------------------------------------
if docker info 2>/dev/null | grep -q "Swarm: active"; then
    echo "[SECRETS] Creating Docker Swarm secrets..."

    echo -n "$JWT_SECRET" | docker secret create jwt_secret - 2>/dev/null || \
        echo "[SECRETS] jwt_secret already exists"

    echo -n "$API_SECRET" | docker secret create api_secret - 2>/dev/null || \
        echo "[SECRETS] api_secret already exists"
    
    echo "[SECRETS] Docker Swarm secrets created."
else
    echo "[SECRETS] Swarm not active yet. Secrets will be created during Swarm init."
fi
