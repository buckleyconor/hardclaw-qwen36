# Cloning a Second NemoClaw Agent — Deployment Guide

`clone-agent.sh` stands up an **additional**, independent NemoClaw agent on this
GB10 host, using the `nemoclaw-backup-day1/` snapshot as the golden template and
applying every known-good fix automatically (toolSearch off, SearXNG web search,
`searxng_local` policy with the SSRF `allowed_ips` bypass, no-auto-onboard reboot
wrapper, correct ownership/hash).

It does **not** clone `the-king`'s identity or secrets. The new agent is onboarded
fresh (its own gateway tokens, its own openclaw.json) and gets its **own** Telegram
bot. By default it also starts with **fresh memory**, so it's a genuinely separate
assistant rather than a twin.

---

## Why you can't just `restore.sh` a second agent

`restore.sh` is hardcoded to `the-king` and overlays config onto the *existing*
sandbox. Several things are host-wide singletons that would collide if duplicated:

| Resource | Conflict if shared | How clone-agent handles it |
|---|---|---|
| **Telegram bot token** | Telegram allows only one `getUpdates` long-poll per bot → constant `409 Conflict`, messages bouncing between agents | You supply a **new** bot token (`--bot-token`); it's wired into the new agent only |
| **Sandbox name** | everything is keyed on it | `--name` must be unique; preflight refuses an existing one |
| **systemd unit** | one `nemoclaw-sandbox.service` | installs a **per-agent** `nemoclaw-sandbox-<name>.service` |
| **gateway auth tokens / dashboard** | twins | fresh onboard generates new ones; each container has its own netns so internal `:18789` doesn't clash |

