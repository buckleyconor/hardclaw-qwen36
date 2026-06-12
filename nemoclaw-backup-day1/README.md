# nemoclaw-backup-day1

A known-good "day 1" snapshot of the hardclaw-omni **`the-king`** NemoClaw agent,
captured **2026-06-04** after fixing web search, the meal-planner skill, and the
reboot-survival systemd units. Use it to restore the agent to this exact state.

## When to use this

Something broke the agent and you want it back fast, or you reinstalled NemoClaw
and want the day-1 config back. Run `restore.sh` (see below).

## What's in here

```
nemoclaw-backup-day1/
├── restore.sh                     # automated restore (idempotent, never onboards)
├── README.md                      # this file
├── MANIFEST.txt                   # sha256 of every backed-up file
├── sandbox-config/                # contents of the container's /sandbox/.openclaw/
│   ├── openclaw.json              #   main agent config (toolSearch=false, SearXNG provider, Telegram)
│   ├── .config-hash               #   integrity hash (recomputed on restore anyway)
│   ├── openclaw.json.last-good    #   reference copy
│   ├── exec-approvals.json        #   approved exec commands
│   ├── workspace/                 #   AGENTS/SOUL/TOOLS/IDENTITY/USER/HEARTBEAT.md + skills/
│   ├── plugin-skills/             #   meal-planner (SKILL.md, references, data, scripts)
│   ├── memory/                    #   agent long-term memory (main.sqlite)
│   ├── cron/  hooks/              #   agent cron jobs and hooks
├── policy/
│   ├── policy-active.yaml         # the LIVE L7 sandbox policy (searxng_local rest+allowed_ips, telegram_bot, …)
│   └── openclaw-sandbox.template.yaml  # the on-disk policy template (reference only)
├── systemd/
│   ├── nemoclaw-sandbox-start     # corrected reboot wrapper (no auto-onboard; ensures gateway; restarts container)
│   ├── nemoclaw-sandbox-stop      # corrected stop wrapper (stops only the sandbox container)
│   └── nemoclaw-sandbox.service   # systemd unit
└── secrets/
    ├── nemoclaw.env               # ~/.nemoclaw.env — CONTAINS THE TELEGRAM BOT TOKEN (chmod 600)
    └── .gitignore                 # keeps secrets out of git
```

## Prerequisites for restore

`restore.sh` **overlays** this config onto an existing, already-onboarded
`the-king` sandbox. It does **not** onboard or recreate the sandbox (auto-onboard
once clobbered the agent). So before restoring you need:

1. **Docker running** and your user in the `docker` group.
2. **The external vLLM** serving `qwen3.6-35b-a3b-dflash` on `:8000` — it's owned
   by its own project (`~/projects/dgx-spark-vllm-qwen3.6-35b-a3b-dflash`,
   Docker `unless-stopped`). This backup does **not** include it.
3. **SearXNG** running on `:8888` (also its own container, `unless-stopped`).
4. **An onboarded `the-king` sandbox** — the `openshell-the-king-*` container
   exists and `nemoclaw the-king status` works. On a blank machine, run the
   repo's `install.sh` first to onboard, then run this restore.

## How to restore

```bash
cd ~/projects/hardclaw-omni/nemoclaw-backup-day1
bash restore.sh          # add --yes to skip the confirmation prompt
```

You'll be prompted for `sudo` (only for the systemd files in `/usr/local/bin` and
`/etc/systemd/system`). Everything else uses Docker directly.

### What restore.sh does

1. Restores `~/.nemoclaw.env` (backs up any existing one first).
2. Installs the systemd units, `daemon-reload`, `enable`, `reset-failed`.
3. Applies `policy/policy-active.yaml` via `openshell policy set` (validated server-side).
4. Copies the in-sandbox config/skills/workspace/memory into the container,
   fixes ownership to `sandbox:sandbox`, and recomputes `.config-hash`.
5. Restarts the sandbox container and waits for the gateway to come back.
6. Verifies `toolSearch=false` and that there are no policy-validation errors.

It is **idempotent** — safe to run more than once. It finds the container by the
`openshell-the-king-*` name pattern, so it still works after a re-onboard changes
the container's UUID suffix.

## Caveats

- **Telegram token caveat.** `openclaw.json` references the bot token indirectly
  as `openshell:resolve:env:<key>_TELEGRAM_BOT_TOKEN`, where `<key>` is assigned
  by the gateway. On the **same machine** this is stable and Telegram resumes
  automatically. After a **full re-onboard** the key can change; if Telegram
  doesn't come back, re-run the repo's Telegram setup (install.sh Phase 7) or
  re-point that `botToken` field, then recompute the hash.
- **Secrets.** `secrets/nemoclaw.env` contains your Telegram bot token. Keep this
  folder private; don't commit or share it. (`secrets/.gitignore` guards against
  accidental commits.)
- **Not backed up (intentionally):** ephemeral/regenerable state — agent sessions
  & trajectories (`agents/`, wiped every 30 min by cron anyway), `npm/`,
  `extensions/`, `logs/`, completions, media. The vLLM model and SearXNG are
  separate projects.
- **`NGC_API_KEY`** in `nemoclaw.env` is a leftover from the original Ollama/Nemotron
  plan; the current vLLM+Qwen stack doesn't use it.

## Re-capturing a fresh snapshot

To refresh this backup after making new known-good changes, re-run the capture
steps (or ask Claude to). The key sources are: the container's `/sandbox/.openclaw/`,
`openshell policy get the-king --full`, `/usr/local/bin/nemoclaw-sandbox-*`,
`/etc/systemd/system/nemoclaw-sandbox.service`, and `~/.nemoclaw.env`.
