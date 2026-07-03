#!/usr/bin/env bash
set -e

echo "========================================"
echo "  Claude Code Add-on Starting"
echo "========================================"

# ── Environment ──────────────────────────────────────────────────────────────
export HA_TOKEN="$SUPERVISOR_TOKEN"
export HA_URL="http://supervisor/core"

PERSIST_DIR=/homeassistant/.claudecode
mkdir -p "$PERSIST_DIR/config" /root/.config

# ── CLAUDE.md context file ───────────────────────────────────────────────────
cat > "$PERSIST_DIR/CLAUDE.md" << 'CLAUDEMD'
# Claude Code - Home Assistant Add-on

## Path Mapping

In this add-on container, paths are mapped differently than HA Core:
- `/homeassistant` = HA config directory (equivalent to `/config` in HA Core)
- `/config` does NOT exist - always use `/homeassistant`

When users mention `/config/...`, translate to `/homeassistant/...`

## Available Paths

| Path | Description | Access |
|------|-------------|--------|
| `/homeassistant` | HA configuration | read-write |
| `/share` | Shared folder | read-write |
| `/media` | Media files | read-write |
| `/ssl` | SSL certificates | read-only |
| `/backup` | Backups | read-only |

## Home Assistant Integration

Use the `homeassistant` MCP server to query entities and call services.

## Reading Home Assistant Logs

**Log levels (from most to least verbose):**
- `debug` - Only shown if explicitly enabled in configuration.yaml
- `info` - General information, shown by default
- `warning` - Warnings, always shown
- `error` - Errors, always shown

**Commands to read logs:**
```bash
# View recent logs (ha CLI)
ha core logs 2>&1 | tail -100

# Filter by keyword
ha core logs 2>&1 | grep -i keyword

# Filter errors only
ha core logs 2>&1 | grep -iE "(error|exception)"

# Alternative: read log file directly
tail -100 /homeassistant/home-assistant.log
```

**To enable debug logging for an integration**, add to `configuration.yaml`:
```yaml
logger:
  default: info
  logs:
    custom_components.YOUR_INTEGRATION: debug
```

**Key insight:** `_LOGGER.debug()` calls are invisible unless the logger level is set to debug. Use `_LOGGER.info()` or `_LOGGER.warning()` for logs that should always appear.
CLAUDEMD

# ── Symlinks for persistence ────────────────────────────────────────────────
if [ ! -L /root/.claude ]; then
  rm -rf /root/.claude
  ln -s "$PERSIST_DIR" /root/.claude
fi

if [ ! -L /root/.config/claude-code ]; then
  rm -rf /root/.config/claude-code
  ln -s "$PERSIST_DIR/config" /root/.config/claude-code
fi

if [ ! -L /root/.claude.json ]; then
  touch "$PERSIST_DIR/.claude.json"
  rm -f /root/.claude.json
  ln -s "$PERSIST_DIR/.claude.json" /root/.claude.json
fi

# ── Read user options ────────────────────────────────────────────────────────
FONT_SIZE=$(jq -r '.terminal_font_size // 14' /data/options.json)
THEME=$(jq -r '.terminal_theme // "dark"' /data/options.json)
SESSION_PERSIST=$(jq -r '.session_persistence // true' /data/options.json)
ENABLE_MCP=$(jq -r '.enable_mcp // true' /data/options.json)
ENABLE_PLAYWRIGHT=$(jq -r '.enable_playwright_mcp // false' /data/options.json)
PLAYWRIGHT_HOST=$(jq -r '.playwright_cdp_host // ""' /data/options.json)
AUTO_UPDATE=$(jq -r '.auto_update_claude // true' /data/options.json)

# ── Auto-detect Playwright Browser hostname ──────────────────────────────────
if [ -z "$PLAYWRIGHT_HOST" ] && [ "$ENABLE_PLAYWRIGHT" = "true" ]; then
  echo "[INFO] Auto-detecting Playwright Browser hostname..."
  PLAYWRIGHT_HOST=$(curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
    http://supervisor/addons | \
    jq -r '.data.addons[] | select(.slug | test("playwright-browser")) | .hostname' \
    2>/dev/null | head -1)
  if [ -n "$PLAYWRIGHT_HOST" ] && [ "$PLAYWRIGHT_HOST" != "null" ]; then
    echo "[INFO] Found Playwright Browser: $PLAYWRIGHT_HOST"
  else
    echo "[WARN] Playwright Browser add-on not found, using default hostname"
    PLAYWRIGHT_HOST="playwright-browser"
  fi
fi

# ── Auto-update Claude Code ─────────────────────────────────────────────────
# Key fix: install to /data/claude-code/ (writable ext4) instead of
# /usr/local/ (read-only OverlayFS image layer).
# /data/claude-code/bin is first in PATH so the updated version takes precedence.
CLAUDE_DATA_DIR=/data/claude-code

