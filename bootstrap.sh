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

echo "→ Wiring ~/.claude/CLAUDE.md and ~/.claude/skills symlinks..."
mkdir -p "$HOME/.claude"

CLAUDE_MD_TARGET="$LLM_DIR/claude/instructions/global.md"
SKILLS_TARGET="$LLM_DIR/claude/skills"

if [ -f "$CLAUDE_MD_TARGET" ]; then
  ln -sfn "$CLAUDE_MD_TARGET" "$HOME/.claude/CLAUDE.md"
  echo "  ✓ ~/.claude/CLAUDE.md → $CLAUDE_MD_TARGET"
else
  echo "  ⚠ $CLAUDE_MD_TARGET not found — skipping CLAUDE.md symlink"
fi

if [ -d "$SKILLS_TARGET" ]; then
  ln -sfn "$SKILLS_TARGET" "$HOME/.claude/skills"
  echo "  ✓ ~/.claude/skills → $SKILLS_TARGET"
else
  echo "  ⚠ $SKILLS_TARGET not found — skipping skills symlink"
fi
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

# ── 5. Start PM2 daemon ─────────────────────────────────────────────────

echo "→ Starting meta-orchestrator under PM2..."
cd "$WIKI_DIR"
pm2 delete meta-orchestrator 2>/dev/null || true
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
