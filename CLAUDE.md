# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

**hardclaw-omni** is a fully automated deployment for security-hardened NemoClaw v0.0.56
on Dell Pro Max GB10 (DGX Spark). It is a deployment automation project, not a
buildable software project — there are no build scripts, test suites, or package managers.

**Differences from hardclaw v1 (../hardclaw/):**
- Model: `qwen3.6-35b-a3b-dflash` served by vLLM vs Nemotron 3 Super 120B
  (the deployment pivoted from the originally-planned Ollama + Nemotron Nano Omni 30B
  to an external vLLM serving Qwen 3.6 35B A3B)
- NemoClaw version: v0.0.56 (v1 used v0.0.4)
- SearXNG web search integration via host Docker container on :8888
- Telegram with `allowed_user_ids` whitelist enforcement (v1 had no whitelist)
- Additional sysctl hardening (rp_filter, ICMP redirects, SYN cookies)
- UFW rules for SearXNG :8888 in addition to vLLM :8000

## Architecture

```
Dell Pro Max GB10 (Ubuntu 24.04, 128 GB UMA)
  │
  ├── UFW (deny-all inbound)
  ├── vLLM (Docker, :8000) — Qwen 3.6 35B A3B  [owned by its OWN external
  │     project: ~/projects/dgx-spark-vllm-qwen3.6-35b-a3b-dflash; this repo
  │     only consumes it — does not build/start/stop it]
  ├── SearXNG (Docker, :8888) [pre-existing, not managed here]
  ├── OpenShell gateway (host daemon, :8080) — serves L7 sandbox policy via gRPC
  └── Docker (NVIDIA runtime, cgroupns=host)
       └── OpenShell sandbox container (openshell-the-king-*, unless-stopped)
            └── k3s (embedded)
                 └── NemoClaw sandbox (Landlock + seccomp + netns)
                      └── OpenClaw agent
                           ├── Inference → OpenShell → vLLM :8000
                           ├── Web search → OpenShell → SearXNG :8888
                           └── Telegram → OpenShell → api.telegram.org:443
```

**Reboot survival:** vLLM, SearXNG, and the sandbox container are all Docker
`unless-stopped`, so Docker restarts them on boot. The `openshell-gateway` host
daemon has no boot unit of its own (it is auto-spawned on first CLI use), so the
`nemoclaw-sandbox.service` systemd unit exists mainly to spawn the gateway at boot
and ensure the sandbox container cleanly fetches its policy. The service NEVER
re-onboards — a missing sandbox is a manual-recovery situation (auto-onboard once
clobbered the sandbox with the wrong model).

## Key Files

| File | Purpose |
|------|---------|
| `install.sh` | Automated deployment (phases 0–10, idempotent) |
| `verify.sh` | 7-layer security + health checks (run any time) |
| `shutdown.sh` | Clean teardown |
| `README.md` | Quick start + troubleshooting |
| `policies/news-sources.yaml` | Egress preset: news domains the agent may `web_fetch` (AI News cron + interactive) |
| `policies/weather-services.yaml` | Egress preset: wttr.in + met.ie for the daily-weather cron |

Runtime files created during deployment (not in repo):
- `~/.nemoclaw.env` — credentials (chmod 600; user creates before running install)
- `~/.nemoclaw/source/nemoclaw-blueprint/policies/openclaw-sandbox.yaml` — sandbox policy
- `/etc/systemd/system/nemoclaw-sandbox.service` — reboot survival unit

## Credentials

