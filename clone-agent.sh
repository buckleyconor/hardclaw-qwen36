#!/usr/bin/env bash
# =============================================================================
# clone-agent.sh — stand up a SECOND hardclaw-omni NemoClaw agent from the
# nemoclaw-backup-day1 golden template, with all the known-good fixes applied.
#
# It does NOT clone the-king's identity/tokens. Instead it:
#   1. Onboards a brand-new, separately-named sandbox (fresh gateway tokens,
#      fresh openclaw.json) against the SAME external vLLM + SearXNG.
#   2. Applies the known-good config deltas: toolSearch=false, SearXNG web
#      search, reasoning, and a Telegram channel wired to a NEW bot token +
#      your allowlist.
#   3. Applies the L7 sandbox policy (searxng_local rest+allowed_ips, telegram_bot…)
#      under the new sandbox name.
#   4. Copies the skills + workspace bootstrap from the template (fresh memory
#      by default, so it's a distinct agent).
#   5. Installs a per-agent reboot-survival systemd unit (never auto-onboards).
#
# Shared, no-conflict: vLLM :8000, SearXNG :8888, the OpenShell gateway.
# Per-agent, MUST be unique: sandbox name, Telegram bot token, systemd unit.
#
# Usage:
#   bash clone-agent.sh --name the-duke \
#        --bot-token 8123:AA...your-NEW-bot-token \
#        --user-id <your-telegram-user-id> \
#        [--model qwen3.6-35b-a3b-dflash] [--vllm-port 8000] [--searxng-port 8888] \
#        [--template-dir ./nemoclaw-backup-day1] [--copy-memory] [--dry-run]
#
# Run as your normal user (democenter). It will use sudo for the systemd files
# (you'll be prompted). Requires: docker access, nemoclaw + openshell CLIs, expect.
# =============================================================================
set -euo pipefail

# ---- defaults ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="${HOME:-/home/democenter}"
NEW_NAME=""
BOT_TOKEN=""
USER_ID=""
MODEL="qwen3.6-35b-a3b-dflash"
VLLM_PORT="8000"
SEARXNG_PORT="8888"
TEMPLATE_DIR="${SCRIPT_DIR}/nemoclaw-backup-day1"
COPY_MEMORY=0
DRY_RUN=0

VLLM_ENDPOINT_HOST="172.17.0.1"   # docker bridge IP the gateway uses to reach host vLLM
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
run()  { if [[ "$DRY_RUN" == 1 ]]; then echo "    [dry-run] $*"; else eval "$@"; fi; }

# ---- args ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)         NEW_NAME="$2"; shift 2 ;;
        --bot-token)    BOT_TOKEN="$2"; shift 2 ;;
        --user-id)      USER_ID="$2"; shift 2 ;;
        --model)        MODEL="$2"; shift 2 ;;
        --vllm-port)    VLLM_PORT="$2"; shift 2 ;;
        --searxng-port) SEARXNG_PORT="$2"; shift 2 ;;
        --template-dir) TEMPLATE_DIR="$2"; shift 2 ;;
        --copy-memory)  COPY_MEMORY=1; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        -h|--help)      sed -n '2,40p' "$0"; exit 0 ;;
        *) die "Unknown flag: $1 (try --help)" ;;
    esac
done
VLLM_ENDPOINT="http://${VLLM_ENDPOINT_HOST}:${VLLM_PORT}/v1"