if [ "$AUTO_UPDATE" = "true" ]; then
  echo "[INFO] Checking for Claude Code updates..."

  # Get currently available version
  CURRENT_VER=$(/usr/local/bin/claude --version 2>/dev/null | head -1 || echo "unknown")
  if [ -x "$CLAUDE_DATA_DIR/bin/claude" ]; then
    CURRENT_VER=$("$CLAUDE_DATA_DIR/bin/claude" --version 2>/dev/null | head -1 || echo "$CURRENT_VER")
  fi

  if npm install -g --prefix "$CLAUDE_DATA_DIR" @anthropic-ai/claude-code 2>&1 | tail -5; then
    NEW_VER=$("$CLAUDE_DATA_DIR/bin/claude" --version 2>/dev/null | head -1 || echo "unknown")
    echo "[INFO] Claude Code updated: $CURRENT_VER -> $NEW_VER"
  else
    echo "[WARN] Claude Code update failed, using image-bundled version"
  fi
else
  echo "[INFO] Auto-update disabled"
fi

# Ensure the data bin dir exists even if update was skipped
mkdir -p "$CLAUDE_DATA_DIR/bin"

# ── MCP Configuration ───────────────────────────────────────────────────────
SETTINGS_FILE=/root/.claude/settings.json

# Ensure settings file exists
if [ ! -f "$SETTINGS_FILE" ]; then
  echo '{}' > "$SETTINGS_FILE"
fi

# Remove stale MCP entries
claude mcp remove homeassistant -s user 2>/dev/null || true
claude mcp remove playwright -s user 2>/dev/null || true

if [ "$ENABLE_MCP" = "true" ]; then
  claude mcp add-json homeassistant '{"command":"hass-mcp"}' -s user

  # Update HASS_TOKEN in MCP config
  if [ -n "$SUPERVISOR_TOKEN" ]; then
    jq ".mcpServers.homeassistant.env.HASS_TOKEN = \"$SUPERVISOR_TOKEN\"" \
      "$SETTINGS_FILE" > /tmp/settings.tmp 2>/dev/null \
      && mv /tmp/settings.tmp "$SETTINGS_FILE"
  fi

  # Pre-authorize read-only MCP tools
  ALLOWED_TOOLS='["mcp__homeassistant__get_version","mcp__homeassistant__get_entity","mcp__homeassistant__list_entities","mcp__homeassistant__search_entities_tool","mcp__homeassistant__domain_summary_tool","mcp__homeassistant__list_automations","mcp__homeassistant__get_history","mcp__homeassistant__get_error_log","Read(/homeassistant/**)","Read(/config/**)","Read(/share/**)","Read(/media/**)","Glob(/homeassistant/**)","Glob(/config/**)","Grep(/homeassistant/**)","Grep(/config/**)"]'
  jq --argjson tools "$ALLOWED_TOOLS" \
    '.permissions.allow = ($tools + (.permissions.allow // []) | unique)' \
    "$SETTINGS_FILE" > /tmp/settings.tmp && mv /tmp/settings.tmp "$SETTINGS_FILE"

  echo "[INFO] MCP configured with Home Assistant integration"
else
  echo "[INFO] MCP disabled"
fi

# ── Playwright MCP ───────────────────────────────────────────────────────────
if [ "$ENABLE_PLAYWRIGHT" = "true" ]; then
  claude mcp add-json playwright \
    "{\"command\":\"npx\",\"args\":[\"--no-install\",\"@playwright/mcp\",\"--cdp-endpoint\",\"http://${PLAYWRIGHT_HOST}:9222\"]}" \
    -s user
  echo "[INFO] Playwright MCP enabled (CDP: http://${PLAYWRIGHT_HOST}:9222)"
else
  echo "[INFO] Playwright MCP disabled"
fi

# ── Theme colors ─────────────────────────────────────────────────────────────
if [ "$THEME" = "dark" ]; then
  COLORS='background=#1e1e2e,foreground=#cdd6f4,cursor=#f5e0dc'
else
  COLORS='background=#eff1f5,foreground=#4c4f69,cursor=#dc8a78'
fi

# ── Shell command ────────────────────────────────────────────────────────────
if [ "$SESSION_PERSIST" = "true" ]; then
  SHELL_CMD='tmux new-session -A -s claude'
else
  SHELL_CMD='bash --login'
fi

# ── Launch ttyd ──────────────────────────────────────────────────────────────
cd /homeassistant
exec ttyd --port 7681 --writable --ping-interval 30 --max-clients 5 \
  -t fontSize="$FONT_SIZE" \
  -t fontFamily=Monaco,Consolas,monospace \
  -t scrollback=20000 \
  -t "theme=$COLORS" \
  $SHELL_CMD
