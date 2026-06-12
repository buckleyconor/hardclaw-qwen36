#!/usr/bin/env bash
# =============================================================================
# nemoclaw-backup-day1 / recapture.sh
#
# Refreshes THIS backup folder from the current live state of the "the-king"
# NemoClaw sandbox, then rebuilds the dated tar.gz archive. Run it whenever you
# add/change a skill or otherwise reach a new known-good state.
#
# It captures the same artifact set the original snapshot did:
#   - in-sandbox config:  openclaw.json (+ .config-hash, last-good),
#     exec-approvals.json, workspace/ (bootstrap md + skills/),
#     plugin-skills/ (ALL skills), memory/, cron/, hooks/
#   - control-plane L7 policy  (openshell policy get … --full)
#   - systemd units            (/usr/local/bin + /etc/systemd/system)
#   - credentials              (~/.nemoclaw.env, chmod 600)
#
# Safe to run repeatedly. Finds the container by the openshell-the-king-* name
# pattern, so it survives a re-onboard that changes the UUID suffix.
#
# Usage:
#   bash recapture.sh           # interactive (confirms before overwriting)
#   bash recapture.sh --yes     # non-interactive
# =============================================================================
set -euo pipefail

SANDBOX="${SANDBOX:-the-king}"
HOME_DIR="/home/democenter"
BK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC="$BK/sandbox-config"
PROJECT_DIR="$(dirname "$BK")"
SANDBOX_DIR="/sandbox/.openclaw"
NEMOCLAW="${HOME_DIR}/.local/bin/nemoclaw"
OPENSHELL="${HOME_DIR}/.local/bin/openshell"
export PATH="${HOME_DIR}/.npm-global/bin:${HOME_DIR}/.local/bin:/usr/local/bin:/usr/bin:/bin"

GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; BOLD=$'\e[1m'; NC=$'\e[0m'
ok()   { echo "${GREEN}✓${NC} $*"; }
info() { echo "  $*"; }
warn() { echo "${YELLOW}⚠${NC}  $*"; }
die()  { echo "${RED}✗ $*${NC}" >&2; exit 1; }
step() { echo; echo "${BOLD}— $*${NC}"; }

ASSUME_YES=0
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && ASSUME_YES=1

echo "${BOLD}Recapture hardclaw-omni '${SANDBOX}' backup snapshot${NC}"
echo "Target backup folder: $BK"
if [[ "$ASSUME_YES" != 1 ]]; then
    warn "This OVERWRITES the snapshot in this folder with current live state and rebuilds the tarball."
    read -r -p "Proceed? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || die "Aborted."
fi

# ---------------------------------------------------------------------------
step "Preflight"
# ---------------------------------------------------------------------------
command -v docker &>/dev/null || die "docker not found in PATH"
docker info &>/dev/null || die "Docker daemon not reachable"
"$NEMOCLAW" "$SANDBOX" status &>/dev/null || die "Sandbox '$SANDBOX' not known to the gateway"
CONTAINER=$(docker ps -a --filter "name=openshell-${SANDBOX}-" --format '{{.Names}}' | head -1 || true)
[[ -n "$CONTAINER" ]] || die "No sandbox container 'openshell-${SANDBOX}-*' found"
ok "Sandbox container: $CONTAINER"

mkdir -p "$SC" "$BK/policy" "$BK/systemd" "$BK/secrets" "$BK/meta"

# ---------------------------------------------------------------------------
step "Capture in-sandbox config, skills, workspace, memory"
# ---------------------------------------------------------------------------
cp_out() {  # <container-path> <local-dest>
    docker cp "${CONTAINER}:$1" "$2" 2>/dev/null && info "captured: $(basename "$1")" \
        || info "skip (absent): $(basename "$1")"
}
for f in openclaw.json .config-hash openclaw.json.last-good exec-approvals.json; do
    cp_out "$SANDBOX_DIR/$f" "$SC/$f"
done
# Directories: remove the local copy first so removed skills/files don't linger.
for d in workspace plugin-skills memory cron hooks; do
    rm -rf "${SC:?}/$d"
    docker cp "${CONTAINER}:$SANDBOX_DIR/$d" "$SC/$d" 2>/dev/null && info "captured dir: $d" || info "skip dir: $d"
done
rm -rf "$SC/workspace/.openclaw" 2>/dev/null || true   # nested ephemeral

# Validate the captured config before trusting the snapshot.
python3 -c "import json; json.load(open('$SC/openclaw.json'))" \
    || die "Captured openclaw.json is not valid JSON — aborting (old snapshot left intact above this point)"
