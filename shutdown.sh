#!/usr/bin/env bash
# =============================================================================
# hardclaw-omni shutdown.sh
# Clean, ordered teardown of the sandbox. Preserves state so it can be restarted.
#
# Stops ONLY the NemoClaw sandbox container. The external vLLM inference server
# (qwen3.6-35b-a3b-dflash, owned by its own project) and SearXNG are Docker
# unless-stopped containers owned by other projects — this script leaves them
# running. To free their memory, stop them from their own projects.
#
# Usage:
#   bash shutdown.sh                    # Stop the sandbox container
#   bash shutdown.sh --sandbox-name X   # Custom sandbox name
# =============================================================================

set -euo pipefail

ENV_FILE="${HOME}/.nemoclaw.env"
[[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a

SANDBOX_NAME="${SANDBOX_NAME:-my-assistant}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sandbox-name)   SANDBOX_NAME="$2"; shift 2 ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; BOLD='\033[1m'; NC='\033[0m'

_log() { echo -e "$*"; }
info() { _log "${BLUE}[shutdown]${NC} $*"; }
ok()   { _log "  ${GREEN}✓${NC} $*"; }
warn() { _log "  ${YELLOW}!${NC} $*"; }

export PATH="${HOME}/.npm-global/bin:${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin"
NEMOCLAW=$(command -v nemoclaw 2>/dev/null || echo "${HOME}/.local/bin/nemoclaw")

info "Shutting down hardclaw-omni stack (sandbox: ${SANDBOX_NAME})"

# 1. Stop Telegram bridge and auxiliary services
info "Stopping auxiliary services (Telegram bridge, tunnel)..."
"$NEMOCLAW" stop 2>/dev/null && ok "Auxiliary services stopped" || warn "nemoclaw stop reported an error (may be okay)"

# 2. Graceful shutdown of the sandbox container (30s drain). The container is
#    named openshell-<sandbox-name>-<uuid> (embedded k3s; not a shared cluster).
info "Stopping sandbox container..."
CONTAINER=$(docker ps --filter "name=openshell-${SANDBOX_NAME}-" --format '{{.Names}}' 2>/dev/null | head -1 || true)
if [[ -n "$CONTAINER" ]]; then
    docker stop --time 30 "$CONTAINER" 2>/dev/null && \
        ok "Sandbox container '${CONTAINER}' stopped" || \
        warn "Stop failed — it may already be stopped"
else
    ok "Sandbox container: already stopped"
fi

# Note: the external vLLM (qwen3.6-35b-a3b-dflash) and SearXNG are owned by their
# own projects and are intentionally left running. Stop them from those projects
# if you need to free their memory.

info "Shutdown complete."
info "To restart: sudo systemctl start nemoclaw-sandbox.service"
info "           (or: bash install.sh to do a fresh deploy)"
