#!/bin/bash
#ddev-generated
set -euo pipefail

LOG_PREFIX="[ddev-claude]"
SCRIPT_DIR="${DDEV_APPROOT}/.ddev/claude"
BLOCKED_LOG="/tmp/ddev-claude-blocked.log"

log() { echo "$LOG_PREFIX $*"; }
error() { echo "$LOG_PREFIX ERROR: $*" >&2; }

fail_closed() {
    error "Firewall initialization failed - blocking all traffic"
    iptables -P OUTPUT DROP 2>/dev/null || true
    exit 1
}

# Error trap - fail closed
trap fail_closed ERR

log "Initializing firewall rules..."

# Initialize blocked log file (for Phase 2 whitelist suggestions)
> "$BLOCKED_LOG"
log "Initialized blocked request log at $BLOCKED_LOG"

# 1. Flush existing rules (idempotent)
iptables -F OUTPUT 2>/dev/null || true
iptables -P OUTPUT ACCEPT  # Temporarily allow while setting up

# 2. Create ipset (use -exist for idempotency). hash:net stores single IPs
# (as /32) and CIDR ranges alike, one entry each.
ipset create -exist whitelist_ips hash:net timeout 3600
log "Created ipset 'whitelist_ips'"

# 3. Allow loopback (critical for localhost communication)
iptables -A OUTPUT -o lo -j ACCEPT
log "Allowed loopback interface"

# 4. Allow DNS BEFORE restrictive rules (UDP and TCP)
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
log "Allowed DNS resolution (port 53)"

# 5. Allow established connections (return traffic)
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
log "Allowed established/related connections"

# 6. Get merged whitelist (default + global + project)
merged_whitelist=$("$SCRIPT_DIR/scripts/merge-whitelist.sh")
if [[ -n "$merged_whitelist" ]]; then
    temp_whitelist=$(mktemp)
    echo "$merged_whitelist" > "$temp_whitelist"
    "$SCRIPT_DIR/resolve-and-apply.sh" "$temp_whitelist"
    rm -f "$temp_whitelist"
else
    log "WARNING: No domains in merged whitelist"
fi

# 6b. Auto-whitelist MCP server domains from user config
extract_mcp_domains() {
    local domains=""
    local claude_home="${CLAUDE_HOME:-/root}"
    local mcp_json="${claude_home}/.mcp.json"
    local claude_json="${claude_home}/.claude.json"
    local project_mcp="${DDEV_APPROOT}/.mcp.json"

    # Tier 1: ~/.mcp.json (global)
    if [[ -f "$mcp_json" ]]; then
        domains+=$(jq -r '.mcpServers[]?.url? // empty' "$mcp_json" 2>/dev/null || true)
        domains+=$'\n'
    fi

    # Tier 2: ~/.claude.json — global mcpServers
    if [[ -f "$claude_json" ]]; then
        domains+=$(jq -r '.mcpServers[]?.url? // empty' "$claude_json" 2>/dev/null || true)
        domains+=$'\n'
        # Tier 2: ~/.claude.json — current project mcpServers only
        domains+=$(jq -r --arg proj "$DDEV_APPROOT" \
            '.projects[$proj]?.mcpServers[]?.url? // empty' "$claude_json" 2>/dev/null || true)
        domains+=$'\n'
    fi

    # Tier 3: project-local .mcp.json
    if [[ -f "$project_mcp" ]]; then
        domains+=$(jq -r '.mcpServers[]?.url? // empty' "$project_mcp" 2>/dev/null || true)
        domains+=$'\n'
    fi

    # Extract hostnames from URLs, filter localhost, deduplicate
    echo "$domains" \
        | sed -E 's#^[a-zA-Z]+://##; s#[:/?].*$##' \
        | grep -v -E '^(localhost|127\.0\.0\.1|0\.0\.0\.0)$' \
        | sort -u \
        || true
}

if mcp_domains=$(extract_mcp_domains 2>/dev/null) && [[ -n "$mcp_domains" ]]; then
    log "Whitelisting MCP domains: $(echo "$mcp_domains" | tr '\n' ', ' | sed 's/,$//')"
    temp_mcp=$(mktemp)
    echo "$mcp_domains" > "$temp_mcp"
    "$SCRIPT_DIR/resolve-and-apply.sh" "$temp_mcp" || log "WARNING: Some MCP domains failed to resolve"
    rm -f "$temp_mcp"
else
    log "No MCP domains detected"
fi

# 7. Allow traffic to whitelisted IPs
iptables -A OUTPUT -m set --match-set whitelist_ips dst -j ACCEPT
log "Allowed whitelisted IPs"

# 8. Log blocked requests (rate limited for visible logs)
# Phase 2 will parse kernel log for whitelist suggestions
iptables -A OUTPUT -m limit --limit 2/sec --limit-burst 5 \
  -j LOG --log-prefix "[FIREWALL-BLOCK] " --log-level warning

# 9. Default DROP (fail closed)
iptables -P OUTPUT DROP
log "Set default policy to DROP"

ip_count=$(ipset list whitelist_ips 2>/dev/null | grep -c "^[0-9]" || echo 0)
log "Firewall initialized successfully ($ip_count IPs whitelisted)"
log "If you see 'Network request BLOCKED' messages, run 'ddev claude:whitelist' or use /whitelist skill"

# Register Claude Code hooks for domain whitelisting UX
log "Registering Claude Code hooks..."
"$SCRIPT_DIR/scripts/generate-settings.sh" || {
    log "WARNING: Failed to register hooks (continuing without hooks)"
}

# Merge denylist and scan for secret files
log "Initializing secret file protection..."
"$SCRIPT_DIR/scripts/merge-denylist.sh" > /dev/null 2>&1 || {
    log "WARNING: Failed to merge denylist (continuing without secret pattern cache)"
}
"$SCRIPT_DIR/scripts/check-secrets.sh" || {
    log "WARNING: Secret scan failed (continuing without secret protection warnings)"
}

# Configure git safe.directory for the mounted project.
# The project dir is bind-mounted from host and may be owned by a different uid than root.
# Git >= 2.35.2 rejects operations in repos owned by other users.
# Use --system (/etc/gitconfig) because ~/.gitconfig is mounted read-only from host.
log "Configuring git safe.directory for ${DDEV_APPROOT}..."
git config --system --add safe.directory "${DDEV_APPROOT}"

# Start config file watcher in background
log "Starting config file watcher..."
"$SCRIPT_DIR/scripts/watch-config.sh" &
WATCHER_PID=$!
log "Config watcher started (PID $WATCHER_PID)"

# Start user-friendly block notification monitor
log "Starting block notification monitor..."
"$SCRIPT_DIR/scripts/format-block-message.sh" &
BLOCK_MONITOR_PID=$!
log "Block monitor started (PID $BLOCK_MONITOR_PID)"

# Execute command passed to entrypoint
exec "$@"
