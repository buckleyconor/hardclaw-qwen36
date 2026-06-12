hardclaw-omni
=============
Security-hardened NemoClaw v0.0.56 + external vLLM serving Qwen 3.6 35B A3B
on Dell Pro Max GB10 (DGX Spark, 128 GB UMA)

Features: Telegram (user-whitelisted), SearXNG local web search,
          UFW deny-all firewall, reboot-survival systemd service

Inference is served by an EXTERNAL project (dgx-spark-vllm-qwen3.6-35b-a3b-dflash)
running vLLM as a Docker unless-stopped container on :8000. hardclaw-omni only
CONSUMES it via an OpenAI-compatible provider — it does not build, start, stop,
or otherwise manage the vLLM container.


QUICK START
-----------
1.  Make sure the shared services are already running:
      - External vLLM project (container vllm-qwen3.6-35b-a3b-dflash on :8000)
      - SearXNG Docker container on :8888

2.  Create your credentials file FIRST (never skip this step):

        install -m 600 /dev/null ~/.nemoclaw.env
        cat >> ~/.nemoclaw.env <<EOF
        TELEGRAM_BOT_TOKEN=1234567890:AAABBBCCC...
        TELEGRAM_USER_ID=987654321
        SANDBOX_NAME=my-assistant
        SEARXNG_PORT=8888
        EOF

3.  Run the installer:

        bash install.sh

    Time estimate: 5–15 minutes (model weights are local — no large download).

4.  Verify the deployment:

        bash verify.sh

5.  (Optional) Confirm reboot survival:

        sudo reboot
        # wait 3 minutes, then:
        bash verify.sh


DAILY USE
---------
  nemoclaw my-assistant connect          Shell into sandbox
  nemoclaw my-assistant status           Health check
  nemoclaw my-assistant logs --follow    Stream sandbox logs
  openshell term                         Real-time policy TUI (shows blocked requests)

Inside the sandbox:
  openclaw tui                           Interactive chat
  openclaw agent --agent main --local -m "hello" --session-id test
  curl -sf https://inference.local/v1/models  Verify inference routing

Telegram:
  Send any message to your bot from Telegram user ID ${TELEGRAM_USER_ID}
  First response ~15 seconds; subsequent responses faster (KV cache)


DASHBOARD ACCESS (SSH tunnel — never expose :18789 directly)
-------------------------------------------------------------
  # On the GB10:
  openshell forward start 18789 my-assistant --background

  # From your laptop:
  ssh -L 18789:127.0.0.1:18789 <user>@<gb10-ip> -N
  # Then open: http://127.0.0.1:18789/#token=<from ~/.nemoclaw/dashboard-token.txt>


SHUTDOWN / RESTART
------------------
  bash shutdown.sh                       Stop the sandbox container
  sudo systemctl start nemoclaw-sandbox.service   Restart after manual shutdown
  sudo systemctl status nemoclaw-sandbox.service  Check service state

  Note: shutdown.sh stops ONLY the sandbox. The external vLLM and SearXNG are
  owned by their own projects (Docker unless-stopped) and are left running.


ENVIRONMENT VARIABLES
---------------------
  TELEGRAM_BOT_TOKEN    Telegram bot token from @BotFather (required)
  TELEGRAM_USER_ID      Your Telegram user ID (whitelist; get from @userinfobot) (required)
  SANDBOX_NAME          Sandbox name (default: my-assistant; live: the-king)
  SEARXNG_PORT          SearXNG container port (default: 8888)
  MODEL                 Served model name (default: qwen3.6-35b-a3b-dflash)
  NEMOCLAW_TAG          NemoClaw version (default: v0.0.56)

All variables read from ~/.nemoclaw.env — never pass secrets as CLI args.
(NGC_API_KEY is NOT needed — that was only for the old Ollama/Nemotron NGC pull.
 The current vLLM+Qwen stack is served by an external project.)


ARCHITECTURE
------------
  Dell Pro Max GB10 (128 GB UMA)
  │
  ├── UFW (deny-all inbound baseline)
  ├── vLLM :8000 — Qwen 3.6 35B A3B  [external project; consumed, not managed]
  ├── SearXNG :8888 (pre-existing Docker container)
  ├── OpenShell gateway (host daemon, :8080 — serves L7 policy via gRPC)
  └── Docker (NVIDIA runtime, cgroupns=host)
       └── OpenShell sandbox container (openshell-<name>-<uuid>, unless-stopped)
            └── k3s (embedded)
                 └── NemoClaw sandbox (Landlock + seccomp + netns)
                      └── OpenClaw agent
                           ├── Inference → OpenShell → vLLM :8000
                           ├── Web search → OpenShell → SearXNG :8888
                           └── Telegram → OpenShell → api.telegram.org:443

Inference flow: the sandbox never sees vLLM's real port — all calls go through
the OpenShell gateway (inference.local) which enforces the network policy.


SECURITY: Q1 2026 OPENCLAW INCIDENTS MITIGATED
-----------------------------------------------
  Port 18789 exposed to internet   → UFW deny 18789; localhost-only access
  clawhub.com supply chain attack  → removed from network_policies (never re-add)
  Unrestricted sandbox egress      → deny-all policy; only SearXNG + Telegram
  mDNS self-advertisement          → avahi-daemon disabled
  Inference port exposed to LAN    → UFW: only Docker bridge ranges reach :8000
  Telegram bot open to all         → dmPolicy=allowlist + allowFrom in openclaw.json
  Bot token in shell history       → stored in ~/.nemoclaw.env (chmod 600 only)
  Telemetry egress (sentry, etc.)  → removed from network_policies
  NVIDIA cloud inference from box  → removed; all inference is local vLLM


