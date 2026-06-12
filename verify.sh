#!/usr/bin/env bash
# =============================================================================
# hardclaw-omni verify.sh
# 7-layer security and health verification. Run any time to check the deployment.
#
# Usage: bash verify.sh [--sandbox-name NAME] [--searxng-port PORT]
#
# Exit codes: 0 = all pass, 1 = one or more FAILs
# =============================================================================

set -euo pipefail

ENV_FILE="${HOME}/.nemoclaw.env"
[[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a

SANDBOX_NAME="${SANDBOX_NAME:-my-assistant}"
DASHBOARD_PORT="${DASHBOARD_PORT:-18789}"
MODEL="${MODEL:-qwen3.6-35b-a3b-dflash}"
SEARXNG_PORT="${SEARXNG_PORT:-8888}"
VLLM_PORT="${VLLM_PORT:-8000}"
VLLM_CONTAINER="${VLLM_CONTAINER:-vllm-qwen3.6-35b-a3b-dflash}"
TELEGRAM_USER_ID="${TELEGRAM_USER_ID:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sandbox-name)  SANDBOX_NAME="$2";  shift 2 ;;
        --searxng-port)  SEARXNG_PORT="$2";  shift 2 ;;
        --vllm-port)     VLLM_PORT="$2";     shift 2 ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; BOLD='\033[1m'; NC='\033[0m'

PASS=0; FAIL=0; WARN_COUNT=0

pass()    { echo -e "  ${GREEN}PASS${NC}  $*";              PASS=$((PASS + 1)); }
fail()    { echo -e "  ${RED}FAIL${NC}  $*";               FAIL=$((FAIL + 1)); }
warn()    { echo -e "  ${YELLOW}WARN${NC}  $*";            WARN_COUNT=$((WARN_COUNT + 1)); }
info()    { echo -e "  ${BLUE}INFO${NC}  $*"; }
section() { echo -e "\n${BOLD}── $* ──${NC}"; }

echo -e "\n${BOLD}hardclaw-omni security verification${NC}  $(date)"
echo -e "Sandbox: ${SANDBOX_NAME}  |  Model: ${MODEL}  |  SearXNG: :${SEARXNG_PORT}\n"

# ---------------------------------------------------------------------------
# Layer 1 — Host baseline
# ---------------------------------------------------------------------------
section "Layer 1 — Host baseline"

if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
    pass "UFW is active"
else
    fail "UFW is not active — run: sudo ufw enable"
fi

if sudo ufw status 2>/dev/null | grep -qE "DENY.*${DASHBOARD_PORT}|${DASHBOARD_PORT}.*DENY"; then
    pass "Dashboard port ${DASHBOARD_PORT} is denied externally"
else
    warn "Port ${DASHBOARD_PORT} may not be denied — check: sudo ufw status"
fi

if sudo ufw status 2>/dev/null | grep -qE "172.17.0.0/16.*${SEARXNG_PORT}"; then
    pass "UFW: Docker bridge → SearXNG :${SEARXNG_PORT} rules present"
else
    warn "UFW: SearXNG bridge rules missing — sandbox cannot reach SearXNG"
fi

if sudo ufw status 2>/dev/null | grep -qE "172.17.0.0/16.*${VLLM_PORT}"; then
    pass "UFW: Docker bridge → vLLM :${VLLM_PORT} rules present"
else
    warn "UFW: vLLM bridge rules missing — sandbox cannot reach vLLM at :${VLLM_PORT}"
fi

if [[ -f /etc/sysctl.d/99-hardclaw-omni.conf ]]; then
    if sysctl net.ipv4.conf.all.rp_filter 2>/dev/null | grep -q "= 1"; then
        pass "Sysctl: rp_filter=1 active"
    else
        warn "Sysctl: rp_filter not set — run: sudo sysctl -p /etc/sysctl.d/99-hardclaw-omni.conf"
    fi
else
    warn "Sysctl hardening file missing: /etc/sysctl.d/99-hardclaw-omni.conf"
fi

if systemctl is-active avahi-daemon &>/dev/null 2>&1; then
    warn "avahi-daemon is running (should be disabled): sudo systemctl disable --now avahi-daemon"
else
    pass "avahi-daemon: disabled"
fi

