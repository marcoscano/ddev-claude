#!/bin/bash
#
# merge-whitelist.sh - Merge multiple whitelist JSON files into line-delimited domains
# (local fix 2026-07-23: chmod the cache world-readable — mktemp creates it 0600,
# and when root's watcher writes it the claude-user hook can't read it and denies
# every domain; #ddev-generated marker removed to protect the fix)
#
# Usage: merge-whitelist.sh [global_config] [project_config]
#
# Merges domains from:
#   1. Default whitelist (built into addon)
#   2. Global user config (~/.ddev/ddev-claude/whitelist.json)
#   3. Project config (.ddev/ddev-claude/whitelist.json)
#
# Outputs unique domains, one per line, for use by resolve-and-apply.sh

set -euo pipefail

# Configuration paths
DEFAULT_WHITELIST="${DDEV_APPROOT}/.ddev/claude/config/default-whitelist.json"
GLOBAL_CONFIG="${1:-$HOME/.ddev/ddev-claude/whitelist.json}"
PROJECT_CONFIG="${2:-.ddev/ddev-claude/whitelist.json}"

# Helper function to validate JSON array
validate_json() {
    local file="$1"
    if ! jq empty "$file" 2>/dev/null; then
        echo "ERROR: Invalid JSON in $file" >&2
        return 1
    fi
    # Ensure it's an array
    if ! jq -e 'if type == "array" then true else false end' "$file" >/dev/null 2>&1; then
        echo "ERROR: $file must contain a JSON array" >&2
        return 1
    fi
    return 0
}

# Helper function to get JSON content (empty array if file doesn't exist)
get_json_content() {
    local file="$1"
    if [[ -f "$file" ]]; then
        if validate_json "$file"; then
            cat "$file"
        else
            exit 1
        fi
    else
        echo "[]"
    fi
}

# Collect all JSON sources
sources=()

# Default whitelist (required)
if [[ ! -f "$DEFAULT_WHITELIST" ]]; then
    echo "ERROR: Default whitelist not found at $DEFAULT_WHITELIST" >&2
    exit 1
fi
sources+=("$(get_json_content "$DEFAULT_WHITELIST")")

# Global config (optional)
sources+=("$(get_json_content "$GLOBAL_CONFIG")")

# Project config (optional)
sources+=("$(get_json_content "$PROJECT_CONFIG")")

# Merge all sources and output unique domains
CACHE_FILE="/tmp/ddev-claude-merged-whitelist.txt"
merged_output=$(printf '%s\n' "${sources[@]}" | jq -s 'add | unique | .[]' -r)
echo "$merged_output"
tmp_cache=$(mktemp)
echo "$merged_output" > "$tmp_cache"
chmod 644 "$tmp_cache"
mv "$tmp_cache" "$CACHE_FILE"
