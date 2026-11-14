#!/usr/bin/env bash
# setup-webui.sh: Deploys the Open WebUI + SearXNG stack using Docker Compose.

set -euo pipefail

# ==============================================================================
# LOGGING & ERROR HANDLING
# ==============================================================================
log() {
    echo -e "\n\033[1;32m==>\033[0m \033[1m$*\033[0m"
}

warn() {
    echo -e "\033[1;33m[WARN]\033[0m $*" >&2
}

err() {
    echo -e "\033[1;31m[ERROR]\033[0m $*" >&2
    exit 1
}

# ==============================================================================
# LOAD CONFIGURATION
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG_FILE="${REPO_ROOT}/config.env"

if [[ -f "$CONFIG_FILE" ]]; then
    log "Loading configuration from $CONFIG_FILE"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
else
    err "Configuration file config.env not found in ${REPO_ROOT}."
fi

# ==============================================================================
# PRE-FLIGHT CHECKS
# ==============================================================================
log "Running pre-flight checks..."

if ! command -v docker >/dev/null 2>&1; then
    err "Docker is not installed. Please install Docker before running this script."
fi

if ! docker compose version >/dev/null 2>&1; then
    err "Docker Compose plugin is not installed. Please install it before running this script."
fi

# ==============================================================================
# DEPLOYMENT
# ==============================================================================
log "Deploying the 'ai-server' stack (Open WebUI + SearXNG)..."

cd "${REPO_ROOT}"
docker compose -f docker-compose.ai.yml --env-file "$CONFIG_FILE" up -d

# ==============================================================================
# POST-DEPLOYMENT STATUS
# ==============================================================================
log "Waiting for containers to initialize..."
sleep 5

log "Deployment complete!"
echo "----------------------------------------------------------------"
echo "  Open WebUI: Listening on port ${OPENWEBUI_PORT}"
echo "  SearXNG:    Listening on port ${SEARXNG_PORT}"
echo "----------------------------------------------------------------"
