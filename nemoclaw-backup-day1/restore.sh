#!/usr/bin/env bash
# =============================================================================
# nemoclaw-backup-day1 / restore.sh
#
# Restores the hardclaw-omni "the-king" NemoClaw agent to its known-good day-1
# state: openclaw.json (toolSearch off, SearXNG provider), the L7 sandbox policy
# (searxng_local with rest + allowed_ips), the workspace bootstrap files, the
# meal-planner skill, agent memory, and the reboot-survival systemd units.
#
# PREREQUISITE: a working, already-onboarded "the-king" sandbox must exist
# (the openshell-the-king-* container is present and the OpenShell gateway is
# reachable). This script OVERLAYS the known-good config onto it — it never
# onboards or recreates the sandbox. For a truly blank machine, run the repo's
# install.sh first to onboard the sandbox, then run this to restore the config.
#
# Usage:
#   bash restore.sh            # interactive (asks for confirmation)
#   bash restore.sh --yes      # non-interactive
#
# Needs: docker access (democenter is in the docker group) + sudo (for the
# systemd files under /usr/local/bin and /etc/systemd/system).
# =============================================================================
set -euo pipefail

SANDBOX="the-king"
HOME_DIR="/home/democenter"
BK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC="$BK/sandbox-config"
NEMOCLAW="${HOME_DIR}/.local/bin/nemoclaw"
OPENSHELL="${HOME_DIR}/.local/bin/openshell"
SANDBOX_DIR="/sandbox/.openclaw"

export PATH="${HOME_DIR}/.npm-global/bin:${HOME_DIR}/.local/bin:/usr/local/bin:/usr/bin:/bin"

GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; BOLD=$'\e[1m'; NC=$'\e[0m'
ok()   { echo "${GREEN}✓${NC} $*"; }
info() { echo "  $*"; }
warn() { echo "${YELLOW}⚠${NC}  $*"; }
die()  { echo "${RED}✗ $*${NC}" >&2; exit 1; }
step() { echo; echo "${BOLD}— $*${NC}"; }

ASSUME_YES=0
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && ASSUME_YES=1

echo "${BOLD}hardclaw-omni — restore the-king to day-1 known-good state${NC}"
echo "Backup source: $BK"
if [[ "$ASSUME_YES" != 1 ]]; then
    echo
    warn "This OVERWRITES the live agent config, sandbox policy, workspace files,"
    warn "skills, memory, the systemd units, and ~/.nemoclaw.env (a timestamped"
    warn "copy of the current env is kept). The sandbox container will be restarted."
    read -r -p "Proceed? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || die "Aborted."
fi

# ---------------------------------------------------------------------------
step "Preflight"
# ---------------------------------------------------------------------------
command -v docker &>/dev/null || die "docker not found in PATH"
docker info &>/dev/null || die "Docker daemon not reachable (is it running, and are you in the docker group?)"
[[ -d "$SC" ]] || die "Backup payload missing: $SC"
[[ -f "$SC/openclaw.json" ]] || die "Backup is incomplete: $SC/openclaw.json not found"
python3 -c "import json,sys; json.load(open('$SC/openclaw.json'))" \
    || die "Backed-up openclaw.json is not valid JSON — refusing to restore"

# Ensure the OpenShell gateway daemon is up (auto-spawned by a CLI call) and the
# sandbox is known. This also gives us a clear error if it was never onboarded.
"$NEMOCLAW" "$SANDBOX" status &>/dev/null \
    || die "Sandbox '$SANDBOX' is not known to the gateway. Onboard it first (run install.sh) — this script does not onboard."

CONTAINER=$(docker ps -a --filter "name=openshell-${SANDBOX}-" --format '{{.Names}}' | head -1 || true)
[[ -n "$CONTAINER" ]] || die "No sandbox container 'openshell-${SANDBOX}-*' found. Onboard the sandbox first."
ok "Found sandbox container: $CONTAINER"

# ---------------------------------------------------------------------------
step "1/6 — Restore credentials (~/.nemoclaw.env)"
# ---------------------------------------------------------------------------
if [[ -f "$BK/secrets/nemoclaw.env" ]]; then
    if [[ -f "${HOME_DIR}/.nemoclaw.env" ]]; then
        bak="${HOME_DIR}/.nemoclaw.env.pre-restore.$(date +%Y%m%d_%H%M%S)"
        cp -a "${HOME_DIR}/.nemoclaw.env" "$bak"
        info "Existing env saved to $bak"
    fi
    cp "$BK/secrets/nemoclaw.env" "${HOME_DIR}/.nemoclaw.env"
    chmod 600 "${HOME_DIR}/.nemoclaw.env"
    ok "Restored ~/.nemoclaw.env (chmod 600)"
else
    warn "No secrets/nemoclaw.env in backup — skipping (Telegram may not work until env is set)"
fi

