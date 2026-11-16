<!-- #ddev-generated -->
---
name: whitelist
description: Manage firewall whitelist for ddev-claude. Use when blocked requests occur or user asks about network access.
user-invocable: true
---

# Firewall Whitelist Management

You are running inside a ddev-claude container with a network firewall. Outbound traffic is blocked by default, and only whitelisted domains are allowed.

## Environment

- **Global config:** `~/.ddev/ddev-claude/whitelist.json`
- **Project config:** `$DDEV_APPROOT/.ddev/ddev-claude/whitelist.json`
- **Default domains:** `$DDEV_APPROOT/.ddev/claude/config/default-whitelist.json`
- **Hot reload:** Config changes apply automatically in 2-3 seconds

## How Domain Blocking Works

A PreToolUse hook automatically intercepts tool calls (WebFetch, Bash, MCP tools) and checks if the target domain is in the firewall whitelist. If a domain is not whitelisted:

1. The hook **denies** the tool call before it reaches the network
2. You receive a message with the blocked domain and an `add-domain` command
3. **Ask the user** if they'd like to whitelist the domain
4. If approved, run the provided `add-domain` command
5. Retry the original tool call — it will succeed

This means you don't need to manually detect blocks. The hook tells you proactively.

### Fallback Detection

If hooks are not active (e.g., older container), check for blocks manually:

1. Look for "[ddev-claude] Network request BLOCKED" messages in the terminal
2. Or check dmesg: `dmesg | grep FIREWALL-BLOCK | tail -5`
3. Or run: `ddev claude:whitelist` to see blocked domains interactively

## Adding Domains to Whitelist

**ALWAYS ask for user confirmation before whitelisting domains.**

1. Explain why the domain is needed:
   - "I need access to api.example.com to fetch the API documentation"
   - "registry.npmjs.org is required for npm package installation"

2. After confirmation, use the `add-domain` command:
```bash
# Add a single domain
/opt/ddev-claude/bin/add-domain api.example.com

# Add multiple domains at once
/opt/ddev-claude/bin/add-domain api.example.com cdn.example.com
```

This command:
- Validates the domain format
- Adds it to the project whitelist (`.ddev/ddev-claude/whitelist.json`)
- Resolves the domain to IPs and updates the firewall immediately
- Updates the hook cache so subsequent tool calls are allowed

3. For global config (common tools across all projects), manually edit:
   - `~/.ddev/ddev-claude/whitelist.json`

## Removing Domains

```bash
# Remove a domain from project config
jq 'map(select(. != "domain-to-remove.com"))' \
  $DDEV_APPROOT/.ddev/ddev-claude/whitelist.json > /tmp/whitelist.json && \
  mv /tmp/whitelist.json $DDEV_APPROOT/.ddev/ddev-claude/whitelist.json
```

## Viewing Current Whitelist

Only show whitelist when explicitly asked. Don't proactively display it.

```bash
# Show merged whitelist (default + global + project)
$DDEV_APPROOT/.ddev/claude/scripts/merge-whitelist.sh
```

## Stack Templates

When you detect a project type, offer to add common domains.

**Detection:**
- Laravel: `artisan` file + `composer.json` with `laravel/framework`
- npm: `package.json` exists

**Templates available at:**
- Laravel: `$DDEV_APPROOT/.ddev/claude/config/stack-templates/laravel.json`
- npm: `$DDEV_APPROOT/.ddev/claude/config/stack-templates/npm.json`

**Offer:**
"This appears to be a Laravel project. Would you like me to add the Laravel stack domains (packagist.org, repo.packagist.org)?"

To add a stack template:
```bash
# Merge stack template with project config
jq -s 'add | unique' \
  $DDEV_APPROOT/.ddev/claude/config/stack-templates/laravel.json \
  $DDEV_APPROOT/.ddev/ddev-claude/whitelist.json > /tmp/merged.json && \
  mv /tmp/merged.json $DDEV_APPROOT/.ddev/ddev-claude/whitelist.json
```

## IP Addresses and CIDR Ranges

Whitelist files also accept IPv4 addresses and CIDR ranges (`/8` to `/32`), for example `"198.51.100.0/24"`. Suggest a range when a whitelisted domain only works intermittently: the service probably rotates a single DNS record across a pool of IPs, and the firewall only knows the one it resolved last.

`add-domain` only accepts domain names. After user approval, add the range to the project config, writing the file in place so the watcher sees the change:

```bash
jq '. + ["198.51.100.0/24"] | unique' \
  $DDEV_APPROOT/.ddev/ddev-claude/whitelist.json > /tmp/whitelist.json && \
  cat /tmp/whitelist.json > $DDEV_APPROOT/.ddev/ddev-claude/whitelist.json
```

## Wildcard Domains

Wildcards are supported: `*.example.com` matches all subdomains.

Note: Wildcards are resolved at firewall level. Each subdomain must be resolvable via DNS.

## Troubleshooting

**Check if firewall is active:**
```bash
iptables -L OUTPUT -n | head -5
```

**Check current ipset entries:**
```bash
ipset list whitelist_ips | tail -20
```

**Check watcher process:**
```bash
ps aux | grep watch-config
```

## Important Rules

1. **Always ask before editing** - Never modify whitelist.json without explicit user approval
2. **Explain domain purpose** - Tell users why each domain is needed
3. **Prefer project config** for project-specific APIs, global for common tools
4. **Don't proactively show whitelist** - Only display when asked
5. **Confirm success** - Tell users when domains are added and that hot reload is automatic
