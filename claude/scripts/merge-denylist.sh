#!/bin/bash
#
# merge-denylist.sh - Merge multiple denylist JSON files into pattern cache files
# (local fix 2026-07-23: chmod the caches world-readable — mktemp creates them
# 0600, and when root's entrypoint writes them the claude-user hook can't read
# the deny patterns and silently allows secret files; exec bit also restored,
# the file ships 0644 upstream; #ddev-generated marker removed to protect it)
#
# Usage: merge-denylist.sh [global_config] [project_config]
#
# Merges patterns from:
#   1. Default denylist (built into addon)
#   2. Global user config (~/.ddev/ddev-claude/denylist.json)
#   3. Project config (.ddev/ddev-claude/denylist.json)
#
# Outputs two cache files:
#   /tmp/ddev-claude-deny-patterns.txt  (one glob pattern per line)
#   /tmp/ddev-claude-allow-patterns.txt (one glob pattern per line)
#
# Accepts both array format ["pattern"] (treated as all-deny)
# and object format {"deny":[], "allow":[]} for user convenience.

set -euo pipefail

# Configuration paths
DEFAULT_DENYLIST="${DDEV_APPROOT}/.ddev/claude/config/default-denylist.json"
GLOBAL_CONFIG="${1:-$HOME/.ddev/ddev-claude/denylist.json}"
PROJECT_CONFIG="${2:-.ddev/ddev-claude/denylist.json}"

DENY_CACHE="/tmp/ddev-claude-deny-patterns.txt"
ALLOW_CACHE="/tmp/ddev-claude-allow-patterns.txt"

# Helper function to validate JSON
validate_json() {
    local file="$1"
    if ! jq empty "$file" 2>/dev/null; then
        echo "ERROR: Invalid JSON in $file" >&2
        return 1
    fi
    # Ensure it's an array or object with deny/allow arrays
    local json_type
    json_type=$(jq -r 'type' "$file" 2>/dev/null)
    if [[ "$json_type" != "array" && "$json_type" != "object" ]]; then
        echo "ERROR: $file must contain a JSON array or object with deny/allow arrays" >&2
        return 1
    fi
    return 0
}

# Extract deny patterns from a JSON file (handles both array and object format)
get_deny_patterns() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "[]"
        return
    fi
    if ! validate_json "$file"; then
        exit 1
    fi
    # Array format: entire array is deny patterns
    # Object format: .deny array
    jq 'if type == "array" then . elif .deny then .deny else [] end' "$file"
}

# Extract allow patterns from a JSON file (only from object format)
get_allow_patterns() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "[]"
        return
    fi
    if ! validate_json "$file"; then
        exit 1
    fi
    jq 'if type == "object" and .allow then .allow else [] end' "$file"
}

# Default denylist (required)
if [[ ! -f "$DEFAULT_DENYLIST" ]]; then
    echo "ERROR: Default denylist not found at $DEFAULT_DENYLIST" >&2
    exit 1
fi

# Collect deny patterns from all tiers
deny_sources=()
deny_sources+=("$(get_deny_patterns "$DEFAULT_DENYLIST")")
deny_sources+=("$(get_deny_patterns "$GLOBAL_CONFIG")")
deny_sources+=("$(get_deny_patterns "$PROJECT_CONFIG")")

# Collect allow patterns from all tiers
allow_sources=()
allow_sources+=("$(get_allow_patterns "$DEFAULT_DENYLIST")")
allow_sources+=("$(get_allow_patterns "$GLOBAL_CONFIG")")
allow_sources+=("$(get_allow_patterns "$PROJECT_CONFIG")")

# Merge and deduplicate deny patterns
deny_output=$(printf '%s\n' "${deny_sources[@]}" | jq -s 'add | unique | .[]' -r)

# Merge and deduplicate allow patterns
allow_output=$(printf '%s\n' "${allow_sources[@]}" | jq -s 'add | unique | .[]' -r)

# Write cache files (atomic via temp+mv)
tmp_deny=$(mktemp)
tmp_allow=$(mktemp)
if [[ -n "$deny_output" ]]; then
    echo "$deny_output" > "$tmp_deny"
else
    : > "$tmp_deny"
fi
if [[ -n "$allow_output" ]]; then
    echo "$allow_output" > "$tmp_allow"
else
    : > "$tmp_allow"
fi
chmod 644 "$tmp_deny" "$tmp_allow"
mv "$tmp_deny" "$DENY_CACHE"
mv "$tmp_allow" "$ALLOW_CACHE"

echo "$deny_output"