# ---------------------------------------------------------------------------
step "2/6 — Install systemd reboot-survival units"
# ---------------------------------------------------------------------------
sudo install -m 755 "$BK/systemd/nemoclaw-sandbox-start" /usr/local/bin/nemoclaw-sandbox-start
sudo install -m 755 "$BK/systemd/nemoclaw-sandbox-stop"  /usr/local/bin/nemoclaw-sandbox-stop
sudo install -m 644 "$BK/systemd/nemoclaw-sandbox.service" /etc/systemd/system/nemoclaw-sandbox.service
sudo touch /var/log/nemoclaw-sandbox-start.log /var/log/nemoclaw-sandbox-stop.log
sudo chmod 666 /var/log/nemoclaw-sandbox-start.log /var/log/nemoclaw-sandbox-stop.log
sudo systemctl daemon-reload
sudo systemctl reset-failed nemoclaw-sandbox.service 2>/dev/null || true
sudo systemctl enable nemoclaw-sandbox.service &>/dev/null || true
ok "Systemd units installed and enabled"

# ---------------------------------------------------------------------------
step "3/6 — Restore L7 sandbox policy (control plane)"
# ---------------------------------------------------------------------------
if [[ -f "$BK/policy/policy-active.yaml" ]]; then
    "$OPENSHELL" policy set "$SANDBOX" --policy "$BK/policy/policy-active.yaml" --yes \
        && ok "Policy submitted (searxng_local rest + allowed_ips, telegram_bot, etc.)" \
        || warn "Policy set returned non-zero — verify with: openshell policy get $SANDBOX --full"
else
    warn "No policy/policy-active.yaml in backup — skipping policy restore"
fi

# ---------------------------------------------------------------------------
step "4/6 — Restore in-sandbox config, skills, workspace and memory"
# ---------------------------------------------------------------------------
# Copy each artifact into the container, then fix ownership (docker cp lands as
# root) and recompute the integrity hash from the restored openclaw.json.
restore_into() {  # <local-path> <container-dest>
    local src="$1" dest="$2"
    [[ -e "$src" ]] || { info "skip (not in backup): $(basename "$src")"; return 0; }
    docker cp "$src" "${CONTAINER}:${dest}" && info "restored: $(basename "$src")"
}

restore_into "$SC/openclaw.json"        "$SANDBOX_DIR/openclaw.json"
restore_into "$SC/openclaw.json.last-good" "$SANDBOX_DIR/openclaw.json.last-good"
restore_into "$SC/exec-approvals.json"  "$SANDBOX_DIR/exec-approvals.json"
# Directory contents (the trailing /. merges contents into the existing dir)
for d in workspace plugin-skills memory cron hooks; do
    [[ -d "$SC/$d" ]] && docker cp "$SC/$d/." "${CONTAINER}:$SANDBOX_DIR/$d/" && info "restored dir: $d"
done

# Ownership: everything under the sandbox config tree must be sandbox:sandbox.
docker exec "$CONTAINER" chown -R sandbox:sandbox "$SANDBOX_DIR/openclaw.json" \
    "$SANDBOX_DIR/workspace" "$SANDBOX_DIR/plugin-skills" "$SANDBOX_DIR/memory" \
    "$SANDBOX_DIR/cron" "$SANDBOX_DIR/hooks" "$SANDBOX_DIR/exec-approvals.json" 2>/dev/null || true

# Recompute the integrity hash from the restored config (mutable-mode safe).
docker exec "$CONTAINER" sh -c "cd $SANDBOX_DIR && sha256sum openclaw.json > .config-hash && chown sandbox:sandbox .config-hash"
ok "Config, skills, workspace and memory restored; ownership fixed; hash recomputed"

# ---------------------------------------------------------------------------
step "5/6 — Restart sandbox container to apply restored config"
# ---------------------------------------------------------------------------
docker restart "$CONTAINER" >/dev/null
info "Waiting for the gateway to come back up..."
up=0
for i in $(seq 1 24); do
    sleep 5
    if [[ "$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" == "running" ]] \
       && docker exec "$CONTAINER" sh -c "grep -q 'http server listening' /tmp/gateway.log" &>/dev/null; then
        up=1; break
    fi
done
[[ "$up" == 1 ]] && ok "Gateway is up" || warn "Gateway not confirmed up after 2min — check: docker logs $CONTAINER"

# ---------------------------------------------------------------------------
step "6/6 — Verify"
# ---------------------------------------------------------------------------
ts=$(docker exec "$CONTAINER" sh -c "python3 -c \"import json;print(json.load(open('$SANDBOX_DIR/openclaw.json'))['tools']['toolSearch'])\"" 2>/dev/null || echo "?")
[[ "$ts" == "False" ]] && ok "toolSearch = False (tools presented directly)" || warn "toolSearch is '$ts' (expected False)"

crash=$(docker logs --since 3m "$CONTAINER" 2>&1 | grep -c 'L7 policy validation failed' || true)
[[ "$crash" == 0 ]] && ok "No L7 policy validation errors since restart" || warn "Saw $crash L7 policy errors — check the policy"

echo
ok "${BOLD}Restore complete.${NC}"
echo "  Verify web search + /meal-planner via Telegram. If Telegram doesn't resume,"
echo "  see README.md → 'Telegram token caveat'."
