#!/bin/bash
#ddev-generated
set -euo pipefail

WHITELIST_FILE="${1:-${DDEV_APPROOT}/.ddev/claude/whitelist-domains.txt}"
LOG_PREFIX="[ddev-claude]"

log() { echo "$LOG_PREFIX $*"; }
warn() { echo "$LOG_PREFIX WARNING: $*" >&2; }

total_ips=0
failed_domains=()

# IPv4 address with an optional /8 to /32 prefix.
OCTET='(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])'
IP_OR_RANGE="^${OCTET}(\.${OCTET}){3}(/([89]|[12][0-9]|3[0-2]))?$"

if [[ ! -f "$WHITELIST_FILE" ]]; then
  warn "Whitelist file not found: $WHITELIST_FILE"
  exit 0  # Don't fail - just no domains to whitelist
fi

while IFS= read -r domain || [[ -n "$domain" ]]; do
  # Skip empty lines and comments
  [[ -z "$domain" || "$domain" =~ ^[[:space:]]*# ]] && continue

  # Trim whitespace
  domain=$(echo "$domain" | xargs)

  # IPv4 addresses and CIDR ranges are whitelisted as-is, without DNS. Ranges
  # cover hosts that publish a single, rotating A record (api.github.com): the
  # one IP resolved here goes stale as soon as DNS hands out the next one.
  if [[ "$domain" =~ ^[0-9./]+$ ]]; then
    if [[ "$domain" =~ $IP_OR_RANGE ]] \
      && ipset add -exist whitelist_ips "$domain" timeout 3600; then
      log "Whitelisted: $domain"
      ((++total_ips))
    else
      warn "Invalid IP address or range $domain, expected IPv4 with an optional /8 to /32 prefix (skipping)"
    fi
    continue
  fi

  # Resolve domain with retries
  ips=$(dig +short +time=2 +tries=3 A "$domain" 2>/dev/null | grep -E '^[0-9]+\.' || true)

  if [[ -n "$ips" ]]; then
    while IFS= read -r ip; do
      ipset add -exist whitelist_ips "$ip" timeout 3600
      log "Whitelisted: $domain -> $ip"
      ((++total_ips))
    done <<< "$ips"
  else
    warn "Could not resolve $domain (skipping)"
    failed_domains+=("$domain")
  fi
done < "$WHITELIST_FILE"

log "Whitelist complete: $total_ips IPs added"
if [[ ${#failed_domains[@]} -gt 0 ]]; then
  warn "Failed to resolve: ${failed_domains[*]}"
fi