echo "  skills captured:"; find "$SC" -name SKILL.md | sed "s#$SC/#    #" | sort

# ---------------------------------------------------------------------------
step "Capture control-plane L7 policy"
# ---------------------------------------------------------------------------
"$OPENSHELL" policy get "$SANDBOX" --full 2>/dev/null | sed -n '/^version:/,$p' > "$BK/policy/policy-active.yaml"
if grep -q '^network_policies:' "$BK/policy/policy-active.yaml"; then
    ok "Policy captured ($(wc -l < "$BK/policy/policy-active.yaml") lines)"
    grep -q 'protocol: http' "$BK/policy/policy-active.yaml" && \
        warn "Captured policy contains 'protocol: http' — that is the bad pattern; check before relying on it."
else
    warn "Policy capture looks empty — check 'openshell policy get $SANDBOX --full'"
fi
# Refresh the on-disk policy template too (reference)
cp "${HOME_DIR}/.nemoclaw/source/nemoclaw-blueprint/policies/openclaw-sandbox.yaml" \
   "$BK/policy/openclaw-sandbox.template.yaml" 2>/dev/null || true

# ---------------------------------------------------------------------------
step "Capture systemd units (with safety guard)"
# ---------------------------------------------------------------------------
# Guard: don't let a stale, not-yet-replaced wrapper (one that actually invokes
# `onboard`) overwrite the good copy already in this backup.
live_start="/usr/local/bin/nemoclaw-sandbox-start"
if [[ -f "$live_start" ]] && grep -nE '(\$NEMOCLAW|nemoclaw)[^#]*onboard' "$live_start" | grep -vq '^\s*#'; then
    warn "Installed $live_start still auto-onboards (stale) — KEEPING the corrected copy already in the backup."
else
    for u in nemoclaw-sandbox-start nemoclaw-sandbox-stop; do
        [[ -f "/usr/local/bin/$u" ]] && cp "/usr/local/bin/$u" "$BK/systemd/$u" && chmod 755 "$BK/systemd/$u" && info "captured: $u"
    done
    [[ -f /etc/systemd/system/nemoclaw-sandbox.service ]] && \
        cp /etc/systemd/system/nemoclaw-sandbox.service "$BK/systemd/nemoclaw-sandbox.service" && info "captured: nemoclaw-sandbox.service"
    ok "Systemd units captured from live"
fi

# ---------------------------------------------------------------------------
step "Capture credentials"
# ---------------------------------------------------------------------------
if [[ -f "${HOME_DIR}/.nemoclaw.env" ]]; then
    cp "${HOME_DIR}/.nemoclaw.env" "$BK/secrets/nemoclaw.env"
    chmod 600 "$BK/secrets/nemoclaw.env"
    ok "Captured ~/.nemoclaw.env (chmod 600)"
fi
printf '# Never commit secrets\n*\n!.gitignore\n' > "$BK/secrets/.gitignore"

# ---------------------------------------------------------------------------
step "Write metadata, manifest, and rebuild tarball"
# ---------------------------------------------------------------------------
pol_ver=$("$OPENSHELL" policy get "$SANDBOX" 2>/dev/null | awk -F: '/Version/{gsub(/ /,"",$2);print $2}' | head -1)
{
    echo "captured_utc: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "host: $(hostname)"
    echo "sandbox: ${SANDBOX}"
    echo "model: qwen3.6-35b-a3b-dflash (external vLLM :8000)"
    echo "searxng_port: 8888"
    echo "container_at_capture: ${CONTAINER}"
    echo "policy_version_at_capture: ${pol_ver:-unknown}"
    echo "nemoclaw_tag: v0.0.56"
    echo "skills_captured: $(find "$SC" -name SKILL.md -printf '%P\n' | paste -sd, -)"
} > "$BK/meta/capture-info.txt"

( cd "$BK" && find . -type f ! -name MANIFEST.txt -printf '%P\n' | sort \
    | while read -r f; do sha256sum "$f"; done > MANIFEST.txt )
ok "MANIFEST.txt regenerated ($(wc -l < "$BK/MANIFEST.txt") files)"

STAMP=$(date +%Y%m%d)
TARBALL="${PROJECT_DIR}/nemoclaw-backup-day1-${STAMP}.tar.gz"
rm -f "$TARBALL"
( cd "$PROJECT_DIR" && tar -czf "$TARBALL" --owner=democenter --group=democenter "$(basename "$BK")" )
chmod 600 "$TARBALL"
ok "Tarball rebuilt: $TARBALL"
echo "  sha256: $(sha256sum "$TARBALL" | awk '{print $1}')"

echo
ok "${BOLD}Recapture complete.${NC}"
