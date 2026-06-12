#!/usr/bin/env bash
# =============================================================================
# hardclaw-omni install.sh
# Security-hardened NemoClaw v0.0.56 + external vLLM serving Qwen 3.6 35B A3B
# on Dell Pro Max GB10 (DGX Spark, 128 GB UMA)
#
# Features: Telegram (user-whitelisted), SearXNG web search, deny-all UFW,
#           reboot-survival systemd service
#
# Inference: vLLM serving qwen3.6-35b-a3b-dflash on :8000, provisioned by its
#            OWN external project (dgx-spark-vllm-qwen3.6-35b-a3b-dflash). This
#            installer only consumes it via an OpenAI-compatible provider; it
#            does not build, start, or manage the vLLM container.
#
# Usage:
#   # 1. Create credentials file first:
#   install -m 600 /dev/null ~/.nemoclaw.env
#   cat > ~/.nemoclaw.env <<EOF
#   TELEGRAM_BOT_TOKEN=1234567890:AAABBBCCC...
#   TELEGRAM_USER_ID=987654321
#   SANDBOX_NAME=my-assistant
#   SEARXNG_PORT=8888
#   EOF
#
#   # 2. Run the installer:
#   bash install.sh
#
# Idempotent: safe to re-run if interrupted.
# Time estimate: 5–15 minutes (model weights are local, no large download).
# =============================================================================

set -euo pipefail

trap 'echo "[ERROR] install.sh failed at line ${LINENO} — command: ${BASH_COMMAND}" | tee -a "${LOG_FILE:-/tmp/hardclaw-debug.log}" >&2' ERR

# ---------------------------------------------------------------------------
# Configuration — sourced from ~/.nemoclaw.env; CLI flags override
# ---------------------------------------------------------------------------
ENV_FILE="${HOME}/.nemoclaw.env"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a && source "$ENV_FILE" && set +a
fi

SANDBOX_NAME="${SANDBOX_NAME:-my-assistant}"
NEMOCLAW_TAG="${NEMOCLAW_TAG:-v0.0.56}"
MODEL="${MODEL:-qwen3.6-35b-a3b-dflash}"
SEARXNG_PORT="${SEARXNG_PORT:-8888}"
DASHBOARD_PORT=18789
VLLM_PORT=8000
# NemoClaw probes append /chat/completions directly (no /v1/), so include /v1 here.
# Also use the Docker bridge IP — the OpenShell gateway routes this from inside the
# container, where localhost does not reach the host.
VLLM_ENDPOINT="http://172.17.0.1:${VLLM_PORT}/v1"
# vLLM is provisioned by its own project (dgx-spark-vllm-qwen3.6-35b-a3b-dflash);
# this deployment only *consumes* it on :${VLLM_PORT}. These are used to verify it.
VLLM_CONTAINER="vllm-qwen3.6-35b-a3b-dflash"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/hardclaw-install.log"
TOKEN_FILE="${HOME}/.nemoclaw/dashboard-token.txt"

# Parse CLI overrides
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sandbox-name) SANDBOX_NAME="$2"; shift 2 ;;
        --tag)          NEMOCLAW_TAG="$2"; shift 2 ;;
        --model)        MODEL="$2"; shift 2 ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; BOLD='\033[1m'; NC='\033[0m'