POLICY MANAGEMENT
-----------------
  View active policy (gateway name "nemoclaw", sandbox "the-king"):
    openshell policy get the-king --full

  Edit and re-apply the network policy:
    nano ~/.nemoclaw/source/nemoclaw-blueprint/policies/openclaw-sandbox.yaml
    openshell policy set the-king --policy <file> --yes

  IMPORTANT: After ANY manual edit to openclaw.json, recompute the hash, or every
  nemoclaw-start will exit with a [SECURITY] integrity check FAILED error:
    CONTAINER=$(docker ps --filter name=openshell-the-king- --format '{{.Names}}' | head -1)
    docker exec "$CONTAINER" sh -c "cd /sandbox/.openclaw && sha256sum openclaw.json > .config-hash"


TROUBLESHOOTING
---------------

§ Inference fails entirely
  vLLM is provisioned by its own external project. If inference fails, check/start
  that project (container vllm-qwen3.6-35b-a3b-dflash on :8000):
    docker logs vllm-qwen3.6-35b-a3b-dflash
    curl -sf http://localhost:8000/v1/models

§ Inference times out (60-second cutoff)
  Root cause: OpenShell proxy has a default 60s request timeout.
  Fix (hot-reloadable, no sandbox restart):
    openshell inference update --timeout 300
    openshell inference get   # verify

§ Telegram bridge returns nothing (silent failure)
  Three causes — apply all three in order:

  Issue A — proxy timeout too short: apply timeout fix above.

  Issue B — config integrity check failed:
    Bridge log shows: [SECURITY] openclaw.json integrity check FAILED
    Fix: CONTAINER=$(docker ps --filter name=openshell-the-king- --format '{{.Names}}' | head -1)
         docker exec "$CONTAINER" sh -c "cd /sandbox/.openclaw && sha256sum openclaw.json > .config-hash"

  Issue C — session lock conflict:
    Bridge log shows: session file locked (timeout 10000ms)
    Fix: sed -i \
           -e 's|replace(/\[^a-zA-Z0-9-\]/g, "")|replace(/[^0-9]/g, "").slice(0, 12)|' \
           -e 's|--session-id \${shellQuote("tg-" + safeSessionId)}|--to ${shellQuote("+" + safeSessionId)}|' \
           ~/.nemoclaw/source/scripts/telegram-bridge.js
         # Restart bridge:
         kill $(pgrep -f telegram-bridge) 2>/dev/null; nemoclaw start

  NOTE: The bridge script fix (Issue C) is lost after nemoclaw uninstall/reinstall.
  Re-apply the sed one-liner after any upgrade.

§ web_search loops / "I can't access the internet"
  tools.toolSearch must be false in openclaw.json — when true, tools are hidden
  behind a compact prompt surface the local model can't drive (it loops on
  tool_search_code), silently breaking web_search and file reads.

§ CAP_SETPCAP warning in logs
  Not an error. OpenShell drops this capability by default. The bridge continues.

§ SearXNG not reachable from sandbox
  Check 1: curl "http://localhost:${SEARXNG_PORT}/search?q=test&format=json"   (on host)
  Check 2: sudo ufw status | grep ${SEARXNG_PORT}
  Check 3: the searxng_search policy needs allowed_ips (private ranges) to bypass
           OpenShell's SSRF guard, which blocks private IPs before the L7 policy
           is consulted (e.g. host.openshell.internal → 172.22.0.1).


SOFTWARE INVENTORY
------------------
  NemoClaw       v0.0.56   (NVIDIA alpha agent orchestration)
  OpenShell      bundled with NemoClaw v0.0.56
  OpenClaw       bundled with NemoClaw v0.0.56
  vLLM           external project (dgx-spark-vllm-qwen3.6-35b-a3b-dflash)
  Model          qwen3.6-35b-a3b-dflash (served by external vLLM on :8000)
  SearXNG        pre-existing Docker container on host :8888


KNOWN LIMITATIONS
-----------------
  - NemoClaw v0.0.56 is alpha. NVIDIA provides it AS IS for demo use only.
  - No MCP tool-level inspection. OpenShell controls connections but cannot
    inspect content inside permitted TLS tunnels.
  - SearXNG results are unfiltered — the agent can receive any web content.
  - Telegram bridge session-lock fix is lost on nemoclaw uninstall/reinstall.
  - openclaw.json hash must be recomputed after any manual edit.
  - Dashboard token is long-lived; rotate when not in use.
  - The service NEVER re-onboards — a missing sandbox is a manual-recovery
    situation (auto-onboard once clobbered the sandbox with the wrong model).
  - Host compromise = sandbox compromise. NemoClaw protects against agent
    misbehaviour, not a compromised host.


MAINTENANCE
-----------
  Watch NemoClaw releases:   https://github.com/NVIDIA/NemoClaw/releases
  Rotate Telegram token:     @BotFather → /revoke  (after each demo)
  Check denied requests:     nemoclaw the-king logs -n 500 | grep deny
  vLLM lifecycle:            managed by its own project, not here

  Full uninstall:
    cd ~/.nemoclaw/source && ./uninstall.sh --yes
    sudo systemctl disable --now nemoclaw-sandbox.service
    sudo rm /etc/systemd/system/nemoclaw-sandbox.service
    sudo rm /usr/local/bin/nemoclaw-sandbox-{start,stop}
