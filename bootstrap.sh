#!/usr/bin/env bash
# Karpathi-Bootstrap — one-command disaster recovery for the autonomous wiki system.
#
# Prereqs this script does NOT handle (install them first):
#   - Homebrew         (https://brew.sh)
#   - Node.js >= 25    (brew install node)
#   - Git              (comes with Xcode CLT: xcode-select --install)
#   - Claude Code CLI  (npm install -g @anthropic-ai/claude-code) and `claude` logged in
#
# This script handles everything else: npm install, symlinks, MCP registration,
# PM2 startup, launchd watchdog.

set -euo pipefail

BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIKI_DIR="$BOOTSTRAP_DIR/Wiki"
LLM_DIR="$BOOTSTRAP_DIR/LLM"

echo "=== Karpathi-Bootstrap ==="
echo "Bootstrap dir: $BOOTSTRAP_DIR"
echo ""

# ── 0. Sanity checks ────────────────────────────────────────────────────

for cmd in node npm git claude; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: '$cmd' not found in PATH. Install it and re-run."
    exit 1
  fi
done

if [ ! -d "$WIKI_DIR/.git" ] || [ ! -d "$LLM_DIR/.git" ]; then
  echo "ERROR: Wiki or LLM submodule missing. Did you clone with --recurse-submodules?"
  echo "Fix: cd '$BOOTSTRAP_DIR' && git submodule update --init --recursive"
  exit 1
fi

if ! npm ls -g --depth=0 pm2 >/dev/null 2>&1 && ! command -v pm2 >/dev/null 2>&1; then
  echo "Installing pm2 globally..."
  npm install -g pm2
fi

echo "✓ Prerequisites present"
echo ""

# ── 1. Install Wiki dependencies ────────────────────────────────────────

echo "→ Installing Wiki dependencies (npm install)..."
cd "$WIKI_DIR"
npm install --silent
echo "✓ npm install complete"
echo ""

# ── 2. Create Claude Code symlinks into LLM ─────────────────────────────

echo "→ Wiring Claude Code symlinks (per LLM-OS Phase 6)..."
mkdir -p "$HOME/.claude" "$HOME/.claude/skills" "$HOME/.claude/hooks"

# CLAUDE.md → single file symlink
CLAUDE_MD_TARGET="$LLM_DIR/claude/instructions/global.md"
if [ -f "$CLAUDE_MD_TARGET" ]; then
  ln -sfn "$CLAUDE_MD_TARGET" "$HOME/.claude/CLAUDE.md"
  echo "  ✓ ~/.claude/CLAUDE.md → LLM/claude/instructions/global.md"
else
  echo "  ⚠ $CLAUDE_MD_TARGET not found — skipping CLAUDE.md symlink"
fi