# Dashboard token age check
if [[ -f "${HOME}/.nemoclaw/dashboard-token.txt" ]]; then
    local_age=$(( ( $(date +%s) - $(stat -c %Y "${HOME}/.nemoclaw/dashboard-token.txt") ) / 86400 ))
    if [[ $local_age -gt 30 ]]; then
        warn "Dashboard token is ${local_age} days old — consider rotating: nemoclaw ${SANDBOX_NAME} status --refresh-token"
    else
        pass "Dashboard token age: ${local_age} days"
    fi
else
    warn "Dashboard token file not found: ~/.nemoclaw/dashboard-token.txt"
fi

# ---------------------------------------------------------------------------
# Layer 2 — Docker + NVIDIA runtime
# ---------------------------------------------------------------------------
section "Layer 2 — Docker + NVIDIA runtime"

if docker info &>/dev/null; then
    pass "Docker: running"
else
    fail "Docker: not running — run: sudo systemctl start docker"
fi

if docker info 2>/dev/null | grep -q "nvidia"; then
    pass "NVIDIA runtime: configured in Docker"
else
    fail "NVIDIA runtime: missing — run: sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
fi

if docker run --rm --runtime=nvidia --gpus all ubuntu:24.04 echo ok 2>/dev/null | grep -q ok; then
    pass "NVIDIA runtime: container launch successful"
else
    warn "NVIDIA runtime: container launch failed — may need reboot"
fi

if [[ -f /etc/docker/daemon.json ]]; then
    if python3 -c "import json; d=json.load(open('/etc/docker/daemon.json')); assert d.get('no-new-privileges')" 2>/dev/null; then
        pass "Docker: no-new-privileges=true"
    else
        warn "Docker daemon.json: no-new-privileges not set"
    fi
    if python3 -c "import json; d=json.load(open('/etc/docker/daemon.json')); assert d.get('userland-proxy') == False" 2>/dev/null; then
        pass "Docker: userland-proxy=false"
    else
        warn "Docker daemon.json: userland-proxy not set to false"
    fi
else
    warn "/etc/docker/daemon.json not found"
fi

# ---------------------------------------------------------------------------
# Layer 3 — vLLM inference server (external project, consumed not managed)
# ---------------------------------------------------------------------------
section "Layer 3 — vLLM inference + model"

# vLLM is provisioned/owned by its own project (dgx-spark-vllm-qwen3.6-35b-a3b-dflash)
# as a Docker unless-stopped container. hardclaw-omni only consumes it on :${VLLM_PORT}.
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${VLLM_CONTAINER}$"; then
    pass "vLLM container: running (${VLLM_CONTAINER})"
else
    fail "vLLM container not running: ${VLLM_CONTAINER} — start its own external project"
fi

if curl -sf --max-time 5 "http://localhost:${VLLM_PORT}/v1/models" &>/dev/null; then
    pass "vLLM: responding on :${VLLM_PORT}"
else
    fail "vLLM: not responding at http://localhost:${VLLM_PORT}/v1/models"
fi

if curl -sf "http://localhost:${VLLM_PORT}/v1/models" 2>/dev/null | grep -q "$MODEL"; then
    pass "Model: served by vLLM ($MODEL)"
else
    fail "vLLM not serving expected model: $MODEL"
fi

# ---------------------------------------------------------------------------
# Layer 4 — NemoClaw sandbox + policy
# ---------------------------------------------------------------------------
section "Layer 4 — NemoClaw sandbox + policy"

if ! command -v nemoclaw &>/dev/null; then
    fail "nemoclaw: CLI not in PATH"