_log() { echo -e "$*" | tee -a "$LOG_FILE"; }
info()  { _log "${BLUE}[hardclaw-omni]${NC} $*"; }
ok()    { _log "  ${GREEN}✓${NC} $*"; }
warn()  { _log "  ${YELLOW}!${NC} $*"; }
die()   { _log "  ${RED}✗ ERROR:${NC} $*"; exit 1; }
step()  { _log "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n  $*\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# Always log start time
_log "\n=== hardclaw-omni install started at $(date) ==="

# ---------------------------------------------------------------------------
# Phase 0 — Preflight checks
# ---------------------------------------------------------------------------
phase_preflight() {
    step "Phase 0 — Preflight checks"

    # OS check
    local os_id os_ver
    os_id=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
    os_ver=$(grep '^VERSION_ID=' /etc/os-release | tr -d '"' | cut -d= -f2)
    if [[ "$os_id" != "ubuntu" ]]; then
        warn "Expected Ubuntu but found: $os_id $os_ver. Continuing anyway."
    else
        ok "OS: Ubuntu $os_ver"
    fi

    # GPU check
    if ! nvidia-smi &>/dev/null; then
        die "nvidia-smi failed. Is the NVIDIA driver installed?"
    fi
    local gpu_name
    gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    ok "GPU: $gpu_name"

    # Docker check
    if ! docker info &>/dev/null; then
        die "Docker is not running. Start it: sudo systemctl start docker"
    fi
    local docker_ver
    docker_ver=$(docker info --format '{{.ServerVersion}}' 2>/dev/null)
    ok "Docker: $docker_ver"

    # sudo check
    if ! sudo -n true 2>/dev/null; then
        info "This script requires sudo access."
        sudo true || die "sudo access required."
    fi
    ok "sudo: available"

    # Memory check (30B model needs ~20 GB, but pre-warm needs headroom)
    local free_gb
    free_gb=$(awk '/^MemAvailable:/{printf "%d", $2/1024/1024}' /proc/meminfo)
    if [[ "$free_gb" -lt 30 ]]; then
        warn "Only ${free_gb} GB free RAM. Recommend flushing cache first:"
        warn "  sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'"
    else
        ok "Memory: ${free_gb} GB available"
    fi

    # Disk check (model ~18 GB + Docker layers)
    local free_disk_gb
    free_disk_gb=$(df -BG /home | awk 'NR==2{gsub("G","",$4); print $4}')
    if [[ "$free_disk_gb" -lt 60 ]]; then
        warn "Only ${free_disk_gb} GB free on /home. Model needs ~18 GB plus Docker overhead."
        read -rp "  Continue anyway? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || exit 1
    else
        ok "Disk: ${free_disk_gb} GB free"
    fi

    # Credentials file check
    if [[ ! -f "$ENV_FILE" ]]; then
        die "Credentials file not found: $ENV_FILE\n\nCreate it first:\n  install -m 600 /dev/null ~/.nemoclaw.env\n  # Then add TELEGRAM_BOT_TOKEN, TELEGRAM_USER_ID"
    fi
    local env_perms
    env_perms=$(stat -c '%a' "$ENV_FILE")
    if [[ "$env_perms" != "600" ]]; then
        warn "Fixing permissions on $ENV_FILE (was $env_perms, should be 600)"
        chmod 600 "$ENV_FILE"
    fi
    ok "Credentials file: $ENV_FILE (chmod 600)"

    # Check required credentials
    for var in TELEGRAM_BOT_TOKEN TELEGRAM_USER_ID; do
        if [[ -z "${!var:-}" ]]; then
            die "Missing required credential: $var\nAdd it to $ENV_FILE"
        fi
        ok "Credential set: $var"
    done

    # SearXNG check
    if curl -sf --max-time 5 "http://localhost:${SEARXNG_PORT}/search?q=test&format=json" &>/dev/null; then
        ok "SearXNG responding on :${SEARXNG_PORT}"
    else
        warn "SearXNG not responding on :${SEARXNG_PORT}. Web search will fail until it's up."
        warn "Make sure your SearXNG Docker container is running."
    fi

    # Internet check
    if ! curl -sf --max-time 10 https://huggingface.co &>/dev/null; then
        die "No internet access. Check network connectivity."
    fi
    ok "Internet: reachable"

    # vLLM inference server — provisioned and owned by its own external project
    # (dgx-spark-vllm-qwen3.6-35b-a3b-dflash), running as Docker unless-stopped.
    # This deployment only consumes it; it does NOT build or manage the container.
    if curl -sf --max-time 10 "http://localhost:${VLLM_PORT}/v1/models" &>/dev/null; then
        local served
        served=$(curl -sf "http://localhost:${VLLM_PORT}/v1/models" \
            | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || echo "")
        ok "vLLM inference reachable on :${VLLM_PORT} (serving: ${served:-unknown})"
        [[ -n "$served" && "$served" != "$MODEL" ]] && \
            warn "vLLM serves '${served}' but MODEL='${MODEL}' — make sure they match."
    else
        die "vLLM not reachable on :${VLLM_PORT}. Start the external vLLM project first (it should run as a Docker unless-stopped container serving ${MODEL})."
    fi

    # Backup existing config
    if [[ -d "${HOME}/.nemoclaw" ]]; then
        local bak="${HOME}/.nemoclaw.bak.$(date +%Y%m%d_%H%M%S)"
        warn "Backing up ~/.nemoclaw to $bak"
        cp -a "${HOME}/.nemoclaw" "$bak"
    fi

    # Backup /etc/docker/daemon.json + UFW rules
    local backup_dir="${HOME}/hardclaw-omni-backup"
    mkdir -p "$backup_dir"
    [[ -f /etc/docker/daemon.json ]] && cp /etc/docker/daemon.json "${backup_dir}/daemon.json.bak"
    sudo ufw status verbose > "${backup_dir}/ufw-rules.bak" 2>/dev/null || true
    ok "Backups saved to $backup_dir"

    info "Log file: $LOG_FILE"
    info "Estimated time: 5–10 minutes (model already local)"
}

# ---------------------------------------------------------------------------
# Phase 1 — Host hardening (UFW deny-all + sysctl + avahi)
# ---------------------------------------------------------------------------
phase_harden_host() {
    step "Phase 1 — Host hardening"

    # Install UFW if missing
    if ! command -v ufw &>/dev/null; then
        info "Installing UFW..."
        sudo apt-get install -y ufw
    fi
    ok "UFW installed"

    # Detect LAN subnet from default route
    local gateway lan_subnet
    gateway=$(ip route show default | awk 'NR==1{print $3}')
    if [[ -z "$gateway" ]]; then
        warn "Could not detect default gateway. Using 192.168.1.0/24 for SSH."
        lan_subnet="192.168.1.0/24"
    else
        lan_subnet=$(echo "$gateway" | awk -F. '{print $1"."$2"."$3".0/24"}')
    fi
    info "Detected LAN subnet for SSH: $lan_subnet"

    sudo ufw --force reset

    sudo ufw default deny incoming
    sudo ufw default allow outgoing

    sudo ufw allow from "$lan_subnet" to any port 22 proto tcp \
        comment 'SSH from LAN'

    sudo ufw deny "$DASHBOARD_PORT" \
        comment 'Block OpenShell dashboard (access via SSH tunnel only)'

    # vLLM — Docker bridges only (inference on :8000)
    sudo ufw allow from 127.0.0.1 to any port "${VLLM_PORT}" proto tcp \
        comment 'localhost → vLLM'
    sudo ufw allow from 172.17.0.0/16 to any port "${VLLM_PORT}" proto tcp \
        comment 'Docker bridge → vLLM'
    sudo ufw allow from 172.18.0.0/16 to any port "${VLLM_PORT}" proto tcp \
        comment 'OpenShell cluster → vLLM'
    sudo ufw allow from 10.42.0.0/16 to any port "${VLLM_PORT}" proto tcp \
        comment 'k3s pods → vLLM'

    # SearXNG — Docker bridges only (sandbox-to-host search, not exposed to LAN)
    sudo ufw allow from 172.17.0.0/16 to any port "${SEARXNG_PORT}" proto tcp \
        comment 'Docker bridge → SearXNG'
    sudo ufw allow from 172.18.0.0/16 to any port "${SEARXNG_PORT}" proto tcp \
        comment 'OpenShell cluster → SearXNG'
    sudo ufw allow from 10.42.0.0/16 to any port "${SEARXNG_PORT}" proto tcp \
        comment 'k3s pods → SearXNG'

    # OpenShell gateway — sandbox containers must reach the gateway on :8080
    # to fetch their policy and report status. The openshell-docker network is
    # 172.22.0.0/16; without this rule the sandbox hangs in Provisioning.
    sudo ufw allow from 172.22.0.0/16 to any port 8080 proto tcp \
        comment 'openshell-docker → OpenShell gateway'

    sudo ufw --force enable
    ok "UFW enabled with deny-all baseline"
    sudo ufw status verbose | tee -a "$LOG_FILE" || true

    # Disable mDNS (OpenClaw Q1 2026: avahi-daemon advertised agent presence)
    if systemctl is-active avahi-daemon &>/dev/null 2>&1; then
        sudo systemctl disable --now avahi-daemon
        ok "avahi-daemon disabled (mDNS broadcast suppressed)"
    else
        ok "avahi-daemon already inactive"
    fi

    # Sysctl hardening (not in hardclaw v1 — additional network stack protection)
    sudo tee /etc/sysctl.d/99-hardclaw-omni.conf > /dev/null <<'EOF'
# hardclaw-omni: additional network stack hardening
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.tcp_syncookies = 1
EOF
    sudo sysctl -p /etc/sysctl.d/99-hardclaw-omni.conf 2>&1 | tee -a "$LOG_FILE" || true
    ok "Sysctl hardening applied"
}

# ---------------------------------------------------------------------------
# Phase 2 — Docker + NVIDIA runtime
# ---------------------------------------------------------------------------
phase_docker() {
    step "Phase 2 — Docker + NVIDIA runtime"

    info "Configuring NVIDIA container runtime..."
    sudo nvidia-ctk runtime configure --runtime=docker
    ok "NVIDIA runtime configured"

    info "Hardening Docker daemon.json..."
    sudo python3 -c "
import json, os
path = '/etc/docker/daemon.json'
d = json.load(open(path)) if os.path.exists(path) else {}
d.update({
    'default-runtime': 'nvidia',
    'default-cgroupns-mode': 'host',
    'no-new-privileges': True,
    'userland-proxy': False,
    'live-restore': True,
    'log-driver': 'json-file',
    'log-opts': {'max-size': '10m', 'max-file': '5'},
})
json.dump(d, open(path, 'w'), indent=2)
print('daemon.json written')
"
    ok "Docker daemon.json hardened"

    sudo systemctl restart docker
    ok "Docker restarted"

    # Verify NVIDIA runtime (GB10/ARM64: use a plain echo test, not nvidia-smi)
    if docker run --rm --runtime=nvidia --gpus all ubuntu:24.04 echo "NVIDIA-OK" 2>/dev/null | grep -q "NVIDIA-OK"; then
        ok "NVIDIA container runtime: working"
    else
        warn "NVIDIA runtime test failed — may need a reboot to take effect"
    fi

    # Add user to docker group (effective on next login)
    if ! groups "$USER" | grep -q docker; then
        sudo usermod -aG docker "$USER"
        warn "Added $USER to docker group — you may need to re-login for group membership to take effect"
        warn "Current session: using 'newgrp docker' or running with sudo as fallback"
    else
        ok "User $USER already in docker group"
    fi
}

# ---------------------------------------------------------------------------
# Phase 3 — Verify external vLLM inference server
# ---------------------------------------------------------------------------
# vLLM (serving ${MODEL}) is provisioned and owned by its own project
# (dgx-spark-vllm-qwen3.6-35b-a3b-dflash), running as a Docker unless-stopped
# container on :${VLLM_PORT}. hardclaw-omni only *consumes* it — it does not
# build, start, stop, or otherwise manage the vLLM container. This phase just
# verifies it is up and serving the expected model before onboarding.
phase_vllm() {
    step "Phase 3 — Verify external vLLM inference server"

    info "vLLM is managed by its own project; this deployment only consumes it on :${VLLM_PORT}."

    # Wait for the inference endpoint to actually answer a chat completion, not
    # just for the HTTP server to be up — weights can take minutes to load.
    local attempts=0
    while true; do
        if curl -sf "http://localhost:${VLLM_PORT}/v1/models" &>/dev/null; then
            local test_ok
            test_ok=$(curl -sf -X POST "http://localhost:${VLLM_PORT}/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}" \
                2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print('ok')" 2>/dev/null || echo "")
            [[ "$test_ok" == "ok" ]] && break
        fi
        sleep 10
        attempts=$((attempts + 1))
        if [[ $attempts -eq 12 ]]; then
            info "Still waiting for vLLM — model may be loading. Check the vLLM project: docker logs ${VLLM_CONTAINER}"
        fi
        [[ $attempts -gt 180 ]] && die "vLLM not ready within 30 minutes on :${VLLM_PORT}. Start/check its own project (container ${VLLM_CONTAINER})."
    done
    ok "vLLM inference ready on :${VLLM_PORT}"

    # Verify served model name matches what NemoClaw expects
    local served
    served=$(curl -sf "http://localhost:${VLLM_PORT}/v1/models" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null || echo "")
    if [[ "$served" == "$MODEL" ]]; then
        ok "Model verified: ${MODEL}"
    else
        warn "Served model name '${served}' does not match expected '${MODEL}' — onboarding may fail."
    fi
}

# ---------------------------------------------------------------------------
# Phase 4 — NemoClaw install + initial onboard
# ---------------------------------------------------------------------------
phase_nemoclaw_install() {
    step "Phase 4 — NemoClaw install (${NEMOCLAW_TAG})"

    # Check if already installed at the right version
    local installed_ver=""
    if command -v nemoclaw &>/dev/null; then
        installed_ver=$(nemoclaw --version 2>/dev/null | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    fi

    if [[ "$installed_ver" == "$NEMOCLAW_TAG" ]]; then
        ok "NemoClaw already installed: $installed_ver"
    else
        if [[ -n "$installed_ver" ]]; then
            warn "Existing NemoClaw $installed_ver found; reinstalling as $NEMOCLAW_TAG"
        fi
        info "Installing NemoClaw ${NEMOCLAW_TAG}..."
        curl -fsSL https://www.nvidia.com/nemoclaw.sh | NEMOCLAW_INSTALL_TAG="${NEMOCLAW_TAG}" bash \
            2>&1 | tee -a "$LOG_FILE"
    fi

    # Verify CLI is reachable
    local nemo_path
    for candidate in \
        "${HOME}/.local/bin/nemoclaw" \
        "${HOME}/.npm-global/bin/nemoclaw" \
        "$(command -v nemoclaw 2>/dev/null || true)"; do
        [[ -x "$candidate" ]] && { nemo_path="$candidate"; break; }
    done
    [[ -z "$nemo_path" ]] && die "nemoclaw binary not found in PATH after install."
    ok "NemoClaw installed: $nemo_path"

    # Export path for subsequent phases
    export PATH="${HOME}/.local/bin:${HOME}/.npm-global/bin:${PATH}"
}

phase_onboard() {
    step "Phase 4b — Sandbox onboard"

    if nemoclaw "${SANDBOX_NAME}" status &>/dev/null 2>&1; then
        ok "Sandbox '${SANDBOX_NAME}' already exists. Skipping initial onboard."
        return 0
    fi

    _run_onboard_expect "$LOG_FILE"

    # Extract dashboard token
    local token
    token=$(grep -oP '(?<=#token=)[^\s\r\n"]+' "$LOG_FILE" | tail -1 || true)
    if [[ -n "$token" ]]; then
        mkdir -p "$(dirname "$TOKEN_FILE")"
        install -m 600 /dev/null "$TOKEN_FILE"
        echo "$token" > "$TOKEN_FILE"
        ok "Dashboard token saved: $TOKEN_FILE"
    else
        warn "Could not capture dashboard token from wizard output."
        warn "Check $LOG_FILE for '#token=' or run: nemoclaw ${SANDBOX_NAME} status"
    fi

    sleep 5
    if nemoclaw "${SANDBOX_NAME}" status &>/dev/null 2>&1; then
        ok "Sandbox '${SANDBOX_NAME}' running"
    else
        warn "Sandbox status check failed — may still be starting."
    fi
}

_run_onboard_expect() {
    local log="$1"
    local expect_log
    expect_log=$(mktemp /tmp/hardclaw-wizard.XXXXXX)

    if ! command -v expect &>/dev/null; then
        info "Installing expect..."
        sudo apt-get install -y expect 2>/dev/null || true
    fi

    if ! command -v expect &>/dev/null; then
        warn "expect not available. Please run the wizard manually:"
        warn "  nemoclaw onboard"
        warn "  Sandbox name: ${SANDBOX_NAME}"
        warn "  Provider: Other OpenAI-compatible (option 3)"
        warn "  URL: ${VLLM_ENDPOINT}  (NOT localhost — gateway validates from inside container)"
        warn "  Model: ${MODEL}"
        warn "  Policy preset: Y"
        warn "  Telegram: N (configured separately)"
        warn "  Web search: N (configured separately)"
        exit 1
    fi

    # chat-completions: skip the Responses API tool-calling probe.
    # This model is a reasoning model that exhausts its token budget in the
    # thinking phase before emitting a tool call, causing the Responses probe
    # to fail.  chat-completions probe is a simple "does it respond" check
    # that passes without requiring the model to return a structured tool call.
    # Increase the probe timeout to 30 s — the model generates up to 500 thinking
    # tokens at ~63 t/s (~8 s) and the default 15-second budget is too tight.
    NEMOCLAW_PREFERRED_API=chat-completions NEMOCLAW_ONBOARD_VALIDATION_TIMEOUT_SECONDS=30 expect -c "
        log_file -noappend \"${expect_log}\"
        set timeout 1200

        spawn nemoclaw onboard

        set name_sent 0
        set provider_sent 0
        set url_sent 0
        set api_key_sent 0
        set model_sent 0
        set policy_tier_sent 0
        set presets_sent 0
        set policy_sent 0
        set confirm_sent 0
        set telegram_sent 0
        set search_sent 0

        expect {
            -re {[Ss]andbox.*[Nn]ame|[Nn]ame.*sandbox|Enter.*name} {
                if {\$name_sent == 0} {
                    sleep 0.3
                    send \"${SANDBOX_NAME}\r\"
                    set name_sent 1
                }
                exp_continue
            }

            -re {[Ss]elect.*provider|inference.*provider|[Pp]rovider.*\[} {
                if {\$provider_sent == 0} {
                    sleep 0.5
                    send \"3\r\"
                    set provider_sent 1
                }
                exp_continue
            }

            -re {[Oo]ther.*[Oo]pen[Aa][Ii]|[Cc]ompatible.*endpoint|[Cc]ustom.*endpoint} {
                if {\$provider_sent == 0} {
                    sleep 0.3
                    send \"3\r\"
                    set provider_sent 1
                }
                exp_continue
            }

            -re {[Bb]ase.*[Uu][Rr][Ll]|[Oo]pen[Aa][Ii].*[Uu][Rr][Ll]|[Ee]ndpoint.*[Uu][Rr][Ll]|[Ee]nter.*[Uu][Rr][Ll]} {
                if {\$provider_sent == 1 && \$url_sent == 0} {
                    sleep 0.3
                    send \"${VLLM_ENDPOINT}\r\"
                    set url_sent 1
                }
                exp_continue
            }

            -re {[Aa][Pp][Ii].*[Kk]ey|[Aa]uthorization.*[Kk]ey|[Aa]ccess.*[Kk]ey|endpoint.*[Kk]ey} {
                if {\$url_sent == 1 && \$api_key_sent == 0} {
                    sleep 0.2
                    send \"ollama\r\"
                    set api_key_sent 1
                }
                exp_continue
            }

            -re {[Ss]elect.*model|[Ww]hich model|[Mm]odel.*\[} {
                if {\$model_sent == 0 && \$url_sent == 1} {
                    sleep 0.5
                    send \"${MODEL}\r\"
                    set model_sent 1
                }
                exp_continue
            }

            -re {[Ee]nter.*model|[Mm]odel.*name|[Mm]odel.*id} {
                if {\$model_sent == 0 && \$url_sent == 1} {
                    sleep 0.5
                    send \"${MODEL}\r\"
                    set model_sent 1
                }
                exp_continue
            }

            -re {[Pp]olicy tier|[Pp]olicy.*controls|[Aa]dd.*polic} {
                if {\$policy_tier_sent == 0} {
                    sleep 0.5
                    send \"\r\"
                    set policy_tier_sent 1
                }
                exp_continue
            }

            -re {[Bb]alanced defaults|toggle rw|[Pp]resets.*[Dd]efault} {
                if {\$presets_sent == 0} {
                    sleep 0.5
                    send \"\r\"
                    set presets_sent 1
                }
                exp_continue
            }

            -re {[Aa]dd.*polic|\[Yy/[Nn]\].*polic|polic.*\[Yy} {
                if {\$policy_sent == 0} {
                    sleep 0.3
                    send \"Y\r\"
                    set policy_sent 1
                }
                exp_continue
            }

            -re {[Aa]pply.*configuration.*\[Y/n\]|[Cc]onfirm.*configuration.*\[Y/n\]} {
                if {\$confirm_sent == 0} {
                    sleep 0.3
                    send \"Y\r\"
                    set confirm_sent 1
                }
                exp_continue
            }

            -re {[Tt]elegram|[Bb]ot.*[Tt]oken|telegram.*bridge} {
                if {\$telegram_sent == 0 && \$confirm_sent == 1} {
                    sleep 0.2
                    send \"N\r\"
                    set telegram_sent 1
                }
                exp_continue
            }

            -re {[Ww]eb.?search|[Ee]nable.*search|configure.*search|[Bb]rave|search.*provider} {
                if {\$search_sent == 0 && \$confirm_sent == 1} {
                    sleep 0.2
                    send \"N\r\"
                    set search_sent 1
                }
                exp_continue
            }

            -re {[Rr]esource.*profile|[Pp]rofile.*\[} {
                sleep 0.2
                send \"\r\"
                exp_continue
            }

            -re {[Vv]alidation.*fail|[Pp]lease.*choose.*again|[Ee]ndpoint.*valid} {
                # Wizard looped back after failed validation — reset flags so all
                # answers are resent when the prompts reappear.
                set provider_sent 0
                set url_sent 0
                set api_key_sent 0
                set model_sent 0
                exp_continue
            }

            -re {\[Y/n\]|\(Y/n\)} {
                sleep 0.2
                send \"Y\r\"
                exp_continue
            }

            -re {\[y/N\]|\(y/N\)} {
                sleep 0.2
                send \"\r\"
                exp_continue
            }

            -re {[Pp]ress.*[Ee]nter|continue.*\\.\\.\\.} {
                sleep 0.2
                send \"\r\"
                exp_continue
            }

            eof { }

            timeout {
                puts \"\\nWizard timed out.\"
                exit 1
            }
        }
    " 2>&1 | tee -a "$log" || {
        warn "Automated wizard failed. Run manually:"
        warn "  nemoclaw onboard"
        warn "  Sandbox name: ${SANDBOX_NAME}, Provider: Other OpenAI-compatible (3), URL: ${VLLM_ENDPOINT}, API key: ollama, Model: ${MODEL}, Policy: Y, Resource profile: Enter (default 6), Telegram: N, Search: N"
        exit 1
    }

    cat "$expect_log" >> "$log"
    rm -f "$expect_log"
}

# ---------------------------------------------------------------------------
# Phase 5 — Sandbox policy hardening (deny-all + SearXNG + Telegram)
# ---------------------------------------------------------------------------
phase_policy_harden() {
    step "Phase 5 — Sandbox policy hardening"

    local policy_dir="${HOME}/.nemoclaw/source/nemoclaw-blueprint/policies"
    local policy_file="${policy_dir}/openclaw-sandbox.yaml"

    if [[ ! -d "$policy_dir" ]]; then
        die "Policy directory not found: $policy_dir\nDid Phase 4 complete successfully?"
    fi

    info "Writing hardened network policy..."
    cat > "$policy_file" <<YAML
version: 1

filesystem_policy:
  include_workdir: true
  read_only:
    - /usr
    - /lib
    - /proc
    - /dev/urandom
    - /app
    - /etc
    - /var/log
  read_write:
    - /sandbox
    - /tmp
    - /dev/null

landlock:
  compatibility: best_effort

process:
  run_as_user: sandbox
  run_as_group: sandbox

network_policies:
  # inference.local is the OpenShell gateway's internal virtual hostname;
  # the gateway proxies it to the configured vLLM provider.
  managed_inference:
    name: managed_inference
    endpoints:
      - host: inference.local
        port: 443
        protocol: rest
        enforcement: enforce
        access: full
    binaries:
      - { path: /usr/local/bin/openclaw }
      - { path: /usr/local/bin/node }
      - { path: /usr/bin/node }

  # SearXNG — local instance on host via OpenShell host gateway
  # allowed_ips permits the private-range resolved address (SSRF guard bypass)
  searxng_search:
    name: searxng_search
    endpoints:
      - host: host.openshell.internal
        port: ${SEARXNG_PORT}
        protocol: rest
        enforcement: enforce
        allowed_ips:
          - 10.0.0.0/8
          - 172.16.0.0/12
          - 192.168.0.0/16
        rules:
          - allow: { method: GET, path: "/**" }
          - allow: { method: POST, path: "/**" }
    binaries:
      - { path: /usr/local/bin/openclaw }
      - { path: /usr/local/bin/node }
      - { path: /usr/bin/node }

  # Telegram Bot API — required for Telegram bridge
  # REMOVED — do not add back: clawhub.com (Q1 2026 malicious packages),
  #   api.anthropic.com, integrate.api.nvidia.com, sentry.io,
  #   statsig.anthropic.com, api.github.com
  telegram_bot:
    name: telegram_bot
    endpoints:
      - host: api.telegram.org
        port: 443
        protocol: rest
        enforcement: enforce
        rules:
          - allow: { method: GET, path: "/bot*/**" }
          - allow: { method: POST, path: "/bot*/**" }
          - allow: { method: GET, path: "/file/bot*/**" }
    binaries:
      - { path: /usr/local/bin/node }
      - { path: /usr/bin/node }
YAML
    ok "Hardened policy written: $policy_file"

    # Destroy sandbox to re-lock Landlock/seccomp at creation time
    info "Destroying sandbox to re-apply Landlock/seccomp policy (data is preserved)..."
    nemoclaw "${SANDBOX_NAME}" destroy 2>/dev/null || true

    info "Recreating sandbox with hardened policy..."
    _run_onboard_expect "$LOG_FILE"

    # Re-capture token (it changes on recreate)
    local token
    token=$(grep -oP '(?<=#token=)[^\s\r\n"]+' "$LOG_FILE" | tail -1 || true)
    if [[ -n "$token" ]]; then
        mkdir -p "$(dirname "$TOKEN_FILE")"
        install -m 600 /dev/null "$TOKEN_FILE"
        echo "$token" > "$TOKEN_FILE"
        ok "Dashboard token updated: $TOKEN_FILE"
    fi

    ok "Sandbox recreated with hardened policy"
}

# ---------------------------------------------------------------------------
# Phase 5b — Agent defaults (openclaw.json patches: skipBootstrap, reasoning,
#            SearXNG web_search provider, toolSearch off; + TOOLS.md / SOUL.md)
# ---------------------------------------------------------------------------
phase_agent_defaults() {
    step "Phase 5b — Agent defaults (bootstrap + system prompt)"

    local container config_file
    container=$(docker ps --filter "name=openshell-${SANDBOX_NAME}-" --format '{{.Names}}' | head -1 || true)

    if [[ -z "$container" ]]; then
        warn "Container not found — agent default patches will apply on next nemoclaw start."
        return 0
    fi

    config_file="/sandbox/.openclaw/openclaw.json"

    docker exec "$container" python3 -c "
import json
with open('${config_file}') as f:
    c = json.load(f)

# skipBootstrap: false — let OpenClaw assemble the full system prompt
# (includes tool definitions; true suppresses them and breaks tool use)
c['agents']['defaults']['skipBootstrap'] = False

# Remove systemPromptOverride if present — it replaces the assembled
# prompt and strips tool definitions, leaving the model blind to tools
c['agents']['defaults'].pop('systemPromptOverride', None)

# reasoning: true + thinkingFormat — vLLM reasoning parser routes
# <think> tokens into reasoning_content; thinkingDefault:off hides them
m = c['models']['providers']['inference']['models'][0]
m['reasoning'] = True
m.setdefault('compat', {})['thinkingFormat'] = 'qwen-chat-template'

# Enable SearXNG as the web_search provider
c['plugins']['entries']['searxng'] = {
    'enabled': True,
    'config': {
        'webSearch': {
            'baseUrl': 'http://host.openshell.internal:${SEARXNG_PORT}',
            'categories': 'general,news',
            'language': 'en'
        }
    }
}
c['tools']['web']['search'] = {
    'enabled': True,
    'provider': 'searxng',
    'maxResults': 8,
    'timeoutSeconds': 15
}

# Disable toolSearch — when enabled it hides every tool behind a 'compact
# prompt surface' that the local model must drive via tool_search_code.
# The 30B/35B local models can't handle that indirection: they write broken
# JS (require('fs'), openclaw.tools.call('web_search',...)) and loop forever,
# so web_search and file reads both silently fail. With ~28 tools, presenting
# them directly is well within the model's context budget.
c['tools']['toolSearch'] = False

# NOTE: tool_choice=required was tried but causes infinite tool_search_code loops
# with Qwen models. Leave models:{} empty and rely on TOOLS.md + SOUL.md prompting.

with open('${config_file}', 'w') as f:
    json.dump(c, f, indent=2)
" 2>/dev/null && \
        ok "Agent config: skipBootstrap=false, reasoning=true, SearXNG web_search enabled, toolSearch=false" || \
        warn "Agent config patch failed — apply manually (see README.txt)"

    docker exec "$container" \
        sh -c "cd /sandbox/.openclaw && sha256sum openclaw.json > .config-hash" 2>/dev/null && \
        ok "openclaw.json hash updated" || true

    # Write TOOLS.md and SOUL.md so the model knows web_search is permitted.
    # Without this the model's training bias ("sandbox = no network") overrides
    # tool availability and it refuses to call web_search even when it's enabled.
    local ws="/sandbox/.openclaw/workspace"
    docker exec "$container" sh -c "mkdir -p ${ws}" 2>/dev/null || true
    docker exec "$container" sh -c "cat > ${ws}/TOOLS.md" << 'TOOLSEOF'
# TOOLS.md — Available Tools

## web_search — CALL THIS DIRECTLY AS A TOOL

**Do NOT call web_search via tool_search_code or openclaw.tools.call(). Call it directly.**

- RIGHT: call the `web_search` tool with argument `query="your search string"`
- WRONG: `tool_search_code` with `openclaw.tools.call("web_search", ...)` — this loops forever

**Correct parameter name: `query` (NOT `q`)**
- RIGHT: `query="Ireland news today"`
- WRONG: `q="Ireland news today"` — fails with "query required"

Use web_search for:
- Any question about current events, news, or recent developments
- Anything that happened after your training cutoff
- Prices, scores, weather, or any time-sensitive fact

**Never say "I can't access the internet" or "network access is blocked."**
The web_search tool routes through a local SearXNG instance and IS permitted by policy.

When asked about current events or news — call web_search immediately with the `query` parameter. Do not refuse. Do not use code to wrap it.

---

## web_fetch — CALL DIRECTLY AS A TOOL

Fetch the full content of a specific URL. Call it directly with a `url` parameter.
Do NOT wrap it in tool_search_code.

---

## Skill Files

Skill files live at known paths — use read_file directly, never `find /`:
- Plugin skills: /sandbox/.openclaw/plugin-skills/<skill-name>/SKILL.md
- Workspace skills: /sandbox/.openclaw/workspace/skills/<skill-name>/SKILL.md

meal-planner paths:
- /sandbox/.openclaw/plugin-skills/meal-planner/SKILL.md
- /sandbox/.openclaw/plugin-skills/meal-planner/references/recipes.md
- /sandbox/.openclaw/plugin-skills/meal-planner/references/aisle-order.md
TOOLSEOF
    docker exec "$container" sh -c "cat >> ${ws}/SOUL.md" << 'SOULEOF'

## Web Access

You have working web search. This is not a fully isolated sandbox — web_search is policy-permitted and routes through a local search engine.

**Rule: If a question involves current events, recent news, scores, prices, or anything time-sensitive — call web_search first. Do not refuse. Do not say the network is blocked. Just search.**
SOULEOF
    # Fix ownership — docker exec runs as root so written files may be root-owned;
    # OpenClaw (sandbox user) can't write to root-owned workspace/skills/ entries.
    docker exec "$container" chown -R sandbox:sandbox "${ws}/" 2>/dev/null || true

    ok "Bootstrap files updated: web_search policy written to TOOLS.md and SOUL.md"
}

phase_searxng() {
    step "Phase 6 — SearXNG host alias"

    local bridge_ip container
    bridge_ip=$(docker network inspect bridge \
        --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || echo "172.17.0.1")

    container=$(docker ps --filter "name=openshell-${SANDBOX_NAME}-" --format '{{.Names}}' | head -1 || true)

    if [[ -z "$container" ]]; then
        warn "Container not found — cannot register searxng.local host alias."
        return 0
    fi

    # nemoclaw hosts-add requires a separate cluster container not present in
    # this embedded-k3s deployment; write the alias directly into /etc/hosts.
    if docker exec "$container" sh -c \
        "grep -q 'searxng.local' /etc/hosts || echo '${bridge_ip} searxng.local' >> /etc/hosts" 2>/dev/null; then
        ok "SearXNG host alias: searxng.local → ${bridge_ip}"
        ok "Agent can reach SearXNG at http://searxng.local:${SEARXNG_PORT}"
    else
        warn "Could not register searxng.local — agent must use http://${bridge_ip}:${SEARXNG_PORT}"
    fi
}

# ---------------------------------------------------------------------------
# Phase 7 — Telegram integration (v0.0.56)
# ---------------------------------------------------------------------------
phase_telegram() {
    step "Phase 7 — Telegram integration"

    # v0.0.56: container name includes sandbox name + UUID suffix
    local container config_file
    container=$(docker ps --filter "name=openshell-${SANDBOX_NAME}-" --format '{{.Names}}' | head -1 || true)

    if [[ -z "$container" ]]; then
        warn "Could not find running container for sandbox '${SANDBOX_NAME}'."
        warn "Telegram config will need to be applied manually."
        return 0
    fi

    config_file="/sandbox/.openclaw/openclaw.json"
    info "Container: ${container}"

    # 7a: Restrict DMs to operator only — add allowFrom whitelist + dmPolicy.
    # Token is already wired via openshell:resolve:env:TELEGRAM_BOT_TOKEN (no file needed).
    # groupPolicy "open" is left as-is (groups still require @mention by default).
    docker exec "$container" perl -i -0pe \
        "s|(\"groupPolicy\":\\s*\"[^\"]*\")(\\s*\\})|
\$1,
          \"dmPolicy\": \"allowlist\",
          \"allowFrom\": [\"${TELEGRAM_USER_ID}\"]\$2|" \
        "$config_file" 2>/dev/null && \
        ok "openclaw.json: Telegram dmPolicy=allowlist, allowFrom=[${TELEGRAM_USER_ID}]" || \
        warn "Telegram whitelist inject failed — apply manually per README.txt §Phase 7"

    # 7b: Set OpenShell inference proxy timeout (default 60s is too short for long prompts)
    if command -v openshell &>/dev/null; then
        openshell inference update --timeout 300 2>/dev/null && \
            ok "OpenShell inference timeout: 300s" || \
            warn "openshell inference update failed — run manually: openshell inference update --timeout 300"
    fi

    # 7c: Recompute integrity hash after patches
    docker exec "$container" \
        sh -c "cd /sandbox/.openclaw && sha256sum openclaw.json > .config-hash" 2>/dev/null && \
        ok "openclaw.json integrity hash updated" || \
        warn "Hash update failed — run manually:"
        warn "  docker exec ${container} sh -c 'cd /sandbox/.openclaw && sha256sum openclaw.json > .config-hash'"

    # 7d: Start Telegram bridge
    info "Starting Telegram bridge..."
    set -a && source "$ENV_FILE" && set +a
    nemoclaw start 2>&1 | tee -a "$LOG_FILE" || \
        warn "nemoclaw start failed — bridge may need manual start after reboot"

    ok "Telegram integration complete"
    info "Send a message to your bot from Telegram user ID ${TELEGRAM_USER_ID} to test."
    info "First response may take 15–20 seconds (model loading)."
}

# ---------------------------------------------------------------------------
# Phase 8 — Systemd service (reboot survival)
# ---------------------------------------------------------------------------
phase_systemd() {
    step "Phase 8 — Reboot survival (systemd)"

    local nemoclaw_bin username home_dir
    nemoclaw_bin=$(command -v nemoclaw 2>/dev/null || echo "${HOME}/.local/bin/nemoclaw")
    username=$(whoami)
    home_dir="$HOME"

    # Ensure OpenShell container has restart=unless-stopped
    local openshell_container
    openshell_container=$(docker ps -aq --filter "name=openshell" 2>/dev/null | head -1 || true)
    if [[ -n "$openshell_container" ]]; then
        docker update --restart=unless-stopped "$openshell_container" &>/dev/null && \
            ok "OpenShell container: restart=unless-stopped" || true
    fi

    # Startup wrapper
    sudo tee /usr/local/bin/nemoclaw-sandbox-start > /dev/null <<WRAPPER
#!/usr/bin/env bash
# hardclaw-omni startup wrapper — managed by install.sh, do not edit manually
#
# Reboot-survival model: the vLLM inference server (${MODEL}, owned by its own
# external project), SearXNG, and the sandbox container are all Docker
# \`unless-stopped\`, so Docker itself brings them back. This unit's real job is
# to (1) ensure the OpenShell gateway daemon is running — it has no boot unit of
# its own and is what the sandbox fetches its L7 policy from via gRPC — and
# (2) make sure the sandbox container is cleanly serving once the gateway is up.
# It NEVER re-onboards: a genuinely missing sandbox is logged and left for manual
# recovery (auto-onboard previously clobbered the sandbox with the wrong model).
set -euo pipefail

export PATH="${home_dir}/.npm-global/bin:${home_dir}/.local/bin:/usr/local/bin:/usr/bin:/bin"
NEMOCLAW="${nemoclaw_bin}"
SANDBOX="${SANDBOX_NAME}"
SEARXNG_PORT="${SEARXNG_PORT}"
VLLM_PORT="${VLLM_PORT}"          # ${MODEL}, served by the external vLLM project
LOG=/var/log/nemoclaw-sandbox-start.log

# Always log to stdout (captured by the journal); append to \$LOG best-effort so a
# non-writable/absent log file can never abort startup under \`set -e\`.
log() { local m="\$(date '+%Y-%m-%d %T') \$*"; echo "\$m"; echo "\$m" >> "\$LOG" 2>/dev/null || true; }
log "=== nemoclaw-sandbox-start (hardclaw-omni / \${SANDBOX}) ==="

# Credentials (Telegram bot token etc.) — the gateway resolves these for the bridge.
[[ -f "${home_dir}/.nemoclaw.env" ]] && set -a && source "${home_dir}/.nemoclaw.env" && set +a

# 1. Wait for Docker
log "Waiting for Docker..."
for i in \$(seq 1 30); do docker info &>/dev/null && break; sleep 2; done
docker info &>/dev/null || { log "ERROR: Docker not ready"; exit 1; }
log "Docker ready"

# 2. Best-effort wait for the external vLLM inference server on :\${VLLM_PORT}.
#    The sandbox can boot before inference is ready (only model calls need it),
#    so don't block startup on a slow model load.
log "Waiting (best-effort) for vLLM on :\${VLLM_PORT}..."
for i in \$(seq 1 12); do
    curl -sf --max-time 5 "http://localhost:\${VLLM_PORT}/v1/models" &>/dev/null && break
    sleep 5
done
curl -sf --max-time 5 "http://localhost:\${VLLM_PORT}/v1/models" &>/dev/null && \
    log "vLLM ready on :\${VLLM_PORT}" || \
    log "WARNING: vLLM not ready yet on :\${VLLM_PORT} — inference will fail until it loads"

# 3. SearXNG availability (external, unless-stopped) — informational only.
if curl -sf --max-time 5 "http://localhost:\${SEARXNG_PORT}/search?q=test&format=json" &>/dev/null; then
    log "SearXNG responding on :\${SEARXNG_PORT}"
else
    log "WARNING: SearXNG not responding on :\${SEARXNG_PORT} — web search may fail"
fi

# 4. Ensure the OpenShell gateway daemon is up. It is auto-spawned on first CLI
#    use and has no boot unit; the sandbox fetches policy from it, so it MUST be
#    running before the container boots. \`status\` connects to (and spawns) it.
log "Ensuring OpenShell gateway is up..."
gw_ok=0
for i in \$(seq 1 15); do
    if "\$NEMOCLAW" "\$SANDBOX" status &>/dev/null; then gw_ok=1; break; fi
    sleep 2
done
[[ "\$gw_ok" == 1 ]] && log "Gateway up; sandbox '\${SANDBOX}' known" || \
    log "WARNING: gateway/sandbox status not confirmed after 30s"

# 5. Ensure the sandbox container is cleanly serving. It is unless-stopped, but at
#    boot it may have crash-looped on policy fetch before the gateway came up
#    (step 4). Find it by name; restart once if it isn't already serving so it
#    gets a clean policy fetch. NEVER onboard — refuse to auto-recreate.
CONTAINER=\$(docker ps -a --filter "name=openshell-\${SANDBOX}-" --format '{{.Names}}' | head -1 || true)
if [[ -z "\$CONTAINER" ]]; then
    log "ERROR: no sandbox container 'openshell-\${SANDBOX}-*' found — NOT onboarding."
    log "       Recover manually (e.g. re-run install.sh); refusing to auto-recreate."
    exit 0
fi
if [[ "\$(docker inspect -f '{{.State.Status}}' "\$CONTAINER" 2>/dev/null)" == "running" ]] && \
   docker exec "\$CONTAINER" sh -c "grep -q 'http server listening' /tmp/gateway.log" &>/dev/null; then
    log "Sandbox container '\${CONTAINER}' already serving"
else
    log "Restarting sandbox container '\${CONTAINER}' for a clean policy fetch..."
    docker restart "\$CONTAINER" &>/dev/null || log "WARNING: docker restart failed"
fi

log "=== startup complete ==="
WRAPPER
    sudo chmod +x /usr/local/bin/nemoclaw-sandbox-start

    # Shutdown wrapper
    sudo tee /usr/local/bin/nemoclaw-sandbox-stop > /dev/null <<WRAPPER
#!/usr/bin/env bash
# hardclaw-omni shutdown wrapper — managed by install.sh, do not edit manually
set -euo pipefail

export PATH="${home_dir}/.npm-global/bin:${home_dir}/.local/bin:/usr/local/bin:/usr/bin:/bin"
SANDBOX="${SANDBOX_NAME}"
LOG=/var/log/nemoclaw-sandbox-stop.log

log() { local m="\$(date '+%Y-%m-%d %T') \$*"; echo "\$m"; echo "\$m" >> "\$LOG" 2>/dev/null || true; }
log "=== nemoclaw-sandbox-stop (\${SANDBOX}) ==="

# Stop ONLY the sandbox container. vLLM (${MODEL}) and SearXNG are owned by their
# own projects (Docker unless-stopped) — leave them running.
CONTAINER=\$(docker ps --filter "name=openshell-\${SANDBOX}-" --format '{{.Names}}' | head -1 || true)
if [[ -n "\$CONTAINER" ]]; then
    log "Stopping sandbox container '\${CONTAINER}'..."
    docker stop --time 30 "\$CONTAINER" 2>&1 | tee -a "\$LOG" || true
else
    log "No running sandbox container to stop."
fi

log "=== shutdown complete ==="
WRAPPER
    sudo chmod +x /usr/local/bin/nemoclaw-sandbox-stop

    # Systemd unit
    sudo tee /etc/systemd/system/nemoclaw-sandbox.service > /dev/null <<SERVICE
[Unit]
Description=NemoClaw AI Agent Sandbox — hardclaw-omni (${SANDBOX_NAME})
Documentation=file://${SCRIPT_DIR}/README.txt
After=network-online.target docker.service
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=${username}
Environment="HOME=${home_dir}"
Environment="PATH=${home_dir}/.npm-global/bin:${home_dir}/.local/bin:/usr/local/bin:/usr/bin:/bin"
EnvironmentFile=-${home_dir}/.nemoclaw.env
ExecStart=/usr/local/bin/nemoclaw-sandbox-start
ExecStop=/usr/local/bin/nemoclaw-sandbox-stop
TimeoutStartSec=300
TimeoutStopSec=60
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

    sudo systemctl daemon-reload
    sudo systemctl enable nemoclaw-sandbox.service
    ok "nemoclaw-sandbox.service installed and enabled"
    ok "Reboot survival: active"
}

# ---------------------------------------------------------------------------
# Phase 9 — Quick verification
# ---------------------------------------------------------------------------
phase_verify() {
    step "Phase 9 — Quick verification"

    local failures=0

    # UFW
    if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        ok "UFW: active"
    else
        warn "UFW not active"; failures=$((failures + 1))
    fi

    # vLLM container
    if docker ps --format '{{.Names}}' | grep -q "^${VLLM_CONTAINER}$"; then
        ok "vLLM container: running (${VLLM_CONTAINER})"
    else
        warn "vLLM container not running: ${VLLM_CONTAINER}"; failures=$((failures + 1))
    fi

    # Model via vLLM API
    if curl -sf "http://localhost:${VLLM_PORT}/v1/models" 2>/dev/null | grep -q "$MODEL"; then
        ok "Model: served by vLLM ($MODEL)"
    else
        warn "vLLM not serving expected model: $MODEL"; failures=$((failures + 1))
    fi

    # Sandbox
    if nemoclaw "${SANDBOX_NAME}" status &>/dev/null 2>&1; then
        ok "Sandbox '${SANDBOX_NAME}': running"
    else
        warn "Sandbox not running"; failures=$((failures + 1))
    fi

    # systemd service
    if systemctl is-enabled nemoclaw-sandbox.service &>/dev/null 2>&1; then
        ok "nemoclaw-sandbox.service: enabled"
    else
        warn "nemoclaw-sandbox.service: not enabled"; failures=$((failures + 1))
    fi

    if [[ $failures -gt 0 ]]; then
        warn "${failures} quick check(s) failed. Run 'bash verify.sh' for full diagnostics."
    else
        ok "All quick checks passed"
    fi
}

# ---------------------------------------------------------------------------
# Phase 10 — Summary
# ---------------------------------------------------------------------------
phase_summary() {
    step "Phase 10 — Installation summary"

    local token=""
    [[ -f "$TOKEN_FILE" ]] && token=$(cat "$TOKEN_FILE")

    echo ""
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${GREEN}${BOLD}hardclaw-omni deployment complete${NC}"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  NemoClaw version : ${NEMOCLAW_TAG}"
    echo -e "  Sandbox          : ${SANDBOX_NAME}"
    echo -e "  Inference        : external vLLM (${VLLM_CONTAINER}) on :${VLLM_PORT}"
    echo -e "  Model            : ${MODEL}"
    echo -e "  SearXNG          : http://localhost:${SEARXNG_PORT} (sandbox-accessible)"
    echo -e "  Telegram         : enabled (user ID: ${TELEGRAM_USER_ID})"
    echo -e "  Reboot survival  : nemoclaw-sandbox.service (enabled)"
    if [[ -n "$token" ]]; then
        echo -e "  Dashboard URL    : http://127.0.0.1:${DASHBOARD_PORT}/#token=${token}"
        echo -e "  (Access via SSH tunnel from remote: ssh -L ${DASHBOARD_PORT}:127.0.0.1:${DASHBOARD_PORT} user@<gb10-ip>)"
    fi
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e ""
    echo -e "  ${BOLD}Next steps:${NC}"
    echo -e "  1. Run: ${BOLD}bash verify.sh${NC}  (7-layer security check)"
    echo -e "  2. Send 'hello' to your Telegram bot to confirm bridge works"
    echo -e "  3. Ask the agent to search the web to confirm SearXNG works"
    echo -e "  4. Reboot to confirm auto-start: ${BOLD}sudo reboot${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    phase_preflight
    phase_harden_host
    phase_docker
    phase_vllm
    phase_nemoclaw_install
    phase_onboard
    phase_policy_harden
    phase_agent_defaults
    phase_searxng
    phase_telegram
    phase_systemd
    phase_verify
    phase_summary
}

main "$@"