Shared with no conflict: the external **vLLM** (`:8000`), **SearXNG** (`:8888`),
and the **OpenShell gateway** (it's explicitly multi-sandbox).

---

## Prerequisites

1. **A new Telegram bot.** In Telegram, talk to **@BotFather** → `/newbot` →
   get a token like `8123456789:AAH...`. (Each agent needs its own bot.)
2. **Your Telegram user ID** (same one you use for `the-king` is fine; you'll just
   be DMing two different bots). Get yours from @userinfobot in Telegram.
3. **Shared services running:** the external vLLM project (serving
   `qwen3.6-35b-a3b-dflash` on `:8000`) and SearXNG on `:8888`.
4. **The template present:** `nemoclaw-backup-day1/` (run its `recapture.sh` first
   if you want the very latest skills baked into the clone).
5. `expect` installed (`sudo apt-get install -y expect`) — used for the onboard wizard.

---

## Usage

Always preview first with `--dry-run` (makes **no** changes):

```bash
cd ~/projects/hardclaw-omni

bash clone-agent.sh \
  --name the-duke \
  --bot-token 8123456789:AAH_your_NEW_bot_token \
  --user-id <your-telegram-user-id> \
  --dry-run
```

When the dry-run looks right, run it for real (you'll be prompted for `sudo`
once, for the systemd files):

```bash
bash clone-agent.sh \
  --name the-duke \
  --bot-token 8123456789:AAH_your_NEW_bot_token \
  --user-id <your-telegram-user-id>
```

### Options

| Flag | Default | Meaning |
|---|---|---|
| `--name` | *(required)* | New sandbox name, lowercase/hyphens (e.g. `the-duke`) |
| `--bot-token` | *(required)* | **New** Telegram bot token from @BotFather |
| `--user-id` | *(required)* | Telegram user ID allowed to DM the new bot |
| `--model` | `qwen3.6-35b-a3b-dflash` | Served model name on the vLLM endpoint |
| `--vllm-port` | `8000` | Shared vLLM port |
| `--searxng-port` | `8888` | Shared SearXNG port |
| `--template-dir` | `./nemoclaw-backup-day1` | Golden-template source (skills, policy, bootstrap) |
| `--copy-memory` | *(off)* | Copy `the-king`'s memory DB into the new agent (makes it remember as if it were the-king). Omit for a fresh mind. |
| `--dry-run` | *(off)* | Print the plan; change nothing |

---

## What it does (7 steps)

1. **Preflight** — checks Docker, the CLIs, `expect`, vLLM reachability, that the
   template exists, and that `--name` isn't already taken.
2. **Onboard** the new sandbox via the same `expect` flow `install.sh` uses
   (provider = OpenAI-compatible, the vLLM endpoint, the model). Telegram/search
   are answered *No* here and configured explicitly next. Result: a fresh
   container + openclaw.json with its own gateway tokens.
3. **Config deltas** into the fresh openclaw.json: `toolSearch=false`, SearXNG as
   the `web.search` provider + `searxng` plugin baseUrl, `reasoning=true` +
   `thinkingFormat`, `skipBootstrap=false`, and the **Telegram channel** wired to
   your new bot token + allowlist (egress proxy read from the container, not
   hardcoded).
4. **Policy** — applies `policy/policy-active.yaml` under the new name via
   `openshell policy set <name>` (the content is sandbox-agnostic, incl. the
   `searxng_local` SSRF `allowed_ips` bypass and `telegram_bot`).
5. **Skills + bootstrap** — copies `plugin-skills/` (meal-planner, ai-news),
   `workspace/skills/`, and the workspace `*.md` bootstrap (incl. `TOOLS.md` whose
   web_search instructions are essential). **Fresh memory** unless `--copy-memory`.
   Fixes ownership to `sandbox:sandbox` and recomputes `.config-hash`.
6. **Per-agent systemd unit** — generates and installs
   `/usr/local/bin/nemoclaw-sandbox-<name>-{start,stop}` and
   `/etc/systemd/system/nemoclaw-sandbox-<name>.service` (same no-auto-onboard,
   gateway-first logic as the-king's), `daemon-reload`, `enable`.
7. **Restart + verify** — restarts the container, waits for the gateway, and
   checks `toolSearch=false` and that there are no L7 policy-validation errors.

---

## After it runs

- **Test:** DM the new bot from your Telegram user ID. First reply takes ~15–20 s
  (model already warm if `the-king` is active). Try a web-search question and
  `/meal-planner` (or `/ai-news`).
- **Logs / status:** `nemoclaw <name> logs --follow` · `nemoclaw <name> status`
- **Differentiate the persona (recommended):** edit the new agent's
  `IDENTITY.md`, `USER.md`, and `SOUL.md` in `/sandbox/.openclaw/workspace/` so it
  isn't a verbatim copy of the-king, then recompute the hash:
  ```bash
  C=$(docker ps --filter name=openshell-<name>- --format '{{.Names}}' | head -1)
  docker exec "$C" sh -c 'cd /sandbox/.openclaw && sha256sum openclaw.json > .config-hash'
  ```
- **Snapshot the new agent:** copy `nemoclaw-backup-day1/recapture.sh` and run it
  with `SANDBOX=<name> bash recapture.sh` to capture its own day-1 backup.

---

## Caveats & notes

- **Bot token is stored literally** in the new agent's `openclaw.json` (inside the
  sandbox, hashed). This is deterministic and avoids the fragile
  `openshell:resolve:env:<prefix>` mechanism. Treat that container's config as
  secret-bearing. If you prefer env-resolution, set `botToken` to
  `openshell:resolve:env:YOURVAR` and export `YOURVAR` for the gateway instead.
- **GPU load:** two agents share one vLLM. Concurrent heavy use competes for the
  model's batch slots — fine for light/interactive use, watch latency under load.
- **Onboard wizard is version-sensitive.** The `expect` matchers track NemoClaw
  v0.0.56 prompts. If onboarding stalls, run `nemoclaw onboard` manually (answers:
  name=`<name>`, provider=Other OpenAI-compatible/`3`, URL=`http://172.17.0.1:8000/v1`,
  key=`unused`, model=`qwen3.6-35b-a3b-dflash`, policy=Y, Telegram=N, Search=N),
  then re-run `clone-agent.sh` — it will skip onboarding once the container exists.
- **`--copy-memory`** makes the clone believe it *is* the-king (same recalled
  history/identity). Only use it if that's what you want.
- **Removing a cloned agent:** `nemoclaw <name> destroy`, then
  `sudo systemctl disable --now nemoclaw-sandbox-<name>.service` and remove the
  `/usr/local/bin/nemoclaw-sandbox-<name>-*` + unit files.