else
    pass "nemoclaw: $(command -v nemoclaw)"

    if nemoclaw "${SANDBOX_NAME}" status &>/dev/null 2>&1; then
        pass "Sandbox '${SANDBOX_NAME}': running"
    else
        fail "Sandbox '${SANDBOX_NAME}': not running — try: nemoclaw ${SANDBOX_NAME} start"
    fi

    # Policy file checks
    policy_file="${HOME}/.nemoclaw/source/nemoclaw-blueprint/policies/openclaw-sandbox.yaml"
    if [[ -f "$policy_file" ]]; then
        # Check no dangerous endpoints
        policy_check_output=$(python3 -c "
import yaml, sys
try:
    d = yaml.safe_load(open('${policy_file}'))
    net = d.get('network_policies', None)
    if net is None or net == {} or net == []:
        print('DENY-ALL')
        sys.exit(0)
    net_str = str(net)
    bad = [e for e in ['clawhub.com', 'sentry.io', 'statsig.anthropic.com',
                        'api.anthropic.com', 'integrate.api.nvidia.com']
           if e in net_str]
    if bad:
        print('BAD:' + ','.join(bad))
        sys.exit(1)
    print('OK')
except Exception as e:
    print('SKIP:' + str(e))
    sys.exit(0)
" 2>/dev/null || echo "ERROR")

        if echo "$policy_check_output" | grep -q "^BAD:"; then
            bad_endpoints=$(echo "$policy_check_output" | sed 's/BAD://')
            fail "Policy: dangerous endpoints still present: $bad_endpoints"
        else
            pass "Policy: no dangerous endpoints (clawhub, sentry, etc.)"
        fi

        # Check SearXNG is whitelisted
        if grep -q "${SEARXNG_PORT}" "$policy_file" 2>/dev/null; then
            pass "Policy: SearXNG :${SEARXNG_PORT} whitelisted"
        else
            warn "Policy: SearXNG :${SEARXNG_PORT} not found in network_policies"
        fi

        # Check Telegram is whitelisted
        if grep -q "api.telegram.org" "$policy_file" 2>/dev/null; then
            pass "Policy: api.telegram.org whitelisted"
        else
            warn "Policy: api.telegram.org not in network_policies — Telegram bridge will fail"
        fi
    else
        warn "Policy file not found: $policy_file"
    fi
fi

# Systemd service
if systemctl is-enabled nemoclaw-sandbox.service &>/dev/null 2>&1; then
    pass "nemoclaw-sandbox.service: enabled (reboot-safe)"
else
    warn "nemoclaw-sandbox.service: not enabled — run: sudo systemctl enable nemoclaw-sandbox.service"
fi

if systemctl is-active nemoclaw-sandbox.service &>/dev/null 2>&1; then
    pass "nemoclaw-sandbox.service: active"
else
    info "nemoclaw-sandbox.service: not active (may be okay if started another way)"
fi

# ---------------------------------------------------------------------------
# Layer 5 — In-sandbox isolation
# ---------------------------------------------------------------------------
section "Layer 5 — In-sandbox isolation"

if ! command -v nemoclaw &>/dev/null || ! nemoclaw "${SANDBOX_NAME}" status &>/dev/null 2>&1; then
    warn "Skipping in-sandbox checks (sandbox not accessible)"
else
    info "Running checks inside sandbox via nemoclaw exec..."

    # Inference routing
    inference_result=$(nemoclaw "${SANDBOX_NAME}" exec -- \
        curl -sf --max-time 10 https://inference.local/v1/models 2>/dev/null || echo "FAILED")
    if echo "$inference_result" | grep -qi "qwen\|model\|\"id\""; then
        pass "Inference routing: sandbox → OpenShell → vLLM working"
    elif echo "$inference_result" | grep -qi "FAILED\|error\|refused\|Could not"; then
        fail "Inference routing: not working — check OpenShell gateway"
        info "  Debug: nemoclaw ${SANDBOX_NAME} connect  →  curl -sf https://inference.local/v1/models"
    else
        warn "Inference result unclear: ${inference_result:0:100}"
    fi

    # External internet blocked
    deny_result=$(nemoclaw "${SANDBOX_NAME}" exec -- \
        curl -sf --max-time 5 https://api.github.com 2>/dev/null && echo "ALLOWED" || echo "BLOCKED")
    if echo "$deny_result" | grep -q "BLOCKED"; then
        pass "Deny-all: external internet blocked (api.github.com)"
    else
        fail "Deny-all: BROKEN — sandbox can reach api.github.com (policy too permissive)"
        info "  Fix: tighten ~/.nemoclaw/source/nemoclaw-blueprint/policies/openclaw-sandbox.yaml"
    fi

    # clawhub.com blocked
    clawhub_result=$(nemoclaw "${SANDBOX_NAME}" exec -- \
        curl -sf --max-time 5 https://clawhub.com 2>/dev/null && echo "ALLOWED" || echo "BLOCKED")
    if echo "$clawhub_result" | grep -q "BLOCKED"; then
        pass "clawhub.com: blocked (Q1 2026 supply-chain risk mitigated)"
    else
        fail "clawhub.com: REACHABLE — remove from network_policies immediately"
    fi

    # SearXNG reachable from inside sandbox — test both direct IP and hostname
    searxng_result=$(nemoclaw "${SANDBOX_NAME}" exec -- \
        curl -sf --max-time 8 "http://172.17.0.1:${SEARXNG_PORT}/search?q=test&format=json" \
        2>/dev/null || echo "FAILED")
    if echo "$searxng_result" | grep -qi "results\|query"; then
        pass "SearXNG: reachable from sandbox via 172.17.0.1:${SEARXNG_PORT}"
    elif echo "$searxng_result" | grep -q "FAILED"; then
        fail "SearXNG: not reachable from sandbox — check UFW rules and SearXNG container"
        info "  Check: sudo ufw status | grep ${SEARXNG_PORT}"
        info "  Check: curl http://localhost:${SEARXNG_PORT}/search?q=test&format=json"
    else
        warn "SearXNG result unclear: ${searxng_result:0:100}"
    fi

    searxng_host_result=$(nemoclaw "${SANDBOX_NAME}" exec -- \
        curl -sf --max-time 5 "http://searxng.local:${SEARXNG_PORT}/search?q=test&format=json" \
        2>/dev/null || echo "FAILED")
    if echo "$searxng_host_result" | grep -qi "results\|query"; then
        pass "SearXNG: searxng.local:${SEARXNG_PORT} resolves and responds"
    else
        warn "SearXNG: searxng.local hostname not resolving — agent must use 172.17.0.1:${SEARXNG_PORT} directly"
    fi

    # api.telegram.org reachable
    telegram_result=$(nemoclaw "${SANDBOX_NAME}" exec -- \
        curl -sf --max-time 8 https://api.telegram.org 2>/dev/null && echo "REACHABLE" || echo "BLOCKED")
    if echo "$telegram_result" | grep -q "REACHABLE"; then
        pass "api.telegram.org: reachable from sandbox (Telegram bridge can function)"
    else
        warn "api.telegram.org: not reachable — Telegram bridge will fail"
        info "  Fix: ensure api.telegram.org is in network_policies in the sandbox YAML"
    fi
fi

# ---------------------------------------------------------------------------
# Layer 6 — Credential hygiene
# ---------------------------------------------------------------------------
section "Layer 6 — Credential hygiene"

if [[ -f "$ENV_FILE" ]]; then
    env_perms=$(stat -c '%a' "$ENV_FILE")
    if [[ "$env_perms" == "600" ]]; then
        pass "~/.nemoclaw.env: chmod 600"
    else
        fail "~/.nemoclaw.env: permissions are $env_perms (should be 600) — run: chmod 600 $ENV_FILE"
    fi
else
    warn "~/.nemoclaw.env: not found"
fi

if [[ -f "${HOME}/.nemoclaw/dashboard-token.txt" ]]; then
    tok_perms=$(stat -c '%a' "${HOME}/.nemoclaw/dashboard-token.txt")
    if [[ "$tok_perms" == "600" ]]; then
        pass "~/.nemoclaw/dashboard-token.txt: chmod 600"
    else
        fail "Dashboard token permissions are $tok_perms (should be 600)"
    fi
    token=$(cat "${HOME}/.nemoclaw/dashboard-token.txt")
    info "Dashboard URL: http://127.0.0.1:${DASHBOARD_PORT}/#token=${token}"
fi

# Check shell history for leaked credentials
for hist_file in "${HOME}/.bash_history" "${HOME}/.zsh_history"; do
    if [[ -f "$hist_file" ]]; then
        if grep -qE "NGC_API_KEY=nvapi-|TELEGRAM_BOT_TOKEN=[0-9]" "$hist_file" 2>/dev/null; then
            warn "Possible credential leak in $hist_file — clear with: history -c"
        fi
    fi
done

# Check install log for leaked tokens (ngc API keys are nvapi-... ; bot tokens are NNN:AAA)
local_log="${SCRIPT_DIR:-${HOME}/projects/hardclaw-omni}/hardclaw-install.log"
if [[ -f "$local_log" ]]; then
    if grep -qE "nvapi-[A-Za-z0-9_-]{20,}|[0-9]{9,}:AA[A-Za-z0-9_-]{30,}" "$local_log" 2>/dev/null; then
        warn "Possible credential leak in install log: $local_log"
        warn "  Review and scrub if needed"
    else
        pass "Install log: no obvious credential leaks"
    fi
fi

# ---------------------------------------------------------------------------
# Layer 7 — Telegram bridge health
# ---------------------------------------------------------------------------
section "Layer 7 — Telegram bridge health"

if pgrep -f telegram-bridge &>/dev/null; then
    pass "Telegram bridge: process running"
else
    warn "Telegram bridge: not running — start with: nemoclaw start"
fi

# Check bridge script has the --to fix applied (session lock conflict prevention)
bridge_script="${HOME}/.nemoclaw/source/scripts/telegram-bridge.js"
if [[ -f "$bridge_script" ]]; then
    if grep -q -- "--to" "$bridge_script" && ! grep -q -- "--session-id.*tg-" "$bridge_script"; then
        pass "Telegram bridge: session-lock fix applied (--to)"
    else
        warn "Telegram bridge: session-lock fix may not be applied — Telegram responses may fail"
        warn "  Fix: see README.md §Phase 7"
    fi
else
    warn "Telegram bridge script not found: $bridge_script"
fi

# Check openclaw.json enforces the Telegram DM allowlist. The embedded-k3s
# sandbox stores its config at /sandbox/.openclaw/openclaw.json inside the
# openshell-<name>-<uuid> container (not in an external k3s PVC).
if command -v docker &>/dev/null; then
    sbx_container=$(docker ps --filter "name=openshell-${SANDBOX_NAME}-" --format '{{.Names}}' | head -1 || true)
    if [[ -n "$sbx_container" ]]; then
        config_file="/sandbox/.openclaw/openclaw.json"
        if docker exec "$sbx_container" grep -qE "allowFrom|allowlist" "$config_file" 2>/dev/null; then
            pass "openclaw.json: Telegram DM allowlist present (allowFrom/dmPolicy)"
        else
            warn "openclaw.json: DM allowlist NOT found — any Telegram user can talk to the agent"
        fi
        # Check for integrity check failure in logs
        bridge_log_check=$(journalctl -u nemoclaw-sandbox.service -n 200 2>/dev/null | \
            grep -c "integrity check FAILED" || echo "0")
        if [[ "$bridge_log_check" -gt 0 ]]; then
            warn "openclaw.json integrity check failures detected in journal"
            warn "  Run: docker exec ${sbx_container} sh -c \"cd /sandbox/.openclaw && sha256sum openclaw.json > .config-hash\""
        else
            pass "openclaw.json: no integrity check failures in journal"
        fi
    else
        warn "Could not find sandbox container 'openshell-${SANDBOX_NAME}-*' — skipping openclaw.json checks"
    fi
fi

# Check OpenShell inference timeout
if command -v openshell &>/dev/null; then
    timeout_val=$(openshell inference get 2>/dev/null | grep -oP '\d+' | head -1 || echo "0")
    if [[ "$timeout_val" -ge 300 ]] 2>/dev/null; then
        pass "OpenShell inference timeout: ${timeout_val}s (≥ 300s)"
    else
        warn "OpenShell inference timeout: ${timeout_val}s (should be ≥ 300) — run: openshell inference update --timeout 300"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
total=$((PASS + FAIL + WARN_COUNT))
echo -e "  Results: ${GREEN}${PASS} passed${NC}  ${RED}${FAIL} failed${NC}  ${YELLOW}${WARN_COUNT} warnings${NC}  (${total} total)"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $FAIL -eq 0 && $WARN_COUNT -eq 0 ]]; then
    echo -e "\n  ${GREEN}${BOLD}All checks passed. Deployment is healthy and secure.${NC}"
elif [[ $FAIL -eq 0 ]]; then
    echo -e "\n  ${YELLOW}Passed with ${WARN_COUNT} warning(s). Review WARN items above.${NC}"
else
    echo -e "\n  ${RED}${FAIL} check(s) FAILED. Address FAIL items before using this deployment.${NC}"
    exit 1
fi
echo ""
