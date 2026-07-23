#!/bin/bash
#
# url-check.sh - PreToolUse hook for domain whitelist checking
# (local fix 2026-07-23: emit hookSpecificOutput schema so Claude Code
# honors the decisions; #ddev-generated marker removed to protect it)
#
# Reads Claude Code hook JSON from stdin, extracts domains from tool calls,
# and checks them against the merged whitelist cache. Returns allow/deny
# decisions as JSON on stdout.
#
# This is a UX layer on top of the iptables firewall — iptables remains
# the kernel-level security foundation.

set -euo pipefail

CACHE_FILE="/tmp/ddev-claude-merged-whitelist.txt"
SCRIPT_DIR="${DDEV_APPROOT:-.}/.ddev/claude"

# Passthrough if firewall is disabled
if [[ "${DDEV_CLAUDE_NO_FIREWALL:-}" == "1" ]]; then
    exit 0
fi

# Read hook input from stdin
input=$(cat)

tool_name=$(echo "$input" | jq -r '.tool_name // empty')
tool_input=$(echo "$input" | jq -r '.tool_input // empty')

# Early exit for non-network tools
case "$tool_name" in
    WebFetch|Bash|mcp__*)
        ;; # continue processing
    *)
        exit 0 # pass through
        ;;
esac

# Ensure cache file exists — regenerate if missing (fail-closed)
if [[ ! -f "$CACHE_FILE" ]]; then
    if [[ -x "$SCRIPT_DIR/scripts/merge-whitelist.sh" ]]; then
        "$SCRIPT_DIR/scripts/merge-whitelist.sh" > /dev/null 2>&1 || true
    fi
    if [[ ! -f "$CACHE_FILE" ]]; then
        # Cache still missing — fail closed (deny all domains)
        echo "" > "$CACHE_FILE"
    fi
fi

# Extract domains based on tool type
extract_domains() {
    local domains=()

    case "$tool_name" in
        WebFetch)
            local url
            url=$(echo "$tool_input" | jq -r '.url // empty')
            if [[ -n "$url" ]]; then
                local host
                host=$(echo "$url" | sed -E 's|^https?://||; s|[/:?#].*||')
                if [[ -n "$host" ]]; then
                    domains+=("$host")
                fi
            fi
            ;;
        Bash)
            local cmd
            cmd=$(echo "$tool_input" | jq -r '.command // empty')
            if [[ -z "$cmd" ]]; then
                return
            fi

            # Special-case: allow add-domain when it's the sole command
            # Anchored start and end; reject shell metacharacters to prevent chaining
            if echo "$cmd" | grep -qE '^\s*/opt/ddev-claude/bin/add-domain\s+[^ ;|&$()`]+(\s+[^ ;|&$()`]+)*\s*$'; then
                echo "__ALLOW_ADD_DOMAIN__"
                return
            fi

            # Extract URLs from command string
            local urls
            urls=$(echo "$cmd" | grep -oE "https?://[^ \"'|;&)<>]+" || true)
            for u in $urls; do
                local host
                host=$(echo "$u" | sed -E 's|^https?://||; s|[/:?#].*||')
                if [[ -n "$host" ]]; then
                    domains+=("$host")
                fi
            done
            ;;
        mcp__*)
            # Recursively extract URLs from all JSON string values
            local urls
            urls=$(echo "$tool_input" | jq -r '.. | strings' 2>/dev/null | grep -oE "https?://[^ \"'|;&)<>]+" || true)
            for u in $urls; do
                local host
                host=$(echo "$u" | sed -E 's|^https?://||; s|[/:?#].*||')
                if [[ -n "$host" ]]; then
                    domains+=("$host")
                fi
            done
            ;;
    esac

    # Deduplicate and output
    if [[ ${#domains[@]} -gt 0 ]]; then
        printf '%s\n' "${domains[@]}" | sort -u
    fi
}

domains_output=$(extract_domains)

# Special case: add-domain command gets explicit allow
if [[ "$domains_output" == "__ALLOW_ADD_DOMAIN__" ]]; then
    jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow"}}'
    exit 0
fi

# No domains found — pass through (not a network tool call)
if [[ -z "$domains_output" ]]; then
    exit 0
fi

# Check each domain against whitelist cache
blocked_domains=()
while IFS= read -r domain; do
    if ! grep -qFx "$domain" "$CACHE_FILE" 2>/dev/null; then
        blocked_domains+=("$domain")
    fi
done <<< "$domains_output"

# All domains whitelisted
if [[ ${#blocked_domains[@]} -eq 0 ]]; then
    jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow"}}'
    exit 0
fi

# Build deny message with add-domain instructions
blocked_list=$(printf '%s, ' "${blocked_domains[@]}" | sed 's/, $//')
add_cmd="/opt/ddev-claude/bin/add-domain $(printf '%s ' "${blocked_domains[@]}" | sed 's/ $//')"

deny_reason=$(cat <<EOF
Domain(s) not in the firewall whitelist: ${blocked_list}
Ask the user if they would like to whitelist $([ ${#blocked_domains[@]} -eq 1 ] && echo "it" || echo "them").
If yes, run: ${add_cmd}
EOF
)

jq -n --arg reason "$deny_reason" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
exit 0
