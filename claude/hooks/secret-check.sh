#!/bin/bash
#
# secret-check.sh - PreToolUse hook for secret file protection
# (local fix 2026-07-23: emit hookSpecificOutput schema so Claude Code
# honors the decisions; #ddev-generated marker removed to protect it)
#
# Reads Claude Code hook JSON from stdin, extracts file paths from tool calls,
# and checks them against the merged denylist cache. Returns allow/deny
# decisions as JSON on stdout.
#
# Unlike url-check.sh, this hook stays active even when DDEV_CLAUDE_NO_FIREWALL=1.
# Secret protection is always on — the firewall is just the exfiltration backstop.

set -euo pipefail

DENY_CACHE="/tmp/ddev-claude-deny-patterns.txt"
ALLOW_CACHE="/tmp/ddev-claude-allow-patterns.txt"
OVERRIDE_FILE="/tmp/ddev-claude-secret-override"
SCRIPT_DIR="${DDEV_APPROOT:-.}/.ddev/claude"

# Read hook input from stdin
input=$(cat)

tool_name=$(echo "$input" | jq -r '.tool_name // empty')
tool_input=$(echo "$input" | jq -r '.tool_input // empty')

# Early exit for non-file tools
case "$tool_name" in
    Read|Edit|Write|Bash)
        ;; # continue processing
    *)
        exit 0 # pass through
        ;;
esac

# Ensure cache files exist — regenerate if missing (fail-closed)
if [[ ! -f "$DENY_CACHE" || ! -f "$ALLOW_CACHE" ]]; then
    if [[ -x "$SCRIPT_DIR/scripts/merge-denylist.sh" ]]; then
        "$SCRIPT_DIR/scripts/merge-denylist.sh" > /dev/null 2>&1 || true
    fi
    if [[ ! -f "$DENY_CACHE" ]]; then
        # Cache still missing — fail closed (deny all file operations)
        jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: "Secret protection cache unavailable — blocking file access as a safety measure. Try restarting the container."}}'
        exit 0
    fi
    if [[ ! -f "$ALLOW_CACHE" ]]; then
        echo "" > "$ALLOW_CACHE"
    fi
fi

# Check if a basename matches any pattern in a cache file
matches_pattern() {
    local name="$1"
    local cache_file="$2"

    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        # shellcheck disable=SC2254
        if [[ "$name" == $pattern ]]; then
            return 0
        fi
    done < "$cache_file"
    return 1
}

# Check if a path is in the session override list
is_overridden() {
    local check_path="$1"
    local check_basename
    check_basename=$(basename "$check_path")

    if [[ ! -f "$OVERRIDE_FILE" ]]; then
        return 1
    fi

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        # Match exact path or basename
        if [[ "$check_path" == "$entry" || "$check_basename" == "$entry" ]]; then
            return 0
        fi
    done < "$OVERRIDE_FILE"
    return 1
}

# Check a single file path against deny/allow patterns
check_path() {
    local file_path="$1"
    local basename
    basename=$(basename "$file_path")

    # Allow list takes precedence
    if matches_pattern "$basename" "$ALLOW_CACHE"; then
        return 1 # not denied
    fi

    # Check deny patterns
    if matches_pattern "$basename" "$DENY_CACHE"; then
        # Check session override
        if is_overridden "$file_path"; then
            return 1 # overridden by user
        fi
        return 0 # denied
    fi

    return 1 # not denied
}

# Build deny response
deny_access() {
    local file_path="$1"
    local basename
    basename=$(basename "$file_path")

    local deny_reason
    deny_reason="Secret file access blocked: ${basename}
This file matches a secret/credential pattern in the denylist.
Ask the user if they'd like to grant temporary access for this session.
If yes, run: /opt/ddev-claude/bin/exempt-secret ${file_path}"

    jq -n --arg reason "$deny_reason" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
    exit 0
}

# Extract file paths based on tool type
case "$tool_name" in
    Read|Edit|Write)
        file_path=$(echo "$tool_input" | jq -r '.file_path // empty')
        if [[ -n "$file_path" ]]; then
            if check_path "$file_path"; then
                deny_access "$file_path"
            fi
        fi
        ;;
    Bash)
        cmd=$(echo "$tool_input" | jq -r '.command // empty')
        if [[ -z "$cmd" ]]; then
            exit 0
        fi

        # Special-case: allow exempt-secret when it's the sole command
        # Anchored start and end; reject shell metacharacters to prevent chaining
        if echo "$cmd" | grep -qE '^\s*/opt/ddev-claude/bin/exempt-secret\s+[^ ;|&$()`]+(\s+[^ ;|&$()`]+)*\s*$'; then
            jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow"}}'
            exit 0
        fi

        # Best-effort check for file-reading commands targeting secret files.
        # This is inherently bypassable (variable indirection, redirection, subshells, etc).
        # The iptables firewall is the real security boundary preventing exfiltration.
        # Extract arguments after common file-reading commands
        while IFS= read -r match; do
            [[ -z "$match" ]] && continue
            # Extract the file argument (last token that looks like a path or filename)
            local_path=$(echo "$match" | grep -oE '[^ ]+$' || true)
            if [[ -n "$local_path" ]]; then
                if check_path "$local_path"; then
                    deny_access "$local_path"
                fi
            fi
        done < <(echo "$cmd" | grep -oE '(cat|head|tail|less|more|grep|sed|awk|source|\.|cp|mv)\s+[^ |;&>]+' || true)
        ;;
esac

# No denied paths found — allow
exit 0