All secrets live in `~/.nemoclaw.env` (chmod 600). Never log them or pass as CLI args.
Required: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_USER_ID`.
Optional: `SANDBOX_NAME` (live: `the-king`), `SEARXNG_PORT` (live: `8888`),
`MODEL` (live: `qwen3.6-35b-a3b-dflash`), `NEMOCLAW_TAG`.
(`NGC_API_KEY` was only needed for the old Ollama/Nemotron NGC model pull; the
current vLLM+Qwen stack is served by an external project and does not use it.)

## Security Context

This deployment explicitly mitigates 10 Q1 2026 OpenClaw incidents:
- clawhub.com is removed from network_policies and must never be re-added
- api.telegram.org and SearXNG :8888 are the only outbound network_policy entries
- Telegram bridge has `allowed_user_ids` set to the operator's Telegram user ID
- Dashboard port 18789 is UFW-denied; only accessible via SSH tunnel

## Egress Policy Presets (`policies/`)

The sandbox network policy is deny-all by default, so `web_search` (via SearXNG)
returns snippets but the agent cannot `web_fetch` (open) the actual article/forecast
pages — those come back as `fetch failed`. Without a domain whitelist, the AI News and
weather briefings are built from search snippets only, not full article content. The
presets here re-open a small, trusted set of hosts to preserve the deny-all posture:

| Preset | Hosts opened | Consumed by |
|--------|--------------|-------------|
| `policies/news-sources.yaml` | rte.ie, irishtimes.com, thejournal.ie, bbc.com/.co.uk, techcrunch.com, theregister.com, therundown.ai, tldr.tech, codenewsletter.ai, superhuman.ai (apex + www, GET only) | AI News cron + interactive "latest news" |
| `policies/weather-services.yaml` | wttr.in (:80 + :443), met.ie / www.met.ie | daily-weather cron |

Apply (idempotent, **hot-reloads** — no sandbox restart needed; survives container
restart but a full NemoClaw reinstall drops them, so re-apply after reinstall):

```bash
nemoclaw the-king policy-add --from-file policies/news-sources.yaml --dry-run   # review first
nemoclaw the-king policy-add --from-file policies/news-sources.yaml --yes
nemoclaw the-king policy-add --from-file policies/weather-services.yaml --yes
nemoclaw the-king policy-list                       # confirm both show ● applied
```

Each endpoint uses `protocol: rest` + `enforcement: enforce` with a `GET /**` allow
rule. Keep the list minimal — every host added widens sandbox egress. A malformed
`protocol:` will crash-loop the container on the next restart (see Known Issues).

## Deployment Phases

| Phase | Action |
|-------|--------|
| 0 | Preflight (OS, GPU, Docker, credentials, SearXNG, disk) |
| 1 | Host hardening (UFW deny-all, sysctl, avahi disable) |
| 2 | Docker + NVIDIA runtime hardening |
| 3 | Verify external vLLM is up on :8000 (not provisioned here) |
| 4 | NemoClaw v0.0.56 install + wizard onboard |
| 5 | Sandbox policy hardening (deny-all + SearXNG + Telegram exceptions) |
| 6 | SearXNG web search injection into openclaw.json |
| 7 | Telegram integration (token, whitelist, bridge fixes, timeout) |
| 8 | Systemd service (reboot survival) |
| 9 | Quick verification |
| 10 | Summary |

## Operational Commands

```bash
# Sandbox (live sandbox name is "the-king")
nemoclaw the-king connect              # Shell into sandbox
nemoclaw the-king status               # Health check
nemoclaw the-king logs --follow        # Stream logs
openshell term                         # Real-time policy TUI

# Monitoring
nemoclaw the-king logs -n 500 | grep deny   # Denied egress requests

# Inside sandbox
openclaw tui                           # Interactive chat
curl -sf https://inference.local/v1/models      # Verify inference routing
curl -sf "http://host.openshell.internal:8888/search?q=test&format=json"  # Verify SearXNG

# Policy (gateway name is "nemoclaw"; sandbox is "the-king")
openshell policy get the-king --full   # Show full active policy as YAML
openshell policy set the-king --policy <file> --yes   # Replace policy (validated server-side)
nemoclaw the-king policy-list          # List applied presets

# Verification
bash verify.sh                         # 7-layer security check
```

## Important: openclaw.json Hash

After ANY manual edit to openclaw.json inside the k3s PVC, you must recompute
the SHA256 hash or every nemoclaw-start call will exit immediately with a
[SECURITY] integrity check FAILED error:

```bash
CONTAINER=$(docker ps --filter name=openshell-the-king- --format '{{.Names}}' | head -1)
docker exec "$CONTAINER" sh -c "cd /sandbox/.openclaw && sha256sum openclaw.json > .config-hash"
```

## Known Issues

- Telegram bridge session-lock fix (`--to` vs `--session-id`) is lost on NemoClaw reinstall
- Network policies require `nemoclaw destroy` + `onboard` to lock new Landlock/seccomp settings
- Network policies (only) can be hot-reloaded without sandbox restart
- `tools.toolSearch` must be `false` in openclaw.json — when true, tools are hidden
  behind a "compact prompt surface" the local model can't drive (it loops on
  `tool_search_code`), silently breaking web_search and file reads
- SearXNG network policy needs `allowed_ips` (private ranges) to bypass OpenShell's
  SSRF guard, which blocks private IPs (e.g. host.openshell.internal → 172.22.0.1)
  before the L7 policy is consulted
- Editing openclaw.json or the policy needs a sandbox restart to take effect, and the
  restart re-validates the control-plane policy — a previously-accepted but invalid
  policy (e.g. wrong `protocol:`) will crash-loop the container on the next restart
- vLLM is provisioned by its own external project; if inference fails, check/start
  that project (container `vllm-qwen3.6-35b-a3b-dflash` on :8000) — not this repo
