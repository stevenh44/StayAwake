# ☕️ StayAwake

A tiny macOS menu bar app that keeps your Mac awake **while an AI coding agent is working** — and lets it sleep normally the moment they're all done.

If you kick off a long Claude Code, ChatGPT/Codex, or Cursor agent task and walk away, your Mac's screensaver and display sleep won't interrupt it. When the agents go quiet, normal power management resumes automatically. No toggles to remember.

## What it looks like

- **☕️** in the menu bar — an agent is active, screen staying awake
- **💤** in the menu bar — all quiet, normal sleep allowed

Click the icon to see which tools have been active this session and when they last did something, plus how much of today an agent was running:

```
☕️ Keeping your Mac awake
─────────────────────────
🟢 Claude — 12s ago
⚪️ Cursor — 23m ago
─────────────────────────
Today: active 3h 12m (13% of day)
Open Usage Log
─────────────────────────
Quit StayAwake
```

## How it detects each agent

There's no universal "AI is working" API, so each tool gets the most reliable signal available:

| Tool | Signal |
|---|---|
| **Claude** | Claude Code writes session transcripts (`~/.claude/projects/**/*.jsonl`) continuously — fresh write = working. Regular (non-Code) desktop-app chats have no clean signal: the app writes nothing to disk while streaming, and its idle CPU can hum high enough to defeat a CPU detector — so that watch is **off by default** (`STAYAWAKE_CLAUDE_PATTERN=claude` opts in if your Claude.app idles quietly). Cloud-side chats survive your Mac sleeping anyway. |
| **ChatGPT app / Codex** | Its log files heartbeat even when idle, so file times are useless — but CPU is ~0% idle and 20–60%+ while streaming. StayAwake measures CPU-time growth of `chatgpt`/`codex` processes between checks. |
| **Cursor agents** | [Cursor hooks](https://cursor.com/docs) touch a heartbeat file on every agent event (prompt submitted, thought, response, tool use). Fresh heartbeat = working. Manual editing in Cursor does **not** keep the Mac awake. |

Any signal within the last 10 minutes keeps the screen awake, via a `PreventUserIdleDisplaySleep` power assertion plus periodic user-activity declarations (the same official mechanism `caffeinate` uses — no mouse-jiggling).

## Install

```bash
git clone https://github.com/stevenh44/StayAwake.git
cd StayAwake
./build.sh
open StayAwake.app
```

Requires macOS 12+ and Xcode Command Line Tools (`xcode-select --install`). To start it at login: System Settings → General → Login Items → add StayAwake.

To produce an installable disk image instead, run `./make-dmg.sh` — it builds `dist/StayAwake.dmg` with the usual drag-to-Applications layout. Note the app is ad-hoc signed: if you download the DMG (rather than building it locally), macOS quarantines it and you'll need right-click → Open the first time, or `xattr -dr com.apple.quarantine /Applications/StayAwake.app`.

### Cursor hooks (optional, for Cursor detection)

```bash
mkdir -p ~/.cursor/hooks
cp cursor-hooks/stayawake-heartbeat.sh ~/.cursor/hooks/
cp cursor-hooks/hooks.json ~/.cursor/hooks.json   # merge manually if you already have hooks.json
```

Restart Cursor afterwards — it only reads `hooks.json` at startup.

## Usage log

StayAwake appends to `~/Documents/StayAwake/usage.csv` in 15-minute buckets, pruned to 90 days:

```csv
bucket,checks,awake,claude,gpt,cursor
2026-07-08T09:15,30,22,22,8,0
```

`checks` is the number of 30-second polls in the bucket; the other columns count how many of those polls found the screen being kept awake (overall and per tool). Percent of a day active = `sum(awake) × 30s ÷ 86,400`.

## Tuning

Environment variables, all optional:

| Variable | Default | Meaning |
|---|---|---|
| `STAYAWAKE_IDLE_SECS` | `600` | How long after the last activity signal to keep the screen awake |
| `STAYAWAKE_CHECK_SECS` | `30` | Poll interval |
| `STAYAWAKE_GPT_CPU_RATE` | `0.10` | CPU fraction (of one core) GPT processes must average to count as working |
| `STAYAWAKE_GPT_PATTERN` | `codex,chatgpt` | Comma-separated process-name needles for the GPT CPU detector |
| `STAYAWAKE_CLAUDE_PATTERN` | *(empty — disabled)* | Process-name needle for the Claude desktop app CPU detector; set to `claude` to enable |
| `STAYAWAKE_SCAN_DIR` | `~/.claude/projects` | Claude transcript directory |
| `STAYAWAKE_CURSOR_HEARTBEAT` | `~/.cursor/state/stayawake.heartbeat` | Cursor heartbeat file |
| `STAYAWAKE_USAGE_FILE` | `<app dir>/usage.csv` | Usage log location |

## Caveats

- Keeps the **display** awake; closing the laptop lid still sleeps the Mac.
- The GPT CPU signal is a heuristic: a long silent server-side "thinking" stretch with no local streaming can briefly read as idle (the 10-minute window bridges most of this).
- The binary is ad-hoc signed; build it yourself with `build.sh`.

## License

MIT