# Skills → per-skill symlinks (so Claude Code plugin-managed skills can coexist).
# Only symlink directories (skip README.md and other markdown files).
if [ -d "$LLM_DIR/claude/skills" ]; then
  count=0
  for skill_path in "$LLM_DIR/claude/skills"/*/; do
    [ -d "$skill_path" ] || continue
    skill=$(basename "$skill_path")
    ln -sfn "$skill_path" "$HOME/.claude/skills/$skill"
    count=$((count + 1))
  done
  echo "  ✓ $count skill symlinks created in ~/.claude/skills/"
else
  echo "  ⚠ $LLM_DIR/claude/skills not found — skipping skills"
fi

# Hooks → per-file symlinks for the 4 official hooks.
for hook in session-start.sh track-changes.sh session-end.sh post-compact.sh; do
  src="$LLM_DIR/claude/hooks/$hook"
  if [ -f "$src" ]; then
    ln -sfn "$src" "$HOME/.claude/hooks/$hook"
    chmod +x "$src" 2>/dev/null || true
  fi
done
echo "  ✓ 4 hook symlinks created in ~/.claude/hooks/"
echo ""

# ── 3. Register MCP wiki-search server with Claude Code ─────────────────

echo "→ Registering mcp-wiki-search with Claude Code..."
MCP_SERVER="$WIKI_DIR/src/mcp-search-server.ts"
if [ -f "$MCP_SERVER" ]; then
  # Remove any existing registration first (idempotent)
  claude mcp remove wiki-search --scope user 2>/dev/null || true
  claude mcp add wiki-search --scope user -- \
    node --experimental-strip-types "$MCP_SERVER"
  echo "✓ MCP server registered"
else
  echo "  ⚠ $MCP_SERVER not found — skipping MCP registration"
fi
echo ""

# ── 4. Install watchdog script + launchd agent ──────────────────────────

echo "→ Installing watchdog..."
mkdir -p "$HOME/.local/bin" "$HOME/.local/logs" "$HOME/Library/LaunchAgents"

if [ -f "$WIKI_DIR/watchdog.sh" ]; then
  cp "$WIKI_DIR/watchdog.sh" "$HOME/.local/bin/karpathi-watchdog.sh"
  chmod +x "$HOME/.local/bin/karpathi-watchdog.sh"
  echo "  ✓ Watchdog script installed at $HOME/.local/bin/karpathi-watchdog.sh"

  # Render plist template with current $HOME
  PLIST_SRC="$BOOTSTRAP_DIR/launchd/com.mm.karpathi-watchdog.plist.template"
  PLIST_DST="$HOME/Library/LaunchAgents/com.mm.karpathi-watchdog.plist"
  sed "s|__HOME__|$HOME|g" "$PLIST_SRC" > "$PLIST_DST"
  echo "  ✓ launchd plist installed at $PLIST_DST"

  # Load the agent (ignore errors if already loaded)
  launchctl unload "$PLIST_DST" 2>/dev/null || true
  launchctl load "$PLIST_DST"
  echo "  ✓ Watchdog launchd agent loaded (runs every 15 min)"
else
  echo "  ⚠ watchdog.sh not found — skipping"
fi
echo ""

# ── 4b. Install weekly bootstrap-refresh launchd agent ──────────────────

echo "→ Installing weekly bootstrap-refresh agent (Sundays at 03:00)..."
REFRESH_SRC="$BOOTSTRAP_DIR/launchd/com.mm.karpathi-refresh.plist.template"
REFRESH_DST="$HOME/Library/LaunchAgents/com.mm.karpathi-refresh.plist"
if [ -f "$REFRESH_SRC" ] && [ -f "$BOOTSTRAP_DIR/refresh.sh" ]; then
  sed "s|__HOME__|$HOME|g" "$REFRESH_SRC" > "$REFRESH_DST"
  launchctl unload "$REFRESH_DST" 2>/dev/null || true
  launchctl load "$REFRESH_DST"
  echo "  ✓ Refresh agent loaded — submodule pointers will be re-pinned weekly"
else
  echo "  ⚠ refresh template or refresh.sh missing — skipping"
fi
echo ""

# ── 5. Start PM2 daemon (wiki-pipe) ─────────────────────────────────────

echo "→ Starting wiki-pipe under PM2..."
cd "$WIKI_DIR"
# Idempotent: clear any leftover entries from older bootstrap versions
pm2 delete wiki-pipe 2>/dev/null || true
pm2 delete meta-orchestrator 2>/dev/null || true   # legacy, retired 2026-04-27
pm2 delete mcp-wiki-search 2>/dev/null || true     # legacy, runs via Claude Code MCP
pm2 start ecosystem.config.cjs
pm2 save
echo ""

# ── 6. Enable PM2 on system boot ────────────────────────────────────────

echo "→ Configuring PM2 to start on login..."
echo "  (If this prompts for sudo, run the command it prints, then re-run bootstrap.sh)"
pm2 startup launchd -u "$USER" --hp "$HOME" 2>&1 | tail -5 || true
echo ""

# ── Done ────────────────────────────────────────────────────────────────

echo "============================================"
echo "✓ Bootstrap complete."
echo ""
echo "Verify:"
echo "  pm2 list                   — meta-orchestrator should be 'online'"
echo "  claude mcp list            — wiki-search should show '✓ Connected'"
echo "  bash $HOME/.local/bin/karpathi-watchdog.sh; echo \$?   — should exit 0"
echo ""
echo "Next scheduled topology cycle: every 6 hours on the hour (00:00, 06:00, 12:00, 18:00)."
echo "============================================"
