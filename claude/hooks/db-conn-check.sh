#!/bin/bash
#ddev-generated
#
# db-conn-check.sh - PostToolUse hook for database connection failure diagnosis
#
# Scans Bash tool output for database connection errors (MySQL/MariaDB and
# PostgreSQL). When one is found and the DDEV db container is not reachable,
# injects instructions into the agent context explaining how to whitelist the
# db container IP in the sandbox firewall. Without this, a blocked DB port
# looks like a generic "database is down" error and the agent troubleshoots
# the wrong layer.

set -euo pipefail

# Passthrough if firewall is disabled
if [[ "${DDEV_CLAUDE_NO_FIREWALL:-}" == "1" ]]; then
    exit 0
fi

input=$(cat)

tool_name=$(echo "$input" | jq -r '.tool_name // empty')
if [[ "$tool_name" != "Bash" ]]; then
    exit 0
fi

# Flatten the tool response (plain string or structured) into searchable text
response_text=$(echo "$input" | jq -r '.tool_response // empty | .. | strings' 2>/dev/null || true)
if [[ -z "$response_text" ]]; then
    exit 0
fi

# Detect a DB connection failure and infer the port from the error flavor
db_port=""
if echo "$response_text" | grep -qE "SQLSTATE\[HY000\] \[2002\]|Can't connect to MySQL server"; then
    db_port=3306
elif echo "$response_text" | grep -qE 'SQLSTATE\[08006\]|could not connect to server|connection to server (at|on) .+ failed'; then
    db_port=5432
fi
if [[ -z "$db_port" ]]; then
    exit 0
fi

db_host="${DDEV_CLAUDE_DB_HOST:-db}"

emit_context() {
    jq -n --arg ctx "$1" \
        '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'
    exit 0
}

# IPv4 only: the firewall ipset and the <ip>.sslip.io trick are IPv4-based
db_ip=$(getent ahostsv4 "$db_host" 2>/dev/null | awk '{print $1; exit}' || true)

if [[ -z "$db_ip" ]]; then
    emit_context "The command above failed with a database connection error, and the host '${db_host}' does not resolve inside this container. The database container may not be running — ask the user to check with 'ddev describe' on the host. If the database uses a different hostname, set DDEV_CLAUDE_DB_HOST accordingly."
fi

# If the port is reachable, the failure was not caused by the firewall
if timeout 2 bash -c "echo > /dev/tcp/${db_ip}/${db_port}" 2>/dev/null; then
    exit 0
fi

context=$(cat <<EOF
The command above failed with a database connection error. In the ddev-claude sandbox this usually means the firewall is blocking the database container, not that the database is down: outbound TCP is default-deny, and '${db_host}' (${db_ip}) is currently NOT reachable on port ${db_port} from this container. The container IP can change across restarts, so a previously whitelisted IP may be stale.

To fix it:
1. Whitelist the current IP: /opt/ddev-claude/bin/add-domain ${db_ip}.sslip.io
   (add-domain only accepts domain names; <ip>.sslip.io resolves back to the embedded IP. An immediate "Failed to add IP to ipset" error is expected and harmless — the root watcher applies the whitelist within ~30 seconds.)
2. Wait for the port to open: for i in \$(seq 1 12); do timeout 2 bash -c 'echo > /dev/tcp/${db_ip}/${db_port}' 2>/dev/null && break; sleep 5; done
3. Retry the original command.
EOF
)
emit_context "$context"
