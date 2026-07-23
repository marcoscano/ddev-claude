#!/bin/bash
#
# check-secrets.sh - Scan project for secret files at startup
# (local fix 2026-07-23: exec bit restored, the file ships 0644 upstream so the
# boot-time scan never ran; #ddev-generated marker removed to protect it)
#
# Runs at boot after hook registration. Scans the project directory for files
# matching deny patterns and outputs a visible warning listing detected files.
# Non-blocking — warns but doesn't prevent startup.

set -euo pipefail

LOG_PREFIX="[ddev-claude]"
SCRIPT_DIR="${DDEV_APPROOT}/.ddev/claude"
DENY_CACHE="/tmp/ddev-claude-deny-patterns.txt"
ALLOW_CACHE="/tmp/ddev-claude-allow-patterns.txt"

log() { echo "$LOG_PREFIX $*"; }

# Ensure denylist cache exists
if [[ ! -f "$DENY_CACHE" ]]; then
    if [[ -x "$SCRIPT_DIR/scripts/merge-denylist.sh" ]]; then
        "$SCRIPT_DIR/scripts/merge-denylist.sh" > /dev/null 2>&1 || true
    fi
fi

if [[ ! -f "$DENY_CACHE" ]]; then
    log "WARNING: No denylist cache available — skipping secret scan"
    exit 0
fi

# Collect matching files
found_files=()

# Scan project directory with limited depth, excluding common vendor dirs
while IFS= read -r file; do
    basename=$(basename "$file")

    # Check allow patterns first
    allowed=false
    if [[ -f "$ALLOW_CACHE" ]]; then
        while IFS= read -r pattern; do
            [[ -z "$pattern" ]] && continue
            # shellcheck disable=SC2254
            if [[ "$basename" == $pattern ]]; then
                allowed=true
                break
            fi
        done < "$ALLOW_CACHE"
    fi
    [[ "$allowed" == "true" ]] && continue

    # Check deny patterns
    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        # shellcheck disable=SC2254
        if [[ "$basename" == $pattern ]]; then
            found_files+=("$file")
            break
        fi
    done < "$DENY_CACHE"
done < <(find "${DDEV_APPROOT}" -maxdepth 4 \
    -not -path "*/vendor/*" \
    -not -path "*/node_modules/*" \
    -not -path "*/.git/*" \
    -not -path "*/.ddev/claude/*" \
    -type f 2>/dev/null || true)

if [[ ${#found_files[@]} -eq 0 ]]; then
    log "No secret files detected in project"
    exit 0
fi

# Output warning box
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  SECRET FILES DETECTED                                     ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                            ║"
echo "║  The following files match secret/credential patterns and  ║"
echo "║  will be blocked from reading by the secret-check hook:    ║"
echo "║                                                            ║"
for file in "${found_files[@]}"; do
    # Show path relative to project root, truncate if too long
    rel_path="${file#"${DDEV_APPROOT}"/}"
    if [[ ${#rel_path} -gt 54 ]]; then
        rel_path="...${rel_path: -51}"
    fi
    printf "║  • %-56s ║\n" "$rel_path"
done
echo "║                                                            ║"
echo "║  To grant temporary access, use:                           ║"
echo "║    /opt/ddev-claude/bin/exempt-secret <file_path>          ║"
echo "║                                                            ║"
echo "║  To permanently allow a pattern, add it to the allow list  ║"
echo "║  in .ddev/ddev-claude/denylist.json                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

log "Found ${#found_files[@]} secret file(s) — access will be blocked by hook"