[[ -n "$NEW_NAME"  ]] || die "Missing --name <sandbox-name>"
[[ -n "$BOT_TOKEN" ]] || die "Missing --bot-token <new-bot-token> (create a NEW bot via @BotFather)"
[[ -n "$USER_ID"   ]] || die "Missing --user-id <your-telegram-user-id>"
[[ "$NEW_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "--name must be lowercase alphanumeric/hyphens (e.g. the-duke)"
[[ "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || die "--bot-token doesn't look like a Telegram token (NNN:AAA...)"

echo "${BOLD}Clone a new hardclaw-omni agent: '${NEW_NAME}'${NC}"
echo "  model=${MODEL}  vLLM=:${VLLM_PORT}  SearXNG=:${SEARXNG_PORT}"
echo "  template=${TEMPLATE_DIR}  copy-memory=${COPY_MEMORY}  dry-run=${DRY_RUN}"

# ---------------------------------------------------------------------------
step "Preflight"
# ---------------------------------------------------------------------------
command -v docker &>/dev/null || die "docker not found"
docker info &>/dev/null || die "Docker daemon not reachable"
[[ -x "$NEMOCLAW" ]]  || die "nemoclaw CLI not found at $NEMOCLAW"
[[ -x "$OPENSHELL" ]] || die "openshell CLI not found at $OPENSHELL"
command -v expect &>/dev/null || die "expect not installed (sudo apt-get install -y expect)"
[[ -d "$TEMPLATE_DIR/sandbox-config" ]] || die "Template not found: $TEMPLATE_DIR/sandbox-config"
[[ -f "$TEMPLATE_DIR/policy/policy-active.yaml" ]] || die "Template policy missing: $TEMPLATE_DIR/policy/policy-active.yaml"

# Shared services must be up.
curl -sf --max-time 8 "http://localhost:${VLLM_PORT}/v1/models" &>/dev/null \
    || die "vLLM not reachable on :${VLLM_PORT} — start the external vLLM project first"
curl -sf --max-time 8 "http://localhost:${SEARXNG_PORT}/search?q=test&format=json" &>/dev/null \
    || warn "SearXNG not responding on :${SEARXNG_PORT} — web search will fail until it's up"

# The new name must not collide with an existing sandbox/container.
if docker ps -a --filter "name=openshell-${NEW_NAME}-" --format '{{.Names}}' | grep -q .; then
    die "A container 'openshell-${NEW_NAME}-*' already exists — pick a different --name or destroy it first."
fi
ok "Preflight passed (vLLM up, name '${NEW_NAME}' is free)"

# ---------------------------------------------------------------------------
step "1/7 — Onboard new sandbox '${NEW_NAME}'"
# ---------------------------------------------------------------------------
# Same proven expect flow install.sh uses. Telegram/search answered N here and
# configured explicitly afterwards. Fresh openclaw.json + fresh gateway tokens.
onboard_expect() {
  NEMOCLAW_PREFERRED_API=chat-completions NEMOCLAW_ONBOARD_VALIDATION_TIMEOUT_SECONDS=30 expect -c "
    set timeout 1200
    spawn ${NEMOCLAW} onboard
    set name_sent 0; set provider_sent 0; set url_sent 0; set api_key_sent 0
    set model_sent 0; set confirm_sent 0; set telegram_sent 0; set search_sent 0
    expect {
      -re {[Ss]andbox.*[Nn]ame|[Nn]ame.*sandbox|Enter.*name} {
        if {\$name_sent==0} { sleep 0.3; send \"${NEW_NAME}\r\"; set name_sent 1 }; exp_continue }
      -re {[Ss]elect.*provider|inference.*provider|[Pp]rovider.*\[} {
        if {\$provider_sent==0} { sleep 0.5; send \"3\r\"; set provider_sent 1 }; exp_continue }
      -re {[Oo]ther.*[Oo]pen[Aa][Ii]|[Cc]ompatible.*endpoint|[Cc]ustom.*endpoint} {
        if {\$provider_sent==0} { sleep 0.3; send \"3\r\"; set provider_sent 1 }; exp_continue }
      -re {[Bb]ase.*[Uu][Rr][Ll]|[Oo]pen[Aa][Ii].*[Uu][Rr][Ll]|[Ee]ndpoint.*[Uu][Rr][Ll]|[Ee]nter.*[Uu][Rr][Ll]} {
        if {\$provider_sent==1 && \$url_sent==0} { sleep 0.3; send \"${VLLM_ENDPOINT}\r\"; set url_sent 1 }; exp_continue }
      -re {[Aa][Pp][Ii].*[Kk]ey|[Aa]uthorization.*[Kk]ey|[Aa]ccess.*[Kk]ey|endpoint.*[Kk]ey} {
        if {\$url_sent==1 && \$api_key_sent==0} { sleep 0.2; send \"unused\r\"; set api_key_sent 1 }; exp_continue }
      -re {[Ss]elect.*model|[Ww]hich model|[Mm]odel.*\[|[Ee]nter.*model|[Mm]odel.*name|[Mm]odel.*id} {
        if {\$model_sent==0 && \$url_sent==1} { sleep 0.5; send \"${MODEL}\r\"; set model_sent 1 }; exp_continue }
      -re {[Pp]olicy tier|[Pp]olicy.*controls|[Bb]alanced defaults|[Pp]resets.*[Dd]efault} {
        sleep 0.4; send \"\r\"; exp_continue }
      -re {[Aa]pply.*configuration.*\[Y/n\]|[Cc]onfirm.*configuration.*\[Y/n\]} {
        if {\$confirm_sent==0} { sleep 0.3; send \"Y\r\"; set confirm_sent 1 }; exp_continue }
      -re {[Tt]elegram|[Bb]ot.*[Tt]oken|telegram.*bridge} {
        if {\$telegram_sent==0} { sleep 0.2; send \"N\r\"; set telegram_sent 1 }; exp_continue }
      -re {[Ww]eb.?search|[Ee]nable.*search|configure.*search|[Bb]rave|search.*provider} {
        if {\$search_sent==0} { sleep 0.2; send \"N\r\"; set search_sent 1 }; exp_continue }
      -re {[Rr]esource.*profile|[Pp]rofile.*\[} { sleep 0.2; send \"\r\"; exp_continue }
      -re {[Vv]alidation.*fail|[Pp]lease.*choose.*again|[Ee]ndpoint.*valid} {
        set provider_sent 0; set url_sent 0; set api_key_sent 0; set model_sent 0; exp_continue }
      -re {\[Y/n\]|\(Y/n\)} { sleep 0.2; send \"Y\r\"; exp_continue }
      -re {\[y/N\]|\(y/N\)} { sleep 0.2; send \"\r\"; exp_continue }
      -re {[Pp]ress.*[Ee]nter} { sleep 0.2; send \"\r\"; exp_continue }
      eof { }
      timeout { puts \"\nWizard timed out.\"; exit 1 }
    }"
}
if [[ "$DRY_RUN" == 1 ]]; then
    echo "    [dry-run] would run nemoclaw onboard for '${NEW_NAME}' against ${VLLM_ENDPOINT} (model ${MODEL})"
else
    onboard_expect || die "Onboard wizard failed — run 'nemoclaw onboard' manually for '${NEW_NAME}'"
fi

# Resolve the new container.
if [[ "$DRY_RUN" == 1 ]]; then
    CONTAINER="(dry-run-container)"
else
    for i in $(seq 1 15); do
        CONTAINER=$(docker ps -a --filter "name=openshell-${NEW_NAME}-" --format '{{.Names}}' | head -1 || true)
        [[ -n "$CONTAINER" ]] && break; sleep 2
    done
    [[ -n "$CONTAINER" ]] || die "Onboard finished but no 'openshell-${NEW_NAME}-*' container appeared"
    ok "Onboarded — container: $CONTAINER"
fi

# ---------------------------------------------------------------------------
step "2/7 — Apply known-good config deltas (toolSearch off, SearXNG, Telegram)"
# ---------------------------------------------------------------------------
# Read the per-sandbox egress proxy from the container (don't hardcode it).
if [[ "$DRY_RUN" == 1 ]]; then
    PROXY="http://10.200.0.1:3128"
else
    PH=$(docker exec "$CONTAINER" printenv NEMOCLAW_PROXY_HOST 2>/dev/null || echo "10.200.0.1")
    PP=$(docker exec "$CONTAINER" printenv NEMOCLAW_PROXY_PORT 2>/dev/null || echo "3128")
    PROXY="http://${PH}:${PP}"
fi
info "Telegram egress proxy: ${PROXY}"

DELTA_PY=$(cat <<PY
import json
f="${SANDBOX_DIR}/openclaw.json"
c=json.load(open(f))

# tools: SearXNG web search ON, toolSearch OFF (critical for local models)
c.setdefault('tools',{})
c['tools']['toolSearch']=False
c['tools'].setdefault('web',{}).setdefault('fetch',{}).update({'enabled':True,'useTrustedEnvProxy':True})
c['tools']['web']['search']={'enabled':True,'provider':'searxng','maxResults':8,'timeoutSeconds':15}

# searxng plugin
c.setdefault('plugins',{}).setdefault('entries',{})['searxng']={
  'enabled':True,
  'config':{'webSearch':{'baseUrl':'http://host.openshell.internal:${SEARXNG_PORT}',
                         'categories':'general,news','language':'en'}}}
c['plugins']['entries']['telegram']={'enabled':True}

# agent defaults: assembled prompt + reasoning
d=c.setdefault('agents',{}).setdefault('defaults',{})
d['skipBootstrap']=False
d.pop('systemPromptOverride',None)
d['thinkingDefault']='off'
d['models']={}   # no tool_choice=required (loops the local model)
try:
    m=c['models']['providers']['inference']['models'][0]
    m['reasoning']=True
    m.setdefault('compat',{})['thinkingFormat']='qwen-chat-template'
except Exception as e:
    print("note: could not set reasoning on model:",e)

# Telegram channel wired to the NEW bot token + allowlist
c.setdefault('channels',{}).setdefault('telegram',{})
c['channels']['telegram']['enabled']=True
acct=c['channels']['telegram'].setdefault('accounts',{}).setdefault('default',{})
acct.update({
  'botToken':"${BOT_TOKEN}",
  'enabled':True,
  'healthMonitor':{'enabled':False},
  'proxy':"${PROXY}",
  'groupPolicy':'open',
  'dmPolicy':'allowlist',
  'allowFrom':["${USER_ID}"],
})

json.dump(c,open(f,'w'),indent=2)
print("deltas applied")
PY
)
if [[ "$DRY_RUN" == 1 ]]; then
    echo "    [dry-run] would apply openclaw.json deltas (toolSearch=false, searxng, telegram=${BOT_TOKEN:0:8}…, allowFrom=[${USER_ID}])"
else
    docker exec "$CONTAINER" python3 -c "$DELTA_PY" || die "Failed to apply config deltas"
    ok "Config deltas applied"
fi

# ---------------------------------------------------------------------------
step "3/7 — Apply L7 sandbox policy"
# ---------------------------------------------------------------------------
# Policy content is sandbox-agnostic; just apply it under the new name.
run "\"$OPENSHELL\" policy set \"$NEW_NAME\" --policy \"$TEMPLATE_DIR/policy/policy-active.yaml\" --yes" \
    && ok "Policy submitted for ${NEW_NAME}" || warn "Policy set returned non-zero — verify with: openshell policy get ${NEW_NAME} --full"

# ---------------------------------------------------------------------------
step "4/7 — Install skills + workspace bootstrap (fresh memory)"
# ---------------------------------------------------------------------------
TSC="$TEMPLATE_DIR/sandbox-config"
if [[ "$DRY_RUN" == 1 ]]; then
    echo "    [dry-run] would copy plugin-skills, workspace md + skills$( [[ $COPY_MEMORY == 1 ]] && echo ', memory' ) into $CONTAINER and chown sandbox:sandbox"
else
    # plugin-skills (meal-planner, ai-news, …)
    [[ -d "$TSC/plugin-skills" ]] && docker cp "$TSC/plugin-skills/." "${CONTAINER}:${SANDBOX_DIR}/plugin-skills/"
    # workspace bootstrap md files (TOOLS.md carries the web_search direct-call instructions)
    for md in TOOLS.md SOUL.md AGENTS.md IDENTITY.md USER.md HEARTBEAT.md; do
        [[ -f "$TSC/workspace/$md" ]] && docker cp "$TSC/workspace/$md" "${CONTAINER}:${SANDBOX_DIR}/workspace/$md"
    done
    # workspace/skills
    [[ -d "$TSC/workspace/skills" ]] && docker cp "$TSC/workspace/skills/." "${CONTAINER}:${SANDBOX_DIR}/workspace/skills/"
    # memory: fresh unless --copy-memory
    if [[ "$COPY_MEMORY" == 1 && -d "$TSC/memory" ]]; then
        docker cp "$TSC/memory/." "${CONTAINER}:${SANDBOX_DIR}/memory/"
        info "Copied memory from template (--copy-memory)"
    else
        info "Fresh memory (new agent starts with no recalled history)"
    fi
    # ownership + hash
    docker exec "$CONTAINER" chown -R sandbox:sandbox \
        "${SANDBOX_DIR}/openclaw.json" "${SANDBOX_DIR}/plugin-skills" "${SANDBOX_DIR}/workspace" "${SANDBOX_DIR}/memory" 2>/dev/null || true
    docker exec "$CONTAINER" sh -c "cd ${SANDBOX_DIR} && sha256sum openclaw.json > .config-hash && chown sandbox:sandbox .config-hash"
    ok "Skills + workspace installed; ownership fixed; hash recomputed"
fi

# ---------------------------------------------------------------------------
step "5/7 — Install per-agent reboot-survival systemd unit"
# ---------------------------------------------------------------------------
WRAP="/tmp/nemoclaw-sandbox-${NEW_NAME}-start"
STOP="/tmp/nemoclaw-sandbox-${NEW_NAME}-stop"
UNIT="/tmp/nemoclaw-sandbox-${NEW_NAME}.service"
# Generate from the template wrappers by substituting the sandbox name.
sed "s/^SANDBOX=.*/SANDBOX=\"${NEW_NAME}\"/; s#/var/log/nemoclaw-sandbox-start.log#/var/log/nemoclaw-sandbox-${NEW_NAME}-start.log#; s#/var/log/nemoclaw-sandbox-stop.log#/var/log/nemoclaw-sandbox-${NEW_NAME}-stop.log#" \
    "$TEMPLATE_DIR/systemd/nemoclaw-sandbox-start" > "$WRAP"
sed "s/^SANDBOX=.*/SANDBOX=\"${NEW_NAME}\"/; s#/var/log/nemoclaw-sandbox-stop.log#/var/log/nemoclaw-sandbox-${NEW_NAME}-stop.log#" \
    "$TEMPLATE_DIR/systemd/nemoclaw-sandbox-stop" > "$STOP"
sed "s/(the-king)/(${NEW_NAME})/; s#nemoclaw-sandbox-start#nemoclaw-sandbox-${NEW_NAME}-start#; s#nemoclaw-sandbox-stop#nemoclaw-sandbox-${NEW_NAME}-stop#" \
    "$TEMPLATE_DIR/systemd/nemoclaw-sandbox.service" > "$UNIT"

if [[ "$DRY_RUN" == 1 ]]; then
    echo "    [dry-run] generated unit files in /tmp; would sudo-install them as nemoclaw-sandbox-${NEW_NAME}.{service,start,stop}"
else
    sudo install -m 755 "$WRAP" "/usr/local/bin/nemoclaw-sandbox-${NEW_NAME}-start"
    sudo install -m 755 "$STOP" "/usr/local/bin/nemoclaw-sandbox-${NEW_NAME}-stop"
    sudo install -m 644 "$UNIT" "/etc/systemd/system/nemoclaw-sandbox-${NEW_NAME}.service"
    sudo touch "/var/log/nemoclaw-sandbox-${NEW_NAME}-start.log" "/var/log/nemoclaw-sandbox-${NEW_NAME}-stop.log"
    sudo chmod 666 "/var/log/nemoclaw-sandbox-${NEW_NAME}-start.log" "/var/log/nemoclaw-sandbox-${NEW_NAME}-stop.log"
    sudo systemctl daemon-reload
    sudo systemctl enable "nemoclaw-sandbox-${NEW_NAME}.service" &>/dev/null || true
    ok "Installed + enabled nemoclaw-sandbox-${NEW_NAME}.service"
fi

# ---------------------------------------------------------------------------
step "6/7 — Restart container to apply config"
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == 1 ]]; then
    echo "    [dry-run] would: docker restart $CONTAINER ; wait for gateway"
else
    docker restart "$CONTAINER" >/dev/null
    up=0
    for i in $(seq 1 24); do
        sleep 5
        if [[ "$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" == "running" ]] \
           && docker exec "$CONTAINER" sh -c "grep -q 'http server listening' /tmp/gateway.log" &>/dev/null; then up=1; break; fi
    done
    [[ "$up" == 1 ]] && ok "Gateway up" || warn "Gateway not confirmed — check: docker logs $CONTAINER"
fi

# ---------------------------------------------------------------------------
step "7/7 — Verify"
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == 1 ]]; then
    echo "    [dry-run] would verify toolSearch=false, no L7 errors, SearXNG ALLOWED"
else
    ts=$(docker exec "$CONTAINER" sh -c "python3 -c \"import json;print(json.load(open('${SANDBOX_DIR}/openclaw.json'))['tools']['toolSearch'])\"" 2>/dev/null || echo "?")
    [[ "$ts" == "False" ]] && ok "toolSearch=False" || warn "toolSearch='$ts' (expected False)"
    crash=$(docker logs --since 3m "$CONTAINER" 2>&1 | grep -c 'L7 policy validation failed' || true)
    [[ "$crash" == 0 ]] && ok "No L7 policy validation errors" || warn "$crash L7 policy errors — check policy"
fi

echo
ok "${BOLD}Agent '${NEW_NAME}' created.${NC}"
echo "  • Message its NEW Telegram bot from user ID ${USER_ID} to test (first reply ~15-20s)."
echo "  • Logs:    nemoclaw ${NEW_NAME} logs --follow"
echo "  • Status:  nemoclaw ${NEW_NAME} status"
echo "  • Snapshot it later: copy nemoclaw-backup-day1/recapture.sh and set SANDBOX=${NEW_NAME}."
[[ "$DRY_RUN" == 1 ]] && echo "  (dry-run: nothing was actually changed)"
