#!/bin/bash
#ddev-generated
#
# reload-whitelist.sh - Reload firewall whitelist from merged config sources
#
# Called by watch-config.sh when config files change.
# Flushes ipset and re-resolves all domains from merged whitelist.

set -euo pipefail

LOG_PREFIX="[ddev-claude]"
SCRIPT_DIR="${DDEV_APPROOT}/.ddev/claude"

log() { echo "$LOG_PREFIX $*"; }
error() { echo "$LOG_PREFIX ERROR: $*" >&2; }

log "Reloading whitelist..."

# Merge all whitelist sources
merged=$("$SCRIPT_DIR/scripts/merge-whitelist.sh")

if [[ -z "$merged" ]]; then
    log "WARNING: No domains in merged whitelist"
fi

# Validate merged output (should be one domain, IP or CIDR range per line)
# Allow: alphanumeric, dots, hyphens, asterisks (wildcards), slashes (CIDR)
if echo "$merged" | grep -qE '[^a-zA-Z0-9./*-]'; then
    error "Invalid characters in merged whitelist"
    exit 1
fi

# Create temporary whitelist file for resolve-and-apply.sh
temp_whitelist=$(mktemp)
echo "$merged" > "$temp_whitelist"

# Flush existing ipset entries (keep set, just clear it)
ipset flush whitelist_ips 2>/dev/null || true

# Re-resolve and apply domains
"$SCRIPT_DIR/resolve-and-apply.sh" "$temp_whitelist"

# Cleanup
rm -f "$temp_whitelist"

# Log result
ip_count=$(ipset list whitelist_ips 2>/dev/null | grep -c "^[0-9]" || echo 0)
domain_count=$(echo "$merged" | grep -c . || echo 0)
log "Whitelist reloaded: $ip_count IPs from $domain_count domains"
