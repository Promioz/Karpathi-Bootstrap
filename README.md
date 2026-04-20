# Karpathi-Bootstrap

One-command disaster recovery for the autonomous wiki system ("Karpathi").

Pairs two git submodules:

- **`Wiki/`** → [CLoude_Wiki](https://github.com/Promioz/CLoude_Wiki) — daemon code, wiki pages, agents, workflows
- **`LLM/`** → [Ai-Config](https://github.com/Promioz/Ai-Config) — CLAUDE.md, skills, hooks

…plus a `bootstrap.sh` that wires everything together on a fresh Mac, and a
backup copy of the watchdog `launchd` plist.

---

## Restore from scratch (fresh Mac)

### 1. Install prerequisites

```bash
# Xcode Command Line Tools (gives you git)
xcode-select --install

# Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Node.js + Claude Code CLI
brew install node
npm install -g @anthropic-ai/claude-code

# Log in once, interactively (uses your Claude Max subscription)
claude
# …in the REPL: /login, complete OAuth, then /exit
```

### 2. Clone this repo with submodules

```bash
git clone --recurse-submodules https://github.com/Promioz/Karpathi-Bootstrap.git ~/Dev/Karpathi-Bootstrap
cd ~/Dev/Karpathi-Bootstrap
```

### 3. Run the bootstrap

```bash
./bootstrap.sh
```

That handles:
- `npm install` inside `Wiki/`
- `~/.claude/CLAUDE.md` + `~/.claude/skills` symlinks into `LLM/`
- `claude mcp add wiki-search` registration
- Watchdog script install at `~/.local/bin/karpathi-watchdog.sh`
- Watchdog `launchd` agent install (fires every 15 min)
- `pm2 start ecosystem.config.cjs && pm2 save && pm2 startup launchd`

Expected runtime: 3–5 minutes.

### 4. Verify

```bash
pm2 list                     # meta-orchestrator → online
claude mcp list              # wiki-search → ✓ Connected
bash ~/.local/bin/karpathi-watchdog.sh; echo $?   # → 0
```

---

## Keeping the bootstrap snapshot fresh

The submodules are pinned to specific commits. The Wiki repo auto-commits every
6 hours via the topology daemon, so this parent repo drifts behind reality over
time.

To refresh the snapshot (point submodules at latest `main`):

```bash
cd ~/Dev/Karpathi-Bootstrap
./refresh.sh
```

Recommended cadence: weekly, or before any known "wipe and restore" event.

---

## What this does NOT back up

- **OAuth credentials** (`~/.claude/.credentials.json`) — you log in once via `claude` after install
- **macOS Keychain** (GitHub token) — `gh auth login` on fresh machine, or re-save in keychain
- **PM2 process state** (`~/.pm2/dump.pm2`) — recreated by `bootstrap.sh`

These are machine-local secrets that should not live in a git repo.

---

## Layout

```
Karpathi-Bootstrap/
├── Wiki/                                         (submodule)
├── LLM/                                          (submodule)
├── launchd/
│   └── com.mm.karpathi-watchdog.plist.template   (portable plist, __HOME__ substituted at install)
├── bootstrap.sh                                  (run once on fresh machine)
├── refresh.sh                                    (run periodically to pin latest)
└── README.md
```
