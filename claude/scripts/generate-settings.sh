#!/bin/bash
#ddev-generated
#
# generate-settings.sh - Register Claude Code hooks in project settings.local.json
#
# Writes ddev-claude hook configuration to $DDEV_APPROOT/.claude/settings.local.json
# (project-scoped, auto-gitignored by Claude Code). This avoids polluting the
# global ~/.claude/settings.json which would cause errors on the host where
# /opt/ddev-claude/hooks/ does not exist.
#
# Hook commands are conditional: they no-op gracefully if the scripts don't exist
# (e.g. when Claude Code runs on the host in the same project directory).

set -euo pipefail

LOG_PREFIX="[ddev-claude]"
log() { echo "$LOG_PREFIX $*"; }
error() { echo "$LOG_PREFIX ERROR: $*" >&2; }

SETTINGS_FILE="${DDEV_APPROOT}/.claude/settings.local.json"
HOOK_COMMAND_URL="/opt/ddev-claude/hooks/url-check.sh"
HOOK_COMMAND_SECRET="/opt/ddev-claude/hooks/secret-check.sh"
HOOK_COMMAND_DB="/opt/ddev-claude/hooks/db-conn-check.sh"

# Hook configs to inject — commands are conditional so they no-op on the host
HOOK_CONFIG_URL=$(cat <<'HOOKJSON'
{
  "matcher": "WebFetch|Bash|mcp__.*",
  "hooks": [
    {
      "type": "command",
      "command": "test -f /opt/ddev-claude/hooks/url-check.sh && /opt/ddev-claude/hooks/url-check.sh || exit 0"
    }
  ]
}
HOOKJSON
)

HOOK_CONFIG_SECRET=$(cat <<'HOOKJSON'
{
  "matcher": "Read|Edit|Write|Bash",
  "hooks": [
    {
      "type": "command",
      "command": "test -f /opt/ddev-claude/hooks/secret-check.sh && /opt/ddev-claude/hooks/secret-check.sh || exit 0"
    }
  ]
}
HOOKJSON
)

HOOK_CONFIG_DB=$(cat <<'HOOKJSON'
{
  "matcher": "Bash",
  "hooks": [
    {
      "type": "command",
      "command": "test -f /opt/ddev-claude/hooks/db-conn-check.sh && /opt/ddev-claude/hooks/db-conn-check.sh || exit 0"
    }
  ]
}
HOOKJSON
)

# Read existing settings (or empty object)
if [[ -f "$SETTINGS_FILE" ]]; then
    if ! existing=$(jq '.' "$SETTINGS_FILE" 2>/dev/null); then
        error "settings.local.json contains invalid JSON - please fix manually: $SETTINGS_FILE"
        exit 1
    fi
else
    existing='{}'
fi

# Check which hooks need registration (idempotent)
needs_url=true
needs_secret=true
needs_db=true

if echo "$existing" | jq -e --arg cmd "$HOOK_COMMAND_URL" \
    '.hooks.PreToolUse // [] | map(.hooks // []) | flatten | map(select(.command | contains($cmd))) | length > 0' \
    > /dev/null 2>&1; then
    needs_url=false
fi

if echo "$existing" | jq -e --arg cmd "$HOOK_COMMAND_SECRET" \
    '.hooks.PreToolUse // [] | map(.hooks // []) | flatten | map(select(.command | contains($cmd))) | length > 0' \
    > /dev/null 2>&1; then
    needs_secret=false
fi

if echo "$existing" | jq -e --arg cmd "$HOOK_COMMAND_DB" \
    '.hooks.PostToolUse // [] | map(.hooks // []) | flatten | map(select(.command | contains($cmd))) | length > 0' \
    > /dev/null 2>&1; then
    needs_db=false
fi

if [[ "$needs_url" == "false" && "$needs_secret" == "false" && "$needs_db" == "false" ]]; then
    log "Hooks already registered in settings.local.json"
    exit 0
fi

# Ensure settings directory exists
mkdir -p "$(dirname "$SETTINGS_FILE")"

# Deep-merge: append missing hook entries to existing PreToolUse array
merged="$existing"

if [[ "$needs_url" == "true" ]]; then
    merged=$(echo "$merged" | jq --argjson hook "$HOOK_CONFIG_URL" '
        .hooks //= {} |
        .hooks.PreToolUse //= [] |
        .hooks.PreToolUse += [$hook]
    ')
    log "Adding url-check hook"
fi

if [[ "$needs_secret" == "true" ]]; then
    merged=$(echo "$merged" | jq --argjson hook "$HOOK_CONFIG_SECRET" '
        .hooks //= {} |
        .hooks.PreToolUse //= [] |
        .hooks.PreToolUse += [$hook]
    ')
    log "Adding secret-check hook"
fi

if [[ "$needs_db" == "true" ]]; then
    merged=$(echo "$merged" | jq --argjson hook "$HOOK_CONFIG_DB" '
        .hooks //= {} |
        .hooks.PostToolUse //= [] |
        .hooks.PostToolUse += [$hook]
    ')
    log "Adding db-conn-check hook"
fi

# Write back (atomic)
tmp_settings=$(mktemp)
echo "$merged" > "$tmp_settings"
mv "$tmp_settings" "$SETTINGS_FILE"

log "Registered hooks in settings.local.json"
